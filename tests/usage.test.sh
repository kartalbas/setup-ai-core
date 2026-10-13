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
unset CODEX_THREAD_ID CODEX_SANDBOX CODEX_SANDBOX_NETWORK_DISABLED CODEX_HOME   # the Claude Code cases run as no Codex shell
mkdir -p "$HOME" "$work/project"

failed=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}
now="$(date +%s)"; soon=$((now + 3600)); later=$((now + 86400))
state="$(printf '{"model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":42.7,"resets_at":%s},"seven_day":{"used_percentage":95.1,"resets_at":%s}}}' "$soon" "$later")"
when() { LC_ALL=C date -d "@$1" '+%a %H:%M' 2>/dev/null || LC_ALL=C date -r "$1" '+%a %H:%M'; }

echo 'the status line records the windows and shows the model and the windows'
out="$(cd "$work/project" && bash "$root/bin/statusline.sh" <<< "$state")"
check 'the line'                 'Opus · 5h 42 % · week 95 %' "$out"
check 'the windows recorded'     '42.7 95.1' "$(jq -r '[.rate_limits.five_hour.used_percentage, .rate_limits.seven_day.used_percentage] | map(tostring) | join(" ")' "$HOME/.ai-core/usage.json")"
out="$(cd "$work/project" && bash "$root/bin/statusline.sh" <<< "$state")"   # a second run within the minute adds no line to the history
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

echo "in a Codex shell: the windows Codex wrote last into its newest session file, never Claude's"
printf '{"recorded_at":%s,"rate_limits":{"seven_day":{"used_percentage":99,"resets_at":%s}}}\n' "$now" "$later" > "$HOME/.ai-core/usage.json"
sessions="$HOME/.codex/sessions/2026/10/13"; mkdir -p "$sessions"
codex_line() { printf '{"timestamp":"2026-10-13T07:09:45.777Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":%s,"window_minutes":10080,"resets_at":%s},"secondary":%s}}}\n' "$1" "$later" "$2"; }
codex_line 99 null > "$sessions/rollout-old.jsonl"; touch -t 202601010000 "$sessions/rollout-old.jsonl"
{ codex_line 3 null; codex_line 7 "{\"used_percent\":12.5,\"window_minutes\":300,\"resets_at\":$soon}"
  printf '{"timestamp":"2026-10-13T07:10:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":null}}\n'; } > "$sessions/rollout-new.jsonl"
touch -t 202601020000 "$sessions/rollout-new.jsonl"   # the newest file below has no window at all, so the one before it counts
printf '{"timestamp":"2026-10-13T07:11:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":null,"secondary":null}}}\n' > "$sessions/rollout-newest.jsonl"
out="$(cd "$work/project" && CODEX_THREAD_ID=t bash "$root/bin/usage.sh" 2>&1)"; rc=$?
check 'exit 0, Claude at 99 % does not count'  0 "$rc"
check 'the week'                 "seven_day    7 %  resets $(when "$later")" "$(sed -n 1p <<< "$out")"
check 'the five hours'           "five_hour   12 %  resets $(when "$soon")" "$(sed -n 2p <<< "$out")"
check 'when Codex recorded it'   "recorded $(when "$(jq -n '"2026-10-13T07:09:45Z" | fromdateiso8601')"), limit 92 %" "$(sed -n 3p <<< "$out")"
out="$(cd "$work/project" && bash "$root/bin/usage.sh" 2>&1)"; rc=$?
check 'no Codex shell: Claude at 99 %, exit 3'  3 "$rc"
codex_line 95 null >> "$sessions/rollout-new.jsonl"
out="$(cd "$work/project" && CODEX_THREAD_ID=t bash "$root/bin/usage.sh" 2>&1)"; rc=$?
check 'Codex at its limit: exit 3'  3 "$rc"
rm -rf "$HOME/.codex"
out="$(cd "$work/project" && CODEX_THREAD_ID=t bash "$root/bin/usage.sh" 2>&1)"; rc=$?
check 'no Codex session file: exit 2'  2 "$rc"
check 'it says why'              yes "$(grep -q 'no usage recorded yet: Codex records it' <<< "$out" && echo yes || echo no)"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
