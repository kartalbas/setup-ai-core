#!/usr/bin/env bash
# Set which items a board view shows, by repo name.
#
#   view-filter.sh --project 5 --view ALL-ISSUES --repo-name example-repo --repo-name other-repo
#   view-filter.sh --project 7 --view ALL-ISSUES --clear
#
# A board that carries several repos shows all of them by default, which is right for a
# board that is read as a whole and wrong for one where a reader only ever wants their own
# repos. The filter narrows the view; it removes nothing from the board, so a card hidden
# here is still on it and still counts towards its epic.
#
# Repos are named without the org, the way they appear in the board's own repo filter.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/board.sh"

project=""; view="ALL-ISSUES"; do_clear=""
repo_names=()

while [ $# -gt 0 ]; do
  case "$1" in
    --project)   need_value "$1" "${2-}"; project="$2";       shift 2 ;;
    --view)      need_value "$1" "${2-}"; view="$2";          shift 2 ;;
    --repo-name) need_value "$1" "${2-}"; repo_names+=("$2"); shift 2 ;;
    --clear)     do_clear=1;         shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$project" ] || die "--project <number> is required"
[ -n "$do_clear" ] || [ "${#repo_names[@]}" -gt 0 ] || die "pass --repo-name, or --clear to show everything again"

set_project "$project" >/dev/null

rows="$(board_views "$project")" || exit 1

# The filter uses the same syntax the board's own filter box takes. Several repos are
# one comma-separated repo: term, which is an OR.
view_id="$(printf '%s\n' "$rows" | awk -F'\t' -v v="$view" '$1==v {print $2; exit}')"
[ -n "$view_id" ] || die "project $project has no view named '$view'. It has: $(printf '%s\n' "$rows" | cut -f1 | paste -sd' ' -)"

if [ -n "$do_clear" ]; then
  filter=""
else
  filter="repo:$(printf '%s\n' "${repo_names[@]}" | awk -v org="$(project_org)" '{ printf "%s%s/%s", (NR>1 ? "," : ""), org, $0 }')"
fi

# What the mutation answered is the line this prints, so it is established as an answer first
# rather than written to the screen as the result of a filter that was never set.
check_public_body view-filter "$(project_org)/$(project_number)" "$filter" "" project
view_filter_set "$view_id" "$filter"
