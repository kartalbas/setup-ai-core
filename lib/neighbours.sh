#!/usr/bin/env bash
# THE PUBLISHED COPIES OF THE NEIGHBOURS, for init, which makes and links them, and for the push gate,
# which brings them to the newest commit of their origins before a check reads them. Source it, do not
# run it; lib/common.sh is sourced already.
#
# A copy is the detached worktree <project folder>/.ai-core/neighbours/<neighbour>/origin-<branch>, and
# the link ../<neighbour> beside the worktrees of a repository leads to it. A copy stays where it stands
# while it holds a change in its tree or a commit its origin lacks: it is then somebody's work.
#
# Three locks of the kernel (flock) keep the movers and the readers of a copy apart. They belong to the process
# that holds them: a process that ends loses them, and no process takes one from a process that runs.
#   <neighbour>/.fetch.lock      exclusive, only while origin is asked
#   <neighbour>/.admission.lock  shared by a gate only while it takes the copy lock, exclusive for a mover from the moment
#                                it wants the copy until the move ended: a gate that finds it held waits, so the gates
#                                that read the copy already are the last a mover waits for
#   <neighbour>/.copy.lock       shared by a gate whose check reads the copy for as long as the check runs,
#                                exclusive while the copy moves, so a reader never sees half a checkout and
#                                a copy never moves under a check
# A reader takes the admission lock, then the copy lock, then gives the admission lock up; a mover takes the admission
# lock, and the copy lock once the readers it found have ended. A copy lock is waited for as long as the checks take:
# NEIGHBOUR_LOCK_WAIT_SECONDS, when above 0, is the least, and the wait is at least one and a half times the longest
# check the run log of the gate records for the last 14 days (neighbour_allowance). Admission and copy locks share
# that one wait. A gate that holds several neighbours takes their locks in the order of the names, and holds none of
# them while it waits for another. Descriptors: 7 admission in hand, 8 fetch, 9 copy in hand, 40 up the copies a gate
# holds, 60 up the admissions an init holds for its pending moves.

. "$(dirname "${BASH_SOURCE[0]}")/pre-push-runs.sh"

# neighbour_dir <project folder> <neighbour>: where the copies of a neighbour stand
neighbour_dir() { printf '%s/.ai-core/neighbours/%s\n' "$1" "$2"; }

# neighbour_lock_wait <config.env>: NEIGHBOUR_LOCK_WAIT_SECONDS, a whole number up to nine digits: the seconds a
# fetch is waited for, and the least a copy lock is waited for, which 0 turns into one attempt
neighbour_lock_wait() {
  local wait
  wait="$(config_value_in_file "$1" NEIGHBOUR_LOCK_WAIT_SECONDS 600)" || return 1
  case "$wait" in ''|*[!0-9]*|??????????*) echo "error: NEIGHBOUR_LOCK_WAIT_SECONDS is '$wait' in $1; it is the least seconds a copy of a neighbour is waited for, a whole number from 0 to 999999999" >&2; return 1 ;; esac
  printf '%s\n' "$((10#$wait))"
}

# neighbour_open <fd> <lock file>: opens the lock file on that descriptor, which the caller keeps for as long as
# the lock is to hold
neighbour_open() {
  NEIGHBOUR_ERROR=""
  eval "exec $1>>\"\$2\"" 2>/dev/null || { NEIGHBOUR_ERROR="the lock file $2 cannot be opened"; return 1; }
}

# neighbour_flock <fd> <lock file> <seconds>: takes the exclusive lock on the descriptor neighbour_open opened,
# for the fetch. On failure NEIGHBOUR_ERROR says why.
neighbour_flock() {
  NEIGHBOUR_ERROR=""
  command -v flock >/dev/null 2>&1 \
    || { NEIGHBOUR_ERROR="flock (util-linux) is not on the path, and the copies of the neighbours are locked with it"; return 1; }
  flock -x -w "$3" "$1" \
    || { NEIGHBOUR_ERROR="the lock $2 is held by another gate or init and was not free in $3 seconds (NEIGHBOUR_LOCK_WAIT_SECONDS)"; return 1; }
}

# neighbour_try_flock <fd> shared|exclusive: takes the lock on the descriptor at once or not at all, and a lock
# the descriptor holds already is given up on the way. Status 0 taken, 1 held by another process, 2 flock failed,
# NEIGHBOUR_ERROR says why.
neighbour_try_flock() {
  local flag=-x rc=0
  [ "$2" != shared ] || flag=-s
  NEIGHBOUR_ERROR=""
  command -v flock >/dev/null 2>&1 \
    || { NEIGHBOUR_ERROR="flock (util-linux) is not on the path, and the copies of the neighbours are locked with it"; return 2; }
  flock "$flag" -n "$1" || rc=$?
  case "$rc" in 0) return 0 ;; 1) return 1 ;; *) NEIGHBOUR_ERROR="flock failed with status $rc"; return 2 ;; esac
}

# The wait for a copy lock, one acquisition at a time: neighbour_wait_begin names the checkout's config.env and
# starts the clock, and every neighbour_wait_flock after it counts from that start.
NEIGHBOUR_WAIT_CONFIG=""; NEIGHBOUR_WAIT_START=0; NEIGHBOUR_WAIT_LONGEST=0; NEIGHBOUR_WAIT_HISTORY=""
NEIGHBOUR_ALLOWANCE=0; NEIGHBOUR_AUTOMATIC=0; NEIGHBOUR_BASE=0
NEIGHBOUR_INITIAL_CHECK_SECONDS=1320   # the 22 minutes of the longest check reported: no wait counts for less

# neighbour_wait_begin <config.env>: an acquisition starts now. The longest check the run log records is read
# once; the configuration is read again at every poll.
neighbour_wait_begin() {
  local log
  NEIGHBOUR_WAIT_CONFIG="$1"; NEIGHBOUR_WAIT_START="$(date +%s)"
  log="$(gate_runs_file)"
  gate_runs_timing "$log" || :
  NEIGHBOUR_WAIT_LONGEST=0
  case "$GATE_RUNS_STATE" in
    missing) NEIGHBOUR_WAIT_HISTORY="no run log stands at $log yet" ;;
    unreadable) NEIGHBOUR_WAIT_HISTORY="the run log $log cannot be read" ;;
    *)
      if [ "$GATE_RUNS_TIMED" -eq 0 ]; then
        NEIGHBOUR_WAIT_HISTORY="no check that ran is recorded among the $GATE_RUNS_ROWS rows of the last $GATE_RUNS_WINDOW_DAYS days of $log"
      else
        NEIGHBOUR_WAIT_LONGEST="$GATE_RUNS_LONGEST"
        NEIGHBOUR_WAIT_HISTORY="the longest of the $GATE_RUNS_TIMED checks among the $GATE_RUNS_ROWS rows of the last $GATE_RUNS_WINDOW_DAYS days of $log took $GATE_RUNS_LONGEST seconds"
      fi
      [ "$GATE_RUNS_OLDER" -eq 0 ] || NEIGHBOUR_WAIT_HISTORY="$NEIGHBOUR_WAIT_HISTORY, and the $GATE_RUNS_OLDER rows before them are not counted"
      [ "$GATE_RUNS_UNREADABLE" -eq 0 ] || NEIGHBOUR_WAIT_HISTORY="$NEIGHBOUR_WAIT_HISTORY, and $GATE_RUNS_UNREADABLE of those rows could not be read" ;;
  esac
}

# neighbour_allowance <configured seconds>: sets NEIGHBOUR_ALLOWANCE, the seconds a copy lock is waited for in all.
# 0 is one attempt. Above 0 it is the greater of the configured seconds, their least, and the automatic ones,
# NEIGHBOUR_AUTOMATIC: one and a half times the longest check on record, which counts for no less than the
# initial 1320 seconds (NEIGHBOUR_BASE).
neighbour_allowance() {
  NEIGHBOUR_BASE="$NEIGHBOUR_WAIT_LONGEST"
  [ "$NEIGHBOUR_BASE" -ge "$NEIGHBOUR_INITIAL_CHECK_SECONDS" ] || NEIGHBOUR_BASE="$NEIGHBOUR_INITIAL_CHECK_SECONDS"
  NEIGHBOUR_AUTOMATIC=$(( (3 * NEIGHBOUR_BASE + 1) / 2 ))
  if [ "$1" -eq 0 ]; then NEIGHBOUR_ALLOWANCE=0
  elif [ "$1" -gt "$NEIGHBOUR_AUTOMATIC" ]; then NEIGHBOUR_ALLOWANCE="$1"
  else NEIGHBOUR_ALLOWANCE="$NEIGHBOUR_AUTOMATIC"
  fi
}

# neighbour_allowance_reason <configured seconds>: what the allowance came from, one phrase
neighbour_allowance_reason() {
  if [ "$1" -eq 0 ]; then echo "NEIGHBOUR_LOCK_WAIT_SECONDS is 0, which is one attempt"; return; fi
  printf 'NEIGHBOUR_LOCK_WAIT_SECONDS is %s, the least; the automatic %s seconds are one and a half times %s seconds, %s (%s)\n' \
    "$1" "$NEIGHBOUR_AUTOMATIC" "$NEIGHBOUR_BASE" \
    "$([ "$NEIGHBOUR_WAIT_LONGEST" -ge "$NEIGHBOUR_INITIAL_CHECK_SECONDS" ] && echo "the longest check on record" || echo "the initial $NEIGHBOUR_INITIAL_CHECK_SECONDS, as no check on record was longer")" \
    "$NEIGHBOUR_WAIT_HISTORY"
}

# neighbour_wait_for <lock description> <holder> <attempt command>...: runs the attempt, which answers as
# neighbour_try_flock does (0 taken, 1 held by another process, 2 failed), at once, and then every tenth of the time
# waited so far, from 1 to 30 seconds, without blocking, until the allowance since neighbour_wait_begin is used up.
# The caller holds no other copy lock. On failure NEIGHBOUR_ERROR says why, and <holder> what keeps the copy longer than
# the allowance. What it says while it waits goes to standard error.
neighbour_wait_for() {
  local lock="$1" holder="$2" rc configured now elapsed remaining step announced=0
  shift 2
  while :; do
    rc=0; "$@" || rc=$?
    [ "$rc" -ne 0 ] || return 0
    [ "$rc" -eq 1 ] || return 1
    configured="$(neighbour_lock_wait "$NEIGHBOUR_WAIT_CONFIG")" \
      || { NEIGHBOUR_ERROR="NEIGHBOUR_LOCK_WAIT_SECONDS is not a whole number of seconds in $NEIGHBOUR_WAIT_CONFIG, or $NEIGHBOUR_WAIT_CONFIG cannot be read"; return 1; }
    neighbour_allowance "$configured"
    now="$(date +%s)"; elapsed=$((now - NEIGHBOUR_WAIT_START)); remaining=$((NEIGHBOUR_ALLOWANCE - elapsed))
    if [ "$remaining" -le 0 ]; then
      NEIGHBOUR_ERROR="the lock $lock is held by another gate or init and was not free in $elapsed seconds ($(neighbour_allowance_reason "$configured")). $holder: wait for it to end, or set NEIGHBOUR_LOCK_WAIT_SECONDS above $NEIGHBOUR_ALLOWANCE in $NEIGHBOUR_WAIT_CONFIG"
      return 1
    fi
    if [ "$announced" -eq 0 ]; then
      echo "neighbours: waiting for the lock $lock, which another gate or init holds: for $NEIGHBOUR_ALLOWANCE seconds at most ($(neighbour_allowance_reason "$configured"))" >&2
      announced=1
    fi
    step=$((elapsed / 10)); [ "$step" -ge 1 ] || step=1; [ "$step" -le 30 ] || step=30
    [ "$remaining" -ge "$step" ] || step="$remaining"
    neighbour_unlocked sleep "$step"
  done
}

# neighbour_wait_flock <fd> <lock file> shared|exclusive [holder]: neighbour_wait_for the lock on the descriptor
# neighbour_open opened. The holder is a check for an exclusive lock, a move for a shared one.
neighbour_wait_flock() {
  local holder="A check that runs longer, or hangs, keeps the copy"
  [ "$3" != shared ] || holder="A move of the copy that runs longer, or hangs, keeps it"
  neighbour_wait_for "$2" "${4:-$holder}" neighbour_try_flock "$1" "$3"
}

# neighbour_enter <fd> <copy lock> <admission lock>: for a gate. Takes the copy lock shared on the descriptor, which the
# caller keeps for as long as the check reads the copy, and only while it holds the admission lock shared, so no mover
# is between its admission and the copy. A pending or running move holds the admission lock exclusive: the gate then
# takes nothing. Answers as neighbour_try_flock does.
neighbour_enter() {
  local rc=0
  neighbour_open 7 "$3" || return 2
  neighbour_try_flock 7 shared || rc=$?
  [ "$rc" -ne 0 ] || neighbour_try_flock "$1" shared || rc=$?
  neighbour_unlock 7
  return "$rc"
}

# neighbour_unlock <fd>: closes the descriptor, which gives up its lock
neighbour_unlock() { eval "exec $1>&-"; }

# neighbour_default_ref <neighbour checkout>: origin/<branch> of the default branch its origin named at the
# last fetch, or nothing and status 1
neighbour_default_ref() { git -C "$1" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null; }

# neighbour_unlocked <command>...: runs the command with the lock descriptors closed, 7, 8, 9 and the ones neighbours_hold
# and neighbour_pending_begin keep, while the shell keeps them. A process that outlives the command, such as the detached
# maintenance git starts after a fetch or a daemon of a check, would otherwise hold a lock until it exits.
neighbour_unlocked() {
  local fd closing="7>&- 8>&- 9>&-"
  for fd in $NEIGHBOUR_FDS; do closing="$closing $fd>&-"; done
  ( eval "exec $closing"; exec "$@" )
}

# neighbour_fetch <project folder> <neighbour> <seconds>: asks the origin of the neighbour's checkout for its branches
# and its default branch, one asker at a time. Prints git's words and fails where it could not. No prompt: an
# origin that wants a login the shell does not hold fails here instead of waiting.
neighbour_fetch() (
  local dir checkout="$1/$2" said
  dir="$(neighbour_dir "$1" "$2")"
  mkdir -p "$dir" && neighbour_open 8 "$dir/.fetch.lock" && neighbour_flock 8 "$dir/.fetch.lock" "$3" || { printf '%s\n' "$NEIGHBOUR_ERROR"; exit 1; }
  said="$(GIT_TERMINAL_PROMPT=0 neighbour_unlocked git -C "$checkout" fetch -q origin 2>&1 < /dev/null)" || { printf '%s\n' "$said"; exit 1; }
  said="$(GIT_TERMINAL_PROMPT=0 neighbour_unlocked git -C "$checkout" remote set-head origin --auto 2>&1 < /dev/null)" || { printf '%s\n' "$said"; exit 1; }
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
  said="$(neighbour_unlocked git -C "$1" checkout -q --detach "$2" 2>&1)" || { NEIGHBOUR_ERROR="git checkout of $2 in $1 failed: $said"; return 1; }
  [ "$(git -C "$1" rev-parse HEAD)" = "$(git -C "$1" rev-parse "$2^{commit}")" ] \
    || { NEIGHBOUR_ERROR="$1 does not stand on $2 after the checkout"; return 1; }
}

# neighbour_copy_of <project folder> <neighbour> <ref>: where the published copy of a neighbour at <ref> stands
neighbour_copy_of() { printf '%s/origin-%s\n' "$(neighbour_dir "$1" "$2")" "${3#origin/}"; }

# neighbour_read_state <directory of the neighbour> <copy> <ref>: neighbour_copy_state under the copy lock taken shared
# for that read alone, so a copy is never read half moved and a copy that stays waits for no check that reads it.
# Fails with NEIGHBOUR_FAILED_STEP reading where the lock was not free in time.
neighbour_read_state() {
  local rc=0
  NEIGHBOUR_FAILED_STEP=reading
  { neighbour_open 9 "$1/.copy.lock" && neighbour_wait_flock 9 "$1/.copy.lock" shared; } || { neighbour_unlock 9; return 1; }
  NEIGHBOUR_FAILED_STEP=state
  neighbour_copy_state "$2" "$3" || rc=$?
  neighbour_unlock 9
  return "$rc"
}

# neighbour_settle <directory of the neighbour> <copy> <ref> <admitted>: for init and the gate, which hold no lock of
# this copy. Sets NEIGHBOUR_STATE to current, held or moved, with NEIGHBOUR_ERROR the reason where it is held, and
# NEIGHBOUR_BEFORE to the commit a moved copy stood at. The copy moves to <ref> where it holds nothing of anybody's:
# the state is read, and only a copy that must move takes the admission lock, exclusive, unless <admitted> is 1, which
# says the caller holds it already. The state is read again once it is held, because another mover may have brought the
# copy to <ref> meanwhile, and the copy lock is then waited for exclusively only for a copy that is still movable, its
# state read once more under it before the checkout. Fails with NEIGHBOUR_FAILED_STEP, reading, admission, copy, state
# or move, and NEIGHBOUR_ERROR. The admission and the copy lock end with the call.
neighbour_settle() {
  local rc=0
  neighbour_settle_steps "$@" || rc=$?
  neighbour_unlock 9; neighbour_unlock 7
  return "$rc"
}
neighbour_settle_steps() {
  local dir="$1" copy="$2" ref="$3"
  NEIGHBOUR_BEFORE=""
  neighbour_read_state "$dir" "$copy" "$ref" || return 1
  [ "$NEIGHBOUR_STATE" = movable ] || return 0
  if [ "$4" -ne 1 ]; then
    NEIGHBOUR_FAILED_STEP=admission
    { neighbour_open 7 "$dir/.admission.lock" && neighbour_wait_flock 7 "$dir/.admission.lock" exclusive "A move of the copy that waits for a check that runs longer, or hangs, keeps it"; } || return 1
    neighbour_read_state "$dir" "$copy" "$ref" || return 1
    [ "$NEIGHBOUR_STATE" = movable ] || return 0
  fi
  NEIGHBOUR_FAILED_STEP=copy
  { neighbour_open 9 "$dir/.copy.lock" && neighbour_wait_flock 9 "$dir/.copy.lock" exclusive; } || return 1
  NEIGHBOUR_FAILED_STEP=state
  neighbour_copy_state "$copy" "$ref" || return 1
  [ "$NEIGHBOUR_STATE" = movable ] || return 0
  NEIGHBOUR_BEFORE="$(git -C "$copy" rev-parse HEAD)"
  NEIGHBOUR_FAILED_STEP=move
  neighbour_move_copy "$copy" "$ref" || return 1
  NEIGHBOUR_STATE=moved
}

# neighbour_pending_begin <project folder> <config.env> <lines>: for init, before it refreshes any copy. <lines> hold one
# copy a line, the neighbour, the copy and the ref, separated by tabs. Of those that must move, in the order of the
# names, it takes the admission lock of every one, exclusive, on a descriptor from 60 up and keeps it until
# neighbour_pending_end or neighbours_release, so no gate that arrives later reads a copy init waits to move, and init
# does not meet a fresh cohort of gates at each neighbour. The state is read again under each admission, and a copy that
# no longer needs a move gives its admission back. One wait starts here: it is the deadline of every copy. A copy whose
# state cannot be read, or whose admission is not free in time, is left for neighbour_refresh_copy to name. Init refreshes
# the copies it claimed (neighbour_claimed) before any other, so it never waits for the admission of another copy while it
# keeps a claim: a second init that holds that admission and waits for the claim would make both wait out the allowance.
NEIGHBOUR_PENDING=""
neighbour_pending_begin() {
  local name copy ref dir fd=60 lines
  neighbour_wait_begin "$2"; NEIGHBOUR_PENDING=""
  lines="$(printf '%s' "$3" | LC_ALL=C sort)"
  while IFS=$'\t' read -r name copy ref; do
    [ -n "$name" ] || continue
    dir="$(neighbour_dir "$1" "$name")"
    neighbour_read_state "$dir" "$copy" "$ref" && [ "$NEIGHBOUR_STATE" = movable ] || continue
    NEIGHBOUR_FDS="$NEIGHBOUR_FDS $fd"
    { neighbour_open "$fd" "$dir/.admission.lock" && neighbour_wait_flock "$fd" "$dir/.admission.lock" exclusive "A move of the copy that waits for a check that runs longer, or hangs, keeps it"; } || { neighbour_unlock "$fd"; continue; }
    if neighbour_read_state "$dir" "$copy" "$ref" && [ "$NEIGHBOUR_STATE" = movable ]; then
      NEIGHBOUR_PENDING="$NEIGHBOUR_PENDING $name:$fd"; fd=$((fd + 1))
    else
      neighbour_unlock "$fd"
    fi
  done <<< "$lines"
}

# neighbour_pending_end <neighbour>: init is done with that copy: its admission lock goes
neighbour_pending_end() {
  local entry kept=""
  for entry in $NEIGHBOUR_PENDING; do
    if [ "${entry%:*}" = "$1" ]; then neighbour_unlock "${entry#*:}"; else kept="$kept $entry"; fi
  done
  NEIGHBOUR_PENDING="$kept"
}

# neighbour_claimed <neighbour>: init holds the admission of that neighbour's copies, which neighbour_pending_begin took
neighbour_claimed() { case "$NEIGHBOUR_PENDING " in *" $1:"*) return 0 ;; esac; return 1; }

# neighbour_refresh_copy <project folder> <neighbour> <copy> <ref> <config.env>: for init. neighbour_settle for the copy,
# which neighbour_pending_begin may hold the admission of already. Prints one line, the state - current, moved, held or
# failed - and a tab and the reason where there is one.
neighbour_refresh_copy() (
  local admitted=0
  [ "$NEIGHBOUR_WAIT_START" -ne 0 ] || neighbour_wait_begin "$5"
  ! neighbour_claimed "$2" || admitted=1
  neighbour_settle "$(neighbour_dir "$1" "$2")" "$3" "$4" "$admitted" || { printf 'failed\t%s\n' "$NEIGHBOUR_ERROR"; exit 0; }
  case "$NEIGHBOUR_STATE" in
    held) printf 'held\t%s\n' "$NEIGHBOUR_ERROR" ;;
    current) printf 'current\n' ;;
    moved) printf 'moved\n' ;;
  esac
)

# neighbour_add_copy <project folder> <neighbour> <copy> <ref> <config.env>: for init. Adds the copy as a detached
# worktree at <ref> under the admission and the exclusive copy lock, so no reader finds it half made and no second
# creator repeats it. Fails where the copy does not stand afterwards.
neighbour_add_copy() (
  local dir
  dir="$(neighbour_dir "$1" "$2")"
  [ "$NEIGHBOUR_WAIT_START" -ne 0 ] || neighbour_wait_begin "$5"
  mkdir -p "$dir" || { echo "neighbours: the folder $dir cannot be made" >&2; exit 1; }
  { neighbour_open 7 "$dir/.admission.lock" && neighbour_wait_flock 7 "$dir/.admission.lock" exclusive "A move of the copy that waits for a check that runs longer, or hangs, keeps it" \
    && neighbour_open 9 "$dir/.copy.lock" && neighbour_wait_flock 9 "$dir/.copy.lock" exclusive; } || { printf '%s\n' "$NEIGHBOUR_ERROR" >&2; exit 1; }
  [ -e "$3/.git" ] || neighbour_unlocked git -C "$1/$2" worktree add -q --detach "$3" "$4" >/dev/null 2>&1 || [ -e "$3/.git" ]
)


# neighbours_hold <worktree>: for the push gate. For every link beside the worktree that leads to a published
# copy, in the order of the neighbours' names: asks the origin, brings the copy to its newest commit where the
# copy holds nothing of anybody's, and keeps a shared lock on it, on a descriptor from 40 up, until
# neighbours_release. The check then reads the measured snapshot, and no init and no other gate moves it.
# A copy that has to move, or a lock a mover holds, is waited for with no lock of any copy held: the gate gives
# them up, waits, moves, and takes every shared lock again in the order of the names, reading each copy's state
# again under its lock, until all are held together. The wait counts from the first lock, and the allowance is
# the one of neighbour_allowance.
# Sets NEIGHBOUR_REPORT, one line per neighbour, and NEIGHBOUR_TIPS, one line per neighbour, the name and the
# full commit the copy stands at; fails with NEIGHBOUR_ERROR naming the copy whose freshness could not be
# established. A worktree with no such link holds nothing.
NEIGHBOUR_REPORT=""; NEIGHBOUR_TIPS=""; NEIGHBOUR_ERROR=""; NEIGHBOUR_STATE=""; NEIGHBOUR_FDS=""
NEIGHBOUR_BRANCH=""; NEIGHBOUR_DIR=""; NEIGHBOUR_COPY=""; NEIGHBOUR_REF=""; NEIGHBOUR_MOVES=""; NEIGHBOUR_BEFORE=""; NEIGHBOUR_FAILED_STEP=""
NEIGHBOUR_FETCH_WRAP=""   # a command that runs the fetch, such as the sign-in line of a forge
neighbours_hold() {
  local root="$1" common main folder container link names config wait
  NEIGHBOUR_REPORT=""; NEIGHBOUR_TIPS=""; NEIGHBOUR_FDS=""; NEIGHBOUR_ERROR=""; NEIGHBOUR_MOVES=""
  common="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 0
  [ "$common" != "$(git -C "$root" rev-parse --path-format=absolute --git-dir 2>/dev/null)" ] || return 0
  main="$(dirname "$common")"; folder="$(dirname "$main")"; container="$(dirname "$(git -C "$root" rev-parse --show-toplevel)")"
  [ "$container" = "$folder/.worktrees/${main##*/}" ] || return 0
  names="$(for link in "$container"/*; do
    [ -L "$link" ] || continue
    case "$(readlink "$link")" in "../../.ai-core/neighbours/${link##*/}/origin-"?*) echo "${link##*/}" ;; esac
  done | LC_ALL=C sort)"
  [ -n "$names" ] || return 0
  config="$root/.ai-core/config.env"
  wait="$(neighbour_lock_wait "$config")" || { NEIGHBOUR_ERROR="NEIGHBOUR_LOCK_WAIT_SECONDS is not a whole number of seconds in $config, or $config cannot be read"; return 1; }
  neighbours_ask "$container" "$folder" "$names" "$wait" || return 1
  neighbour_wait_begin "$config"
  neighbours_take "$container" "$folder" "$names" || { neighbours_release; return 1; }
}

# neighbour_locate <container> <folder> <neighbour>: sets NEIGHBOUR_BRANCH, NEIGHBOUR_DIR and NEIGHBOUR_COPY from the
# link beside the worktree; fails where the copy or the checkout is gone
neighbour_locate() {
  NEIGHBOUR_BRANCH="$(readlink "$1/$3")"; NEIGHBOUR_BRANCH="${NEIGHBOUR_BRANCH#../../.ai-core/neighbours/$3/origin-}"
  NEIGHBOUR_DIR="$(neighbour_dir "$2" "$3")"; NEIGHBOUR_COPY="$NEIGHBOUR_DIR/origin-$NEIGHBOUR_BRANCH"
  if [ ! -e "$NEIGHBOUR_COPY/.git" ] || [ ! -d "$2/$3/.git" ]; then
    NEIGHBOUR_ERROR="the link $1/$3 leads to $NEIGHBOUR_COPY, and that copy or the checkout $2/$3 is gone: run ai-core init in this worktree"
    return 1
  fi
}

# neighbour_follow_default <folder> <neighbour>: sets NEIGHBOUR_REF to the default branch its origin named at the last
# fetch; fails where the link leads to the copy of another branch
neighbour_follow_default() {
  NEIGHBOUR_REF="$(neighbour_default_ref "$1/$2")" || NEIGHBOUR_REF=""
  if [ "$NEIGHBOUR_REF" != "origin/$NEIGHBOUR_BRANCH" ]; then
    NEIGHBOUR_ERROR="the origin of $2 names ${NEIGHBOUR_REF:-no default branch} and the link leads to the copy of $NEIGHBOUR_BRANCH: run ai-core init in this worktree, which follows it"
    return 1
  fi
}

# neighbours_ask <container> <folder> <names> <seconds>: asks the origin of every neighbour, in the order of the names,
# with no copy lock held
neighbours_ask() {
  local name said
  while IFS= read -r name; do
    neighbour_locate "$1" "$2" "$name" || return 1
    if ! said="$(${NEIGHBOUR_FETCH_WRAP:+$NEIGHBOUR_FETCH_WRAP} neighbour_fetch "$2" "$name" "$4")"; then
      NEIGHBOUR_ERROR="the origin of $name could not be asked, so its copy $NEIGHBOUR_COPY may stand behind it: ${said//$'\n'/ | }"
      return 1
    fi
    neighbour_follow_default "$2" "$name" || return 1
  done <<< "$3"
}

# neighbours_take <container> <folder> <names>: enters every copy, in the order of the names, without waiting for any
# (neighbour_enter): at the first copy that has to move, or that a pending or running move keeps, it gives up every
# lock it took, waits for that copy alone, moves it where it is movable (neighbour_settle), and starts again. It
# returns once every lock is held together, each copy's state read under its own lock.
neighbours_take() {
  local name fd rc blocked mode moved_from note
  while :; do
    NEIGHBOUR_REPORT=""; NEIGHBOUR_TIPS=""; blocked=""; fd=40
    while IFS= read -r name; do
      neighbour_locate "$1" "$2" "$name" && neighbour_follow_default "$2" "$name" || return 1
      NEIGHBOUR_FDS="$NEIGHBOUR_FDS $fd"
      neighbour_open "$fd" "$NEIGHBOUR_DIR/.copy.lock" || return 1
      rc=0; neighbour_enter "$fd" "$NEIGHBOUR_DIR/.copy.lock" "$NEIGHBOUR_DIR/.admission.lock" || rc=$?
      if [ "$rc" -eq 1 ]; then blocked="$name"; mode=shared; break; fi
      [ "$rc" -eq 0 ] || { NEIGHBOUR_ERROR="the copy $NEIGHBOUR_COPY cannot be read: $NEIGHBOUR_ERROR"; return 1; }
      neighbour_copy_state "$NEIGHBOUR_COPY" "$NEIGHBOUR_REF" || { NEIGHBOUR_ERROR="the freshness of $NEIGHBOUR_COPY cannot be established: $NEIGHBOUR_ERROR"; return 1; }
      if [ "$NEIGHBOUR_STATE" = movable ]; then blocked="$name"; mode=exclusive; break; fi
      moved_from="$(awk -v n="$name" '$1 == n { print $2; exit }' <<< "$NEIGHBOUR_MOVES")"
      if [ "$NEIGHBOUR_STATE" = held ]; then note="NOT moved to $NEIGHBOUR_REF ($(git -C "$NEIGHBOUR_COPY" rev-parse "$NEIGHBOUR_REF^{commit}")): $NEIGHBOUR_ERROR"
      elif [ -n "$moved_from" ]; then note="moved from $moved_from to $NEIGHBOUR_REF"
      else note="already at $NEIGHBOUR_REF"; fi
      NEIGHBOUR_TIPS="$NEIGHBOUR_TIPS$name $(git -C "$NEIGHBOUR_COPY" rev-parse HEAD)"$'\n'
      NEIGHBOUR_REPORT="$NEIGHBOUR_REPORT$name: the published copy $NEIGHBOUR_COPY stands at $(git -C "$NEIGHBOUR_COPY" rev-parse HEAD) ($note)"$'\n'
      fd=$((fd + 1))
    done <<< "$3"
    [ -n "$blocked" ] || return 0
    neighbours_release
    if [ "$mode" = shared ]; then
      NEIGHBOUR_FDS=" 40"
      neighbour_open 40 "$NEIGHBOUR_DIR/.copy.lock" || return 1
      neighbour_wait_for "$NEIGHBOUR_DIR/.admission.lock or $NEIGHBOUR_DIR/.copy.lock" "A move of the copy that runs longer, or hangs, keeps it" \
        neighbour_enter 40 "$NEIGHBOUR_DIR/.copy.lock" "$NEIGHBOUR_DIR/.admission.lock" || { NEIGHBOUR_ERROR="the copy $NEIGHBOUR_COPY cannot be read: $NEIGHBOUR_ERROR"; return 1; }
    else
      neighbour_settle "$NEIGHBOUR_DIR" "$NEIGHBOUR_COPY" "$NEIGHBOUR_REF" 0 || {
        case "$NEIGHBOUR_FAILED_STEP" in
          reading) NEIGHBOUR_ERROR="the copy $NEIGHBOUR_COPY cannot be read: $NEIGHBOUR_ERROR" ;;
          admission) NEIGHBOUR_ERROR="the copy $NEIGHBOUR_COPY cannot move to $NEIGHBOUR_REF, as another move of it waits for the checks that read it: $NEIGHBOUR_ERROR" ;;
          copy) NEIGHBOUR_ERROR="the copy $NEIGHBOUR_COPY cannot move to $NEIGHBOUR_REF, as a check still reads it: $NEIGHBOUR_ERROR" ;;
          state) NEIGHBOUR_ERROR="the freshness of $NEIGHBOUR_COPY cannot be established: $NEIGHBOUR_ERROR" ;;
          *) NEIGHBOUR_ERROR="the copy $NEIGHBOUR_COPY could not move to $NEIGHBOUR_REF: $NEIGHBOUR_ERROR" ;;
        esac
        return 1
      }
      [ "$NEIGHBOUR_STATE" != moved ] || NEIGHBOUR_MOVES="$NEIGHBOUR_MOVES$blocked $NEIGHBOUR_BEFORE"$'\n'
    fi
    neighbours_release
  done
}

# neighbours_release: gives up the locks neighbours_hold and neighbour_pending_begin took
neighbours_release() {
  local fd
  for fd in $NEIGHBOUR_FDS; do neighbour_unlock "$fd"; done
  NEIGHBOUR_FDS=""; NEIGHBOUR_PENDING=""
}
