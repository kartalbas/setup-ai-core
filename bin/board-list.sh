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

gh_read "the cards of board $(project_number)" api graphql --paginate -f pid="$(project_id)" -f query='
  query($pid:ID!, $endCursor:String) { node(id:$pid) { ... on ProjectV2 {
    items(first:100, after:$endCursor) {
      pageInfo { hasNextPage endCursor }
      nodes {
        fieldValues(first:20) { nodes { ... on ProjectV2ItemFieldSingleSelectValue {
          name field { ... on ProjectV2SingleSelectField { name } } } } }
        content { ... on Issue { number title state repository { name } } }
      } } } } }' \
  --jq '.data.node.items.nodes[] | select(.content.number != null)
        | { n: .content.number, t: .content.title, r: .content.repository.name, closed: (.content.state == "CLOSED"),
            s: ([.fieldValues.nodes[] | select(.field.name == "Status")   | .name] | first // "-"),
            p: ([.fieldValues.nodes[] | select(.field.name == "Priority") | .name] | first // "-") }
        | "\(.s)\t\(.p)\t\(.r)\t\(.n)\t\(.t)\t\(if .closed then "closed" else "" end)"' \
| awk -F'\t' -v ws="$want_status" -v wr="$want_repo" \
      '(ws == "" || $1 == ws) && (wr == "" || $3 == wr)' \
| sort -t$'\t' -k1,1 -k2,2 -k3,3 -k4,4n \
| awk -F'\t' '{ printf "%-15s %-3s %-22s #%-4s %s%s\n", $1, $2, $3, $4, $5, ($6=="" ? "" : "  ["$6"]") }'
