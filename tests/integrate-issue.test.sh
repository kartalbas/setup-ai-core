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
# A public repository lands only on green checks, a private one on its push gate: the fake gh answers the
# visibility and the checks from files, so each answer is planted. A public one that is green lands and
# names the sha; one that is red, still pending at the deadline, unreadable or of unknown visibility
# is refused with origin as it was, and one whose checks are pending first waits and then lands; a
# private one lands without any check being read. Both paths are pinned, with and without --from-origin.
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
# The checks and the visibility are planted by files: visibility (public, private, or a word that is no
# answer; private when absent), runs (what gh run list answers; a completed success when absent) and
# runs-queue (answers given first, one per call). A run query is a call of the checks, so tests count them.
case "\$*" in
  *"repo view"*"--json isPrivate"*)
    case "\$(cat "$fake/visibility" 2>/dev/null || echo private)" in
      private) echo '{"isPrivate":true}' ;; public) echo '{"isPrivate":false}' ;;
      *) echo 'visibility denied' >&2; exit 1 ;;
    esac
    exit 0 ;;
  "run list"*)
    answer="\$(cat "$fake/runs" 2>/dev/null || echo '[{"status":"completed","conclusion":"success"}]')"
    if [ -s "$fake/runs-queue" ]; then answer="\$(head -n1 "$fake/runs-queue")"; sed -i 1d "$fake/runs-queue"; fi
    if [ "\$answer" = broken ]; then echo 'HTTP 502: Bad Gateway' >&2; exit 1; fi
    echo "\$answer"
    exit 0 ;;
  "api repos/{owner}/{repo}/commits/"*"/status") echo '{"state":"pending","total_count":0}'; exit 0 ;;
esac
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
check 'normal integration refreshes the main default' "$(tip)" "$(git -C "$work" rev-parse master)"

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

# the repository the forge is asked about is the one origin names: the last two parts of its address
origin_repo="$(basename "$fake")/origin"
# land_public <number> <slug> <runs> [wait]: a public repository, the planted answer of the checks, and an
# issue branch to land; sets out, rc, wt and sha (the reviewed tip). The poll is 0 and the wait short, so
# a test that waits takes no time.
land_public() {
  wt="$(new_tree "$1" "$2")"; sha="$(git -C "$wt" rev-parse HEAD)"
  echo public > "$fake/visibility"; printf '%s\n' "$3" > "$fake/runs"; : > "$fake/runs-queue"; : > "$fake/calls.txt"
  out="$(AI_CORE_INTEGRATE_POLL=0 AI_CORE_INTEGRATE_WAIT="${4:-5}" integrate "$wt" "$1" --reviewed-by l4)"; rc=$?
  rm -f "$fake/visibility" "$fake/runs"
}
asked_checks() { grep -c '^run list ' "$fake/calls.txt" || true; }
success='[{"status":"completed","conclusion":"success"}]'

echo 'a public repository lands on green checks and names the sha it waited for'
before="$(tip)"
land_public 120 green "$success"
check 'exit 0'                         0 "$rc"
check 'the checks of the reviewed tip were asked' yes "$(grep -qF "run list --commit $sha " "$fake/calls.txt" && echo yes || echo no)"
check 'it says the checks were green, with the sha' yes "$(grep -qxF "checks: green for ${sha:0:7} on GitHub; $origin_repo is public and lands only on green checks" <<< "$out" && echo yes || echo no)"
check 'one merge commit landed'        1 "$(git --git-dir="$origin" rev-list --merges --count "$before..master")"
check 'its second parent is the tip that was green' "$sha" "$(git --git-dir="$origin" rev-parse master^2)"

echo 'a public repository with red checks is refused with nothing merged or pushed'
before="$(tip)"
land_public 121 red '[{"status":"completed","conclusion":"failure"}]'
check 'exit 1'                         1 "$rc"
check 'it says nothing landed and the checks are red' yes "$(grep -qF "nothing landed: the checks for $sha are red" <<< "$out" && echo yes || echo no)"
check 'origin did not move'            "$before" "$(tip)"
check 'the worktree is on its branch'  'issue-121-red' "$(git -C "$wt" symbolic-ref --short HEAD)"
check 'and no merge is left open'      '' "$(git -C "$wt" status --porcelain)"

echo 'checks that are pending first are waited for, and the branch lands once they are green'
before="$(tip)"
wt="$(new_tree 122 waits-for-ci)"; sha="$(git -C "$wt" rev-parse HEAD)"
echo public > "$fake/visibility"; : > "$fake/calls.txt"
printf '%s\n' '[{"status":"in_progress","conclusion":null}]' '[]' > "$fake/runs-queue"
out="$(AI_CORE_INTEGRATE_POLL=0 AI_CORE_INTEGRATE_WAIT=30 integrate "$wt" 122 --reviewed-by l4)"; rc=$?
rm -f "$fake/visibility"
check 'exit 0'                         0 "$rc"
check 'it said once that it waits'     1 "$(grep -c "^waiting: $origin_repo is public" <<< "$out" || true)"
check 'it asked three times: two pending, then green' 3 "$(asked_checks)"
check 'one merge commit landed'        1 "$(git --git-dir="$origin" rev-list --merges --count "$before..master")"

echo 'checks still pending at the deadline refuse, with nothing merged or pushed'
before="$(tip)"
land_public 123 stuck '[{"status":"in_progress","conclusion":null}]' 0
check 'exit 1'                         1 "$rc"
check 'it says they did not finish'    yes "$(grep -qF "nothing landed: the checks for $sha did not finish in 0 minute(s)" <<< "$out" && echo yes || echo no)"
check 'origin did not move'            "$before" "$(tip)"
check 'the worktree is on its branch'  'issue-123-stuck' "$(git -C "$wt" symbolic-ref --short HEAD)"

echo 'checks that cannot be read until the deadline refuse and name what the forge said'
before="$(tip)"
land_public 124 unreadable broken 0
check 'exit 1'                         1 "$rc"
check "it names the forge's words"     yes "$(grep -qF 'it said last: HTTP 502: Bad Gateway' <<< "$out" && echo yes || echo no)"
check 'it says nothing landed'         yes "$(grep -qF 'nothing landed: ' <<< "$out" && echo yes || echo no)"
check 'origin did not move'            "$before" "$(tip)"

echo 'a private repository lands without any check being read, and says its push gate is the check'
before="$(tip)"
wt="$(new_tree 125 private)"; echo private > "$fake/visibility"; : > "$fake/calls.txt"; echo broken > "$fake/runs"
out="$(AI_CORE_INTEGRATE_POLL=0 AI_CORE_INTEGRATE_WAIT=0 integrate "$wt" 125 --reviewed-by l4)"; rc=$?
rm -f "$fake/visibility" "$fake/runs"
check 'exit 0'                         0 "$rc"
check 'it says the push gate is its check' yes "$(grep -qF 'its push gate is its check; the CI of GitHub is not read' <<< "$out" && echo yes || echo no)"
check 'no check was asked'             0 "$(asked_checks)"
check 'no commit status was asked'     0 "$(grep -c 'commits/' "$fake/calls.txt" || true)"
check 'one merge commit landed'        1 "$(git --git-dir="$origin" rev-list --merges --count "$before..master")"

echo 'a visibility the forge does not establish refuses, and no check is read'
before="$(tip)"
wt="$(new_tree 126 unknown)"; echo unknown > "$fake/visibility"; : > "$fake/calls.txt"
out="$(AI_CORE_INTEGRATE_POLL=0 AI_CORE_INTEGRATE_WAIT=0 integrate "$wt" 126 --reviewed-by l4)"; rc=$?
rm -f "$fake/visibility"
check 'exit 1'                         1 "$rc"
check 'it names the repository and the words of gh' yes "$(grep -qF "the visibility of $origin_repo" <<< "$out" && grep -qF 'visibility denied' <<< "$out" && echo yes || echo no)"
check 'it says nothing landed'         yes "$(grep -qF 'nothing landed: ' <<< "$out" && echo yes || echo no)"
check 'no check was asked'             0 "$(asked_checks)"
check 'origin did not move'            "$before" "$(tip)"
check 'the worktree is on its branch'  'issue-126-unknown' "$(git -C "$wt" symbolic-ref --short HEAD)"

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
# what stands in the worktree folder of the clone besides the worktrees of issues: the temporary worktree of --from-origin
leftovers() { ls -A "$trees" | grep -vc '^issue-'; }

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
check 'from-origin integration refreshes the main default' "$(tip)" "$(git -C "$work" rev-parse master)"

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

echo '--from-origin: a public repository lands on green checks, and is refused on red ones with the held worktree untouched'
success_tip() { git -C "$1" rev-parse HEAD; }
heldwt10="$(held_tree 130 ci-green)"
tipg="$(success_tip "$heldwt10")"
held_before="$(held_state "$heldwt10")"; before="$(tip)"
echo public > "$fake/visibility"; : > "$fake/calls.txt"
out="$(AI_CORE_INTEGRATE_POLL=0 AI_CORE_INTEGRATE_WAIT=5 integrate "$work" 130 --reviewed-by l4 --from-origin)"; rc=$?
check 'green: exit 0'                  0 "$rc"
check 'the checks of the tip origin holds were asked' yes "$(grep -qF "run list --commit $tipg " "$fake/calls.txt" && echo yes || echo no)"
check 'it says the checks were green, with the sha' yes "$(grep -qxF "checks: green for ${tipg:0:7} on GitHub; $origin_repo is public and lands only on green checks" <<< "$out" && echo yes || echo no)"
check 'one merge commit landed'        1 "$(git --git-dir="$origin" rev-list --merges --count "$before..master")"
check 'the held worktree is as it was' "$held_before" "$(held_state "$heldwt10")"
heldwt11="$(held_tree 131 ci-red)"
held_before="$(held_state "$heldwt11")"; before="$(tip)"; trees_before="$(trees_listed)"
echo '[{"status":"completed","conclusion":"failure"}]' > "$fake/runs"
out="$(AI_CORE_INTEGRATE_POLL=0 AI_CORE_INTEGRATE_WAIT=5 integrate "$work" 131 --reviewed-by l4 --from-origin)"; rc=$?
check 'red: exit 1'                    1 "$rc"
check 'it says nothing landed and the checks are red' yes "$(grep -qF "nothing landed: the checks for $(success_tip "$heldwt11") are red" <<< "$out" && echo yes || echo no)"
check 'origin did not move'            "$before" "$(tip)"
check 'the held worktree is as it was' "$held_before" "$(held_state "$heldwt11")"
check 'no temporary worktree was made' "$trees_before" "$(trees_listed)"
check 'the lock is released'           no "$([ -e "$lock" ] && echo yes || echo no)"
echo unknown > "$fake/visibility"; rm -f "$fake/runs"
out="$(AI_CORE_INTEGRATE_POLL=0 AI_CORE_INTEGRATE_WAIT=5 integrate "$work" 131 --reviewed-by l4 --from-origin)"; rc=$?
check 'unknown visibility: exit 1'     1 "$rc"
check 'it names the words of gh'       yes "$(grep -qF 'visibility denied' <<< "$out" && echo yes || echo no)"
check 'origin did not move'            "$before" "$(tip)"
rm -f "$fake/visibility"
echo private > "$fake/visibility"; : > "$fake/calls.txt"
out="$(AI_CORE_INTEGRATE_POLL=0 AI_CORE_INTEGRATE_WAIT=5 integrate "$work" 131 --reviewed-by l4 --from-origin)"; rc=$?
rm -f "$fake/visibility"
check 'private: exit 0'                0 "$rc"
check 'it says the push gate is its check' yes "$(grep -qF 'its push gate is its check' <<< "$out" && echo yes || echo no)"
check 'no check was asked'             0 "$(asked_checks)"

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
check 'the gate ran in the temporary worktree beside the clone, where start-issue cuts its worktrees' yes "$([[ "$(cat "$fake/checked.txt" 2>/dev/null)" == "$trees"/integrate-103.* ]] && echo yes || echo no)"
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

# A project test finds a sibling checkout by walking up from its own checkout. The gate planted here is
# that test: it walks up from where it runs to a folder holding sibling-repo, as the census test of a
# platform repository does, and refuses where it finds none.
git -C "$work" config --unset core.hooksPath
git -C "$work" pull -q origin master
git -C "$work" rm -q scripts/install.sh
git -C "$work" commit -q -m 'Drop the failing install step'
git -C "$work" push -q origin master 2>/dev/null
mkdir "$fake/checkouts/sibling-repo"
mkdir -p "$fake/walk"
printf '#!/bin/sh\npwd > "%s"\nd="$(pwd)"\nwhile [ "$d" != / ]; do\n  [ -d "$d/sibling-repo" ] && exit 0\n  d="$(dirname "$d")"\ndone\necho "check: FAIL - 0 censused, sibling-repo is not above $(pwd)"\nexit 1\n' "$fake/checked.txt" > "$fake/walk/pre-push"
chmod +x "$fake/walk/pre-push"
printf '#!/bin/sh\npwd > "%s"\nexit 0\n' "$fake/checked.txt" > "$fake/walk/innocent-pre-push"
chmod +x "$fake/walk/innocent-pre-push"

echo '--from-origin: a gate that walks up to a sibling checkout finds it from the temporary worktree'
git -C "$work" config core.hooksPath "$fake/walk"
heldwt7="$(held_tree 106 walk)"
trees_before="$(trees_listed)"
before="$(tip)"
rm -f "$fake/checked.txt"
out="$(integrate "$work" 106 --reviewed-by l4 --from-origin)"; rc=$?
check 'exit 0'                         0 "$rc"
check 'the gate ran beside the clone, not under the temporary folder' yes "$([[ "$(cat "$fake/checked.txt" 2>/dev/null)" == "$trees"/integrate-106.* ]] && echo yes || echo no)"
check 'one merge commit landed'        1 "$(git --git-dir="$origin" rev-list --merges --count "$before..master")"
check 'the temporary worktree is gone, registered nowhere' "$trees_before" "$(trees_listed)"
check 'and no folder of it is left'    0 "$(leftovers)"

echo '--from-origin: a gate with no such check stays green'
git -C "$work" config core.hooksPath "$fake/walk"
mv "$fake/walk/pre-push" "$fake/walk/walks-up"; mv "$fake/walk/innocent-pre-push" "$fake/walk/pre-push"
heldwt8="$(held_tree 107 plain)"
before="$(tip)"
out="$(integrate "$work" 107 --reviewed-by l4 --from-origin)"; rc=$?
check 'exit 0'                         0 "$rc"
check 'one merge commit landed'        1 "$(git --git-dir="$origin" rev-list --merges --count "$before..master")"
check 'and no folder of it is left'    0 "$(leftovers)"

echo '--from-origin: an interruption removes the temporary worktree too'
heldwt9="$(held_tree 108 stopped)"
printf '#!/bin/sh\npwd > "%s"\nkill -TERM "$(cut -f1 "%s")"\nsleep 1\nexit 1\n' "$fake/checked.txt" "$lock" > "$fake/walk/pre-push"
trees_before="$(trees_listed)"
after="$(tip)"
rm -f "$fake/checked.txt"
out="$(integrate "$work" 108 --reviewed-by l4 --from-origin 2>/dev/null)"; rc=$?
check 'the gate ran in the temporary worktree' yes "$([[ "$(cat "$fake/checked.txt" 2>/dev/null)" == "$trees"/integrate-108.* ]] && echo yes || echo no)"
check 'the run ended on the signal'    143 "$rc"
check 'origin did not move'            "$after" "$(tip)"
check 'the temporary worktree is gone, registered nowhere' "$trees_before" "$(trees_listed)"
check 'and no folder of it is left'    0 "$(leftovers)"
check 'the lock is released'           no "$([ -e "$lock" ] && echo yes || echo no)"

echo 'integration refresh snapshots start only after the successful push, for both landing paths'
FF_COPY="$fake/refresh-copy"; mkdir -p "$FF_COPY"
cp -R "$root/bin" "$root/lib" "$root/templates" "$FF_COPY/"
sed 's/^fast_forward_default_branch() {/fast_forward_default_branch_real() {/' "$root/lib/common.sh" > "$FF_COPY/lib/common.sh"
sed -n '/^state() {/,/^}/p' "$root/tests/default-branch.test.sh" >> "$FF_COPY/lib/common.sh"
cat >> "$FF_COPY/lib/common.sh" <<'WRAPPER'
git() { [ -z "${RECORD_GIT:-}" ] || printf '%s\n' "$*" >> "$RECORD_GIT"; command git "$@"; }
fast_forward_default_branch() {
 local rc=0 RECORD_GIT="$FF_TRACE/calls" remote tip old
 mkdir -p "$FF_TRACE"; : > "$RECORD_GIT"
 if [ -n "${FF_PLANT_STALE:-}" ]; then
   remote="$(command git -C "$1" remote get-url origin)"
   tip="$(command git --git-dir="$remote" rev-parse HEAD)"; old="$(command git -C "$1" rev-parse HEAD)"
   command git --git-dir="$remote" update-ref refs/heads/probe "$tip"
   command git -C "$1" update-ref refs/remotes/origin/probe "$old"
 fi
 state "$1" > "$FF_TRACE/before"
 fast_forward_default_branch_real "$1" || rc=$?
 state "$1" > "$FF_TRACE/after"
 printf '%s\n' "$rc" > "$FF_TRACE/rc"
 return "$rc"
}
WRAPPER
FF_N=0
ff_fixture() {
 FF_N=$((FF_N+1)); FF_DIR="$fake/refresh-$FF_N"; mkdir -p "$FF_DIR"
 FF_DEFAULT="$1"; FF_SEED="$FF_DIR/seed"; FF_REPO="$FF_DIR/checkout"; FF_ORIGIN="$FF_DIR/origin.git"
 git init -qb "$FF_DEFAULT" "$FF_SEED"; dress "$FF_SEED"
 printf 'base\n' > "$FF_SEED/tracked"; git -C "$FF_SEED" add tracked; git -C "$FF_SEED" commit -qm base
 git clone -q --bare "$FF_SEED" "$FF_ORIGIN"; git clone -q "$FF_ORIGIN" "$FF_REPO"; dress "$FF_REPO"
 git -C "$FF_SEED" remote add origin "$FF_ORIGIN"
 for commit in one two; do printf '%s\n' "$commit" > "$FF_SEED/remote-file"; git -C "$FF_SEED" add remote-file; git -C "$FF_SEED" commit -qm "$commit"; done
 git -C "$FF_SEED" push -q origin "$FF_DEFAULT"
 FF_ISSUE="$FF_DIR/issue-200-refresh"; git -C "$FF_REPO" worktree add -qb issue-200-refresh "$FF_ISSUE"; dress "$FF_ISSUE"
 printf 'change\n' > "$FF_ISSUE/change"; git -C "$FF_ISSUE" add change; git -C "$FF_ISSUE" commit -qm 'Preserve the checkout (#200)'
 git -C "$FF_ISSUE" push -q origin HEAD
 FF_TRACE="$FF_DIR/trace"; export FF_TRACE
 unset FF_PLANT_STALE
}
ff_land() { ( cd "$FF_ISSUE" && bash "$FF_COPY/bin/integrate-issue.sh" 200 --reviewed-by reader "$@" 2>&1 ); }
for mode in normal from-origin; do
 args=(); [ "$mode" != from-origin ] || args=(--from-origin)
 for FF_DEFAULT in main master; do
  ff_fixture "$FF_DEFAULT"; out="$(ff_land ${args[@]+"${args[@]}"})"; rc=$?
  check "$mode $FF_DEFAULT succeeded" 0 "$rc"
  check "$mode $FF_DEFAULT main matches origin" "$(git --git-dir="$FF_ORIGIN" rev-parse "$FF_DEFAULT")" "$(git -C "$FF_REPO" rev-parse "$FF_DEFAULT")"
  check "$mode issue branch restored" issue-200-refresh "$(git -C "$FF_ISSUE" symbolic-ref --short HEAD)"
 done
 for state in staged unstaged untracked unmerged; do
  ff_fixture main
  case "$state" in
   staged) printf 'mine\n' > "$FF_REPO/tracked"; git -C "$FF_REPO" add tracked ;;
   unstaged) printf 'mine\n' > "$FF_REPO/tracked" ;;
   untracked) printf 'mine\n' > "$FF_REPO/loose" ;;
   unmerged)
    git -C "$FF_REPO" switch -qc conflict; printf 'other\n' > "$FF_REPO/tracked"; git -C "$FF_REPO" commit -qam other
    git -C "$FF_REPO" switch -q main; printf 'mine\n' > "$FF_REPO/tracked"; git -C "$FF_REPO" commit -qam mine
    git -C "$FF_REPO" merge conflict >/dev/null 2>&1 ;;
  esac
  export FF_PLANT_STALE=1
  out="$(ff_land ${args[@]+"${args[@]}"})"; rc=$?
  check "$mode $state integration stays successful" 0 "$rc"
  check "$mode $state snapshot unchanged" yes "$(cmp -s "$FF_TRACE/before" "$FF_TRACE/after" && echo yes || echo no)"
  check "$mode $state helper does not fetch" 0 "$(grep -c ' fetch ' "$FF_TRACE/calls" || true)"
  check "$mode $state names skipped checkout" yes "$(grep -qF "$FF_REPO was not refreshed" <<< "$out" && echo yes || echo no)"
  check "$mode $state reports integrated" yes "$(grep -q '^integrated:' <<< "$out" && echo yes || echo no)"
 done
 ff_fixture main
 printf '#!/bin/sh\nexit 1\n' > "$FF_ORIGIN/hooks/pre-receive"; chmod +x "$FF_ORIGIN/hooks/pre-receive"
 out="$(ff_land ${args[@]+"${args[@]}"})"; rc=$?
 check "$mode rejected push refuses" 1 "$rc"
 check "$mode rejected push never refreshes" no "$([ -d "$FF_TRACE" ] && echo yes || echo no)"
done
# Losing the call leaves a clean checkout behind, despite a successful push.
cp "$FF_COPY/bin/integrate-issue.sh" "$fake/integrate-with-refresh"
sed '/^if ! fast_forward_default_branch /,/^fi/d' "$root/bin/integrate-issue.sh" > "$FF_COPY/bin/integrate-issue.sh"
ff_fixture main; out="$(ff_land)"; rc=$?
check 'missing integration call mutant still pushes' 0 "$rc"
check 'missing integration call mutant is caught' no "$([ "$(git -C "$FF_REPO" rev-parse main)" = "$(git --git-dir="$FF_ORIGIN" rev-parse main)" ] && echo yes || echo no)"
cp "$fake/integrate-with-refresh" "$FF_COPY/bin/integrate-issue.sh"
printf '\nfast_forward_default_branch() { echo "not refreshed: $1: planted failure" >&2; return 1; }\n' >> "$FF_COPY/lib/common.sh"
ff_fixture main; out="$(ff_land)"; rc=$?
check 'post-push refresh failure keeps success' 0 "$rc"
check 'post-push refresh failure reports integrated' yes "$(grep -q '^integrated:' <<< "$out" && echo yes || echo no)"
check 'post-push refresh failure never claims nothing landed' no "$(grep -q 'nothing landed' <<< "$out" && echo yes || echo no)"

echo
[ "$failed" -eq 0 ] && echo 'all passed' || echo "$failed failed"
[ "$failed" -eq 0 ]
