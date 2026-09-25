#!/usr/bin/env bash
# Does every rule carry the mechanism that enforces it?
#
#   rules-check.sh [FILE-OR-DIRECTORY]
#
# A rule is a bold opening under a `## ` section, written in one of three shapes:
#   - **A rule.**      a list bullet
#   3. **A rule.**     a numbered item, which is how a set of rules that has an order is written
#   **A rule.**        a paragraph of its own, at the left margin
# Every one of them ends with an enforcement tag naming what actually holds it:
#   [machine]     a lint, a test or a hook refuses
#   [tool]        a command does it at the moment of the action
#   [review]      the reviewer's checklist asks for it
#   [discipline]  only the reader
# Two mechanisms sharing one rule are written as a combination, `[machine · review]`, joined with
# a middle dot. The order does not matter and a tag may not stand twice in one combination.
#
# WHY A TAG IS REQUIRED RATHER THAN NICE. A document of rules with no tags reads as a document of
# rules that are all enforced, and most of them are not. The count per tag is the honest figure: it
# says how much of the rule set a machine holds and how much rests on a person remembering, and it
# moves the day somebody writes a check.
#
# A RULE IS ITS WHOLE PARAGRAPH. A rule regularly runs over several lines, so a list bullet is its
# opening line plus the indented lines under it, and a rule written as a paragraph is its opening
# line plus the lines at the left margin under it, up to the blank line. The tag is looked for at
# the end of the last of them.
#
# It prints one line per untagged rule, naming the file and the line, then the count per tag over
# every file read. Exits 1 when any rule has no tag. A directory means its NN-*.md section files,
# which is how setup-ai-core checks its own rules/; without an argument it reads
# .ai-core/rules/rules.md in a checkout, or rules/ in the clone.
set -uo pipefail

for arg in "$@"; do
  if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
    echo "Usage: rules-check.sh [file-or-directory]"
    echo ""
    echo "Refuses a rule (a bold opening under a ## section, with the lines it wraps over) that does not"
    echo "end with an enforcement tag: [machine], [tool], [review], [discipline], or a combination such"
    echo "as [machine · review]. Prints every untagged rule with its file and line, then the count per tag."
    echo "A directory means every NN-*.md section file in it."
    echo "Default: .ai-core/rules/rules.md in a checkout, or the rules/ directory of setup-ai-core."
    echo ""
    echo "Options:"
    echo "  -h, --help    Show this help message"
    echo ""
    echo "Examples:"
    echo "  ai-core rules-check"
    echo "  ai-core rules-check rules"
    exit 0
  fi
done

case "${1:-}" in
  -*) echo "error: unknown argument '$1'" >&2; exit 2 ;;
esac
TARGET="${1:-}"; [ $# -le 1 ] || { echo "error: usage: rules-check.sh [file-or-directory]" >&2; exit 2; }
if [ -z "$TARGET" ]; then
  if [ -f ".ai-core/rules/rules.md" ]; then TARGET=".ai-core/rules/rules.md"
  elif [ -d "rules" ]; then TARGET="rules"
  else TARGET="rules/rules.md"; fi
fi
if [ -d "$TARGET" ]; then
  FILES=("$TARGET"/[0-9][0-9]-*.md)
  [ -f "${FILES[0]}" ] || { echo "error: no NN-*.md section file in $TARGET" >&2; exit 2; }
elif [ -f "$TARGET" ]; then
  FILES=("$TARGET")
else
  echo "error: there is no file at $TARGET" >&2; exit 2
fi

TAGS='machine tool review discipline'

# The rules of one file, one per line: <line number>\t<the whole rule, its wrapped lines joined>
rules_of() {  # rules_of <file>
  awk '
    function flush() {
      if (open) { sub(/[ \t]+$/, "", text); print at "\t" text }
      open = 0; para = 0; text = ""
    }
    /^##[ \t]/ { flush(); section = 1; next }
    !section   { next }
    /^-[ \t]+\*\*/        { flush(); open = 1; at = NR; text = $0; next }
    /^[0-9]+\.[ \t]+\*\*/ { flush(); open = 1; at = NR; text = $0; next }
    /^\*\*/               { flush(); open = 1; para = 1; at = NR; text = $0; next }
    /^[ \t]*$/            { flush(); next }
    /^[-*+][ \t]/         { flush(); next }
    /^[0-9]+\.[ \t]/      { flush(); next }
    open && /^[ \t]+[^ \t]/ { line = $0; sub(/^[ \t]+/, "", line); text = text " " line; next }
    para                  { text = text " " $0; next }
    { flush() }
    END { flush() }
  ' "$1"
}

# The tags named inside the brackets, one per line, or nothing when the text is no tag: a word
# outside the four, a word standing twice, or a bracket inside the brackets.
read_tag() {  # read_tag <the text inside the brackets>
  local inside="$1" part seen=''
  case "$inside" in *'['*|*']'*) return 1 ;; esac
  while [ -n "$inside" ]; do
    case "$inside" in
      *' · '*) part="${inside%% · *}"; inside="${inside#* · }" ;;
      *)       part="$inside"; inside='' ;;
    esac
    case " $TAGS " in *" $part "*) ;; *) return 1 ;; esac
    case " $seen " in *" $part "*) return 1 ;; esac
    seen="$seen $part"
    printf '%s\n' "$part"
  done
  [ -n "$seen" ] || return 1
}

total=0
untagged=0
counts=''
for file in "${FILES[@]}"; do
  while IFS=$'\t' read -r at text; do
    [ -n "$at" ] || continue
    total=$((total + 1))
    named=''
    case "$text" in
      *'['*']')
        inside="${text##*[}"; inside="${inside%]}"
        named="$(read_tag "$inside")" || named='' ;;
    esac
    if [ -z "$named" ]; then
      untagged=$((untagged + 1))
      echo "$file:$at has no enforcement tag: $(printf '%s' "$text" | cut -c1-72)"
      continue
    fi
    counts="$counts$named"$'\n'
  done <<< "$(rules_of "$file")"
done

echo
for tag in $TAGS; do
  printf '%-12s %s\n' "$tag" "$(grep -cx "$tag" <<< "$counts" || true)"
done
echo
if [ "$untagged" -gt 0 ]; then
  echo "rules-check: $total rule bullets, $untagged without an enforcement tag."
  exit 1
fi
echo "rules-check: $total rule bullets, every one tagged."
