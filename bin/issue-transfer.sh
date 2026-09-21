#!/usr/bin/env bash
# Transfer an issue to another repository.
#
#   issue-transfer.sh [OWNER/REPO] NUMBER TARGET_REPO
#
# The repo may be left out inside a checkout. The card is NOT moved with the issue: the
# target repository resolves to its own board, and which board the work belongs on after a
# transfer is a decision, not a consequence. board-sync puts it on the right one, or
# item-move carries it across explicitly.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/board.sh"

usage='usage: issue-transfer.sh [OWNER/REPO] NUMBER TARGET_REPO'
reject_options "$@"
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

gh_read "the transfer of $repo#$number to $target_repo" issue transfer "$number" "$target_repo" --repo "$repo"
