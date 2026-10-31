#!/usr/bin/env bash
# The PreToolUse hook, which init puts into .claude/settings.json. Claude Code runs it before every tool call
# of every session and hands it the call as JSON on standard input. It holds two rules that a script can hold,
# and refuses a call with the JSON that Claude Code reads as a deny, whose reason the session sees:
#
#   after a compaction (rules/80)   until the session has read every rules file whole again, as bin/session-start.sh
#                                   listed them in ~/.ai-core/rules-unread/<session id>, only the Read of a listed file
#                                   passes; the refusal names every file still unread. bin/post-tool-use.sh takes a
#                                   file out of the list when its Read covered it from the first line to the last.
#   a stated time (rules/10)        a message to another session (the SendMessage tool) whose text says a clock time with
#                                   a zone word that the clock in that zone does not show is refused, naming both.
#
# A call that falls under neither rule prints nothing and exits 0, which is every call of every session without a
# compaction and without a message: no list of any session on the machine and no SendMessage in the input end the
# hook before anything is parsed.
#
#   pre-tool-use.sh    Claude Code's PreToolUse JSON on standard input
set -uo pipefail

CORE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "${1:-}" in -h|--help) echo "usage: pre-tool-use.sh  (Claude Code's PreToolUse JSON on standard input; refuses a call that the rules after a compaction or a stated time forbid)"; exit 0 ;; esac
input="$(cat)"
. "$CORE/lib/rules-read.sh"
if ! compgen -G "$RULES_UNREAD_DIRECTORY/*" > /dev/null; then
  case "$input" in *SendMessage*) ;; *) exit 0 ;; esac
fi

deny() {  # deny <reason>
  jq -nc --arg reason "$1" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
  exit 0
}
fields="$(printf '%s' "$input" | jq -r '[(.session_id // ""), (.agent_id // "" | tostring), (.tool_name // ""), ((.tool_input.offset // "") | tostring), ((.tool_input.limit // "") | tostring), (.cwd // ""), ((.tool_input.file_path // "") | gsub("\n"; " "))] | .[]' 2>&1)" \
  || deny "Denied: the PreToolUse input is not JSON that this hook can read: ${fields//$'\n'/ }"
{ IFS= read -r session; IFS= read -r agent; IFS= read -r tool; IFS= read -r offset; IFS= read -r limit; IFS= read -r folder; IFS= read -r path; } <<< "$fields"

unread=""
# A subagent carries the session id of the session that started it (agent_id names it): its context was not compacted
if [ -z "$agent" ] && record="$(rules_unread_file "$session")" && [ -f "$record" ]; then
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

if [ "$tool" = SendMessage ]; then
  [ -z "$folder" ] || [ ! -d "$folder" ] || cd "$folder" || deny "Denied: the folder of the call, $folder, cannot be entered, so the settings of the stated-time check cannot be read"
  . "$CORE/lib/stated-time.sh"
  text="$(printf '%s' "$input" | jq -r '[(.tool_input.summary // ""), (.tool_input.message // "")] | join("\n")')"
  destination="$(printf '%s' "$input" | jq -r '.tool_input.to // "another session"')"
  refusal="$(check_stated_time SendMessage "$destination" "$text" 2>&1)" || deny "Refused: $refusal"
fi
exit 0
