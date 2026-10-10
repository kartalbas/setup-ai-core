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
#
#   bash tests/integrate-issue.test.sh

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fake="$(mktemp -d)"
export GH_CACHE_DIRECTORY="$fake/cache"
trap 'rm -rf "$fake"' EXIT
title="$fake/title.txt"

cat > "$fake/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$fake/calls.txt"
case "\$*" in
  *"repo view"*) echo 'example-org/example-repo' ;;
  *comments*)    echo '[]' ;;
  *issues/*)     printf '{"number":77,"title":"%s","state":"open","labels":[],"assignees":[],"body":"b"}\n' "\$(cat "$title")" ;;
  *)             echo '{}' ;;
esac
exit 0
EOF
chmod +x "$fake/gh"
export PATH="$fake:$PATH"
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
  git -C "$1" config core.autocrlf false
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

echo 'a clean run leaves one merge commit with the title and the trailer, and the branch checked out'
out="$(integrate "$wt" 77 --reviewed-by l4)"; rc=$?
check 'exit 0'                         0 "$rc"
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
out="$(integrate "$wt7" example-org/example-repo 83 --reviewed-by l4)"; rc=$?
check 'its own repository named: exit 0' 0 "$rc"
check 'the subject keeps the short form' 'Read the board whole (#83)' "$(git --git-dir="$origin" log -1 --format=%s master)"

echo 'the landings of one clone take turns: a lock a live process holds is waited for, a dead one taken over'
lock="$work/.git/ai-core-landing"
sleep 30 & holder=$!
printf '%s\t%s\n' "$holder" 'example-org/example-repo#5' > "$lock"
( sleep 4; rm -f "$lock" ) & release=$!
wt8="$(new_tree 84 waits)"
started=$SECONDS
out="$(integrate "$wt8" 84 --reviewed-by l4)"; rc=$?
waited=$((SECONDS - started))
kill "$holder" 2>/dev/null; wait "$holder" "$release" 2>/dev/null
check 'exit 0'                         0 "$rc"
check 'it names who holds the lock'    yes "$(grep -qxF "waiting: example-org/example-repo#5 is landing from this clone (process $holder); this one lands after it" <<< "$out" && echo yes || echo no)"
check 'it landed once the lock was released' yes "$([ "$waited" -ge 3 ] && [ "$(git --git-dir="$origin" log -1 --format=%s master)" = 'Read the board whole (#84)' ] && echo yes || echo no)"
check 'and released its own'           no "$([ -e "$lock" ] && echo yes || echo no)"
sh -c 'exit 0' & dead=$!; wait "$dead"
printf '%s\t%s\n' "$dead" 'example-org/example-repo#6' > "$lock"
wt9="$(new_tree 85 takes)"
out="$(integrate "$wt9" 85 --reviewed-by l4)"; rc=$?
check 'a lock whose process is gone: exit 0' 0 "$rc"
check 'it says it took the lock over'  yes "$(grep -qxF "taken over: the landing lock of example-org/example-repo#6, whose process $dead no longer runs" <<< "$out" && echo yes || echo no)"
check 'and released it'                no "$([ -e "$lock" ] && echo yes || echo no)"

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

echo
[ "$failed" -eq 0 ] && echo 'all passed' || echo "$failed failed"
[ "$failed" -eq 0 ]
