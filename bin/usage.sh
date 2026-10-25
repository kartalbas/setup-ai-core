#!/usr/bin/env bash
# What the selected account's usage windows stand at, as its tool last recorded them, where each
# will stand at its reset at the burn measured since the window's first reading, and whether one
# has reached the limit or will reach it before its reset. Claude Code's windows are what its status
# line records, its history the status line's log; Codex's are what Codex writes into its session
# files after every answer.
#
#   usage.sh [--tool claude|codex] [--stop-at N]     N percent; else USAGE_STOP_AT of the project's config.env; else 92
#
# Exit 0: every window below N, and none projected to N by its reset. Exit 4: a window projected to
# N or more by its reset, so nothing new starts on it. Exit 3: a window at N or more. Exit 2: nothing
# recorded yet, or a wrong argument. A window whose reset time has passed counts as reset; a window
# whose readings span less than 30 minutes has no measured burn and is judged by what it stands at.
# One model's own weekly quota is not among the windows Claude Code hands the status line, so it is
# not here either.
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
# With its zone, because a reset on the night the clocks change reads an hour off without it.
when() { LC_ALL=C date -d "@$1" '+%a %H:%M %Z' 2>/dev/null || LC_ALL=C date -r "$1" '+%a %H:%M %Z'; }
left() { local m=$((($1 - now) / 60)); if [ "$m" -lt 60 ]; then echo "in $m min"; elif [ "$m" -lt 2880 ]; then echo "in $((m / 60)) h $((m % 60)) min"; else echo "in $((m / 1440)) d $((m % 1440 / 60)) h"; fi; }
minutes() { case "$1" in five_hour) echo 300 ;; seven_day) echo 10080 ;; *_minutes) echo "${1%_minutes}" ;; *) echo 0 ;; esac; }
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
  # A week is the longest window, so an older session file holds no reading of a current one.
  readings="$(find "${CODEX_HOME:-$HOME/.codex}/sessions" -name 'rollout-*.jsonl' -mmin -10080 -exec grep -h -F '"rate_limits":{"' {} + 2>/dev/null \
    | jq -r '(.timestamp | sub("\\.[0-9]+"; "") | fromdateiso8601) as $t | .payload.rate_limits | (.primary, .secondary) | select(. != null)
      | "\(if .window_minutes == 300 then "five_hour" elif .window_minutes == 10080 then "seven_day" else "\(.window_minutes)_minutes" end)\t\($t)\t\(.used_percent // 0)\t\(.resets_at // 0)"' 2>/dev/null)"
else
  file="${AI_CORE_HOME:-$HOME}/.ai-core/usage.json"
  [ -f "$file" ] || { echo "no usage recorded yet: the status line records it once a session has had an answer" >&2; exit 2; }
  windows="$(jq -r '.rate_limits | to_entries[] | "\(.key)\t\(.value.used_percentage // 0)\t\(.value.resets_at // 0)"' "$file")"
  recorded="$(jq -r '.recorded_at' "$file")"
  readings="$(awk '{ if ($2 != "-") print "five_hour\t" $1 "\t" $2 "\t" $3; if ($4 != "-") print "seven_day\t" $1 "\t" $4 "\t" $5 }' \
    "${AI_CORE_HOME:-$HOME}/.ai-core/usage.log" 2>/dev/null)"
fi
now="$(date +%s)"; reached=0; projected=0; warnings=""
# Readings are whole percents, so over a shorter span one rounding step reads as a steep burn.
trusted_span=1800
while IFS=$'\t' read -r name used resets; do
  [ -n "$name" ] || continue
  if [ "$resets" -gt 0 ] && [ "$resets" -le "$now" ]; then
    printf '%-10s %3d %% used  reset since %s\n' "$name" 0 "$(when "$resets")"; continue
  fi
  # The burn runs from the window's first reading, one with the same reset taken after the window
  # began, to the last record.
  forecast="$(awk -F'\t' -v n="$name" -v r="$resets" -v u="$used" -v at="$recorded" -v s="$stop" -v len="$(minutes "$name")" -v span="$trusted_span" '
    $1 == n && $4 == r && (len == 0 || $2 >= r - len * 60) && (t == "" || $2 < t) { t = $2; first = $3 }
    END {
      if (t == "" || at - t < span) { print "unmeasured\t"; exit }
      burn = (u - first) / (at - t)
      if (burn <= 0) { print "0.0 %/h\t"; exit }
      p = u + burn * (r - at); cross = at + (s - u) / burn
      if (p < s) printf "%.1f %%/h, %d %% at reset\t\n", burn * 3600, p
      else printf "%.1f %%/h\t%d\n", burn * 3600, (cross > at ? cross : at)
    }' <<< "$readings")"
  cross="${forecast##*$'\t'}"; burn="${forecast%%$'\t'*}"
  [ -z "$cross" ] || burn="$burn, $stop % at $(when "$cross")"
  printf '%-10s %3d %% used  resets %s, %s  burn %s\n' "$name" "$(awk -v u="$used" 'BEGIN { printf "%d", u }')" "$(when "$resets")" "$(left "$resets")" "$burn"
  awk -v u="$used" -v s="$stop" 'BEGIN { exit !(u >= s) }' && reached=1
  [ -n "$cross" ] || continue
  # A window of a day or less resets soon after, so waiting costs little; a longer one is a
  # person's decision, another account or slower work, and needs the hour ahead of time.
  if [ "$(minutes "$name")" -gt 0 ] && [ "$(minutes "$name")" -le 1440 ]; then projected=1
  else warnings="$warnings$name reaches $stop % at $(when "$cross"), before its reset: tell the person who decides the account now"$'\n'; fi
done <<< "$windows"
echo "recorded $(when "$recorded"), limit $stop %"
printf '%s' "$warnings"
[ "$reached" -eq 0 ] || { echo "a window stands at $stop % or more: finish the step in hand, commit and report it, then wait for its reset"; exit 3; }
[ "$projected" -eq 0 ] || { echo "a window reaches $stop % before its reset at the measured burn: start nothing new on this account, and have what runs commit before that hour"; exit 4; }
