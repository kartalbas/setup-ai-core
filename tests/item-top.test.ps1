# The PowerShell twin of item-top.test.sh, asserting the SAME order.
#
# The board keeps ONE order for all its items, and `updateProjectV2ItemPosition` with no afterId
# means the very top. So moving each named card to the top would hand back the names REVERSED -
# the one outcome nobody asking for an order wants. The first name goes to the top and every
# later one is placed under the card moved before it, which is what `afterId` is for.
#
#   pwsh -File test/item-top.test.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fake = Join-Path ([IO.Path]::GetTempPath()) "gh-fake-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$env:GH_CACHE_DIRECTORY = Join-Path $fake 'cache'
New-Item -ItemType Directory -Path $fake | Out-Null
$log = Join-Path $fake 'calls.txt'
$PROJECT = 999986

@"
`$a = `$args -join ' '
Add-Content -Path '$log' -Value (`$a -replace '\r?\n', ' ')
if (`$a -match 'issues/373') { 'I_node373'; exit 0 }
if (`$a -match 'issues/372') { 'I_node372'; exit 0 }
if (`$a -match 'projectItems') { exit 0 }
if (`$a -match 'addProjectV2ItemById') {
  foreach (`$one in `$args) { if (`$one -match '^cid=I_node(\d+)') { 'PVTI_' + `$Matches[1]; exit 0 } }
  'PVTI_unknown'; exit 0
}
if (`$args[0] -eq 'repo') { 'example-org/example-repo'; exit 0 }
'{}'
exit 0
"@ | Set-Content -Path (Join-Path $fake 'gh.ps1') -Encoding utf8NoBOM
"@echo off`r`npwsh -NoProfile -File `"$fake\gh.ps1`" %*" |
  Set-Content -Path (Join-Path $fake 'gh.cmd') -Encoding ascii
if (-not $IsWindows) { Set-Content -Path (Join-Path $fake 'gh') -Value "#!/bin/sh`nexec pwsh -NoProfile -File `"$fake/gh.ps1`" `"`$@`"" -Encoding ascii; & chmod +x (Join-Path $fake 'gh') }
$env:PATH = "$fake$([IO.Path]::PathSeparator)$env:PATH"

$cache = Join-Path $env:GH_CACHE_DIRECTORY "$PROJECT"
New-Item -ItemType Directory -Force -Path $cache | Out-Null
Set-Content -Path (Join-Path $cache 'project-id') -Value "PVT_kwtop$PROJECT" -NoNewline

$failed = 0
function Check($name, $expected, $actual) {
  if ("$expected" -eq "$actual") { Write-Host "  ok   $name" }
  else { Write-Host "  FAIL $name`n       expected: $expected`n       actual:   $actual"; $script:failed++ }
}

$top = Join-Path $root 'bin/item-top.ps1'
$repo = 'example-org/example-repo'
function Calls { @(Get-Content $log -ErrorAction SilentlyContinue) }
function Clear-Log { Remove-Item $log -ErrorAction SilentlyContinue }

# The position calls in the order they were made, as "<item>[ <after item>]" per line.
function Positions {
  @((Calls) | Where-Object { $_ -match '-f iid=' } | ForEach-Object {
    $iid = if ($_ -match '-f iid=(\S+)') { $Matches[1] } else { '' }
    $after = if ($_ -match '-f after=(\S+)') { ' ' + $Matches[1] } else { '' }
    "$iid$after"
  }) -join "`n"
}

Write-Host 'the first card goes to the top, the second lands under it'
Clear-Log
$out = (@(& $top -Project "$PROJECT" -Repo $repo -Number 373, 372) -join "`n")
Check 'both reported' "#373 -> top`n#372 -> top" $out
Check 'two moves'     2 @((Calls) | Where-Object { $_ -match 'updateProjectV2ItemPosition' }).Count
Check 'the order'     "PVTI_373`nPVTI_372 PVTI_373" (Positions)

Write-Host 'one card alone goes to the top with no afterId at all'
Clear-Log
& $top -Project "$PROJECT" -Repo $repo -Number 373 | Out-Null
Check 'one move'   1 @((Calls) | Where-Object { $_ -match 'updateProjectV2ItemPosition' }).Count
Check 'no afterId' 0 @((Calls) | Where-Object { $_ -match '-f after=' }).Count

Write-Host 'the board named on the command line is the board acted on'
Check 'the project id sent' 'True' ([bool]((Calls) -match "pid=PVT_kwtop$PROJECT"))

Remove-Item -Recurse -Force $fake, $cache -ErrorAction SilentlyContinue
if ($failed -gt 0) { Write-Host "`n$failed failed"; exit 1 }
Write-Host "`nall passed"
