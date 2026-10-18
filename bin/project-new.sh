#!/usr/bin/env bash
# Create a board by copying an existing one, so a new board has the same fields, the
# same options and the same views as the boards already in use.
#
#   project-new.sh TITLE [LIKE]
#
# Project visibility is unknown on GitHub and Plane. Names receive the public email-address check;
# reserved example domains and GitHub noreply addresses are allowed.
# The check reads the raw text, and an address dressed by Markdown, HTML, invisible or lookalike characters may pass; the README names the cases.
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
#
# On Plane (TRACKER=plane) nothing is copied: the project PLANE_PROJECT names is made with the eight
# states of the harness and the labels of labels.tsv, and a LIKE is refused.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/board.sh"

reject_options "$@"

case $# in
  1) title="$1"; like="$(template_project_number)" ;;
  2) title="$1"; like="$2" ;;
  *) die "usage: project-new.sh TITLE [LIKE]" ;;
esac

org_name="$(gh_org)" || exit 1

check_public_body project-new "$org_name" "$title" "" project
made="$(project_create "$org_name" "$like" "$title")" || exit 1

IFS=$'\t' read -r num url <<< "$made"
echo "created: $title  ->  $url"
echo "$num"
