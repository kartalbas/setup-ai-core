#!/usr/bin/env bash
# Check a solution path and post it under its issue.
#
#   solution-path.sh NUMBER FILE [--check]
#
# The seven fields and the reuse manifest are what makes a decision reviewable: where a person
# meets it, what they see today, what runs behind that, the decision itself, the options with
# what each costs, the recommendation, the code facts, and the list of everything that already
# exists and that this change touches or resembles. A missing field is not a formatting slip -
# it is the part of the answer that was not thought through, and it is cheapest to notice
# before the code is written.
#
# A section is measured by what it CONTAINS and not by whether its heading is there, because a
# heading with nothing under it reads as a filled-in field to every list that counts headings.
#
# --check validates and posts nothing, for a writer who wants to know before they send.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/board.sh"

BIN="$ROOT/bin"
usage='usage: solution-path.sh NUMBER FILE [--check]'

# The headings a solution path must carry, in the order a reader walks them.
REQUIRED=(
  'Where a person meets this'
  'What they see today'
  'What the system does behind it'
  'The decision'
  'Options'
  'Recommendation'
  'Code facts'
  'Reuse manifest'
)

check_only=0
rest=()
while [ $# -gt 0 ]; do
  case "$1" in
    --check)   check_only=1; shift ;;
    -h|--help) echo "$usage"; exit 0 ;;
    -*)        die "unknown argument '$1'" ;;
    *)         rest+=("$1"); shift ;;
  esac
done

[ ${#rest[@]} -eq 2 ] || die "$usage"
number="${rest[0]}"
file="${rest[1]}"
case "$number" in ''|*[!0-9]*) die "the issue number must be numeric, not '$number' - $usage" ;; esac
[ -f "$file" ] || die "there is no file at $file"

# Every "## " heading in the file. A deeper heading stands INSIDE its section and is not one.
headings="$(awk '
  /^##[[:space:]]/ {
    line = substr($0, 4)
    sub(/^[[:space:]]+/, "", line)
    sub(/[[:space:]]+$/, "", line)
    print line
  }
' "$file")"

# What one heading has under it, down to the next "## " heading.
section_body() {  # section_body <heading>
  awk -v want="$1" '
    /^##[ \t]/ {
      if (inside) exit
      line = substr($0, 4); sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line)
      inside = (line == want)
      next
    }
    inside { print }
  ' "$file"
}

join_with() {  # join_with <separator> <item>...
  local sep="$1" out='' item; shift
  for item in "$@"; do out="${out:+$out$sep}$item"; done
  printf '%s' "$out"
}

# A required heading that stands twice is refused before anything else is judged. Only one of
# its two bodies is ever read, and which one it is differs between the two shells, so the same
# file would be accepted by one and refused by the other.
doubled=()
for want in "${REQUIRED[@]}"; do
  [ "$(grep -cxF "$want" <<< "$headings" || true)" -le 1 ] || doubled+=("$want")
done
if [ ${#doubled[@]} -gt 0 ]; then
  echo "$file names \"## $(join_with '", "## ' "${doubled[@]}")\" twice." >&2
  die 'a required heading may stand only once - with two of them one body is read and the other is not'
fi

absent=()
empty=()
for want in "${REQUIRED[@]}"; do
  if ! grep -qxF "$want" <<< "$headings"; then
    absent+=("$want")
  elif [ -z "$(section_body "$want" | tr -d '[:space:]')" ]; then
    empty+=("$want")
  fi
done

if [ ${#absent[@]} -gt 0 ] || [ ${#empty[@]} -gt 0 ]; then
  [ ${#absent[@]} -eq 0 ] \
    || echo "$file has no \"## $(join_with '", no "## ' "${absent[@]}")\" heading." >&2
  [ ${#empty[@]} -eq 0 ] \
    || echo "$file leaves \"$(join_with '", "' "${empty[@]}")\" empty." >&2
  die 'write those sections, then run this again - code starts after the solution path is posted'
fi

echo "$file carries all ${#REQUIRED[@]} sections."

if [ "$check_only" -eq 1 ]; then
  echo 'Checked only - nothing was posted.'
  exit 0
fi

# The file travels as a file: its backticks, quotes and newlines reach GitHub as they were
# written, because no shell reads them on the way.
posted="$("$BIN/issue-comment.sh" "$number" --body-file "$file" 2>&1)" \
  || die "the solution path was NOT posted: $posted"
printf '%s\n' "$posted"
