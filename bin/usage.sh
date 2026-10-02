#!/usr/bin/env bash
# What the account's usage windows stand at, as the status line last recorded them, and whether one
# has reached the limit at which every session finishes the step in hand and waits for its reset.
#
#   usage.sh [--stop-at N]     N percent; else USAGE_STOP_AT of the project's config.env; else 92
#
# Exit 0: every window below N. Exit 3: a window at N or more. Exit 2: nothing recorded yet, or a
# wrong argument. A window whose reset time has passed counts as reset. One model's own weekly quota
# is not among the windows Claude Code hands the status line, so it is not here either.
set -uo pipefail

usage="usage: usage.sh [--stop-at N]"
config="$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.ai-core/config.env"
stop="$(grep -E '^[[:space:]]*USAGE_STOP_AT[[:space:]]*=' "$config" 2>/dev/null | tail -n1 || true)"
stop="${stop#*=}"; stop="${stop%%#*}"; stop="${stop//[[:space:]\"\']/}"; stop="${stop:-92}"
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) echo "$usage"; exit 0 ;;
    --stop-at) stop="${2:-}"; shift 2 || { echo "error: --stop-at takes a percentage - $usage" >&2; exit 2; } ;;
    *) echo "error: unknown argument '$1' - $usage" >&2; exit 2 ;;
  esac
done
case "$stop" in ''|*[!0-9]*) echo "error: --stop-at takes a whole percentage, not '$stop'" >&2; exit 2 ;; esac
file="${AI_CORE_HOME:-$HOME}/.ai-core/usage.json"
[ -f "$file" ] || { echo "no usage recorded yet: the status line records it once a session has had an answer" >&2; exit 2; }
when() { LC_ALL=C date -d "@$1" '+%a %H:%M' 2>/dev/null || LC_ALL=C date -r "$1" '+%a %H:%M'; }
now="$(date +%s)"; reached=0
while IFS=$'\t' read -r name used resets; do
  [ -n "$name" ] || continue
  if [ "$resets" -gt 0 ] && [ "$resets" -le "$now" ]; then used=0; note="reset since $(when "$resets")"; else note="resets $(when "$resets")"; fi
  printf '%-10s %3d %%  %s\n' "$name" "$(awk -v u="$used" 'BEGIN { printf "%d", u }')" "$note"
  awk -v u="$used" -v s="$stop" 'BEGIN { exit !(u >= s) }' && reached=1
done <<< "$(jq -r '.rate_limits | to_entries[] | "\(.key)\t\(.value.used_percentage // 0)\t\(.value.resets_at // 0)"' "$file")"
echo "recorded $(when "$(jq -r '.recorded_at' "$file")"), limit $stop %"
[ "$reached" -eq 0 ] || { echo "a window stands at $stop % or more: finish the step in hand, commit and report it, then wait for its reset"; exit 3; }
