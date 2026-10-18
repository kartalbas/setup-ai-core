#!/usr/bin/env bash
# The issue commands against Plane, one work item at a time: TRACKER=plane in a project whose curl is the
# stand-in of tests/lib.sh. Each shape of defect the acceptance criteria of #184 rule out is planted and
# shown red, and the innocent case beside it green. Nothing here reaches a network.
#
#   bash tests/plane-work-items.test.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export HOME="$WORK/home" AI_CORE_HOME="$WORK/ai-core-home" GH_CACHE_DIRECTORY="$WORK/cache" AI_CORE_SLEEP="$WORK/sleep"
mkdir -p "$HOME" "$AI_CORE_HOME"
printf '#!/bin/sh\necho "$@" >> "%s/slept"\n' "$WORK" > "$WORK/sleep"; chmod +x "$WORK/sleep"
make_curl_fake

printf 'plane-token-0123\n' > "$WORK/token"
P="$WORK/project"; mkdir -p "$P/.ai-core"; git init -q "$P"; git -C "$P" remote add origin https://forge.example.test/example-org/example-repo.git
cat > "$P/.ai-core/config.env" <<CONF
TRACKER=plane
PLANE_URL=https://plane.example.test
PLANE_WORKSPACE=ws
PLANE_PROJECT=ENG
PLANE_TOKEN_COMMAND="cat $WORK/token"
CONF
# ai <command> [args]: bin/<command>.sh of <root> (the real tree unless ROOT_UNDER_TEST names a copy) in the project
ai() { local c="$1"; shift; ( cd "$P" && PATH="$PATH_CURL" bash "${ROOT_UNDER_TEST:-$ROOT}/bin/$c.sh" "$@" ); }
planeq() { node -e "const s=JSON.parse(require('fs').readFileSync('$CURL_FAKE_STATE/plane.json'));const p=s.projects[0];$1"; }
reset_log() { : > "$CURL_FAKE_STATE/requests.log"; : > "$CURL_FAKE_STATE/argv.log"; : > "$CURL_FAKE_STATE/env.log"; }
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

# CLOSE AND REOPEN: one write, and the reason of a not-planned close is kept
reset_log; ai issue-close "$n" >/dev/null || fail "issue-close"
[ "$(planeq 'console.log(p.states.find(s=>s.id===p.issues[0].state).name)')" = done ] || fail "issue-close did not move the work item to done"
ai issue-reopen "$n" >/dev/null || fail "issue-reopen"
[ "$(planeq 'console.log(p.states.find(s=>s.id===p.issues[0].state).name)')" = ready ] || fail "issue-reopen did not move the work item to ready"
ai issue-close --reason not-planned "$n" >/dev/null 2>"$WORK/err" || fail "issue-close --reason not-planned"
[ "$(planeq 'console.log(p.states.find(s=>s.id===p.issues[0].state).name)')" = Cancelled ] || fail "a not-planned close should stand in Cancelled, not be turned into done by the column write after it"
grep -q 'stays Cancelled' "$WORK/err" || fail "the kept Cancelled is not said"
echo "  issue-close: done; issue-reopen: ready; --reason not-planned: Cancelled, kept when the done column is written after it"
ai issue-reopen "$n" >/dev/null || fail "issue-reopen"

# A STATE THE PROJECT LACKS is refused with the states there are, and nothing is written
reset_log; out="$(ai issue-status "$n" nonesuch 2>&1)" && fail "a state the project lacks was accepted"
grep -q "has no option 'nonesuch'. It has: backlog ready planned implementing review testing done Cancelled" <<< "$out" || fail "the states there are are not named: $out"
! grep -q '^PATCH' "$CURL_FAKE_STATE/requests.log" || fail "a refused status still wrote"
ai issue-status "$n" Testing >/dev/null || fail "issue-status Testing (matched without case)"
[ "$(planeq 'console.log(p.states.find(s=>s.id===p.issues[0].state).name)')" = testing ] || fail "issue-status did not move the work item to testing"
echo "  issue-status: a state is matched without case; one the project lacks is refused with the list"

# PRIORITY: P0 to P3 are urgent, high, medium and low
ai issue-priority "$n" P0 >/dev/null || fail "issue-priority"
[ "$(planeq 'console.log(p.issues[0].priority)')" = urgent ] || fail "P0 is not urgent"

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

# THE DOCTOR LINE: the tracker, where it answers, and that the key does, never the key
line="$( cd "$P" && PATH="$PATH_CURL" bash -c 'report() { echo "report $*"; }; problem() { echo problem; }; . "$1/lib/tracker.sh"; tracker_doctor' _ "$ROOT" )"
[ "$line" = "  tracker: plane (https://plane.example.test, the key answers)" ] || fail "the doctor line is '$line'"
printf 'wrong-token\n' > "$WORK/token"
line="$( cd "$P" && PATH="$PATH_CURL" bash -c 'report() { echo "report $*"; }; problem() { echo problem; }; . "$1/lib/tracker.sh"; tracker_doctor' _ "$ROOT" )"
grep -q 'problem' <<< "$line" || fail "a key Plane refuses is no problem for the doctor: $line"
grep -q 'wrong-token' <<< "$line" && fail "the doctor printed the key"
printf 'plane-token-0123\n' > "$WORK/token"
echo "  doctor: tracker: plane (<url>, the key answers), a refused key is a problem, the key is never printed"

echo "all passed"
