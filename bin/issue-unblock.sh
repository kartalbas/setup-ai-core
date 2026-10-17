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

issue_unblock "$blocked_repo" "$blocked_num" "$by_repo" "$by_num"
echo "$blocked_repo#$blocked_num is no longer blocked by $by_repo#$by_num"
