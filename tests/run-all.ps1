# Run every PowerShell test in this directory, one verdict line each, and a count at the end.
#
#   pwsh -NoProfile -File test/run-all.ps1
#
# Exits non-zero when any test is red. A test's own output is printed only when it FAILS: a green
# suite that scrolls for three hundred lines is a suite nobody reads to the end, and the one line
# that matters is the count.
#
# EACH TEST RUNS IN ITS OWN pwsh PROCESS. Several of them set PATH, HOME, TEAM_MODES_FILE,
# GH_CACHE_DIRECTORY and the current directory, and a test that changed those for the ones after
# it would make the order the suite runs in part of what it proves. A separate process is also
# what makes the exit status of a single test readable at all.

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
# The organisation the suites were written for; nothing here reaches github.com
$env:GH_ORG = "example-org"

# THE TREE IS READ BEFORE AND AFTER, and a suite that changed it is RED whatever its own
# assertions said. A test writes into its own temporary directory and nowhere else: one that
# plants into the checkout has to put it back, two suites in flight then restore what the other
# planted, and the tracked file is left holding a test's plant. Only what this run changed is
# judged, so uncommitted work of somebody's own is not reported as a test's doing. Where git
# cannot read the tree there is nothing to compare, and that is said rather than passed over.
function Read-TreeState {
  $root = Split-Path -Parent $here
  $out = @(& git -C $root status --porcelain 2>$null | ForEach-Object { "$_" })
  if ($LASTEXITCODE -ne 0) { return $null }
  return ($out -join "`n")
}
$before = Read-TreeState

$passed = 0
$failed = 0
$failedNames = @()

foreach ($test in (Get-ChildItem -LiteralPath $here -Filter '*.test.ps1' | Sort-Object Name)) {
  $out = & pwsh -NoProfile -File $test.FullName 2>&1 | ForEach-Object { "$_" }
  if ($LASTEXITCODE -eq 0) {
    "ok    $($test.Name)"
    $passed++
  } else {
    "FAIL  $($test.Name)"
    $out | ForEach-Object { "      $_" }
    $failed++
    $failedNames += $test.Name
  }
}

$after = Read-TreeState

''
"$($passed + $failed) PowerShell tests: $passed passed, $failed failed"
if ($failed -gt 0) { "red: $($failedNames -join ' ')"; exit 1 }

if ($null -eq $before -or $null -eq $after) {
  'the working tree could NOT be read, so nothing says whether a test wrote into it'
  exit 0
}
if ($before -cne $after) {
  'a test wrote into the working tree. What changed under it:'
  $was = $before -split "`n"
  ($after -split "`n") | Where-Object { $was -cnotcontains $_ } | ForEach-Object { "  $_" }
  'a test plants into its own temporary directory, never into the tree it is testing'
  exit 1
}
'the working tree is as the suite found it'
exit 0
