#!/usr/bin/env bash
# the board and issue commands, the bash twins, and their case check; one section of the suite, run by tests/check.sh with the others
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

section "the board and issue commands, bash twins: the suite against a fake gh, then the case check"
bash "$ROOT/tests/run-all.sh" > "$WORK/suite.sh.log" 2>&1 || { cat "$WORK/suite.sh.log"; fail "bash tests/run-all.sh"; }
echo "  $(tail -3 "$WORK/suite.sh.log" | grep -a 'tests:' | head -1)"
bash "$ROOT/bin/case-check.sh" > "$WORK/case.sh.log" 2>&1 || { cat "$WORK/case.sh.log"; fail "bash bin/case-check.sh"; }
echo "  case check green (schema-check needs github.com and runs in CI)"
exit 0
