#!/usr/bin/env bash
# Close the worktree of one issue once its work has landed, move its card one column on, and say
# in the issue what landed.
#
#   finish-issue.sh NUMBER
#   finish-issue.sh --sweep [--dry-run]
#
# The counterpart of start-issue. A worktree left behind after its work landed holds a copy of
# the repository and its build output, gigabytes on a machine with several sessions, and a card
# left in implementing tells everyone the work is still going on. Run it from the checkout or from
# any worktree of the repository, after the push that lands the work.
#
# NOTHING THAT HAS NOT LANDED IS REMOVED. A worktree with changes, or with a commit origin's
# default branch does not have, stops the run and is named; the work in it is somebody's.
#
# THE CARD MOVES TO THE COLUMN AFTER implementing, read from the board's own order: on a board
# with a testing column the card goes there, and the owner closes the issue after review. Where
# the next column is done, the card stays, because done is what closing the issue sets.
#
# --sweep removes every worktree of this repository whose work has landed and has rested for a
# day, and names the others it leaves; start-issue and init --all run it, so a worktree nobody
# finished does not stay for good. A worktree that was never committed in is left alone.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/board.sh"

BIN="$ROOT/bin"
usage='usage: finish-issue.sh NUMBER | finish-issue.sh --sweep [--dry-run]'
# A landed worktree younger than this is left to the session that may still be working in it
REST_SECONDS=$((24 * 3600))

sweep=0; dry=0; number=""
for arg in "$@"; do
  case "$arg" in
    --sweep)   sweep=1 ;;
    --dry-run) dry=1 ;;
    -*)        die "unknown argument '$arg' - $usage" ;;
    *)         [ -z "$number" ] || die "$usage"; number="$arg" ;;
  esac
done
if [ "$sweep" -eq 1 ]; then [ -z "$number" ] || die "$usage"
else
  case "$number" in ''|*[!0-9]*) die "the issue number must be numeric, not '$number' - $usage" ;; esac
  [ "$dry" -eq 0 ] || die "--dry-run goes with --sweep - $usage"
fi

git rev-parse --show-toplevel >/dev/null 2>&1 \
  || die 'not inside a git working copy - run this from the repository the work belongs to'

said="$(git fetch origin 2>&1)" \
  || die "could not reach origin: $said - what has landed is measured against what origin has right now"
head_ref="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null || true)"
[ -n "$head_ref" ] \
  || die "cannot read the default branch from origin/HEAD - run 'git remote set-head origin -a', then run this again"
default="${head_ref##refs/remotes/origin/}"

# The main checkout, as start-issue finds it: the worktrees are removed from there, so this answers
# the same from inside the worktree being removed.
common="$(git rev-parse --git-common-dir)"
main="$(cd "$common/.." && git rev-parse --show-toplevel)"

# landed <branch>: every commit of the branch is on origin's default branch
landed() { [ "$(git -C "$main" rev-list --count "origin/$default..refs/heads/$1" 2>/dev/null || echo 1)" -eq 0 ]; }
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
    if [ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ]; then echo "worktree $path: has changes, stays"
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
found=0
while IFS=$'\t' read -r path branch; do
  [ -n "$path" ] || continue
  case "$branch" in "issue-$number"|"issue-$number-"*) ;; *) continue ;; esac
  found=1
  [ -z "$(git -C "$path" status --porcelain)" ] \
    || die "the worktree $path has changes - commit and push them, or put them aside, then run this again"
  ahead="$(git -C "$main" rev-list --count "origin/$default..refs/heads/$branch")"
  [ "$ahead" -eq 0 ] \
    || die "the worktree $path has $ahead commit(s) origin/$default does not have - push them, then run this again"
  remove_worktree "$path" "$branch"
  echo "Worktree $path and its branch $branch removed: its work is on origin/$default. Open $main to go on."
done <<< "$(issue_worktrees)"
[ "$found" -eq 1 ] || echo "no worktree of issue $number stands here - only the card and the issue are brought up to date"

# The card: one column past implementing, as the board orders them, unless that column is done
thread="$("$BIN/issue-thread.sh" "$number" --json 2>&1)" || die "the issue could not be read: $thread"
if [ "$(printf '%s' "$thread" | jq -r '.state // ""' | tr '[:upper:]' '[:lower:]')" = closed ]; then
  echo "the issue is closed already - its card stays where closing put it"
elif repo="$(resolve_repo "")" && on_no_board "$repo"; then
  echo "$repo is on no board - there is no card to move"
else
  set_project "" "$repo" >/dev/null
  next="$(fields_tsv | awk -F'\t' 'tolower($1)=="status" { if (hit) { print $3; exit } if (tolower($3)=="implementing") hit=1 }')"
  if [ -z "$next" ]; then
    echo "the board has no column after implementing - the card stays; move it by hand"
  elif [ "$(printf '%s' "$next" | tr '[:upper:]' '[:lower:]')" = done ]; then
    echo "the column after implementing is done, which closing the issue sets - the card stays for the owner"
  elif moved="$("$BIN/issue-status.sh" "$number" "$next" 2>&1)"; then
    printf '%s\n' "$moved"
  else
    echo "the card did NOT move: $moved - move it to $next by hand" >&2
  fi
fi

# What landed, in the issue, for whoever reads it next
commits="$(git -C "$main" log "origin/$default" -E --grep="#$number([^0-9]|$)" --format='- %h %s' -n 20)"
[ -n "$commits" ] || commits="- (no commit on origin/$default names #$number)"
body="$(printf 'Landed on %s:\n\n%s\n' "$default" "$commits")"
"$BIN/issue-comment.sh" "$number" "$body" >/dev/null \
  && echo "the issue says what landed" \
  || echo "the issue was NOT told what landed - add the commits by hand" >&2
