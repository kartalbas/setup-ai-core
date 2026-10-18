#!/usr/bin/env bash
# issue-transfer --to plane: a GitHub issue, or every open issue of a board column, carried into the Plane
# project. GitHub is a stand-in gh that keeps issues, cards and comments in files of $G, Plane is the stand-in
# curl of tests/lib.sh; nothing here reaches a network. Each defect the carry must refuse is planted and
# shown red, the innocent case beside it green.
#
#   bash tests/issue-transfer-plane.test.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export GH_ORG=example-org GH_PROJECT_NUMBER=1
make_plane_project
G="$WORK/gh-state"; mkdir -p "$G" "$WORK/ghbin" "$GH_CACHE_DIRECTORY/1"
printf 'PVT_kwcarry1\n' > "$GH_CACHE_DIRECTORY/1/project-id"

cat > "$WORK/ghbin/gh" <<'FAKE'
#!/usr/bin/env bash
# the gh calls of github_carry_rows, check_public_body, issue_comment_post and issue_close, answered from $G
line="$*"; jq_expr=""; n=""; text=""
prev=""; for a in "$@"; do
  [ "$prev" != --jq ] || jq_expr="$a"
  case "$a" in n=*) n="${a#n=}" ;; body=*) text="${a#body=}" ;; esac
  prev="$a"
done
out() { if [ -n "$jq_expr" ]; then jq -r "$jq_expr"; else cat; fi; }
printf '%s\n' "$line" >> "$G/calls.log"
case "$line" in
  "repo view"*) echo "{\"isPrivate\":false}" ;;
  *"items(first:100"*) out < "$G/cards.json" ;;
  *"issue(number:\$n)"*) out < "$G/parent-$n.json" ;;
  "api --paginate repos/example-org/example-repo/issues/"*"/comments")
    id="${line#*issues/}"; id="${id%%/*}"; cat "$G/comments-$id.json" 2>/dev/null || echo '[]' ;;
  "api repos/example-org/example-repo/issues/"*"/comments "*)
    id="${line#*issues/}"; id="${id%%/*}"
    echo "$text" >> "$G/comments.log"
    jq -n --arg b "$text" '{user:{login:"bot"},created_at:"2026-10-19T00:00:00Z",body:$b}' > "$G/one"
    jq -s '.' "$G/comments-$id.json" "$G/one" 2>/dev/null > "$G/tmp" || jq -s '.' "$G/one" > "$G/tmp"
    jq 'flatten' "$G/tmp" > "$G/comments-$id.json"
    echo '{"html_url":"https://github.com/example-org/example-repo/issues/1#c"}' | out ;;
  "api --method PATCH repos/example-org/example-repo/issues/"*)
    [ ! -f "$G/fail-close" ] || { echo 'gh: HTTP 502' >&2; exit 1; }
    id="${line#*issues/}"; id="${id%% *}"
    echo "$line" >> "$G/closes.log"; jq '.state = "closed"' "$G/issue-$id.json" > "$G/tmp" && mv "$G/tmp" "$G/issue-$id.json" ;;
  "api repos/example-org/example-repo/issues/"*) cat "$G/issue-${line##*/}.json" ;;
  *) echo "unexpected gh call: $line" >&2; exit 1 ;;
esac
FAKE
chmod +x "$WORK/ghbin/gh"; export G
PATH_CURL="$WORK/ghbin:$PATH_CURL"

# a literal &lt; and a trailing newline: an escaping that is missing, or a newline added, shows in the stored html
BODY=$'Fix the carry at lib/plane/tracker.sh:312\n\n```bash\nif [ "$a" -lt 2 ] && x=\'<y>\'; then echo "&lt; & >"; fi\n```\n\nlast line\n'
gh_issue() {  # gh_issue <number> <title> <body> <label>... : an open issue in the stand-in
  local n="$1" t="$2" b="$3"; shift 3
  jq -n --argjson n "$n" --arg t "$t" --arg b "$b" --args '{number:$n,title:$t,state:"open",body:$b,labels:[$ARGS.positional[]|{name:.}]}' "$@" > "$G/issue-$n.json"
  gh_parent_none "$n"
}
gh_parent() { printf '{"data":{"repository":{"issue":{"parent":{"number":%s,"repository":{"nameWithOwner":"example-org/example-repo"}}}}}}\n' "$2" > "$G/parent-$1.json"; }
gh_parent_none() { echo '{"data":{"repository":{"issue":{"parent":null}}}}' > "$G/parent-$1.json"; }
card() {  # card <number> <status> <priority>
  jq -nc --argjson n "$1" --arg s "$2" --arg p "$3" '{id:"PVTI_\($n)",content:{number:$n,repository:{nameWithOwner:"example-org/example-repo"}},fieldValues:{nodes:[{name:$s,field:{name:"Status"}},{name:$p,field:{name:"Priority"}}]}}'
}
cards() {  # cards <"number status priority">... : the board, in this order
  local c rows=""
  for c in "$@"; do rows="$rows$(card $c)"$'\n'; done
  { echo '{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":['; printf '%s' "$rows" | paste -sd, -; echo ']}}}}'; } > "$G/cards.json"
}
reset_gh() { : > "$G/calls.log"; : > "$G/comments.log"; : > "$G/closes.log"; }
writes() { grep -c '^\(POST\|PATCH\|PUT\|DELETE\) ' "$CURL_FAKE_STATE/requests.log" || true; }
stored() { planeq "console.log(JSON.stringify(p.issues.find((i)=>i.sequence_id===$1)))"; }
reset_gh

# #8 is the sub-issue of #7 and its card comes first; #10 stands in backlog, its sub-issue #11 in ready
gh_issue 7 "Carry the thing, or R4 has no tool" "$BODY" type:feature area:gate
gh_issue 8 "Carry the child" "child body" type:feature; gh_parent 8 7
gh_issue 10 "A parent nobody carried" "p" type:feature
gh_issue 11 "A child of the uncarried" "c" type:feature; gh_parent 11 10
gh_issue 12 "Sits in backlog" "b" type:feature
cards "8 ready P2" "7 ready P1" "10 backlog P3" "11 ready P2" "12 backlog P0"

section "issue-transfer --to plane: a GitHub issue carried into Plane"

# a sub-issue whose parent is not carried yet is refused by name, and nothing is written
reset_log
out="$(ai issue-transfer 11 --to plane 2>&1)" && fail "a sub-issue of an uncarried parent was carried: $out"
grep -q 'example-org/example-repo#10, which is not carried into Plane yet' <<< "$out" || fail "the uncarried parent is not named: $out"
[ "$(writes)" = 0 ] || fail "a refused carry wrote to Plane"
[ ! -s "$G/closes.log" ] || fail "a refused carry closed the GitHub issue"
echo "  a sub-issue whose parent is not carried is refused, naming example-org/example-repo#10, and nothing is written"

# one issue: the label the project lacks is made first, the body arrives as the exact html
[ "$(planeq 'console.log(p.labels.some((l)=>l.name==="area:gate"))')" = false ] || fail "the project already has area:gate"
out="$(ai issue-transfer 7 --to plane 2>"$WORK/err")" || fail "issue-transfer 7 --to plane: $out"
[ "$out" = "#7 -> ENG-1" ] || fail "the line printed is '$out', not '#7 -> ENG-1'"
[ "$(planeq 'const l=p.labels.find((l)=>l.name==="area:gate");console.log(l&&l.color)')" = "#1D76DB" ] || fail "area:gate was not made with the colour of labels.tsv"
[ "$(planeq 'const i=p.issues[0];console.log(i.name+"|"+i.priority+"|"+p.states.find((s)=>s.id===i.state).name+"|"+i.external_source+"|"+i.external_id+"|"+i.labels.map((id)=>p.labels.find((l)=>l.id===id).name).sort().join(","))')" \
  = "Carry the thing, or R4 has no tool|high|ready|github|example-org/example-repo#7|area:gate,repo:example-repo,type:feature" ] || fail "the work item is not as carried: $(stored 1)"
# the html itself: one <pre>, & < > escaped once, the literal &lt; of the body escaped again, the trailing newline kept
printf '<pre>Fix the carry at lib/plane/tracker.sh:312\n\n```bash\nif [ "$a" -lt 2 ] &amp;&amp; x=\x27&lt;y&gt;\x27; then echo "&amp;lt; &amp; &gt;"; fi\n```\n\nlast line\n</pre>' > "$WORK/want-html"
stored 1 | jq -j '.description_html' > "$WORK/got-html"
cmp -s "$WORK/want-html" "$WORK/got-html" || fail "the stored description_html is not the escaped body in one <pre>: $(cat "$WORK/got-html")"
ai issue-thread 1 --json | jq -j .body > "$WORK/got-body"; printf '%s' "$BODY" > "$WORK/want-body"
cmp -s "$WORK/want-body" "$WORK/got-body" || fail "the body did not read back unchanged: $(cat "$WORK/got-body")"
echo "  #7 -> ENG-1: title, priority P1 as high, state ready, external_id, labels with area:gate made first; description_html is the exact escaped body in one <pre>"

# the work item is found by the external_id query, not by reading the whole project
reset_log
ai issue-transfer 7 --to plane >/dev/null 2>&1
grep -q 'external_id=example-org%2Fexample-repo%237' "$CURL_FAKE_STATE/requests.log" || fail "the lookup did not ask for the external_id: $(cat "$CURL_FAKE_STATE/requests.log")"
! grep -q 'issues/?expand' "$CURL_FAKE_STATE/requests.log" || fail "the lookup read the whole project"
echo "  the work item is found by GET issues/?external_id=&external_source=github, not by a scan of the project"

# GitHub: one comment with the link, closed as not planned
grep -q 'https://plane.example.test/ws/browse/ENG-1/' "$G/comments.log" || fail "the comment lacks the Plane link: $(cat "$G/comments.log")"
grep -q 'state_reason=not_planned' "$G/closes.log" || fail "the GitHub issue was not closed as not planned: $(cat "$G/closes.log")"
echo "  the GitHub issue got one comment with https://plane.example.test/ws/browse/ENG-1/ and was closed as not planned"

# a second run finds it by external_id and writes nothing, to Plane or to GitHub
reset_log; reset_gh
out="$(ai issue-transfer 7 --to plane 2>"$WORK/err")" || fail "the second run: $out"
[ "$out" = "#7 -> ENG-1" ] || fail "the second run printed '$out'"
[ "$(writes)" = 0 ] || fail "the second run wrote to Plane: $(grep '^\(POST\|PATCH\) ' "$CURL_FAKE_STATE/requests.log")"
[ ! -s "$G/comments.log" ] && [ ! -s "$G/closes.log" ] || fail "the second run wrote to GitHub"
[ "$(planeq 'console.log(p.issues.length)')" = 1 ] || fail "the second run made a second work item"
echo "  a second run prints the same line and writes nothing"

# a column: #7 is closed by now and left alone; #8 is carried with its parent; #11 is refused by name and the
# run ends non-zero with #8 done
reset_gh
out="$(ai issue-transfer --column ready --to plane 2>&1)" && fail "column ready carried #11 whose parent is not carried: $out"
grep -q '^#8 -> ENG-2$' <<< "$out" || fail "column ready did not carry #8: $out"
grep -q 'example-org/example-repo#10, which is not carried' <<< "$out" || fail "column ready: the refusal does not name #10: $out"
[ "$(planeq 'const c=p.issues.find((i)=>i.sequence_id===2);console.log(p.issues.find((i)=>i.id===c.parent).sequence_id)')" = 1 ] || fail "#8 is not a sub-issue of ENG-1"
gh_parent_none 11
reset_gh
out="$(ai issue-transfer --column ready --to plane 2>"$WORK/err")" || fail "issue-transfer --column ready --to plane: $out"
[ "$out" = "#11 -> ENG-3" ] || fail "the column printed: $out"
[ "$(grep -c . "$G/closes.log")" = 1 ] || fail "the second column run closed $(grep -c . "$G/closes.log") issues, not the 1 still open: $(cat "$G/closes.log")"
! grep -q 'issues/12' "$G/closes.log" || fail "the backlog issue #12 was carried"
echo "  --column ready: #8 carried under ENG-1, #11 refused while its parent #10 is not carried, then carried; #12 in backlog left alone"

# the column once every issue of it is carried: nothing is left, nothing is written, exit 0
reset_log; reset_gh
out="$(ai issue-transfer --column ready --to plane 2>&1)" || fail "a fully carried column was refused: $out"
grep -q 'nothing is left to carry' <<< "$out" || fail "a fully carried column does not say so: $out"
[ "$(writes)" = 0 ] || fail "a fully carried column wrote to Plane: $(grep '^\(POST\|PATCH\) ' "$CURL_FAKE_STATE/requests.log")"
echo "  a column that is carried already: 'nothing is left to carry', exit 0, no POST"

# a close that fails after its comment: the rerun finishes the close and posts no second comment
gh_issue 30 "Close fails once" "x" type:feature; cards "30 review P2"
touch "$G/fail-close"; reset_gh
out="$(ai issue-transfer 30 --to plane 2>&1)" && fail "a failed close was reported as success: $out"
[ "$(grep -c . "$G/comments.log")" = 1 ] && [ ! -s "$G/closes.log" ] || fail "the failed close left comments=$(grep -c . "$G/comments.log") closes=$(grep -c . "$G/closes.log")"
rm "$G/fail-close"
out="$(ai issue-transfer 30 --to plane 2>&1)" || fail "the rerun after a failed close: $out"
[ "$(grep -c . "$G/comments.log")" = 1 ] || fail "the rerun posted a second 'Moved to' comment: $(cat "$G/comments.log")"
[ "$(grep -c . "$G/closes.log")" = 1 ] || fail "the rerun did not close the issue"
echo "  a failed close leaves one comment; the rerun posts no second one and closes"

# three levels in reverse card order are carried parents first; a child whose parent is outside the selection
# is refused by name, the rest goes on, and the run ends non-zero
gh_issue 20 "Root" "r" type:feature; gh_issue 21 "Middle" "m" type:feature; gh_parent 21 20
gh_issue 22 "Leaf" "l" type:feature; gh_parent 22 21; gh_issue 23 "Orphan" "o" type:feature; gh_parent 23 10
cards "23 planned P2" "22 planned P2" "21 planned P2" "20 planned P2"
reset_gh
out="$(ai issue-transfer --column planned --to plane 2>&1)" && fail "the orphan was carried: $out"
[ "$(grep '^#' <<< "$out" | cut -d' ' -f1 | paste -sd' ' -)" = "#20 #21 #22" ] || fail "three levels were not carried parents first: $out"
grep -q 'example-org/example-repo#10, which is not carried' <<< "$out" || fail "the orphan's parent is not named: $out"
[ "$(planeq 'const o=(n)=>p.issues.find((i)=>i.external_id==="example-org/example-repo#"+n);console.log(p.issues.find((i)=>i.id===o(22).parent).external_id+" "+p.issues.find((i)=>i.id===o(21).parent).external_id+" "+!!o(23))')" \
  = "example-org/example-repo#21 example-org/example-repo#20 false" ] || fail "the three levels are not chained"
echo "  three levels in reverse card order: #20, #21, #22 carried in that order and chained; the orphan #23 refused by name, exit non-zero"

# refused before any write: a priority Plane has no value for, an email address, a parent of another repository
gh_issue 40 "Parked" "x" type:feature
gh_issue 41 "Has an address" "write to someone@company.ch" type:feature
gh_issue 42 "Foreign parent" "x" type:feature
printf '{"data":{"repository":{"issue":{"parent":{"number":3,"repository":{"nameWithOwner":"example-org/other-repo"}}}}}}\n' > "$G/parent-42.json"; cards "40 ready P9" "41 ready P2" "42 ready P2"
reset_log
out="$(ai issue-transfer 40 --to plane 2>&1)" && fail "priority P9 was carried: $out"
grep -q "priority 'P9'" <<< "$out" || fail "P9 is not named: $out"
out="$(ai issue-transfer 41 --to plane 2>&1)" && fail "a body with an email address was carried: $out"
grep -q 'refused email address someone@company.ch' <<< "$out" || fail "the address is not named: $out"
out="$(ai issue-transfer 42 --to plane 2>&1)" && fail "a parent of another repository was carried: $out"
grep -q 'example-org/other-repo#3, a parent of another repository' <<< "$out" || fail "the foreign parent is not named: $out"
[ "$(writes)" = 0 ] || fail "a refused carry wrote to Plane: $(grep '^\(POST\|PATCH\) ' "$CURL_FAKE_STATE/requests.log")"
echo "  P9, an email address in the body and a parent of another repository are each refused by name before any write"

# no answer to the create: it is not known whether the work item exists
gh_issue 50 "Times out" "x" type:feature; cards "50 ready P2"
printf '[{"match":"POST /api/v1/workspaces/ws/projects/","status":0,"times":1}]' > "$CURL_FAKE_STATE/inject.json"
out="$(ai issue-transfer 50 --to plane 2>&1)" && fail "a create without an answer was reported as success: $out"
grep -q 'cannot tell whether the work item carried from example-org/example-repo#50 was created' <<< "$out" || fail "a timeout is not named: $out"
! grep -q 'NOT created' <<< "$out" || fail "a timeout says NOT created: $out"
echo "  a create that gets no answer says it is not known whether the work item exists"

# the old form behaves as before: Plane cannot move between repositories, and says so
reset_log
out="$(ai issue-transfer 7 example-org/other-repo 2>&1)" && fail "the old form was accepted on Plane"
grep -q 'issue-transfer is not served on Plane' <<< "$out" || fail "the old form on Plane: $out"
out="$(ai issue-transfer --project 6 7 example-org/other-repo 2>&1)" && fail "--project was accepted"
grep -q "unknown argument '--project'" <<< "$out" || fail "an unknown flag is not named: $out"
out="$(ai issue-transfer 7 --to forgejo 2>&1)" && fail "--to forgejo was accepted"
out="$(ai issue-transfer --column ready 2>&1)" && fail "--column without --to was accepted"
echo "  issue-transfer N OWNER/REPO is refused on Plane as before; an unknown flag, --to forgejo and --column alone are refused"
echo "all passed"
