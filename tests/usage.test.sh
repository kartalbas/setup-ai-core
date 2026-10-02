#!/usr/bin/env bash
# What the status line records of the account's usage windows, and what `usage` makes of it: the
# limit reached, the limit not reached, a window whose reset has passed, and nothing recorded.
# HOME and AI_CORE_HOME point into a temporary folder, so the machine's own record is not touched.
#
#   bash tests/usage.test.sh

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export HOME="$work/home" AI_CORE_HOME="$work/home"
mkdir -p "$HOME" "$work/project/.claude/helpers"

failed=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}
now="$(date +%s)"; soon=$((now + 3600)); later=$((now + 86400))
state="$(printf '{"model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":42.7,"resets_at":%s},"seven_day":{"used_percentage":95.1,"resets_at":%s}}}' "$soon" "$later")"
when() { LC_ALL=C date -d "@$1" '+%a %H:%M' 2>/dev/null || LC_ALL=C date -r "$1" '+%a %H:%M'; }

echo 'the status line records the windows, and shows its own short line where Graft has none'
out="$(cd "$work/project" && CLAUDE_PROJECT_DIR="$work/project" bash "$root/bin/statusline.sh" <<< "$state")"
check 'the line'                 'Opus · 5h 42 % · week 95 %' "$out"
check 'the windows recorded'     '42.7 95.1' "$(jq -r '[.rate_limits.five_hour.used_percentage, .rate_limits.seven_day.used_percentage] | map(tostring) | join(" ")' "$HOME/.ai-core/usage.json")"
echo "and Graft's line where Graft is wired"
printf 'process.stdout.write("graft line")\n' > "$work/project/.claude/helpers/graft-statusline.cjs"
out="$(cd "$work/project" && CLAUDE_PROJECT_DIR="$work/project" bash "$root/bin/statusline.sh" <<< "$state")"
check "Graft's line"             'graft line' "$out"
check 'the history, one line a minute' "1 42.7 $soon 95.1 $later" "$(wc -l < "$HOME/.ai-core/usage.log" | tr -d ' ') $(cut -d' ' -f2- "$HOME/.ai-core/usage.log")"

echo 'usage at the limit: every window named, and exit 3'
out="$(cd "$work/project" && bash "$root/bin/usage.sh" 2>&1)"; rc=$?
check 'exit 3'                   3 "$rc"
check 'the five hours'           "five_hour   42 %  resets $(when "$soon")" "$(sed -n 1p <<< "$out")"
check 'the week'                 "seven_day   95 %  resets $(when "$later")" "$(sed -n 2p <<< "$out")"
check 'what to do'               yes "$(grep -q '^a window stands at 92 % or more: finish the step in hand' <<< "$out" && echo yes || echo no)"
echo 'below a limit given: exit 0'
out="$(cd "$work/project" && bash "$root/bin/usage.sh" --stop-at 96 2>&1)"; rc=$?
check 'exit 0'                   0 "$rc"
echo "the project's own limit: USAGE_STOP_AT in its config.env"
mkdir -p "$work/project/.ai-core"; printf 'USAGE_STOP_AT="96"\n' > "$work/project/.ai-core/config.env"
out="$(cd "$work/project" && bash "$root/bin/usage.sh" 2>&1)"; rc=$?
check 'exit 0 at 95 % under 96'  0 "$rc"
check 'it names the limit'       yes "$(grep -q ', limit 96 %$' <<< "$out" && echo yes || echo no)"
rm -f "$work/project/.ai-core/config.env"
echo 'a window whose reset has passed counts as reset'
printf '{"recorded_at":%s,"rate_limits":{"five_hour":{"used_percentage":99,"resets_at":%s}}}\n' "$now" "$((now - 60))" > "$HOME/.ai-core/usage.json"
out="$(cd "$work/project" && bash "$root/bin/usage.sh" 2>&1)"; rc=$?
check 'exit 0'                   0 "$rc"
check 'reported as reset'        "five_hour    0 %  reset since $(when "$((now - 60))")" "$(sed -n 1p <<< "$out")"
echo 'nothing recorded: exit 2, and why'
rm -f "$HOME/.ai-core/usage.json"
out="$(cd "$work/project" && bash "$root/bin/usage.sh" 2>&1)"; rc=$?
check 'exit 2'                   2 "$rc"
check 'it says why'              yes "$(grep -q 'no usage recorded yet' <<< "$out" && echo yes || echo no)"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
