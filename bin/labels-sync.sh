#!/usr/bin/env bash
# Apply labels.tsv to a repo. Existing labels are updated in place, so running this
# twice changes nothing the second time.
#
#   labels-sync.sh                            the repo of the current directory
#   labels-sync.sh OWNER/REPO ...             named repos
#   labels-sync.sh --all [--project N]        every repo on one board
#
# It only adds and updates. A label that is in the repo but not in labels.tsv is
# reported and left alone - deleting one would strip it off every issue that carries it.
#
# --all means every repo on ONE board, so it needs to know which board. It takes the
# same answer as every other script: --project, else GH_PROJECT_NUMBER, else the board
# the current directory's repo is linked to.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/board.sh"

project_arg=""
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --project) need_value "$1" "${2-}"; project_arg="$2"; shift 2 ;;
    # --all is read below, where the repo list is built, so it travels with the arguments.
    --all)     args+=("$1"); shift ;;
    -*)        die "unknown argument '$1'" ;;
    *)         args+=("$1"); shift ;;
  esac
done
set -- "${args[@]+"${args[@]}"}"

case "${1:-}" in
  # Read into a variable before it is split into lines. A process substitution reports nothing
  # about how the command inside it ended, so a refused query would leave no repos and the run
  # would end without having touched one, saying nothing.
  --all) set_project "$project_arg" >/dev/null
         linked="$(project_repos)" || exit 1
         set_repos=()
         while IFS= read -r r || [ -n "$r" ]; do [ -n "$r" ] && set_repos+=("$r"); done <<< "$linked"
         set -- ${set_repos[@]+"${set_repos[@]}"} ;;
  '')    here="$(default_repo)" || exit 1; set -- "$here" ;;
esac

# Read once, before the first repo is touched. The taxonomy is held against its own shape in
# labels_tsv, and a file that cannot be read must stop the run rather than create part of it in
# the first repository and then die in the second.
taxonomy="$(labels_tsv)" || exit 1

for repo in "$@"; do
  echo "$repo"
  while IFS=$'\t' read -r group name color desc; do
    [ -n "$name" ] || continue
    gh label create "$name" --repo "$repo" --color "$color" --description "$desc" --force >/dev/null
    printf '  %-8s %s\n' "$group" "$name"
  done <<< "$taxonomy"

  known="$(printf '%s\n' "$taxonomy" | cut -f2)"
  # The list is read before it is filtered. The `|| true` below belongs to grep, which reports "no
  # line matched" the same way it reports an error - so a refused query would come out the other
  # side and be printed as labels this repository carries.
  on="$(gh_read "the labels of $repo" label list --repo "$repo" --limit 200 --json name --jq '.[].name')" || exit 1
  extra="$(printf '%s\n' "$on" | grep -vxF "$known" || true)"
  [ -z "$extra" ] || {
    echo "  not in labels.tsv, left alone:"
    echo "$extra" | sed 's/^/    /'
  }
done
