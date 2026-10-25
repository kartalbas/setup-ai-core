#!/usr/bin/env bash
# Close the worktree of one issue once its work has landed, move its card one column on, and say
# in the issue what landed.
#
#   finish-issue.sh [OWNER/REPO] NUMBER [--landed]
#   finish-issue.sh --sweep [--dry-run]
#
# The counterpart of start-issue. A worktree left behind after its work landed holds a copy of
# the repository and its build output, gigabytes on a machine with several sessions, and a card
# left in implementing tells everyone the work is still going on. Run it from the checkout or from
# any worktree of the repository, after the push that lands the work. The issue, its card and its
# comment are in OWNER/REPO where it is given, else in the repository start-issue recorded on the
# issue's branch, else in the checkout's own.
#
# NOTHING THAT HAS NOT LANDED IS REMOVED. A worktree with changes, or with a commit origin's
# default branch does not have, stops the run and is named; the work in it is somebody's.
#
# THE CARD MOVES TO testing, whatever column it stands in: the work has landed and waits for its
# release and its proof. status-sync, which this runs for the repository, closes it once a release
# carries its work and a proof record follows its landing. On a board without a testing column the
# card stays. An issue no commit on origin's default branch names has not landed: the run stops
# before the card moves.
#
# A WORKTREE THAT WAS NEVER COMMITTED IN holds no work: it goes with its branch, and where no commit on
# origin's default branch names the issue either, this repository holds no work of it. The run says
# so, leaves the card and the issue alone, and ends well. A branch that was committed in is
# different: with no commit naming the issue it is the fault of the commits, and the run refuses.
#
# THE ISSUE'S BRANCH ON origin GOES once the change of every commit of it is on the default branch,
# merged, cherry-picked or rebased; one with more work, a commit reshaped on landing, or one a
# worktree has checked out, stays and is named. With --landed on a closed issue a branch with more
# work goes too, and the commits whose change the default branch lacks are printed; each branch is
# deleted at the tip that was measured, so a commit pushed meanwhile keeps it. A closed issue
# whose commits on the default branch do not name it has its branches cleared the same way, and
# the run says that the card and the issue were not updated; where it met no worktree and no
# branch of the issue, it says that it removed nothing.
#
# AFTER A CARRY FROM GITHUB a branch named issue-<GitHub number>-... of a work item that has a Plane number is still
# the work item's. The branches of the issue are those named by the number given and by the number it was carried
# from, kept where the tracker, asked for the number of the name at the time the branch was started, answers this
# issue; all are measured before one is removed, and a branch of another work item stays and is named with it.
#
# --sweep removes every worktree of this repository whose work has landed and has rested for a
# day, and names the others it leaves; start-issue and init --all run it, so a worktree nobody
# finished does not stay for good. A worktree that was never committed in is left alone.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/board.sh"

BIN="$ROOT/bin"
usage='usage: finish-issue.sh [OWNER/REPO] NUMBER [--landed] | finish-issue.sh --sweep [--dry-run]'
# A landed worktree younger than this is left to the session that may still be working in it
REST_SECONDS=$((24 * 3600))

sweep=0; dry=0; landed_flag=0; repo=""; number=""
for arg in "$@"; do
  case "$arg" in
    --sweep)   sweep=1 ;;
    --dry-run) dry=1 ;;
    --landed)  landed_flag=1 ;;
    -*)        die "unknown argument '$arg' - $usage" ;;
    */*)       [ -z "$repo" ] || die "$usage"; repo="$arg" ;;
    *)         [ -z "$number" ] || die "$usage"; number="$arg" ;;
  esac
done
if [ "$sweep" -eq 1 ]; then [ -z "$number" ] && [ -z "$repo" ] && [ "$landed_flag" -eq 0 ] || die "$usage"
else
  case "$number" in ''|*[!0-9]*) die "the issue number must be numeric, not '$number' - $usage" ;; esac
  [ "$dry" -eq 0 ] || die "--dry-run goes with --sweep - $usage"
fi

git rev-parse --show-toplevel >/dev/null 2>&1 \
  || die 'not inside a git working copy - run this from the repository the work belongs to'

said="$(git fetch origin 2>&1)" \
  || die "could not reach origin: $said - what has landed is measured against what origin has right now"
default="$(origin_default_branch)" || exit 1

# The main checkout, as start-issue finds it: the worktrees are removed from there, so this answers
# the same from inside the worktree being removed.
common="$(git rev-parse --git-common-dir)"
main="$(cd "$common/.." && git rev-parse --show-toplevel)"
# The run goes on from the main checkout: started inside the worktree it removes, every step after
# the removal would run in a directory that is gone
cd "$main" || die "cannot change to the main checkout $main"

# unlanded <ref>: the commits of the ref whose change is not on origin's default branch, one
# "<sha> <subject>" per line. A branch that landed by cherry-pick or rebase has new commits upstream,
# so ancestry alone would hold it back; git cherry compares the changes. git cherry passes over a
# merge commit, whose own content (a resolved conflict) it never measures, so every merge the
# default branch lacks counts as unlanded. A git command that fails makes the whole measurement fail:
# status 1 and git's words, which no flag waives, so a branch it cannot read never counts as landed.
unlanded() {
  local out
  out="$(git -C "$main" cherry -v "origin/$default" "$1" 2>&1)" || { printf '%s\n' "$out"; return 1; }
  sed -n 's/^+ //p' <<< "$out"
  out="$(git -C "$main" log --merges --format='%h %s' "origin/$default..$1" 2>&1)" || { printf '%s\n' "$out"; return 1; }
  [ -z "$out" ] || printf '%s\n' "$out"
}
# branch_history <branch>: what the reflog says happened to the branch. It is read whole before anything
# looks into it: piped into grep -q, grep stops at the first hit, git can die of the closed pipe, and
# under pipefail the answer then turned into "never committed in" on a busy machine
branch_history() { git -C "$main" reflog show --format=%gs "refs/heads/$1" 2>/dev/null || true; }
# worked_in <branch>: the branch was committed on, not only cut
worked_in() { grep -qv '^branch: Created' <<< "$(branch_history "$1")"; }
# cut_only <branch>: the reflog holds the cutting of the branch and nothing else; an empty reflog says
# nothing, so it never counts
cut_only() {
  local log
  log="$(branch_history "$1")"
  [ -n "$log" ] && ! grep -qv '^branch: Created' <<< "$log"
}

remove_worktree() {  # remove_worktree <path> <branch>
  git -C "$main" worktree remove "$1" || die "the worktree $1 could not be removed (see above)"
  git -C "$main" branch -D "$2" >/dev/null || die "the branch $2 could not be deleted (see above)"
}

# own_worktree <path> <branch>: the worktree carries the name of the issue its branch belongs to, as
# start-issue names it. A package is worked in the worktree of its first issue with each issue's
# branch checked out in turn, and that worktree is not the later issues' to remove.
own_worktree() {
  local n="${2#issue-}"; n="${n%%-*}"
  case "${1##*/}" in "issue-$n"|"issue-$n-"*) return 0 ;; *) return 1 ;; esac
}

# One "<path>\t<branch>" per worktree that carries an issue branch
issue_worktrees() {
  git -C "$main" worktree list --porcelain | awk '
    /^worktree / { path = substr($0, 10) }
    /^branch refs\/heads\/issue-[0-9]+(-|$)/ { print path "\t" substr($0, 19) }'
}

if [ "$sweep" -eq 1 ]; then
  now="$(date +%s)"
  while IFS=$'\t' read -r path branch; do
    [ -n "$path" ] || continue
    if ! own_worktree "$path" "$branch"; then echo "worktree $path: named for another issue, holds $branch, stays"
    elif [ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ]; then echo "worktree $path: has changes, stays"
    elif ! missing="$(unlanded "refs/heads/$branch")"; then
      # git's words on one line, their colons spelled as dashes: the line of a kept worktree is read back as "<path>: <reason>, stays"
      echo "worktree $path: could not be measured against origin/$default - $(tr -s '\n' ' ' <<< "$missing" | sed 's/: / - /g; s/ *$//'), stays"
    elif [ -n "$missing" ]; then echo "worktree $path: has work origin/$default does not have yet, stays"
    elif ! worked_in "$branch"; then echo "worktree $path: never committed in, stays"
    elif [ $((now - $(git -C "$main" log -1 --format=%ct "refs/heads/$branch"))) -lt "$REST_SECONDS" ]; then
      echo "worktree $path: landed less than a day ago, stays; finish-issue removes it at once"
    elif [ "$dry" -eq 1 ]; then echo "worktree $path: landed, would be removed"
    else remove_worktree "$path" "$branch"; echo "worktree $path: landed, removed"; fi
  done <<< "$(issue_worktrees)"
  exit 0
fi

# --- one issue ---------------------------------------------------------------------------------
# The record is read from the issue's branch, which can outlive its worktree
if [ -z "$repo" ]; then
  for branch in $(git for-each-ref --format='%(refname:short)' "refs/heads/issue-$number" "refs/heads/issue-$number-*"); do
    repo="$(branch_issue_repo "$branch")"; [ -z "$repo" ] || break
  done
fi
ref="$(issue_ref "$repo" "$number")"
thread="$(apart "$BIN/issue-thread.sh" ${repo:+"$repo"} "$number" --json)" || die "the issue could not be read: $thread"
state="$(printf '%s' "$thread" | jq -r '.state // ""' | tr '[:upper:]' '[:lower:]')"
[ "$landed_flag" -eq 0 ] || [ "$state" = closed ] \
  || die "--landed removes the work of a closed issue only, and $ref is open - close it once its work is on origin/$default"
own="$(default_repo 2>/dev/null)"
issue_repo="${repo:-$own}"

# THE BRANCHES OF THE ISSUE, all measured before anything is removed: removing a worktree deletes its local branch
# and the reflog that says when the branch was started, and origin's branches are read after that. A branch is
# named issue-<number>-..., and after a carry from GitHub a number is both a work item of the project and the
# GitHub number of another. The candidates are the branches named by the number given and by the number the issue
# was carried from; one is the issue's where the tracker, asked for the number of its name at the time the branch
# was started, answers this issue. Any other branch of those names is left alone and named with the work item it
# belongs to.
carried_number="$(carried_branch_number "$issue_repo" "$thread")"
owners="$(issue_branch_owners "$issue_repo" "$default" "$number" ${carried_number:+"$carried_number"})" || exit 1
mine=" "
while IFS=$'\t' read -r name item why; do
  [ -n "$name" ] || continue
  if [ "$item" = "$number" ]; then mine="$mine$name "
  elif [ "$item" != - ]; then echo "the branch $name belongs to $(issue_ref "$issue_repo" "$item"), not to $ref: it stays, and its worktree with it"
  else echo "the branch $name stays: it ${why:-belongs to no work item}"; fi
done <<< "$owners"
found=0; met=0; cut_only_removed=0; worked_in_removed=0
while IFS=$'\t' read -r path branch; do
  [ -n "$path" ] || continue
  case "$mine" in *" $branch "*) ;; *) continue ;; esac
  if ! own_worktree "$path" "$branch"; then
    echo "the worktree $path is named for another issue and has $branch checked out: it stays, and the branch with it"
    met=$((met + 1))
    continue
  fi
  found=1; met=$((met + 1))
  [ -z "$(git -C "$path" status --porcelain)" ] \
    || die "the worktree $path has changes - commit and push them, or put them aside, then run this again"
  missing="$(unlanded "refs/heads/$branch")" || die "the history of $branch could not be read, so nothing is removed: $missing"
  if [ -n "$missing" ]; then
    # Work that landed in another shape, a resolved conflict or a changed context, is the owner's
    # word against git's: --landed takes it, and only for an issue somebody closed.
    [ "$landed_flag" -eq 1 ] \
      || die "the worktree $path has $(grep -c . <<< "$missing") commit(s) whose change is not on origin/$default - push them, then run this again; where they landed in another shape, run finish-issue $number --landed once the issue is closed"
    echo "removed with --landed, these commits not found on origin/$default by their change:"
    sed 's/^/  /' <<< "$missing"
  fi
  if cut_only "$branch"; then
    cut_only_removed=$((cut_only_removed + 1)); because="it was never committed in"
  else
    worked_in_removed=$((worked_in_removed + 1)); because="its work is on origin/$default"
  fi
  remove_worktree "$path" "$branch"
  echo "Worktree $path and its branch $branch removed: $because. Open $main to go on."
done <<< "$(issue_worktrees)"
[ "$found" -eq 1 ] || echo "no worktree of issue $number stands here"

# clear_origin_branches: the issue's branches on origin. One whose every commit's change is on origin's
# default branch holds nothing the default branch lacks, so it is deleted; a repository that lands by
# rebase never makes the branch an ancestor. A commit reshaped on landing is no identical change, so its
# branch stays, unless --landed says the closed issue's work landed in another shape. A branch is
# measured and deleted at one tip, taken once, so a fetch or a push meanwhile never changes what the
# lease protects; the worktrees are listed again before each branch. The check for a worktree is a
# measurement, not a lock: a worktree made after it is not seen.
clear_origin_branches() {
  local branch tip held missing now
  for branch in $(git -C "$main" for-each-ref --format='%(refname:strip=3)' "refs/remotes/origin/issue-$number" "refs/remotes/origin/issue-$number-*" ${carried_number:+"refs/remotes/origin/issue-$carried_number" "refs/remotes/origin/issue-$carried_number-*"}); do
    case "$mine" in *" $branch "*) ;; *) continue ;; esac
    met=$((met + 1))
    tip="$(git -C "$main" rev-parse "refs/remotes/origin/$branch")" || { echo "the branch $branch on origin stays: its tip could not be read"; continue; }
    held="$(git -C "$main" worktree list --porcelain | sed -n 's#^branch refs/heads/##p')"
    if grep -qxF "$branch" <<< "$held"; then
      echo "the branch $branch on origin stays: a worktree has it checked out"
      continue
    fi
    missing="$(unlanded "$tip")" || { echo "the branch $branch on origin stays: its history could not be read: $missing"; continue; }
    if [ -n "$missing" ] && [ "$landed_flag" -eq 0 ]; then
      echo "the branch $branch on origin stays: it has commits whose change is not on origin/$default; where the issue is closed and they landed in another shape, run finish-issue $number --landed"
      continue
    fi
    if [ -n "$missing" ]; then
      echo "the branch $branch on origin has these commits, whose change is not on origin/$default; --landed deletes it:"
      sed 's/^/  /' <<< "$missing"
    fi
    if git -C "$main" push -q origin --force-with-lease="refs/heads/$branch:$tip" --delete "$branch"; then
      if [ -n "$missing" ]; then echo "the branch $branch on origin deleted with --landed"
      else echo "the branch $branch on origin deleted: the change of every commit of it is on origin/$default"; fi
    elif ! now="$(git -C "$main" ls-remote --heads origin "refs/heads/$branch" 2>&1)"; then
      echo "the branch $branch on origin could not be deleted, and origin could not be read to say why: $now"
    elif [ -z "$now" ]; then
      echo "the branch $branch on origin is already gone: it was deleted since it was measured"
    elif [ "${now%%$'\t'*}" != "$tip" ]; then
      echo "the branch $branch on origin stays: its tip moved from $tip to ${now%%$'\t'*} since it was measured"
    else
      echo "the branch $branch on origin could not be deleted and stays (see above)"
    fi
  done
}

# What landed. An issue no commit on origin names has not landed, whatever its worktree held: the
# card does not move and the issue is not told.
commits="$(issue_commits "$main" "origin/$default" "${repo:-$own}" "$number" "$own" "$(jq -r '.createdAt // ""' <<< "$thread")" "$(jq -r '.carriedFrom // ""' <<< "$thread")" '- %h %s' 20)"
if [ -z "$commits" ]; then
  if [ "$landed_flag" -eq 1 ]; then
    clear_origin_branches
    if [ "$met" -eq 0 ]; then
      echo "No commit on origin/$default names $ref, so the card stays and the issue is not told; --landed found no worktree of it in this clone and no branch of it on origin, so it removed nothing."
    else
      echo "No commit on origin/$default names $ref, so the card stays and the issue is not told; --landed went through what the closed issue left in this clone and on origin, and the lines above say what it removed and what stays."
    fi
    exit 0
  fi
  [ "$cut_only_removed" -gt 0 ] && [ "$worked_in_removed" -eq 0 ] \
    || die "no commit on origin/$default names $ref, so the card stays and the issue is not told; a commit that touches an issue names it"
  echo "${own:-this repository} holds no work of $ref: its worktree was never committed in and no commit on origin/$default names it. The card and the issue stay as they are."
  exit 0
fi

clear_origin_branches

# The card: to testing
if [ "$state" = closed ]; then
  echo "the issue is closed already - its card stays where closing put it"
elif repo="$(resolve_repo "$repo")" && on_no_board "$repo"; then
  echo "$repo is on no board - there is no card to move"
else
  set_project "" "$repo" >/dev/null
  all="$(fields_tsv)" || exit 1
  next="$(awk -F'\t' 'tolower($1)=="status" && tolower($3)=="testing" { print $3; exit }' <<< "$all")"
  if [ -z "$next" ]; then
    all="$(fields_fresh)" || exit 1
    next="$(awk -F'\t' 'tolower($1)=="status" && tolower($3)=="testing" { print $3; exit }' <<< "$all")"
  fi
  if [ -z "$next" ]; then
    echo "the board has no testing column - the card stays; move it by hand"
  elif moved="$("$BIN/issue-status.sh" ${repo:+"$repo"} "$number" "$next" 2>&1)"; then
    printf '%s\n' "$moved"
  else
    echo "the card did NOT move: $moved - move it to $next by hand" >&2
  fi
fi

# What landed, in the issue, for whoever reads it next; once: an issue that holds a record listing these
# commits is not told again. An issue of another repository is told which repository the commits are in.
# A comment that cannot be read leaves open whether the record is there, so then nothing is written.
landed_on="$default"; [ "$ref" = "#$number" ] || landed_on="$default of $(default_repo)"
issue_repo="${repo:-$own}"
if ! context="$(issue_landing_context "$issue_repo" "$number")"; then
  echo "the issue was NOT told what landed: its comments could not be read, so a record it holds is not known - add the commits by hand" >&2
else
  recorded=0; landing_recorded "$state" "$context" "$own" "$issue_repo" "$commits" || recorded=$?
  case "$recorded" in
    0) echo "the issue holds this record already - nothing added" ;;
    1) body="$(printf 'Landed on %s:\n\n%s\n' "$landed_on" "$commits")"
       "$BIN/issue-comment.sh" ${repo:+"$repo"} "$number" "$body" >/dev/null \
         && echo "the issue says what landed" \
         || echo "the issue was NOT told what landed - add the commits by hand" >&2 ;;
    *) echo "the issue was NOT told what landed: its comments could not be compared with the commits - add the commits by hand" >&2 ;;
  esac
fi

# The cards of this repository and of the issue's whose work a release carries and a proof covers close (status-sync)
released_repo="$(resolve_repo "")" && sync_released_cards "$released_repo" ${repo:+"$repo"}
