#!/usr/bin/env bash
# the .gitignore block; one section of the suite, run by tests/check.sh with the others
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

section "the .gitignore block: rewritten in place, a path the project ignores already is not written twice, on both twins"
for twin in sh ps1; do
  git init -q "$WORK/gi-$twin"; mkdir -p "$WORK/gi-$twin/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$WORK/gi-$twin/.ai-core/config.env"
  printf 'node_modules/\n.claude/\n.agents\n' > "$WORK/gi-$twin/.gitignore"
  for run in 1 2; do
    if [ "$twin" = sh ]; then bash "$ROOT/bin/init.sh" "$WORK/gi-$twin" --no-doctor > /dev/null 2>&1 || fail "init.sh gitignore run $run"
    else pwsh -NoProfile -File "$ROOT/bin/init.ps1" -TargetDir "$(native "$WORK/gi-$twin")" -NoDoctor > /dev/null 2>&1 || fail "init.ps1 gitignore run $run"; fi
  done
  GI="$WORK/gi-$twin/.gitignore"
  [ "$(grep -c '^# setup-ai-core start' "$GI")" = 1 ] || fail "init.$twin wrote the .gitignore block $(grep -c '^# setup-ai-core start' "$GI") times"
  [ "$(grep -c 'claude' "$GI")" = 1 ] && [ "$(grep -cxE '/?\.agents/?' "$GI")" = 1 ] || fail "init.$twin wrote a path the project already ignores: $(tr '\n' '|' < "$GI")"
  grep -qxF '/AGENTS.md' "$GI" && grep -qxF 'node_modules/' "$GI" || fail "init.$twin lost a line of the project's .gitignore or the block"
  head -1 "$GI" | grep -q '^node_modules/$' || fail "init.$twin moved the project's own lines"
done
cmp -s <(tr -d '\r' < "$WORK/gi-sh/.gitignore") <(tr -d '\r' < "$WORK/gi-ps1/.gitignore") || fail "the .gitignore differs between the twins"
echo "  one block, no duplicate of .claude/ and .agents, the project's lines first, identical on both twins"

section "the block is rewritten where it stands: the lines before and after it stay as they are, blank lines too, on both twins"
BLOCK="$(tr -d '\r' < "$ROOT/lib/gitignore-block")"
OLD="$(printf '%s\n' '# setup-ai-core start: an older list' /GEMINI.md /.ai-core/ /AGENTS.md '# setup-ai-core end')"
ENTRIES="$(grep -v '^#' <<< "$BLOCK")"
# <name> <the .gitignore before> <the .gitignore init writes>; an empty file stands for none
fixture() { printf '%s' "$2" > "$WORK/gip-$1.before"; printf '%s' "$3" > "$WORK/gip-$1.after"; }
fixture blank-before "node_modules/"$'\n\n'"$BLOCK"$'\n' "node_modules/"$'\n\n'"$BLOCK"$'\n'
fixture after "node_modules/"$'\n'"$BLOCK"$'\n\n'"# the cursor rules are ours"$'\n'"!/.cursorrules"$'\n' "node_modules/"$'\n'"$BLOCK"$'\n\n'"# the cursor rules are ours"$'\n'"!/.cursorrules"$'\n'
fixture old-block "dist/"$'\n\n'"$OLD"$'\n\n'"# local"$'\n'"*.log"$'\n' "dist/"$'\n\n'"$BLOCK"$'\n\n'"# local"$'\n'"*.log"$'\n'
fixture covered "dist/"$'\n'"$OLD"$'\n'"$ENTRIES"$'\n' "dist/"$'\n'"$ENTRIES"$'\n'
fixture none "dist/"$'\n\n' "dist/"$'\n\n'"$BLOCK"$'\n'
fixture no-newline "dist/" "dist/"$'\n'"$BLOCK"$'\n'
fixture two-blocks "a"$'\n'"$OLD"$'\n'"b"$'\n'"$OLD"$'\n'"c"$'\n' "a"$'\n'"$BLOCK"$'\n'"b"$'\n'"c"$'\n'
fixture empty "" "$BLOCK"$'\n'
fixture missing "" "$BLOCK"$'\n'
OPEN="dist/"$'\n'"# setup-ai-core start: x"$'\n'"/GEMINI.md"$'\n'"keepme"$'\n'
fixture open "$OPEN" "$OPEN"
printf '%s\n' dist/ "$OLD" '' '*.log' | awk '{ printf "%s\r\n", $0 }' > "$WORK/gip-crlf.before"
printf '%s\n' dist/ "$BLOCK" '' '*.log' | awk '{ printf "%s\r\n", $0 }' > "$WORK/gip-crlf.after"
for f in blank-before after old-block covered none no-newline two-blocks empty missing open crlf; do
  for twin in sh ps1; do
    R="$WORK/gip-$f-$twin"; git init -q "$R"; mkdir -p "$R/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$R/.ai-core/config.env"
    git -C "$R" config user.name check; git -C "$R" config user.email check@localhost
    if [ "$f" = missing ]; then git -C "$R" commit -q --allow-empty -m 'the project #1'
    else cp "$WORK/gip-$f.before" "$R/.gitignore"; git -C "$R" add .gitignore; git -C "$R" commit -q -m 'the project #1'; fi
    for run in 1 2; do
      if [ "$twin" = sh ]; then bash "$ROOT/bin/init.sh" "$R" --no-doctor > "$R-$run.log" 2>&1; else pwsh -NoProfile -File "$ROOT/bin/init.ps1" -TargetDir "$(native "$R")" -NoDoctor > "$R-$run.log" 2>&1; fi || fail "init.$twin on $f, run $run (see $R-$run.log)"
      [ "$run" = 1 ] && cp "$R/.gitignore" "$R.first"
    done
    cmp -s "$R/.gitignore" "$WORK/gip-$f.after" || fail "init.$twin on $f wrote: $(tr '\n' '|' < "$R/.gitignore") - expected: $(tr '\n' '|' < "$WORK/gip-$f.after")"
    cmp -s "$R.first" "$R/.gitignore" || fail "init.$twin on $f changed the .gitignore again on the second run"
    if cmp -s "$WORK/gip-$f.before" "$WORK/gip-$f.after"; then commits=1; else commits=2; fi
    [ "$(git -C "$R" rev-list --count HEAD)" = "$commits" ] || fail "init.$twin on $f made $(( $(git -C "$R" rev-list --count HEAD) - 1 )) commit(s), expected $(( commits - 1 ))"
    [ "$f" != open ] || grep -aqxF "  .gitignore not written: it has a '# setup-ai-core start' line and no '# setup-ai-core end' after it; end the block or delete its start line, then run this again" "$R-1.log" || fail "init.$twin did not name the block without its end line (see $R-1.log)"
  done
  cmp -s "$WORK/gip-$f-sh/.gitignore" "$WORK/gip-$f-ps1/.gitignore" || fail "the twins wrote different .gitignore files on $f"
done
echo "  a current block between blank lines and after-lines: nothing written, nothing committed; an old one: rewritten in its place, CRLF kept; one the project covers: gone where it stood; a second one: gone; none, no final newline, an empty file: appended; no file: written with LF; a block without its end: left alone and named; a second run changes nothing; the twins agree"

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

section "a block without its end line that the catch-up brings is left alone as well, on both twins"
for twin in sh ps1; do
  O="$WORK/open-origin-$twin.git"; git init -q --bare -b master "$O"
  A="$WORK/open-first-$twin"; git init -q -b master "$A"; git -C "$A" config user.name check; git -C "$A" config user.email check@localhost
  git -C "$A" commit -q --allow-empty -m 'Start #1'; git -C "$A" remote add origin "$O"; git -C "$A" push -q origin master 2>/dev/null
  B="$WORK/open-behind-$twin"; git clone -q "$O" "$B" 2>/dev/null; git -C "$B" config user.name check; git -C "$B" config user.email check@localhost
  mkdir -p "$B/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$B/.ai-core/config.env"
  printf '%s' "$OPEN" > "$A/.gitignore"; git -C "$A" add .gitignore; git -C "$A" commit -q -m 'An open block #2'; git -C "$A" push -q origin master 2>/dev/null
  if [ "$twin" = sh ]; then bash "$ROOT/bin/init.sh" "$B" --no-doctor > "$B.log" 2>&1; else pwsh -NoProfile -File "$ROOT/bin/init.ps1" -TargetDir "$(native "$B")" -NoDoctor > "$B.log" 2>&1; fi || fail "init.$twin in $(basename "$B") (see $B.log)"
  cmp -s "$B/.gitignore" <(printf '%s' "$OPEN") && [ "$(git -C "$B" rev-parse HEAD)" = "$(git -C "$O" rev-parse master)" ] || fail "init.$twin rewrote or committed the open block it pulled (see $B.log)"
  grep -aqxF "  .gitignore not written: pulled 1 commit(s) from origin/master first; it has a '# setup-ai-core start' line and no '# setup-ai-core end' after it; end the block or delete its start line, then run this again" "$B.log" || fail "init.$twin did not name the open block it pulled (see $B.log)"
done
echo "  the clone behind pulls the open block, keeps it as it came and names it, on both twins"

exit 0
