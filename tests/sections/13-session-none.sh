#!/usr/bin/env bash
# session-start where the harness is not installed; one section of the suite, run by tests/check.sh with the others
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

section "session-start fails where the harness is not installed"
mkdir -p "$WORK/none"
(cd "$WORK/none" && bash "$ROOT/bin/session-start.sh" > /dev/null 2>&1) && fail "session-start.sh exited 0 without rules"
(cd "$WORK/none" && pwsh -NoProfile -File "$(native "$ROOT/bin/session-start.ps1")" > /dev/null 2>&1) && fail "session-start.ps1 exited 0 without rules"
exit 0
