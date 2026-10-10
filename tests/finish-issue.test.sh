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
  # like gh, which reads the repository of the directory it runs in and finds none in a removed one
  *"repo view"*)            [ -d "\$PWD" ] || { echo 'failed to determine the repository' >&2; exit 1; }; echo 'example-org/example-repo' ;;
  *"issue comment"*)        echo 'https://example.invalid/example-org/example-repo/issues/163#issuecomment-1' ;;
  # status-sync's query of the repository's issues names comments and projectItems too
  *"issues(states:OPEN"*)   [ -e "$fake/issues-down" ] && { echo 'the issues are down' >&2; exit 1; }; echo '{"data":{"repository":{"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}' ;;
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
check 'it names the commit' yes "$(grep -q 'has 1 commit(s) whose change is not on origin/master' <<< "$out" && echo yes || echo no)"
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
check 'the board is not read whole' 0 "$(grep -c 'items(first:100, after:' "$log" || true)"
check 'the cards of its repository are swept, in one query (status-sync)' 1 "$(grep -c 'issues(states:OPEN' "$log" || true)"

echo 'a status-sync that fails is said, and finish-issue still completes'
touch "$fake/issues-down"; : > "$log"; rm -rf "$fake/cache"
out="$(run 163)"; rc=$?
check 'exits zero'            0 "$rc"
check 'it says so'            yes "$(grep -q '^status-sync did NOT run for example-org/example-repo: ' <<< "$out" && echo yes || echo no)"
rm -f "$fake/issues-down"

echo 'run inside the worktree it removes, it goes on from the main checkout and still moves the card'
open issue-170-run-from-inside
land issue-170-run-from-inside 'Run from inside (#170)'
: > "$log"; rm -rf "$fake/cache"
out="$(cd "$trees/issue-170-run-from-inside" && bash "$finish" 170 2>&1)"; rc=$?
check 'exits zero'            0 "$rc"
check 'the worktree is gone'  no "$(has_tree issue-170-run-from-inside)"
check 'the card moved to testing' 1 "$(grep -c 'oid=OPT_test' "$log" || true)"

echo "a package worktree, named for its first issue, stays when a later issue's branch in it is finished"
open issue-177-package
git -C "$trees/issue-177-package" checkout -q -b issue-182-a-later-part origin/master
land issue-177-package 'A later part (#182)'
: > "$log"; rm -rf "$fake/cache"
out="$(cd "$trees/issue-177-package" && bash "$finish" 182 2>&1)"; rc=$?
check 'exits zero'                 0 "$rc"
check 'the package worktree stays' yes "$(has_tree issue-177-package)"
check 'and the branch in it'       yes "$(has_branch issue-182-a-later-part)"
check 'it says why'                yes "$(grep -q 'issue-177-package is named for another issue and has issue-182-a-later-part checked out: it stays' <<< "$out" && echo yes || echo no)"
check 'the card of #182 moved'     1 "$(grep -c 'oid=OPT_test' "$log" || true)"

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
check 'a package worktree holding a later issue stays' yes "$(grep -q 'issue-177-package: named for another issue, holds issue-182-a-later-part, stays' <<< "$out" && echo yes || echo no)"

echo 'a repository on no board: the landed worktree goes, no card is looked for, and the issue is told'
open issue-167-keep-the-harness-off-the-board
land issue-167-keep-the-harness-off-the-board 'Keep the harness off the board (#167)'
touch "$fake/no-board"; : > "$log"; rm -rf "$fake/cache"
out="$(cd "$work" && GH_PROJECT_NUMBER='' bash "$finish" 167 2>&1)"; rc=$?
check 'exits zero'             0 "$rc"
check 'the worktree is gone'   no "$(has_tree issue-167-keep-the-harness-off-the-board)"
check 'it says so'             yes "$(grep -q '^example-org/example-repo is on no board - there is no card to move$' <<< "$out" && echo yes || echo no)"
check 'no card was moved'      0 "$(grep -c 'oid=OPT_' "$log" || true)"
check 'and no card is swept'   0 "$(grep -c 'issues(states:OPEN' "$log" || true)"
check 'the issue was told'     yes "$(grep -q 'issue comment 167 .*Landed on master:.*Keep the harness off the board (#167)' <<< "$(tr '\n' ' ' < "$log")" && echo yes || echo no)"
rm -f "$fake/no-board"

# The issue lives in other-org/tracker and its work landed here: start-issue recorded that on the
# branch, so the issue is read, its board asked and its comment posted there, never here.
echo 'an issue of another repository: read, asked and told there, from the record on its branch'
open issue-169-alert-on-a-stuck-run
git -C "$work" config branch.issue-169-alert-on-a-stuck-run.issueRepository other-org/tracker
land issue-169-alert-on-a-stuck-run 'Alert on a stuck run (other-org/tracker#169)'
touch "$fake/no-board"; : > "$log"; rm -rf "$fake/cache"
out="$(cd "$work" && GH_PROJECT_NUMBER='' bash "$finish" 169 2>&1)"; rc=$?
check 'exits zero'             0 "$rc"
check 'the worktree is gone'   no "$(has_tree issue-169-alert-on-a-stuck-run)"
check 'the record went with the branch' '' "$(git -C "$work" config --get branch.issue-169-alert-on-a-stuck-run.issueRepository || true)"
check 'the issue was read there' yes "$(grep -q 'other-org/tracker/issues/169' "$log" && echo yes || echo no)"
check 'its board was asked'    yes "$(grep -q '^other-org/tracker is on no board - there is no card to move$' <<< "$out" && echo yes || echo no)"
check 'the issue was told there' yes "$(grep -q 'issue comment 169 --repo other-org/tracker .*Landed on master of example-org/example-repo:.*(other-org/tracker#169)' <<< "$(tr '\n' ' ' < "$log")" && echo yes || echo no)"

echo 'this repository'"'"'s own issue of the same number is not told of the other one'"'"'s commit'
open issue-169-own-fix
land issue-169-own-fix 'Own fix (#169)'
: > "$log"; rm -rf "$fake/cache"
out="$(cd "$work" && GH_PROJECT_NUMBER='' bash "$finish" 169 2>&1)"; rc=$?
check 'exits zero'             0 "$rc"
check 'its own commit is named' yes "$(grep -q 'issue comment 169 --repo example-org/example-repo .*Landed on master:.*Own fix (#169)' <<< "$(tr '\n' ' ' < "$log")" && echo yes || echo no)"
check 'the other one is not'   no "$(grep -q 'other-org/tracker#169' <<< "$(tr '\n' ' ' < "$log")" && echo yes || echo no)"

echo 'a branch that outlived its worktree still says where its issue lives'
git -C "$work" branch -q issue-175-gone origin/master
git -C "$work" config branch.issue-175-gone.issueRepository other-org/tracker
: > "$log"; rm -rf "$fake/cache"
out="$(cd "$work" && GH_PROJECT_NUMBER='' bash "$finish" 175 2>&1)"; rc=$?
check 'the issue was read there' yes "$(grep -q 'other-org/tracker/issues/175' "$log" && echo yes || echo no)"
check 'and never here'         0 "$(grep -c 'example-org/example-repo/issues/175' "$log" || true)"
check 'no commit names it, so it is refused under its own name' \
  'error: no commit on origin/master names other-org/tracker#175, so the card stays and the issue is not told; a commit that touches an issue names it' \
  "$(grep '^error: ' <<< "$out")"
git -C "$work" branch -q -D issue-175-gone
rm -f "$fake/no-board"

echo 'an issue no commit on the default branch names has not landed: refused, no card moves, no word on the issue'
: > "$log"; rm -rf "$fake/cache"
out="$(run 177)"; rc=$?
check 'exit 1'                 1 "$rc"
check 'it says why'            'error: no commit on origin/master names #177, so the card stays and the issue is not told; a commit that touches an issue names it' "$(grep '^error: ' <<< "$out")"
check 'no card moved'          0 "$(grep -c 'oid=OPT_' "$log" || true)"
check 'the issue was not told' 0 "$(grep -c 'issue comment 177' "$log" || true)"
check 'no card is swept'       0 "$(grep -c 'issues(states:OPEN' "$log" || true)"

echo 'an origin/HEAD naming a branch the remote no longer has: the default branch is asked of the remote'
open issue-168-read-the-default-branch
land issue-168-read-the-default-branch 'Read the default branch from the remote (#168)'
git -C "$work" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/gone
out="$(run 168)"; rc=$?
check 'exits zero'             0 "$rc"
check 'the worktree is gone'   no "$(has_tree issue-168-read-the-default-branch)"
git -C "$work" remote set-head origin -a >/dev/null

echo 'a branch that landed by cherry-pick goes without a flag'
open issue-173-landed-by-cherry-pick
echo 'picked' >> "$trees/issue-173-landed-by-cherry-pick/README.md"
git -C "$trees/issue-173-landed-by-cherry-pick" commit -q -am 'Land by cherry-pick (#173)'
git -C "$work" pull -q --ff-only origin master
git -C "$work" cherry-pick "$(git -C "$trees/issue-173-landed-by-cherry-pick" rev-parse HEAD)" >/dev/null
git -C "$work" push -q origin master
out="$(run 173)"; rc=$?
check 'exits zero'             0 "$rc"
check 'the worktree is gone'   no "$(has_tree issue-173-landed-by-cherry-pick)"

echo 'a branch whose change landed in another shape stays, and names --landed'
open issue-174-landed-changed
echo 'mine' >> "$trees/issue-174-landed-changed/README.md"
git -C "$trees/issue-174-landed-changed" commit -q -am 'Land in another shape (#174)'
echo 'mine, as the conflict was resolved' >> "$work/README.md"
git -C "$work" commit -q -am 'Land in another shape, resolved (#174)'
git -C "$work" push -q origin master
out="$(run 174)"; rc=$?
check 'exits nonzero'          yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'it names --landed'      yes "$(grep -q 'run finish-issue 174 --landed once the issue is closed' <<< "$out" && echo yes || echo no)"
check 'the worktree stays'     yes "$(has_tree issue-174-landed-changed)"
echo '--landed on an open issue is refused'
out="$(run 174 --landed)"; rc=$?
check 'exits nonzero'          yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'it says the issue is open' yes "$(grep -q -- '--landed removes the work of a closed issue only, and #174 is open' <<< "$out" && echo yes || echo no)"
check 'the worktree stays'     yes "$(has_tree issue-174-landed-changed)"
echo '--landed on a closed issue removes the worktree and names the commit it did not find'
echo closed > "$state"
out="$(run 174 --landed)"; rc=$?
check 'exits zero'             0 "$rc"
check 'the worktree is gone'   no "$(has_tree issue-174-landed-changed)"
check 'it names the commit'    yes "$(grep -q '^  [0-9a-f]* Land in another shape (#174)$' <<< "$out" && echo yes || echo no)"
echo open > "$state"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
