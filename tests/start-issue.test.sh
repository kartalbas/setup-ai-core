#!/usr/bin/env bash
# What start-issue.sh refuses, where it puts the worktree, and what it moves.
#
# It runs inside a TEMPORARY repository with a temporary origin, both built and deleted here,
# and with a FAKE gh on PATH: no real worktree is created anywhere and nothing leaves the
# machine. What is pinned: every refusal happens BEFORE a worktree exists, the worktree stands
# beside the checkout under .worktrees/<repo>/ and never inside it, its branch carries the
# issue number, and the card is moved to implementing in the same run.
#
#   bash test/start-issue.test.sh

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fake="$(mktemp -d)"
export GH_CACHE_DIRECTORY="$fake/cache"
# The board number is one no board has, so the ids this test invents land in a cache directory
# of their own and are taken away with it.
export GH_PROJECT_NUMBER=999981
trap 'rm -rf "$fake"' EXIT
log="$fake/calls.txt"

cat > "$fake/gh" <<EOF
#!/usr/bin/env bash
a="\$*"
printf '%s\n' "\$a" >> "$log"
case "\$a" in
  *"repo view"*)            echo 'example-org/example-repo' ;;
  # status-sync's query of the repository's issues names comments and projectItems too
  *"issues(states:OPEN"*)   [ -e "$fake/issues-down" ] && { echo 'the issues are down' >&2; exit 1; }; echo '{"data":{"repository":{"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}' ;;
  *comments*)               echo '[]' ;;
  *"--jq .node_id"*)        echo 'I_node163' ;;
  *"projectV2(number:"*)    echo 'PVT_kwstart' ;;
  *"fields(first:50)"*)     printf 'Status\tFID\ttodo\tOPT_todo\nStatus\tFID\timplementing\tOPT_impl\n' ;;
  *addProjectV2ItemById*)   echo 'PVTI_item163' ;;
  *"parent {"*)             printf '' ;;
  *projectItems*)           printf '' ;;
  *"projectsV2(first"*)     [ -e "$fake/no-board" ] || echo '{}' ;;
  *graphql*)                echo '{}' ;;
  *"api user"*)             echo '{"login":"tester"}' ;;
  *issues/*)                echo '{"number":163,"title":"Read the board whole","state":"open","labels":[],"assignees":[{"login":"'"\${ASSIGNEE:-tester}"'"}],"body":"The count is a guess."}' ;;
  *)                        echo '{}' ;;
esac
exit 0
EOF
chmod +x "$fake/gh"
export PATH="$fake:$PATH"
# The team modes are not what this test proves; a table whose probes always pass keeps the
# gate out of the way. team-modes.test.sh proves the gate itself.
printf 'claude\tcaveman\tlite\talways\t-\t-\n' > "$fake/team-modes.tsv"
export TEAM_MODES_FILE="$fake/team-modes.tsv"

failed=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}

# git is given an identity and a default branch here, so the test does not depend on whatever
# the machine's own configuration happens to be.
dress() {
  git -C "$1" config user.email 'test@example.invalid'
  git -C "$1" config user.name 'test'
  git -C "$1" config commit.gpgsign false
  git -C "$1" config core.autocrlf false
}

origin="$fake/origin.git"
checkouts="$fake/checkouts"
work="$checkouts/example-repo"
mkdir -p "$checkouts"
git -c init.defaultBranch=master init -q --bare "$origin"
git -c init.defaultBranch=master init -q "$work"
dress "$work"
echo 'one' > "$work/README.md"
git -C "$work" add -A && git -C "$work" commit -q -m 'the first commit'
git -C "$work" remote add origin "$origin"
git -C "$work" push -q -u origin master
git -C "$work" remote set-head origin -a >/dev/null
# The main checkout carries the harness data a worktree inherits; nothing reaches the network
mkdir -p "$work/.ai-core"; printf 'UPDATE_CHECK="never"
' > "$work/.ai-core/config.env"
printf '/.ai-core/
' >> "$work/.git/info/exclude"

start="$root/bin/start-issue.sh"
run() { (cd "$work" && bash "$start" "$@" 2>&1); }
branches() { git -C "$work" for-each-ref --format='%(refname:short)' refs/heads | paste -sd' ' -; }
worktrees() { git -C "$work" worktree list --porcelain | grep -c '^worktree ' || true; }

echo 'a call with no number is refused before anything is read'
: > "$log"
out="$(run)"; rc=$?
check 'exits nonzero'    yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'nothing was read' 0 "$(grep -c . "$log" || true)"
out="$(run not-a-number)"; rc=$?
check 'a number that is not one is refused' yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"

echo 'a working copy with changes in it opens no worktree'
echo 'unsaved' >> "$work/README.md"
out="$(run 163)"; rc=$?
check 'exits nonzero'    yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'it says which'    yes "$(grep -q 'the working copy has changes' <<< "$out" && echo yes || echo no)"
check 'no branch made'   master "$(branches)"
check 'one worktree'     1 "$(worktrees)"
git -C "$work" checkout -q -- README.md

echo 'a master behind origin is pulled first, not branched from'
other="$fake/other"
git clone -q "$origin" "$other"
dress "$other"
echo 'two' >> "$other/README.md"
git -C "$other" add -A && git -C "$other" commit -q -m 'a commit somebody else pushed'
git -C "$other" push -q origin HEAD:master
out="$(run 163)"; rc=$?
check 'exits nonzero'   yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'it says how far' yes "$(grep -q 'master is 1 commit(s) behind origin/master' <<< "$out" && echo yes || echo no)"
check 'no branch made'  master "$(branches)"
git -C "$work" pull -q --ff-only origin master

echo "somebody else's issue opens no worktree"
: > "$log"
out="$(ASSIGNEE=somebody run 163)"; rc=$?
check 'exits nonzero'  yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'it names both'  yes "$(grep -q '#163 is assigned to @somebody, not to @tester' <<< "$out" && echo yes || echo no)"
check 'no branch made' master "$(branches)"
check 'the card did not move' 0 "$(grep -c 'oid=OPT_impl' "$log" || true)"

# A worktree of another issue whose work landed three days ago: the run that opens the next one
# removes it (finish-issue --sweep)
old="$checkouts/.worktrees/example-repo/issue-170-old"
mkdir -p "$checkouts/.worktrees/example-repo"
git -C "$work" worktree add -q -b issue-170-old "$old" origin/master 2>/dev/null
dress "$old"
echo 'old' >> "$old/README.md"; git -C "$old" add -A
long_ago="$(date -d '3 days ago' '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -v-3d '+%Y-%m-%dT%H:%M:%S')"
GIT_AUTHOR_DATE="$long_ago" GIT_COMMITTER_DATE="$long_ago" git -C "$old" commit -q -m 'An old change (#170)'
git -C "$old" push -q origin HEAD:master
git -C "$work" pull -q --ff-only origin master

echo 'the worktree, the card and the thread come out of one run'
: > "$log"
out="$(run 163)"; rc=$?
tree="$checkouts/.worktrees/example-repo/issue-163-read-the-board-whole"
check 'exits zero'        0 "$rc"
check 'the worktree line' yes "$(printf '%s\n' "$out" | sed -n '1p' | grep -q "^Worktree .*issue-163-read-the-board-whole on issue-163-read-the-board-whole, cut from origin/master.$" && echo yes || echo no)"
check 'it is there'       yes "$([ -d "$tree" ] && echo yes || echo no)"
check 'and outside the checkout' no "$(grep -q "^$work/" <<< "$tree" && echo yes || echo no)"
check 'two worktrees'     2 "$(worktrees)"
check 'the branch'        'issue-163-read-the-board-whole master' "$(branches)"
check 'the card moved'    '#163 -> implementing' "$(printf '%s\n' "$out" | sed -n '2p')"
check 'to that option'    yes "$(grep -q 'oid=OPT_impl' "$log" && echo yes || echo no)"
check 'the thread'        1 "$(grep -c '^#163 Read the board whole$' <<< "$out" || true)"
check 'the landed worktree of #170 is gone' no "$([ -d "$old" ] && echo yes || echo no)"
check 'and named'         yes "$(grep -q 'issue-170-old: landed, removed$' <<< "$out" && echo yes || echo no)"
check 'the board is not read whole' 0 "$(grep -c 'items(first:100, after:' "$log" || true)"
check 'the cards of its repository are swept, in one query (status-sync)' 1 "$(grep -c 'issues(states:OPEN' "$log" || true)"
check 'the worktree is on the new branch' 'issue-163-read-the-board-whole' \
  "$(git -C "$tree" rev-parse --abbrev-ref HEAD)"

echo 'a worktree for that number already there is not opened twice'
out="$(run 163)"; rc=$?
check 'exits nonzero' yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'it names it'   yes "$(grep -q 'a branch for this issue exists already: issue-163-read-the-board-whole' <<< "$out" && echo yes || echo no)"
check 'still two worktrees' 2 "$(worktrees)"

echo 'the slug is cut to forty characters'
git -C "$work" worktree remove --force "$tree"
git -C "$work" branch -q -D issue-163-read-the-board-whole
long="$fake/long"
mkdir -p "$long"
cat > "$long/gh" <<'LONG'
#!/usr/bin/env bash
case "$*" in
  *"repo view"*) echo 'example-org/example-repo' ;;
  *comments*)    echo '[]' ;;
  *"api user"*)  echo '{"login":"tester"}' ;;
  *issues/*)     echo '{"number":164,"title":"Read the whole board before the count is printed, or the number is a guess","state":"open","labels":[],"assignees":[{"login":"tester"}],"body":"x"}' ;;
  *)             echo '{}' ;;
esac
exit 0
LONG
chmod +x "$long/gh"
out="$(cd "$work" && PATH="$long:$PATH" bash "$start" 164 2>&1)"; rc=$?
made="$(git -C "$work" for-each-ref --format='%(refname:short)' refs/heads | grep '^issue-164' || true)"
check 'exits zero'    0 "$rc"
check 'the slug is 40 characters' 40 "$(printf '%s' "${made#issue-164-}" | wc -c | tr -d ' ')"

# WHAT SEPARATES THE TWO TWINS. The title below carries U+212A KELVIN SIGN, which
# .ToLowerInvariant() maps to `k` and `tr '[:upper:]' '[:lower:]'` leaves alone, so the same issue
# produced issue-165-read-the-kelvin-board on one shell and issue-165-read-the-elvin-board on the
# other. Both twins assert the same name here, which is what makes the pair provable rather than
# merely both green.
echo 'the two folds answer alike on a letter only one of them lowercases'
kelvin="$fake/kelvin"
mkdir -p "$kelvin"
cat > "$kelvin/gh" <<'KELVIN'
#!/usr/bin/env bash
# U+212A KELVIN SIGN, written as its three UTF-8 bytes in octal so this file stays plain ASCII.
sign="$(printf '\342\204\252')"
case "$*" in
  *"repo view"*) echo 'example-org/example-repo' ;;
  *comments*)    echo '[]' ;;
  *"api user"*)  echo '{"login":"tester"}' ;;
  *issues/*)     echo '{"number":165,"title":"Read the '"$sign"'ELVIN board","state":"open","labels":[],"assignees":[{"login":"tester"}],"body":"x"}' ;;
  *)             echo '{}' ;;
esac
exit 0
KELVIN
chmod +x "$kelvin/gh"
out="$(cd "$work" && PATH="$kelvin:$PATH" bash "$start" 165 2>&1)"; rc=$?
made="$(git -C "$work" for-each-ref --format='%(refname:short)' refs/heads | grep '^issue-165' || true)"
check 'exits zero' 0 "$rc"
check 'the slug folds A-Z and nothing else' 'issue-165-read-the-elvin-board' "$made"

echo 'a repository on no board: the worktree opens, and the status says it has nowhere to go'
touch "$fake/no-board"; : > "$log"
out="$(cd "$work" && GH_PROJECT_NUMBER='' bash "$start" 166 2>&1)"; rc=$?
check 'exits zero'             0 "$rc"
check 'it says so'             '#166 -> implementing not set: example-org/example-repo is on no board' "$(printf '%s\n' "$out" | sed -n '2p')"
check 'no warning'             no "$(grep -q 'did NOT move' <<< "$out" && echo yes || echo no)"
check 'no card was looked for' 0 "$(grep -c 'addProjectV2ItemById' "$log" || true)"
echo 'issue-priority on a repository on no board says so and exits zero'
out="$(cd "$work" && GH_PROJECT_NUMBER='' bash "$root/bin/issue-priority.sh" 166 P2 2>&1)"; rc=$?
check 'exits zero'             0 "$rc"
check 'it says so'             '#166 -> P2 not set: example-org/example-repo is on no board' "$out"
rm -f "$fake/no-board"

echo 'an origin/HEAD naming a branch the remote no longer has: the default branch is asked of the remote'
git -C "$work" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/gone
out="$(run 168)"; rc=$?
check 'exits zero'             0 "$rc"
check 'cut from origin/master' yes "$(grep -q '^Worktree .*issue-168-.*, cut from origin/master\.$' <<< "$out" && echo yes || echo no)"
git -C "$work" remote set-head origin -a >/dev/null

# The issue lives in other-org/tracker and its work lands here. Asked of this repository, the same
# number is Not Found, so a read in the wrong repository shows as a failure, not as a wrong title.
echo 'an issue of another repository: cut here, read there, and its repository recorded on the branch'
cross="$fake/cross"; mkdir -p "$cross"; clog="$fake/cross-calls.txt"; : > "$clog"
cat > "$cross/gh" <<CROSS
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$clog"
case "\$*" in
  *"repo view"*)                     echo 'example-org/example-repo' ;;
  *"api user"*)                      echo '{"login":"tester"}' ;;
  *"projectsV2(first"*)              ;;
  *other-org/tracker/issues/*/comments*) echo '[]' ;;
  *other-org/tracker/issues/*)       echo '{"number":171,"title":"Alert on a stuck run","state":"open","labels":[],"assignees":[{"login":"tester"}],"body":"The rule lands in the other repository."}' ;;
  *issues/*)                         echo '{"message":"Not Found"}'; echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
  *)                                 echo '{}' ;;
esac
exit 0
CROSS
chmod +x "$cross/gh"
out="$(cd "$work" && PATH="$cross:$PATH" GH_PROJECT_NUMBER='' bash "$start" other-org/tracker 171 2>&1)"; rc=$?
cut="issue-171-alert-on-a-stuck-run"
check 'exits zero'                       0 "$rc"
check 'the branch carries the number'    "$cut" "$(git -C "$work" for-each-ref --format='%(refname:short)' refs/heads | grep '^issue-171' || true)"
check 'the repository is recorded on it' other-org/tracker "$(git -C "$work" config --get "branch.$cut.issueRepository" || true)"
check 'the issue was read there'         yes "$(grep -q 'other-org/tracker/issues/171' "$clog" && echo yes || echo no)"
check 'and never here'                   0 "$(grep -c 'example-org/example-repo/issues' "$clog" || true)"

echo 'its own repository, named in another case, is no other repository'
out="$(cd "$work" && GH_PROJECT_NUMBER='' bash "$start" Example-Org/Example-Repo 172 2>&1)"; rc=$?
check 'exits zero'                       0 "$rc"
check 'nothing is recorded'              '' "$(git -C "$work" config --get-regexp '^branch\.issue-172-.*\.issuerepository$' || true)"

echo 'session-start in that worktree reads the issue where the branch says, and ends ready'
wt="$checkouts/.worktrees/example-repo/$cut"
started() { (cd "$wt" && PATH="$cross:$PATH" AI_CORE_UPDATE_CHECK=never bash "$root/bin/session-start.sh" "$@" 2>&1); }
out="$(started)"; rc=$?
check 'exits zero'                       0 "$rc"
check 'it names the issue by its repository' yes "$(grep -q '^This worktree carries issue other-org/tracker#171\.' <<< "$out" && echo yes || echo no)"
check 'it carries the thread'            yes "$(grep -qF 'The rule lands in the other repository.' <<< "$out" && echo yes || echo no)"
check 'it ends ready'                    yes "$(grep -qx 'Ready for task execution.' <<< "$out" && echo yes || echo no)"
check 'the JSON names the repository'    other-org/tracker "$(started --json | jq -r '.issue_repository')"

echo 'an issue that cannot be read: the start does not end as if it had been read'
git -C "$work" config --unset "branch.$cut.issueRepository"
out="$(started)"; rc=$?
check 'exits zero'                       0 "$rc"
check 'no plain ready'                   no "$(grep -qx 'Ready for task execution.' <<< "$out" && echo yes || echo no)"
check 'the last line names the miss'     yes "$(tail -n 1 <<< "$out" | grep -q '^Ready for task execution, but WITHOUT the issue: #171 could not be read (' && echo yes || echo no)"
check 'the JSON names no repository'     null "$(started --json | jq -r 'if has("issue_repository") then .issue_repository else "absent" end')"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
