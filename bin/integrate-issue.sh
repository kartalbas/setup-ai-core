#!/usr/bin/env bash
# Integrate the reviewed branch of one issue into the default branch: a merge commit that names the
# issue and its reviewer, pushed through the gate.
#
#   integrate-issue.sh [OWNER/REPO] NUMBER --reviewed-by REVIEWER [--reviewed-by REVIEWER ...] [--from-origin]
#
# Between start-issue and finish-issue. Run it in the worktree of the issue, on its branch, once the
# reviewer gave the GO. It fetches origin, puts the worktree on the newest origin/<default>, merges
# the branch with --no-ff under the issue's title and a 'Reviewed-by: REVIEWER' trailer per
# reviewer, pushes HEAD:<default> through the gate, and checks the branch out again for
# finish-issue. The issue is read in OWNER/REPO where it is given, else in the repository
# start-issue recorded on the branch, else in the checkout's own.
#
# --from-origin LANDS THE BRANCH AS ORIGIN HOLDS IT, FROM ANY DIRECTORY OF THE CLONE, for a branch
# whose worktree another session holds and nobody may touch: its changes may be somebody's work in
# progress. The merge is made in a temporary worktree of origin/<default>, which is removed on every
# way out, so the issue's worktree, its branch and its changes stay as they were. It stands beside the
# clone in .worktrees/<repo>/, where start-issue cuts the worktrees of the clone, named
# integrate-<number>.XXXXXX (no issue's worktree is named so): a project test that walks up from its
# checkout to a sibling checkout finds it there, as in any other worktree, and not under the
# temporary folder of the machine. It is a flag, not a detection: without it a run outside the
# issue's worktree stays refused, so a wrong directory never lands a branch by accident. It merges
# origin/<branch> and says at which commit: what the branch holds only locally does not land.
# Where the merged tree carries scripts/install.sh, it runs there before the push, so the gate's
# check finds what it needs installed; a failing install refuses the landing, and nothing is pushed.
#
# A PUBLIC REPOSITORY LANDS ONLY ON THE GREEN CHECKS OF THE COMMIT THAT LANDS. Before anything is made, the
# forge says whether the repository of origin is public. If it is, in both paths the merge commit is made in
# a temporary worktree of origin/<default> (so the issue's worktree is not touched) and pushed to
# ci/integrate-<issue branch>, a name only a landing uses, in the family of the integrate-<number>.XXXXXX
# worktrees, so a ci/<issue branch> a person pushed for the CI is never touched. Its checks are waited for
# (every 20 seconds, 30 minutes at most; AI_CORE_INTEGRATE_POLL and AI_CORE_INTEGRATE_WAIT, in seconds, for a
# suite): the CI of a repository may run on ci/ branches and the default branch only, so the issue branch
# itself may never get one. The wait is the one release uses (wait_for_checks in lib/forge.sh) and happens
# before the landing lock is taken, so a slow CI holds up no other landing. Green says which commit was
# green and on which branch; then, with the lock held and origin fetched, the push to the default branch
# sends exactly that commit. Red checks, checks that do not finish or cannot be read, an origin/<default>
# that moved while they ran and an issue branch whose tip moved refuse with nothing pushed to the default
# branch. The push to ci/integrate-<issue branch> replaces what stands there (the left-over of an earlier
# landing of the issue that was killed), but only if it is still what was read just before the push (a
# lease): a branch written in between is refused. The delete removes the branch only while it holds this
# landing's merge commit (a lease again), and names it in one line when it stays. It runs on every way out
# that can be trapped; a SIGKILL leaves the branch behind, and the next landing of the issue replaces it.
# Without --from-origin, a local branch tip that origin does not hold has no checks and refuses at once. A
# private repository rests on its push gate, which is its check: nothing goes to ci/ and no CI is read, and
# one line says so. A visibility the forge does not establish refuses.
#
# A MERGE COMMIT, NOT A REBASE: the reviewed commits land as they were read, with the shas the
# reviewer saw, and the one new commit carries the issue and the reviewer.
#
# THE REVIEWER IS A NAME GIVEN, NOT A REVIEW PROVEN. Without --reviewed-by this refuses; with it, the
# name goes into the history, where it can be traced, and nothing here can tell whether the review
# took place.
#
# NOTHING IS LEFT HALF DONE. A conflict aborts the merge, a branch already in the default branch has
# nothing to integrate, and a push the gate refuses reaches nothing; each time the branch is checked
# out again and the cause is named.
#
# THE LANDINGS OF ONE CLONE TAKE TURNS. Git fixes the old value of the remote branch when the push
# starts, before the gate runs, so a landing that moves the default branch while another one's gate
# runs refuses the other's push. From the fetch to the end of the push this holds the file
# ai-core-landing in the clone's git directory, which every worktree of the clone shares: its process id and its issue. A landing that finds it held waits; one whose holder
# no longer runs takes it over.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/board.sh"
. "$ROOT/lib/forge.sh"

BIN="$ROOT/bin"
usage='usage: integrate-issue.sh [OWNER/REPO] NUMBER --reviewed-by REVIEWER [--reviewed-by REVIEWER ...] [--from-origin]'

# Every --reviewed-by adds its reviewer, once, in the order given: a second one that overwrote the
# first would drop a review from the history without a word
repo=""; number=""; reviewers=(); from_origin=""
add_reviewer() {  # add_reviewer <name>
  local known
  for known in ${reviewers[@]+"${reviewers[@]}"}; do [ "$known" != "$1" ] || return 0; done
  reviewers+=("$1")
}
while [ $# -gt 0 ]; do
  case "$1" in
    --reviewed-by)   [ $# -ge 2 ] || die "--reviewed-by takes the reviewer's name - $usage"; add_reviewer "$2"; shift ;;
    --reviewed-by=*) add_reviewer "${1#--reviewed-by=}" ;;
    --from-origin)   from_origin=1 ;;
    -*)              die "unknown argument '$1' - $usage" ;;
    */*)             [ -z "$repo" ] || die "$usage"; repo="$1" ;;
    *)               [ -z "$number" ] || die "$usage"; number="$1" ;;
  esac
  shift
done
case "$number" in ''|*[!0-9]*) die "the issue number must be numeric, not '$number' - $usage" ;; esac
[ "${#reviewers[@]}" -gt 0 ] || die "who reviewed the work? --reviewed-by names the reviewer whose GO this integrates - $usage"
for reviewer in "${reviewers[@]}"; do
  [ -n "${reviewer//[[:space:]]/}" ] || die "who reviewed the work? --reviewed-by names the reviewer whose GO this integrates - $usage"
  case "$reviewer" in *$'\n'*) die "--reviewed-by takes one line" ;; esac
done
trailers="$(printf 'Reviewed-by: %s\n' "${reviewers[@]}")"

git rev-parse --show-toplevel >/dev/null 2>&1 \
  || die "not inside a git working copy - run this in the worktree of issue $number"
if [ -z "$from_origin" ]; then
  branch="$(git symbolic-ref --short -q HEAD)" || branch=""
  case "$branch" in
    "issue-$number"|"issue-$number-"*) ;;
    *) die "this runs in the worktree of issue $number, on its branch issue-$number-*; here ${branch:-no branch} is checked out (--from-origin lands the branch as origin holds it, from any directory)" ;;
  esac
  [ -z "$(git status --porcelain)" ] \
    || die "the worktree has changes - commit them for the review, or put them aside, then run this again"
else
  # The name is read from origin itself: a clone that never fetched the branch has no ref to list
  heads="$(git ls-remote --heads origin "refs/heads/issue-$number" "refs/heads/issue-$number-*" 2>&1)" \
    || die "could not reach origin: $heads"
  branch="$(printf '%s\n' "$heads" | awk '$2 ~ "^refs/heads/" { sub("^refs/heads/", "", $2); print $2 }')"
  listed_tip="$(printf '%s\n' "$heads" | awk '$2 ~ "^refs/heads/" { print $1 }')"
  case "$branch" in
    '')       die "origin has no branch issue-$number-* to integrate - push the reviewed branch, then run this again" ;;
    *$'\n'*)  die "origin has more than one branch for issue $number, and which one the reviewer read is not for this command to guess: $(printf '%s' "$branch" | tr '\n' ' ')" ;;
  esac
fi

[ -n "$repo" ] || repo="$(branch_issue_repo "$branch")"
# The one tracker call before anything moves. A refusal of it, a rate limit among them, says in plain
# words that nothing landed: a coordinator that read a bare error as "landed" released without the work.
title="$(apart "$BIN/issue-thread.sh" ${repo:+"$repo"} "$number" --json)" \
  || die "nothing landed: the issue $number could not be read from $(tracker_name), so nothing was merged or pushed and origin is as it was: $title"
title="$(printf '%s' "$title" | jq -r '.title // ""')"
ref="$(issue_ref "$repo" "$number")"
# The subject the gate takes is 72 characters at most, so a longer one falls back, shortest last
subject="$title ($ref)"
[ -n "$title" ] && [ "${#subject}" -le 72 ] || subject="Merge $branch ($ref)"
[ "${#subject}" -le 72 ] || subject="Merge issue-$number ($ref)"

landing="$(git rev-parse --path-format=absolute --git-common-dir)/ai-core-landing"
# The branch ci/integrate-<issue branch> on origin and the temporary worktree go first, on every way out,
# then the lock. The branch is deleted only while it still holds the merge commit of this landing (a lease),
# so a branch somebody else wrote stays; a branch that is not there is nothing to delete. A branch that
# stays or cannot be deleted is named in one line and changes nothing about the outcome. A kill that
# cannot be trapped (SIGKILL) runs none of this and leaves the branch behind.
tree=""; ci_branch=""
delete_ci_branch() {
  local said
  [ -n "$ci_branch" ] || return 0
  said="$(git ls-remote origin "refs/heads/$ci_branch" 2>&1)" \
    || { echo "$ci_branch could not be looked up on origin, so it was not deleted; delete it by hand if it stands: $(printf '%s' "$said" | tr -s '\r\n' '  ')" >&2; return 0; }
  [ -n "$said" ] || return 0
  said="$(git push origin "--force-with-lease=refs/heads/$ci_branch:$merged_sha" --delete "refs/heads/$ci_branch" 2>&1)" && return 0
  case "$said" in
    *"stale info"*|*"cannot lock ref"*) echo "$ci_branch on origin is not the merge commit ${merged_sha:0:7} of this landing, so it was left in place" >&2 ;;
    *) echo "$ci_branch could not be deleted on origin, delete it by hand: $(printf '%s' "$said" | tr -s '\r\n' '  ')" >&2 ;;
  esac
}
trap 'delete_ci_branch
  [ -z "$tree" ] || git worktree remove --force "$tree" >/dev/null 2>&1 || rm -rf "$tree"
  [ "$(cut -f1 "$landing" 2>/dev/null)" != "$$" ] || rm -f "$landing"' EXIT

# make_merge <tip> <name of the tip>: the merge commit of the tip into origin/<default>, made in a temporary
# worktree beside the clone (tree), where scripts/install.sh of the merged tree runs if it has one, so the
# gate's check finds what it needs. Sets base_tip (the origin/<default> it was made on), merged_sha, merged.
make_merge() {
  local container
  [ -n "$(git rev-list -n1 "$1" --not "origin/$default")" ] \
    || die "nothing to integrate: $2 is in origin/$default already"
  [ -z "$from_origin" ] || echo "merging: $2 at $(git rev-parse --short "$1")"
  container="$(worktree_container)" && mkdir -p "$container" \
    && tree="$(mktemp -d "$container/integrate-$number.XXXXXX")" || die "no folder for the temporary worktree beside the clone"
  git worktree add -q --detach "$tree" "origin/$default" || die "the temporary worktree could not be made on origin/$default (see above)"
  base_tip="$(git -C "$tree" rev-parse HEAD)"
  git -C "$tree" merge -q --no-ff --no-edit "$1" -m "$subject" -m "$trailers" \
    || die "$2 does not merge cleanly into origin/$default - bring origin/$default into the branch, get the review of the result, then run this again; nothing was pushed"
  merged_sha="$(git -C "$tree" rev-parse HEAD)"
  merged="$(git -C "$tree" rev-parse --short HEAD)"
  if [ -f "$tree/scripts/install.sh" ]; then
    echo "installing: scripts/install.sh of the merged tree runs in $tree, so the gate's check finds what it needs"
    (cd "$tree" && bash scripts/install.sh) \
      || die "scripts/install.sh failed in the temporary worktree (see above) - nothing was pushed, origin is as it was, and the worktree of $branch is as it was"
  fi
}

# keep_waited_tip <ref>: once the lock is held and origin fetched, the reviewed tip is still the tip of <ref>,
# else nothing lands. Nothing is waited for in a private repository, so there it holds nothing.
waited_tip=""
keep_waited_tip() {
  local now
  [ -n "$waited_tip" ] || return 0
  now="$(git rev-parse -q --verify "$1^{commit}")" || now="nothing"
  [ "$now" = "$waited_tip" ] \
    || die "nothing landed: $1 moved from $waited_tip to $now while its checks were waited for; run this again"
}

# gate_public_repository: a public repository lands only on the green checks of the commit that lands. It
# runs before the landing lock, so a slow CI holds up no other landing, and before anything reaches the
# default branch. The merge commit is made in a temporary worktree and pushed to ci/integrate-<issue
# branch>, which only a landing uses: a left-over of an earlier killed landing is replaced, but only if it is
# still what was read just before the push (a lease), so a branch written meanwhile is refused. Its checks are waited for; the push to the default branch after the lock sends exactly the
# merge commit. A private repository
# rests on its push gate: nothing is made or pushed here, and no CI is read. The reviewed tip is the one
# origin lists for --from-origin, else the local branch, which must be the tip origin holds too.
base_tip=""; merged_sha=""; merged=""
gate_public_repository() {
  local checked_repo visibility tip tip_name poll limit checks=0 on_origin said held
  checked_repo="$(origin_repo)" || die "nothing landed: origin names no repository, so its visibility cannot be established"
  visibility="$(apart forge_repo_visibility "$checked_repo")" \
    || die "nothing landed: the visibility of $checked_repo cannot be established, so it is not known whether its checks must be green: $visibility"
  if [ "$visibility" = private ]; then
    echo "checks: $checked_repo is private, its push gate is its check; the CI of $(forge_name) is not read"
    return 0
  fi
  if [ -n "$from_origin" ]; then
    tip="$listed_tip"; tip_name="origin/$branch"
  else
    tip="$(git rev-parse "$branch^{commit}")"; tip_name="$branch"
    on_origin="$(GIT_TERMINAL_PROMPT=0 git ls-remote origin "refs/heads/$branch" 2>&1)" \
      || die "could not reach origin: $on_origin"
    [ "${on_origin%%[[:space:]]*}" = "$tip" ] \
      || die "nothing landed: $tip is not on origin, so it has no checks; push the branch, then run this again"
  fi
  said="$(git fetch origin 2>&1)" || die "could not reach origin: $said"
  default="$(origin_default_branch)" || exit 1
  waited_tip="$tip"
  keep_waited_tip "origin/$branch"
  make_merge "$tip" "$tip_name"
  ci_branch="ci/integrate-$branch"
  held="$(git ls-remote origin "refs/heads/$ci_branch" 2>&1)" || die "could not reach origin: $held"
  held="${held%%[[:space:]]*}"
  said="$(git -C "$tree" push origin "--force-with-lease=refs/heads/$ci_branch:$held" "$merged_sha:refs/heads/$ci_branch" 2>&1)" || case "$said" in
    *"stale info"*|*"cannot lock ref"*) die "nothing landed: $ci_branch on origin changed after it was read, so another landing of this branch may be running; nothing was pushed to it or to $default: $said" ;;
    *) die "nothing landed: the merge commit ${merged_sha:0:7} could not be pushed to $ci_branch for its checks, and nothing reached $default: $said" ;;
  esac
  poll="${AI_CORE_INTEGRATE_POLL:-20}"; limit="${AI_CORE_INTEGRATE_WAIT:-1800}"
  wait_for_checks "$tree" "$merged_sha" "$poll" "$limit" \
    "waiting: $checked_repo is public and lands only on green checks; the checks of ${merged_sha:0:7} on $ci_branch are asked every ${poll}s, $((limit / 60)) minute(s) at most" || checks=$?
  case "$checks" in
    0) echo "checks: green for ${merged_sha:0:7} on $ci_branch at $(forge_name); $checked_repo is public and lands only on green checks" ;;
    1) die "nothing landed: the checks for $merged_sha on $ci_branch are red, so nothing was pushed to $default and origin/$default is as it was" ;;
    2) die "nothing landed: the checks for $merged_sha on $ci_branch did not finish in $((limit / 60)) minute(s), so nothing was pushed to $default. A new run makes a new merge commit and waits for a new CI run; set AI_CORE_INTEGRATE_WAIT (seconds, $limit now) higher if the CI takes longer" ;;
    *) die "nothing landed: $(checks_unreadable_message "$merged_sha" "$checks_said")" ;;
  esac
}

gate_public_repository

# A known limit: two waiters that find the same dead holder can both take over, and the push then still
# refuses the second, as it does without the lock; a holder's process id that an unrelated process
# took over keeps the lock held, and the waiting line names that process
waited=""; missing=0; nameless=0
until said="$( (set -C; printf '%s\t%s\n' "$$" "$ref" > "$landing") 2>&1 )"; do
  # Gone between the two steps is a lock just released; gone twice in a row, one never written
  if ! holder="$(cat "$landing" 2>/dev/null)"; then
    missing=$((missing + 1)); [ "$missing" -lt 2 ] || die "the landing lock $landing could not be written: $said"; continue
  fi
  missing=0; pid="${holder%%$'\t'*}"
  # A lock still without its process id after the poll was never finished: nobody holds it
  dead=""
  case "$pid" in
    ''|*[!0-9]*) nameless=$((nameless + 1)); [ "$nameless" -lt 2 ] || dead="a landing lock that names no process: '$holder'" ;;
    *) nameless=0; ps -p "$pid" >/dev/null 2>&1 || dead="the landing lock of ${holder#*$'\t'}, whose process $pid no longer runs" ;;
  esac
  if [ -n "$dead" ]; then
    rm -f "$landing" || die "the landing lock $landing could not be removed: $dead"
    echo "taken over: $dead" >&2; nameless=0; continue
  fi
  [ -n "$waited" ] || [ "$nameless" -gt 0 ] || { waited=1; echo "waiting: ${holder#*$'\t'} is landing from this clone (process $pid); this one lands after it" >&2; }
  sleep 2
done
said="$(git fetch origin 2>&1)" || die "could not reach origin: $said"
default="$(origin_default_branch)" || exit 1

# back_to_branch <reason>: the worktree goes back to the branch it was on, and the run stops
back_to_branch() {
  git switch -q "$branch" 2>/dev/null || echo "error: the branch $branch could not be checked out again - run git switch $branch" >&2
  die "$1"
}

if [ -n "$waited_tip" ]; then
  # The public repository: the merge commit made and checked before the lock lands as it is, if nothing moved
  now="$(git rev-parse "origin/$default^{commit}")" || die "origin/$default is not there after the fetch"
  [ "$now" = "$base_tip" ] \
    || die "nothing landed: origin/$default moved from $base_tip to $now while the checks of $merged_sha ran; run this again"
  keep_waited_tip "origin/$branch"
  [ -n "$from_origin" ] || keep_waited_tip "$branch"
  git -C "$tree" push origin "$merged_sha:refs/heads/$default" \
    || die "the push was refused (see above) - nothing reached origin, and the worktree of $branch is as it was"
elif [ -n "$from_origin" ]; then
  tip="$(git rev-parse -q --verify "origin/$branch^{commit}")" || die "origin/$branch is not there after the fetch - push the reviewed branch, then run this again"
  make_merge "$tip" "origin/$branch"
  git -C "$tree" push origin "HEAD:$default" \
    || die "the push was refused (see above) - nothing reached origin, and the worktree of $branch is as it was"
else
  [ -n "$(git rev-list -n1 "$branch" --not "origin/$default")" ] \
    || die "nothing to integrate: $branch is in origin/$default already"
  git switch -q --detach "origin/$default" || die "the worktree could not be put on origin/$default (see above)"
  if ! git merge -q --no-ff --no-edit "$branch" -m "$subject" -m "$trailers"; then
    git merge --abort 2>/dev/null
    back_to_branch "$branch does not merge cleanly into origin/$default - bring origin/$default into the branch, get the review of the result, then run this again"
  fi
  merged="$(git rev-parse --short HEAD)"
  git push origin "HEAD:$default" \
    || back_to_branch "the push was refused (see above) - nothing reached origin, and $branch is checked out again"
  git switch -q "$branch" || die "$merged is on origin/$default, but $branch could not be checked out again - run git switch $branch before finish-issue"
fi
checkout="$(cd "$(dirname "$landing")/.." && pwd)"
if ! fast_forward_default_branch "$checkout"; then
  echo "integration succeeded: $merged is on origin/$default; checkout $checkout was not refreshed" >&2
fi
echo "integrated: $merged on origin/$default, $subject$(printf ', Reviewed-by: %s' "${reviewers[@]}")"
# Every issue the merged commits name in parentheses, the integrated one first: a package lands
# several issues in one merge, and the card of each moves on only through its own finish-issue. Only
# the forms '(#N)' and '(owner/repo#N)' count: a number named in passing is no landing.
own="$(default_repo 2>/dev/null | tr 'A-Z' 'a-z')" || own=""
{ echo "$ref"; git log --reverse --format=%s "$merged^1..$merged^2" | { grep -oE '\(([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)?#[0-9]+\)' || true; } | tr -d '()'; } |
  while IFS= read -r named; do
    landed_repo="${named%#*}"
    [ "$(printf '%s' "$landed_repo" | tr 'A-Z' 'a-z')" != "$own" ] || landed_repo=""
    echo "next: ai-core finish-issue ${landed_repo:+$landed_repo }${named##*#}"
  done | awk '!seen[tolower($0)]++'
