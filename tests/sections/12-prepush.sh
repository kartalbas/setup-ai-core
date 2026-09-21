#!/usr/bin/env bash
# init arms the push gate and fills a worktree; one section of the suite, run by tests/check.sh with the others
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

section "init arms a clone that carries .githooks/pre-push: core.hooksPath set, reported, once; a dry run only says so; both twins"
for twin in sh ps1; do
  H="$WORK/hooks-$twin"; git init -q "$H"; mkdir -p "$H/.githooks" "$H/.ai-core"
  printf '#!/usr/bin/env bash\nexec ai-core pre-push "$@"\n' > "$H/.githooks/pre-push"
  printf 'GRAFT_EXECUTION_MODE="skip"\n' > "$H/.ai-core/config.env"
  if [ "$twin" = sh ]; then
    bash "$ROOT/bin/init.sh" "$H" --no-doctor --dry-run > "$WORK/hooks-$twin-dry.log" 2>&1 || fail "init.sh --dry-run on a repository with the shim (see $WORK/hooks-$twin-dry.log)"
    bash "$ROOT/bin/init.sh" "$H" --no-doctor > "$WORK/hooks-$twin-1.log" 2>&1 || fail "init.sh on a repository with the shim (see $WORK/hooks-$twin-1.log)"
    bash "$ROOT/bin/init.sh" "$H" --no-doctor > "$WORK/hooks-$twin-2.log" 2>&1 || fail "init.sh second run on a repository with the shim"
  else
    pwsh -NoProfile -File "$ROOT/bin/init.ps1" -TargetDir "$(native "$H")" -NoDoctor -DryRun > "$WORK/hooks-$twin-dry.log" 2>&1 || fail "init.ps1 -DryRun on a repository with the shim (see $WORK/hooks-$twin-dry.log)"
    pwsh -NoProfile -File "$ROOT/bin/init.ps1" -TargetDir "$(native "$H")" -NoDoctor > "$WORK/hooks-$twin-1.log" 2>&1 || fail "init.ps1 on a repository with the shim (see $WORK/hooks-$twin-1.log)"
    pwsh -NoProfile -File "$ROOT/bin/init.ps1" -TargetDir "$(native "$H")" -NoDoctor > "$WORK/hooks-$twin-2.log" 2>&1 || fail "init.ps1 second run on a repository with the shim"
  fi
  grep -aq '^  core.hooksPath would be set to .githooks: the push gate runs here$' "$WORK/hooks-$twin-dry.log" || fail "init.$twin --dry-run does not say core.hooksPath would be set"
  grep -aq '^  core.hooksPath set to .githooks: the push gate runs here$' "$WORK/hooks-$twin-1.log" || fail "init.$twin does not report core.hooksPath"
  [ "$(git -C "$H" config --get core.hooksPath)" = ".githooks" ] || fail "init.$twin did not set core.hooksPath"
  grep -aq 'core.hooksPath' "$WORK/hooks-$twin-2.log" && fail "init.$twin reports core.hooksPath again on the second run"
done
echo "  core.hooksPath set once and reported, the dry run announces it, on both twins"

section "init in a worktree that starts empty takes the checkout's .ai-core data first; a dry run only says so; both twins"
for twin in sh ps1; do
  H="$WORK/hooks-$twin"; git -C "$H" add -A 2>/dev/null; git -C "$H" commit -q -m 'the tree #1' >/dev/null 2>&1 || true
  mkdir -p "$H/.ai-core/rules"; printf '# mine\n' > "$H/.ai-core/rules/rules.local.md"
  W="$WORK/hooks-$twin-wt"; git -C "$H" worktree add -q --detach "$W" HEAD < /dev/null 2>/dev/null || fail "worktree add for $twin"
  [ ! -d "$W/.ai-core" ] || fail "the worktree of $twin starts with .ai-core (nothing should have written it)"
  if [ "$twin" = sh ]; then
    bash "$ROOT/bin/init.sh" "$W" --no-doctor --dry-run > "$WORK/wt-$twin-dry.log" 2>&1 || fail "init.sh --dry-run in a worktree (see $WORK/wt-$twin-dry.log)"
    [ ! -d "$W/.ai-core" ] || fail "init.sh --dry-run wrote .ai-core into the worktree"
    bash "$ROOT/bin/init.sh" "$W" --no-doctor > "$WORK/wt-$twin-1.log" 2>&1 || fail "init.sh in a worktree (see $WORK/wt-$twin-1.log)"
    bash "$ROOT/bin/init.sh" "$W" --no-doctor > "$WORK/wt-$twin-2.log" 2>&1 || fail "init.sh second run in a worktree"
  else
    pwsh -NoProfile -File "$ROOT/bin/init.ps1" -TargetDir "$(native "$W")" -NoDoctor -DryRun > "$WORK/wt-$twin-dry.log" 2>&1 || fail "init.ps1 -DryRun in a worktree (see $WORK/wt-$twin-dry.log)"
    [ ! -d "$W/.ai-core" ] || fail "init.ps1 -DryRun wrote .ai-core into the worktree"
    pwsh -NoProfile -File "$ROOT/bin/init.ps1" -TargetDir "$(native "$W")" -NoDoctor > "$WORK/wt-$twin-1.log" 2>&1 || fail "init.ps1 in a worktree (see $WORK/wt-$twin-1.log)"
    pwsh -NoProfile -File "$ROOT/bin/init.ps1" -TargetDir "$(native "$W")" -NoDoctor > "$WORK/wt-$twin-2.log" 2>&1 || fail "init.ps1 second run in a worktree"
  fi
  grep -aq "^  .ai-core would be taken from the checkout .*hooks-$twin: a worktree starts with the checkout's configuration, local rules and documents$" "$WORK/wt-$twin-dry.log" || fail "init.$twin --dry-run does not say the checkout's .ai-core would be taken"
  grep -aq "^  .ai-core taken from the checkout .*hooks-$twin: a worktree starts with the checkout's configuration, local rules and documents$" "$WORK/wt-$twin-1.log" || fail "init.$twin does not report the checkout's .ai-core"
  [ "$(cat "$W/.ai-core/rules/rules.local.md")" = '# mine' ] || fail "init.$twin did not take the checkout's local rules into the worktree"
  grep -q 'GRAFT_EXECUTION_MODE="skip"' "$W/.ai-core/config.env" || fail "init.$twin did not take the checkout's config.env into the worktree"
  grep -aq 'taken from the checkout' "$WORK/wt-$twin-2.log" && fail "init.$twin reports the checkout's .ai-core again on the second run"
  git -C "$H" worktree remove --force "$W" >/dev/null 2>&1
done
echo "  a worktree gets the checkout's config.env and rules.local.md before the harness is assembled, reported once, the dry run announces it and writes nothing, on both twins"
exit 0
