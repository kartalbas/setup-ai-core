#!/usr/bin/env bash
# What solution-path.sh refuses and what it sends.
#
# Run with a FAKE gh on PATH, so nothing is commented and every call is recorded instead. What
# is pinned: a heading that is not there and a heading with nothing under it are both named and
# both stop the run before GitHub is reached, a deeper heading belongs to the section it stands
# in rather than ending it, --check posts nothing, and the finished file travels as a file.
#
#   bash test/solution-path.test.sh

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fake="$(mktemp -d)"
trap 'rm -rf "$fake"' EXIT
log="$fake/calls.txt"

cat > "$fake/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
if [ "\$1" = "repo" ]; then echo 'example-org/example-repo'; exit 0; fi
echo 'https://github.com/example-org/example-repo/issues/163#issuecomment-1'
exit 0
EOF
chmod +x "$fake/gh"
export PATH="$fake:$PATH"

failed=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}

path="$root/bin/solution-path.sh"
whole="$fake/whole.md"

# Every required heading, with the options written as sub-headings - a deeper heading stands
# INSIDE its section and neither opens a new one nor ends the one it is in.
cat > "$whole" <<'TEXT'
# Solution path

## Where a person meets this
On the board, the first time a card is read after a push.

## What they see today
The card still says implementing, and the work is on master.

## What the system does behind it
Nothing reads the commit; the column is only ever set by hand.

## The decision
Whether the sweep reads a pull request or a commit on master.

## Options
### It reads the commit on master
One signal, and it is the one the push hook already lets through.
### It reads an open worktree
A worktree is a place to commit, not a statement that anything is finished.

## Recommendation
It reads the commit on master.

## Code facts
`bin/status-sync.sh:42` is where the signals are derived.

## Reuse manifest
`lib/board.sh` board_items and `bin/board-list.sh`.
TEXT

echo 'a finished path is checked and posts nothing with --check'
: > "$log"
out="$("$path" 163 "$whole" --check 2>&1)"; rc=$?
check 'exits zero'      0 "$rc"
check 'every section'   "$whole carries all 8 sections." "$(printf '%s\n' "$out" | sed -n '1p')"
check 'and says so'     'Checked only - nothing was posted.' "$(printf '%s\n' "$out" | sed -n '2p')"
check 'nothing sent'    0 "$(grep -c . "$log" || true)"

echo 'without --check the file travels as a file'
: > "$log"
out="$("$path" 163 "$whole" 2>&1)"; rc=$?
check 'exits zero'      0 "$rc"
check 'the flag'        yes "$(grep -q -- "--body-file $whole" "$log" && echo yes || echo no)"
check 'no inline body'  no  "$(grep -q -- '--body ' "$log" && echo yes || echo no)"
check 'what gh printed' 'https://github.com/example-org/example-repo/issues/163#issuecomment-1' \
  "$(printf '%s\n' "$out" | tail -n1)"

echo 'a heading that is not there is named, and nothing is sent'
short="$fake/short.md"
grep -v '^## Options$' "$whole" | grep -v '^## Reuse manifest$' > "$short"
: > "$log"
out="$("$path" 163 "$short" 2>&1)"; rc=$?
check 'exits nonzero'  yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'both are named' "$short has no \"## Options\", no \"## Reuse manifest\" heading." \
  "$(printf '%s\n' "$out" | sed -n '1p')"
check 'nothing sent'   0 "$(grep -c . "$log" || true)"

echo 'a heading with nothing under it is named too'
hollow="$fake/hollow.md"
sed -e 's/^It reads the commit on master\.$//' "$whole" > "$hollow"
: > "$log"
out="$("$path" 163 "$hollow" 2>&1)"; rc=$?
check 'exits nonzero' yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'the empty one' "$hollow leaves \"Recommendation\" empty." "$(printf '%s\n' "$out" | sed -n '1p')"
check 'nothing sent'  0 "$(grep -c . "$log" || true)"
check 'what to do'    yes \
  "$(printf '%s\n' "$out" | grep -q 'code starts after the solution path is posted' && echo yes || echo no)"

# A heading that stands twice has two bodies and only one of them is ever read - the first in
# one shell, the last in the other - so the same file was accepted by one twin and refused by
# the other.
echo 'a heading that stands twice is refused, and nothing is sent'
doubled="$fake/doubled.md"
{ cat "$whole"; printf '\n## Options\n'; } > "$doubled"
: > "$log"
out="$("$path" 163 "$doubled" 2>&1)"; rc=$?
check 'exits nonzero'        yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'it names the heading' "$doubled names \"## Options\" twice." "$(printf '%s\n' "$out" | sed -n '1p')"
check 'nothing sent'         0 "$(grep -c . "$log" || true)"

echo 'a file that is not there stops before anything is read'
: > "$log"
out="$("$path" 163 "$fake/nope.md" 2>&1)"; rc=$?
check 'exits nonzero'     yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'the file is named' yes "$(printf '%s\n' "$out" | grep -q "there is no file at $fake/nope.md" && echo yes || echo no)"
check 'nothing sent'      0 "$(grep -c . "$log" || true)"

echo 'a call missing the issue or the file is refused'
out="$("$path" "$whole" 2>&1)"; rc=$?
check 'no number: exits nonzero' yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
out="$("$path" not-a-number "$whole" --check 2>&1)"; rc=$?
check 'a number that is not one is refused' yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
