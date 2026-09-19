#!/usr/bin/env bash
# Validate that every rule carries an explicit enforcement tag.
#
#   rules-check.sh [FILE_OR_DIRECTORY]
#
set -euo pipefail

for arg in "$@"; do
  if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
  echo "Usage: rules-check.sh [file-or-directory]"
  echo ""
  echo "Validates that every rule (a bullet with its wrapped lines) ends with an enforcement tag:"
  echo "[machine], [tool], [review] or [discipline]. A directory means every NN-*.md section file in it."
  echo "Default: .ai-core/rules/rules.md in a checkout, or the rules/ directory of setup-ai-core."
  echo ""
  echo "Options:"
  echo "  -h, --help    Show this help message"
  echo ""
  echo "Examples:"
  echo "  bash .ai-core/bin/rules-check.sh"
  echo "  bash bin/rules-check.sh rules"
  exit 0
  fi
done

TARGET="${1:-}"

if [ -z "$TARGET" ]; then
  if [ -f ".ai-core/rules/rules.md" ]; then
    TARGET=".ai-core/rules/rules.md"
  elif [ -d "rules" ]; then
    TARGET="rules"
  else
    TARGET="rules/rules.md"
  fi
fi

if [ -d "$TARGET" ]; then
  FILES=("$TARGET"/[0-9][0-9]-*.md)
elif [ -f "$TARGET" ]; then
  FILES=("$TARGET")
else
  echo "error: rules file or directory not found at $TARGET" >&2
  exit 1
fi

echo "==> Checking rule enforcement tags in $TARGET..."

untagged=0
machine_count=0
tool_count=0
review_count=0
discipline_count=0
total_rules=0

# A rule is one bullet with its wrapped continuation lines; the tag stands at its end.
rule=""
current_file=""
check_rule() {
  [ -n "$rule" ] || return 0
  total_rules=$((total_rules + 1))
  if [[ "$rule" =~ \[([^]]+)\][[:space:]]*$ ]]; then
    tag="${BASH_REMATCH[1]}"
    valid=0
    if [[ "$tag" =~ machine ]]; then machine_count=$((machine_count + 1)); valid=1; fi
    if [[ "$tag" =~ tool ]]; then tool_count=$((tool_count + 1)); valid=1; fi
    if [[ "$tag" =~ review ]]; then review_count=$((review_count + 1)); valid=1; fi
    if [[ "$tag" =~ discipline ]]; then discipline_count=$((discipline_count + 1)); valid=1; fi
    if [ "$valid" -eq 0 ]; then
      echo "warning: $current_file: rule carries unknown tag '$tag': ${rule:0:80}" >&2
      untagged=$((untagged + 1))
    fi
  else
    echo "error: $current_file: rule carries NO enforcement tag: ${rule:0:80}" >&2
    untagged=$((untagged + 1))
  fi
  rule=""
}

for current_file in "${FILES[@]}"; do
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+ ]]; then
      check_rule
      rule="$line"
    elif [ -n "$rule" ] && [[ "$line" =~ ^[[:space:]]+[^[:space:]] ]]; then
      rule="$rule $line"
    else
      check_rule
    fi
  done < "$current_file"
  check_rule
done

echo "--------------------------------------------------"
echo "Files checked: ${#FILES[@]}"
echo "Total rules checked: $total_rules"
echo "  [machine]    : $machine_count"
echo "  [tool]       : $tool_count"
echo "  [review]     : $review_count"
echo "  [discipline] : $discipline_count"
echo "--------------------------------------------------"

if [ "$untagged" -gt 0 ]; then
  echo "FAILED: $untagged rule(s) without valid enforcement tags." >&2
  exit 1
fi

echo "✓ All rules carry valid enforcement tags."
