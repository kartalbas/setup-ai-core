#!/usr/bin/env bash
# Put cards at the top of the board, in the order they are named.
#
#   item-top.sh [OWNER/REPO] NUMBER [NUMBER...]
#   item-top.sh --project 5 NUMBER [NUMBER...]
#
# The repo may be left out inside a checkout. The order the names arrive in is the order the
# cards end in: each one is moved directly under the card moved before it, and the first is
# moved above everything. Moving each to the top instead would hand back the names reversed -
# the one outcome nobody asking for this wants.
#
# epics-top.sh does the same act for every epic on a board, found by title. This one takes the
# numbers, for an order somebody worked out.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/board.sh"

usage='usage: item-top.sh [OWNER/REPO] [--project N] NUMBER [NUMBER...]'
[ $# -ge 1 ] || die "$usage"

project=""
numbers=()
while [ $# -gt 0 ]; do
  case "$1" in
    --project) need_value "$1" "${2-}"; project="$2"; shift 2 ;;
    -*)        die "unknown argument '$1'" ;;
    *)         numbers+=("$1"); shift ;;
  esac
done

[ ${#numbers[@]} -ge 1 ] || die "$usage"

repo="$(resolve_repo "${numbers[0]}")" || exit 1
case "${numbers[0]}" in */*) numbers=("${numbers[@]:1}") ;; esac
[ ${#numbers[@]} -ge 1 ] || die "$usage"
for n in "${numbers[@]}"; do
  case "$n" in ''|*[!0-9]*) die "the issue number must be numeric, not '$n'" ;; esac
done

set_project "$project" "$repo" >/dev/null

under=""
for n in "${numbers[@]}"; do
  item="$(item_id "$repo" "$n")" || exit 1
  item_top "$item" "$under"
  under="$item"
  echo "#$n -> top"
done
