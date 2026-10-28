#!/usr/bin/env bash
# What the selected account's usage windows stand at, as its tool last recorded them, where each
# will stand at its reset at the burn measured since the window's first reading, and whether one
# has reached the limit or will reach it before its reset. Claude Code's windows are what its status
# line records, its history the status line's log; Codex's are what Codex writes into its session
# files after every answer, a record older than an hour renewed first by one minimal Codex call;
# agy's are what `agy -p /usage` answers now, each group of models with its own windows, its history
# the readings this command saved under ~/.ai-core/usage-agy/.
#
#   usage.sh [--tool claude|codex|agy] [--model MODEL] [--stop-at N]
#                                                     N percent used; else USAGE_STOP_AT of the project's config.env; else 92
#
# Every tool's windows, their forecast and the limit N are shown as the share used. --model, for agy
# only, judges just the group whose description lists the family of the model's display name from
# `agy models`.
# Exit 0: every window below N, and none projected to N by its reset. Exit 4: a window projected to
# N or more by its reset, so nothing new starts on it. Exit 3: a window at N or more. Exit 2: nothing
# recorded yet, a reading that cannot be used, or a wrong argument. A window whose reset time has
# passed counts as reset; a window whose readings span less than 30 minutes has no measured burn and
# is judged by what it stands at. One model's own weekly quota is not among the windows Claude Code
# hands the status line, so it is not here either.
# The readers of the three tools are in lib/usage.sh, which bin/status.sh uses for its usage line.
# Without --tool it then audits the phase starts of the machine against the choices of phase-model
# (lib/tool-order.sh), after the windows; a quota exit stays, and an audit that cannot be read turns
# exit 0 into exit 2.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/lib/common.sh"
. "$ROOT/lib/usage.sh"

tool=""; model=""; audit=1
usage="usage: usage.sh [--tool claude|codex|agy] [--model MODEL] [--stop-at N]"
stop="$(usage_stop_at)" || exit 2
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) echo "$usage"
      echo 'Reads the windows of one tool, selected explicitly or by the session tool (Claude otherwise).'
      echo 'Exit 2 means usage is unknown or an argument is invalid; it is not a successful preflight.'
      echo 'Without --tool it also reports the saved tool order and audits the phase starts against the choices of phase-model.'
      exit 0 ;;
    --tool) case "${2-}" in claude|codex|agy) tool="$2"; audit=0; shift 2 ;; *) echo "error: --tool takes claude, codex or agy - $usage" >&2; exit 2 ;; esac ;;
    --model) case "${2-}" in ''|-*) echo "error: --model takes a model of agy - $usage" >&2; exit 2 ;; *) model="$2"; shift 2 ;; esac ;;
    --stop-at) stop="${2:-}"; shift 2 || { echo "error: --stop-at takes a percentage - $usage" >&2; exit 2; } ;;
    *) echo "error: unknown argument '$1' - $usage" >&2; exit 2 ;;
  esac
done
reject() { echo "error: $*" >&2; exit 2; }
case "$stop" in ''|*[!0-9]*) reject "--stop-at takes a whole percentage, not '$stop'" ;; esac
stop="$(awk -v n="$stop" 'BEGIN { if (n > 100) exit 1; printf "%d", n }')" \
  || reject '--stop-at takes a whole percentage from 0 to 100'
# With its zone, because a reset on the night the clocks change reads an hour off without it.
when() { LC_ALL=C date -d "@$1" '+%a %H:%M %Z' 2>/dev/null || LC_ALL=C date -r "$1" '+%a %H:%M %Z'; }
left() { local m=$((($1 - now) / 60)); if [ "$m" -lt 60 ]; then echo "in $m min"; elif [ "$m" -lt 2880 ]; then echo "in $((m / 60)) h $((m % 60)) min"; else echo "in $((m / 1440)) d $((m % 1440 / 60)) h"; fi; }
# A Codex session started from a Claude Code shell inherits CLAUDECODE, so the Codex variables decide.
[ -n "$tool" ] || tool="$(session_tool)"
[ -n "$tool" ] || tool=claude
case "$tool" in claude|codex|agy) ;; *) reject "usage does not read the quota of $tool: --tool takes claude, codex or agy" ;; esac
[ -z "$model" ] || [ "$tool" = agy ] || reject "--model is for agy, which has a quota per group of models; $tool has none - $usage"
finish_usage() {
  local result="$?" audit_result=0
  trap - EXIT
  usage_release || audit_result=2
  if [ "$audit" -eq 1 ]; then
    if . "$ROOT/lib/tool-order.sh"; then tool_order_audit || audit_result=2; else audit_result=2; fi
  fi
  [ "$result" -ne 0 ] || result="$audit_result"
  exit "$result"
}
trap finish_usage EXIT
usage_read "$tool" "$model" || { echo "$usage_failure" >&2; exit 2; }
windows="$usage_windows"; recorded="$usage_recorded"; readings="$usage_readings"
now="$(date +%s)"
limit="$stop % used"
reached=0; projected=0; warnings=""
# Readings are whole percents, so over a shorter span one rounding step reads as a steep burn.
trusted_span=1800
width="$(awk -F'\t' '{ if (length($2) > w) w = length($2) } END { print (w > 10 ? w : 10) }' <<< "$windows")"
while IFS=$'\t' read -r key name length used resets; do
  [ -n "$key" ] || continue
  if [ "$resets" -gt 0 ] && [ "$resets" -le "$now" ]; then
    printf '%-*s   0 %% used  reset since %s\n' "$width" "$name" "$(when "$resets")"; continue
  fi
  # The burn runs from the window's first reading, one with the same reset taken after the window
  # began, to the last record.
  forecast="$(AI_CORE_USAGE_KEY="$key" awk -F'\t' -v r="$resets" -v u="$used" -v at="$recorded" -v s="$stop" -v len="$length" -v span="$trusted_span" '
    BEGIN { k = ENVIRON["AI_CORE_USAGE_KEY"] }
    $1 == k && $4 == r && (len == 0 || $2 >= r - len * 60) && (t == "" || $2 < t) { t = $2; first = $3 }
    END {
      if (t == "" || at - t < span) { print "unmeasured\t"; exit }
      burn = (u - first) / (at - t)
      if (burn <= 0) { print "0.0 %/h\t"; exit }
      p = u + burn * (r - at); cross = at + (s - u) / burn
      if (p < s) printf "%.1f %%/h, %d %% used at reset\t\n", burn * 3600, p
      else printf "%.1f %%/h\t%d\n", burn * 3600, (cross > at ? cross : at)
    }' <<< "$readings")"
  cross="${forecast##*$'\t'}"; burn="${forecast%%$'\t'*}"
  [ -z "$cross" ] || burn="$burn, $limit at $(when "$cross")"
  printf '%-*s %3d %% used  resets %s, %s  burn %s\n' "$width" "$name" "$(awk -v u="$used" 'BEGIN { printf "%d", u }')" "$(when "$resets")" "$(left "$resets")" "$burn"
  awk -v u="$used" -v s="$stop" 'BEGIN { exit !(u >= s) }' && reached=1
  [ -n "$cross" ] || continue
  # A window of a day or less resets soon after, so waiting costs little; a longer one is a
  # person's decision, another account or slower work, and needs the hour ahead of time.
  if [ "$length" -gt 0 ] && [ "$length" -le 1440 ]; then projected=1
  else warnings="$warnings$name reaches $limit at $(when "$cross"), before its reset; the person who holds the account watches it"$'\n'; fi
done <<< "$windows"
echo "recorded $(when "$recorded"), limit $limit"
[ -z "$usage_notice" ] || echo "$usage_notice"
printf '%s' "$warnings"
[ "$reached" -eq 0 ] || { echo "a window stands at $limit or more: finish the step in hand, commit and report it, then wait for its reset"; exit 3; }
[ "$projected" -eq 0 ] || { echo "a window reaches $limit before its reset at the measured burn: start nothing new on this account, and have what runs commit before that hour"; exit 4; }
