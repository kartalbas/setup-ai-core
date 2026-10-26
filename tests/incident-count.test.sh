#!/usr/bin/env bash
# What incident-count.sh counts and what its table looks like.
#
# Run with a FAKE gh on PATH: the issues are fixed text, so nothing leaves the machine and
# nothing is written. The clock of the command and the dates the fake reports are one pinned instant
# (a Sunday, one second before the week turns): a clock that moves between the fixture and the command
# would move the incidents into another column, and a date of the real clock would drift out of the window.
#
#   bash test/incident-count.test.sh

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fake="$(mktemp -d)"
export GH_CACHE_DIRECTORY="$fake/cache"
trap 'rm -rf "$fake"' EXIT
log="$fake/calls.txt"

. "$root/tests/date-stub.sh"; make_date_stub "$fake"
export PATH="$fake:$PATH"
seed_clock="$(epoch_of 2026-10-25T23:59:59Z)"
export DATE_STUB_NOW="$seed_clock"

days_ago() { date -u -d "@$((seed_clock - $1 * 86400))" "$2"; }

this_week="$(date -u +%G-W%V)"
last_week="$(days_ago 7 +%G-W%V)"
long_ago="$(days_ago 400 +%Y-%m-%dT%H:%M:%SZ)"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
week_back="$(days_ago 7 +%Y-%m-%dT%H:%M:%SZ)"

# Two open boards plus a template board that tracks no work. The numbers are ones no real board
# carries, so the ids this test invents land in cache directories of their own.
#
# THE ID QUERY IS MATCHED BEFORE THE BOARD LIST. Its own text names organization(login:) as well,
# so an arm matching that first would answer the id query with a list of boards - and the run
# would stop on a project id that is a table.
cat > "$fake/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$log"
case "\$*" in
  *"issue list"*) cat <<JSON
[ { "createdAt": "$now",       "labels": [ { "name": "incident:title" }, { "name": "area:tooling" } ] },
  { "createdAt": "$now",       "labels": [ { "name": "incident:title" } ] },
  { "createdAt": "$week_back", "labels": [ { "name": "incident:context" } ] },
  { "createdAt": "$long_ago",  "labels": [ { "name": "incident:title" } ] },
  { "createdAt": "$now",       "labels": [ { "name": "type:feature" }, { "name": "area:tooling" } ] } ]
JSON
    exit 0 ;;
  *"projectV2(number:"*)     echo 'PVT_kwincident'; exit 0 ;;
  *"projectsV2(first:100)"*) printf '996\tbeta\n997\talpha\n999\t[TEMPLATE] the shape\n'; exit 0 ;;
  *repositories*)            echo 'example-org/example-repo'; exit 0 ;;
  *) printf 'example-org/example-repo\n'; exit 0 ;;
esac
EOF
chmod +x "$fake/gh"

failed=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}

count="$root/bin/incident-count.sh"
repo='example-org/example-repo'

echo 'a named repo is read once, and nothing is written'
: > "$log"
out="$("$count" "$repo" 2>&1 | tr -d '\r')"
check 'one issue list'      1 "$(grep -c "issue list --repo $repo" "$log" || true)"
check 'the state is all'    1 "$(grep -c -- '--state all' "$log" || true)"
check 'nothing was written' 0 "$(grep -cE 'method (POST|PATCH|PUT|DELETE)|mutation|label create|issue edit' "$log" || true)"
check 'no board was asked'  0 "$(grep -c 'projectsV2(first:100)' "$log" || true)"

echo 'the table has a row per incident label and a column per week'
check 'header names the weeks' yes \
  "$(echo "$out" | head -1 | grep -q "$last_week.*$this_week" && echo yes || echo no)"
check 'eight columns by default' 8 "$(echo "$out" | head -1 | awk '{print NF - 1}')"
check 'six rows, one per label' 6 "$(echo "$out" | tail -n +2 | grep -c .)"
check 'every incident label named' yes \
  "$(for l in duplicate context question title released-wrong unasked; do
       grep -q "^incident:$l " <<< "$out" || { echo no; exit; }
     done; echo yes)"

echo 'the counts land in the right week'
row_title="$(grep '^incident:title ' <<< "$out")"
row_context="$(grep '^incident:context ' <<< "$out")"
row_question="$(grep '^incident:question ' <<< "$out")"
check 'two incident:title this week'   2 "$(echo "$row_title" | awk '{print $NF}')"
check 'one incident:context last week' 1 "$(echo "$row_context" | awk '{print $(NF - 1)}')"
check 'incident:question has none'     0 "$(echo "$row_question" | awk '{for (i = 2; i <= NF; i++) s += $i} END {print s + 0}')"
check 'the ticket from last year is outside the window' 0 \
  "$(echo "$row_title" | awk '{for (i = 2; i < NF; i++) s += $i} END {print s + 0}')"

echo 'a label that is not an incident is not counted'
check 'no type row' no "$(grep -q '^type:' <<< "$out" && echo yes || echo no)"

# The week turns between the fixture and the command: the incidents made on the Sunday stay in the week they
# were made in, now the second column from the end, and the new week is empty
echo 'after midnight, in the next week, the counts stay in the week of the incident'
out="$(DATE_STUB_NOW="$(epoch_of 2026-10-26T00:00:01Z)" "$count" "$repo" 2>&1 | tr -d '\r')"
next_week="$(date -u -d 2026-10-26 +%G-W%V)"
check 'the header ends with the new week' yes "$(echo "$out" | head -1 | grep -q "$this_week.*$next_week\$" && echo yes || echo no)"
in_week() { awk -v week="$1" 'NR == 1 { for (i = 2; i <= NF; i++) if ($i == week) column = i } $1 == "incident:title" { print $column }' <<< "$out"; }
check 'two incident:title in the week they were made in' 2 "$(in_week "$this_week")"
check 'none in the new week, where the last column of the table now reads' 0 "$(in_week "$next_week")"

# How well the tickets themselves are written is a question about the organisation and not
# about one board, and an answer covering half of it reads as an answer covering all of it.
echo 'with no repository named it reads every open board, and not the template'
: > "$log"
out="$("$count" 2>&1 | tr -d '\r')"
check 'the boards were asked'  1 "$(grep -c 'projectsV2(first:100)' "$log" || true)"
check 'the first was resolved' 1 "$(grep -c 'num=996' "$log" || true)"
check 'the second too'         1 "$(grep -c 'num=997' "$log" || true)"
check 'the template was not'   0 "$(grep -c 'num=999' "$log" || true)"

echo '--weeks changes the window'
out="$("$count" "$repo" --weeks 3 2>&1 | tr -d '\r')"
check 'three columns' 3 "$(echo "$out" | head -1 | awk '{print NF - 1}')"

echo 'a window that is not a number is refused'
out="$("$count" "$repo" --weeks soon 2>&1)"; rc=$?
check 'exits nonzero'      yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'the value is named' yes "$(grep -q 'soon' <<< "$out" && echo yes || echo no)"

echo 'a flag without its value is named'
out="$("$count" "$repo" --weeks 2>&1)"; rc=$?
check 'exits nonzero'  yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'names the flag' yes "$(grep -q -- '--weeks needs a value' <<< "$out" && echo yes || echo no)"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
