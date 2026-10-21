#!/usr/bin/env bash
# What finish-issue.sh removes, what it refuses, where it moves the card, and what --sweep leaves.
#
# It runs inside a TEMPORARY repository with a temporary origin, both built and deleted here, and
# with a FAKE gh on PATH: nothing leaves the machine. What is pinned: a worktree with changes or
# with work origin does not have stays and is named; a landed one goes with its branch; the card
# moves to testing where the board has one; the issue is told what landed; --sweep removes only a
# landed worktree that was committed in and has rested for a day.
#
#   bash test/finish-issue.test.sh

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fake="$(mktemp -d)"
export GH_CACHE_DIRECTORY="$fake/cache"
export GH_PROJECT_NUMBER=999982
trap 'rm -rf "$fake"' EXIT
export AI_CORE_SLEEP=true   # the waits of a refused call take no time here
log="$fake/calls.txt"
board="$fake/board.tsv"
state="$fake/state.txt"

cat > "$fake/gh" <<EOF
#!/usr/bin/env bash
a="\$*"
printf '%s\n' "\$a" >> "$log"
if [ -e "$fake/refuse-once" ] && [[ "\$a" == *"issues/163"* ]] && [[ "\$a" != *"comments"* ]]; then
  rm -f "$fake/refuse-once"
  echo '{"message":"API rate limit already exceeded for user ID 1."}'
  echo 'gh: API rate limit already exceeded for user ID 1. (HTTP 403)' >&2
  exit 1
fi
# The comments of an issue are kept in a file of their own, as the tracker keeps them: a comment posted by one
# run is read by the next, "$fake/page-size" cuts a read into pages of that many comments, and a comment
# planted by plant_comment carries the author association the test names
path=""; text=""
for x in "\$@"; do case "\$x" in repos/*/issues/*/comments) path="\$x" ;; body=*) text="\${x#body=}" ;; esac; done
store="$fake/comments/\$(printf '%s' "\$path" | tr '/' '_').json"
case "\$a" in
  # like gh, which reads the repository of the directory it runs in and finds none in a removed one
  *"repo view"*|"api repos/{owner}/{repo} --jq .full_name"*)            [ -d "\$PWD" ] || { echo 'failed to determine the repository' >&2; exit 1; }; echo 'example-org/example-repo' ;;
  *"/comments -f body="*)
    mkdir -p "$fake/comments"; [ -s "\$store" ] || echo '[]' > "\$store"
    jq --arg b "\$text" '. + [{user: {login: "tester"}, author_association: "OWNER", body: \$b,
      created_at: ("2026-10-21T10:" + (length | tostring | if length < 2 then "0" + . else . end) + ":00Z")}]' "\$store" > "\$store.new" && mv "\$store.new" "\$store"
    echo 'https://example.invalid/example-org/example-repo/issues/163#issuecomment-1' ;;
  # status-sync's query of the repository's issues names comments and projectItems too
  *"issues(states:OPEN"*)   [ -e "$fake/issues-down" ] && { echo 'the issues are down' >&2; exit 1; }; echo '{"data":{"repository":{"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}' ;;
  # the last reopening of one issue, as --jq prints it
  *REOPENED_EVENT*)         [ -e "$fake/reopened-down" ] && { echo 'the timeline is down' >&2; exit 1; }; cat "$fake/reopened-at" 2>/dev/null || echo null ;;
  *comments*)               if [ -s "\$store" ]; then jq -c --argjson s "\$(cat "$fake/page-size" 2>/dev/null || echo 1000)" '[range(0; length; \$s) as \$i | .[\$i:\$i + \$s]] | .[]' "\$store"; else echo '[]'; fi ;;
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
# check_runs <rc>: exit zero, and where it is not, what finish-issue said, which is the reason
check_runs() { check 'exits zero' 0 "$1"; [ "$1" = 0 ] || sed 's/^/       said:     /' <<< "$out"; }
# setup <command>...: a step that arranges a case. Where it fails the run is red and says which step and why;
# a step that fails unseen leaves the case testing something other than what it names
setup() {
  local said
  said="$("$@" 2>&1)" && return 0
  echo "  FAIL setup: $*"; sed 's/^/       said:     /' <<< "$said"; failed=$((failed + 1))
}
dress() {
  git -C "$1" config user.email 'test@example.invalid'
  git -C "$1" config user.name 'test'
  git -C "$1" config commit.gpgsign false
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
open() { setup git -C "$work" worktree add -q -b "$1" "$trees/$1" origin/master; dress "$trees/$1"; }
# land <branch> <message> [date]: a commit in the worktree, pushed to master
land() {
  echo "$2" >> "$trees/$1/README.md"
  setup git -C "$trees/$1" add -A
  GIT_AUTHOR_DATE="${3:-}" GIT_COMMITTER_DATE="${3:-}" setup git -C "$trees/$1" commit -q -m "$2"
  setup git -C "$trees/$1" push -q origin HEAD:master
  setup git -C "$work" pull -q --ff-only origin master
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

echo 'a landed worktree goes with its branch, the card moves to testing, and the issue says what landed, the read of the issue refused once on the way'
git -C "$trees/issue-163-read-the-board-whole" push -q origin HEAD:master
: > "$log"; rm -rf "$fake/cache"; touch "$fake/refuse-once"
out="$(run 163)"; rc=$?
check_runs "$rc"
check 'the refusal was met and waited for' 1 "$(grep -c "^waiting 60s for GitHub's secondary rate limit" <<< "$out" || true)"
check 'the worktree is gone'  no "$(has_tree issue-163-read-the-board-whole)"
check 'the branch is gone'    no "$(has_branch issue-163-read-the-board-whole)"
check 'the card moved to testing' 1 "$(grep -c 'oid=OPT_test' "$log" || true)"
check 'the issue was told'    yes "$(grep -q 'issues/163/comments -f body=Landed on master:.*Not pushed yet (#163)' <<< "$(tr '\n' ' ' < "$log")" && echo yes || echo no)"
check 'the board is not read whole' 0 "$(grep -c 'items(first:100, after:' "$log" || true)"
check 'the cards of its repository are swept, in one query (status-sync)' 1 "$(grep -c 'issues(states:OPEN' "$log" || true)"

echo 'a status-sync that fails is said, and finish-issue still completes'
touch "$fake/issues-down"; : > "$log"; rm -rf "$fake/cache"
out="$(run 163)"; rc=$?
check_runs "$rc"
check 'it says so'            yes "$(grep -q '^status-sync did NOT run for example-org/example-repo: ' <<< "$out" && echo yes || echo no)"
rm -f "$fake/issues-down"

echo 'run inside the worktree it removes, it goes on from the main checkout and still moves the card'
open issue-170-run-from-inside
land issue-170-run-from-inside 'Run from inside (#170)'
: > "$log"; rm -rf "$fake/cache"
out="$(cd "$trees/issue-170-run-from-inside" && bash "$finish" 170 2>&1)"; rc=$?
check_runs "$rc"
check 'the worktree is gone'  no "$(has_tree issue-170-run-from-inside)"
check 'the card moved to testing' 1 "$(grep -c 'oid=OPT_test' "$log" || true)"

echo "a package worktree, named for its first issue, stays when a later issue's branch in it is finished"
open issue-177-package
git -C "$trees/issue-177-package" checkout -q -b issue-182-a-later-part origin/master
land issue-177-package 'A later part (#182)'
: > "$log"; rm -rf "$fake/cache"
out="$(cd "$trees/issue-177-package" && bash "$finish" 182 2>&1)"; rc=$?
check_runs "$rc"
check 'the package worktree stays' yes "$(has_tree issue-177-package)"
check 'and the branch in it'       yes "$(has_branch issue-182-a-later-part)"
check 'it says why'                yes "$(grep -q 'issue-177-package is named for another issue and has issue-182-a-later-part checked out: it stays' <<< "$out" && echo yes || echo no)"
check 'the card of #182 moved'     1 "$(grep -c 'oid=OPT_test' "$log" || true)"

echo 'a board without a testing column: the card stays'
printf 'Status\tFID\ttodo\tOPT_todo\nStatus\tFID\timplementing\tOPT_impl\nStatus\tFID\tdone\tOPT_done\n' > "$board"
: > "$log"; rm -rf "$fake/cache"
out="$(run 163)"; rc=$?
check_runs "$rc"
check 'it says so'          yes "$(grep -q 'the board has no testing column - the card stays' <<< "$out" && echo yes || echo no)"
check 'the card did not move' 0 "$(grep -c 'oid=OPT_' "$log" || true)"

# The run above cached the board without testing; the board gains it, and the cache stays
echo 'a cache written before the board gained testing: the board is read again and the card moves'
printf 'Status\tFID\ttodo\tOPT_todo\nStatus\tFID\timplementing\tOPT_impl\nStatus\tFID\ttesting\tOPT_test\nStatus\tFID\tdone\tOPT_done\n' > "$board"
: > "$log"
out="$(run 163)"; rc=$?
check_runs "$rc"
check 'the card moved to testing' 1 "$(grep -c 'oid=OPT_test' "$log" || true)"

echo 'a board with ready, planned and review: the card goes to testing, never to the column after implementing'
printf 'Status\tFID\tready\tOPT_ready\nStatus\tFID\tplanned\tOPT_plan\nStatus\tFID\timplementing\tOPT_impl\nStatus\tFID\treview\tOPT_rev\nStatus\tFID\ttesting\tOPT_test\nStatus\tFID\tdone\tOPT_done\n' > "$board"
: > "$log"; rm -rf "$fake/cache"
out="$(run 163)"; rc=$?
check_runs "$rc"
check 'the card went to testing' 1 "$(grep -c 'oid=OPT_test' "$log" || true)"
check 'not to review'       0 "$(grep -c 'oid=OPT_rev' "$log" || true)"

echo 'a closed issue keeps its card'
echo closed > "$state"; : > "$log"; rm -rf "$fake/cache"
out="$(run 163)"; rc=$?
check_runs "$rc"
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
check_runs "$rc"
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
check_runs "$rc"
check 'the worktree is gone'   no "$(has_tree issue-167-keep-the-harness-off-the-board)"
check 'it says so'             yes "$(grep -q '^example-org/example-repo is on no board - there is no card to move$' <<< "$out" && echo yes || echo no)"
check 'no card was moved'      0 "$(grep -c 'oid=OPT_' "$log" || true)"
check 'and no card is swept'   0 "$(grep -c 'issues(states:OPEN' "$log" || true)"
check 'the issue was told'     yes "$(grep -q 'issues/167/comments -f body=Landed on master:.*Keep the harness off the board (#167)' <<< "$(tr '\n' ' ' < "$log")" && echo yes || echo no)"
rm -f "$fake/no-board"

# The issue lives in other-org/tracker and its work landed here: start-issue recorded that on the
# branch, so the issue is read, its board asked and its comment posted there, never here.
echo 'an issue of another repository: read, asked and told there, from the record on its branch'
open issue-169-alert-on-a-stuck-run
git -C "$work" config branch.issue-169-alert-on-a-stuck-run.issueRepository other-org/tracker
land issue-169-alert-on-a-stuck-run 'Alert on a stuck run (other-org/tracker#169)'
touch "$fake/no-board"; : > "$log"; rm -rf "$fake/cache"
out="$(cd "$work" && GH_PROJECT_NUMBER='' bash "$finish" 169 2>&1)"; rc=$?
check_runs "$rc"
check 'the worktree is gone'   no "$(has_tree issue-169-alert-on-a-stuck-run)"
check 'the record went with the branch' '' "$(git -C "$work" config --get branch.issue-169-alert-on-a-stuck-run.issueRepository || true)"
check 'the issue was read there' yes "$(grep -q 'other-org/tracker/issues/169' "$log" && echo yes || echo no)"
check 'its board was asked'    yes "$(grep -q '^other-org/tracker is on no board - there is no card to move$' <<< "$out" && echo yes || echo no)"
check 'the issue was told there' yes "$(grep -q 'other-org/tracker/issues/169/comments -f body=Landed on master of example-org/example-repo:.*(other-org/tracker#169)' <<< "$(tr '\n' ' ' < "$log")" && echo yes || echo no)"

echo 'this repository'"'"'s own issue of the same number is not told of the other one'"'"'s commit'
open issue-169-own-fix
land issue-169-own-fix 'Own fix (#169)'
: > "$log"; rm -rf "$fake/cache"
out="$(cd "$work" && GH_PROJECT_NUMBER='' bash "$finish" 169 2>&1)"; rc=$?
check_runs "$rc"
check 'its own commit is named' yes "$(grep -q 'example-org/example-repo/issues/169/comments -f body=Landed on master:.*Own fix (#169)' <<< "$(tr '\n' ' ' < "$log")" && echo yes || echo no)"
check 'the other one is not'   no "$(grep -q 'other-org/tracker#169' <<< "$(tr '\n' ' ' < "$log")" && echo yes || echo no)"

echo 'an issue of another repository on a board: the cards of both repositories are swept, in one run'
open issue-179-sweep-both-repositories
git -C "$work" config branch.issue-179-sweep-both-repositories.issueRepository other-org/tracker
land issue-179-sweep-both-repositories 'Sweep both repositories (other-org/tracker#179)'
: > "$log"; rm -rf "$fake/cache"
out="$(run 179)"; rc=$?
check_runs "$rc"
# a query of one repository's open issues: its first line names the repository, its third the issues
swept() { grep -A2 -F "graphql -f o=$1 -f n=$2 -f query=" "$log" | grep -c 'issues(states:OPEN' || true; }
check 'the cards of this repository are swept' 1 "$(swept example-org example-repo)"
check 'and the issue'"'"'s'      1 "$(swept other-org tracker)"

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
check 'the issue was not told' 0 "$(grep -c 'issues/177/comments -f body=' "$log" || true)"
check 'no card is swept'       0 "$(grep -c 'issues(states:OPEN' "$log" || true)"

# A commit may name its issue written out, the way an integration of two issues names the second one
# in a body. The own repository written out names the issue; another repository's never does.
echo 'a commit that names the issue as <owner>/<repo>#<n> of its own repository has landed it'
open issue-178-name-it-in-full
land issue-178-name-it-in-full 'Land the work of another issue (#179)

Carries Example-Org/example-repo#178 as well.'
out="$(run 178)"; rc=$?
check_runs "$rc"
check 'the worktree is gone'      no "$(has_tree issue-178-name-it-in-full)"

echo 'a commit that names only <other owner>/<other repo>#<n> has not landed this issue'
: > "$log"
open issue-180-another-repository
land issue-180-another-repository 'Land the work (#179)

Carries other-org/other-repo#180, an issue over there.'
out="$(run 180)"; rc=$?
check 'exit 1'                    1 "$rc"
check 'it says why'               'error: no commit on origin/master names #180, so the card stays and the issue is not told; a commit that touches an issue names it' "$(grep '^error: ' <<< "$out")"
check 'no card moved'             0 "$(grep -c 'oid=OPT_' "$log" || true)"

# A package gives an issue a worktree in each repository it touches, and the work often lands in one.
# The other worktrees were cut and never committed in: they hold nothing, and nothing names the issue.
echo 'a worktree that was never committed in, and an issue no commit names: removed, said, and nothing else is touched'
open issue-181-never-committed
: > "$log"; rm -rf "$fake/cache"
out="$(run 181)"; rc=$?
check_runs "$rc"
check 'the worktree is gone'        no "$(has_tree issue-181-never-committed)"
check 'the branch is gone'          no "$(has_branch issue-181-never-committed)"
check 'it says this repository holds no work of the issue' yes "$(grep -q '^example-org/example-repo holds no work of #181: ' <<< "$out" && echo yes || echo no)"
check 'it says why the worktree went' yes "$(grep -q 'removed: it was never committed in\.' <<< "$out" && echo yes || echo no)"
check 'it claims no landing'        0 "$(grep -c 'its work is on origin' <<< "$out" || true)"
check 'it says nothing of a fault'  0 "$(grep -c '^error: ' <<< "$out" || true)"
check 'no card moved'               0 "$(grep -c 'oid=OPT_' "$log" || true)"
check 'the issue was not told'      0 "$(grep -c 'issues/181/comments -f body=' "$log" || true)"
check 'no card is swept'            0 "$(grep -c 'issues(states:OPEN' "$log" || true)"
check 'nothing was written at all'  0 "$(grep -cE 'method (POST|PATCH|PUT|DELETE)|mutation|-f body=' "$log" || true)"

echo 'a worktree that was never committed in, with changes, stays'
open issue-184-empty-with-changes
echo 'unsaved' >> "$trees/issue-184-empty-with-changes/README.md"
out="$(run 184)"; rc=$?
check 'exits nonzero'               yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'it says which'               yes "$(grep -q 'issue-184-empty-with-changes has changes' <<< "$out" && echo yes || echo no)"
check 'the worktree stays'          yes "$(has_tree issue-184-empty-with-changes)"
check 'and the branch'              yes "$(has_branch issue-184-empty-with-changes)"

echo "a package worktree's later branch that was never committed in stays with its worktree, and no commit names it: refused"
open issue-185-package
git -C "$trees/issue-185-package" checkout -q -b issue-186-a-later-part origin/master
out="$(cd "$trees/issue-185-package" && bash "$finish" 186 2>&1)"; rc=$?
check 'exit 1'                      1 "$rc"
check 'it says why'                 yes "$(grep -q 'issue-185-package is named for another issue and has issue-186-a-later-part checked out: it stays' <<< "$out" && echo yes || echo no)"
check 'and that no commit names it' 'error: no commit on origin/master names #186, so the card stays and the issue is not told; a commit that touches an issue names it' "$(grep '^error: ' <<< "$out")"
check 'the package worktree stays'  yes "$(has_tree issue-185-package)"
check 'and the branch in it'        yes "$(has_branch issue-186-a-later-part)"

echo 'a branch that was committed in, with all its commits on origin and none naming the issue: refused as before'
open issue-187-worked-in
land issue-187-worked-in 'A change that names no issue'
out="$(run 187)"; rc=$?
check 'exit 1'                      1 "$rc"
check 'it says why'                 'error: no commit on origin/master names #187, so the card stays and the issue is not told; a commit that touches an issue names it' "$(grep '^error: ' <<< "$out")"
check 'it does not say the repository holds no work' 0 "$(grep -c 'holds no work of' <<< "$out" || true)"

echo 'an origin/HEAD naming a branch the remote no longer has: the default branch is asked of the remote'
open issue-168-read-the-default-branch
land issue-168-read-the-default-branch 'Read the default branch from the remote (#168)'
git -C "$work" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/gone
out="$(run 168)"; rc=$?
check_runs "$rc"
check 'the worktree is gone'   no "$(has_tree issue-168-read-the-default-branch)"
git -C "$work" remote set-head origin -a >/dev/null

echo 'a branch that landed by cherry-pick goes without a flag'
open issue-173-landed-by-cherry-pick
echo 'picked' >> "$trees/issue-173-landed-by-cherry-pick/README.md"
setup git -C "$trees/issue-173-landed-by-cherry-pick" commit -q -am 'Land by cherry-pick (#173)'
check 'the worktree holds the commit to pick' 1 "$(git -C "$trees/issue-173-landed-by-cherry-pick" rev-list --count origin/master..HEAD)"
setup git -C "$work" pull -q --ff-only origin master
setup git -C "$work" cherry-pick "$(git -C "$trees/issue-173-landed-by-cherry-pick" rev-parse HEAD)"
setup git -C "$work" push -q origin master
out="$(run 173)"; rc=$?
check_runs "$rc"
check 'the worktree is gone'   no "$(has_tree issue-173-landed-by-cherry-pick)"
check 'it went as landed work, not as an empty worktree' yes "$(grep -q 'removed: its work is on origin/master\.' <<< "$out" && echo yes || echo no)"

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
check_runs "$rc"
check 'the worktree is gone'   no "$(has_tree issue-174-landed-changed)"
check 'it names the commit'    yes "$(grep -q '^  [0-9a-f]* Land in another shape (#174)$' <<< "$out" && echo yes || echo no)"
echo open > "$state"

echo "a landed issue's merged branch on origin is deleted; one with more work, and one a worktree holds, stay"
open issue-190-merged-on-origin
land issue-190-merged-on-origin 'Land the merged one (#190)'
git -C "$trees/issue-190-merged-on-origin" push -q origin HEAD:issue-190-merged-on-origin
unlanded="$(git -C "$work" commit-tree -p origin/master -m 'Not landed (#190)' 'origin/master^{tree}')"
git -C "$work" push -q origin "$unlanded:refs/heads/issue-190-more-work"
git -C "$work" worktree add -q -b issue-190-held "$trees/issue-191-package" origin/master 2>/dev/null
git -C "$work" push -q origin issue-190-held
on_origin() { git -C "$origin" rev-parse -q --verify "refs/heads/$1" >/dev/null && echo yes || echo no; }
out="$(run 190)"; rc=$?
check_runs "$rc"
check 'the merged branch on origin is gone' no "$(on_origin issue-190-merged-on-origin)"
check 'the branch with more work stays'     yes "$(on_origin issue-190-more-work)"
check 'and says why'                        yes "$(grep -q 'issue-190-more-work on origin stays: it has commits whose change is not on origin/master' <<< "$out" && echo yes || echo no)"
check 'the branch a worktree holds stays'   yes "$(on_origin issue-190-held)"
check 'and says why'                        yes "$(grep -q 'issue-190-held on origin stays: a worktree has it checked out' <<< "$out" && echo yes || echo no)"

echo 'a branch on origin that is gone already is named, and the card still moves'
open issue-192-gone-on-origin
land issue-192-gone-on-origin 'Land the one origin lost (#192)'
git -C "$trees/issue-192-gone-on-origin" push -q origin HEAD:issue-192-gone-on-origin
git -C "$origin" update-ref -d refs/heads/issue-192-gone-on-origin
git -C "$work" config remote.origin.fetch '+refs/heads/master:refs/remotes/origin/master'
: > "$log"; rm -rf "$fake/cache"
out="$(run 192)"; rc=$?
git -C "$work" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
check_runs "$rc"
check 'it names the branch'                 yes "$(grep -q 'issue-192-gone-on-origin on origin could not be deleted and stays' <<< "$out" && echo yes || echo no)"
check 'the card moved to testing'           1 "$(grep -c 'oid=OPT_test' "$log" || true)"

echo 'a branch somebody pushed to after it was read stays on origin'
open issue-193-moved-on-origin
land issue-193-moved-on-origin 'Land the one that moves (#193)'
git -C "$trees/issue-193-moved-on-origin" push -q origin HEAD:issue-193-moved-on-origin
git -C "$work" config remote.origin.fetch '+refs/heads/master:refs/remotes/origin/master'
later="$(git -C "$work" commit-tree -p origin/issue-193-moved-on-origin -m 'Pushed later (#193)' 'origin/master^{tree}')"
git -C "$work" push -q origin "$later:refs/heads/issue-193-moved-on-origin"
out="$(run 193)"; rc=$?
git -C "$work" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
check_runs "$rc"
check 'the moved branch stays on origin'    yes "$(on_origin issue-193-moved-on-origin)"
check 'with the later commit'               "$later" "$(git -C "$origin" rev-parse refs/heads/issue-193-moved-on-origin)"

echo 'a branch on origin that landed by rebase is deleted; one whose change landed reshaped stays'
git -C "$work" pull -q --ff-only origin master
git -C "$work" checkout -q -b issue-194-rebased origin/master
echo 'rebased' > "$work/rebased.txt"
git -C "$work" add rebased.txt && git -C "$work" commit -q -m 'Land by rebase (#194)'
git -C "$work" push -q origin issue-194-rebased
git -C "$work" checkout -q -b issue-194-reshaped origin/master
echo 'reshaped' > "$work/reshaped.txt"
git -C "$work" add reshaped.txt && git -C "$work" commit -q -m 'Land reshaped (#194)'
git -C "$work" push -q origin issue-194-reshaped
git -C "$work" checkout -q master
# another landing first, so the rebased commit gets a new sha on master
echo 'landed first' >> "$work/README.md"
git -C "$work" commit -q -am 'Another landing first'
git -C "$work" cherry-pick issue-194-rebased >/dev/null
echo 'reshaped, as the conflict was resolved' > "$work/reshaped.txt"
git -C "$work" add reshaped.txt && git -C "$work" commit -q -m 'Land reshaped, resolved (#194)'
git -C "$work" push -q origin master
git -C "$work" branch -q -D issue-194-rebased issue-194-reshaped
check 'the rebased branch is no ancestor'   no "$(git -C "$work" merge-base --is-ancestor origin/issue-194-rebased origin/master && echo yes || echo no)"
out="$(run 194)"; rc=$?
check_runs "$rc"
check 'the rebased branch on origin is gone' no "$(on_origin issue-194-rebased)"
check 'and says so'                         yes "$(grep -q 'issue-194-rebased on origin deleted: the change of every commit of it is on origin/master' <<< "$out" && echo yes || echo no)"
check 'the reshaped branch stays'           yes "$(on_origin issue-194-reshaped)"
check 'and says why'                        yes "$(grep -q 'issue-194-reshaped on origin stays: it has commits whose change is not on origin/master' <<< "$out" && echo yes || echo no)"

echo 'a branch on origin whose merge commit carries its own content stays'
git -C "$work" pull -q --ff-only origin master
git -C "$work" checkout -q -b issue-195-side origin/master
echo 'side' > "$work/side.txt"
git -C "$work" add side.txt && git -C "$work" commit -q -m 'Land the merged side (#195)'
git -C "$work" checkout -q -b issue-195-merged origin/master
git -C "$work" merge -q --no-ff --no-commit issue-195-side >/dev/null 2>&1
echo 'only in the merge' > "$work/merge-only.txt"
git -C "$work" add merge-only.txt && git -C "$work" commit -q -m 'Merge the side, with content of its own (#195)'
git -C "$work" push -q origin issue-195-merged
git -C "$work" checkout -q master
git -C "$work" cherry-pick issue-195-side >/dev/null
git -C "$work" push -q origin master
git -C "$work" branch -q -D issue-195-side issue-195-merged
out="$(run 195)"; rc=$?
check_runs "$rc"
check 'the merged branch stays on origin'   yes "$(on_origin issue-195-merged)"
check 'and says why'                        yes "$(grep -q 'issue-195-merged on origin stays: it has commits whose change is not on origin/master' <<< "$out" && echo yes || echo no)"

# --- the issue is told once what landed ---------------------------------------------------------
#
# The comments of an issue stay in the stand-in, so what one run writes the next one reads. A run lists
# the commits of the default branch that name the issue, and an issue that holds ONE record of the landing
# in this repository listing all of them, written by the repository's owner, a member or a collaborator,
# is not told again. Of an open issue that record must also stand after its last reopening and within the
# last 50 comments, the ones status-sync reads, or it would not serve the card. A closed issue has no proof
# pending, so any such record of it serves.
comments_file() { echo "$fake/comments/$(printf '%s' "repos/$1/issues/$2/comments" | tr '/' '_').json"; }
# plant_comment <repo> <number> <author association> <time> <body>: a comment the issue holds already
plant_comment() {
  local f; f="$(comments_file "$1" "$2")"; mkdir -p "$fake/comments"; [ -s "$f" ] || echo '[]' > "$f"
  jq --arg a "$3" --arg t "$4" --arg b "$5" '. + [{user: {login: "somebody"}, author_association: $a, body: $b, created_at: $t}]' "$f" > "$f.new" && mv "$f.new" "$f"
}
landings_of() { jq '[.[] | select(.body | startswith("Landed on "))] | length' "$(comments_file example-org/example-repo "$1")" 2>/dev/null || echo 0; }
last_landing_of() { jq -r '[.[] | select(.body | startswith("Landed on "))] | last | .body' "$(comments_file example-org/example-repo "$1")"; }
commits_of() { git -C "$work" log origin/master -E -i --grep="(^|[^A-Za-z0-9._/-])#$1([^0-9]|$)" --format='- %h %s' -n 20; }
posted() { grep -c 'comments -f body=' "$log" || true; }
holds_already() { grep -q '^the issue holds this record already - nothing added$' <<< "$out" && echo yes || echo no; }
repo=example-org/example-repo

echo 'an issue is told what landed once: finishing it again adds no copy'
open issue-301-tell-once
land issue-301-tell-once 'Tell once (#301)'
: > "$log"; rm -rf "$fake/cache"
out="$(run 301)"; rc=$?
check_runs "$rc"
check 'the first run tells the issue'   1 "$(landings_of 301)"
check 'and says so'                     yes "$(grep -q '^the issue says what landed$' <<< "$out" && echo yes || echo no)"
: > "$log"; rm -rf "$fake/cache"
out="$(run 301)"; rc=$?
check_runs "$rc"
check 'the second run leaves one record' 1 "$(landings_of 301)"
check 'it posts nothing'                 0 "$(posted)"
check 'and says the issue holds it'      yes "$(holds_already)"

echo 'a commit the record does not list is told as the full record, as today'
open issue-301-more
land issue-301-more 'Tell once, the rest (#301)'
: > "$log"; rm -rf "$fake/cache"
out="$(run 301)"; rc=$?
check_runs "$rc"
check 'a second record'                  2 "$(landings_of 301)"
check 'it lists every commit'            "Landed on master:

$(commits_of 301)" "$(last_landing_of 301)"
check 'it lists both'                    2 "$(grep -c '(#301)$' <<< "$(last_landing_of 301)" || true)"
: > "$log"; rm -rf "$fake/cache"
out="$(run 301)"; rc=$?
check 'and that covers the next run'     2 "$(landings_of 301)"

echo 'a closed issue is not told again, and one with no record yet is told once'
echo closed > "$state"
out="$(run 301)"; rc=$?
check_runs "$rc"
check 'no copy on the closed issue'      2 "$(landings_of 301)"
check 'it says the issue holds it'       yes "$(holds_already)"
open issue-302-closed-first
land issue-302-closed-first 'Closed first (#302)'
out="$(run 302)"; rc=$?
check_runs "$rc"
check 'the closed issue gets its record' 1 "$(landings_of 302)"
out="$(run 302)"; rc=$?
check 'and keeps one'                    1 "$(landings_of 302)"
echo open > "$state"

echo 'a record that lists more commits than this run covers it'
open issue-303-superset
land issue-303-superset 'Superset (#303)'
plant_comment $repo 303 OWNER 2026-10-21T09:00:00Z "Landed on master:

$(commits_of 303)
- 0123abc An older step (#303)"
out="$(run 303)"; rc=$?
check_runs "$rc"
check 'nothing is added'                 1 "$(landings_of 303)"
check 'it says the issue holds it'       yes "$(holds_already)"

echo 'a record of the landing in another repository covers nothing here'
open issue-304-elsewhere
land issue-304-elsewhere 'Elsewhere (#304)'
plant_comment $repo 304 OWNER 2026-10-21T09:00:00Z "Landed on master of other-org/other-repo:

$(commits_of 304)"
out="$(run 304)"; rc=$?
check_runs "$rc"
check 'this landing is told too'         2 "$(landings_of 304)"
out="$(run 304)"; rc=$?
check 'and then covers the next run'     2 "$(landings_of 304)"

echo 'a record on a later page of the comments is found'
open issue-305-paged
land issue-305-paged 'Paged (#305)'
plant_comment $repo 305 OWNER 2026-10-21T09:00:00Z "Landed on master:

$(commits_of 305)"
for t in 01 02 03; do plant_comment $repo 305 OWNER "2026-10-21T09:$t:00Z" "talk $t"; done
echo 1 > "$fake/page-size"
out="$(run 305)"; rc=$?
rm -f "$fake/page-size"
check_runs "$rc"
check 'nothing is added'                 1 "$(landings_of 305)"
check 'it says the issue holds it'       yes "$(holds_already)"

echo 'an open issue reopened after its record is told again; a closed one is not'
open issue-306-reopened
land issue-306-reopened 'Reopened (#306)'
plant_comment $repo 306 OWNER 2026-10-21T09:00:00Z "Landed on master:

$(commits_of 306)"
echo 2026-10-21T09:30:00Z > "$fake/reopened-at"
out="$(run 306)"; rc=$?
check_runs "$rc"
check 'the open issue gets a record after the reopening' 2 "$(landings_of 306)"
open issue-307-reopened-closed
land issue-307-reopened-closed 'Reopened, closed again (#307)'
plant_comment $repo 307 OWNER 2026-10-21T09:00:00Z "Landed on master:

$(commits_of 307)"
echo closed > "$state"
out="$(run 307)"; rc=$?
echo open > "$state"; rm -f "$fake/reopened-at"
check_runs "$rc"
check 'the closed issue keeps its old record' 1 "$(landings_of 307)"

echo 'a record of a stranger covers nothing, on an open issue or on a closed one'
open issue-308-stranger
land issue-308-stranger 'Stranger (#308)'
plant_comment $repo 308 NONE 2026-10-21T09:00:00Z "Landed on master:

$(commits_of 308)"
out="$(run 308)"; rc=$?
check_runs "$rc"
check 'the open issue is told'           2 "$(landings_of 308)"
open issue-309-stranger-closed
land issue-309-stranger-closed 'Stranger, closed (#309)'
plant_comment $repo 309 NONE 2026-10-21T09:00:00Z "Landed on master:

$(commits_of 309)"
echo closed > "$state"
out="$(run 309)"; rc=$?
echo open > "$state"
check_runs "$rc"
check 'the closed issue is told'         2 "$(landings_of 309)"

echo 'a record further back than the last 50 comments covers a closed issue, not an open one'
for n in 310 311; do
  open "issue-$n-far-back"
  land "issue-$n-far-back" "Far back (#$n)"
  plant_comment $repo $n OWNER 2026-10-21T08:00:00Z "Landed on master:

$(commits_of $n)"
  for t in $(seq 10 59); do plant_comment $repo $n OWNER "2026-10-21T09:$t:00Z" "talk $t"; done
done
out="$(run 310)"; rc=$?
check_runs "$rc"
check 'the open issue is told'           2 "$(landings_of 310)"
echo closed > "$state"
out="$(run 311)"; rc=$?
echo open > "$state"
check_runs "$rc"
check 'the closed issue is not'          1 "$(landings_of 311)"

echo 'comments that cannot be read are no empty list: nothing is written, and it says so'
open issue-312-unreadable
land issue-312-unreadable 'Unreadable (#312)'
touch "$fake/reopened-down"
: > "$log"; rm -rf "$fake/cache"
out="$(run 312)"; rc=$?
rm -f "$fake/reopened-down"
check_runs "$rc"
check 'the issue is not told'            0 "$(landings_of 312)"
check 'nothing was posted'               0 "$(posted)"
check 'it says so'                       yes "$(grep -q '^the issue was NOT told what landed: its comments could not be read' <<< "$out" && echo yes || echo no)"
out="$(run 312)"; rc=$?
check 'a run that can read tells it'     1 "$(landings_of 312)"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
