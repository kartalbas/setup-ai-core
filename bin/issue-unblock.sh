#!/usr/bin/env bash
# Clear a `blocked by` dependency between two issues, across repositories.
#
#   issue-unblock.sh BLOCKED_REPO BLOCKED_NUMBER BY_REPO BY_NUMBER
#
# The mirror of issue-block.sh, and it exists for the same reason that one does: a
# dependency somebody recorded by hand is one nobody can clear by hand, and a stale
# blocker is worse than none - it holds work off the board that nothing is actually
# waiting for.
#
# A refusal is answered with what to do next: a dependency that is not there says so and
# changes nothing, and a missing endpoint names what to check.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/board.sh"

usage='usage: issue-unblock.sh BLOCKED_REPO BLOCKED_NUMBER BY_REPO BY_NUMBER'
reject_options "$@"
[ $# -eq 4 ] || die "$usage"

blocked_repo="$1"; blocked_num="$2"; by_repo="$3"; by_num="$4"
[[ "$blocked_repo" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || die "the blocked issue's repository must be named OWNER/REPO"
[[ "$by_repo" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || die "the blocking issue's repository must be named OWNER/REPO"
case "$blocked_num" in ''|*[!0-9]*) die "the blocked issue number must be numeric, not '$blocked_num'" ;; esac
case "$by_num" in ''|*[!0-9]*) die "the blocking issue number must be numeric, not '$by_num'" ;; esac

# THE ENDPOINT'S REPO IS THE BLOCKED ISSUE'S and the id is the BLOCKER's database id -
# resolved BEFORE the call, in the shape the POST takes, so the two scripts cannot come to
# disagree about which side of the relationship is addressed.
by_id="$(issue_db_id "$by_repo" "$by_num")" || exit 1
if ! answer="$(gh api --method DELETE "repos/$blocked_repo/issues/$blocked_num/dependencies/blocked_by/$by_id" 2>&1)"; then
  case "$answer" in
    *404*) die "$blocked_repo#$blocked_num is not blocked by $by_repo#$by_num - nothing was changed" ;;
    *)     die "$answer" ;;
  esac
fi
echo "$blocked_repo#$blocked_num is no longer blocked by $by_repo#$by_num"
