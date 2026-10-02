#!/usr/bin/env bash
# The state of the work on one board and the plan for the rest, printed the same way every time:
# the usage windows, the pace, what an issue costs, every worker's packages with their start and
# end, the pauses at the usage limit, the end of the work, and what is ready to close. It is
# counted from the board, the team, the usage the status line records and the session
# transcripts; no model is involved. This script reads the board; lib/status.mjs counts, so
# status.ps1 prints the same page.
#
#   status.sh [--project N] [--issues]   the board of the repository you stand in, or board N;
#                                        --issues adds every open issue, by package
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/../lib/board.sh"

usage="usage: status.sh [--project N] [--issues]"
project=""; issues=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) echo "$usage"; exit 0 ;;
    --project) need_value "$1" "${2-}"; project="$2"; shift 2 ;;
    --issues) issues=--issues; shift ;;
    *) die "unknown argument '$1' - $usage" ;;
  esac
done
command -v node >/dev/null 2>&1 || die "status counts with node, and node is not on the PATH"
# Outside a repository there is none to find the board from, and the board is named instead
[ -n "$project" ] || [ -n "${GH_PROJECT_NUMBER:-}" ] || git rev-parse --git-dir >/dev/null 2>&1 \
  || die "outside a repository, name the board - status --project N"
set_project "$project" "" >/dev/null || exit 1

# The project folder: the one the repositories and their .worktrees stand in, found from a worktree
# too; outside a repository, the folder you stand in
if common="$(git rev-parse --git-common-dir 2>/dev/null)"; then
  folder="$(dirname "$(cd "$common/.." && git rev-parse --show-toplevel)")"
else
  folder="$(pwd)"
fi
# The limit as usage.sh reads it: USAGE_STOP_AT of the project's config.env, else 92
stop="$(grep -E '^[[:space:]]*USAGE_STOP_AT[[:space:]]*=' "$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.ai-core/config.env" 2>/dev/null | tail -n1 || true)"
stop="${stop#*=}"; stop="${stop%%#*}"; stop="${stop//[[:space:]\"\']/}"; stop="${stop:-92}"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
columns="$(fields_tsv)" || exit 1
awk -F'\t' 'tolower($1) == "status" { print $3 }' <<< "$columns" > "$work/columns"
# One card a line, then the cursor of the next page where there is one
cards='(.data.node.items.nodes[] | tojson), (.data.node.items.pageInfo | select(.hasNextPage) | "after \(.endCursor)")'
: > "$work/items"; after=""
while :; do
  out="$(gh_read "the cards of board $(project_number)" api graphql -f pid="$(project_id)" ${after:+-f after="$after"} -f query='
    query($pid:ID!, $after:String) { node(id:$pid) { ... on ProjectV2 {
      items(first:100, after:$after) { pageInfo { hasNextPage endCursor } nodes {
        status: fieldValueByName(name:"Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } }
        priority: fieldValueByName(name:"Priority") { ... on ProjectV2ItemFieldSingleSelectValue { name } }
        content { ... on Issue { number title state closedAt body repository { nameWithOwner }
          parent { number repository { nameWithOwner } } subIssuesSummary { total } } } } } } } }' --jq "$cards")" || exit 1
  grep '^{' <<< "$out" >> "$work/items"
  after="$(sed -n 's/^after //p' <<< "$out")"
  [ -n "$after" ] || break
done

node "$here/../lib/status.mjs" --items-file "$work/items" --columns-file "$work/columns" \
  --board "$(project_org)/$(project_number)" --folder "$folder" --stop-at "$stop" $issues
