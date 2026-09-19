#!/usr/bin/env bash
# Validate a solution path and optionally post it under a GitHub issue.
#
#   solution-path.sh FILE [--check] [--issue NUMBER]
#
set -euo pipefail

for arg in "$@"; do
  if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
  echo "Usage: solution-path.sh <file> [--check]"
  echo ""
  echo "Validates a solution path document against the 8 required sections."
  echo ""
  echo "Options:"
  echo "  -h, --help    Show this help message"
  echo "  --check       Enforce validation and exit with error if incomplete"
  echo ""
  echo "Examples:"
  echo "  ai-core solution-path docs/my-solution.md --check"
  exit 0
  fi
done

usage='usage: solution-path.sh FILE [--check] [--issue NUMBER]'

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
issue_num=""
file=""

while [ $# -gt 0 ]; do
  case "$1" in
    --check)     check_only=1; shift ;;
    --issue)     shift; [ $# -gt 0 ] || { echo "error: --issue requires a number" >&2; exit 1; }; issue_num="$1"; shift ;;
    -h|--help)   echo "$usage"; exit 0 ;;
    -*)          echo "error: unknown argument '$1'" >&2; exit 1 ;;
    *)
      if [ -z "$file" ]; then
        file="$1"; shift
      else
        echo "error: unexpected argument '$1'" >&2; exit 1
      fi
      ;;
  esac
done

[ -n "$file" ] || { echo "$usage" >&2; exit 1; }
[ -f "$file" ] || { echo "error: file not found: $file" >&2; exit 1; }

echo "==> Validating solution path: $file"

# Extract all ## headings
headings="$(awk '
  /^##[[:space:]]/ {
    line = substr($0, 4)
    sub(/^[[:space:]]+/, "", line)
    sub(/[[:space:]]+$/, "", line)
    print line
  }
' "$file")"

# Check for duplicates
doubled=()
for want in "${REQUIRED[@]}"; do
  count="$(printf '%s\n' "$headings" | grep -cxF "$want" || true)"
  if [ "$count" -gt 1 ]; then
    doubled+=("$want")
  fi
done

if [ ${#doubled[@]} -gt 0 ]; then
  echo "error: duplicate required headings found in $file:" >&2
  for d in "${doubled[@]}"; do
    echo "  - ## $d (appears multiple times)" >&2
  done
  exit 1
fi

# Function to get section body
section_body() {
  local want="$1"
  awk -v want="$want" '
    /^##[ \t]/ {
      if (inside) exit
      line = substr($0, 4); sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line)
      inside = (line == want)
      next
    }
    inside { print }
  ' "$file"
}

strip_comments() {
  awk '
    BEGIN { in_comment = 0 }
    {
      line = $0
      while (length(line) > 0) {
        if (!in_comment) {
          start = index(line, "<!--")
          if (start > 0) {
            printf "%s", substr(line, 1, start - 1)
            line = substr(line, start + 4)
            in_comment = 1
          } else {
            print line
            break
          }
        } else {
          end = index(line, "-->")
          if (end > 0) {
            line = substr(line, end + 3)
            in_comment = 0
          } else {
            break
          }
        }
      }
    }
  '
}

absent=()
empty=()

for want in "${REQUIRED[@]}"; do
  if ! printf '%s\n' "$headings" | grep -qxF "$want"; then
    absent+=("$want")
  else
    body_no_comments="$(section_body "$want" | strip_comments | tr -d '[:space:]')"
    if [ -z "$body_no_comments" ]; then
      empty+=("$want")
    fi
  fi
done

has_errors=0

if [ ${#absent[@]} -gt 0 ]; then
  has_errors=1
  echo "error: missing required headings in $file:" >&2
  for a in "${absent[@]}"; do
    echo "  - ## $a" >&2
  done
fi

if [ ${#empty[@]} -gt 0 ]; then
  has_errors=1
  echo "error: empty sections (or placeholder only) in $file:" >&2
  for e in "${empty[@]}"; do
    echo "  - ## $e" >&2
  done
fi

if [ "$has_errors" -ne 0 ]; then
  echo "Validation FAILED. All 8 sections must be present and filled with substantive content." >&2
  exit 1
fi

echo "✓ Solution path is VALID (all 8 sections populated)."

# Post to GitHub issue if requested and not check-only
if [ "$check_only" -eq 0 ] && [ -n "$issue_num" ]; then
  if command -v gh >/dev/null 2>&1; then
    echo "==> Posting solution path to GitHub Issue #$issue_num..."
    gh issue comment "$issue_num" --body-file "$file"
    echo "✓ Posted to Issue #$issue_num"
  else
    echo "warning: gh CLI not available, could not post to issue" >&2
  fi
fi
