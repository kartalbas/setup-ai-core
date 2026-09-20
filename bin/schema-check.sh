#!/usr/bin/env bash
# Does every mutation this repository sends name a field the interface really has?
#
#   schema-check.sh [DIRECTORY]
#
# It reads every .sh, .ps1 and .psm1 under bin/ and lib/ of DIRECTORY - this repository when none
# is named - finds the GraphQL mutations written in them, and holds each one against the schema
# github.com publishes. Two things are asked of every mutation: the root field must be one the
# interface has, and the field asked of its answer must stand on that mutation's payload type.
#
# WHY THIS IS A COMMAND AND NOT A TEST. Every test here runs against a fake gh on PATH, so nothing
# in test/ reaches github.com and nothing there can know whether a field name is real. That is
# what let `updateProjectV2ItemPosition(...) { projectV2Item { id } }` stand in lib/board.sh and
# lib/Board.psm1 under two green tests: the interface validates a mutation document before it
# executes it, so it refuses the whole thing and no card moves. This is the one step of
# scripts/check.sh that reaches github.com, and it stands beside the two suites rather than inside
# them, so test/ keeps reaching nothing.
#
# IT IS RED WHEN THE INTERFACE CANNOT BE READ, and never skipped. A check that passes itself when
# it could not look reports green for a question nobody asked.
#
# WHAT IT READS AND WHAT IT DOES NOT, named rather than counted. It reads the FIRST field asked of
# each mutation's answer. It does not read deeper selections, it does not read queries, and it
# does not read the fields of the input object.
#
# COMMENTS ARE DROPPED BEFORE ANYTHING IS MATCHED, and both shells write them differently. A line
# whose first character is a hash is dropped, and so is a PowerShell block comment - the lines
# from the one that opens it to the one that closes it. Without the second, a mutation quoted in
# a .ps1 help block is counted as code, and the two twins then disagree about the same tree,
# because the shell twin drops that same sentence when it stands in a .sh file. A block comment
# opened in the middle of a line is not dropped; no file here writes one.
#
# ONE CALL ANSWERS EVERYTHING. The Mutation type's own fields carry both the name of every
# mutation and, one level down, the fields of the payload it answers with.

set -uo pipefail

usage='usage: schema-check.sh [DIRECTORY]'

case "${1:-}" in
  -h|--help) echo "$usage"; exit 0 ;;
  -*) echo "error: unknown argument '$1'" >&2; exit 2 ;;
esac
[ $# -le 1 ] || { echo "error: $usage" >&2; exit 2; }

root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
[ -d "$root" ] || { echo "error: there is no directory at $root" >&2; exit 2; }

command -v gh >/dev/null 2>&1 || { echo "error: gh is not on PATH, and the schema is read through it" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "error: jq is not on PATH, and the schema is read through it" >&2; exit 2; }

where=()
for d in bin lib; do [ -d "$root/$d" ] && where+=("$root/$d"); done
[ ${#where[@]} -gt 0 ] || { echo "error: $root has neither a bin/ nor a lib/ to read" >&2; exit 2; }

# gh writes its error body to STDOUT where the answer would be and exits non-zero, so the status
# is what decides, exactly as gh_read in lib/board.sh does. A caller reading the text alone would
# take the complaint for a schema with no mutations in it.
schema="$(gh api graphql -f query='{ __type(name:"Mutation") { fields { name type { name fields { name } } } } }' 2>&1)"
if [ $? -ne 0 ]; then
  printf '%s\n' "$schema" >&2
  echo 'schema-check: FAIL - the interface could not be read, so no mutation was checked' >&2
  exit 1
fi

# One row per mutation: its name, the payload type it answers with, and that payload's fields.
# tr strips the carriage return jq writes on Windows; an unstripped field name matches nothing and
# every selection would be reported as absent.
pairs="$(printf '%s' "$schema" | jq -r '.data.__type.fields[]
  | [ .name, (.type.name // "-"), ((.type.fields // []) | map(.name) | join(",")) ] | @tsv' | tr -d '\r')"
if [ $? -ne 0 ] || [ -z "$pairs" ]; then
  echo 'schema-check: FAIL - the interface named no mutation, so there was nothing to check against' >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
printf '%s\n' "$pairs" > "$tmp/schema.tsv"

# LC_ALL=C, so the two twins list their refusals in the same order. A locale that folds
# punctuation orders the same names differently, and the PowerShell twin sorts ordinally.
files=()
while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done <<EOF
$(find "${where[@]}" -type f \( -name '*.sh' -o -name '*.ps1' -o -name '*.psm1' \) | LC_ALL=C sort)
EOF
if [ ${#files[@]} -eq 0 ]; then
  echo "schema-check: FAIL - no script was found under $root" >&2
  exit 1
fi

# The file is read twice over one buffer. A mutation document runs over several physical lines in
# a .sh file, so the lines are joined with a space first and the match is made on the whole thing.
# Each pass advances past the OPENING PARENTHESIS of the match it just took, not past the whole
# match: a mutation document opens `mutation(...) { <root>(`, so a pass that consumed its whole
# match would swallow the root name and never see the selection under it.
awk -v root="$root" '
function short(p) {
  # The file named without the directory the run was pointed at, so the report is read in one
  # glance. A path outside that directory is printed whole.
  if (index(p, root "/") == 1) return substr(p, length(root) + 2)
  return p
}
function lineof(name,   i) {
  # The physical line the name is called on. The buffer has lost the line breaks, so the line is
  # found by looking the call up again in the lines that were kept.
  for (i = 1; i <= nl; i++) if (index(L[i], name "(") > 0) return i
  return 0
}
function named(hit,   name) {
  # The identifier a match ends on. The pattern ends with `{ <identifier>`, and the greedy `.*`
  # runs to the LAST brace of the match - the selection brace. Cutting at the FIRST one would
  # hand back the input object, because `input:{` opens a brace of its own.
  name = hit
  sub(/^.*\{[ \t]*/, "", name)
  return name
}
function flush(   s, hit, p, q, r, f) {
  s = buf
  while (match(s, /mutation[ \t]*(\([^)]*\))?[ \t]*\{[ \t]*[A-Za-z_][A-Za-z0-9_]*/)) {
    hit = substr(s, RSTART, RLENGTH)
    q = index(hit, "{")
    r = named(hit)
    if (!(r in payload)) {
      bad++
      printf "%s:%d names `%s`, and the interface has no mutation of that name\n", short(cur), lineof(r), r
    }
    s = substr(s, RSTART + q)
  }
  s = buf
  while (match(s, /[A-Za-z_][A-Za-z0-9_]*\([^)]*\)[ \t]*\{[ \t]*[A-Za-z_][A-Za-z0-9_]*/)) {
    hit = substr(s, RSTART, RLENGTH)
    p = index(hit, "(")
    r = substr(hit, 1, p - 1)
    if (r in payload) {
      f = named(hit)
      seen++
      if (index("," fields[r] ",", "," f ",") == 0) {
        bad++
        printf "%s:%d asks `%s` for `%s`, and %s has: %s\n", short(cur), lineof(r), r, f, payload[r], fields[r]
      }
    }
    s = substr(s, RSTART + p)
  }
  nfiles++
}
NR == FNR { payload[$1] = $2; fields[$1] = $3; next }
FILENAME != cur { if (cur != "") flush(); cur = FILENAME; buf = ""; nl = 0; inblock = 0 }
{
  nl++; L[nl] = $0
  if ($0 ~ /^[ \t]*<#/) inblock = 1
  if (inblock) { if ($0 ~ /#>[ \t]*$/) inblock = 0; next }
  if ($0 !~ /^[ \t]*#/) buf = buf " " $0
}
END {
  if (cur != "") flush()
  print ""
  if (bad > 0) {
    printf "schema-check: %d mutation selection(s) in %d file(s), %d refused.\n", seen, nfiles, bad
    exit 1
  }
  printf "schema-check: %d mutation selection(s) in %d file(s), every one on the payload the interface publishes.\n", seen, nfiles
}
' "$tmp/schema.tsv" "${files[@]}"
