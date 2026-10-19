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
# --to plane carries a GitHub issue, or every open issue whose card stands in the column NAME of the
# repository's board, into the Plane project this checkout is set up for (PLANE_URL, PLANE_WORKSPACE,
# PLANE_PROJECT, PLANE_TOKEN_COMMAND). Each becomes a work item with its title, body, labels, priority,
# state named after the column and parent, and the GitHub issue is closed as not planned with a comment
# that carries the work item's address. The GitHub side is read, and closed, by one process with
# TRACKER=github and the Plane side written by another with TRACKER=plane. An issue carried before is
# found again by its external_id and writes nothing to Plane, and finishes a GitHub close that failed; a sub-issue whose
# parent is not carried is refused by name, the rest of the selection goes on, and the exit status is non-zero when
# anything was refused.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/board.sh"

usage='usage: issue-transfer.sh [OWNER/REPO] NUMBER TARGET_REPO | [OWNER/REPO] NUMBER --to plane | [OWNER/REPO] --column NAME --to plane'
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
  repo="$(resolve_repo "$repo")" || exit 1
  if [ -n "$column" ]; then
    [ ${#args[@]} -eq 0 ] || die "--column carries a column, not a number: $usage"
  else
    [ ${#args[@]} -eq 1 ] || die "$usage"
    number="${args[0]}"
    case "$number" in ''|*[!0-9]*) die "the issue number must be numeric, not '$number'" ;; esac
  fi
  in_tracker() {  # in_tracker <tracker> <function> [argument...]: a function of that tracker's provider, in a process of its own
    TRACKER="$1" bash -c '. "$1/lib/board.sh"; shift; "$@"' _ "$HARNESS_ROOT" "${@:2}"
  }
  rows="$(in_tracker github github_carry_rows "$repo" "$number" "$column")" || exit 1
  [ -n "$rows" ] || { echo "nothing is left to carry: no open issue of $repo is selected"; exit 0; }
  refused=0
  while IFS= read -r row; do
    n="$(jq -r '.number' <<< "$row")"
    if ! carried="$(printf '%s\n' "$row" | in_tracker plane plane_carry "$repo")"; then refused=1; continue; fi
    echo "#$n -> ${carried%%$'\t'*}"
    [ "$(jq -r '.open' <<< "$row")" = true ] || continue
    link="${carried#*$'\t'}"
    # a close that failed after its comment leaves the comment: the rerun posts it once
    if ! jq -e --arg u "$link" 'any(.comments[]; contains($u))' <<< "$row" >/dev/null; then
      text="Moved to $link"
      in_tracker github check_public_body issue-transfer "$repo" "$text" "" || { refused=1; continue; }
      in_tracker github issue_comment_post "$repo" "$n" "$text" "" >/dev/null || { refused=1; continue; }
    fi
    in_tracker github issue_close "$repo" "$n" not-planned || refused=1
  done <<< "$rows"
  exit "$refused"
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
