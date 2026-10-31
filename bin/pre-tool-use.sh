#!/usr/bin/env bash
# The PreToolUse hook, which init puts into .claude/settings.json. Claude Code runs it before every tool call
# of every session and hands it the call as JSON on standard input. It holds a rule that a script can hold,
# and refuses a call with the JSON that Claude Code reads as a deny, whose reason the session sees:
#
#   after a compaction (rules/80)   until the session has read every rules file whole again, as bin/session-start.sh
#                                   listed them in ~/.ai-core/rules-unread/<session id>, only the Read of a listed file
#                                   passes; the refusal names every file still unread. bin/post-tool-use.sh takes a
#                                   file out of the list when its Read covered it from the first line to the last.
#
# A call that falls under no rule prints nothing and exits 0, which is every call of every session without a
# compaction: no list of any session on the machine ends the hook before anything is parsed.
#
#   pre-tool-use.sh    Claude Code's PreToolUse JSON on standard input
set -uo pipefail

CORE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "${1:-}" in -h|--help) echo "usage: pre-tool-use.sh  (Claude Code's PreToolUse JSON on standard input; refuses a call that the rules after a compaction or a stated time forbid)"; exit 0 ;; esac
input="$(cat)"
. "$CORE/lib/rules-read.sh"
compgen -G "$RULES_UNREAD_DIRECTORY/*" > /dev/null || exit 0

deny() {  # deny <reason>
  jq -nc --arg reason "$1" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
  exit 0
}
fields="$(printf '%s' "$input" | jq -r '[(.session_id // ""), (.tool_name // ""), ((.tool_input.offset // "") | tostring), ((.tool_input.limit // "") | tostring), ((.tool_input.file_path // "") | gsub("\n"; " "))] | .[]' 2>&1)" \
  || deny "Denied: the PreToolUse input is not JSON that this hook can read: ${fields//$'\n'/ }"
{ IFS= read -r session; IFS= read -r tool; IFS= read -r offset; IFS= read -r limit; IFS= read -r path; } <<< "$fields"

unread=""
if record="$(rules_unread_file "$session")" && [ -f "$record" ]; then
  # a listed file that is gone cannot be read, and is no duty
  while IFS= read -r listed; do
    [ ! -f "$listed" ] || unread="$unread$listed"$'\n'
  done < "$record"
  if [ -z "$unread" ]; then
    rm -f "$record"
  elif ! { [ "$tool" = Read ] && [ -n "$path" ] && rules_is_listed "$unread" "$path" && rules_read_is_whole "$path" "$offset" "$limit"; }; then
    deny "Refused: a compaction lost the rules, so read every rules file whole, with no offset and no limit, before any other step. Still unread:"$'\n'"$(printf '%s' "$unread" | sed 's/^/  /')"
  fi
fi

exit 0
