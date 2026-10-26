#!/usr/bin/env bash
# The lifetime of a linked worktree while the harness works in it. Source it, do not run it.
#
# init equips a worktree for minutes, and finish-issue may remove the same worktree meanwhile:
# the run then writes into a path that is no worktree any more and creates it again. So init locks
# the worktree with `git worktree lock`, which makes `git worktree remove` refuse, and unlocks it
# when it ends. finish-issue reads the lock and names it. A path under .worktrees/ that holds no
# .git is no worktree, and nothing is written into it.

WORKTREE_INIT_LOCK="ai-core init"

# worktree_is_linked <dir>: the directory is a linked worktree, not a main checkout or a plain folder
worktree_is_linked() {
  local gitdir common
  gitdir="$(git -C "$1" rev-parse --path-format=absolute --git-dir 2>/dev/null)" || return 1
  common="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [ "$gitdir" != "$common" ]
}

# worktree_orphan <dir>: a path under .worktrees/ that is no checkout, the leftover of a removed worktree
worktree_orphan() {
  local top
  case "$1" in */.worktrees/*) ;; *) return 1 ;; esac
  [ ! -e "$1/.git" ] || return 1
  top="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || return 0
  case "$top" in */.worktrees/*) return 1 ;; esac
  return 0
}

# worktree_lock_reason <checkout> <worktree path>: prints the reason the worktree is locked with, and
# succeeds, where git lists that path as locked
worktree_lock_reason() {
  git -C "$1" worktree list --porcelain | awk -v want="$2" '
    /^worktree / { current = substr($0, 10) }
    current == want && /^locked/ && !found { found = 1; print substr($0, 8) }
    END { exit found ? 0 : 1 }'
}

# worktree_lock_state <reason>: what a lock with that reason is, on one line that holds no colon
worktree_lock_state() {
  if [ "$1" = "$WORKTREE_INIT_LOCK" ]; then echo "locked by ai-core init, which is equipping it"
  else echo "locked${1:+ ($(sed 's/: / - /g' <<< "$1"))}"; fi
}

# worktree_lock_retry <worktree path> <reason>: what to do about that lock
worktree_lock_retry() {
  if [ "$2" = "$WORKTREE_INIT_LOCK" ]; then
    echo "run it again in a moment, and where no init runs any more it was killed and git worktree unlock $1 lifts the lock"
  else
    echo "git worktree unlock $1 lifts the lock"
  fi
}

# delete_branch_at_tip <checkout> <branch> <tip>: deletes the local branch in one step that holds only
# while it still points at <tip>, the tip that was measured, then its configuration; a branch that a
# worktree has checked out stays. Where it deletes nothing it prints why and fails.
delete_branch_at_tip() {
  local checkout="$1" branch="$2" tip="$3" said status=0
  if grep -qxF "$branch" <<< "$(git -C "$checkout" worktree list --porcelain | sed -n 's#^branch refs/heads/##p')"; then
    echo "the branch $branch stays: a worktree has it checked out"; return 1
  fi
  if ! said="$(git -C "$checkout" update-ref -d "refs/heads/$branch" "$tip" 2>&1)"; then
    echo "the branch $branch stays: it is not at ${tip:0:7} any more - $(tr -s '\n' ' ' <<< "$said" | sed 's/: / - /g; s/ *$//')"; return 1
  fi
  # exit 128 is git saying that the branch had no configuration section
  git -C "$checkout" config --remove-section "branch.$branch" 2>/dev/null || status=$?
  case "$status" in 0|128) ;; *) echo "the branch $branch is deleted, but its configuration section could not be removed"; return 1 ;; esac
}

# worktree_lock_for_init <dir>: locks the worktree for this run and remembers it in WORKTREE_LOCKED and
# WORKTREE_LOCK_COMMON. A lock that somebody else holds is kept as it is and not taken over; where that
# somebody is another ai-core init, the run fails, because the two would write the same files.
worktree_lock_for_init() {
  local dir said held lockfile
  WORKTREE_LOCKED=""; WORKTREE_LOCK_COMMON=""
  # git lists a worktree by its top folder with links resolved, and the unlock finds the lock by that path
  dir="$(git -C "$1" rev-parse --show-toplevel 2>&1)" || { echo "error: could not lock the worktree $1: $dir" >&2; return 1; }
  if said="$(git -C "$dir" worktree lock --reason "$WORKTREE_INIT_LOCK" "$dir" 2>&1)"; then
    WORKTREE_LOCKED="$dir"
    WORKTREE_LOCK_COMMON="$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir)"
    return 0
  fi
  lockfile="$(git -C "$dir" rev-parse --absolute-git-dir)/locked"
  [ -e "$lockfile" ] || { echo "error: could not lock the worktree $dir: $said" >&2; return 1; }
  held="$(cat "$lockfile")"
  if [ "$held" = "$WORKTREE_INIT_LOCK" ]; then
    echo "error: another ai-core init holds the worktree $dir (it is locked: $held); run init again when it ends, and where none runs any more it was killed: git worktree unlock $dir" >&2
    return 1
  fi
  echo "The worktree is locked by somebody else${held:+ ($held)}; init leaves that lock as it is."
}

# worktree_unlock_for_init: lifts the lock this run took, and only while it is still this run's
worktree_unlock_for_init() {
  local dir="${WORKTREE_LOCKED:-}" reason
  [ -n "$dir" ] || return 0
  WORKTREE_LOCKED=""
  reason="$(worktree_lock_reason "$WORKTREE_LOCK_COMMON" "$dir")" || return 0
  [ "$reason" = "$WORKTREE_INIT_LOCK" ] || return 0
  git -C "$WORKTREE_LOCK_COMMON" worktree unlock "$dir" || echo "warning: could not unlock the worktree $dir; git worktree unlock $dir lifts it" >&2
}
