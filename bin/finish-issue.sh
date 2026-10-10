#!/usr/bin/env bash
# Close the worktree of one issue once its work has landed, move its card one column on, and say
# in the issue what landed.
#
#   finish-issue.sh [OWNER/REPO] NUMBER
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
# THE CARD MOVES TO THE COLUMN AFTER implementing, read from the board's own order: on a board
# with a testing column the card goes there; status-sync, which this runs for the repository,
# closes it once a release carries its work and a proof record follows its landing. Where the next
# column is done, the card stays, because done is what closing the issue sets. An issue no commit
# on origin's default branch names has not landed: the run stops before the card moves.
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

# unlanded <branch>: the commits of the branch whose change is not on origin's default branch, one
# "<sha> <subject>" per line. A branch that landed by cherry-pick has new commits upstream, so
# ancestry alone would hold it back; git cherry compares the changes. A git cherry that fails
# answers a line of its own, so a branch it cannot read never counts as landed.
unlanded() {
  local out
  out="$(git -C "$main" cherry -v "origin/$default" "refs/heads/$1" 2>&1)" || { echo "? $out"; return 0; }
  sed -n 's/^+ //p' <<< "$out"
}
landed() { [ -z "$(unlanded "$1")" ]; }
# worked_in <branch>: the branch was committed on, not only cut. The reflog is read whole first: piped
# into grep -q, grep stops at the first hit, git can die of the closed pipe, and under pipefail the
# answer then turned into "never committed in" on a busy machine
worked_in() {
  local log
  log="$(git -C "$main" reflog show --format=%gs "refs/heads/$1" 2>/dev/null || true)"
  grep -qv '^branch: Created' <<< "$log"
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
    elif ! landed "$branch"; then echo "worktree $path: has work origin/$default does not have yet, stays"
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
thread="$("$BIN/issue-thread.sh" ${repo:+"$repo"} "$number" --json 2>&1)" || die "the issue could not be read: $thread"
state="$(printf '%s' "$thread" | jq -r '.state // ""' | tr '[:upper:]' '[:lower:]')"
found=0
while IFS=$'\t' read -r path branch; do
  [ -n "$path" ] || continue
  case "$branch" in "issue-$number"|"issue-$number-"*) ;; *) continue ;; esac
  if ! own_worktree "$path" "$branch"; then
    echo "the worktree $path is named for another issue and has $branch checked out: it stays, and the branch with it"
    continue
  fi
  found=1
  [ -z "$(git -C "$path" status --porcelain)" ] \
    || die "the worktree $path has changes - commit and push them, or put them aside, then run this again"
  missing="$(unlanded "$branch")"
  if [ -n "$missing" ]; then
    # Work that landed in another shape, a resolved conflict or a changed context, is the owner's
    # word against git's: --landed takes it, and only for an issue somebody closed.
    [ "$landed_flag" -eq 1 ] \
      || die "the worktree $path has $(grep -c . <<< "$missing") commit(s) whose change is not on origin/$default - push them, then run this again; where they landed in another shape, run finish-issue $number --landed once the issue is closed"
    [ "$state" = closed ] \
      || die "--landed removes the work of a closed issue only, and $ref is open - close it once its work is on origin/$default"
    echo "removed with --landed, these commits not found on origin/$default by their change:"
    sed 's/^/  /' <<< "$missing"
  fi
  remove_worktree "$path" "$branch"
  echo "Worktree $path and its branch $branch removed: its work is on origin/$default. Open $main to go on."
done <<< "$(issue_worktrees)"
[ "$found" -eq 1 ] || echo "no worktree of issue $number stands here - only the card and the issue are brought up to date"

# What landed. An issue no commit on origin names has not landed, whatever its worktree held: the
# card does not move and the issue is not told. The reference stands alone: '#<N>' must not match
# '<OWNER/REPO>#<N>', an issue of another repository.
commits="$(git -C "$main" log "origin/$default" -E --grep="(^|[^A-Za-z0-9._/-])${ref//./\\.}([^0-9]|$)" --format='- %h %s' -n 20)"
[ -n "$commits" ] \
  || die "no commit on origin/$default names $ref: nothing of it has landed, so the card stays and the issue is not told; a commit that touches an issue names it"

# The card: one column past implementing, as the board orders them, unless that column is done
if [ "$state" = closed ]; then
  echo "the issue is closed already - its card stays where closing put it"
elif repo="$(resolve_repo "$repo")" && on_no_board "$repo"; then
  echo "$repo is on no board - there is no card to move"
else
  set_project "" "$repo" >/dev/null
  next="$(fields_tsv | awk -F'\t' 'tolower($1)=="status" { if (hit) { print $3; exit } if (tolower($3)=="implementing") hit=1 }')"
  if [ -z "$next" ]; then
    echo "the board has no column after implementing - the card stays; move it by hand"
  elif [ "$(printf '%s' "$next" | tr '[:upper:]' '[:lower:]')" = done ]; then
    echo "the column after implementing is done, which closing the issue sets - the card stays for the owner"
  elif moved="$("$BIN/issue-status.sh" ${repo:+"$repo"} "$number" "$next" 2>&1)"; then
    printf '%s\n' "$moved"
  else
    echo "the card did NOT move: $moved - move it to $next by hand" >&2
  fi
fi

# What landed, in the issue, for whoever reads it next
# An issue of another repository is told which repository the commits are in
landed_on="$default"; [ "$ref" = "#$number" ] || landed_on="$default of $(default_repo)"
body="$(printf 'Landed on %s:\n\n%s\n' "$landed_on" "$commits")"
"$BIN/issue-comment.sh" ${repo:+"$repo"} "$number" "$body" >/dev/null \
  && echo "the issue says what landed" \
  || echo "the issue was NOT told what landed - add the commits by hand" >&2

# The cards of this repository whose work a release carries and a proof covers close (status-sync)
released_repo="$(resolve_repo "")" && sync_released_cards "$released_repo"
