#!/usr/bin/env bash
# the report and --dry-run; one section of the suite, run by tests/check.sh with the others
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

section "the report and --dry-run: a dry run writes nothing and says what a run would do; a run and a second run report the same"
init_quiet() {  # init_quiet <dir> <log> [--dry-run]: init without doctor
  local dir="$1" log="$2"; shift 2
  bash "$ROOT/bin/init.sh" "$dir" --no-doctor "$@" > "$log" 2>&1
}
# The report lines of a log; the .gitignore line without its note, and Claude Code's folder under one name
report_of() { sed -n '/^init would change in /,/^====/p; /^init changed in /,/^====/p' "$1" | grep -a '^  ' | tr -d '\r' | sed 's/^  \.gitignore .*/  .gitignore/; s/would be written/written/; s#[^ ]*/claude-config#CLAUDE_CONFIG_DIR#g'; }
D="$WORK/report"
git init -q "$D"; echo readme > "$D/README.md"; git -C "$D" add README.md
git -C "$D" -c user.name=check -c user.email=check@localhost commit -q -m init
mkdir -p "$D/.ai-core/bin"; echo old > "$D/.ai-core/bin/left-behind"
printf 'AGENTS="claude codex"\n' > "$D/.ai-core/config.env"
# 1. the dry run
init_quiet "$D" "$WORK/report-dry.log" --dry-run || fail "init.sh --dry-run failed (see $WORK/report-dry.log)"
[ "$(git -C "$D" status --porcelain --untracked-files=all | tr -d '\r' | sort | tr '\n' '|')" = "?? .ai-core/bin/left-behind|?? .ai-core/config.env|" ] || fail "init.sh --dry-run wrote or removed something: $(git -C "$D" status --porcelain --untracked-files=all | tr '\n' ' ')"
[ ! -e "$D/.git/info/exclude" ] || ! grep -q 'setup-ai-core' "$D/.git/info/exclude" || fail "init.sh --dry-run wrote the exclude file"
grep -aq "^init would change in report:" "$WORK/report-dry.log" || fail "init.sh --dry-run has no report"
grep -a '^  created ' "$WORK/report-dry.log" | grep -q 'AGENTS.md' || fail "init.sh --dry-run does not list AGENTS.md as created"
grep -a '^  created ' "$WORK/report-dry.log" | grep -q '.claude/settings.json' || fail "init.sh --dry-run does not list the Claude Code settings as created"
grep -a '^  created ' "$WORK/report-dry.log" | grep -q '.cursorrules' && fail "init.sh --dry-run lists the file of an agent the project does not serve"
grep -aq '^  removed    .ai-core/bin$' "$WORK/report-dry.log" || fail "init.sh --dry-run does not list .ai-core/bin as removed"
grep -aq '^  kept       .ai-core/config.env ' "$WORK/report-dry.log" || fail "init.sh --dry-run does not list config.env as kept"
grep -aq '^  .gitignore would change' "$WORK/report-dry.log" || fail "init.sh --dry-run does not say .gitignore would change"
grep -aq '^  nothing was written (dry run)$' "$WORK/report-dry.log" || fail "init.sh --dry-run does not say that nothing was written"
# 2. the run: what the dry run announced, done and reported the same way
init_quiet "$D" "$WORK/report-1.log" || fail "init.sh run 1 failed (see $WORK/report-1.log)"
[ -f "$D/AGENTS.md" ] && [ ! -e "$D/.ai-core/bin" ] || fail "init.sh run 1 did not do what the dry run announced"
diff <(report_of "$WORK/report-dry.log" | sed 's/would change/changed/; s/^  nothing was written (dry run)$//' | grep .) <(report_of "$WORK/report-1.log") > /dev/null || fail "init.sh: the run reports something else than its dry run announced: $(diff <(report_of "$WORK/report-dry.log") <(report_of "$WORK/report-1.log"))"
# 3. the second run: nothing created, refreshed or removed; the exclude file untouched
cp "$D/.git/info/exclude" "$WORK/report.exclude"
init_quiet "$D" "$WORK/report-2.log" || fail "init.sh run 2 failed (see $WORK/report-2.log)"
grep -aqE '^  (created|refreshed|removed) ' "$WORK/report-2.log" && fail "init.sh run 2 changed something: $(grep -aE '^  (created|refreshed|removed) ' "$WORK/report-2.log")"
grep -aq '^  .gitignore changed' "$WORK/report-2.log" && fail "init.sh run 2 changed .gitignore again"
cmp -s "$D/.git/info/exclude" "$WORK/report.exclude" || fail "init.sh run 2 rewrote the exclude file"
# 4. a project folder: its AGENTS.md is generated on every run
F="$WORK/folder"; mkdir -p "$F"; git init -q "$F/app"
init_quiet "$F" "$WORK/folder-1.log" || fail "init.sh on a project folder failed (see $WORK/folder-1.log)"
grep -aq 'No such file or directory' "$WORK/folder-1.log" && fail "init.sh printed a shell error on a project folder without .ai-core/DEPLOYED: $(grep -a 'No such file' "$WORK/folder-1.log")"
init_quiet "$F" "$WORK/folder-2.log" || fail "init.sh run 2 on a project folder failed (see $WORK/folder-2.log)"
grep -aqE '^  (created|refreshed|removed) ' "$WORK/folder-2.log" && fail "init.sh run 2 on a project folder changed something: $(grep -aE '^  (created|refreshed|removed) ' "$WORK/folder-2.log")"
grep -q '^| `app` |' "$F/AGENTS.md" || fail "the folder's AGENTS.md lost the map"
grep -aq "^  claude -p runs: the denials written to $AI_CORE_HOME/.ai-core/claude-run-settings.json$" "$WORK/report-1.log" || fail "init.sh run 1 did not report the denials it wrote for the claude -p runs: $(grep -a 'claude -p runs' "$WORK/report-1.log")"
grep -aq 'claude -p runs' "$WORK/report-2.log" && fail "init.sh run 2 reported the denials for the claude -p runs again"
echo "  dry run: nothing written, created/removed/kept/.gitignore announced; run 1 reports the same; run 2 only unchanged files"
section "init adds the rules as instructions to an opencode.json the checkout had, beside its own MCP server; the run after changes nothing"
G="$WORK/opencode-first"; git init -q "$G"; mkdir -p "$G/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$G/.ai-core/config.env"
printf '{\n  "mcp": {\n    "docs": { "type": "local", "command": ["docs-server"], "enabled": true }\n  }\n}\n' > "$G/opencode.json"
for run in 1 2; do
  bash "$ROOT/bin/init.sh" "$G" --no-doctor > "$G-$run.log" 2>&1 || fail "init.sh run $run on a checkout with an opencode.json of its own (see $G-$run.log)"
done
[ "$(jq -c '.instructions' "$G/opencode.json")" = '[".ai-core/rules/rules.md",".ai-core/rules/skills.md",".ai-core/rules/rules.local.md"]' ] && [ "$(jq -r '.mcp.docs.command[0]' "$G/opencode.json")" = 'docs-server' ] || fail "init.sh did not add the instructions to the checkout's opencode.json, or lost its MCP server: $(jq -c . "$G/opencode.json")"
grep -aqE '^  (created|refreshed|removed) ' "$G-2.log" && fail "init.sh changes something on the run after: $(grep -aE '^  (created|refreshed|removed) ' "$G-2.log")"
echo "  the instructions beside the checkout's own MCP server, nothing changed on the run after"
exit 0
