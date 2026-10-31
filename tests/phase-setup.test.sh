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
setup "$(jq -cn --argjson b "$(entry claude-opus-5-5 max 100000)" '{review:{claude:$b}}')"
selection review high-risk --written-by gpt-6-astra --setup-file "$WORK/setup.json"
expect 'a high-risk review on the native row behind a route (innocent)' 0 'claude claude-opus-5-5 max'
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

section "a tool with several rows for the class holds its Setup to the first row"
two_row_table() { printf 'claude\tbuild\t*\tclaude-sonnet-5-5\thigh\nclaude\tui-test\tnormal-hard\tclaude-haiku-5-5\thigh\nclaude\tui-test\tnormal-hard\tclaude-haiku-5-5\tmax\n' > "$PROJECT/.ai-core/models.tsv"; }
two_row_table
setup "$(jq -cn --argjson b "$(entry claude-haiku-5-5 high 60000)" '{"ui-test":{claude:$b}}')"
selection ui-test normal-hard --setup-file "$WORK/setup.json"
expect 'a ui-test entry on the first row (innocent)' 0 'claude claude-haiku-5-5 high'
setup "$(jq -cn --argjson b "$(entry claude-haiku-5-5 max 60000)" '{"ui-test":{claude:$b}}')"
selection ui-test normal-hard --setup-file "$WORK/setup.json"
refused 'a ui-test entry on the second row' 'for normal-hard it is the row of the table, claude-haiku-5-5 high, not claude-haiku-5-5 max'
rm -f "$PROJECT/.ai-core/models.tsv"

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
two_row_table
plant 'the lookup of a row takes the last of its rows' 's|rows%%[$]'"'"'\\n'"'"'[*]|rows##*$'"'"'\\n'"'"'|'
setup "$(jq -cn --argjson b "$(entry claude-haiku-5-5 max 60000)" '{"ui-test":{claude:$b}}')"; selection ui-test normal-hard --setup-file "$WORK/setup.json"
[ "$rc" = 0 ] || fail "a lookup that takes the last row refused an entry on the second row: $err"
rm -f "$PROJECT/.ai-core/models.tsv"
plant 'a second value is allowed' 's/if length != 1 then error/if false then error/'
two_setups; selection build normal-hard --setup-file "$WORK/setup.json"
[ "$rc" = 0 ] || fail "a Setup check that allows a second value refused two objects: $err"
selector=''
echo "  ok   each planted defect lets its case through, so the real check is what refuses it"

section "a start through the command is on the Setup's tuple, with the name, the window and the budget that agree"
# The command itself runs, on a copy of the tree whose quota reader is the fixture one; Claude Code and Codex are stand-ins on the
# PATH that keep every call, and a planted defect is one changed line of a second copy
CMD="$WORK/cmd"; mkdir -p "$CMD" "$WORK/bin" "$WORK/captures"
cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/templates" "$CMD/"; cp "$SRC/bin/usage.sh" "$CMD/bin/usage.sh"
cat > "$WORK/bin/claude" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = agents ]; then cat "$NATIVE"; exit 0; fi
jq -cn --args '{args:$ARGS.positional}' -- "$@" >> "$CAPTURES/calls"
name=''; prev=''; for a in "$@"; do [ "$prev" != --name ] || name="$a"; prev="$a"; done
[ -z "$name" ] || jq -cn --arg name "$name" '[{name:$name,id:"agent-1",sessionId:"claude-identity",cwd:"/",status:"idle",state:"done"}]' > "$NATIVE"
EOF
cat > "$WORK/bin/codex" <<'EOF'
#!/usr/bin/env bash
printf '{"type":"thread.started","thread_id":"thread-1"}\n{"type":"turn.completed"}\n'
EOF
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/google-chrome"
chmod +x "$WORK/bin/claude" "$WORK/bin/codex" "$WORK/bin/google-chrome"
printf '{"permissions":{"deny":[]}}\n' > "$AI_CORE_HOME/.ai-core/claude-run-settings.json"
echo '[]' > "$WORK/native.json"
SESSIONS="$AI_CORE_HOME/.ai-core/sessions"
brief="$WORK/brief.md"; printf '# Brief: a fixture\n\nRead nothing.\n' > "$brief"
echo 10000 > "$WORK/number"; command=''
run_command() {  # run_command <args>...: the command in the project; its worker line in $line, its session name in $session, its refusal in $err
  # the number is kept in a file: a call inside a command substitution runs in a subshell, and a counter in memory would run back
  number=$(( $(cat "$WORK/number") + 1 )); echo "$number" > "$WORK/number"; : > "$WORK/captures/calls"
  rc=0; line="$(cd "$PROJECT" && env PATH="$WORK/bin:$PATH" CAPTURES="$WORK/captures" NATIVE="$WORK/native.json" \
    bash "${command:-$CMD/bin/start-phase.sh}" "$@" --issue o/r#7 --brief "$brief" --number "$number" 2> "$WORK/err")" || rc=$?
  err="$(cat "$WORK/err")"; session="${line%% *}"
  if [ "$rc" = 0 ]; then
    for _ in $(seq 100); do { [ ! -f "$SESSIONS/$session.pid" ] || [ -f "$SESSIONS/$session.exit" ]; } && break; sleep 0.1; done
  fi
}
run_resume() {  # run_resume <name>: the resume of the session the stand-in just started
  : > "$WORK/captures/calls"
  rc=0; line="$(cd "$PROJECT" && env PATH="$WORK/bin:$PATH" CAPTURES="$WORK/captures" NATIVE="$WORK/native.json" \
    bash "${command:-$CMD/bin/start-phase.sh}" --resume "$1" 'go on' 2> "$WORK/err")" || rc=$?
  err="$(cat "$WORK/err")"
}
last_call() { tail -n 1 "$WORK/captures/calls"; }
plant_command() {  # plant_command <name> <file under the tree> <sed script>: a copy of the tree with one defect; `command` runs it
  local tree="$WORK/cmd-$1"
  rm -rf "$tree"; cp -R "$CMD" "$tree"
  sed "$3" "$CMD/$2" > "$tree/$2"
  ! cmp -s "$CMD/$2" "$tree/$2" || fail "the planted defect $1 changed nothing in $2"
  command="$tree/bin/start-phase.sh"
}
order claude
setup "$(jq -cn --argjson b "$(entry claude-sonnet-5-5 xhigh 150000)" '{build:{claude:$b}}')"
budget="$(jq -r '.build.claude.budget_tokens' "$WORK/setup.json")"
run_command build normal-hard --setup-file "$WORK/setup.json"
[ "$rc" = 0 ] || fail "the command refused a start on a Setup: $err"
call="$(last_call)"
[ "$(jq -r '.args | index("--model") as $i | .[$i + 1]' <<< "$call")" = claude-sonnet-5-5 ] || fail "the start did not use the model of the Setup: $call"
[ "$(jq -r '.args | index("--effort") as $i | .[$i + 1]' <<< "$call")" = xhigh ] || fail "the start did not use the effort of the Setup: $call"
grep -Eq '^build10001-sonnet5\.5-xhigh-225k-[0-9a-f]{5}$' <<< "$session" || fail "the name does not carry the budget of the Setup: $session"
[ "$(jq -r '.args | index("--name") as $i | .[$i + 1]' <<< "$call")" = "$session" ] || fail "the session does not run under the name the command printed: $call"
[ "$(jq -r '.args | index("--settings") as $i | .[$i + 1]' <<< "$call")" = '{"autoCompactWindow":325000}' ] || fail "the window is not the budget plus 100000: $call"
echo "  ok   the start uses claude-sonnet-5-5 at xhigh, named 225k, with a window of 325000"
grep -q '"model":"claude-sonnet-5-5","effort":"xhigh"' "$SESSIONS/$session.start.jsonl" || fail "the start record does not carry the Setup's tuple"
echo "  ok   the start record carries the same tuple"
plant_command no-setup bin/start-phase.sh '/select_args+=(--setup-file/d'
run_command build normal-hard --setup-file "$WORK/setup.json"; command=''
[ "$rc" = 2 ] && grep -qF 'no budget' <<< "$err" || [ "$(jq -r '.args | index("--effort") as $i | .[$i + 1]' <<< "$(last_call)")" = high ] \
  || fail "a command that does not pass the Setup file to the selector still started on the Setup's tuple: $err"
echo "  ok   a command that drops the Setup file starts on the table row or refuses (planted)"
order codex
setup "$(jq -cn --argjson b "$(entry gpt-6-sol xhigh 100000)" '{build:{codex:$b}}')"
run_command build normal-hard --setup-file "$WORK/setup.json"
[ "$rc" = 0 ] || fail "the command refused a Codex start on a Setup: $err"
grep -Eq '^build[0-9]+-gpt6sol-xhigh-150k-[0-9a-f]{5}$' <<< "$session" || fail "the name of a Codex start does not carry the budget of the Setup: $session"
echo "  ok   a Codex start takes the Setup file through the same selection (150k)"
order claude

section "a phase session starts without the connectors and with everything that carries its rules"
launch_faults() {  # launch_faults <start|resume> <call>: what the call of the stand-in gets wrong, one fault per line
  local allowed='--bg --model --effort --permission-mode --strict-mcp-config --add-dir'
  jq -e '.args | index("--strict-mcp-config") != null' <<< "$2" > /dev/null || echo 'no --strict-mcp-config, so the connectors of the account load'
  # Only the flags a phase needs: Claude Code has many that drop the rules or the skills (--safe-mode, --bare) or let a connector in (--mcp-config)
  if [ "$1" = resume ]; then allowed="$allowed --resume"; else allowed="$allowed --name --settings"; fi
  jq -r --arg allowed "$allowed" --arg operation "$1" '($allowed | split(" ")) as $ok | .args[] | . as $flag
    | select(startswith("-") and (any($ok[]; . == $flag) | not)) | "the flag \($flag) stands in the \($operation)"' <<< "$2"
  [ "$1" = resume ] || jq -e --arg dir "$SESSIONS" '[.args as $a | range(0; $a | length - 1) | select($a[.] == "--add-dir") | $a[. + 1]] | index($dir) != null' <<< "$2" > /dev/null \
    || echo "--add-dir does not name the folder of the brief"
  return 0
}
started_faults() {  # started_faults: the faults of a start by the command that `command` names, on the Setup of the section before
  run_command build normal-hard --setup-file "$WORK/setup.json"
  [ "$rc" = 0 ] || { echo "the command refused: $err"; return; }
  launch_faults start "$(last_call)"
}
resumed_faults() {  # resumed_faults: the faults of a resume of the session the last start left
  local started="$session"
  run_resume "$started"
  [ "$rc" = 0 ] || { echo "the command refused the resume: $err"; return; }
  launch_faults resume "$(last_call)"
}
setup "$(jq -cn --argjson b "$(entry claude-sonnet-5-5 xhigh 150000)" '{build:{claude:$b}}')"
[ -z "$(started_faults)" ] || fail "the start of the command has faults: $(started_faults)"
echo "  ok   the start has --strict-mcp-config, no flag beyond the ones a phase needs, and the brief's folder (innocent)"
run_command build normal-hard --setup-file "$WORK/setup.json"; [ "$rc" = 0 ] || fail "the start before a resume was refused: $err"
[ -z "$(resumed_faults)" ] || fail "the resume of the command has faults: $(resumed_faults)"
echo "  ok   the resume has --strict-mcp-config and no flag beyond the ones a phase needs (innocent)"
planted_start() {  # planted_start <name> <sed script> <the one fault it must give>
  plant_command "$1" lib/start-phase.sh "$2"
  local faults; faults="$(started_faults)"; command=''
  [ "$faults" = "$3" ] || fail "a start planted '$1' was not refused as '$3': $faults"
  echo "  ok   a start planted '$1' is refused (planted)"
}
planted_start bare 's/--strict-mcp-config --add-dir/--strict-mcp-config --bare --add-dir/' 'the flag --bare stands in the start'
planted_start system-prompt 's/--strict-mcp-config --add-dir/--strict-mcp-config --system-prompt x --add-dir/' 'the flag --system-prompt stands in the start'
planted_start disable-slash-commands 's/--strict-mcp-config --add-dir/--strict-mcp-config --disable-slash-commands --add-dir/' 'the flag --disable-slash-commands stands in the start'
planted_start safe-mode 's/--strict-mcp-config --add-dir/--strict-mcp-config --safe-mode --add-dir/' 'the flag --safe-mode stands in the start'
planted_start connectors 's/--strict-mcp-config --add-dir/--add-dir/' 'no --strict-mcp-config, so the connectors of the account load'
planted_start mcp-config 's/--strict-mcp-config --add-dir/--strict-mcp-config --mcp-config {} --add-dir/' 'the flag --mcp-config stands in the start'
planted_start brief-folder 's/--strict-mcp-config --add-dir "$(dirname "$SP_BRIEF")"/--strict-mcp-config/' '--add-dir does not name the folder of the brief'
planted_resume() {  # planted_resume <name> <sed script> <the one fault it must give>
  run_command build normal-hard --setup-file "$WORK/setup.json"; [ "$rc" = 0 ] || fail "the start before a planted resume was refused: $err"
  local started="$session"
  plant_command "$1" lib/start-phase.sh "$2"
  run_resume "$started"; command=''
  [ "$rc" = 0 ] || fail "the planted resume '$1' was refused: $err"
  local faults; faults="$(launch_faults resume "$(last_call)")"
  [ "$faults" = "$3" ] || fail "a resume planted '$1' was not refused as '$3': $faults"
  echo "  ok   a resume planted '$1' is refused (planted)"
}
planted_resume resume-connectors 's/^      --strict-mcp-config \${roots/      ${roots/' 'no --strict-mcp-config, so the connectors of the account load'
planted_resume resume-bare 's/^      --strict-mcp-config \${roots/      --strict-mcp-config --bare ${roots/' 'the flag --bare stands in the resume'

section "the UI-test run keeps its own browser server beside the strict flag"
ui_test_faults() {  # ui_test_faults <call>: what the run of a UI test lacks, one fault per line
  jq -r '.args as $a
    | (if ($a | index("--strict-mcp-config")) == null then "no --strict-mcp-config" else empty end),
      (if ($a | index("--mcp-config")) as $i | $i == null or ($a[$i + 1] | startswith("{\"mcpServers\":{\"chrome-devtools\"") | not) then "no browser server in --mcp-config" else empty end),
      (if ($a | index("--allowedTools")) as $i | $i == null or $a[$i + 1] != "mcp__chrome-devtools" then "--allowedTools is not the tools of the browser" else empty end)' <<< "$1"
}
ui_test_run() { run_command ui-test normal-hard --budget 100; [ "$rc" = 0 ] || { echo "the command refused: $err"; return; }; ui_test_faults "$(last_call)"; }
[ -z "$(ui_test_run)" ] || fail "the UI-test run of the command lost its browser server: $(ui_test_run)"
echo "  ok   the UI-test run has its browser server, the strict flag and the browser's tools (innocent)"
for planted in 's/--mcp-config "$mcp"/--no-browser "$mcp"/|no browser server in --mcp-config' \
               's/ --strict-mcp-config --no-session-persistence/ --no-session-persistence/|no --strict-mcp-config' \
               's/--allowedTools mcp__chrome-devtools/--allowedTools Read/|--allowedTools is not the tools of the browser'; do
  plant_command ui-test lib/start-phase.sh "${planted%%|*}"
  faults="$(ui_test_run)"; command=''
  [ "$faults" = "${planted##*|}" ] || fail "a UI-test run planted with '${planted%%|*}' was not refused as '${planted##*|}': $faults"
done
echo "  ok   a UI-test run without its --mcp-config, its strict flag or its browser tools is refused (planted)"

section "the budget is read from the Setup file for a UI test too"
setup "$(jq -cn --argjson u "$(entry claude-haiku-5-5 high 60000)" '{"ui-test":{claude:$u}}')"
run_command ui-test normal-hard --setup-file "$WORK/setup.json"
[ "$rc" = 0 ] || fail "the command refused a UI test on a Setup: $err"
grep -Eq '^ui-test[0-9]+-haiku5\.5-high-90k-[0-9a-f]{5}$' <<< "$session" || fail "the name does not carry the 90000 of the ui-test entry: $session"
echo "  ok   a UI test on its entry is named 90k"
order codex
run_command build normal-hard --setup-file "$WORK/setup.json"
[ "$rc" = 2 ] && grep -qF 'no budget' <<< "$err" || fail "a tool without an entry in the Setup and without --budget was not refused for its budget: rc $rc: $err"
echo "  ok   a tool with no entry for its phase, and no --budget, is refused for its budget"
order claude
plant_command phase-and-tool bin/start-phase.sh 's/\.\[\$phase\]\[\$tool\]\.budget_tokens/.build[$tool].budget_tokens/'
run_command ui-test normal-hard --setup-file "$WORK/setup.json"; command=''
{ [ "$rc" = 2 ] && grep -qF 'no budget' <<< "$err"; } || ! grep -Eq -- '-90k-' <<< "$session" || fail "a read of the budget that fixes the phase still gave the 90000 of the ui-test entry"
echo "  ok   a read of the budget that fixes the phase, not the Setup's phase, gives no budget (planted)"

echo "all phase setup cases passed"
