#!/usr/bin/env bash
# One Plane project holds the work items of several repositories, told apart by the label repo:<name>: a
# work item is created with the label of the checkout's repository, a number of another repository is
# refused, and the rows give each work item the repository its label names. TRACKER=plane in a project whose
# curl is the stand-in of tests/lib.sh; each defect is planted and shown red beside its innocent case green.
#
#   bash tests/plane-repo-label.test.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
make_plane_project
printf 'A body at lib/x.sh:12\n' > "$WORK/body.md"
new() { ai issue-new --repo example-org/example-repo --title "$1" --body-file "$WORK/body.md" --label type:feature --label area:tooling --priority P2 --asked-by someone --asked-in "the test" 2>&1; }
labels_of() { planeq "const it=p.issues.find((i)=>i.sequence_id===$1);console.log(it.labels.map((id)=>p.labels.find((l)=>l.id===id).name).sort().join(' '))"; }

section "the repository label of a work item on Plane: shared projects do not mix"

# labels_create makes the label of the checkout's repository once
planeset 'p.labels=p.labels.filter((l)=>l.name!=="repo:example-repo")'
ai labels-sync >/dev/null 2>&1 || fail "labels-sync on a project without the repository label"
[ "$(planeq 'console.log(p.labels.filter((l)=>l.name==="repo:example-repo").length)')" = 1 ] || fail "labels-sync did not make repo:example-repo"
reset_log; ai labels-sync >/dev/null 2>&1 || fail "the second labels-sync"
[ "$(grep -c '^POST ' "$CURL_FAKE_STATE/requests.log")" = 0 ] || fail "a second labels-sync wrote to Plane: $(grep '^POST ' "$CURL_FAKE_STATE/requests.log")"
echo "  labels-sync: repo:example-repo is made once, and a second run writes nothing"
[ -z "$(plane_fn labels_list example-org/example-repo | grep '^repo:')" ] || fail "labels_list shows the label the harness keeps"

# issue_create: the label is on the work item
out="$(new "Say whose it is, or shared projects mix")" || fail "issue-new: $out"
[ "$(labels_of 1)" = "area:tooling repo:example-repo type:feature" ] || fail "the work item carries: $(labels_of 1)"
[ "$(ai issue-label 1 2>&1 | grep -c 'repo:')" = 0 ] || fail "issue-label shows the label the harness keeps"
echo "  issue-new: the work item carries repo:example-repo beside its own labels, which a person's label list does not show"

# planted: Plane drops the label id, which here belongs to the other project
foreign="$(planeq 'console.log(s.projects[1].labels.find((l)=>l.name==="repo:example-repo").id)')"
planeq "const rows=p.labels.map((l)=>l.name==='repo:example-repo'?{...l,id:'$foreign'}:l);console.log(JSON.stringify([{match:'/projects/'+p.id+'/labels/',status:200,times:1,body:{results:rows,next_page_results:false,next_cursor:'100:1:0'}}]))" > "$CURL_FAKE_STATE/inject.json"
out="$(new "A label that is the other project's")" && fail "a work item whose repository label Plane dropped was accepted"
grep -q 'Plane dropped the label repo:example-repo of #2: the label id belongs to another project' <<< "$out" || fail "the dropped label is not named: $out"
echo "  planted: Plane drops the label id of another project; the create is refused by name (#2 exists without it, and the message says so)"
grep -q 'exists without it' <<< "$out" || fail "the message does not say the work item exists"

# another repository's work item is refused, and nothing is written
plane_add_item 50 "Somebody else's work" repo:other-repo
state_of() { planeq "const it=p.issues.find((i)=>i.sequence_id===$1);console.log(p.states.find((s)=>s.id===it.state).name)"; }
reset_log; out="$(ai issue-close 50 2>&1)" && fail "issue-close of another repository's work item was accepted"
grep -q '#50 belongs to other-repo, not this checkout' <<< "$out" || fail "the other repository is not named: $out"
[ "$(state_of 50)" = ready ] || fail "the other repository's work item changed state"
! grep -q '^\(POST\|PATCH\|PUT\|DELETE\) ' "$CURL_FAKE_STATE/requests.log" || fail "a write was sent: $(grep '^\(POST\|PATCH\|PUT\|DELETE\) ' "$CURL_FAKE_STATE/requests.log")"
for c in "issue-reopen 50" "issue-comment 50 hello" "issue-status 50 done" "issue-edit 50 --title X"; do
  out="$(ai $c 2>&1)" && fail "$c on another repository's work item was accepted"
  grep -q '#50 belongs to other-repo' <<< "$out" || fail "$c: the other repository is not named: $out"
done
echo "  planted: a work item of another repository given to five commands is refused by name, and the stand-in records no write"
ai issue-close 1 >/dev/null 2>&1 || fail "issue-close of the checkout's own work item"
[ "$(state_of 1)" = done ] || fail "the checkout's own work item was not closed"
plane_add_item 51 "Carried over, without a repository label"
ai issue-close 51 >/dev/null 2>&1 || fail "issue-close of a work item with no repository label"
[ "$(state_of 51)" = done ] || fail "a work item with no repository label was not closed"
echo "  innocent: the checkout's own work item and one with no repo: label are closed"

# the rows
out="$(new "Still open, and ours")" || fail "issue-new: $out"
plane_add_item 53 "Open, and nobody's"
rows="$(plane_fn issue_rows example-org/example-repo)" || fail "issue_rows"
[ "$(jq -r '.number' <<< "$rows" | paste -sd, -)" = 52 ] || fail "issue_rows lists: $(jq -r '.number' <<< "$rows" | paste -sd, -)"
[ "$(jq -r '.repo' <<< "$rows")" = example-org/example-repo ] || fail "the row has the repository: $(jq -r '.repo' <<< "$rows")"
[ "$(jq -c '.labels | sort' <<< "$rows")" = '["area:tooling","type:feature"]' ] || fail "the row's labels: $(jq -c '.labels | sort' <<< "$rows")"
echo "  issue_rows: only the open work items whose repo: label names the repository, under the owner of the origin, without that label in labels"

# a repository of the project is read by its label; one of another owner is no repository of it
[ "$(plane_fn issue_rows example-org/other-repo | jq -r '.number')" = 50 ] || fail "the rows of example-org/other-repo are not exactly its work item 50"
[ "$(plane_fn issue_rows other-org/example-repo 2>&1 | grep -c 'no Plane project is configured here for other-org/example-repo')" = 1 ] || fail "the rows of another owner's repository were not refused"
echo "  issue_rows: another repository of the project has its own (here #50); another owner's repository is refused by name"
