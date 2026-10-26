#!/usr/bin/env bash
# Integrate the reviewed branch of one issue into the default branch: a merge commit that names the
# issue and its reviewer, pushed through the gate.
#
#   integrate-issue.sh [OWNER/REPO] NUMBER [NUMBER ...] --reviewed-by REVIEWER [--reviewed-by REVIEWER ...] [--from-origin]
#
# Between start-issue and finish-issue. Run it in the worktree of the issue, on its branch, once the
# reviewer gave the GO. It fetches origin, puts the worktree on the newest origin/<default>, merges
# the branch with --no-ff under the issue's title and a 'Reviewed-by: REVIEWER' trailer per
# reviewer, pushes HEAD:<default> through the gate, and checks the branch out again for
# finish-issue. The issue is read in OWNER/REPO where it is given, else in the repository
# start-issue recorded on the branch, else in the checkout's own; every number of a list is read
# in the repository of the first.
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
# AFTER A CARRY FROM GITHUB the branch of a work item may still be named by the GitHub number, issue-<GitHub number>-...:
# it is the issue's where the tracker, asked for the number of the name at the time the branch was started, answers the
# issue given. A branch of another work item is named and not taken, and the next: lines name the work item that each
# (#N) of a merged commit meant at the time of that commit.
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
# sends exactly that commit. Red checks, checks that do not finish or cannot be read and an issue branch whose
# tip moved refuse with nothing pushed to the default branch; an origin/<default> that moved while they ran
# ends the round, and the next one is made on the new tip (THE ROUNDS below). The push to ci/integrate-<issue branch> replaces what stands there (a left-over of an earlier
# landing of the issue, or the branch of one that still runs), but only if it is still what was read just
# before the push (a lease): a branch written in between is refused. The delete removes the branch only while it holds this
# landing's merge commit (a lease again), and names it in one line when it stays. It runs on every way out
# that can be trapped; a SIGKILL leaves the branch behind, and the next landing of the issue replaces it.
# Without --from-origin, a local branch tip that origin does not hold has no checks and refuses at once. A
# private repository rests on its push gate, which is its check: nothing goes to ci/ and no CI is read, and
# one line says so; so does a public one of a project whose config.env sets CI_GATE="none" (CI_GATE is public
# when unset; any other value refuses before anything is made). A visibility the forge does not establish refuses.
#
# THE REPOSITORY CHECK RUNS ONCE PER LANDED COMMIT. A public landing opens a receipt (lib/landing-check.sh) and
# hands it to the two pushes alone: the gate of the push to ci/ writes its green check into it, this script
# completes it once the push went through and the CI of that commit was green, and the gate of the push to the
# default branch skips scripts/check.sh only for that commit. The receipt is deleted on every way out.
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
# THE ROUNDS. When the default branch moved while a round's gate ran, that round ends with nothing pushed to the
# default branch, and the next round fetches origin again, merges every branch onto the new tip and runs the whole gate
# on that merge: a landing never pushes a merge the gate did not judge, however harmless the commits in between look.
# INTEGRATE_MAX_ROUNDS in the config.env of the checkout it runs in is the most rounds, the first one counted (3 when
# unset, 1 is a single attempt); it is read again before every round, never from the environment, and a value that is no
# whole number from 1 to 999999999 stops the run before the next merge and names the key. Every round says its number and
# the limit, the base and the merge commit. A move is proven by the refusal of origin that git's own porcelain lines name
# together with a tip that differs from the base; the tip alone proves nothing, so a red gate beside a move stays a red
# gate and stops. Stopping at once, with nothing pushed to the default branch: a conflict, an install that fails, red or
# unfinished or unreadable checks, an issue branch that holds another commit than round 1 read, a ci/ branch someone else
# wrote, an origin that cannot be read and any other refusal. A public round may have pushed its merge commit to
# ci/integrate-<issue branch>; the lease delete removes it at the end of the round, and one that stays is named.
# A push that git reports as failed while origin holds the merge commit afterwards is reported as landed.
#
# THE LANDINGS OF ONE CLONE TAKE TURNS. Git fixes the old value of the remote branch when the push
# starts, before the gate runs, so a landing that moves the default branch while another one's gate
# runs refuses the other's push. From the fetch to the end of the push of a round this holds the file
# ai-core-landing in the clone's git directory, which every worktree of the clone shares: its process id and its issue. A landing that finds it held waits; one whose holder
# no longer runs takes it over. A round that ended because the default branch moved gives it up before the next one.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/board.sh"
. "$ROOT/lib/forge.sh"
. "$ROOT/lib/landing-check.sh"

BIN="$ROOT/bin"
usage='usage: integrate-issue.sh [OWNER/REPO] NUMBER [NUMBER ...] --reviewed-by REVIEWER [--reviewed-by REVIEWER ...] [--from-origin]'

# Every --reviewed-by adds its reviewer, once, in the order given: a second one that overwrote the
# first would drop a review from the history without a word
repo=""; numbers=(); reviewers=(); from_origin=""
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
    *)               numbers+=("$1") ;;
  esac
  shift
done
[ "${#numbers[@]}" -gt 0 ] || die "the issue number must be numeric, not '' - $usage"
for number in "${numbers[@]}"; do
  case "$number" in ''|*[!0-9]*) die "the issue number must be numeric, not '$number' - $usage" ;; esac
done
if [ "${#numbers[@]}" -gt 1 ] && [ -n "$(printf '%s\n' "${numbers[@]}" | sort | uniq -d)" ]; then
  die "an issue is named twice: $(printf '%s ' "${numbers[@]}") - $usage"
fi
number="${numbers[0]}"
[ "${#reviewers[@]}" -gt 0 ] || die "who reviewed the work? --reviewed-by names the reviewer whose GO this integrates - $usage"
for reviewer in "${reviewers[@]}"; do
  [ -n "${reviewer//[[:space:]]/}" ] || die "who reviewed the work? --reviewed-by names the reviewer whose GO this integrates - $usage"
  case "$reviewer" in *$'\n'*) die "--reviewed-by takes one line" ;; esac
done
trailers="$(printf 'Reviewed-by: %s\n' "${reviewers[@]}")"

git rev-parse --show-toplevel >/dev/null 2>&1 \
  || die "not inside a git working copy - run this in the worktree of issue $number"

# The tracker call before anything moves. A refusal of it, a rate limit among them, says in plain words that
# nothing landed: a coordinator that read a bare error as "landed" released without the work.
thread=""
read_thread() {  # read_thread <number> <repository or empty>: sets thread
  thread="$(apart "$BIN/issue-thread.sh" ${2:+"$2"} "$1" --json)" \
    || die "nothing landed: the issue $1 could not be read from $(tracker_name), so nothing was merged or pushed and origin is as it was: $thread"
}

# WHOSE A BRANCH IS: a branch is named issue-<number>-..., and after a carry from GitHub a number is both a work item
# of the project and the GitHub number of another. The branch is the issue's where the tracker, asked for the number of
# its name at the time the branch was started, answers the issue given. A branch of another work item is named, not taken.
belongs_note() {  # belongs_note <branch>: after branch_work_item, the words that say whose the branch is
  if [ -n "$WORK_ITEM" ]; then printf 'it belongs to %s' "$(issue_ref "$issue_repo" "$WORK_ITEM")"
  else printf 'it %s' "${WORK_ITEM_REASON:-belongs to no work item}"; fi
}

# origin_issue_branch <number> [<repository>]: the branch of one issue as origin holds it, read from origin itself, for
# --from-origin and for every issue after the first of a list, which passes the repository of the first. Sets issue_repo
# (the repository passed, else the one named, else the one a local branch of the number records; nothing for the
# checkout's own), thread, origin_branch and origin_tip; stops the run where origin holds no branch of the issue, or more
# than one.
origin_issue_branch() {
  local n="$1" carried owners listed item why heads="" tip ref_name
  issue_repo="$repo"
  if [ "$#" -gt 1 ]; then
    issue_repo="$2"
  elif [ -z "$issue_repo" ]; then
    for listed in $(git for-each-ref --format='%(refname:short)' "refs/heads/issue-$n" "refs/heads/issue-$n-*"); do
      issue_repo="$(branch_issue_repo "$listed")"; [ -z "$issue_repo" ] || break
    done
  fi
  read_thread "$n" "$issue_repo"
  carried="$(carried_branch_number "$issue_repo" "$thread")"
  default="$(origin_default_branch)" || exit 1
  owners="$(issue_branch_owners "$issue_repo" "$default" "$(issue_branch_name "$n" "$(jq -r '.title // ""' <<< "$thread")")" "$n" ${carried:+"$carried"})" \
    || die "nothing landed: the work items of the branches of issue $n could not be told from $(tracker_name), so nothing was merged or pushed and origin is as it was"
  # Only stdout is read: a warning git writes on stderr is no ref
  run_split git ls-remote --heads origin "refs/heads/issue-$n" "refs/heads/issue-$n-*" ${carried:+"refs/heads/issue-$carried" "refs/heads/issue-$carried-*"} \
    || die "could not reach origin: $split_out$split_err"
  while IFS=$'\t' read -r tip ref_name; do
    case "$ref_name" in refs/heads/*) ;; *) continue ;; esac
    listed="${ref_name#refs/heads/}"
    item="$(awk -F'\t' -v b="$listed" '$1 == b { print $2; exit }' <<< "$owners")"
    why="$(awk -F'\t' -v b="$listed" '$1 == b { print $3; exit }' <<< "$owners")"
    if [ "$item" = "$n" ]; then heads="$heads$tip"$'\t'"$ref_name"$'\n'; continue; fi
    case "$listed" in
      "issue-$n"|"issue-$n-"*)
        WORK_ITEM="${item#-}"; WORK_ITEM_REASON="$why"
        echo "the branch $listed on origin is not taken: $(belongs_note "$listed")" ;;
    esac
  done <<< "$split_out"
  origin_branch="$(printf '%s' "$heads" | awk -F'\t' '{ sub("^refs/heads/", "", $2); print $2 }')"
  origin_tip="$(printf '%s' "$heads" | awk -F'\t' '{ print $1 }')"
  case "$origin_branch" in
    '')       die "origin has no branch issue-$n-* of $(issue_ref "$issue_repo" "$n") to integrate - push the reviewed branch, then run this again" ;;
    *$'\n'*)  die "origin has more than one branch for issue $n, and which one the reviewer read is not for this command to guess: $(printf '%s' "$origin_branch" | tr '\n' ' ')" ;;
  esac
}

# Every issue of the run, in the order given: its number, branch, thread, how its commits name it (ref) and the subject
# of its merge commit. The first comes from the worktree, or from origin with --from-origin; every other one from origin.
issue_numbers=(); issue_branches=(); issue_threads=(); issue_repos=(); issue_refs=(); issue_subjects=(); issue_origin_tips=()
if [ "${#numbers[@]}" -gt 1 ] || [ -n "$from_origin" ]; then
  # The branches are read from origin itself: a clone that never fetched one has no ref to list. They are fetched
  # first, because when a branch was started is read from its commits.
  said="$(git fetch origin 2>&1)" || die "could not reach origin: $said"
fi
if [ -z "$from_origin" ]; then
  branch="$(git symbolic-ref --short -q HEAD)" || branch=""
  issue_repo="${repo:-$(branch_issue_repo "$branch")}"
  whose=""; is_issue_branch=""
  if [ -n "$(name_issue_number "$branch")" ]; then
    branch_work_item "$issue_repo" "$branch" \
      || die "nothing landed: the work item of $branch could not be told from $(tracker_name), so nothing was merged or pushed and origin is as it was"
    is_issue_branch=1
    [ "$WORK_ITEM" = "$number" ] || whose=", and $(belongs_note "$branch")"
  fi
  [ -n "$is_issue_branch" ] && [ -z "$whose" ] \
    || die "this runs in the worktree of issue $number, on its branch issue-$number-*; here ${branch:-no branch} is checked out${whose} (--from-origin lands the branch as origin holds it, from any directory)"
  [ -z "$(git status --porcelain)" ] \
    || die "the worktree has changes - commit them for the review, or put them aside, then run this again"
  read_thread "$number" "${repo:-$(branch_issue_repo "$branch")}"
  first_repo_of_issue="${repo:-$(branch_issue_repo "$branch")}"
else
  origin_issue_branch "$number"
  branch="$origin_branch"; listed_tip="$origin_tip"; first_repo_of_issue="$issue_repo"
fi
issue_numbers+=("$number"); issue_branches+=("$branch"); issue_threads+=("$thread"); issue_repos+=("$first_repo_of_issue"); issue_origin_tips+=("${listed_tip:-}")
for number_after in ${numbers[@]+"${numbers[@]:1}"}; do
  origin_issue_branch "$number_after" "$first_repo_of_issue"
  issue_numbers+=("$number_after"); issue_branches+=("$origin_branch"); issue_threads+=("$thread"); issue_repos+=("$issue_repo"); issue_origin_tips+=("$origin_tip")
done
# The subject the gate takes is 72 characters at most, so a longer one falls back, shortest last
for position in "${!issue_numbers[@]}"; do
  n="${issue_numbers[position]}"
  title="$(printf '%s' "${issue_threads[position]}" | jq -r '.title // ""')"
  issue_refs[position]="$(issue_ref "${issue_repos[position]}" "$n")"
  subject="$title (${issue_refs[position]})"
  [ -n "$title" ] && [ "${#subject}" -le 72 ] || subject="Merge ${issue_branches[position]} (${issue_refs[position]})"
  [ "${#subject}" -le 72 ] || subject="Merge issue-$n (${issue_refs[position]})"
  issue_subjects[position]="$subject"
done
subject="${issue_subjects[0]}"
ref="${issue_refs[0]}"
thread="${issue_threads[0]}"

landing="$(git rev-parse --path-format=absolute --git-common-dir)/ai-core-landing"
# What a round owns goes first, on every way out and between two rounds: the branch ci/integrate-<issue branch>
# on origin, the temporary worktree and the file with the output of a push, the receipt, then the lock. The
# branch is deleted only while it still holds the merge commit of this round (a lease), so a branch somebody
# else wrote stays; a branch that is not there is nothing to delete. A branch that stays or cannot be deleted
# is named in one line and changes nothing about the outcome. A kill that cannot be trapped (SIGKILL) runs none
# of this and leaves the branch behind. The lock is removed only where this process wrote it.
tree=""; ci_branch=""; pushed=""; receipt=""
# remote_ref_sha <full ref>: the sha origin holds for the ref, nothing where it has none. Only stdout is read,
# so a warning git writes on stderr (a repository that was renamed, say) is no part of the sha; when git
# fails, its words are printed and the status is 1.
remote_ref_sha() {
  local rc=0
  GIT_TERMINAL_PROMPT=0 run_split git ls-remote origin "$1" || rc=$?
  if [ "$rc" -ne 0 ]; then printf '%s\n' "$split_out$split_err"; return 1; fi
  awk -v ref="$1" '$2 == ref { print $1 }' <<< "$split_out"
}
delete_ci_branch() {
  local said
  [ -n "$ci_branch" ] || return 0
  said="$(remote_ref_sha "refs/heads/$ci_branch")" \
    || { echo "$ci_branch could not be looked up on origin, so it was not deleted; delete it by hand if it stands: $(printf '%s' "$said" | tr -s '\r\n' '  ')" >&2; return 0; }
  [ -n "$said" ] || return 0
  said="$(git push origin "--force-with-lease=refs/heads/$ci_branch:$merged_sha" --delete "refs/heads/$ci_branch" 2>&1)" && return 0
  case "$said" in
    *"stale info"*|*"cannot lock ref"*) echo "$ci_branch on origin is not the merge commit ${merged_sha:0:7} of this landing, so it was left in place" >&2 ;;
    *) echo "$ci_branch could not be deleted on origin, delete it by hand: $(printf '%s' "$said" | tr -s '\r\n' '  ')" >&2 ;;
  esac
}
end_round() {
  delete_ci_branch; ci_branch=""
  [ -z "$tree" ] || git worktree remove --force "$tree" >/dev/null 2>&1 || rm -rf "$tree"
  tree=""
  [ -z "$pushed" ] || rm -f "$pushed"
  pushed=""
  [ -z "$receipt" ] || landing_check_close "$receipt"
  receipt=""
  [ "$(cut -f1 "$landing" 2>/dev/null)" != "$$" ] || rm -f "$landing"
}
trap end_round EXIT

# make_merge: the merge commit of every issue of the run into origin/<default>, one after the other in the order given,
# made in a temporary worktree beside the clone (tree), where scripts/install.sh of the merged tree runs if it has one, so
# the gate's check finds what it needs. It reads merge_tips and merge_names. Sets base_tip (the origin/<default> it was
# made on), merge_shas (each merge commit), merged_sha (the last one) and merged.
merge_tips=(); merge_names=(); merge_shas=()
make_merge() {
  local container position
  for position in "${!merge_tips[@]}"; do
    [ -n "$(git rev-list -n1 "${merge_tips[position]}" --not "origin/$default")" ] \
      || die "nothing to integrate: ${merge_names[position]} is in origin/$default already"
    { [ -z "$from_origin" ] && [ "${#merge_tips[@]}" -eq 1 ]; } || echo "merging: ${merge_names[position]} at $(git rev-parse --short "${merge_tips[position]}")"
  done
  container="$(worktree_container)" && mkdir -p "$container" \
    && tree="$(mktemp -d "$container/integrate-$number.XXXXXX")" || die "no folder for the temporary worktree beside the clone"
  git worktree add -q --detach "$tree" "origin/$default" || die "the temporary worktree could not be made on origin/$default (see above)"
  base_tip="$(git -C "$tree" rev-parse HEAD)"
  merge_shas=()
  for position in "${!merge_tips[@]}"; do
    # git merges a tip that the merges before it hold already into nothing, and says so with status 0
    [ "$position" -eq 0 ] || ! git -C "$tree" merge-base --is-ancestor "${merge_tips[position]}" HEAD \
      || die "nothing to integrate: ${merge_names[position]} holds nothing that the issues before it in the list do not, so it would land in no merge commit of its own; leave it out of the list"
    git -C "$tree" merge -q --no-ff --no-edit "${merge_tips[position]}" -m "${issue_subjects[position]}" -m "$trailers" \
      || die "${merge_names[position]} does not merge cleanly into origin/$default - bring origin/$default into the branch, get the review of the result, then run this again; nothing was pushed"
    merge_shas+=("$(git -C "$tree" rev-parse HEAD)")
  done
  merged_sha="${merge_shas[${#merge_shas[@]}-1]}"
  merged="$(git -C "$tree" rev-parse --short HEAD)"
  echo "round $round of $rounds_limit: the merge commit $merged_sha is made on origin/$default at $base_tip"
  if [ -f "$tree/scripts/install.sh" ]; then
    echo "installing: scripts/install.sh of the merged tree runs in $tree, so the gate's check finds what it needs"
    (cd "$tree" && bash scripts/install.sh) \
      || die "scripts/install.sh failed in the temporary worktree (see above) - nothing was pushed, origin is as it was, and the worktree of $branch is as it was"
  fi
}

# set_merge_tips_from_refs: merge_tips and merge_names from the refs as the fetch left them. The first issue is merged
# from its branch in the worktree unless --from-origin names origin's; every other one from origin's.
set_merge_tips_from_refs() {
  local position ref_name sha
  merge_tips=(); merge_names=()
  for position in "${!issue_numbers[@]}"; do
    if [ "$position" -eq 0 ] && [ -z "$from_origin" ]; then ref_name="${issue_branches[0]}"; else ref_name="origin/${issue_branches[position]}"; fi
    sha="$(git rev-parse -q --verify "$ref_name^{commit}")" || die "$ref_name is not there after the fetch - push the reviewed branch, then run this again"
    merge_tips+=("$sha"); merge_names+=("$ref_name")
  done
}

# THE REVIEWED TIPS: the commits the first round merges, one per issue in the order given. A later round finds the same
# commit on every branch or stops, so a landing that runs again never lands what the reviewer did not read.
reviewed_tips=()
keep_reviewed_tips() {  # keep_reviewed_tips <tip>...: what this round is about to merge
  local position
  if [ "${#reviewed_tips[@]}" -eq 0 ]; then reviewed_tips=("$@"); return 0; fi
  for position in "${!reviewed_tips[@]}"; do
    [ "$1" = "${reviewed_tips[position]}" ] \
      || die "nothing landed: ${issue_branches[position]} is at $1, but round 1 of this landing read ${reviewed_tips[position]}; the branch changed after the review, and no round merges another commit than the first one"
    shift
  done
}

# keep_waited_tips: once the lock is held and origin fetched, every reviewed tip is still the tip of its branch, else
# nothing lands. Nothing is waited for in a private repository or under CI_GATE none, so there it holds nothing.
waited_tips=()
keep_waited_tip() {  # keep_waited_tip <ref> <the tip waited for>
  local now when="while its checks were waited for"
  now="$(git rev-parse -q --verify "$1^{commit}")" || now="nothing"
  [ "$round" -le 1 ] || when="since round 1 of this landing read it"
  [ "$now" = "$2" ] \
    || die "nothing landed: $1 moved from $2 to $now $when; run this again"
}
keep_waited_tips() {
  local position
  [ "${#waited_tips[@]}" -gt 0 ] || return 0
  for position in "${!issue_numbers[@]}"; do
    keep_waited_tip "origin/${issue_branches[position]}" "${waited_tips[position]}"
    { [ -n "$from_origin" ] || [ "$position" -gt 0 ]; } || keep_waited_tip "${issue_branches[0]}" "${waited_tips[0]}"
  done
}

# gate_public_repository: a public repository lands only on the green checks of the commit that lands. It
# runs before the landing lock, so a slow CI holds up no other landing, and before anything reaches the
# default branch. The merge commit is made in a temporary worktree and pushed to ci/integrate-<issue
# branch>, which only a landing uses: a left-over of an earlier landing of the issue, or the branch of one that still runs, is replaced, but only if it is
# still what was read just before the push (a lease), so a branch written meanwhile is refused. Its checks are waited for; the push to the default branch after the lock sends exactly the
# merge commit. A private repository, and a public one of a project whose config.env sets CI_GATE to none,
# rests on its push gate: nothing is made or pushed here, and no CI is read. The reviewed tip is the one
# origin lists for --from-origin, else the local branch, which must be the tip origin holds too.
base_tip=""; merged_sha=""; merged=""
gate_public_repository() {
  local checked_repo visibility ci_gate tip poll limit checks=0 on_origin said held push_status position
  ci_gate="$(config_file_value CI_GATE public | tr '[:upper:]' '[:lower:]')"
  case "$ci_gate" in
    public|none) ;;
    *) die "nothing landed: CI_GATE is '$ci_gate' in the config.env of the project; it is public or none" ;;
  esac
  checked_repo="$(origin_repo)" || die "nothing landed: origin names no repository, so its visibility cannot be established"
  visibility="$(apart forge_repo_visibility "$checked_repo")" \
    || die "nothing landed: the visibility of $checked_repo cannot be established, so it is not known whether its checks must be green: $visibility"
  if [ "$visibility" = private ]; then
    echo "checks: $checked_repo is private, its push gate is its check; the CI of $(forge_name) is not read"
    return 0
  fi
  if [ "$ci_gate" = none ]; then
    echo "checks: $checked_repo is public and the CI_GATE of the project is none, its push gate is its check; the CI of $(forge_name) is not read"
    return 0
  fi
  waited_tips=()
  if [ "${#reviewed_tips[@]}" -gt 0 ]; then
    waited_tips=("${reviewed_tips[@]}")
  else
    for position in "${!issue_numbers[@]}"; do
      if [ "$position" -eq 0 ] && [ -z "$from_origin" ]; then
        tip="$(git rev-parse "$branch^{commit}")"
        on_origin="$(remote_ref_sha "refs/heads/$branch")" || die "could not reach origin: $on_origin"
        [ "$on_origin" = "$tip" ] \
          || die "nothing landed: $tip is not on origin, so it has no checks; push the branch, then run this again"
      else
        tip="${issue_origin_tips[position]}"
      fi
      waited_tips+=("$tip")
    done
    reviewed_tips=("${waited_tips[@]}")
  fi
  said="$(git fetch origin 2>&1)" || die "could not reach origin: $said"
  default="$(origin_default_branch)" || exit 1
  keep_waited_tips
  receipt="$(landing_check_open)" || die "no folder for the receipt of the checks of this landing"
  merge_tips=("${waited_tips[@]}"); merge_names=()
  for position in "${!issue_numbers[@]}"; do
    if [ "$position" -eq 0 ] && [ -z "$from_origin" ]; then merge_names+=("$branch"); else merge_names+=("origin/${issue_branches[position]}"); fi
  done
  make_merge
  ci_branch="ci/integrate-$branch"
  held="$(remote_ref_sha "refs/heads/$ci_branch")" || die "could not reach origin: $held"
  # The push gate runs inside this push and may wait for a lower load before its check: its words are
  # shown as they come, and kept only to tell a race from a refusal.
  pushed="$(mktemp)" || die "no temporary file for the output of the push to $ci_branch"
  push_status=0
  with_landing_mark "$tree" "$merged_sha" "refs/heads/$ci_branch" "refs/heads/$default" -- env AI_CORE_LANDING_RECEIPT="$receipt" git -C "$tree" push origin "--force-with-lease=refs/heads/$ci_branch:$held" "$merged_sha:refs/heads/$ci_branch" 2>&1 | tee "$pushed" >&2 || push_status="${PIPESTATUS[0]}"
  said="$(cat "$pushed")"; rm -f "$pushed"; pushed=""
  [ "$push_status" -eq 0 ] || case "$said" in
    *"stale info"*|*"cannot lock ref"*) die "nothing landed: $ci_branch on origin changed after it was read, so another landing of this branch may be running; nothing was pushed to it or to $default (git's words are above)" ;;
    *) die "nothing landed: the merge commit ${merged_sha:0:7} could not be pushed to $ci_branch for its checks, and nothing reached $default (the words of git and of the push gate are above)" ;;
  esac
  poll="${AI_CORE_INTEGRATE_POLL:-20}"; limit="${AI_CORE_INTEGRATE_WAIT:-1800}"
  wait_for_checks "$tree" "$merged_sha" "$poll" "$limit" \
    "waiting: $checked_repo is public and lands only on green checks; the checks of ${merged_sha:0:7} on $ci_branch are asked every ${poll}s, $((limit / 60)) minute(s) at most" || checks=$?
  case "$checks" in
    0) echo "checks: green for ${merged_sha:0:7} on $ci_branch at $(forge_name); $checked_repo is public and lands only on green checks"
       # Both the push and the CI went through: from here the final push may rest on the check the gate ran for it
       landing_check_complete "$receipt" "$merged_sha" "refs/heads/$ci_branch" \
         || echo "note: the receipt of ${merged_sha:0:7} could not be completed, so the push to $default runs scripts/check.sh again" ;;
    1) die "nothing landed: the checks for $merged_sha on $ci_branch are red, so nothing was pushed to $default and origin/$default is as it was" ;;
    2) die "nothing landed: the checks for $merged_sha on $ci_branch did not finish in $((limit / 60)) minute(s), so nothing was pushed to $default. A new run makes a new merge commit and waits for a new CI run; set AI_CORE_INTEGRATE_WAIT (seconds, $limit now) higher if the CI takes longer" ;;
    *) die "nothing landed: $(checks_unreadable_message "$merged_sha" "$checks_said")" ;;
  esac
}

# take_landing_lock: the file ai-core-landing is this process's. A known limit: two waiters that find the same dead holder
# can both take over, and the push then still refuses the second, as it does without the lock; a holder's process id that
# an unrelated process took over keeps the lock held, and the waiting line names that process
take_landing_lock() {
  local waited="" missing=0 nameless=0 holder pid dead said
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
}

# back_to_branch <reason>: the worktree goes back to the branch it was on, and the run stops
back_to_branch() {
  git switch -q "$branch" 2>/dev/null || echo "error: the branch $branch could not be checked out again - run git switch $branch" >&2
  die "$1"
}

# base_has_moved <what happened meanwhile> [<how to stop>]: whether origin/<default> is no longer the tip the merge of this
# round was made on, asked of origin right before the push, so that a gate is not started on a base that is gone. Names the
# move in round_cause where it is. The gate refuses a push over a tip it does not hold, whatever the cause, and a refusal is
# no proof. An origin that cannot be read stops the run through <how to stop>: back_to_branch where the merge was made in
# the worktree of the issue, die (the default) where it was made beside it.
base_has_moved() {
  local now said stop="${2:-die}"
  said="$(git fetch origin 2>&1)" || "$stop" "could not reach origin: $said"
  now="$(git rev-parse "origin/$default^{commit}")" || "$stop" "origin/$default is not there after the fetch"
  [ "$now" != "$base_tip" ] || return 1
  round_cause="origin/$default moved from $base_tip to $now $1"
}

# back_to_branch_after_move: the worktree goes back to the branch it was on, so that the next round starts from it
back_to_branch_after_move() {
  git switch -q "$branch" || die "the branch $branch could not be checked out again after $default moved - run git switch $branch, then run this again"
}

# push_default <mark root> <commit> <what to say when nothing moved> -- <the git push>: the push of a round to the default
# branch, its lines kept as it ran. The outcome, in push_outcome and, where the push was refused, in refusal or round_cause:
#   landed   the commit is on origin, also where git reported a failure after origin took it
#   moved    origin refused the update because the default branch moved: round_cause names the tips
#   refused  anything else, which keeps the cause it had
# A move is proven by two things together: git's own porcelain line, which names a ref that origin refused to update
# because it holds another tip, and the tip origin holds now. Either alone proves nothing: the tip of origin differs
# after a red gate whenever the default branch moved while the gate ran, and the words of a gate may look like git's.
# A move before the push starts is found by base_has_moved, so that no gate runs on a base that is gone.
push_outcome=""; refusal=""; round_cause=""
push_default() {
  local root="$1" commit="$2" nothing_moved="$3" status=0 said now
  shift 4
  pushed="$(mktemp)" || die "no temporary file for the output of the push to $default"
  with_landing_mark "$root" "$commit" "refs/heads/$default" -- "$@" | tee "$pushed" >&2 || status="${PIPESTATUS[0]}"
  said="$(cat "$pushed")"; rm -f "$pushed"; pushed=""
  if [ "$status" -eq 0 ]; then push_outcome=landed; return 0; fi
  if ! now="$(remote_ref_sha "refs/heads/$default")"; then
    refusal="$nothing_moved (origin could not be read afterwards to tell whether $default moved: $(printf '%s' "$now" | tr -s '\r\n' '  '))"
    push_outcome=refused; return 0
  fi
  # Also a tip above the commit: a push that reached origin may have been followed by another landing before it was read
  if [ "$now" = "$commit" ] || { git fetch -q origin 2>/dev/null && git merge-base --is-ancestor "$commit" "$now" 2>/dev/null; }; then
    echo "origin holds ${commit:0:7} on $default although git reported a failure: the landing went through" >&2
    push_outcome=landed; return 0
  fi
  if [ -n "$now" ] && [ "$now" != "$base_tip" ] && grep -Eq $'^!\t[^\t]+\t\\[(rejected\\] \\((fetch first|non-fast-forward)\\)|remote rejected\\] \\((incorrect old value provided|failed to update ref|cannot lock ref))' <<< "$said"; then
    round_cause="$default moved on origin from $base_tip to $now after this landing fetched it, so another landing got there first and origin refused the push of $commit, and it was not overwritten"
    push_outcome=moved; return 0
  fi
  refusal="$nothing_moved"
  push_outcome=refused
}

# land_round: one round, from the checks of a public repository to the push to the default branch. It makes the merge
# commit on the newest origin/<default>, which the gate judges, and pushes exactly that. It leaves round_cause empty
# where the commit is on origin, and names the move of the default branch in it where that made the round stop. Any
# other refusal ends the run here. It never ends in a status other than 0, so that errexit holds inside it.
land_round() {
  local now said
  round_cause=""
  gate_public_repository
  take_landing_lock
  said="$(git fetch origin 2>&1)" || die "could not reach origin: $said"
  default="$(origin_default_branch)" || exit 1
  if [ "${#waited_tips[@]}" -gt 0 ]; then
    # The public repository: the merge commit made and checked before the lock lands as it is, if nothing moved
    now="$(git rev-parse "origin/$default^{commit}")" || die "origin/$default is not there after the fetch"
    if [ "$now" != "$base_tip" ]; then
      round_cause="origin/$default moved from $base_tip to $now while the checks of $merged_sha ran"
      return 0
    fi
    keep_waited_tips
    push_default "$tree" "$merged_sha" "the push was refused (see above) - nothing reached origin, and the worktree of $branch is as it was" -- env AI_CORE_LANDING_RECEIPT="$receipt" git -C "$tree" push --porcelain origin "$merged_sha:refs/heads/$default"
    case "$push_outcome" in moved) return 0 ;; refused) die "$refusal" ;; esac
  elif [ -n "$from_origin" ] || [ "${#numbers[@]}" -gt 1 ]; then
    set_merge_tips_from_refs
    keep_reviewed_tips "${merge_tips[@]}"
    make_merge
    if base_has_moved "while the merge was made"; then return 0; fi
    push_default "$tree" "$merged_sha" "the push was refused (see above) - nothing reached origin, and the worktree of $branch is as it was" -- git -C "$tree" push --porcelain origin "HEAD:$default"
    case "$push_outcome" in moved) return 0 ;; refused) die "$refusal" ;; esac
  else
    [ -n "$(git rev-list -n1 "$branch" --not "origin/$default")" ] \
      || die "nothing to integrate: $branch is in origin/$default already"
    keep_reviewed_tips "$(git rev-parse "$branch^{commit}")"
    base_tip="$(git rev-parse "origin/$default^{commit}")" || die "origin/$default is not there after the fetch"
    git switch -q --detach "origin/$default" || die "the worktree could not be put on origin/$default (see above)"
    if ! git merge -q --no-ff --no-edit "$branch" -m "$subject" -m "$trailers"; then
      git merge --abort 2>/dev/null
      back_to_branch "$branch does not merge cleanly into origin/$default - bring origin/$default into the branch, get the review of the result, then run this again"
    fi
    merged_sha="$(git rev-parse HEAD)"; merged="$(git rev-parse --short HEAD)"; merge_shas=("$merged_sha")
    echo "round $round of $rounds_limit: the merge commit $merged_sha is made on origin/$default at $base_tip"
    if base_has_moved "while the merge was made" back_to_branch; then back_to_branch_after_move; return 0; fi
    push_default . "$merged_sha" "the push was refused (see above) - nothing reached origin, and $branch is checked out again" -- git push --porcelain origin "HEAD:$default"
    case "$push_outcome" in
      moved) back_to_branch_after_move; return 0 ;;
      refused) back_to_branch "$refusal" ;;
    esac
    git switch -q "$branch" || die "$merged is on origin/$default, but $branch could not be checked out again - run git switch $branch before finish-issue"
  fi
}

# THE ROUNDS: the default branch moving while a round's gate ran ends that round with nothing pushed to the default
# branch, and the next round fetches it again, merges onto its new tip and runs the whole gate on that merge, at most
# INTEGRATE_MAX_ROUNDS rounds, which is read again before every round. A conflict, a red gate or CI, a branch that changed,
# an unreadable origin and every other refusal end the run at once.
round=0; rounds_limit=0
while :; do
  round=$((round + 1))
  # The number is read from standard output alone: a warning on standard error is shown and is no part of it
  rounds_limit="$(apart landing_rounds_limit)" || die "nothing landed, and no round $round was started: $rounds_limit"
  if [ "$round" -gt "$rounds_limit" ]; then
    die "nothing landed: $round_cause; round $((round - 1)) was the last that INTEGRATE_MAX_ROUNDS ($rounds_limit) allows, and nothing was pushed to $default. A public repository pushes the merge commit of each round to ci/integrate-$branch for its checks and deletes it from there again; one that stays is named above. Run this again, which merges onto the new $default"
  fi
  [ "$round" -eq 1 ] || echo "round $round of $rounds_limit: the round before ended because $round_cause; this round fetches origin again, merges onto the new $default and runs the whole gate on that merge"
  land_round
  [ -n "$round_cause" ] || break
  end_round
done
checkout="$(cd "$(dirname "$landing")/.." && pwd)"
if ! fast_forward_default_branch "$checkout"; then
  echo "integration succeeded: $merged is on origin/$default; the refresh of checkout $checkout did not finish (see above)" >&2
fi
integrated_subject="$subject"
for position in "${!issue_subjects[@]}"; do [ "$position" -eq 0 ] || integrated_subject="$integrated_subject; ${issue_subjects[position]}"; done
echo "integrated: $merged on origin/$default, $integrated_subject$(printf ', Reviewed-by: %s' "${reviewers[@]}")"
# Every issue the merged commits name in parentheses, the integrated one first: a package lands
# several issues in one merge, and the card of each moves on only through its own finish-issue. Only
# the forms '(#N)' and '(owner/repo#N)' count: a number named in passing is no landing. The number a commit
# names is read by the tracker at the time of that commit: after a carry from GitHub, a commit made before the
# work item existed names the GitHub issue the work item was carried from, and its line gives the work item.
own_repo="$(default_repo 2>/dev/null)" || own_repo=""
own="$(printf '%s' "$own_repo" | tr 'A-Z' 'a-z')"
{ for position in "${!issue_numbers[@]}"; do
    first_repo="${issue_refs[position]%#*}"
    echo "next: ai-core finish-issue ${first_repo:+$first_repo }${issue_numbers[position]}"
  done
  for merge_sha in "${merge_shas[@]}"; do git log --reverse --format='%ct %s' "$merge_sha^1..$merge_sha^2"; done | while IFS= read -r line; do
    { grep -oE '\(([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)?#[0-9]+\)' <<< "${line#* }" || true; } | tr -d '()' | while IFS= read -r named; do
      landed_repo="${named%#*}"
      [ "$(printf '%s' "$landed_repo" | tr 'A-Z' 'a-z')" != "$own" ] || landed_repo=""
      if reference_answer "${landed_repo:-$own_repo}" "${named##*#}" "${line%% *}"; then
        if [ -n "$WORK_ITEM" ]; then echo "next: ai-core finish-issue ${landed_repo:+$landed_repo }$WORK_ITEM"
        else echo "note: the commit ($named) ${WORK_ITEM_REASON:-names no work item}, so no finish-issue follows for it"; fi
      else
        echo "next: ai-core finish-issue ${landed_repo:+$landed_repo }${named##*#}   (the work item it names could not be read, see above)"
      fi
    done
  done; } | awk '!seen[tolower($0)]++'
