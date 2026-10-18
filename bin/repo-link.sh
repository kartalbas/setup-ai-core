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

taxonomy="$(labels_tsv)" || exit 1
for repo in "$@"; do
  check_public_body repo-link "$repo" "$repo"$'\n'"$taxonomy" ""
done

for repo in "$@"; do
  # What the mutation answered is printed as the confirmation, so it is established as an answer
  # first. Piping it straight into sed prints a refusal as `linked: {"data":null,...}`.
  linked="$(repo_link "$repo")" || exit 1
  echo "linked: $linked"
done

"$ROOT/bin/labels-sync.sh" "$@"
