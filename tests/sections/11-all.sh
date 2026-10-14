#!/usr/bin/env bash
# init --all; one section of the suite, run by tests/check.sh with the others
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

section "init --all: every git repository and start-issue worktree under a folder, a failing one reported"
mkdir -p "$WORK/all"
for r in one two; do git init -q "$WORK/all/$r"; mkdir -p "$WORK/all/$r/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$WORK/all/$r/.ai-core/config.env"; done
git init -q "$WORK/all/broken"; git -C "$WORK/all/broken" remote add origin https://github.com/example-org/broken-ai-core.git   # its origin is a harness repository: init refuses it
mkdir -p "$WORK/all/not-a-repo" "$WORK/all/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$WORK/all/.ai-core/config.env"
git init -q "$WORK/all/x-ai-core"   # a harness clone beside the repositories is none of them
# the worktrees ai-core start-issue puts under .worktrees/<repository>/: one of a repository, whose
# own name ends like a harness clone's, and one of the harness clone
for r in one x-ai-core; do git -C "$WORK/all/$r" commit -q --allow-empty -m start; done
git -C "$WORK/all/one" worktree add -q -b issue-1-to-ai-core "$WORK/all/.worktrees/one/issue-1-to-ai-core"
git -C "$WORK/all/x-ai-core" worktree add -q -b issue-2-rules "$WORK/all/.worktrees/x-ai-core/issue-2-rules"
# and the layout of a package that spans repositories, .worktrees/<issue>/<repository>/: one of the
# harness clone, and one of a repository under an issue whose name ends like a harness clone's
git -C "$WORK/all/two" commit -q --allow-empty -m start
git -C "$WORK/all/x-ai-core" worktree add -q -b issue-3-pkg "$WORK/all/.worktrees/issue-3-pkg/x-ai-core"
git -C "$WORK/all/two" worktree add -q -b issue-4-to-ai-core "$WORK/all/.worktrees/issue-4-to-ai-core/two"
mkdir -p "$WORK/all/.worktrees/issue-5-gone/three"; printf 'gitdir: /nonexistent/gone\n' > "$WORK/all/.worktrees/issue-5-gone/three/.git"   # a worktree whose checkout is gone is walked as before, and the run goes on
bash "$ROOT/bin/init.sh" --all "$WORK/all" --no-doctor --dry-run > "$WORK/all-dry.log" 2>&1 && fail "init.sh --all --dry-run exited 0 with a failing repository"
bash "$ROOT/bin/init.sh" --all "$WORK/all" --no-doctor > "$WORK/all.log" 2>&1 && fail "init.sh --all exited 0 with a failing repository"
grep -aq '5 repositories would be initialized; failed: broken' "$WORK/all-dry.log" || fail "init --all --dry-run summary wrong for sh: $(grep -a 'repositories' "$WORK/all-dry.log")"
[ "$(grep -ac '^init would change in ' "$WORK/all-dry.log")" = 6 ] || fail "init --all --dry-run did not report every repository, the worktree and the folder"
grep -aq '^  created .*AGENTS.md' "$WORK/all.log" || fail "init --all did not report what it created"
grep -aq '5 repositories were initialized; failed: broken' "$WORK/all.log" || fail "init --all summary wrong for sh: $(grep -a 'repositories' "$WORK/all.log")"
[ -f "$WORK/all/one/AGENTS.md" ] && [ -f "$WORK/all/two/AGENTS.md" ] || fail "init --all did not initialize the good repositories"
grep -aq '^### \.worktrees/one/issue-1-to-ai-core' "$WORK/all.log" && [ -f "$WORK/all/.worktrees/one/issue-1-to-ai-core/.ai-core/rules/rules.md" ] || fail "init --all did not initialize the worktree under .worktrees/"
[ -e "$WORK/all/.worktrees/x-ai-core/issue-2-rules/.ai-core" ] && fail "init --all initialized a worktree of a harness clone"
[ -e "$WORK/all/.worktrees/issue-3-pkg/x-ai-core/.ai-core" ] && fail "init --all initialized a worktree of a harness clone under .worktrees/<issue>/"
[ -f "$WORK/all/.worktrees/issue-4-to-ai-core/two/.ai-core/rules/rules.md" ] || fail "init --all skipped a repository's worktree under an issue named like a harness clone"
[ -e "$WORK/all/not-a-repo/.ai-core" ] && fail "init --all touched a folder that is not a repository"
[ -e "$WORK/all/x-ai-core/.ai-core" ] && fail "init --all initialized a harness clone"
grep -q 'x-ai-core' "$WORK/all/AGENTS.md" && fail "the project folder's AGENTS.md lists a harness clone"
grep -q 'written by init for a project folder' "$WORK/all/AGENTS.md" || fail "init --all did not write the project folder's AGENTS.md"
for r in one two broken; do grep -q "| \`$r\` | \`$r/AGENTS.md\` |" "$WORK/all/AGENTS.md" || fail "the project folder's AGENTS.md does not list $r"; done
grep -q 'not-a-repo' "$WORK/all/AGENTS.md" && fail "the project folder's AGENTS.md lists a folder that is not a repository"
[ -f "$WORK/all/.ai-core/rules/rules.md" ] || fail "init --all did not give the project folder the rules"
echo "  2 repositories and two worktrees under .worktrees/ initialized, 1 failed and named, the plain folder, the harness clone and its worktrees in both layouts untouched, the folder's AGENTS.md lists the three"

section "init --all gives the folder its rules before its repositories: a repository with the folder's rules names them without the @ in one run, the folder's rules older or missing"
F="$WORK/order"; mkdir -p "$F/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$F/.ai-core/config.env"
git init -q "$F/app"; mkdir -p "$F/app/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$F/app/.ai-core/config.env"
for run in 1 2 3; do
  [ "$run" = 2 ] && printf 'a rule of an older version\n' >> "$F/.ai-core/rules/rules.md"
  bash "$ROOT/bin/init.sh" --all "$F" --no-doctor $([ "$run" = 3 ] && echo --dry-run) > "$F-$run.log" 2>&1 || fail "init --all run $run failed (see $F-$run.log)"
  [ "$run" = 3 ] && continue
  grep -q '@\.ai-core/rules/rules\.md' "$F/app/AGENTS.md" && fail "init --all run $run: the repository imports the rules the folder's AGENTS.md loads already"
  grep -q "rules/rules.md\`, the same as the project folder's" "$F/app/AGENTS.md" || fail "init --all run $run: the repository does not name the folder's rules"
done
grep -aE '^  (created|refreshed|removed) ' "$F-3.log" && fail "init --all changes something on the run after (see $F-3.log)"
echo "  the repository names the folder's rules without the @ after the first run and after the folder held older ones, and the run after changes nothing"
section "init --all removes a worktree whose work landed a day ago or more before it inits the rest, and leaves a fresh one"
F="$WORK/sweep"; O="$WORK/sweep-origin.git"; A="$F/app"
mkdir -p "$F/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$F/.ai-core/config.env"
git init -q --bare -b master "$O"; git init -q -b master "$A"
mkdir -p "$A/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$A/.ai-core/config.env"; printf '/.ai-core/\n' >> "$A/.git/info/exclude"
echo one > "$A/README.md"; git -C "$A" add README.md; git -C "$A" commit -q -m 'Start #1'
git -C "$A" remote add origin "$O"; git -C "$A" push -q -u origin master 2>/dev/null; git -C "$A" remote set-head origin -a >/dev/null
long_ago="$(date -d '3 days ago' '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -v-3d '+%Y-%m-%dT%H:%M:%S')"
for w in issue-5-old issue-6-new; do
  T="$F/.worktrees/app/$w"; git -C "$A" worktree add -q -b "$w" "$T" origin/master 2>/dev/null
  echo "$w" >> "$T/README.md"; git -C "$T" add README.md
  if [ "$w" = issue-5-old ]; then GIT_AUTHOR_DATE="$long_ago" GIT_COMMITTER_DATE="$long_ago" git -C "$T" commit -q -m "Land $w #5"; else git -C "$T" commit -q -m "Land $w #6"; fi
  git -C "$T" push -q origin HEAD:master 2>/dev/null; git -C "$A" pull -q --ff-only origin master 2>/dev/null
done
bash "$ROOT/bin/init.sh" --all "$F" --no-doctor > "$F.log" 2>&1 || fail "init --all with landed worktrees failed (see $F.log)"
[ -d "$F/.worktrees/app/issue-5-old" ] && fail "init --all left the worktree whose work landed three days ago (see $F.log)"
git -C "$A" rev-parse -q --verify refs/heads/issue-5-old >/dev/null && fail "init --all left the branch of the landed worktree"
grep -aq 'issue-5-old: landed, removed' "$F.log" || fail "init --all does not name the worktree it removed (see $F.log)"
[ -d "$F/.worktrees/app/issue-6-new" ] || fail "init --all removed a worktree whose work landed today"
[ -f "$F/.worktrees/app/issue-6-new/.ai-core/rules/rules.md" ] || fail "init --all did not init the worktree that stays"
echo "  the worktree that landed three days ago is gone with its branch and named, the one of today stays and is inited"

section "init links the other checkouts of the folder beside a worktree, so .. finds them from it"
F="$WORK/near"; T="$F/.worktrees/app/issue-1-x"
mkdir -p "$F/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$F/.ai-core/config.env"
for r in app lib tools docs; do
  git init -q "$F/$r"; mkdir -p "$F/$r/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$F/$r/.ai-core/config.env"
  git -C "$F/$r" commit -q --allow-empty -m start; echo "$r" > "$F/$r/marker"
done
mkdir -p "$F/notes"                                  # a folder that is no checkout gets no link
git -C "$F/app" worktree add -q -b issue-1-x "$T"
echo mine > "$F/.worktrees/app/docs"                 # an entry that stands there already stays
init_one() { # [dry]: init on the worktree, its log in $F-$1.log
  bash "$ROOT/bin/init.sh" "$T" --no-doctor $([ "$1" = dry ] && echo --dry-run) > "$F-$1.log" 2>&1
}
init_one dry || fail "init --dry-run on a worktree failed (see $F-dry.log)"
[ -e "$F/.worktrees/app/lib" ] && fail "init --dry-run made a link"
grep -aq '^  links to the neighbour checkouts would be made in \.worktrees/app/: lib tools; ' "$F-dry.log" || fail "init --dry-run does not say which link it would make (see $F-dry.log)"
init_one real || fail "init on a worktree failed: $(tail -5 "$F-real.log")"
grep -aq '^  links to the neighbour checkouts made in \.worktrees/app/: lib tools; ' "$F-real.log" || fail "init does not say which link it made (see $F-real.log)"
[ "$(cat "$T/../lib/marker" 2>/dev/null)" = lib ] || fail "from the worktree, ../lib is not the checkout lib"
[ -L "$F/.worktrees/app/lib" ] || fail "beside the worktree, lib is a copy and not a link"
[ "$(cat "$F/.worktrees/app/docs")" = mine ] || fail "init replaced an entry that stood beside the worktree already"
[ -e "$F/.worktrees/app/app" ] && fail "init linked the worktree's own repository beside it"
[ -e "$F/.worktrees/app/notes" ] && fail "init linked a folder that is no checkout"
ln -s /nowhere/foreign "$F/.worktrees/app/foreign"
ln -s loop-b "$F/.worktrees/app/loop-a"; ln -s loop-a "$F/.worktrees/app/loop-b"   # a loop cannot be followed at all
ln -s ../../gone "$F/.worktrees/app/other"                                          # into the folder, under another name
rm -rf "$F/lib"                                      # the neighbour checkout goes, its link stays behind
init_one dry || fail "init --dry-run on a worktree beside a dangling link failed (see $F-dry.log)"
[ -L "$F/.worktrees/app/lib" ] || fail "init --dry-run removed the link to the checkout that is gone"
grep -aq '^  links to checkouts that are gone would be removed in \.worktrees/app/: lib[[:space:]]*$' "$F-dry.log" || fail "init --dry-run does not name the link it would remove (the link names $(readlink "$F/.worktrees/app/lib" 2>&1), see $F-dry.log)"
init_one real || fail "init on a worktree beside a dangling link failed: $(tail -5 "$F-real.log")"
[ -L "$F/.worktrees/app/lib" ] && fail "init left the link to the checkout that is gone"
grep -aq '^  links to checkouts that are gone removed in \.worktrees/app/: lib[[:space:]]*$' "$F-real.log" || fail "init does not name the link it removed (see $F-real.log)"
[ "$(cat "$F/.worktrees/app/tools/marker" 2>/dev/null)" = tools ] || fail "init removed the link to a checkout that stays"
{ [ -L "$F/.worktrees/app/foreign" ] && [ -L "$F/.worktrees/app/loop-a" ] && [ -L "$F/.worktrees/app/other" ]; } || fail "init removed a dangling link it did not make"
bash "$ROOT/bin/init.sh" --all "$F" --no-doctor > "$F-all.log" 2>&1 || fail "init --all over the folder failed: $(grep -a -E '^###|error|failed' "$F-all.log" | tail -8)"
grep -aq '^### \.worktrees/app/issue-1-x' "$F-all.log" || fail "init --all did not init the worktree (see $F-all.log)"
grep -aq '^### \.worktrees/app/tools' "$F-all.log" && fail "init --all took the link to a neighbour for a worktree (see $F-all.log)"
echo "  a worktree finds the neighbour checkout through .., the dry run only names the link, an entry there, the repository itself and a plain folder get none, a link whose checkout is gone goes and a link of anybody else stays, init --all inits no link"

section "a neighbour with an origin is linked as what it published, never as its working copy"
F="$WORK/published"; T="$F/.worktrees/app/issue-2-y"
mkdir -p "$F/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$F/.ai-core/config.env"
git init -q --bare -b master "$WORK/published-origin.git"
git clone -q "$WORK/published-origin.git" "$F/cat" 2>/dev/null
git -C "$F/cat" config user.email t@example.invalid; git -C "$F/cat" config user.name t
echo published > "$F/cat/marker"; git -C "$F/cat" add marker; git -C "$F/cat" commit -q -m one; git -C "$F/cat" push -q origin master
# no `remote set-head`: the clone was made empty, so only init can learn the origin's default branch
for r in app; do git init -q "$F/$r"; mkdir -p "$F/$r/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$F/$r/.ai-core/config.env"; git -C "$F/$r" commit -q --allow-empty -m start; done
git -C "$F/app" worktree add -q -b issue-2-y "$T"
# PLANTED: the neighbour's checkout stands on another branch with a change nobody published
git -C "$F/cat" switch -q -c somebodys-work; echo unpublished > "$F/cat/marker"
ln -s ../../cat "$F/.worktrees/app/cat"              # a link of the old shape, to the checkout itself
bash "$ROOT/bin/init.sh" "$T" --no-doctor > "$F-1.log" 2>&1 || fail "init on a worktree beside a published neighbour failed: $(tail -5 "$F-1.log")"
[ "$(cat "$T/../cat/marker" 2>/dev/null)" = published ] || fail "from the worktree, ../cat shows $(cat "$T/../cat/marker" 2>&1), not what cat published (see $F-1.log)"
[ "$(readlink "$F/.worktrees/app/cat")" = ../cat/origin-master ] || fail "the link of the old shape was not replaced: $(readlink "$F/.worktrees/app/cat")"
[ "$(cat "$F/cat/marker")" = unpublished ] || fail "init changed the neighbour's working copy"
# The origin moves on: a second init moves the copy; a copy with a change of its own is held and named
git clone -q "$WORK/published-origin.git" "$WORK/published-pusher" 2>/dev/null
git -C "$WORK/published-pusher" config user.email t@example.invalid; git -C "$WORK/published-pusher" config user.name t
echo newer > "$WORK/published-pusher/marker"; git -C "$WORK/published-pusher" commit -q -am two; git -C "$WORK/published-pusher" push -q origin master
bash "$ROOT/bin/init.sh" "$T" --no-doctor > "$F-2.log" 2>&1 || fail "the second init failed: $(tail -5 "$F-2.log")"
[ "$(cat "$T/../cat/marker" 2>/dev/null)" = newer ] || fail "the second init did not move the copy to the newer origin (see $F-2.log)"
echo edited > "$F/.worktrees/cat/origin-master/marker"
echo newest > "$WORK/published-pusher/marker"; git -C "$WORK/published-pusher" commit -q -am three; git -C "$WORK/published-pusher" push -q origin master
bash "$ROOT/bin/init.sh" "$T" --no-doctor > "$F-3.log" 2>&1 || fail "the third init failed: $(tail -5 "$F-3.log")"
[ "$(cat "$F/.worktrees/cat/origin-master/marker")" = edited ] || fail "init moved a copy that carried a change"
grep -aq 'were not moved to their origin.s newest commit: cat' "$F-3.log" || fail "init does not name the held copy (see $F-3.log)"
rm -f "$F/.worktrees/cat/origin-master/marker"; git -C "$F/.worktrees/cat/origin-master" checkout -q -- marker
(cd "$F/cat" && bash "$ROOT/bin/pre-push.sh" --install > "$F-shim.log" 2>&1) || true
[ -z "$(git -C "$F/.worktrees/cat/origin-master" status --porcelain)" ] || fail "pre-push --install wrote into the published copy: $(git -C "$F/.worktrees/cat/origin-master" status --porcelain | head -3)"
bash "$ROOT/bin/init.sh" --all "$F" --no-doctor > "$F-all.log" 2>&1 || fail "init --all over the folder failed: $(grep -a -E '^###|error|failed' "$F-all.log" | tail -8)"
grep -aq '^### \.worktrees/cat/origin-master' "$F-all.log" && fail "init --all took the published copy for a place of work (see $F-all.log)"
grep -aq '^### cat: worktrees whose work landed' "$F-all.log" && fail "init --all counts the published copy as a worktree of cat (see $F-all.log)"
# A commit in the copy, with a clean tree: the origin lacks it, so the copy is held and the commit stays
C="$F/.worktrees/cat/origin-master"
git -C "$C" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m "somebody's fix"
kept="$(git -C "$C" rev-parse HEAD)"
echo four > "$WORK/published-pusher/marker"; git -C "$WORK/published-pusher" commit -q -am four; git -C "$WORK/published-pusher" push -q origin master
bash "$ROOT/bin/init.sh" "$T" --no-doctor > "$F-4.log" 2>&1 || fail "init beside a copy with a commit of its own failed: $(tail -5 "$F-4.log")"
[ "$(git -C "$C" rev-parse HEAD)" = "$kept" ] || fail "init moved a copy off a commit its origin lacks, and left that commit behind"
grep -aq 'were not moved to their origin.s newest commit: cat' "$F-4.log" || fail "init does not name the copy held for its commit (see $F-4.log)"
git -C "$C" checkout -q --detach origin/master
# The origin renames its default branch: the link follows to the copy of the new one
git -C "$WORK/published-pusher" push -q origin master:main
git -C "$WORK/published-origin.git" symbolic-ref HEAD refs/heads/main
bash "$ROOT/bin/init.sh" "$T" --no-doctor > "$F-5.log" 2>&1 || fail "init after a renamed default branch failed: $(tail -5 "$F-5.log")"
[ "$(readlink "$F/.worktrees/app/cat")" = ../cat/origin-main ] || fail "the link stayed on the old default branch: $(readlink "$F/.worktrees/app/cat") (see $F-5.log)"
[ "$(cat "$T/../cat/marker" 2>/dev/null)" = four ] || fail "from the worktree, ../cat does not show the renamed branch's tree"
grep -aq 'copies of the old one stay.*\.worktrees/cat/origin-master' "$F-5.log" || fail "init does not name the copy of the old default branch it leaves (see $F-5.log)"
# The copy's folder removed by hand while git still registers it: no link to the working copy
rm -rf "$F/.worktrees/cat/origin-main"
bash "$ROOT/bin/init.sh" "$T" --no-doctor > "$F-5b.log" 2>&1 || fail "init beside a removed but registered copy failed: $(tail -5 "$F-5b.log")"
[ "$(readlink "$F/.worktrees/app/cat")" = ../cat/origin-main ] || fail "init replaced the link of a removed but registered copy with $(readlink "$F/.worktrees/app/cat")"
grep -aq 'cannot become one.*: cat' "$F-5b.log" || fail "init does not name the copy git still registers (see $F-5b.log)"
git -C "$F/cat" worktree prune
bash "$ROOT/bin/init.sh" "$T" --no-doctor > "$F-5c.log" 2>&1 || fail "init after the prune failed: $(tail -5 "$F-5c.log")"
[ "$(cat "$T/../cat/marker" 2>/dev/null)" = four ] || fail "after the prune, init did not add the copy again (see $F-5c.log)"
# A neighbour whose copy's place holds a folder that is no worktree, and one whose origin names no
# default branch: neither is linked to something that never moves, both are named
for r in dog eel; do
  git init -q --bare -b master "$WORK/published-$r.git"
  git clone -q "$WORK/published-$r.git" "$F/$r" 2>/dev/null
  git -C "$F/$r" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m one; git -C "$F/$r" push -q origin master
done
mkdir -p "$F/.worktrees/dog/origin-master"; echo somebodys > "$F/.worktrees/dog/origin-master/note"
git -C "$WORK/published-eel.git" symbolic-ref HEAD refs/heads/nothing
bash "$ROOT/bin/init.sh" "$T" --no-doctor > "$F-6.log" 2>&1 || fail "init beside a blocked and an unnamed origin failed: $(tail -5 "$F-6.log")"
[ -e "$F/.worktrees/app/dog" ] && fail "init linked dog although its copy's place holds a folder that is no worktree: $(readlink "$F/.worktrees/app/dog")"
[ "$(cat "$F/.worktrees/dog/origin-master/note")" = somebodys ] || fail "init changed the folder that stands where dog's copy would go"
grep -aq 'cannot become one.*: dog' "$F-6.log" || fail "init does not name the neighbour whose copy's place is taken (see $F-6.log)"
[ "$(readlink "$F/.worktrees/app/eel")" = ../../eel ] || fail "eel, whose origin names no default branch, is not linked as its checkout: $(readlink "$F/.worktrees/app/eel" 2>&1)"
grep -aq 'named no default branch.*: eel' "$F-6.log" || fail "init does not name the neighbour linked as its checkout (see $F-6.log)"
echo "  ../cat from the worktree shows what cat published while its checkout carries somebody's change, the old link is replaced, a newer origin moves the copy, a copy with a change or a commit of its own is held and named, a renamed default branch is followed, a taken place and an origin without a default branch are named, pre-push --install and init --all leave the copy alone"
exit 0
