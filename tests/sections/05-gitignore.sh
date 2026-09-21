#!/usr/bin/env bash
# the .gitignore block; one section of the suite, run by tests/check.sh with the others
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

section "the .gitignore block: rewritten in place, a path the project ignores already is not written twice, on both twins"
for twin in sh ps1; do
  git init -q "$WORK/gi-$twin"; mkdir -p "$WORK/gi-$twin/.ai-core"; printf 'GRAFT_EXECUTION_MODE="skip"\n' > "$WORK/gi-$twin/.ai-core/config.env"
  printf 'node_modules/\n.claude/\ngraft\n' > "$WORK/gi-$twin/.gitignore"
  for run in 1 2; do
    if [ "$twin" = sh ]; then bash "$ROOT/bin/init.sh" "$WORK/gi-$twin" --no-doctor > /dev/null 2>&1 || fail "init.sh gitignore run $run"
    else pwsh -NoProfile -File "$ROOT/bin/init.ps1" -TargetDir "$(native "$WORK/gi-$twin")" -NoDoctor > /dev/null 2>&1 || fail "init.ps1 gitignore run $run"; fi
  done
  GI="$WORK/gi-$twin/.gitignore"
  [ "$(grep -c '^# setup-ai-core start' "$GI")" = 1 ] || fail "init.$twin wrote the .gitignore block $(grep -c '^# setup-ai-core start' "$GI") times"
  [ "$(grep -c 'claude' "$GI")" = 1 ] && [ "$(grep -c 'graft' "$GI")" = 1 ] || fail "init.$twin wrote a path the project already ignores: $(tr '\n' '|' < "$GI")"
  grep -qxF '/AGENTS.md' "$GI" && grep -qxF 'node_modules/' "$GI" || fail "init.$twin lost a line of the project's .gitignore or the block"
  head -1 "$GI" | grep -q '^node_modules/$' || fail "init.$twin moved the project's own lines"
done
cmp -s <(tr -d '\r' < "$WORK/gi-sh/.gitignore") <(tr -d '\r' < "$WORK/gi-ps1/.gitignore") || fail "the .gitignore differs between the twins"
echo "  one block, no duplicate of .claude/ and graft, the project's lines first, identical on both twins"
exit 0
