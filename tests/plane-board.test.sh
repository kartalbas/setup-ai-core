#!/usr/bin/env bash
# The board commands against Plane: the project's states as the columns, the cards over the whole project,
# the order, the project's creation, and the commands Plane's API cannot serve, each refused with its own
# sentence. TRACKER=plane in a project whose curl is the stand-in of tests/lib.sh. A 429, an archived card
# and a full page followed by a second page are planted, each shown red beside its innocent case green.
#
#   bash tests/plane-board.test.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
make_plane_project
printf 'A body at lib/x.sh:12\n' > "$WORK/body.md"
new() { ai issue-new --repo example-org/example-repo --title "$1" --body-file "$WORK/body.md" --label type:feature --label area:tooling --priority "${2:-P2}" --asked-by someone --asked-in "the test" 2>/dev/null; }
state_of() { planeq "const it=p.issues.find((i)=>i.sequence_id===$1);console.log(p.states.find((s)=>s.id===it.state).name)"; }

section "the board commands on Plane: the states of a project are its columns"

# PROJECT-NEW: the eight states in their groups and order, and the labels, in a project that does not exist yet
printf 'PLANE_PROJECT=NEW\n' >> "$P/.ai-core/config.env"
out="$(ai project-new "The new project" 2>&1)" || fail "project-new: $out"
grep -q '^NEW$' <<< "$out" || fail "project-new did not print the identifier: $out"
grep -q 'https://plane.example.test/ws/projects/.*/issues/' <<< "$out" || fail "project-new did not print the project's address: $out"
got="$(planeq 'const n=s.projects.find((x)=>x.identifier==="NEW");console.log(n.states.filter((x)=>x.group!=="triage").sort((a,b)=>a.sequence-b.sequence).map((x)=>x.name+":"+x.group).join(" "))')"
want="backlog:backlog ready:unstarted planned:unstarted implementing:started review:started testing:started done:completed Cancelled:cancelled"
[ "$got" = "$want" ] || fail "the states are: $got"
[ "$(planeq 'const n=s.projects.find((x)=>x.identifier==="NEW");console.log(n.labels.filter((l)=>l.name==="repo:example-repo"||l.name==="type:feature"||l.name==="area:tooling").length)')" = 3 ] \
  || fail "the labels of labels.tsv and repo:example-repo were not made"
out="$(ai project-new "Again" 2>&1)" && fail "project-new made a project whose identifier is taken"
grep -q 'the Plane project NEW exists already' <<< "$out" || fail "the taken identifier is not named: $out"
out="$(ai project-new "With a copy" 12 2>&1)" && fail "project-new accepted a board to copy"
grep -q 'Plane copies no project' <<< "$out" || fail "the copy is not refused by name: $out"
echo "  project-new: eight states in their groups and order, the labels of labels.tsv and repo:example-repo; a taken identifier and a board to copy are refused by name"
sed -i.bak '/^PLANE_PROJECT=NEW$/d' "$P/.ai-core/config.env"

# THE CARDS
new "Move me to testing, or nobody sees it" P1 >/dev/null || fail "issue-new"
new "The second one" P3 >/dev/null || fail "issue-new"
ai issue-status 1 testing >/dev/null || fail "issue-status 1 testing"
[ "$(state_of 1)" = testing ] || fail "the work item is not in testing"
plane_add_item 50 "Somebody else's work" repo:other-repo
plane_add_item 51 "Carried over, without a repository label"
ITEM_EXTERNAL_SOURCE=github ITEM_EXTERNAL_ID=example-org/carried-repo#9 plane_add_item 52 "Named by its external id"
plane_add_item 53 "Archived by a person" repo:example-repo
planeset 'p.issues.find((i)=>i.sequence_id===53).archived_at="2026-10-17T10:00:00Z"'
list="$(ai board-list)" || fail "board-list: $list"
[ "$(awk '$4 == "#1" { print $1 }' <<< "$list")" = testing ] || fail "board-list does not print #1 under testing: $list"
[ "$(awk '$4 == "#1" { print $2 }' <<< "$list")" = P1 ] || fail "board-list does not print the priority P1: $list"
[ "$(awk '$4 == "#50" { print $3 }' <<< "$list")" = other-repo ] || fail "the work item of another repository is not under its own: $list"
[ "$(awk '$4 == "#52" { print $3 }' <<< "$list")" = carried-repo ] || fail "a carried work item is not under the repository its external_id names: $list"
[ "$(awk '$4 == "#51" { print $3 }' <<< "$list")" = - ] || fail "a work item without a repository is not listed under none: $list"
! grep -q '#53' <<< "$list" || fail "the archived work item is listed: $list"
echo "  board-list: #1 under testing with P1; a repository from the repo: label, from external_id, none for neither; the archived card is not listed"

# THE CARD ROWS: the shape of lib/tracker.sh, parents by repository, sub-issues counted, closed ones dated
ai subissue-add 1 2 >/dev/null 2>&1 || fail "subissue-add"
new "A closed one" >/dev/null || fail "issue-new"
ai issue-close 54 >/dev/null 2>&1 || fail "issue-close 54"
rows="$(plane_fn card_rows)" || fail "card_rows"
[ "$(jq -c 'select(.number == 1) | [.repo, .status, .priority, .subs, .open]' <<< "$rows")" = '["example-org/example-repo","testing","P1",1,true]' ] || fail "the card row of #1: $(jq -c 'select(.number == 1)' <<< "$rows")"
[ "$(jq -c 'select(.number == 2) | [.parent, .status, .priority, .open, .closedAt]' <<< "$rows")" = '["example-org/example-repo#1","ready","P3",true,null]' ] || fail "the card row of #2: $(jq -c 'select(.number == 2)' <<< "$rows")"
[ "$(jq -c 'select(.number == 54) | [.status, .open, (.closedAt != null)]' <<< "$rows")" = '["done",false,true]' ] || fail "the card row of #54: $(jq -c 'select(.number == 54)' <<< "$rows")"
[ "$(jq -c 'select(.number == 51) | .repo' <<< "$rows")" = null ] || fail "a work item without a repository has a repository in its row"
[ "$(jq -r 'select(.number == 53) | .number' <<< "$rows")" = "" ] || fail "the archived work item has a card row"
echo "  card_rows: the row of lib/tracker.sh, the parent as a repository reference, the sub-issue count, the closing time"

# a card that names no repository does not break the readers of the rows
items="$WORK/items"; plane_fn card_rows > "$items"
fields="$WORK/columns"; plane_fn fields_tsv | awk -F'\t' '$1 == "Status" { print $3 }' > "$fields"
[ "$(tail -n1 "$fields")" = done ] || fail "the last Status column is $(tail -n1 "$fields"), not done"
out="$(cd "$P" && node "$ROOT/lib/status.mjs" --items-file "$items" --columns-file "$fields" --board example-org/ENG --folder "$WORK" --stop-at 92 --issues 2>&1)" || fail "status.mjs on a row with no repository: $out"
grep -q -- '-#51' <<< "$out" || fail "status.mjs does not list the work item with no repository: $out"
echo "  status.mjs: a card with no repository is listed as -#51, and done is the last column"

# A FULL PAGE FOLLOWED BY A SECOND ONE: 120 more work items, and every one of them is read
planeset 'for (let i = 0; i < 120; i++) { const it = JSON.parse(JSON.stringify(p.issues[0])); it.id = require("crypto").randomUUID(); it.sequence_id = 100 + i; it.name = "Bulk " + i; it.parent = null; it.labels = []; p.issues.push(it); }'
reset_log
total="$(planeq 'console.log(p.issues.filter((i)=>!i.archived_at).length)')"
[ "$(plane_fn card_rows | wc -l | tr -d ' ')" = "$total" ] || fail "card_rows read $(plane_fn card_rows | wc -l | tr -d ' ') of $total work items"
grep -q 'cursor=' "$CURL_FAKE_STATE/requests.log" || fail "the second page was never asked for"
echo "  a full page of 100 followed by a second: all $total work items are read, and the second page was asked for by its cursor"
# planted: a reader that stops after the first page misses the rest
planted="$WORK/planted"; mkdir -p "$planted"; cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/templates" "$planted/"; cp "$ROOT/VERSION" "$planted/"
sed -i.bak "s|\[ \"\$(printf '%s' \"\$page\" \| jq -r '.next_page_results // false')\" = true \] \|\| break|break|" "$planted/lib/plane/api.sh"
cmp -s "$ROOT/lib/plane/api.sh" "$planted/lib/plane/api.sh" && fail "the planted copy equals the real lib/plane/api.sh"
[ "$(ROOT_UNDER_TEST="$planted" plane_fn card_rows | wc -l | tr -d ' ')" = 100 ] || fail "planted: a reader that stops after one page should read 100 work items"
echo "  planted: a reader that stops after the first page reads 100 of $total, which the check above would refuse"

# A 429 IN THE MIDDLE OF A LISTING is waited out, and the listing goes on from where it stood
reset=$(( $(date +%s) + 7 )); : > "$WORK/slept"
printf '[{"match":"cursor=","status":429,"times":1,"headers":{"X-RateLimit-Reset":"%s"}}]' "$reset" > "$CURL_FAKE_STATE/inject.json"
[ "$(plane_fn card_rows 2>/dev/null | wc -l | tr -d ' ')" = "$total" ] || fail "a 429 on the second page lost work items"
grep -qE '^[1-9][0-9]*$' "$WORK/slept" || fail "the 429 on the second page was not waited out"
printf '[{"match":"cursor=","status":429,"times":9,"headers":{"X-RateLimit-Reset":"%s"}}]' "$reset" > "$CURL_FAKE_STATE/inject.json"
out="$(plane_fn card_rows 2>&1 >/dev/null)" && fail "a 429 that never lifts was accepted"
grep -q 'rate limit still refuses after 3 waits' <<< "$out" || fail "a 429 that never lifts is not named: $out"
printf '[]' > "$CURL_FAKE_STATE/inject.json"
echo "  a 429 on the second page is waited out and the listing goes on; one that never lifts is refused by name, not read as the end of the list"

# THE ORDER: item-top, board-order and epics-top write sort_order, the smallest first
order_of() { planeq "console.log(p.issues.find((i)=>i.sequence_id===$1).sort_order)"; }
min_order="$(planeq 'console.log(Math.min(...p.issues.map((i)=>i.sort_order)))')"
ai item-top 2 >/dev/null 2>&1 || fail "item-top 2"
[ "$(order_of 2)" = "$(( min_order - 10000 ))" ] || fail "item-top 2 wrote sort_order $(order_of 2), not $(( min_order - 10000 ))"
ai item-top 54 2 >/dev/null 2>&1 || fail "item-top 54 2"
planeq 'const o=(n)=>p.issues.find((i)=>i.sequence_id===n).sort_order,a=o(54),b=o(2),rest=Math.min(...p.issues.filter((i)=>![54,2].includes(i.sequence_id)).map((i)=>i.sort_order));if(!(a<b&&b<rest))throw new Error(a+" "+b+" "+rest)' || fail "item-top 54 2 did not put #54 first and #2 directly under it"
printf 'example-org/example-repo#1\nexample-org/example-repo#54\n' | ai board-order --project ENG >/dev/null 2>&1 || fail "board-order"
[ "$(order_of 1)" -lt "$(order_of 54)" ] || fail "board-order did not put #1 above #54"
[ "$(order_of 54)" -lt "$(order_of 51)" ] || fail "board-order did not put #54 above the rest"
out="$(printf 'example-org/example-repo#9999\n' | ai board-order --project ENG 2>&1)"
grep -q 'not on this board  example-org/example-repo#9999' <<< "$out" || fail "board-order did not report a work item that is not on the board: $out"
planeset 'p.issues.find((i)=>i.sequence_id===2).name="EPIC · the second one"'
out="$(ai epics-top 2>&1)" || fail "epics-top: $out"
[ "$(order_of 2)" = "$(planeq 'console.log(Math.min(...p.issues.map((i)=>i.sort_order)))')" ] || fail "epics-top did not lift the epic to the top"
echo "  item-top, board-order and epics-top: sort_order is written, to the top or between two neighbours, and the order given is the order read"

# THE COMMANDS PLANE CANNOT SERVE, each with its own sentence and no write
reset_log
refuse() {  # refuse <words in the sentence> <command...>
  local want="$1" out; shift
  out="$(ai "$@" 2>&1)" && fail "$*: was accepted"
  grep -qF -- "$want" <<< "$out" || fail "$*: the sentence lacks '$want': $out"
}
refuse "item-move is not served on Plane" item-move --repo example-org/example-repo --from ENG --to OPS
refuse "view-filter is not served on Plane" view-filter --project ENG --view "ENG board" --clear
refuse "field-option-add is not served on Plane" field-option-add --project ENG --field Status --name extra --color BLUE
refuse "issue-transfer is not served on Plane" issue-transfer 2 example-org/other-repo
refuse "issue-unblock is not served on Plane" issue-unblock example-org/example-repo 2 example-org/example-repo 1
refuse "board-unarchive is not served on Plane" board-unarchive example-org/example-repo 2
refuse "repo-boards is not served on Plane" repo-boards
! grep -q '^\(POST\|PATCH\|PUT\|DELETE\) ' "$CURL_FAKE_STATE/requests.log" || fail "a refused command wrote to Plane: $(grep '^\(POST\|PATCH\|PUT\|DELETE\) ' "$CURL_FAKE_STATE/requests.log")"
out="$(ai schema-check 2>&1)" || fail "schema-check on Plane: $out"
grep -q "TRACKER is plane, and the schema it checks against is GitHub's" <<< "$out" || fail "schema-check does not say it is GitHub's: $out"
out="$(ai board-sync 2>&1)" || fail "board-sync on Plane exited $?: $out"
[ "$(wc -l <<< "$out" | tr -d ' ')" = 1 ] && grep -q 'every work item of a project is on its board already' <<< "$out" || fail "board-sync does not print its one line: $out"
echo "  item-move, view-filter, field-option-add, issue-transfer, issue-unblock, board-unarchive and repo-boards are each refused by name with no write; schema-check and board-sync say what they are on Plane and exit 0"
refuse "removal of a duplicate mark is not served on Plane" issue-duplicate --undo example-org/example-repo 1 example-org/example-repo 2

# THE READS OVER A REPOSITORY: its repositories, its numbers, its summaries and the incident count
[ "$(plane_fn project_repos | sort | paste -sd' ' -)" = "example-org/example-repo example-org/other-repo" ] || fail "project_repos: $(plane_fn project_repos | paste -sd' ' -)"
# the workspace holds ENG, NEW (made above, open and empty), OPS, open, with a repository of its own and one incident,
# and OLD, archived, with an incident of its own that must not be counted
planeset '
  const id=()=>require("crypto").randomUUID(), mk=(pr,labels)=>pr.issues.push({id:id(),project:pr.id,name:"An incident in "+pr.identifier,description_html:"<p></p>",priority:"none",parent:null,
    labels:labels.map((n)=>pr.labels.find((l)=>l.name===n).id),assignees:[],sort_order:65535,external_source:null,external_id:null,archived_at:null,created_at:s.day+"T08:00:00Z",
    updated_at:s.day+"T08:00:00Z",completed_at:null,sequence_id:1,state:pr.states[0].id});
  const label=(n)=>({id:id(),name:n,color:"#000",description:""});
  const ops=s.projects.find((x)=>x.identifier==="OPS");
  ops.labels.push(label("repo:ops-repo"),label("incident:duplicate")); mk(ops,["repo:ops-repo","incident:duplicate"]);
  const old={id:id(),identifier:"OLD",name:"Old",archived_at:"2026-01-01T00:00:00Z",states:[{id:id(),name:"done",color:"#000",group:"completed"}],
    labels:[label("repo:old-repo"),label("incident:duplicate")],issues:[],comments:[],relations:[],activities:[],members:[]};
  mk(old,["repo:old-repo","incident:duplicate"]); s.projects.push(old)'
[ "$(plane_fn projects_of_org example-org | paste -sd' ' -)" = "$(printf 'ENG\tEngineering OPS\tOperations NEW\tThe new project')" ] || fail "projects_of_org: $(plane_fn projects_of_org example-org | paste -sd' ' -)"
[ "$(plane_fn board_repos OPS | sort | paste -sd' ' -)" = "example-org/example-repo example-org/ops-repo" ] || fail "board_repos OPS: $(plane_fn board_repos OPS | paste -sd' ' -)"
[ "$(plane_fn board_repos ENG | sort | paste -sd' ' -)" = "example-org/example-repo example-org/other-repo" ] || fail "board_repos ENG: $(plane_fn board_repos ENG | paste -sd' ' -)"
[ "$(plane_fn issue_numbers_closed example-org/example-repo | paste -sd' ' -)" = 54 ] || fail "issue_numbers_closed: $(plane_fn issue_numbers_closed example-org/example-repo | paste -sd' ' -)"
sum="$(plane_fn issue_summaries example-org/example-repo)" || fail "issue_summaries"
[ "$(awk -F'\t' '$1 == 54 { print $2 }' <<< "$sum")" = CLOSED ] && [ "$(awk -F'\t' '$1 == 1 { print $2 "|" $3 "|" $4 }' <<< "$sum")" = "OPEN|type:feature,area:tooling|Move me to testing, or nobody sees it" ] \
  || fail "issue_summaries: $sum"
plane_add_item 60 "The work already had a ticket" repo:example-repo incident:duplicate
day="$(planeq 'console.log(s.day)')"
since="$(plane_fn issues_created_since example-org/example-repo "$day" 500)" || fail "issues_created_since"
[ "$(jq -r '[.[] | select(.createdAt != null)] | length' <<< "$since")" -ge 3 ] || fail "issues_created_since: $since"
[ "$(jq -r '[.[] | select(.labels | index("incident:duplicate"))] | length' <<< "$since")" = 1 ] || fail "the incident label is not in the rows of issues_created_since: $since"
[ "$(plane_fn issues_created_since example-org/example-repo 2999-01-01 500)" = '[]' ] || fail "issues_created_since reads work items from before the day it was asked from"
[ "$(plane_fn issues_created_since example-org/ops-repo "$day" 500 | jq -c '[.[] | .labels[]]')" = '["incident:duplicate"]' ] \
  || fail "issues_created_since does not read the project OPS: $(plane_fn issues_created_since example-org/ops-repo "$day" 500)"
[ "$(plane_fn issues_created_since example-org/old-repo "$day" 500)" = '[]' ] || fail "issues_created_since reads an archived project"
table="$(ai incident-count --weeks 2 2>&1)" || fail "incident-count: $table"
[ "$(awk '$1 == "incident:duplicate" { print $NF }' <<< "$table")" = 2 ] \
  || fail "incident-count does not count the incident of ENG and the one of OPS, and not the one of the archived project: $table"
# a project the count cannot read stops it: a table without that project would read as a table of all of them
ops_id="$(planeq 'console.log(s.projects.find((x)=>x.identifier==="OPS").id)')"
printf '[{"match":"/projects/%s/issues/","status":403,"times":9,"body":{"detail":"You do not have permission to perform this action."}}]' "$ops_id" > "$CURL_FAKE_STATE/inject.json"
out="$(ai incident-count --weeks 2 2>&1)" && fail "incident-count printed a table over a project it could not read: $out"
grep -q 'incident:duplicate' <<< "$out" && fail "incident-count printed rows beside a refused read: $out"
printf '[]' > "$CURL_FAKE_STATE/inject.json"
echo "  project_repos, board_repos, projects_of_org, issue_numbers_closed, issue_summaries, issues_created_since and incident-count read the repositories of the project by their labels, and incident-count every open project of the workspace and no archived one"

# STATUS-SYNC reads the cards of each repository of the project, and the clone of each by the repository its
# work item names: by the repo: label, or by external_id where it was carried and has no label
mkdir -p "$WORK/origins/example-org"
git init -q --bare -b master "$WORK/origins/example-org/example-repo.git"; git init -q --bare -b master "$WORK/origins/example-org/carried-repo.git"
git -C "$P" remote set-url origin "$WORK/origins/example-org/example-repo.git"
git init -q -b master "$WORK/carried-repo"; git -C "$WORK/carried-repo" remote add origin "$WORK/origins/example-org/carried-repo.git"
printf 'LIVE_TAGS="prod=landed"\n' >> "$P/.ai-core/config.env"
mkdir -p "$WORK/carried-repo/.ai-core"; printf 'LIVE_TAGS="prod=landed"\n' > "$WORK/carried-repo/.ai-core/config.env"
commit() {  # commit <dir> <subject>: an empty commit pushed to origin's master; prints its short hash
  git -C "$1" -c user.name=Test -c user.email=test@example.test checkout -q -B master 2>/dev/null
  git -C "$1" -c user.name=Test -c user.email=test@example.test commit -q --allow-empty -m "$2"
  git -C "$1" push -q origin master 2>/dev/null; git -C "$1" rev-parse --short HEAD
}
n="$(new "Landed, released and proven")" || fail "issue-new"
ai issue-status "$n" testing >/dev/null || fail "issue-status testing"
sha="$(commit "$P" "#$n Do the thing")"
plane_add_comment "$n" "Landed on master:
- $sha #$n Do the thing"
plane_add_comment "$n" "Proven on prod: it works"
ITEM_EXTERNAL_SOURCE=github ITEM_EXTERNAL_ID=example-org/carried-repo#9 plane_add_item 70 "Carried over and landed"
planeset 'p.issues.find((i)=>i.sequence_id===70).state=p.states.find((s)=>s.name==="testing").id'
sha2="$(commit "$WORK/carried-repo" "#70 Do the carried thing")"
plane_add_comment 70 "Landed on master:
- $sha2 #70 Do the carried thing"
plane_add_comment 70 "Proven on prod: it works"
plane_add_item 71 "In testing, landed, and nobody's"
planeset 'p.issues.find((i)=>i.sequence_id===71).state=p.states.find((s)=>s.name==="testing").id'
plane_add_comment 71 "Landed on master:
- $sha #71 Do the thing"
plane_add_comment 71 "Proven on prod: it works"
out="$(ai status-sync --dry-run 2>&1)" || fail "status-sync --dry-run: $out"
grep -q "would close  example-repo#$n  (testing -> done, released in its landing on origin/master and proven)" <<< "$out" || fail "the work item of the label was not found in its clone: $out"
grep -q "would close  carried-repo#70  (testing -> done, released in its landing on origin/master and proven)" <<< "$out" || fail "the carried work item was not found in the clone its external_id names: $out"
! grep -q '#71' <<< "$out" || fail "a work item that names no repository was swept: $out"
echo "  status-sync: a card is found in the clone of the repository its repo: label names, and, carried without a label, in the one its external_id names; a card that names none is not swept"
out="$(ai status-sync --dry-run example-repo 2>&1)" || fail "status-sync --dry-run example-repo: $out"
grep -q "would close  example-repo#$n" <<< "$out" || fail "status-sync with a repository named did not find the card: $out"

# a reopening after the landing record voids it: the record is of the work that closed the first time
plane_add_item 72 "Reopened after it landed" repo:example-repo
planeset 'p.issues.find((i)=>i.sequence_id===72).state=p.states.find((s)=>s.name==="testing").id'
plane_add_comment 72 "Landed on master:
- $sha #72 Do the thing"
plane_add_comment 72 "Proven on prod: it works"
planeset 'const it=p.issues.find((i)=>i.sequence_id===72);p.activities.push({id:require("crypto").randomUUID(),issue:it.id,field:"state",old_identifier:p.states.find((x)=>x.name==="done").id,new_identifier:p.states.find((x)=>x.name==="ready").id,created_at:new Date(Date.parse(s.day+"T09:00:00Z")+ ++s.clock*1000).toISOString()})'
out="$(ai status-sync --dry-run example-repo 2>&1)" || fail "status-sync --dry-run: $out"
grep -q '^no landing   example-repo#72' <<< "$out" || fail "the landing record before a reopening still counted: $out"
! grep -q "would close  example-repo#72" <<< "$out" || fail "a reopened work item was closed on the record of its first landing: $out"
echo "  status-sync: a reopening after the landing record voids it, read from the state changes of the work item"

# WHO WROTE THE PROOF: a "Proven on" comment counts when its author is an active member of the project. Plane's
# is_member says whether the key's own user is one, for every comment, so the author is looked up in the members
for spec in "73 stranger@example.test" "74 gone@example.test" "75 other@example.test"; do
  seq="${spec%% *}"; who="${spec#* }"
  plane_add_item "$seq" "Proven by $who" repo:example-repo
  planeset "p.issues.find((i)=>i.sequence_id===$seq).state=p.states.find((s)=>s.name==='testing').id"
  plane_add_comment "$seq" "Landed on master:
- $sha #$seq Do the thing"
  plane_add_comment "$seq" "Proven on prod: it works" "$who"
done
out="$(ai status-sync --dry-run example-repo 2>&1)" || fail "status-sync --dry-run: $out"
grep -q '^proof due    example-repo#73' <<< "$out" || fail "the proof of somebody who is not in the project counted: $out"
grep -q '^proof due    example-repo#74' <<< "$out" || fail "the proof of somebody who left the project counted: $out"
grep -q "would close  example-repo#75  (testing -> done, released in its landing on origin/master and proven)" <<< "$out" \
  || fail "the proof of an active member other than the key's own user did not count: $out"
echo "  status-sync: a proof counts when its author is an active member of the project; one by a stranger or by somebody who left does not"

# A CARD OF ANOTHER REPOSITORY of the project is moved by the clone of that repository, and its epic is read from
# here: the sweep applies, not only announces, and a repository with no clone here is named and left
git init -q --bare -b master "$WORK/origins/example-org/other-repo.git"
git init -q -b master "$WORK/other-repo"; git -C "$WORK/other-repo" remote add origin "$WORK/origins/example-org/other-repo.git"
for c in carried-repo other-repo; do
  mkdir -p "$WORK/$c/.ai-core"
  printf 'LIVE_TAGS="prod=landed"\nTRACKER=plane\nPLANE_URL=https://plane.example.test\nPLANE_WORKSPACE=ws\nPLANE_PROJECT=ENG\nPLANE_TOKEN_COMMAND="cat %s/token"\n' "$WORK" > "$WORK/$c/.ai-core/config.env"
done
commit "$WORK/other-repo" "Start the other repository" >/dev/null
plane_add_item 80 "EPIC · the epic of the other repository" repo:other-repo
plane_add_item 81 "Its child, begun" repo:other-repo
planeset 'const e=p.issues.find((i)=>i.sequence_id===80),c=p.issues.find((i)=>i.sequence_id===81);c.parent=e.id;c.state=p.states.find((x)=>x.name==="implementing").id'
out="$(ai status-sync --dry-run 2>&1)" || fail "status-sync --dry-run with the epic of another repository: $out"
grep -q 'would move   other-repo#80  (ready -> implementing)' <<< "$out" || fail "the epic of another repository was not read from here: $out"
out="$(ai status-sync 2>&1)" || fail "status-sync: $out"
[ "$(state_of 80)" = implementing ] || fail "the epic of the other repository stands in $(state_of 80), not in implementing"
[ "$(state_of 70)" = done ] || fail "the card of carried-repo stands in $(state_of 70), not in done"
[ "$(state_of "$n")" = done ] || fail "the card of this checkout stands in $(state_of "$n"), not in done"
echo "  status-sync: the cards of two other repositories are moved by their own clones (a closing and an epic followed to implementing), and the card of this checkout from here"
planeset 'p.issues.find((i)=>i.sequence_id===81).state=p.states.find((x)=>x.name==="done").id'
mkdir -p "$WORK/away"; mv "$WORK/other-repo" "$WORK/away/other-repo"
out="$(ai status-sync 2>&1)" || fail "status-sync without the clone of another repository: $out"
grep -q 'no clone     other-repo#80  (no clone of example-org/other-repo in ' <<< "$out" || fail "the missing clone is not named: $out"
[ "$(state_of 80)" = implementing ] || fail "the epic of a repository with no clone was moved to $(state_of 80)"
mv "$WORK/away/other-repo" "$WORK/other-repo"
echo "  status-sync: a card whose repository has no clone here is named and stays"

# repo-link: the repository joins the project by its label, made once
planeset 'p.labels=p.labels.filter((l)=>l.name!=="repo:example-repo")'
out="$(ai repo-link --project ENG 2>&1)" || fail "repo-link: $out"
grep -q 'linked: example-org/example-repo' <<< "$out" || fail "repo-link did not print what it linked: $out"
[ "$(planeq 'console.log(p.labels.filter((l)=>l.name==="repo:example-repo").length)')" = 1 ] || fail "repo-link did not make the repository label"
echo "  repo-link: the repository label is made, and the link printed"
