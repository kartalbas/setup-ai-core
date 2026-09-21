#!/usr/bin/env bash
# What board-sync REPORTS, and which of its numbers a reader can do something with.
#
#   bash test/board-sync.test.sh
#
# NOTHING REACHES github.com. A stand-in `gh` is on PATH for the whole run and answers a
# prepared board, a prepared repository list and a prepared issue list, so every shape below
# is one somebody would otherwise have to create real cards to produce - a card carrying no
# priority, a closed card carrying none, a card GitHub stamped a status onto as it was added.
# A project id is seeded into the cache under a board number of this run's own, and the
# stand-in answers the id query as well, so no real board is ever resolved and no run depends
# on what another one left behind.
#
# THE CLASS THIS HOLDS CLOSED. This sweep is the one report the owner reads to find out what
# is missing, and a REPORT is only worth what a reader can act on. A ticket that is OPEN and
# carries no priority is work somebody can still decide about, so it is named with its repo,
# its number and its title. A CLOSED one is not: a priority put on a finished ticket by
# somebody who did not work it is a guess, and this tool reports rather than guesses. Held as
# one number the two are indistinguishable, and the one ticket that can be fixed disappears
# into a count that is mostly finished work.
#
# THE PLANTED DEFECTS, one of each shape the report has to tell apart:
#   #3 and #5 are OPEN and carry no priority   -> both named, one per line
#   #2 is CLOSED and carries none              -> counted, never named
#   #2 carries no label at all, and is closed  -> counted, never named
#   #3 carries an area label and no type       -> named, because it is open
#
# THE PLANTED INNOCENT CASES are #1 and #4, which carry a priority and both labels. Neither
# may appear anywhere in the report - without them a script that named every card it read
# would pass every assertion above. A whole innocent BOARD is run at the end for the same
# reason one level up: nothing missing anywhere, and the run must still say what it looked at.
#
# EVERY COUNT IS ASSERTED WITH ITS DENOMINATOR. "1 missing" reads the same on a board of two
# cards and a board of two hundred, and it reads the same on a run that read nothing at all.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAKE="$(mktemp -d)"
export GH_CACHE_DIRECTORY="$FAKE/cache"
PROJECT_NUMBER=999997
PROJECT_ID='PVT_kwboardtest'
failed=0

cleanup() { rm -rf "$FAKE"; }
trap cleanup EXIT

check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}

# A block of lines as one string, so a report is asserted whole and a line that moved is
# shown next to the line it moved from.
joined() { printf '%s\n' "$@" | paste -sd'|' -; }

mkdir -p "$GH_CACHE_DIRECTORY/$PROJECT_NUMBER"
printf '%s\n' "$PROJECT_ID" > "$GH_CACHE_DIRECTORY/$PROJECT_NUMBER/project-id"

# --- the prepared answers -----------------------------------------------------

# The stand-in answers the project-id query as well as the rest, so a run whose seeded cache is
# gone asks for the id and is given the same one. Without it the verdict depends on a file under
# the repository surviving the whole run, and a run that lost it goes red about the stand-in
# instead of about board-sync.
printf '{"data":{"organization":{"projectV2":{"id":"%s"}}}}\n' "$PROJECT_ID" > "$FAKE/project-id.json"
cat > "$FAKE/repos.json" <<'JSON'
{"data":{"node":{"repositories":{"nodes":[{"nameWithOwner":"example-org/example"}]}}}}
JSON
cat > "$FAKE/archived.json" <<'JSON'
{"data":{"repository":{"issue":{"projectItems":{"nodes":[]}}}}}
JSON
cat > "$FAKE/node.json" <<'JSON'
{"node_id":"I_kwexample"}
JSON
cat > "$FAKE/item.json" <<'JSON'
{"data":{"addProjectV2ItemById":{"item":{"id":"PVTI_kwexample"}}}}
JSON

# One card as the board query answers it. A card with no priority simply has no Priority
# value among its field values, which is how the board answers for a field nobody set -
# board-list turns that absence into the "-" column this report reads.
card() { # card <number> <title> <state> <status> <priority or ->
  local prio=""
  [ "$5" = "-" ] || prio=",{\"name\":\"$5\",\"field\":{\"name\":\"Priority\"}}"
  printf '{"fieldValues":{"nodes":[{"name":"%s","field":{"name":"Status"}}%s]},"content":{"number":%s,"title":"%s","state":"%s","repository":{"name":"example"}}}' \
    "$4" "$prio" "$1" "$2" "$3"
}
board() { # board <card>...
  local IFS=,
  printf '{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[%s]}}}}' "$*"
}
issue() { # issue <number> <state> <title> <space separated labels>
  local names="" l
  for l in ${4:-}; do names="$names${names:+,}{\"name\":\"$l\"}"; done
  printf '{"number":%s,"state":"%s","title":"%s","labels":[%s]}' "$1" "$2" "$3" "$names"
}
issues() { # issues <issue>...
  local IFS=,
  printf '[%s]' "$*"
}

# The stand-in answers each query by what it asked for, and RUNS the --jq program the caller
# gave, the way gh does. Answering the raw document instead would let a script that never
# reads its answer pass. The two board reads are answered from two different documents, so
# what was on the board before the sweep and what is on it after are genuinely different.
mkdir -p "$FAKE/bin"
cat > "$FAKE/bin/gh" <<EOF
#!/usr/bin/env bash
prog=""; prev=""
for a in "\$@"; do
  [ "\$prev" = "--jq" ] && prog="\$a"
  prev="\$a"
done
case "\$*" in
  *"projectV2(number:"*)       doc="$FAKE/project-id.json" ;;
  *"repositories(first:100)"*) doc="$FAKE/repos.json" ;;
  *"items(first:100, after:"*)
    n=\$(cat "$FAKE/reads" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "$FAKE/reads"
    doc="$FAKE/board-\$n.json" ;;
  *"issue list"*)              doc="$FAKE/issues.json" ;;
  *"projectItems(first:20"*)   doc="$FAKE/archived.json" ;;
  *"addProjectV2ItemById"*)    doc="$FAKE/item.json" ;;
  *"/issues/"*)                doc="$FAKE/node.json" ;;
  *) echo "the stand-in gh has no answer for: \$*" >&2; echo "PROBE cache: [\$(ls -la "$GH_CACHE_DIRECTORY/$PROJECT_NUMBER" 2>&1 | tr '
' '~')]" >&2; exit 9 ;;
esac
# A query the stand-in recognised but has no document for - a THIRD read of the board is the
# one that happens - refuses by name. Handed to jq instead it dies about a file, which reads
# as a broken test rather than as the run asking one time too often.
[ -f "\$doc" ] || { echo "the stand-in gh has no \$doc prepared" >&2; exit 9; }
# The jq BINARY writes CRLF on Windows where gh's own --jq writes LF, and stripping it is
# what makes the stand-in answer the way gh does. Left in, every line the caller reads ends
# in a carriage return and a pattern anchored at the end of a line matches nothing.
if [ -n "\$prog" ]; then jq -r "\$prog" < "\$doc" | tr -d '\r'
else cat "\$doc"; fi
exit 0
EOF
chmod +x "$FAKE/bin/gh"
export PATH="$FAKE/bin:$PATH"

# ONE run per board, and every assertion below reads the lines that run produced. Sweeping
# again per assertion would let two of them describe two different runs, and it multiplies
# whatever a busy machine does to one of the several processes a sweep starts.
sweep() {
  rm -f "$FAKE/reads"
  bash "$ROOT/bin/board-sync.sh" --project "$PROJECT_NUMBER" 2>&1
}
lines() { printf '%s\n' "$run"; }

# --- the board with a gap of every shape --------------------------------------

# #5 is on the board after the sweep and not before it, which is the item GitHub stamps a
# status onto as it is added.
on_board_before="$(board \
  "$(card 1 'Add the job-completion endpoint'   'OPEN'   'todo' 'P1')" \
  "$(card 2 'Rename the sweep that no longer sweeps' 'CLOSED' 'done' '-')" \
  "$(card 3 'Read the install order from one file'   'OPEN'   'todo' '-')" \
  "$(card 4 'Take a label off an issue'         'CLOSED' 'done' 'P2')")"
on_board_after="$(board \
  "$(card 1 'Add the job-completion endpoint'   'OPEN'   'todo' 'P1')" \
  "$(card 2 'Rename the sweep that no longer sweeps' 'CLOSED' 'done' '-')" \
  "$(card 3 'Read the install order from one file'   'OPEN'   'todo' '-')" \
  "$(card 4 'Take a label off an issue'         'CLOSED' 'done' 'P2')" \
  "$(card 5 'Name the tickets that carry no priority' 'OPEN' 'todo' '-')")"

printf '%s' "$on_board_before" > "$FAKE/board-1.json"
printf '%s' "$on_board_after"  > "$FAKE/board-2.json"
printf '%s' "$(issues \
  "$(issue 1 'OPEN'   'Add the job-completion endpoint'       'type:feature area:tooling')" \
  "$(issue 2 'CLOSED' 'Rename the sweep that no longer sweeps' '')" \
  "$(issue 3 'OPEN'   'Read the install order from one file'  'area:tooling')" \
  "$(issue 4 'CLOSED' 'Take a label off an issue'             'type:feature area:tooling')" \
  "$(issue 5 'OPEN'   'Name the tickets that carry no priority' 'type:bug area:tooling')")" \
  > "$FAKE/issues.json"

run="$(sweep)"

echo 'the whole report, which is what both shells are held to'

check 'reads line for line' \
  "$(joined \
    'example-org/example' \
    '  #3    missing label: type         Read the install order from one file' \
    '' \
    '1 of 3 OPEN issues are missing a type or an area label, listed above' \
    '1 of 2 closed issues are missing one too, and are not listed -' \
    '  labelling somebody else'"'"'s finished ticket is a guess, and nothing on the board filters on it' \
    '' \
    '1 of the 5 cards on the board were NOT on it before this run.' \
    'GitHub stamped each one with a status as it was added - it is the first word of every' \
    'line below. Move whatever does not belong there:' \
    '  todo            -   example                #5    Name the tickets that carry no priority' \
    '' \
    'OPEN cards on the board that carry no priority:' \
    '  todo            -   example                #3    Read the install order from one file' \
    '  todo            -   example                #5    Name the tickets that carry no priority' \
    '2 of 3 OPEN cards carry no priority, listed above' \
    '1 of 2 closed cards carry none either, and are not listed -' \
    '  a priority put on a finished ticket by somebody who did not work it is a guess')" \
  "$(lines | paste -sd'|' -)"

echo
echo 'the priority gap'

check 'every OPEN card that carries none is named, with its repo, its number and its title' \
  "$(joined \
    'OPEN cards on the board that carry no priority:' \
    '  todo            -   example                #3    Read the install order from one file' \
    '  todo            -   example                #5    Name the tickets that carry no priority')" \
  "$(lines | grep -A2 '^OPEN cards on the board that carry no priority:$' | paste -sd'|' -)"

check 'the count beside them says what they were counted out of' \
  '2 of 3 OPEN cards carry no priority, listed above' \
  "$(lines | grep 'OPEN cards carry no priority')"

check 'the CLOSED one is counted, with its own denominator' \
  '1 of 2 closed cards carry none either, and are not listed -' \
  "$(lines | grep 'closed cards carry none either')"

check 'and the CLOSED one is nowhere named' 0 \
  "$(lines | grep -c 'Rename the sweep that no longer sweeps')"

echo
echo 'the label gap, which is the report this one was made to match'

check 'the OPEN issue missing a label is named and counted out of the open ones' \
  "$(joined \
    '  #3    missing label: type         Read the install order from one file' \
    '1 of 3 OPEN issues are missing a type or an area label, listed above')" \
  "$(lines | grep -E '^  #3 |OPEN issues are missing' | paste -sd'|' -)"

check 'the CLOSED one is counted out of the closed ones' \
  '1 of 2 closed issues are missing one too, and are not listed -' \
  "$(lines | grep 'closed issues are missing')"

echo
echo 'the card GitHub stamped a status onto as it was added'

check 'is listed with the column it landed in, not with its number alone' \
  "$(joined \
    '1 of the 5 cards on the board were NOT on it before this run.' \
    'GitHub stamped each one with a status as it was added - it is the first word of every' \
    'line below. Move whatever does not belong there:' \
    '  todo            -   example                #5    Name the tickets that carry no priority')" \
  "$(lines | grep -A3 'cards on the board were NOT on it before this run' | paste -sd'|' -)"

echo
echo 'the board is read once for both reports'

check 'twice in all - before the sweep and after it, never a third time' 2 \
  "$(cat "$FAKE/reads")"

echo
echo 'the innocent cards'

check 'a card that carries a priority and both labels appears nowhere' 0 \
  "$(lines | grep -cE 'Add the job-completion endpoint|Take a label off an issue')"

# THE INNOCENT BOARD. Nothing missing anywhere: every card carries a priority, every issue
# carries both labels, and nothing was added. The run must still say what it looked at, or a
# board with no gaps could not be told from a board that was never read.
echo
echo 'a board and a repository with nothing missing'

nothing_missing="$(board \
  "$(card 1 'Add the job-completion endpoint'   'OPEN'   'todo' 'P1')" \
  "$(card 2 'Rename the sweep that no longer sweeps' 'CLOSED' 'done' 'P3')" \
  "$(card 3 'Read the install order from one file'   'OPEN'   'todo' 'P2')" \
  "$(card 4 'Take a label off an issue'         'CLOSED' 'done' 'P2')" \
  "$(card 5 'Name the tickets that carry no priority' 'OPEN' 'todo' 'P1')")"
printf '%s' "$nothing_missing" > "$FAKE/board-1.json"
printf '%s' "$nothing_missing" > "$FAKE/board-2.json"
printf '%s' "$(issues \
  "$(issue 1 'OPEN'   'Add the job-completion endpoint'       'type:feature area:tooling')" \
  "$(issue 2 'CLOSED' 'Rename the sweep that no longer sweeps' 'type:chore area:tooling')" \
  "$(issue 3 'OPEN'   'Read the install order from one file'  'type:feature area:tooling')" \
  "$(issue 4 'CLOSED' 'Take a label off an issue'             'type:feature area:tooling')" \
  "$(issue 5 'OPEN'   'Name the tickets that carry no priority' 'type:bug area:tooling')")" \
  > "$FAKE/issues.json"

run="$(sweep)"

check 'reports nothing missing, and still says what it read' \
  "$(joined \
    'example-org/example' \
    '' \
    '0 of 3 OPEN issues are missing a type or an area label, listed above' \
    '0 of 2 closed issues are missing one too, and are not listed -' \
    '  labelling somebody else'"'"'s finished ticket is a guess, and nothing on the board filters on it' \
    '' \
    '0 of 3 OPEN cards carry no priority' \
    '0 of 2 closed cards carry none either, and are not listed -' \
    '  a priority put on a finished ticket by somebody who did not work it is a guess')" \
  "$(lines | paste -sd'|' -)"

check 'and prints no list header above nothing' 0 \
  "$(lines | grep -c 'OPEN cards on the board that carry no priority:')"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo; echo 'all passed'
