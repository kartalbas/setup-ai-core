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

# The start commit carries its configured identity, which the real gate holds it against: an identity in the caller's
# environment would make it a stranger's.
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fake="$(mktemp -d)"
# Every run of the gate leaves a record under AI_CORE_HOME; a test writes none into the machine's own
export AI_CORE_HOME="$fake/ai-core-home"
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
if [ -e "$fake/refuse-once" ] && [[ "\$a" == *"issues/163"* ]] && [[ "\$a" != *"comments"* ]]; then
  rm -f "$fake/refuse-once"
  echo '{"message":"API rate limit already exceeded for user ID 1."}'
  echo 'gh: API rate limit already exceeded for user ID 1. (HTTP 403)' >&2
  exit 1
fi
case "\$a" in
  *"repo view"*"--json isPrivate"*)                                      echo '{"isPrivate":true}' ;;
  *"repo view"*|"api repos/{owner}/{repo} --jq .full_name"*)            echo 'example-org/example-repo' ;;
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
export AI_CORE_SLEEP=true   # the waits of a refused call take no time here
# The team modes are not what this test proves; a table whose probes always pass keeps the
# gate out of the way. team-modes.test.sh proves the gate itself.
printf 'claude\tmode\talways\t-\t-\ncodex\tmode\talways\t-\t-\n' > "$fake/team-modes.tsv"
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
}

origin="$fake/origin.git"
checkouts="$fake/checkouts"
work="$checkouts/example-repo"
mkdir -p "$checkouts"
git -c init.defaultBranch=master init -q --bare "$origin"
git -c init.defaultBranch=master init -q "$work"
dress "$work"
echo 'one' > "$work/README.md"
echo 'notes' > "$work/notes.txt"
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

# The worktree is cut from origin, so a checkout behind it, with changes in it, or with commits of
# its own opens a worktree all the same and is named in one line. Every checkout below is a clone of
# its own, so one case never stands on another's leftovers.
echo 'a checkout behind origin, with changes, or with commits of its own opens its worktree from origin and is left as it is'
states="$fake/states"
git_real="$(command -v git)"
gitfail="$fake/gitfail"
mkdir -p "$states" "$gitfail"
# A git that fails for the one subcommand named in FAIL_GIT and is the real git for every other
cat > "$gitfail/git" <<GITFAIL
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = "\${FAIL_GIT:-.}" ]; then echo "fatal: planted failure of git \$a" >&2; exit 128; fi
done
exec "$git_real" "\$@"
GITFAIL
chmod +x "$gitfail/git"

harness_data() {
  mkdir -p "$1/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$1/.ai-core/config.env"
  printf '/.ai-core/\n' >> "$1/.git/info/exclude"
}
make_source() { git clone -q "$origin" "$states/$1"; dress "$states/$1"; harness_data "$states/$1"; }
add_changes() {  # a staged change, a change not staged, and an untracked file
  echo 'staged' >> "$states/$1/README.md"; git -C "$states/$1" add README.md
  echo 'unstaged' >> "$states/$1/notes.txt"
  echo 'untracked' > "$states/$1/untracked.txt"
}
add_commit() {
  echo 'local only' > "$states/$1/local.txt"
  git -C "$states/$1" add local.txt && git -C "$states/$1" commit -q -m 'a commit only this checkout has'
}
# All that start-issue must leave as it was: the branch or the detached state, HEAD, the branch
# tips, the index entries and the index file itself, the status, and every file with its content.
snapshot() {
  { git -C "$1" symbolic-ref -q HEAD || echo detached
    git -C "$1" rev-parse -q --verify HEAD || echo unborn
    git -C "$1" for-each-ref --format='%(refname) %(objectname)' refs/heads | grep -v '^refs/heads/issue-'
    GIT_OPTIONAL_LOCKS=0 git -C "$1" status --porcelain=v1 --untracked-files=all
    git -C "$1" ls-files -s
    cksum < "$1/.git/index" 2>/dev/null
    git -C "$1" stash list
    (cd "$1" && find . -path ./.git -prune -o -type f -exec cksum {} + | sort)
  } 2>&1
}
state_line() {  # NAME WHERE STATE
  echo "The checkout $(git -C "$states/$1" rev-parse --show-toplevel) ($2) $3. The new worktree starts from origin/master and does not see that; the checkout's branch, index, files and commits stay as they were."
}
source_case() {  # NAME NUMBER WANTED-LINE (empty: no line)
  local src="$states/$1" n="$2" before after out rc tree
  tree="$states/.worktrees/$1/issue-$n-read-the-board-whole"
  before="$(snapshot "$src")"
  out="$(cd "$src" && bash "$start" "$n" 2>&1)"; rc=$?
  after="$(snapshot "$src")"
  check "$1: exits zero"                         0 "$rc"
  check "$1: the worktree is cut from origin"    "$(git -C "$src" rev-parse refs/remotes/origin/master)" "$(git -C "$tree" rev-parse HEAD 2>/dev/null)"
  check "$1: the state is named"                 "$3" "$(grep '^The checkout ' <<< "$out")"
  check "$1: the checkout is as it was"          "$before" "$after"
  check "$1: none of its changes is in the tree" '' "$(git -C "$tree" status --porcelain 2>&1)$(for f in local.txt untracked.txt; do [ ! -e "$tree/$f" ] || echo "$f"; done)"
}

make_source behind
make_source both;     add_changes both
make_source diverged; add_commit diverged
make_source feature;  git -C "$states/feature" checkout -q -b feature; git -C "$states/feature" branch -q -D master
make_source detached; git -C "$states/detached" checkout -q --detach
make_source faulty
git init -q -b trunk "$states/unborn"; dress "$states/unborn"; harness_data "$states/unborn"
git -C "$states/unborn" remote add origin "$origin"
other="$fake/other"
git clone -q "$origin" "$other"
dress "$other"
echo 'two' >> "$other/README.md"
git -C "$other" add -A && git -C "$other" commit -q -m 'a commit somebody else pushed'
git -C "$other" push -q origin HEAD:master
make_source current
make_source dirty;    add_changes dirty
make_source ahead;    add_commit ahead
make_source touched;  touch -t 202001010000 "$states/touched/README.md"   # stat changed, content not
make_source hidden;   git -C "$states/hidden" config status.showUntrackedFiles no; echo 'untracked' > "$states/hidden/untracked.txt"
make_source treehead; echo "$(git -C "$states/treehead" rev-parse 'HEAD^{tree}')" > "$states/treehead/.git/refs/heads/master"
make_source locked
make_source hooked;   printf '#!/bin/sh\nexit 1\n' > "$states/hooked/.git/hooks/post-checkout"; chmod +x "$states/hooked/.git/hooks/post-checkout"
make_source ambiguous; git -C "$states/ambiguous" branch -q origin/master
make_source racer;    echo 'edit' >> "$states/racer/README.md"

source_case behind   201 "$(state_line behind 'branch master' 'is 1 commit(s) behind origin/master')"
source_case dirty    202 "$(state_line dirty 'branch master' 'has changes')"
source_case both     203 "$(state_line both 'branch master' 'has changes, is 1 commit(s) behind origin/master')"
source_case ahead    204 "$(state_line ahead 'branch master' 'is 1 commit(s) ahead of origin/master')"
source_case diverged 205 "$(state_line diverged 'branch master' 'is 1 commit(s) behind and 1 commit(s) ahead of origin/master')"
source_case feature  206 "$(state_line feature 'branch feature' 'is 1 commit(s) behind origin/master')"
source_case detached 207 "$(state_line detached "detached HEAD at $(git -C "$states/detached" rev-parse --short HEAD)" 'is 1 commit(s) behind origin/master')"
source_case unborn   208 "$(state_line unborn 'branch trunk' 'has no commit yet')"
source_case current  209 ''
source_case touched  216 ''
source_case hidden   217 "$(state_line hidden 'branch master' 'has changes')"
check 'diverged: its own commit survives' 'a commit only this checkout has' "$(git -C "$states/diverged" log -1 --format=%s)"
check 'diverged: and its file' 'local only' "$(cat "$states/diverged/local.txt")"
git -C "$work" pull -q --ff-only origin master

# origin moves, and the checkout fetches it, after the run has read origin and before it creates the
# worktree: the worktree must start at the commit that was read and measured
echo 'a fetch into the checkout during the run changes neither the commit the worktree starts at nor the state named'
racegh="$fake/racegh"
mkdir -p "$racegh"
cat > "$racegh/gh" <<RACEGH
#!/usr/bin/env bash
if [[ "\$*" == *issues/* && "\$*" != *comments* && -e "$fake/race-once" ]]; then
  rm -f "$fake/race-once"
  git -C "$other" commit -q --allow-empty -m 'a commit pushed while start-issue runs'
  git -C "$other" push -q origin HEAD:master
  git -C "$states/racer" fetch -q origin
fi
exec "$fake/gh" "\$@"
RACEGH
chmod +x "$racegh/gh"
read_tip="$(git -C "$states/racer" rev-parse refs/remotes/origin/master)"
touch "$fake/race-once"
out="$(cd "$states/racer" && PATH="$racegh:$PATH" bash "$start" 218 2>&1)"; rc=$?
tree="$states/.worktrees/racer/issue-218-read-the-board-whole"
check 'race: exits zero'                              0 "$rc"
check 'race: origin moved during the run'             yes "$([ "$(git -C "$states/racer" rev-parse refs/remotes/origin/master)" != "$read_tip" ] && echo yes || echo no)"
check 'race: the worktree starts at the commit read'  "$read_tip" "$(git -C "$tree" rev-parse HEAD 2>/dev/null)"
check 'race: the state line matches that commit'      "$(state_line racer 'branch master' 'has changes')" "$(grep '^The checkout ' <<< "$out")"
check 'race: the branch pushes to its own branch on origin' 'origin issue-218-read-the-board-whole' "$(git -C "$tree" config branch.issue-218-read-the-board-whole.remote) $(git -C "$tree" config branch.issue-218-read-the-board-whole.merge | sed 's|^refs/heads/||')"
master_before_push="$(git --git-dir="$origin" rev-parse refs/heads/master)"
git -C "$tree" commit -q --allow-empty -m 'Work on the issue (#218)'
git -C "$tree" push -q 2>"$fake/plain-push.err"; rc=$?
check 'race: a plain git push goes through' 0 "$rc$([ "$rc" -eq 0 ] || echo " $(cat "$fake/plain-push.err")")"
check 'race: it made the branch of the issue on origin' "$(git -C "$tree" rev-parse HEAD)" "$(git --git-dir="$origin" rev-parse refs/heads/issue-218-read-the-board-whole 2>&1)"
check 'race: and did not touch the default branch' "$master_before_push" "$(git --git-dir="$origin" rev-parse refs/heads/master)"
check 'race: the branch now tracks origin/<its own name>' origin/issue-218-read-the-board-whole "$(git -C "$tree" rev-parse --abbrev-ref '@{upstream}' 2>&1)"

echo 'a checkout whose HEAD cannot be read as a commit is refused before anything is made'
made_before="$(git -C "$states/treehead" worktree list; git -C "$states/treehead" for-each-ref --format='%(refname)' refs/heads)"
out="$(cd "$states/treehead" && bash "$start" 219 2>&1)"; rc=$?
check 'unreadable HEAD: exits nonzero' yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'unreadable HEAD: it says so'    yes "$(grep -q 'cannot read the checkout.s HEAD, so its state cannot be named' <<< "$out" && echo yes || echo no)"
check 'unreadable HEAD: nothing made'  "$made_before" "$(git -C "$states/treehead" worktree list; git -C "$states/treehead" for-each-ref --format='%(refname)' refs/heads)"

# A step of the creation that fails leaves no worktree, so the next run, without the fault, completes
echo 'a config file that is locked during the run leaves no worktree, and the next run completes the start'
locked_made() { git -C "$states/locked" worktree list; }
made_before="$(locked_made)"
touch "$states/locked/.git/config.lock"
out="$(cd "$states/locked" && bash "$start" 220 2>&1)"; rc=$?
check 'locked config: exits nonzero'     yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'locked config: it says so'        yes "$(grep -q 'the worktree could not be created: ' <<< "$out" && grep -q -- ' - no worktree stands at ' <<< "$out" && echo yes || echo no)"
check 'locked config: no worktree made'  "$made_before" "$(locked_made)"
rm -f "$states/locked/.git/config.lock"
: > "$log"
out="$(cd "$states/locked" && bash "$start" 220 2>&1)"; rc=$?
tree="$states/.worktrees/locked/issue-220-read-the-board-whole"
check 'locked config, again without it: exits zero'   0 "$rc"
check 'it pushes to its own branch on origin' 'origin issue-220-read-the-board-whole' "$(git -C "$states/locked" config branch.issue-220-read-the-board-whole.remote) $(git -C "$states/locked" config branch.issue-220-read-the-board-whole.merge | sed 's|^refs/heads/||')"
check 'init ran in the worktree'         yes "$([ -f "$tree/.ai-core/config.env" ] && echo yes || echo no)"
check 'the card moved'                   yes "$(grep -q 'oid=OPT_impl' "$log" && echo yes || echo no)"
check 'it names the missing push gate (planted: origin carries no shim)' yes "$(grep -qF "this repository carries no push gate (.githooks/pre-push), so a push from the worktree runs no check: run 'ai-core pre-push --install' in $states/locked first" <<< "$out" && echo yes || echo no)"

echo 'a repository whose tree carries the push gate is not named as one without it'
gated_origin="$fake/gated.git"; gated_seed="$fake/gated-seed"
git -c init.defaultBranch=master init -q --bare "$gated_origin"
git -c init.defaultBranch=master init -q "$gated_seed"; dress "$gated_seed"
mkdir -p "$gated_seed/.githooks"; printf '#!/bin/sh\nexit 0\n' > "$gated_seed/.githooks/pre-push"; chmod +x "$gated_seed/.githooks/pre-push"
git -C "$gated_seed" add -A; git -C "$gated_seed" commit -q -m 'the gate'
git -C "$gated_seed" remote add origin "$gated_origin"; git -C "$gated_seed" push -q -u origin master
git clone -q "$gated_origin" "$states/gated"; dress "$states/gated"; harness_data "$states/gated"
out="$(cd "$states/gated" && bash "$start" 224 2>&1)"; rc=$?
check 'gated: exits zero'                0 "$rc$([ "$rc" -eq 0 ] || echo " $out")"
check 'gated: nothing is said about a missing push gate (innocent)' no "$(grep -q 'carries no push gate' <<< "$out" && echo yes || echo no)"

echo 'a post-checkout hook that fails leaves a worktree, and the message names it'
tree="$states/.worktrees/hooked/issue-222-read-the-board-whole"
out="$(cd "$states/hooked" && bash "$start" 222 2>&1)"; rc=$?
check 'failing hook: exits nonzero'           yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'failing hook: the worktree is there'   yes "$([ -d "$tree" ] && echo yes || echo no)"
check 'failing hook: the message names it'    yes "$(grep -qF "a worktree stands at $tree on issue-222-read-the-board-whole" <<< "$out" && echo yes || echo no)"
check 'failing hook: it does not say there is none' no "$(grep -q 'no worktree' <<< "$out" && echo yes || echo no)"

echo 'a local branch named origin/master does not make the start ambiguous'
out="$(cd "$states/ambiguous" && bash "$start" 221 2>&1)"; rc=$?
tree="$states/.worktrees/ambiguous/issue-221-read-the-board-whole"
check 'ambiguous name: exits zero'       0 "$rc"
check 'it starts at the commit of origin/master' "$(git -C "$states/ambiguous" rev-parse refs/remotes/origin/master)" "$(git -C "$tree" rev-parse HEAD 2>/dev/null)"
check 'it pushes to its own branch on origin' 'origin issue-221-read-the-board-whole' "$(git -C "$states/ambiguous" config branch.issue-221-read-the-board-whole.remote) $(git -C "$states/ambiguous" config branch.issue-221-read-the-board-whole.merge | sed 's|^refs/heads/||')"

echo 'a checkout with changes and behind origin still refuses what else was refused'
out="$(cd "$states/both" && ASSIGNEE=somebody bash "$start" 210 2>&1)"; rc=$?
check "another one's issue: exits nonzero" yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'it names both'                      yes "$(grep -q '#210 is assigned to @somebody, not to @tester' <<< "$out" && echo yes || echo no)"
check 'no branch made'                     '' "$(git -C "$states/both" for-each-ref --format='%(refname:short)' 'refs/heads/issue-210*')"
out="$(cd "$states/both" && bash "$start" 203 2>&1)"; rc=$?
check 'a branch for the issue exists: exits nonzero' yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'it names the branch'                yes "$(grep -q 'a branch for this issue exists already: issue-203-read-the-board-whole' <<< "$out" && echo yes || echo no)"

echo 'a failed read of origin or of the checkout is reported, and nothing is made'
faulty_made() { git -C "$states/faulty" for-each-ref --format='%(refname)' refs/heads; git -C "$states/faulty" worktree list; }
faulty_start() {  # NUMBER [VARIABLE=VALUE ...]
  local n="$1"; shift
  : > "$log"
  (cd "$states/faulty" && env ${1+"$@"} bash "$start" "$n" 2>&1)
}
faulty_untouched() { check "$1: no branch and no worktree made" "$made_before" "$(faulty_made)"; check "$1: no issue read, no card moved" 0 "$(grep -c 'issues/\|OPT_impl' "$log" || true)"; }
made_before="$(faulty_made)"
git -C "$states/faulty" remote set-url origin "$fake/nowhere.git"
out="$(faulty_start 211)"; rc=$?
check 'fetch fails: exits nonzero' yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'fetch fails: it says so'    yes "$(grep -q 'could not reach origin' <<< "$out" && echo yes || echo no)"
faulty_untouched 'fetch fails'
git -C "$states/faulty" remote set-url origin "$origin"
git -C "$states/faulty" config remote.origin.fetch '+refs/heads/no-such-branch*:refs/remotes/origin/no-such-branch*'
git -C "$states/faulty" update-ref -d refs/remotes/origin/master
out="$(faulty_start 212)"; rc=$?
check 'no remote commit: exits nonzero' yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'no remote commit: it says so'    yes "$(grep -q 'origin has no branch master to cut the worktree from' <<< "$out" && echo yes || echo no)"
faulty_untouched 'no remote commit'
git -C "$states/faulty" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
git -C "$states/faulty" fetch -q origin
out="$(faulty_start 213 PATH="$gitfail:$PATH" FAIL_GIT=status)"; rc=$?
check 'status fails: exits nonzero' yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'status fails: it says so'    yes "$(grep -q 'cannot read the status of the checkout' <<< "$out" && echo yes || echo no)"
faulty_untouched 'status fails'
out="$(faulty_start 214 PATH="$gitfail:$PATH" FAIL_GIT=rev-list)"; rc=$?
check 'comparison fails: exits nonzero' yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'comparison fails: it says so'    yes "$(grep -q 'cannot compare the checkout.s HEAD with origin/master' <<< "$out" && echo yes || echo no)"
faulty_untouched 'comparison fails'
out="$(faulty_start 215)"; rc=$?
check 'the same checkout, nothing planted: exits zero' 0 "$rc"

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

echo 'the worktree, the card and the thread come out of one run, the read of the issue refused once on the way'
: > "$log"; touch "$fake/refuse-once"
out="$(run 163)"; rc=$?
tree="$checkouts/.worktrees/example-repo/issue-163-read-the-board-whole"
check 'exits zero'        0 "$rc"
check 'the refusal was met and waited for' 1 "$(grep -c "^waiting 60s for GitHub's secondary rate limit" <<< "$out" || true)"
out="$(grep -v '^waiting ' <<< "$out")"
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
  *"repo view"*|"api repos/{owner}/{repo} --jq .full_name"*) echo 'example-org/example-repo' ;;
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

# The title below carries U+212A KELVIN SIGN, which `tr '[:upper:]' '[:lower:]'` leaves alone, so
# the slug is issue-165-read-the-elvin-board.
echo 'a letter that tr does not lowercase stays out of the slug'
kelvin="$fake/kelvin"
mkdir -p "$kelvin"
cat > "$kelvin/gh" <<'KELVIN'
#!/usr/bin/env bash
# U+212A KELVIN SIGN, written as its three UTF-8 bytes in octal so this file stays plain ASCII.
sign="$(printf '\342\204\252')"
case "$*" in
  *"repo view"*|"api repos/{owner}/{repo} --jq .full_name"*) echo 'example-org/example-repo' ;;
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

echo 'a landed branch left on origin is no obstacle; one with work master lacks still is'
git -C "$work" push -q origin "master:refs/heads/issue-181-read-the-board-whole"
git -C "$work" fetch -q origin
out="$(run 181)"; rc=$?
check 'landed: exits zero'     0 "$rc"
check 'landed: cut from origin/master' yes "$(grep -q '^Worktree .*issue-181-read-the-board-whole, cut from origin/master\.$' <<< "$out" && echo yes || echo no)"
side="$fake/side"; git clone -q "$origin" "$side"; dress "$side"
git -C "$side" checkout -q -b issue-182-read-the-board-whole
echo 'not landed' > "$side/side.txt"; git -C "$side" add side.txt; git -C "$side" commit -q -m 'work in progress'
git -C "$side" push -q origin issue-182-read-the-board-whole
git -C "$work" fetch -q origin
out="$(run 182)"; rc=$?
check 'not landed: exits nonzero' yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'not landed: it names the branch' yes "$(grep -q 'a branch for this issue exists already: origin/issue-182-read-the-board-whole' <<< "$out" && echo yes || echo no)"
git -C "$work" branch -q issue-182-second origin/issue-182-read-the-board-whole
out="$(run 182)"; rc=$?
check 'two branches: both named' yes "$(grep -q 'a branch for this issue exists already: issue-182-second, origin/issue-182-read-the-board-whole - use' <<< "$out" && echo yes || echo no)"

echo 'a landed branch left only locally is no obstacle: the new worktree takes it over'
git -C "$work" branch -q issue-183-read-the-board-whole origin/master
out="$(run 183)"; rc=$?
check 'local landed: exits zero' 0 "$rc"
check 'local landed: cut from origin/master' yes "$(grep -q '^Worktree .*issue-183-read-the-board-whole, cut from origin/master\.$' <<< "$out" && echo yes || echo no)"

echo 'an origin/HEAD naming a branch the remote no longer has: the default branch is asked of the remote'
git -C "$work" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/gone
out="$(run 168)"; rc=$?
check 'exits zero'             0 "$rc"
check 'cut from origin/master' yes "$(grep -q '^Worktree .*issue-168-.*, cut from origin/master\.$' <<< "$out" && echo yes || echo no)"
git -C "$work" remote set-head origin -a >/dev/null

echo 'an origin/HEAD naming a branch the remote has but does not lead with: the remote decides'
git -C "$work" push -q origin master:refs/heads/old-default 2>/dev/null; git -C "$work" fetch -q origin
git -C "$work" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/old-default
out="$(run 169)"; rc=$?
check 'stale pointer: exits zero'             0 "$rc"
check 'stale pointer: cut from origin/master' yes "$(grep -q '^Worktree .*issue-169-.*, cut from origin/master\.$' <<< "$out" && echo yes || echo no)"
git -C "$work" remote set-head origin -a >/dev/null

# The issue lives in other-org/tracker and its work lands here. Asked of this repository, the same
# number is Not Found, so a read in the wrong repository shows as a failure, not as a wrong title.
echo 'an issue of another repository: cut here, read there, and its repository recorded on the branch'
cross="$fake/cross"; mkdir -p "$cross"; clog="$fake/cross-calls.txt"; : > "$clog"
cat > "$cross/gh" <<CROSS
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$clog"
case "\$*" in
  *"repo view"*|"api repos/{owner}/{repo} --jq .full_name"*)                     echo 'example-org/example-repo' ;;
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

# The number 174 is also the number of an issue of this clone's own repository, which has a branch of its own: local, and
# on origin. Asked about it in the tracker of the other repository, that branch answers "this issue", and it is not.
echo 'an issue of another repository whose number a branch of this clone'"'"'s own issue carries: that branch is no obstacle'
git -C "$side" checkout -q -b issue-174-own-work master
echo 'own' > "$side/own.txt"; git -C "$side" add own.txt; git -C "$side" commit -q -m 'work of this clone'"'"'s own issue'
git -C "$side" push -q origin issue-174-own-work
git -C "$work" fetch -q origin
git -C "$work" branch -q issue-174-own-work origin/issue-174-own-work
out="$(cd "$work" && PATH="$cross:$PATH" GH_PROJECT_NUMBER='' bash "$start" other-org/tracker 174 2>&1)"; rc=$?
check 'planted: exits zero'                    0 "$rc"
check 'planted: its own branch is cut'         issue-174-alert-on-a-stuck-run "$(git -C "$work" for-each-ref --format='%(refname:short)' refs/heads | grep '^issue-174-alert' || true)"
check 'planted: the repository is recorded'    other-org/tracker "$(git -C "$work" config --get "branch.issue-174-alert-on-a-stuck-run.issueRepository" || true)"
check 'planted: the other branch is untouched' "$(git -C "$side" rev-parse issue-174-own-work)" "$(git -C "$work" rev-parse issue-174-own-work)"
out="$(run 174)"; rc=$?
check 'innocent: its own issue still refuses'  yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'innocent: it names the branch'          yes "$(grep -q 'a branch for this issue exists already: .*issue-174-own-work.* - use its worktree instead' <<< "$out" && echo yes || echo no)"
git -C "$side" checkout -q -b issue-176-alert-on-a-stuck-run master
echo 'other' > "$side/other.txt"; git -C "$side" add other.txt; git -C "$side" commit -q -m 'work of the other issue'
git -C "$side" push -q origin issue-176-alert-on-a-stuck-run
git -C "$work" fetch -q origin
out="$(cd "$work" && PATH="$cross:$PATH" GH_PROJECT_NUMBER='' bash "$start" other-org/tracker 176 2>&1)"; rc=$?
check 'innocent: the issue'"'"'s own branch on origin refuses' yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'innocent: it names the branch on origin' yes "$(grep -q 'a branch for this issue exists already: origin/issue-176-alert-on-a-stuck-run' <<< "$out" && echo yes || echo no)"

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

echo 'a source issue worktree is opened without product assembly'
source_origin="$fake/github.com/example-org/shop-ai-core.git"
source_work="$fake/source-checkouts/shop-ai-core"
mkdir -p "$(dirname "$source_origin")" "$(dirname "$source_work")"
git init -q --bare -b master "$source_origin"
git init -q -b master "$source_work"; dress "$source_work"
cp -R "$root/skeleton/." "$source_work/"
mkdir -p "$source_work/.githooks"; cp "$root/.githooks/post-checkout" "$source_work/.githooks/"
git -C "$source_work" add .; git -C "$source_work" add --chmod=+x .githooks/post-checkout
git -C "$source_work" commit -qm 'the source #1'
git -C "$source_work" remote add origin "$source_origin"
git -C "$source_work" push -qu origin master
git -C "$source_work" remote set-head origin -a >/dev/null
touch "$fake/no-board"
out="$(cd "$source_work" && PATH="$root/bin:$PATH" GH_PROJECT_NUMBER='' bash "$start" example-org/shop-ai-core 173 2>&1)"; rc=$?
check 'source start exits zero' 0 "$rc"
check 'source caller names the workflow' yes "$(grep -qF 'Harness source worktree: run ai-core session-start and read its source rules.' <<< "$out" && echo yes || echo no)"
source_tree="$(git -C "$source_work" worktree list --porcelain | sed -n 's/^worktree //p' | tail -1)"
check 'source tree has no assembly' no "$([ -e "$source_tree/.ai-core" ] && echo yes || echo no)"
check 'source tree has no product map' no "$([ -e "$source_tree/AGENTS.md" ] && echo yes || echo no)"
check 'source tree has the commit-msg hook' yes "$([ -x "$source_tree/.githooks/commit-msg" ] && echo yes || echo no)"
check 'a fresh source clone has its hooks armed' .githooks "$(git -C "$source_tree" config --get core.hooksPath)"
check 'the hook stays out of every commit' yes "$(git -C "$source_tree" check-ignore -q .githooks/commit-msg && echo yes || echo no)"
check 'the tree stays clean'             '' "$(git -C "$source_tree" status --porcelain)"
long_subject="$(printf 'x%.0s' $(seq 1 73))"
out="$(cd "$source_tree" && PATH="$root/bin:$PATH" git commit -q --allow-empty -m "$long_subject" 2>&1)"; rc=$?
check 'a subject of 73 characters is refused at the commit' 1 "$rc"
check 'the hook names the refusal'       yes "$(grep -q '^commit-msg: REFUSED' <<< "$out" && echo yes || echo no)"
before="$(git -C "$source_tree" rev-parse HEAD)"
out="$(cd "$source_tree" && PATH="$root/bin:$PATH" git commit -q --allow-empty -m 'Fix #173' 2>&1)"; rc=$?
check 'a closing keyword is refused at the commit' 1 "$rc"
check 'the refused message made no commit' "$before" "$(git -C "$source_tree" rev-parse HEAD)"
out="$(cd "$source_tree" && PATH="$root/bin:$PATH" git commit -q --allow-empty -m 'Keep a short subject #173' 2>&1)"; rc=$?
check 'a short subject is taken'         0 "$rc"

# A new repository has no branch at all, and the first branch pushed into an empty repository becomes its default branch: so the
# default branch is started first, with one empty commit that goes through the real push gate, and named by the clone's own
# HEAD, which has no commit. The worktree is cut from it as from any default branch.
echo 'an empty origin: the default branch is started with a start commit that holds nothing, the push gate takes it, and the worktree is cut from it'
arm_hook() {  # arm_hook <checkout> <script>: a pre-push hook in .githooks of the checkout, untracked, armed as init arms it
  mkdir -p "$1/.githooks"; printf '#!/bin/sh\n%s\n' "$2" > "$1/.githooks/pre-push"; chmod +x "$1/.githooks/pre-push"
  printf '/.githooks/\n' >> "$1/.git/info/exclude"; git -C "$1" config core.hooksPath .githooks
}
fresh_origin="$fake/github.com/example-org/fresh.git"
fresh="$fake/fresh-checkouts/fresh"
mkdir -p "$(dirname "$fresh_origin")" "$(dirname "$fresh")"
git init -q --bare -b trunk "$fresh_origin"
git init -q -b trunk "$fresh"; dress "$fresh"; harness_data "$fresh"
git -C "$fresh" remote add origin "$fresh_origin"
arm_hook "$fresh" "exec bash '$root/bin/pre-push.sh' \"\$@\""
fresh_tree="$fake/fresh-checkouts/.worktrees/fresh/issue-163-read-the-board-whole"
fresh_before="$(snapshot "$fresh")"
out="$(cd "$fresh" && PRE_PUSH_LOAD_LIMIT=0 bash "$start" 163 2>&1)"; rc=$?
fresh_start="$(git --git-dir="$fresh_origin" rev-parse refs/heads/trunk 2>/dev/null)"
check 'exits zero'                       0 "$rc$([ "$rc" -eq 0 ] || echo " $out")"
check 'it says that it started the default branch, with the commit' "Started trunk of the empty example-org/fresh with the start commit $fresh_start." "$(grep '^Started ' <<< "$out")"
check 'the gate took the push'           yes "$(grep -q "^pre-push: trunk of this empty repository starts with ${fresh_start:0:7}" <<< "$out" && echo yes || echo no)"
check 'the worktree is cut from origin/trunk' "Worktree $fresh_tree on issue-163-read-the-board-whole, cut from origin/trunk." "$(grep '^Worktree ' <<< "$out")"
check 'origin holds the default branch and nothing else' refs/heads/trunk "$(git --git-dir="$fresh_origin" for-each-ref --format='%(refname)')"
check 'the worktree stands on the start commit' "$fresh_start" "$(git -C "$fresh_tree" rev-parse HEAD 2>/dev/null)"
check 'the commit has no parent'         "$fresh_start" "$(git -C "$fresh_tree" rev-list --max-parents=0 HEAD)"
check 'it holds the empty tree'          "$(git hash-object -t tree /dev/null)" "$(git -C "$fresh_tree" rev-parse 'HEAD^{tree}')"
check 'its subject names repository and issue' 'Start example-org/fresh (#163)' "$(git -C "$fresh_tree" log -1 --format=%s)"
check 'the branch of the issue pushes to its own branch' 'origin issue-163-read-the-board-whole' "$(git -C "$fresh" config branch.issue-163-read-the-board-whole.remote) $(git -C "$fresh" config branch.issue-163-read-the-board-whole.merge | sed 's|^refs/heads/||')"
check 'the checkout is as it was (its HEAD still has no commit)' "$fresh_before" "$(snapshot "$fresh")"
check 'no temporary worktree is left'    "$fresh_tree" "$(git -C "$fresh" worktree list --porcelain | sed -n 's/^worktree //p' | grep -v "^$fresh$")"
check 'the state is named'               "The checkout $fresh (branch trunk) has no commit yet. The new worktree starts from origin/trunk and does not see that; the checkout's branch, index, files and commits stay as they were." "$(grep '^The checkout ' <<< "$out")"
check 'it names the missing push gate (planted: the start commit holds no shim)' yes "$(grep -qF "this repository carries no push gate (.githooks/pre-push), so a push from the worktree runs no check: run 'ai-core pre-push --install' in $fresh first" <<< "$out" && echo yes || echo no)"
echo 'the whole flow: the branch of the issue is committed and pushed, integrate-issue lands it, and the default branch stays the one the HEAD named'
[ -e "$fresh_tree/.githooks/pre-push" ] || { mkdir -p "$fresh_tree/.githooks"; cp "$fresh/.githooks/pre-push" "$fresh_tree/.githooks/"; }
echo 'work' > "$fresh_tree/work.txt"; git -C "$fresh_tree" add work.txt; git -C "$fresh_tree" commit -q -m 'Work on the issue (#163)'
git -C "$fresh_tree" push -q 2>"$fake/plain-push.err"; rc=$?
check 'the branch of the issue is pushed as any branch' 0 "$rc$([ "$rc" -eq 0 ] || echo " $(cat "$fake/plain-push.err")")"
check 'the default branch is still the start commit' "$fresh_start" "$(git --git-dir="$fresh_origin" rev-parse refs/heads/trunk)"
check 'and origin names trunk, not the branch of the issue, as its default' refs/heads/trunk "$(git --git-dir="$fresh_origin" symbolic-ref HEAD)"
out="$(cd "$fresh_tree" && PRE_PUSH_LOAD_LIMIT=0 bash "$root/bin/integrate-issue.sh" 163 --reviewed-by l4 2>&1)"; rc=$?
check 'integrate-issue lands the branch: exit 0' 0 "$rc$([ "$rc" -eq 0 ] || echo " $out")"
check 'the first parent of the merge is the start commit' "$fresh_start" "$(git --git-dir="$fresh_origin" rev-parse refs/heads/trunk^1 2>&1)"
check 'the second parent is the branch'  "$(git -C "$fresh_tree" rev-parse HEAD)" "$(git --git-dir="$fresh_origin" rev-parse refs/heads/trunk^2 2>&1)"
check 'its subject names the issue'      'Read the board whole (#163)' "$(git --git-dir="$fresh_origin" log -1 --format=%s refs/heads/trunk)"
check 'it carries the reviewer'          l4 "$(git --git-dir="$fresh_origin" log -1 --format='%(trailers:key=Reviewed-by,valueonly)' refs/heads/trunk | tr -d '\n')"
check 'the history of the default branch has one root, the start commit' "$fresh_start" "$(git --git-dir="$fresh_origin" rev-list --max-parents=0 refs/heads/trunk)"
check 'the clone takes the default branch that it started' "$(git --git-dir="$fresh_origin" rev-parse refs/heads/trunk) trunk" "$(git -C "$fresh" rev-parse -q --verify HEAD) $(git -C "$fresh" symbolic-ref --short HEAD)"
check 'and its refresh finished'         '' "$(grep -E 'not refreshed|did not finish' <<< "$out")"

echo 'a push of the start commit that the gate refuses leaves origin empty and cuts nothing'
git init -q --bare -b trunk "$fake/github.com/example-org/refused.git"
git init -q -b trunk "$fake/fresh-checkouts/refused"; dress "$fake/fresh-checkouts/refused"; harness_data "$fake/fresh-checkouts/refused"
git -C "$fake/fresh-checkouts/refused" remote add origin "$fake/github.com/example-org/refused.git"
arm_hook "$fake/fresh-checkouts/refused" 'echo "pre-push: REFUSED - planted"; exit 1'
: > "$log"
out="$(cd "$fake/fresh-checkouts/refused" && bash "$start" 163 2>&1)"; rc=$?
check 'exits nonzero'                    yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'it names the refusal'             yes "$(grep -q 'origin did not take the start commit as trunk' <<< "$out" && echo yes || echo no)"
check 'origin is still empty'            '' "$(git --git-dir="$fake/github.com/example-org/refused.git" for-each-ref)"
check 'no branch of the issue, no worktree' '' "$(git -C "$fake/fresh-checkouts/refused" for-each-ref --format='%(refname)' 'refs/heads/issue-*')$(git -C "$fake/fresh-checkouts/refused" worktree list --porcelain | grep -c '^worktree ' | grep -v '^1$' || true)"
check 'the card did not move'            0 "$(grep -c 'oid=OPT_impl' "$log" || true)"

echo 'an empty origin and a clone whose HEAD branch has commits: refused before anything is made'
git init -q -b trunk "$fake/fresh-checkouts/populated"; dress "$fake/fresh-checkouts/populated"; harness_data "$fake/fresh-checkouts/populated"
git -C "$fake/fresh-checkouts/populated" remote add origin "$fake/github.com/example-org/refused.git"
git -C "$fake/fresh-checkouts/populated" commit -q --allow-empty -m 'a commit that origin lacks'
out="$(cd "$fake/fresh-checkouts/populated" && bash "$start" 163 2>&1)"; rc=$?
check 'exits nonzero'                    yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'it names the branch with commits' yes "$(grep -q 'origin holds no branch, but the branch trunk of this clone has commits' <<< "$out" && echo yes || echo no)"
check 'origin is still empty'            '' "$(git --git-dir="$fake/github.com/example-org/refused.git" for-each-ref)"

echo 'an origin that cannot be asked is no empty origin: nothing is made'
git -C "$fake/fresh-checkouts/refused" remote set-url origin "$fake/nowhere.git"
out="$(cd "$fake/fresh-checkouts/refused" && bash "$start" 163 2>&1)"; rc=$?
check 'exits nonzero'                    yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'it says so'                       yes "$(grep -q 'could not reach origin' <<< "$out" && echo yes || echo no)"
check 'no branch of the issue made'      '' "$(git -C "$fake/fresh-checkouts/refused" for-each-ref --format='%(refname)' 'refs/heads/issue-*')"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
