#!/usr/bin/env bash
# What integrate-issue.sh puts on origin's default branch, what it refuses, and where it leaves the
# worktree.
#
# It runs inside a TEMPORARY repository with a temporary origin, both built and deleted here, and
# with a FAKE gh on PATH: nothing leaves the machine. What is pinned: no reviewer, no issue branch
# or a tree with changes is refused before anything moves; a clean run leaves one merge commit with
# the issue's title and the trailer, its parents the old tip and the branch, and the branch checked
# out again; a branch already integrated, a conflict and a push the hook refuses leave origin as it
# was and the worktree on its branch. The landings of one clone take turns: a lock a live process
# holds is waited for, one whose process is gone is taken over, and the lock spans the push.
# With --from-origin the branch lands as origin holds it, from a directory that is not the issue's
# worktree: the worktree another session holds, with its uncommitted change and its commits that
# origin lacks, stays as it was, the temporary worktree of the merge is gone afterwards, and a
# missing branch, a conflict and a refused push leave origin as it was. Where the merged tree
# carries scripts/install.sh, it runs in the temporary worktree before the push, so a gate that
# needs installed dependencies passes; a failing install refuses the landing before the gate runs.
#
#   bash tests/integrate-issue.test.sh

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fake="$(mktemp -d)"
export GH_CACHE_DIRECTORY="$fake/cache"
trap 'rm -rf "$fake"' EXIT
mkdir "$fake/tmp"; export TMPDIR="$fake/tmp"   # where the temporary worktree of --from-origin is made
title="$fake/title.txt"

cat > "$fake/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$fake/calls.txt"
if [ -e "$fake/refuse-once" ] && [[ "\$*" == *"/issues/"* ]] && [[ "\$*" != *"comments"* ]]; then
  rm -f "$fake/refuse-once"
  echo '{"message":"API rate limit already exceeded for user ID 1."}'
  echo 'gh: API rate limit already exceeded for user ID 1. (HTTP 403)' >&2
  exit 1
fi
if [ -e "$fake/refuse-repo-once" ] && [[ "\$*" == "api repos/{owner}/{repo} --jq .full_name"* ]]; then
  rm -f "$fake/refuse-repo-once"
  echo '{"message":"API rate limit already exceeded for user ID 1."}'
  echo 'gh: API rate limit already exceeded for user ID 1. (HTTP 403)' >&2
  exit 1
fi
case "\$*" in
  *"repo view"*|"api repos/{owner}/{repo} --jq .full_name"*) if [ -e "$fake/limited" ]; then echo '{"message":"API rate limit already exceeded for user ID 1."}'; echo 'gh: API rate limit already exceeded for user ID 1. (HTTP 403)' >&2; exit 1; fi; echo 'example-org/example-repo' ;;
  *comments*)    echo '[]' ;;
  *issues/*)     printf '{"number":77,"title":"%s","state":"open","labels":[],"assignees":[],"body":"b"}\n' "\$(cat "$title")" ;;
  *)             echo '{}' ;;
esac
exit 0
EOF
chmod +x "$fake/gh"
export PATH="$fake:$PATH"
export AI_CORE_SLEEP=true   # the waits of a refused call take no time here
echo 'Read the board whole' > "$title"

failed=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}
dress() {
  git -C "$1" config user.email 'test@example.invalid'
  git -C "$1" config user.name 'test'
  git -C "$1" config commit.gpgsign false
}

origin="$fake/origin.git"
work="$fake/checkouts/example-repo"
trees="$fake/checkouts/.worktrees/example-repo"
mkdir -p "$trees"
git -c init.defaultBranch=master init -q --bare "$origin"
git -c init.defaultBranch=master init -q "$work"
dress "$work"
echo 'one' > "$work/README.md"
git -C "$work" add -A && git -C "$work" commit -q -m 'Start #1'
git -C "$work" remote add origin "$origin"
git -C "$work" push -q origin master 2>/dev/null
git -C "$work" remote set-head origin master >/dev/null 2>&1 || git -C "$work" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master

# new_tree <number> <slug>: the worktree of an issue, as start-issue cuts it, with one commit in it
new_tree() {
  local wt="$trees/issue-$1-$2"
  git -C "$work" worktree add -q -b "issue-$1-$2" "$wt" origin/master
  dress "$wt"
  echo "$2" > "$wt/$2.txt"
  git -C "$wt" add -A && git -C "$wt" commit -q -m "Write $2 #$1"
  printf '%s' "$wt"
}
integrate() {  # integrate <dir> <args...>
  local dir="$1"; shift
  ( cd "$dir" && bash "$root/bin/integrate-issue.sh" "$@" 2>&1 )
}
tip() { git --git-dir="$origin" rev-parse master; }

wt="$(new_tree 77 board)"
before="$(tip)"

echo 'no reviewer, no issue branch, or a tree with changes is refused before anything moves'
out="$(integrate "$wt" 77)"; rc=$?
check 'without --reviewed-by: exit 1'  1 "$rc"
check 'it asks who reviewed'           yes "$(grep -qF 'who reviewed the work?' <<< "$out" && echo yes || echo no)"
out="$(integrate "$work" 77 --reviewed-by l4)"; rc=$?
check 'outside the issue branch: exit 1' 1 "$rc"
echo 'loose' > "$wt/loose.txt"
out="$(integrate "$wt" 77 --reviewed-by l4)"; rc=$?
check 'a tree with changes: exit 1'    1 "$rc"
rm "$wt/loose.txt"
check 'origin did not move'            "$before" "$(tip)"

echo 'a GitHub call refused by a rate limit says that nothing landed, and names the limit'
touch "$fake/limited"
out="$(integrate "$wt" 77 --reviewed-by l4)"; rc=$?
rm -f "$fake/limited"
check 'exit 1'                         1 "$rc"
check 'it says nothing landed'         yes "$(grep -qF 'nothing landed' <<< "$out" && echo yes || echo no)"
check 'it names the limit'             yes "$(grep -qF "GitHub's secondary rate limit still refuses after 3 waits" <<< "$out" && echo yes || echo no)"
check 'origin did not move'            "$before" "$(tip)"
check 'the worktree is on its branch'  'issue-77-board' "$(git -C "$wt" symbolic-ref --short HEAD)"

echo 'a clean run leaves one merge commit with the title and the trailer, and the branch checked out, a refusal that lifts met twice on the way'
touch "$fake/refuse-once" "$fake/refuse-repo-once"
out="$(integrate "$wt" 77 --reviewed-by l4)"; rc=$?
check 'exit 0'                         0 "$rc"
check 'the repository read was refused once and waited for' 2 "$(grep -c "^waiting 60s for GitHub's secondary rate limit" <<< "$out" || true)"
check 'the first parent is the old tip' "$before" "$(git --git-dir="$origin" rev-parse master^1)"
check 'the second parent is the branch' "$(git -C "$wt" rev-parse HEAD)" "$(git --git-dir="$origin" rev-parse master^2)"
check 'the subject is the title and the issue' 'Read the board whole (#77)' "$(git --git-dir="$origin" log -1 --format=%s master)"
check 'it carries the trailer'         'l4' "$(git --git-dir="$origin" log -1 --format='%(trailers:key=Reviewed-by,valueonly)' master | tr -d '\n')"
check 'the worktree is on its branch again' 'issue-77-board' "$(git -C "$wt" symbolic-ref --short HEAD)"

echo 'a branch already integrated has nothing to integrate'
after="$(tip)"
out="$(integrate "$wt" 77 --reviewed-by l4)"; rc=$?
check 'exit 1'                         1 "$rc"
check 'it says so'                     yes "$(grep -qF 'nothing to integrate' <<< "$out" && echo yes || echo no)"
check 'origin did not move'            "$after" "$(tip)"

echo 'a title too long for a subject gives way to the branch'
echo 'Read every column of the board whole and in its own order, or a card is lost' > "$title"
wt2="$(new_tree 78 columns)"
out="$(integrate "$wt2" 78 --reviewed-by l4)"; rc=$?
check 'exit 0'                         0 "$rc"
check 'the subject names the branch'   'Merge issue-78-columns (#78)' "$(git --git-dir="$origin" log -1 --format=%s master)"
echo 'Read the board whole' > "$title"

echo 'two reviewers: one trailer each, in the order given, and a name given twice once'
wt12="$(new_tree 88 two)"
out="$(integrate "$wt12" 88 --reviewed-by l4 --reviewed-by=l5 --reviewed-by l4)"; rc=$?
check 'exit 0'                         0 "$rc"
check 'both trailers, in order, l4 once' 'l4 l5' "$(git --git-dir="$origin" log -1 --format='%(trailers:key=Reviewed-by,valueonly)' master | tr '\n' ' ' | sed 's/ *$//')"
check 'the report names both'          yes "$(grep -q ', Reviewed-by: l4, Reviewed-by: l5$' <<< "$out" && echo yes || echo no)"
wt13="$(new_tree 89 comma)"
out="$(integrate "$wt13" 89 --reviewed-by 'Smith,J')"; rc=$?
check 'a comma in a name stays in the report' yes "$(grep -q ', Reviewed-by: Smith,J$' <<< "$out" && echo yes || echo no)"

echo 'a conflict leaves origin as it was and the worktree on its branch'
wt3="$(new_tree 79 clash)"
echo 'theirs' > "$work/clash.txt"
git -C "$work" pull -q origin master 2>/dev/null
git -C "$work" add -A && git -C "$work" commit -q -m 'Write clash first #9' && git -C "$work" push -q origin master 2>/dev/null
after="$(tip)"
out="$(integrate "$wt3" 79 --reviewed-by l4)"; rc=$?
check 'exit 1'                         1 "$rc"
check 'it names the conflict'          yes "$(grep -qF 'does not merge cleanly' <<< "$out" && echo yes || echo no)"
check 'origin did not move'            "$after" "$(tip)"
check 'the worktree is on its branch'  'issue-79-clash' "$(git -C "$wt3" symbolic-ref --short HEAD)"
check 'and no merge is left open'      '' "$(git -C "$wt3" status --porcelain)"

# The issue lives in other-org/tracker and its work lands here: the subject names it with its
# repository, because '#81' here would link to an unrelated issue of this repository.
echo 'an issue of another repository is read there and named with it, from the branch or the argument'
wt5="$(new_tree 81 cross)"
git -C "$work" config branch.issue-81-cross.issueRepository other-org/tracker
: > "$fake/calls.txt"
out="$(integrate "$wt5" 81 --reviewed-by l4)"; rc=$?
check 'exit 0'                         0 "$rc"
check 'the issue was read there'       yes "$(grep -q 'other-org/tracker/issues/81' "$fake/calls.txt" && echo yes || echo no)"
check 'the subject names its repository' 'Read the board whole (other-org/tracker#81)' "$(git --git-dir="$origin" log -1 --format=%s master)"
check 'the next step names it too'     yes "$(grep -qx 'next: ai-core finish-issue other-org/tracker 81' <<< "$out" && echo yes || echo no)"
wt6="$(new_tree 82 named)"
: > "$fake/calls.txt"
out="$(integrate "$wt6" other-org/tracker 82 --reviewed-by l4)"; rc=$?
check 'given as an argument: exit 0'   0 "$rc"
check 'the issue was read there'       yes "$(grep -q 'other-org/tracker/issues/82' "$fake/calls.txt" && echo yes || echo no)"
check 'the subject names its repository' 'Read the board whole (other-org/tracker#82)' "$(git --git-dir="$origin" log -1 --format=%s master)"
wt7="$(new_tree 83 own)"
touch "$fake/refuse-repo-once"
out="$(integrate "$wt7" example-org/example-repo 83 --reviewed-by l4)"; rc=$?
check 'its own repository named: exit 0' 0 "$rc"
check 'the subject keeps the short form' 'Read the board whole (#83)' "$(git --git-dir="$origin" log -1 --format=%s master)"
check 'one issue, one next step'          1 "$(grep -c '^next: ' <<< "$out")"

# A package: one commit per issue, one merge named for the first. Its own repository written out
# is the short form; a number named in passing, without parentheses, lands nothing.
echo 'a package: every issue its commits name in parentheses is a next step, the integrated one first'
wt8="$(new_tree 91 package)"
for part in '(#92)' '(example-org/example-repo#93)' '(other-org/tracker#7)' '(#92) again' 'after #12 in passing'; do
  echo "$part" >> "$wt8/package.txt"; git -C "$wt8" commit -q -am "Part $part"
done
out="$(integrate "$wt8" 91 --reviewed-by l4)"; rc=$?
check 'exit 0'                         0 "$rc"
check 'every issue once, in the order the commits landed' \
  'next: ai-core finish-issue 91
next: ai-core finish-issue 92
next: ai-core finish-issue 93
next: ai-core finish-issue other-org/tracker 7' "$(grep '^next: ' <<< "$out")"

echo 'the landings of one clone take turns: a lock a live process holds is waited for, a dead one taken over'
lock="$work/.git/ai-core-landing"
# land_while_held <dir> <number>: the landing runs in the background; once it says it waits, and
# not before, the lock it waits for is released, so a slow start cannot pass for a wait
land_while_held() {
  local said="$fake/held-$2.out" i
  ( integrate "$1" "$2" --reviewed-by l4 > "$said"; echo $? > "$said.rc" ) & local landing=$!
  for i in $(seq 1 240); do grep -qF 'waiting: ' "$said" 2>/dev/null && break; sleep 0.5; done
  tip_while_held="$(tip)"
  rm -f "$lock"; wait "$landing"
  out="$(cat "$said")"; rc="$(cat "$said.rc")"
}
sleep 300 & holder=$!
printf '%s\t%s\n' "$holder" 'example-org/example-repo#5' > "$lock"
wt8="$(new_tree 84 waits)"
before_held="$(tip)"
land_while_held "$wt8" 84
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
check 'exit 0'                         0 "$rc"
check 'it names who holds the lock'    "waiting: example-org/example-repo#5 is landing from this clone (process $holder); this one lands after it" "$(grep -m1 -E '^(waiting|taken over): ' <<< "$out")"
check 'it pushed nothing while it waited' "$before_held" "$tip_while_held"
check 'it landed once the lock was released' 'Read the board whole (#84)' "$(git --git-dir="$origin" log -1 --format=%s master)"
check 'and released its own'           no "$([ -e "$lock" ] && echo yes || echo no)"
sh -c 'exit 0' & dead=$!; wait "$dead"
printf '%s\t%s\n' "$dead" 'example-org/example-repo#6' > "$lock"
wt9="$(new_tree 85 takes)"
out="$(integrate "$wt9" 85 --reviewed-by l4)"; rc=$?
check 'a lock whose process is gone: exit 0' 0 "$rc"
check 'it says it took the lock over'  yes "$(grep -qxF "taken over: the landing lock of example-org/example-repo#6, whose process $dead no longer runs" <<< "$out" && echo yes || echo no)"
check 'and released it'                no "$([ -e "$lock" ] && echo yes || echo no)"
# A holder of another user's: kill -0 cannot signal it, and it still runs. Process 1 is one where
# this test runs unprivileged on a system that has it.
if ps -p 1 >/dev/null 2>&1 && ! kill -0 1 2>/dev/null; then
  printf '%s\t%s\n' 1 'example-org/example-repo#7' > "$lock"
  wt11="$(new_tree 87 foreign)"
  land_while_held "$wt11" 87
  check "another user's process: exit 0" 0 "$rc"
  check 'it is waited for, not taken over' 'waiting: example-org/example-repo#7 is landing from this clone (process 1); this one lands after it' "$(grep -m1 -E '^(waiting|taken over): ' <<< "$out")"
else
  echo "  skip another user's process: process 1 is missing here or this test may signal it"
fi
printf 'half written' > "$lock"
wt10="$(new_tree 86 blank)"
out="$(integrate "$wt10" 86 --reviewed-by l4)"; rc=$?
check 'a lock that names no process: exit 0' 0 "$rc"
check 'it is taken over after one poll' yes "$(grep -qxF "taken over: a landing lock that names no process: 'half written'" <<< "$out" && echo yes || echo no)"

# held_tree <number> <slug>: the worktree of an issue whose branch is pushed and whose session left
# a change in the tree that no commit holds, as a stopped session does
held_tree() {
  local wt
  wt="$(new_tree "$1" "$2")"
  git -C "$wt" push -q origin "issue-$1-$2" 2>/dev/null
  echo 'work in progress' >> "$wt/$2.txt"
  echo 'a new file' > "$wt/untracked.txt"
  printf '%s' "$wt"
}
# held_state <dir>: everything the integration must leave as it found it
held_state() { printf '%s\n%s\n%s\n' "$(git -C "$1" rev-parse HEAD)" "$(git -C "$1" symbolic-ref --short HEAD)" "$(git -C "$1" status --porcelain; cat "$1"/*.txt)"; }
trees_listed() { git -C "$work" worktree list | wc -l | tr -d ' '; }
leftovers() { ls -A "$fake/tmp" | wc -l | tr -d ' '; }

echo '--from-origin lands a pushed branch whose worktree holds an uncommitted change, and leaves that worktree alone'
heldwt="$(held_tree 100 held)"
held_before="$(held_state "$heldwt")"
trees_before="$(trees_listed)"
before="$(tip)"
out="$(integrate "$work" 100 --reviewed-by l4 --from-origin)"; rc=$?
check 'exit 0'                         0 "$rc"
check 'it says which commit it merges' yes "$(grep -qxF "merging: origin/issue-100-held at $(git -C "$heldwt" rev-parse --short HEAD)" <<< "$out" && echo yes || echo no)"
check 'no install step runs where the tree has none' no "$(grep -q '^installing: ' <<< "$out" && echo yes || echo no)"
check 'one merge commit landed'        1 "$(git --git-dir="$origin" rev-list --merges --count "$before..master")"
check 'the first parent is the old tip' "$before" "$(git --git-dir="$origin" rev-parse master^1)"
check 'the second parent is the pushed branch, with the sha the reviewer read' "$(git -C "$heldwt" rev-parse HEAD)" "$(git --git-dir="$origin" rev-parse master^2)"
check 'the subject is the title and the issue' 'Read the board whole (#100)' "$(git --git-dir="$origin" log -1 --format=%s master)"
check 'it carries the trailer'         'l4' "$(git --git-dir="$origin" log -1 --format='%(trailers:key=Reviewed-by,valueonly)' master | tr -d '\n')"
check 'it names the next step'         'next: ai-core finish-issue 100' "$(grep '^next: ' <<< "$out")"
check 'the held worktree, its branch, HEAD and changes are as they were' "$held_before" "$(held_state "$heldwt")"
check 'the temporary worktree is gone, registered nowhere' "$trees_before" "$(trees_listed)"
check 'and no folder of it is left'    0 "$(leftovers)"
check 'the lock is released'           no "$([ -e "$lock" ] && echo yes || echo no)"
check 'the checkout it ran in is on its own branch' master "$(git -C "$work" symbolic-ref --short HEAD)"

echo '--from-origin merges what origin holds: a commit only the held worktree has does not land'
heldwt2="$(held_tree 101 local)"
pushed="$(git -C "$heldwt2" rev-parse HEAD)"
echo 'only here' > "$heldwt2/only-here.txt"; git -C "$heldwt2" add only-here.txt; git -C "$heldwt2" commit -q -m 'Not pushed #101'
held_before="$(held_state "$heldwt2")"
out="$(integrate "$work" 101 --reviewed-by l4 --from-origin)"; rc=$?
check 'exit 0'                         0 "$rc"
check 'it names the commit of origin'  yes "$(grep -qxF "merging: origin/issue-101-local at $(git -C "$heldwt2" rev-parse --short "$pushed")" <<< "$out" && echo yes || echo no)"
check 'the second parent is the commit origin held' "$pushed" "$(git --git-dir="$origin" rev-parse master^2)"
check 'the unpushed commit is not on origin' no "$(git --git-dir="$origin" cat-file -e "$(git -C "$heldwt2" rev-parse HEAD)" 2>/dev/null && echo yes || echo no)"
check 'the held worktree is as it was' "$held_before" "$(held_state "$heldwt2")"

heldwt3="$(held_tree 102 refused)"

echo '--from-origin without a branch on origin, or of one already integrated, is refused before anything moves'
after="$(tip)"
out="$(integrate "$work" 99 --reviewed-by l4 --from-origin)"; rc=$?
check 'no branch: exit 1'              1 "$rc"
check 'it says origin has none'        yes "$(grep -qF 'origin has no branch issue-99-*' <<< "$out" && echo yes || echo no)"
out="$(integrate "$work" 100 --reviewed-by l4 --from-origin)"; rc=$?
check 'integrated already: exit 1'     1 "$rc"
check 'it says nothing to integrate'   yes "$(grep -qF 'nothing to integrate' <<< "$out" && echo yes || echo no)"
git -C "$work" push -q origin issue-77-board "issue-77-board:issue-77-board-again" 2>/dev/null
out="$(integrate "$work" 77 --reviewed-by l4 --from-origin)"; rc=$?
check 'two branches of one issue: exit 1' 1 "$rc"
check 'it names that it does not guess' yes "$(grep -qF 'more than one branch for issue 77' <<< "$out" && echo yes || echo no)"
git -C "$work" push -q origin --delete issue-77-board issue-77-board-again 2>/dev/null
check 'origin did not move'            "$after" "$(tip)"
check 'no folder of a temporary worktree is left' 0 "$(leftovers)"

echo '--from-origin on a conflict leaves origin as it was, the held worktree untouched and no temporary worktree'
git -C "$wt3" push -q origin issue-79-clash 2>/dev/null
echo 'in progress' > "$wt3/loose.txt"
held_before="$(held_state "$wt3")"
trees_before="$(trees_listed)"
out="$(integrate "$work" 79 --reviewed-by l4 --from-origin)"; rc=$?
check 'exit 1'                         1 "$rc"
check 'it names the conflict'          yes "$(grep -qF 'does not merge cleanly' <<< "$out" && echo yes || echo no)"
check 'origin did not move'            "$after" "$(tip)"
check 'the held worktree is as it was' "$held_before" "$(held_state "$wt3")"
check 'the temporary worktree is gone' "$trees_before" "$(trees_listed)"
check 'and no folder of it is left'    0 "$(leftovers)"
check 'the lock is released'           no "$([ -e "$lock" ] && echo yes || echo no)"
rm "$wt3/loose.txt"

echo 'a push the hook refuses reaches nothing, and the branch is checked out again'
wt4="$(new_tree 80 refused)"
mkdir -p "$fake/hooks"; printf '#!/bin/sh\ncut -f2 "%s" > "%s"\necho "pre-push: REFUSED - planted"\nexit 1\n' "$lock" "$fake/held.txt" > "$fake/hooks/pre-push"; chmod +x "$fake/hooks/pre-push"
git -C "$work" config core.hooksPath "$fake/hooks"
after="$(tip)"
out="$(integrate "$wt4" 80 --reviewed-by l4)"; rc=$?
check 'exit 1'                         1 "$rc"
check 'it says nothing reached origin' yes "$(grep -qF 'nothing reached origin' <<< "$out" && echo yes || echo no)"
check 'origin did not move'            "$after" "$(tip)"
check 'the worktree is on its branch'  'issue-80-refused' "$(git -C "$wt4" symbolic-ref --short HEAD)"
check 'the lock was held during the push' '#80' "$(cat "$fake/held.txt" 2>/dev/null)"
check 'and is released after the refusal' no "$([ -e "$lock" ] && echo yes || echo no)"

echo '--from-origin: a push the hook refuses reaches nothing, and the held worktree is as it was'
held_before="$(held_state "$heldwt3")"
trees_before="$(trees_listed)"
after="$(tip)"
out="$(integrate "$work" 102 --reviewed-by l4 --from-origin)"; rc=$?
check 'exit 1'                         1 "$rc"
check 'it says nothing reached origin' yes "$(grep -qF 'nothing reached origin' <<< "$out" && echo yes || echo no)"
check 'origin did not move'            "$after" "$(tip)"
check 'the lock was held during the push' '#102' "$(cat "$fake/held.txt" 2>/dev/null)"
check 'the held worktree is as it was' "$held_before" "$(held_state "$heldwt3")"
check 'the temporary worktree is gone' "$trees_before" "$(trees_listed)"
check 'and no folder of it is left'    0 "$(leftovers)"
check 'and the lock is released'       no "$([ -e "$lock" ] && echo yes || echo no)"

# The gate of a repository whose check needs installed dependencies, planted over the hook above: it
# refuses a tree that differs from the commit, as bin/pre-push.sh does, refuses without the installed
# marker, as the check of such a repository does, and records where it ran. The fixtures of each case
# reach origin with no hook, so core.hooksPath is unset around them and set right before integrate.
printf '#!/bin/sh\npwd > "%s"\n[ -z "$(git status --porcelain)" ] || { echo "pre-push: REFUSED - the working tree differs from the commit: $(git status --porcelain)"; exit 1; }\n[ -f node_modules/installed ] || { echo "check: FAIL - node_modules is missing"; echo "pre-push: REFUSED - planted"; exit 1; }\n' "$fake/checked.txt" > "$fake/hooks/pre-push"
# commit_install_script <body>: scripts/install.sh with that body on master, pushed with no hook
commit_install_script() {
  git -C "$work" config --unset core.hooksPath
  git -C "$work" pull -q origin master
  mkdir -p "$work/scripts"
  printf '#!/usr/bin/env bash\n%s\n' "$1" > "$work/scripts/install.sh"
  printf 'node_modules/\n' > "$work/.gitignore"
  git -C "$work" add -A && git -C "$work" commit -q -m 'Add the install step'
  git -C "$work" push -q origin master 2>/dev/null
}

echo '--from-origin runs scripts/install.sh of the merged tree before the push, so the gate finds what it installed'
commit_install_script 'mkdir -p node_modules && echo installed > node_modules/installed && echo "install: planted"'
heldwt4="$(held_tree 103 installed)"
held_before="$(held_state "$heldwt4")"
trees_before="$(trees_listed)"
before="$(tip)"
rm -f "$fake/checked.txt"
git -C "$work" config core.hooksPath "$fake/hooks"
out="$(integrate "$work" 103 --reviewed-by l4 --from-origin)"; rc=$?
check 'exit 0'                         0 "$rc"
check 'it says the install runs'       yes "$(grep -q '^installing: scripts/install.sh' <<< "$out" && echo yes || echo no)"
check 'the output of the install is visible' yes "$(grep -qxF 'install: planted' <<< "$out" && echo yes || echo no)"
check 'the gate ran in the temporary worktree' yes "$([[ "$(cat "$fake/checked.txt" 2>/dev/null)" == */ai-core-integrate-103.* ]] && echo yes || echo no)"
check 'one merge commit landed'        1 "$(git --git-dir="$origin" rev-list --merges --count "$before..master")"
check 'the held worktree is as it was' "$held_before" "$(held_state "$heldwt4")"
check 'the temporary worktree is gone, registered nowhere' "$trees_before" "$(trees_listed)"
check 'and nothing it installed is left' 0 "$(leftovers)"
check 'the lock is released'           no "$([ -e "$lock" ] && echo yes || echo no)"

echo '--from-origin of a tree without scripts/install.sh runs no install, and the gate refuses what it needs'
git -C "$work" config --unset core.hooksPath
git -C "$work" pull -q origin master
git -C "$work" rm -q scripts/install.sh
git -C "$work" commit -q -m 'Drop the install step'
git -C "$work" push -q origin master 2>/dev/null
heldwt5="$(held_tree 104 missing)"
held_before="$(held_state "$heldwt5")"
trees_before="$(trees_listed)"
after="$(tip)"
rm -f "$fake/checked.txt"
git -C "$work" config core.hooksPath "$fake/hooks"
out="$(integrate "$work" 104 --reviewed-by l4 --from-origin)"; rc=$?
check 'exit 1'                         1 "$rc"
check 'no install step ran'            no "$(grep -q '^installing: ' <<< "$out" && echo yes || echo no)"
check 'the gate says what is missing'  yes "$(grep -qF 'check: FAIL - node_modules is missing' <<< "$out" && echo yes || echo no)"
check 'it says nothing reached origin' yes "$(grep -qF 'nothing reached origin' <<< "$out" && echo yes || echo no)"
check 'origin did not move'            "$after" "$(tip)"
check 'the held worktree is as it was' "$held_before" "$(held_state "$heldwt5")"
check 'the temporary worktree is gone' "$trees_before" "$(trees_listed)"
check 'and no folder of it is left'    0 "$(leftovers)"
check 'the lock is released'           no "$([ -e "$lock" ] && echo yes || echo no)"

echo '--from-origin with a failing scripts/install.sh pushes nothing, never starts the gate and names the script'
commit_install_script 'echo "install: FAIL - planted"; exit 1'
heldwt6="$(held_tree 105 broken)"
held_before="$(held_state "$heldwt6")"
trees_before="$(trees_listed)"
after="$(tip)"
rm -f "$fake/checked.txt"
git -C "$work" config core.hooksPath "$fake/hooks"
out="$(integrate "$work" 105 --reviewed-by l4 --from-origin)"; rc=$?
check 'exit 1'                         1 "$rc"
check 'it names the script that failed' yes "$(grep -qF 'scripts/install.sh failed' <<< "$out" && echo yes || echo no)"
check 'the output of the install is visible' yes "$(grep -qxF 'install: FAIL - planted' <<< "$out" && echo yes || echo no)"
check 'the gate never ran'             no "$([ -e "$fake/checked.txt" ] && echo yes || echo no)"
check 'origin did not move'            "$after" "$(tip)"
check 'the held worktree is as it was' "$held_before" "$(held_state "$heldwt6")"
check 'the temporary worktree is gone' "$trees_before" "$(trees_listed)"
check 'and no folder of it is left'    0 "$(leftovers)"
check 'the lock is released'           no "$([ -e "$lock" ] && echo yes || echo no)"

echo
[ "$failed" -eq 0 ] && echo 'all passed' || echo "$failed failed"
[ "$failed" -eq 0 ]
