#!/usr/bin/env bash
# Close issues as completed (the default) or as not planned, and put their board cards in done.
#
#   issue-close.sh [OWNER/REPO] NUMBER [NUMBER...]
#   issue-close.sh [OWNER/REPO] --reason not-planned NUMBER
#
# The repo may be left out inside a checkout. A superseded or rejected design closes as
# not planned; recording it as completed says work shipped when it did not.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/board.sh"

usage='usage: issue-close.sh [OWNER/REPO] [--reason completed|not-planned] NUMBER [NUMBER...]'
[ $# -ge 1 ] || die "$usage"

reason="completed"
numbers=()
while [ $# -gt 0 ]; do
  case "$1" in
    --reason)   need_value "$1" "${2-}"; reason="$2"; shift 2 ;;
    --reason=*) reason="${1#--reason=}"; shift ;;
    -*)         die "unknown argument '$1'" ;;
    *)          numbers+=("$1"); shift ;;
  esac
done

case "$reason" in
  completed|not-planned) ;;
  *) die "--reason must be completed or not-planned, not '$reason'" ;;
esac

[ ${#numbers[@]} -ge 1 ] || die "$usage"

repo="$(resolve_repo "${numbers[0]}")" || exit 1
case "${numbers[0]}" in */*) numbers=("${numbers[@]:1}") ;; esac
[ ${#numbers[@]} -ge 1 ] || die "$usage"
for n in "${numbers[@]}"; do
  case "$n" in ''|*[!0-9]*) die "the issue number must be numeric, not '$n'" ;; esac
done

# The column of the card is the provider's for the reason: done, except where the board has a column of its own for
# an issue closed as not planned
column="$(closing_column "$reason")" || exit 1

# The close is reported on its own line and each board on its own after it: the issue is
# closed ONCE, but its cards are plural - a sub-issue of a cross-repository epic sits on two
# boards, and one line saying "closed, done" about one of them is false about the other.
for n in "${numbers[@]}"; do
  issue_close "$repo" "$n" "$reason"
  echo "#$n -> closed"
  for_each_board "$repo" "$n" Status "$column" "$column"
  update_parent_epic "$repo" "$n" || exit 1
done
