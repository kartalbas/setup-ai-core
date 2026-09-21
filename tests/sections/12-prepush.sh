#!/usr/bin/env bash
# init arms the push gate; one section of the suite, run by tests/check.sh with the others
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
exit 0
