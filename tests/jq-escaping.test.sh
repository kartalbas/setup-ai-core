#!/usr/bin/env bash
# What reaches gh, and what an archived card survives. The Bash twin of
# jq-escaping.test.ps1, asserting the SAME rules against the same lib.
#
#   bash test/jq-escaping.test.sh
#
# Nothing is written to a real board: `gh` is a stand-in on PATH. It records every call,
# and for a graphql read it runs the REAL jq over a canned payload with the jq program it
# was handed - so a program that arrives mangled fails here exactly as it fails against
# github.com, with jq's own compile error.
#
# TWO WAYS A QUERY COMES BACK WITHOUT ROWS, and the stand-in reproduces both. Each was measured
# against github.com with gh 2.98.0, and they need different guards because they look nothing alike.
#
#   FAKE_GH_REFUSE      the server REFUSES. The FULL error body goes to STDOUT, where the rows would
#                       be, the one-line complaint goes to stderr, and gh exits 1. The --jq program
#                       is not run at all, so nothing filters the body out.
#   FAKE_GH_WRONG_KIND  the server ACCEPTS and answers `{}` with exit 0, which is what a query for a
#                       board's id gets when the id it names belongs to a repository instead. No
#                       status check can tell that from an answer; only the value can.
#
# The innocent case above them is what says a clean answer means the callers looked, rather than
# that nothing was looking.
#
# The payloads carry a double quote, a backslash, a dollar sign and three non-ASCII
# characters in the title, because that is what a board title, an issue title and a label
# are allowed to contain, because every jq program in this repository is built out of
# double-quoted strings, and because what gh writes back is UTF-8 whatever the console
# code page says.
#
# WHAT THIS DOES NOT REACH: a tab or a newline INSIDE one of those values. Every jq program
# here packs its fields into one tab-separated line, so a value carrying either separator
# splits the row and the reader downstream mis-reads it. Nothing on the board carries one
# today, and whether GitHub accepts one in a title cannot be established without writing to
# GitHub, so the row format is left as it is and this is stated rather than covered.
#
# The last section points `gh` at the real jq binary, which does nothing but print the
# argument vector it was started with. The newline lives there, on the way OUT, where an
# argument is one string and no line separates anything.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAKE="$(mktemp -d)"
export GH_CACHE_DIRECTORY="$FAKE/cache"
# A board number no real project carries, so the cache this writes cannot be mistaken
# for a live board's - and is removed again below.
PROJECT_NUMBER=999999
failed=0

cleanup() { rm -rf "$FAKE"; }
trap cleanup EXIT

check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}

# The characters a title is allowed to carry and a jq program is built out of. The JSON
# form is derived from the same string rather than typed twice, so the payload below and
# the expected value cannot drift apart.
#
# The three non-ASCII characters are written as their UTF-8 bytes so this file stays plain
# ASCII and the assertion cannot turn on how an editor or git stored it. U+00B7 is the
# middle dot the epic titles on this board are written with, U+00FC an umlaut, U+20AC a
# euro sign - one, two and three UTF-8 bytes, so a decoder reading the wrong code page is
# wrong differently for each of them.
NON_ASCII="$(printf '\xc2\xb7 \xc3\xbc \xe2\x82\xac')"
NASTY="$(printf 'a "quoted" title with %s and $dollar %s' '\' "$NON_ASCII")"
NASTY_JSON="$(printf '%s' "$NASTY" | jq -Rs . | tr -d '\r')"

# --- the canned answers -------------------------------------------------------

mkdir -p "$FAKE/gh" "$FAKE/argv"

cat > "$FAKE/gh/repo-projects.json" <<EOF
{"data":{"repository":{"projectsV2":{"nodes":[
  {"number":$PROJECT_NUMBER,"title":$NASTY_JSON,"closed":false},
  {"number":12,"title":"[TEMPLATE] shape","closed":false},
  {"number":3,"title":"an old board","closed":true}]}}}}
EOF

cat > "$FAKE/gh/project-id.json" <<'EOF'
{"data":{"organization":{"projectV2":{"id":"PVT_kwtestboard"}}}}
EOF

# Three items on three different boards and two different archive states. Only the one
# that is archived AND on this board may come back.
cat > "$FAKE/gh/archived.json" <<'EOF'
{"data":{"repository":{"issue":{"projectItems":{"nodes":[
  {"id":"PVTI_otherboard","isArchived":true,"project":{"id":"PVT_kwotherboard"}},
  {"id":"PVTI_archived","isArchived":true,"project":{"id":"PVT_kwtestboard"}},
  {"id":"PVTI_live","isArchived":false,"project":{"id":"PVT_kwtestboard"}}]}}}}}
EOF

cat > "$FAKE/gh/no-archived.json" <<'EOF'
{"data":{"repository":{"issue":{"projectItems":{"nodes":[]}}}}}
EOF

cat > "$FAKE/gh/added.json" <<'EOF'
{"data":{"addProjectV2ItemById":{"item":{"id":"PVTI_added"}}}}
EOF

cat > "$FAKE/gh/issue.json" <<'EOF'
{"node_id":"I_kwissue","id":8008}
EOF

# What a refused query answers with, copied from what github.com answered gh 2.98.0 for a node id
# it could not resolve. It is a whole JSON document on the channel the rows come back on, and its
# first field is not a row.
cat > "$FAKE/gh/refused.json" <<'EOF'
{"data":{"node":null},"errors":[{"type":"NOT_FOUND","path":["node"],"locations":[{"line":1,"column":19}],"message":"Could not resolve to a node with the global id of 'PVT_kwtestboard'"}]}
EOF

cat > "$FAKE/gh/items.json" <<EOF
{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"fieldValues":{"nodes":[
     {"name":"Todo","field":{"name":"Status"}},
     {"name":"P1","field":{"name":"Priority"}}]},
   "content":{"number":7,"title":$NASTY_JSON,"state":"OPEN","repository":{"name":"example-repo"}}},
  {"fieldValues":{"nodes":[]},
   "content":{"number":8,"title":"plain","state":"CLOSED","repository":{"name":"example-repo"}}}]}}}}
EOF

# --- the stand-in -------------------------------------------------------------

cat > "$FAKE/gh/gh" <<'EOF'
#!/usr/bin/env bash
d="$(cd "$(dirname "$0")" && pwd)"
printf '%s\n' "$*" >> "$d/calls"

# Both answers-without-rows come before anything is parsed: the real ones are decided by the
# server and reach every query alike, whatever it asked for.
if [ -n "${FAKE_GH_REFUSE:-}" ]; then
  cat "$d/refused.json"
  echo "gh: $FAKE_GH_REFUSE" >&2
  exit 1
fi
if [ -n "${FAKE_GH_WRONG_KIND:-}" ]; then
  echo '{}'
  exit 0
fi

prog=""; query=""; num=""; rest=""; prev=""
for a in "$@"; do
  [ "$prev" = "--jq" ] && prog="$a"
  case "$a" in
    query=*)         query="${a#query=}" ;;
    num=*)           num="${a#num=}" ;;
    repos/*/issues/*) rest="$a" ;;
  esac
  prev="$a"
done

payload=""
case "$query" in
  *addProjectV2ItemById*) payload=added.json ;;
  *projectItems*)         if [ "$num" = "8" ]; then payload=no-archived.json; else payload=archived.json; fi ;;
  *"projectsV2(first:50)"*) payload=repo-projects.json ;;
  *"projectV2(number:"*)  payload=project-id.json ;;
  *"items(first:100"*)    payload=items.json ;;
esac
[ -n "$payload" ] || { [ -n "$rest" ] && payload=issue.json; }
[ -n "$payload" ] || { echo "fake gh: nothing canned for: $*" >&2; exit 64; }

# The program goes through a FILE, so this hop adds no escaping of its own and what jq
# compiles is exactly the bytes gh was handed.
#
# gh writes LF on Windows and the jq binary writes CRLF, so the CR is dropped here. A
# stand-in that answered differently from the real command would put the callers' line
# handling under test instead of their escaping.
if [ -n "$prog" ]; then
  printf '%s' "$prog" > "$d/prog.jq"
  set -o pipefail
  jq -r -f "$d/prog.jq" "$d/$payload" | tr -d '\r'
  exit $?
fi
exec cat "$d/$payload"
EOF
chmod +x "$FAKE/gh/gh"

# A second stand-in that is nothing but real jq, to read back the argument vector a call
# actually arrives with.
cat > "$FAKE/argv/gh" <<'EOF'
#!/usr/bin/env bash
exec jq "$@"
EOF
chmod +x "$FAKE/argv/gh"

# shellcheck source=/dev/null
. "$ROOT/lib/board.sh"
# board.sh runs the bin scripts under `set -e`; a failed assertion here must be counted,
# not abort the run.
set +e

PATH="$FAKE/gh:$PATH"
calls() { cat "$FAKE/gh/calls" 2>/dev/null; }
: > "$FAKE/gh/calls"

echo 'a title with a quote, a backslash, a dollar and non-ASCII survives the trip'
check 'the board is resolved from its repo' "$PROJECT_NUMBER" \
      "$(resolve_project_for_repo example-org/example-repo)"

set_project "$PROJECT_NUMBER" >/dev/null
check 'the project id is read back' 'PVT_kwtestboard' "$(project_id)"

echo 'an archived card is found from the issue, and stays archived'
check 'the archived item on THIS board' 'PVTI_archived' \
      "$(archived_item_id example-org/example-repo 7)"

: > "$FAKE/gh/calls"
check 'item_id hands the archived id back' 'PVTI_archived' \
      "$(item_id example-org/example-repo 7)"
if calls | grep -q addProjectV2ItemById; then
  check 'and adds nothing' 'no add' "$(calls | grep -c addProjectV2ItemById) adds"
else
  check 'and adds nothing' 'no add' 'no add'
fi

: > "$FAKE/gh/calls"
check 'an issue with no item is still added' 'PVTI_added' \
      "$(item_id example-org/example-repo 8)"
if calls | grep -q addProjectV2ItemById; then
  check 'by the add mutation' 'added' 'added'
else
  check 'by the add mutation' 'added' 'nothing was added'
fi

echo 'and the board reads back with the title intact'
squeeze() { sed 's/  */ /g'; }
rows="$("$ROOT/bin/board-list.sh" --project "$PROJECT_NUMBER" 2>&1 | squeeze)"
check 'an open card keeps its status, priority and title' \
      "Todo P1 example-repo #7 $NASTY" \
      "$(printf '%s\n' "$rows" | grep -F '#7')"
check 'a card with no field values reads as - -, and closed says so' \
      '- - example-repo #8 plain [closed]' \
      "$(printf '%s\n' "$rows" | grep -F '#8')"

echo 'a refused query is not an empty result'
export FAKE_GH_REFUSE="Could not resolve to a node with the global id of 'PVT_kwtestboard'"

: > "$FAKE/gh/calls"
answer="$( { archived_item_id example-org/example-repo 7; } 2>&1 )" && stopped=no || stopped=yes
check 'archived_item_id stops'            yes "$stopped"
check 'and hands back no item id'         yes "$(case "$answer" in *PVTI_*) echo no ;; *) echo yes ;; esac)"
check 'and says which query was refused'  yes "$(case "$answer" in *'the project items of example-org/example-repo#7'*) echo yes ;; *) echo no ;; esac)"

# THE ONE THAT COSTS A CARD. A refusal read as "this issue has no archived item" is not a wrong
# line on a screen: the next call takes the card OUT of the archive, which is the owner's decision
# and nothing else's. So what is asserted is that the mutation was never reached.
: > "$FAKE/gh/calls"
printed="$( { item_id example-org/example-repo 7; } 2>/dev/null )" && stopped=no || stopped=yes
check 'item_id stops rather than adding'  yes "$stopped"
check 'and nothing reached the board'     'no add' \
      "$(if calls | grep -q addProjectV2ItemById; then echo added; else echo 'no add'; fi)"
check 'and no item id is printed'         '' "$printed"

# End to end, in the process bin/ actually runs in, where the refusal has to survive a pipeline
# and reach the exit status.
rows="$("$ROOT/bin/board-list.sh" --project "$PROJECT_NUMBER" 2>/dev/null)" && ended=0 || ended=1
check 'board-list stops'                  1  "$ended"
check 'and prints no card'                '' "$rows"

unset FAKE_GH_REFUSE

echo 'a query gh accepts, answering with something that is not a board'
CACHE="$GH_CACHE_DIRECTORY/$PROJECT_NUMBER"

export FAKE_GH_WRONG_KIND=1
rm -rf "$CACHE"
answer="$( { project_id; } 2>&1 )" && stopped=no || stopped=yes
check 'project_id stops'                  yes "$stopped"
check 'and prints no id'                  yes "$(case "$answer" in *PVT_*) echo no ;; *) echo yes ;; esac)"
# The cache is the answer for every later run, and nothing asks again once it is not empty.
check 'and nothing is cached as an answer' 'nothing cached' \
      "$([ -s "$CACHE/project-id" ] && echo "cached $(cat "$CACHE/project-id")" || echo 'nothing cached')"
unset FAKE_GH_WRONG_KIND

# The same value already sitting in the cache, which is how a machine that ran this tooling before
# the guard existed is found. Nothing asks gh at all on this path.
mkdir -p "$CACHE"; printf '%s\n' '{}' > "$CACHE/project-id"
answer="$( { project_id; } 2>&1 )" && stopped=no || stopped=yes
check 'a cached non-id stops it too'      yes "$stopped"
check 'and names the file holding it'     yes "$(case "$answer" in *"$CACHE/project-id"*) echo yes ;; *) echo no ;; esac)"
rm -rf "$CACHE"

echo 'what the process itself receives'
PATH="$FAKE/argv:$PATH"
program='.data.node.items.nodes[]
| select(.content.state == "CLOSED")
| "\(.number)\t\(.title)"'
title="$(printf 'He said "no" \\ path\\to $HOME\nand a second line %s' "$NON_ASCII")"
seen="$(gh -n --args '$ARGS.positional' -- "$program" "$title")"
check 'a jq program arrives verbatim' "$program" "$(printf '%s' "$seen" | jq -r '.[0]' | tr -d '\r')"
check 'a title arrives verbatim'      "$title"   "$(printf '%s' "$seen" | jq -r '.[1]' | tr -d '\r')"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo; echo 'all passed'
