#!/usr/bin/env bash
# What the selected account's usage windows stand at, as its tool last recorded them, and
# whether one has reached the limit at which every session finishes the step in hand and waits for
# its reset. Claude Code's windows are what its status line records; Codex's are what Codex writes
# into its session files after every answer.
#
#   usage.sh [--tool claude|codex] [--stop-at N]     N percent; else USAGE_STOP_AT of the project's config.env; else 92
#
# Exit 0: every window below N. Exit 3: a window at N or more. Exit 2: nothing recorded yet, or a
# wrong argument. A window whose reset time has passed counts as reset. One model's own weekly quota
# is not among the windows Claude Code hands the status line, so it is not here either.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/lib/common.sh"

tool=""
usage="usage: usage.sh [--tool claude|codex] [--stop-at N]"
config="$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.ai-core/config.env"
stop="$(grep -E '^[[:space:]]*USAGE_STOP_AT[[:space:]]*=' "$config" 2>/dev/null | tail -n1 || true)"
stop="${stop#*=}"; stop="${stop%%#*}"; stop="${stop//[[:space:]\"\']/}"; stop="${stop:-92}"
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) echo "$usage"
      echo 'Reads last recorded windows, selected explicitly or by the session tool (Claude otherwise).'
      echo 'Exit 2 means usage is unknown or an argument is invalid; it is not a successful preflight.'
      exit 0 ;;
    --tool) case "${2-}" in claude|codex) tool="$2"; shift 2 ;; *) echo "error: --tool takes claude or codex - $usage" >&2; exit 2 ;; esac ;;
    --stop-at) stop="${2:-}"; shift 2 || { echo "error: --stop-at takes a percentage - $usage" >&2; exit 2; } ;;
    *) echo "error: unknown argument '$1' - $usage" >&2; exit 2 ;;
  esac
done
case "$stop" in ''|*[!0-9]*) echo "error: --stop-at takes a whole percentage, not '$stop'" >&2; exit 2 ;; esac
when() { LC_ALL=C date -d "@$1" '+%a %H:%M' 2>/dev/null || LC_ALL=C date -r "$1" '+%a %H:%M'; }
# A Codex session started from a Claude Code shell inherits CLAUDECODE, so the Codex variables decide.
# A record counts only with a window in it; a line whose windows are all null says nothing.
[ -n "$tool" ] || tool="$(session_tool)"
if [ "$tool" = codex ]; then
  line="$(ls -t "${CODEX_HOME:-$HOME/.codex}"/sessions/*/*/*/rollout-*.jsonl 2>/dev/null | while IFS= read -r f; do
    r="$(grep -F '"rate_limits":{"' "$f" | grep -E '"(primary|secondary)":\{"' | tail -n1)"; [ -n "$r" ] && { printf '%s\n' "$r"; break; }; done)"
  [ -n "$line" ] || { echo "no usage recorded yet: Codex records it in its session files once a session has had an answer" >&2; exit 2; }
  windows="$(jq -r '.payload.rate_limits | (.primary, .secondary) | select(. != null)
    | "\(if .window_minutes == 300 then "five_hour" elif .window_minutes == 10080 then "seven_day" else "\(.window_minutes)_minutes" end)\t\(.used_percent // 0)\t\(.resets_at // 0)"' <<< "$line")"
  recorded="$(jq -r '.timestamp | sub("\\.[0-9]+"; "") | fromdateiso8601' <<< "$line")"
else
  file="${AI_CORE_HOME:-$HOME}/.ai-core/usage.json"
  [ -f "$file" ] || { echo "no usage recorded yet: the status line records it once a session has had an answer" >&2; exit 2; }
  windows="$(jq -r '.rate_limits | to_entries[] | "\(.key)\t\(.value.used_percentage // 0)\t\(.value.resets_at // 0)"' "$file")"
  recorded="$(jq -r '.recorded_at' "$file")"
fi
now="$(date +%s)"; reached=0
while IFS=$'\t' read -r name used resets; do
  [ -n "$name" ] || continue
  if [ "$resets" -gt 0 ] && [ "$resets" -le "$now" ]; then used=0; note="reset since $(when "$resets")"; else note="resets $(when "$resets")"; fi
  printf '%-10s %3d %% used  %s\n' "$name" "$(awk -v u="$used" 'BEGIN { printf "%d", u }')" "$note"
  awk -v u="$used" -v s="$stop" 'BEGIN { exit !(u >= s) }' && reached=1
done <<< "$windows"
echo "recorded $(when "$recorded"), limit $stop %"
[ "$reached" -eq 0 ] || { echo "a window stands at $stop % or more: finish the step in hand, commit and report it, then wait for its reset"; exit 3; }
