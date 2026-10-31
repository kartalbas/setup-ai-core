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
# Each entry has a session id and the folder it works in, and a transcript at <root>/<the folder, every character that is
# no letter or digit a dash>/<session id>.jsonl, as Claude Code keeps it; the root is AI_CORE_TRANSCRIPTS
export AI_CORE_TRANSCRIPTS="$work/transcripts"
dig_id=11111111-aaaa-4aaa-8aaa-000000000001; other_id=11111111-aaaa-4aaa-8aaa-000000000002; live_id=11111111-aaaa-4aaa-8aaa-000000000003
transcript_of() {  # transcript_of <folder under the work folder> <session id>
  printf '%s/%s/%s.jsonl' "$AI_CORE_TRANSCRIPTS" "$(printf '%s' "$work/$1" | sed 's/[^A-Za-z0-9]/-/g')" "$2"
}
healthy() {  # healthy <folder> <session id>: a transcript that has no compaction in it
  mkdir -p "$(dirname "$(transcript_of "$@")")"; printf '{"type":"user","message":{"content":"hello"},"timestamp":"2026-10-19T10:00:00.000Z"}\n' > "$(transcript_of "$@")"
}
healthy dig "$dig_id"; healthy other "$other_id"; healthy live "$live_id"
# The fields as Claude Code writes them: `state` is `working` until a background job is finished,
# also while it waits; `status` is `busy` only while it works
agents() { printf '[{"name":"dig","kind":"background","state":"working","status":"%s","sessionId":"%s","cwd":"%s"},{"name":"other","kind":"background","state":"working","status":"busy","sessionId":"%s","cwd":"%s"}]\n' "$1" "$dig_id" "$work/dig" "$other_id" "$work/other" > "$work/agents.json"; }

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
printf '[{"name":"dig","kind":"interactive","state":null,"status":"idle","sessionId":"%s","cwd":"%s"},{"name":"dig","kind":"background","state":"working","status":"busy","sessionId":"%s","cwd":"%s"}]\n' "$live_id" "$work/live" "$dig_id" "$work/dig" > "$work/agents.json"
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

echo 'a session that compacts in a loop is read from its transcript, however busy it is'
ts() { LC_ALL=C date -u -d "@$(( $(date +%s) - $1 ))" '+%Y-%m-%dT%H:%M:%S.000Z' 2>/dev/null || LC_ALL=C date -u -r "$(( $(date +%s) - $1 ))" '+%Y-%m-%dT%H:%M:%S.000Z'; }
boundary() {  # boundary <seconds ago> <uuid>: the line Claude Code writes when it compacts
  printf '{"type":"system","subtype":"compact_boundary","content":"Conversation compacted","uuid":"%s","timestamp":"%s","sessionId":"%s","compactMetadata":{"trigger":"auto","preTokens":170000}}\n' "$2" "$(ts "$1")" "$dig_id"
}
diagnostic() {  # diagnostic <seconds ago>: the error message Claude Code writes when autocompaction thrashes
  printf '{"type":"assistant","isApiErrorMessage":true,"timestamp":"%s","message":{"model":"<synthetic>","content":[{"type":"text","text":"Autocompact is thrashing: the context refilled to the limit within 3 turns of the previous compact, 3 times in a row."}]}}\n' "$(ts "$1")"
}
chat() {  # chat <role> <text>: an ordinary message that holds the words
  printf '{"type":"%s","timestamp":"%s","message":{"role":"%s","content":[{"type":"text","text":"%s"}]}}\n' "$1" "$(ts 1)" "$1" "$2"
}
dig_transcript="$(transcript_of dig "$dig_id")"
thrashing() { watch 6 --session dig --still 60 --every 1 --heartbeat 100; }   # a session that works, so only its transcript can wake the caller
agents busy

healthy dig "$dig_id"; diagnostic 4 >> "$dig_transcript"
thrashing
check 'the diagnostic wakes within a round' 0 "$rc"
check 'and names the session and the sign' yes "$(grep -Eq '^dig: Claude Code wrote "Autocompact is thrashing" [0-9]+ seconds ago$' <<< "$out" && echo yes || echo "no: $out")"

healthy dig "$dig_id"; { boundary 100 u1; boundary 50 u2; boundary 5 u3; } >> "$dig_transcript"
thrashing
check 'three compactions within 600 seconds wake within a round' 0 "$rc"
check 'and the line gives the count and the window' 'dig: 3 compactions in the last 600 seconds' "$out"

healthy dig "$dig_id"; { boundary 606 u1; boundary 305 u2; boundary 5 u3; } >> "$dig_transcript"
thrashing
check 'three compactions spread over 601 seconds or more stay quiet (innocent)' 124 "$rc"
healthy dig "$dig_id"; boundary 7200 u1 >> "$dig_transcript"
thrashing
check 'one compaction long ago stays quiet (innocent)' 124 "$rc"
spread_while_watching() {  # two compactions in the window, and a third 6 seconds on: the first is then 601 seconds old
  healthy dig "$dig_id"; { boundary 595 u1; boundary 300 u2; } >> "$dig_transcript"
  ( sleep 6; boundary 0 u3 >> "$dig_transcript" ) & writer=$!
}
spread_while_watching
watch 9 --session dig --still 60 --every 1 --heartbeat 100
check 'three compactions spread over 601 seconds while it watches stay quiet (planted)' 124 "$rc"
wait "$writer"
healthy dig "$dig_id"; { boundary 50 u1; boundary 40 u1; boundary 5 u2; } >> "$dig_transcript"
thrashing
check 'one compaction written twice is one compaction (planted)' 124 "$rc"
healthy dig "$dig_id"; { chat user 'Autocompact is thrashing: I quote it'; chat assistant 'Autocompact is thrashing, it said'; } >> "$dig_transcript"
thrashing
check 'the words inside an ordinary message count as nothing (planted)' 124 "$rc"

echo 'a transcript that cannot be read is named, never counted healthy'
rm "$dig_transcript"
thrashing
check 'a missing transcript: exit 1' 1 "$rc"
check 'it names the session and the id' "dig: no transcript $dig_id.jsonl under $AI_CORE_TRANSCRIPTS" "$out"
healthy dig "$dig_id"; chmod 000 "$dig_transcript"
thrashing
check 'an unreadable transcript: exit 1' 1 "$rc"
check 'it names it' yes "$(grep -q "^dig: the transcript $dig_transcript cannot be read" <<< "$out" && echo yes || echo "no: $out")"
chmod 600 "$dig_transcript"
healthy dig "$dig_id"; printf 'not json\n' >> "$dig_transcript"
thrashing
check 'a complete line that is no JSON: exit 1' 1 "$rc"
check 'it names the transcript' yes "$(grep -q "^dig: the transcript $dig_transcript holds a complete line that is not JSON" <<< "$out" && echo yes || echo "no: $out")"
healthy dig "$dig_id"; printf '{"type":"system","subtype":"compact_boundary","uuid":"u1"}\n' >> "$dig_transcript"
thrashing
check 'a compaction with no time: exit 1' 1 "$rc"
check 'it says so' yes "$(grep -q 'holds a compaction with no usable timestamp' <<< "$out" && echo yes || echo "no: $out")"
healthy dig "$dig_id"; mkdir -p "$AI_CORE_TRANSCRIPTS/-elsewhere"; cp "$dig_transcript" "$AI_CORE_TRANSCRIPTS/-elsewhere/$dig_id.jsonl"
thrashing
check 'one id in two folders: exit 1' 1 "$rc"
check 'it counts them' "dig: 2 transcripts named $dig_id.jsonl under $AI_CORE_TRANSCRIPTS" "$out"
rm "$dig_transcript"
thrashing
check 'a transcript in another folder than its cwd names: exit 1' 1 "$rc"
check 'it says where it is' yes "$(grep -q '^dig: its transcript is in -elsewhere, which is not the folder of its cwd ' <<< "$out" && echo yes || echo "no: $out")"
rm -rf "$AI_CORE_TRANSCRIPTS/-elsewhere"; healthy dig "$dig_id"

echo 'a line still being written is read when it is complete'
healthy dig "$dig_id"; { boundary 50 u1; boundary 40 u2; } >> "$dig_transcript"
line="$(boundary 5 u3)"
printf '%s' "${line:0:60}" >> "$dig_transcript"
( sleep 2.5; printf '%s\n' "${line:60}" >> "$dig_transcript" ) & writer=$!
thrashing
check 'the two lines and the half of the third stay quiet, the third wakes: exit 0' 0 "$rc"
check 'with three' 'dig: 3 compactions in the last 600 seconds' "$out"
wait "$writer"

echo 'one name on two entries: each transcript on its own'
printf '[{"name":"dig","kind":"interactive","state":null,"status":"busy","sessionId":"%s","cwd":"%s"},{"name":"dig","kind":"background","state":"working","status":"busy","sessionId":"%s","cwd":"%s"}]\n' "$live_id" "$work/live" "$dig_id" "$work/dig" > "$work/agents.json"
healthy live "$live_id"; healthy dig "$dig_id"
{ boundary 50 u1; boundary 40 u2; } >> "$dig_transcript"; { boundary 30 v1; boundary 20 v2; } >> "$(transcript_of live "$live_id")"
thrashing
check 'two compactions in each of two sessions of one name are four, not three: quiet (innocent)' 124 "$rc"
boundary 10 u3 >> "$dig_transcript"
thrashing
check 'three in one of them wake' 0 "$rc"
check 'and the line names the id' "dig ($dig_id): 3 compactions in the last 600 seconds" "$out"
agents busy

echo 'a transcript that is replaced is read anew, not on from the old position'
replace_transcript() {  # replace_transcript: after 2.5 seconds a longer file takes the place of the transcript, and one more compaction follows
  sleep 2.5
  { printf '{"type":"user","message":{"content":"%0600d"},"timestamp":"%s"}\n' 0 "$(ts 30)"; boundary 20 w1; } > "$work/replacement.jsonl"
  mv "$work/replacement.jsonl" "$dig_transcript"
  sleep 1; boundary 5 w2 >> "$dig_transcript"
}
healthy dig "$dig_id"; { boundary 50 u1; boundary 40 u2; } >> "$dig_transcript"
replace_transcript & writer=$!
thrashing
check 'two compactions in the old file and two in its replacement are not four in one transcript: quiet (planted)' 124 "$rc"
wait "$writer"

echo 'two watchers on one transcript wake once each, with the same count'
healthy dig "$dig_id"; { boundary 50 u1; boundary 40 u2; boundary 5 u3; } >> "$dig_transcript"
for n in 1 2; do ( timeout 8 bash "$root/bin/watch.sh" --session dig --still 60 --every 1 --heartbeat 100 > "$work/watcher$n.out" 2>/dev/null; echo "$?" > "$work/watcher$n.rc" ) & done
wait
check 'both exit 0' '0 0' "$(cat "$work/watcher1.rc") $(cat "$work/watcher2.rc")"
check 'both one line, the same' "dig: 3 compactions in the last 600 seconds|dig: 3 compactions in the last 600 seconds" "$(cut -d' ' -f2- "$work/watcher1.out" | tr '\n' '|' | sed 's/|$//')|$(cut -d' ' -f2- "$work/watcher2.out" | tr '\n' '|' | sed 's/|$//')"

echo 'the default root of the transcripts is under the home of the caller'
mkdir -p "$HOME/.claude"; rm -rf "$HOME/.claude/projects"; cp -R "$AI_CORE_TRANSCRIPTS" "$HOME/.claude/projects"
AI_CORE_TRANSCRIPTS= watch 6 --session dig --still 60 --every 1 --heartbeat 100
check 'read from ~/.claude/projects: three compactions wake' 'dig: 3 compactions in the last 600 seconds' "$out"
rm -rf "$HOME/.claude"

echo 'the help says what is watched, the threshold, the diagnostic, the failure and what is not covered'
help="$(bash "$root/bin/watch.sh" --help | sed 's/^#* *//' | tr '\n' ' ' | tr -s ' ')"
for words in 'three `compact_boundary` lines' 'within the last 600 seconds' '"Autocompact is thrashing"' 'wakes the caller with exit 1 and is named' 'Only Claude Code sessions are covered'; do
  check "the help holds: $words" yes "$(grep -qF "$words" <<< "$help" && echo yes || echo no)"
done

echo 'planted defects in the reader: each turns a case red'
mutant="$work/mutant"
plant() {  # plant <sed script>: a copy of the harness whose transcript reader has one defect
  rm -rf "$mutant"; mkdir -p "$mutant"; cp -R "$root/bin" "$root/lib" "$mutant/"
  sed -i.bak "$1" "$mutant/lib/watch-transcript.mjs"
  cmp -s "$root/lib/watch-transcript.mjs" "$mutant/lib/watch-transcript.mjs" && { echo "  FAIL the planted reader equals the real one: $1"; failed=$((failed + 1)); }
  watch_script="$mutant/bin/watch.sh"
}
planted() { out="$(timeout 6 bash "$watch_script" --session dig --still 60 --every 1 --heartbeat 100 2>/dev/null)"; rc=$?; }
plant 's/state.compactions\[record.uuid\] = seconds;/state.compactions[record.uuid + state.offset] = seconds;/'
healthy dig "$dig_id"; { boundary 50 u1; boundary 40 u1; boundary 5 u2; } >> "$dig_transcript"
planted; check 'a reader that counts lines, not uuids, wakes on one compaction written twice' 0 "$rc"
plant 's/seconds <= NOW - WINDOW/false/'
spread_while_watching
out="$(timeout 9 bash "$watch_script" --session dig --still 60 --every 1 --heartbeat 100 2>/dev/null)"; rc=$?
check 'a reader that keeps every event wakes on a spread of 601 seconds' 0 "$rc"
wait "$writer"
plant 's/record.isApiErrorMessage === true/true/'
healthy dig "$dig_id"; chat assistant 'Autocompact is thrashing, it said' >> "$dig_transcript"
planted; check 'a reader that trusts the words wakes on a quoted phrase' 0 "$rc"
plant 's/state.ino !== stat.ino || //'
healthy dig "$dig_id"; { boundary 50 u1; boundary 40 u2; } >> "$dig_transcript"
replace_transcript & writer=$!
planted; check 'a reader that ignores the inode reads a replaced file on from the old position' yes "$([ "$rc" != 124 ] && echo yes || echo no)"
wait "$writer"
plant 's/failure = `the transcript ${A.file} holds a complete line that is not JSON, at byte ${state.offset}`; break;/state.offset += length; continue;/'
healthy dig "$dig_id"; printf 'not json\n' >> "$dig_transcript"
planted; check 'a reader that skips a line that is no JSON counts the session healthy' 124 "$rc"

echo 'a session that start-phase started: its deadline, its report, its print run, and what a refused report leaves'
# claude lists the session with its agent id and logs every stop; gh answers the thread of the issue and takes the comment
mkdir -p "$work/bin2" "$work/sessions-state"
cat > "$work/bin2/claude" <<EOF
#!/usr/bin/env bash
case "\$1" in stop) printf '%s\n' "\$2" >> "$work/stopped"; exit 0 ;; esac
cat "$work/agents.json"
EOF
cat > "$work/bin2/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
  "repo view"*) echo '{"isPrivate":true}'; exit 0 ;;
  *"--jq .html_url"*)
    [ ! -f "$work/refuse" ] || { echo "refused: \$(cat "$work/refuse")" >&2; exit 1; }
    for a in "\$@"; do case "\$a" in body=@*) cp "\${a#body=@}" "$work/posted" ;; esac; done
    echo "https://example.invalid/o/r/issues/7#issuecomment-77"; exit 0 ;;
  *comments*) cat "$work/comments.json"; exit 0 ;;
  *"repos/o/r/issues/7"*) echo '{"number":7,"title":"The plan","state":"open","labels":[],"body":"plan","created_at":"2026-10-30T08:00:00Z"}'; exit 0 ;;
  *) echo o/r; exit 0 ;;
esac
EOF
chmod +x "$work/bin2/claude" "$work/bin2/gh"
# watch reads the records under ${AI_CORE_HOME:-$HOME}/.ai-core, and a runner of the whole suite exports AI_CORE_HOME
export AI_CORE_HOME="$HOME"
sessions="$HOME/.ai-core/sessions"; mkdir -p "$sessions"
# the key of the key tool acme-key: a made-up string in the scratch home
watch_key='sk-ant-WATCHFAKE-0123456789'
mkdir -p "$HOME/.ai-core/secrets"; chmod 700 "$HOME/.ai-core/secrets"
printf '%s' "$watch_key" > "$HOME/.ai-core/secrets/acme-key"; chmod 600 "$HOME/.ai-core/secrets/acme-key"
chmod 644 "$dig_transcript"; healthy dig "$dig_id"
echo '[]' > "$work/comments.json"
live_agents() { printf '[{"name":"dig","id":"agent-9","kind":"background","state":"working","status":"busy","sessionId":"%s","cwd":"%s"}]\n' "$dig_id" "$work/dig" > "$work/agents.json"; }
record() {  # record <name> <deadline or null> <output> <tool>: the attempt and native lines of a start
  local now; now="$(date +%s)"
  jq -cn --argjson invoked "$((now - 30))" --argjson deadline "$2" --arg output "$3" --arg tool "$4" '{version:1,kind:"attempt",operation:"start",tool:$tool,model:"claude-sonnet-5-5",effort:"high",phase:"build",class:"mechanical",writer:"",invoked:$invoked,observed:$invoked,nativeIdentity:"",issue:"o/r#7",does:"a test",output:$output,deadline:$deadline,measuredSeconds:600,measuredFrom:"build10000-sonnet5.5-high-100k-zzzzz"}' > "$sessions/$1.start.jsonl"
  [ "$3" != none ] || jq -cn --arg id "$dig_id" --argjson invoked "$((now - 30))" '{version:1,kind:"native",operation:"start",tool:"claude",model:"claude-sonnet-5-5",effort:"high",phase:"build",class:"mechanical",writer:"",invoked:$invoked,observed:$invoked,nativeIdentity:$id}' >> "$sessions/$1.start.jsonl"
}
reported_at() { jq -cn --arg name "$1" --arg created "$(date -u -d '+5 seconds' +%Y-%m-%dT%H:%M:%SZ)" '[{user:{login:"a"},created_at:$created,html_url:"https://example.invalid/o/r/issues/7#issuecomment-5",body:"Reported by \($name):\n\nREPORT x"}]' > "$work/comments.json"; }
swatch() { out="$(PATH="$work/bin2:$PATH" timeout "$1" bash "$root/bin/watch.sh" "${@:2}" 2>/dev/null)"; rc=$?; out="${out#[0-9][0-9]:[0-9][0-9] }"; }

live_agents; record dig null none claude
swatch 4 --session dig --still 60 --every 1
check 'unmeasured: no deadline, nothing reported, so still running' 124 "$rc"
record dig "$(( $(date +%s) + 2 ))" none claude
swatch 90 --session dig --still 60 --every 1
check 'a sleeper past its short deadline ends the watch' 0 "$rc"
check 'the line names the worker, the deadline and the measured run' "yes" "$(grep -Eq '^deadline dig: passed at [0-9]{2}:[0-9]{2}, measured 600 seconds from build10000-sonnet5\.5-high-100k-zzzzz$' <<< "$out" && echo yes || echo no)"
record dig "$(( $(date +%s) + 3600 ))" none claude
swatch 4 --session dig --still 60 --every 1
check 'innocent: a deadline an hour away ends nothing' 124 "$rc"

echo 'a report comment ends the watch, stops the session and writes the end record'
rm -f "$work/stopped"; record dig null none claude; echo '[{"user":{"login":"a"},"created_at":"2020-01-01T00:00:00Z","html_url":"https://example.invalid/o/r/issues/7#issuecomment-1","body":"Reported by dig:\n\nan older report"}]' > "$work/comments.json"
swatch 4 --session dig --still 60 --every 1
check 'innocent: a report from before the start is no report' 124 "$rc"
reported_at dig
swatch 90 --session dig --still 60 --every 1
check 'exit 0' 0 "$rc"
check 'the reported line holds the comment URL' 'reported dig: https://example.invalid/o/r/issues/7#issuecomment-5' "$out"
check 'claude stop was called with the agent id' agent-9 "$(cat "$work/stopped" 2>/dev/null)"
check 'the end record is written' 'end https://example.invalid/o/r/issues/7#issuecomment-5' "$(jq -r 'select(.kind == "end") | "end \(.report)"' "$sessions/dig.start.jsonl")"
check 'the end record holds its duration' yes "$(jq -e 'select(.kind == "end") | .duration > 0' "$sessions/dig.start.jsonl" > /dev/null && echo yes || echo no)"
swatch 4 --session dig --still 60 --every 1
check 'a watch of the ended session says so at once' 'reported dig: https://example.invalid/o/r/issues/7#issuecomment-5' "$out"

echo 'a print run is followed by its process, and its output is posted under the first line'
name='build10001-fable5.1-high-100k-abcde'
record "$name" null json acme-key
sleep 0 & dead=$!; wait "$dead"; printf '%s\n' "$dead" > "$sessions/$name.pid"; printf '0\n' > "$sessions/$name.exit"
printf '{"type":"result","result":"the print report","total_cost_usd":0.25,"session_id":"s"}\n' > "$sessions/$name.out"; : > "$sessions/$name.err"
echo '[]' > "$work/comments.json"
swatch 90 --session "$name" --still 60 --every 1
check 'exit 0' 0 "$rc"
check 'the reported line' 'reported '"$name"': https://example.invalid/o/r/issues/7#issuecomment-77' "$out"
check 'the report is posted under the first line' "Reported by $name:" "$(head -n 1 "$work/posted")"
check 'it holds the result of the run' yes "$(grep -qF 'the print report' "$work/posted" && echo yes || echo no)"
check 'the end record holds the cost of the run' 0.25 "$(jq -r 'select(.kind == "end") | .costUsd' "$sessions/$name.start.jsonl")"
check 'the end record says the run gave its report' true "$(jq -r 'select(.kind == "end") | .reported' "$sessions/$name.start.jsonl")"
echo 'a post the tracker refuses ends the watch with the refusal and writes no end record'
name='build10002-fable5.1-high-100k-fffff'
record "$name" null json acme-key
printf '%s\n' "$dead" > "$sessions/$name.pid"; printf '0\n' > "$sessions/$name.exit"
printf '{"type":"result","result":"a report with a time","total_cost_usd":0.1}\n' > "$sessions/$name.out"; : > "$sessions/$name.err"
echo 'stated time is wrong' > "$work/refuse"
swatch 90 --session "$name" --still 60 --every 1
check 'exit 1' 1 "$rc"
check 'the line names the refusal' yes "$(grep -q "^report refused $name: .*stated time is wrong" <<< "$out" && echo yes || echo no)"
check 'no end record' 0 "$(jq -c 'select(.kind == "end")' "$sessions/$name.start.jsonl" | grep -c . || true)"
rm -f "$work/refuse"
echo 'the report of a key run that holds its key is not posted, and the key reaches no line'
for planted in result err; do
  case "$planted" in result) name='build10004-fable5.1-high-100k-ccccc' ;; err) name='build10005-fable5.1-high-100k-ddddd' ;; esac
  record "$name" null json acme-key
  printf '%s\n' "$dead" > "$sessions/$name.pid"; printf '1\n' > "$sessions/$name.exit"
  # PLANTED: the key in the result of the run, and in the last error line of a run that gave no result
  case "$planted" in
    result) jq -cn --arg key "$watch_key" '{type:"result",result:"the environment holds ANTHROPIC_API_KEY=\($key)",total_cost_usd:0.1}' > "$sessions/$name.out"; : > "$sessions/$name.err" ;;
    err) : > "$sessions/$name.out"; printf 'invalid x-api-key %s\n' "$watch_key" > "$sessions/$name.err" ;;
  esac
  rm -f "$work/posted"
  swatch 90 --session "$name" --still 60 --every 1
  check "$planted: exit 1" 1 "$rc"
  check "$planted: the line names the refusal" "report refused $name: the report holds the key of acme-key, so it is not posted" "$out"
  check "$planted: nothing was posted" no "$([ -f "$work/posted" ] && echo yes || echo no)"
  check "$planted: no end record" 0 "$(jq -c 'select(.kind == "end")' "$sessions/$name.start.jsonl" | grep -c . || true)"
done
name='build10006-fable5.1-high-100k-bbbbb'
record "$name" null json acme-key
printf '%s\n' "$dead" > "$sessions/$name.pid"; printf '0\n' > "$sessions/$name.exit"
printf '{"type":"result","result":"a clean report"}\n' > "$sessions/$name.out"; : > "$sessions/$name.err"
mv "$HOME/.ai-core/secrets/acme-key" "$work/acme-key.away"; rm -f "$work/posted"
swatch 90 --session "$name" --still 60 --every 1
mv "$work/acme-key.away" "$HOME/.ai-core/secrets/acme-key"
check 'a key that cannot be read: exit 1' 1 "$rc"
check 'it says the report is not checked and not posted' "report refused $name: the key of acme-key cannot be read, so the report is not checked for it and not posted" "$out"
check 'nothing was posted unchecked' no "$([ -f "$work/posted" ] && echo yes || echo no)"
echo 'a print run that gave no report says so on the issue, and its end record says so too'
name='build10007-fable5.1-high-100k-aaaab'
record "$name" null json acme-key
printf '%s\n' "$dead" > "$sessions/$name.pid"; printf '3\n' > "$sessions/$name.exit"
# PLANTED: an empty output, which jq reads without an error
: > "$sessions/$name.out"; printf 'the model is overloaded\n' > "$sessions/$name.err"
swatch 90 --session "$name" --still 60 --every 1
check 'exit 0' 0 "$rc"
check 'the post says the run gave no report' yes "$(grep -qF 'the run ended with exit status 3 and gave no report: the model is overloaded' "$work/posted" && echo yes || echo no)"
check 'the end record says it gave no report' false "$(jq -r 'select(.kind == "end") | .reported' "$sessions/$name.start.jsonl")"
echo 'a print run that still runs ends nothing'
name='build10003-fable5.1-high-100k-eeeee'
record "$name" null json acme-key
sleep 30 & runner=$!; printf '%s\n' "$runner" > "$sessions/$name.pid"
swatch 4 --session "$name" --still 60 --every 1
check 'still running when the time ran out' 124 "$rc"
kill "$runner" 2>/dev/null; wait "$runner" 2>/dev/null

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
