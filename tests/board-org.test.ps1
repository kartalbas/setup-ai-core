# The PowerShell twin of board-org.test.sh: which ORGANISATION a board is resolved under, and
# where its cache lands, read off the module the scripts share.
#
#   pwsh -File test/board-org.test.ps1
#
# A bare number is a board of the organisation the named repository belongs to, ORG/N names one
# outright, and a command that names no repository falls back to GH_ORG (example-tools#25). A FAKE
# gh on PATH records every call, so the organisation the id query was sent for is read back off
# the record and no board is touched.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fake = Join-Path ([IO.Path]::GetTempPath()) "gh-fake-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$env:GH_CACHE_DIRECTORY = Join-Path $fake 'cache'
New-Item -ItemType Directory -Path $fake | Out-Null
$log = Join-Path $fake 'calls.txt'
@"
`$a = (`$args -join ' ') -replace '\r?\n', ' '
Add-Content -Path '$log' -Value `$a
if (`$a -match 'projectV2\(number') { 'PVT_kworgtest'; exit 0 }
if (`$args[0] -eq 'repo') { 'other-org/example-repo'; exit 0 }
'{}'
exit 0
"@ | Set-Content -Path (Join-Path $fake 'gh.ps1') -Encoding utf8NoBOM
"@echo off`r`npwsh -NoProfile -File `"$fake\gh.ps1`" %*" |
  Set-Content -Path (Join-Path $fake 'gh.cmd') -Encoding ascii
if (-not $IsWindows) { Set-Content -Path (Join-Path $fake 'gh') -Value "#!/bin/sh`nexec pwsh -NoProfile -File `"$fake/gh.ps1`" `"`$@`"" -Encoding ascii; & chmod +x (Join-Path $fake 'gh') }
$env:PATH = "$fake$([IO.Path]::PathSeparator)$env:PATH"
Import-Module (Join-Path $root 'lib/Board.psm1') -Force

$failed = 0
function Check([string]$Name, $Expected, $Actual) {
  if ("$Expected" -eq "$Actual") { Write-Host "  ok   $Name" }
  else { Write-Host "  FAIL $Name"; Write-Host "       expected: $Expected"; Write-Host "       actual:   $Actual"; $script:failed++ }
}
function IdQuery { (Get-Content $log -EA SilentlyContinue | Where-Object { $_ -match 'projectV2\(number' } | Select-Object -First 1) }
function OrgAsked { $q = IdQuery; if ($q -match 'org=([A-Za-z0-9_-]+)') { "org=$($Matches[1])" } else { '' } }
function Fresh { Set-Content -Path $log -Value '' -NoNewline; if (Test-Path $env:GH_CACHE_DIRECTORY) { Remove-Item -Recurse -Force $env:GH_CACHE_DIRECTORY } }

Write-Host ''
Write-Host "a bare number with a repository of another organisation is that organisation's board"
Fresh
Set-Project -Number '999979' -Repo 'other-org/example-repo' | Out-Null
Check 'the organisation' 'other-org' (Get-ProjectOrg)
$id = Get-ProjectId
Check 'the id is asked of other-org' 'org=other-org' (OrgAsked)
Check 'and answered' 'PVT_kworgtest' $id
Check 'and cached under the organisation and the number' (Join-Path $env:GH_CACHE_DIRECTORY 'other-org/999979') (Get-CacheDir)

Write-Host ''
Write-Host 'ORG/N names the organisation outright, whatever repository the command names'
Fresh
Set-Project -Number 'example-org/999978' -Repo 'other-org/example-repo' | Out-Null
Check 'the organisation' 'example-org' (Get-ProjectOrg)
Check 'the number after the slash' '999978' (Get-ProjectNumber)
Get-ProjectId | Out-Null
Check 'the id is asked of example-org' 'org=example-org' (OrgAsked)
Check 'and a board of GH_ORG caches under its number alone, as it always has' (Join-Path $env:GH_CACHE_DIRECTORY '999978') (Get-CacheDir)

Write-Host ''
Write-Host 'a command that names no repository falls back to GH_ORG'
Fresh
Set-Project -Number '999977' | Out-Null
Check 'the organisation' (Get-Org) (Get-ProjectOrg)

Write-Host ''
Write-Host 'a board written with a slash and nothing on one side of it is refused by name'
Fresh
$said = ''
try { Set-Project -Number '/7' -Repo 'other-org/example-repo' | Out-Null } catch { $said = "$_" }
Check 'refused, saying how a board is written' $true ($said -like "*a board is written N or ORG/N, not '/7'*")
Check 'and asked gh for no id' '' (IdQuery)

Write-Host ''
Write-Host "a card on another organisation's board is acted on under THAT organisation (example-tools#26)"
$carded = Join-Path $fake 'carded'
New-Item -ItemType Directory -Path $carded | Out-Null
@"
`$a = (`$args -join ' ') -replace '?
', ' '
Add-Content -Path '$log' -Value `$a
if (`$a -match 'projectItems')        { 'other-org/1' + [char]9 + 'PVTI_card3'; exit 0 }
if (`$a -match 'projectV2\(number')   { 'PVT_kworgtest'; exit 0 }
if (`$a -match 'fields\(first')       { 'Status' + [char]9 + 'F1' + [char]9 + 'done' + [char]9 + 'O_done'; exit 0 }
if (`$args[0] -eq 'repo') { 'other-org/example-repo'; exit 0 }
'{}'
exit 0
"@ | Set-Content -Path (Join-Path $carded 'gh.ps1') -Encoding utf8NoBOM
"@echo off`r`npwsh -NoProfile -File `"$carded\gh.ps1`" %*" |
  Set-Content -Path (Join-Path $carded 'gh.cmd') -Encoding ascii
if (-not $IsWindows) { Set-Content -Path (Join-Path $carded 'gh') -Value "#!/bin/sh`nexec pwsh -NoProfile -File `"$carded/gh.ps1`" `"`$@`"" -Encoding ascii; & chmod +x (Join-Path $carded 'gh') }
Fresh
$savedPath = $env:PATH
$env:PATH = "$carded$([IO.Path]::PathSeparator)$env:PATH"
$out = @(& pwsh -NoProfile -NoLogo -File (Join-Path $root 'bin/issue-close.ps1') -Repo other-org/example-repo 3 2>&1 | ForEach-Object { "$_" })
$rc = $LASTEXITCODE
$env:PATH = $savedPath
if ($rc -ne 0) { Write-Host ('       issue-close said: ' + ($out -join ' | ')) }
Check 'exits zero' 0 $rc
Check 'the id is asked of other-org' 'org=other-org' (OrgAsked)
Check 'and the board is named with its owner' $true (($out -join "`n") -like '*#3 -> done (board other-org/1)*')

Remove-Item -Recurse -Force $fake -EA SilentlyContinue
Write-Host ''
if ($failed -eq 0) { Write-Host 'board-org: every check green'; exit 0 }
else { Write-Host "board-org: $failed check(s) red"; exit 1 }
