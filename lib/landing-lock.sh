#!/usr/bin/env bash
# THE LANDING LOCK of a clone: one landing at a time runs its rounds there, whichever tracker it lands for. Source it, or run it as
#
#   landing-lock.sh take <dir> <pid> <issue> <branch>   waits for the lock, then writes it for process <pid>; its waiting lines go to
#                                                       standard error, and a refusal at the deadline to standard output, exit 1
#   landing-lock.sh release <dir> <pid>                 removes the lock where process <pid> wrote it, and records how long it held it
#
# Git fixes the old value of the remote branch when a push starts, before the gate runs, so a landing that moves the default
# branch while another one's gate runs makes the other's push refused, and its green gate is thrown away. The file
# ai-core-landing in the git directory of the clone, which every worktree of the clone shares, holds the process id, the issue,
# the branch, the time it was taken (epoch seconds) and the repository of the landing that owns it. A landing takes it before the
# fetch of a round and gives it up when its push ended or was refused, so the next round takes it again. A landing that finds it
# held names the holder, since when it holds the lock and when the deadline for that holder is, and waits; one whose holder no
# longer runs takes it over. The deadline counts per holder, from the moment that holder took the lock, so a waiter stops only
# when one holder has held the lock longer than the allowance, and the landing then stops with nothing pushed. The allowance is
# one and a half times the longest hold of the repository that the run log records, a row written when a landing gives the lock
# up; where none is recorded it is the sum of the bounds a holder may spend under the lock, which are configured and not measured.

. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
. "$(dirname "${BASH_SOURCE[0]}")/pre-push-runs.sh"
. "$(dirname "${BASH_SOURCE[0]}")/neighbours.sh"

# landing_lock_path <dir>: the lock file of the clone that holds <dir>
landing_lock_path() {
  local common
  common="$(git -C "${1:-.}" rev-parse --path-format=absolute --git-common-dir)" || return 1
  printf '%s/ai-core-landing\n' "$common"
}

# landing_lock_field <lock line> <number>: one tab-separated field, 1 process, 2 issue, 3 branch, 4 time taken, 5 repository
landing_lock_field() { printf '%s\n' "$1" | cut -f"$2"; }

# landing_lock_setting <dir> <reader> <key> <default>: sets LANDING_LOCK_VALUE to the whole number of seconds that <reader>
# (config_file_value or config_value) finds for <key> in the settings of <dir>; fails with LANDING_LOCK_REFUSAL where they cannot
# be read or say no number
LANDING_LOCK_VALUE=""
landing_lock_setting() {
  LANDING_LOCK_VALUE="$(cd "$1" && "$2" "$3" "$4")" || { LANDING_LOCK_REFUSAL="the settings of $1 cannot be read, so $3 is not known"; return 1; }
  case "$LANDING_LOCK_VALUE" in
    ''|*[!0-9]*) LANDING_LOCK_REFUSAL="$3 is '$LANDING_LOCK_VALUE' in the settings of $1; it is a whole number of seconds"; return 1 ;;
  esac
  [ "${#LANDING_LOCK_VALUE}" -le 9 ] || { LANDING_LOCK_REFUSAL="$3 is '$LANDING_LOCK_VALUE' in the settings of $1; it is a whole number of seconds up to 999999999"; return 1; }
}

# landing_lock_allowance <dir> <repository>: sets LANDING_LOCK_SECONDS, the seconds one holder may hold the lock before a wait for
# it ends, and LANDING_LOCK_BASIS, the words that say where that comes from. Measured, it is one and a half times the longest hold
# of the repository in the run log. Where none is recorded (no repository, no log, a log that cannot be read, no hold of it) it is
# configured: one and a half times the longest check of the repository on record, or NEIGHBOUR_INITIAL_CHECK_SECONDS where none is,
# plus the seconds the gate waits for the load (PRE_PUSH_LOAD_WAIT_SECONDS), plus, where the repository lands on CI
# (CI_GATE is public), the seconds the checks are waited for (AI_CORE_INTEGRATE_WAIT). Fails with LANDING_LOCK_REFUSAL where a setting
# is unreadable.
LANDING_LOCK_SECONDS=""; LANDING_LOCK_BASIS=""
landing_lock_allowance() {
  local log hold="" check="" reason ci_gate load wait base basis_check basis_ci=""
  log="$(gate_runs_file)"
  LANDING_LOCK_SECONDS=""; LANDING_LOCK_BASIS=""
  if [ -z "$2" ]; then reason="origin names no repository, so no hold of it is recorded"
  elif [ ! -e "$log" ]; then reason="no run log stands at $log yet"
  elif ! hold="$(gate_runs_repository_longest "$log" "$2" hold)" || ! check="$(gate_runs_repository_longest "$log" "$2" check)"; then
    hold=""; check=""; reason="the run log $log cannot be read"
  else reason="no hold of the landing lock of $2 is recorded in the last $GATE_RUNS_WINDOW_DAYS days of $log"; fi
  if [ -n "$hold" ]; then
    LANDING_LOCK_SECONDS=$(( (3 * hold + 1) / 2 ))
    LANDING_LOCK_BASIS="measured: one and a half times the $hold seconds of the longest hold of the landing lock of $2 in the last $GATE_RUNS_WINDOW_DAYS days of $log"
    return 0
  fi
  landing_lock_setting "$1" config_file_value PRE_PUSH_LOAD_WAIT_SECONDS 300 || return 1
  load="$LANDING_LOCK_VALUE"
  ci_gate="$(cd "$1" && config_file_value CI_GATE public)" || { LANDING_LOCK_REFUSAL="the settings of $1 cannot be read, so CI_GATE is not known"; return 1; }
  wait=0
  case "$(printf '%s' "$ci_gate" | tr '[:upper:]' '[:lower:]')" in
    public) landing_lock_setting "$1" config_value AI_CORE_INTEGRATE_WAIT 1800 || return 1
            wait="$LANDING_LOCK_VALUE"
            basis_ci=", AI_CORE_INTEGRATE_WAIT $wait because CI_GATE is public" ;;
    none) ;;
    *) LANDING_LOCK_REFUSAL="CI_GATE is '$ci_gate' in the settings of $1; it is public or none"; return 1 ;;
  esac
  base="${check:-$NEIGHBOUR_INITIAL_CHECK_SECONDS}"
  if [ -n "$check" ]; then basis_check="the $check seconds of the longest check of $2"
  else basis_check="the $NEIGHBOUR_INITIAL_CHECK_SECONDS seconds of NEIGHBOUR_INITIAL_CHECK_SECONDS, as no check of the repository is on record"; fi
  LANDING_LOCK_SECONDS=$(( (3 * base + 1) / 2 + load + wait ))
  LANDING_LOCK_BASIS="configured, not measured ($reason): one and a half times $basis_check, PRE_PUSH_LOAD_WAIT_SECONDS $load$basis_ci"
}

# landing_lock_holder_words <holder line>: who holds the lock, as the issue, then the branch where the lock names it
landing_lock_holder_words() {
  local issue branch
  issue="$(landing_lock_field "$1" 2)"; branch="$(landing_lock_field "$1" 3)"
  printf '%s' "${issue:-an unnamed landing}${branch:+ on $branch}"
}

# landing_lock_take <dir> <pid> <issue> <branch> [<repository>]: succeeds with the lock written for <pid>. Fails at the deadline
# with the words in LANDING_LOCK_REFUSAL, and where the lock cannot be written or the allowance cannot be set. A known limit: two
# waiters that find the same dead holder can both take over, and the push then still refuses the second, as it does without the
# lock; a holder's process id that an unrelated process took over keeps the lock held until the deadline for it.
LANDING_LOCK_REFUSAL=""
landing_lock_take() {
  local lock="$(landing_lock_path "$1")" pid="$2" issue="$3" branch="$4" repository="${5:-}"
  local missing=0 nameless=0 seen="" seen_at=0 holder holder_pid holder_since started now dead said since_words
  LANDING_LOCK_REFUSAL=""
  [ -n "$lock" ] || { LANDING_LOCK_REFUSAL="the git directory of $1 cannot be read, so the landing lock has no place"; return 1; }
  landing_lock_allowance "$1" "$repository" || return 1
  until said="$( (set -C; printf '%s\t%s\t%s\t%s\t%s\n' "$pid" "$issue" "$branch" "$(date +%s)" "$repository" > "$lock") 2>&1 )"; do
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
      now="$(date +%s)"
      holder_since="$(landing_lock_field "$holder" 4)"
      case "$holder_since" in ''|*[!0-9]*) holder_since="" ;; esac
      # A new holder starts its own count: the lock of an older version names no time, so it counts from the first sight of it
      if [ "$holder_pid:$holder_since" != "$seen" ]; then
        seen="$holder_pid:$holder_since"; seen_at="$now"
        started="${holder_since:-$seen_at}"
        since_words="since $(gate_runs_clock "$started")"
        [ -n "$holder_since" ] || since_words="$since_words (its lock names no time, so counted from now)"
        echo "waiting: $(landing_lock_holder_words "$holder") holds the lock $since_words (process $holder_pid); this one lands after it" >&2
        echo "deadline: $(gate_runs_clock $((started + LANDING_LOCK_SECONDS))) for this holder, $LANDING_LOCK_SECONDS seconds after it took the lock; $LANDING_LOCK_BASIS" >&2
      fi
      started="${holder_since:-$seen_at}"
      if [ $((now - started)) -gt "$LANDING_LOCK_SECONDS" ]; then
        LANDING_LOCK_REFUSAL="nothing landed: the landing lock is still held by $(landing_lock_holder_words "$holder") (process $holder_pid), which took it at $(gate_runs_clock "$started") and held it $((now - started)) seconds, longer than the $LANDING_LOCK_SECONDS seconds of its deadline ($LANDING_LOCK_BASIS); nothing was pushed. Run this again once that landing has ended"
        return 1
      fi
    fi
    sleep 2
  done
}

# landing_lock_release <dir> <pid>: the lock is removed only where process <pid> wrote it, and the seconds it was held are
# recorded in the run log for its repository, where the lock names the repository and the time. Fails, after the lock is
# removed, with the words where that record could not be made.
landing_lock_release() {
  local lock holder since repository now
  lock="$(landing_lock_path "$1")" || return 1
  holder="$(cat "$lock" 2>/dev/null)" || return 0
  [ "$(landing_lock_field "$holder" 1)" = "$2" ] || return 0
  rm -f "$lock"
  since="$(landing_lock_field "$holder" 4)"; repository="$(landing_lock_field "$holder" 5)"
  case "$since" in ''|*[!0-9]*) return 0 ;; esac
  [ -n "$repository" ] || return 0
  now="$(date +%s)"
  mkdir -p "$(dirname "$(gate_runs_file)")" 2>/dev/null \
    && gate_runs_append "$(printf '%s\t%s\t%s\t-\tlanding lock\t%s\t%s\t-' "$(gate_runs_clock "$now")" "$repository" "$(git -C "$1" rev-parse --show-toplevel)" \
      "$((now - since))" "$(landing_lock_holder_words "$holder" | tr '\t\n' '  ')")" \
    || { echo "the landing lock was released, but its hold of $((now - since)) seconds could not be recorded in $(gate_runs_file)" >&2; return 1; }
}

if [ "${BASH_SOURCE[0]}" = "${0:-}" ]; then
  set -uo pipefail
  case "${1:-}" in
    take)
      [ $# -eq 5 ] || { echo "usage: landing-lock.sh take <dir> <pid> <issue> <branch>" >&2; exit 2; }
      landing_lock_take "$2" "$3" "$4" "$5" "$(origin_repo "$2" 2>/dev/null || true)" || { echo "$LANDING_LOCK_REFUSAL"; exit 1; } ;;
    release) [ $# -eq 3 ] || { echo "usage: landing-lock.sh release <dir> <pid>" >&2; exit 2; }; landing_lock_release "$2" "$3" ;;
    *) echo "usage: landing-lock.sh take <dir> <pid> <issue> <branch> | release <dir> <pid>" >&2; exit 2 ;;
  esac
fi
