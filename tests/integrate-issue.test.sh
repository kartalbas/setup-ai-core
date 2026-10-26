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
# private one, and a public one of a project whose config.env sets CI_GATE="none", lands without any
# check being read, and any other CI_GATE refuses. Both paths are pinned, with and without --from-origin.
#
#   bash tests/integrate-issue.test.sh

set -uo pipefail

# The commits of the scratch repositories carry their configured identity, which the real gate holds them
# against: an identity in the caller's environment would make every one of them a stranger's.
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fake="$(mktemp -d)"
# Every run of the gate leaves a record under AI_CORE_HOME; a test writes none into the machine's own
export AI_CORE_HOME="$fake/ai-core-home"
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
# runs-queue (answers given first, one per call), during-wait (a script run once, at the first run query:
# what happens to origin while the checks are waited for) and during-visibility (the same, at the visibility query). A run query is a call of the checks, so tests count them.
case "\$*" in
  *"repo view"*"--json isPrivate"*)
    if [ -e "$fake/during-visibility" ]; then mv "$fake/during-visibility" "$fake/during-visibility.ran"; bash "$fake/during-visibility.ran" >/dev/null 2>&1; fi
    case "\$(cat "$fake/visibility" 2>/dev/null || echo private)" in
      private) echo '{"isPrivate":true}' ;; public) echo '{"isPrivate":false}' ;;
      *) echo 'visibility denied' >&2; exit 1 ;;
    esac
    exit 0 ;;
  "run list"*)
    if [ -e "$fake/during-wait" ]; then mv "$fake/during-wait" "$fake/during-wait.ran"; bash "$fake/during-wait.ran" >/dev/null 2>&1; fi
    case " \$* " in *" --workflow "*) echo 'could not find any workflows named check' >&2; exit 1 ;; esac   # as gh does where a repository has no such workflow
    answer="\$(cat "$fake/runs" 2>/dev/null || echo '[{"status":"completed","conclusion":"success","workflowName":"check"}]')"
    if [ -s "$fake/runs-queue" ]; then answer="\$(head -n1 "$fake/runs-queue")"; sed -i 1d "$fake/runs-queue"; fi
    if [ "\$answer" = broken ]; then echo 'HTTP 502: Bad Gateway' >&2; exit 1; fi
    echo "\$answer"
    exit 0 ;;
  "api repos/"*"/commits/"*"/status") echo '{"state":"pending","total_count":0}'; exit 0 ;;
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
dress "$origin"
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
# rounds_in <dir> <limit>: INTEGRATE_MAX_ROUNDS in the config.env of the checkout a landing runs in; a run that has none lands
# again by itself up to the default of 3 rounds
rounds_in() { mkdir -p "$1/.ai-core"; printf 'INTEGRATE_MAX_ROUNDS="%s"\n' "$2" >> "$1/.ai-core/config.env"; }

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
ci_tip() { git --git-dir="$origin" rev-parse -q --verify "refs/heads/ci/integrate-$1" 2>/dev/null || true; }
# plant_hook <branch> [shell]: at the first query of the checks, what stands on origin's ci/integrate-<branch> and in the
# issue's worktree is written down, then the shell runs: what happens to origin while the checks are waited for
plant_hook() {
  printf '#!/bin/sh\ngit --git-dir="%s" rev-parse -q --verify "refs/heads/ci/integrate-%s" > "%s"\n%s\n' "$origin" "$1" "$fake/ci-during" "${2:-}" > "$fake/during-wait"
}
# push_to_master: a commit another session lands on origin's default branch, from a clone of its own
push_to_master="d=\$(mktemp -d) && git clone -q '$origin' \"\$d/c\" && cd \"\$d/c\" && git config user.email t@example.invalid && git config user.name t && echo other > \"other-\$\$.txt\" && git add -A && git commit -q -m 'Other #1' && git push -q origin master"
# land_public <number> <slug> <runs> [wait] [shell]: a public repository, the branch pushed, the planted answer of
# the checks; sets out, rc, wt and sha (the reviewed tip). The poll is 0 and the wait short, so a test that waits
# takes no time.
land_public() {
  wt="$(new_tree "$1" "$2")"; sha="$(git -C "$wt" rev-parse HEAD)"
  git -C "$wt" push -q origin "issue-$1-$2" 2>/dev/null
  [ -z "${rounds:-}" ] || rounds_in "$wt" "$rounds"
  echo public > "$fake/visibility"; printf '%s\n' "$3" > "$fake/runs"; : > "$fake/runs-queue"; : > "$fake/calls.txt"; rm -f "$fake/ci-during"
  plant_hook "issue-$1-$2" "${5:-}"
  [ -z "${arm_shim:-}" ] || : > "$fake/after-worktree"   # the shim acts at the first worktree the landing makes, not at the test's own
  [ -z "${arm_ls:-}" ] || : > "$fake/after-ls-remote"
  out="$(AI_CORE_INTEGRATE_POLL=0 AI_CORE_INTEGRATE_WAIT="${4:-5}" integrate "$wt" "$1" --reviewed-by l4)"; rc=$?
  rm -f "$fake/visibility" "$fake/runs" "$fake/during-wait"
}
asked_checks() { grep -c '^run list ' "$fake/calls.txt" || true; }
success='[{"status":"completed","conclusion":"success","workflowName":"check"}]'

echo 'a public repository lands the merge commit its ci/ branch got, on green checks, and names it'
before="$(tip)"
land_public 120 green "$success"
check 'exit 0'                         0 "$rc"
check 'the merge commit was on ci/integrate-<branch> during the wait' "$(tip)" "$(cat "$fake/ci-during")"
check 'exactly that commit landed'     "$(cat "$fake/ci-during")" "$(tip)"
check 'the checks of that commit were asked, from the repository origin names' yes "$(grep -qF "run list -R $origin_repo --commit $(tip) " "$fake/calls.txt" && echo yes || echo no)"
check 'it says the checks were green, with the commit and the ci/ branch' yes "$(grep -qxF "checks: green for $(tip | cut -c1-7) on ci/integrate-issue-120-green at GitHub; $origin_repo is public and lands only on green checks" <<< "$out" && echo yes || echo no)"
check 'one merge commit landed'        1 "$(git --git-dir="$origin" rev-list --merges --count "$before..master")"
check 'its first parent is the old tip' "$before" "$(git --git-dir="$origin" rev-parse master^1)"
check 'its second parent is the reviewed tip' "$sha" "$(git --git-dir="$origin" rev-parse master^2)"
check 'the subject and the trailer are the same as without checks' 'Read the board whole (#120)' "$(git --git-dir="$origin" log -1 --format=%s master)"
check 'the trailer'                    'l4' "$(git --git-dir="$origin" log -1 --format='%(trailers:key=Reviewed-by,valueonly)' master | tr -d '\n')"
check 'ci/integrate-<branch> is gone after the landing' '' "$(ci_tip issue-120-green)"
check 'the worktree is on its branch'  'issue-120-green' "$(git -C "$wt" symbolic-ref --short HEAD)"

echo 'a public repository with red checks is refused, ci/integrate-<branch> deleted, nothing on the default branch'
before="$(tip)"
land_public 121 red '[{"status":"completed","conclusion":"failure","workflowName":"check"}]'
check 'exit 1'                         1 "$rc"
check 'it says nothing landed and the checks are red' yes "$(grep -qF "nothing landed: the checks for $(cat "$fake/ci-during") on ci/integrate-issue-121-red are red" <<< "$out" && echo yes || echo no)"
check 'the merge commit had been on ci/integrate-<branch>' yes "$([ -n "$(cat "$fake/ci-during")" ] && echo yes || echo no)"
check 'origin did not move'            "$before" "$(tip)"
check 'ci/integrate-<branch> is deleted'         '' "$(ci_tip issue-121-red)"
check 'the worktree is on its branch and was never switched' 'issue-121-red' "$(git -C "$wt" symbolic-ref --short HEAD)"
check 'and no merge is left open'      '' "$(git -C "$wt" status --porcelain)"

echo 'checks that are pending first are waited for, and the commit lands once they are green'
before="$(tip)"
wt="$(new_tree 122 waits-for-ci)"; sha="$(git -C "$wt" rev-parse HEAD)"
git -C "$wt" push -q origin issue-122-waits-for-ci 2>/dev/null
echo public > "$fake/visibility"; : > "$fake/calls.txt"
printf '%s\n' '[{"status":"in_progress","conclusion":null,"workflowName":"check"}]' '[]' > "$fake/runs-queue"
out="$(AI_CORE_INTEGRATE_POLL=0 AI_CORE_INTEGRATE_WAIT=30 integrate "$wt" 122 --reviewed-by l4)"; rc=$?
rm -f "$fake/visibility"
check 'exit 0'                         0 "$rc"
check 'it said once that it waits'     1 "$(grep -c "^waiting: $origin_repo is public" <<< "$out" || true)"
check 'it asked three times: two pending, then green' 3 "$(asked_checks)"
check 'one merge commit landed'        1 "$(git --git-dir="$origin" rev-list --merges --count "$before..master")"
check 'ci/integrate-<branch> is gone'            '' "$(ci_tip issue-122-waits-for-ci)"

echo 'checks still pending at the deadline refuse, ci/integrate-<branch> deleted, nothing on the default branch'
before="$(tip)"
land_public 123 stuck '[{"status":"in_progress","conclusion":null,"workflowName":"check"}]' 0
check 'exit 1'                         1 "$rc"
check 'it says they did not finish'    yes "$(grep -qF "nothing landed: the checks for $(cat "$fake/ci-during") on ci/integrate-issue-123-stuck did not finish in 0 minute(s)" <<< "$out" && echo yes || echo no)"
check 'it says a new run makes a new merge commit and names the setting' yes "$(grep -qF 'A new run makes a new merge commit and waits for a new CI run; set AI_CORE_INTEGRATE_WAIT (seconds, 0 now) higher' <<< "$out" && echo yes || echo no)"
check 'origin did not move'            "$before" "$(tip)"
check 'ci/integrate-<branch> is deleted'         '' "$(ci_tip issue-123-stuck)"
check 'the worktree is on its branch'  'issue-123-stuck' "$(git -C "$wt" symbolic-ref --short HEAD)"

echo 'checks that cannot be read until the deadline refuse and name what the forge said'
before="$(tip)"
land_public 124 unreadable broken 0
check 'exit 1'                         1 "$rc"
check "it names the forge's words"     yes "$(grep -qF 'it said last: HTTP 502: Bad Gateway' <<< "$out" && echo yes || echo no)"
check 'it says nothing landed'         yes "$(grep -qF 'nothing landed: ' <<< "$out" && echo yes || echo no)"
check 'origin did not move'            "$before" "$(tip)"
check 'ci/integrate-<branch> is deleted'         '' "$(ci_tip issue-124-unreadable)"

echo 'a private repository pushes nothing to ci/, reads no check, and says its push gate is the check'
before="$(tip)"
wt="$(new_tree 125 private)"; echo private > "$fake/visibility"; : > "$fake/calls.txt"; echo broken > "$fake/runs"
git -C "$wt" push -q origin issue-125-private 2>/dev/null
out="$(AI_CORE_INTEGRATE_POLL=0 AI_CORE_INTEGRATE_WAIT=0 integrate "$wt" 125 --reviewed-by l4)"; rc=$?
rm -f "$fake/visibility" "$fake/runs"
check 'exit 0'                         0 "$rc"
check 'it says the push gate is its check' yes "$(grep -qF 'its push gate is its check; the CI of GitHub is not read' <<< "$out" && echo yes || echo no)"
check 'no check was asked'             0 "$(asked_checks)"
check 'no commit status was asked'     0 "$(grep -c 'commits/' "$fake/calls.txt" || true)"
check 'no ci/ branch exists or was made' '' "$(git --git-dir="$origin" for-each-ref --format='%(refname)' refs/heads/ci)"
check 'one merge commit landed, made in the issue worktree as before' 1 "$(git --git-dir="$origin" rev-list --merges --count "$before..master")"

echo '.ai-core/' >> "$work/.git/info/exclude"   # the project's config.env is in the working tree, not tracked
echo 'a public repository of a project with CI_GATE="none" pushes nothing to ci/, reads no check, and says its push gate is the check'
before="$(tip)"
wt="$(new_tree 135 gate-none)"; echo public > "$fake/visibility"; : > "$fake/calls.txt"; echo broken > "$fake/runs"
mkdir -p "$wt/.ai-core"; echo 'CI_GATE="none"' > "$wt/.ai-core/config.env"
git -C "$wt" push -q origin issue-135-gate-none 2>/dev/null
out="$(AI_CORE_INTEGRATE_POLL=0 AI_CORE_INTEGRATE_WAIT=0 integrate "$wt" 135 --reviewed-by l4)"; rc=$?
rm -f "$fake/visibility" "$fake/runs"
check 'exit 0'                         0 "$rc"
check 'it says the project reads no CI, its push gate is its check' yes "$(grep -qF "checks: $origin_repo is public and the CI_GATE of the project is none, its push gate is its check; the CI of GitHub is not read" <<< "$out" && echo yes || echo no)"
check 'no check was asked'             0 "$(asked_checks)"
check 'no ci/ branch exists or was made' '' "$(git --git-dir="$origin" for-each-ref --format='%(refname)' refs/heads/ci)"
check 'one merge commit landed'        1 "$(git --git-dir="$origin" rev-list --merges --count "$before..master")"

echo 'a CI_GATE that is neither public nor none refuses before anything is made, and names the key'
before="$(tip)"
wt="$(new_tree 136 gate-off)"; echo public > "$fake/visibility"; : > "$fake/calls.txt"
mkdir -p "$wt/.ai-core"; echo 'CI_GATE="off"' > "$wt/.ai-core/config.env"
git -C "$wt" push -q origin issue-136-gate-off 2>/dev/null
out="$(AI_CORE_INTEGRATE_POLL=0 AI_CORE_INTEGRATE_WAIT=0 integrate "$wt" 136 --reviewed-by l4)"; rc=$?
rm -f "$fake/visibility"
check 'exit 1'                         1 "$rc"
check 'it names the key, the value and the two values' yes "$(grep -qF "nothing landed: CI_GATE is 'off' in the config.env of the project; it is public or none" <<< "$out" && echo yes || echo no)"
check 'no check was asked'             0 "$(asked_checks)"
check 'no ci/ branch exists or was made' '' "$(git --git-dir="$origin" for-each-ref --format='%(refname)' refs/heads/ci)"
check 'origin did not move'            "$before" "$(tip)"

echo 'a CI_GATE in the environment is no setting of the project: red checks still refuse where config.env has no key'
before="$(tip)"
CI_GATE=none land_public 171 env-gate '[{"status":"completed","conclusion":"failure","workflowName":"check"}]'
check 'exit 1'                         1 "$rc"
check 'the checks were read and are red' yes "$(grep -qF "nothing landed: the checks for $(cat "$fake/ci-during") on ci/integrate-issue-171-env-gate are red" <<< "$out" && echo yes || echo no)"
check 'origin did not move'            "$before" "$(tip)"

echo 'CI_GATE is read without regard to case, as the other keys of config.env'
before="$(tip)"
wt="$(new_tree 172 gate-none-case)"; echo public > "$fake/visibility"; : > "$fake/calls.txt"
mkdir -p "$wt/.ai-core"; echo 'CI_GATE="None"' > "$wt/.ai-core/config.env"
git -C "$wt" push -q origin issue-172-gate-none-case 2>/dev/null
out="$(AI_CORE_INTEGRATE_POLL=0 AI_CORE_INTEGRATE_WAIT=0 integrate "$wt" 172 --reviewed-by l4)"; rc=$?
rm -f "$fake/visibility"
check 'exit 0'                         0 "$rc"
check 'no check was asked'             0 "$(asked_checks)"
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

echo 'a public repository whose branch tip is not on origin is refused at once, before any merge or wait'
before="$(tip)"
wt="$(new_tree 127 unpushed)"; echo public > "$fake/visibility"; : > "$fake/calls.txt"
git -C "$wt" push -q origin issue-127-unpushed 2>/dev/null
echo more > "$wt/more.txt"; git -C "$wt" add -A; git -C "$wt" commit -q -m 'Only here #127'
sha="$(git -C "$wt" rev-parse HEAD)"
out="$(AI_CORE_INTEGRATE_POLL=0 AI_CORE_INTEGRATE_WAIT=5 integrate "$wt" 127 --reviewed-by l4)"; rc=$?
check 'exit 1'                         1 "$rc"
check 'it says the commit has no checks' yes "$(grep -qF "nothing landed: $sha is not on origin, so it has no checks; push the branch, then run this again" <<< "$out" && echo yes || echo no)"
check 'no check was asked'             0 "$(asked_checks)"
check 'nothing went to ci/'            '' "$(ci_tip issue-127-unpushed)"
check 'origin did not move'            "$before" "$(tip)"
check 'the worktree is on its branch'  'issue-127-unpushed' "$(git -C "$wt" symbolic-ref --short HEAD)"
git -C "$wt" push -q origin issue-127-unpushed 2>/dev/null
echo "$success" > "$fake/runs"
out="$(AI_CORE_INTEGRATE_POLL=0 AI_CORE_INTEGRATE_WAIT=5 integrate "$wt" 127 --reviewed-by l4)"; rc=$?
rm -f "$fake/visibility" "$fake/runs"
check 'pushed, the same branch lands'  0 "$rc"

echo 'the default branch moving while the checks run, in a landing that may make one round only, refuses with ci/integrate-<branch> deleted and nothing landed'
before="$(tip)"
rounds=1 land_public 128 base-moves "$success" 5 "$push_to_master"
moved="$(tip)"
check 'the default branch did move'    no "$([ "$before" = "$moved" ] && echo yes || echo no)"
check 'exit 1'                         1 "$rc"
check 'it names the old and the new tip and the commit that was checked, and that round 1 was the last' yes "$(grep -qF "nothing landed: origin/master moved from $before to $moved while the checks of $(cat "$fake/ci-during") ran; round 1 was the last that INTEGRATE_MAX_ROUNDS (1) allows" <<< "$out" && grep -qF 'Run this again' <<< "$out" && echo yes || echo no)"
check 'only the other session landed'  0 "$(git --git-dir="$origin" rev-list --merges --count "$before..master")"
check 'ci/integrate-<branch> is deleted'         '' "$(ci_tip issue-128-base-moves)"
check 'the lock is released'           no "$([ -e "$work/.git/ai-core-landing" ] && echo yes || echo no)"
check 'the worktree is on its branch'  'issue-128-base-moves' "$(git -C "$wt" symbolic-ref --short HEAD)"

echo 'a reviewed tip that moves on origin while the checks run is refused, ci/integrate-<branch> deleted'
before="$(tip)"
land_public 129 tip-moves "$success" 5 "d=\$(mktemp -d) && cd \"\$d\" && git clone -q '$origin' c && cd c && git config user.email t@example.invalid && git config user.name t && git switch -q issue-129-tip-moves && echo m > m.txt && git add -A && git commit -q -m 'Moved #129' && git push -q origin issue-129-tip-moves"
moved="$(git --git-dir="$origin" rev-parse issue-129-tip-moves)"
check 'the tip did move'               no "$([ "$sha" = "$moved" ] && echo yes || echo no)"
check 'exit 1'                         1 "$rc"
check 'it names the old and the new tip' yes "$(grep -qF "nothing landed: origin/issue-129-tip-moves moved from $sha to $moved while its checks were waited for; run this again" <<< "$out" && echo yes || echo no)"
check 'origin did not move'            "$before" "$(tip)"
check 'ci/integrate-<branch> is deleted'         '' "$(ci_tip issue-129-tip-moves)"

echo 'a local commit on the branch while the checks run is refused too, ci/integrate-<branch> deleted'
before="$(tip)"
land_public 130 local-moves "$success" 5 "cd '$trees/issue-130-local-moves' && echo m > m.txt && git add -A && git commit -q -m 'Local #130'"
moved="$(git -C "$wt" rev-parse HEAD)"
check 'the local tip did move'         no "$([ "$sha" = "$moved" ] && echo yes || echo no)"
check 'exit 1'                         1 "$rc"
check 'it names the old and the new tip' yes "$(grep -qF "nothing landed: issue-130-local-moves moved from $sha to $moved while its checks were waited for; run this again" <<< "$out" && echo yes || echo no)"
check 'origin did not move'            "$before" "$(tip)"
check 'ci/integrate-<branch> is deleted'         '' "$(ci_tip issue-130-local-moves)"

echo 'a ci/integrate-<branch> left by an earlier attempt is replaced, and a ci/integrate-<branch> that cannot be deleted is named'
before="$(tip)"
wt="$(new_tree 131 stale)"; git -C "$wt" push -q origin issue-131-stale 2>/dev/null
stale="$(git --git-dir="$origin" commit-tree -m stale "$(git --git-dir="$origin" rev-parse "master^{tree}")")"   # no ancestor of the merge: replacing it takes a force
git --git-dir="$origin" update-ref refs/heads/ci/integrate-issue-131-stale "$stale"
git --git-dir="$origin" config receive.denyDeletes true
echo public > "$fake/visibility"; : > "$fake/calls.txt"
out="$(AI_CORE_INTEGRATE_POLL=0 AI_CORE_INTEGRATE_WAIT=5 integrate "$wt" 131 --reviewed-by l4)"; rc=$?
rm -f "$fake/visibility"
git --git-dir="$origin" config --unset receive.denyDeletes
check 'exit 0'                         0 "$rc"
check 'the stale branch was replaced by the merge commit that landed' "$(tip)" "$(ci_tip issue-131-stale)"
check 'the undeletable branch is named, on one line' 1 "$(grep -c '^ci/integrate-issue-131-stale could not be deleted on origin, delete it by hand: ' <<< "$out" || true)"
git --git-dir="$origin" update-ref -d refs/heads/ci/integrate-issue-131-stale

# A git on the PATH of a landing that acts after one of its commands, once, where the test armed it: after the
# first worktree the landing adds (after-worktree) and after the read of ci/integrate-<branch> (after-ls-remote), the two
# moments no hook of git can reach.
real_git="$(command -v git)"; saved_path="$PATH"
mkdir -p "$fake/shim"
cat > "$fake/shim/git" <<SHIM
#!/bin/sh
case " \$* " in
  *" ls-remote "*) [ ! -e "$fake/ls-remote-warns" ] || echo 'warning: redirecting to https://example.invalid/renamed.git/' >&2 ;;
esac
case " \$* " in
  *" ls-remote "*"refs/heads/ci/"*) if [ -e "$fake/ls-remote-fails" ]; then echo 'fatal: planted' >&2; exit 128; fi ;;
esac
"$real_git" "\$@"; rc=\$?
case " \$* " in
  *" worktree add "*) if [ -e "$fake/after-worktree" ]; then rm -f "$fake/after-worktree"; sh "$fake/after-worktree.sh"; fi ;;
  *" ls-remote "*"refs/heads/ci/"*) if [ -e "$fake/after-ls-remote" ]; then rm -f "$fake/after-ls-remote"; sh "$fake/after-ls-remote.sh"; fi ;;
esac
exit \$rc
SHIM
chmod +x "$fake/shim/git"

echo 'a ci/integrate-<branch> somebody else wrote between the read and the push is never overwritten, and is named when it stays'
before="$(tip)"
other_tip="$(git --git-dir="$origin" commit-tree -m other "$(git --git-dir="$origin" rev-parse "master^{tree}")")"
printf 'git --git-dir="%s" update-ref refs/heads/ci/integrate-issue-132-a-lease %s\n' "$origin" "$other_tip" > "$fake/after-ls-remote.sh"
arm_ls=1; PATH="$fake/shim:$saved_path"
land_public 132 a-lease "$success"
arm_ls=""; PATH="$saved_path"; rm -f "$fake/after-ls-remote"
check 'exit 1'                         1 "$rc"
check 'it says the branch changed after it was read' yes "$(grep -qF 'nothing landed: ci/integrate-issue-132-a-lease on origin changed after it was read' <<< "$out" && echo yes || echo no)"
check "the other writer's branch was not overwritten" "$other_tip" "$(ci_tip issue-132-a-lease)"
check 'and was left in place, said in one line' 1 "$(grep -c '^ci/integrate-issue-132-a-lease on origin is not the merge commit .* of this landing, so it was left in place' <<< "$out" || true)"
check 'no check was asked'             0 "$(asked_checks)"
check 'origin did not move'            "$before" "$(tip)"
git --git-dir="$origin" update-ref -d refs/heads/ci/integrate-issue-132-a-lease

echo 'the same race that the server meets first (the ref appears after the push began) is refused alike'
mkdir -p "$fake/lease-hooks"
printf '#!/bin/sh\nwhile read -r a b ref c; do\n  if [ "$ref" = refs/heads/ci/integrate-issue-133-lease ]; then git --git-dir="%s" update-ref refs/heads/ci/integrate-issue-133-lease %s; fi\ndone\nexit 0\n' "$origin" "$other_tip" > "$fake/lease-hooks/pre-push"
chmod +x "$fake/lease-hooks/pre-push"; git -C "$work" config core.hooksPath "$fake/lease-hooks"
land_public 133 lease "$success"
git -C "$work" config --unset core.hooksPath
check 'exit 1'                         1 "$rc"
check 'it says the branch changed after it was read' yes "$(grep -qF 'nothing landed: ci/integrate-issue-133-lease on origin changed after it was read' <<< "$out" && echo yes || echo no)"
check "the other writer's branch was not overwritten" "$other_tip" "$(ci_tip issue-133-lease)"
check 'and was left in place, said in one line' 1 "$(grep -c '^ci/integrate-issue-133-lease on origin is not the merge commit .* of this landing, so it was left in place' <<< "$out" || true)"
check 'no check was asked'             0 "$(asked_checks)"
check 'origin did not move'            "$before" "$(tip)"
git --git-dir="$origin" update-ref -d refs/heads/ci/integrate-issue-133-lease

echo 'a ci/integrate-<branch> somebody else replaced during the wait is not deleted, and the landing is not changed'
other_hook="git --git-dir='$origin' update-ref refs/heads/ci/integrate-issue-134-delete-lease $other_tip"
land_public 134 delete-lease "$success" 5 "$other_hook"
check 'exit 0'                         0 "$rc"
check "the other writer's branch stays" "$other_tip" "$(ci_tip issue-134-delete-lease)"
check 'it says so in one line'         1 "$(grep -c '^ci/integrate-issue-134-delete-lease on origin is not the merge commit .* of this landing, so it was left in place' <<< "$out" || true)"
check 'the commit that was checked landed' "$(cat "$fake/ci-during")" "$(tip)"
git --git-dir="$origin" update-ref -d refs/heads/ci/integrate-issue-134-delete-lease

echo 'a push to ci/ that fails leaves nothing to delete, and says nothing about a delete'
before="$(tip)"
mkdir -p "$fake/refuse-ci-hooks"
printf '#!/bin/sh\nwhile read -r a b ref c; do\n  case "$ref" in refs/heads/ci/*) echo "pre-push: REFUSED - planted"; exit 1 ;; esac\ndone\nexit 0\n' > "$fake/refuse-ci-hooks/pre-push"
chmod +x "$fake/refuse-ci-hooks/pre-push"; git -C "$work" config core.hooksPath "$fake/refuse-ci-hooks"
land_public 135 refused "$success"
git -C "$work" config --unset core.hooksPath
check 'exit 1'                         1 "$rc"
check 'it says the merge commit could not be pushed to ci/' yes "$(grep -qF 'could not be pushed to ci/integrate-issue-135-refused for its checks, and nothing reached master' <<< "$out" && echo yes || echo no)"
check 'no word about a delete'         0 "$(grep -c 'deleted on origin\|left in place' <<< "$out" || true)"
check 'no check was asked'             0 "$(asked_checks)"
check 'origin did not move'            "$before" "$(tip)"

echo 'the base the default branch is compared with is the one the merge was made on, not the one read after it'
before="$(tip)"
printf '%s\ngit -C "%s" fetch -q origin\n' "$push_to_master" "$work" > "$fake/after-worktree.sh"
arm_shim=1; PATH="$fake/shim:$saved_path"
rounds=1 land_public 136 base-read "$success"
arm_shim=""; PATH="$saved_path"; rm -f "$fake/after-worktree"
moved="$(tip)"
check 'exit 1'                         1 "$rc"
check 'it names the base the merge was made on and the new tip' yes "$(grep -qF "nothing landed: origin/master moved from $before to $moved while the checks of $(cat "$fake/ci-during") ran" <<< "$out" && echo yes || echo no)"
check 'only the other session landed'  0 "$(git --git-dir="$origin" rev-list --merges --count "$before..master")"
check 'the default branch did move'    no "$([ "$before" = "$moved" ] && echo yes || echo no)"

echo 'exactly the merge commit that was checked lands, whatever the install step left in the temporary worktree'
git -C "$work" pull -q origin master 2>/dev/null
mkdir -p "$work/scripts"; printf '#!/usr/bin/env bash\ngit commit -q --allow-empty -m "Extra from the install step #1"\n' > "$work/scripts/install.sh"
git -C "$work" add -A && git -C "$work" commit -q -m 'Add an install step that commits'; git -C "$work" push -q origin master 2>/dev/null
land_public 137 exact "$success"
check 'exit 0'                         0 "$rc"
check 'the install step ran'           yes "$(grep -q '^installing: ' <<< "$out" && echo yes || echo no)"
check 'the commit on the default branch is the one on ci/integrate-<branch>' "$(cat "$fake/ci-during")" "$(tip)"
check 'and is the merge, not the commit the install step made' yes "$([ "$(git --git-dir="$origin" log -1 --format=%s master)" = 'Read the board whole (#137)' ] && echo yes || echo no)"
git -C "$work" pull -q origin master 2>/dev/null
git -C "$work" rm -q scripts/install.sh && git -C "$work" commit -q -m 'Drop the install step that commits' && git -C "$work" push -q origin master 2>/dev/null

echo "a ci/<issue branch> a person pushed for the CI is never touched: the landing writes ci/integrate-<issue branch>"
before="$(tip)"
wt="$(new_tree 138 persons)"; git -C "$wt" push -q origin issue-138-persons 2>/dev/null
git --git-dir="$origin" update-ref refs/heads/ci/issue-138-persons "$before"
echo public > "$fake/visibility"; : > "$fake/calls.txt"
out="$(AI_CORE_INTEGRATE_POLL=0 AI_CORE_INTEGRATE_WAIT=5 integrate "$wt" 138 --reviewed-by l4)"; rc=$?
rm -f "$fake/visibility"
check 'exit 0'                         0 "$rc"
check "the person's branch is as it was" "$before" "$(git --git-dir="$origin" rev-parse refs/heads/ci/issue-138-persons)"
check 'the landing used its own branch' yes "$(grep -q 'on ci/integrate-issue-138-persons at GitHub' <<< "$out" && echo yes || echo no)"
check 'and removed only that one'      '' "$(ci_tip issue-138-persons)"
git --git-dir="$origin" update-ref -d refs/heads/ci/issue-138-persons

echo 'a ci/integrate- branch that cannot be looked up on origin at the end is named, and the outcome stays'
PATH="$fake/shim:$saved_path"
land_public 139 lookup "$success" 5 "touch '$fake/ls-remote-fails'"
PATH="$saved_path"; rm -f "$fake/ls-remote-fails"
check 'the landing itself succeeded'   0 "$rc"
check 'the failed lookup is named in one line' 1 "$(grep -c '^ci/integrate-issue-139-lookup could not be looked up on origin, so it was not deleted; delete it by hand if it stands: fatal: planted' <<< "$out" || true)"
check 'the merge commit landed'        "$(cat "$fake/ci-during")" "$(tip)"
git --git-dir="$origin" update-ref -d refs/heads/ci/integrate-issue-139-lookup

echo 'a warning git writes on stderr while it reads a ref of origin is no part of the ref: the landing succeeds'
touch "$fake/ls-remote-warns"; PATH="$fake/shim:$saved_path"
land_public 141 warns "$success"
PATH="$saved_path"; rm -f "$fake/ls-remote-warns"
check 'exit 0'                         0 "$rc"
check 'the merge commit that was on ci/integrate-<branch> landed' "$(cat "$fake/ci-during")" "$(tip)"
check 'ci/integrate-<branch> is gone'  '' "$(ci_tip issue-141-warns)"

echo 'the checks are waited for before the landing lock is taken'
wt="$(new_tree 132 no-lock)"; git -C "$wt" push -q origin issue-132-no-lock 2>/dev/null
echo public > "$fake/visibility"
printf '%s\n' '[{"status":"in_progress","conclusion":null,"workflowName":"check"}]' > "$fake/runs-queue"
printf '#!/bin/sh\necho "$([ -e "%s" ] && echo held || echo free)" > "%s"\n' "$work/.git/ai-core-landing" "$fake/lock-during-wait" > "$fake/during-wait"
out="$(AI_CORE_INTEGRATE_POLL=0 AI_CORE_INTEGRATE_WAIT=30 integrate "$wt" 132 --reviewed-by l4)"; rc=$?
rm -f "$fake/visibility"
check 'exit 0'                         0 "$rc"
check 'no landing lock was held during the wait' free "$(cat "$fake/lock-during-wait")"

echo 'an origin that names no repository refuses before any check is read'
flat="$fake/flat-checkouts"; mkdir -p "$flat"
git -c init.defaultBranch=master init -q --bare "$flat/flat.git"
git -c init.defaultBranch=master init -q "$flat/repo"; dress "$flat/repo"
git -C "$flat/repo" commit -q --allow-empty -m 'Start'
git -C "$flat/repo" remote add origin ../flat.git
git -C "$flat/repo" push -q origin master 2>/dev/null
git -C "$flat/repo" switch -q -c issue-140-flat
echo flat > "$flat/repo/flat.txt"; git -C "$flat/repo" add -A; git -C "$flat/repo" commit -q -m 'Flat #140'
: > "$fake/calls.txt"
out="$(integrate "$flat/repo" 140 --reviewed-by l4)"; rc=$?
check 'exit 1'                         1 "$rc"
check 'it says origin names no repository' yes "$(grep -qF 'nothing landed: origin names no repository, so its visibility cannot be established' <<< "$out" && echo yes || echo no)"
check 'no check was asked'             0 "$(asked_checks)"
check 'nothing reached origin'         '' "$(git --git-dir="$flat/flat.git" for-each-ref --format='%(refname)' | grep -v '^refs/heads/master$' || true)"

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
  local said="$fake/held-$2.out"
  ( integrate "$1" "$2" --reviewed-by l4 > "$said"; echo $? > "$said.rc" ) & local landing=$!
  for _ in $(seq 1 240); do grep -qF 'waiting: ' "$said" 2>/dev/null && break; sleep 0.5; done
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
leftovers() { find "$trees" -mindepth 1 -maxdepth 1 ! -name 'issue-*' | wc -l | tr -d ' '; }

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

echo '--from-origin: a public repository lands the commit its ci/ branch got on green checks, and is refused on red ones with the held worktree untouched'
heldwt10="$(held_tree 150 ci-green)"
tipg="$(git -C "$heldwt10" rev-parse HEAD)"
held_before="$(held_state "$heldwt10")"; before="$(tip)"
echo public > "$fake/visibility"; : > "$fake/calls.txt"; rm -f "$fake/ci-during"; plant_hook issue-150-ci-green "git -C '$heldwt10' status --porcelain > '$fake/held-during'"
out="$(AI_CORE_INTEGRATE_POLL=0 AI_CORE_INTEGRATE_WAIT=5 integrate "$work" 150 --reviewed-by l4 --from-origin)"; rc=$?
check 'green: exit 0'                  0 "$rc"
check 'exactly the commit of ci/integrate-<branch> landed' "$(cat "$fake/ci-during")" "$(tip)"
check 'the checks of that commit were asked' yes "$(grep -qF "run list -R $origin_repo --commit $(tip) " "$fake/calls.txt" && echo yes || echo no)"
check 'it says the checks were green, with the commit and the ci/ branch' yes "$(grep -qxF "checks: green for $(tip | cut -c1-7) on ci/integrate-issue-150-ci-green at GitHub; $origin_repo is public and lands only on green checks" <<< "$out" && echo yes || echo no)"
check 'its second parent is the tip origin held' "$tipg" "$(git --git-dir="$origin" rev-parse master^2)"
check 'one merge commit landed'        1 "$(git --git-dir="$origin" rev-list --merges --count "$before..master")"
check 'ci/integrate-<branch> is gone'            '' "$(ci_tip issue-150-ci-green)"
check 'the held worktree is as it was' "$held_before" "$(held_state "$heldwt10")"
check 'no temporary worktree is left'  0 "$(leftovers)"
heldwt11="$(held_tree 151 ci-red)"
held_before="$(held_state "$heldwt11")"; before="$(tip)"; trees_before="$(trees_listed)"
echo '[{"status":"completed","conclusion":"failure","workflowName":"check"}]' > "$fake/runs"; plant_hook issue-151-ci-red
out="$(AI_CORE_INTEGRATE_POLL=0 AI_CORE_INTEGRATE_WAIT=5 integrate "$work" 151 --reviewed-by l4 --from-origin)"; rc=$?
check 'red: exit 1'                    1 "$rc"
check 'it says nothing landed and the checks are red' yes "$(grep -qF "nothing landed: the checks for $(cat "$fake/ci-during") on ci/integrate-issue-151-ci-red are red" <<< "$out" && echo yes || echo no)"
check 'origin did not move'            "$before" "$(tip)"
check 'ci/integrate-<branch> is deleted'         '' "$(ci_tip issue-151-ci-red)"
check 'the held worktree is as it was' "$held_before" "$(held_state "$heldwt11")"
check 'the temporary worktree is gone' "$trees_before" "$(trees_listed)"
check 'the lock is released'           no "$([ -e "$lock" ] && echo yes || echo no)"
echo unknown > "$fake/visibility"; rm -f "$fake/runs" "$fake/during-wait"
out="$(AI_CORE_INTEGRATE_POLL=0 AI_CORE_INTEGRATE_WAIT=5 integrate "$work" 151 --reviewed-by l4 --from-origin)"; rc=$?
check 'unknown visibility: exit 1'     1 "$rc"
check 'it names the words of gh'       yes "$(grep -qF 'visibility denied' <<< "$out" && echo yes || echo no)"
check 'origin did not move'            "$before" "$(tip)"
echo private > "$fake/visibility"; : > "$fake/calls.txt"
out="$(AI_CORE_INTEGRATE_POLL=0 AI_CORE_INTEGRATE_WAIT=5 integrate "$work" 151 --reviewed-by l4 --from-origin)"; rc=$?
rm -f "$fake/visibility"
check 'private: exit 0'                0 "$rc"
check 'it says the push gate is its check' yes "$(grep -qF 'its push gate is its check' <<< "$out" && echo yes || echo no)"
check 'no check was asked'             0 "$(asked_checks)"
check 'no ci/ branch was made'         '' "$(git --git-dir="$origin" for-each-ref --format='%(refname)' refs/heads/ci)"

echo '--from-origin: a public repository of a project with CI_GATE="none" lands with no ci/ branch and no check read'
heldwt12="$(held_tree 156 held-gate-none)"
held_before="$(held_state "$heldwt12")"; before="$(tip)"
mkdir -p "$work/.ai-core"; echo 'CI_GATE="none"' > "$work/.ai-core/config.env"
echo public > "$fake/visibility"; : > "$fake/calls.txt"; echo broken > "$fake/runs"
out="$(AI_CORE_INTEGRATE_POLL=0 AI_CORE_INTEGRATE_WAIT=0 integrate "$work" 156 --reviewed-by l4 --from-origin)"; rc=$?
rm -rf "$work/.ai-core"; rm -f "$fake/visibility" "$fake/runs"
check 'exit 0'                         0 "$rc"
check 'it says the project reads no CI' yes "$(grep -qF 'and the CI_GATE of the project is none, its push gate is its check' <<< "$out" && echo yes || echo no)"
check 'no check was asked'             0 "$(asked_checks)"
check 'no ci/ branch was made'         '' "$(git --git-dir="$origin" for-each-ref --format='%(refname)' refs/heads/ci)"
check 'one merge commit landed'        1 "$(git --git-dir="$origin" rev-list --merges --count "$before..master")"
check 'the held worktree is as it was' "$held_before" "$(held_state "$heldwt12")"
check 'no temporary worktree is left'  0 "$(leftovers)"

echo '--from-origin: the default branch or the reviewed tip moving while the checks run refuses, ci/integrate-<branch> deleted, the held worktree untouched'
heldwt12="$(held_tree 152 ci-base-moves)"
held_before="$(held_state "$heldwt12")"; before="$(tip)"; trees_before="$(trees_listed)"
echo public > "$fake/visibility"; plant_hook issue-152-ci-base-moves "$push_to_master"; rounds_in "$work" 1
out="$(AI_CORE_INTEGRATE_POLL=0 AI_CORE_INTEGRATE_WAIT=5 integrate "$work" 152 --reviewed-by l4 --from-origin)"; rc=$?
moved="$(tip)"
check 'exit 1'                         1 "$rc"
check 'it names the old and the new default branch tip' yes "$(grep -qF "nothing landed: origin/master moved from $before to $moved while the checks of $(cat "$fake/ci-during") ran; round 1 was the last that INTEGRATE_MAX_ROUNDS (1) allows" <<< "$out" && echo yes || echo no)"
rm -rf "$work/.ai-core"
check 'ci/integrate-<branch> is deleted'         '' "$(ci_tip issue-152-ci-base-moves)"
check 'the held worktree is as it was' "$held_before" "$(held_state "$heldwt12")"
check 'the temporary worktree is gone' "$trees_before" "$(trees_listed)"
check 'the lock is released'           no "$([ -e "$lock" ] && echo yes || echo no)"
heldwt13="$(held_tree 153 ci-tip-moves)"
sha="$(git -C "$heldwt13" rev-parse HEAD)"; before="$(tip)"
plant_hook issue-153-ci-tip-moves "d=\$(mktemp -d) && cd \"\$d\" && git clone -q '$origin' c && cd c && git config user.email t@example.invalid && git config user.name t && git switch -q issue-153-ci-tip-moves && echo m > m.txt && git add -A && git commit -q -m 'Moved #153' && git push -q origin issue-153-ci-tip-moves"
out="$(AI_CORE_INTEGRATE_POLL=0 AI_CORE_INTEGRATE_WAIT=5 integrate "$work" 153 --reviewed-by l4 --from-origin)"; rc=$?
rm -f "$fake/visibility" "$fake/during-wait"
moved="$(git --git-dir="$origin" rev-parse issue-153-ci-tip-moves)"
check 'exit 1'                         1 "$rc"
check 'it names the old and the new tip' yes "$(grep -qF "nothing landed: origin/issue-153-ci-tip-moves moved from $sha to $moved while its checks were waited for; run this again" <<< "$out" && echo yes || echo no)"
check 'origin did not move'            "$before" "$(tip)"
check 'ci/integrate-<branch> is deleted'         '' "$(ci_tip issue-153-ci-tip-moves)"

echo '--from-origin: a tip that moves between the listing and the fetch is refused before any merge, push or check'
heldwt14="$(held_tree 154 ci-early)"
sha="$(git -C "$heldwt14" rev-parse HEAD)"; before="$(tip)"; : > "$fake/calls.txt"
echo public > "$fake/visibility"; rm -f "$fake/ci-during"
printf '#!/bin/sh\nd=$(mktemp -d) && cd "$d" && git clone -q "%s" c && cd c && git config user.email t@example.invalid && git config user.name t && git switch -q issue-154-ci-early && echo m > m.txt && git add -A && git commit -q -m "Moved #154" && git push -q origin issue-154-ci-early\n' "$origin" > "$fake/during-visibility"
out="$(AI_CORE_INTEGRATE_POLL=0 AI_CORE_INTEGRATE_WAIT=5 integrate "$work" 154 --reviewed-by l4 --from-origin)"; rc=$?
rm -f "$fake/visibility"
moved="$(git --git-dir="$origin" rev-parse issue-154-ci-early)"
check 'exit 1'                         1 "$rc"
check 'it names the old and the new tip' yes "$(grep -qF "nothing landed: origin/issue-154-ci-early moved from $sha to $moved while its checks were waited for; run this again" <<< "$out" && echo yes || echo no)"
check 'no check was asked'             0 "$(asked_checks)"
check 'nothing went to ci/'            '' "$(ci_tip issue-154-ci-early)"
check 'origin did not move'            "$before" "$(tip)"

echo '--from-origin: a warning git writes on stderr while it lists the branch of origin is no part of the listing'
heldwt15="$(held_tree 155 ci-warns)"
tipw="$(git -C "$heldwt15" rev-parse HEAD)"; before="$(tip)"
echo public > "$fake/visibility"; rm -f "$fake/ci-during"; plant_hook issue-155-ci-warns
touch "$fake/ls-remote-warns"; PATH="$fake/shim:$saved_path"
out="$(AI_CORE_INTEGRATE_POLL=0 AI_CORE_INTEGRATE_WAIT=5 integrate "$work" 155 --reviewed-by l4 --from-origin)"; rc=$?
PATH="$saved_path"; rm -f "$fake/ls-remote-warns" "$fake/visibility"
check 'exit 0'                         0 "$rc"
check 'the second parent is the tip origin held' "$tipw" "$(git --git-dir="$origin" rev-parse master^2)"
check 'exactly the commit of ci/integrate-<branch> landed' "$(cat "$fake/ci-during")" "$(tip)"

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

# The number 195 is also the number of an issue of this clone's own repository, whose branch stands on origin. Asked about
# it in the tracker of the other repository, that branch answers "this issue", and it is not.
echo '--from-origin for an issue of another repository does not take the branch of this clone'"'"'s own issue of that number'
wt_own="$(new_tree 195 clones-own-work)"
git -C "$work" push -q origin issue-195-clones-own-work
before_planted="$(tip)"
out="$(integrate "$work" other-org/tracker 195 --reviewed-by l4 --from-origin)"; rc=$?
check 'planted: exit 1'                1 "$rc"
check 'planted: the branch is named and not taken' yes "$(grep -qF 'the branch issue-195-clones-own-work on origin is not taken: it belongs to an issue of example-org/example-repo' <<< "$out" && echo yes || echo no)"
check 'planted: it says origin has none of the issue' yes "$(grep -qF 'origin has no branch issue-195-* of other-org/tracker#195' <<< "$out" && echo yes || echo no)"
check 'planted: origin did not move'   "$before_planted" "$(tip)"
wt_issue="$(new_tree 195 read-the-board-whole)"
git -C "$work" push -q origin issue-195-read-the-board-whole
out="$(integrate "$work" other-org/tracker 195 --reviewed-by l4 --from-origin)"; rc=$?
check 'innocent: the issue'"'"'s own branch lands: exit 0' 0 "$rc"
check 'innocent: the subject names the other repository' 'Read the board whole (other-org/tracker#195)' "$(git --git-dir="$origin" log -1 --format=%s master)"
check 'innocent: the branch of the own issue is not merged' no "$(git --git-dir="$origin" merge-base --is-ancestor issue-195-clones-own-work master && echo yes || echo no)"
git -C "$work" worktree remove --force "$wt_own"; git -C "$work" worktree remove --force "$wt_issue"
git -C "$work" push -q origin --delete issue-195-clones-own-work issue-195-read-the-board-whole
git -C "$work" branch -q -D issue-195-clones-own-work issue-195-read-the-board-whole
after="$(tip)"

# A package lands several issues in one push. The first comes from the worktree, every other one from origin, all merged in one
# temporary worktree: one gate run, one push, one merge commit per issue.
echo 'a list of issues lands each one in a merge commit of its own, in the order given, in one push'
wt_first="$(new_tree 301 first-part)"
new_tree 302 second-part >/dev/null
git -C "$work" push -q origin issue-302-second-part
before_list="$(tip)"
# every push of the clone passes its pre-push hook, so a hook that counts them counts the pushes of the landing
mkdir -p "$fake/count-hooks"; printf '#!/bin/sh\ncat > /dev/null\necho push >> "%s"\n' "$fake/pushes.txt" > "$fake/count-hooks/pre-push"
chmod +x "$fake/count-hooks/pre-push"; : > "$fake/pushes.txt"
git -C "$work" config core.hooksPath "$fake/count-hooks"
out="$(integrate "$wt_first" 301 302 --reviewed-by l4 --reviewed-by l5)"; rc=$?
git -C "$work" config --unset core.hooksPath
check 'exit 0'                         0 "$rc"
check 'one push'                       1 "$(wc -l < "$fake/pushes.txt" | tr -d ' ')"
check 'one integrated line'            1 "$(grep -c '^integrated: ' <<< "$out")"
check 'two merge commits on top, in the order given' "Read the board whole (#302)
Read the board whole (#301)" "$(git --git-dir="$origin" log --merges -2 --format=%s master)"
check 'each carries both reviewers'    2 "$(git --git-dir="$origin" log --merges -2 --format=%b master | grep -c '^Reviewed-by: l5$')"
check 'origin moved by both merges and their commits, once' 4 "$(git --git-dir="$origin" rev-list --count "$before_list..master")"
check 'it names the next step of each' "next: ai-core finish-issue 301
next: ai-core finish-issue 302" "$(grep '^next: ' <<< "$out")"
check 'the first worktree is on its branch' issue-301-first-part "$(git -C "$wt_first" symbolic-ref --short HEAD)"
check 'no temporary worktree is left'  0 "$(leftovers)"
echo 'a conflict of the second issue lands neither, names the issue and leaves origin as it was'
wt_c1="$(new_tree 305 clash-one)"; echo a > "$wt_c1/same.txt"; git -C "$wt_c1" add same.txt; git -C "$wt_c1" commit -q -m 'same file (#305)'
wt_c2="$(new_tree 306 clash-two)"; echo b > "$wt_c2/same.txt"; git -C "$wt_c2" add same.txt; git -C "$wt_c2" commit -q -m 'same file (#306)'
git -C "$work" push -q origin issue-306-clash-two
before_list="$(tip)"
out="$(integrate "$wt_c1" 305 306 --reviewed-by l4)"; rc=$?
check 'planted: exit 1'                1 "$rc"
check 'planted: it names the issue that clashes' yes "$(grep -qF 'origin/issue-306-clash-two does not merge cleanly into origin/master' <<< "$out" && echo yes || echo no)"
check 'planted: origin did not move'   "$before_list" "$(tip)"
check 'planted: no temporary worktree is left' 0 "$(leftovers)"
check 'planted: the first worktree is on its branch' issue-305-clash-one "$(git -C "$wt_c1" symbolic-ref --short HEAD)"
echo 'a list in a public repository pushes the merged head to ci/ once, waits for its checks once and lands both merges'
pub_one="$(held_tree 310 pub-one)"; pub_two="$(held_tree 311 pub-two)"
before="$(tip)"
echo public > "$fake/visibility"; : > "$fake/calls.txt"; rm -f "$fake/ci-during"; plant_hook issue-310-pub-one
out="$(AI_CORE_INTEGRATE_POLL=0 AI_CORE_INTEGRATE_WAIT=5 integrate "$work" 310 311 --reviewed-by l4 --from-origin)"; rc=$?
rm -f "$fake/visibility" "$fake/during-wait"
check 'exit 0'                         0 "$rc"
check 'exactly the commit of ci/integrate-<first branch> landed' "$(cat "$fake/ci-during")" "$(tip)"
check 'its checks are read green once' 1 "$(grep -c '^checks: green for ' <<< "$out")"
check 'the checks of the final merge were asked' yes "$(grep -qF "run list -R $origin_repo --commit $(tip) " "$fake/calls.txt" && echo yes || echo no)"
check 'two merge commits landed'       2 "$(git --git-dir="$origin" rev-list --merges --count "$before..master")"
check 'ci/integrate-<branch> is gone'  '' "$(ci_tip issue-310-pub-one)"
check 'no temporary worktree is left'  0 "$(leftovers)"
git -C "$work" worktree remove --force "$pub_one"; git -C "$work" worktree remove --force "$pub_two"
before_list="$(tip)"
# A branch pushed past the gate (a cloud session's) reached origin unjudged. The landing runs the commit checks on every commit it
# adds to the default branch, those another ref of origin holds already among them.
echo 'a commit that no gate judged is judged when its branch lands: a subject over 72 characters refuses the landing and names the commit'
mkdir -p "$fake/gate-hooks"; printf '#!/bin/sh\nexec bash "%s/bin/pre-push.sh" "$@"\n' "$root" > "$fake/gate-hooks/pre-push"; chmod +x "$fake/gate-hooks/pre-push"
printf 'claude\tmode\talways\t-\t-\ncodex\tmode\talways\t-\t-\n' > "$fake/team-modes.tsv"
wt_long="$(new_tree 321 long-subject)"
long_subject='Write the long subject that no gate judged and that is far beyond the limit (#321)'
echo 'a second commit' > "$wt_long/second-commit.txt"; git -C "$wt_long" add second-commit.txt; git -C "$wt_long" commit -q -m "$long_subject"
git -C "$wt_long" push -q --no-verify origin issue-321-long-subject
long_sha="$(git -C "$wt_long" rev-parse --short HEAD)"
before_gate="$(tip)"
git -C "$work" config core.hooksPath "$fake/gate-hooks"
out="$(TEAM_MODES_FILE="$fake/team-modes.tsv" PRE_PUSH_LOAD_LIMIT=0 integrate "$wt_long" 321 --reviewed-by l4)"; rc=$?
check 'planted: exit 1'                1 "$rc"
check 'planted: it names the commit that is too long' yes "$(grep -qF "$long_sha" <<< "$out" && grep -q 'subjects are longer than 72 characters' <<< "$out" && echo yes || echo no)"
check 'planted: origin did not move'   "$before_gate" "$(tip)"
check 'planted: the worktree is on its branch' issue-321-long-subject "$(git -C "$wt_long" symbolic-ref --short HEAD)"
wt_passed="$(new_tree 322 passed-the-gate)"
TEAM_MODES_FILE="$fake/team-modes.tsv" PRE_PUSH_LOAD_LIMIT=0 git -C "$wt_passed" push -q origin issue-322-passed-the-gate 2>/dev/null
out="$(TEAM_MODES_FILE="$fake/team-modes.tsv" PRE_PUSH_LOAD_LIMIT=0 integrate "$wt_passed" 322 --reviewed-by l4)"; rc=$?
check 'innocent: a branch whose commits passed the gate lands: exit 0' 0 "$rc$([ "$rc" -eq 0 ] || echo " $out")"
check 'innocent: its merge commit is on origin' "Read the board whole (#322)" "$(git --git-dir="$origin" log -1 --format=%s master)"
git -C "$work" config --unset core.hooksPath
before_list="$(tip)"

echo 'an issue named twice, and an issue without a branch on origin, are refused before anything moves'
out="$(integrate "$wt_c1" 305 305 --reviewed-by l4)"; rc=$?
check 'twice: exit 1'                  1 "$rc"
check 'twice: it says so'              yes "$(grep -qF 'an issue is named twice' <<< "$out" && echo yes || echo no)"
out="$(integrate "$wt_c1" 305 399 --reviewed-by l4)"; rc=$?
check 'no branch on origin: exit 1'    1 "$rc"
check 'no branch on origin: it says so' yes "$(grep -qF 'origin has no branch issue-399-*' <<< "$out" && echo yes || echo no)"
check 'no branch on origin: origin did not move' "$before_list" "$(tip)"
echo 'a list whose later issue holds nothing that the earlier ones do not lands none, since git would merge it into no commit, and names it'
wt_holds="$(new_tree 315 holds-the-work)"
git -C "$work" branch -q issue-316-holds-nothing "$(git -C "$wt_holds" rev-parse HEAD)"
git -C "$work" push -q origin issue-316-holds-nothing
before_list="$(tip)"
out="$(integrate "$wt_holds" 315 316 --reviewed-by l4)"; rc=$?
check 'planted: exit 1'                1 "$rc"
check 'planted: it names the branch that adds nothing' yes "$(grep -qF 'nothing to integrate: origin/issue-316-holds-nothing holds nothing that the issues before it in the list do not' <<< "$out" && echo yes || echo no)"
check 'planted: origin did not move'   "$before_list" "$(tip)"
check 'planted: no temporary worktree is left' 0 "$(leftovers)"
git -C "$work" worktree remove --force "$wt_holds"; git -C "$work" push -q origin --delete issue-316-holds-nothing
git -C "$work" branch -q -D issue-315-holds-the-work issue-316-holds-nothing
echo 'a list in the worktree of an issue of another repository reads every later number there, also one whose branch this clone holds no record of'
wt_elsewhere="$(new_tree 340 first-elsewhere)"
git -C "$work" config branch.issue-340-first-elsewhere.issueRepository other-org/tracker
# the branch of the second was started in another clone: origin holds it, and this clone has no branch or record of it
elsewhere="$fake/clone-elsewhere"
git clone -q "$origin" "$elsewhere"; dress "$elsewhere"
git -C "$elsewhere" switch -q -c issue-341-read-the-board-whole
echo 'started in another clone' > "$elsewhere/started-elsewhere.txt"
git -C "$elsewhere" add -A && git -C "$elsewhere" commit -q -m 'Write the second part in another clone #341'
git -C "$elsewhere" push -q origin issue-341-read-the-board-whole; rm -rf "$elsewhere"
: > "$fake/calls.txt"
out="$(integrate "$wt_elsewhere" 340 341 --reviewed-by l4)"; rc=$?
check 'planted: exit 0'                0 "$rc"
check 'planted: both subjects name the other repository' "Read the board whole (other-org/tracker#341)
Read the board whole (other-org/tracker#340)" "$(git --git-dir="$origin" log --merges -2 --format=%s master)"
check 'planted: the second issue was read there' yes "$(grep -q 'other-org/tracker/issues/341' "$fake/calls.txt" && echo yes || echo no)"
check 'planted: and never in this clone'"'"'s repository' no "$(grep -q 'example-org/example-repo/issues/341' "$fake/calls.txt" && echo yes || echo no)"
check 'planted: the next steps name the other repository' "next: ai-core finish-issue other-org/tracker 340
next: ai-core finish-issue other-org/tracker 341" "$(grep '^next: ' <<< "$out")"
git -C "$work" worktree remove --force "$wt_elsewhere"; git -C "$work" push -q origin --delete issue-341-read-the-board-whole
git -C "$work" branch -q -D issue-340-first-elsewhere
after="$(tip)"

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
held_tree 106 walk >/dev/null
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
held_tree 107 plain >/dev/null
before="$(tip)"
out="$(integrate "$work" 107 --reviewed-by l4 --from-origin)"; rc=$?
check 'exit 0'                         0 "$rc"
check 'one merge commit landed'        1 "$(git --git-dir="$origin" rev-list --merges --count "$before..master")"
check 'and no folder of it is left'    0 "$(leftovers)"

echo '--from-origin: an interruption removes the temporary worktree too'
held_tree 108 stopped >/dev/null
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
  check "$mode $state names skipped checkout" yes "$(grep -qF "the refresh of checkout $FF_REPO did not finish" <<< "$out" && echo yes || echo no)"
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

# --- the real push gate beside the landing: one wait for a lower load at each local check --------
# The hook is the real gate, the check is planted in the branch, and the load, the clock and the sleeping
# are stand-ins: no case burns CPU or waits on the host. A check writes down that it ran, and holds while
# hold-check exists and release-check does not.
. "$root/tests/load-stubs.sh"; make_load_stubs "$fake/loadstubs"; real_sleep="$(command -v sleep)"
printf 'claude\tmode\talways\t-\t-\n' > "$fake/modes-green.tsv"; export TEAM_MODES_FILE="$fake/modes-green.tsv"
mkdir -p "$fake/gate-hooks"; printf '#!/bin/sh\nexec bash "%s/bin/pre-push.sh" "$@"\n' "$root" > "$fake/gate-hooks/pre-push"; chmod +x "$fake/gate-hooks/pre-push"
gate_runs="$fake/gate-checks.txt"
# The gate holds every commit against the identity configured in the repository: one in the caller's environment would make them strangers'
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
git -C "$work" config --unset core.hooksPath 2>/dev/null   # the earlier cases leave their own hook set
# gated_tree <number> <slug> <load limit> <bound> [CI_GATE]: an issue worktree whose commit carries the planted check and the settings
gated_tree() {
  local wt="$trees/issue-$1-$2"
  git -C "$work" worktree add -q -b "issue-$1-$2" "$wt" origin/master; dress "$wt"
  mkdir -p "$wt/scripts" "$wt/.ai-core"
  printf '#!/usr/bin/env bash\n# issue %s\necho "$(cat "$PROBE_STATE/clock")" >> "%s"\nwhile [ -e "%s/hold-check" ] && [ ! -e "%s/release-check" ]; do "%s" 0.05; done\n[ "${PROBE_CHECK:-green}" = green ] || { echo "check: FAIL"; exit 1; }\necho "check: OK"\n' "$1" "$gate_runs" "$fake" "$fake" "$real_sleep" > "$wt/scripts/check.sh"
  chmod +x "$wt/scripts/check.sh"
  printf 'PRE_PUSH_LOAD_LIMIT="%s"\nPRE_PUSH_LOAD_WAIT_SECONDS="%s"\n%s' "$3" "$4" "${5:+CI_GATE=\"$5\"}" > "$wt/.ai-core/config.env"
  git -C "$wt" add -f -A && git -C "$wt" commit -q -m "Plant the check #$1"
  git -C "$wt" push -q origin "issue-$1-$2" 2>/dev/null
  printf '%s' "$wt"
}
integrate_here() { AI_CORE_INTEGRATE_POLL=0 AI_CORE_INTEGRATE_WAIT=0 bash "$root/bin/integrate-issue.sh" "$1" --reviewed-by l4 2>&1; }
lines_of() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
load_plan() { PROBE_STATE="$fake/gate-state"; plan_load "$PROBE_STATE" "$@"; rm -f "$fake/hold-check" "$fake/release-check" "$gate_runs"; : > "$gate_runs"; }
announced='waiting for the 1-minute load to fall below'
ended='the wait is over; the check starts at a 1-minute load of 30, at or above the limit of 24'
# await <pid> <seconds> <command...>: until the command succeeds or the process is gone. The seconds are a ceiling that
# only a defect reaches, so a slow machine never turns correct code red; a planted defect, which can never succeed,
# is given a short one by its case (VISIBLE_WITHIN)
await() { local pid="$1" tries=$(( $2 * 20 )) _; shift 2; for _ in $(seq "$tries"); do "$@" 2>/dev/null && return 0; kill -0 "$pid" 2>/dev/null || return 1; "$real_sleep" 0.05; done; return 1; }
shows() { grep -qF -- "$2" "$1"; }   # shows <file> <text>

# start_landing <number> <slug> <entry...>: a public repository's landing, in the background, its pid in landing_pid. The gate of
# its CI push waits for a lower load, then holds its check. LANDING_TMPDIR names the folder the child makes temporary files in;
# LANDING_GROUP makes it the leader of a process group of its own, which a case can signal as a whole.
start_landing() {
  local n="$1" slug="$2"; shift 2
  local wt dir
  wt="$(gated_tree "$n" "$slug" 24 10)"; load_plan 30; : > "$fake/hold-check"; : > "$PROBE_STATE/block"
  echo public > "$fake/visibility"; : > "$fake/calls.txt"; rm -f "$fake/ci-during"; plant_hook "issue-$n-$slug" ""
  dir="$wt"; [[ " $* " != *" --from-origin "* ]] || dir="$work"
  ( cd "$dir" && git config core.hooksPath "$fake/gate-hooks" \
      && { [ -z "${LANDING_TMPDIR:-}" ] || export TMPDIR="$LANDING_TMPDIR"; } \
      && PATH="$fake/loadstubs:$PATH" PROBE_STATE="$PROBE_STATE" AI_CORE_INTEGRATE_POLL=0 AI_CORE_INTEGRATE_WAIT=5 \
      exec ${LANDING_GROUP:+setsid} bash "${INTEGRATE_SCRIPT:-$root/bin/integrate-issue.sh}" "$n" --reviewed-by l4 "$@" > "$fake/landing.out" 2>&1 ) & landing_pid=$!
}
end_landing() { git -C "$work" config --unset core.hooksPath; rm -f "$fake/visibility" "$fake/hold-check"; out="$(cat "$fake/landing.out")"; }

# public_landing <number> <slug> <entry...>: a public repository lands on green checks while the gate of the CI push waits
# for a lower load, then holds its check; what the person sees is read from the output while it runs, and only once the
# gate stands in its first wait, because before that no word of it can be on screen
public_landing() {
  local seen_wait seen_over in_flight within="${VISIBLE_WITHIN:-180}"
  start_landing "$@"
  await "$landing_pid" 180 test -e "$PROBE_STATE/sleeping" || true
  await "$landing_pid" "$within" shows "$fake/landing.out" "$announced" && seen_wait=yes || seen_wait=no
  : > "$PROBE_STATE/wake"
  await "$landing_pid" "$within" shows "$fake/landing.out" "$ended" && seen_over=yes || seen_over=no
  kill -0 "$landing_pid" 2>/dev/null && in_flight=yes || in_flight=no
  : > "$fake/release-check"; wait "$landing_pid"; rc=$?
  end_landing; seen="$seen_wait $seen_over $in_flight"
}
echo 'a landing whose repository has no scripts/check.sh reads no load and waits for nothing'
before="$(tip)"
wt="$(new_tree 165 no-check)"; git -C "$wt" push -q origin issue-165-no-check 2>/dev/null; load_plan 99; echo private > "$fake/visibility"
git -C "$work" config core.hooksPath "$fake/gate-hooks"
out="$(cd "$wt" && PATH="$fake/loadstubs:$PATH" PROBE_STATE="$PROBE_STATE" integrate_here 165)"; rc=$?
git -C "$work" config --unset core.hooksPath; rm -f "$fake/visibility"
check 'exit 0, no reading of the load, no sleep, no check' '0 0 0 0' "$rc $(cat "$PROBE_STATE/uptime-calls" 2>/dev/null || echo 0) $(lines_of "$PROBE_STATE/sleeps") $(lines_of "$gate_runs")"
check 'and it landed'                            1 "$(git --git-dir="$origin" rev-list --merges --count "$before..master")"

# --- the default branch moves while a landing pushes: the real gate beside it must name the race --------
# Another session's landing is planted by a hook: pre-merge-commit runs after the landing fetched and before it
# pushes, so the check of the base right before the push finds the default branch moved and no gate runs; the pre-push
# wrapper moves the branch while the gate of the final push runs, so that origin refuses the push itself. Each of these
# landings may make one round only (INTEGRATE_MAX_ROUNDS 1), which is the single attempt: the rounds are pinned below.
printf '%s\n' "$push_to_master" > "$fake/race.sh"
mkdir -p "$fake/race-hooks"
printf '#!/bin/sh\nunset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX\n[ -z "${PLANT_RACE:-}" ] || [ -e "$PLANT_RACE.done" ] || { : > "$PLANT_RACE.done"; sh "$PLANT_RACE" >/dev/null 2>&1; }\n' > "$fake/race-hooks/pre-merge-commit"
printf '#!/bin/sh\nunset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX\nlines="$(cat)"\ncase "$lines" in *" refs/heads/master "*) [ -z "${PLANT_RACE_LATE:-}" ] || [ -e "$PLANT_RACE_LATE.late" ] || { : > "$PLANT_RACE_LATE.late"; sh "$PLANT_RACE_LATE" >/dev/null 2>&1; } ;; esac\nprintf "%%s\\n" "$lines" | exec bash "%s/bin/pre-push.sh" "$@"\n' "$root" > "$fake/race-hooks/pre-push"
chmod +x "$fake/race-hooks/pre-merge-commit" "$fake/race-hooks/pre-push"
race_refused() {  # race_refused <label> <before> merge|push: what the person reads, and what origin and the worktree keep; merge where the base check before the push found the move, push where origin refused the push for it
  local moved cause
  moved="$(tip)"
  case "$3" in merge) cause="origin/master moved from $2 to $moved while the merge was made" ;; *) cause="master moved on origin from $2 to $moved after this landing fetched it" ;; esac
  check "$1: exit 1" 1 "$rc"
  check "$1: the output names the move and tells to run again" yes "$(grep -qF "nothing landed: $cause" <<< "$out" && grep -qF 'Run this again' <<< "$out" && echo yes || echo no)"
  check "$1: the gate does not talk of a branch" no "$(grep -qF 'not on a branch; nothing to judge' <<< "$out" && echo yes || echo no)"
  check "$1: only the other landing reached the default branch" "0 yes" "$(git --git-dir="$origin" rev-list --merges --count "$2..master") $([ "$moved" != "$2" ] && echo yes || echo no)"
  check "$1: the lock is released" no "$([ -e "$work/.git/ai-core-landing" ] && echo yes || echo no)"
}
echo 'a default branch that moves between the fetch and the push is named, in each of the paths, when one round only is allowed, and the rerun lands'
git -C "$work" config core.hooksPath "$fake/race-hooks"; echo private > "$fake/visibility"
wt="$(new_tree 970 race)"; git -C "$wt" push -q origin issue-970-race 2>/dev/null; rounds_in "$wt" 1
before="$(tip)"; rm -f "$fake/race.sh.done" "$fake/race.sh.late"
out="$(cd "$wt" && PLANT_RACE="$fake/race.sh" integrate_here 970)"; rc=$?
race_refused 'in the worktree' "$before" merge
check 'in the worktree: the branch is checked out again' issue-970-race "$(git -C "$wt" symbolic-ref --short HEAD)"
before="$(tip)"
out="$(cd "$wt" && integrate_here 970)"; rc=$?
check 'in the worktree: the rerun lands' '0 1' "$rc $(git --git-dir="$origin" rev-list --merges --count "$before..master")"
wt="$(new_tree 971 race-origin)"; git -C "$wt" push -q origin issue-971-race-origin 2>/dev/null; rounds_in "$work" 1
before="$(tip)"; rm -f "$fake/race.sh.done" "$fake/race.sh.late"
out="$(cd "$work" && PLANT_RACE="$fake/race.sh" AI_CORE_INTEGRATE_POLL=0 AI_CORE_INTEGRATE_WAIT=0 bash "$root/bin/integrate-issue.sh" 971 --reviewed-by l4 --from-origin 2>&1)"; rc=$?
race_refused 'with --from-origin' "$before" merge
rm -rf "$work/.ai-core"
before="$(tip)"
out="$(cd "$work" && AI_CORE_INTEGRATE_POLL=0 AI_CORE_INTEGRATE_WAIT=0 bash "$root/bin/integrate-issue.sh" 971 --reviewed-by l4 --from-origin 2>&1)"; rc=$?
check 'with --from-origin: the rerun lands' '0 1' "$rc $(git --git-dir="$origin" rev-list --merges --count "$before..master")"
echo 'the receipt of the checks of a public landing is removed after a landing that went through and after one that was refused'
mkdir -p "$fake/receipts"
TMPDIR="$fake/receipts" land_public 978 receipt-green "$success"
check 'green: exit 0 and no receipt left'        '0 0' "$rc $(find "$fake/receipts" -mindepth 1 | wc -l | tr -d ' ')"
TMPDIR="$fake/receipts" land_public 979 receipt-red '[{"status":"completed","conclusion":"failure","workflowName":"check"}]'
check 'red: exit 1 and no receipt left'          '1 0' "$rc $(find "$fake/receipts" -mindepth 1 | wc -l | tr -d ' ')"
receipt_a="$(TMPDIR="$fake/receipts" bash "$root/lib/landing-check.sh" open)"; receipt_b="$(TMPDIR="$fake/receipts" bash "$root/lib/landing-check.sh" open)"
check 'the receipts of two landings are two folders' different "$([ "$receipt_a" != "$receipt_b" ] && echo different || echo same)"
bash "$root/lib/landing-check.sh" close "$receipt_a"; bash "$root/lib/landing-check.sh" close "$receipt_b"
echo 'two integrations at the same moment: in one clone they take turns and both land; in separate clones each lands or says the default branch moved'
git -C "$work" config --unset core.hooksPath; echo private > "$fake/visibility"
wt_a="$(new_tree 974 twin-a)"; git -C "$wt_a" push -q origin issue-974-twin-a 2>/dev/null
wt_b="$(new_tree 975 twin-b)"; git -C "$wt_b" push -q origin issue-975-twin-b 2>/dev/null
before="$(tip)"
( cd "$wt_a" && integrate_here 974 > "$fake/twin-a.out" ) & pid_a=$!
( cd "$wt_b" && integrate_here 975 > "$fake/twin-b.out" ) & pid_b=$!
wait "$pid_a"; rc_a=$?; wait "$pid_b"; rc_b=$?
check 'one clone: both landed' '0 0 2' "$rc_a $rc_b $(git --git-dir="$origin" rev-list --merges --count "$before..master")"
second="$fake/checkouts-second/example-repo"; mkdir -p "$fake/checkouts-second/.worktrees/example-repo"
git clone -q "$origin" "$second" 2>/dev/null; dress "$second"
git -C "$second" worktree add -q -b issue-976-twin-c "$fake/checkouts-second/.worktrees/example-repo/issue-976-twin-c" origin/master
wt_c="$fake/checkouts-second/.worktrees/example-repo/issue-976-twin-c"; dress "$wt_c"; echo c > "$wt_c/c.txt"; git -C "$wt_c" add -A; git -C "$wt_c" commit -q -m 'Write c #976'; git -C "$wt_c" push -q origin issue-976-twin-c 2>/dev/null
wt_d="$(new_tree 977 twin-d)"; git -C "$wt_d" push -q origin issue-977-twin-d 2>/dev/null
before="$(tip)"
( cd "$wt_c" && integrate_here 976 > "$fake/twin-c.out"; echo $? > "$fake/twin-c.rc" ) &
( cd "$wt_d" && integrate_here 977 > "$fake/twin-d.out"; echo $? > "$fake/twin-d.rc" ) &
wait
landed=0; explained=yes
for t in c d; do
  if [ "$(cat "$fake/twin-$t.rc")" = 0 ]; then landed=$((landed + 1))
  else grep -qE 'moved on origin from [0-9a-f]{7,40} to [0-9a-f]{7,40}|origin/master moved' "$fake/twin-$t.out" || explained=no; fi
  grep -qF 'not on a branch; nothing to judge' "$fake/twin-$t.out" && explained=no
done
check 'separate clones: every refusal explains the move, and the landings that succeeded are on origin' "yes $landed" "$explained $(git --git-dir="$origin" rev-list --merges --count "$before..master")"
echo 'a push that git reports as failed while origin holds the merge commit is not denied'
mkdir -p "$fake/anyway-hooks"
printf '#!/bin/sh\nunset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX\n[ ! -e "$ANYWAY_MARKER" ] || exit 0\n: > "$ANYWAY_MARKER"\ngit push -q origin HEAD:refs/heads/master\nexit 1\n' > "$fake/anyway-hooks/pre-push"; chmod +x "$fake/anyway-hooks/pre-push"
git -C "$work" config core.hooksPath "$fake/anyway-hooks"
wt="$(new_tree 973 pushed-anyway)"; git -C "$wt" push -q origin issue-973-pushed-anyway 2>/dev/null
before="$(tip)"; rm -f "$fake/anyway.marker"
out="$(cd "$wt" && ANYWAY_MARKER="$fake/anyway.marker" integrate_here 973)"; rc=$?
check 'exit 0, one merge commit, the branch checked out again' '0 1 issue-973-pushed-anyway' "$rc $(git --git-dir="$origin" rev-list --merges --count "$before..master") $(git -C "$wt" symbolic-ref --short HEAD)"
check 'it says that origin holds the commit although git failed, and that it integrated' yes "$(grep -qE 'origin holds [0-9a-f]{7} on master although git reported a failure: the landing went through' <<< "$out" && grep -q '^integrated: ' <<< "$out" && echo yes || echo no)"
check 'it does not say that nothing landed' no "$(grep -qF 'nothing landed' <<< "$out" && echo yes || echo no)"
git -C "$work" config core.hooksPath "$fake/race-hooks"
rm -f "$fake/visibility"
echo 'the same during the gate of the final push of a public repository, and a gate that git starts with no ref judges nothing'
git -C "$work" config core.hooksPath "$fake/race-hooks"
wt="$(new_tree 972 race-public)"; sha="$(git -C "$wt" rev-parse HEAD)"; git -C "$wt" push -q origin issue-972-race-public 2>/dev/null; rounds_in "$wt" 1
echo public > "$fake/visibility"; printf '%s\n' "$success" > "$fake/runs"; : > "$fake/runs-queue"; : > "$fake/calls.txt"; plant_hook issue-972-race-public ""
before="$(tip)"; rm -f "$fake/race.sh.done" "$fake/race.sh.late"
out="$(cd "$wt" && PLANT_RACE_LATE="$fake/race.sh" AI_CORE_INTEGRATE_POLL=0 AI_CORE_INTEGRATE_WAIT=5 integrate_here 972)"; rc=$?
rm -f "$fake/visibility" "$fake/runs" "$fake/during-wait"
race_refused 'in a public repository' "$before" push
check 'in a public repository: ci/integrate-<branch> is deleted' '' "$(ci_tip issue-972-race-public)"
git -C "$work" config --unset core.hooksPath
out="$(cd "$wt" && printf '' | bash "$root/bin/pre-push.sh" origin "$origin" 2>&1)"; rc=$?
check 'a hook that git starts with no ref line exits 0 and judges nothing' '0 yes' "$rc $(grep -qF 'git sent no ref for this push: nothing to judge' <<< "$out" && echo yes || echo no)"
out="$(cd "$work" && git checkout -q --detach && printf '' | bash "$root/bin/pre-push.sh" 2>&1)"; rc=$?
check 'a gate run by hand on a detached HEAD, with no remote, keeps its refusal' '2 yes' "$rc $(grep -qF 'not on a branch; nothing to judge' <<< "$out" && echo yes || echo no)"
git -C "$work" switch -q master

before="$(tip)"
echo 'a public landing shows the wait for a lower load while its CI push waits, then the check, and lands the commit its checks were green for'
public_landing 160 streamed
check 'exit 0'                                   0 "$rc"
check 'the announcement, and the start above the limit, were on screen while the check still ran' 'yes yes yes' "$seen"
check 'the announcement stands once, for the one local check' 1 "$(grep -c "$announced" <<< "$out")"
check 'and so does the start above the limit'    1 "$(grep -c "$ended" <<< "$out")"
check 'the check ran once, after its wait: the push to the default branch did not run it again' '1 1010' "$(lines_of "$gate_runs") $(sed -n 1p "$gate_runs")"
check 'the gate says for the commit that landed that it does not run again' yes "$(grep -qF "scripts/check.sh of $(tip) does not run again" <<< "$out" && echo yes || echo no)"
check 'and for the commit of its ci/ push which check it ran' yes "$(grep -qF "scripts/check.sh runs for $(tip):" <<< "$out" && echo yes || echo no)"
check 'the checks of the CI were asked on their own, and the commit that landed is the one that was checked' "$(cat "$fake/ci-during")" "$(tip)"
check 'the CI answered green, said once'         1 "$(grep -c '^checks: green for' <<< "$out")"
check 'one merge commit landed'                  1 "$(git --git-dir="$origin" rev-list --merges --count "$before..master")"
before="$(tip)"
echo 'the same with --from-origin'
public_landing 161 streamed-origin --from-origin
check 'exit 0 and the same words on screen while the check ran' '0 yes yes yes' "$rc $seen"
check 'one merge commit landed, the commit of its ci/ branch' "$(cat "$fake/ci-during") 1" "$(tip) $(git --git-dir="$origin" rev-list --merges --count "$before..master")"

echo 'a red check after the wait refuses: nothing on the default branch, the gate named once, the wait said once'
before="$(tip)"
wt="$(gated_tree 162 red-after-wait 24 10)"; load_plan 30; echo public > "$fake/visibility"; plant_hook issue-162-red-after-wait ""
git -C "$work" config core.hooksPath "$fake/gate-hooks"
out="$(cd "$wt" && PROBE_CHECK=red PATH="$fake/loadstubs:$PATH" PROBE_STATE="$PROBE_STATE" AI_CORE_INTEGRATE_POLL=0 AI_CORE_INTEGRATE_WAIT=5 bash "$root/bin/integrate-issue.sh" 162 --reviewed-by l4 2>&1)"; rc=$?
git -C "$work" config --unset core.hooksPath; rm -f "$fake/visibility"
check 'exit 1'                                   1 "$rc"
check 'the failed check of the gate is shown'    yes "$(grep -qF 'check: FAIL' <<< "$out" && echo yes || echo no)"
check 'the refusal names the cause and points at the words above' yes "$(grep -qF 'could not be pushed to ci/integrate-issue-162-red-after-wait for its checks, and nothing reached master (the words of git and of the push gate are above)' <<< "$out" && echo yes || echo no)"
check 'the wait was said once, not again in the refusal' 1 "$(grep -c "$announced" <<< "$out")"
check 'origin did not move'                      "$before" "$(tip)"

echo 'a private landing and one under CI_GATE="none" reach the single wait of their check through the hook, and read no check of the CI'
for variant in private none; do
  before="$(tip)"; n=$([ "$variant" = private ] && echo 163 || echo 164)
  wt="$(gated_tree "$n" "gate-$variant" 24 300 "$([ "$variant" = none ] && echo none)")"; load_plan 25 24 23.5
  [ "$variant" = private ] && echo private > "$fake/visibility" || echo public > "$fake/visibility"; : > "$fake/calls.txt"
  git -C "$work" config core.hooksPath "$fake/gate-hooks"
  out="$(cd "$wt" && PATH="$fake/loadstubs:$PATH" PROBE_STATE="$PROBE_STATE" integrate_here "$n")"; rc=$?
  git -C "$work" config --unset core.hooksPath; rm -f "$fake/visibility"
  check "$variant: exit 0"                       0 "$rc"
  check "$variant: one wait, two sleeps of five, one check at 1010" "1 5 5  1 1010" "$(grep -c "$announced" <<< "$out") $(tr '\n' ' ' < "$PROBE_STATE/sleeps") $(lines_of "$gate_runs") $(cat "$gate_runs")"
  check "$variant: no check of the CI was asked" 0 "$(asked_checks)"
  check "$variant: the commit landed"            1 "$(git --git-dir="$origin" rev-list --merges --count "$before..master")"
done

# mutant_integrate <folder> <sed expression>: a copy of the harness with one defect in integrate-issue.sh and every other
# file linked, so the planted copy runs as far as the real one does and fails for its defect alone
mutant_integrate() {
  local entry
  rm -rf "$1"; mkdir -p "$1/bin"
  for entry in "$root"/* "$root"/bin/*; do
    case "$entry" in "$root/bin"|"$root/bin/integrate-issue.sh") continue ;; "$root"/bin/*) ln -s "$entry" "$1/bin/${entry##*/}" ;; *) ln -s "$entry" "$1/${entry##*/}" ;; esac
  done
  sed "$2" "$root/bin/integrate-issue.sh" > "$1/bin/integrate-issue.sh"; chmod +x "$1/bin/integrate-issue.sh"
  cmp -s "$root/bin/integrate-issue.sh" "$1/bin/integrate-issue.sh" && { echo '  FAIL the planted defect changed nothing'; failed=$((failed + 1)); }
  return 0
}

echo 'planted: the output of the push to ci/ is buffered until the push is over, as it was'
mutant_integrate "$fake/mutant-integrate" 's/2>&1 | tee "\$pushed" >&2 ||/> "$pushed" 2>\&1 ||/'
VISIBLE_WITHIN=3 INTEGRATE_SCRIPT="$fake/mutant-integrate/bin/integrate-issue.sh" public_landing 166 buffered
check 'the planted copy reached the wait of the gate, so what it did not show is its own silence' yes "$([ -e "$PROBE_STATE/sleeping" ] && echo yes || echo no)"
check 'the announcement is not on screen before the push ends' no "$(case "$seen" in yes\ *) echo yes ;; *) echo no ;; esac)"
unset INTEGRATE_SCRIPT

echo 'a landing interrupted while the gate of its push to ci/ waits leaves no file of that push behind; the planted copy, which removes it only after a push that ended, leaves one'
mutant_integrate "$fake/mutant-leftover" '/^  \[ -z "\$pushed" \] || rm -f "\$pushed"$/d'
# stopped_landing <number> <slug>: every process of the landing is sent SIGTERM while the gate waits, as ^C reaches them; files_during
# counts the temporary files of the landing while it stood there, files_after the ones that outlived it (the gate keeps a folder
# of its own there)
files_in() { find "$1" -maxdepth 1 -type f | wc -l | tr -d ' '; }
group_gone() { ! kill -0 -- "-$1" 2>/dev/null; }
stopped_landing() {
  local scratch="$fake/landing-tmp-$1"
  rm -rf "$scratch"; mkdir -p "$scratch"
  LANDING_GROUP=yes LANDING_TMPDIR="$scratch" start_landing "$1" "$2"
  await "$landing_pid" 180 test -e "$PROBE_STATE/sleeping" || true
  files_during="$(files_in "$scratch")"
  kill -TERM -- "-$landing_pid"
  wait "$landing_pid"; rc=$?
  await "$$" 60 group_gone "$landing_pid" || true
  files_after="$(files_in "$scratch")"
  end_landing
}
stopped_landing 167 stopped
check 'the landing ended on the signal'            143 "$rc"
check 'the output of the push stood in a file while the gate waited, and none outlives the landing' '1 0' "$files_during $files_after"
INTEGRATE_SCRIPT="$fake/mutant-leftover/bin/integrate-issue.sh" stopped_landing 168 stopped-planted
check 'the planted copy leaves that file behind'   '1 1' "$files_during $files_after"
unset INTEGRATE_SCRIPT

# --- the rounds: the default branch moves while the gate of a round runs, and the landing makes the next round by itself ---
# racing_tree <number> <slug> [limit]: an issue worktree whose scripts/check.sh is the planted gate of the rounds. It writes the commit
# and the tree it judges to $rs/judged, moves origin's default branch (another session's landing) while it runs for the first
# $rs/moves runs, runs $rs/during.sh where there is one, and is red where $rs/red exists. The limit goes to the config.env of the
# worktree, where integrate-issue reads INTEGRATE_MAX_ROUNDS.
racing_tree() {
  local wt="$trees/issue-$1-$2" rs="$fake/rs-$1"
  rm -rf "$rs"; mkdir -p "$rs"; : > "$rs/judged"; echo 0 > "$rs/moves"; printf '%s\n' "$push_to_master" > "$rs/move.sh"
  git -C "$work" worktree add -q -b "issue-$1-$2" "$wt" origin/master; dress "$wt"
  mkdir -p "$wt/scripts" "$wt/.ai-core"
  { printf '#!/usr/bin/env bash\nrs="%s"\n' "$rs"
    cat <<'CHECK'
echo "$(git rev-parse HEAD) $(git rev-parse 'HEAD^{tree}')" >> "$rs/judged"
n=$(wc -l < "$rs/judged" | tr -d ' ')
if [ "$n" -le "$(cat "$rs/moves")" ]; then sh "$rs/move.sh" >/dev/null 2>&1; fi
[ ! -f "$rs/during.sh" ] || sh "$rs/during.sh" "$n" >/dev/null 2>&1
[ ! -e "$rs/red" ] || { echo "check: FAIL"; exit 1; }
echo "check: OK"
CHECK
  } > "$wt/scripts/check.sh"
  chmod +x "$wt/scripts/check.sh"
  printf 'PRE_PUSH_LOAD_LIMIT="0"\n%s' "${3:+INTEGRATE_MAX_ROUNDS=\"$3\"}" > "$wt/.ai-core/config.env"
  git -C "$wt" add -f -A && git -C "$wt" commit -q -m "Plant the check #$1"
  git -C "$wt" push -q origin "issue-$1-$2" 2>/dev/null
  printf '%s' "$wt"
}
judged() { wc -l < "$rs/judged" | tr -d ' '; }
judged_commit() { awk -v n="$1" 'NR == n { print $1 }' "$rs/judged"; }
last_green_row() { awk -F'\t' '$5 == "green" { c = $4 } END { print c }' "$AI_CORE_HOME/.ai-core/pre-push-runs.tsv"; }
other_commits() { git --git-dir="$origin" log --format=%s "$1..master" | grep -c '^Other #1$' || true; }
# land_racing <number> <slug> <limit or empty> <moves> [the script to run]: a private landing in the issue's worktree through the real gate; sets wt, rs, before, out, rc, sha
land_racing() {
  wt="$(racing_tree "$1" "$2" "$3")"; rs="$fake/rs-$1"; echo "$4" > "$rs/moves"; sha="$(git -C "$wt" rev-parse HEAD)"
  [ -z "${RED:-}" ] || : > "$rs/red"; [ -z "${DURING:-}" ] || printf '[ "$1" = 1 ] || exit 0\n%s\n' "${DURING//@WT@/$wt}" > "$rs/during.sh"
  echo private > "$fake/visibility"; git -C "$work" config core.hooksPath "$fake/gate-hooks"
  before="$(tip)"
  out="$(cd "$wt" && bash "${5:-$root/bin/integrate-issue.sh}" "$1" --reviewed-by l4 2>&1)"; rc=$?
  git -C "$work" config --unset core.hooksPath; rm -f "$fake/visibility"
}
no_leftovers() { check "$1: no temporary worktree and no lock is left" '0 no' "$(git -C "$work" worktree list | grep -c 'integrate-' || true) $([ -e "$work/.git/ai-core-landing" ] && echo yes || echo no)"; }

echo 'the default branch moving once during the gate of the first round: the landing lands in the second round, on the new tip, with a gate of its own'
land_racing 980 rounds-once "" 1
merged="$(tip)"
check 'exit 0, one merge commit, one commit of the other session'  '0 1 1' "$rc $(git --git-dir="$origin" rev-list --merges --count "$before..master") $(other_commits "$before")"
check 'the gate judged two merge commits, the second one is on the default branch and the first one is not' "2 $merged no" "$(judged) $(judged_commit 2) $(git --git-dir="$origin" merge-base --is-ancestor "$(judged_commit 1)" master 2>/dev/null && echo yes || echo no)"
check 'the second merge is made on the tip the other session landed, and holds the reviewed head' "$(git --git-dir="$origin" rev-parse "$merged^1") $sha" "$(git --git-dir="$origin" log -1 --format=%H --grep='^Other #1$' "$before..master") $(git --git-dir="$origin" rev-parse "$merged^2")"
check 'the record of the gate names the commit that landed, green' "$merged" "$(last_green_row)"
check 'the output names both rounds and the limit' yes "$(grep -q '^round 1 of 3: the merge commit ' <<< "$out" && grep -q '^round 2 of 3: the round before ended because master moved on origin from [0-9a-f]\{40\} to [0-9a-f]\{40\} after this landing fetched it' <<< "$out" && echo yes || echo no)"
check 'the branch is checked out again'                         issue-980-rounds-once "$(git -C "$wt" symbolic-ref --short HEAD)"
no_leftovers 'once'

echo 'a default branch that does not move lands in the first round (innocent case); the planted copy that stops after the first round does not land the moved one'
land_racing 981 rounds-still "" 0
check 'exit 0, one gate, one round'                              '0 1 yes' "$rc $(judged) $(grep -q '^round 2 of' <<< "$out" && echo no || echo yes)"
mutant_integrate "$fake/mutant-one-round" 's/if \[ "\$round" -gt "\$rounds_limit" \]; then/if [ "$round" -gt 1 ]; then/'
land_racing 982 rounds-planted "" 1 "$fake/mutant-one-round/bin/integrate-issue.sh"
check 'planted: a loop that stops after the first round leaves the landing unlanded (exit 1, no merge, one gate)' '1 0 1' "$rc $(git --git-dir="$origin" rev-list --merges --count "$before..master") $(judged)"
land_racing 983 rounds-planted-ok "" 1
check 'the same landing with the real loop lands'                '0 1' "$rc $(git --git-dir="$origin" rev-list --merges --count "$before..master")"

echo 'every round finds the default branch moved: the bound stops it with nothing pushed, the commits of the other session remain'
land_racing 984 rounds-bound 2 5
check 'exit 1, two gates, no merge of the landing, two commits of the other session' '1 2 0 2' "$rc $(judged) $(git --git-dir="$origin" rev-list --merges --count "$before..master") $(other_commits "$before")"
check 'it names the cause, the round that was the last and the setting' yes "$(grep -q 'nothing landed: master moved on origin from [0-9a-f]\{40\} to [0-9a-f]\{40\} after this landing fetched it.*round 2 was the last that INTEGRATE_MAX_ROUNDS (2) allows, and nothing was pushed to master' <<< "$out" && echo yes || echo no)"
check 'it does not claim that nothing was pushed anywhere' no "$(grep -qi 'nothing was pushed anywhere' <<< "$out" && echo yes || echo no)"
check 'the branch is checked out again'                         issue-984-rounds-bound "$(git -C "$wt" symbolic-ref --short HEAD)"
no_leftovers 'bound'
land_racing 985 rounds-third 3 2
check 'two moves and three rounds: it lands in the third'        '0 3 1' "$rc $(judged) $(git --git-dir="$origin" rev-list --merges --count "$before..master")"
land_racing 986 rounds-one 1 1
check 'a limit of 1 is a single attempt'                         '1 1 0' "$rc $(judged) $(git --git-dir="$origin" rev-list --merges --count "$before..master")"

echo 'a move that conflicts with the branch stops the landing in the second round, before its gate'
wt="$(racing_tree 987 rounds-conflict "")"; rs="$fake/rs-987"; echo 1 > "$rs/moves"
printf 'cd "$(mktemp -d)" && git clone -q "%s" c && cd c && git config user.email t@example.invalid && git config user.name t && echo other > rounds-conflict.txt && git add -A && git commit -q -m "Other #1" && git push -q origin master\n' "$origin" > "$rs/move.sh"
echo "x" > "$wt/rounds-conflict.txt"; git -C "$wt" add -A && git -C "$wt" commit -q -m 'Write the same file #987' && git -C "$wt" push -q origin issue-987-rounds-conflict 2>/dev/null
echo private > "$fake/visibility"; git -C "$work" config core.hooksPath "$fake/gate-hooks"; before="$(tip)"
out="$(cd "$wt" && bash "$root/bin/integrate-issue.sh" 987 --reviewed-by l4 2>&1)"; rc=$?
git -C "$work" config --unset core.hooksPath; rm -f "$fake/visibility"
check 'exit 1, one gate, no merge, the commit of the other session is there' '1 1 0 1' "$rc $(judged) $(git --git-dir="$origin" rev-list --merges --count "$before..master") $(other_commits "$before")"
check 'it says which branch does not merge' yes "$(grep -q 'issue-987-rounds-conflict does not merge cleanly into origin/master' <<< "$out" && echo yes || echo no)"
no_leftovers 'conflict'

echo 'a red gate beside a move stays a red gate: no second round; the planted copy that takes the tip alone for a race makes one'
RED=1 land_racing 988 rounds-red "" 1
check 'exit 1, one gate and no second round, no merge, the commit of the other session is there' '1 1 0 1' "$rc $(judged) $(git --git-dir="$origin" rev-list --merges --count "$before..master") $(other_commits "$before")"
check 'it shows the red check and says that origin refused nothing for a move' yes "$(grep -q 'check: FAIL' <<< "$out" && grep -q 'the push was refused (see above) - nothing reached origin' <<< "$out" && ! grep -q '^round 2 of' <<< "$out" && echo yes || echo no)"
mutant_integrate "$fake/mutant-tip-only" 's/ && grep -Eq .* <<< "\$said"; then$/; then/'
RED=1 land_racing 989 rounds-red-planted "" 1 "$fake/mutant-tip-only/bin/integrate-issue.sh"
check 'planted: a landing that takes the tip alone for a race makes a second round after a red gate' yes "$(grep -q '^round 2 of' <<< "$out" && echo yes || echo no)"
no_leftovers 'red'

echo 'a value that is no number of rounds stops the landing before anything is merged or pushed, naming the key; the default of 3 holds where the file sets none'
for bad in abc 0 -1 1.5 03 99999999999; do
  wt="$(racing_tree 990 rounds-bad "$bad")"; rs="$fake/rs-990"; before="$(tip)"
  out="$(cd "$wt" && bash "$root/bin/integrate-issue.sh" 990 --reviewed-by l4 2>&1)"; rc=$?
  check "the value '$bad': exit 1, the key and the value named, nothing judged, nothing merged" '1 yes 0 0' "$rc $(grep -qF "INTEGRATE_MAX_ROUNDS is '$bad' in " <<< "$out" && echo yes || echo no) $(judged) $(git --git-dir="$origin" rev-list --merges --count "$before..master")"
  git -C "$work" worktree remove --force "$wt"; git -C "$work" branch -q -D issue-990-rounds-bad; git --git-dir="$origin" branch -q -D issue-990-rounds-bad
done

echo 'the bound is read again before every round: a file lowered during the first round ends the landing, a file broken during it stops the landing naming the key'
DURING='printf "PRE_PUSH_LOAD_LIMIT=\"0\"\nINTEGRATE_MAX_ROUNDS=\"1\"\n" > "@WT@/.ai-core/config.env"' land_racing 991 rounds-lowered 3 1
check 'lowered to 1: exit 1, one gate, no merge, round 1 named as the last' '1 1 0 yes' "$rc $(judged) $(git --git-dir="$origin" rev-list --merges --count "$before..master") $(grep -q 'round 1 was the last that INTEGRATE_MAX_ROUNDS (1) allows' <<< "$out" && echo yes || echo no)"
git -C "$wt" checkout -q -- .ai-core/config.env
DURING='printf "INTEGRATE_MAX_ROUNDS=\"soon\"\n" > "@WT@/.ai-core/config.env"' land_racing 992 rounds-broken 3 1
check 'broken: exit 1, one gate, no merge, the key named' '1 1 0 yes' "$rc $(judged) $(git --git-dir="$origin" rev-list --merges --count "$before..master") $(grep -qF "nothing landed, and no round 2 was started: INTEGRATE_MAX_ROUNDS is 'soon'" <<< "$out" && echo yes || echo no)"
git -C "$wt" checkout -q -- .ai-core/config.env

echo 'a reviewed branch that holds another commit in the second round than in the first stops the landing; nothing lands that the reviewer did not read'
DURING='b=$(git -C "@WT@" symbolic-ref --short -q HEAD || git -C "@WT@" for-each-ref --format="%(refname:short)" refs/heads/issue-993-rounds-head); git -C "@WT@" update-ref "refs/heads/$b" "$(git -C "@WT@" commit-tree -p "refs/heads/$b" -m extra "refs/heads/$b^{tree}")"' land_racing 993 rounds-head "" 1
check 'exit 1, one gate, no merge, the branch and the two commits named' '1 1 0 yes' "$rc $(judged) $(git --git-dir="$origin" rev-list --merges --count "$before..master") $(grep -q 'issue-993-rounds-head is at [0-9a-f]\{40\}, but round 1 of this landing read [0-9a-f]\{40\}' <<< "$out" && echo yes || echo no)"
no_leftovers 'head'

echo 'the same in the other paths: --from-origin from the main checkout, and a list of two issues'
wt="$(racing_tree 994 rounds-origin "")"; rs="$fake/rs-994"; echo 1 > "$rs/moves"; sha="$(git -C "$wt" rev-parse HEAD)"
echo private > "$fake/visibility"; git -C "$work" config core.hooksPath "$fake/gate-hooks"; before="$(tip)"
out="$(cd "$work" && bash "$root/bin/integrate-issue.sh" 994 --reviewed-by l4 --from-origin 2>&1)"; rc=$?
git -C "$work" config --unset core.hooksPath; rm -f "$fake/visibility"
check '--from-origin: lands in the second round, the second merge is the one the gate judged and last recorded green' "0 2 $(tip) $(tip) 1" "$rc $(judged) $(judged_commit 2) $(last_green_row) $(git --git-dir="$origin" rev-list --merges --count "$before..master")"
no_leftovers '--from-origin'
wt="$(racing_tree 995 rounds-list-a "")"; rs="$fake/rs-995"; echo 1 > "$rs/moves"; sha="$(git -C "$wt" rev-parse HEAD)"
wt_b="$(new_tree 996 rounds-list-b)"; git -C "$wt_b" push -q origin issue-996-rounds-list-b 2>/dev/null
echo private > "$fake/visibility"; git -C "$work" config core.hooksPath "$fake/gate-hooks"; before="$(tip)"
out="$(cd "$wt" && bash "$root/bin/integrate-issue.sh" 995 996 --reviewed-by l4 2>&1)"; rc=$?
git -C "$work" config --unset core.hooksPath; rm -f "$fake/visibility"
check 'a list: lands in the second round, one merge commit per issue, the gate judged the last' "0 2 2 $(tip) $(tip)" "$rc $(judged) $(git --git-dir="$origin" rev-list --merges --count "$before..master") $(judged_commit 2) $(last_green_row)"
no_leftovers 'a list'

echo 'a public repository: the default branch moving while the checks of the first round are waited for makes a second round, with its own push to ci/ and its own checks'
before="$(tip)"
land_public 997 rounds-public "$success" 5 "$push_to_master"
merged="$(tip)"
check 'exit 0, one merge commit, the second round named, ci/integrate-<branch> deleted' '0 1 yes' "$rc $(git --git-dir="$origin" rev-list --merges --count "$before..master") $(grep -q '^round 2 of 3: ' <<< "$out" && echo yes || echo no)"
check 'the checks were green twice, the last for the commit that landed' "2 yes" "$(grep -c '^checks: green for' <<< "$out") $(grep -q "^checks: green for ${merged:0:7} on ci/integrate-issue-997-rounds-public" <<< "$out" && echo yes || echo no)"
check 'ci/integrate-<branch> is deleted and the lock is released' ' no' "$(ci_tip issue-997-rounds-public) $([ -e "$work/.git/ai-core-landing" ] && echo yes || echo no)"

echo 'a push that git reports as failed while a newer commit of origin holds the merge commit is not denied'
mkdir -p "$fake/above-hooks"
printf '#!/bin/sh
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX
[ ! -e "$ABOVE_MARKER" ] || exit 0
: > "$ABOVE_MARKER"
git push -q origin HEAD:refs/heads/master
%s
exit 1
' "$push_to_master" > "$fake/above-hooks/pre-push"; chmod +x "$fake/above-hooks/pre-push"
git -C "$work" config core.hooksPath "$fake/above-hooks"; echo private > "$fake/visibility"
wt="$(new_tree 998 pushed-above)"; git -C "$wt" push -q origin issue-998-pushed-above 2>/dev/null
before="$(tip)"; rm -f "$fake/above.marker"
out="$(cd "$wt" && ABOVE_MARKER="$fake/above.marker" integrate_here 998)"; rc=$?
git -C "$work" config --unset core.hooksPath; rm -f "$fake/visibility"
check 'exit 0, one merge commit below the newer commit' '0 1 Other #1' "$rc $(git --git-dir="$origin" rev-list --merges --count "$before..master") $(git --git-dir="$origin" log -1 --format=%s master)"
check 'it says that origin holds the commit although git failed' yes "$(grep -qE 'origin holds [0-9a-f]{7} on master although git reported a failure: the landing went through' <<< "$out" && echo yes || echo no)"

echo
[ "$failed" -eq 0 ] && echo 'all passed' || echo "$failed failed"
[ "$failed" -eq 0 ]
