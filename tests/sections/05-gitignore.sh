#!/usr/bin/env bash
# the .gitignore block; one section of the suite, run by tests/check.sh with the others
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

section "the .gitignore block: rewritten in place, a path the project ignores already is not written twice"
git init -q "$WORK/gi"; mkdir -p "$WORK/gi/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$WORK/gi/.ai-core/config.env"
printf 'node_modules/\n.claude/\n.agents\n' > "$WORK/gi/.gitignore"
for run in 1 2; do
  bash "$ROOT/bin/init.sh" "$WORK/gi" --no-doctor > /dev/null 2>&1 || fail "init.sh gitignore run $run"
done
GI="$WORK/gi/.gitignore"
[ "$(grep -c '^# setup-ai-core start' "$GI")" = 1 ] || fail "init.sh wrote the .gitignore block $(grep -c '^# setup-ai-core start' "$GI") times"
[ "$(grep -c 'claude' "$GI")" = 1 ] && [ "$(grep -cxE '/?\.agents/?' "$GI")" = 1 ] || fail "init.sh wrote a path the project already ignores: $(tr '\n' '|' < "$GI")"
grep -qxF '/AGENTS.md' "$GI" && grep -qxF 'node_modules/' "$GI" || fail "init.sh lost a line of the project's .gitignore or the block"
head -1 "$GI" | grep -q '^node_modules/$' || fail "init.sh moved the project's own lines"
echo "  one block, no duplicate of .claude/ and .agents, the project's lines first"

section "the block is rewritten where it stands: the lines before and after it stay as they are, blank lines too"
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
  R="$WORK/gip-$f"; git init -q "$R"; mkdir -p "$R/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$R/.ai-core/config.env"
  git -C "$R" config user.name check; git -C "$R" config user.email check@localhost
  if [ "$f" = missing ]; then git -C "$R" commit -q --allow-empty -m 'the project #1'
  else cp "$WORK/gip-$f.before" "$R/.gitignore"; git -C "$R" add .gitignore; git -C "$R" commit -q -m 'the project #1'; fi
  for run in 1 2; do
    bash "$ROOT/bin/init.sh" "$R" --no-doctor > "$R-$run.log" 2>&1 || fail "init.sh on $f, run $run (see $R-$run.log)"
    [ "$run" = 1 ] && cp "$R/.gitignore" "$R.first"
  done
  cmp -s "$R/.gitignore" "$WORK/gip-$f.after" || fail "init.sh on $f wrote: $(tr '\n' '|' < "$R/.gitignore") - expected: $(tr '\n' '|' < "$WORK/gip-$f.after")"
  cmp -s "$R.first" "$R/.gitignore" || fail "init.sh on $f changed the .gitignore again on the second run"
  if cmp -s "$WORK/gip-$f.before" "$WORK/gip-$f.after"; then commits=1; else commits=2; fi
  [ "$(git -C "$R" rev-list --count HEAD)" = "$commits" ] || fail "init.sh on $f made $(( $(git -C "$R" rev-list --count HEAD) - 1 )) commit(s), expected $(( commits - 1 ))"
  [ "$f" != open ] || grep -aqxF "  .gitignore not written: it has a '# setup-ai-core start' line and no '# setup-ai-core end' after it; end the block or delete its start line, then run this again" "$R-1.log" || fail "init.sh did not name the block without its end line (see $R-1.log)"
done
echo "  a current block between blank lines and after-lines: nothing written, nothing committed; an old one: rewritten in its place, CRLF kept; one the project covers: gone where it stood; a second one: gone; none, no final newline, an empty file: appended; no file: written with LF; a block without its end: left alone and named; a second run changes nothing"

section "init commits the block on top of what the origin has: a clone the origin moved past catches up first, one with a commit of its own is left alone"
O="$WORK/up-origin.git"; git init -q --bare -b master "$O"
A="$WORK/up-first"; git init -q -b master "$A"; git -C "$A" -c user.name=check -c user.email=check@localhost commit -q --allow-empty -m 'Start #1'
git -C "$A" remote add origin "$O"; git -C "$A" push -q origin master 2>/dev/null
B="$WORK/up-behind"; C="$WORK/up-own"; git clone -q "$O" "$B" 2>/dev/null; git clone -q "$O" "$C" 2>/dev/null
for d in "$A" "$B" "$C"; do mkdir -p "$d/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$d/.ai-core/config.env"; git -C "$d" config user.name check; git -C "$d" config user.email check@localhost; done
printf 'mine\n' > "$C/mine.txt"; git -C "$C" add mine.txt; git -C "$C" commit -q -m 'A commit of its own #2'
for d in "$A" "$B" "$C"; do
  bash "$ROOT/bin/init.sh" "$d" --no-doctor > "$d.log" 2>&1 || fail "init.sh in $(basename "$d") (see $d.log)"
  [ "$d" = "$A" ] && { [ "$(git -C "$A" rev-parse HEAD)" = "$(git -C "$O" rev-parse master)" ] || fail "init.sh did not push the block from the first clone (see $A.log)"; }
done
grep -aq '^  .gitignore: pulled 1 commit(s) from origin/master first; the block was there already$' "$B.log" && [ "$(git -C "$B" rev-parse HEAD)" = "$(git -C "$O" rev-parse master)" ] || fail "init.sh did not bring the clone behind level with its origin, or committed the block again (see $B.log)"
grep -aq '^  .gitignore not written: this checkout is 1 commit(s) behind origin/master, with 1 commit(s) of its own; pull, then run this again$' "$C.log" && [ "$(git -C "$C" log -1 --format=%s)" = 'A commit of its own #2' ] && [ ! -e "$C/.gitignore" ] || fail "init.sh wrote or committed the block on a clone with a commit of its own behind its origin (see $C.log)"
echo "  the first clone pushes the block, the clone behind pulls it and commits nothing, the one with a commit of its own is named and left alone"

section "init commits the block only where the push takes it: off a branch, or over a .gitignore with changes of its own, nothing is written; a refused push takes the commit back"
O="$WORK/nopush-origin.git"; git init -q --bare -b master "$O"
A="$WORK/nopush-first"; git init -q -b master "$A"; printf 'node_modules/\n' > "$A/.gitignore"; git -C "$A" add .gitignore
git -C "$A" -c user.name=check -c user.email=check@localhost commit -q -m 'Start #1'; git -C "$A" remote add origin "$O"; git -C "$A" push -q origin master 2>/dev/null
D="$WORK/nopush-detached"; R="$WORK/nopush-refused"; E="$WORK/nopush-edited"
for d in "$D" "$R" "$E"; do git clone -q "$O" "$d" 2>/dev/null; done
git -C "$D" checkout -q --detach
printf 'mine.local\n' >> "$E/.gitignore"
printf '#!/bin/sh\necho "refused by the origin"\nexit 1\n' > "$O/hooks/pre-receive"; chmod +x "$O/hooks/pre-receive"
for d in "$D" "$R" "$E"; do
  mkdir -p "$d/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$d/.ai-core/config.env"; git -C "$d" config user.name check; git -C "$d" config user.email check@localhost
  bash "$ROOT/bin/init.sh" "$d" --no-doctor > "$d.log" 2>&1 || fail "init.sh in $(basename "$d") (see $d.log)"
  [ "$(git -C "$d" rev-parse HEAD)" = "$(git -C "$O" rev-parse master)" ] || fail "init.sh left a commit in $(basename "$d"): $(git -C "$d" log -1 --format=%s) (see $d.log)"
done
[ -z "$(git -C "$D" status --porcelain -- .gitignore)" ] && [ -z "$(git -C "$R" status --porcelain -- .gitignore)" ] || fail "init.sh left a changed .gitignore off a branch or after a refused push: $(git -C "$D" status --porcelain -- .gitignore) $(git -C "$R" status --porcelain -- .gitignore)"
cmp -s "$E/.gitignore" <(printf 'node_modules/\nmine.local\n') || fail "init.sh changed a .gitignore with changes of its own: $(tr '\n' '|' < "$E/.gitignore")"
grep -aqxF '  .gitignore not written: this checkout is on no branch; check out its branch, then run this again' "$D.log" || fail "init.sh did not name the checkout off a branch (see $D.log)"
grep -aqxF '  .gitignore not written: the push was refused or failed (see above), so init took its commit back' "$R.log" || fail "init.sh did not name the refused push (see $R.log)"
grep -aqxF '  .gitignore not written: it has changes of its own; commit them or take them back, then run this again' "$E.log" || fail "init.sh did not name the .gitignore with changes of its own (see $E.log)"
echo "  off a branch and over local changes nothing is written, the refused push has its commit taken back, each named"

section "a block without its end line that the catch-up brings is left alone as well"
O="$WORK/open-origin.git"; git init -q --bare -b master "$O"
A="$WORK/open-first"; git init -q -b master "$A"; git -C "$A" config user.name check; git -C "$A" config user.email check@localhost
git -C "$A" commit -q --allow-empty -m 'Start #1'; git -C "$A" remote add origin "$O"; git -C "$A" push -q origin master 2>/dev/null
B="$WORK/open-behind"; git clone -q "$O" "$B" 2>/dev/null; git -C "$B" config user.name check; git -C "$B" config user.email check@localhost
mkdir -p "$B/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$B/.ai-core/config.env"
printf '%s' "$OPEN" > "$A/.gitignore"; git -C "$A" add .gitignore; git -C "$A" commit -q -m 'An open block #2'; git -C "$A" push -q origin master 2>/dev/null
bash "$ROOT/bin/init.sh" "$B" --no-doctor > "$B.log" 2>&1 || fail "init.sh in $(basename "$B") (see $B.log)"
cmp -s "$B/.gitignore" <(printf '%s' "$OPEN") && [ "$(git -C "$B" rev-parse HEAD)" = "$(git -C "$O" rev-parse master)" ] || fail "init.sh rewrote or committed the open block it pulled: $(tr '\r\n' '^|' < "$B/.gitignore"), HEAD $(git -C "$B" log -1 --format=%s), $(tr '\n' '|' < "$B.log" | tail -c 400)"
grep -aqxF "  .gitignore not written: pulled 1 commit(s) from origin/master first; it has a '# setup-ai-core start' line and no '# setup-ai-core end' after it; end the block or delete its start line, then run this again" "$B.log" || fail "init.sh did not name the open block it pulled (see $B.log)"
echo "  the clone behind pulls the open block, keeps it as it came and names it"

exit 0
