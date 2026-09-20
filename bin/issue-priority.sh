#!/usr/bin/env bash
# Set the board Priority: P0 blocker, P1 high, P2 normal, P3 low, P9 parked.
#
#   issue-priority.sh [--project N] [OWNER/REPO] NUMBER [NUMBER...] PRIORITY
#
# The repo may be left out inside a checkout.

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

[ $# -ge 2 ] || die "usage: issue-priority.sh [--project N] [OWNER/REPO] NUMBER [NUMBER...] PRIORITY"

repo="$(resolve_repo "$1")"; case "$1" in */*) shift ;; esac
set_project "$project" "$repo" >/dev/null
priority="${!#}"
nums=("${@:1:$(($#-1))}")

# THE CARD IS RESOLVED BEFORE THE MUTATION. Written as an argument to set_select, a card that could
# not be resolved leaves an EMPTY value behind - a failed command substitution does not stop the
# command it stands in - and the move goes ahead with it, so a person reads this tool's refusal and
# then a second complaint from gh about an item id that belongs to nothing.
for n in "${nums[@]}"; do
  case "$n" in ''|*[!0-9]*) die "the issue number must be numeric, not '$n'" ;; esac
  item="$(item_id "$repo" "$n")" || exit 1
  set_select "$item" Priority "$priority"
  echo "#$n -> $priority"
done
