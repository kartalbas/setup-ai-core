#!/usr/bin/env bash
# init --all; one section of the suite, run by tests/check.sh with the others
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

section "init --all: every git repository and start-issue worktree under a folder, a failing one reported, both twins"
for twin in sh ps; do
  mkdir -p "$WORK/all-$twin"
  for r in one two; do git init -q "$WORK/all-$twin/$r"; mkdir -p "$WORK/all-$twin/$r/.ai-core"; printf 'GRAFT_EXECUTION_MODE="skip"\n' > "$WORK/all-$twin/$r/.ai-core/config.env"; done
  git init -q "$WORK/all-$twin/broken"; mkdir -p "$WORK/all-$twin/broken/.ai-core"; printf 'GRAFT_EXECUTION_MODE="bogus"\n' > "$WORK/all-$twin/broken/.ai-core/config.env"
  mkdir -p "$WORK/all-$twin/not-a-repo" "$WORK/all-$twin/.ai-core"; printf 'GRAFT_EXECUTION_MODE="skip"\n' > "$WORK/all-$twin/.ai-core/config.env"
  git init -q "$WORK/all-$twin/x-ai-core"   # a harness clone beside the repositories is none of them
  # the worktrees ai-core start-issue puts under .worktrees/<repository>/: one of a repository, whose
  # own name ends like a harness clone's, and one of the harness clone
  for r in one x-ai-core; do git -C "$WORK/all-$twin/$r" commit -q --allow-empty -m start; done
  git -C "$WORK/all-$twin/one" worktree add -q -b issue-1-to-ai-core "$WORK/all-$twin/.worktrees/one/issue-1-to-ai-core"
  git -C "$WORK/all-$twin/x-ai-core" worktree add -q -b issue-2-rules "$WORK/all-$twin/.worktrees/x-ai-core/issue-2-rules"
  if [ "$twin" = sh ]; then
    bash "$ROOT/bin/init.sh" --all "$WORK/all-$twin" --no-doctor --dry-run > "$WORK/all-$twin-dry.log" 2>&1 && fail "init.sh --all --dry-run exited 0 with a failing repository"
    bash "$ROOT/bin/init.sh" --all "$WORK/all-$twin" --no-doctor > "$WORK/all-$twin.log" 2>&1 && fail "init.sh --all exited 0 with a failing repository"
  else
    pwsh -NoProfile -File "$ROOT/bin/init.ps1" -All "$(native "$WORK/all-$twin")" -NoDoctor -DryRun > "$WORK/all-$twin-dry.log" 2>&1 && fail "init.ps1 -All -DryRun exited 0 with a failing repository"
    pwsh -NoProfile -File "$ROOT/bin/init.ps1" -All "$(native "$WORK/all-$twin")" -NoDoctor > "$WORK/all-$twin.log" 2>&1 && fail "init.ps1 -All exited 0 with a failing repository"
  fi
  grep -aq '3 repositories would be initialized; failed: broken' "$WORK/all-$twin-dry.log" || fail "init --all --dry-run summary wrong for $twin: $(grep -a 'repositories' "$WORK/all-$twin-dry.log")"
  [ "$(grep -ac '^init would change in ' "$WORK/all-$twin-dry.log")" = 4 ] || fail "init --all --dry-run did not report every repository, the worktree and the folder ($twin)"
  grep -aq '^  created .*AGENTS.md' "$WORK/all-$twin.log" || fail "init --all did not report what it created ($twin)"
  grep -aq '3 repositories were initialized; failed: broken' "$WORK/all-$twin.log" || fail "init --all summary wrong for $twin: $(grep -a 'repositories' "$WORK/all-$twin.log")"
  [ -f "$WORK/all-$twin/one/AGENTS.md" ] && [ -f "$WORK/all-$twin/two/AGENTS.md" ] || fail "init --all did not initialize the good repositories ($twin)"
  grep -aq '^### \.worktrees/one/issue-1-to-ai-core' "$WORK/all-$twin.log" && [ -f "$WORK/all-$twin/.worktrees/one/issue-1-to-ai-core/.ai-core/rules/rules.md" ] || fail "init --all did not initialize the worktree under .worktrees/ ($twin)"
  [ -e "$WORK/all-$twin/.worktrees/x-ai-core/issue-2-rules/.ai-core" ] && fail "init --all initialized a worktree of a harness clone ($twin)"
  [ -e "$WORK/all-$twin/not-a-repo/.ai-core" ] && fail "init --all touched a folder that is not a repository ($twin)"
  [ -e "$WORK/all-$twin/x-ai-core/.ai-core" ] && fail "init --all initialized a harness clone ($twin)"
  grep -q 'x-ai-core' "$WORK/all-$twin/AGENTS.md" && fail "the project folder's AGENTS.md lists a harness clone ($twin)"
  grep -q 'written by init for a project folder' "$WORK/all-$twin/AGENTS.md" || fail "init --all did not write the project folder's AGENTS.md ($twin)"
  for r in one two broken; do grep -q "| \`$r\` | \`$r/AGENTS.md\` |" "$WORK/all-$twin/AGENTS.md" || fail "the project folder's AGENTS.md does not list $r ($twin)"; done
  grep -q 'not-a-repo' "$WORK/all-$twin/AGENTS.md" && fail "the project folder's AGENTS.md lists a folder that is not a repository ($twin)"
  [ -f "$WORK/all-$twin/.ai-core/rules/rules.md" ] || fail "init --all did not give the project folder the rules ($twin)"
done
diff <(sed "s/^# all-sh$/# FOLDER/" "$WORK/all-sh/AGENTS.md") <(sed "s/^# all-ps$/# FOLDER/" "$WORK/all-ps/AGENTS.md") > /dev/null || fail "the project folder's AGENTS.md differs between the twins"
echo "  2 repositories and a worktree under .worktrees/ initialized, 1 failed and named, the plain folder, the harness clone and its worktree untouched, the folder's AGENTS.md lists the three, on both twins"

section "init --all gives the folder its rules before its repositories: a repository with the folder's rules names them without the @ in one run, the folder's rules older or missing; both twins"
for twin in sh ps; do
  F="$WORK/order-$twin"; mkdir -p "$F/.ai-core"; printf 'GRAFT_EXECUTION_MODE="skip"\n' > "$F/.ai-core/config.env"
  git init -q "$F/app"; mkdir -p "$F/app/.ai-core"; printf 'GRAFT_EXECUTION_MODE="skip"\n' > "$F/app/.ai-core/config.env"
  for run in 1 2 3; do
    [ "$run" = 2 ] && printf 'a rule of an older version\n' >> "$F/.ai-core/rules/rules.md"
    if [ "$twin" = sh ]; then bash "$ROOT/bin/init.sh" --all "$F" --no-doctor $([ "$run" = 3 ] && echo --dry-run) > "$F-$run.log" 2>&1
    else pwsh -NoProfile -File "$ROOT/bin/init.ps1" -All "$(native "$F")" -NoDoctor $([ "$run" = 3 ] && echo -DryRun) > "$F-$run.log" 2>&1; fi || fail "init --all run $run failed ($twin, see $F-$run.log)"
    [ "$run" = 3 ] && continue
    grep -q '@\.ai-core/rules/rules\.md' "$F/app/AGENTS.md" && fail "init --all run $run: the repository imports the rules the folder's AGENTS.md loads already ($twin)"
    grep -q "rules/rules.md\`, the same as the project folder's" "$F/app/AGENTS.md" || fail "init --all run $run: the repository does not name the folder's rules ($twin)"
  done
  grep -aE '^  (created|refreshed|removed) ' "$F-3.log" && fail "init --all changes something on the run after ($twin, see $F-3.log)"
done
echo "  the repository names the folder's rules without the @ after the first run and after the folder held older ones, and the run after changes nothing, on both twins"
exit 0
