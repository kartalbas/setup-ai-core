#!/usr/bin/env bash
# What the PreToolUse hook refuses and lets through. After a compaction, with the list of unread rules files that
# bin/session-start.sh wrote: every call but the whole read of a listed file is refused, naming each file still unread,
# and once the list is empty the hook is silent. A message to another session that says a time the clock does not show
# is refused, naming both times. A session with no list and no such message gets no output at all.
#
#   bash tests/pre-tool-use.test.sh

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export HOME="$work/home" AI_CORE_HOME="$work/core"; mkdir -p "$HOME" "$AI_CORE_HOME"
unset STATED_TIME_ZONE STATED_TIME_ZONE_WORDS STATED_TIME_TOLERANCE_MINUTES TZ
failed=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}
hook="$root/bin/pre-tool-use.sh"
records="$AI_CORE_HOME/.ai-core/rules-unread"
rules="$work/rules"; mkdir -p "$rules"
printf 'one\ntwo\nthree\n' > "$rules/a.md"; printf 'only\n' > "$rules/b.md"
seq 1 3000 > "$rules/long.md"
# record <session>: the two files unread, as session-start writes them
record() { mkdir -p "$records"; printf '%s\n%s\n' "$rules/a.md" "$rules/b.md" > "$records/$1"; }
bash_call() { jq -nc --arg s "$1" '{session_id: $s, hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: "ls"}, cwd: "/"}'; }
read_call() {  # read_call <session> <file> [offset] [limit]
  jq -nc --arg s "$1" --arg f "$2" --arg o "${3:-}" --arg l "${4:-}" '{session_id: $s, hook_event_name: "PreToolUse", tool_name: "Read", tool_input: ({file_path: $f} + (if $o != "" then {offset: ($o | tonumber)} else {} end) + (if $l != "" then {limit: ($l | tonumber)} else {} end)), cwd: "/"}'
}
message_call() { jq -nc --arg s "$1" --arg m "$2" '{session_id: $s, hook_event_name: "PreToolUse", tool_name: "SendMessage", tool_input: {to: "worker", summary: "report", message: $m}, cwd: "/"}'; }
# verdict <input>: "silent" for exit 0 with no output, else "deny: <reason>"
verdict() {
  local out rc
  out="$(bash "$hook" <<< "$1" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then echo "exit $rc: $out"
  elif [ -z "$out" ]; then echo silent
  else echo "$(jq -r '.hookSpecificOutput | .permissionDecision + ": " + .permissionDecisionReason' <<< "$out")"; fi
}
reason_after() { echo "deny: Refused: a compaction lost the rules, so read every rules file whole, with no offset and no limit, before any other step. Still unread:"; }

echo 'a session that did not compact: no output, with no list on the machine and with the list of another session'
check 'a Bash call, no list at all' silent "$(verdict "$(bash_call s1)")"
record other
check 'a Bash call, only another session has a list' silent "$(verdict "$(bash_call s1)")"
rm -rf "$records"

echo 'after a compaction: every call but the whole read of a listed file is refused, naming each unread file'
record s1
check 'a Bash call is refused and names both files' "$(reason_after)"$'\n'"  $rules/a.md"$'\n'"  $rules/b.md" "$(verdict "$(bash_call s1)")"
check 'a Read of another file is refused' "$(reason_after)"$'\n'"  $rules/a.md"$'\n'"  $rules/b.md" "$(verdict "$(read_call s1 "$work/other.md")")"
check 'a Read with a limit shorter than the file is refused' "$(reason_after)"$'\n'"  $rules/a.md"$'\n'"  $rules/b.md" "$(verdict "$(read_call s1 "$rules/a.md" '' 2)")"
check 'a Read from an offset is refused' "$(reason_after)"$'\n'"  $rules/a.md"$'\n'"  $rules/b.md" "$(verdict "$(read_call s1 "$rules/a.md" 2)")"
check 'a Write is refused' "$(reason_after)"$'\n'"  $rules/a.md"$'\n'"  $rules/b.md" "$(verdict "$(jq -nc '{session_id: "s1", tool_name: "Write", tool_input: {file_path: "/x/y"}}')")"
check 'another session, with no list of its own, is let through' silent "$(verdict "$(bash_call s2)")"

echo 'after a compaction: the whole read of a listed file passes, by any name that leads to it'
check 'a Read with no offset and no limit' silent "$(verdict "$(read_call s1 "$rules/a.md")")"
check 'a Read from line 1 with a limit that covers the file' silent "$(verdict "$(read_call s1 "$rules/a.md" 1 3)")"
check 'a Read with a limit above the length' silent "$(verdict "$(read_call s1 "$rules/b.md" '' 2000)")"
ln -s "$rules/b.md" "$work/link.md"
check 'a Read through a link' silent "$(verdict "$(read_call s1 "$work/link.md")")"
check 'a Read by a path with .. in it' silent "$(verdict "$(read_call s1 "$rules/../rules/a.md")")"

echo 'a file longer than a default read is not read whole by a Read without a limit'
printf '%s\n' "$rules/long.md" > "$records/s1"
check 'no limit, 3000 lines: refused' "$(reason_after)"$'\n'"  $rules/long.md" "$(verdict "$(read_call s1 "$rules/long.md")")"
check 'limit 2500, 3000 lines: refused' "$(reason_after)"$'\n'"  $rules/long.md" "$(verdict "$(read_call s1 "$rules/long.md" '' 2500)")"
check 'limit 3000: passes' silent "$(verdict "$(read_call s1 "$rules/long.md" '' 3000)")"

echo 'the list that no file is left in is silent, and goes'
printf '%s\n' "$rules/gone.md" > "$records/s1"
check 'a list of files that no longer exist is no duty' silent "$(verdict "$(bash_call s1)")"
check 'and the record is removed' no "$([ -e "$records/s1" ] && echo yes || echo no)"
record s1; rm "$rules/b.md"
check 'one of two files gone: the other is named alone' "$(reason_after)"$'\n'"  $rules/a.md" "$(verdict "$(bash_call s1)")"
printf 'only\n' > "$rules/b.md"

echo 'input the hook cannot read, and a session id that could name another place'
record s1
out="$(verdict 'not json')"
check 'invalid JSON with a list present is refused' true "$([[ "$out" == "deny: Denied: the PreToolUse input is not JSON"* ]] && echo true || echo "$out")"
check 'a session id with a slash passes: it names no list' silent "$(verdict "$(bash_call '../../x')")"

echo 'a stated time in a message to another session'
export AI_CORE_NOW="$(date -u -d '2026-10-31 12:00:00' +%s)"
rm -rf "$records"
check 'a wrong time is refused and names both' 'deny: Refused: SendMessage to worker: the text says 13:10 UTC, the clock there shows 12:00 (UTC)' "$(verdict "$(message_call s1 'Landed at 13:10 UTC.')")"
check 'the clock'"'"'s time passes' silent "$(verdict "$(message_call s1 'Landed at 12:01 UTC.')")"
check 'a time with its date passes' silent "$(verdict "$(message_call s1 'Landed on 2026-10-30 at 09:10 UTC.')")"
check 'a message with no time passes' silent "$(verdict "$(message_call s1 'Done.')")"
check 'a wrong time in the summary is refused too' 'deny: Refused: SendMessage to worker: the text says 09:00 UTC, the clock there shows 12:00 (UTC)' "$(verdict "$(jq -nc '{session_id: "s1", tool_name: "SendMessage", tool_input: {to: "worker", summary: "at 09:00 UTC", message: "ok"}, cwd: "/"}')")"
check 'a Bash call that writes a wrong time is not judged' silent "$(verdict "$(jq -nc '{session_id: "s1", tool_name: "Bash", tool_input: {command: "echo 13:10 UTC"}, cwd: "/"}')")"
mkdir -p "$work/project/.ai-core"; git init -q "$work/project"
printf 'STATED_TIME_ZONE="Europe/Zurich"\nSTATED_TIME_ZONE_WORDS="Zurich"\n' > "$work/project/.ai-core/config.env"
call="$(jq -nc --arg d "$work/project" '{session_id: "s1", tool_name: "SendMessage", tool_input: {to: "worker", message: "Landed at 13:02 Zurich."}, cwd: $d}')"
check 'the zone comes from the config.env of the call'"'"'s folder: the clock there passes' silent "$(verdict "$call")"
call="$(jq -nc --arg d "$work/project" '{session_id: "s1", tool_name: "SendMessage", tool_input: {to: "worker", message: "Landed at 12:02 Zurich."}, cwd: $d}')"
check 'and an hour off is refused' 'deny: Refused: SendMessage to worker: the text says 12:02 Zurich, the clock there shows 13:00 (Europe/Zurich)' "$(verdict "$call")"
record s1
check 'after a compaction the unread files come first, even for a message with the right time' "$(reason_after)"$'\n'"  $rules/a.md"$'\n'"  $rules/b.md" "$(verdict "$(message_call s1 'Done.')")"
rm -rf "$records"

echo 'planted: a hook that never refuses lets the Bash call through, so the refusals above are what turn red'
mutant="$work/mutant"; mkdir -p "$mutant/bin"; cp -R "$root/lib" "$mutant/"; cp "$hook" "$mutant/bin/"
sed -i.bak 's/^    deny "Refused: a compaction/    : "Refused: a compaction/' "$mutant/bin/pre-tool-use.sh"
cmp -s "$hook" "$mutant/bin/pre-tool-use.sh" && { echo '  FAIL the planted copy equals bin/pre-tool-use.sh'; failed=$((failed + 1)); }
record s1
out="$(bash "$mutant/bin/pre-tool-use.sh" <<< "$(bash_call s1)" 2>&1)"
check 'the Bash call passes in the planted copy' '' "$out"

echo 'the hook with no list on the machine ends before it parses anything'
rm -rf "$records"
out="$(bash "$hook" <<< 'not json at all' 2>&1)"; rc=$?
check 'unreadable input, no list: exit code' 0 "$rc"
check 'unreadable input, no list: no output' '' "$out"
out="$(bash "$hook" --help)"; rc=$?
check '--help: exit code' 0 "$rc"
check '--help names the hook' true "$([[ "$out" == "usage: pre-tool-use.sh"* ]] && echo true || echo "$out")"

if [ "$failed" -ne 0 ]; then echo "$failed failed"; exit 1; fi
echo 'all passed'
