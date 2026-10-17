#!/usr/bin/env bash
# Create a board by copying an existing one, so a new board has the same fields, the
# same options and the same views as the boards already in use.
#
#   project-new.sh TITLE [LIKE]
#
# Prints "created: TITLE -> URL" then the new project number on stdout.
#
# With no LIKE the source is the org's template board, found by its title rather than
# by a number written down here, so renumbering or replacing the template does not
# break this.
#
# Copying rather than building the fields one call at a time is deliberate: a
# hand-built board drifts from the others in the details nobody checks - an option
# colour, a description, the order of the columns - and those are exactly what makes
# two boards read differently to the same person. The items of the source board are
# not copied.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/board.sh"

reject_options "$@"

case $# in
  1) title="$1"; like="$(template_project_number)" ;;
  2) title="$1"; like="$2" ;;
  *) die "usage: project-new.sh TITLE [LIKE]" ;;
esac
case "$like" in ''|*[!0-9]*) die "the board number must be numeric, not '$like'" ;; esac

org_name="$(gh_org)" || exit 1

made="$(project_create "$org_name" "$like" "$title")" || exit 1

IFS=$'\t' read -r num url <<< "$made"
echo "created: $title  ->  $url"
echo "$num"
