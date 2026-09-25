#!/usr/bin/env bash
# the syntax of every script, and every rule tagged; one section of the suite, run by tests/check.sh with the others
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

section "syntax"
for f in "$ROOT"/bin/*.sh "$ROOT/bin/ai-core"; do bash -n "$f" || fail "bash -n $f"; done
# A grep -q stops at its first match and breaks the pipe of a printf or echo still writing into it;
# under pipefail the pipeline then fails although grep matched. A variable goes to grep as a here-string.
hits="$(grep -nE '(printf|echo) [^|]*\| *(tr [^|]*\| *)?grep +-[a-zA-Z]*q' "$ROOT"/bin/*.sh "$ROOT"/lib/*.sh "$ROOT"/tests/*.sh "$ROOT"/tests/sections/*.sh || true)"
[ -z "$hits" ] || fail "printf or echo piped into grep -q, which breaks the pipe under pipefail; give grep a here-string: $hits"
PS_EXPECTED="$(ls "$ROOT"/bin/*.ps1 | wc -l | tr -d ' ')"
PS_SCANNED="$(CHECK_ROOT="$(native "$ROOT")" pwsh -NoProfile -Command '
  $bad = 0; $n = 0
  Get-ChildItem (Join-Path $env:CHECK_ROOT "bin/*.ps1") | ForEach-Object {
    $n++
    $e = $null
    [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$e) | Out-Null
    if ($e) { [Console]::Error.WriteLine("  $($_.Name): $($e[0].Message)"); $bad = 1 }
  }
  Write-Output $n
  exit $bad
')" || fail "PowerShell parse"
[ "$PS_SCANNED" = "$PS_EXPECTED" ] || fail "PowerShell parse scanned $PS_SCANNED of $PS_EXPECTED scripts"
echo "  $(ls "$ROOT"/bin/*.sh | wc -l | tr -d ' ') bash scripts, the ai-core launcher and $PS_SCANNED PowerShell scripts parse"

section "every rule carries its enforcement tag, on both twins"
bash "$ROOT/bin/rules-check.sh" "$ROOT/rules" > /dev/null || fail "rules-check.sh on rules/"
pwsh -NoProfile -File "$ROOT/bin/rules-check.ps1" -RulesFile "$(native "$ROOT/rules")" > /dev/null || fail "rules-check.ps1 on rules/"

section "every committed script carries its executable bit: a Windows clone records none, and a runner executes bin/*.sh directly"
bad="$(cd "$ROOT" && git ls-files -s | awk '$1 == "100644" {print $4}' | while IFS= read -r f; do [ "$(head -c 2 "$f" 2>/dev/null)" = "#!" ] && printf "%s " "$f"; done; true)"
[ -z "$bad" ] || fail "committed without the executable bit (git update-index --chmod=+x): $bad"
echo "  every file with a shebang is 100755 in the index"

exit 0
