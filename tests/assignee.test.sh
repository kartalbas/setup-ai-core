#!/usr/bin/env bash
# The Bash twin of assignee.test.ps1, asserting the SAME rules against the same
# reader. Two implementations of one rule are two chances to drift, and this is
# what makes the drift fail rather than surprise somebody months later.
#
# EVERY PLANT GOES INTO A FILE OF THIS RUN'S OWN. The reader takes the map as its
# second argument, so nothing here writes the tracked assignees.tsv. A test that planted
# into the tracked file and copied it back on exit would leave two suites in flight
# restoring twice, with the last restore writing whatever it had captured - the other
# suite's plant.
#
# The half below that runs bin/issue-new.sh runs it as a SEPARATE PROCESS, which no
# argument of this shell reaches, so it is read against the TRACKED map. That map is
# empty on purpose, so what it proves is that the reader's own answer is what lands on
# `gh issue create --assignee`: `@me` is produced nowhere but inside the reader. Which
# answer the reader gives for a mapped repository is proven above, against the plant.
#
#   bash test/assignee.test.sh

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAKE="$(mktemp -d)"
LOG="$FAKE/calls.txt"
MAP="$FAKE/assignees.tsv"
failed=0

trap 'rm -rf "$FAKE"' EXIT

check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}

# The stand-in: records what it was asked and answers the little the command reads.
cat > "$FAKE/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$LOG"
case "\$1 \${2:-}" in
  "issue create") echo "https://github.com/o/r/issues/123"; exit 0 ;;
  "repo view")    echo "example-org/mapped-repo"; exit 0 ;;
esac
echo "{}"
exit 0
EOF
chmod +x "$FAKE/gh"
echo body > "$FAKE/b.md"

# shellcheck source=/dev/null
. "$ROOT/lib/board.sh"

printf 'example-org/mapped-repo\tmapped-owner\n' > "$MAP"

echo 'the map decides the default'
check 'a mapped repo'    'mapped-owner' "$(assignee_for 'example-org/mapped-repo' "$MAP")"
check 'an unmapped repo' '@me'          "$(assignee_for 'example-org/unmapped-repo' "$MAP")"

echo 'a broken map stops before anything is created'
printf 'example-org/x\tone\tsurplus\n' > "$MAP"
if (assignee_for 'example-org/x' "$MAP" >/dev/null 2>&1); then check 'malformed row' 'died' 'returned'
else check 'malformed row' 'died' 'died'; fi
printf 'example-org/x\tone\nexample-org/x\ttwo\n' > "$MAP"
if (assignee_for 'example-org/x' "$MAP" >/dev/null 2>&1); then check 'duplicate row' 'died' 'returned'
else check 'duplicate row' 'died' 'died'; fi

# WHITESPACE AROUND A COLUMN, which is the divergence example-tools#21 measured and #22 closed.
# `example-org/x<SPACE><TAB>one` answered `one` on the PowerShell side, which trimmed six times,
# and `@me` here, which compared the raw field - one invisible space deciding who a new issue
# lands on. The format is now stated in assignees.tsv's own header and both readers refuse the
# row by name. The tab cases are the same question one class over: `IFS=$'\t' read` collapses a
# run of tabs and strips a leading one, so this reader used to see a valid two-column row where
# the PowerShell reader saw three columns and refused.
echo 'whitespace around a column is refused, and the row is named'

refused_row() { # refused_row <line>
  printf '%s\n' "$1" > "$MAP"
  local out
  out="$(assignee_for 'example-org/x' "$MAP" 2>&1)" && { echo "answered: $out"; return; }
  printf '%s\n' "$out" | sed "s|$MAP|MAP|"
}

check 'a space before the tab' \
  "error: MAP:1 has a space at the edge of a column, and the format allows none: 'example-org/x ' 'one'" \
  "$(refused_row "$(printf 'example-org/x \tone')")"
check 'a space after the tab' \
  "error: MAP:1 has a space at the edge of a column, and the format allows none: 'example-org/x' ' one'" \
  "$(refused_row "$(printf 'example-org/x\t one')")"
check 'two tabs' \
  "error: MAP:1 is not 'repo<TAB>login': $(printf 'example-org/x\t\tone')" \
  "$(refused_row "$(printf 'example-org/x\t\tone')")"
check 'a leading tab' \
  "error: MAP:1 is not 'repo<TAB>login': $(printf '\texample-org/x\tone')" \
  "$(refused_row "$(printf '\texample-org/x\tone')")"
check 'an indented comment' \
  "error: MAP:1 is not 'repo<TAB>login':   # example-org/x" \
  "$(refused_row '  # example-org/x')"
check 'a line of spaces' \
  "error: MAP:1 is not 'repo<TAB>login':   " \
  "$(refused_row '  ')"

echo 'a missing map stops too'
if (assignee_for 'example-org/x' "$FAKE/nowhere.tsv" >/dev/null 2>&1); then check 'absent file' 'died' 'returned'
else check 'absent file' 'died' 'died'; fi

echo 'and what actually reaches gh issue create'
PATH="$FAKE:$PATH"

sent_for() { # repo [explicit]
  : > "$LOG"
  # --project skips the board lookup. What is under test is the assignee that reaches
  # `gh issue create`, and everything after that call is somebody else's rule.
  local args=(--repo "$1" --title t --body-file "$FAKE/b.md"
              --label correctness --label frontend --priority P2 --project 5
              --asked-by kartalbas --asked-in 'the test')
  [ -n "${2:-}" ] && args+=(--assignee "$2")
  bash "$ROOT/bin/issue-new.sh" "${args[@]}" >/dev/null 2>&1
  grep -m1 '^issue create' "$LOG" 2>/dev/null | sed -n 's/.*--assignee \([^ ]*\).*/\1/p' | head -1
}

check 'the reader answers for it'   '@me'     "$(sent_for 'example-org/unmapped-repo')"
check 'explicit wins over the map'  'someone' "$(sent_for 'example-org/mapped-repo' someone)"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo; echo 'all passed'
