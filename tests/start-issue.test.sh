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
  *comments*)               echo '[]' ;;
  *"--jq .node_id"*)        echo 'I_node163' ;;
  *"projectV2(number:"*)    echo 'PVT_kwstart' ;;
  *"fields(first:50)"*)     printf 'Status\tFID\ttodo\tOPT_todo\nStatus\tFID\timplementing\tOPT_impl\n' ;;
  *addProjectV2ItemById*)   echo 'PVTI_item163' ;;
  *projectItems*)           printf '' ;;
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
# The main checkout carries the harness data a worktree inherits; Graft stays off, nothing reaches the network
mkdir -p "$work/.ai-core"; printf 'GRAFT_EXECUTION_MODE="skip"
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
check 'it says which'    yes "$(printf '%s\n' "$out" | grep -q 'the working copy has changes' && echo yes || echo no)"
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
check 'it says how far' yes "$(printf '%s\n' "$out" | grep -q 'master is 1 commit(s) behind origin/master' && echo yes || echo no)"
check 'no branch made'  master "$(branches)"
git -C "$work" pull -q --ff-only origin master

echo "somebody else's issue opens no worktree"
: > "$log"
out="$(ASSIGNEE=somebody run 163)"; rc=$?
check 'exits nonzero'  yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'it names both'  yes "$(printf '%s\n' "$out" | grep -q '#163 is assigned to @somebody, not to @tester' && echo yes || echo no)"
check 'no branch made' master "$(branches)"
check 'the card did not move' 0 "$(grep -c 'oid=OPT_impl' "$log" || true)"

echo 'the worktree, the card and the thread come out of one run'
: > "$log"
out="$(run 163)"; rc=$?
tree="$checkouts/.worktrees/example-repo/issue-163-read-the-board-whole"
check 'exits zero'        0 "$rc"
check 'the worktree line' yes "$(printf '%s\n' "$out" | sed -n '1p' | grep -q "^Worktree .*issue-163-read-the-board-whole on issue-163-read-the-board-whole, cut from origin/master.$" && echo yes || echo no)"
check 'it is there'       yes "$([ -d "$tree" ] && echo yes || echo no)"
check 'and outside the checkout' no "$(printf '%s' "$tree" | grep -q "^$work/" && echo yes || echo no)"
check 'two worktrees'     2 "$(worktrees)"
check 'the branch'        'issue-163-read-the-board-whole master' "$(branches)"
check 'the card moved'    '#163 -> implementing' "$(printf '%s\n' "$out" | sed -n '2p')"
check 'to that option'    yes "$(grep -q 'oid=OPT_impl' "$log" && echo yes || echo no)"
check 'the thread'        1 "$(printf '%s\n' "$out" | grep -c '^#163 Read the board whole$' || true)"
check 'the worktree is on the new branch' 'issue-163-read-the-board-whole' \
  "$(git -C "$tree" rev-parse --abbrev-ref HEAD)"

echo 'a worktree for that number already there is not opened twice'
out="$(run 163)"; rc=$?
check 'exits nonzero' yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'it names it'   yes "$(printf '%s\n' "$out" | grep -q 'a branch for this issue exists already: issue-163-read-the-board-whole' && echo yes || echo no)"
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

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
