#!/usr/bin/env bash
# What is on the board right now, in column order: status, priority, repo, number, title.
#
#   board-list.sh                       everything, which is what the board is
#   board-list.sh Todo                  one column
#   board-list.sh Todo example-repo     one column of one repo
#   board-list.sh --project 5 Todo
#
# This is the check after a batch of changes - the board is the single source of truth
# for state, so reading it back is how a move is proven rather than assumed.
#
# Everything by default, because the board is shared - several people read the same project
# view, and a tool that hid what one of them does not work on would hide it from all of them.
# To narrow a shared view to a set of repos, use view-filter, which changes the view itself
# rather than one reader's output.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/board.sh"

project=""
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --project) need_value "$1" "${2-}"; project="$2"; shift 2 ;;
    -*)        die "unknown argument '$1'" ;;
    *)         args+=("$1"); shift ;;
  esac
done
set -- "${args[@]}"

want_status="${1:-}"
want_repo="${2:-}"

set_project "$project" >/dev/null
# A card of another organisation's repository is listed with its owner, so whoever reads the list,
# and status-sync after it, names that repository and not one of the board's organisation
org="$(project_org | tr '[:upper:]' '[:lower:]')"

board_card_lines "$org" \
| awk -F'\t' -v ws="$want_status" -v wr="$want_repo" \
      '(ws == "" || $1 == ws) && (wr == "" || $3 == wr)' \
| sort -t$'\t' -k1,1 -k2,2 -k3,3 -k4,4n \
| awk -F'\t' '{ printf "%-15s %-3s %-22s #%-4s %s%s\n", $1, $2, $3, $4, $5, ($6=="" ? "" : "  ["$6"]") }'
