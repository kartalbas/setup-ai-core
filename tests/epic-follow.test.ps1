# The PowerShell twin of epic-follow.test.sh, asserting the SAME answers: Get-EpicTarget, the rule
# itself, then issue-status moving an epic to testing with its last sub-issue, a sub-issue that only
# started leaving an epic in testing where it is, and issue-close closing an epic with its last
# sub-issue. A fake gh answers, so nothing leaves the machine.
#
#   pwsh -File tests/epic-follow.test.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fake = Join-Path ([IO.Path]::GetTempPath()) "epic-follow-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$env:GH_ORG = 'example-org'; $env:GH_CACHE_DIRECTORY = Join-Path $fake 'cache'
New-Item -ItemType Directory -Force -Path (Join-Path $env:GH_CACHE_DIRECTORY '7'), (Join-Path $fake 'bin') | Out-Null
Set-Content -LiteralPath (Join-Path $env:GH_CACHE_DIRECTORY '7/project-id') -Value 'PVT_epic7'
Set-Content -LiteralPath (Join-Path $env:GH_CACHE_DIRECTORY '7/fields.tsv') -Value @("Status`tF1`ttodo`tO1", "Status`tF1`timplementing`tO2", "Status`tF1`ttesting`tO3", "Status`tF1`tdone`tO4")
$calls = Join-Path $fake 'calls'; $epic = Join-Path $fake 'epic-44'

$failed = 0
function Check($name, $expected, $actual) {
  if ("$expected" -ceq "$actual") { Write-Host "  ok   $name" }
  else { Write-Host "  FAIL $name`n       expected: [$expected]`n       actual:   [$actual]"; $script:failed++ }
}

try {
  Write-Host 'the rule: where an epic stands follows from its sub-issues, forward only'
  Import-Module (Join-Path $root 'lib/Board.psm1') -Force
  Check 'nothing started'         ''           (Get-EpicTarget -Current todo -Statuses todo, backlog)
  Check 'one started'             implementing (Get-EpicTarget -Current todo -Statuses implementing, todo)
  Check 'all in testing or done'  testing      (Get-EpicTarget -Current implementing -Statuses testing, done)
  Check 'all done'                CLOSE        (Get-EpicTarget -Current testing -Statuses done, done)
  Check 'never backward'          ''           (Get-EpicTarget -Current testing -Statuses implementing, testing)
  Check 'no sub-issues, nothing'  ''           (Get-EpicTarget -Current todo)

  # The fake gh: #3 is a sub-issue of #44, #44 has no parent; epic-44 holds the statuses of #44
  # and of its sub-issues as the board gives them, one a line, the epic first
  @"
`$line = `$args -join ' '
Add-Content -LiteralPath '$calls' -Value (`$line -replace '\r?\n', ' ')
`$num = ''; foreach (`$a in `$args) { if (`$a -cmatch '^(num|n)=([0-9]+)$') { `$num = `$Matches[2]; break } }
if (`$line -clike '*subIssues(first*') { Get-Content -LiteralPath '$epic'; exit 0 }
if (`$line -clike '*parent {*') { if (`$num -ceq '3') { 'example-org/example-repo 44' }; exit 0 }
if (`$line -clike '*includeArchived*') { "PVT_epic7``tPVTI_card`$num"; exit 0 }
if (`$line -clike '*projectItems(first:20)*') { "example-org/7``tPVTI_card`$num"; exit 0 }
if (`$line -clike '*updateProjectV2ItemFieldValue*') { '{}'; exit 0 }
if (`$line -clike '*--method PATCH*') { '{}'; exit 0 }
[Console]::Error.WriteLine("the stand-in gh has no answer for: `$line"); exit 9
"@ | Set-Content -Path (Join-Path $fake 'bin/gh.ps1') -Encoding utf8NoBOM
  "@echo off`r`npwsh -NoProfile -File `"$fake\bin\gh.ps1`" %*" | Set-Content -Path (Join-Path $fake 'bin/gh.cmd') -Encoding ascii
  if (-not $IsWindows) { Set-Content -Path (Join-Path $fake 'bin/gh') -Value "#!/bin/sh`nexec pwsh -NoProfile -File `"$fake/bin/gh.ps1`" `"`$@`"" -Encoding ascii; & chmod +x (Join-Path $fake 'bin/gh') }
  $env:PATH = "$(Join-Path $fake 'bin')$([IO.Path]::PathSeparator)$env:PATH"
  function Moves { (@(Get-Content -LiteralPath $calls | ForEach-Object { [regex]::Matches($_, 'iid=PVTI_card[0-9]+') | ForEach-Object { $_.Value } }) -join ' ') }
  function Closes { (@(Get-Content -LiteralPath $calls | ForEach-Object { [regex]::Matches($_, 'PATCH repos/example-org/example-repo/issues/[0-9]+') | ForEach-Object { 'issues/' + ($_.Value -csplit '/')[-1] } }) -join ' ') }
  function Run($Mover) { $script:out = @(& pwsh -NoProfile -File (Join-Path $root "bin/$Mover") @args 2>&1 | ForEach-Object { "$_" }); $script:rc = $LASTEXITCODE }
  function EpicLine { "$(@($out | Where-Object { $_.StartsWith('epic ', [StringComparison]::Ordinal) }) -join ' ')" }

  Write-Host 'issue-status: the last sub-issue in testing moves its epic to testing'
  Set-Content -LiteralPath $calls -Value @(); Set-Content -LiteralPath $epic -Value @('implementing', 'testing', 'testing')
  Run 'issue-status.ps1' -Project 7 -Repo example-org/example-repo -Number 3 -Status testing
  Check 'exit 0'        0 $rc
  Check 'it says so'    'epic example-org/example-repo#44 -> testing, as its sub-issues stand' (EpicLine)
  Check 'both cards moved, the sub-issue first' 'iid=PVTI_card3 iid=PVTI_card44' (Moves)

  Write-Host 'issue-status: a sub-issue that only started leaves an epic in testing where it is'
  Set-Content -LiteralPath $calls -Value @(); Set-Content -LiteralPath $epic -Value @('testing', 'implementing', 'testing')
  Run 'issue-status.ps1' -Project 7 -Repo example-org/example-repo -Number 3 -Status implementing
  Check 'exit 0'        0 $rc
  Check 'no epic line'  '' (EpicLine)
  Check 'only the sub-issue moved' 'iid=PVTI_card3' (Moves)

  Write-Host 'issue-close: the last sub-issue closed closes its epic'
  Set-Content -LiteralPath $calls -Value @(); Set-Content -LiteralPath $epic -Value @('testing', 'done', 'done')
  Run 'issue-close.ps1' -Repo example-org/example-repo -Number 3
  Check 'exit 0'        0 $rc
  Check 'it says so'    'epic example-org/example-repo#44 -> closed, every sub-issue done' (EpicLine)
  Check 'both issues closed' 'issues/3 issues/44' (Closes)
} finally {
  Remove-Item -Recurse -Force -LiteralPath $fake -ErrorAction SilentlyContinue
}

Write-Host ''
if ($failed -gt 0) { Write-Host "$failed failed"; exit 1 }
Write-Host 'all passed'
