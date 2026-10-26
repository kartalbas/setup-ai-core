#!/usr/bin/env bash
# issue-transfer --to plane: the issues of a GitHub project carried into Plane, read-only on GitHub. GitHub is the stand-in
# gh of tests/gh-carry-fake.mjs (a world built by tests/carry-fixture.mjs), Plane the stand-in curl of tests/lib.sh;
# nothing here reaches a network. Each defect the carry must refuse is planted and shown red, the innocent case green.
#
#   bash tests/issue-transfer-plane.test.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export GH_ORG=example-org GH_PROJECT_NUMBER=1
make_plane_project
G="$WORK/gh-state"; export GH_CARRY_STATE="$G"; mkdir -p "$WORK/ghbin" "$GH_CACHE_DIRECTORY/1"
printf 'PVT_kwcarry1\n' > "$GH_CACHE_DIRECTORY/1/project-id"
printf '#!/bin/sh\nexec node "%s/tests/gh-carry-fake.mjs" "$@"\n' "$ROOT" > "$WORK/ghbin/gh"; chmod +x "$WORK/ghbin/gh"
PATH_CURL="$WORK/ghbin:$PATH_CURL"
world() { node "$ROOT/tests/carry-fixture.mjs" "$G" "$@"; : > "$G/calls.log"; }
gh_set() { GH_CARRY_STATE="$G" node -e "const fs=require('fs'),f='$G/github.json',s=JSON.parse(fs.readFileSync(f));$1;fs.writeFileSync(f,JSON.stringify(s))"; }

# two more destinations: OPS gets the states a project needs for open work, WEB is a project of its own; each repository
# has a clone beside the project folder, set up for its project
planeset 'const id=()=>require("crypto").randomUUID(), st=(n,g,d)=>({id:id(),name:n,color:"#000",group:g,sequence:15000,default:!!d});
  s.projects[1].states=[st("backlog","backlog",1),st("ready","unstarted"),st("done","completed"),st("Cancelled","cancelled")];
  s.projects.push({id:id(),identifier:"WEB",name:"Web",states:[st("Backlog","backlog",1),st("Todo","unstarted"),st("Done","completed"),st("Cancelled","cancelled")],labels:[],issues:[],comments:[],relations:[],activities:[],members:[{user:s.users[0].id,is_active:true}]})'
mkclone() {  # mkclone <repository name> <project identifier>
  mkdir -p "$WORK/$1/.ai-core"; git init -q "$WORK/$1"; git -C "$WORK/$1" remote add origin "https://forge.example.test/example-org/$1.git"
  printf 'TRACKER=github\nPLANE_URL=https://plane.example.test\nPLANE_WORKSPACE=ws\nPLANE_PROJECT=%s\nPLANE_TOKEN_COMMAND="cat %s/token"\n' "$2" "$WORK" > "$WORK/$1/.ai-core/config.env"
}
mkclone tools OPS; mkclone web WEB
git -C "$P" remote set-url origin https://forge.example.test/example-org/example-repo.git
writes() { grep -c '^\(POST\|PATCH\|PUT\|DELETE\) ' "$CURL_FAKE_STATE/requests.log" || true; }
carry() { CURL_FAKE_STDOUT="$WORK/out.txt" ai issue-transfer "$@" > "$WORK/out.txt" 2> "$WORK/err.txt"; }
pq() { local i="$1"; shift; node -e "const s=JSON.parse(require('fs').readFileSync('$CURL_FAKE_STATE/plane.json'));const p=s.projects[$i];const N=(r)=>p.issues.find((i)=>i.external_id===r);const S=(i)=>p.states.find((x)=>x.id===i.state);const L=(i)=>i.labels.map((l)=>p.labels.find((x)=>x.id===l).name).sort().join(',');const C=(i)=>p.comments.filter((c)=>c.issue===i.id);$1"; }
github_writes() { grep -c 'mutation\|--method\|--input\|issue close\|issue comment' "$G/calls.log" || true; }
me="$(planeq 'console.log(s.users[0].id)')"   # the user of the Plane key, whom the stand-in answers at users/me
who() {  # who <project index> <external id>: the assignees of that work item, comma between, or nobody
  pq "$1" "const i=N('$2');console.log(i.assignees.join(',')||'nobody')"
}

# a check is a function that takes the root of a tree and returns 0 when that tree does right; each is shown red on a copy of
# the tree with one defect planted, and green on the tree as it is
planted="$WORK/planted"
plant_copy() { rm -rf "$planted"; mkdir -p "$planted"; cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/templates" "$planted/"; cp "$ROOT/VERSION" "$planted/"; }
plant() {  # plant <check> <file> <sed expression> <what is planted> [argument of the check...]
  local check="$1" file="$2" what="$4" expression="$3"
  shift 4; plant_copy; sed -i.bak "$expression" "$planted/$file"; cmp -s "$ROOT/$file" "$planted/$file" && fail "the planted copy equals $file ($what)"
  ! "$check" "$planted" "$@" >/dev/null 2>&1 || fail "planted: $what passes the check, so it cannot go red"
}
plant_line() {  # plant_line <check> <file> <start of a line> <the line instead> <what is planted> [argument of the check...]
  local check="$1" file="$2" start="$3" line="$4" what="$5"
  shift 5; plant_copy
  START="$start" LINE="$line" awk 'index($0, ENVIRON["START"]) == 1 && !done { print ENVIRON["LINE"]; done = 1; next } { print }' "$ROOT/$file" > "$planted/$file"
  cmp -s "$ROOT/$file" "$planted/$file" && fail "no line of $file starts with '$start' ($what)"
  ! "$check" "$planted" "$@" >/dev/null 2>&1 || fail "planted: $what passes the check, so it cannot go red"
}

section "issue-transfer --to plane: one issue, then a column"
world
carry 1 --to plane || fail "issue-transfer 1 --to plane: $(cat "$WORK/out.txt" "$WORK/err.txt")"
grep -qx '#1 -> ENG-1' "$WORK/out.txt" || fail "the line '#1 -> ENG-1' is not printed: $(cat "$WORK/out.txt")"
[ "$(pq 0 'const i=N("example-org/example-repo#1");console.log([i.name,i.priority,S(i).name,i.external_source,L(i)].join("|"))')" = "example-repo issue 1|high|ready|github|area:gate,repo:example-repo,type:feature" ] \
  || fail "the work item is not as carried: $(pq 0 'console.log(JSON.stringify(N("example-org/example-repo#1")))')"
printf '<pre>Fix the carry at lib/plane/tracker.sh:312\n\n```bash\nif [ "$a" -lt 2 ] &amp;&amp; x=\x27&lt;y&gt;\x27; then echo "&amp;lt; &amp; &gt;"; fi\n```\n\nlast line\n</pre>' > "$WORK/want-html"
pq 0 'process.stdout.write(N("example-org/example-repo#1").description_html)' > "$WORK/got-html"
cmp -s "$WORK/want-html" "$WORK/got-html" || fail "the stored description_html is not the escaped body in one <pre>: $(cat "$WORK/got-html")"
[ "$(github_writes)" = 0 ] || fail "the carry wrote to GitHub: $(grep 'mutation\|--method' "$G/calls.log")"
echo "  #1 -> ENG-1: title, priority P1 as high, state ready, labels, the body byte for byte; GitHub got no write"

reset_log; carry 1 --to plane || fail "the second run: $(cat "$WORK/err.txt")"
[ "$(writes)" = 0 ] || fail "the second run wrote to Plane: $(grep '^\(POST\|PATCH\) ' "$CURL_FAKE_STATE/requests.log")"
! grep -q 'issues/?expand' "$CURL_FAKE_STATE/requests.log" || fail "the lookup read the whole project"
echo "  a second run finds the work item by its external_id and writes nothing"

# a column: the open issues whose card stands in it
gh_set 's.cards={data:{node:{items:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[{id:"PVTI_a2",content:{number:2,repository:{nameWithOwner:"example-org/example-repo"}},fieldValues:{nodes:[{name:"ready",field:{name:"Status"}}]}},{id:"PVTI_a3",content:{number:3,repository:{nameWithOwner:"example-org/example-repo"}},fieldValues:{nodes:[{name:"ready",field:{name:"Status"}}]}}]}}}}'
carry --column ready --to plane || fail "--column ready: $(cat "$WORK/out.txt" "$WORK/err.txt")"
grep -q '^#2 -> ENG-2$' "$WORK/out.txt" && ! grep -q '#3 ->' "$WORK/out.txt" || fail "the column carried the wrong issues (#3 is closed): $(cat "$WORK/out.txt")"
[ "$(pq 0 'console.log(p.issues.find((i)=>i.id===N("example-org/example-repo#2").parent).external_id)')" = "example-org/example-repo#1" ] || fail "#2 is not a sub-issue of #1"
echo "  --column ready: the open issue #2 is carried under #1, the closed #3 on the card is left"

# a column no card stands in, and a board that cannot be read, are no empty selection: each stops the carry, named
column_check() {  # column_check <root>
  ROOT_UNDER_TEST="$1" carry --column nosuch --to plane && return 1
  grep -q "no card of example-org/example-repo stands in the column 'nosuch'" "$WORK/err.txt" || return 1
  gh_set 's.fail=[{match:"items(first:100) {",times:99,rate:true}]'
  if ROOT_UNDER_TEST="$1" carry --column ready --to plane; then gh_set 's.fail=[]'; return 1; fi
  gh_set 's.fail=[]'
  grep -q 'cannot read the cards of board' "$WORK/err.txt" || return 1
  ! grep -q 'nothing is left to carry' "$WORK/out.txt"
}
column_check "$ROOT" || fail "a column no card stands in, or a board that cannot be read, did not stop the carry with a name: $(cat "$WORK/out.txt" "$WORK/err.txt")"
plant column_check lib/carry.sh '/github_carry_column_numbers/ s/ || exit 1$/ || true/' "a column read whose status is dropped"
echo "  a column no card stands in, and a board that cannot be read, each stop --column with their name and a non-zero status, never 'nothing is left to carry'; a dropped status goes red"

section "issue-transfer --to plane: the project, every case at once"
reset_plane() { planeset 's.projects.forEach((q)=>{q.issues=[];q.comments=[]})'; }
reset_plane
world; reset_log
gh_set 's.boards.find((b)=>b.id==="PVT_D").title="Empty and unlinked\nA second line"'
# the provenance comment is stamped with the clock of the carry: its instant lies between the two readings around the run
carry_from="$(date -u +%s)"
carry --to plane || fail "the project carry: $(cat "$WORK/out.txt" "$WORK/err.txt")"
carry_to="$(date -u +%s)"
out="$(cat "$WORK/out.txt")"
grep -q '^board Empty and unlinked -> ' <<< "$out" || fail "the board report did not keep the first line of its title"
! grep -q '^A second line -> ' <<< "$out" || fail "the board title split its report across lines"
for want in '14 issues of 3 repositories' 'skipped archived repositories: example-org/old' '234 original and 14 provenance, 248 in all, in 16 pages' \
  '3 archived, on 3 issues of 14), 5 of 14 issues on no board' '(1 sub-issues, 1 recorded relationships across destinations, 1 outside the selection, 1 distinct)' \
  '5 on GitHub (2 empty, 1 closed, 3 in several destinations), 10 board records' 'priority P9 on 1 of 14 issues; an email address in 1 of 14 issues (0 titles, 0 bodies, 1 of 234 comments); differing active Status values on 1 of 14' \
  'destinations: 3' "Plane requests, at most: 370 = 3 x (14 issues + 10 board records) + 248 comments + 2 x 16 comment pages + 8 metadata pages + 5 new labels + 1 outside parents + 4 reads of the Plane key's user; at 60 a minute that is 7 minutes" \
  "assignees to carry: 3 of 14 issues, as the Plane key's user (the GitHub login tester of the account that runs the carry)" \
  'assignees not carried: 2 (a Plane member is never guessed from a GitHub login): anton on example-org/example-repo#2, example-org/example-repo#3'; do
  grep -qF -- "$want" <<< "$out" || fail "the report lacks '$want': $out"
done
echo "  the report: the counts of the fixture, the skipped repository named, the assignees carried and the one not carried with its issues, and the bound of 370 requests in 7 minutes"
[ "$(head -n1 "$CURL_FAKE_STATE/stdout-at-write.log" | awk '{print $3}')" -ge "$(grep -b 'Plane requests, at most' "$WORK/out.txt" | head -n1 | cut -d: -f1)" ] || fail "a write came before the report was printed"
echo "  the whole report stood in the output before the first write"
grep -q 'carried 14 of 14 issues: 0 already complete, 14 newly created, 0 finished from an earlier run, 0 incomplete' <<< "$out" || fail "the issue total is not '14 of 14': $out"
grep -q 'board records: 10 of 10' <<< "$out" || fail "the board total is not 10 of 10: $out"
[ "$(github_writes)" = 0 ] || fail "the carry wrote to GitHub: $(grep 'mutation\|--method' "$G/calls.log")"
total="$(grep -c '^[A-Z]' "$CURL_FAKE_STATE/requests.log")"; [ "$total" -le 370 ] || fail "the carry made $total requests, more than the 370 it printed"
state_of() { pq "$1" "const i=N('$2');console.log(i?S(i).name+'|'+(i.archived_at?'archived':'active')+'|'+i.priority+'|'+L(i):'none')"; }
[ "$(state_of 0 example-org/example-repo#3)" = "done|archived|medium|repo:example-repo,type:feature" ] || fail "#3 (completed, card archived in Done): $(state_of 0 example-org/example-repo#3)"
[ "$(state_of 0 example-org/example-repo#4)" = "Cancelled|archived|none|repo:example-repo,type:feature" ] || fail "#4 (not planned, card archived in Done): $(state_of 0 example-org/example-repo#4)"
[ "$(state_of 0 example-org/example-repo#5)" = "Cancelled|active|none|repo:example-repo,type:feature" ] || fail "#5 (duplicate, no card): $(state_of 0 example-org/example-repo#5)"
[ "$(state_of 0 example-org/example-repo#6)" = "backlog|active|low|repo:example-repo,type:feature" ] || fail "#6 (reopened, card archived in Done) is not in the open default state: $(state_of 0 example-org/example-repo#6)"
[ "$(state_of 0 example-org/example-repo#7)" = "backlog|active|none|repo:example-repo,type:feature" ] || fail "#7 (no card): $(state_of 0 example-org/example-repo#7)"
[ "$(state_of 0 example-org/example-repo#8)" = "backlog|active|none|P9,repo:example-repo,type:feature" ] || fail "#8 (P9): $(state_of 0 example-org/example-repo#8)"
[ "$(state_of 0 example-org/example-repo#9)" = "backlog|active|medium|repo:example-repo,type:feature" ] || fail "#9 (two active Status values): $(state_of 0 example-org/example-repo#9)"
[ "$(state_of 0 example-org/example-repo#1)" = "ready|active|high|area:gate,repo:example-repo,type:feature" ] || fail "#1: $(state_of 0 example-org/example-repo#1)"
[ "$(state_of 1 example-org/tools#1)" = "ready|active|urgent|repo:tools,type:feature" ] || fail "tools#1 in its own project: $(state_of 1 example-org/tools#1)"
[ "$(state_of 2 example-org/web#1)" = "Backlog|active|none|repo:web,type:feature" ] || fail "web#1 has no state called ready, so it stands in the open default Backlog: $(state_of 2 example-org/web#1)"
[ "$(who 0 example-org/example-repo#1)" = "$me" ] && [ "$(who 0 example-org/example-repo#2)" = "$me" ] && [ "$(who 1 example-org/tools#1)" = "$me" ] \
  || fail "an issue assigned to the account that runs the carry does not stand assigned to the Plane key's user: #1 $(who 0 example-org/example-repo#1), #2 $(who 0 example-org/example-repo#2), tools#1 $(who 1 example-org/tools#1)"
[ "$(who 0 example-org/example-repo#3)" = nobody ] && [ "$(who 0 example-org/example-repo#4)" = nobody ] && [ "$(who 2 example-org/web#1)" = nobody ] \
  || fail "an issue assigned to another login or to nobody stands assigned: #3 $(who 0 example-org/example-repo#3), #4 $(who 0 example-org/example-repo#4), web#1 $(who 2 example-org/web#1)"
[ "$(grep -c '^GET /api/v1/users/me/' "$CURL_FAKE_STATE/requests.log")" = 2 ] && [ "$(grep -cx 'api user' "$G/calls.log")" = 1 ] \
  || fail "the Plane key's user was not read once for each of the two destinations that hold an assigned issue, or gh was not asked once who it is"
echo "  completed and archived, not planned and archived, a duplicate, a reopened issue, no card, P9 as a label, two Status values, three destinations: each in the state its facts name; the account that runs the carry as the assignee, anton and nobody as none"

# the thread: 230 comments and the provenance on one work item, the others with theirs; author, time, order and the body kept
[ "$(pq 0 'console.log(C(N("example-org/example-repo#10")).length)')" = 231 ] || fail "#10 holds $(pq 0 'console.log(C(N("example-org/example-repo#10")).length)') comments, not its 230 and the provenance"
thread_of_1="$(pq 0 'console.log(C(N("example-org/example-repo#1")).map((c)=>c.created_at+" "+c.external_id).join(","))')"
provenance_stamp="${thread_of_1##*,}"; provenance_stamp="${provenance_stamp% *}"
[ "${thread_of_1%,*}" = "2026-10-01T10:00:00Z IC_1a,2026-10-01T10:00:00Z IC_1b,2026-10-02T10:00:00Z IC_1c" ] && [ "${thread_of_1##* }" = I_example-repo1 ] \
  || fail "#1 does not hold its three comments with their own times and ids, then the provenance: $thread_of_1"
stamped_within() { local at; at="$(date -u -d "$1" +%s)" && [ "$at" -ge "$2" ] && [ "$at" -le "$3" ]; }  # stamped_within <UTC stamp> <from> <to>, in epoch seconds
stamped_within "$provenance_stamp" "$carry_from" "$carry_to" \
  || fail "the provenance of #1 is stamped $provenance_stamp, not at a time between the start ($carry_from) and the end ($carry_to) of the carry"
# planted: a carry one second before midnight, read after it, keeps its stamp within the carry; a stamp after the carry does not
stamped_within 2026-10-25T23:59:59Z "$(epoch_of 2026-10-25T23:59:58Z)" "$(epoch_of 2026-10-26T00:00:01Z)" || fail "a provenance stamped before midnight and read after it is not within its carry"
! stamped_within 2026-10-26T00:00:02Z "$(epoch_of 2026-10-25T23:59:58Z)" "$(epoch_of 2026-10-26T00:00:01Z)" || fail "a provenance stamped after its carry ended passed"
pq 0 'const c=C(N("example-org/example-repo#1"));console.log([c[0].comment_html,c[1].comment_html.split("\n")[0],c[1].comment_html.includes("&lt;b&gt;"),c[2].comment_html.includes("someone@company.ch")].join("|"))' | grep -q '^<pre>Comment 1 of 3 by @kadir (MEMBER) on 2026-10-01T10:00:00Z' || fail "the first comment lacks its author, time and order"
pq 0 'console.log(C(N("example-org/example-repo#1"))[1].comment_html.split("\n")[0])' | grep -q 'Comment 2 of 3 by an unavailable author (NONE) on' || fail "a deleted author is not marked as unavailable, with the association NONE"
pq 0 'console.log(C(N("example-org/example-repo#1"))[0].comment_html)' | grep -q 'first$' || fail "the body of the first comment lost its trailing newline"
prov() { pq 0 "const c=C(N('$1')).pop();console.log(c.comment_html)"; }
prov "example-org/example-repo#6" | grep -qx 'Last reopened on GitHub at 2026-10-05T09:00:00Z\.' || fail "the provenance of #6 does not name the time of its reopening on GitHub: $(prov example-org/example-repo#6)"
! prov "example-org/example-repo#1" | grep -q 'Last reopened' || fail "the provenance of #1, which was never reopened, names a reopening"
[ "$(pq 0 'console.log(p.issues.find((i)=>i.id===N("example-org/example-repo#2").parent).external_id)')" = "example-org/example-repo#1" ] || fail "#2 is not a sub-issue of #1 in the project carry"
prov example-org/example-repo#2 | grep -q 'Parent: example-org/example-repo#1 .*, a sub-issue in Plane' || fail "the parent of #2 is not in its provenance: $(prov example-org/example-repo#2)"
[ "$(pq 0 'console.log(N("example-org/example-repo#7").parent)')" = null ] || fail "#7 got a native parent although its parent stands in another destination"
prov example-org/example-repo#7 | grep -q 'Parent: example-org/tools#1 (https://github.com/example-org/tools/issues/1), in another destination' || fail "the parent in another destination is not recorded: $(prov example-org/example-repo#7)"
prov example-org/example-repo#7 | grep -qF "Plane parent link: https://plane.example.test/ws/browse/OPS-$(pq 1 'console.log(N("example-org/tools#1").sequence_id)')/" || fail "the provenance of #7 does not name the Plane link of its parent tools#1 in the other destination: $(prov example-org/example-repo#7)"
prov example-org/example-repo#11 | grep -q 'Parent: example-org/old#1 .* outside the selected issues' || fail "the parent in an archived repository is not recorded: $(prov example-org/example-repo#11)"
prov example-org/example-repo#5 | grep -q 'close reason: DUPLICATE' || fail "the duplicate close reason is lost: $(prov example-org/example-repo#5)"
! prov example-org/example-repo#12 | grep -q 'earlier carry' || fail "#12 has a \"Moved to\" comment but no work item stood in Plane before, and its provenance speaks of an earlier carry: $(prov example-org/example-repo#12)"
prov example-org/example-repo#9 | grep -q 'board 2 "Second" item PVTI_b9: Status planned' || fail "the second membership of #9 is not in its provenance: $(prov example-org/example-repo#9)"
pq 0 'console.log(JSON.stringify(N("example-org/example-repo#6")))' | grep -q '"archived_at":null' || fail "a reopened issue was archived"
echo "  230 comments and the provenance on one work item; author, own time, order and trailing newline of a comment; a deleted author; parents across destinations, with the Plane link, and outside the selection; DUPLICATE; a \"Moved to\" comment that no earlier carry made; every membership"

# the request shapes: no detail read of an item (an archived one answers 404 there), the metadata once per destination, the pages of a thread bounded
! grep -E '^GET /api/v1/workspaces/ws/(issues/[A-Z]+-[0-9]+|projects/[0-9a-f-]{36}/issues/[0-9a-f-]{36}/(\?|$))' "$CURL_FAKE_STATE/requests.log" || fail "the carry read a work item by its detail endpoint"
[ "$(grep -c '^GET .*/states/' "$CURL_FAKE_STATE/requests.log")" = 3 ] && [ "$(grep -c '^GET .*/labels/' "$CURL_FAKE_STATE/requests.log")" = 3 ] || fail "the states or labels were read more often than once per destination"
ten="$(pq 0 'console.log(N("example-org/example-repo#10").id)')"
[ "$(grep -c "^GET .*/issues/$ten/comments/" "$CURL_FAKE_STATE/requests.log")" = 3 ] || fail "the 231 comments of #10 were read with $(grep -c "^GET .*/issues/$ten/comments/" "$CURL_FAKE_STATE/requests.log") page reads, not 3 (one read after the writes)"
echo "  no detail read of a work item, states and labels read once per destination, the thread of 231 read in 3 pages"

# a rerun writes nothing, and what a person changed in Plane stays
planeset 'const a=p.issues.find((i)=>i.external_id==="example-org/example-repo#3");a.archived_at=null;a.state=p.states.find((x)=>x.name==="ready").id;
  const b=p.issues.find((i)=>i.external_id==="example-org/example-repo#1");b.name="Renamed by a person";b.priority="low";b.parent=null;b.labels=[];
  p.comments.find((c)=>c.external_id==="IC_1a").comment_html="<pre>edited by a person</pre>"'
before="$(pq 0 'console.log(p.issues.length+" "+p.comments.length)')"
rm -rf "$HOME/.cache" "$GH_CACHE_DIRECTORY/plane"; reset_log; world; carry --to plane || fail "the rerun: $(cat "$WORK/out.txt" "$WORK/err.txt")"
[ "$(writes)" = 0 ] || fail "the rerun wrote to Plane: $(grep '^\(POST\|PATCH\|PUT\|DELETE\) ' "$CURL_FAKE_STATE/requests.log" | head -3)"
grep -q 'carried 14 of 14 issues: 14 already complete, 0 newly created, 0 finished from an earlier run, 0 incomplete' "$WORK/out.txt" || fail "the rerun does not report 14 complete: $(tail -3 "$WORK/out.txt")"
[ "$(pq 0 'console.log(p.issues.length+" "+p.comments.length)')" = "$before" ] || fail "the rerun made a second work item or comment"
[ "$(pq 0 'const a=N("example-org/example-repo#3"),b=N("example-org/example-repo#1");console.log([S(a).name,a.archived_at,b.name,b.priority,b.parent,L(b),p.comments.find((c)=>c.external_id==="IC_1a").comment_html].join("|"))')" = "ready||Renamed by a person|low|||<pre>edited by a person</pre>" ] || fail "a change made in Plane was written back"
echo "  a rerun with the caches gone writes nothing: 14 already complete; a changed state, an unarchived item, a new title, priority, labels and parent, and an edited comment all stay"

# GitHub is never written, on any path; the removed close and comment path shows the check red
plant_copy
sed -i.bak 's|if \[ "\$label" = short \]; then echo|carry_in_tracker github issue_close "${ref%#*}" "${ref##*#}" not-planned \|\| true; if [ "$label" = short ]; then echo|' "$planted/lib/carry.sh"
cmp -s "$ROOT/lib/carry.sh" "$planted/lib/carry.sh" && fail "the planted copy equals lib/carry.sh"
: > "$G/calls.log"; ROOT_UNDER_TEST="$planted" carry 1 --to plane >/dev/null 2>&1 || true
[ "$(github_writes)" != 0 ] || fail "planted: a carry that closes the GitHub issue is not seen by the write check, so it cannot go red"
echo "  the GitHub request log holds no write, no comment, no close; a carry that closes the issue as before is caught"

# the carry of one issue or one column names each board of the issue's memberships by number and title, reading those boards and
# no others, within the request bound it printed; an issue on no board gets no board line and no board read
boards_named() {  # boards_named <root>: 0 where all of that holds
  local root="$1" text
  reset_plane; world; reset_log
  ROOT_UNDER_TEST="$root" carry 9 --to plane || return 1
  [ "$(grep -c '^[A-Z]' "$CURL_FAKE_STATE/requests.log")" -le "$(sed -n 's/^Plane requests, at most: \([0-9]*\) =.*/\1/p' "$WORK/out.txt")" ] || return 1
  text="$(prov example-org/example-repo#9)"
  grep -qF 'board 1 "Main" item PVTI_a9: Status ready' <<< "$text" && grep -qF 'board 2 "Second" item PVTI_b9: Status planned' <<< "$text" || return 1
  [ "$(grep -c 'on ProjectV2 { id number title }' "$G/calls.log")" = 2 ] && ! grep -q 'projectsV2' "$G/calls.log" || return 1
  gh_set 's.cards={data:{node:{items:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[{id:"PVTI_a2",content:{number:2,repository:{nameWithOwner:"example-org/example-repo"}},fieldValues:{nodes:[{name:"ready",field:{name:"Status"}}]}}]}}}}'
  : > "$G/calls.log"
  ROOT_UNDER_TEST="$root" carry --column ready --to plane || return 1
  grep -qF 'board 1 "Main" item PVTI_a2: Status ready' <<< "$(prov example-org/example-repo#2)" || return 1
  [ "$(grep -c 'on ProjectV2 { id number title }' "$G/calls.log")" = 1 ] || return 1
  : > "$G/calls.log"
  ROOT_UNDER_TEST="$root" carry 5 --to plane || return 1
  text="$(prov example-org/example-repo#5)"
  grep -qF 'Board memberships (0): none.' <<< "$text" && ! grep -q '^Board memberships.*board ' <<< "$text" && ! grep -q 'on ProjectV2 { id number title }' "$G/calls.log"
}
boards_named "$ROOT" || fail "a carry of one issue or one column does not name its boards by number and title, or reads more than they name: $(prov example-org/example-repo#9)"
plant boards_named lib/carry.sh '/github_carry_board_names/ s/^.*$/    :/' "the board read taken out of the carry of one issue"
echo "  a carry of one issue and of one column names each board of the memberships by number and title, one read per board and no listing of the boards; an issue on no board reads none and gets no board line; with the board read taken out the check is red"

# a board of a membership that GitHub does not answer for stops the carry of one issue, named, before any write
board_unread_refused() {  # board_unread_refused <root>: 0 where the carry refuses, names the board and writes nothing
  local root="$1"
  reset_plane; world; reset_log
  gh_set 's.boards=s.boards.filter((b)=>b.id!=="PVT_B")'
  ! ROOT_UNDER_TEST="$root" carry 9 --to plane && grep -q 'cannot read the board PVT_B' "$WORK/err.txt" && [ "$(writes)" = 0 ]
}
board_unread_refused "$ROOT" || fail "a board GitHub does not answer for did not stop the carry of one issue before any write: $(cat "$WORK/err.txt")"
plant_line board_unread_refused lib/github/tracker.sh '      || die "cannot read the board $id' '      || true' "a board that cannot be read passed over"
echo "  a board of a membership that GitHub does not answer for stops the carry of one issue before any write, and names the board; with the refusal taken out the check is red"

# a source that cannot be read whole stops before any write: a missing clone, a partial GraphQL answer
reset_plane; world; reset_log; mkdir -p "$WORK/off"; mv "$WORK/tools" "$WORK/off/tools"
carry --to plane && fail "a repository without a clone was carried past"
grep -q 'no clone of example-org/tools' "$WORK/err.txt" || fail "the repository without a clone is not named: $(cat "$WORK/err.txt")"
mv "$WORK/off/tools" "$WORK/tools"
gh_set 's.fail=[{match:"issues(first:50",times:1}]'
carry --to plane && fail "a partial GraphQL answer was read as the whole source"
grep -q 'cannot read the issues of example-org/' "$WORK/err.txt" || fail "the failed read is not named: $(cat "$WORK/err.txt")"
[ "$(writes)" = 0 ] || fail "a source read that failed was followed by a write"
gh_set 's.fail=[{match:"repositories(first:100",times:1,rate:true}]'; : > "$WORK/slept"
carry --to plane || fail "GitHub's rate limit stopped the read: $(cat "$WORK/err.txt")"
grep -q '^60$' "$WORK/slept" || fail "the GitHub rate limit was not waited out through AI_CORE_SLEEP: $(cat "$WORK/slept")"
echo "  a repository without a clone and a partial GraphQL answer each stop the carry, named, before any write; GitHub's rate limit is waited out through AI_CORE_SLEEP"

# a harness clone has no .ai-core/config.env: its destination is the layer's config.env at its root; a product clone's
# own .ai-core/config.env is read as before, a config.env at the root of a product clone is not
mkdir -p "$WORK/tools-ai-core"; git init -q "$WORK/tools-ai-core"; git -C "$WORK/tools-ai-core" remote add origin https://github.com/example-org/tools-ai-core.git
printf 'TRACKER="github"\nPLANE_URL=https://plane.example.test\nPLANE_WORKSPACE=ws\nPLANE_PROJECT=OPS\nPLANE_TOKEN_COMMAND="cat %s/token"\n' "$WORK" > "$WORK/tools-ai-core/config.env"
destination_of() { ( cd "$P" && bash -c '. "$1/lib/carry.sh"; carry_destination_of "$2"' _ "$1" "$2" ); }
harness_destination() {  # harness_destination <root>: 0 where the harness clone's destination is its layer's project and the product clone's is its own
  [ "$(destination_of "$1" example-org/tools-ai-core)" = "$(printf 'example-org/tools-ai-core\t%s\thttps://plane.example.test|ws|OPS' "$WORK/tools-ai-core")" ] \
    && [ "$(destination_of "$1" example-org/web)" = "$(printf 'example-org/web\t%s\thttps://plane.example.test|ws|WEB' "$WORK/web")" ]
}
harness_destination "$ROOT" || fail "the destination of a harness clone is not read from its layer's config.env: $(destination_of "$ROOT" example-org/tools-ai-core)"
plant harness_destination lib/common.sh 's|&& is_harness_clone "\$main"; then|\&\& false; then|' "the layer's config.env not read for a harness clone"
echo "  a harness clone's destination is the project its layer's config.env names; a product clone's is still its own, and the planted copy that reads no layer's config.env is caught"

# the fake Plane is as strict as Plane 1.4.2, asserted on its own
pid="$(planeq 'console.log(p.id)')"; ident="$(pq 0 'console.log("ENG-"+N("example-org/example-repo#4").sequence_id)')"; four="$(pq 0 'console.log(N("example-org/example-repo#4").id)')"
http() { local body="${3:-}"; printf 'url = "https://plane.example.test%s"\nrequest = "%s"\nheader = "X-API-Key: plane-token-0123"\n%s' "$2" "$1" "${body:+data-binary = \"$(printf '%s' "$body" | sed 's/[\\"]/\\&/g')\"}" | PATH="$PATH_CURL" curl --config - --silent --output "$WORK/http-body"; }
[ "$(http GET "/api/v1/workspaces/ws/issues/$ident/")" = 404 ] && [ "$(http GET "/api/v1/workspaces/ws/projects/$pid/issues/$four/")" = 404 ] || fail "an archived work item answers a detail read"
[ "$(http GET "/api/v1/workspaces/ws/projects/$pid/issues/$four/comments/")" = 200 ] || fail "the comments of an archived work item cannot be listed"
other="$(pq 0 'console.log(N("example-org/example-repo#1").id)')"
[ "$(http POST "/api/v1/workspaces/ws/projects/$pid/issues/$other/comments/" '{"comment_html":"x","external_source":"github","external_id":"IC_1a","created_at":"2020-01-02T03:04:05Z"}')" = 409 ] || fail "a comment external id used again on another work item is accepted"
[ "$(http POST "/api/v1/workspaces/ws/projects/$pid/issues/$other/comments/" '{"comment_html":"y","external_source":"github","external_id":"IC_new","created_at":"2020-01-02T03:04:05Z"}')" = 201 ] \
  && [ "$(date -u -d "$(jq -r .created_at "$WORK/http-body")" +%s)" = "$(date -u -d 2020-01-02T03:04:05Z +%s)" ] \
  && jq -e '.created_at | test("^2020-01-02T04:04:05\\.[0-9]{6}\\+01:00$")' "$WORK/http-body" > /dev/null || fail "created_at of a comment is not kept as the instant, written in the zone of the server with microseconds: $(cat "$WORK/http-body")"
[ "$(http POST "/api/v1/workspaces/ws/projects/$pid/issues/" '{"name":"twin","external_source":"github","external_id":"example-org/example-repo#4"}')" = 409 ] || fail "an item external id used twice is accepted"
echo "  the stand-in answers 404 to both detail reads of an archived item, lists its comments, refuses a comment external id used on another item, keeps the instant of created_at, written in the zone of the server, and an item external id is unique"

# an interruption at every stage of one issue: after the create, after an early comment, before the provenance and after it,
# each as a write that was lost and a write that was made without its answer; a rerun without caches finishes the rest
one_issue() {  # one_issue <inject json>: a fresh Plane, #1 carried with the answer planted; prints the exit status
  reset_plane; : > "$WORK/slept"; printf '%s' "$1" > "$CURL_FAKE_STATE/inject.json"; local rc=0
  carry 1 --to plane || rc=$?
  printf '[]' > "$CURL_FAKE_STATE/inject.json"; echo "$rc"
}
posts="POST /api/v1/workspaces/ws/projects/$(planeq 'console.log(p.id)')/issues/"
for at in 0 1 3 4; do   # POST number 0 is the create, 1 to 3 the comments, 4 the provenance (the labels stand already)
  rc="$(one_issue "[{\"match\":\"$posts\",\"status\":0,\"commit\":true,\"times\":1,\"skip\":$at}]")"
  [ "$rc" = 0 ] || fail "a write made without its answer (POST $at) left the carry incomplete: $(cat "$WORK/err.txt")"
  [ "$(pq 0 'console.log(p.issues.length+" "+p.comments.length)')" = "1 4" ] || fail "after the answer to POST $at was lost: $(pq 0 'console.log(p.issues.length+" "+p.comments.length)') items and comments, not 1 and 4"
  rc="$(one_issue "[{\"match\":\"$posts\",\"status\":503,\"times\":1,\"skip\":$at}]")"
  [ "$rc" != 0 ] || fail "a write that was lost (POST $at) was reported as carried"
  grep -q 'INCOMPLETE\|NOT created' "$WORK/err.txt" || fail "the incomplete issue is not named after POST $at: $(cat "$WORK/err.txt")"
  reset_log; carry 1 --to plane || fail "the rerun after the write $at was lost: $(cat "$WORK/err.txt")"
  [ "$(pq 0 'console.log(p.issues.length+" "+p.comments.length)')" = "1 4" ] || fail "the rerun after POST $at: $(pq 0 'console.log(p.issues.length+" "+p.comments.length)') items and comments, not 1 and 4"
  [ "$(pq 0 'const i=p.issues[0];console.log(S(i).name+"|"+L(i))')" = "ready|area:gate,repo:example-repo,type:feature" ] || fail "the rerun after POST $at left the work item as $(pq 0 'console.log(JSON.stringify(p.issues[0]))')"
  reset_log; carry 1 --to plane; [ "$(writes)" = 0 ] || fail "the next complete run wrote after POST $at"
done
echo "  the answer to the create, to a comment and to the provenance lost, or the write refused: a lost answer heals, a lost write is named and the rerun finishes it, one work item and 4 comments each time, and the next run writes nothing"
reset_plane
planeset 'p.issues.push({id:require("crypto").randomUUID(),project:p.id,name:"other",description_html:"",priority:"none",parent:null,labels:[],assignees:[],external_source:"x",external_id:"y",archived_at:null,created_at:s.day,updated_at:s.day,sequence_id:77,state:p.states[1].id});
  p.comments.push({id:require("crypto").randomUUID(),issue:p.issues[0].id,comment_html:"x",created_at:s.day,actor:s.users[0].id,external_source:"github",external_id:"IC_1b"})'
carry 1 --to plane && fail "a comment identity that stands on another work item was carried past"
grep -q 'the comment identity IC_1b stands on another work item of the project' "$WORK/err.txt" || fail "the comment identity conflict is not named: $(cat "$WORK/err.txt")"
echo "  a comment identity that stands on another work item is a named conflict, 409 reconciled against the right item"

# the old forms stay as they were
reset_log
out="$(ai issue-transfer 7 example-org/other-repo 2>&1)" && fail "the old form was accepted on Plane"
grep -q 'issue-transfer is not served on Plane' <<< "$out" || fail "the old form on Plane: $out"
out="$(ai issue-transfer 7 --to forgejo 2>&1)" && fail "--to forgejo was accepted"
out="$(ai issue-transfer --column ready 2>&1)" && fail "--column without --to was accepted"
out="$(ai issue-transfer --project 6 7 example-org/other-repo 2>&1)" && fail "--project was accepted"
echo "  issue-transfer N OWNER/REPO is refused on Plane as before; an unknown flag, --to forgejo and --column alone are refused"

# the defects the report and the reader must not have: each planted in a copy and shown red, the real code green beside it
world_check() {  # world_check <root>: the small world carried by that root; 0 when the bound, the duplicate and the archived card are right
  reset_plane; world
  ROOT_UNDER_TEST="$1" carry --to plane || return 1
  local line r m l u k
  line="$(grep 'Plane requests, at most' "$WORK/out.txt")"
  r="$(sed -n 's/.*at most: \([0-9]*\) =.*/\1/p' <<< "$line")"; m="$(sed -n 's/.* + \([0-9]*\) metadata pages.*/\1/p' <<< "$line")"
  l="$(sed -n 's/.* + \([0-9]*\) new labels.*/\1/p' <<< "$line")"; u="$(sed -n 's/.* + \([0-9]*\) outside parents.*/\1/p' <<< "$line")"
  k="$(sed -n 's/.* + \([0-9]*\) reads of the Plane key.*/\1/p' <<< "$line")"
  # the fixture's own figures: 3 x (14 issues + 10 board records), 248 comments with the provenance, 2 x 16 comment pages
  [ "$r" = "$((72 + 248 + 32 + m + l + u + k))" ] || { echo "the bound $r is not the sum of its terms"; return 1; }
  pq 0 'console.log(C(N("example-org/example-repo#5")).pop().comment_html)' | grep -q 'close reason: DUPLICATE' || { echo "the duplicate is lost"; return 1; }
  [ "$(pq 0 'console.log(!!N("example-org/example-repo#3"))')" = true ] && pq 0 'console.log(JSON.stringify(N("example-org/example-repo#3")))' | grep -q '"archived_at":"' || { echo "the archived card is lost"; return 1; }
}
world_check "$ROOT" || fail "the real code does not carry the small world right: $(cat "$WORK/out.txt" "$WORK/err.txt" | tail -3)"
plant world_check lib/github/tracker.sh 's/stateReason(enableDuplicate: true)/stateReason/' "a query without enableDuplicate"
plant world_check lib/github/tracker.sh 's/projectItems(first:50, includeArchived: true)/projectItems(first:50)/' "a membership query without includeArchived"
plant world_check lib/carry.sh 's/ + (\$r.comments_original + \$r.comments_provenance) + 2 \*/ + 2 */' "a bound without its comment term"
echo "  planted and red: a query without enableDuplicate, one without includeArchived, a bound that omits the comments; the code as it is, green"

# the close of an earlier carry: the old issue-transfer commented "Moved to <address of the work item>" and closed the issue as not
# planned. The provenance says so only for an issue whose work item stood in Plane before, whose comment names that work item, and
# whose close came after the comment with no reopening since; a close a person made later is the issue's own
section "the close of an earlier carry"
legacy_world() {
  world
  gh_set 'const R="example-org/example-repo",T=(type,createdAt)=>({type,createdAt}),at="2026-10-04T10:00:00Z",closed=T("CLOSED_EVENT","2026-10-04T10:00:05Z");
    const mk=(n,link,timeline)=>({number:n,id:"I_example-repo"+n,title:"closed "+n,body:"b\n",state:"CLOSED",stateReason:"NOT_PLANNED",url:"https://github.com/"+R+"/issues/"+n,labels:["type:feature"],
      comments:[{id:"IC_"+n+"m",url:"https://github.com/x",createdAt:at,body:"Moved to https://plane.example.test/ws/browse/ENG-"+link+"/",author:"kadir"}],parent:null,items:[],timeline});
    s.issues[R].push(mk(21,77,[closed]),mk(22,78,[closed]),mk(23,80,[closed,T("REOPENED_EVENT","2026-10-05T09:00:00Z"),T("CLOSED_EVENT","2026-10-06T09:00:00Z")]),
      mk(24,82,[closed]),mk(25,81,[T("CLOSED_EVENT","2026-09-01T10:00:00Z"),T("REOPENED_EVENT","2026-09-02T10:00:00Z"),closed]))'
  planeset 'const item=(n,seq)=>({id:require("crypto").randomUUID(),project:p.id,name:"closed "+n,description_html:"",priority:"none",parent:null,labels:[],assignees:[],external_source:"github",
      external_id:"example-org/example-repo#"+n,archived_at:null,created_at:s.day,updated_at:s.day,sequence_id:seq,state:p.states[1].id});
    p.issues.push(item(21,77),item(22,79),item(23,80),item(25,81))'
}
earlier_carry() { pq 0 "console.log(C(N('example-org/example-repo#$1')).pop().comment_html)" | grep -q 'may be the close of an earlier carry'; }
legacy_check() {  # legacy_check <root> [number...]: 0 when the sentence stands for #21 and #25 and for none of #22, #23 and #24, among the numbers carried
  local root="$1" n state numbers
  shift; numbers="${*:-21 22 23 24 25}"
  reset_plane; legacy_world
  state="$(pq 0 'console.log(N("example-org/example-repo#21").state)')"
  for n in $numbers; do
    ROOT_UNDER_TEST="$root" carry "$n" --to plane || return 1
    case "$n" in
      21|25) earlier_carry "$n" || return 1 ;;   # the work item stood in Plane, the comment names it, the close came last
      *)     ! earlier_carry "$n" || return 1 ;;   # 22 names another work item; 23 was reopened after the comment and closed again; 24 had no work item before, and its comment names the address the new one gets
    esac
  done
  case " $numbers " in *" 21 "*)
    pq 0 "console.log(C(N('example-org/example-repo#21')).pop().comment_html)" | grep -qF 'the work item https://plane.example.test/ws/browse/ENG-77/ stood in Plane before this carry' || return 1
    [ "$(pq 0 'console.log(N("example-org/example-repo#21").state)')" = "$state" ] || return 1 ;;   # the state of a work item that stood in Plane is not touched
  esac
}
legacy_check "$ROOT" || fail "the earlier carry's close is not recognised exactly: $(for n in 21 22 23 24 25; do earlier_carry $n && echo -n "#$n yes " || echo -n "#$n no "; done) $(tail -2 "$WORK/err.txt")"
plant legacy_check lib/plane/tracker.sh 's/\[ "\$preexisting" = 1 \] && //' "a close assumed to be the earlier carry's where no work item stood in Plane" 24
plant legacy_check lib/plane/tracker.sh 's/ && \[ "\$moved_to" = "\$(plane_item_url "\$seq")" \]//' "a Moved to comment taken for the earlier carry's whatever work item it names" 22
plant legacy_check lib/carry-plan.jq 's/ and (\$t | all(.kind != "reopened" or .at < \$m.at))//' "a reopening after the comment ignored" 23
plant legacy_check lib/carry-plan.jq 's/\.kind != "reopened" or \.at < \$m\.at/.kind != "reopened"/' "a reopening before the comment taken for one after it" 25
echo "  the sentence stands for the work item that stood in Plane and is named by the comment, the close last (also after an older reopening); not for another work item, a reopening, or an item no earlier carry made; four plants red"

# a sub-issue whose parent stands in another destination: Plane has no parent across projects, so the provenance of the sub-issue
# names the parent and the Plane link of the parent, which the run made first. A parent that was not carried leaves the sub-issue
# waiting, with nothing written for it
section "a parent in another destination"
parent_check() {  # parent_check <root>: 0 when example-repo#7 names the Plane link of its parent tools#1 of the project OPS
  reset_plane; world pair
  ROOT_UNDER_TEST="$1" carry --to plane || return 1
  [ "$(pq 0 'console.log(N("example-org/example-repo#7").parent)')" = null ] || return 1
  local html
  html="$(pq 0 'console.log(C(N("example-org/example-repo#7")).pop().comment_html)')"
  grep -qF 'Parent: example-org/tools#1 (https://github.com/example-org/tools/issues/1), in another destination' <<< "$html" \
    && grep -qF "Plane parent link: https://plane.example.test/ws/browse/OPS-$(pq 1 'console.log(N("example-org/tools#1").sequence_id)')/" <<< "$html"
}
parent_check "$ROOT" || fail "the sub-issue example-repo#7 does not name the Plane link of its parent tools#1: $(cat "$WORK/err.txt"); $(pq 0 'console.log(C(N("example-org/example-repo#7")).pop().comment_html)')"
plant parent_check lib/plane/tracker.sh 's/Plane parent link: \$parent_link//' "a parent in another destination recorded without its Plane link"
plant parent_check lib/carry-plan.jq 's/(if \$parent == null then "" else "Parent: /(if true then "" else "Parent: /' "a parent in another destination dropped from the provenance"
reset_plane; world pair
printf '[{"match":"POST /api/v1/workspaces/ws/projects/%s/issues/","status":503,"times":1}]' "$(pq 1 'console.log(p.id)')" > "$CURL_FAKE_STATE/inject.json"
carry --to plane && fail "a parent that was not created left the carry complete"
grep -q 'INCOMPLETE example-org/example-repo#7: .*waits for the parent' "$WORK/err.txt" || fail "the sub-issue that waits for its parent is not named: $(cat "$WORK/err.txt")"
[ "$(pq 0 'console.log(p.issues.length+" "+p.comments.length)')" = "0 0" ] || fail "something was written for a sub-issue that waits for its parent: $(pq 0 'console.log(p.issues.length+" "+p.comments.length)')"
printf '[]' > "$CURL_FAKE_STATE/inject.json"
carry --to plane || fail "the rerun after the parent was refused: $(cat "$WORK/err.txt")"
pq 0 'console.log(C(N("example-org/example-repo#7")).pop().comment_html)' | grep -qF "Plane parent link: https://plane.example.test/ws/browse/OPS-$(pq 1 'console.log(N("example-org/tools#1").sequence_id)')/" || fail "after the rerun the sub-issue does not name its parent's Plane link"
echo "  example-repo#7 names the Plane link of its parent tools#1 in the other project; with the parent refused it waits and nothing is written for it, the rerun carries both; the parent or its link left out goes red"

# The assignee. The account that runs the carry, spelled as GitHub names it in any case, becomes the Plane key's user in the create request:
# Plane takes a user id, and the key's user is the one Plane user the carry can tell from a login. Another login is named in the report and
# written nowhere. An issue that names nobody asks neither gh who it is nor Plane who the key's user is, and a work item that stood in
# Plane before is not changed. The example-repo issues of the fixture: #1 names tester, #2 TESTER and anton, #3 anton alone, #5 nobody
section "the assignee of a carried issue"
assignee_check() {  # assignee_check <root>: 0 when #2 stands assigned to the key's user alone and issue-mine takes it up, #3 and #5 stand assigned to nobody, and the report of each says what it carries
  local seq
  reset_plane; world; reset_log
  ROOT_UNDER_TEST="$1" carry 2 --to plane || return 1
  [ "$(who 0 example-org/example-repo#2)" = "$me" ] || { echo "#2 stands assigned to $(who 0 example-org/example-repo#2)"; return 1; }
  grep -qF "\"assignees\":[\"$me\"]" "$CURL_FAKE_STATE/requests.log" || { echo "the create request of #2 names no assignee"; return 1; }
  [ "$(grep -cx 'api user' "$G/calls.log")" = 1 ] || { echo "gh was not asked once who it is"; return 1; }
  seq="$(pq 0 'console.log(N("example-org/example-repo#2").sequence_id)')"
  ROOT_UNDER_TEST="$1" ai issue-mine "$seq" > "$WORK/mine.txt" 2>&1 || { echo "issue-mine refuses #2 as ENG-$seq: $(cat "$WORK/mine.txt")"; return 1; }
  grep -qF "assignees to carry: 1 of 1 issues, as the Plane key's user (the GitHub login tester" "$WORK/out.txt" \
    && grep -qF 'assignees not carried: 1 (a Plane member is never guessed from a GitHub login): anton on example-org/example-repo#2' "$WORK/out.txt" \
    || { echo "the report of #2: $(grep '^assignees' "$WORK/out.txt")"; return 1; }
  ROOT_UNDER_TEST="$1" carry 3 --to plane || return 1
  [ "$(who 0 example-org/example-repo#3)" = nobody ] || { echo "#3, which names anton alone, stands assigned to $(who 0 example-org/example-repo#3)"; return 1; }
  grep -qF 'assignees to carry: 0 of 1 issues' "$WORK/out.txt" && grep -qF 'anton on example-org/example-repo#3' "$WORK/out.txt" \
    || { echo "the report of #3: $(grep '^assignees' "$WORK/out.txt")"; return 1; }
  : > "$G/calls.log"; reset_log
  ROOT_UNDER_TEST="$1" carry 5 --to plane || return 1
  [ "$(who 0 example-org/example-repo#5)" = nobody ] || { echo "#5, which names nobody, stands assigned to $(who 0 example-org/example-repo#5)"; return 1; }
  ! grep -qx 'api user' "$G/calls.log" && ! grep -q '/users/me/' "$CURL_FAKE_STATE/requests.log" || { echo "an issue that names nobody asked who the account is"; return 1; }
  grep -qF 'assignees to carry: 0 of 1 issues' "$WORK/out.txt" && grep -qx 'assignees not carried: 0' "$WORK/out.txt" || { echo "the report of #5: $(grep '^assignees' "$WORK/out.txt")"; return 1; }
  seq="$(pq 0 'console.log(N("example-org/example-repo#5").sequence_id)')"
  ! ROOT_UNDER_TEST="$1" ai issue-mine "$seq" > "$WORK/mine.txt" 2>&1 && grep -q "REFUSED: #$seq is assigned to nobody" "$WORK/mine.txt" || { echo "issue-mine takes up #5 as ENG-$seq: $(cat "$WORK/mine.txt")"; return 1; }
}
assignee_check "$ROOT" || fail "the assignee is not carried as the key's user alone: $(cat "$WORK/err.txt")"
plant assignee_check lib/plane/tracker.sh 's/ + (if \$assignee != "" then {assignees: \[\$assignee\]} else {} end)//' "an assignee left out of the create request"
plant assignee_check lib/carry-plan.jq 's/def assigned_to_key_user: .assignees | any(lc == (\$login | lc));/def assigned_to_key_user: .assignees | length > 0;/' "another login written as the key's user"
plant assignee_check lib/carry.sh 's/\\(if (\$r.assignees_not_carried | length) == 0 then/\\(if true then/' "a report that names no login it cannot carry"
plant assignee_check lib/github/tracker.sh 's/^  assignees(first:10){ nodes{ login } }$//' "a GitHub query that does not ask for the assignees"
echo "  #2 (tester as TESTER, and anton) stands assigned to the key's user in the create request, anton is named with the issue in the report and written nowhere, #3 (anton alone) and #5 (nobody) stand assigned to nobody and #5 asks neither gh nor Plane who the account is; issue-mine takes up #2 and refuses #5 as assigned to nobody; four plants red: the assignee left out of the request, anton taken for the key's user, a report without the login, a query that does not ask for the assignees"

carried_before_check() {  # carried_before_check <root>: 0 when a work item carried before its issue named the account stays without it, and the rerun writes nothing
  reset_plane; world
  gh_set 's.issues["example-org/example-repo"][0].assignees=[]'
  ROOT_UNDER_TEST="$1" carry 1 --to plane || return 1
  [ "$(who 0 example-org/example-repo#1)" = nobody ] || return 1
  world; reset_log
  ROOT_UNDER_TEST="$1" carry 1 --to plane || return 1
  [ "$(writes)" = 0 ] && [ "$(who 0 example-org/example-repo#1)" = nobody ]
}
carried_before_check "$ROOT" || fail "a work item carried before was given the assignee its issue names now: $(who 0 example-org/example-repo#1); $(cat "$WORK/err.txt")"
plant carried_before_check lib/plane/tracker.sh '/^  carry_remember "\$ref" "\$found"$/a\  plane_call PATCH "$(plane_path "projects/$project/issues/$id/")" "{}"' "a work item that stood in Plane patched"
echo "  #1 carried before its issue named the account stays without it, and the rerun writes nothing; a rerun that patches the found work item is red"

dropped_check() {  # dropped_check <root>: 0 when a Plane that keeps no assignee although the create names one leaves the issue incomplete, named
  reset_plane; world; reset_log
  CURL_FAKE_DROP_ASSIGNEE=1 ROOT_UNDER_TEST="$1" carry 1 --to plane && return 1
  grep -q 'INCOMPLETE example-org/example-repo#1: .*another state, parent, archive date or assignee' "$WORK/err.txt"
}
dropped_check "$ROOT" || fail "a Plane that kept no assignee was not read back as incomplete: $(cat "$WORK/err.txt")"
plant dropped_check lib/plane/tracker.sh 's/ and (\$u == "" or ((.assignees \/\/ \[\]) | index(\$u) != null))//' "a read-back that does not look at the assignee"
member_check() {  # member_check <root>: 0 when a key's user who is no active member of the project, or a guest in it, stops the carry before the first write, named
  local rc=0 how
  for how in 'is_active=false' 'role=5'; do
    reset_plane; world; reset_log
    planeset "p.members.find((m)=>m.user===s.users[0].id).$how"
    rc=0; ROOT_UNDER_TEST="$1" carry 1 --to plane || rc=$?
    planeset 'const m=p.members.find((m)=>m.user===s.users[0].id);m.is_active=true;delete m.role'
    [ "$rc" != 0 ] && grep -q 'is not an active member of the project ENG with a role of 15 or more' "$WORK/err.txt" && [ "$(writes)" = 0 ] || return 1
  done
}
member_check "$ROOT" || fail "a key's user who is no active member of the project did not stop the carry before the first write: $(cat "$WORK/err.txt")"
plant member_check lib/plane/tracker.sh 's/|| die "\$3 is not an active member/|| : "/' "a key's user who is no member of the project let through"
plant member_check lib/plane/tracker.sh 's/ and \.role >= 15)/)/' "a key's user who is a guest of the project let through"
echo "  a Plane that keeps no assignee although the create names one leaves the issue incomplete, named; a key's user who is no active member of the project, or a guest in it, stops the carry before the first write; each check left out is red"

# answers larger than one command-line argument, which Linux caps at 128 KiB: a board of 1,508 cards, 200 comments of 1,500 characters,
# and one comment of 27,000 ampersands whose escaped text is 135,000 characters. They cross as files or standard input, never as an argument
section "answers larger than one command-line argument"
bulk_source() {  # bulk_source <root> <function> [argument...]: a reader of the GitHub provider of that root, in a process of its own as the carry runs it
  local root="$1"; shift
  ( cd "$P" && PATH="$PATH_CURL" TRACKER=github bash -c '. "$1/lib/board.sh"; shift; "$@"' _ "$root" "$@" )
}
bulk_check() {  # bulk_check <root>: 0 when that root reads the cards of the first board and the comments of #13 and #14 whole
  world bulk
  bulk_source "$1" github_carry_boards example-org > "$WORK/bulk-boards.jsonl" 2> "$WORK/bulk-err.txt" || return 1
  bulk_source "$1" github_carry_issues example-org/example-repo > "$WORK/bulk-issues.jsonl" 2>> "$WORK/bulk-err.txt" || return 1
  node -e "const s=JSON.parse(require('fs').readFileSync('$G/github.json')),out=[];
    for (const m of s.boards[0].items) out.push('card '+m.id+' '+m.issue.id+' '+m.issue.repository+'#'+m.issue.number+' '+m.isArchived+' '+m.status);
    for (const i of s.issues['example-org/example-repo'].filter((x) => x.number>=13)) for (const c of i.comments) out.push('comment '+i.number+' '+c.id+' '+c.createdAt+' '+c.body);
    console.log(out.join('\n'))" > "$WORK/bulk-want.txt"
  { jq -r 'select(.kind == "board" and .number == 1) | .items[] | "card \(.item) \(.issue) \(.repo)#\(.number) \(.archived) \(.status)"' "$WORK/bulk-boards.jsonl"
    jq -r 'select(.kind == "issue" and .number >= 13) | .number as $n | .comments[] | "comment \($n) \(.id) \(.createdAt) \(.body)"' "$WORK/bulk-issues.jsonl"; } > "$WORK/bulk-got.txt"
  cmp -s "$WORK/bulk-want.txt" "$WORK/bulk-got.txt"
}
bulk_plane_check() {  # bulk_plane_check <root>: 0 when that root carries the comment of #14, 135,000 characters once escaped, as it was written
  reset_plane; world bulk
  ROOT_UNDER_TEST="$1" carry 14 --to plane || return 1
  [ "$(pq 0 'const c=C(N("example-org/example-repo#14"));console.log(c.length+" "+(c[0].comment_html.length > 131072)+" "+c[0].comment_html.endsWith("&amp;".repeat(27000)+"</pre>"))')" = "2 true true" ]
}
bulk_check "$ROOT" || fail "the cards of a board of 1,508, or the 200 comments of 1,500 characters, were not read whole: $(tail -3 "$WORK/bulk-err.txt")"
read -r cardbytes commentbytes <<< "$(node -e "const s=JSON.parse(require('fs').readFileSync('$G/github.json'));console.log(JSON.stringify(s.boards[0].items.slice(100)).length+' '+JSON.stringify(s.issues['example-org/example-repo'].find((i)=>i.number===13).comments.slice(100)).length)")"
[ "$cardbytes" -gt 131072 ] && [ "$commentbytes" -gt 131072 ] || fail "the bulk world is not larger than 128 KiB in each overflow: the cards after the first page are $cardbytes bytes, the comments after the first page $commentbytes"
bulk_plane_check "$ROOT" || fail "the comment of 27,000 ampersands was not carried as written: $(tail -3 "$WORK/err.txt"); $(pq 0 'const c=C(N("example-org/example-repo#14"));console.log(c.length+" "+(c[0]||{comment_html:""}).comment_html.length)')"
fake_flush_check() {  # fake_flush_check <gh stand-in>: 0 when a reader that starts late gets the whole answer for #13, 100 comments of 1,500 characters
  GH_CARRY_STATE="$G" node "$1" api graphql -f o=example-org -f n=example-repo -F i=13 -f query='query($o:String!,$n:String!,$i:Int!){ repository(owner:$o,name:$n){ issue(number:$i){ id } } }' \
    | { sleep 1; jq -e '.data.repository.issue.comments.nodes | length == 100' > /dev/null; }
}
fake_flush_check "$ROOT/tests/gh-carry-fake.mjs" || fail "the gh stand-in does not write its whole answer to a reader that starts late"
sed 's/^process.exitCode = answer.code;.*/process.exit(answer.code);/' "$ROOT/tests/gh-carry-fake.mjs" > "$WORK/gh-carry-fake-cut.mjs"
cmp -s "$ROOT/tests/gh-carry-fake.mjs" "$WORK/gh-carry-fake-cut.mjs" && fail "the planted stand-in equals the real one"
! fake_flush_check "$WORK/gh-carry-fake-cut.mjs" || fail "planted: a stand-in that ends the process right after writing passes the check, so it cannot go red"
carry_append_by_argument='carry_append() { jq -c --arg k "$2" --argjson e "$(printf "%s\n" "$3" | jq -sc .)" ".[\$k] += \$e" <<< "$1"; }'
plant_line bulk_check lib/github/tracker.sh 'carry_append()' "$carry_append_by_argument" "an overflow page handed to jq as an argument"
carry_comment_request_by_argument='carry_comment_request() { local c; c="$(cat)"; jq -nc --arg h "$(jq -r .text <<< "$c" | jq -Rrs "$PLANE_HTML html")" --argjson c "$c" "{comment_html: \$h, external_source: \"github\", external_id: \$c.external_id, created_at: \$c.created_at}"; }'
plant_line bulk_plane_check lib/plane/tracker.sh 'carry_comment_request()' "$carry_comment_request_by_argument" "a comment handed to jq as an argument"
echo "  1,508 cards and 200 comments of 1,500 characters read whole, a comment of 135,000 characters once escaped carried as written; an argument in place of a file or standard input goes red; the gh stand-in writes its whole answer, and one that exits right after writing is cut at 64 KiB"

# A REPOSITORY WITH NO ISSUE HAS NOTHING TO CARRY, so it needs no destination and stops nothing; one with issues and none
# still stops the run before the first write. The world gets two such repositories, one with issues disabled and one that
# simply holds none, and a clone of neither.
no_issue_world() {
  reset_plane; world; reset_log
  gh_set 's.repositories.push({nameWithOwner:"example-org/off",isArchived:false,hasIssuesEnabled:false},{nameWithOwner:"example-org/empty",isArchived:false})'
}
carries_past_no_issues() {  # carries_past_no_issues <root>: 0 where the project is carried whole, and the report names the two
  no_issue_world
  ROOT_UNDER_TEST="$1" carry --to plane || return 1
  grep -q '^repositories with no issue, which need no destination: example-org/off, example-org/empty$' "$WORK/out.txt" \
    && grep -q '^carried 14 of 14 issues' "$WORK/out.txt" && [ "$(writes)" != 0 ]
}
refuses_a_repository_with_issues() {  # refuses_a_repository_with_issues <root>: 0 where a repository with issues and no clone refuses the run before any write
  no_issue_world; mkdir -p "$WORK/off"; mv "$WORK/tools" "$WORK/off/tools"
  local rc=0
  ROOT_UNDER_TEST="$1" carry --to plane || rc=$?
  mv "$WORK/off/tools" "$WORK/tools"
  [ "$rc" != 0 ] && grep -q 'no clone of example-org/tools' "$WORK/err.txt" && [ "$(writes)" = 0 ]
}
carries_past_no_issues "$ROOT" || fail "the project was not carried past a repository with issues disabled and one with none: $(cat "$WORK/out.txt" "$WORK/err.txt")"
refuses_a_repository_with_issues "$ROOT" || fail "a repository with issues and no clone did not refuse the run before any write: $(cat "$WORK/err.txt")"
! grep -q 'example-org/off\|example-org/empty' "$WORK/err.txt" || fail "the refusal names a repository with no issue: $(cat "$WORK/err.txt")"
plant carries_past_no_issues lib/carry.sh 's/<<< "\$line")" = 0 \]; then no_issues/<<< "$line")" = -1 ]; then no_issues/' 'every repository asked for a destination, the loop as it was'
plant carries_past_no_issues lib/github/tracker.sh 's/ hasIssuesEnabled issues{ totalCount }//' 'the repository listing without the count of issues'
plant_copy; sed -i.bak 's/<<< "\$line")" = 0 \]; then no_issues/<<< "$line")" = -1 ]; then no_issues/' "$planted/lib/carry.sh"
refuses_a_repository_with_issues "$planted" || fail "the innocent case, a repository with issues and no clone, is not refused on the copy with the old loop"
echo "  a repository with issues disabled and one with none are named and need no destination, a repository with issues and no clone still refuses the run before any write; the old loop and a listing without the count each turn the first red, and the second stays green"

# the project counted on 2026-10-20: 4,100 issues, 624 archived cards, 18 open ones on no board, three boards' worth of cards, several
# threads over 100 comments. The run is stopped at its first write, because the stand-in curl costs a process and a rewrite of the
# whole state per request: what is proven here is the source read whole and the report whole before that write
reset_plane; world scale; gh_set 's.page.issues=50'; reset_log; rm -f "$CURL_FAKE_STATE/stdout-at-write.log"; : > "$WORK/out.txt"
set -m; ( CURL_FAKE_STDOUT="$WORK/out.txt" ai issue-transfer --to plane > "$WORK/out.txt" 2> "$WORK/err.txt" ) & pid=$!
waited=0; until [ -s "$CURL_FAKE_STATE/stdout-at-write.log" ] || ! kill -0 "$pid" 2>/dev/null; do sleep 1; waited=$((waited + 1)); [ "$waited" -lt 1500 ] || break; done
kill -- "-$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; set +m
[ -s "$CURL_FAKE_STATE/stdout-at-write.log" ] || fail "the run of 4,100 issues came to no write: $(tail -3 "$WORK/err.txt")"
known="$(node -e "const s=JSON.parse(require('fs').readFileSync('$G/github.json'));const all=Object.entries(s.issues).filter(([r])=>!r.endsWith('/old')).flatMap(([,v])=>v);
  console.log([all.length,all.reduce((a,i)=>a+i.items.filter((m)=>m.isArchived).length,0),all.filter((i)=>!i.items.length).length,all.filter((i)=>!i.items.length&&i.state==='OPEN').length,
  all.reduce((a,i)=>a+i.comments.length,0),all.reduce((a,i)=>a+Math.ceil((i.comments.length+1)/100),0),all.filter((i)=>i.comments.length>100).length,s.boards.reduce((a,b)=>a+b.items.length,0),s.boards[0].items.length].join(' '))")"
read -r n a boardless open c pages over cards firstboard <<< "$known"
[ "$n $a $open" = "4100 624 18" ] && [ "$over" -ge 5 ] && [ "$firstboard" -gt 800 ] || fail "the fixture is not the project counted, or its first board is not over 800 cards: $known"
for want in "$n issues of 3 repositories" "$c original and $n provenance, $((c + n)) in all, in $pages pages" "($a archived, on " "$boardless of $n issues on no board" "$cards cards in all" "11 board records to create" "destinations: 3"; do
  grep -qF -- "$want" "$WORK/out.txt" || fail "the report of 4,100 issues lacks '$want': $(head -c 1500 "$WORK/out.txt")"
done
line="$(grep 'Plane requests, at most' "$WORK/out.txt")"; r="$(sed -n 's/.*at most: \([0-9]*\) =.*/\1/p' <<< "$line")"
m="$(sed -n 's/.* + \([0-9]*\) metadata pages.*/\1/p' <<< "$line")"; l="$(sed -n 's/.* + \([0-9]*\) new labels.*/\1/p' <<< "$line")"; u="$(sed -n 's/.* + \([0-9]*\) outside parents.*/\1/p' <<< "$line")"
k="$(sed -n 's/.* + \([0-9]*\) reads of the Plane key.*/\1/p' <<< "$line")"
# B is 11: the first board reaches all three destinations (3), the second and third one each (1 and 1), the empty and the closed one every destination of the selection (3 and 3)
[ "$r" = "$((3 * (n + 11) + c + n + 2 * pages + m + l + u + k))" ] || fail "the bound $r of 4,100 issues is not 3 x (N + B) + C + 2P + M + L + U + K = $((3 * (n + 11) + c + n + 2 * pages + m + l + u + k))"
grep -qF "that is $(( (r + 59) / 60 )) minutes" <<< "$line" || fail "the minutes of $r requests are not $(( (r + 59) / 60 )): $line"
[ "$(awk '{print $3}' "$CURL_FAKE_STATE/stdout-at-write.log" | head -n1)" -ge "$(grep -b 'Plane requests, at most' "$WORK/out.txt" | head -n1 | cut -d: -f1)" ] || fail "a write came before the report of 4,100 issues was printed"
[ "$(github_writes)" = 0 ] || fail "reading 4,100 issues wrote to GitHub"
echo "  4,100 issues, 624 archived cards, 18 open ones on no board, $over threads over 100 comments, $firstboard cards on the first board: the source read whole, and the report with $r requests ($(( (r + 59) / 60 )) minutes) printed before the first write"
echo "all passed"
