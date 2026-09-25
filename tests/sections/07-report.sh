#!/usr/bin/env bash
# the report and --dry-run; one section of the suite, run by tests/check.sh with the others
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

section "the report and --dry-run: a dry run writes nothing and says what a run would do; a run and a second run report the same on both twins"
make_graft_fake
init_twin() {  # init_twin <sh|ps1> <dir> <log> [--dry-run]: init with the fake Graft on the PATH
  local twin="$1" dir="$2" log="$3"; shift 3
  if [ "$twin" = sh ]; then
    GRAFT_FAKE_LOG="$WORK/report.args" PATH="$WORK/graftbin:$PATH" bash "$ROOT/bin/init.sh" "$dir" --no-doctor "$@" > "$log" 2>&1
  else
    local ps=(); for a in "$@"; do [ "$a" = --dry-run ] && ps+=(-DryRun); done
    GRAFT_FAKE_LOG="$(native "$WORK/report.args")" PATH="$WORK/graftbin:$PATH" pwsh -NoProfile -File "$ROOT/bin/init.ps1" -TargetDir "$(native "$dir")" -NoDoctor ${ps[@]+"${ps[@]}"} > "$log" 2>&1
  fi
}
report_of() { sed -n '/^init would change in /,/^====/p; /^init changed in /,/^====/p' "$1" | grep -a '^  ' | tr -d '\r' | sed 's/^  \.gitignore .*/  .gitignore/'; }   # the report lines of a log; the .gitignore line without its note
for twin in sh ps1; do
  D="$WORK/report-$twin"; : > "$WORK/report.args"
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
  grep -a '^  created ' "$WORK/report-$twin-dry.log" | grep -q '.codex/config.toml' || fail "init.$twin --dry-run does not list the codex file as created"
  grep -a '^  created ' "$WORK/report-$twin-dry.log" | grep -q '.cursorrules' && fail "init.$twin --dry-run lists the file of an agent the project does not serve"
  grep -aq '^  removed    .ai-core/bin$' "$WORK/report-$twin-dry.log" || fail "init.$twin --dry-run does not list .ai-core/bin as removed"
  grep -aq '^  kept       .ai-core/config.env ' "$WORK/report-$twin-dry.log" || fail "init.$twin --dry-run does not list config.env as kept"
  grep -aq '^  .gitignore would change' "$WORK/report-$twin-dry.log" || fail "init.$twin --dry-run does not say .gitignore would change"
  grep -aq '^  nothing was written (dry run)$' "$WORK/report-$twin-dry.log" || fail "init.$twin --dry-run does not say that nothing was written"
  grep -aq '^  Graft would write (init):$' "$WORK/report-$twin-dry.log" && grep -aq '^      GEMINI.md ' "$WORK/report-$twin-dry.log" && grep -aq 'codex.config.toml' "$WORK/report-$twin-dry.log" || fail "init.$twin --dry-run does not show what Graft would write"
  grep -aq 'Graft would build the graph' "$WORK/report-$twin-dry.log" || fail "init.$twin --dry-run does not say the graph is not built"
  grep -aq 'graft build' "$WORK/report.args" && fail "init.$twin --dry-run built the graph"
  # 2. the run: what the dry run announced, done and reported the same way
  init_twin "$twin" "$D" "$WORK/report-$twin-1.log" || fail "init.$twin run 1 failed (see $WORK/report-$twin-1.log)"
  [ -f "$D/AGENTS.md" ] && [ ! -e "$D/.ai-core/bin" ] || fail "init.$twin run 1 did not do what the dry run announced"
  diff <(report_of "$WORK/report-$twin-dry.log" | sed 's/would change/changed/; s/^  nothing was written (dry run)$//' | grep .) <(report_of "$WORK/report-$twin-1.log") > /dev/null || fail "init.$twin: the run reports something else than its dry run announced: $(diff <(report_of "$WORK/report-$twin-dry.log") <(report_of "$WORK/report-$twin-1.log"))"
  grep -aq '^  Graft wrote in the repository:$' "$WORK/report-$twin-1.log" && grep -aq '^    AGENTS.md (appended)$' "$WORK/report-$twin-1.log" || fail "init.$twin does not report what Graft wrote in the repository: $(grep -a 'Graft' "$WORK/report-$twin-1.log" | tr '\n' '|')"
  grep -aq '^  Graft wrote on the machine:$' "$WORK/report-$twin-1.log" && grep -aq '^    ~.\.codex.config.toml (updated)$' "$WORK/report-$twin-1.log" || fail "init.$twin does not report what Graft wrote on the machine: $(grep -a 'Graft' "$WORK/report-$twin-1.log" | tr '\n' '|')"
  grep -aq '^  Graft graph: 2 nodes' "$WORK/report-$twin-1.log" || fail "init.$twin does not report the graph"
  # 3. the second run: nothing created, refreshed or removed; the exclude file untouched
  cp "$D/.git/info/exclude" "$WORK/report-$twin.exclude"
  init_twin "$twin" "$D" "$WORK/report-$twin-2.log" || fail "init.$twin run 2 failed (see $WORK/report-$twin-2.log)"
  grep -aqE '^  (created|refreshed|removed) ' "$WORK/report-$twin-2.log" && fail "init.$twin run 2 changed something: $(grep -aE '^  (created|refreshed|removed) ' "$WORK/report-$twin-2.log")"
  grep -aq '^  .gitignore changed' "$WORK/report-$twin-2.log" && fail "init.$twin run 2 changed .gitignore again"
  cmp -s "$D/.git/info/exclude" "$WORK/report-$twin.exclude" || fail "init.$twin run 2 rewrote the exclude file"
  # 4. a project folder: its AGENTS.md is generated on every run and keeps the block Graft appends to it
  F="$WORK/folder-$twin"; mkdir -p "$F"; git init -q "$F/app"; git init -q "$F/x-ai-core"   # a harness clone beside the repositories: Graft wires it, init takes that out again
  git init -q "$F/y-ai-core"; printf '/private/\n' > "$F/y-ai-core/.gitignore"   # one whose .gitignore is somebody's own
  init_twin "$twin" "$F" "$WORK/folder-$twin-1.log" || fail "init.$twin on a project folder failed (see $WORK/folder-$twin-1.log)"
  [ ! -e "$F/x-ai-core/AGENTS.md" ] && grep -aq '^  taken out of the harness clones (data, not code): x-ai-core/AGENTS.md' "$WORK/folder-$twin-1.log" || fail "init.$twin left what Graft wrote in the harness clone: $(ls -A "$F/x-ai-core" | tr '\n' ' ')"
  [ ! -e "$F/x-ai-core/.gitignore" ] && [ ! -e "$F/x-ai-core/.ignore" ] && [ ! -e "$F/y-ai-core/.ignore" ] && grep -aq 'x-ai-core/\.gitignore, x-ai-core/\.ignore' "$WORK/folder-$twin-1.log" || fail "init.$twin left the .gitignore or .ignore Graft wrote in a harness clone: $(ls -A "$F/x-ai-core" "$F/y-ai-core" | tr '\n' ' ')"
  [ "$(tr -d '\r' < "$F/y-ai-core/.gitignore")" = '/private/' ] || fail "init.$twin touched a harness clone's own .gitignore"
  grep -q '^<!-- graft:start -->' "$F/AGENTS.md" || fail "the fake Graft did not append its block to the folder's AGENTS.md ($twin)"
  init_twin "$twin" "$F" "$WORK/folder-$twin-2.log" || fail "init.$twin run 2 on a project folder failed (see $WORK/folder-$twin-2.log)"
  grep -aqE '^  (created|refreshed|removed) ' "$WORK/folder-$twin-2.log" && fail "init.$twin run 2 on a project folder changed something: $(grep -aE '^  (created|refreshed|removed) ' "$WORK/folder-$twin-2.log")"
  [ "$(grep -c '^<!-- graft:start -->' "$F/AGENTS.md")" = 1 ] && grep -q '^| `app` |' "$F/AGENTS.md" || fail "the folder's AGENTS.md lost the map or Graft's block ($twin)"
done
for run in dry 1 2; do
  diff <(report_of "$WORK/report-sh-$run.log" | sed 's/report-sh/report-TWIN/') <(report_of "$WORK/report-ps1-$run.log" | sed 's/report-ps1/report-TWIN/') > /dev/null || fail "the report of run $run differs between the twins: $(diff <(report_of "$WORK/report-sh-$run.log") <(report_of "$WORK/report-ps1-$run.log"))"
done
echo "  dry run: nothing written, created/removed/kept/.gitignore and Graft's lists announced; run 1 reports the same; run 2 only unchanged files, the folder's AGENTS.md keeps Graft's block; identical on both twins"
exit 0
