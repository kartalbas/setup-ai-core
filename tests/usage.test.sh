#!/usr/bin/env bash
# What the status line records of the account's usage windows, and what `usage` makes of it: the
# limit reached, the limit not reached, a window whose reset has passed, nothing recorded, and the
# burn measured from the history with the hour a window reaches the limit before its reset.
# HOME and AI_CORE_HOME point into a temporary folder, so the machine's own record is not touched.
#
#   bash tests/usage.test.sh

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export HOME="$work/home" AI_CORE_HOME="$work/home"
. "$root/tests/tool-environment.sh"
unset CODEX_HOME
mkdir -p "$HOME" "$work/project"

failed=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}
now="$(date +%s)"; soon=$((now + 3600)); later=$((now + 86400))
state="$(printf '{"model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":42.7,"resets_at":%s},"seven_day":{"used_percentage":95.1,"resets_at":%s}}}' "$soon" "$later")"
when() { LC_ALL=C date -d "@$1" '+%a %H:%M %Z' 2>/dev/null || LC_ALL=C date -r "$1" '+%a %H:%M %Z'; }
# The time left is counted by usage.sh a moment after this test's clock, so a minute may be gone.
matches() { grep -Eq "$1" <<< "$2" && echo yes || echo "no: $2"; }

echo 'the status line records the windows and shows the model and the windows'
out="$(cd "$work/project" && bash "$root/bin/statusline.sh" <<< "$state")"
check 'the line'                 'Opus · 5h 42 % · week 95 %' "$out"
check 'the windows recorded'     '42.7 95.1' "$(jq -r '[.rate_limits.five_hour.used_percentage, .rate_limits.seven_day.used_percentage] | map(tostring) | join(" ")' "$HOME/.ai-core/usage.json")"
out="$(cd "$work/project" && bash "$root/bin/statusline.sh" <<< "$state")"   # a second run within the minute adds no line to the history
check 'the history, one line a minute' "1 42.7 $soon 95.1 $later" "$(wc -l < "$HOME/.ai-core/usage.log" | tr -d ' ') $(cut -d' ' -f2- "$HOME/.ai-core/usage.log")"

echo 'usage at the limit: every window named, and exit 3'
out="$(cd "$work/project" && bash "$root/bin/usage.sh" 2>&1)"; rc=$?
check 'exit 3'                   3 "$rc"
check 'the five hours, one reading: unmeasured' yes "$(matches "^five_hour   42 % used  resets $(when "$soon"), in (59 min|1 h 0 min)  burn unmeasured$" "$(sed -n 1p <<< "$out")")"
check 'the week'                 yes "$(matches "^seven_day   95 % used  resets $(when "$later"), in (23 h 59 min|24 h 0 min)  burn unmeasured$" "$(sed -n 2p <<< "$out")")"
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
check 'reported as reset'        "five_hour    0 % used  reset since $(when "$((now - 60))")" "$(sed -n 1p <<< "$out")"
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
check 'the week, as what is left' yes "$(matches "^seven_day   93 % left  resets $(when "$later"), in (23 h 59 min|24 h 0 min)  burn unmeasured$" "$(sed -n 1p <<< "$out")")"
check 'the five hours'           yes "$(matches "^five_hour   87 % left  resets $(when "$soon"), in (59 min|1 h 0 min)  burn unmeasured$" "$(sed -n 2p <<< "$out")")"
check 'when Codex recorded it, the limit as used' "recorded $(when "$(jq -n '"2026-10-13T07:09:45Z" | fromdateiso8601')"), limit 92 % used" "$(sed -n 3p <<< "$out")"
out="$(cd "$work/project" && bash "$root/bin/usage.sh" 2>&1)"; rc=$?
check 'no Codex shell: Claude at 99 %, exit 3'  3 "$rc"
echo 'an explicit selector reads the destination account despite inherited identity'
out="$(cd "$work/project" && CLAUDECODE=1 bash "$root/bin/usage.sh" --tool codex 2>&1)"; rc=$?
check 'explicit Codex below, Claude at 99' 0 "$rc"
out="$(cd "$work/project" && CODEX_THREAD_ID=t CODEX_SANDBOX=fixture CODEX_SANDBOX_NETWORK_DISABLED=1 bash "$root/bin/usage.sh" --tool claude 2>&1)"; rc=$?
check 'explicit Claude at limit' 3 "$rc"
for flag in '--tool' '--tool gemini' '--tool unknown' '--tool --stop-at 92' '--model' '--model --stop-at 92'; do
  out="$(cd "$work/project" && bash "$root/bin/usage.sh" $flag 2>&1)"; rc=$?
  check "invalid selector $flag" 2 "$rc"
done
codex_line 95 null >> "$sessions/rollout-new.jsonl"
out="$(cd "$work/project" && CODEX_THREAD_ID=t bash "$root/bin/usage.sh" 2>&1)"; rc=$?
check 'Codex at its limit: exit 3'  3 "$rc"
printf '{"recorded_at":%s,"rate_limits":{"seven_day":{"used_percentage":4,"resets_at":%s}}}\n' "$now" "$later" > "$HOME/.ai-core/usage.json"
out="$(cd "$work/project" && CLAUDECODE=1 bash "$root/bin/usage.sh" --tool codex 2>&1)"; rc=$?
check 'explicit Codex at limit despite Claude below' 3 "$rc"
out="$(cd "$work/project" && CODEX_THREAD_ID=t bash "$root/bin/usage.sh" --tool claude 2>&1)"; rc=$?
check 'explicit Claude below despite Codex at limit' 0 "$rc"
mkdir -p "$work/mutant/bin" "$work/mutant/lib"
cp "$root/lib/common.sh" "$work/mutant/lib/"
sed 's/tool="$2"/tool="claude"/' "$root/bin/usage.sh" > "$work/mutant/bin/usage.sh"
out="$(cd "$work/project" && bash "$work/mutant/bin/usage.sh" --tool codex 2>&1)"; rc=$?
check 'ignoring selector is caught' 0 "$rc"
sed 's/exit 3/exit 0/g' "$root/bin/usage.sh" > "$work/mutant/bin/usage.sh"
out="$(cd "$work/project" && bash "$work/mutant/bin/usage.sh" --tool codex 2>&1)"; rc=$?
check 'non-stopping mutant is caught' 0 "$rc"
echo 'Codex: the burn from the readings in its session files'
iso() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%S.000Z' 2>/dev/null || date -u -r "$1" '+%Y-%m-%dT%H:%M:%S.000Z'; }
reading() { printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":%s,"window_minutes":300,"resets_at":%s},"secondary":null}}}\n' "$(iso "$1")" "$2" "$soon"; }
{ reading "$((now - 1800))" 50; reading "$now" 80; } > "$sessions/rollout-burn.jsonl"
out="$(cd "$work/project" && CODEX_THREAD_ID=t bash "$root/bin/usage.sh" 2>&1)"; rc=$?
check 'Codex projected to its limit: exit 4'  4 "$rc"
check 'the burn and the hour, as what is left' yes "$(matches "^five_hour   20 % left  resets .*  burn 60.0 %/h, 8 % left at $(when "$((now + 720))")$" "$(sed -n 1p <<< "$out")")"
rm -rf "$HOME/.codex"
out="$(cd "$work/project" && CODEX_THREAD_ID=t bash "$root/bin/usage.sh" 2>&1)"; rc=$?
check 'no Codex session file: exit 2'  2 "$rc"
check 'it says why'              yes "$(grep -q 'no usage recorded yet: Codex records it' <<< "$out" && echo yes || echo no)"

echo 'the burn from the history: a window that reaches the limit before its reset stops new starts'
week=$((now + 4 * 86400))
history() { printf '%s %s %s %s %s\n' "$((now - 1800))" "$1" "$2" "$3" "$week" > "$HOME/.ai-core/usage.log"
  printf '{"recorded_at":%s,"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":%s,"resets_at":%s}}}\n' "$now" "$4" "$2" "$5" "$week" > "$HOME/.ai-core/usage.json"; }
history 50 "$soon" 10 80 10
out="$(cd "$work/project" && bash "$root/bin/usage.sh" 2>&1)"; rc=$?
check 'exit 4 below the limit'   4 "$rc"
check 'the hour it reaches 92 %' yes "$(matches "^five_hour   80 % used  resets $(when "$soon"), in (59 min|1 h 0 min)  burn 60.0 %/h, 92 % at $(when "$((now + 720))")$" "$(sed -n 1p <<< "$out")")"
check 'a week without burn'      yes "$(matches "^seven_day   10 % used  resets $(when "$week"), in (3 d 23 h|4 d 0 h)  burn 0.0 %/h$" "$(sed -n 2p <<< "$out")")"
check 'what to do'               yes "$(matches '^a window reaches 92 % before its reset at the measured burn: start nothing new on this account' "$out")"
echo 'the same burn with the reset minutes away: the window carries on (innocent case)'
history 50 "$((now + 300))" 10 80 10
out="$(cd "$work/project" && bash "$root/bin/usage.sh" 2>&1)"; rc=$?
check 'exit 0'                   0 "$rc"
check 'what it stands at then'   yes "$(matches "  burn 60.0 %/h, 85 % at reset$" "$(sed -n 1p <<< "$out")")"
echo 'one whole percent minutes into a window: too short a span to measure a burn (planted)'
fresh=$((now + 17400))
printf '%s %s %s %s %s\n' "$((now - 180))" 0 "$fresh" 10 "$week" > "$HOME/.ai-core/usage.log"
printf '{"recorded_at":%s,"rate_limits":{"five_hour":{"used_percentage":1,"resets_at":%s},"seven_day":{"used_percentage":10,"resets_at":%s}}}\n' "$now" "$fresh" "$week" > "$HOME/.ai-core/usage.json"
out="$(cd "$work/project" && bash "$root/bin/usage.sh" 2>&1)"; rc=$?
check 'exit 0'                   0 "$rc"
check 'unmeasured'               yes "$(matches "^five_hour +1 % used  resets .*  burn unmeasured$" "$(sed -n 1p <<< "$out")")"
echo 'a week that fills before its reset warns and stops nothing: its account is a person'"'"'s decision'
history 80 "$soon" 10 80 40
out="$(cd "$work/project" && bash "$root/bin/usage.sh" 2>&1)"; rc=$?
check 'exit 0'                   0 "$rc"
check 'the warning'              yes "$(matches "^seven_day reaches 92 % at $(when "$((now + 3120))"), before its reset: tell the person who decides the account now$" "$out")"
echo 'a window at the limit outranks a projection'
history 50 "$soon" 10 95 10
out="$(cd "$work/project" && bash "$root/bin/usage.sh" 2>&1)"; rc=$?
check 'exit 3'                   3 "$rc"
sed 's/projected=1/projected=0/' "$root/bin/usage.sh" > "$work/mutant/bin/usage.sh"
history 50 "$soon" 10 80 10
out="$(cd "$work/project" && bash "$work/mutant/bin/usage.sh" 2>&1)"; rc=$?
check 'a mutant that ignores the projection is caught' 0 "$rc"

echo 'a record without a usable reading is exit 2 with the reason, never a window at 0 %'
claude_record() {  # claude_record <what the status line recorded>: the answer of usage in $out and $rc
  printf '%s\n' "$1" > "$HOME/.ai-core/usage.json"
  out="$(cd "$work/project" && bash "$script" 2>&1)"; rc=$?
}
script="$root/bin/usage.sh"
window="\"resets_at\":$later"
refused_claude() {  # refused_claude <name> <reason> <record>
  claude_record "$3"
  check "Claude, $1: exit 2" 2 "$rc"
  check "Claude, $1: the reason" yes "$(matches "$2" "$out")"
  check "Claude, $1: no window" 0 "$(grep -c '% used' <<< "$out")"
}
refused_claude 'a window without used_percentage' 'the window five_hour has no number for used_percentage or resets_at' "{\"recorded_at\":$now,\"rate_limits\":{\"five_hour\":{$window}}}"
refused_claude 'a window without resets_at' 'the window five_hour has no number for used_percentage or resets_at' "{\"recorded_at\":$now,\"rate_limits\":{\"five_hour\":{\"used_percentage\":5}}}"
refused_claude 'a percentage as text' 'the window seven_day has no number' "{\"recorded_at\":$now,\"rate_limits\":{\"seven_day\":{\"used_percentage\":\"5\",$window}}}"
refused_claude 'a negative percentage' 'invalid percentage or reset' "{\"recorded_at\":$now,\"rate_limits\":{\"five_hour\":{\"used_percentage\":-5,$window}}}"
refused_claude 'a fractional reset' 'invalid percentage or reset' "{\"recorded_at\":$now,\"rate_limits\":{\"five_hour\":{\"used_percentage\":5,\"resets_at\":123.5}}}"
refused_claude 'rate_limits empty' 'rate_limits holds no window' "{\"recorded_at\":$now,\"rate_limits\":{}}"
refused_claude 'rate_limits missing' 'rate_limits holds no window' "{\"recorded_at\":$now}"
refused_claude 'a window that is null only' 'rate_limits holds no window' "{\"recorded_at\":$now,\"rate_limits\":{\"five_hour\":null}}"
refused_claude 'no recorded_at' 'recorded_at is not a number' "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":5,$window}}}"
refused_claude 'a file that is no JSON' 'usage.json' 'five_hour 5'
claude_record "{\"recorded_at\":$now,\"rate_limits\":{\"seven_day\":null,\"five_hour\":{\"used_percentage\":5,$window}}}"
check 'Claude, a null window beside a usable one (innocent): exit 0' 0 "$rc"
check 'Claude, the usable window alone' 1 "$(grep -c '^five_hour    5 % used' <<< "$out")"
sed 's/if \[.used_percentage, .resets_at\]/(.used_percentage \/\/= 0) | if [.used_percentage, .resets_at]/' "$root/bin/usage.sh" > "$work/mutant/bin/usage.sh"
script="$work/mutant/bin/usage.sh"
claude_record "{\"recorded_at\":$now,\"rate_limits\":{\"five_hour\":{$window}}}"
check 'a reader that lets a missing percentage through is caught' yes "$([ "$rc" != 2 ] && echo yes || echo no)"
script="$root/bin/usage.sh"
codex_record() {  # codex_record <a line of Codex's session file>
  rm -rf "$HOME/.codex"; mkdir -p "$sessions"
  printf '%s\n' "$1" > "$sessions/rollout-record.jsonl"
  out="$(cd "$work/project" && CODEX_THREAD_ID=t bash "$script" 2>&1)"; rc=$?
}
codex_with() { printf '{"timestamp":"2026-10-13T07:09:45.777Z","payload":{"rate_limits":{"primary":%s,"secondary":null}}}' "$1"; }
refused_codex() {  # refused_codex <name> <reason> <record>
  codex_record "$3"
  check "Codex, $1: exit 2" 2 "$rc"
  check "Codex, $1: the reason" yes "$(matches "$2" "$out")"
  check "Codex, $1: no window" 0 "$(grep -c '% left' <<< "$out")"
}
refused_codex 'a window without used_percent' 'a window without a number for used_percent, window_minutes or resets_at' "$(codex_with "{\"window_minutes\":300,\"resets_at\":$soon}")"
refused_codex 'a window without window_minutes' 'a window without a number' "$(codex_with "{\"used_percent\":5,\"resets_at\":$soon}")"
refused_codex 'a window without resets_at' 'a window without a number' "$(codex_with '{"used_percent":5,"window_minutes":300}')"
refused_codex 'a negative percentage' 'invalid percentage, duration or reset' "$(codex_with "{\"used_percent\":-5,\"window_minutes\":300,\"resets_at\":$soon}")"
refused_codex 'a fractional duration' 'invalid percentage, duration or reset' "$(codex_with "{\"used_percent\":5,\"window_minutes\":0.5,\"resets_at\":$soon}")"
refused_codex 'a record cut off while Codex writes it' 'jq|parse|Unfinished|error' '{"timestamp":"2026-10-13T07:09:45.777Z","payload":{"rate_limits":{"primary":{"used_percent":5'
refused_codex 'a record without a timestamp' 'no usable timestamp' '{"payload":{"rate_limits":{"primary":{"used_percent":5,"window_minutes":300,"resets_at":1},"secondary":null}}}'
codex_record "$(codex_with "{\"used_percent\":5,\"window_minutes\":300,\"resets_at\":$soon}")"
check 'Codex, a complete window beside a null one (innocent): exit 0' 0 "$rc"
check 'Codex, its window'        1 "$(grep -c '^five_hour   95 % left' <<< "$out")"
codex_record "$(printf '{"timestamp":"2026-10-13T07:09:45.777Z","payload":{"rate_limits":{"primary":{"used_percent":5,"window_minutes":300,"resets_at":%s},"secondary":{"used_percent":0.0,"window_minutes":0,"resets_at":%s}}}}' "$soon" "$soon")"
check 'Codex, a window of 0 minutes, as Codex writes one beside a real window, says nothing: exit 0' 0 "$rc"
check 'Codex, only the real window shown' '1 0' "$(grep -c '^five_hour   95 % left' <<< "$out") $(grep -c '0_minutes' <<< "$out")"
sed 's/if \[.used_percent, .window_minutes, .resets_at\]/(.used_percent \/\/= 0) | if [.used_percent, .window_minutes, .resets_at]/' "$root/bin/usage.sh" > "$work/mutant/bin/usage.sh"
script="$work/mutant/bin/usage.sh"
codex_record "$(codex_with "{\"window_minutes\":300,\"resets_at\":$soon}")"
check 'a reader that lets a missing used_percent through is caught' yes "$([ "$rc" != 2 ] && echo yes || echo no)"
script="$root/bin/usage.sh"
rm -rf "$HOME/.codex"

echo 'the newest quota timestamp wins within one second, even when an older session file was touched later'
mkdir -p "$sessions"
{ reading "$((now - 1800))" 50; reading "$now" 99; } | sed 's/\.000Z/\.900Z/' > "$sessions/rollout-current.jsonl"
reading "$now" 5 | sed 's/\.000Z/\.100Z/' > "$sessions/rollout-touched.jsonl"
touch -t 202601010000 "$sessions/rollout-current.jsonl"
out="$(cd "$work/project" && bash "$script" --tool codex 2>&1)"; rc=$?
check 'newest reading at 99 % used holds the start: exit 3' 3 "$rc"
check 'the newest value is shown' yes "$(matches '^five_hour +1 % left' "$out")"
printf '{"timestamp":"bad","payload":{"rate_limits":{"primary":{"used_percent":5,"window_minutes":300,"resets_at":%s}}}}\n' "$soon" > "$sessions/rollout-bad-history.jsonl"
touch -t 202601010000 "$sessions/rollout-bad-history.jsonl"
out="$(cd "$work/project" && bash "$script" --tool codex 2>&1)"; rc=$?
check 'malformed Codex history is reported: exit 2' 2 "$rc"
check 'its timestamp error is visible' yes "$(matches 'timestamp|UTC time' "$out")"
rm -rf "$HOME/.codex"

echo 'a malformed Claude history is reported, while an absent history means unmeasured'
claude_record "{\"recorded_at\":$now,\"rate_limits\":{\"five_hour\":{\"used_percentage\":5,$window}}}"
printf '%s 5 %s - -\ngarbage\n' "$((now - 60))" "$later" > "$HOME/.ai-core/usage.log"
out="$(cd "$work/project" && bash "$script" --tool claude 2>&1)"; rc=$?
check 'malformed Claude history: exit 2' 2 "$rc"
check 'the history error names its line' yes "$(matches 'usage.log:2' "$out")"
check 'the history error is one line, without the lines read before it' 1 "$(wc -l <<< "$out" | tr -d ' ')"
rm "$HOME/.ai-core/usage.log"
out="$(cd "$work/project" && bash "$script" --tool claude 2>&1)"; rc=$?
check 'missing history: exit 0, burn unmeasured' '0 yes' "$rc $(matches 'burn unmeasured' "$out")"

echo 'a Claude reading above 100 %, as Claude reports a window over its limit, is read as it is'
printf '%s 99 %s - -\n%s 105 %s - -\n' "$((now - 120))" "$later" "$((now - 60))" "$later" > "$HOME/.ai-core/usage.log"
out="$(cd "$work/project" && bash "$script" --tool claude 2>&1)"; rc=$?
check 'a history line above 100 %: read, exit 0 below the limit' 0 "$rc"
claude_record "{\"recorded_at\":$now,\"rate_limits\":{\"five_hour\":{\"used_percentage\":106,$window}}}"
check 'a live reading above 100 %: at the limit, exit 3' 3 "$rc"
check 'shown as it is' yes "$(matches '^five_hour +106 % used' "$out")"
rm "$HOME/.ai-core/usage.log"

echo 'a status-line replacement cannot mix quota values with another reading timestamp'
mkdir -p "$work/replacing-bin"
export REAL_CAT="$(command -v cat)" REAL_JQ="$(command -v jq)"
export QUOTA_FILE="$HOME/.ai-core/usage.json" QUOTA_NEXT="$work/quota-next.json" QUOTA_REPLACED="$work/quota-replaced"
cat > "$work/replacing-bin/cat" <<'TOOL'
#!/usr/bin/env bash
case "${0##*/}" in cat) reader="$REAL_CAT" ;; jq) reader="$REAL_JQ" ;; esac
"$reader" "$@"; rc=$?
for arg in "$@"; do
  if [ "$arg" = "$QUOTA_FILE" ] && [ ! -e "$QUOTA_REPLACED" ]; then
    cp "$QUOTA_NEXT" "$QUOTA_FILE"
    : > "$QUOTA_REPLACED"
  fi
done
exit "$rc"
TOOL
cp "$work/replacing-bin/cat" "$work/replacing-bin/jq"
chmod +x "$work/replacing-bin/"*
printf '{"recorded_at":%s,"rate_limits":{"five_hour":{"used_percentage":5,%s}}}\n' "$((now - 1800))" "$window" > "$QUOTA_FILE"
printf '{"recorded_at":%s,"rate_limits":{"five_hour":{"used_percentage":95,%s}}}\n' "$now" "$window" > "$QUOTA_NEXT"
out="$(cd "$work/project" && PATH="$work/replacing-bin:$PATH" bash "$script" --tool claude 2>&1)"; rc=$?
check 'the replacement happened between reads' yes "$([ -e "$QUOTA_REPLACED" ] && echo yes || echo no)"
check 'quota and timestamp come from the same snapshot' "recorded $(when "$((now - 1800))"), limit 92 %" "$(grep '^recorded ' <<< "$out")"

echo 'the common percentage limit is decimal and within zero to one hundred'
codex_record "$(codex_with "{\"used_percent\":95,\"window_minutes\":300,\"resets_at\":$soon}")"
out="$(cd "$work/project" && bash "$script" --tool codex --stop-at 092 2>&1)"; rc=$?
check 'leading zero: decimal 92, exit 3, no arithmetic error' '3 yes no' "$rc $(matches 'limit 92 % used' "$out") $(grep -q 'base\|arithmetic\|integer expected' <<< "$out" && echo yes || echo no)"
for limit in 101 999999999999999999999999; do
  out="$(cd "$work/project" && bash "$script" --tool codex --stop-at "$limit" 2>&1)"; rc=$?
  check "out-of-range limit $limit: exit 2" 2 "$rc"
done
rm -rf "$HOME/.codex"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
