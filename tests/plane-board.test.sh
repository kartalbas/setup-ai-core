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
[ "$(jq -c 'select(.number == 51) | [.parent, .subs]' <<< "$rows")" = '[null,0]' ] || fail "a work item whose parent is {} has a parent or sub-issues in its row: $(jq -c 'select(.number == 51)' <<< "$rows")"
echo "  card_rows: the row of lib/tracker.sh, the parent as a repository reference, the sub-issue count, the closing time; a parent of {} is none"

# a card that names no repository does not break the readers of the rows
items="$WORK/items"; plane_fn card_rows > "$items"
fields="$WORK/columns"; plane_fn fields_tsv | awk -F'\t' '$1 == "Status" { print $3 }' > "$fields"
[ "$(tail -n1 "$fields")" = done ] || fail "the last Status column is $(tail -n1 "$fields"), not done"
out="$(cd "$P" && node "$ROOT/lib/status.mjs" --items-file "$items" --columns-file "$fields" --board example-org/ENG --folder "$WORK" --stop-at 92 --issues 2>&1)" || fail "status.mjs on a row with no repository: $out"
grep -q -- '-#51' <<< "$out" || fail "status.mjs does not list the work item with no repository: $out"
echo "  status.mjs: a card with no repository is listed as -#51, and done is the last column"

# THE LABEL P9 says parked, which Plane has no priority for: the card row reads it whatever the native priority is, and an item
# without the label reads as before
ITEM_EXTERNAL_SOURCE=github ITEM_EXTERNAL_ID=example-org/example-repo#300 plane_add_item 300 "Parked" P9 repo:example-repo
ITEM_EXTERNAL_SOURCE=github ITEM_EXTERNAL_ID=example-org/example-repo#301 plane_add_item 301 "Not parked" repo:example-repo
planeset 'p.issues.find((i)=>i.sequence_id===300).priority="high";p.issues.find((i)=>i.sequence_id===301).priority="high"'
prio_of() { ROOT_UNDER_TEST="${2:-$ROOT}" plane_fn card_rows | jq -r --argjson n "$1" 'select(.number == $n) | .priority'; }
[ "$(prio_of 300)" = P9 ] && [ "$(prio_of 301)" = P1 ] || fail "the card row of a parked item reads $(prio_of 300) and of an item without the label $(prio_of 301), not P9 and P1"
planted="$WORK/planted"; rm -rf "$planted"; mkdir -p "$planted"; cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/templates" "$planted/"; cp "$ROOT/VERSION" "$planted/"
sed -i.bak 's/if any(.labels\[\]?; .name == "P9") then "P9" else/if false then "P9" else/' "$planted/lib/plane/tracker.sh"
cmp -s "$ROOT/lib/plane/tracker.sh" "$planted/lib/plane/tracker.sh" && fail "the planted copy equals lib/plane/tracker.sh"
[ "$(prio_of 300 "$planted")" = P1 ] || fail "planted: a card row that ignores the label P9 should read the native priority"
echo "  the card row reads the label P9 as priority P9 whatever the native priority is; an item without it reads P1 as before; a reader that ignores the label is caught"

# A FULL PAGE FOLLOWED BY A SECOND ONE: 120 more work items, and every one of them is read
planeset 'for (let i = 0; i < 120; i++) { const it = JSON.parse(JSON.stringify(p.issues[0])); it.id = require("crypto").randomUUID(); it.sequence_id = 100 + i; it.name = "Bulk " + i; it.parent = null; it.labels = []; p.issues.push(it); }'
reset_log
total="$(planeq 'console.log(p.issues.filter((i)=>!i.archived_at).length)')"
[ "$(plane_fn card_rows | wc -l | tr -d ' ')" = "$total" ] || fail "card_rows read $(plane_fn card_rows | wc -l | tr -d ' ') of $total work items"
grep -q 'cursor=' "$CURL_FAKE_STATE/requests.log" || fail "the second page was never asked for"
echo "  a full page of 100 followed by a second: all $total work items are read, and the second page was asked for by its cursor"
# planted: a reader that stops after the first page misses the rest
planted="$WORK/planted"; mkdir -p "$planted"; cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/templates" "$planted/"; cp "$ROOT/VERSION" "$planted/"
sed -i.bak 's|\[ "\$more" = true \] \|\| break|break|' "$planted/lib/plane/api.sh"
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

# A failed repository discovery on an earlier board cannot be hidden by a readable later board.
eng_id="$(planeq 'console.log(p.id)')"
printf '[{"match":"/projects/%s/labels/","status":403,"times":9,"body":{"detail":"Labels are forbidden."}}]' "$eng_id" > "$CURL_FAKE_STATE/inject.json"
out="$(ai incident-count --weeks 2 2>&1)" && fail "incident-count swallowed ENG's labels refusal before readable OPS: $out"
grep -q 'cannot read the labels of ENG - the Plane API answered 403' <<< "$out" || fail "the labels refusal was not propagated: $out"
! grep -qE '^label[[:space:]]|^incident:' <<< "$out" || fail "incident-count printed a table beside a labels refusal: $out"
printf '[]' > "$CURL_FAKE_STATE/inject.json"
echo "  incident discovery refusal: ENG labels answering 403 stops the count without a table even when OPS is readable"

# STATUS-SYNC reads the cards of each repository of the project, and the clone of each by the repository its
# work item names: by the repo: label, or by external_id where it was carried and has no label
mkdir -p "$WORK/origins/example-org"
git init -q --bare -b master "$WORK/origins/example-org/example-repo.git"; git init -q --bare -b master "$WORK/origins/example-org/carried-repo.git"
git -C "$P" remote set-url origin "$WORK/origins/example-org/example-repo.git"
git init -q -b master "$WORK/carried-repo"; git -C "$WORK/carried-repo" remote add origin "$WORK/origins/example-org/carried-repo.git"
printf 'LIVE_TAGS="prod=landed"\n' >> "$P/.ai-core/config.env"
mkdir -p "$WORK/carried-repo/.ai-core"; cp "$P/.ai-core/config.env" "$WORK/carried-repo/.ai-core/config.env"
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

# THE LANDING CONTEXT: finish-issue asks whether an issue holds a record of its landing, and so it needs every
# comment of the work item with the association of its author and the last reopening; status-sync's page holds
# the last 50 comments of a work item in testing and nothing before them
plane_add_item 76 "Landing context" repo:example-repo
planeset "p.issues.find((i)=>i.sequence_id===76).state=p.states.find((s)=>s.name==='testing').id"
plane_add_comment 76 "Landed on master:
- $sha #76 Do the thing" other@example.test
plane_add_comment 76 "Landed on master:
- $sha #76 Do the thing" stranger@example.test
planeset 'const it=p.issues.find((i)=>i.sequence_id===76);
  for (let k=1;k<=52;k++) p.comments.push({id:require("crypto").randomUUID(),issue:it.id,comment_html:"<p>talk "+k+"</p>",created_at:new Date(Date.parse(s.day+"T09:00:00Z")+ ++s.clock*1000).toISOString(),actor:s.users.find((u)=>u.email==="me@example.test").id,is_member:true});
  p.activities.push({id:require("crypto").randomUUID(),issue:it.id,field:"state",old_identifier:p.states.find((x)=>x.name==="done").id,new_identifier:p.states.find((x)=>x.name==="ready").id,created_at:new Date(Date.parse(s.day+"T09:00:00Z")+ ++s.clock*1000).toISOString()})'
context="$(plane_fn issue_landing_context example-org/example-repo 76)" || fail "issue_landing_context: $context"
[ "$(jq '.comments | length' <<< "$context")" = 54 ] || fail "the landing context holds $(jq '.comments | length' <<< "$context") comments, not all 54: $context"
[ "$(jq -r '[.comments[0, 1] | .authorAssociation] | join(" ")' <<< "$context")" = "MEMBER NONE" ] || fail "the associations of the two records are not MEMBER and NONE: $(jq -c '.comments[0, 1]' <<< "$context")"
[ "$(jq -r '.comments[0].body' <<< "$context")" = "Landed on master:
- $sha #76 Do the thing" ] || fail "the body of the first record is not the text of the comment: $(jq -c '.comments[0]' <<< "$context")"
[ "$(jq -r '.reopenedAt != null' <<< "$context")" = true ] || fail "the reopening is not in the landing context: $context"
page="$(plane_fn open_issue_page example-org/example-repo)" || fail "open_issue_page: $page"
[ "$(jq '.data.repository.issues.nodes[] | select(.number == 76) | .comments.nodes | length' <<< "$page")" = 50 ] || fail "the page of status-sync does not hold the last 50 comments of #76: $(jq -c '.data.repository.issues.nodes[] | select(.number == 76) | .comments.nodes | length' <<< "$page")"
[ "$(jq -r '.data.repository.issues.nodes[] | select(.number == 76) | .reopened.nodes[0].createdAt' <<< "$page")" = "$(jq -r '.reopenedAt' <<< "$context")" ] || fail "the page and the landing context disagree on the last reopening"
out="$(plane_fn issue_landing_context example-org/example-repo 9999 2>&1)" && fail "the landing context of a work item that does not exist was answered: $out"
echo "  issue_landing_context: all 54 comments of #76 with MEMBER and NONE for their authors and the last reopening, where the page of status-sync holds the last 50; a work item that does not exist is refused"

# The closed states are read where nothing else of the project is: a read that fails is no empty list, whatever the
# caller does with pipe failures, or a reopening would never be found. The same call with the read answered lists the
# ids of the completed and the cancelled state
closed_states() {  # closed_states [refuse]: plane_closed_state_ids with pipefail off, the states read refused once after the setup where one is named
  ( cd "$P" && PATH="$PATH_CURL" REFUSE="${1:-}" bash -c '. "$1/lib/board.sh"; set_project >/dev/null
      [ -z "$REFUSE" ] || printf "[{\"match\":\"/states/\",\"status\":502,\"times\":1}]" > "$CURL_FAKE_STATE/inject.json"
      set +o pipefail; plane_closed_state_ids' _ "${ROOT_UNDER_TEST:-$ROOT}" 2>&1 )
}
out="$(closed_states refuse)" && fail "the closed states were answered although their read was refused: $out"
printf '[]' > "$CURL_FAKE_STATE/inject.json"
out="$(closed_states)" || fail "plane_closed_state_ids: $out"
[ "$(jq 'length' <<< "$out")" = 2 ] || fail "the closed states are not the completed and the cancelled one: $out"
echo "  plane_closed_state_ids: a states read that fails fails the call, with pipefail off too; read, it lists the completed and the cancelled state"

# finish-issue tells a work item what landed once. The comment it wrote is read back from Plane, written by the
# key's own user, an active member, so the record counts; a commit the record does not list is told in full
landings() { planeq "const it=p.issues.find((i)=>i.sequence_id===$1);console.log(p.comments.filter((c)=>c.issue===it.id&&c.comment_html.includes('Landed on')).length)"; }
m="$(new "Finished more than once")" || fail "issue-new"
commit "$P" "#$m Do it once" >/dev/null
out="$(ai finish-issue "$m" 2>&1)" || fail "finish-issue: $out"
[ "$(landings "$m")" = 1 ] || fail "the work item holds $(landings "$m") records of its landing after the first run, not 1: $out"
out="$(ai finish-issue "$m" 2>&1)" || fail "finish-issue again: $out"
[ "$(landings "$m")" = 1 ] || fail "the second run added a copy of the record: $(landings "$m") records"
grep -q '^the issue holds this record already - nothing added$' <<< "$out" || fail "the second run does not say the work item holds the record: $out"
commit "$P" "#$m Do the rest" >/dev/null
out="$(ai finish-issue "$m" 2>&1)" || fail "finish-issue after a new commit: $out"
[ "$(landings "$m")" = 2 ] || fail "a commit the record lacks was not told: $(landings "$m") records"
echo "  finish-issue on a work item: the first run writes its record, a rerun adds no copy and says the work item holds it, a new commit gets the full record"

# A READ THAT FAILS leaves the last reopening, or who wrote each comment, unknown, and a record from before a
# reopening then reads as current: finish-issue must say its comments could not be read and write nothing, never
# that the work item holds the record. The same run with every read answered writes the record again, as the
# reopening voided the first.
reopened_after_landing() {  # reopened_after_landing <title>: a work item that landed, closed and reopened; prints its number
  local k
  k="$(new "$1")" || fail "issue-new"
  commit "$P" "#$k Do it" >/dev/null
  ai finish-issue "$k" >/dev/null 2>&1 || fail "finish-issue on the first landing of #$k"
  ai issue-close "$k" >/dev/null 2>&1 || fail "issue-close $k"
  ai issue-reopen "$k" >/dev/null 2>&1 || fail "issue-reopen $k"
  printf '%s\n' "$k"
}
for refused in states project-members-lite; do
  m="$(reopened_after_landing "Reopened, and its $refused cannot be read")"
  [ "$(landings "$m")" = 1 ] || fail "#$m does not hold exactly its first record before the failing run: $(landings "$m")"
  printf '[{"match":"/projects/%s/%s/","status":502,"times":1}]' "$(planeq 'console.log(p.id)')" "$refused" > "$CURL_FAKE_STATE/inject.json"
  out="$(ai finish-issue "$m" 2>&1)" || fail "finish-issue with the $refused refused: $out"
  ! grep -q 'holds this record already' <<< "$out" || fail "a record from before the reopening was taken as current while the $refused could not be read: $out"
  grep -q 'its comments could not be read' <<< "$out" || fail "the failed read of the $refused is not said: $out"
  [ "$(landings "$m")" = 1 ] || fail "a record was written while the $refused could not be read: $(landings "$m") records"
  printf '[]' > "$CURL_FAKE_STATE/inject.json"
done
# The same read answered 200 with a proxy's HTML page is no empty listing either: the landing context fails with the
# line that names the listing and prints nothing, and finish-issue writes no record and does not call the old one current.
for html in states project-members-lite comments activities; do
  m="$(reopened_after_landing "Reopened, and its $html answer is HTML")"
  printf '[{"match":"/%s/","status":200,"times":1,"body":"<html>502 Bad Gateway</html>"}]' "$html" > "$CURL_FAKE_STATE/inject.json"
  out="$(plane_fn issue_landing_context example-org/example-repo "$m" 2>"$WORK/err")" && fail "the landing context was answered although the $html listing was HTML: $out"
  [ -z "$out" ] || fail "the landing context printed '$out' although the $html listing was HTML"
  grep -q 'the answer is not the required JSON object with a results array' "$WORK/err" || fail "the HTML $html listing is not named: $(cat "$WORK/err")"
  printf '[{"match":"/%s/","status":200,"times":1,"body":"<html>502 Bad Gateway</html>"}]' "$html" > "$CURL_FAKE_STATE/inject.json"
  if [ "$html" = comments ]; then   # the thread of the work item is read before the landing context, and stops finish-issue there
    out="$(ai finish-issue "$m" 2>&1)" && fail "finish-issue went on although the comments listing was HTML: $out"
    grep -q 'the answer is not the required JSON object with a results array' <<< "$out" || fail "the HTML comments listing is not named: $out"
  else
    out="$(ai finish-issue "$m" 2>&1)" || fail "finish-issue with the $html listing as HTML: $out"
    grep -q 'its comments could not be read' <<< "$out" || fail "the HTML $html listing is not said to be unreadable: $out"
  fi
  ! grep -q 'holds this record already' <<< "$out" || fail "a record from before the reopening was taken as current while the $html listing was HTML: $out"
  [ "$(landings "$m")" = 1 ] || fail "a record was written while the $html listing was HTML: $(landings "$m") records"
  printf '[]' > "$CURL_FAKE_STATE/inject.json"
done
echo "  the landing context fails closed on a 200 answer with HTML for the states, members, comments or state changes: nothing printed, the listing named, and finish-issue writes no record and does not call the old one current"

m="$(reopened_after_landing "Reopened, and everything can be read")"
out="$(ai finish-issue "$m" 2>&1)" || fail "finish-issue after the reopening: $out"
[ "$(landings "$m")" = 2 ] || fail "the reopening did not void the first record: $(landings "$m") records: $out"
echo "  finish-issue on a reopened work item: a states or members read that fails leaves it untold and says so; read, they void the record from before the reopening and the full record is written"

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

# The same issue number in another configured project must never receive this board's move.
plane_add_item 82 "Another epic whose child has begun" repo:other-repo
plane_add_item 83 "Its child" repo:other-repo
planeset 'const e=p.issues.find((i)=>i.sequence_id===82),c=p.issues.find((i)=>i.sequence_id===83);c.parent=e.id;c.state=p.states.find((x)=>x.name==="implementing").id;
  const ops=s.projects.find((x)=>x.identifier==="OPS"), label={id:require("crypto").randomUUID(),name:"repo:other-repo",color:"#000",description:""};ops.labels.push(label);
  for (const name of ["ready","implementing"]) ops.states.push({id:require("crypto").randomUUID(),name,group:name==="ready"?"unstarted":"started",color:"#000"});
  for (const n of [80,82]) { const it=JSON.parse(JSON.stringify(p.issues.find((i)=>i.sequence_id===n)));it.id=require("crypto").randomUUID();it.project=ops.id;it.labels=[label.id];it.parent=null;it.state=ops.states.find((x)=>x.name==="ready").id;ops.issues.push(it); }'
cp "$WORK/other-repo/.ai-core/config.env" "$WORK/other-config"
for spec in 'PLANE_PROJECT=OPS' 'PLANE_URL=http://plane.example.test' 'PLANE_WORKSPACE=other' 'TRACKER=github'; do
  key="${spec%%=*}"
  cp "$WORK/other-config" "$WORK/other-repo/.ai-core/config.env"
  printf '%s\n' "$spec" >> "$WORK/other-repo/.ai-core/config.env"
  reset_log; out="$(ai status-sync other-repo 2>&1)" || fail "status-sync with different $key: $out"
  grep -q "other-repo#80.*$WORK/other-repo.*$key" <<< "$out" || fail "status-sync did not name the clone and differing $key: $out"
  [ "$(grep -c "other-repo#80.*$key" <<< "$out")" = 1 ] || fail "the differing $key was not reported once for the card: $out"
  [ "$(state_of 80)" = implementing ] && [ "$(state_of 82)" = ready ] || fail "a clone with different $key moved ENG's cards"
  [ "$(planeq 'const ops=s.projects.find((x)=>x.identifier==="OPS");console.log(ops.issues.filter((i)=>[80,82].includes(i.sequence_id)).map((i)=>ops.states.find((x)=>x.id===i.state).name).join(" "))')" = 'ready ready' ] || fail "a clone with different $key moved OPS#80 or OPS#82"
  ! grep -qE '^(PATCH|POST|PUT|DELETE) ' "$CURL_FAKE_STATE/requests.log" || fail "a clone with different $key wrote a card"
done
cp "$WORK/other-config" "$WORK/other-repo/.ai-core/config.env"
out="$(ai status-sync other-repo 2>&1)" || fail "status-sync with matching tracker identity: $out"
[ "$(state_of 80)" = done ] && [ "$(state_of 82)" = implementing ] || fail "a matching clone did not close ENG#80 and move ENG#82"
[ "$(planeq 'const ops=s.projects.find((x)=>x.identifier==="OPS");console.log(ops.issues.filter((i)=>[80,82].includes(i.sequence_id)).map((i)=>ops.states.find((x)=>x.id===i.state).name).join(" "))')" = 'ready ready' ] || fail "a matching ENG clone changed OPS#80 or OPS#82"
echo "  clone tracker identity: differing tracker, URL, workspace or project leaves both boards untouched; a matching clone closes ENG#80 and moves ENG#82 while OPS stays"

# repo-link: the repository joins the project by its label, made once
planeset 'p.labels=p.labels.filter((l)=>l.name!=="repo:example-repo")'
out="$(ai repo-link --project ENG 2>&1)" || fail "repo-link: $out"
grep -q 'linked: example-org/example-repo' <<< "$out" || fail "repo-link did not print what it linked: $out"
[ "$(planeq 'console.log(p.labels.filter((l)=>l.name==="repo:example-repo").length)')" = 1 ] || fail "repo-link did not make the repository label"
echo "  repo-link: the repository label is made, and the link printed"

# --- issue-priority P9 on Plane ---------------------------------------------------------------
# P9 is the label P9 with the native priority none, the form the carry writes; P0 to P3 are native priorities
# without that label. One PATCH carries both, and the work item is read back before the command says it is done.
section "issue-priority on Plane: P9 parks a card as the label P9 and the native priority none"
seed_item() {  # seed_item <number> [native priority]: an owned work item with an unrelated label, a parent and an assignee
  plane_add_item "$1" "Item $1" repo:example-repo area:tooling
  N="$1" NATIVE="${2:-high}" planeset 'const e=process.env,i=p.issues.find((x)=>x.sequence_id===+e.N);i.priority=e.NATIVE;i.parent=p.issues[0].id;i.assignees=[s.users[0].id]'
}
item_labels() { planeq "const i=p.issues.find((x)=>x.sequence_id===$1);console.log(i.labels.map((id)=>p.labels.find((l)=>l.id===id).name).sort().join(','))"; }
item_native() { planeq "console.log(p.issues.find((x)=>x.sequence_id===$1).priority)"; }
item_kept() { planeq "const i=p.issues.find((x)=>x.sequence_id===$1);console.log(JSON.stringify([i.name,i.description_html,i.state,i.parent,i.assignees]))"; }
p9_labels() { planeq "console.log(p.labels.filter((l)=>l.name==='P9').length)"; }
line_prio() { plane_fn board_card_lines example-org | awk -F'\t' -v n="$1" '$4 == n { print $2 }'; }
writes() { grep -c '^\(POST\|PATCH\) ' "$CURL_FAKE_STATE/requests.log" || true; }

drop_p9_label() { planeset 'const l=p.labels.find((x)=>x.name==="P9");if(l){p.issues.forEach((i)=>{i.labels=i.labels.filter((x)=>x!==l.id)});p.labels=p.labels.filter((x)=>x!==l)}'; }
drop_p9_label   # an earlier case made one
seed_item 700; seed_item 701 none
kept="$(item_kept 700)"; [ "$(p9_labels)" = 0 ] || fail "the fixture starts with a P9 label"
out="$(ai issue-priority 700 P9 2>&1)" || fail "issue-priority 700 P9: $out"
[ "$out" = "#700 -> P9" ] || fail "issue-priority says '$out'"
[ "$(p9_labels)" = 1 ] || fail "$(p9_labels) P9 labels in the project after the first P9, not one"
[ "$(item_labels 700)" = "P9,area:tooling,repo:example-repo" ] || fail "the labels of the parked item are $(item_labels 700)"
[ "$(item_native 700)" = none ] || fail "the native priority of the parked item is $(item_native 700), not none"
[ "$(item_kept 700)" = "$kept" ] || fail "parking changed the title, body, state, parent or assignee: $(item_kept 700)"
[ "$(prio_of 700)" = P9 ] && [ "$(line_prio 700)" = P9 ] || fail "the card row reads $(prio_of 700) and the board line $(line_prio 700), not P9"
[ "$(prio_of 701)" != P9 ] && [ "$(line_prio 701)" != P9 ] || fail "an item with native none and no P9 reads as parked"
echo "  P9: the label is made once, the item carries it and native none, its other labels, parent and assignee stay, the card row and the board line read P9; an item with native none and no label is not parked"
ai issue-priority 700 P9 >/dev/null 2>&1 || fail "a second P9 failed"
[ "$(item_labels 700)" = "P9,area:tooling,repo:example-repo" ] && [ "$(p9_labels)" = 1 ] || fail "a second P9 changed the membership: $(item_labels 700), $(p9_labels) labels"
for p in P0:urgent P1:high P2:medium P3:low; do
  ai issue-priority 700 P9 >/dev/null 2>&1; ai issue-priority 700 "${p%%:*}" >/dev/null 2>&1 || fail "issue-priority 700 ${p%%:*}"
  [ "$(item_native 700) $(item_labels 700) $(prio_of 700) $(line_prio 700)" = "${p##*:} area:tooling,repo:example-repo ${p%%:*} ${p%%:*}" ] \
    || fail "${p%%:*} after P9 leaves: native $(item_native 700), labels $(item_labels 700), row $(prio_of 700), line $(line_prio 700)"
done
[ "$(item_kept 700)" = "$kept" ] || fail "setting P0 to P3 changed the title, body, state, parent or assignee"
echo "  a second P9 changes nothing; each of P0 to P3 sets its native priority and takes the label P9 away, and the row and the line follow"

reset_log
out="$(ai issue-priority 700 P7 2>&1)" && fail "issue-priority accepted P7"
grep -q 'P0' <<< "$out" && grep -q 'P1' <<< "$out" && grep -q 'P2' <<< "$out" && grep -q 'P3' <<< "$out" && grep -q 'P9' <<< "$out" || fail "the refusal does not name the five values: $out"
[ "$(writes)" = 0 ] || fail "a refused value wrote $(writes) times"
cache="$(find "$WORK" -name fields.tsv -path '*cache*' | head -n1)"; [ -n "$cache" ] || fail "no fields cache to age"
sed -i.bak '/	P9	/d' "$cache"; ai issue-priority 700 P9 >/dev/null 2>&1 || fail "an old fields cache without P9 did not refresh itself"
[ "$(item_native 700) $(item_labels 700)" = "none P9,area:tooling,repo:example-repo" ] || fail "P9 through an old cache left $(item_native 700) $(item_labels 700)"
echo "  a value outside P0 to P3 and P9 is refused naming all five, with no write; a cache without P9 refreshes by itself"

out="$(ai issue-new --repo example-org/example-repo --title "Parked on arrival" --body-file "$WORK/body.md" --label type:feature --label area:tooling --priority P9 --asked-by someone --asked-in "the test" 2>&1)" || fail "issue-new --priority P9: $out"
new_n="$(planeq "console.log(Math.max(...p.issues.map((i)=>i.sequence_id)))")"
[ "$(item_native "$new_n") $(item_labels "$new_n")" = "none P9,area:tooling,repo:example-repo,type:feature" ] || fail "a work item made with P9 has $(item_native "$new_n") and $(item_labels "$new_n")"
before="$(planeq "console.log(p.issues.length)")"; reset_log
out="$(ai issue-new --repo example-org/example-repo --title "Never made" --body-file "$WORK/body.md" --label type:feature --label area:tooling --priority P7 --asked-by someone --asked-in "the test" 2>&1)" && fail "issue-new accepted P7"
[ "$(planeq "console.log(p.issues.length)") $(writes)" = "$before 0" ] || fail "an invalid creation priority made a work item or wrote"
echo "  issue-new --priority P9 writes the same representation; an invalid creation priority refuses before the item is made"

# failures: nothing says done that was not read back, and no pair is half written
seed_item 710; seed_item 711
fails() {  # fails <inject json> <message>: issue-priority 710 P9 must fail, leaving the item as it was
  printf '%s' "$1" > "$CURL_FAKE_STATE/inject.json"
  out="$(ai issue-priority 710 P9 2>&1)" && fail "$2: it said done: $out"
  printf '[]' > "$CURL_FAKE_STATE/inject.json"
  [ "$(item_native 710) $(item_labels 710)" = "high area:tooling,repo:example-repo" ] || fail "$2: the item changed to $(item_native 710) $(item_labels 710)"
  grep -q '^#710 -> P9' <<< "$out" && fail "$2: the success line was printed"
  return 0
}
fails '[{"match":"expand=labels","status":502,"times":9}]' "the item cannot be read"
fails '[{"match":"/labels/?","status":502,"times":9}]' "the labels cannot be read"
fails '[{"match":"/labels/","status":403,"skip":1,"times":1}]' "the label is refused"
fails '[{"match":"PATCH","status":400,"times":1,"body":{"detail":"no"}}]' "the write is refused"
out="$(CURL_FAKE_DROP_LABEL=P9 ai issue-priority 710 P9 2>&1)" && fail "a write that dropped the label was reported as done: $out"
grep -q 'was NOT confirmed' <<< "$out" || fail "a dropped label is not named: $out"
printf '[{"match":"PATCH","status":0,"commit":true,"times":1}]' > "$CURL_FAKE_STATE/inject.json"
out="$(ai issue-priority 711 P9 2>&1)" && fail "a write whose answer was lost was reported as done: $out"
printf '[]' > "$CURL_FAKE_STATE/inject.json"
[ "$(item_native 711) $(item_labels 711)" = "none P9,area:tooling,repo:example-repo" ] || fail "the committed write is not in the state: $(item_native 711) $(item_labels 711)"
ai issue-priority 711 P9 >/dev/null 2>&1 || fail "the rerun after a lost answer failed"
[ "$(item_labels 711)" = "P9,area:tooling,repo:example-repo" ] && [ "$(p9_labels)" = 1 ] || fail "the rerun left $(item_labels 711), $(p9_labels) P9 labels"
echo "  failures: an unreadable item, an unreadable label list, a refused label, a refused write, a write that drops the label and a lost answer each end with an error and no success line; a rerun reads what was committed"

# two commands from the no-label state meet at the write of the label: one label, one membership each
seed_item 720; seed_item 721
drop_p9_label; rm -rf "$WORK/barrier"
( CURL_FAKE_BARRIER="$WORK/barrier" CURL_FAKE_BARRIER_MATCH=/labels/ ai issue-priority 720 P9 > "$WORK/p9-a.out" 2>&1; echo $? > "$WORK/p9-a.rc" ) &
( CURL_FAKE_BARRIER="$WORK/barrier" CURL_FAKE_BARRIER_MATCH=/labels/ ai issue-priority 721 P9 > "$WORK/p9-b.out" 2>&1; echo $? > "$WORK/p9-b.rc" ) &
wait
[ "$(cat "$WORK/p9-a.rc") $(cat "$WORK/p9-b.rc")" = "0 0" ] || fail "two P9 commands at once: $(cat "$WORK/p9-a.out" "$WORK/p9-b.out")"
[ "$(p9_labels) $(item_labels 720) $(item_labels 721)" = "1 P9,area:tooling,repo:example-repo P9,area:tooling,repo:example-repo" ] || fail "two P9 commands at once left $(p9_labels) labels, $(item_labels 720) and $(item_labels 721)"
echo "  two P9 commands at one write of the label: one label, and each item carries it once"

# planted defects, each in a copy of the library
planted_run() {  # planted_run <sed expression> <number> <priority>: the command with one defect, as issue-priority runs it
  rm -rf "$planted"; mkdir -p "$planted"; cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/templates" "$planted/"; cp "$ROOT/VERSION" "$planted/"
  sed -i.bak "$1" "$planted/lib/plane/tracker.sh"
  cmp -s "$ROOT/lib/plane/tracker.sh" "$planted/lib/plane/tracker.sh" && fail "the planted copy equals lib/plane/tracker.sh: $1"
  ROOT_UNDER_TEST="$planted" ai issue-priority "$2" "$3" 2>&1
}
seed_item 730; drop_p9_label
planted_run 's/^    plane_label_ensure "\$rows" P9 .*$/    :/' 730 P9 >/dev/null && fail "planted: without the creation of the label P9 the command succeeded"
planted_run "s/{priority: \$p, labels: \$l}/{labels: \$l}/" 730 P9 >/dev/null && fail "planted: without the native priority none the command succeeded"
seed_item 731; ai issue-priority 731 P9 >/dev/null 2>&1
planted_run 's/select(.name != "P9") | //' 731 P1 >/dev/null && fail "planted: without the removal of P9 the command succeeded"
seed_item 732; reset_log
planted_run 's/oid="\$(option_id "\$2" "\$3")" || exit 1/oid=none/' 732 P7 >/dev/null; [ "$(writes)" -gt 0 ] || fail "planted: without the validation an invalid value wrote nothing"
seed_item 733
planted_run 's/\[.labels\[\].id, \$p\] | unique/[$p]/' 733 P9 >/dev/null; [ "$(item_labels 733)" = "P9" ] || fail "planted: a label list built from P9 alone should leave $(item_labels 733)"
echo "  planted defects, each caught: no label made, no native none, no P9 removal, no validation before the write, other labels not kept"

# --- a repository whose LIVE_TAGS says command, on Plane -------------------------------------------------------------
# The landing and the proof are comments of a work item, timed as Plane times them (milliseconds, a clock of its own); the
# reader of the engine's clone answers the commit of its clone and the time the test sets, before the comments or after.
echo "  a repository whose LIVE_TAGS says command: its work items are closed, and drawn, by the delivery its reader answers"
day="$(planeq 'console.log(s.day)')"
export AI_CORE_NOW="$(node -e 'console.log(Date.parse(process.argv[1]) / 1000)' "${day}T23:59:59Z")"
git init -q --bare -b master "$WORK/origins/example-org/engine.git"
git init -q -b master "$WORK/engine"; git -C "$WORK/engine" remote add origin "$WORK/origins/example-org/engine.git"
mkdir -p "$WORK/engine/.ai-core" "$WORK/engine/tools"
cp "$P/.ai-core/config.env" "$WORK/engine/.ai-core/config.env"
sed -i.bak 's/^LIVE_TAGS=.*$/LIVE_TAGS="prod=command"/' "$WORK/engine/.ai-core/config.env"; rm -f "$WORK/engine/.ai-core/config.env.bak"
printf 'LIVE_RELEASE_COMMAND="tools/read"\n' >> "$WORK/engine/.ai-core/config.env"
esha="$(commit "$WORK/engine" "Do the engine thing")"
cat > "$WORK/engine/tools/read" <<READER
#!/usr/bin/env bash
printf '{"repository":"%s","environment":"%s","commit":"%s","releasedAt":"%s","source":"run 12"}\n' "\$1" "\$2" "\$(git rev-parse HEAD)" "\$(cat "$WORK/released-at")"
READER
chmod +x "$WORK/engine/tools/read"
none="$WORK/none"; : > "$none"
plane_status() { ( cd "$P" && PATH="$PATH_CURL" AI_CORE_PROCESSES="$none" AI_CORE_AGENTS="$none" AI_CORE_ROLLOUTS="$none" bash "${ROOT_UNDER_TEST:-$ROOT}/bin/status.sh" 2>&1 ); }
engine_item() {  # engine_item <number> <proof header>: a work item in testing whose work landed in the engine, and a proof of it
  plane_add_item "$1" "Landed in the engine" repo:example-repo
  planeset "p.issues.find((i)=>i.sequence_id===$1).state=p.states.find((s)=>s.name==='testing').id"
  plane_add_comment "$1" "Landed on master of example-org/engine:
- $esha #$1 Do the engine thing"
  plane_add_comment "$1" "$2: it works"
}
engine_item 90 "Proven on prod (https://example.test)"
printf '%sT08:00:00Z\n' "$day" > "$WORK/released-at"
reset_log
out="$(ai status-sync --dry-run example-repo 2>&1)" || fail "status-sync --dry-run with a reader: $out"
grep -q "would close  example-repo#90  (testing -> done, released in example-org/engine prod delivery run 12 at ${day}T08:00:00Z and proven)" <<< "$out" \
  || fail "the delivery before the proof did not close the work item: $(grep 'example-repo#90' <<< "$out")"
! grep -qE '^(PATCH|POST|PUT|DELETE) ' "$CURL_FAKE_STATE/requests.log" || fail "a dry run with a reader wrote to Plane"
printf '%sT10:00:00Z\n' "$day" > "$WORK/released-at"
out="$(ai status-sync --dry-run example-repo 2>&1)" || fail "status-sync --dry-run with a later delivery: $out"
grep -q "proof due    example-repo#90  (released in example-org/engine prod delivery run 12 at ${day}T10:00:00Z, no \"Proven on prod\" record after both its landing and that delivery)" <<< "$out" \
  || fail "a proof before the delivery counted: $(grep 'example-repo#90' <<< "$out")"
printf '%sT08:00:00Z\n' "$day" > "$WORK/released-at"
out="$(ai status-sync example-repo 2>&1)" || fail "status-sync with a reader: $out"
[ "$(state_of 90)" = done ] || fail "the work item stands in $(state_of 90), not in done, after the applied run: $out"
echo "    status-sync: a delivery before the proof closes the work item through its own clone, a delivery after it makes the proof due, and a dry run writes nothing"

engine_item 91 "Proven on prod"; engine_item 92 "Proven on prod"
out="$(plane_status)" || fail "status with a reader: $out"
for seq in 91 92; do
  grep -qE "^  🟢 example-repo#$seq +live on prod since .* \(run 12, ${day}T08:00:00Z\)  Landed in the engine$" <<< "$out" || fail "the work item $seq is not live on prod by the delivery: $(grep "example-repo#$seq" <<< "$out")"
done
! grep -q '❓' <<< "$out" || fail "a card is unknown although every read was answered: $(grep '❓' <<< "$out")"
for listing in states project-members-lite comments activities; do
  printf '[{"match":"/%s/","status":502,"times":1}]' "$listing" > "$CURL_FAKE_STATE/inject.json"
  out="$(plane_status)" && fail "status exited 0 although the $listing read of a card was refused"
  [ "$(grep -c '^  ❓ unknown' <<< "$out")" = 1 ] || fail "the refused $listing read did not make exactly one card unknown: $(grep '❓' <<< "$out")"
  grep -qE "^  🟢 example-repo#92 +live on prod" <<< "$out" || fail "the card that could be read is not drawn after the refused $listing read: $out"
  printf '[]' > "$CURL_FAKE_STATE/inject.json"
done
echo "    status: each of the states, members, comments and state changes read of a card, refused, makes that card unknown with the exit 1 and leaves the others drawn"
unset AI_CORE_NOW
