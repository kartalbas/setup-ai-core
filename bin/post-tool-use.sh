#!/usr/bin/env bash
# The PostToolUse hook for the Read tool, which init puts into .claude/settings.json. After a compaction
# bin/pre-tool-use.sh refuses every call of a session until it has read each rules file in
# ~/.ai-core/rules-unread/<session id>; this hook takes a file out of that list once a Read of it has covered it from
# its first line to its last, by the same judgement (lib/rules-read.sh), and the list goes with its last file. A Read
# of one span of a file leaves it listed. It never refuses and prints nothing.
#
#   post-tool-use.sh    Claude Code's PostToolUse JSON on standard input
set -uo pipefail

CORE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "${1:-}" in -h|--help) echo "usage: post-tool-use.sh  (Claude Code's PostToolUse JSON on standard input; marks a rules file read whole after a compaction)"; exit 0 ;; esac
input="$(cat)"
. "$CORE/lib/rules-read.sh"
compgen -G "$RULES_UNREAD_DIRECTORY/*" > /dev/null || exit 0

fields="$(printf '%s' "$input" | jq -r '[(.session_id // ""), (.agent_id // "" | tostring), (.tool_name // ""), ((.tool_input.offset // "") | tostring), ((.tool_input.limit // "") | tostring), ((.tool_input.file_path // "") | gsub("\n"; " "))] | .[]' 2>/dev/null)" \
  || { echo "post-tool-use: the PostToolUse input is not JSON this hook can read" >&2; exit 1; }
{ IFS= read -r session; IFS= read -r agent; IFS= read -r tool; IFS= read -r offset; IFS= read -r limit; IFS= read -r path; } <<< "$fields"
# A subagent's Read carries the session id of the session that started it (agent_id names it), and is no read of that session
[ -z "$agent" ] && [ "$tool" = Read ] && [ -n "$path" ] || exit 0
record="$(rules_unread_file "$session")" && [ -f "$record" ] || exit 0
if rules_is_listed "$(cat "$record")" "$path" && rules_read_is_whole "$path" "$offset" "$limit"; then rules_unread_remove "$session" "$path"; fi
exit 0
