#!/usr/bin/env bash
# the report and --dry-run; one section of the suite, run by tests/check.sh with the others
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

section "the report and --dry-run: a dry run writes nothing and says what a run would do; a run and a second run report the same on both twins"
init_twin() {  # init_twin <sh|ps1> <dir> <log> [--dry-run]: init without doctor
  local twin="$1" dir="$2" log="$3"; shift 3
  if [ "$twin" = sh ]; then
    bash "$ROOT/bin/init.sh" "$dir" --no-doctor "$@" > "$log" 2>&1
  else
    local ps=(); for a in "$@"; do [ "$a" = --dry-run ] && ps+=(-DryRun); done
    pwsh -NoProfile -File "$ROOT/bin/init.ps1" -TargetDir "$(native "$dir")" -NoDoctor ${ps[@]+"${ps[@]}"} > "$log" 2>&1
  fi
}
# The report lines of a log; the .gitignore line without its note, and Claude Code's folder under one
# name, because on Windows bash spells it /tmp/... and PowerShell C:/Users/.../Temp/...
report_of() { sed -n '/^init would change in /,/^====/p; /^init changed in /,/^====/p' "$1" | grep -a '^  ' | tr -d '\r' | sed 's/^  \.gitignore .*/  .gitignore/; s#[^ ]*/claude-config#CLAUDE_CONFIG_DIR#g'; }
for twin in sh ps1; do
  D="$WORK/report-$twin"
  git init -q "$D"; echo readme > "$D/README.md"; git -C "$D" add README.md
  git -C "$D" -c user.name=check -c user.email=check@localhost commit -q -m init
  git -C "$D" config core.autocrlf false
  mkdir -p "$D/.ai-core/bin"; echo old > "$D/.ai-core/bin/left-behind"
  printf 'AGENTS="claude codex"\n' > "$D/.ai-core/config.env"
  # 1. the dry run
  init_twin "$twin" "$D" "$WORK/report-$twin-dry.log" --dry-run || fail "init.$twin --dry-run failed (see $WORK/report-$twin-dry.log)"
  [ "$(git -C "$D" status --porcelain --untracked-files=all | tr -d '\r' | sort | tr '\n' '|')" = "?? .ai-core/bin/left-behind|?? .ai-core/config.env|" ] || fail "init.$twin --dry-run wrote or removed something: $(git -C "$D" status --porcelain --untracked-files=all | tr '\n' ' ')"
  [ ! -e "$D/.git/info/exclude" ] || ! grep -q 'setup-ai-core' "$D/.git/info/exclude" || fail "init.$twin --dry-run wrote the exclude file"
  grep -aq "^init would change in report-$twin:" "$WORK/report-$twin-dry.log" || fail "init.$twin --dry-run has no report"
  grep -a '^  created ' "$WORK/report-$twin-dry.log" | grep -q 'AGENTS.md' || fail "init.$twin --dry-run does not list AGENTS.md as created"
  grep -a '^  created ' "$WORK/report-$twin-dry.log" | grep -q '.claude/settings.json' || fail "init.$twin --dry-run does not list the Claude Code settings as created"
  grep -a '^  created ' "$WORK/report-$twin-dry.log" | grep -q '.cursorrules' && fail "init.$twin --dry-run lists the file of an agent the project does not serve"
  grep -aq '^  removed    .ai-core/bin$' "$WORK/report-$twin-dry.log" || fail "init.$twin --dry-run does not list .ai-core/bin as removed"
  grep -aq '^  kept       .ai-core/config.env ' "$WORK/report-$twin-dry.log" || fail "init.$twin --dry-run does not list config.env as kept"
  grep -aq '^  .gitignore would change' "$WORK/report-$twin-dry.log" || fail "init.$twin --dry-run does not say .gitignore would change"
  grep -aq '^  nothing was written (dry run)$' "$WORK/report-$twin-dry.log" || fail "init.$twin --dry-run does not say that nothing was written"
  # 2. the run: what the dry run announced, done and reported the same way
  init_twin "$twin" "$D" "$WORK/report-$twin-1.log" || fail "init.$twin run 1 failed (see $WORK/report-$twin-1.log)"
  [ -f "$D/AGENTS.md" ] && [ ! -e "$D/.ai-core/bin" ] || fail "init.$twin run 1 did not do what the dry run announced"
  diff <(report_of "$WORK/report-$twin-dry.log" | sed 's/would change/changed/; s/^  nothing was written (dry run)$//' | grep .) <(report_of "$WORK/report-$twin-1.log") > /dev/null || fail "init.$twin: the run reports something else than its dry run announced: $(diff <(report_of "$WORK/report-$twin-dry.log") <(report_of "$WORK/report-$twin-1.log"))"
  # 3. the second run: nothing created, refreshed or removed; the exclude file untouched
  cp "$D/.git/info/exclude" "$WORK/report-$twin.exclude"
  init_twin "$twin" "$D" "$WORK/report-$twin-2.log" || fail "init.$twin run 2 failed (see $WORK/report-$twin-2.log)"
  grep -aqE '^  (created|refreshed|removed) ' "$WORK/report-$twin-2.log" && fail "init.$twin run 2 changed something: $(grep -aE '^  (created|refreshed|removed) ' "$WORK/report-$twin-2.log")"
  grep -aq '^  .gitignore changed' "$WORK/report-$twin-2.log" && fail "init.$twin run 2 changed .gitignore again"
  cmp -s "$D/.git/info/exclude" "$WORK/report-$twin.exclude" || fail "init.$twin run 2 rewrote the exclude file"
  # 4. a project folder: its AGENTS.md is generated on every run
  F="$WORK/folder-$twin"; mkdir -p "$F"; git init -q "$F/app"
  init_twin "$twin" "$F" "$WORK/folder-$twin-1.log" || fail "init.$twin on a project folder failed (see $WORK/folder-$twin-1.log)"
  grep -aq 'No such file or directory' "$WORK/folder-$twin-1.log" && fail "init.$twin printed a shell error on a project folder without .ai-core/DEPLOYED: $(grep -a 'No such file' "$WORK/folder-$twin-1.log")"
  init_twin "$twin" "$F" "$WORK/folder-$twin-2.log" || fail "init.$twin run 2 on a project folder failed (see $WORK/folder-$twin-2.log)"
  grep -aqE '^  (created|refreshed|removed) ' "$WORK/folder-$twin-2.log" && fail "init.$twin run 2 on a project folder changed something: $(grep -aE '^  (created|refreshed|removed) ' "$WORK/folder-$twin-2.log")"
  grep -q '^| `app` |' "$F/AGENTS.md" || fail "the folder's AGENTS.md lost the map ($twin)"
done
for run in dry 1 2; do
  diff <(report_of "$WORK/report-sh-$run.log" | sed 's/report-sh/report-TWIN/') <(report_of "$WORK/report-ps1-$run.log" | sed 's/report-ps1/report-TWIN/') > /dev/null || fail "the report of run $run differs between the twins: $(diff <(report_of "$WORK/report-sh-$run.log") <(report_of "$WORK/report-ps1-$run.log"))"
done
echo "  dry run: nothing written, created/removed/kept/.gitignore announced; run 1 reports the same; run 2 only unchanged files; identical on both twins"
section "init adds the rules as instructions to an opencode.json the checkout had, beside its own MCP server; the run after changes nothing; both twins"
for twin in sh ps1; do
  G="$WORK/opencode-first-$twin"; git init -q "$G"; mkdir -p "$G/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$G/.ai-core/config.env"
  printf '{\n  "mcp": {\n    "docs": { "type": "local", "command": ["docs-server"], "enabled": true }\n  }\n}\n' > "$G/opencode.json"
  for run in 1 2; do
    if [ "$twin" = sh ]; then bash "$ROOT/bin/init.sh" "$G" --no-doctor > "$G-$run.log" 2>&1
    else pwsh -NoProfile -File "$ROOT/bin/init.ps1" -TargetDir "$(native "$G")" -NoDoctor > "$G-$run.log" 2>&1; fi || fail "init.$twin run $run on a checkout with an opencode.json of its own (see $G-$run.log)"
  done
  [ "$(jq -c '.instructions' "$G/opencode.json")" = '[".ai-core/rules/rules.md",".ai-core/rules/skills.md",".ai-core/rules/rules.local.md"]' ] && [ "$(jq -r '.mcp.docs.command[0]' "$G/opencode.json")" = 'docs-server' ] || fail "init.$twin did not add the instructions to the checkout's opencode.json, or lost its MCP server: $(jq -c . "$G/opencode.json")"
  grep -aqE '^  (created|refreshed|removed) ' "$G-2.log" && fail "init.$twin changes something on the run after: $(grep -aE '^  (created|refreshed|removed) ' "$G-2.log")"
done
echo "  the instructions beside the checkout's own MCP server, nothing changed on the run after, on both twins"
exit 0
