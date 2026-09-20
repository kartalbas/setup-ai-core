#!/usr/bin/env bash
# Every repository of the organisation and the open board it is linked to.
#
#   repo-boards.sh
#
# Exits 1 when any repository is linked to NO open board, or to more than one. Exits 0
# when every one of them resolves to exactly one, which is the state every other script
# in bin/ needs.
#
# WHY NOTHING ELSE COULD ANSWER THIS. Every other path into this tooling starts from a
# repository and asks which board it resolves to, so a repository that resolves to none
# stops that one call and is never counted; and board-sync sweeps "every repo linked to
# the project", which by construction can never reach a repository linked to no project.
# The question has to be asked from the ORGANISATION, which is the one side that can list
# a repository nobody linked.
#
# WHAT IT COSTS TO BE WRONG. An issue filed in an unlinked repository is on no board, so
# it is invisible to whoever reads progress off the board, and it stays invisible until
# somebody remembers it exists. Linked to more than one, the resolution is ambiguous and
# every script refuses until a number is passed by hand.
#
# The template board is not a board work is tracked on, so it does not count as a link -
# the same rule resolve_project_for_repo applies when it resolves one repository. A
# CLOSED project does not count either, for the same reason: a repository keeps its old
# boards after they are closed.
#
# AN ARCHIVED REPOSITORY IS LISTED AND NOT COUNTED AGAINST THE RUN. It takes no new
# issues, so a board link would put nothing on a board; reporting it as a gap would be a
# red nobody can clear except by linking a dead repository.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/board.sh"

reject_options "$@"
[ $# -eq 0 ] || die "repo-boards.sh takes no arguments - it reads the whole organisation"
org="$(gh_org)" || exit 1

# ONE ROW PER REPOSITORY, AND ONE MORE PER BOARD IT IS LINKED TO. Packing the boards into
# the repository's own row would mean filtering rows by their board title below, and a
# repository whose only link is to the template board would then vanish from the report
# entirely - which is the one answer this script exists to never give.
rows() {
  local after="" page
  while :; do
    if [ -n "$after" ]; then
      page="$(gh_read "the repositories of $org after $after" api graphql -f o="$org" -f after="$after" -f query='
        query($o:String!, $after:String) { organization(login:$o) {
          repositories(first:100, after:$after) { pageInfo { hasNextPage endCursor }
            nodes { nameWithOwner isArchived
              projectsV2(first:50) { nodes { number title closed } } } } } }')" || exit 1
    else
      page="$(gh_read "the repositories of $org" api graphql -f o="$org" -f query='
        query($o:String!) { organization(login:$o) {
          repositories(first:100) { pageInfo { hasNextPage endCursor }
            nodes { nameWithOwner isArchived
              projectsV2(first:50) { nodes { number title closed } } } } } }')" || exit 1
    fi
    # The carriage return is stripped here for the same reason board_items strips it: this
    # is the jq BINARY rather than gh's own --jq, and on Windows that binary writes CRLF.
    printf '%s' "$page" | jq -r '.data.organization.repositories.nodes[] | . as $r
      | "R\t\($r.nameWithOwner)\t\($r.isArchived)",
        ($r.projectsV2.nodes[] | select(.closed == false)
         | "B\t\($r.nameWithOwner)\t\(.number)\t\(.title)")' | tr -d '\r'
    [ "$(printf '%s' "$page" | jq -r '.data.organization.repositories.pageInfo.hasNextPage')" = 'true' ] || break
    after="$(printf '%s' "$page" | jq -r '.data.organization.repositories.pageInfo.endCursor')"
  done
}

# Read whole before it is split. A process substitution reports nothing about how the
# command inside it ended, so a refused query would arrive as an organisation with no
# repositories and the run would report that every one of them is linked.
all="$(rows)" || exit 1

unlinked=0
ambiguous=0
archived=0
counted=0

while IFS=$'\t' read -r kind repo is_archived; do
  [ "$kind" = R ] || continue

  if [ "$is_archived" = true ]; then
    printf '  %-34s archived, not counted\n' "$repo"
    archived=$((archived + 1))
    continue
  fi

  # The template mark is matched at the START of the title, against the tab that stands
  # before it, exactly as resolve_project_for_repo matches it for one repository.
  boards="$(printf '%s\n' "$all" | awk -F'\t' -v r="$repo" '$1=="B" && $2==r {print $3"\t"$4}' \
            | grep -Fv "$(printf '\t')$TEMPLATE_MARK" || true)"
  n="$(printf '%s\n' "$boards" | grep -c . || true)"

  counted=$((counted + 1))
  case "$n" in
    0) printf '  %-34s LINKED TO NO OPEN BOARD\n' "$repo"; unlinked=$((unlinked + 1)) ;;
    1) printf '  %-34s %s\n' "$repo" "$(printf '%s' "$boards" | tr '\t' ' ')" ;;
    *) printf '  %-34s LINKED TO %s BOARDS: %s\n' "$repo" "$n" \
              "$(printf '%s\n' "$boards" | tr '\t' ' ' | awk 'NR>1 {printf ", "} {printf "%s", $0} END {print ""}')"
       ambiguous=$((ambiguous + 1)) ;;
  esac
done <<< "$all"

echo
echo "$counted repositories read, $archived archived and left out of the count"

# A COUNT WITH NO DENOMINATOR SAYS NOTHING, so both halves are printed even when they are
# zero - a run that found nothing and a run that looked at nothing print differently.
echo "$unlinked linked to no open board, $ambiguous linked to more than one"

[ "$((unlinked + ambiguous))" -eq 0 ] || exit 1
