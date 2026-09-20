#!/usr/bin/env bash
# Move a card. The board's Status is the only place a state is recorded, so this
# is how a ticket travels from one column to the next.
#
#   issue-status.sh [--project N] [OWNER/REPO] NUMBER [NUMBER...] STATUS
#
# The repo may be left out inside a checkout. The status is the last argument, so a
# whole batch moves in one call:
#   issue-status.sh 2 3 4 implementing
#
# THE COLUMN NAMES ARE THE BOARD'S OWN, not a list kept here. They are matched without
# case, and a name matching none stops the run and prints the ones the board carries -
# so a column renamed on the board is a refusal here rather than a card that silently
# does not move. Measured on 2026-08-26, boards 6 and 7 both carry: backlog todo
# implementing testing done.

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

[ $# -ge 2 ] || die "usage: issue-status.sh [--project N] [OWNER/REPO] NUMBER [NUMBER...] STATUS"

repo="$(resolve_repo "$1")"; case "$1" in */*) shift ;; esac
set_project "$project" "$repo" >/dev/null
status="${!#}"                 # last argument
nums=("${@:1:$(($#-1))}")

# THE CARD IS RESOLVED BEFORE THE MUTATION. Written as an argument to set_select, a card that could
# not be resolved leaves an EMPTY value behind - a failed command substitution does not stop the
# command it stands in - and the move goes ahead with it, so a person reads this tool's refusal and
# then a second complaint from gh about an item id that belongs to nothing.
for n in "${nums[@]}"; do
  case "$n" in ''|*[!0-9]*) die "the issue number must be numeric, not '$n'" ;; esac
  item="$(item_id "$repo" "$n")" || exit 1
  set_select "$item" Status "$status"
  echo "#$n -> $status"
done
