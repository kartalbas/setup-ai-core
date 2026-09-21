#!/usr/bin/env bash
# Lift every epic to the top of the board, above every ordinary ticket.
#
#   epics-top.sh                  the board the current directory's repo is linked to
#   epics-top.sh --project N      a named board
#   epics-top.sh --dry-run        print what would move, change nothing
#
# A board column has more rows than fit on a screen, and it is read from the top. An epic
# scrolled below the fold is an epic nobody sees, and with it goes the only thing that says
# which of the tickets underneath belong together. Priority orders the WORK; an epic is not
# work, it is the heading the work stands under, so it is not sorted in among it.
#
# An epic is recognised by its title, which is how a reader recognises one too: the
# convention is `EPIC · <what it covers>`. Nothing else on the board carries that prefix.
#
# The board keeps ONE order for all its items and every view honours it within whatever it
# groups by, so lifting an item to the top of that order puts it at the top of its column
# whichever column it currently stands in. `updateProjectV2ItemPosition` with no `afterId`
# means the top; the epics are therefore moved in reverse, so the first one listed ends up
# first on the board.

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

# Title comes from the issue, not from the board: the board carries no title field, and an
# epic is an epic because of what its issue says.
#
# The board is read into a variable first, and a title that cannot be read STOPS the run. Both were
# swallowed before: a process substitution reports nothing about how the command inside it ended,
# and a title read with the error hidden comes back empty, matches no epic prefix, and leaves the
# epic where it was - so a refused query ended with "epics: none on this board".
items="$(board_items)" || exit 1
epics=""
while IFS=$'\t' read -r item repo number; do
  [ -n "$item" ] || continue
  title="$(gh_read "the title of $repo#$number" issue view "$number" --repo "$repo" --json title --jq '.title')" || exit 1
  case "$title" in
    "EPIC · "*|"EPIC "*|"EPIC:"*) epics="$epics$item"$'\t'"$repo"$'\t'"$number"$'\t'"$title"$'\n' ;;
  esac
done <<< "$items"

[ -n "$epics" ] || { echo "epics: none on this board"; exit 0; }

count="$(printf '%s' "$epics" | grep -c .)"

# Reversed, because each move goes to the very top and the last one moved wins the top slot.
printf '%s' "$epics" | awk '{ line[NR] = $0 } END { for (i = NR; i > 0; i--) print line[i] }' \
  | while IFS=$'\t' read -r item repo number title; do
  if [ -n "$dry_run" ]; then
    echo "would lift  $repo#$number  $title"
    continue
  fi
  gh api graphql -f pid="$(project_id)" -f iid="$item" -f query='
    mutation($pid:ID!, $iid:ID!) {
      updateProjectV2ItemPosition(input:{projectId:$pid, itemId:$iid}) {
        items { totalCount } } }' >/dev/null
  echo "lifted      $repo#$number  $title"
done

[ -n "$dry_run" ] || echo "epics: $count at the top of board $(project_number)"
