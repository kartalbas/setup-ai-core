#!/usr/bin/env bash
# The status line command, which graft-setup puts into .claude/settings.json. Claude Code hands it
# the session's state as JSON on standard input; the account's usage windows in it, rate_limits
# with used_percentage and resets_at per window, are recorded in ~/.ai-core/usage.json, where
# `ai-core usage` reads them for every session of the machine. Then Graft's status line runs on the
# same input, as before; without it a short line of the model and the windows is shown.
#
#   statusline.sh            Claude Code's status line JSON on standard input
set -uo pipefail

case "${1:-}" in -h|--help) echo "usage: statusline.sh  (Claude Code's status line JSON on standard input)"; exit 0 ;; esac
input="$(cat)"
home="${AI_CORE_HOME:-$HOME}"
limits="$(jq -c '.rate_limits // {}' <<< "$input" 2>/dev/null || echo '{}')"
if [ -n "$limits" ] && [ "$limits" != '{}' ]; then
  mkdir -p "$home/.ai-core"
  printf '{"recorded_at":%s,"rate_limits":%s}\n' "$(date +%s)" "$limits" > "$home/.ai-core/usage.json.$$" \
    && mv -f "$home/.ai-core/usage.json.$$" "$home/.ai-core/usage.json"
  # The history, at most one line a minute, so `ai-core status` can measure what a closed issue
  # costs of a window: <epoch> <five-hour %> <its reset> <weekly %> <its reset>
  log="$home/.ai-core/usage.log"; now="$(date +%s)"
  last="$(tail -n1 "$log" 2>/dev/null | cut -d' ' -f1)"
  if [ "$((now - ${last:-0}))" -ge 60 ]; then
    jq -r --arg t "$now" '"\($t) \(.five_hour.used_percentage // "-") \(.five_hour.resets_at // "-") \(.seven_day.used_percentage // "-") \(.seven_day.resets_at // "-")"' <<< "$limits" >> "$log"
  fi
fi
graft="${CLAUDE_PROJECT_DIR:-.}/.claude/helpers/graft-statusline.cjs"
if [ -f "$graft" ] && command -v node >/dev/null 2>&1; then
  node "$graft" <<< "$input"
else
  jq -r '[(.model.display_name // empty), (.rate_limits.five_hour.used_percentage // empty | "5h \(floor) %"), (.rate_limits.seven_day.used_percentage // empty | "week \(floor) %")] | join(" · ")' <<< "$input" 2>/dev/null || true
fi
