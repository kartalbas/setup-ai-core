#!/usr/bin/env bash
# What finish-issue.sh removes, what it refuses, where it moves the card, and what --sweep leaves.
#
# It runs inside a TEMPORARY repository with a temporary origin, both built and deleted here, and
# with a FAKE gh on PATH: nothing leaves the machine. What is pinned: a worktree with changes or with
# work origin does not have stays and is named; a landed one goes with its branch; the card moves to
# the column after implementing unless that is done; the issue is told what landed; --sweep removes
# only a landed worktree that was committed in and has rested for a day.
#
#   bash test/finish-issue.test.sh

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fake="$(mktemp -d)"
export GH_CACHE_DIRECTORY="$fake/cache"
export GH_PROJECT_NUMBER=999982
trap 'rm -rf "$fake"' EXIT
log="$fake/calls.txt"
board="$fake/board.tsv"
state="$fake/state.txt"

cat > "$fake/gh" <<EOF
#!/usr/bin/env bash
a="\$*"
printf '%s\n' "\$a" >> "$log"
case "\$a" in
  *"repo view"*)            echo 'example-org/example-repo' ;;
  *"issue comment"*)        echo 'https://example.invalid/example-org/example-repo/issues/163#issuecomment-1' ;;
  *comments*)               echo '[]' ;;
  *"--jq .node_id"*)        echo 'I_node163' ;;
  *"projectV2(number:"*)    echo 'PVT_kwfinish' ;;
  *"fields(first:50)"*)     cat "$board" ;;
  *addProjectV2ItemById*)   echo 'PVTI_item163' ;;
  *projectItems*)           printf '' ;;
  *"projectsV2(first"*)     [ -e "$fake/no-board" ] || echo '{}' ;;
  *graphql*)                echo '{}' ;;
  *"api user"*)             echo '{"login":"tester"}' ;;
  *issues/*)                echo '{"number":163,"title":"Read the board whole","state":"'"\$(cat "$state")"'","labels":[],"assignees":[],"body":"The count is a guess."}' ;;
  *)                        echo '{}' ;;
esac
exit 0
EOF
chmod +x "$fake/gh"
export PATH="$fake:$PATH"
printf 'Status\tFID\ttodo\tOPT_todo\nStatus\tFID\timplementing\tOPT_impl\nStatus\tFID\ttesting\tOPT_test\nStatus\tFID\tdone\tOPT_done\n' > "$board"
echo open > "$state"

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
checkouts="$fake/checkouts"
work="$checkouts/example-repo"
trees="$checkouts/.worktrees/example-repo"
mkdir -p "$checkouts" "$trees"
git -c init.defaultBranch=master init -q --bare "$origin"
git -c init.defaultBranch=master init -q "$work"
dress "$work"
echo 'one' > "$work/README.md"
git -C "$work" add -A && git -C "$work" commit -q -m 'the first commit'
git -C "$work" remote add origin "$origin"
git -C "$work" push -q -u origin master
git -C "$work" remote set-head origin -a >/dev/null

finish="$root/bin/finish-issue.sh"
run() { (cd "$work" && bash "$finish" "$@" 2>&1); }
# open <branch>: a worktree on a new issue branch, cut from origin/master
open() { git -C "$work" worktree add -q -b "$1" "$trees/$1" origin/master 2>/dev/null; dress "$trees/$1"; }
# land <branch> <message> [date]: a commit in the worktree, pushed to master
land() {
  echo "$2" >> "$trees/$1/README.md"
  git -C "$trees/$1" add -A
  GIT_AUTHOR_DATE="${3:-}" GIT_COMMITTER_DATE="${3:-}" git -C "$trees/$1" commit -q -m "$2"
  git -C "$trees/$1" push -q origin HEAD:master
  git -C "$work" pull -q --ff-only origin master
}
has_tree() { [ -d "$trees/$1" ] && echo yes || echo no; }
has_branch() { git -C "$work" rev-parse -q --verify "refs/heads/$1" >/dev/null && echo yes || echo no; }

echo 'a call with no number is refused before anything is read'
: > "$log"
out="$(run)"; rc=$?
check 'exits nonzero'    yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'nothing was read' 0 "$(grep -c . "$log" || true)"

echo 'a worktree with changes stays, and says why'
open issue-163-read-the-board-whole
echo 'unsaved' >> "$trees/issue-163-read-the-board-whole/README.md"
out="$(run 163)"; rc=$?
check 'exits nonzero'       yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'it says which'       yes "$(grep -q 'issue-163-read-the-board-whole has changes' <<< "$out" && echo yes || echo no)"
check 'the worktree stays'  yes "$(has_tree issue-163-read-the-board-whole)"
git -C "$trees/issue-163-read-the-board-whole" checkout -q -- README.md

echo 'a worktree with a commit origin does not have stays, and says so'
echo 'mine' >> "$trees/issue-163-read-the-board-whole/README.md"
git -C "$trees/issue-163-read-the-board-whole" commit -q -am 'Not pushed yet (#163)'
out="$(run 163)"; rc=$?
check 'exits nonzero'       yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'it names the commit' yes "$(grep -q 'has 1 commit(s) origin/master does not have' <<< "$out" && echo yes || echo no)"
check 'the worktree stays'  yes "$(has_tree issue-163-read-the-board-whole)"

echo 'a landed worktree goes with its branch, the card moves to testing, and the issue says what landed'
git -C "$trees/issue-163-read-the-board-whole" push -q origin HEAD:master
: > "$log"; rm -rf "$fake/cache"
out="$(run 163)"; rc=$?
check 'exits zero'            0 "$rc"
check 'the worktree is gone'  no "$(has_tree issue-163-read-the-board-whole)"
check 'the branch is gone'    no "$(has_branch issue-163-read-the-board-whole)"
check 'the card moved to testing' 1 "$(grep -c 'oid=OPT_test' "$log" || true)"
check 'the issue was told'    yes "$(grep -q 'issue comment 163 .*Landed on master:.*Not pushed yet (#163)' <<< "$(tr '\n' ' ' < "$log")" && echo yes || echo no)"

echo 'where the column after implementing is done, the card stays for the owner'
printf 'Status\tFID\ttodo\tOPT_todo\nStatus\tFID\timplementing\tOPT_impl\nStatus\tFID\tdone\tOPT_done\n' > "$board"
: > "$log"; rm -rf "$fake/cache"
out="$(run 163)"; rc=$?
check 'exits zero'          0 "$rc"
check 'it says so'          yes "$(grep -q 'the column after implementing is done' <<< "$out" && echo yes || echo no)"
check 'the card did not move' 0 "$(grep -c 'oid=OPT_' "$log" || true)"

echo 'a closed issue keeps its card'
echo closed > "$state"; : > "$log"; rm -rf "$fake/cache"
out="$(run 163)"; rc=$?
check 'exits zero'          0 "$rc"
check 'it says so'          yes "$(grep -q 'the issue is closed already' <<< "$out" && echo yes || echo no)"
check 'the card did not move' 0 "$(grep -c 'oid=OPT_' "$log" || true)"
echo open > "$state"

echo '--sweep removes a landed worktree that has rested for a day, and names every other'
open issue-201-rested
land issue-201-rested 'An old change (#201)' "$(date -d '2 days ago' '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -v-2d '+%Y-%m-%dT%H:%M:%S')"
open issue-202-fresh
land issue-202-fresh 'A change of today (#202)'
open issue-203-never-committed
open issue-204-open-work
echo 'unsaved' >> "$trees/issue-204-open-work/README.md"
: > "$log"
out="$(run --sweep --dry-run)"; rc=$?
check 'dry run: exits zero'            0 "$rc"
check 'dry run: it would remove the rested one' yes "$(grep -q 'issue-201-rested: landed, would be removed' <<< "$out" && echo yes || echo no)"
check 'dry run: nothing removed'       yes "$(has_tree issue-201-rested)"
out="$(run --sweep)"; rc=$?
check 'exits zero'                     0 "$rc"
check 'the rested one is gone'         no "$(has_tree issue-201-rested)"
check 'with its branch'                no "$(has_branch issue-201-rested)"
check 'the fresh one stays'            yes "$(has_tree issue-202-fresh)"
check 'and says why'                   yes "$(grep -q 'issue-202-fresh: landed less than a day ago' <<< "$out" && echo yes || echo no)"
grep -q 'issue-202-fresh: landed less than a day ago' <<< "$out" || printf '       the sweep said:\n%s\n' "$(sed 's/^/         /' <<< "$out")"
check 'the uncommitted one stays'      yes "$(has_tree issue-203-never-committed)"
check 'the one with changes stays'     yes "$(has_tree issue-204-open-work)"
check 'the sweep moves no card'        0 "$(grep -c 'oid=OPT_' "$log" || true)"

echo 'a repository on no board: the landed worktree goes, no card is looked for, and the issue is told'
open issue-167-keep-the-harness-off-the-board
land issue-167-keep-the-harness-off-the-board 'Keep the harness off the board (#167)'
touch "$fake/no-board"; : > "$log"; rm -rf "$fake/cache"
out="$(cd "$work" && GH_PROJECT_NUMBER='' bash "$finish" 167 2>&1)"; rc=$?
check 'exits zero'             0 "$rc"
check 'the worktree is gone'   no "$(has_tree issue-167-keep-the-harness-off-the-board)"
check 'it says so'             yes "$(grep -q '^example-org/example-repo is on no board - there is no card to move$' <<< "$out" && echo yes || echo no)"
check 'no card was moved'      0 "$(grep -c 'oid=OPT_' "$log" || true)"
check 'the issue was told'     yes "$(grep -q 'issue comment 167 .*Landed on master:.*Keep the harness off the board (#167)' <<< "$(tr '\n' ' ' < "$log")" && echo yes || echo no)"
rm -f "$fake/no-board"

echo 'an origin/HEAD naming a branch the remote no longer has: the default branch is asked of the remote'
open issue-168-read-the-default-branch
land issue-168-read-the-default-branch 'Read the default branch from the remote (#168)'
git -C "$work" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/gone
out="$(run 168)"; rc=$?
check 'exits zero'             0 "$rc"
check 'the worktree is gone'   no "$(has_tree issue-168-read-the-default-branch)"
git -C "$work" remote set-head origin -a >/dev/null

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
