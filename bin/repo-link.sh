#!/usr/bin/env bash
# Link a repo to a project, and give it the label taxonomy at the same time.
# Run this once per new repo; without the link its issues can still be added to the
# board by hand, but the repo does not appear in the board's own repo filter.
#
#   repo-link.sh --project 5                  the repo of the current directory
#   repo-link.sh --project 5 OWNER/REPO ...
#
# --project is required: this script creates the very link every other script uses
# to find the project from the repo, so that link cannot itself be resolved from the
# repo - it does not exist yet.

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

[ -n "$project" ] || die "--project <number> is required - the project cannot be resolved from a repo that is not linked yet"

[ $# -gt 0 ] || set -- "$(default_repo)"

set_project "$project" >/dev/null

for repo in "$@"; do
  rid="$(gh_read "the node id of $repo" api "repos/$repo" --jq '.node_id')" || exit 1
  # What the mutation answered is printed as the confirmation, so it is established as an answer
  # first. Piping it straight into sed prints a refusal as `linked: {"data":null,...}`.
  linked="$(gh_read "the link between $repo and board $(project_number)" api graphql \
    -f pid="$(project_id)" -f rid="$rid" -f query='
    mutation($pid:ID!, $rid:ID!) {
      linkProjectV2ToRepository(input:{projectId:$pid, repositoryId:$rid}) {
        repository { nameWithOwner } } }' \
    --jq '.data.linkProjectV2ToRepository.repository.nameWithOwner')" || exit 1
  echo "linked: $linked"
done

"$ROOT/bin/labels-sync.sh" "$@"
