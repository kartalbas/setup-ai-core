#!/usr/bin/env bash
# What issue-new and issue-edit SAY about a title, and the fact that they still go ahead.
#
# The report is the whole point: a long title, a title full of code, or a title that names an
# artifact and no stake is a real ticket that a reader will struggle with, so the tool names the
# struggle and creates the issue anyway. A run with a fake gh on PATH proves both halves at once -
# the words on stderr and the call that still reached GitHub.
#
#   bash test/title-report.test.sh

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fake="$(mktemp -d)"
export GH_CACHE_DIRECTORY="$fake/cache"
PROJECT_NUMBER=999989
trap 'rm -rf "$fake"' EXIT
log="$fake/calls.txt"

cat > "$fake/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$log"
case "\$*" in
  *issue*create*)         printf 'https://github.com/example-org/example-repo/issues/999\n'; exit 0 ;;
  *projectItems*)         exit 0 ;;
  *addProjectV2ItemById*) echo 'PVTI_new'; exit 0 ;;
  *) echo '{}'; exit 0 ;;
esac
EOF
chmod +x "$fake/gh"
export PATH="$fake:$PATH"

mkdir -p "$GH_CACHE_DIRECTORY/$PROJECT_NUMBER"
printf 'PVT_kwtitle%s\n' "$PROJECT_NUMBER" > "$GH_CACHE_DIRECTORY/$PROJECT_NUMBER/project-id"
printf 'Status\tF1\ttodo\tO1\nPriority\tF2\tP1\tO2\n' > "$GH_CACHE_DIRECTORY/$PROJECT_NUMBER/fields.tsv"

failed=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}

body="$fake/body.md"; printf 'the body\n' > "$body"
repo='example-org/example-repo'
good='Put every new issue on its board, or nobody reading the board sees it'
exactly70="$(printf 'a%.0s' $(seq 1 70))"
over70="$(printf 'a%.0s' $(seq 1 71))"

new_with_title() {
  : > "$log"
  bash "$root/bin/issue-new.sh" --repo "$repo" --title "$1" --body-file "$body" \
    --label type:feature --label area:tooling --priority P1 --project "$PROJECT_NUMBER" \
    --asked-by kartalbas --asked-in 'the test' 2>&1 >/dev/null
}

echo 'issue-new reports a long title and creates the issue anyway'
out="$(new_with_title "$over70")"
check 'says how long it is'    yes "$(grep -q 'title is 71 characters, over 70' <<< "$out" && echo yes || echo no)"
check 'says what a title is'   yes "$(grep -q 'one sentence a stranger understands' <<< "$out" && echo yes || echo no)"
check 'the issue was created'  yes "$(grep -q 'issue create' "$log" && echo yes || echo no)"

echo 'seventy characters is not over seventy'
out="$(new_with_title "$exactly70")"
check 'nothing said about the length' no "$(grep -q 'over 70' <<< "$out" && echo yes || echo no)"

# The count is CHARACTERS, not bytes. An em dash is three bytes, so a title of exactly seventy
# carrying one was reported as seventy-two by the shell that counts bytes.
echo 'a title of seventy with an em dash in it is not over seventy either'
out="$(new_with_title "$(printf 'a%.0s' $(seq 1 68))—x")"
check 'nothing said about the length' no "$(grep -q 'over 70' <<< "$out" && echo yes || echo no)"

# A CHARACTER OUTSIDE THE BASIC MULTILINGUAL PLANE IS STILL ONE CHARACTER. An emoji is four
# bytes and one code point, and the shell that stores text as UTF-16 counts it as two.
echo 'a title of seventy ending in an emoji is not over seventy either'
emoji="$(printf '\360\237\230\200')"
out="$(new_with_title "$(printf 'a%.0s' $(seq 1 69))$emoji")"
check 'nothing said about the length' no "$(grep -q 'over 70' <<< "$out" && echo yes || echo no)"
out="$(new_with_title "$(printf 'a%.0s' $(seq 1 70))$emoji")"
check 'and seventy-one is counted as seventy-one' yes "$(grep -q 'title is 71 characters, over 70' <<< "$out" && echo yes || echo no)"

echo 'issue-new reports a backtick and creates the issue anyway'
out="$(new_with_title 'Fix the `board_items` reader, or every card past the first hundred is missing')"
check 'names the backtick'      yes "$(grep -q 'title contains a backtick' <<< "$out" && echo yes || echo no)"
check 'says no code in a title' yes "$(grep -q 'no code name in a title' <<< "$out" && echo yes || echo no)"
check 'the issue was created'   yes "$(grep -q 'issue create' "$log" && echo yes || echo no)"

# A title that names an artifact and no stake fits twenty other tickets. The shape reported is
# narrow on purpose: one of six verbs AND none of the three joins.
echo 'a title that names an action and no stake is reported'
out="$(new_with_title 'Add the board-sync command')"
check 'names the missing stake' yes "$(grep -q 'title names an action and no stake' <<< "$out" && echo yes || echo no)"
check 'the issue was created'   yes "$(grep -q 'issue create' "$log" && echo yes || echo no)"

echo 'the same verb WITH a stake draws no line'
out="$(new_with_title 'Add the board-sync command, or an issue filed on github.com is on no board')"
check 'silent about the stake'  no "$(grep -q 'no stake' <<< "$out" && echo yes || echo no)"
out="$(new_with_title 'Add the board-sync command: an issue filed on github.com is on no board')"
check 'a colon joins the halves too' no "$(grep -q 'no stake' <<< "$out" && echo yes || echo no)"

echo 'a verb outside the six is not judged at all'
out="$(new_with_title 'Refuse a push whose commit names no issue')"
check 'silent about the stake' no "$(grep -q 'no stake' <<< "$out" && echo yes || echo no)"

# issue-new reports every board it touched on stderr too, so the check is for a TITLE line and
# not for silence.
echo 'a title that reads well draws no title line at all'
out="$(new_with_title "$good")"
check 'nothing said about the title' no "$(grep -qE '^title (is|contains|names)' <<< "$out" && echo yes || echo no)"

echo 'issue-edit reads a new title the same way'
: > "$log"
out="$(bash "$root/bin/issue-edit.sh" "$repo" 163 --title "$over70" 2>&1 >/dev/null)"
check 'says how long it is' yes "$(grep -q 'title is 71 characters, over 70' <<< "$out" && echo yes || echo no)"
check 'the edit was sent'   yes "$(grep -q 'method PATCH' "$log" && echo yes || echo no)"

: > "$log"
out="$(bash "$root/bin/issue-edit.sh" "$repo" 163 --title 'Add the board-sync command' 2>&1 >/dev/null)"
check 'names the missing stake' yes "$(grep -q 'title names an action and no stake' <<< "$out" && echo yes || echo no)"

echo 'an edit with no title has no title to read'
: > "$log"
out="$(bash "$root/bin/issue-edit.sh" "$repo" 163 --body-file "$body" 2>&1 >/dev/null)"
check 'nothing said about the title' no "$(grep -qE '^title (is|contains|names)' <<< "$out" && echo yes || echo no)"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
