#!/usr/bin/env bash
# What the status line records of the account's usage windows, and what `usage` makes of it: the
# limit reached, the limit not reached, a window whose reset has passed, nothing recorded, and the
# burn measured from the history with the hour a window reaches the limit, which stops no start.
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
mkdir -p "$HOME" "$work/project" "$work/stub"
# No test calls the real codex: the stub fails unless STUB_MODE says it refills, and every call is logged.
cat > "$work/stub/codex" <<'STUB'
#!/usr/bin/env bash
echo "$PWD $*" >> "$STUB_CALLS"
sleep "${STUB_DELAY:-0}"
case "${STUB_MODE:-fail}" in
  refill)
    dir="${CODEX_HOME:-$HOME/.codex}/sessions/2026/10/28"; mkdir -p "$dir"
    printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":0,"window_minutes":300,"resets_at":%s},"secondary":null}}}\n' \
      "$(date -u '+%Y-%m-%dT%H:%M:%S.000Z')" "$(( $(date +%s) + 18000 ))" > "$dir/rollout-stub-$$.jsonl" ;;
  silent) ;;
  stdin-first) printf 'Reading additional input from stdin...\n\nERROR: You have hit your usage limit.\n' >&2; exit 1 ;;
  stderr) printf '%s' "${STUB_STDERR-}" >&2; exit 1 ;;
  *) echo "Not logged in" >&2; exit 1 ;;
esac
STUB
chmod +x "$work/stub/codex"
export PATH="$work/stub:$PATH" STUB_CALLS="$work/codex-calls"
: > "$STUB_CALLS"

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
check 'what to do'               yes "$(grep -q '^a window stands at 92 % used or more: finish the step in hand' <<< "$out" && echo yes || echo no)"
echo 'below a limit given: exit 0'
out="$(cd "$work/project" && bash "$root/bin/usage.sh" --stop-at 96 2>&1)"; rc=$?
check 'exit 0'                   0 "$rc"
echo "the project's own limit: USAGE_STOP_AT in its config.env"
mkdir -p "$work/project/.ai-core"; printf 'USAGE_STOP_AT="96"\n' > "$work/project/.ai-core/config.env"
out="$(cd "$work/project" && bash "$root/bin/usage.sh" 2>&1)"; rc=$?
check 'exit 0 at 95 % under 96'  0 "$rc"
check 'it names the limit'       yes "$(grep -q ', limit 96 % used$' <<< "$out" && echo yes || echo no)"
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
check 'the week, as the share used' yes "$(matches "^seven_day    7 % used  resets $(when "$later"), in (23 h 59 min|24 h 0 min)  burn unmeasured$" "$(sed -n 1p <<< "$out")")"
check 'the five hours'           yes "$(matches "^five_hour   12 % used  resets $(when "$soon"), in (59 min|1 h 0 min)  burn unmeasured$" "$(sed -n 2p <<< "$out")")"
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
cp "$root/lib/common.sh" "$root/lib/tool-order.sh" "$work/mutant/lib/"
plant() {  # plant <file under the root> <sed script>: the mutant is the whole tree of usage, with that one file changed
  cp "$root/bin/usage.sh" "$work/mutant/bin/usage.sh"; cp "$root/lib/usage.sh" "$work/mutant/lib/usage.sh"
  sed "$2" "$root/$1" > "$work/mutant/$1"
  if cmp -s "$root/$1" "$work/mutant/$1"; then echo "  FAIL the planted defect left $1 as it was: $2"; failed=$((failed + 1)); fi
}
plant bin/usage.sh 's/tool="$2"/tool="claude"/'
out="$(cd "$work/project" && bash "$work/mutant/bin/usage.sh" --tool codex 2>&1)"; rc=$?
check 'ignoring selector is caught' 0 "$rc"
plant bin/usage.sh 's/exit 3/exit 0/g'
out="$(cd "$work/project" && bash "$work/mutant/bin/usage.sh" --tool codex 2>&1)"; rc=$?
check 'non-stopping mutant is caught' 0 "$rc"
echo 'Codex: the burn from the readings in its session files'
iso() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%S.000Z' 2>/dev/null || date -u -r "$1" '+%Y-%m-%dT%H:%M:%S.000Z'; }
reading() { printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":%s,"window_minutes":300,"resets_at":%s},"secondary":null}}}\n' "$(iso "$1")" "$2" "$soon"; }
{ reading "$((now - 1800))" 50; reading "$now" 80; } > "$sessions/rollout-burn.jsonl"
out="$(cd "$work/project" && CODEX_THREAD_ID=t bash "$root/bin/usage.sh" 2>&1)"; rc=$?
check 'Codex projected to its limit still starts: exit 0'  0 "$rc"
check 'the burn and the hour, as the share used' yes "$(matches "^five_hour   80 % used  resets .*  burn 60.0 %/h, 92 % used at $(when "$((now + 720))")$" "$(sed -n 1p <<< "$out")")"
rm -rf "$HOME/.codex"
out="$(cd "$work/project" && CODEX_THREAD_ID=t bash "$root/bin/usage.sh" 2>&1)"; rc=$?
check 'no Codex session file: exit 2'  2 "$rc"
check 'it says why'              yes "$(grep -q 'no usage recorded yet: Codex records it' <<< "$out" && echo yes || echo no)"

echo 'the burn from the history: a window that reaches the limit before its reset names the hour, and starts go on up to the limit'
week=$((now + 4 * 86400))
history() { printf '%s %s %s %s %s\n' "$((now - 1800))" "$1" "$2" "$3" "$week" > "$HOME/.ai-core/usage.log"
  printf '{"recorded_at":%s,"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":%s,"resets_at":%s}}}\n' "$now" "$4" "$2" "$5" "$week" > "$HOME/.ai-core/usage.json"; }
history 50 "$soon" 10 80 10
out="$(cd "$work/project" && bash "$root/bin/usage.sh" 2>&1)"; rc=$?
check 'exit 0 below the limit (planted: the old refusal exited 4)' 0 "$rc"
check 'the hour it reaches 92 %' yes "$(matches "^five_hour   80 % used  resets $(when "$soon"), in (59 min|1 h 0 min)  burn 60.0 %/h, 92 % used at $(when "$((now + 720))")$" "$(sed -n 1p <<< "$out")")"
check 'a week without burn'      yes "$(matches "^seven_day   10 % used  resets $(when "$week"), in (3 d 23 h|4 d 0 h)  burn 0.0 %/h$" "$(sed -n 2p <<< "$out")")"
check 'no refusal'               no "$(grep -q 'start nothing new' <<< "$out" && echo yes || echo no)"
echo 'the same burn with the reset minutes away: the window carries on (innocent case)'
history 50 "$((now + 300))" 10 80 10
out="$(cd "$work/project" && bash "$root/bin/usage.sh" 2>&1)"; rc=$?
check 'exit 0'                   0 "$rc"
check 'what it stands at then'   yes "$(matches "  burn 60.0 %/h, 85 % used at reset$" "$(sed -n 1p <<< "$out")")"
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
check 'the warning'              yes "$(matches "^seven_day reaches 92 % used at $(when "$((now + 3120))"), before its reset; the person who holds the account watches it$" "$out")"
echo 'a window at the limit outranks a projection'
history 50 "$soon" 10 95 10
out="$(cd "$work/project" && bash "$root/bin/usage.sh" 2>&1)"; rc=$?
check 'exit 3'                   3 "$rc"
plant bin/usage.sh 's/\[ -n "\$cross" \] || continue/[ -n "$cross" ] \&\& exit 4/'
history 50 "$soon" 10 80 10
out="$(cd "$work/project" && bash "$work/mutant/bin/usage.sh" 2>&1)"; rc=$?
check 'a mutant that refuses on the projection is caught' 4 "$rc"

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
plant lib/usage.sh 's/if \[.used_percentage, .resets_at\]/(.used_percentage \/\/= 0) | if [.used_percentage, .resets_at]/'
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
  check "Codex, $1: no window" 0 "$(grep -c '% used  reset' <<< "$out")"
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
check 'Codex, its window'        1 "$(grep -c '^five_hour    5 % used' <<< "$out")"
codex_record "$(printf '{"timestamp":"2026-10-13T07:09:45.777Z","payload":{"rate_limits":{"primary":{"used_percent":5,"window_minutes":300,"resets_at":%s},"secondary":{"used_percent":0.0,"window_minutes":0,"resets_at":%s}}}}' "$soon" "$soon")"
check 'Codex, a window of 0 minutes, as Codex writes one beside a real window, says nothing: exit 0' 0 "$rc"
check 'Codex, only the real window shown' '1 0' "$(grep -c '^five_hour    5 % used' <<< "$out") $(grep -c '0_minutes' <<< "$out")"
plant lib/usage.sh 's/if \[.used_percent, .window_minutes, .resets_at\]/(.used_percent \/\/= 0) | if [.used_percent, .window_minutes, .resets_at]/'
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
check 'the newest value is shown' yes "$(matches '^five_hour +99 % used' "$out")"
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
check 'the history error is one line, without the lines read before it' 1 "$(grep -c '^error:' <<< "$out")"
check 'an unreadable quota shows no partial windows beside the audit' 0 "$(grep -cE '^(five_hour|seven_day) ' <<< "$out" || true)"
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
check 'quota and timestamp come from the same snapshot' "recorded $(when "$((now - 1800))"), limit 92 % used" "$(grep '^recorded ' <<< "$out")"

echo 'the common percentage limit is decimal and within zero to one hundred'
codex_record "$(codex_with "{\"used_percent\":95,\"window_minutes\":300,\"resets_at\":$soon}")"
out="$(cd "$work/project" && bash "$script" --tool codex --stop-at 092 2>&1)"; rc=$?
check 'leading zero: decimal 92, exit 3, no arithmetic error' '3 yes no' "$rc $(matches 'limit 92 % used' "$out") $(grep -q 'base\|arithmetic\|integer expected' <<< "$out" && echo yes || echo no)"
for limit in 101 999999999999999999999999; do
  out="$(cd "$work/project" && bash "$script" --tool codex --stop-at "$limit" 2>&1)"; rc=$?
  check "out-of-range limit $limit: exit 2" 2 "$rc"
done
rm -rf "$HOME/.codex"

echo 'a Codex record older than one hour is renewed by one minimal call; a record of one hour or less is used as it is'
old_codex_record() { rm -rf "$HOME/.codex" "$HOME/.ai-core/codex-usage-refresh.failed"; mkdir -p "$sessions"; codex_line 99 null > "$sessions/rollout-old.jsonl"; : > "$STUB_CALLS"; }
calls() { wc -l < "$STUB_CALLS" | tr -d ' '; }
codex_usage() { out="$(cd "$work/project" && bash "${1:-$root/bin/usage.sh}" --tool codex 2>&1)"; rc=$?; }
helper_model="$(awk -F'\t' '$1 == "codex" && $2 == "helper" { print $4 }' "$root/templates/.ai-core/models.tsv")"
old_codex_record
STUB_MODE=refill codex_usage
check 'a refill behind an old record: the new reading, exit 0' '0 yes' "$rc $(matches '^five_hour +0 % used' "$out")"
check 'one call'                 1 "$(calls)"
check 'on the cheapest model of the table, read-only, in a scratch folder' yes "$(grep -q -- "^/.* exec --skip-git-repo-check -s read-only -m $helper_model " "$STUB_CALLS" && echo yes || echo no)"
check 'the scratch folder is gone, and no repository' no "$(d="$(cut -d' ' -f1 "$STUB_CALLS")"; [ -e "$d" ] || [ "$d" = "$work/project" ] && echo yes || echo no)"
check 'the reading names its own time' yes "$(matches "^recorded $(when "$(date +%s)"), limit 92 % used$" "$(grep '^recorded ' <<< "$out")")"
check 'no failure to report'     0 "$(grep -c 'refresh failed' <<< "$out")"
echo 'the same reader asked again at once: the record is fresh, no second call'
STUB_MODE=refill codex_usage
check 'no second call'           1 "$(calls)"
echo 'the call fails with its cause after a first line about stdin: the line names the cause'
old_codex_record
STUB_MODE=stdin-first codex_usage
check 'the line names the cause, not the stdin line' 1 "$(grep -c '^the Codex record is older than 60 minutes and its refresh failed: codex exec exited 1: ERROR: You have hit your usage limit\.$' <<< "$out")"
echo 'failure diagnostics prefer an error substring, else the last non-empty line, and keep at most 200 characters'
padding="$(printf '%4096s' '' | tr ' ' x)"
for diagnostic in mixed-case no-error empty blank terrorist errorless long-error long-fallback late-error; do
  case "$diagnostic" in
    mixed-case) stderr=$'Reading additional input from stdin...\nErRoR: first failure\nERROR: second failure\n'; expected='ErRoR: first failure' ;;
    no-error) stderr=$'Reading additional input from stdin...\n\nNot logged in\n\n'; expected='Not logged in' ;;
    empty) stderr=''; expected='' ;;
    blank) stderr=$'\n\n\n'; expected='' ;;
    terrorist|errorless) stderr="$diagnostic"$' notice\nERROR: actual failure\n'; expected="$diagnostic notice" ;;
    long-error) stderr="Error: $padding"; expected="Error: ${padding:0:193}" ;;
    long-fallback) stderr=$'Reading additional input from stdin...\n'"$padding"$'\n\n'; expected="${padding:0:200}" ;;
    late-error) stderr="$padding"$' ERROR: beyond the cutoff\nlast line\n'; expected="${padding:0:200}" ;;
  esac
  old_codex_record
  STUB_MODE=stderr STUB_STDERR="$stderr" codex_usage
  check "$diagnostic: old quota and one call" '3 1' "$rc $(calls)"
  check "$diagnostic: one bounded diagnostic line" "the Codex record is older than 60 minutes and its refresh failed: codex exec exited 1: $expected" "$(sed -n '/^the Codex record is older /p' <<< "$out")"
  check "$diagnostic: the same reason is cached" "codex exec exited 1: $expected" "$(cut -f2- "$HOME/.ai-core/codex-usage-refresh.failed")"
done
echo 'the call fails: the old record, and one line that says why'
old_codex_record
codex_usage
check 'the old week is shown, exit 3' '3 yes' "$rc $(matches '^seven_day +99 % used' "$out")"
check 'one call'                 1 "$(calls)"
check 'one line names the failure' 1 "$(grep -c '^the Codex record is older than 60 minutes and its refresh failed: codex exec exited 1: Not logged in$' <<< "$out")"
echo 'asked again within the hour after the failure: no second call, and the line says when it failed'
codex_usage
check 'no second call'           1 "$(calls)"
check 'the old week, exit 3'     '3 yes' "$rc $(matches '^seven_day +99 % used' "$out")"
check 'the line names the failure and its age' 1 "$(grep -c '^the Codex record is older than 60 minutes and its refresh failed: codex exec exited 1: Not logged in, 0 minutes ago; no new call until 60 minutes after it$' <<< "$out")"
echo 'more than an hour after the failure: a new call'
AI_CORE_NOW=$(( $(date +%s) + 3660 )) codex_usage
check 'the second call'          2 "$(calls)"
old_codex_record
STUB_MODE=silent codex_usage
check 'a call that wrote no record is named' 1 "$(grep -c 'its refresh failed: codex exec answered, but wrote no usage record$' <<< "$out")"
check 'and the status page snapshot carries the line' yes "$(matches 'refresh failed' "$(bash -c '. "$1/lib/common.sh"; . "$1/lib/usage.sh"; usage_snapshot codex | jq -r .notice' _ "$root" 2>&1)")"
echo 'a record of one hour or younger makes no call (innocent)'
rm -rf "$HOME/.codex"; mkdir -p "$sessions"; : > "$STUB_CALLS"
reading "$((now - 3500))" 5 > "$sessions/rollout-young.jsonl"
STUB_MODE=refill codex_usage
check 'used as it is, exit 0'    '0 yes' "$rc $(matches '^five_hour +5 % used' "$out")"
check 'no call'                  0 "$(calls)"
check 'nothing to report'        0 "$(grep -c 'refresh failed' <<< "$out")"
echo 'two readers that find the same old record at once start one call between them'
old_codex_record
for reader in 1 2; do (cd "$work/project" && STUB_MODE=refill STUB_DELAY=1 bash "$root/bin/usage.sh" --tool codex > "$work/reader-$reader.out" 2>&1; echo $? > "$work/reader-$reader.rc") & done
wait
check 'one call between them'    1 "$(calls)"
check 'both read the new record' '0 0 yes yes' "$(cat "$work/reader-1.rc") $(cat "$work/reader-2.rc") $(matches '^five_hour +0 % used' "$(cat "$work/reader-1.out")") $(matches '^five_hour +0 % used' "$(cat "$work/reader-2.out")")"
echo 'two readers that find the same old record at once, and the call fails: still one call between them'
old_codex_record
for reader in 1 2; do (cd "$work/project" && STUB_DELAY=1 bash "$root/bin/usage.sh" --tool codex > "$work/reader-$reader.out" 2>&1; echo $? > "$work/reader-$reader.rc") & done
wait
check 'one call between them'    1 "$(calls)"
check 'both show the old week and name the failure' '3 3 1 1' "$(cat "$work/reader-1.rc") $(cat "$work/reader-2.rc") $(grep -c 'its refresh failed: codex exec exited 1: Not logged in' "$work/reader-1.out") $(grep -c 'its refresh failed: codex exec exited 1: Not logged in' "$work/reader-2.out")"
echo 'a reader without the age check keeps the old reading (planted)'
plant lib/usage.sh 's/^USAGE_CODEX_MAX_AGE_SECONDS=3600$/USAGE_CODEX_MAX_AGE_SECONDS=99999999999/'
old_codex_record
STUB_MODE=refill codex_usage "$work/mutant/bin/usage.sh"
check 'it shows the old week and makes no call, so the refill case goes red' '3 yes 0' "$rc $(matches '^seven_day +99 % used' "$out") $(calls)"
echo 'a reader that keeps no failure calls again at once (planted)'
mkdir -p "$work/mutant/templates/.ai-core"; cp "$root/templates/.ai-core/models.tsv" "$work/mutant/templates/.ai-core/"
plant lib/usage.sh 's|failed="$lock_dir/codex-usage-refresh.failed"|failed=/dev/null|'
old_codex_record
codex_usage "$work/mutant/bin/usage.sh"; codex_usage "$work/mutant/bin/usage.sh"
check 'two calls, so the case asked again within the hour goes red' 2 "$(calls)"
echo 'a call that does not end in its time is stopped: the old record, and one line that says why'
plant lib/usage.sh 's/^USAGE_CODEX_REFRESH_SECONDS=120$/USAGE_CODEX_REFRESH_SECONDS=1/'
old_codex_record
started=$SECONDS; STUB_MODE=refill STUB_DELAY=10 codex_usage "$work/mutant/bin/usage.sh"
check 'the old week, exit 3, within seconds' '3 yes yes' "$rc $(matches '^seven_day +99 % used' "$out") $([ $((SECONDS - started)) -lt 8 ] && echo yes || echo "no: $((SECONDS - started)) s")"
check 'one line names the timeout' 1 "$(grep -c '^the Codex record is older than 60 minutes and its refresh failed: codex exec did not end in 1 seconds$' <<< "$out")"
echo 'a tool the refresh needs is not on the PATH: the old record, and one line that names it, without a call'
for missing in codex flock timeout; do
  farm="$work/path-without-$missing"; mkdir -p "$farm"
  for tool in bash env jq date grep ls cut awk sed mktemp dirname cat tr wc head tail rm mkdir sort git flock timeout; do
    [ "$tool" = "$missing" ] || ln -sf "$(command -v "$tool")" "$farm/$tool"
  done
  [ "$missing" = codex ] || ln -sf "$work/stub/codex" "$farm/codex"
  old_codex_record
  out="$(cd "$work/project" && PATH="$farm" STUB_MODE=refill bash "$root/bin/usage.sh" --tool codex 2>&1)"; rc=$?
  check "without $missing: the old week, exit 3, no call" '3 yes 0' "$rc $(matches '^seven_day +99 % used' "$out") $(calls)"
  check "without $missing: one line names it" 1 "$(grep -c "^the Codex record is older than 60 minutes and its refresh failed: $missing is not on the PATH$" <<< "$out")"
done
rm -rf "$HOME/.codex" "$HOME/.ai-core/codex-usage-refresh.failed"

echo 'the usage report joins native starts to historical choices and preserves quota exits'
mkdir -p "$HOME/.ai-core/sessions" "$work/audit-tools"
cat > "$work/audit-tools/claude" <<'TOOL'
#!/usr/bin/env bash
cat "$NATIVE_AGENTS"
TOOL
chmod +x "$work/audit-tools/claude"
export NATIVE_AGENTS="$work/native-agents.json"
name='build10001-shared-high-250k-abcde'
now="$(date +%s)"
jq -cn --argjson at "$((now - 100))" '{version:1,orders:[{generation:1,time:$at,tools:["codex","claude"]}]}' > "$HOME/.ai-core/tool-order.json"
jq -cn --arg project "$work/project" --argjson at "$((now - 80))" --slurpfile state "$HOME/.ai-core/tool-order.json" \
  '{version:1,time:$at,project:$project,phase:"build",class:"normal-hard",writer:"",order:$state[0].orders[0],
    selected:{tool:"codex",model:"shared",effort:"high"},refusal:"",reasons:[{tool:"codex",exit:0,reason:"quota left at selection"}]}' > "$HOME/.ai-core/phase-model.jsonl"
printf '%s\tclaude\n' "$work/project" > "$HOME/.ai-core/sessions/l10000.block"
jq -cn --arg name "$name" --arg cwd "$work/project" '[{name:$name,sessionId:"fixture-native",id:"short-id",cwd:$cwd}]' > "$NATIVE_AGENTS"
for kind in attempt native; do
  jq -cn --arg kind "$kind" --argjson at "$((now - 60))" '{version:1,kind:$kind,operation:"start",tool:"claude",model:"shared",effort:"high",invoked:$at,observed:($at+1),nativeIdentity:"fixture-native"}' >> "$HOME/.ai-core/sessions/$name.start.jsonl"
done
rm -f "$HOME/.ai-core/usage.log"
usage_report() { out="$(cd "$work/project" && PATH="$work/audit-tools:$PATH" bash "$root/bin/usage.sh" 2>&1)"; rc=$?; }
printf '{"recorded_at":%s,"rate_limits":{"five_hour":{"used_percentage":5,"resets_at":%s}}}\n' "$now" "$soon" > "$HOME/.ai-core/usage.json"
usage_report
check 'RED audit does not redefine a successful quota exit' 0 "$rc"
check 'a later Claude start is visibly red' yes "$(matches "^RED $name start:" "$out")"
check 'the saved order is shown' yes "$(matches '^tool order: codex,claude' "$out")"
check 'the actual set time is shown' yes "$(matches "^set at: $((now - 100)) " "$out")"
check 'per-tool counts and the matched denominator are visible' yes "$(matches 'codex 0, agy 0, claude 1; matched 1/1' "$out")"
printf '{"recorded_at":%s,"rate_limits":{"five_hour":{"used_percentage":99,"resets_at":%s}}}\n' "$now" "$soon" > "$HOME/.ai-core/usage.json"
usage_report
check 'audit does not erase quota exit 3' 3 "$rc"
printf '{"recorded_at":%s,"rate_limits":{"five_hour":{"used_percentage":80,"resets_at":%s}}}\n' "$now" "$soon" > "$HOME/.ai-core/usage.json"
printf '%s 20 %s - -\n' "$((now - 3600))" "$soon" > "$HOME/.ai-core/usage.log"
usage_report
check 'a projected window keeps exit 0 under the audit' 0 "$rc"
printf 'malformed\n' > "$HOME/.ai-core/tool-order.json"
usage_report
check 'an audit read failure turns that exit 0 into 2' 2 "$rc"
check 'audit read failure is named' yes "$(matches 'audit read failure' "$out")"
rm -f "$HOME/.ai-core/usage.log"
printf '{"recorded_at":%s,"rate_limits":{"five_hour":{"used_percentage":5,"resets_at":%s}}}\n' "$now" "$soon" > "$HOME/.ai-core/usage.json"
usage_report
check 'audit failure after a good quota is exit 2' 2 "$rc"
rm "$HOME/.ai-core/usage.json"
usage_report
check 'failed quota remains exit 2 beside a failed audit' 2 "$rc"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
