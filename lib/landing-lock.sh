#!/usr/bin/env bash
# THE LANDING LOCK of a clone: one landing at a time runs its rounds there, whichever tracker it lands for. Source it, or run it as
#
#   landing-lock.sh take <dir> <pid> <issue> <branch>   waits for the lock, then writes it for process <pid>; fails at the deadline
#   landing-lock.sh release <dir> <pid>                 removes the lock where process <pid> wrote it
#
# Git fixes the old value of the remote branch when a push starts, before the gate runs, so a landing that moves the default
# branch while another one's gate runs makes the other's push refused, and its green gate is thrown away. The file
# ai-core-landing in the git directory of the clone, which every worktree of the clone shares, holds the process id, the issue and
# the branch of the landing that owns it. A landing takes it before the fetch of a round and gives it up when its push ended or
# was refused, so the next round takes it again. A landing that finds it held names the issue and branch that hold it and waits;
# one whose holder no longer runs takes it over. The wait ends at a deadline: one and a half times the longest check of the
# repository that the run log records, or none where no check of it is recorded, and the landing then stops with nothing pushed.

. "$(dirname "${BASH_SOURCE[0]}")/pre-push-runs.sh"

# landing_lock_path <dir>: the lock file of the clone that holds <dir>
landing_lock_path() {
  local common
  common="$(git -C "${1:-.}" rev-parse --path-format=absolute --git-common-dir)" || return 1
  printf '%s/ai-core-landing\n' "$common"
}

# landing_lock_allowance <repository>: sets LANDING_LOCK_SECONDS, the seconds a wait lasts at most, empty where it has no
# deadline, and LANDING_LOCK_BASIS, the words that say where that comes from
LANDING_LOCK_SECONDS=""; LANDING_LOCK_BASIS=""
landing_lock_allowance() {
  local log longest
  LANDING_LOCK_SECONDS=""
  log="$(gate_runs_file)"
  if [ -z "$1" ]; then LANDING_LOCK_BASIS="origin names no repository, so no gate of it is measured"
  elif [ ! -e "$log" ]; then LANDING_LOCK_BASIS="no run log stands at $log yet"
  elif ! longest="$(gate_runs_repository_longest "$log" "$1")"; then LANDING_LOCK_BASIS="the run log $log cannot be read"
  elif [ -z "$longest" ]; then LANDING_LOCK_BASIS="no check of $1 is recorded in the last $GATE_RUNS_WINDOW_DAYS days of $log"
  else
    LANDING_LOCK_SECONDS=$(( (3 * longest + 1) / 2 ))
    LANDING_LOCK_BASIS="one and a half times the $longest seconds of the longest check of $1 in the last $GATE_RUNS_WINDOW_DAYS days of $log"
  fi
}

# landing_lock_holder_words <holder line>: who holds the lock, as the issue, then the branch where the lock names it
landing_lock_holder_words() {
  local issue branch
  IFS=$'\t' read -r _ issue branch <<< "$1"
  printf '%s' "${issue:-an unnamed landing}${branch:+ on $branch}"
}

# landing_lock_take <dir> <pid> <issue> <branch> [<repository>]: succeeds with the lock written for <pid>. Fails at the deadline
# with the words in LANDING_LOCK_REFUSAL, and where the lock cannot be written. A known limit: two waiters that find the same dead
# holder can both take over, and the push then still refuses the second, as it does without the lock; a holder's process id that
# an unrelated process took over keeps the lock held, and the waiting line names that process.
LANDING_LOCK_REFUSAL=""
landing_lock_take() {
  local lock="$(landing_lock_path "$1")" pid="$2" issue="$3" branch="$4" repository="${5:-}"
  local waited="" missing=0 nameless=0 holder holder_pid dead said began now
  LANDING_LOCK_REFUSAL=""
  [ -n "$lock" ] || { LANDING_LOCK_REFUSAL="the git directory of $1 cannot be read, so the landing lock has no place"; return 1; }
  landing_lock_allowance "$repository"
  began="$(date +%s)"
  until said="$( (set -C; printf '%s\t%s\t%s\n' "$pid" "$issue" "$branch" > "$lock") 2>&1 )"; do
    # Gone between the two steps is a lock just released; gone twice in a row, one never written
    if ! holder="$(cat "$lock" 2>/dev/null)"; then
      missing=$((missing + 1))
      [ "$missing" -lt 2 ] || { LANDING_LOCK_REFUSAL="the landing lock $lock could not be written: $said"; return 1; }
      continue
    fi
    missing=0; holder_pid="${holder%%$'\t'*}"
    # A lock still without its process id after the poll was never finished: nobody holds it
    dead=""
    case "$holder_pid" in
      ''|*[!0-9]*) nameless=$((nameless + 1)); [ "$nameless" -lt 2 ] || dead="a landing lock that names no process: '$holder'" ;;
      *) nameless=0; ps -p "$holder_pid" >/dev/null 2>&1 || dead="the landing lock of $(landing_lock_holder_words "$holder"), whose process $holder_pid no longer runs" ;;
    esac
    if [ -n "$dead" ]; then
      rm -f "$lock" || { LANDING_LOCK_REFUSAL="the landing lock $lock could not be removed: $dead"; return 1; }
      echo "taken over: $dead" >&2; nameless=0; continue
    fi
    if [ "$nameless" -eq 0 ]; then
      if [ -z "$waited" ]; then
        waited=1
        echo "waiting: $(landing_lock_holder_words "$holder") is landing from this clone (process $holder_pid); this one lands after it" >&2
        if [ -n "$LANDING_LOCK_SECONDS" ]; then echo "deadline: ${LANDING_LOCK_SECONDS} seconds, $LANDING_LOCK_BASIS" >&2
        else echo "deadline: none, because $LANDING_LOCK_BASIS" >&2; fi
      fi
      now="$(date +%s)"
      if [ -n "$LANDING_LOCK_SECONDS" ] && [ $((now - began)) -ge "$LANDING_LOCK_SECONDS" ]; then
        LANDING_LOCK_REFUSAL="nothing landed: the landing lock is still held by $(landing_lock_holder_words "$holder") (process $holder_pid) after $((now - began)) seconds, the deadline of $LANDING_LOCK_BASIS; nothing was pushed. Run this again once that landing has ended"
        return 1
      fi
    fi
    sleep 2
  done
}

# landing_lock_release <dir> <pid>: the lock is removed only where process <pid> wrote it
landing_lock_release() {
  local lock
  lock="$(landing_lock_path "$1")" || return 1
  [ "$(cut -f1 "$lock" 2>/dev/null)" != "$2" ] || rm -f "$lock"
}

if [ "${BASH_SOURCE[0]}" = "${0:-}" ]; then
  set -uo pipefail
  case "${1:-}" in
    take)
      [ $# -eq 5 ] || { echo "usage: landing-lock.sh take <dir> <pid> <issue> <branch>" >&2; exit 2; }
      . "$(dirname "${BASH_SOURCE[0]}")/common.sh"
      landing_lock_take "$2" "$3" "$4" "$5" "$(origin_repo "$2" 2>/dev/null || true)" || { echo "$LANDING_LOCK_REFUSAL" >&2; exit 1; } ;;
    release) [ $# -eq 3 ] || { echo "usage: landing-lock.sh release <dir> <pid>" >&2; exit 2; }; landing_lock_release "$2" "$3" ;;
    *) echo "usage: landing-lock.sh take <dir> <pid> <issue> <branch> | release <dir> <pid>" >&2; exit 2 ;;
  esac
fi
