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


echo 'file growth uses an independent inactivity clock and parsed final events'
file="$work/output file.jsonl"; other="$work/other.jsonl"
printf '%s\n' '{"type":"thread.started","thread_id":"fixture"}' > "$file"
watch 9 --file "$file" --still 2 --every 1 --heartbeat 60
check 'stalled file wakes' 0 "$rc"
check 'stalled file names path and minutes' yes "$(grep -qF "$file has not grown for 0 minutes" <<< "$out" && echo yes || echo no)"
# Use the full observed completion record, rather than an invented external event schema.
completed='{"type":"turn.completed","usage":{"input_tokens":2321047,"cached_input_tokens":2174976,"cache_write_input_tokens":0,"output_tokens":21658,"reasoning_output_tokens":11479}}'
printf '  %s  \n' "$completed" > "$file"
watch 5 --file "$file" --still 1 --every 1 --heartbeat 60
check 'parsed completion stays quiet' 124 "$rc"; check 'completion no event output' '' "$out"
for event in '' '{"type":"item.completed","item":{"type":"agent_message","text":"turn.completed"}}' '{"type":"turn.completed"' '{"type":"turn.failed","error":{"message":"fixture failure"}}' 'not JSON' '{"type":"turn.completed"} {"type":"turn.completed"}'; do
 printf '%s\n' "$event" > "$file"
 watch 8 --file "$file" --still 1 --every 1 --heartbeat 60
 check "unfinished or nested event wakes: $event" 0 "$rc"
 check 'not mistaken for completion' yes "$(grep -qF "$file has not grown" <<< "$out" && echo yes || echo no)"
done
printf 'start\n' > "$file"
( for n in 1 2 3 4 5 6 7 8; do sleep 0.5; printf '%s\n' "$n" >> "$file"; done ) & appender=$!
watch 4 --file "$file" --still 2 --every 1 --heartbeat 60
check 'growing file stays quiet' 124 "$rc"; check 'growing file no output' '' "$out"
wait "$appender"
printf 'still\n' > "$other"
( for n in 1 2 3 4 5 6; do sleep 0.5; printf '%s\n' "$n" >> "$file"; done ) & appender=$!
watch 8 --file "$file" --file "$other" --still 2 --every 1 --heartbeat 60
check 'growth does not hide another stalled file' yes "$(grep -qF "$other has not grown" <<< "$out" && echo yes || echo no)"
wait "$appender"
printf '%s\n' "$completed" > "$file"; printf 'active\n' > "$other"; agents busy
bytes="$(wc -c < "$file" | tr -d ' ')"
watch 9 --session dig --ref "$work/clone:origin/master" --file "$file" --file "$other" --still 60 --every 1 --heartbeat 2
check 'mixed heartbeat' 0 "$rc"
for target in "$file, $bytes bytes, 0 minutes since growth" "$other, 7 bytes, 0 minutes since growth" 'dig busy' "$work/clone:origin/master at"; do
 check "heartbeat target $target" yes "$(grep -qF "$target" <<< "$out" && echo yes || echo no)"
done
for argument in "$work/absent" "$work"; do watch 5 --file "$argument" --every 1; check 'invalid file argument' 2 "$rc"; done
watch 5 --file; check 'file without value' 2 "$rc"
printf 'initial\n' > "$other"; chmod 000 "$other"
watch 5 --file "$other" --every 1; check 'unreadable file argument' 2 "$rc"; chmod 600 "$other"
printf 'initial\n' > "$other"; ( sleep 0.5; rm "$other" ) & remover=$!
watch 6 --file "$other" --every 1; check 'file lost after validation' 1 "$rc"
check 'lost file named' yes "$(grep -qF "$other" <<< "$out" && echo yes || echo no)"; wait "$remover"
# No invalid file invocation may fetch, even if a ref appears first.
mkdir -p "$work/gitbin"
printf '#!/usr/bin/env bash\nprintf "called\\n" >> "%s/git-calls"\nexit 9\n' "$work" > "$work/gitbin/git"; chmod +x "$work/gitbin/git"
PATH="$work/gitbin:$PATH" watch 5 --ref "$work/clone:origin/master" --file "$work/absent" --every 1
check 'invalid file refuses before ref fetch' 2 "$rc"
check 'invalid file no side effects' no "$([ -e "$work/git-calls" ] && echo yes || echo no)"
# Mutants prove the deadlines, completion parser and heartbeat target checks can go red.
watch_script="$work/mutant-watch.sh"
printf 'still\n' > "$other"
sed 's/if \[ "$size" -gt "${sizes\[\$i\]}" \]; then/if true; then/' "$root/bin/watch.sh" > "$watch_script"
mutant_watch() { out="$(timeout "$1" bash "$watch_script" "${@:2}" 2>/dev/null)"; rc=$?; }
mutant_watch 4 --file "$other" --still 2 --every 1 --heartbeat 60
check 'reset-on-read mutant fails stalled deadline' 124 "$rc"
sed 's/if \[ "$size" -gt "${sizes\[\$i\]}" \]; then/if false; then/' "$root/bin/watch.sh" > "$watch_script"
( for n in 1 2 3 4 5 6; do sleep 0.5; printf '%s\n' "$n" >> "$other"; done ) & appender=$!
mutant_watch 6 --file "$other" --still 2 --every 1 --heartbeat 60
check 'never-reset mutant wakes growing file' 0 "$rc"; wait "$appender"
# A parser replaced with a substring search must suppress the planted nested word.
sed 's/jq -se .*2>\/dev\/null/grep -q turn.completed/' "$root/bin/watch.sh" > "$watch_script"
printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"turn.completed"}}' > "$other"
mutant_watch 4 --file "$other" --still 1 --every 1 --heartbeat 60
check 'substring completion mutant hides unfinished output' 124 "$rc"
# Shrinkage is not activity, and a later append below the old high-water mark is still growth.
printf '%0100d\n' 0 > "$other"
( sleep 0.5; : > "$other" ) & shrinker=$!
watch 7 --file "$other" --still 2 --every 1 --heartbeat 60
check 'shrink does not reset growth clock' 0 "$rc"; wait "$shrinker"
printf '%0100d\n' 0 > "$other"
( sleep 0.3; : > "$other"; sleep 1; for n in 1 2 3 4 5 6; do printf 'x' >> "$other"; sleep 0.5; done ) & appender=$!
watch 4 --file "$other" --still 3 --every 1 --heartbeat 60
check 'append after shrink below old size resets clock' 124 "$rc"; wait "$appender"
printf '%s\n' "$completed" > "$file"; printf '%s\n' "$completed" > "$other"
sed '/report="$report; ${files\[\$i\]}/d' "$root/bin/watch.sh" > "$watch_script"
cmp -s "$watch_script" "$root/bin/watch.sh" && { echo '  FAIL heartbeat mutant unchanged'; failed=$((failed+1)); }
mutant_watch 7 --file "$file" --file "$other" --still 60 --every 1 --heartbeat 2
check 'omitted-file heartbeat mutant is caught' no "$(grep -qF "$file," <<< "$out" && echo yes || echo no)"
printf 'initial\n' > "$other"; ( sleep 0.5; chmod 000 "$other" ) & changer=$!
watch 6 --file "$other" --every 1; check 'file becomes unreadable at runtime' 1 "$rc"; wait "$changer"; chmod 600 "$other"
echo 'file watcher stalled/growing/completed, target-set, validation, and mutation checks finished'

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
