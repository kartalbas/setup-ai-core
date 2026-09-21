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

# THE ENDPOINT'S REPO IS THE BLOCKED ISSUE'S and the id is the BLOCKER's database id -
# resolved BEFORE the call, so an id that could not be read stops the run instead of being
# posted as an empty one.
by_id="$(issue_db_id "$by_repo" "$by_num")" || exit 1
if ! answer="$(gh api --method POST "repos/$blocked_repo/issues/$blocked_num/dependencies/blocked_by" \
      -F issue_id="$by_id" 2>&1)"; then
  case "$answer" in
    *422*) die "$blocked_repo#$blocked_num is already blocked by $by_repo#$by_num - nothing was changed" ;;
    *404*) die "an issue was not found - check OWNER/REPO and the numbers on both sides" ;;
    *)     die "$answer" ;;
  esac
fi
echo "$blocked_repo#$blocked_num is blocked by $by_repo#$by_num"
