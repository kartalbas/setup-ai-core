#!/usr/bin/env bash
# How many tickets picked up each incident label, week by week.
#
#   incident-count.sh                      every repository of every open board
#   incident-count.sh OWNER/REPO ...       named repos
#   incident-count.sh --weeks 12           a longer window than the eight weeks default
#
# One row per `incident:` label in labels.tsv, one column per ISO week, oldest week first.
# It reads and prints; it sets no field and it writes no label.
#
# WITH NO REPOSITORY NAMED IT READS BOTH BOARDS. How well the tickets themselves are written is
# a question about the organisation and not about one board, and an answer covering half of it
# reads as an answer covering all of it. The boards are the org's own open projects, found the
# way project-new finds the template - by asking - so a third board is included the day it
# exists rather than the day somebody remembers to edit a number in here.
#
# A ticket counts in the week it was CREATED, taken in UTC, so the same run on two machines in
# two time zones puts the same ticket in the same column.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/board.sh"

usage='usage: incident-count.sh [OWNER/REPO...] [--weeks N]'

weeks=8
repos=()
while [ $# -gt 0 ]; do
  case "$1" in
    --weeks)   need_value "$1" "${2-}"; weeks="$2"; shift 2 ;;
    -h|--help) echo "$usage"; exit 0 ;;
    -*)        die "unknown argument '$1'" ;;
    *)         repos+=("$1"); shift ;;
  esac
done
case "$weeks" in ''|*[!0-9]*) die "--weeks must be numeric, not '$weeks'" ;; esac
[ "$weeks" -ge 1 ] || die "--weeks must be at least 1"

# GNU date and BSD date take opposite arguments for "N days ago", and this half of the pair runs
# on macOS as well as on Linux and Git Bash. Which one is here is asked once.
if date -u -d '1970-01-01' +%Y >/dev/null 2>&1; then
  date_kind=gnu
else
  date_kind=bsd
fi

days_ago() { # days_ago <days> <format>
  if [ "$date_kind" = gnu ]; then date -u -d "$1 days ago" "$2"
  else date -u -v-"$1"d "$2"
  fi
}

week_of() { # week_of <UTC timestamp>
  if [ "$date_kind" = gnu ]; then date -u -d "$1" +%G-W%V
  else date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%G-W%V
  fi
}

# Every repository of every open board of the organisation, without the template board - which
# is a shape to copy and tracks no work.
every_board_repo() {
  local boards number
  org="$(gh_org)" || exit 1
  boards="$(gh_read "the projects of $org" api graphql -f o="$org" -f query='
    query($o:String!) { organization(login:$o) {
      projectsV2(first:100) { nodes { number title closed } } } }' \
    --jq '.data.organization.projectsV2.nodes[] | select(.closed == false) | "\(.number)\t\(.title)"')" || exit 1
  boards="$(printf '%s\n' "$boards" | grep -Fv "	$TEMPLATE_MARK" || true)"
  [ -n "$boards" ] || die "no open board in $org - name the repositories to count over"
  while IFS=$'\t' read -r number _; do
    [ -n "$number" ] || continue
    set_project "$number" >/dev/null
    project_repos || exit 1
  done <<< "$boards"
}

if [ ${#repos[@]} -eq 0 ]; then
  # Read whole, then split. A process substitution reports nothing about how the command inside
  # it ended, so a refused query would arrive as an organisation with no repositories and the
  # table would be printed full of zeroes.
  found="$(every_board_repo)" || exit 1
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    case " ${repos[*]:-} " in *" $repo "*) continue ;; esac
    repos+=("$repo")
  done <<< "$found"
  [ ${#repos[@]} -ge 1 ] || die "no repository is linked to an open board - name the repositories to count over"
fi

# The taxonomy is the list of incident labels - one definition, the same file issue-label and
# labels-sync read, held against its shape by the same reader.
labels=()
while IFS= read -r label; do [ -n "$label" ] && labels+=("$label"); done < <(label_names_in_group incident)
[ ${#labels[@]} -ge 1 ] || die "labels.tsv holds no incident label - there is nothing to count"

# The columns: the last N ISO weeks, oldest first, the current week last.
columns=()
back=$((weeks - 1))
while [ "$back" -ge 0 ]; do
  columns+=("$(days_ago "$((back * 7))" +%G-W%V)")
  back=$((back - 1))
done

# The first day the table can show anything for: the Monday of the oldest column. The query asks
# for that day onwards, so the reply holds what the window needs and nothing older.
oldest="$(days_ago "$(((weeks - 1) * 7))" +%Y-%m-%d)"
if [ "$date_kind" = gnu ]; then
  first_day="$(date -u -d "$oldest -$(($(date -u -d "$oldest" +%u) - 1)) days" +%Y-%m-%d)"
else
  weekday="$(date -u -j -f '%Y-%m-%d' "$oldest" +%u)"
  first_day="$(date -u -j -f '%Y-%m-%d' "$oldest" -v-"$((weekday - 1))"d +%Y-%m-%d)"
fi

# gh returns the newest LIMIT issues and says nothing about the rest, so a reply that reaches
# the limit is a count that may be short. It is refused rather than printed.
limit=500

seen="$(mktemp)"
trap 'rm -f "$seen"' EXIT

for repo in "${repos[@]}"; do
  found="$(gh_read "the issues of $repo" issue list --repo "$repo" --state all --limit "$limit" \
           --search "created:>=$first_day" --json createdAt,labels)" || exit 1
  [ "$(printf '%s' "$found" | jq 'length')" -lt "$limit" ] \
    || die "more than $limit issues in the window for $repo - the count would be partial"
  # The carriage returns come out here, not later. jq ends a line with CRLF on Windows, and a CR
  # left on the label stops it matching the name read from labels.tsv - a table of zeroes on one
  # platform and the right numbers on the other.
  while IFS=$'\t' read -r created label; do
    [ -n "$created" ] || continue
    printf '%s\t%s\n' "$label" "$(week_of "$created")" >> "$seen"
  done < <(printf '%s' "$found" \
           | jq -r '.[] | .createdAt as $c | .labels[].name
                    | select(startswith("incident:")) | "\($c)\t\(.)"' \
           | tr -d '\r')
done

printf '%-24s' 'label'
for week in "${columns[@]}"; do printf '%9s' "$week"; done
printf '\n'

for label in "${labels[@]}"; do
  printf '%-24s' "$label"
  for week in "${columns[@]}"; do
    printf '%9s' "$(awk -F'\t' -v l="$label" -v w="$week" \
      '$1 == l && $2 == w { n++ } END { print n + 0 }' "$seen")"
  done
  printf '\n'
done
