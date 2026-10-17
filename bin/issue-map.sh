#!/usr/bin/env bash
# One map of the open issues of one or more repositories and of what joins them, so a planner reads
# it once instead of every issue's body. Nothing is kept anywhere: the map is read from the tracker
# each time, so there is no second record to fall behind it.
#
#   issue-map.sh [OWNER/REPO ...]          default: the repository of the checkout
#
# First one line per open issue:
#   <repo>#<n> <status> <type> <area> | <title> | parent <repo>#<n> | blocked by <repo>#<n>,...
#     | blocks <repo>#<n>,... | files <path>,...
# status is the Status of its board card, `-` on no board; type and area come from its labels, `-`
# where it has none; files are the paths its body names as `path:line`. A part with nothing in it
# is left out. Then each group of two or more issues that a parent or a `blocked by` joins, as
# `group: <repo>#<n> ...`, and each file that two or more issues name, as `file <path>: <repo>#<n> ...`.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/board.sh"

repos=()
while [ $# -gt 0 ]; do
  case "$1" in
    -*) die "unknown argument '$1'" ;;
    */*) repos+=("$1"); shift ;;
    *) die "'$1' is no OWNER/REPO" ;;
  esac
done
[ ${#repos[@]} -gt 0 ] || repos=("$(default_repo)")

issues=""
for repo in "${repos[@]}"; do
  page="$(gh_read "the open issues of $repo" api graphql --paginate -F owner="${repo%%/*}" -F name="${repo#*/}" -f query='
    query($owner:String!, $name:String!, $endCursor:String) { repository(owner:$owner, name:$name) {
      issues(states:OPEN, first:50, after:$endCursor) { pageInfo { hasNextPage endCursor } nodes {
        number title body
        labels(first:20) { nodes { name } }
        parent { number repository { name } }
        blockedBy(first:20) { nodes { number repository { name } } }
        blocking(first:20) { nodes { number repository { name } } }
        projectItems(first:5) { nodes { fieldValueByName(name:"Status") {
          ... on ProjectV2ItemFieldSingleSelectValue { name } } } } } } } }')"
  issues="$issues$(jq -c --arg repo "${repo#*/}" '.data.repository.issues.nodes[]
    | def ref: "\(.repository.name)#\(.number)";
      def tagged($group): [.labels.nodes[].name | select(startswith($group + ":")) | sub("^[^:]*:"; "")][0] // "-";
      { repo: $repo, number, id: "\($repo)#\(.number)", title,
        status: ([.projectItems.nodes[].fieldValueByName.name // empty][0] // "-"),
        type: tagged("type"), area: tagged("area"),
        parent: (if .parent then (.parent | ref) else null end),
        blockedBy: [.blockedBy.nodes[] | ref], blocking: [.blocking.nodes[] | ref],
        files: ([(.body // "") | scan("[A-Za-z0-9_][A-Za-z0-9_./-]*\\.[A-Za-z0-9]+(?=:[0-9])")] | unique) }' <<< "$page")
"
done

printf '%s' "$issues" | jq -rs '
  sort_by(.repo, .number) as $all
  | ($all | map(.id)) as $ids
  | ($all | map("\(.id) \(.status) \(.type) \(.area) | \(.title)"
      + (if .parent then " | parent \(.parent)" else "" end)
      + (if (.blockedBy | length) > 0 then " | blocked by \(.blockedBy | join(","))" else "" end)
      + (if (.blocking | length) > 0 then " | blocks \(.blocking | join(","))" else "" end)
      + (if (.files | length) > 0 then " | files \(.files | join(","))" else "" end))[]),
    # A group is what the joins reach: every join sets both ends to the smaller label, and as many
    # passes as there are issues carry a label across the longest chain
    ([$all[] | .id as $a | ([.parent] + .blockedBy + .blocking)[] | select(. != null and IN($ids[])) | [$a, .]] as $joins
     | reduce range(0; $all | length) as $pass ($all | map({key: .id, value: .id}) | from_entries;
         reduce $joins[] as $j (.; ([.[$j[0]], .[$j[1]]] | min) as $m | .[$j[0]] = $m | .[$j[1]] = $m))
     | to_entries | group_by(.value) | map(select(length > 1) | map(.key))
     | map(sort_by(split("#") | [.[0], (.[1] | tonumber)]))[] | "group: \(join(" "))"),
    ([$all[] | .id as $i | .files[] | {file: ., id: $i}] | group_by(.file)
     | map(select(length > 1))[] | "file \(.[0].file): \(map(.id) | join(" "))")'
