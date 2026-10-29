#!/usr/bin/env bash
# What the PermissionRequest hook answers: a deny that names the call in a background session, for a
# command and for a file, and nothing in a session somebody sits at, so the prompt is shown there.
#
#   bash tests/permission-request.test.sh

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failed=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}
bash_call='{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"cd /x/wt && cat -n a.test.tsx","description":"read"}}'
edit_call='{"hook_event_name":"PermissionRequest","tool_name":"Edit","tool_input":{"file_path":"/x/.git/config","old_string":"a","new_string":"b"}}'

echo 'a background session: the prompt is denied, the session goes on, the message names the call'
out="$(CLAUDE_JOB_DIR=/tmp/job bash "$root/bin/permission-request.sh" <<< "$bash_call")"; rc=$?
check 'exit code'                0 "$rc"
check 'the event'                PermissionRequest "$(jq -r '.hookSpecificOutput.hookEventName' <<< "$out")"
check 'the decision'             deny "$(jq -r '.hookSpecificOutput.decision.behavior' <<< "$out")"
check 'the session goes on'      false "$(jq -r '.hookSpecificOutput.decision.interrupt' <<< "$out")"
check 'the command named'        true "$(jq '.hookSpecificOutput.decision.message | contains("Bash `cd /x/wt && cat -n a.test.tsx`")' <<< "$out")"
check 'the way without a prompt' true "$(jq '.hookSpecificOutput.decision.message | contains("the Read tool")' <<< "$out")"
out="$(CLAUDE_JOB_DIR=/tmp/job bash "$root/bin/permission-request.sh" <<< "$edit_call")"
check 'a file call names the file' true "$(jq '.hookSpecificOutput.decision.message | contains("Edit `/x/.git/config`")' <<< "$out")"

echo 'a background session: the question dialog is shown, because a person attached to the session answers it'
ask_call='{"hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which one?","header":"Pick","multiSelect":false,"options":[{"label":"a","description":"a"},{"label":"b","description":"b"}]}]}}'
out="$(CLAUDE_JOB_DIR=/tmp/job bash "$root/bin/permission-request.sh" <<< "$ask_call")"; rc=$?
check 'exit code'                0 "$rc"
check 'no output, so the dialog is shown (planted: it was denied)' '' "$out"

echo 'only the exact question tool name passes through'
while IFS= read -r call; do
  out="$(CLAUDE_JOB_DIR=/tmp/job bash "$root/bin/permission-request.sh" <<< "$call" 2>&1)"; rc=$?
  check "exit code for $call" 0 "$rc"
  check "denied: $call" deny "$(jq -r '.hookSpecificOutput.decision.behavior' <<< "$out" 2>/dev/null)"
done <<'CALLS'
{"tool_name":"PrefixAskUserQuestion"}
{"tool_name":"AskUserQuestionSuffix"}
{"tool_name":"askuserquestion"}
{"tool_name":"AskUserQuestion\n"}
{"tool_name":"AskUserQuestion\u0000"}
{"tool_name":""}
{"tool_name":null}
{"tool_name":["AskUserQuestion"]}
{}
CALLS

echo 'invalid input returns a denial, not a silent or failed hook'
for call in '' 'not JSON' '{' '[]' 'null' '"AskUserQuestion"' \
            '{"tool_name":"AskUserQuestion"} garbage' \
            '{"tool_name":"AskUserQuestion"} {"tool_name":"Bash"}'; do
  out="$(CLAUDE_JOB_DIR=/tmp/job bash "$root/bin/permission-request.sh" <<< "$call" 2>&1)"; rc=$?
  check "exit code for invalid input: $call" 0 "$rc"
  check "invalid input denied: $call" true "$(jq '.hookSpecificOutput | .hookEventName == "PermissionRequest" and .decision.behavior == "deny" and .decision.interrupt == false and (.decision.message | contains("invalid PermissionRequest input"))' <<< "$out" 2>/dev/null)"
done

out="$(printf '{"tool_name":"AskUserQuestion\0"}\n' | CLAUDE_JOB_DIR=/tmp/job bash "$root/bin/permission-request.sh" 2>&1)"; rc=$?
check 'exit code for a literal NUL in JSON' 0 "$rc"
check 'a literal NUL in JSON is denied' deny "$(jq -r '.hookSpecificOutput.decision.behavior' <<< "$out" 2>/dev/null)"

echo 'a session somebody sits at: nothing printed, the prompt is shown'
for call in "$bash_call" "$edit_call" "$ask_call" 'not JSON' ''; do
  out="$(env -u CLAUDE_JOB_DIR bash "$root/bin/permission-request.sh" <<< "$call" 2>&1)"; rc=$?
  check 'exit code without CLAUDE_JOB_DIR' 0 "$rc"
  check 'no output without CLAUDE_JOB_DIR' '' "$out"
  out="$(CLAUDE_JOB_DIR='' bash "$root/bin/permission-request.sh" <<< "$call" 2>&1)"; rc=$?
  check 'exit code with empty CLAUDE_JOB_DIR' 0 "$rc"
  check 'no output with empty CLAUDE_JOB_DIR' '' "$out"
done

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
