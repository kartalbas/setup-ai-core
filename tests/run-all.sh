#!/usr/bin/env bash
# Run every bash test in this directory, one verdict line each, and a count at the end.
#
#   bash test/run-all.sh
#
# Exits non-zero when any test is red. A test's own output is printed only when it FAILS: a
# green suite that scrolls for three hundred lines is a suite nobody reads to the end, and the
# one line that matters is the count.
#
# THE TESTS RUN IN THEIR OWN PROCESS, one at a time. Several of them set PATH, HOME,
# TEAM_MODES_FILE and GH_CACHE_DIRECTORY, and a test that changed those for the ones after it
# would make the order the suite runs in part of what it proves.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The organisation the suites were written for; nothing here reaches github.com
export GH_ORG=example-org

# THE TREE IS READ BEFORE AND AFTER, and a suite that changed it is RED whatever its own
# assertions said. A test writes into its own temporary directory and nowhere else: one that
# plants into the checkout has to put it back, two suites in flight then restore what the other
# planted, and the tracked file is left holding a test's plant. Only what this run changed is
# judged, so uncommitted work of somebody's own is not reported as a test's doing. Where git
# cannot read the tree there is nothing to compare, and that is said rather than passed over.
tree_state() { git -C "$here/.." status --porcelain 2>/dev/null; }
before="$(tree_state)"; before_read=$?

passed=0
failed=0
failed_names=''

for test in "$here"/*.test.sh; do
  name="$(basename "$test")"
  if out="$(bash "$test" 2>&1)"; then
    printf 'ok    %s\n' "$name"
    passed=$((passed + 1))
  else
    printf 'FAIL  %s\n' "$name"
    printf '%s\n' "$out" | sed 's/^/      /'
    failed=$((failed + 1))
    failed_names="$failed_names $name"
  fi
done

after="$(tree_state)"; after_read=$?

echo
echo "$((passed + failed)) bash tests: $passed passed, $failed failed"
[ "$failed" -eq 0 ] || { echo "red:$failed_names"; exit 1; }

if [ "$before_read" -ne 0 ] || [ "$after_read" -ne 0 ]; then
  echo 'the working tree could NOT be read, so nothing says whether a test wrote into it'
  exit 0
fi
if [ "$before" != "$after" ]; then
  echo 'a test wrote into the working tree. What changed under it:'
  diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed -n 's/^> /  /p'
  echo 'a test plants into its own temporary directory, never into the tree it is testing'
  exit 1
fi
echo 'the working tree is as the suite found it'
