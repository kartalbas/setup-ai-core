#!/usr/bin/env bash
# Stamp a worked-out order onto a board, so it is read top to bottom and the next thing to do
# is the next card down.
#
#   board-order.sh --project N < order.txt
#   board-order.sh --project N --dry-run < order.txt
#
# Input is one issue per line, `owner/repo#number`, in the order they should appear. Blank
# lines and lines starting with # are ignored, so the list can carry its own headings.
#
# WHY THIS EXISTS. Priority is not a sequence. P0 says a thing matters; it does not say which
# of the eleven P0 cards comes first, and a board of forty tickets in four priority buckets
# leaves the reader to re-derive the order every morning from dependencies he has to remember.
# The order is worked out once, when the plan is made, and then it lives where the work is
# read instead of in the conversation where it was decided.
#
# An issue named here that is not on this board is reported and skipped rather than added:
# putting it on the board is a decision about scope, and this is a script about sequence.
#
# The epics rule stands above this: every epic sits at the top of its column. So either list
# the epics first, or run epics-top.sh afterwards, which is idempotent.

set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/board.sh"

project_arg=""
dry_run=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project) need_value "$1" "${2-}"; project_arg="$2"; shift 2 ;;
    --dry-run) dry_run="yes"; shift ;;
    *)         die "unknown argument '$1'" ;;
  esac
done

set_project "$project_arg" >/dev/null

# The whole board once, rather than a lookup per line: forty lookups is forty round trips.
#
# Read into a variable first: a process substitution reports nothing about how the command inside
# it ended, so a refused query would leave the text empty and every line of the input would be
# reported as "not on this board".
items="$(board_items)" || exit 1
item_for() {  # item_for <repo#number>; the item id, or nothing when the card is not on the board
  printf '%s\n' "$items" | awk -F'\t' -v key="$1" '$2 "#" $3 == key { print $1; exit }'
}

wanted=()
while IFS= read -r line || [ -n "$line" ]; do
  line="$(printf '%s' "$line" | tr -d '\r' | sed 's/[[:space:]]*$//')"
  case "$line" in ''|'#'*) continue ;; esac
  wanted+=("$line")
done

[ ${#wanted[@]} -gt 0 ] || die "no issues on standard input"

# Applied last-to-first, because every move goes to the very top of the board's one order and
# the last card moved is the one that ends up first.
placed=0
missing=0
for (( i=${#wanted[@]}-1; i>=0; i-- )); do
  key="${wanted[$i]}"
  item="$(item_for "$key")"
  if [ -z "$item" ]; then
    echo "not on this board  $key" >&2
    missing=$(( missing + 1 ))
    continue
  fi
  if [ -n "$dry_run" ]; then
    placed=$(( placed + 1 ))
    continue
  fi
  gh api graphql -f pid="$(project_id)" -f iid="$item" -f query='
    mutation($pid:ID!, $iid:ID!) {
      updateProjectV2ItemPosition(input:{projectId:$pid, itemId:$iid}) {
        items { totalCount } } }' >/dev/null
  placed=$(( placed + 1 ))
done

if [ -n "$dry_run" ]; then
  echo "would order $placed card(s) on board $(project_number), $missing not on it"
else
  echo "ordered $placed card(s) on board $(project_number), $missing not on it"
fi
