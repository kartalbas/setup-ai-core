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
org="$(gh_read "the id of $org_name" api graphql -f o="$org_name" -f query='
  query($o:String!){ organization(login:$o){ id } }' \
  --jq '.data.organization.id')" || exit 1

src="$(gh_read "the id of project $like in $org_name" api graphql -f o="$org_name" -F n="$like" -f query='
  query($o:String!,$n:Int!){ organization(login:$o){ projectV2(number:$n){ id } } }' \
  --jq '.data.organization.projectV2.id')" || exit 1
[ -n "$src" ] || die "no project $like in $org_name to copy from"

made="$(gh_read "the board copied from project $like" api graphql -f pid="$src" -f oid="$org" -f t="$title" -f query='
  mutation($pid:ID!,$oid:ID!,$t:String!){
    copyProjectV2(input:{projectId:$pid, ownerId:$oid, title:$t, includeDraftIssues:false}){
      projectV2 { number url } } }' \
  --jq '.data.copyProjectV2.projectV2 | "\(.number)\t\(.url)"')" || exit 1

IFS=$'\t' read -r num url <<< "$made"
echo "created: $title  ->  $url"
echo "$num"
