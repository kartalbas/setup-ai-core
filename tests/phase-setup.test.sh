#!/usr/bin/env bash
# The planner's Setup chooses a phase's model, effort and budget, and ai-core phase-model keeps it inside models.tsv.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export HOME="$WORK/home"; mkdir -p "$HOME"
SRC="$WORK/source"; QUOTA="$WORK/quota"; PROJECT="$WORK/project"
mkdir -p "$SRC/bin" "$SRC/lib" "$SRC/templates/.ai-core" "$QUOTA" "$PROJECT/.ai-core"
for f in bin/phase-model.sh lib/tool-order.sh lib/common.sh templates/.ai-core/models.tsv; do cp "$ROOT/$f" "$SRC/$f"; done
# The quota reader stands in: its exit status per tool is the file of that name, and every call is kept
cat > "$SRC/bin/usage.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$QUOTA/calls"
printf '%s quota fixture\n' "$2"
exit "$(cat "$QUOTA/$2")"
EOF
for t in claude codex agy; do echo 0 > "$QUOTA/$t"; done
export QUOTA

order() {  # order <tool>...: the saved order
  local tools; tools="$(printf '"%s",' "$@")"
  mkdir -p "$AI_CORE_HOME/.ai-core"
  printf '{"version":1,"orders":[{"generation":1,"time":%s,"tools":[%s]}]}\n' "$(( $(date +%s) - 1000 ))" "${tools%,}" > "$AI_CORE_HOME/.ai-core/tool-order.json"
}
entry() {  # entry <model> <effort> <estimate> [budget] [reason]: one tool's entry of a Setup
  local estimate="$3" budget="${4:-$(( ($3 * 3 + 1) / 2 ))}" reason="${5-the last builds of this area used about this}"
  jq -cn --arg model "$1" --arg effort "$2" --argjson estimate "$estimate" --argjson budget "$budget" --arg reason "$reason" \
    '{model:$model,effort:$effort,estimate_tokens:$estimate,budget_tokens:$budget,reason:$reason}'
}
setup() { printf '%s\n' "$1" > "$WORK/setup.json"; }
selection() {  # selection <phase> <class> [option...]: runs the selector in the project, keeps its words
  : > "$QUOTA/calls"
  rc=0; out="$(cd "$PROJECT" && bash "${selector:-$SRC/bin/phase-model.sh}" "$@" 2> "$WORK/err")" || rc=$?
  err="$(cat "$WORK/err")"
}
expect() {  # expect <name> <rc> <stdout> [stderr pattern]
  [ "$rc" = "$2" ] || fail "$1: exit $rc, wanted $2: $out / $err"
  [ "$out" = "$3" ] || fail "$1: stdout '$out', wanted '$3': $err"
  [ -z "${4-}" ] || grep -qF -- "$4" <<< "$err" || fail "$1: stderr lacks '$4': $err"
  echo "  ok   $1"
}
refused() {  # refused <name> <reason>: a Setup the selector refuses before it reads any quota
  expect "$1" 2 '' "$2"
  [ ! -s "$QUOTA/calls" ] || fail "$1: the quota was read before the Setup was refused: $(cat "$QUOTA/calls")"
}

section "the selector without a Setup is unchanged"
order claude
selection build normal-hard
expect 'no option: the table row' 0 'claude claude-sonnet-5-5 high'

section "a full Setup chooses the tuple of each phase"
setup "$(jq -cn --argjson b "$(entry claude-sonnet-5-5 xhigh 150000)" --argjson r "$(entry claude-opus-5-5 max 80000)" --argjson u "$(entry claude-haiku-5-5 high 60000)" \
  '{build:{claude:$b},review:{claude:$r},"ui-test":{claude:$u}}')"
selection build normal-hard --setup-file "$WORK/setup.json"
expect 'build takes its entry' 0 'claude claude-sonnet-5-5 xhigh'
selection review normal-hard --written-by claude-sonnet-5-5 --setup-file "$WORK/setup.json"
expect 'review takes its entry beside --written-by' 0 'claude claude-opus-5-5 max'
selection ui-test normal-hard --setup-file "$WORK/setup.json"
expect 'ui-test takes the row of the table, which its entry names' 0 'claude claude-haiku-5-5 high'
selection build normal-hard --setup-file "$WORK/setup.json" --written-by claude-opus-5-5
expect 'the options come in either order' 0 'claude claude-sonnet-5-5 xhigh'
selection plan-check normal-hard --written-by gpt-6-astra --setup-file "$WORK/setup.json"
expect 'a phase with no place in a Setup stays on its row' 0 'claude claude-opus-5-5 high'

section "what the Setup leaves out runs on the table"
setup "$(jq -cn --argjson r "$(entry claude-opus-5-5 max 80000)" '{review:{claude:$r}}')"
selection build normal-hard --setup-file "$WORK/setup.json"
expect 'no entry for the phase' 0 'claude claude-sonnet-5-5 high'
setup '{}'
selection build normal-hard --setup-file "$WORK/setup.json"
expect 'an empty Setup' 0 'claude claude-sonnet-5-5 high'
setup "$(jq -cn --argjson b "$(entry gpt-6-sol xhigh 100000)" '{build:{codex:$b}}')"
selection build normal-hard --setup-file "$WORK/setup.json"
expect 'no entry for the tool that runs' 0 'claude claude-sonnet-5-5 high'
order codex claude
selection build normal-hard --setup-file "$WORK/setup.json"
expect 'the entry of the first tool of the order' 0 'codex gpt-6-sol xhigh'
selection review normal-hard --written-by claude-sonnet-5-5 --setup-file "$WORK/setup.json"
expect 'a tool without an entry runs its row' 0 'codex gpt-6-astra xhigh'

section "the first tool is out of quota: the second tool's entry is used"
setup "$(jq -cn --argjson c "$(entry gpt-6-sol xhigh 100000)" --argjson d "$(entry claude-sonnet-5-5 xhigh 100000)" '{build:{codex:$c,claude:$d}}')"
echo 3 > "$QUOTA/codex"
selection build normal-hard --setup-file "$WORK/setup.json"
expect 'codex at its limit' 0 'claude claude-sonnet-5-5 xhigh'
echo 0 > "$QUOTA/codex"

section "the writer's model is never the reviewer"
setup "$(jq -cn --argjson c "$(entry claude-opus-5-5 xhigh 80000)" '{review:{claude:$c}}')"
order claude
selection review normal-hard --written-by claude-opus-5-5 --setup-file "$WORK/setup.json"
expect 'an entry on the writer model is skipped, and nothing else is left' 2 '' 'writer model claude-opus-5-5 is not independent'
order claude codex
selection review normal-hard --written-by claude-opus-5-5-high --setup-file "$WORK/setup.json"
expect 'the next tool answers, on its row' 0 'codex gpt-6-astra xhigh'
selection review normal-hard --written-by gpt-6-astra --setup-file "$WORK/setup.json"
expect 'another writer leaves the entry standing (innocent)' 0 'claude claude-opus-5-5 xhigh'

section "a Setup the table does not allow is refused before any quota is read"
order claude
setup '{not json'
selection build normal-hard --setup-file "$WORK/setup.json"
refused 'invalid JSON' 'is refused: parse error'
selection build normal-hard --setup-file "$WORK/missing.json"
refused 'a missing file' 'cannot be read'
setup '[1]'
selection build normal-hard --setup-file "$WORK/setup.json"
refused 'not an object' 'it is not a JSON object'
: > "$WORK/setup.json"
selection build normal-hard --setup-file "$WORK/setup.json"
refused 'an empty file, which holds no Setup' 'it holds 0 JSON values, not one object'
two_setups() { setup "$(jq -cn --argjson b "$(entry claude-sonnet-5-5 xhigh 100000)" '{build:{claude:$b}}') $(jq -cn --argjson b "$(entry claude-sonnet-5-5 high 100000)" '{build:{claude:$b}}')"; }
two_setups
selection build normal-hard --setup-file "$WORK/setup.json"
refused 'two objects, each one a Setup the table allows' 'it holds 2 JSON values, not one object'
setup "$(jq -cn --argjson b "$(entry claude-sonnet-5-5 xhigh 100000)" '{plan:{claude:$b}}')"
selection build normal-hard --setup-file "$WORK/setup.json"
refused 'a phase that has no Setup' 'it names the phase plan'
setup "$(jq -cn --argjson b "$(entry claude-sonnet-5-5 xhigh 100000)" '{build:{gemini:$b}}')"
selection build normal-hard --setup-file "$WORK/setup.json"
refused 'a tool that does not exist' 'names the tool gemini'
setup "$(jq -cn --argjson b "$(entry claude-sonnet-5-5 low 100000)" '{build:{claude:$b}}')"
selection build normal-hard --setup-file "$WORK/setup.json"
refused 'a tuple the table does not name' 'claude-sonnet-5-5 low is no tuple of claude for build'
setup "$(jq -cn --argjson b "$(entry gpt-6-sol xhigh 100000)" '{build:{claude:$b}}')"
selection build normal-hard --setup-file "$WORK/setup.json"
refused "another tool's model on this tool" 'is no tuple of claude for build'
setup "$(jq -cn --argjson b "$(entry claude-sonnet-5-5 high 100000)" '{build:{claude:$b}}')"
selection build high-risk --setup-file "$WORK/setup.json"
refused 'a high-risk entry below the row' 'for high-risk it is the row of the table, claude-sonnet-5-5 xhigh, not claude-sonnet-5-5 high'
setup "$(jq -cn --argjson b "$(entry claude-sonnet-5-5 xhigh 100000)" '{build:{claude:$b}}')"
selection build high-risk --setup-file "$WORK/setup.json"
expect 'a high-risk entry on the row (innocent)' 0 'claude claude-sonnet-5-5 xhigh'
setup "$(jq -cn --argjson b "$(entry claude-opus-5-5 high 100000)" '{review:{claude:$b}}')"
selection review high-risk --written-by claude-sonnet-5-5 --setup-file "$WORK/setup.json"
refused 'a high-risk review below the row' 'for high-risk it is the row of the table, claude-opus-5-5 max'
setup "$(jq -cn --argjson b "$(entry claude-sonnet-5-5-high - 100000)" '{build:{agy:$b}}')"
order agy
selection build high-risk --setup-file "$WORK/setup.json"
refused 'agy for a high-risk package' 'agy has no build row for high-risk'
selection build normal-hard --setup-file "$WORK/setup.json"
expect 'agy for a normal-hard package (innocent)' 0 'agy claude-sonnet-5-5-high -'
setup "$(jq -cn --argjson b "$(entry claude-sonnet-5-5-high - 60000)" '{"ui-test":{agy:$b}}')"
order agy
selection ui-test high-risk --setup-file "$WORK/setup.json"
refused 'a ui-test entry of a tool that does not run the class' 'agy has no build row for high-risk'
order claude
setup "$(jq -cn --argjson b "$(entry claude-sonnet-5-5 high 60000)" '{"ui-test":{claude:$b}}')"
selection ui-test normal-hard --setup-file "$WORK/setup.json"
refused 'a ui-test entry on another model than the row' 'for normal-hard it is the row of the table, claude-haiku-5-5 high'
setup "$(jq -cn --argjson b "$(entry claude-haiku-5-5 high 60000)" '{"ui-test":{claude:$b}}')"
selection ui-test high-risk --setup-file "$WORK/setup.json"
refused 'a ui-test entry below the row of its class' 'for high-risk it is the row of the table, claude-haiku-5-5 max'
setup "$(jq -cn --argjson b "$(entry claude-haiku-5-5 max 60000)" '{"ui-test":{claude:$b}}')"
selection ui-test high-risk --setup-file "$WORK/setup.json"
expect 'a ui-test entry on the row of its class (innocent)' 0 'claude claude-haiku-5-5 max'

section "the shape of an entry"
bad() {  # bad <name> <jq filter on a valid entry> <reason>
  setup "$(jq -cn --argjson b "$(entry claude-sonnet-5-5 xhigh 100000 | jq -c "$2")" '{build:{claude:$b}}')"
  selection build normal-hard --setup-file "$WORK/setup.json"
  refused "$1" "$3"
}
bad 'a missing reason' 'del(.reason)' 'must hold exactly model, effort, estimate_tokens, budget_tokens and reason'
bad 'an empty reason' '.reason = "  "' 'gives no reason'
bad 'a field nobody asked for' '. + {note: 1}' 'must hold exactly'
bad 'a model with a space' '.model = "claude sonnet"' 'model and effort are words with no space'
bad 'an estimate that is no whole number' '.estimate_tokens = 100000.5 | .budget_tokens = 150001' 'positive whole numbers'
bad 'a budget as text' '.budget_tokens = "150000"' 'positive whole numbers'
bad 'a budget of zero' '.estimate_tokens = 0 | .budget_tokens = 0' 'positive whole numbers'
bad 'a margin of 100 %' '.budget_tokens = 200000' 'is not 1.5 times estimate_tokens 100000, rounded up'
bad 'a margin of 0 %' '.budget_tokens = 100000' 'is not 1.5 times'
bad 'a budget one under the margin' '.budget_tokens = 149999' 'is not 1.5 times'
setup "$(jq -cn --argjson b "$(entry claude-sonnet-5-5 xhigh 100001)" '{build:{claude:$b}}')"
selection build normal-hard --setup-file "$WORK/setup.json"
expect 'a margin rounded up (innocent)' 0 'claude claude-sonnet-5-5 xhigh'

section "the budget stays within the ceiling of its phase"
ceiling() {  # ceiling <name> <phase> <tool> <model> <effort> <estimate> <reason or ok>
  setup "$(jq -cn --argjson b "$(entry "$4" "$5" "$6")" --arg phase "$2" --arg tool "$3" '{($phase):{($tool):$b}}')"
  order "$3"
  selection "$2" normal-hard --written-by none --setup-file "$WORK/setup.json"
  if [ "$7" = ok ]; then expect "$1" 0 "$3 $4 $5"; else refused "$1" "$7"; fi
}
ceiling 'a build of 300000 on Claude (innocent)' build claude claude-sonnet-5-5 high 200000 ok
ceiling 'a build of 300002 on Claude' build claude claude-sonnet-5-5 high 200001 'is above the 300000 of the phase'
ceiling 'a build of 249999 on Codex (innocent)' build codex gpt-6-sol xhigh 166666 ok
ceiling 'a build of 250001 on Codex' build codex gpt-6-sol xhigh 166667 'budget_tokens 250001 is above the 250000'
ceiling 'a review of 150000 (innocent)' review claude claude-opus-5-5 high 100000 ok
ceiling 'a review of 150002' review claude claude-opus-5-5 high 100001 'is above the 150000'
ceiling 'a ui-test of 100000 (innocent)' ui-test claude claude-haiku-5-5 high 66666 ok
ceiling 'a ui-test of 100002' ui-test claude claude-haiku-5-5 high 66668 'is above the 100000'
order claude

section "the refusal is recorded, and the options are checked"
last="$(tail -n 1 "$AI_CORE_HOME/.ai-core/phase-model.jsonl")"
[ "$(jq -r '.refusal' <<< "$last")" != '' ] && grep -q 'is above the 100000' <<< "$last" || fail "the last refusal is not on record: $last"
echo "  ok   the refusal is on record with its reason"
selection build normal-hard --setup-file
expect 'an option with no value' 2 '' 'phase-model takes only --written-by MODEL and --setup-file PATH'
selection build normal-hard --written-by claude-sonnet-5-5 --nonsense x
expect 'an option nobody knows' 2 '' 'phase-model takes only --written-by MODEL and --setup-file PATH'
selection build normal-hard --setup-file --written-by
expect 'an option as the value of another' 2 '' 'phase-model takes only'
bash "$SRC/bin/phase-model.sh" --help | grep -q -- '--setup-file PATH' || fail 'the help does not name --setup-file'
echo "  ok   the help names the option"

section "planted defects in the Setup check each turn a case red"
mutant="$WORK/mutant"
plant() {  # plant <name> <sed script>: a copy of the selector whose Setup check has one defect, run on the cases it must still refuse
  rm -rf "$mutant"; cp -R "$SRC" "$mutant"
  sed -i.bak "$2" "$mutant/lib/tool-order.sh"
  ! cmp -s "$SRC/lib/tool-order.sh" "$mutant/lib/tool-order.sh" || fail "the planted defect '$1' changed nothing"
  selector="$mutant/bin/phase-model.sh"
}
order claude
plant 'the margin is not checked' 's/if \$e.budget_tokens != (\$e.estimate_tokens \* 1.5 | ceil) then/if false then/'
bad_margin() { setup "$(jq -cn --argjson b "$(entry claude-sonnet-5-5 xhigh 100000 200000)" '{build:{claude:$b}}')"; selection build normal-hard --setup-file "$WORK/setup.json"; }
bad_margin; [ "$rc" = 0 ] || fail "a Setup with no margin check refused a wrong margin: $err"
plant 'the ceiling is not checked' 's/if \$e.budget_tokens > ceiling(\$phase; \$tool) then/if false then/'
setup "$(jq -cn --argjson b "$(entry claude-sonnet-5-5 xhigh 200001)" '{build:{claude:$b}}')"; selection build normal-hard --setup-file "$WORK/setup.json"
[ "$rc" = 0 ] || fail "a Setup with no ceiling check refused a budget above it: $err"
plant 'the high-risk floor is not checked' 's/ui-test:\*|\*:high-risk)/ui-test:*)/'
setup "$(jq -cn --argjson b "$(entry claude-sonnet-5-5 high 100000)" '{build:{claude:$b}}')"; selection build high-risk --setup-file "$WORK/setup.json"
[ "$rc" = 0 ] || fail "a Setup with no floor refused a high-risk entry below the row: $err"
plant 'any tuple is allowed' '/exit !found/ s/.*/        true \\/'
setup "$(jq -cn --argjson b "$(entry claude-sonnet-5-5 low 100000)" '{build:{claude:$b}}')"; selection build normal-hard --setup-file "$WORK/setup.json"
[ "$rc" = 0 ] || fail "a Setup with any tuple allowed refused a tuple outside the table: $err"
plant 'a tool without a build row of the class is allowed' '/has no build row/ s/[[] -n "\$row" []]/true/'
order agy
setup "$(jq -cn --argjson b "$(entry claude-sonnet-5-5-high - 60000)" '{"ui-test":{agy:$b}}')"; selection ui-test high-risk --setup-file "$WORK/setup.json"
[ "$rc" = 0 ] || fail "a Setup that lets a tool run any class refused agy for a high-risk UI test: $err"
order claude
plant 'a second value is allowed' 's/if length != 1 then error/if false then error/'
two_setups; selection build normal-hard --setup-file "$WORK/setup.json"
[ "$rc" = 0 ] || fail "a Setup check that allows a second value refused two objects: $err"
selector=''
echo "  ok   each planted defect lets its case through, so the real check is what refuses it"

section "a filled launch starts on the Setup's tuple, with the name, the window and the budget that agree"
launch="$WORK/launch.sh"
awk '/^```bash$/ { on = 1; next } /^```$/ { if (on) exit } on' "$ROOT/skills/person-in-charge/references/claude.md" > "$launch"
[ -s "$launch" ] || fail "the launch of references/claude.md was not found"
mkdir -p "$WORK/bin" "$WORK/captures"
cat > "$WORK/bin/ai-core" <<'EOF'
#!/usr/bin/env bash
[ "$1" = phase-model ] || exit 7
shift
exec bash "$SELECTOR" "$@"
EOF
cat > "$WORK/bin/claude" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = agents ]; then cat "$NATIVE"; exit 0; fi
jq -cn --args '{args:$ARGS.positional}' -- "$@" >> "$CAPTURES/calls"
jq -cn --arg name "$SESSION" '[{name:$name,sessionId:"claude-identity",status:"idle",state:"done"}]' > "$NATIVE"
EOF
chmod +x "$WORK/bin/ai-core" "$WORK/bin/claude"
echo '[]' > "$WORK/native.json"
brief="$WORK/brief.md"; echo 'fixture brief' > "$brief"
setup "$(jq -cn --argjson b "$(entry claude-sonnet-5-5 xhigh 150000)" '{build:{claude:$b}}')"
budget="$(jq -r '.build.claude.budget_tokens' "$WORK/setup.json")"
thousands=$(( (budget + 999) / 1000 ))
run_launch() {  # run_launch <launch file>
  : > "$WORK/captures/calls"; echo '[]' > "$WORK/native.json"
  env PATH="$WORK/bin:$PATH" SELECTOR="$SRC/bin/phase-model.sh" CAPTURES="$WORK/captures" NATIVE="$WORK/native.json" \
    PROJECT="$PROJECT" PHASE=build CLASS=normal-hard SESSION="build10001-sonnet5.5-xhigh-${thousands}k-abcde" BRIEF="$brief" \
    WINDOW="$(( budget + 100000 ))" SETUP_FILE="$WORK/setup.json" bash "$1" > "$WORK/launch.out" 2>&1 || fail "the launch failed: $(cat "$WORK/launch.out")"
}
order claude
run_launch "$launch"
call="$(tail -n 1 "$WORK/captures/calls")"
[ "$(jq -r '.args | index("--model") as $i | .[$i + 1]' <<< "$call")" = claude-sonnet-5-5 ] || fail "the launch did not start on the model of the Setup: $call"
[ "$(jq -r '.args | index("--effort") as $i | .[$i + 1]' <<< "$call")" = xhigh ] || fail "the launch did not start on the effort of the Setup: $call"
[ "$(jq -r '.args | index("--name") as $i | .[$i + 1]' <<< "$call")" = "build10001-sonnet5.5-xhigh-225k-abcde" ] || fail "the name does not carry the budget of the Setup: $call"
[ "$(jq -r '.args | index("--settings") as $i | .[$i + 1]' <<< "$call")" = '{"autoCompactWindow":325000}' ] || fail "the window is not the budget plus 100000: $call"
echo "  ok   the launch starts claude-sonnet-5-5 at xhigh, named 225k, with a window of 325000"
grep -q '"model":"claude-sonnet-5-5","effort":"xhigh"' "$AI_CORE_HOME/.ai-core/sessions/build10001-sonnet5.5-xhigh-225k-abcde.start.jsonl" || fail "the start record does not carry the Setup's tuple"
echo "  ok   the start record carries the same tuple"
grep -v 'SETUP_FILE' "$launch" > "$WORK/launch-planted.sh"
run_launch "$WORK/launch-planted.sh"
[ "$(jq -r '.args | index("--effort") as $i | .[$i + 1]' <<< "$(tail -n 1 "$WORK/captures/calls")")" = high ] || fail "a launch that drops the Setup file still started on the Setup's tuple"
echo "  ok   a launch that drops --setup-file starts on the table row instead (planted)"
for tool in codex agy; do
  grep -qF -- '--setup-file "$SETUP_FILE"' "$ROOT/skills/person-in-charge/references/$tool.md" || fail "the launch of references/$tool.md does not pass the Setup file"
done
echo "  ok   the launches of codex and agy pass the Setup file as well"

section "a phase session starts without the connectors and with everything that carries its rules"
run_resume() {  # run_resume <launch file>: the resume of the session the stand-in just started
  : > "$WORK/captures/calls"
  jq -cn '[{name:"other",sessionId:"claude-identity",status:"idle",state:"done"}]' > "$WORK/native.json"
  env PATH="$WORK/bin:$PATH" SELECTOR="$SRC/bin/phase-model.sh" CAPTURES="$WORK/captures" NATIVE="$WORK/native.json" \
    PROJECT="$PROJECT" PHASE=build CLASS=normal-hard SESSION="build10001-sonnet5.5-xhigh-${thousands}k-abcde" BRIEF="$brief" \
    OPERATION=resume NATIVE_ID=claude-identity TEXT='go on' SETUP_FILE="$WORK/setup.json" bash "$1" > "$WORK/launch.out" 2>&1 \
    || fail "the resume failed: $(cat "$WORK/launch.out")"
}
launch_faults() {  # launch_faults <start|resume>: what the last call of the stand-in gets wrong, one fault per line
  local call allowed='--bg --model --effort --permission-mode --strict-mcp-config --add-dir'
  call="$(tail -n 1 "$WORK/captures/calls")"
  [ -n "$call" ] || { echo 'the launch made no call'; return; }
  jq -e '.args | index("--strict-mcp-config") != null' <<< "$call" > /dev/null || echo 'no --strict-mcp-config, so the connectors of the account load'
  # Only the flags a phase needs: Claude Code has many that drop the rules or the skills (--safe-mode, --bare) or let a connector in (--mcp-config)
  if [ "$1" = resume ]; then allowed="$allowed --resume"; else allowed="$allowed --name --settings"; fi
  jq -r --arg allowed "$allowed" --arg operation "$1" '($allowed | split(" ")) as $ok | .args[] | . as $flag
    | select(startswith("-") and (any($ok[]; . == $flag) | not)) | "the flag \($flag) stands in the \($operation)"' <<< "$call"
  [ "$1" = resume ] || jq -e --arg dir "$(dirname "$brief")" '[.args as $a | range(0; $a | length - 1) | select($a[.] == "--add-dir") | $a[. + 1]] | index($dir) != null' <<< "$call" > /dev/null \
    || echo "--add-dir does not name the folder of the brief"
  return 0
}
plant() {  # plant <name> <sed script>: a copy of the launch with one defect
  sed "$2" "$launch" > "$WORK/launch-$1.sh"
  ! cmp -s "$launch" "$WORK/launch-$1.sh" || fail "the planted defect $1 changed nothing in the launch"
}
run_launch "$launch"
[ -z "$(launch_faults start)" ] || fail "the start of references/claude.md has faults: $(launch_faults start)"
echo "  ok   the start has --strict-mcp-config, no flag beyond the ones a phase needs, and the brief's folder (innocent)"
run_resume "$launch"
[ -z "$(launch_faults resume)" ] || fail "the resume of references/claude.md has faults: $(launch_faults resume)"
echo "  ok   the resume has --strict-mcp-config and no flag beyond the ones a phase needs (innocent)"
plant bare 's/--strict-mcp-config --add-dir/--strict-mcp-config --bare --add-dir/'
run_launch "$WORK/launch-bare.sh"
[ "$(launch_faults start)" = 'the flag --bare stands in the start' ] || fail "a start with --bare was not refused: $(launch_faults start)"
echo "  ok   a start with --bare is refused (planted)"
plant system-prompt 's/--strict-mcp-config --add-dir/--strict-mcp-config --system-prompt x --add-dir/'
run_launch "$WORK/launch-system-prompt.sh"
[ "$(launch_faults start)" = 'the flag --system-prompt stands in the start' ] || fail "a start with --system-prompt was not refused: $(launch_faults start)"
echo "  ok   a start with --system-prompt is refused (planted)"
plant slash 's/--strict-mcp-config --add-dir/--strict-mcp-config --disable-slash-commands --add-dir/'
run_launch "$WORK/launch-slash.sh"
[ "$(launch_faults start)" = 'the flag --disable-slash-commands stands in the start' ] || fail "a start with --disable-slash-commands was not refused: $(launch_faults start)"
echo "  ok   a start with --disable-slash-commands is refused (planted)"
plant safe-mode 's/--strict-mcp-config --add-dir/--strict-mcp-config --safe-mode --add-dir/'
run_launch "$WORK/launch-safe-mode.sh"
[ "$(launch_faults start)" = 'the flag --safe-mode stands in the start' ] || fail "a start with --safe-mode was not refused: $(launch_faults start)"
echo "  ok   a start with --safe-mode, which turns off the instruction files and the skills, is refused (planted)"
plant connectors 's/--strict-mcp-config --add-dir/--add-dir/'
run_launch "$WORK/launch-connectors.sh"
[ "$(launch_faults start)" = 'no --strict-mcp-config, so the connectors of the account load' ] || fail "a start without --strict-mcp-config was not refused: $(launch_faults start)"
echo "  ok   a start without --strict-mcp-config is refused (planted)"
plant mcp-config 's/--strict-mcp-config --add-dir/--strict-mcp-config --mcp-config {} --add-dir/'
run_launch "$WORK/launch-mcp-config.sh"
[ "$(launch_faults start)" = 'the flag --mcp-config stands in the start' ] || fail "a start with --mcp-config was not refused: $(launch_faults start)"
echo "  ok   a start with a connector of its own is refused (planted)"
plant brief-folder 's/--strict-mcp-config --add-dir "$(dirname "$BRIEF")"/--strict-mcp-config/'
run_launch "$WORK/launch-brief-folder.sh"
[ "$(launch_faults start)" = "--add-dir does not name the folder of the brief" ] || fail "a start without the brief's folder was not refused: $(launch_faults start)"
echo "  ok   a start that does not add the brief's folder is refused (planted)"
plant resume-connectors 's/--permission-mode auto --strict-mcp-config/--permission-mode auto/'
run_resume "$WORK/launch-resume-connectors.sh"
[ "$(launch_faults resume)" = 'no --strict-mcp-config, so the connectors of the account load' ] || fail "a resume without --strict-mcp-config was not refused: $(launch_faults resume)"
echo "  ok   a resume without --strict-mcp-config is refused (planted)"
plant resume-bare 's/--permission-mode auto --strict-mcp-config/--permission-mode auto --strict-mcp-config --bare/'
run_resume "$WORK/launch-resume-bare.sh"
[ "$(launch_faults resume)" = 'the flag --bare stands in the resume' ] || fail "a resume with --bare was not refused: $(launch_faults resume)"
echo "  ok   a resume with --bare is refused (planted)"
ui_test_browser() {  # ui_test_browser <reference>: the UI-test run of a reference keeps its own browser server beside the strict flag
  local block
  block="$(awk '/^      claude -p / { on = 1 } on { print } on && !/\\$/ { exit }' "$1" | tr -s ' \n' ' ')"
  grep -qF -- '--strict-mcp-config' <<< "$block" && grep -qF -- '--mcp-config '"'"'{"mcpServers":{"chrome-devtools"' <<< "$block" && grep -qF -- '--allowedTools mcp__chrome-devtools' <<< "$block"
}
ui_test_browser "$ROOT/skills/person-in-charge/references/claude.md" || fail "the UI-test run of references/claude.md lost its browser server"
for cut in 's/--mcp-config /--no-browser /' 's/ --strict-mcp-config --no-session-persistence/ --no-session-persistence/' 's/--allowedTools mcp__chrome-devtools/--allowedTools Read/'; do
  sed "$cut" "$ROOT/skills/person-in-charge/references/claude.md" > "$WORK/claude-planted.md"
  ! cmp -s "$ROOT/skills/person-in-charge/references/claude.md" "$WORK/claude-planted.md" || fail "the planted UI-test defect '$cut' changed nothing"
  ! ui_test_browser "$WORK/claude-planted.md" || fail "a UI-test run planted with '$cut' passed, so the case cannot go red"
done
echo "  ok   the UI-test run keeps its own browser server; one without its --mcp-config, its strict flag or its browser tools is refused (planted)"

section "the budget is read from the Setup file as SKILL.md says, for a UI test too"
budget_of() {  # budget_of <SKILL.md> <phase> <tool>: what the read of the budget that SKILL.md names prints on the Setup file
  local read
  read="$(tr '\n' ' ' < "$1" | tr -s ' ' | grep -o '`jq [^`]*budget_tokens[^`]*`' | head -n 1 | tr -d '`')"
  [ -n "$read" ] || { echo 'SKILL.md names no read of the budget'; return 1; }
  read="${read//<phase>/$2}"; read="${read//<tool>/$3}"
  case "$read" in *'<that file>'*) read="${read//<that file>/$WORK/setup.json}" ;; *) read="$read $WORK/setup.json" ;; esac
  bash -c "$read" 2>&1
}
skill="$ROOT/skills/person-in-charge/SKILL.md"
setup "$(jq -cn --argjson u "$(entry claude-haiku-5-5 high 60000)" '{"ui-test":{claude:$u}}')"
[ "$(budget_of "$skill" ui-test claude)" = 90000 ] || fail "the read SKILL.md names does not give the 90000 of the ui-test entry: $(budget_of "$skill" ui-test claude)"
[ "$(budget_of "$skill" build codex)" = null ] || fail "the read SKILL.md names does not give null for a tool without an entry: $(budget_of "$skill" build codex)"
echo "  ok   the read SKILL.md names gives 90000 for the ui-test entry and null where a tool has none"
sed 's/\.\[\$phase\]\[\$tool\]\.budget_tokens/.<phase>.<tool>.budget_tokens/' "$skill" > "$WORK/SKILL-planted.md"
! cmp -s "$skill" "$WORK/SKILL-planted.md" || fail "the planted read of .<phase>.<tool> changed nothing in SKILL.md"
[ "$(budget_of "$WORK/SKILL-planted.md" ui-test claude)" != 90000 ] || fail "a read of .<phase>.<tool> gave the budget of the ui-test entry, so the case cannot go red"
echo "  ok   a read of .<phase>.<tool>, which jq takes as .ui - test for a UI test, gives no budget (planted)"

echo "all phase setup cases passed"
