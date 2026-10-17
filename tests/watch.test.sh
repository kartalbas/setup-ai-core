#!/usr/bin/env bash
# What `watch` wakes its caller for: a session that stopped working, a ref that moved, the heartbeat,
# and a failed fetch or session list; and that it stays quiet while a session works and no ref moves.
# `claude` is a stand-in that prints a session list the test writes; the clone's origin is a folder.
#
#   bash tests/watch.test.sh

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export HOME="$work/home"
mkdir -p "$HOME" "$work/bin"
# It also prints a notice on stderr, as a tool that runs fine may: that is no part of the list
printf '#!/usr/bin/env bash\n[ -f "%s/agents.json" ] || { echo "no session list" >&2; exit 1; }\necho "a notice" >&2\ncat "%s/agents.json"\n' "$work" "$work" > "$work/bin/claude"
chmod +x "$work/bin/claude"
export PATH="$work/bin:$PATH"
# The fields as Claude Code writes them: `state` is `working` until a background job is finished,
# also while it waits; `status` is `busy` only while it works
agents() { printf '[{"name":"dig","kind":"background","state":"working","status":"%s"},{"name":"other","kind":"background","state":"working","status":"busy"}]\n' "$1" > "$work/agents.json"; }

failed=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}
git_() { git -c user.name=test -c user.email=test@example.invalid "$@"; }
git_ init -q -b master "$work/seed" && git_ -C "$work/seed" commit -q --allow-empty -m one
git clone -q --bare "$work/seed" "$work/origin.git" && git clone -q "$work/origin.git" "$work/clone"
first="$(git -C "$work/clone" rev-parse origin/master)"
# The line is on stdout. stderr stays out: `timeout` ends the whole process group, and bash may report
# its killed `sleep` there as "Terminated", or not, by the order the two die in
watch() { out="$(timeout "$1" bash "$root/bin/watch.sh" "${@:2}" 2>/dev/null)"; rc=$?; out="${out#[0-9][0-9]:[0-9][0-9] }"; }

echo 'nothing moves and the session works: no return'
agents busy
watch 4 --session dig --ref "$work/clone:origin/master" --still 2 --every 1 --heartbeat 60
check 'still running when the time ran out' 124 "$rc"
check 'and said nothing'                    '' "$out"

echo 'idle for less than --still, then busy again: no return'
agents busy; ( sleep 1; agents idle; sleep 1.5; agents busy ) &
watch 6 --session dig --still 4 --every 1
check 'still running when the time ran out' 124 "$rc"
check 'and said nothing'                    '' "$out"
wait

echo 'one name on an idle interactive entry and a busy background one: no return'
printf '[{"name":"dig","kind":"interactive","state":null,"status":"idle"},{"name":"dig","kind":"background","state":"working","status":"busy"}]\n' > "$work/agents.json"
watch 4 --session dig --still 2 --every 1
check 'still running when the time ran out' 124 "$rc"

echo 'the session stops working'
agents busy; ( sleep 1; agents idle ) &
watch 10 --session dig --session other --still 2 --every 1
check 'exit 0'        0 "$rc"
check 'it names it'   'dig is idle and has not been busy for 0 minutes' "$out"
agents busy
echo 'the session leaves the list'
printf '[]\n' > "$work/agents.json"
watch 10 --session dig --still 2 --every 1
check 'it says gone'  'dig is gone and has not been busy for 0 minutes' "$out"

echo 'the ref moves'
agents busy
( sleep 1; git_ -C "$work/seed" commit -q --allow-empty -m two; git -C "$work/seed" push -q "$work/origin.git" master ) &
watch 10 --session dig --ref "$work/clone:origin/master" --still 60 --every 1
second="$(git -C "$work/clone" rev-parse origin/master)"
check 'exit 0'        0 "$rc"
check 'it names it'   "$work/clone:origin/master moved: ${first:0:9} -> ${second:0:9}" "$out"

echo 'the heartbeat'
watch 10 --session dig --ref "$work/clone:origin/master" --still 60 --every 1 --heartbeat 2
check 'exit 0'        0 "$rc"
check 'every status'  "heartbeat after 0 minutes: $work/clone:origin/master at ${second:0:9}; dig busy, 0 minutes since it was busy" "$out"

echo 'a failed session list and a failed fetch'
rm "$work/agents.json"
watch 10 --session dig --every 1
check 'exit 1'        1 "$rc"
check 'it names it'   'claude agents failed: no session list' "$out"
mv "$work/origin.git" "$work/gone.git"
watch 10 --ref "$work/clone:origin/master" --every 1
check 'exit 1'        1 "$rc"
check 'it names it'   yes "$(case "$out" in "$work/clone: the fetch failed: "*) echo yes ;; *) echo "no: $out" ;; esac)"
mv "$work/gone.git" "$work/origin.git"

echo 'wrong arguments'
watch 5 --every 1;                                            check 'nothing to watch: exit 2'        2 "$rc"
watch 5 --session dig --every 0;                              check 'zero seconds: exit 2'            2 "$rc"
watch 5 --ref "$work/clone";                                  check 'a ref without its clone: exit 2' 2 "$rc"
watch 5 --ref "$work/clone:origin/none" --every 1;            check 'a ref that names nothing: exit 2' 2 "$rc"
watch 5 --session;                                            check 'an option without value: exit 2' 2 "$rc"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
