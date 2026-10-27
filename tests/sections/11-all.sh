#!/usr/bin/env bash
# init --all; one section of the suite, run by tests/check.sh with the others
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

section "init --all: every git repository and start-issue worktree under a folder, a failing one reported"
mkdir -p "$WORK/all"
for r in one two; do git init -q "$WORK/all/$r"; mkdir -p "$WORK/all/$r/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$WORK/all/$r/.ai-core/config.env"; done
git init -q "$WORK/all/broken"; git -C "$WORK/all/broken" remote add origin https://github.com/example-org/broken-ai-core.git   # its origin is a harness repository: init refuses it
mkdir -p "$WORK/all/not-a-repo" "$WORK/all/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$WORK/all/.ai-core/config.env"
git init -q "$WORK/all/x-ai-core"   # a harness clone beside the repositories is none of them
carry_harness "$WORK/all/one" "$WORK/all/two" "$WORK/all/broken"
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
mkdir -p "$WORK/all/.worktrees/issue-5-gone/three"; printf 'gitdir: /nonexistent/gone\n' > "$WORK/all/.worktrees/issue-5-gone/three/.git"   # a worktree whose checkout is gone belongs to no harness: it is passed over, and the run goes on
bash "$ROOT/bin/init.sh" --all "$WORK/all" --no-doctor --dry-run > "$WORK/all-dry.log" 2>&1 && fail "init.sh --all --dry-run exited 0 with a failing repository"
bash "$ROOT/bin/init.sh" --all "$WORK/all" --no-doctor > "$WORK/all.log" 2>&1 && fail "init.sh --all exited 0 with a failing repository"
grep -aq '4 repositories would be initialized, 0 skipped without a harness; failed: broken' "$WORK/all-dry.log" || fail "init --all --dry-run summary wrong for sh: $(grep -a 'repositories' "$WORK/all-dry.log")"
[ "$(grep -ac '^init would change in ' "$WORK/all-dry.log")" = 5 ] || fail "init --all --dry-run did not report every repository, the worktree and the folder"
grep -aq '^  created .*AGENTS.md' "$WORK/all.log" || fail "init --all did not report what it created"
grep -aq '4 repositories were initialized, 0 skipped without a harness; failed: broken' "$WORK/all.log" || fail "init --all summary wrong for sh: $(grep -a 'repositories' "$WORK/all.log")"
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
git init -q "$F/app"; mkdir -p "$F/app/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$F/app/.ai-core/config.env"; carry_harness "$F/app"
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
mkdir -p "$A/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$A/.ai-core/config.env"; printf '/.ai-core/\n' >> "$A/.git/info/exclude"; carry_harness "$A"
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
  git -C "$F/$r" commit -q --allow-empty -m start; echo "$r" > "$F/$r/marker"; carry_harness "$F/$r"
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
carry_harness "$F/app"
bash "$ROOT/bin/init.sh" --all "$F" --no-doctor > "$F-all.log" 2>&1 || fail "init --all over the folder failed: $(grep -a -E '^###|error|failed' "$F-all.log" | tail -8)"
grep -aq '^### \.worktrees/app/issue-1-x' "$F-all.log" || fail "init --all did not init the worktree (see $F-all.log)"
grep -aq '^### \.worktrees/app/tools' "$F-all.log" && fail "init --all took the link to a neighbour for a worktree (see $F-all.log)"
echo "  a worktree finds the neighbour checkout through .., the dry run only names the link, an entry there, the repository itself and a plain folder get none, a link whose checkout is gone goes and a link of anybody else stays, init --all inits no link"

section "a neighbour with an origin is linked as what it published, never as its working copy"
F="$WORK/published"; T="$F/.worktrees/app/issue-2-y"
mkdir -p "$F/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$F/.ai-core/config.env"
git init -q --bare -b master "$WORK/published-origin.git"
git clone -q "$WORK/published-origin.git" "$F/cat" 2>/dev/null; carry_harness "$F/cat"
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
[ "$(readlink "$F/.worktrees/app/cat")" = ../../.ai-core/neighbours/cat/origin-master ] || fail "the link of the old shape was not replaced: $(readlink "$F/.worktrees/app/cat")"
[ "$(cat "$F/cat/marker")" = unpublished ] || fail "init changed the neighbour's working copy"
# The origin moves on: a second init moves the copy; a copy with a change of its own is held and named
git clone -q "$WORK/published-origin.git" "$WORK/published-pusher" 2>/dev/null
git -C "$WORK/published-pusher" config user.email t@example.invalid; git -C "$WORK/published-pusher" config user.name t
echo newer > "$WORK/published-pusher/marker"; git -C "$WORK/published-pusher" commit -q -am two; git -C "$WORK/published-pusher" push -q origin master
bash "$ROOT/bin/init.sh" "$T" --no-doctor > "$F-2.log" 2>&1 || fail "the second init failed: $(tail -5 "$F-2.log")"
[ "$(cat "$T/../cat/marker" 2>/dev/null)" = newer ] || fail "the second init did not move the copy to the newer origin (see $F-2.log)"
echo edited > "$F/.ai-core/neighbours/cat/origin-master/marker"
echo newest > "$WORK/published-pusher/marker"; git -C "$WORK/published-pusher" commit -q -am three; git -C "$WORK/published-pusher" push -q origin master
bash "$ROOT/bin/init.sh" "$T" --no-doctor > "$F-3.log" 2>&1 || fail "the third init failed: $(tail -5 "$F-3.log")"
[ "$(cat "$F/.ai-core/neighbours/cat/origin-master/marker")" = edited ] || fail "init moved a copy that carried a change"
grep -aq 'were not moved to their origin.s newest commit: cat' "$F-3.log" || fail "init does not name the held copy (see $F-3.log)"
rm -f "$F/.ai-core/neighbours/cat/origin-master/marker"; git -C "$F/.ai-core/neighbours/cat/origin-master" checkout -q -- marker
(cd "$F/cat" && bash "$ROOT/bin/pre-push.sh" --install > "$F-shim.log" 2>&1) || true
[ -z "$(git -C "$F/.ai-core/neighbours/cat/origin-master" status --porcelain)" ] || fail "pre-push --install wrote into the published copy: $(git -C "$F/.ai-core/neighbours/cat/origin-master" status --porcelain | head -3)"
carry_harness "$F/app"
bash "$ROOT/bin/init.sh" --all "$F" --no-doctor > "$F-all.log" 2>&1 || fail "init --all over the folder failed: $(grep -a -E '^###|error|failed' "$F-all.log" | tail -8)"
grep -aq '^### \.ai-core' "$F-all.log" && fail "init --all took the published copy for a place of work (see $F-all.log)"
grep -aq '^### cat: worktrees whose work landed' "$F-all.log" && fail "init --all counts the published copy as a worktree of cat (see $F-all.log)"
[ "$(cat "$T/../cat/marker" 2>/dev/null)" = newest ] || fail "init --all over the folder took the published copy away (see $F-all.log)"
# A commit in the copy, with a clean tree: the origin lacks it, so the copy is held and the commit stays
C="$F/.ai-core/neighbours/cat/origin-master"
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
[ "$(readlink "$F/.worktrees/app/cat")" = ../../.ai-core/neighbours/cat/origin-main ] || fail "the link stayed on the old default branch: $(readlink "$F/.worktrees/app/cat") (see $F-5.log)"
[ "$(cat "$T/../cat/marker" 2>/dev/null)" = four ] || fail "from the worktree, ../cat does not show the renamed branch's tree"
grep -aq 'copies of the old one stay.*\.ai-core/neighbours/cat/origin-master' "$F-5.log" || fail "init does not name the copy of the old default branch it leaves (see $F-5.log)"
# The copy's folder removed by hand while git still registers it: no link to the working copy
rm -rf "$F/.ai-core/neighbours/cat/origin-main"
bash "$ROOT/bin/init.sh" "$T" --no-doctor > "$F-5b.log" 2>&1 || fail "init beside a removed but registered copy failed: $(tail -5 "$F-5b.log")"
[ "$(readlink "$F/.worktrees/app/cat")" = ../../.ai-core/neighbours/cat/origin-main ] || fail "init replaced the link of a removed but registered copy with $(readlink "$F/.worktrees/app/cat")"
grep -aq 'cannot become one.*: cat' "$F-5b.log" || fail "init does not name the copy git still registers (see $F-5b.log)"
git -C "$F/cat" worktree prune
bash "$ROOT/bin/init.sh" "$T" --no-doctor > "$F-5c.log" 2>&1 || fail "init after the prune failed: $(tail -5 "$F-5c.log")"
[ "$(cat "$T/../cat/marker" 2>/dev/null)" = four ] || fail "after the prune, init did not add the copy again (see $F-5c.log)"
# A neighbour whose copy's place holds a folder that is no worktree, and one whose origin names no
# default branch: neither is linked to something that never moves, both are named
for r in dog eel; do
  git init -q --bare -b master "$WORK/published-$r.git"
  git clone -q "$WORK/published-$r.git" "$F/$r" 2>/dev/null; carry_harness "$F/$r"
  git -C "$F/$r" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m one; git -C "$F/$r" push -q origin master
done
mkdir -p "$F/.ai-core/neighbours/dog/origin-master"; echo somebodys > "$F/.ai-core/neighbours/dog/origin-master/note"
git -C "$WORK/published-eel.git" symbolic-ref HEAD refs/heads/nothing
bash "$ROOT/bin/init.sh" "$T" --no-doctor > "$F-6.log" 2>&1 || fail "init beside a blocked and an unnamed origin failed: $(tail -5 "$F-6.log")"
[ -e "$F/.worktrees/app/dog" ] && fail "init linked dog although its copy's place holds a folder that is no worktree: $(readlink "$F/.worktrees/app/dog")"
[ "$(cat "$F/.ai-core/neighbours/dog/origin-master/note")" = somebodys ] || fail "init changed the folder that stands where dog's copy would go"
grep -aq 'cannot become one.*: dog' "$F-6.log" || fail "init does not name the neighbour whose copy's place is taken (see $F-6.log)"
[ "$(readlink "$F/.worktrees/app/eel")" = ../../eel ] || fail "eel, whose origin names no default branch, is not linked as its checkout: $(readlink "$F/.worktrees/app/eel" 2>&1)"
grep -aq 'named no default branch.*: eel' "$F-6.log" || fail "init does not name the neighbour linked as its checkout (see $F-6.log)"
# A dry run asks no origin, so it names no origin as lacking a default branch; a default branch
# with a slash makes a copy one folder deeper, which is still no worktree of anybody's work
git init -q --bare -b release/1 "$WORK/published-fox.git"
git clone -q "$WORK/published-fox.git" "$F/fox" 2>/dev/null; carry_harness "$F/fox"
git -C "$F/fox" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m one; git -C "$F/fox" push -q origin HEAD:release/1
git -C "$F/fox" remote set-head origin -d 2>/dev/null || true
bash "$ROOT/bin/init.sh" "$T" --no-doctor --dry-run > "$F-7.log" 2>&1 || fail "the dry run beside fox failed: $(tail -5 "$F-7.log")"
grep -aq 'named no default branch.*fox' "$F-7.log" && fail "the dry run names fox's origin as lacking a default branch, without having asked it (see $F-7.log)"
bash "$ROOT/bin/init.sh" "$T" --no-doctor > "$F-8.log" 2>&1 || fail "init beside fox failed: $(tail -5 "$F-8.log")"
[ "$(readlink "$F/.worktrees/app/fox")" = ../../.ai-core/neighbours/fox/origin-release/1 ] || fail "fox is not linked to the copy of release/1: $(readlink "$F/.worktrees/app/fox" 2>&1) (see $F-8.log)"
bash "$ROOT/bin/init.sh" --all "$F" --no-doctor > "$F-all2.log" 2>&1 || fail "the second init --all failed: $(grep -a -E '^###|error|failed' "$F-all2.log" | tail -8)"
grep -aq '^### fox: worktrees whose work landed' "$F-all2.log" && fail "init --all counts fox's copy of release/1 as a worktree (see $F-all2.log)"
[ -z "$(find "$F/.worktrees" -name 'origin-*')" ] || fail "a published copy stands in .worktrees/, where a project's tool counts it as a place of work: $(find "$F/.worktrees" -name 'origin-*')"
echo "  ../cat from the worktree shows what cat published while its checkout carries somebody's change, the old link is replaced, a newer origin moves the copy, a copy with a change or a commit of its own is held and named, a renamed default branch is followed, a taken place and an origin without a default branch are named, pre-push --install and init --all leave the copy alone"

section "a published copy left in .worktrees/ moves out with what it holds, and every link follows"
F="$WORK/moved"; T="$F/.worktrees/app/issue-3-z"
mkdir -p "$F/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$F/.ai-core/config.env"
git init -q --bare -b release/1 "$WORK/moved-origin.git"
git clone -q "$WORK/moved-origin.git" "$F/cat" 2>/dev/null; carry_harness "$F/cat"
git -C "$F/cat" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m one; git -C "$F/cat" push -q origin HEAD:release/1
for r in app dog; do git init -q "$F/$r"; mkdir -p "$F/$r/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$F/$r/.ai-core/config.env"; git -C "$F/$r" commit -q --allow-empty -m start; done
git -C "$F/app" worktree add -q -b issue-3-z "$T"
git -C "$F/dog" worktree add -q -b issue-4-w "$F/.worktrees/dog/issue-4-w"
# PLANTED: the copy where an earlier init put it, in .worktrees/, with a change in it, and linked
# from two worktrees' folders
git -C "$F/cat" worktree add -q --detach "$F/.worktrees/cat/origin-release/1" origin/release/1
echo somebodys > "$F/.worktrees/cat/origin-release/1/note"
ln -s ../cat/origin-release/1 "$F/.worktrees/app/cat"; ln -s ../cat/origin-release/1 "$F/.worktrees/dog/cat"
bash "$ROOT/bin/init.sh" "$T" --no-doctor --dry-run > "$F-1.log" 2>&1 || fail "the dry run beside a copy in .worktrees/ failed: $(tail -5 "$F-1.log")"
[ -f "$F/.worktrees/cat/origin-release/1/note" ] || fail "the dry run moved the copy"
grep -aq 'would move out of \.worktrees/.*: cat' "$F-1.log" || fail "the dry run does not name the copy it would move (see $F-1.log)"
bash "$ROOT/bin/init.sh" "$T" --no-doctor > "$F-2.log" 2>&1 || fail "init beside a copy in .worktrees/ failed: $(tail -5 "$F-2.log")"
[ ! -e "$F/.worktrees/cat" ] || fail "the copy or its folder still stands in .worktrees/: $(find "$F/.worktrees/cat" | head -3)"
[ "$(cat "$F/.ai-core/neighbours/cat/origin-release/1/note" 2>/dev/null)" = somebodys ] || fail "the move lost what the copy held (see $F-2.log)"
for c in app dog; do
  [ "$(readlink "$F/.worktrees/$c/cat")" = ../../.ai-core/neighbours/cat/origin-release/1 ] || fail "the link in .worktrees/$c/ did not follow the copy: $(readlink "$F/.worktrees/$c/cat")"
done
[ "$(cat "$T/../cat/note" 2>/dev/null)" = somebodys ] || fail "from the worktree, ../cat no longer reaches the copy"
git -C "$F/cat" worktree list | grep -q '/\.ai-core/neighbours/cat/origin-release/1 ' || fail "git does not register the copy at its new place: $(git -C "$F/cat" worktree list)"
grep -aq 'moved out of \.worktrees/.*: cat' "$F-2.log" || fail "init does not name the copy it moved (see $F-2.log)"
grep -aq 'were not moved to their origin.s newest commit: cat' "$F-2.log" || fail "the moved copy with a change of its own is not held (see $F-2.log)"
echo "  a copy in .worktrees/ moves to .ai-core/neighbours/ with what it holds, a slash branch's folders go with it, the links of every worktree follow, the dry run only names it"

section "init --all refreshes only what carries the harness: a fresh clone is named and left as it was, ai-core init <path> equips it"
make_gh_fake
SHIM="$WORK/skip-shim"; mkdir -p "$SHIM" "$WORK/skip-home"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/gh-calls.log"\nexec "%s/ghbin/gh" "$@"\n' "$WORK" "$WORK" > "$SHIM/gh"; chmod +x "$SHIM/gh"
# skip_copy <dir> [planted-all|planted-map|planted-neighbours|planted-kept|planted-own-stamp]: a copy of the harness whose
# finish-issue only records where the sweep ran; a planted copy walks every repository, lists every repository in the
# folder's map, links every checkout beside a worktree, keeps a link to a clone without the harness, or asks a worktree
# for a STAMP of its own
skip_copy() {
  mkdir -p "$1"; tar -C "$ROOT" --exclude=node_modules --exclude=.git -cf - bin lib templates rules skills VERSION | tar -C "$1" -xf -
  printf '#!/usr/bin/env bash\npwd >> "%s/sweeps.log"\n' "$WORK" > "$1/bin/finish-issue.sh"
  case "${2:-}" in
    planted-all) sed 's/^carries_harness() .*$/carries_harness() { true; }/' "$1/lib/common.sh" > "$1/planted"; mv "$1/planted" "$1/lib/common.sh" ;;
    planted-map) sed '/^      carries_harness "\$d" || continue$/d' "$1/bin/init.sh" > "$1/planted"; mv "$1/planted" "$1/bin/init.sh" ;;
    planted-neighbours) sed 's/ && carries_harness "\$neighbour"//; s/if ! carries_harness "\$neighbour"; then/if false; then/' "$1/bin/init.sh" > "$1/planted"; mv "$1/planted" "$1/bin/init.sh" ;;
    planted-kept) sed '/NEIGHBOURS_UNHARNESSED="\$NEIGHBOURS_UNHARNESSED \$name"; fi$/d' "$1/bin/init.sh" > "$1/planted"; mv "$1/planted" "$1/bin/init.sh" ;;
    planted-own-stamp) sed 's/! carries_harness "\$checkout"/! carries_harness "$repo"/' "$1/bin/init.sh" > "$1/planted"; mv "$1/planted" "$1/bin/init.sh" ;;
  esac
}
skip_copy "$WORK/skip-copy-real"
skip_copy "$WORK/skip-copy-all" planted-all; grep -q '^carries_harness() { true; }$' "$WORK/skip-copy-all/lib/common.sh" || fail "the planted copy that walks every repository was not made"
skip_copy "$WORK/skip-copy-map" planted-map; [ "$(grep -c 'carries_harness' "$WORK/skip-copy-map/bin/init.sh")" = "$(( $(grep -c 'carries_harness' "$WORK/skip-copy-real/bin/init.sh") - 1 ))" ] || fail "the planted copy that lists every repository was not made"
skip_copy "$WORK/skip-copy-neighbours" planted-neighbours; [ "$(grep -c 'carries_harness "\$neighbour"' "$WORK/skip-copy-real/bin/init.sh")" = 4 ] && ! grep -q 'carries_harness "\$neighbour"' "$WORK/skip-copy-neighbours/bin/init.sh" || fail "the planted copy that links every checkout was not made"
skip_copy "$WORK/skip-copy-kept" planted-kept; [ "$(grep -c 'NEIGHBOURS_UNHARNESSED=' "$WORK/skip-copy-kept/bin/init.sh")" = "$(( $(grep -c 'NEIGHBOURS_UNHARNESSED=' "$WORK/skip-copy-real/bin/init.sh") - 1 ))" ] || fail "the planted copy that keeps a link to a clone was not made"
skip_copy "$WORK/skip-copy-own-stamp" planted-own-stamp; grep -q '! carries_harness "\$repo"; then$' "$WORK/skip-copy-own-stamp/bin/init.sh" || fail "the planted copy that asks a worktree for its own STAMP was not made"
# every file of a clone that init could write, with the tree: its checkout, hooks, exclude file and configuration
skip_snapshot() { (cd "$1" && find . -path ./.git/objects -prune -o -path ./.git/index -prune -o -print | LC_ALL=C sort; find . -path ./.git/objects -prune -o -path ./.git/index -prune -o -type f -print0 | LC_ALL=C sort -z | xargs -0 cksum); }
# skip_folder <folder> <name>...: a project folder with the named checkouts: mine carries the harness (and a worktree
# of its own, whose own STAMP is missing), clone is fresh, with a worktree of its own and an origin on this disk under
# a path that names the forge, so a walk over it fetches without the network
skip_folder() {
  local f="$1" name; shift
  mkdir -p "$f/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$f/.ai-core/config.env"
  for name in "$@"; do
    git init -q -b master "$f/$name"; git -C "$f/$name" commit -q --allow-empty -m start
    if [ "$name" = clone ]; then
      git init -q --bare -b master "$f-origin/github.com/example-org/clone.git"; git -C "$f/clone" remote add origin "$f-origin/github.com/example-org/clone.git"
      git -C "$f/clone" push -q -u origin master 2>/dev/null; git -C "$f/clone" remote set-head origin -a >/dev/null
    fi
    [ "$name" != mine ] || carry_harness "$f/mine"
    git -C "$f/$name" worktree add -q -b "issue-9-$name" "$f/.worktrees/$name/issue-9-$name"
  done
}
skip_run() { # skip_run <copy> <folder> [--dry-run]: the log is <folder>.log; the exit status is init's
  : > "$WORK/gh-calls.log"; : > "$WORK/sweeps.log"
  HOME="$WORK/skip-home" PATH="$SHIM:$PATH_SH" bash "$1/bin/init.sh" --all "$2" --no-doctor ${3:+"$3"} > "$2.log" 2>&1
}
# skip_problems <copy> <folder>: what init --all got wrong with a harnessed checkout beside a fresh clone, one line each
skip_problems() {
  local copy="$1" f="$2" before rc=0
  skip_folder "$f" mine clone
  before="$(skip_snapshot "$f/clone")"
  skip_run "$copy" "$f" || rc=$?
  [ "$rc" = 0 ] || echo "exit $rc"
  grep -aqxF "skipped: clone carries no harness; ai-core init $f/clone installs it" "$f.log" || echo "no skip line"
  grep -aq ', 1 skipped without a harness' "$f.log" || echo "the summary does not count the skipped clone"
  [ "$(skip_snapshot "$f/clone")" = "$before" ] || echo "the clone changed"
  [ ! -e "$f/.worktrees/clone/issue-9-clone/.ai-core" ] || echo "the worktree of the clone was equipped"
  [ ! -e "$f/.worktrees/mine/clone" ] && [ ! -L "$f/.worktrees/mine/clone" ] || echo "the worktree of the harnessed checkout links the clone"
  ! grep -aq 'clone-ai-core' "$WORK/gh-calls.log" || echo "a forge call named the clone"
  ! grep -aqxF "$f/clone" "$WORK/sweeps.log" || echo "the worktrees of the clone were swept"
  grep -aqxF "$f/mine" "$WORK/sweeps.log" || echo "the worktrees of the harnessed checkout were not swept"
  [ -f "$f/mine/.ai-core/rules/rules.md" ] || echo "the harnessed checkout was not refreshed"
  [ -f "$f/.worktrees/mine/issue-9-mine/.ai-core/STAMP" ] || echo "the worktree of a harnessed checkout, without a STAMP of its own, was not initialized"
  grep -q '^| `mine` |' "$f/AGENTS.md" || echo "the map does not list the harnessed checkout"
  ! grep -q '^| `clone` |' "$f/AGENTS.md" || echo "the map lists the clone"
}
problems="$(skip_problems "$WORK/skip-copy-real" "$WORK/skip-real")"
[ -z "$problems" ] || fail "init --all beside a fresh clone: $(tr '\n' ';' <<< "$problems") (see $WORK/skip-real.log)"
# planted: a copy that walks every repository goes red on the clone, its forge call, its sweep and the map
problems="$(skip_problems "$WORK/skip-copy-all" "$WORK/skip-planted-all")"
for expected in "the clone changed" "a forge call named the clone" "the worktrees of the clone were swept" "the map lists the clone" "the worktree of the clone was equipped"; do
  grep -qxF "$expected" <<< "$problems" || fail "planted: the copy that walks every repository was not caught by: $expected (it was caught by: $(tr '\n' ';' <<< "$problems"))"
done
# planted: a copy that lists every repository in the folder's map goes red on the map alone
problems="$(skip_problems "$WORK/skip-copy-map" "$WORK/skip-planted-map")"
[ "$problems" = "the map lists the clone" ] || fail "planted: the copy that lists every repository was not caught by the map alone: $(tr '\n' ';' <<< "$problems")"
# planted: a copy whose neighbour step links every checkout fetches into the clone and links it, and nothing else
problems="$(skip_problems "$WORK/skip-copy-neighbours" "$WORK/skip-planted-neighbours")"
[ "$problems" = "the clone changed"$'\n'"the worktree of the harnessed checkout links the clone" ] || fail "planted: the copy that links every checkout was not caught by the clone and the link alone: $(tr '\n' ';' <<< "$problems")"
# planted: a copy that asks a worktree for a STAMP of its own leaves the worktree of the harnessed checkout bare
problems="$(skip_problems "$WORK/skip-copy-own-stamp" "$WORK/skip-planted-own-stamp")"
[ "$problems" = "the worktree of a harnessed checkout, without a STAMP of its own, was not initialized" ] || fail "planted: the copy that asks a worktree for its own STAMP was not caught: $(tr '\n' ';' <<< "$problems")"
# a link an earlier version made beside a worktree of the harnessed checkout to the clone goes at the next init, which
# names it, and the clone stays as it was: the push gate would fetch into the clone through that link. Planted: a copy
# that links every checkout makes the link and fetches into the clone; a copy that keeps the link leaves it standing
L="$WORK/skip-link"; skip_folder "$L" mine clone
link_init() { HOME="$WORK/skip-home" PATH="$SHIM:$PATH_SH" bash "$1/bin/init.sh" "$L/.worktrees/mine/issue-9-mine" --no-doctor > "$L-$2.log" 2>&1 || fail "init of the worktree with the $2 copy failed (see $L-$2.log)"; }
before="$(skip_snapshot "$L/clone")"; link_init "$WORK/skip-copy-neighbours" planted
[ "$(readlink "$L/.worktrees/mine/clone")" = ../../.ai-core/neighbours/clone/origin-master ] && [ "$(skip_snapshot "$L/clone")" != "$before" ] || fail "planted: the copy that links every checkout did not link the clone or fetch into it (see $L-planted.log)"
before="$(skip_snapshot "$L/clone")"; link_init "$WORK/skip-copy-kept" kept
[ -L "$L/.worktrees/mine/clone" ] || fail "planted: the copy that keeps the link to the clone removed it (see $L-kept.log)"
link_init "$WORK/skip-copy-real" real
[ ! -e "$L/.worktrees/mine/clone" ] && [ ! -L "$L/.worktrees/mine/clone" ] || fail "init kept the link to a checkout without the harness (see $L-real.log)"
grep -aq '^  links to checkouts that carry no harness removed in \.worktrees/mine/, .*: clone[[:space:]]*$' "$L-real.log" || fail "init does not name the link it removed to the clone (see $L-real.log)"
[ "$(skip_snapshot "$L/clone")" = "$before" ] || fail "init of the worktree, or the copy that keeps the link, changed the clone (see $L-real.log)"
# a dry run names the clone and leaves it as it was
skip_folder "$WORK/skip-dry" mine clone; before="$(skip_snapshot "$WORK/skip-dry/clone")"
skip_run "$WORK/skip-copy-real" "$WORK/skip-dry" --dry-run || fail "init --all --dry-run beside a fresh clone failed (see $WORK/skip-dry.log)"
grep -aqxF "skipped: clone carries no harness; ai-core init $WORK/skip-dry/clone installs it" "$WORK/skip-dry.log" && [ "$(skip_snapshot "$WORK/skip-dry/clone")" = "$before" ] || fail "the dry run did not name the clone, or changed it (see $WORK/skip-dry.log)"
# a folder whose only repository is a fresh clone ends with exit 0
skip_folder "$WORK/skip-alone" clone
skip_run "$WORK/skip-copy-real" "$WORK/skip-alone" || fail "init --all over a folder of one fresh clone did not end with exit 0 (see $WORK/skip-alone.log)"
grep -aq '0 repositories were initialized, 1 skipped without a harness$' "$WORK/skip-alone.log" || fail "init --all over a folder of one fresh clone does not count it: $(tail -1 "$WORK/skip-alone.log")"
# innocent: a folder of harnessed checkouts only skips nothing, on the real copy and on the one that walks every repository
for copy in real all; do
  skip_folder "$WORK/skip-innocent-$copy" mine other; carry_harness "$WORK/skip-innocent-$copy/other"
  skip_run "$WORK/skip-copy-$copy" "$WORK/skip-innocent-$copy" || fail "innocent: init --all over harnessed checkouts only failed with the $copy copy (see $WORK/skip-innocent-$copy.log)"
  ! grep -aq '^skipped: ' "$WORK/skip-innocent-$copy.log" && grep -aq '4 repositories were initialized, 0 skipped without a harness$' "$WORK/skip-innocent-$copy.log" || fail "innocent: init --all over harnessed checkouts only skipped one with the $copy copy: $(tail -1 "$WORK/skip-innocent-$copy.log")"
  grep -q '^| `mine` |' "$WORK/skip-innocent-$copy/AGENTS.md" && grep -q '^| `other` |' "$WORK/skip-innocent-$copy/AGENTS.md" || fail "innocent: the map of harnessed checkouts only lacks one with the $copy copy"
  [ -L "$WORK/skip-innocent-$copy/.worktrees/mine/other" ] || fail "innocent: the worktree of mine got no link to the harnessed checkout beside it with the $copy copy"
done
# ai-core init <path> equips the clone, and the next init --all refreshes it
HOME="$WORK/skip-home" PATH="$SHIM:$PATH_SH" bash "$ROOT/bin/init.sh" "$WORK/skip-real/clone" --no-doctor > "$WORK/skip-clone.log" 2>&1 || fail "init on the fresh clone failed (see $WORK/skip-clone.log)"
[ -f "$WORK/skip-real/clone/.ai-core/STAMP" ] || fail "init on the fresh clone did not install the harness"
skip_run "$WORK/skip-copy-real" "$WORK/skip-real" || fail "init --all after the clone was equipped failed (see $WORK/skip-real.log)"
! grep -aq '^skipped: ' "$WORK/skip-real.log" && grep -aq '^### clone$' "$WORK/skip-real.log" && grep -q '^| `clone` |' "$WORK/skip-real/AGENTS.md" || fail "init --all did not refresh the clone once it carried the harness (see $WORK/skip-real.log)"
echo "  the clone is named, counted and left byte for byte as it was, with its worktrees, its forge and its map entry, the harnessed checkout and its worktree are refreshed, a dry run and a folder of one clone end with exit 0, a folder of harnessed checkouts skips nothing and links its neighbours, a link an earlier version made to the clone goes and the clone stays, init <path> equips the clone and the next run refreshes it, and each planted copy goes red"
exit 0
