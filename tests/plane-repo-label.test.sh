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

# planted: the read-back after the create fails, so the work item exists and a caller must not create it again
printf '[{"match":"expand=labels","status":500,"body":"Server Error","times":1}]' > "$CURL_FAKE_STATE/inject.json"
before="$(planeq 'console.log(p.issues.length)')"
out="$(new "A read-back that fails, or the work item is made twice")" && fail "a failed read-back after the create was accepted"
[ "$(planeq 'console.log(p.issues.length)')" = $((before + 1)) ] || fail "the failed read-back did not follow a create"
grep -q 'exists in example-org/example-repo after the create.*do not create it again' <<< "$out" || fail "the message does not say the work item exists: $out"
ai issue-close 3 >/dev/null 2>&1 || fail "issue-close of the work item whose read-back failed"
echo "  planted: the read-back after the create fails; the message says the work item exists and must not be created again"

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

# TWO REPOSITORY LABELS name no one repository: the work item is listed under none, and nothing acts on it
plane_add_item 4 "Claimed by two repositories" repo:other-repo repo:example-repo
list="$(ai board-list)" || fail "board-list: $list"
[ "$(awk '$4 == "#4" { print $3 }' <<< "$list")" = - ] || fail "a work item with two repository labels is listed under a repository: $(awk '$4 == "#4"' <<< "$list")"
for r in example-org/example-repo example-org/other-repo; do
  ! plane_fn issue_rows "$r" | jq -e 'select(.number == 4)' >/dev/null || fail "a work item with two repository labels is among the issues of $r"
done
reset_log; out="$(ai issue-close 4 2>&1)" && fail "issue-close of a work item with two repository labels was accepted"
grep -q '#4 carries more than one repository label (repo:other-repo repo:example-repo)' <<< "$out" || fail "the two labels are not named: $out"
[ "$(state_of 4)" = ready ] || fail "the work item with two repository labels changed state"
! grep -q '^\(POST\|PATCH\|PUT\|DELETE\) ' "$CURL_FAKE_STATE/requests.log" || fail "a write was sent: $(grep '^\(POST\|PATCH\|PUT\|DELETE\) ' "$CURL_FAKE_STATE/requests.log")"
echo "  planted: a work item with the labels of two repositories is listed under none and refused by name for a write; the stand-in records no write"

# board-order and epics-top place the work items of this checkout alone
order_of() { planeq "console.log(p.issues.find((i)=>i.sequence_id===$1).sort_order)"; }
reset_log; out="$(printf 'example-org/other-repo#50\n' | ai board-order --project ENG 2>&1)" || fail "board-order of another repository's work item: $out"
grep -q 'not on this board  example-org/other-repo#50' <<< "$out" || fail "another repository's work item is on the board of board-order: $out"
! grep -q '^PATCH ' "$CURL_FAKE_STATE/requests.log" || fail "board-order wrote another repository's work item: $(grep '^PATCH ' "$CURL_FAKE_STATE/requests.log")"
plane_add_item 55 "EPIC · somebody else's epic" repo:other-repo
planeset 'p.issues.find((i)=>i.sequence_id===55).sort_order=99999; p.issues.find((i)=>i.sequence_id===1).name="EPIC · ours"'
reset_log; out="$(ai epics-top 2>&1)" || fail "epics-top: $out"
grep -q 'lifted      example-org/example-repo#1' <<< "$out" || fail "epics-top did not lift the epic of this checkout: $out"
[ "$(order_of 55)" = 99999 ] || fail "epics-top moved another repository's epic to $(order_of 55)"
[ "$(order_of 1)" -lt 99999 ] || fail "epics-top did not lift its own epic"
echo "  planted: board-order given another repository's work item and epics-top beside another repository's epic write only this checkout's work items"

# the parent of a detach is the repository it is named with
parent="$(new "The parent, or the child has nothing to leave")" || fail "issue-new: $parent"
child="$(new "The child, or the parent has nothing to lose")" || fail "issue-new: $child"
parent="${parent//[!0-9]/}"; child="${child//[!0-9]/}"
ai subissue-add "$parent" "$child" >/dev/null 2>&1 || fail "subissue-add"
parent_of() { planeq "const it=p.issues.find((i)=>i.sequence_id===$1);console.log(it.parent ? p.issues.find((x)=>x.id===it.parent).sequence_id : 'none')"; }
[ "$(parent_of "$child")" = "$parent" ] || fail "the child is not under its parent"
reset_log; out="$(ai subissue-remove example-org/other-repo "$parent" "example-org/example-repo#$child" 2>&1)" && fail "a detach under a parent of another repository was accepted"
grep -q 'no Plane project is configured here for example-org/other-repo' <<< "$out" || fail "the other repository is not named: $out"
[ "$(parent_of "$child")" = "$parent" ] || fail "the child lost its parent to a detach that named another repository's"
! grep -q '^PATCH ' "$CURL_FAKE_STATE/requests.log" || fail "a write was sent: $(grep '^PATCH ' "$CURL_FAKE_STATE/requests.log")"
ai subissue-remove "$parent" "$child" >/dev/null 2>&1 || fail "the detach under the true parent"
[ "$(parent_of "$child")" = none ] || fail "the detach under the true parent did not detach"
echo "  planted: a detach under a parent named with another repository is refused and the child keeps its parent; innocent: the true parent detaches"
