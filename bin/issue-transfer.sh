#!/usr/bin/env bash
# Transfer an issue to another repository, or carry it into Plane.
#
#   issue-transfer.sh [OWNER/REPO] NUMBER TARGET_REPO
#   issue-transfer.sh [OWNER/REPO] NUMBER --to plane
#   issue-transfer.sh [OWNER/REPO] --column NAME --to plane
#
# The repo may be left out inside a checkout. The card is NOT moved with the issue: the
# target repository resolves to its own board, and which board the work belongs on after a
# transfer is a decision, not a consequence. board-sync puts it on the right one, or
# item-move carries it across explicitly.
#
# --to plane carries issues from GitHub into Plane and changes nothing on GitHub: no comment, no close.
#   issue-transfer.sh --to plane          every issue, open and closed, of every repository of the organisation that is
#                                         not archived, with its comments, close reason, board memberships (archived
#                                         ones too), parent and assignee, and every board, into the Plane project each
#                                         repository's clone is set up for (PLANE_URL, PLANE_WORKSPACE, PLANE_PROJECT,
#                                         PLANE_TOKEN_COMMAND of that clone); run it in the project folder
#   issue-transfer.sh NUMBER --to plane   one issue of this checkout's repository
#   issue-transfer.sh --column NAME --to plane
#                                         every open issue whose card stands in that column of the repository's board
# The assignee that is carried is the account that runs the carry, as the user of the Plane key; the report names every other
# login with its issue, and the work item gets none for it.
# The counts and the bound on the requests are printed before the first write. A rerun writes nothing that stands in
# Plane already and finishes what an earlier run left; what a person changed in Plane is never written back. Every
# issue left incomplete is named, and the exit status is non-zero then.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/board.sh"

usage='usage: issue-transfer.sh [OWNER/REPO] NUMBER TARGET_REPO | --to plane | [OWNER/REPO] NUMBER --to plane | [OWNER/REPO] --column NAME --to plane'
to=""; column=""; args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --to)     need_value "$@"; to="$2"; shift 2 ;;
    --column) need_value "$@"; column="$2"; shift 2 ;;
    -*)       die "unknown argument '$1'" ;;
    *)        args+=("$1"); shift ;;
  esac
done
[ -z "$column" ] || [ -n "$to" ] || die "--column goes with --to plane: $usage"
[ -z "$to" ] || [ "$to" = plane ] || die "--to takes plane, not '$to'"

if [ -n "$to" ]; then
  [ ${#args[@]} -le 2 ] || die "$usage"
  repo=""; number=""
  case "${args[0]:-}" in */*) repo="${args[0]}"; args=("${args[@]:1}") ;; esac
  if [ -n "$column" ]; then
    [ ${#args[@]} -eq 0 ] || die "--column carries a column, not a number: $usage"
  elif [ -n "$repo" ] || [ ${#args[@]} -gt 0 ]; then
    [ ${#args[@]} -eq 1 ] || die "$usage"
    number="${args[0]}"
    case "$number" in ''|*[!0-9]*) die "the issue number must be numeric, not '$number'" ;; esac
  fi
  if [ -n "$number" ] || [ -n "$column" ]; then repo="$(resolve_repo "$repo")" || exit 1; fi
  . "$HARNESS_ROOT/lib/carry.sh"
  carry_run "$repo" "$number" "$column"
  exit $?
fi

set -- ${args[@]+"${args[@]}"}
[ $# -ge 2 ] || die "$usage"

if [ $# -eq 2 ]; then
  repo="$(resolve_repo "")" || exit 1
  number="$1"
  target_repo="$2"
else
  repo="$(resolve_repo "$1")" || exit 1
  number="$2"
  target_repo="$3"
fi

case "$number" in ''|*[!0-9]*) die "the issue number must be numeric, not '$number'" ;; esac
[[ "$target_repo" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || die "the target repository must be named OWNER/REPO"

issue_transfer "$repo" "$number" "$target_repo"
