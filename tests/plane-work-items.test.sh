#!/usr/bin/env bash
# The issue commands against Plane, one work item at a time: TRACKER=plane in a project whose curl is the
# stand-in of tests/lib.sh. Each shape of defect the Plane provider must refuse is planted and
# shown red, and the innocent case beside it green. Nothing here reaches a network.
#
#   bash tests/plane-work-items.test.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
make_plane_project
printf 'The body & its <tag> at lib/x.sh:12\n\nsecond paragraph\n' > "$WORK/body.md"
new() { ai issue-new --repo example-org/example-repo --title "$1" --body-file "$WORK/body.md" --label type:feature --label area:tooling --priority P2 --asked-by someone --asked-in "the test" "${@:2}" 2>/dev/null; }

section "the issue commands on Plane: one work item at a time"

n="$(new "Put the thing on the board, or nobody sees it")" || fail "issue-new on Plane: $n"
[ "$n" = 1 ] || fail "the first work item should be number 1, got '$n'"
[ "$(planeq 'console.log(p.states.find(s=>s.id===p.issues[0].state).name+" "+p.issues[0].priority)')" = "ready medium" ] \
  || fail "the work item is not in state ready with priority medium"
echo "  issue-new: the work item stands in ready, priority medium (P2)"

# the body and the comments round-trip exactly
thread="$(ai issue-thread "$n" --json)" || fail "issue-thread: $thread"
want="$(printf 'Asked for by @someone on %s in the test.\n\nThe body & its <tag> at lib/x.sh:12\n\nsecond paragraph\n' "$(date +%Y-%m-%d)")"
[ "$(jq -r .body <<< "$thread")" = "$want" ] || fail "the body did not come back as written: $(jq -r .body <<< "$thread")"
[ "$(jq -r .state <<< "$thread")" = open ] || fail "a work item in ready is open"
echo "  issue-thread: the Markdown comes back as written, & and < included"

# THE TOKEN: read from the command at call time, in no argument and no environment
grep -q 'plane-token-0123' "$CURL_FAKE_STATE/argv.log" "$CURL_FAKE_STATE/env.log" && fail "the token stands in curl's arguments or environment"
echo "  the token reached Plane (the stand-in answers 401 without it) and stands in no argument and no environment"
planted="$WORK/planted"; mkdir -p "$planted"; cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/templates" "$planted/"; cp "$ROOT/VERSION" "$planted/"
sed -i.bak 's|} \| curl --silent|} \| curl -H "$name: $prefix$token" --silent|' "$planted/lib/common.sh"
cmp -s "$ROOT/lib/common.sh" "$planted/lib/common.sh" && fail "the planted copy equals the real lib/common.sh"
reset_log; ROOT_UNDER_TEST="$planted" ai issue-thread "$n" --json >/dev/null || fail "the copy with the token in an argument should still get its answer"
grep -q 'plane-token-0123' "$CURL_FAKE_STATE/argv.log" || fail "planted: the token in an argument is not seen in the argument log, so the check cannot go red"
cp "$ROOT/lib/common.sh" "$planted/lib/common.sh"
sed -i.bak 's|^  token=""$|  export PLANE_LEAK="$token"; token=""|; s|^  {$|  export PLANE_LEAK="$token"; {|' "$planted/lib/common.sh"
reset_log; ROOT_UNDER_TEST="$planted" ai issue-thread "$n" --json >/dev/null || fail "the copy with the token in the environment should still get its answer"
grep -q 'plane-token-0123' "$CURL_FAKE_STATE/env.log" || fail "planted: the token in the environment is not seen in the environment log, so the check cannot go red"
reset_log; ai issue-thread "$n" --json >/dev/null || fail "the innocent run gets no answer"
! grep -q 'plane-token-0123' "$CURL_FAKE_STATE/argv.log" "$CURL_FAKE_STATE/env.log" || fail "innocent: the token stands in curl's arguments or environment"
echo "  planted: a token in an argument and a token in the environment are each seen; innocent: the run gets its answer with neither"
printf 'wrong-token\n' > "$WORK/token"; out="$(ai issue-thread "$n" 2>&1)" && fail "a wrong token was accepted"
grep -q 'the Plane API answered 401' <<< "$out" || fail "a refused key is not named: $out"
printf 'plane-token-0123\n' > "$WORK/token"
sed -i.bak 's|^PLANE_TOKEN_COMMAND=.*|PLANE_TOKEN_COMMAND=|' "$P/.ai-core/config.env"; out="$(ai issue-thread "$n" 2>&1)" && fail "a missing token command was accepted"
grep -q 'PLANE_TOKEN_COMMAND is not set' <<< "$out" || fail "a missing token command is not named: $out"
sed -i.bak "s|^PLANE_TOKEN_COMMAND=.*|PLANE_TOKEN_COMMAND=\"cat $WORK/token\"|" "$P/.ai-core/config.env"
echo "  a wrong key and a missing token command are each refused by name"

# THE TRACE: under set -x the shell prints every assignment and argument it expands, the token among them,
# unless the code that holds the token switches the trace off, and the caller's setting is back afterwards
traced() { ( cd "$P" && PATH="$PATH_CURL" bash -x "${ROOT_UNDER_TEST:-$ROOT}/bin/$1.sh" "${@:2}" 2>"$WORK/trace" ); }
traced issue-thread "$n" --json >/dev/null || fail "issue-thread under bash -x gets no answer"
grep -q 'plane_call' "$WORK/trace" || fail "the trace of bash -x is empty, so the check cannot go red"
! grep -q 'plane-token-0123' "$WORK/trace" || fail "the token stands in the trace of bash -x: $(grep -m1 'plane-token-0123' "$WORK/trace")"
cp "$ROOT/lib/common.sh" "$planted/lib/common.sh"
sed -i.bak 's|traced=1; set +x|traced=1|' "$planted/lib/common.sh"
cmp -s "$ROOT/lib/common.sh" "$planted/lib/common.sh" && fail "the planted copy equals the real lib/common.sh"
ROOT_UNDER_TEST="$planted" traced issue-thread "$n" --json >/dev/null || fail "the copy that leaves the trace on should still get its answer"
grep -q 'plane-token-0123' "$WORK/trace" || fail "planted: a token in the trace is not seen, so the check cannot go red"
trace_after() {  # trace_after <on|off> <code>: whether xtrace is on after <code> ran with it <on|off>
  PLANE_TOKEN_COMMAND="cat $WORK/token" PATH="$PATH_CURL" bash -c 'cd "$3"; . "$1/lib/common.sh"; [ "$2" != on ] || set -x; eval "$4" 2>/dev/null; case $- in *x*) echo on ;; *) echo off ;; esac' _ "$ROOT" "$1" "$P" "$2" 2>/dev/null
}
for mode in on off; do
  [ "$(trace_after $mode 'http_call PLANE_TOKEN_COMMAND X-API-Key "" GET https://plane.example.test/api/v1/users/me/')" = "$mode" ] || fail "http_call changed the trace setting $mode of its caller"
  [ "$(trace_after $mode 'token_from_command PLANE_TOKEN_COMMAND >/dev/null')" = "$mode" ] || fail "token_from_command changed the trace setting $mode of its caller"
done
echo "  under bash -x the token is in no trace line, and the caller's trace setting, on or off, is back after a call; planted: a copy that leaves the trace on shows the token in it"

# Fatal token reads must restore tracing before the caller's EXIT trap runs.
trace_on_exit() {  # trace_on_exit <call> <token command>
  ( cd "$P" && PATH="$PATH_CURL" PLANE_TOKEN_COMMAND="$2" bash -c '
    . "$1/lib/plane/api.sh"
    trap '\''case $- in *x*) echo on >&3 ;; *) echo off >&3 ;; esac'\'' EXIT
    set -ex
    eval "$2" >/dev/null
  ' _ "$ROOT" "$1" 3>"$WORK/exit-setting" 2>"$WORK/exit-trace" )
}
for command in "exit 7" "printf 'probe\nbad\n'" "printf ''"; do
  for call in 'token_from_command PLANE_TOKEN_COMMAND' 'http_call PLANE_TOKEN_COMMAND X-API-Key "" GET https://plane.example.test/api/v1/users/me/'; do
    trace_on_exit "$call" "$command" && fail "a failing or invalid token was accepted: $call"
    [ "$(cat "$WORK/exit-setting")" = on ] || fail "$call left xtrace off in the EXIT trap"
    ! grep -q probe "$WORK/exit-trace" || fail "a refused token reached the fatal trace"
  done
done
for call in 'token_from_command UNSET_TOKEN_COMMAND' 'http_call UNSET_TOKEN_COMMAND X-API-Key "" GET https://plane.example.test/api/v1/users/me/'; do
  trace_on_exit "$call" "exit 7" && fail "a missing token setting was accepted: $call"
  [ "$(cat "$WORK/exit-setting")" = on ] || fail "$call left xtrace off in the EXIT trap"
done
trace_on_exit 'plane_api "the user" GET /api/v1/users/me/' "printf 'wrong-token\n'" && fail "a refused request was accepted"
[ "$(cat "$WORK/exit-setting")" = on ] || fail "a refused request left xtrace off in the EXIT trap"
grep -q 'API answered 401' "$WORK/exit-trace" || fail "the refused request was not named"
echo "  fatal trace restoration: failed, invalid and empty token reads and a refused request leave xtrace on in the EXIT trap"

for call in 'token_from_command PLANE_TOKEN_COMMAND >&-' 'token_from_command PLANE_TOKEN_COMMAND >/dev/full'; do
  trace_on_exit "$call" "cat $WORK/token" && fail "a failed token write was accepted: $call"
  [ "$(cat "$WORK/exit-setting")" = on ] || fail "$call left xtrace off in the EXIT trap"
  grep -q 'cannot write the token from PLANE_TOKEN_COMMAND to standard output' "$WORK/exit-trace" || fail "a failed token write did not name its setting: $call"
  ! grep -q 'plane-token-0123' "$WORK/exit-trace" || fail "a failed token write exposed the token: $call"
done
echo "  fatal trace restoration: closed standard output and /dev/full fail by setting, restore xtrace in the EXIT trap and expose no token"

# A NUL must be rejected before command substitution can silently remove it.
out="$(cd "$P" && PLANE_TOKEN_COMMAND="printf 'probe\000-token\n'" bash -c '. "$1/lib/common.sh"; token_from_command PLANE_TOKEN_COMMAND' _ "$ROOT" 2>&1)" && fail "a NUL token was accepted by token_from_command"
grep -q 'PLANE_TOKEN_COMMAND printed a token with a control character' <<< "$out" || fail "a NUL token was not refused by its setting: $out"
! grep -qE 'probe|ignored null byte' <<< "$out" || fail "the NUL refusal exposed or discarded token bytes: $out"
echo "  NUL token refusal: token_from_command rejects probe, NUL, -token and newline without exposing the token"

# A TOKEN OF MORE THAN ONE LINE would add a line to curl's configuration: it is refused by the name of the setting
printf 'first\nrequest = DELETE\n#\n' > "$WORK/token"
reset_log; out="$(ai issue-thread "$n" 2>&1)" && fail "a token of three lines was accepted"
grep -q 'the command of PLANE_TOKEN_COMMAND printed a token with a control character in it' <<< "$out" || fail "a multiline token is not refused by the name of the setting: $out"
! grep -q 'first' <<< "$out" || fail "the refusal prints the token: $out"
[ ! -s "$CURL_FAKE_STATE/requests.log" ] || fail "curl was called with a refused token"
printf 'plane-token-0123\r\n' > "$WORK/token"
out="$(ai issue-thread "$n" 2>&1)" && fail "a token with a carriage return was accepted"
grep -q 'PLANE_TOKEN_COMMAND printed a token with a control character' <<< "$out" || fail "a token with a carriage return is not refused by name: $out"
printf 'plane-token\t0123\n' > "$WORK/token"
out="$(ai issue-thread "$n" 2>&1)" && fail "a token with a tab was accepted"
printf 'first\nrequest = DELETE\n#\n' > "$WORK/token"
cp "$ROOT/lib/common.sh" "$planted/lib/common.sh"
sed -i.bak '/\*\[\[:cntrl:\]\]\*)/d' "$planted/lib/common.sh"
cmp -s "$ROOT/lib/common.sh" "$planted/lib/common.sh" && fail "the planted copy equals the real lib/common.sh"
reset_log; ROOT_UNDER_TEST="$planted" ai issue-thread "$n" >/dev/null 2>&1 || true
grep -q '^DELETE ' "$CURL_FAKE_STATE/requests.log" || fail "planted: a line added to curl's configuration by the token is not seen, so the check cannot go red"
printf 'plane-token-0123\n' > "$WORK/token"
ai issue-thread "$n" >/dev/null || fail "the innocent one-line token is refused"
echo "  a token with a line break, a carriage return or a tab is refused by the name of the setting before curl is called; planted: without the check the extra line reaches curl"

# CLOSE AND REOPEN: one write, and the reason of a not-planned close is kept
reset_log; ai issue-close "$n" >/dev/null || fail "issue-close"
[ "$(planeq 'console.log(p.states.find(s=>s.id===p.issues[0].state).name)')" = done ] || fail "issue-close did not move the work item to done"
ai issue-reopen "$n" >/dev/null || fail "issue-reopen"
[ "$(planeq 'console.log(p.states.find(s=>s.id===p.issues[0].state).name)')" = ready ] || fail "issue-reopen did not move the work item to ready"
reset_log; out="$(ai issue-close --reason not-planned "$n" 2>&1)" || fail "issue-close --reason not-planned: $out"
[ "$(planeq 'console.log(p.states.find(s=>s.id===p.issues[0].state).name)')" = Cancelled ] || fail "a not-planned close should stand in Cancelled, not be turned into done"
grep -q "^#$n -> Cancelled (board example-org/ENG)" <<< "$out" || fail "the column the card was put in is not said: $out"
# an explicit state is applied wherever the work item stands: it is the command that moves a card out of Cancelled
out="$(ai issue-status "$n" done 2>&1)" || fail "issue-status done on a cancelled work item: $out"
[ "$(planeq 'console.log(p.states.find(s=>s.id===p.issues[0].state).name)')" = done ] || fail "issue-status done reported success and left the work item in $(planeq 'console.log(p.states.find(s=>s.id===p.issues[0].state).name)')"
grep -q "^#$n -> done$" <<< "$out" || fail "the move is not reported: $out"
echo "  issue-close: done; issue-reopen: ready; --reason not-planned: the card is put in Cancelled; issue-status done moves a cancelled work item to done"
ai issue-reopen "$n" >/dev/null || fail "issue-reopen"

# A STATE THE PROJECT LACKS is refused with the states there are, and nothing is written
reset_log; out="$(ai issue-status "$n" nonesuch 2>&1)" && fail "a state the project lacks was accepted"
grep -q "has no option 'nonesuch'. It has: backlog ready planned implementing review testing Cancelled done" <<< "$out" || fail "the states there are are not named: $out"
! grep -q '^PATCH' "$CURL_FAKE_STATE/requests.log" || fail "a refused status still wrote"
ai issue-status "$n" Testing >/dev/null || fail "issue-status Testing (matched without case)"
[ "$(planeq 'console.log(p.states.find(s=>s.id===p.issues[0].state).name)')" = testing ] || fail "issue-status did not move the work item to testing"
echo "  issue-status: a state is matched without case; one the project lacks is refused with the list"

# PRIORITY: P0 to P3 are urgent, high, medium and low
ai issue-priority "$n" P0 >/dev/null || fail "issue-priority"
[ "$(planeq 'console.log(p.issues[0].priority)')" = urgent ] || fail "P0 is not urgent"

# ASSIGNEES: a member is named by email; a name Plane does not know stops the command before any write, and a refused write says it was a write
reset_log
out="$(ai issue-assign example-org/example-repo "$n" --add other@example.test 2>&1)" || fail "issue-assign with a member of the workspace: $out"
[ "$(planeq 'console.log(p.issues[0].assignees.length)')" = 2 ] || fail "the member was not assigned: $out"
reset_log
out="$(ai issue-assign example-org/example-repo "$n" --add nobody@example.test 2>&1)" && fail "issue-assign took a member the workspace does not have: $out"
grep -q 'Plane has no member nobody@example.test in the workspace ws' <<< "$out" || fail "an unknown member is not named: $out"
! grep -q 'cannot read the assignees' <<< "$out" || fail "an unknown member ended in an error about a read: $out"
! grep -q '^PATCH' "$CURL_FAKE_STATE/requests.log" || fail "an unknown member still sent a write to Plane: $(grep '^PATCH' "$CURL_FAKE_STATE/requests.log")"
[ "$(planeq 'console.log(p.issues[0].assignees.length)')" = 2 ] || fail "an unknown member changed the assignees"
printf '[{"match":"PATCH ","status":400,"times":1,"body":"refused"}]' > "$CURL_FAKE_STATE/inject.json"
out="$(ai issue-assign example-org/example-repo "$n" --add stranger@example.test 2>&1)" && fail "a write Plane refused was accepted: $out"
grep -q 'cannot write the assignees of example-org/example-repo#1 - the Plane API answered 400' <<< "$out" || fail "a refused write does not say it was a write: $out"
printf '[]' > "$CURL_FAKE_STATE/inject.json"
out="$(bash "$ROOT/bin/ai-core" issue-assign --help | tr -s '\n ' ' ')" && grep -q 'on Plane the email of a member of the workspace' <<< "$out" || fail "the help of issue-assign does not say what Plane accepts: $out"
echo "  issue-assign: a member is named by email; an unknown one stops it before any write; a refused write says it was a write; the help names what Plane accepts"

# A LOOKUP THAT FAILS inside the request of a write stops the command, and nothing is sent
for pair in "issue-close done" "issue-reopen ready"; do
  command="${pair% *}"; state="${pair#* }"
  planeset "p.hidden=p.states.filter((x)=>x.name==='$state'); p.states=p.states.filter((x)=>x.name!=='$state')"
  reset_log
  out="$(ai "$command" "$n" 2>&1)" && fail "$command went on in a project with no state $state: $out"
  grep -q "has no state '$state'" <<< "$out" || fail "$command does not name the missing state $state: $out"
  ! grep -q '^PATCH' "$CURL_FAKE_STATE/requests.log" || fail "$command sent a write although the state $state is not there: $(grep -A1 '^PATCH' "$CURL_FAKE_STATE/requests.log")"
  planeset 'p.states=p.states.concat(p.hidden); delete p.hidden'
done
reset_log
out="$(plane_fn issue_edit example-org/example-repo "$n" "" "$WORK/no-such-body" 2>&1)" && fail "issue_edit took a body file that is not there: $out"
! grep -q '^PATCH' "$CURL_FAKE_STATE/requests.log" || fail "issue_edit sent a write for a body it could not read"
out="$(plane_fn issue_comment_post example-org/example-repo "$n" "" "$WORK/no-such-body" 2>&1)" && fail "issue_comment_post took a text file that is not there: $out"
! grep -q '^POST' "$CURL_FAKE_STATE/requests.log" || fail "issue_comment_post sent a comment it could not read"
out="$(plane_fn issue_create example-org/example-repo "A title" "$WORK/no-such-body" me@example.test 2>&1)" && fail "issue_create took a body file that is not there: $out"
! grep -q '^POST' "$CURL_FAKE_STATE/requests.log" || fail "issue_create created a work item from a body it could not read"
echo "  issue-close, issue-reopen, edit, comment and create: a state or a text that cannot be read stops the command, and nothing is written"
reset_log
out="$(PLANE_PROJECT=NOPE plane_fn plane_label_ensure "" a-new-label 6B7280 "a label" 2>&1)" && fail "plane_label_ensure went on with a project Plane does not have: $out"
grep -q 'Plane has no project with the identifier NOPE' <<< "$out" || fail "a project Plane does not have is not named: $out"
! grep -q '^POST' "$CURL_FAKE_STATE/requests.log" || fail "plane_label_ensure sent a write to a project it could not find: $(grep '^POST' "$CURL_FAKE_STATE/requests.log")"
echo "  a project Plane does not have stops a write before it is sent"

# THE RATE LIMIT: a 429 waits for X-RateLimit-Reset and goes on; one that never lifts is refused
reset=$(( $(date +%s) + 7 ))
printf '[{"match":"/issues/ENG-1/","status":429,"times":1,"headers":{"X-RateLimit-Reset":"%s"}}]' "$reset" > "$CURL_FAKE_STATE/inject.json"
: > "$WORK/slept"; out="$(ai issue-thread "$n" --json 2>&1)" || fail "a 429 that lifts after one wait should not fail: $out"
grep -qE '^[1-9][0-9]*$' "$WORK/slept" || fail "the 429 was not waited out"
printf '[{"match":"/issues/ENG-1/","status":429,"times":9,"headers":{"X-RateLimit-Reset":"%s"}}]' "$reset" > "$CURL_FAKE_STATE/inject.json"
out="$(ai issue-thread "$n" --json 2>&1)" && fail "a 429 that never lifts was accepted"
grep -q "rate limit still refuses after 3 waits" <<< "$out" || fail "a 429 that never lifts is not named: $out"
printf '[]' > "$CURL_FAKE_STATE/inject.json"
echo "  a 429 is waited out until X-RateLimit-Reset; one that never lifts is refused by name"

# COMMENTS
url="$(ai issue-comment "$n" "A comment <b> & more")" || fail "issue-comment"
[ "$url" = "https://plane.example.test/ws/browse/ENG-1/" ] || fail "issue-comment printed '$url'"
[ "$(ai issue-thread "$n" --json | jq -r '.comments[0].body')" = "A comment <b> & more" ] || fail "the comment did not come back as written"
echo "  issue-comment: the work item's address is printed and the comment comes back as written"

# EPICS: a child moves its parent as on GitHub
c1="$(new "First child of the epic, or the epic has no work" --parent "$n")" || fail "issue-new --parent: $c1"
ai issue-status "$c1" implementing >/dev/null || fail "issue-status on the child"
[ "$(planeq 'console.log(p.states.find(s=>s.id===p.issues[0].state).name)')" = implementing ] || fail "the epic did not follow its child to implementing"
ai issue-close "$c1" >/dev/null || fail "issue-close on the child"
[ "$(planeq 'console.log(p.states.find(s=>s.id===p.issues[0].state).name)')" = done ] || fail "the epic did not close with its only child"
echo "  an epic follows its child to implementing, and closes with it"

# BLOCKED BY: the relation is made once; a second block is refused the way GitHub refuses it
a="$(new "Second thing, or the first has nothing to wait for")"; b="$(new "Third thing, or the second waits on nothing")"
out="$(ai issue-block example-org/example-repo "$a" example-org/example-repo "$b" 2>&1)" || fail "issue-block: $out"
out="$(ai issue-block example-org/example-repo "$a" example-org/example-repo "$b" 2>&1)" && fail "a second identical block was accepted"
grep -q 'is already blocked by' <<< "$out" || fail "the repeated block is not named: $out"
echo "  issue-block: the relation blocked_by is made once"

# A DUPLICATE is cancelled as well as related: GitHub closes it, and an open one would hold its epic open
state_of() { planeq "const it=p.issues.find((i)=>i.sequence_id===$1);console.log(p.states.find((s)=>s.id===it.state).name)"; }
canon="$(new "The original, or the duplicate has nothing to copy")"; dup="$(new "The same thing again, or nobody notices")"
out="$(ai issue-duplicate example-org/example-repo "$canon" example-org/example-repo "$dup" 2>&1)" || fail "issue-duplicate: $out"
[ "$(state_of "$dup")" = Cancelled ] || fail "the duplicate stands in $(state_of "$dup"), not in Cancelled"
[ "$(state_of "$canon")" = ready ] || fail "the original was moved to $(state_of "$canon")"
[ "$(planeq 'console.log(p.relations.filter((r)=>r.relation_type==="duplicate").length)')" = 1 ] || fail "the duplicate relation was not made"
echo "  issue-duplicate: the duplicate is related to the original and stands in Cancelled; the original stays where it was"

# AN EPIC WITH AN OPEN CHILD IS NOT CLOSED, as completed or as not planned, and writes nothing. Closed is the
# completed and cancelled groups of the state, so a child still open is not done whatever its state is called
epic="$(new "An epic that owes its child, or it says done early")"
kid_closed="$(new "The child that is done" --parent "$epic")"; kid_open="$(new "The child that is not" --parent "$epic")"
ai issue-close "$kid_closed" >/dev/null 2>&1 || fail "issue-close on the first child"
for reason in '' not-planned; do
  reset_log; out="$(ai issue-close ${reason:+--reason "$reason"} "$epic" 2>&1)" && fail "the epic with an open child was closed (${reason:-completed})"
  grep -q "error: example-org/example-repo#$epic has open sub-issues, so it stays open and its card where it is: example-org/example-repo#$kid_open - close them first, or take them out of it" <<< "$out" \
    || fail "the refusal does not name the open child (${reason:-completed}): $out"
  [ "$(state_of "$epic")" != done ] && [ "$(state_of "$epic")" != Cancelled ] || fail "the refused epic stands in $(state_of "$epic")"
  ! grep -q '^\(PATCH\|POST\|PUT\|DELETE\) ' "$CURL_FAKE_STATE/requests.log" || fail "a refused close wrote (${reason:-completed}): $(grep '^\(PATCH\|POST\|PUT\|DELETE\) ' "$CURL_FAKE_STATE/requests.log")"
done
# a child that is open stands in a state called done of a group that is not completed: it is not done, so closing
# its sibling moves the epic to testing at most and never closes it
planeset 'const k=p.issues.find((i)=>i.sequence_id==='"$kid_open"');const st={id:require("crypto").randomUUID(),name:"done",group:"started",color:"#000",sequence:99};p.states.push(st);k.state=st.id'
epic2="$(new "A second epic, or the first proves nothing")"
sib1="$(new "The sibling that gets closed" --parent "$epic2")"; sib2="$(new "The sibling called done and not" --parent "$epic2")"
planeset 'const k=p.issues.find((i)=>i.sequence_id==='"$sib2"');k.state=p.states.find((s)=>s.name==="done"&&s.group==="started").id'
ai issue-close "$sib1" >/dev/null 2>&1 || fail "closing a child beside one called done that is not: the command failed"
[ "$(state_of "$epic2")" = testing ] || fail "the epic stands in $(state_of "$epic2"), not in testing, beside a child called done that is open"
[ "$(planeq 'const k=p.issues.find((i)=>i.sequence_id==='"$epic2"');console.log(k.completed_at)')" = null ] || fail "the epic was closed beside a child called done that is open"
# a child that is open stands in a state called not planned of a group that is not cancelled: the epic leaves a
# cancelled child out, and this one is not cancelled, so it counts at most as testing and the epic never reaches a close
planeset 'const st={id:require("crypto").randomUUID(),name:"not planned",group:"started",color:"#000",sequence:98};p.states.push(st)'
epic5="$(new "A fifth epic, with a child called not planned")"
sib5="$(new "The sibling that gets closed beside it" --parent "$epic5")"; open5="$(new "The sibling called not planned and open" --parent "$epic5")"
planeset 'const k=p.issues.find((i)=>i.sequence_id==='"$open5"');k.state=p.states.find((s)=>s.name==="not planned"&&s.group==="started").id'
ai issue-close "$sib5" >/dev/null 2>&1 || fail "closing a child beside one called not planned that is open: the command failed"
[ "$(state_of "$epic5")" = testing ] || fail "the epic stands in $(state_of "$epic5"), not in testing, beside a child called not planned that is open"
[ "$(planeq 'const k=p.issues.find((i)=>i.sequence_id==='"$epic5"');console.log(k.completed_at)')" = null ] || fail "the epic was closed beside a child called not planned that is open"
# all its children closed: an epic closes, with either reason, and so does a leaf
epic3="$(new "A third epic, closed by hand")"; kid3="$(new "Its only child" --parent "$epic3")"
planeset 'const k=p.issues.find((i)=>i.sequence_id==='"$kid3"');k.state=p.states.find((s)=>s.name==="done").id'
ai issue-close "$epic3" >/dev/null 2>&1 || fail "an epic whose children are all closed as completed was refused"
[ "$(state_of "$epic3")" = done ] || fail "that epic stands in $(state_of "$epic3"), not in done"
epic4="$(new "A fourth epic, rejected whole")"; kid4="$(new "Its only child, rejected too" --parent "$epic4")"
planeset 'const k=p.issues.find((i)=>i.sequence_id==='"$kid4"');k.state=p.states.find((s)=>s.name==="Cancelled").id'
ai issue-close --reason not-planned "$epic4" >/dev/null 2>&1 || fail "an epic whose children are all cancelled was refused its not-planned close"
[ "$(state_of "$epic4")" = Cancelled ] || fail "that epic stands in $(state_of "$epic4"), not in Cancelled"
leaf="$(new "A leaf with nothing under it")"
ai issue-close "$leaf" >/dev/null 2>&1 || fail "a leaf was refused its close"
[ "$(state_of "$leaf")" = done ] || fail "the leaf stands in $(state_of "$leaf"), not in done"
echo "  an epic with an open child is refused, completed and not planned, naming the child and writing nothing; a child called done or not planned that is open keeps its epic at testing; an epic with all its children closed, a leaf and a not-planned close go through"

# THE DOCTOR LINE: the tracker, where it answers, and that the key does, never the key
line="$( cd "$P" && PATH="$PATH_CURL" bash -c 'report() { echo "report $*"; }; problem() { echo problem; }; . "$1/lib/tracker.sh"; tracker_doctor' _ "$ROOT" )"
[ "$line" = "  tracker: plane (https://plane.example.test, the key answers)" ] || fail "the doctor line is '$line'"
printf 'wrong-token\n' > "$WORK/token"
line="$( cd "$P" && PATH="$PATH_CURL" bash -c 'report() { echo "report $*"; }; problem() { echo problem; }; . "$1/lib/tracker.sh"; tracker_doctor' _ "$ROOT" )"
grep -q 'problem' <<< "$line" || fail "a key Plane refuses is no problem for the doctor: $line"
grep -q 'wrong-token' <<< "$line" && fail "the doctor printed the key"
printf 'plane-token-0123\n' > "$WORK/token"
echo "  doctor: tracker: plane (<url>, the key answers), a refused key is a problem, the key is never printed"

# A LISTING THAT DOES NOT ADVANCE: the same cursor answered again ends in a refusal, not in the same page for ever
printf '[{"match":"/labels/","status":200,"times":9,"body":{"results":[{"id":"1","name":"a"}],"next_page_results":true,"next_cursor":"100:1:0"}}]' > "$CURL_FAKE_STATE/inject.json"
reset_log; out="$(plane_fn labels_list example-org/example-repo 2>&1)" && fail "a listing that repeats its cursor was accepted"
grep -q 'answered the page cursor 100:1:0 again, so the listing does not advance' <<< "$out" || fail "the repeated cursor is not named: $out"
[ "$(grep -c '/labels/' "$CURL_FAKE_STATE/requests.log")" -le 3 ] || fail "the listing went on asking after the repeated cursor ($(grep -c '/labels/' "$CURL_FAKE_STATE/requests.log") asks)"
printf '[{"match":"/labels/","status":200,"times":1,"body":{"results":[{"id":"1","name":"a"}],"next_page_results":true}}]' > "$CURL_FAKE_STATE/inject.json"
out="$(plane_fn labels_list example-org/example-repo 2>&1)" && fail "a next page without a cursor was accepted"
grep -q 'gave no cursor for it' <<< "$out" || fail "the missing cursor is not named: $out"
printf '[]' > "$CURL_FAKE_STATE/inject.json"
[ -n "$(plane_fn labels_list example-org/example-repo)" ] || fail "innocent: a listing that ends is refused"
echo "  a listing that answers its cursor again, or a next page with no cursor, is refused by name; an ordinary listing is read to its end"

# A 2XX ANSWER THAT IS NO LISTING is no empty listing: HTML from a proxy, nothing, a scalar, an array, a missing or
# wrong results, two documents, a wrong pagination field and a bad second page each stop the read with a line that
# names the listing, print no row, and do so whatever the caller does with pipefail and errexit.
labels_path="/api/v1/workspaces/ws/projects/$(planeq 'console.log(p.id)')/labels/"
listing() {  # listing <root> <inject json>: plane_pages on the labels with that answer planted; prints status=<n>, then stdout=[...], then the error line
  printf '%s' "$2" > "$CURL_FAKE_STATE/inject.json"
  ( cd "$P" && PATH="$PATH_CURL" bash -c '. "$1/lib/board.sh"; set_project >/dev/null; set +e +o pipefail
      rows="$(plane_pages "the labels of ENG" "$2" 2>"$3")"; echo "status=$?"; echo "stdout=[$rows]"; cat "$3"' _ "$1" "$labels_path" "$WORK/listing-err" )
}
valid_first='{"results":[{"id":"1","name":"a"}],"next_page_results":true,"next_cursor":"100:1:0"}'
bad_answers=(
  '[{"match":"/labels/","status":200,"times":1,"body":"<html>502 Bad Gateway</html>"}]'
  '[{"match":"/labels/","status":200,"times":1,"body":""}]'
  '[{"match":"/labels/","status":200,"times":1,"body":5}]'
  '[{"match":"/labels/","status":200,"times":1,"body":[]}]'
  '[{"match":"/labels/","status":200,"times":1,"body":{"count":0}}]'
  '[{"match":"/labels/","status":200,"times":1,"body":{"results":{"a":1}}}]'
  '[{"match":"/labels/","status":200,"times":1,"body":"{\"results\":[]}\n{\"results\":[]}"}]'
  '[{"match":"/labels/","status":200,"times":1,"body":{"results":[],"next_page_results":"yes"}}]'
  '[{"match":"/labels/","status":200,"times":1,"body":{"results":[{"id":"1"}],"next_page_results":true,"next_cursor":7}}]'
  "[{\"match\":\"/labels/\",\"status\":200,\"times\":1,\"body\":$valid_first},{\"match\":\"/labels/\",\"status\":200,\"times\":1,\"body\":\"<html>second page</html>\"}]"
)
listing_refused() {  # listing_refused <root>: 0 when every bad answer failed with the named line and no row, and a valid empty listing and a valid two-page listing succeeded
  local a out
  for a in "${bad_answers[@]}"; do
    out="$(listing "$1" "$a")"
    grep -q '^status=[1-9]' <<< "$out" || { echo "accepted: $a -> $out"; return 1; }
    grep -q '^stdout=\[\]$' <<< "$out" || { echo "printed rows: $a -> $out"; return 1; }
    grep -q 'cannot read the labels of ENG - the Plane API answered 2xx, and the answer is not the required JSON object with a results array' <<< "$out" || { echo "not named: $a -> $out"; return 1; }
  done
  out="$(listing "$1" '[{"match":"/labels/","status":200,"times":1,"body":{"results":[]}}]')"
  [ "$out" = $'status=0\nstdout=[]' ] || { echo "a valid empty listing: $out"; return 1; }
  out="$(listing "$1" "[{\"match\":\"/labels/\",\"status\":200,\"times\":1,\"body\":$valid_first},{\"match\":\"/labels/\",\"status\":200,\"times\":1,\"body\":{\"results\":[{\"id\":\"2\",\"name\":\"b\"}]}}]")"
  [ "$out" = $'status=0\nstdout=[{"id":"1","name":"a"}\n{"id":"2","name":"b"}]' ] || { echo "a valid two-page listing: $out"; return 1; }
}
out="$(listing_refused "$ROOT")" || fail "a 2xx answer that is no listing was read as one: $out"
cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/templates" "$planted/"; cp "$ROOT/VERSION" "$planted/"
cat >> "$planted/lib/plane/api.sh" <<'DEFECT'
plane_pages() {
  local what="$1" path="$2" cursor="" seen=" " page sep="?"
  case "$path" in *"?"*) sep="&" ;; esac
  while :; do
    page="$(plane_api "$what" GET "$path${sep}per_page=100${cursor:+&cursor=$cursor}")" || exit 1
    printf '%s' "$page" | jq -c '.results[]'
    [ "$(printf '%s' "$page" | jq -r '.next_page_results // false')" = true ] || break
    cursor="$(printf '%s' "$page" | jq -r '.next_cursor // empty')"
    [ -n "$cursor" ] || die "cannot read $what - the Plane API announced a next page and gave no cursor for it"
    case "$seen" in *" $cursor "*) die "cannot read $what - the Plane API answered the page cursor $cursor again" ;; esac
    seen="$seen$cursor "
  done
}
DEFECT
! listing_refused "$planted" >/dev/null || fail "planted: the plane_pages that reads HTML as an empty listing passes the check, so it cannot go red"
printf '[]' > "$CURL_FAKE_STATE/inject.json"
echo "  a 2xx answer that is HTML, empty, a scalar, an array, without results, with two documents, with a wrong pagination field or with a bad second page stops the read by name and prints no row, with pipefail and errexit off too; a valid empty and a valid two-page listing are read; the old plane_pages fails this check"

# THE CACHES say whose they are: the same identifier in another workspace, or on another instance, is another project
fields_of() { plane_fn fields_tsv | awk -F'\t' '$1 == "Status" && $3 == "ready" { print $4 }'; }
first_ready="$(fields_of)"; [ -n "$first_ready" ] || fail "the first fields have no ready state"
[ "$first_ready" = "$(planeq 'console.log(p.states.find((s)=>s.name==="ready").id)')" ] || fail "the first fields hold another id than the stand-in's"
sed -i.bak 's|^PLANE_URL=.*|PLANE_URL=https://plane2.example.test|' "$P/.ai-core/config.env"
reset_log; fields_of >/dev/null
grep -q '/states/' "$CURL_FAKE_STATE/requests.log" || fail "another instance was answered from the cache of the first"
sed -i.bak 's|^PLANE_URL=.*|PLANE_URL=https://plane.example.test|' "$P/.ai-core/config.env"
# Different schemes and ports on one host can serve different projects with the same identifier.
cp "$CURL_FAKE_STATE/plane.json" "$WORK/https-plane.json"
for url in http://plane.example.test http://plane.example.test:8080; do
  planeset 'p.id=require("crypto").randomUUID(); for (const x of p.states) { const n=require("crypto").randomUUID(); for (const i of p.issues) if (i.state===x.id) i.state=n; x.id=n; } for (const i of p.issues) i.project=p.id'
  sed -i.bak "s|^PLANE_URL=.*|PLANE_URL=$url|" "$P/.ai-core/config.env"
  reset_log; ready="$(fields_of)"
  [ "$ready" = "$(planeq 'console.log(p.states.find((s)=>s.name==="ready").id)')" ] || fail "the full URL $url reused another instance's state UUID"
  [ "$(plane_fn project_id)" = "$(planeq 'console.log(p.id)')" ] || fail "the full URL $url reused another instance's project UUID"
  grep -q '/states/' "$CURL_FAKE_STATE/requests.log" || fail "the full URL $url was answered without reading its states"
done
cp "$WORK/https-plane.json" "$CURL_FAKE_STATE/plane.json"
sed -i.bak 's|^PLANE_URL=.*|PLANE_URL=https://plane.example.test|' "$P/.ai-core/config.env"
echo "  full URL cache identity: HTTP, HTTPS and another port on the same host each read fresh project and state UUIDs"
planeset 's.workspace="ws2"; p.id=require("crypto").randomUUID(); for (const x of p.states) { const n=require("crypto").randomUUID(); for (const i of p.issues) if (i.state===x.id) i.state=n; x.id=n; } for (const i of p.issues) i.project=p.id'
sed -i.bak 's|^PLANE_WORKSPACE=.*|PLANE_WORKSPACE=ws2|' "$P/.ai-core/config.env"
second_ready="$(fields_of)"
[ "$second_ready" = "$(planeq 'console.log(p.states.find((s)=>s.name==="ready").id)')" ] || fail "another workspace was answered with the state ids of the first: $second_ready"
[ "$second_ready" != "$first_ready" ] || fail "the state ids of the two workspaces are the same, so the check cannot go red"
[ "$(plane_fn project_id)" = "$(planeq 'console.log(p.id)')" ] || fail "another workspace was answered with the project id of the first"
echo "  the project id and the fields are cached per instance, workspace and identifier: another workspace and another instance each read their own"

# NO UNCALLED CODE in the Plane provider: every function it defines is named somewhere besides its definition
dead_functions() {  # dead_functions <root>
  local f
  for f in $(grep -ho '^[a-z_][a-z_0-9]*()' "$1"/lib/plane/*.sh | tr -d '()'); do
    [ "$(grep -rhw -- "$f" "$1/bin" "$1/lib" "$1/templates" 2>/dev/null | grep -vc "^$f()")" -gt 0 ] || echo "$f"
  done
}
[ -z "$(dead_functions "$ROOT")" ] || fail "the Plane provider defines code nobody calls: $(dead_functions "$ROOT" | paste -sd' ' -)"
printf '\nplane_uncalled_mapper() { echo urgent; }\n' >> "$planted/lib/plane/tracker.sh"
[ "$(dead_functions "$planted")" = plane_uncalled_mapper ] || fail "planted: an uncalled function is not found, so the check cannot go red: $(dead_functions "$planted")"
echo "  the Plane provider defines no function that nothing calls; planted: an uncalled function is found"

reset_log
out="$(plane_fn repo_visibility example-org/example-repo 2>&1)" && fail "Plane invented a visibility guarantee: $out"
grep -q 'cannot establish private destination visibility' <<< "$out" || fail "Plane omitted its visibility limit: $out"
[ ! -s "$CURL_FAKE_STATE/requests.log" ] || fail "Plane visibility invented an API field"
echo "  Plane declares unsupported visibility without fabricating a private result or API field"
echo "all passed"
