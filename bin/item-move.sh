#!/usr/bin/env bash
# Move a repository's cards from one board to another, keeping Status and Priority.
#
#   item-move.sh --repo OWNER/REPO --from [ORG/]N --to [ORG/]M [--dry-run]
#
# A bare board number is a board of the repository's own organisation; ORG/N names another
# organisation's board, which is where a card stands when it was filed on the wrong one.
#
# Unlinking a repository from a project does NOT take its cards off that project. The link decides
# which repositories a project may draw new items from and where the project appears in a repo's own
# Projects tab; a card already added is an object of its own and stays until it is removed. So a
# repository that has moved to its own board leaves its whole history behind on the old one, where it
# reads as work of that board's team. There are two boards here - 6 beta and 7 alpha - and a
# repository that changes hands between them is exactly this call.
#
# Moving is add-then-remove, in that order. Field values do not travel with a card - the target board
# has its own fields and its own option ids - so Status and Priority are read off the source card and
# written onto the new one. A value the target board has no option for is reported and left unset
# rather than mapped onto the nearest one, because a card in the wrong column is a lie the board then
# tells everyone.
#
# The issue itself is never touched: no label, no state, no comment.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/board.sh"

usage='usage: item-move.sh --repo OWNER/REPO --from N --to M [--dry-run]'

repo=""; from=""; to=""; dry=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)    need_value "$1" "${2-}"; repo="$2"; shift 2 ;;
    --from)    need_value "$1" "${2-}"; from="$2"; shift 2 ;;
    --to)      need_value "$1" "${2-}"; to="$2";   shift 2 ;;
    --dry-run) dry="1";   shift ;;
    *) die "unknown argument '$1'" ;;
  esac
done

[ -n "$repo" ] || die "$usage"
[ -n "$from" ] && [ -n "$to" ] || die "both --from and --to are required"
[ "$from" != "$to" ] || die "--from and --to are the same project"
[[ "$repo" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || die "--repo takes OWNER/REPO, not '$repo'"

# Every card of this repository on the source board, with the two values worth carrying.
# One page of 100 does not cover a board that has run for a while, so this pages.
cards_of() {  # cards_of <owner/repo>
  local after="" page
  while :; do
    if [ -n "$after" ]; then
      page="$(gh_read "the cards of board $(project_number) after $after" api graphql -f pid="$(project_id)" -f after="$after" -f query='
        query($pid:ID!, $after:String) { node(id:$pid) { ... on ProjectV2 {
          items(first:100, after:$after) { pageInfo { hasNextPage endCursor }
            nodes { id
              content { ... on Issue { number repository { nameWithOwner } } }
              fieldValues(first:20) { nodes { ... on ProjectV2ItemFieldSingleSelectValue {
                name field { ... on ProjectV2SingleSelectField { name } } } } } } } } } }')" || exit 1
    else
      page="$(gh_read "the cards of board $(project_number)" api graphql -f pid="$(project_id)" -f query='
        query($pid:ID!) { node(id:$pid) { ... on ProjectV2 {
          items(first:100) { pageInfo { hasNextPage endCursor }
            nodes { id
              content { ... on Issue { number repository { nameWithOwner } } }
              fieldValues(first:20) { nodes { ... on ProjectV2ItemFieldSingleSelectValue {
                name field { ... on ProjectV2SingleSelectField { name } } } } } } } } } }')" || exit 1
    fi
    # The carriage return is stripped here for the same reason board_items strips it: this is
    # the jq BINARY rather than gh's own --jq, and on Windows that binary writes CRLF.
    printf '%s' "$page" | jq -r --arg r "$1" '
      .data.node.items.nodes[]
      | select(.content.number != null and .content.repository.nameWithOwner == $r)
      | . as $i
      | ($i.fieldValues.nodes | map(select(.field.name == "Status"))   | .[0].name // "") as $s
      | ($i.fieldValues.nodes | map(select(.field.name == "Priority")) | .[0].name // "") as $p
      | "\($i.content.number)\t\($s)\t\($p)"' | tr -d '\r'
    [ "$(printf '%s' "$page" | jq -r '.data.node.items.pageInfo.hasNextPage')" = 'true' ] || break
    after="$(printf '%s' "$page" | jq -r '.data.node.items.pageInfo.endCursor')"
  done
}

set_project "$from" "$repo" >/dev/null
rows="$(cards_of "$repo")" || exit 1
[ -n "$rows" ] || { echo "no cards from $repo on project $from"; exit 0; }

count="$(printf '%s\n' "$rows" | grep -c .)"
echo "$count card(s) from $repo on project $from"
printf '%s\n' "$rows" | while IFS=$'\t' read -r n s p; do
  printf '  #%-5s status=%-14s priority=%s\n' "$n" "${s:--}" "${p:--}"
done

if [ -n "$dry" ]; then echo "dry run - nothing changed"; exit 0; fi

# Add to the target first. A card that failed to land there must still be on the source board, or the
# work would be on no board at all - which is the one outcome worse than being on the wrong one.
#
# Status and Priority are written by the scripts that already own those two fields rather than here.
# A second implementation of "put this card in that column" is how two conventions end up on one
# board, and these two resolve their options by NAME against the target project, which is what makes
# a move between projects safe at all.
#
# The loop reads the rows from a here-string and NOT from a pipe: a pipeline runs its last command in
# a subshell, so a `die` inside would end that subshell and the run would carry on to the next card.
BIN="$ROOT/bin"

while IFS=$'\t' read -r n s p; do
  [ -n "$n" ] || continue
  set_project "$to" "$repo" >/dev/null
  item_id "$repo" "$n" >/dev/null || die "#$n could not be added to project $to"
  if [ -n "$s" ]; then
    if ! bash "$BIN/issue-status.sh" --project "$to" "$repo" "$n" "$s" >/dev/null 2>&1; then
      echo "  #$n: Status '$s' has no option on project $to; left unset"
    fi
  fi
  if [ -n "$p" ]; then
    if ! bash "$BIN/issue-priority.sh" --project "$to" "$repo" "$n" "$p" >/dev/null 2>&1; then
      echo "  #$n: Priority '$p' has no option on project $to; left unset"
    fi
  fi
  set_project "$from" "$repo" >/dev/null
  remove_board_item "$repo" "$n" || echo "  #$n: was already off project $from"
  printf '  #%-5s moved  status=%-14s priority=%s\n' "$n" "${s:--}" "${p:--}"
done <<< "$rows"

echo "done - the issues themselves are untouched"
