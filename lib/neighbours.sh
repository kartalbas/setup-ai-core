#!/usr/bin/env bash
# THE PUBLISHED COPIES OF THE NEIGHBOURS, for init, which makes and links them, and for the push gate,
# which brings them to the newest commit of their origins before a check reads them. Source it, do not
# run it; lib/common.sh is sourced already.
#
# A copy is the detached worktree <project folder>/.ai-core/neighbours/<neighbour>/origin-<branch>, and
# the link ../<neighbour> beside the worktrees of a repository leads to it. A copy stays where it stands
# while it holds a change in its tree or a commit its origin lacks: it is then somebody's work.
#
# Two locks of the kernel (flock) keep the movers and the readers of a copy apart. They belong to the
# process that holds them: a process that ends loses them, and no process takes one from a process that
# runs.
#   <neighbour>/.fetch.lock  exclusive, only while origin is asked
#   <neighbour>/.copy.lock   shared by a gate whose check reads the copy for as long as the check runs,
#                            exclusive while the copy moves, so a reader never sees half a checkout and
#                            a copy never moves under a check
# A gate that holds several neighbours takes their locks in the order of the names, so two gates cannot
# wait for each other.

# neighbour_dir <project folder> <neighbour>: where the copies of a neighbour stand
neighbour_dir() { printf '%s/.ai-core/neighbours/%s\n' "$1" "$2"; }

# neighbour_lock_wait <config.env>: the seconds a lock is waited for, from NEIGHBOUR_LOCK_WAIT_SECONDS
neighbour_lock_wait() {
  local wait
  wait="$(config_value_in_file "$1" NEIGHBOUR_LOCK_WAIT_SECONDS 600)"
  case "$wait" in ''|*[!0-9]*) echo "error: NEIGHBOUR_LOCK_WAIT_SECONDS is '$wait' in $1; it is the seconds a copy of a neighbour is waited for, a whole number of 0 or more" >&2; return 1 ;; esac
  printf '%s\n' "$wait"
}

# neighbour_open <fd> <lock file>: opens the lock file on that descriptor, which the caller keeps for as long as
# the lock is to hold
neighbour_open() {
  NEIGHBOUR_ERROR=""
  eval "exec $1>>\"\$2\"" 2>/dev/null || { NEIGHBOUR_ERROR="the lock file $2 cannot be opened"; return 1; }
}

# neighbour_flock <fd> <lock file> shared|exclusive <seconds>: takes the lock on the descriptor neighbour_open
# opened; a lock the descriptor holds already is converted. On failure NEIGHBOUR_ERROR says why.
neighbour_flock() {
  local flag=-x
  [ "$3" != shared ] || flag=-s
  NEIGHBOUR_ERROR=""
  command -v flock >/dev/null 2>&1 \
    || { NEIGHBOUR_ERROR="flock (util-linux) is not on the path, and the copies of the neighbours are locked with it"; return 1; }
  flock "$flag" -w "$4" "$1" \
    || { NEIGHBOUR_ERROR="the lock $2 is held by another gate or init and was not free in $4 seconds (NEIGHBOUR_LOCK_WAIT_SECONDS)"; return 1; }
}

# neighbour_unlock <fd>: closes the descriptor, which gives up its lock
neighbour_unlock() { eval "exec $1>&-"; }

# neighbour_default_ref <neighbour checkout>: origin/<branch> of the default branch its origin named at the
# last fetch, or nothing and status 1
neighbour_default_ref() { git -C "$1" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null; }

# neighbour_fetch <project folder> <neighbour> <seconds>: asks the origin of the neighbour's checkout for its branches
# and its default branch, one asker at a time. Prints git's words and fails where it could not. No prompt: an
# origin that wants a login the shell does not hold fails here instead of waiting.
neighbour_fetch() (
  local dir="$(neighbour_dir "$1" "$2")" checkout="$1/$2" said
  mkdir -p "$dir" && neighbour_open 8 "$dir/.fetch.lock" && neighbour_flock 8 "$dir/.fetch.lock" exclusive "$3" || { printf '%s\n' "$NEIGHBOUR_ERROR"; exit 1; }
  said="$(GIT_TERMINAL_PROMPT=0 git -C "$checkout" fetch -q origin 2>&1 < /dev/null)" || { printf '%s\n' "$said"; exit 1; }
  said="$(GIT_TERMINAL_PROMPT=0 git -C "$checkout" remote set-head origin --auto 2>&1 < /dev/null)" || { printf '%s\n' "$said"; exit 1; }
)

# neighbour_copy_state <copy> <ref>: sets NEIGHBOUR_STATE to
#   current     the copy stands at <ref> and holds no change
#   movable     it stands on an ancestor of <ref> and holds no change
#   held        it holds a change or a commit <ref> lacks; NEIGHBOUR_ERROR says which
# and fails, with NEIGHBOUR_STATE empty, where git could not tell: a status that cannot be read is no clean tree.
neighbour_copy_state() {
  local copy="$1" ref="$2" changes head target rc=0
  NEIGHBOUR_STATE=""; NEIGHBOUR_ERROR=""
  head="$(git -C "$copy" rev-parse -q --verify 'HEAD^{commit}' 2>&1)" || { NEIGHBOUR_ERROR="git cannot read HEAD of $copy: $head"; return 1; }
  target="$(git -C "$copy" rev-parse -q --verify "$ref^{commit}" 2>&1)" || { NEIGHBOUR_ERROR="git cannot read $ref in $copy: $target"; return 1; }
  changes="$(git -C "$copy" status --porcelain 2>&1)" || { NEIGHBOUR_ERROR="git status of $copy failed: $changes"; return 1; }
  if [ -n "$changes" ]; then NEIGHBOUR_STATE=held; NEIGHBOUR_ERROR="it holds a change in its tree"; return 0; fi
  git -C "$copy" merge-base --is-ancestor HEAD "$target" 2>/dev/null || rc=$?
  case "$rc" in
    0) ;;
    1) NEIGHBOUR_STATE=held; NEIGHBOUR_ERROR="it holds a commit its origin lacks"; return 0 ;;
    *) NEIGHBOUR_ERROR="git cannot tell whether $copy stands on an ancestor of $ref"; return 1 ;;
  esac
  if [ "$head" = "$target" ]; then NEIGHBOUR_STATE=current; else NEIGHBOUR_STATE=movable; fi
}

# neighbour_move_copy <copy> <ref>: puts the copy on <ref>, which the caller holds exclusively and found movable,
# and proves it stands there; on failure NEIGHBOUR_ERROR says why
neighbour_move_copy() {
  local said
  said="$(git -C "$1" checkout -q --detach "$2" 2>&1)" || { NEIGHBOUR_ERROR="git checkout of $2 in $1 failed: $said"; return 1; }
  [ "$(git -C "$1" rev-parse HEAD)" = "$(git -C "$1" rev-parse "$2^{commit}")" ] \
    || { NEIGHBOUR_ERROR="$1 does not stand on $2 after the checkout"; return 1; }
}

# neighbour_refresh_copy <project folder> <neighbour> <copy> <ref> <seconds>: for init. The copy moves to <ref> where
# it holds nothing of anybody's. Its state is read under the shared lock, so a copy that stays waits for no check
# that reads it; only a move takes the exclusive lock. Prints one line, the state - current, moved, held or failed -
# and a tab and the reason where there is one.
neighbour_refresh_copy() (
  local dir="$(neighbour_dir "$1" "$2")"
  { neighbour_open 9 "$dir/.copy.lock" && neighbour_flock 9 "$dir/.copy.lock" shared "$5"; } || { printf 'failed\t%s\n' "$NEIGHBOUR_ERROR"; exit 0; }
  neighbour_copy_state "$3" "$4" || { printf 'failed\t%s\n' "$NEIGHBOUR_ERROR"; exit 0; }
  if [ "$NEIGHBOUR_STATE" = movable ]; then
    neighbour_flock 9 "$dir/.copy.lock" exclusive "$5" || { printf 'failed\t%s\n' "$NEIGHBOUR_ERROR"; exit 0; }
    neighbour_copy_state "$3" "$4" || { printf 'failed\t%s\n' "$NEIGHBOUR_ERROR"; exit 0; }
  fi
  case "$NEIGHBOUR_STATE" in
    held) printf 'held\t%s\n' "$NEIGHBOUR_ERROR" ;;
    current) printf 'current\n' ;;
    movable) if neighbour_move_copy "$3" "$4"; then printf 'moved\n'; else printf 'failed\t%s\n' "$NEIGHBOUR_ERROR"; fi ;;
  esac
)

# neighbour_add_copy <project folder> <neighbour> <copy> <ref> <seconds>: for init. Adds the copy as a detached
# worktree at <ref> under the exclusive lock, so no reader finds it half made. Fails where the copy does not stand
# afterwards: a second init may have added it, which is as good.
neighbour_add_copy() (
  local dir="$(neighbour_dir "$1" "$2")"
  mkdir -p "$dir" && neighbour_open 9 "$dir/.copy.lock" && neighbour_flock 9 "$dir/.copy.lock" exclusive "$5" || exit 1
  git -C "$1/$2" worktree add -q --detach "$3" "$4" >/dev/null 2>&1 || [ -e "$3/.git" ]
)

# neighbours_hold <worktree>: for the push gate. For every link beside the worktree that leads to a published
# copy, in the order of the neighbours' names: asks the origin, brings the copy to its newest commit where the
# copy holds nothing of anybody's, and keeps a shared lock on it, on a descriptor from 40 up, until
# neighbours_release. The check then reads the measured snapshot, and no init and no other gate moves it.
# Sets NEIGHBOUR_REPORT, one line per neighbour, and NEIGHBOUR_TIPS, one line per neighbour, the name and the
# full commit the copy stands at; fails with NEIGHBOUR_ERROR naming the copy whose freshness could not be
# established. A worktree with no such link holds nothing.
NEIGHBOUR_REPORT=""; NEIGHBOUR_TIPS=""; NEIGHBOUR_ERROR=""; NEIGHBOUR_STATE=""; NEIGHBOUR_FDS=""
NEIGHBOUR_FETCH_WRAP=""   # a command that runs the fetch, such as the sign-in line of a forge
neighbours_hold() {
  local root="$1" common main folder container link name target copy branch ref fd=40 wait dir before after note names said
  NEIGHBOUR_REPORT=""; NEIGHBOUR_TIPS=""; NEIGHBOUR_FDS=""; NEIGHBOUR_ERROR=""
  common="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 0
  [ "$common" != "$(git -C "$root" rev-parse --path-format=absolute --git-dir 2>/dev/null)" ] || return 0
  main="$(dirname "$common")"; folder="$(dirname "$main")"; container="$(dirname "$(git -C "$root" rev-parse --show-toplevel)")"
  [ "$container" = "$folder/.worktrees/${main##*/}" ] || return 0
  names="$(for link in "$container"/*; do
    [ -L "$link" ] || continue
    case "$(readlink "$link")" in "../../.ai-core/neighbours/${link##*/}/origin-"?*) echo "${link##*/}" ;; esac
  done | LC_ALL=C sort)"
  [ -n "$names" ] || return 0
  wait="$(neighbour_lock_wait "$root/.ai-core/config.env")" || { NEIGHBOUR_ERROR="NEIGHBOUR_LOCK_WAIT_SECONDS is not a whole number of seconds in $root/.ai-core/config.env"; return 1; }
  while IFS= read -r name; do
    target="$(readlink "$container/$name")"; branch="${target#../../.ai-core/neighbours/$name/origin-}"
    dir="$(neighbour_dir "$folder" "$name")"; copy="$dir/origin-$branch"
    if [ ! -e "$copy/.git" ] || [ ! -d "$folder/$name/.git" ]; then
      NEIGHBOUR_ERROR="the link $container/$name leads to $copy, and that copy or the checkout $folder/$name is gone: run ai-core init in this worktree"
      return 1
    fi
    if ! said="$(${NEIGHBOUR_FETCH_WRAP:+$NEIGHBOUR_FETCH_WRAP} neighbour_fetch "$folder" "$name" "$wait")"; then
      NEIGHBOUR_ERROR="the origin of $name could not be asked, so its copy $copy may stand behind it: ${said//$'\n'/ | }"
      return 1
    fi
    ref="$(neighbour_default_ref "$folder/$name")" || ref=""
    if [ "$ref" != "origin/$branch" ]; then
      NEIGHBOUR_ERROR="the origin of $name names ${ref:-no default branch} and the link leads to the copy of $branch: run ai-core init in this worktree, which follows it"
      return 1
    fi
    NEIGHBOUR_FDS="$NEIGHBOUR_FDS $fd"
    neighbour_open "$fd" "$dir/.copy.lock" || return 1
    neighbour_flock "$fd" "$dir/.copy.lock" shared "$wait" || { NEIGHBOUR_ERROR="the copy $copy cannot be read: $NEIGHBOUR_ERROR"; return 1; }
    neighbour_copy_state "$copy" "$ref" || { NEIGHBOUR_ERROR="the freshness of $copy cannot be established: $NEIGHBOUR_ERROR"; return 1; }
    before="$(git -C "$copy" rev-parse HEAD)"; note="already at $ref"
    if [ "$NEIGHBOUR_STATE" = movable ]; then
      neighbour_flock "$fd" "$dir/.copy.lock" exclusive "$wait" || { NEIGHBOUR_ERROR="the copy $copy cannot move to $ref, as a check still reads it: $NEIGHBOUR_ERROR"; return 1; }
      neighbour_copy_state "$copy" "$ref" || { NEIGHBOUR_ERROR="the freshness of $copy cannot be established: $NEIGHBOUR_ERROR"; return 1; }
      if [ "$NEIGHBOUR_STATE" = movable ]; then
        neighbour_move_copy "$copy" "$ref" || { NEIGHBOUR_ERROR="the copy $copy could not move to $ref: $NEIGHBOUR_ERROR"; return 1; }
      fi
      neighbour_flock "$fd" "$dir/.copy.lock" shared "$wait" || { NEIGHBOUR_ERROR="the copy $copy cannot be read: $NEIGHBOUR_ERROR"; return 1; }
      note="moved from $before to $ref"
    fi
    after="$(git -C "$copy" rev-parse HEAD)"
    neighbour_copy_state "$copy" "$ref" || { NEIGHBOUR_ERROR="the freshness of $copy cannot be established: $NEIGHBOUR_ERROR"; return 1; }
    [ "$NEIGHBOUR_STATE" != held ] || note="NOT moved to $ref ($(git -C "$copy" rev-parse "$ref^{commit}")): $NEIGHBOUR_ERROR"
    NEIGHBOUR_REPORT="$NEIGHBOUR_REPORT$name: the published copy $copy stands at $after ($note)"$'\n'
    NEIGHBOUR_TIPS="$NEIGHBOUR_TIPS$name $after"$'\n'
    fd=$((fd + 1))
  done <<< "$names"
}

# neighbours_release: gives up the locks neighbours_hold took
neighbours_release() {
  local fd
  for fd in $NEIGHBOUR_FDS; do neighbour_unlock "$fd"; done
  NEIGHBOUR_FDS=""
}
