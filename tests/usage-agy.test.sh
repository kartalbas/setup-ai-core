#!/usr/bin/env bash
# What `usage --tool agy` makes of agy's answer to /usage: every bucket of every group a window
# named by its group and shown as the share used, the group of a model found from agy's own answers,
# the limit decided on the share used, the burn measured from the readings the command saved, and
# a refusal with its reason, never a made-up reading, for everything agy cannot give.
# The agy of these tests is a planted script on a PATH that holds nothing else of this machine, so
# the real agy is never reached. HOME and AI_CORE_HOME point into a temporary folder.
#
#   bash tests/usage-agy.test.sh

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export HOME="$work/home" AI_CORE_HOME="$work/home"
. "$root/tests/tool-environment.sh"
unset CODEX_HOME
mkdir -p "$HOME" "$work/project" "$work/tools" "$work/agy-bin" "$work/mutant/bin" "$work/mutant/lib"
cp "$root/lib/common.sh" "$root/lib/tool-order.sh" "$root/lib/usage.sh" "$work/mutant/lib/"

failed=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}
matches() { grep -Eq -e "$1" <<< "$2" && echo yes || echo "no: $2"; }
when() { LC_ALL=C date -d "@$1" '+%a %H:%M %Z' 2>/dev/null || LC_ALL=C date -r "$1" '+%a %H:%M %Z'; }
iso_z() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ'; }

# The commands usage.sh runs, and no agy: a PATH of these alone is a machine without agy.
for command in bash jq awk date git grep tail head cut cat ls find mktemp rm mkdir rmdir dirname sed sort tr wc touch sleep env node; do
  ln -sf "$(command -v "$command")" "$work/tools/$command"
done
cat > "$work/agy-bin/agy" <<'TOOL'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AGY_CALLS"
[ -z "${AGY_DELAY:-}" ] || sleep "$AGY_DELAY"
case "$1" in
  -p) [ -z "${AGY_FAILURE:-}" ] || { echo "$AGY_FAILURE" >&2; exit 1; }; cat "$AGY_ANSWER" ;;
  models) [ -z "${AGY_MODELS_FAILURE:-}" ] || { echo "$AGY_MODELS_FAILURE" >&2; exit 1; }; cat "$AGY_MODELS" ;;
  *) exit 64 ;;
esac
TOOL
chmod +x "$work/agy-bin/agy"
planted="$work/agy-bin:$work/tools"
export AGY_CALLS="$work/agy-calls" AGY_ANSWER="$work/answer.json" AGY_MODELS="$work/agy-models.txt"
cp "$root/tests/fixtures/agy-models.txt" "$AGY_MODELS"

script="$root/bin/usage.sh"
run() {  # run <PATH> <arguments>: usage.sh in a folder that is no repository
  local path="$1"; shift
  ( cd "$work/project" && PATH="$path" bash "$script" "$@" 2>&1 )
}
agy_run() { run "$planted" "$@"; }

now="$(date +%s)"; soon=$((now + 3600)); week_at=$((now + 4 * 86400))
history_dir="$HOME/.ai-core/usage-agy"
sample="$root/tests/fixtures/agy-usage.json"
# answer <remaining fraction of: Gemini week, Gemini 5 hours, Claude week, Claude 5 hours> [5-hour reset] [week reset]
# is the real answer of agy with the fractions and the resets put where a case wants them.
answer() {
  jq --argjson f "[$1,$2,$3,$4]" --arg five "$(iso_z "${5:-$soon}")" --arg week "$(iso_z "${6:-$week_at}")" '
    def put($g; $b; $fraction; $at): .command.data.groups[$g].buckets[$b] |= (.remaining_fraction = $fraction | .reset_time = $at);
    put(0; 0; $f[0]; $week) | put(0; 1; $f[1]; $five) | put(1; 0; $f[2]; $week) | put(1; 1; $f[3]; $five)' "$sample" > "$AGY_ANSWER"
}
# seed <group> <bucket> <seconds ago> <share used> <reset>: a reading a former call saved
seed() {
  local at=$(($(date +%s) - $3))
  mkdir -p "$history_dir"
  printf '%s\t%s\t%s\t%s\n' "$(jq -cn --arg g "$1" --arg b "$2" '[$g, $b]')" "$at" "$4" "$5" >> "$history_dir/$((at / 86400)).log"
}
forget() { rm -rf "$history_dir"; : > "$AGY_CALLS"; }
caught() {  # caught <what> <the status the script gives> <the status the mutant gave>
  check "$1" yes "$([ "$2" != "$3" ] && echo yes || echo "no: the mutant gave $3 as well")"
}
mutate() {  # mutate <sed script> <name>: a copy of usage.sh and its reader with one defect planted in either
  sed "$1" "$root/bin/usage.sh" > "$work/mutant/bin/usage.sh"
  sed "$1" "$root/lib/usage.sh" > "$work/mutant/lib/usage.sh"
  if cmp -s "$root/bin/usage.sh" "$work/mutant/bin/usage.sh" && cmp -s "$root/lib/usage.sh" "$work/mutant/lib/usage.sh"; then echo "  FAIL mutant $2 left the script as it was"; failed=$((failed + 1)); fi
  script="$work/mutant/bin/usage.sh"
}
restore() { script="$root/bin/usage.sh"; }

echo 'agy -p /usage: every bucket of every group is a window, named by its group, shown as the share used'
forget; answer 0.92 0.95 0.42 1
out="$(agy_run --tool agy)"; rc=$?
check 'exit 0'                   0 "$rc"
check 'the call'                 '-p /usage --output-format json' "$(sed -n 1p "$AGY_CALLS")"
check 'no model asked for: agy models is not called' 1 "$(wc -l < "$AGY_CALLS" | tr -d ' ')"
check 'Gemini week'              yes "$(matches "^Gemini Models: seven_day +8 % used  resets $(when "$week_at"), in (3 d 23 h|4 d 0 h)  burn unmeasured$" "$(sed -n 1p <<< "$out")")"
check 'Gemini five hours'        yes "$(matches "^Gemini Models: five_hour +5 % used  resets $(when "$soon"), in (59 min|1 h 0 min)  burn unmeasured$" "$(sed -n 2p <<< "$out")")"
check 'Claude week'              yes "$(matches "^Claude and GPT models: seven_day +58 % used  resets $(when "$week_at"), in (3 d 23 h|4 d 0 h)  burn unmeasured$" "$(sed -n 3p <<< "$out")")"
check 'Claude five hours, a bucket without a description' yes "$(matches "^Claude and GPT models: five_hour +0 % used  resets $(when "$soon"), in (59 min|1 h 0 min)  burn unmeasured$" "$(sed -n 4p <<< "$out")")"
check 'the limit is a share used' yes "$(matches '^recorded [A-Z][a-z]{2} [0-9:]{5} [A-Z]+, limit 92 % used$' "$(sed -n 5p <<< "$out")")"
echo 'the first read saves one reading a window, a second adds them again'
rows() { cat "$history_dir"/*.log 2>/dev/null | wc -l | tr -d ' '; }
check 'four rows'                4 "$(rows)"
check 'each row: a key, a time, a share used, a reset' 4 "$(awk -F'\t' 'NF == 4 && $2 > 0 && $3 + 0 == $3 && $4 > 0 { n++ } END { print n }' "$history_dir"/*.log)"
check 'the key names group and bucket' '["Claude and GPT models","3p-5h"]' "$(sed -n 4p "$history_dir"/*.log | cut -f1)"
check 'the share used it saved' '8 5 58 0' "$(cut -f3 "$history_dir"/*.log | tr '\n' ' ' | sed 's/ $//')"
out="$(agy_run --tool agy)"; rc=$?
check 'eight rows after two reads' 8 "$(rows)"
mutate 's/>> "$history\/$day.log"/> "$history\/$day.log"/' 'a history that is overwritten'
forget; out="$(agy_run --tool agy)"; out="$(agy_run --tool agy)"
caught 'a history that keeps only the last reading is caught' 8 "$(rows)"
restore
echo 'the readings a call saved are what the next call measures its burn from'
forget; answer 0.92 0.95 0.92 1
out="$(agy_run --tool agy)"
for log in "$history_dir"/*.log; do awk -F'\t' -v OFS='\t' '{ $2 = $2 - 1810; print }' "$log" > "$log.new" && mv "$log.new" "$log"; done
answer 0.92 0.95 0.92 0.2
out="$(agy_run --tool agy)"; rc=$?
check 'a burn measured from the saved rows: exit 0' 0 "$rc"
check 'its burn and the hour'    yes "$(matches '^Claude and GPT models: five_hour +80 % used  resets .*  burn 15[0-9]\.[0-9] %/h, 92 % used at [A-Z][a-z]{2} [0-9:]{5} [A-Z]+$' "$(sed -n 4p <<< "$out")")"

echo 'a model finds its group in what agy answers: the group whose description lists the family its name starts with'
forget; answer 0.92 0.95 0.42 1
out="$(agy_run --tool agy --model claude-opus-5-5-high)"; rc=$?
check 'exit 0'                   0 "$rc"
check 'agy models was asked'     'models' "$(sed -n 2p "$AGY_CALLS")"
check 'only the group of the model' "2 0" "$(grep -c '^Claude and GPT models' <<< "$out") $(grep -c 'Gemini' <<< "$out")"
out="$(agy_run --tool agy --model claude-sonnet-5-5-high)"; rc=$?
check 'Sonnet is in the same group' 2 "$(grep -c '^Claude and GPT models' <<< "$out")"
out="$(agy_run --tool agy --model gemini-3.8-flash-high)"; rc=$?
check 'the real versioned Gemini Flash model: exit 0, its group alone' '0 2' "$rc $(grep -c '^Gemini Models' <<< "$out")"
echo 'a full group holds its own models, and no other (innocent: the model of the other group)'
answer 0.92 0.95 0.05 1
out="$(agy_run --tool agy --model claude-opus-5-5-high)"; rc=$?
check 'Claude group at 95 % used: exit 3' 3 "$rc"
check 'what to do'               yes "$(matches '^a window stands at 92 % used or more: finish the step in hand' "$out")"
out="$(agy_run --tool agy --model gemini-3.8-flash-high)"; rc=$?
check 'the Gemini model is not held by the full Claude group: exit 0' 0 "$rc"
out="$(agy_run --tool agy)"; rc=$?
check 'no model: every group is judged, exit 3' 3 "$rc"
mutate 's/(if $model == "" then/(if true then/' 'judging every group'
out="$(agy_run --tool agy --model gemini-3.8-flash-high)"; rc=$?
caught 'a reader that judges every group for a model is caught' 0 "$rc"
restore
echo 'a malformed bucket of the other group does not hold the model (it judges only its own group)'
answer 0.92 0.95 0.42 1
jq '.command.data.groups[0].buckets[1].remaining_fraction = null' "$AGY_ANSWER" > "$work/bad.json"
out="$(AGY_ANSWER="$work/bad.json" agy_run --tool agy --model claude-opus-5-5-high)"; rc=$?
check 'exit 0'                   0 "$rc"
out="$(AGY_ANSWER="$work/bad.json" agy_run --tool agy)"; rc=$?
check 'without a model the same answer is refused' 2 "$rc"
jq '.command.data.groups[0].buckets = []' "$AGY_ANSWER" > "$work/bad.json"
out="$(AGY_ANSWER="$work/bad.json" agy_run --tool agy --model claude-opus-5-5-high)"; rc=$?
check 'missing buckets of an unrelated group do not hold the selected model' 0 "$rc"
echo 'a model that is unknown, unlisted or in two groups is refused'
out="$(agy_run --tool agy --model nope)"; rc=$?
check 'a model agy does not list: exit 2' 2 "$rc"
check 'it says so'               yes "$(matches 'agy does not list the model nope' "$out")"
out="$(agy_run --tool agy --model gemini-4-argon-high)"; rc=$?
check 'a listed model no group names a family of: exit 2' 2 "$rc"
check 'it names the model and what the groups list' yes "$(matches 'no group lists the family of gemini-4-argon-high \(Gemini 4 Argon \(High\)\); the groups list: Gemini Models: Gemini Flash, Gemini Pro; Claude and GPT models: Claude Opus, Claude Sonnet, GPT-OSS' "$out")"
jq '.command.data.groups[0].description = "Models within this group: Gemini Flash, Claude Opus"' "$AGY_ANSWER" > "$work/bad.json"
out="$(AGY_ANSWER="$work/bad.json" agy_run --tool agy --model claude-opus-5-5-high)"; rc=$?
check 'two groups listing the family: exit 2' 2 "$rc"
check 'it says ambiguous'        yes "$(matches 'is listed by the groups Gemini Models and Claude and GPT models, so its group is ambiguous' "$out")"
out="$(AGY_MODELS_FAILURE=offline agy_run --tool agy --model claude-opus-5-5-high)"; rc=$?
check 'agy models failing: exit 2 with its reason' "2 yes" "$rc $(matches 'agy models exited 1: offline' "$out")"

echo 'the limit is a share used: fractions, whatever the display rounds to'
forget; answer 0.92 0.95 0.08 1
out="$(agy_run --tool agy)"; rc=$?
check '92 % used: at the limit, exit 3' 3 "$rc"
check 'shown as 92 % used'       yes "$(matches '^Claude and GPT models: seven_day +92 % used' "$(sed -n 3p <<< "$out")")"
answer 0.92 0.95 0.0801 1
out="$(agy_run --tool agy)"; rc=$?
check '91.99 % used: below the limit, exit 0' 0 "$rc"
check 'shown as 91 % used'       yes "$(matches '^Claude and GPT models: seven_day +91 % used' "$(sed -n 3p <<< "$out")")"
mutate 's/exit !(u >= s)/exit !(int(u + 0.5) >= s)/' 'a limit decided on the rounded share used'
out="$(agy_run --tool agy)"; rc=$?
caught 'a limit decided on the rounded share used is caught' 0 "$rc"
mutate 's/exit !(u >= s)/exit !(int(100 - u) <= 100 - s)/' 'a limit decided on the share left rounded down'
out="$(agy_run --tool agy)"; rc=$?
caught 'a limit decided on the share left rounded down is caught' 0 "$rc"
restore
answer 0.92 0.95 0.080000001 1
out="$(agy_run --tool agy)"; rc=$?
check '91.9999999 % used is still below the limit: exit 0' 0 "$rc"
answer 0.92 0.95 0.0801 1
out="$(agy_run --tool agy --stop-at 96)"; rc=$?
check 'the limit given: 91.99 % used under 96, exit 0' 0 "$rc"
check 'and named as used'        yes "$(matches ', limit 96 % used$' "$out")"

echo 'a window projected to the limit before its reset: the burn is of its own bucket and its own reset, and starts go on'
forget; answer 0.92 0.95 0.92 0.2
seed 'Claude and GPT models' 3p-5h 1800 50 "$soon"
out="$(agy_run --tool agy)"; rc=$?
check 'five hours at 80 % used and 60 %/h: exit 0' 0 "$rc"
check 'the burn and the hour, as the share used' yes "$(matches '^Claude and GPT models: five_hour +80 % used  resets .*  burn (59\.9|60\.0) %/h, 92 % used at [A-Z][a-z]{2} [0-9:]{5} [A-Z]+$' "$(sed -n 4p <<< "$out")")"
check 'no refusal'               no "$(grep -q 'start nothing new' <<< "$out" && echo yes || echo no)"
echo 'the same burn with the reset minutes away: the window carries on (innocent)'
forget; answer 0.92 0.95 0.92 0.2 "$((now + 300))"
seed 'Claude and GPT models' 3p-5h 1800 50 "$((now + 300))"
out="$(agy_run --tool agy)"; rc=$?
check 'exit 0'                   0 "$rc"
check 'what it stands at by the reset' yes "$(matches '  burn (59\.9|60\.0) %/h, 8[456] % used at reset$' "$(sed -n 4p <<< "$out")")"
echo 'two readings less than 30 minutes apart: unmeasured, no burn made up'
forget; answer 0.92 0.95 0.92 0.2
seed 'Claude and GPT models' 3p-5h 600 50 "$soon"
out="$(agy_run --tool agy)"; rc=$?
check 'exit 0'                   0 "$rc"
check 'unmeasured'               yes "$(matches '  burn unmeasured$' "$(sed -n 4p <<< "$out")")"
echo 'a new reset does not reuse the burn of the window before'
forget; answer 0.92 0.95 0.92 0.2
seed 'Claude and GPT models' 3p-5h 1800 10 "$((soon - 18000))"
out="$(agy_run --tool agy)"; rc=$?
check 'exit 0'                   0 "$rc"
check 'unmeasured'               yes "$(matches '  burn unmeasured$' "$(sed -n 4p <<< "$out")")"
mutate 's/\$4 == r && //' 'a burn across resets'
out="$(agy_run --tool agy)"; rc=$?
check 'a burn measured across resets is caught' yes "$(grep -q '  burn unmeasured$' <<< "$(sed -n 4p <<< "$out")" && echo no || echo yes)"
restore
echo 'two groups with the same five-hour reset keep their own histories'
forget; answer 0.92 0.2 0.92 0.2
seed 'Claude and GPT models' 3p-5h 1810 50 "$soon"
seed 'Gemini Models' gemini-5h 1800 79 "$soon"
out="$(agy_run --tool agy)"; rc=$?
check 'Claude projected: exit 0' 0 "$rc"
check 'Claude: 60 %/h'           yes "$(matches '^Claude and GPT models: five_hour .*  burn (59\.[0-9]|60\.0) %/h' "$(sed -n 4p <<< "$out")")"
check 'Gemini: 2 %/h'            yes "$(matches '^Gemini Models: five_hour .*  burn (1\.9|2\.0) %/h, ' "$(sed -n 2p <<< "$out")")"
mutate 's/\$1 == k && //' 'histories of all windows mixed'
out="$(agy_run --tool agy)"; rc=$?
check 'a reader that mixes the histories is caught' wrong "$(grep -Eq '^Gemini Models: five_hour .*  burn (1\.9|2\.0) %/h, ' <<< "$(sed -n 2p <<< "$out")" && echo right || echo wrong)"
restore
echo 'JSON escapes in a bucket identity survive the forecast lookup'
forget; answer 0.92 0.95 0.92 0.2
jq '.command.data.groups[1].buckets[1].id = "quota\\bucket"' "$AGY_ANSWER" > "$work/escaped.json"
seed 'Claude and GPT models' 'quota\bucket' 1800 50 "$soon"
out="$(AGY_ANSWER="$work/escaped.json" agy_run --tool agy)"; rc=$?
check 'escaped bucket identity keeps its measured burn: exit 0' 0 "$rc"
echo 'a week that fills before its reset warns and stops nothing; a window at the limit outranks a projection'
forget; answer 0.92 0.95 0.2 1
seed 'Claude and GPT models' 3p-weekly 1800 20 "$week_at"
out="$(agy_run --tool agy)"; rc=$?
check 'exit 0'                   0 "$rc"
check 'the warning names the group and the share used' yes "$(matches '^Claude and GPT models: seven_day reaches 92 % used at [A-Z][a-z]{2} [0-9:]{5} [A-Z]+, before its reset; the person who holds the account watches it$' "$out")"
forget; answer 0.92 0.95 0.05 0.2
seed 'Claude and GPT models' 3p-5h 1800 50 "$soon"
out="$(agy_run --tool agy)"; rc=$?
check 'the week at the limit and the five hours projected: exit 3' 3 "$rc"
echo 'a window whose reset has passed counts as reset, with nothing used'
forget; answer 0.92 0.95 0.92 0.01 "$((now - 60))"
out="$(agy_run --tool agy)"; rc=$?
check 'exit 0'                   0 "$rc"
check 'reported as reset, nothing used' "Claude and GPT models: five_hour   0 % used  reset since $(when "$((now - 60))")" "$(sed -n 4p <<< "$out")"
check 'the week beside it, as the share used' yes "$(matches '^Gemini Models: seven_day +8 % used  resets' "$(sed -n 1p <<< "$out")")"
mutate 's/   0 %% used  reset since/ 100 %% used  reset since/' 'a reset window shown as all used'
out="$(agy_run --tool agy)"
caught 'a reset window shown as all used is caught' 1 "$(sed -n 4p <<< "$out" | grep -c '   0 % used  reset since')"
restore
mutate 's/BEGIN { printf "%d", u }/BEGIN { printf "%d", 100 - u }/' 'a window shown as the share left'
out="$(agy_run --tool agy)"
caught 'a window shown as the share left is caught' yes "$(matches '^Gemini Models: seven_day +8 % used  resets' "$(sed -n 1p <<< "$out")")"
restore

echo 'what agy cannot give is exit 2 with the reason, and no window'
refuse() {  # refuse <name> <reason pattern> <jq filter over the real answer>
  jq "$3" "$sample" > "$work/bad.json"
  out="$(AGY_ANSWER="$work/bad.json" agy_run --tool agy)"; rc=$?
  check "$1: exit 2" 2 "$rc"
  check "$1: the reason" yes "$(matches "$2" "$out")"
  check "$1: no window" 0 "$(grep -c '% used  reset' <<< "$out")"
}
refuse 'a fraction that is null'      'Gemini Models/gemini-5h: remaining_fraction null is not a number from 0 to 1' ".command.data.groups[0].buckets[1].remaining_fraction = null"
refuse 'a fraction missing'           'Gemini Models/gemini-5h: remaining_fraction null' "del(.command.data.groups[0].buckets[1].remaining_fraction)"
refuse 'a window that reads disabled' 'remaining_fraction "disabled" is not a number' ".command.data.groups[0].buckets[1].remaining_fraction = \"disabled\""
refuse 'a fraction as text'           'remaining_fraction "0.5" is not a number' ".command.data.groups[0].buckets[1].remaining_fraction = \"0.5\""
refuse 'a fraction above 1'           'remaining_fraction 1.5 is not a number from 0 to 1' ".command.data.groups[0].buckets[1].remaining_fraction = 1.5"
refuse 'a fraction below 0'           'remaining_fraction -0.1 is not a number from 0 to 1' ".command.data.groups[0].buckets[1].remaining_fraction = -0.1"
refuse 'a reset that is no date'      'Gemini Models/gemini-5h: .*does not match' ".command.data.groups[0].buckets[1].reset_time = \"2026-13-01T00:00:00Z\""
refuse 'a nonexistent calendar date' 'Gemini Models/gemini-5h: .*calendar' '.command.data.groups[0].buckets[1].reset_time = "2027-02-31T00:00:00Z"'
forget
refuse 'a reset at epoch zero' 'Gemini Models/gemini-5h: .*positive epoch second' '.command.data.groups[0].buckets[1].reset_time = "1970-01-01T00:00:00Z"'
answer 0.92 0.95 0.42 1
out="$(agy_run --tool agy)"; rc=$?
check 'a rejected timestamp does not poison the next valid reading' 0 "$rc"
refuse 'a reset in words'             'Gemini Models/gemini-5h: reset_time "tomorrow" is not a UTC time' ".command.data.groups[0].buckets[1].reset_time = \"tomorrow\""
refuse 'a reset missing'              'reset_time null is not a UTC time' "del(.command.data.groups[0].buckets[1].reset_time)"
refuse 'a reset with an offset'       'reset_time "2026-11-01T02:21:43\+00:00" is not a UTC time' ".command.data.groups[0].buckets[1].reset_time = \"2026-11-01T02:21:43+00:00\""
refuse 'a window of another length'   'Gemini Models/gemini-5h: the window "daily" is neither weekly nor 5h' ".command.data.groups[0].buckets[1].window = \"daily\""
refuse 'a bucket without an id'       'a bucket of Gemini Models has no id' "del(.command.data.groups[0].buckets[1].id)"
refuse 'two buckets with one id'      'two buckets of a group share an id' ".command.data.groups[0].buckets[1].id = \"gemini-weekly\""
refuse 'two groups with one name'     'two groups are named alike' ".command.data.groups[1].name = .command.data.groups[0].name"
refuse 'a group without a name'       'a group has no name' "del(.command.data.groups[0].name)"
refuse 'a group without buckets'      'the group Gemini Models has no buckets' ".command.data.groups[0].buckets = []"
refuse 'no groups'                    'it holds no usage groups' ".command.data.groups = []"
refuse 'a signed-out answer without a command' 'it holds no usage groups' "del(.command)"
refuse 'a status that is not SUCCESS' 'the status "ERROR" is not SUCCESS' ".status = \"ERROR\""
for raw in '{bad' '' '[]' 'null'; do
  printf '%s' "$raw" > "$work/bad.json"
  out="$(AGY_ANSWER="$work/bad.json" agy_run --tool agy)"; rc=$?
  check "an answer of '$raw': exit 2" 2 "$rc"
  check "an answer of '$raw': the reason" yes "$(matches 'the answer of agy -p /usage is not a JSON object' "$out")"
done
cat "$sample" "$sample" > "$work/bad.json"
out="$(AGY_ANSWER="$work/bad.json" agy_run --tool agy)"; rc=$?
check 'two JSON answers are not one quota response' '2 yes' "$rc $(matches 'one JSON object' "$out")"
out="$(AGY_FAILURE='not signed in' agy_run --tool agy)"; rc=$?
check 'agy failing: exit 2'      2 "$rc"
check 'agy failing: its own reason' yes "$(matches 'agy -p /usage exited 1: not signed in' "$out")"
out="$(run "$work/tools" --tool agy)"; rc=$?
check 'no agy on the PATH: exit 2' 2 "$rc"
check 'no agy: the reason'       yes "$(matches 'agy is not on the PATH' "$out")"
echo '   a planted defect: a refusal that exits 0, and a fraction made up as 0 (nothing left)'
answer 0.92 0.95 0.92 1
jq '.command.data.groups[0].buckets[1].remaining_fraction = null' "$AGY_ANSWER" > "$work/bad.json"
mutate '/^usage_read "\$tool"/s/exit 2/exit 0/' 'a refusal that exits 0'
out="$(AGY_ANSWER="$work/bad.json" agy_run --tool agy)"; rc=$?
caught 'a refusal that exits 0 is caught' 2 "$rc"
mutate 's/(.remaining_fraction | type) != "number" or .remaining_fraction < 0 or .remaining_fraction > 1/false/; s/100 \* .remaining_fraction/100 * (.remaining_fraction \/\/ 0)/' 'a missing fraction read as 0'
out="$(AGY_ANSWER="$work/bad.json" agy_run --tool agy)"; rc=$?
caught 'a missing fraction read as nothing left is caught' 2 "$rc"
restore

echo 'the history: written in one append, a week kept, a bad one refused with its reason'
forget; answer 0.92 0.95 0.92 1
mkdir -p "$history_dir"; day=$(($(date +%s) / 86400))
printf 'x\n' > "$history_dir/notes.txt"
printf '["Gemini Models","gemini-5h"]\t%s\t5\t%s\n' "$(($(date +%s) - 20 * 86400))" "$soon" > "$history_dir/$((day - 20)).log"
printf '["Gemini Models","gemini-5h"]\t%s\t5\t%s\n' "$(($(date +%s) - 3 * 86400))" "$soon" > "$history_dir/$((day - 3)).log"
out="$(agy_run --tool agy)"; rc=$?
check 'exit 0'                   0 "$rc"
check 'a file older than a week is gone' no "$([ -e "$history_dir/$((day - 20)).log" ] && echo yes || echo no)"
check 'a file of three days ago stays' yes "$([ -e "$history_dir/$((day - 3)).log" ] && echo yes || echo no)"
check 'a file that is no day stays' yes "$([ -e "$history_dir/notes.txt" ] && echo yes || echo no)"
echo 'two reads at once against one home: both finish, both readings stay, no group or bucket mixed'
forget; answer 0.92 0.95 0.42 1
( AGY_DELAY=0.4 agy_run --tool agy > "$work/one.out"; echo $? > "$work/one.rc" ) &
( AGY_DELAY=0.4 agy_run --tool agy > "$work/two.out"; echo $? > "$work/two.rc" ) &
wait
check 'both exit 0'              '0 0' "$(cat "$work/one.rc") $(cat "$work/two.rc")"
check 'both print four windows'  '4 4' "$(grep -c ' used  resets' "$work/one.out") $(grep -c ' used  resets' "$work/two.out")"
check 'eight rows, none torn'    8 "$(awk -F'\t' 'NF == 4 && $3 + 0 == $3 { n++ } END { print n }' "$history_dir"/*.log)"
check 'each bucket twice, with its own share used' \
  '2 ["Claude and GPT models","3p-5h"]=0|2 ["Claude and GPT models","3p-weekly"]=58|2 ["Gemini Models","gemini-5h"]=5|2 ["Gemini Models","gemini-weekly"]=8|' \
  "$(awk -F'\t' '{ print $1 "=" $3 }' "$history_dir"/*.log | LC_ALL=C sort | uniq -c | sed 's/^ *//' | tr '\n' '|')"
echo 'a reader waits for a concurrent append that has written only half a row'
mkdir -p "$work/slow-bin"
export REAL_AWK="$(command -v awk)" HISTORY_WRITE_STARTED="$work/history-write-started"
cat > "$work/slow-bin/awk" <<'TOOL'
#!/usr/bin/env bash
case "$*" in
  *'-v t='*)
    if [ "${SLOW_HISTORY_WRITE:-}" = 1 ]; then
      rows="$("$REAL_AWK" "$@")" || exit
      printf '%s' "${rows:0:16}"
      : > "$HISTORY_WRITE_STARTED"
      sleep 1
      printf '%s\n' "${rows:16}"
      exit
    fi ;;
esac
exec "$REAL_AWK" "$@"
TOOL
chmod +x "$work/slow-bin/awk"
forget; answer 0.92 0.95 0.42 1
( SLOW_HISTORY_WRITE=1 run "$work/slow-bin:$planted" --tool agy > "$work/one.out"; echo $? > "$work/one.rc" ) &
writer=$!
for attempt in $(seq 1 100); do [ ! -e "$HISTORY_WRITE_STARTED" ] || break; sleep 0.05; done
check 'the writer reached its partial append' yes "$([ -e "$HISTORY_WRITE_STARTED" ] && echo yes || echo no)"
out="$(agy_run --tool agy)"; rc=$?
wait "$writer"
check 'both reads finish with usable output' '0 0' "$(cat "$work/one.rc") $rc"
check 'all rows remain intact after the overlap' 8 "$(awk -F'\t' 'NF == 4 && $3 + 0 == $3 { n++ } END { print n }' "$history_dir"/*.log)"
check 'the overlap preserves each bucket identity twice' \
  '2 ["Claude and GPT models","3p-5h"]|2 ["Claude and GPT models","3p-weekly"]|2 ["Gemini Models","gemini-5h"]|2 ["Gemini Models","gemini-weekly"]|' \
  "$(cut -f1 "$history_dir"/*.log | LC_ALL=C sort | uniq -c | sed 's/^ *//' | tr '\n' '|')"
echo 'a held history lock has a bounded refusal and does not hold the agy call'
forget; mkdir -p "$history_dir"; : > "$history_dir/.lock"
out="$(agy_run --tool agy)"; rc=$?
check 'a held lock: exit 2, naming the lock' '2 yes' "$rc $(matches 'history lock .* still held' "$out")"
check 'the quota call preceded the history lock' '-p /usage --output-format json' "$(head -n1 "$AGY_CALLS")"
echo 'a mkdir that cannot tell a held lock, as the coreutils of some machines cannot between two callers racing, does not decide the lock'
mkdir -p "$work/race-bin"
export REAL_MKDIR="$(command -v mkdir)"
cat > "$work/race-bin/mkdir" <<'TOOL'
#!/usr/bin/env bash
for last; do :; done
case "$last" in */.lock) exit 0 ;; esac
exec "$REAL_MKDIR" "$@"
TOOL
chmod +x "$work/race-bin/mkdir"
forget; answer 0.92 0.95 0.42 1; mkdir -p "$history_dir"; : > "$history_dir/.lock"
out="$(run "$work/race-bin:$planted" --tool agy)"; rc=$?
check 'a held lock stays held for a mkdir that succeeds on it: exit 2, naming the lock' '2 yes' "$rc $(matches 'history lock .* still held' "$out")"
check 'the lock of the other holder is still there' yes "$([ -e "$history_dir/.lock" ] && echo yes || echo no)"
mutate 's/( set -C; : > "\$history\/.lock" )/mkdir "$history\/.lock"/; s/rm "\$usage_history_lock" ||/rmdir "$usage_history_lock" ||/' 'a lock taken with mkdir'
forget; answer 0.92 0.95 0.42 1; mkdir -p "$history_dir"; : > "$history_dir/.lock"
out="$(run "$work/race-bin:$planted" --tool agy)"; rc=$?
check 'a lock taken with mkdir is caught' yes "$(grep -q 'still held' <<< "$out" && echo "no: the mutant held back as well" || echo yes)"
restore
if [ "$(id -u)" != 0 ]; then
  forget; answer 0.92 0.95 0.42 1; mkdir -p "$history_dir"; chmod 500 "$history_dir"
  out="$(agy_run --tool agy)"; rc=$?
  chmod 700 "$history_dir"
  check 'a history folder that cannot be written: exit 2 at once, naming the lock' '2 yes' "$rc $(matches 'history lock cannot be made' "$out")"
fi
echo 'a history that cannot be written or read is refused with its reason, and no forecast is made up'
forget; answer 0.92 0.95 0.92 0.2
: > "$history_dir"
out="$(agy_run --tool agy)"; rc=$?
check 'a history folder that is a file: exit 2' 2 "$rc"
check 'the reason'               yes "$(matches 'the usage history folder .* cannot be made' "$out")"
check 'no window'                0 "$(grep -c '% used  reset' <<< "$out")"
forget; mkdir -p "$history_dir"
printf 'garbage\n' > "$history_dir/$(($(date +%s) / 86400)).log"
out="$(agy_run --tool agy)"; rc=$?
check 'a malformed line: exit 2' 2 "$rc"
check 'the reason names file and line' yes "$(matches 'the usage history has a malformed line at .*/[0-9]+\.log:1$' "$out")"
check 'no window'                0 "$(grep -c '% used  reset' <<< "$out")"
forget; seed 'Claude and GPT models' 3p-5h 1800 -10 "$soon"
mutate 's/NF != 4 ||[^{}]* {/0 {/' 'a history read without a check'
out="$(agy_run --tool agy)"; rc=$?
caught 'a history read without a check is caught' 2 "$rc"
restore
forget

echo 'a malformed numeric history is not a measured forecast'
answer 0.92 0.95 0.92 0.2
seed 'Claude and GPT models' 3p-5h 1800 -10 "$soon"
out="$(agy_run --tool agy)"; rc=$?
check 'a negative share in history: exit 2' 2 "$rc"
forget
mkdir -p "$history_dir"
printf 'broken-key\t%s\t10\t%s\n' "$((now - 1800))" "$soon" > "$history_dir/$((now / 86400)).log"
out="$(agy_run --tool agy)"; rc=$?
check 'a broken history identity: exit 2 with its reason' '2 yes' "$rc $(matches 'invalid group/bucket key' "$out")"
forget

echo 'which tool is read: an explicit one wins, agy is no longer read as Claude, an unsupported one is refused'
mkdir -p "$HOME/.ai-core"
printf '{"recorded_at":%s,"rate_limits":{"seven_day":{"used_percentage":99,"resets_at":%s}}}\n' "$now" "$week_at" > "$HOME/.ai-core/usage.json"
answer 0.92 0.95 0.42 1
out="$(CLAUDECODE=1 CODEX_THREAD_ID=t agy_run --tool agy)"; rc=$?
check 'explicit agy despite inherited Codex and Claude identity' '0 4' "$rc $(grep -c ' used  resets' <<< "$out")"
out="$(ANTIGRAVITY_AGENT=1 CLAUDECODE=1 agy_run)"; rc=$?
check 'an agy session reads agy, not Claude at 99 %' "0 Gemini Models: seven_day" "$rc $(sed -n 1p <<< "$out" | cut -c1-24)"
out="$(ANTIGRAVITY_AGENT=1 CODEX_THREAD_ID=t agy_run)"; rc=$?
check 'a Codex shell wins over agy: no Codex record, exit 2' "2 yes" "$rc $(matches 'Codex records it' "$out")"
out="$(GEMINI_CLI=1 agy_run)"; rc=$?
check 'a Gemini session is refused, not read as Claude at 99 %' "2 yes" "$rc $(matches 'usage does not read the quota of gemini' "$out")"
out="$(agy_run)"; rc=$?
check 'outside a detected tool: Claude, at 99 %' 3 "$rc"
mutate 's|reject "usage does not read the quota of $tool[^"]*"|tool=claude|' 'an unsupported tool read as Claude'
out="$(GEMINI_CLI=1 agy_run)"; rc=$?
caught 'an unsupported tool read as Claude is caught' 2 "$rc"
restore
out="$(agy_run --tool claude --model claude-opus-5-5-high)"; rc=$?
check '--model with Claude: exit 2' "2 yes" "$rc $(matches '--model is for agy' "$out")"
out="$(agy_run --tool codex --model claude-opus-5-5-high)"; rc=$?
check '--model with Codex: exit 2' "2 yes" "$rc $(matches '--model is for agy' "$out")"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
