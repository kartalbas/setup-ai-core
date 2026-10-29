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

echo 'a session somebody sits at: nothing printed, the prompt is shown'
out="$(env -u CLAUDE_JOB_DIR bash "$root/bin/permission-request.sh" <<< "$bash_call")"; rc=$?
check 'exit code'                0 "$rc"
check 'no output'                '' "$out"
out="$(CLAUDE_JOB_DIR='' bash "$root/bin/permission-request.sh" <<< "$bash_call")"
check 'an empty CLAUDE_JOB_DIR is no background session' '' "$out"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
