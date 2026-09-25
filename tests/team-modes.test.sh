#!/usr/bin/env bash
# The gate on the three team modes: what team-modes-check sees, what it refuses, and what
# team-modes-install would run.
#
# A fake claude on PATH answers `plugin list`, and a temporary HOME holds or lacks the skill
# folder, so every state a machine can be in is arranged here without touching this one.
#
#   bash test/team-modes.test.sh

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fake="$(mktemp -d)"
trap 'rm -rf "$fake"' EXIT

# The fake tool: `claude plugin list` names what the test says is installed.
cat > "$fake/claude" <<EOF
#!/usr/bin/env bash
case "\$*" in
  "plugin list") cat "$fake/plugins.txt" ;;
esac
exit 0
EOF
chmod +x "$fake/claude"
export PATH="$fake:$PATH"
export HOME="$fake/home"
mkdir -p "$HOME"
export TEAM_MODES_FILE="$root/templates/.ai-core/team-modes.tsv"
# The skill probe also looks in the current directory's skill folders, and a project-level
# install in this checkout would count as installed; the test runs from its own directory.
cd "$fake"

failed=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}
run_check() { bash "$root/bin/team-modes-check.sh" "$@" 2>&1; }

echo 'nothing installed: four MISSING lines (three modes and the archify skill) with their install commands, and a refusal'
: > "$fake/plugins.txt"
out="$(run_check --tool claude)"; code=$?
check 'exit 1'                      1 "$code"
check 'four missing'                4 "$(grep -c '^MISSING' <<< "$out")"
check 'caveman names its installer' yes "$(grep -q 'MISSING .*caveman.*npx skills add JuliusBrussee/caveman' <<< "$out" && echo yes || echo no)"
check 'ponytail names its installer' yes "$(grep -q 'MISSING .*ponytail.*claude plugin install ponytail@ponytail' <<< "$out" && echo yes || echo no)"
check 'the refusal says no work starts' yes "$(grep -q '^REFUSED: 4 mode(s) missing.*No work starts' <<< "$out" && echo yes || echo no)"

echo 'the two plugins installed (i-have-adhd proven by its always-on flag), the skills not: two MISSING'
printf 'Installed plugins:\n  ponytail@ponytail\n  i-have-adhd@i-have-adhd\n' > "$fake/plugins.txt"
mkdir -p "$HOME/.claude"; : > "$HOME/.claude/.i-have-adhd-always"
out="$(run_check --tool claude)"; code=$?
check 'exit 1'        1 "$code"
check 'two missing'   2 "$(grep -c '^MISSING' <<< "$out")"
check 'it is caveman' yes "$(grep -q '^MISSING .*caveman' <<< "$out" && echo yes || echo no)"

echo 'all four installed: every line ok, exit 0'
mkdir -p "$HOME/.claude/skills/caveman" "$HOME/.claude/skills/archify"
out="$(run_check --tool claude)"; code=$?
check 'exit 0'     0 "$code"
check 'four ok'    4 "$(grep -c '^ok ' <<< "$out")"
check 'says all present' yes "$(grep -q 'team modes: all 4 present for: claude' <<< "$out" && echo yes || echo no)"
check 'and names the level' yes "$(grep -q 'ok .*claude caveman (lite)' <<< "$out" && echo yes || echo no)"

echo 'the shared .agents/skills folder counts as installed too'
rm -rf "$HOME/.claude/skills/caveman"; mkdir -p "$HOME/.agents/skills/caveman"
out="$(run_check --tool claude)"; code=$?
check 'exit 0' 0 "$code"

echo 'a row without a probe is refused as unverifiable, never guessed'
printf 'hermes\tcaveman\tlite\tnone\t-\t-\n' > "$fake/no-probe.tsv"
out="$(TEAM_MODES_FILE="$fake/no-probe.tsv" run_check --tool hermes)"; code=$?
check 'exit 1'                    1 "$code"
check 'names the unverified mode' yes "$(grep -q '^UNVERIFIED .*hermes caveman: no probe yet' <<< "$out" && echo yes || echo no)"

echo 'a tool the table does not know is refused with the row to add'
out="$(run_check --tool hermes)"; code=$?
check 'exit 1'        1 "$code"
check 'asks for rows' yes "$(grep -q '^UNVERIFIED  hermes: no rows' <<< "$out" && echo yes || echo no)"

echo 'without --tool, only tools on PATH are checked; none on PATH is a note and exit 0'
# The test itself may run inside an agent tool's shell, whose environment names that tool; the
# case here is a plain terminal, so those variables are taken away too.
out="$(env -u CLAUDECODE -u CODEX_SANDBOX -u CODEX_SANDBOX_NETWORK_DISABLED -u CODEX_THREAD_ID -u GEMINI_CLI PATH="$fake/none:/usr/bin:/bin" bash "$root/bin/team-modes-check.sh" 2>&1)"; code=$?
check 'exit 0'  0 "$code"
check 'says so' yes "$(grep -q 'no agent tool from team-modes.tsv is on PATH' <<< "$out" && echo yes || echo no)"

echo 'the running tool is read from its environment: a Claude session checks claude only, whatever else is on PATH'
cat > "$fake/codex" <<EOF
#!/usr/bin/env bash
case "\$*" in
  "plugin list") printf 'PLUGIN  STATUS  VERSION  PATH\nponytail@ponytail  not installed\ni-have-adhd@i-have-adhd  not installed\n' ;;
esac
exit 0
EOF
chmod +x "$fake/codex"
mkdir -p "$HOME/.agents/skills/caveman"
printf 'Installed plugins:\n  ponytail@ponytail\n  i-have-adhd@i-have-adhd\n' > "$fake/plugins.txt"
out="$(CLAUDECODE=1 bash "$root/bin/team-modes-check.sh" 2>&1)"; code=$?
check 'exit 0'              0 "$code"
check 'codex not mentioned' no  "$(grep -q 'codex' <<< "$out" && echo yes || echo no)"
check 'claude checked'      yes "$(grep -q 'present for: claude' <<< "$out" && echo yes || echo no)"

echo 'a plugin that Codex lists as not installed is missing, not present'
out="$(run_check --tool codex)"; code=$?
check 'exit 1'                        1 "$code"
check 'ponytail missing for codex'    yes "$(grep -q '^MISSING .*codex ponytail' <<< "$out" && echo yes || echo no)"
check 'i-have-adhd missing for codex' yes "$(grep -q '^MISSING .*codex i-have-adhd' <<< "$out" && echo yes || echo no)"
rm -rf "$HOME/.agents/skills/caveman"; : > "$fake/plugins.txt"

echo 'a table whose probes always pass is what the other tests use'
printf 'claude\tcaveman\tlite\talways\t-\t-\n' > "$fake/always.tsv"
out="$(TEAM_MODES_FILE="$fake/always.tsv" run_check --tool claude)"; code=$?
check 'exit 0' 0 "$code"

echo 'a table that is not there is a refusal, not an empty pass'
out="$(TEAM_MODES_FILE="$fake/no-such-table.tsv" run_check --tool claude)"; code=$?
check 'exit 1'  1 "$code"
check 'says so' yes "$(grep -q '^REFUSED: .*is missing - it is the table of the team modes' <<< "$out" && echo yes || echo no)"

echo 'team-modes-install --dry-run prints the install command of every missing mode and runs nothing'
: > "$fake/plugins.txt"; rm -rf "$HOME/.agents/skills/caveman" "$HOME/.claude/skills/archify"; rm -f "$HOME/.claude/.i-have-adhd-always"
out="$(bash "$root/bin/team-modes-install.sh" --tool claude --dry-run 2>&1)"; code=$?
check 'exit 0'                  0 "$code"
check 'four install lines'      4 "$(grep -c '^installing ' <<< "$out")"
check 'ponytail command whole'  yes "$(grep -q 'installing  claude ponytail: claude plugin marketplace add DietrichGebert/ponytail && claude plugin install ponytail@ponytail' <<< "$out" && echo yes || echo no)"

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
row() { printf '%s\t%s\t%s\t%s\t%s\t-\n' "$1" "$2" "$3" "$4" "$5"; }
{
  echo '# a stand-in table: no probe here is on this machine, so every row is missing'
  row probetool caveman     lite "file:$fake/nowhere-a" "printf 'caveman-a\n' >> '$marks' && cat >/dev/null && printf 'caveman-b\n' >> '$marks'"
  row probetool ponytail    full "file:$fake/nowhere-b" "printf 'ponytail-a\n' >> '$marks' && printf 'ponytail-b\n' >> '$marks'"
  row probetool i-have-adhd on   "file:$fake/nowhere-c" "printf 'adhd-a\n' >> '$marks' && printf 'adhd-b\n' >> '$marks'"
} > "$standin"
out="$(TEAM_MODES_FILE="$standin" bash "$root/bin/team-modes-install.sh" --tool probetool 2>&1 </dev/null)"; code=$?
check 'exit 0'              0 "$code"
check 'three install lines' 3 "$(grep -c '^installing ' <<< "$out")"
check 'the count says three' 'installed 3, failed 0, skipped 0.' "$(grep '^installed ' <<< "$out")"
check 'every half of every row ran, in order' \
  'caveman-a caveman-b ponytail-a ponytail-b adhd-a adhd-b' "$(tr '\n' ' ' < "$marks" | sed 's/ *$//')"

echo 'an install command that ends non-zero is counted FAILED and the run is red'
standin_bad="$fake/standin-bad.tsv"
row probetool caveman lite "file:$fake/nowhere-a" 'exit 3' > "$standin_bad"
out="$(TEAM_MODES_FILE="$standin_bad" bash "$root/bin/team-modes-install.sh" --tool probetool 2>&1 </dev/null)"; code=$?
check 'exit 1'          1 "$code"
check 'the row is named' yes "$(grep -q '^FAILED      probetool caveman: the install command exited non-zero' <<< "$out" && echo yes || echo no)"
check 'the count'       'installed 0, failed 1, skipped 0.' "$(grep '^installed ' <<< "$out")"

echo 'a --tool without a value is refused, and so is a flag standing in for one'
out="$(bash "$root/bin/team-modes-check.sh" --tool --quiet 2>&1)"; code=$?
check 'the check exits 2'    2 "$code"
check 'and says what is missing' yes "$(grep -q '^--tool needs a value' <<< "$out" && echo yes || echo no)"
out="$(bash "$root/bin/team-modes-install.sh" --tool 2>&1)"; code=$?
check 'the installer exits 2' 2 "$code"

echo 'session-start refuses before printing anything when a mode is missing'
out="$(cd "$root" && bash "$root/bin/session-start.sh" --tool claude 2>&1)"; code=$?
check 'exit 1'                     1 "$code"
check 'the first line is the gate' yes "$(echo "$out" | head -1 | grep -qE '^(ok |MISSING)' && echo yes || echo no)"
check 'it refuses'                 yes "$(grep -q '^REFUSED' <<< "$out" && echo yes || echo no)"
check 'no registries printed'      no  "$(grep -q '^## Registries' <<< "$out" && echo yes || echo no)"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
