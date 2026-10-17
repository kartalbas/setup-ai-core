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
# where it has none; files are the files of its own repository, on its default branch, that its body
# names as `path:line`. A part with nothing in it is left out. Then each group of two or more issues
# that a parent or a `blocked by` joins, as `group: <repo>#<n> ...`; each file that two or more
# issues name, as `file <repo> <path>: <repo>#<n> ...`; and a `cut:` line for every list GitHub gave
# only in part, so a short list never passes for a whole one. <repo> is the repository's name, or
# OWNER/REPO where two of the repositories asked for share a name.

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

# A repository's file list runs to megabytes, past what one argument of jq may hold
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
issues=""
for repo in "${repos[@]}"; do
  rows="$(issue_rows "$repo")" || exit 1
  # A repository without a commit has no default branch and holds no file yet. The default branch
  # and the file list are the repository's, not the tracker's: they stay GitHub's own reads here.
  branch="$(gh_read "the default branch of $repo" api graphql -F owner="${repo%%/*}" -F name="${repo#*/}" -f query='
    query($owner:String!, $name:String!) { repository(owner:$owner, name:$name) {
      defaultBranchRef { name } } }')" || exit 1
  if [ -n "$(jq -rn 'first(inputs | .data.repository.defaultBranchRef.name // empty)' <<< "$branch")" ]; then
    gh_read "the files of $repo" api "repos/$repo/git/trees/HEAD?recursive=1" > "$work/tree.json"
  else
    echo '{"tree": []}' > "$work/tree.json"
  fi
  # Every `path:line` of a body is a candidate; only a path its repository holds is a file, so a
  # version, a host with its port or a path on somebody's machine never reads as one
  issues="$issues$(jq -c --slurpfile tree "$work/tree.json" '
    ($tree[0] | [.tree[] | select(.type == "blob") | {key: .path, value: true}] | from_entries) as $files
    | ($tree[0].truncated // false) as $truncated
    | def tagged($group): [.labels[] | select(startswith($group + ":")) | sub("^[^:]*:"; "")][0] // "-";
      { repo, number, id: "\(.repo)#\(.number)", title,
        status: (.status // "-"),
        type: tagged("type"), area: tagged("area"),
        parent, blockedBy, blocking,
        files: ([(.body // "") | scan("[A-Za-z0-9_./-]+(?=:[0-9])") | sub("^\\./"; "") | select($files[.])] | unique),
        cut, truncated: $truncated }' <<< "$rows")
"
done

# Joins and sorting run on the full name; a line shows a repository without its owner, unless the map
# meets its name under two owners
printf '%s' "$issues" | jq -rs '
  def name: split("#")[0] | sub("^[^/]*/"; "");
  def order: split("#") | [.[0], (.[1] | tonumber)];
  sort_by(.repo, .number) as $all
  | ([$all[] | .id, .parent, .blockedBy[], .blocking[] | select(. != null) | split("#")[0]] | unique
     | map(name) | group_by(.) | map(select(length > 1)[0])) as $twice
  | def short: if IN(name; $twice[]) then . else sub("^[^/]*/"; "") end;
  $all
  | ($all | map(.id)) as $ids
  | ($all | map("\(.id | short) \(.status) \(.type) \(.area) | \(.title)"
      + (if .parent then " | parent \(.parent | short)" else "" end)
      + (if (.blockedBy | length) > 0 then " | blocked by \(.blockedBy | map(short) | join(","))" else "" end)
      + (if (.blocking | length) > 0 then " | blocks \(.blocking | map(short) | join(","))" else "" end)
      + (if (.files | length) > 0 then " | files \(.files | join(","))" else "" end))[]),
    # A group is what the joins reach: every join sets both ends to the smaller label, and as many
    # passes as there are issues carry a label across the longest chain
    ([$all[] | .id as $a | ([.parent] + .blockedBy + .blocking)[] | select(. != null and IN($ids[])) | [$a, .]] as $joins
     | reduce range(0; $all | length) as $pass ($all | map({key: .id, value: .id}) | from_entries;
         reduce $joins[] as $j (.; ([.[$j[0]], .[$j[1]]] | min) as $m | .[$j[0]] = $m | .[$j[1]] = $m))
     | to_entries | group_by(.value) | map(select(length > 1) | map(.key))
     | sort_by(.[0] | order)[] | "group: \(map(short) | join(" "))"),
    ([$all[] | .repo as $r | .id as $i | .files[] | {file: "\($r | short) \(.)", id: $i}] | group_by(.file)
     | map(select(length > 1))[] | "file \(.[0].file): \(map(.id | short) | join(" "))"),
    ($all[] | .id as $i | .cut[] | "cut: \($i | short) \(.)"),
    ([$all[] | select(.truncated) | .repo] | unique[] | "cut: files of \(short): GitHub gave its file list only in part")'
