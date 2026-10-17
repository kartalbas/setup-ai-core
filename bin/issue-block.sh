#!/usr/bin/env bash
# Mark an existing issue as blocked by another existing issue, across repositories.
#
#   issue-block.sh BLOCKED_REPO BLOCKED_NUMBER BY_REPO BY_NUMBER
#
# Both issues are named by repository and number; the ids are resolved here and never
# stored. The relationship is GitHub's own `blocked by` - the thing the board and the
# REST surface expose - and not a sentence in a body, which nothing could query or clear.
#
# A refusal is answered with what to do next: a dependency that already exists says so
# and changes nothing, and a missing endpoint names what to check.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/board.sh"

usage='usage: issue-block.sh BLOCKED_REPO BLOCKED_NUMBER BY_REPO BY_NUMBER'
reject_options "$@"
[ $# -eq 4 ] || die "$usage"

blocked_repo="$1"; blocked_num="$2"; by_repo="$3"; by_num="$4"
[[ "$blocked_repo" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || die "the blocked issue's repository must be named OWNER/REPO"
[[ "$by_repo" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || die "the blocking issue's repository must be named OWNER/REPO"
case "$blocked_num" in ''|*[!0-9]*) die "the blocked issue number must be numeric, not '$blocked_num'" ;; esac
case "$by_num" in ''|*[!0-9]*) die "the blocking issue number must be numeric, not '$by_num'" ;; esac

issue_block "$blocked_repo" "$blocked_num" "$by_repo" "$by_num"
echo "$blocked_repo#$blocked_num is blocked by $by_repo#$by_num"
