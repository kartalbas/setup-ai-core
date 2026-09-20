#!/usr/bin/env bash
# Bring archived cards back into view.
#
#   board-unarchive.sh [--project N]                every archived card of the board
#   board-unarchive.sh [--project N] OWNER/REPO NUMBER [NUMBER...]
#
# NOTHING ON THIS BOARD IS EVER ARCHIVED — closed items stay in view, because a
# board is read to see what was done as much as what is left. GitHub ships a
# built-in workflow that archives an item the moment its issue closes, and where
# that workflow is on, every card this tooling moves to Done disappears from the
# column it was just put in. This is how they come back.
#
# THE WORKFLOW ITSELF IS NOT SCRIPTABLE. Projects' built-in workflows have no API,
# and turning "auto-archive items" off, where the workflow is what did it, is a thing a person does once in the board's
# settings. Until that happens this script is a broom, and a broom is not a fix:
# it reports how many it swept so the number itself says whether the workflow is
# still on.

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

unarchive() {  # unarchive <item id>
  gh api graphql -f pid="$(project_id)" -f iid="$1" -f query='
    mutation($pid:ID!, $iid:ID!) {
      unarchiveProjectV2Item(input:{projectId:$pid, itemId:$iid}) { item { id } } }' \
    --jq '.data.unarchiveProjectV2Item.item.id' >/dev/null
}

if [ $# -ge 2 ]; then
  repo="$(resolve_repo "$1")"; case "$1" in */*) shift ;; esac
  set_project "$project" "$repo" >/dev/null
  for n in "$@"; do
    case "$n" in ''|*[!0-9]*) die "the issue number must be numeric, not '$n'" ;; esac
    id="$(archived_item_id "$repo" "$n")" || exit 1
    if [ -z "$id" ]; then echo "#$n is not archived"; continue; fi
    unarchive "$id"
    echo "#$n -> back on the board"
  done
  exit 0
fi

# The whole board: every repository linked to it, every archived item of each.
here="$(default_repo)" || exit 1
set_project "$project" "$here" >/dev/null
swept=0
# Both lists are read into a variable first. A command substitution in a `for` list reports nothing
# about how the command ended, so a refused query would come out as a board with no repos, or a
# repo with no closed issues, and the run would end with "0 card(s) brought back".
linked="$(project_repos)" || exit 1
for repo in $linked; do
  closed="$(gh_read "the closed issues of $repo" issue list --repo "$repo" --state closed --limit 200 \
             --json number --jq '.[].number')" || exit 1
  for n in $closed; do
    id="$(archived_item_id "$repo" "$n")" || exit 1
    [ -n "$id" ] || continue
    unarchive "$id"
    echo "  $repo#$n -> back on the board"
    swept=$((swept + 1))
  done
done
echo "$swept card(s) brought back. That is how many WERE archived, and it does not say by what: a person archives a card and so does the board's auto-archive workflow, and a count cannot tell the two apart. If they go again on the next close, the workflow is on."
