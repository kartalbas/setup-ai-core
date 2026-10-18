#!/usr/bin/env bash
# issue-transfer --to plane: a GitHub issue, or every open issue of a board column, carried into the Plane
# project. GitHub is a stand-in gh that keeps issues and cards in files of $G, Plane is the stand-in curl of
# tests/lib.sh; nothing here reaches a network. Each defect the carry must refuse is planted and shown red,
# the innocent case beside it green.
#
#   bash tests/issue-transfer-plane.test.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export GH_ORG=example-org GH_PROJECT_NUMBER=1
make_plane_project
G="$WORK/gh-state"; mkdir -p "$G" "$WORK/ghbin" "$GH_CACHE_DIRECTORY/1"
printf 'PVT_kwcarry1\n' > "$GH_CACHE_DIRECTORY/1/project-id"

cat > "$WORK/ghbin/gh" <<'FAKE'
#!/usr/bin/env bash
# the gh calls of github_carry_rows, issue_comment_post and issue_close, answered from $G
line="$*"; jq_expr=""; n=""
prev=""; for a in "$@"; do
  [ "$prev" != --jq ] || jq_expr="$a"
  case "$a" in n=*) n="${a#n=}" ;; esac
  prev="$a"
done
out() { if [ -n "$jq_expr" ]; then jq -r "$jq_expr"; else cat; fi; }
printf '%s\n' "$line" >> "$G/calls.log"
case "$line" in
  *"items(first:100"*) out < "$G/cards.json" ;;
  *"issue(number:\$n)"*) out < "$G/parent-$n.json" ;;
  "api --paginate repos/example-org/example-repo/issues/"*"/comments") echo '[]' ;;
  "api repos/example-org/example-repo/issues/"*"/comments "*)
    echo "$line" >> "$G/comments.log"; echo '{"html_url":"https://github.com/example-org/example-repo/issues/1#c"}' | out ;;
  "api --method PATCH repos/example-org/example-repo/issues/"*)
    id="${line#*issues/}"; id="${id%% *}"
    echo "$line" >> "$G/closes.log"; jq '.state = "closed"' "$G/issue-$id.json" > "$G/tmp" && mv "$G/tmp" "$G/issue-$id.json" ;;
  "api repos/example-org/example-repo/issues/"*) cat "$G/issue-${line##*/}.json" ;;
  *) echo "unexpected gh call: $line" >&2; exit 1 ;;
esac
FAKE
chmod +x "$WORK/ghbin/gh"; export G
PATH_CURL="$WORK/ghbin:$PATH_CURL"

BODY=$'Fix the carry at lib/plane/tracker.sh:312\n\n```bash\nif [ "$a" -lt 2 ] && x=\'<y>\'; then echo "&"; fi\n```\n\nlast line'
gh_issue() {  # gh_issue <number> <title> <body> <label>... : an open issue in the stand-in
  local n="$1" t="$2" b="$3"; shift 3
  jq -n --argjson n "$n" --arg t "$t" --arg b "$b" --args '{number:$n,title:$t,state:"open",body:$b,labels:[$ARGS.positional[]|{name:.}]}' "$@" > "$G/issue-$n.json"
  echo null > "$G/parent-$n.json"
}
gh_parent() { printf '{"data":{"repository":{"issue":{"parent":{"number":%s,"repository":{"nameWithOwner":"example-org/example-repo"}}}}}}\n' "$2" > "$G/parent-$1.json"; }
gh_parent_none() { echo '{"data":{"repository":{"issue":{"parent":null}}}}' > "$G/parent-$1.json"; }
gh_card() {  # gh_card <number> <status> <priority>
  jq -nc --argjson n "$1" --arg s "$2" --arg p "$3" '{id:"PVTI_\($n)",content:{number:$n,repository:{nameWithOwner:"example-org/example-repo"}},fieldValues:{nodes:[{name:$s,field:{name:"Status"}},{name:$p,field:{name:"Priority"}}]}}'
}

# #8 is the sub-issue of #7 and its card comes first; #10 stands in backlog, its sub-issue #11 in ready
gh_issue 7 "Carry the thing, or R4 has no tool" "$BODY" type:feature area:gate; gh_parent_none 7
gh_issue 8 "Carry the child" "child body" type:feature; gh_parent 8 7
gh_issue 10 "A parent nobody carried" "p" type:feature; gh_parent_none 10
gh_issue 11 "A child of the uncarried" "c" type:feature; gh_parent 11 10
gh_issue 12 "Sits in backlog" "b" type:feature; gh_parent_none 12
{ echo '{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":['
  { gh_card 8 ready P2; gh_card 7 ready P1; gh_card 10 backlog P3; gh_card 11 ready P2; gh_card 12 backlog P0; } | paste -sd, -
  echo ']}}}}'; } > "$G/cards.json"
reset_gh() { : > "$G/calls.log"; : > "$G/comments.log"; : > "$G/closes.log"; }
writes() { grep -c '^\(POST\|PATCH\|PUT\|DELETE\) ' "$CURL_FAKE_STATE/requests.log" || true; }
reset_gh

section "issue-transfer --to plane: a GitHub issue carried into Plane"

# a sub-issue whose parent is not carried yet is refused by name, and nothing is written
reset_log
out="$(ai issue-transfer 11 --to plane 2>&1)" && fail "a sub-issue of an uncarried parent was carried: $out"
grep -q 'example-org/example-repo#10, which is not carried into Plane yet' <<< "$out" || fail "the uncarried parent is not named: $out"
[ "$(writes)" = 0 ] || fail "a refused carry wrote to Plane"
[ ! -s "$G/closes.log" ] || fail "a refused carry closed the GitHub issue"
echo "  a sub-issue whose parent is not carried is refused, naming example-org/example-repo#10, and nothing is written"

# one issue: the label the project lacks is made first, the body arrives unchanged
[ "$(planeq 'console.log(p.labels.some((l)=>l.name==="area:gate"))')" = false ] || fail "the project already has area:gate"
out="$(ai issue-transfer 7 --to plane 2>&1)" || fail "issue-transfer 7 --to plane: $out"
[ "$out" = "#7 -> ENG-1" ] || fail "the line printed is '$out', not '#7 -> ENG-1'"
[ "$(planeq 'const l=p.labels.find((l)=>l.name==="area:gate");console.log(l&&l.color)')" = "#1D76DB" ] || fail "area:gate was not made with the colour of labels.tsv"
[ "$(planeq 'const i=p.issues[0];console.log(i.name+"|"+i.priority+"|"+p.states.find((s)=>s.id===i.state).name+"|"+i.external_source+"|"+i.external_id+"|"+i.labels.map((id)=>p.labels.find((l)=>l.id===id).name).sort().join(","))')" \
  = "Carry the thing, or R4 has no tool|high|ready|github|example-org/example-repo#7|area:gate,repo:example-repo,type:feature" ] || fail "the work item is not as carried: $(planeq 'console.log(JSON.stringify(p.issues[0]))')"
[ "$(ai issue-thread 1 --json | jq -r .body)" = "$BODY" ] || fail "the body did not arrive unchanged: $(ai issue-thread 1 --json | jq -r .body)"
echo "  #7 -> ENG-1: title, priority P1 as high, state ready, external_id, labels with area:gate made first, the body with code fences and file:line unchanged"

# GitHub: one comment with the link, closed as not planned
grep -q 'https://plane.example.test/ws/browse/ENG-1/' "$G/comments.log" || fail "the comment lacks the Plane link: $(cat "$G/comments.log")"
grep -q 'state_reason=not_planned' "$G/closes.log" || fail "the GitHub issue was not closed as not planned: $(cat "$G/closes.log")"
echo "  the GitHub issue got one comment with https://plane.example.test/ws/browse/ENG-1/ and was closed as not planned"

# a second run finds it by external_id and writes nothing, to Plane or to GitHub
reset_log; reset_gh
out="$(ai issue-transfer 7 --to plane 2>&1)" || fail "the second run: $out"
[ "$out" = "#7 -> ENG-1" ] || fail "the second run printed '$out'"
[ "$(writes)" = 0 ] || fail "the second run wrote to Plane: $(grep '^\(POST\|PATCH\) ' "$CURL_FAKE_STATE/requests.log")"
[ ! -s "$G/comments.log" ] && [ ! -s "$G/closes.log" ] || fail "the second run wrote to GitHub"
[ "$(planeq 'console.log(p.issues.length)')" = 1 ] || fail "the second run made a second work item"
echo "  a second run prints the same line and writes nothing"

# a column: the open issues of 'ready' with their parents first. #7 is closed by now and left alone; #8 is
# carried with its parent; #11 is refused by name, and the run stops there with #8 done
reset_gh
out="$(ai issue-transfer --column ready --to plane 2>&1)" && fail "column ready carried #11 whose parent is not carried: $out"
grep -q '^#8 -> ENG-2$' <<< "$out" || fail "column ready did not carry #8 first: $out"
grep -q 'example-org/example-repo#10, which is not carried' <<< "$out" || fail "column ready: the refusal does not name #10: $out"
[ "$(planeq 'const c=p.issues.find((i)=>i.sequence_id===2);console.log(p.issues.find((i)=>i.id===c.parent).sequence_id)')" = 1 ] || fail "#8 is not a sub-issue of ENG-1"
# #11 stops being a sub-issue of the uncarried; the column goes on and the carried #8 is not asked for again
gh_parent_none 11
reset_gh
out="$(ai issue-transfer --column ready --to plane 2>&1)" || fail "issue-transfer --column ready --to plane: $out"
[ "$out" = "#11 -> ENG-3" ] || fail "the column printed: $out"
[ "$(grep -c . "$G/closes.log")" = 1 ] || fail "the second column run closed $(grep -c . "$G/closes.log") issues, not the 1 still open: $(cat "$G/closes.log")"
! grep -q 'issues/12' "$G/closes.log" || fail "the backlog issue #12 was carried"
[ "$(planeq 'console.log(p.issues.length)')" = 3 ] || fail "Plane holds $(planeq 'console.log(p.issues.length)') work items, not 3"
echo "  --column ready: #8 carried under ENG-1, #11 refused while its parent #10 is not carried and carried once it is not a sub-issue, #12 in backlog left alone"

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
