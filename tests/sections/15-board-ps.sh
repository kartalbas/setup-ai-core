#!/usr/bin/env bash
# the board and issue commands, the PowerShell twins, and their case check; one section of the suite, run by tests/check.sh with the others
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

section "the board and issue commands, PowerShell twins: the suite against a fake gh, then the case check"
pwsh -NoProfile -File "$ROOT/tests/run-all.ps1" > "$WORK/suite.ps1.log" 2>&1 || { cat "$WORK/suite.ps1.log"; fail "pwsh tests/run-all.ps1"; }
echo "  $(tail -3 "$WORK/suite.ps1.log" | grep -a 'tests:' | head -1)"
pwsh -NoProfile -File "$ROOT/bin/case-check.ps1" > "$WORK/case.ps1.log" 2>&1 || { cat "$WORK/case.ps1.log"; fail "pwsh bin/case-check.ps1"; }
echo "  case check green (schema-check needs github.com and runs in CI)"
exit 0
