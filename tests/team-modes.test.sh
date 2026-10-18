#!/usr/bin/env bash
# The gate on the team modes: what team-modes-check sees, what it refuses, and what
# team-modes-install would run.
#
# Fake tools on PATH answer `plugin list`, and a temporary HOME holds or lacks the skill
# folder, so every state a machine can be in is arranged here without touching this one. The
# mechanism is proven on a table of its own; the real table is proven for what it holds.
#
#   bash test/team-modes.test.sh

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/tool-environment.sh"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fake="$(mktemp -d)"
trap 'rm -rf "$fake"' EXIT

# The fake tools: `claude plugin list` and `agy plugin list` name what the test says is installed.
for tool in claude agy; do
  cat > "$fake/$tool" <<EOF
#!/usr/bin/env bash
case "\$*" in
  "plugin list") cat "$fake/$tool-plugins.txt" ;;
esac
exit 0
EOF
  chmod +x "$fake/$tool"
  : > "$fake/$tool-plugins.txt"
done
export PATH="$fake:$PATH"
export HOME="$fake/home"
mkdir -p "$HOME"
real="$root/templates/.ai-core/team-modes.tsv"
table="$fake/modes.tsv"
{
  echo '# the mechanism: a plugin mode and a skill mode for claude, two plugin modes for codex'
  printf 'claude\tplugmode\tplugin:plug-a\tclaude plugin install plug-a@market\t-\n'
  printf 'claude\tskillmode\tskill:skill-a\tnpx -y skills@1.7.0 add https://example.com/skill-a -g -a claude-code -y\t-\n'
  printf 'codex\tplugmode\tplugin:plug-a\tcodex plugin install plug-a\t-\n'
  printf 'codex\tplugmode2\tplugin:plug-b\tcodex plugin install plug-b\t-\n'
} > "$table"
export TEAM_MODES_FILE="$table"
# The skill probe also looks in the current directory's skill folders, and a project-level
# install in this checkout would count as installed; the test runs from its own directory.
cd "$fake"

failed=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}
run_check() { bash "$root/bin/team-modes-check.sh" "$@" 2>&1; }
# The test itself may run inside an agent tool's shell, whose environment names that tool.
no_tool_env=(env)
while IFS= read -r variable; do no_tool_env+=(-u "$variable"); done < <(tool_environment_variables)

echo 'the real table: archify, and nothing else, for each of the four tools'
check 'one archify row per tool' 'agy claude codex gemini' \
  "$(tr -d '\r' < "$real" | awk -F'\t' '!/^#/ && NF >= 5 && $2 == "archify" { print $1 }' | sort | tr '\n' ' ' | sed 's/ *$//')"
check 'no other row' 0 "$(tr -d '\r' < "$real" | awk -F'\t' '!/^#/ && NF >= 5 && $2 != "archify"' | wc -l | tr -d ' ')"
check 'every row has five columns' 0 "$(tr -d '\r' < "$real" | awk -F'\t' '!/^#/ && NF > 0 && NF != 5' | wc -l | tr -d ' ')"

echo 'the real table for claude: archify missing, then present as a skill folder'
out="$(TEAM_MODES_FILE="$real" run_check --tool claude)"; code=$?
check 'exit 1'                    1 "$code"
check 'archify names its installer' yes "$(grep -q '^MISSING     claude archify - install: npx -y skills@1.7.0 add https://github.com/tt-a1i/archify/' <<< "$out" && echo yes || echo no)"
mkdir -p "$HOME/.claude/skills/archify"
out="$(TEAM_MODES_FILE="$real" run_check --tool claude)"; code=$?
check 'exit 0 with the skill'     0 "$code"
rm -rf "$HOME/.claude/skills/archify"

echo 'the real table for agy: archify is proven by agy plugin list, not by a skill folder'
mkdir -p "$HOME/.agents/skills/archify"
out="$(TEAM_MODES_FILE="$real" run_check --tool agy)"; code=$?
check 'a skill folder alone is missing' 1 "$code"
check 'and names the plugin install' yes "$(grep -q '^MISSING     agy archify - install: .*agy plugin install' <<< "$out" && echo yes || echo no)"
printf 'Installed plugins:\n- archify (enabled, 2.17.0)\n    Components: 1 skill\n' > "$fake/agy-plugins.txt"
out="$(TEAM_MODES_FILE="$real" run_check --tool agy)"; code=$?
check 'the plugin listed is present' 0 "$code"
rm -rf "$HOME/.agents/skills/archify"; : > "$fake/agy-plugins.txt"

echo 'the agy install leaves no folder behind, and ends as agy plugin install ended'
inst="$fake/inst"; mkdir -p "$inst/bin" "$inst/tmp"
printf '#!/usr/bin/env bash\nmkdir -p "$HOME/.agents/skills/archify"\n' > "$inst/bin/npx"
printf '#!/usr/bin/env bash\n[ "$1 $2" = "plugin install" ] && exit "${AGY_INSTALL_EXIT:-0}"\nexit 0\n' > "$inst/bin/agy"
chmod +x "$inst/bin/npx" "$inst/bin/agy"
agy_install="$(tr -d '\r' < "$real" | awk -F'\t' '!/^#/ && $1 == "agy" { print $4 }')"
for want in 0 3; do
  code=0; PATH="$inst/bin:$PATH" TMPDIR="$inst/tmp" AGY_INSTALL_EXIT="$want" bash -c "$agy_install" >/dev/null 2>&1 || code=$?
  check "agy plugin install exits $want: so does the install" "$want" "$code"
  check "agy plugin install exits $want: no folder left"      0 "$(ls -A "$inst/tmp" | wc -l | tr -d ' ')"
done
rm -rf "$HOME/.agents/skills/archify"

echo 'nothing installed: two MISSING lines with their install commands, and a refusal'
out="$(run_check --tool claude)"; code=$?
check 'exit 1'                      1 "$code"
check 'two missing'                 2 "$(grep -c '^MISSING' <<< "$out")"
check 'the plugin names its installer' yes "$(grep -q '^MISSING     claude plugmode - install: claude plugin install plug-a@market$' <<< "$out" && echo yes || echo no)"
check 'the refusal says no work starts' yes "$(grep -q '^REFUSED: 2 mode(s) missing.*No work starts without the team modes\.$' <<< "$out" && echo yes || echo no)"

echo 'the plugin installed, the skill not: one MISSING'
printf 'Installed plugins:\n  plug-a@market\n' > "$fake/claude-plugins.txt"
out="$(run_check --tool claude)"; code=$?
check 'exit 1'          1 "$code"
check 'one missing'     1 "$(grep -c '^MISSING' <<< "$out")"
check 'it is the skill' yes "$(grep -q '^MISSING     claude skillmode' <<< "$out" && echo yes || echo no)"

echo 'both installed: every line ok, exit 0'
mkdir -p "$HOME/.claude/skills/skill-a"
out="$(run_check --tool claude)"; code=$?
check 'exit 0'     0 "$code"
check 'two ok'     2 "$(grep -c '^ok ' <<< "$out")"
check 'says all present' yes "$(grep -q 'team modes: all 2 present for: claude' <<< "$out" && echo yes || echo no)"
check 'an ok line names tool and mode' yes "$(grep -q '^ok          claude skillmode$' <<< "$out" && echo yes || echo no)"

echo 'the shared .agents/skills folder counts as installed too'
rm -rf "$HOME/.claude/skills/skill-a"; mkdir -p "$HOME/.agents/skills/skill-a"
out="$(run_check --tool claude)"; code=$?
check 'exit 0' 0 "$code"

echo 'a row without a probe is refused as unverifiable, never guessed'
printf 'hermes\tsomemode\tnone\t-\t-\n' > "$fake/no-probe.tsv"
out="$(TEAM_MODES_FILE="$fake/no-probe.tsv" run_check --tool hermes)"; code=$?
check 'exit 1'                    1 "$code"
check 'names the unverified mode' yes "$(grep -q '^UNVERIFIED .*hermes somemode: no probe yet' <<< "$out" && echo yes || echo no)"

echo 'a tool the table does not know is refused with the row to add'
out="$(run_check --tool hermes)"; code=$?
check 'exit 1'        1 "$code"
check 'asks for rows' yes "$(grep -q '^UNVERIFIED  hermes: no rows' <<< "$out" && echo yes || echo no)"

echo 'without --tool, only tools on PATH are checked; none on PATH is a note and exit 0'
out="$("${no_tool_env[@]}" PATH="$fake/none:/usr/bin:/bin" bash "$root/bin/team-modes-check.sh" 2>&1)"; code=$?
check 'exit 0'  0 "$code"
check 'says so' yes "$(grep -q 'no agent tool from modes.tsv is on PATH' <<< "$out" && echo yes || echo no)"

echo 'the running tool is read from its environment: a Claude session checks claude only, whatever else is on PATH'
cat > "$fake/codex" <<EOF
#!/usr/bin/env bash
case "\$*" in
  "plugin list") printf 'PLUGIN  STATUS  VERSION  PATH\nplug-a@market  not installed\nplug-b@market  not installed\n' ;;
esac
exit 0
EOF
chmod +x "$fake/codex"
out="$("${no_tool_env[@]}" CLAUDECODE=1 bash "$root/bin/team-modes-check.sh" 2>&1)"; code=$?
check 'exit 0'              0 "$code"
check 'codex not mentioned' no  "$(grep -q 'codex' <<< "$out" && echo yes || echo no)"
check 'claude checked'      yes "$(grep -q 'present for: claude' <<< "$out" && echo yes || echo no)"
echo 'a Codex session started from a Claude Code shell carries both variables: Codex is checked'
out="$("${no_tool_env[@]}" CLAUDECODE=1 CODEX_THREAD_ID=t bash "$root/bin/team-modes-check.sh" 2>&1)"
check 'codex checked'       yes "$(grep -q -E '^(ok|MISSING) +codex ' <<< "$out" && echo yes || echo no)"
check 'claude not checked'  no  "$(grep -q 'claude' <<< "$out" && echo yes || echo no)"
echo 'an agy session started from a Claude Code shell carries both variables: agy is checked'
out="$("${no_tool_env[@]}" CLAUDECODE=1 ANTIGRAVITY_AGENT=1 TEAM_MODES_FILE="$real" bash "$root/bin/team-modes-check.sh" 2>&1)"
check 'agy checked'         yes "$(grep -q -E '^(ok|MISSING) +agy archify' <<< "$out" && echo yes || echo no)"
check 'claude not checked'  no  "$(grep -q 'claude' <<< "$out" && echo yes || echo no)"
echo 'an agy session alone is agy; a Codex session started from agy is Codex'
out="$("${no_tool_env[@]}" ANTIGRAVITY_AGENT=1 TEAM_MODES_FILE="$real" bash "$root/bin/team-modes-check.sh" 2>&1)"
check 'agy alone checked'   yes "$(grep -q -E '^(ok|MISSING) +agy archify' <<< "$out" && echo yes || echo no)"
out="$("${no_tool_env[@]}" ANTIGRAVITY_AGENT=1 CODEX_THREAD_ID=t TEAM_MODES_FILE="$real" bash "$root/bin/team-modes-check.sh" 2>&1)"
check 'codex over agy'      yes "$(grep -q -E '^(ok|MISSING) +codex archify' <<< "$out" && echo yes || echo no)"
check 'agy not checked'     no  "$(grep -q -E '^(ok|MISSING) +agy ' <<< "$out" && echo yes || echo no)"

echo 'each environment-selected tool still refuses a missing mode in production'
printf 'claude\tmode\tfile:%s/missing\t-\t-\ncodex\tmode\tfile:%s/missing\t-\t-\nagy\tmode\tfile:%s/missing\t-\t-\ngemini\tmode\tfile:%s/missing\t-\t-\n' "$fake" "$fake" "$fake" "$fake" > "$fake/missing.tsv"
while IFS= read -r variable; do
  out="$("${no_tool_env[@]}" "$variable=fixture" TEAM_MODES_FILE="$fake/missing.tsv" bash "$root/bin/team-modes-check.sh" 2>&1)"; code=$?
  check "$variable refuses" 1 "$code"
  check "$variable missing" yes "$(grep -q '^MISSING' <<< "$out" && echo yes || echo no)"
done < <(tool_environment_variables)
out="$(CODEX_THREAD_ID=fixture run_check --tool claude)"; code=$?
check 'explicit tool overrides identity' 0 "$code"

echo 'a plugin that Codex lists as not installed is missing, not present'
out="$(run_check --tool codex)"; code=$?
check 'exit 1'                     1 "$code"
check 'plugmode missing for codex'  yes "$(grep -q '^MISSING .*codex plugmode ' <<< "$out" && echo yes || echo no)"
check 'plugmode2 missing for codex' yes "$(grep -q '^MISSING .*codex plugmode2 ' <<< "$out" && echo yes || echo no)"
rm -rf "$HOME/.agents/skills/skill-a"; : > "$fake/claude-plugins.txt"

echo 'a table whose probes always pass is what the other tests use'
printf 'claude\tmode\talways\t-\t-\n' > "$fake/always.tsv"
out="$(TEAM_MODES_FILE="$fake/always.tsv" run_check --tool claude)"; code=$?
check 'exit 0' 0 "$code"

echo 'a row that is not five columns wide is a refusal that names the table and the line, also for the installer'
{ printf '# an old table that still carries a level column\n'; printf 'claude\tmode\ton\talways\t-\t-\n'; } > "$fake/six.tsv"
out="$(TEAM_MODES_FILE="$fake/six.tsv" run_check --tool claude)"; code=$?
check 'exit 1'  1 "$code"
check 'names the columns and the line' yes "$(grep -q '^REFUSED: .*six.tsv has rows that are not the five columns tool, mode, probe, install, verified, on line(s) 2\.$' <<< "$out" && echo yes || echo no)"
check 'no probe is blamed' no "$(grep -q '^UNVERIFIED' <<< "$out" && echo yes || echo no)"
out="$(TEAM_MODES_FILE="$fake/six.tsv" bash "$root/bin/team-modes-install.sh" --tool claude 2>&1 </dev/null)"; code=$?
check 'the installer exits 1'   1 "$code"
check 'and passes the refusal on' yes "$(grep -q '^REFUSED: .*has rows that are not the five columns' <<< "$out" && echo yes || echo no)"

echo 'a table that is not there is a refusal, not an empty pass'
out="$(TEAM_MODES_FILE="$fake/no-such-table.tsv" run_check --tool claude)"; code=$?
check 'exit 1'  1 "$code"
check 'says so' yes "$(grep -q '^REFUSED: .*is missing - it is the table of the team modes' <<< "$out" && echo yes || echo no)"

echo 'team-modes-install --dry-run prints the install command of every missing mode and runs nothing'
out="$(bash "$root/bin/team-modes-install.sh" --tool claude --dry-run 2>&1)"; code=$?
check 'exit 0'                  0 "$code"
check 'two install lines'       2 "$(grep -c '^installing ' <<< "$out")"
check 'the skill command whole' yes "$(grep -q '^installing  claude skillmode: npx -y skills@1.7.0 add https://example.com/skill-a -g -a claude-code -y$' <<< "$out" && echo yes || echo no)"

# EVERY MISSING ROW'S COMMAND RUNS, NOT ONLY THE FIRST ONE. The install command is started
# inside the loop that reads the check's report, so it inherits the standard input that report
# is being read from. A command that reads one character - npx asking whether to fetch a
# package - swallows the rows under it, the loop ends after the first, and the run reports one
# installed mode over a machine that is still missing two. The first row of the stand-in table
# below has exactly that shape, and the marks file says which halves of which rows ran.
echo 'team-modes-install runs the command of every missing row, and both halves of each'
marks="$fake/marks.txt"
: > "$marks"
standin="$fake/standin.tsv"
row() { printf '%s\t%s\t%s\t%s\t-\n' "$1" "$2" "$3" "$4"; }
{
  echo '# a stand-in table: no probe here is on this machine, so every row is missing'
  row probetool mode-a "file:$fake/nowhere-a" "printf 'a1\n' >> '$marks' && cat >/dev/null && printf 'a2\n' >> '$marks'"
  row probetool mode-b "file:$fake/nowhere-b" "printf 'b1\n' >> '$marks' && printf 'b2\n' >> '$marks'"
  row probetool mode-c "file:$fake/nowhere-c" "printf 'c1\n' >> '$marks' && printf 'c2\n' >> '$marks'"
} > "$standin"
out="$(TEAM_MODES_FILE="$standin" bash "$root/bin/team-modes-install.sh" --tool probetool 2>&1 </dev/null)"; code=$?
check 'exit 0'              0 "$code"
check 'three install lines' 3 "$(grep -c '^installing ' <<< "$out")"
check 'the count says three' 'installed 3, failed 0, skipped 0.' "$(grep '^installed ' <<< "$out")"
check 'every half of every row ran, in order' 'a1 a2 b1 b2 c1 c2' "$(tr '\n' ' ' < "$marks" | sed 's/ *$//')"

echo 'an install command that ends non-zero is counted FAILED and the run is red'
standin_bad="$fake/standin-bad.tsv"
row probetool mode-a "file:$fake/nowhere-a" 'exit 3' > "$standin_bad"
out="$(TEAM_MODES_FILE="$standin_bad" bash "$root/bin/team-modes-install.sh" --tool probetool 2>&1 </dev/null)"; code=$?
check 'exit 1'          1 "$code"
check 'the row is named' yes "$(grep -q '^FAILED      probetool mode-a: the install command exited non-zero' <<< "$out" && echo yes || echo no)"
check 'the count'       'installed 0, failed 1, skipped 0.' "$(grep '^installed ' <<< "$out")"

echo 'a --tool without a value is refused, and so is a flag standing in for one'
out="$(bash "$root/bin/team-modes-check.sh" --tool --quiet 2>&1)"; code=$?
check 'the check exits 2'    2 "$code"
check 'and says what is missing' yes "$(grep -q '^--tool needs a value' <<< "$out" && echo yes || echo no)"
out="$(bash "$root/bin/team-modes-install.sh" --tool 2>&1)"; code=$?
check 'the installer exits 2' 2 "$code"

echo 'a plugin list of megabytes, the plugins at its top: both found, every time'
cat > "$fake/codex" <<EOF
#!/usr/bin/env bash
case "\$*" in
  "plugin list") printf 'PLUGIN  STATUS\nplug-a@market  installed, enabled\nplug-b@market  installed, enabled\n'
                 # a real tool that loses its reader ends non-zero; the fake ends as its writer did
                 awk 'BEGIN { for (i = 0; i < 100000; i++) printf "offered-%d@market  available\n", i }'; exit \$? ;;
esac
exit 0
EOF
found=0
for i in 1 2 3; do
  out="$(run_check --tool codex)"
  grep -q '^ok .*codex plugmode$' <<< "$out" && grep -q '^ok .*codex plugmode2$' <<< "$out" && found=$((found + 1))
done
check 'found in 3 of 3 runs' 3 "$found"

echo 'session-start refuses before printing anything when a mode is missing'
out="$(cd "$root" && TEAM_MODES_FILE="$real" bash "$root/bin/session-start.sh" --tool claude 2>&1)"; code=$?
check 'exit 1'                     1 "$code"
check 'the first line is the gate' yes "$(echo "$out" | head -1 | grep -qE '^(ok |MISSING)' && echo yes || echo no)"
check 'it refuses'                 yes "$(grep -q '^REFUSED' <<< "$out" && echo yes || echo no)"
check 'no registries printed'      no  "$(grep -q '^## Registries' <<< "$out" && echo yes || echo no)"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
