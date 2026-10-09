#!/usr/bin/env bash
# the .gitignore block; one section of the suite, run by tests/check.sh with the others
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

section "the .gitignore block: rewritten in place, a path the project ignores already is not written twice, on both twins"
for twin in sh ps1; do
  git init -q "$WORK/gi-$twin"; mkdir -p "$WORK/gi-$twin/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$WORK/gi-$twin/.ai-core/config.env"
  printf 'node_modules/\n.claude/\n.codex\n' > "$WORK/gi-$twin/.gitignore"
  for run in 1 2; do
    if [ "$twin" = sh ]; then bash "$ROOT/bin/init.sh" "$WORK/gi-$twin" --no-doctor > /dev/null 2>&1 || fail "init.sh gitignore run $run"
    else pwsh -NoProfile -File "$ROOT/bin/init.ps1" -TargetDir "$(native "$WORK/gi-$twin")" -NoDoctor > /dev/null 2>&1 || fail "init.ps1 gitignore run $run"; fi
  done
  GI="$WORK/gi-$twin/.gitignore"
  [ "$(grep -c '^# setup-ai-core start' "$GI")" = 1 ] || fail "init.$twin wrote the .gitignore block $(grep -c '^# setup-ai-core start' "$GI") times"
  [ "$(grep -c 'claude' "$GI")" = 1 ] && [ "$(grep -c 'codex' "$GI")" = 1 ] || fail "init.$twin wrote a path the project already ignores: $(tr '\n' '|' < "$GI")"
  grep -qxF '/AGENTS.md' "$GI" && grep -qxF 'node_modules/' "$GI" || fail "init.$twin lost a line of the project's .gitignore or the block"
  head -1 "$GI" | grep -q '^node_modules/$' || fail "init.$twin moved the project's own lines"
done
cmp -s <(tr -d '\r' < "$WORK/gi-sh/.gitignore") <(tr -d '\r' < "$WORK/gi-ps1/.gitignore") || fail "the .gitignore differs between the twins"
echo "  one block, no duplicate of .claude/ and .codex, the project's lines first, identical on both twins"

section "init commits the block on top of what the origin has: a clone the origin moved past catches up first, one with a commit of its own is left alone; both twins"
for twin in sh ps1; do
  O="$WORK/up-origin-$twin.git"; git init -q --bare -b master "$O"
  A="$WORK/up-first-$twin"; git init -q -b master "$A"; git -C "$A" -c user.name=check -c user.email=check@localhost commit -q --allow-empty -m 'Start #1'
  git -C "$A" remote add origin "$O"; git -C "$A" push -q origin master 2>/dev/null
  B="$WORK/up-behind-$twin"; C="$WORK/up-own-$twin"; git clone -q "$O" "$B" 2>/dev/null; git clone -q "$O" "$C" 2>/dev/null
  for d in "$A" "$B" "$C"; do mkdir -p "$d/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$d/.ai-core/config.env"; git -C "$d" config user.name check; git -C "$d" config user.email check@localhost; done
  printf 'mine\n' > "$C/mine.txt"; git -C "$C" add mine.txt; git -C "$C" commit -q -m 'A commit of its own #2'
  for d in "$A" "$B" "$C"; do
    if [ "$twin" = sh ]; then bash "$ROOT/bin/init.sh" "$d" --no-doctor > "$d.log" 2>&1; else pwsh -NoProfile -File "$ROOT/bin/init.ps1" -TargetDir "$(native "$d")" -NoDoctor > "$d.log" 2>&1; fi || fail "init.$twin in $(basename "$d") (see $d.log)"
    [ "$d" = "$A" ] && { [ "$(git -C "$A" rev-parse HEAD)" = "$(git -C "$O" rev-parse master)" ] || fail "init.$twin did not push the block from the first clone (see $A.log)"; }
  done
  grep -aq '^  .gitignore: pulled 1 commit(s) from origin/master first; the block was there already$' "$B.log" && [ "$(git -C "$B" rev-parse HEAD)" = "$(git -C "$O" rev-parse master)" ] || fail "init.$twin did not bring the clone behind level with its origin, or committed the block again (see $B.log)"
  grep -aq '^  .gitignore not written: this checkout is 1 commit(s) behind origin/master, with 1 commit(s) of its own; pull, then run this again$' "$C.log" && [ "$(git -C "$C" log -1 --format=%s)" = 'A commit of its own #2' ] && [ ! -e "$C/.gitignore" ] || fail "init.$twin wrote or committed the block on a clone with a commit of its own behind its origin (see $C.log)"
done
echo "  the first clone pushes the block, the clone behind pulls it and commits nothing, the one with a commit of its own is named and left alone, on both twins"

exit 0
