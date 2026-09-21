# The PowerShell twin of close-reason.test.sh, asserting the SAME reason on the wire and the
# SAME card move. A wrong close reason is invisible until somebody reads the issue afterwards and
# sees "completed" on a rejected design, so it is asserted on the recorded call.
#
#   pwsh -File test/close-reason.test.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fake = Join-Path ([IO.Path]::GetTempPath()) "gh-fake-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$env:GH_CACHE_DIRECTORY = Join-Path $fake 'cache'
New-Item -ItemType Directory -Path $fake | Out-Null
$log = Join-Path $fake 'calls.txt'

# The issue is on one board and nowhere else, so the card half has exactly one board to write.
# The number is one no real board carries, so the id this test invents lands in a cache directory
# of its own.
@"
`$a = `$args -join ' '
Add-Content -Path '$log' -Value `$a
if (`$a -match 'projectItems')          { 'example-org/998' + [char]9 + 'PVTI_item'; exit 0 }
if (`$a -match 'projectsV2\(first')     { '998' + [char]9 + 'alpha'; exit 0 }
if (`$a -match 'projectV2\(number')     { 'PVT_kwclose'; exit 0 }
if (`$a -match 'fields\(first:50')      { 'Status' + [char]9 + 'F1' + [char]9 + 'done' + [char]9 + 'D1'; 'Status' + [char]9 + 'F1' + [char]9 + 'todo' + [char]9 + 'T1'; exit 0 }
if (`$a -match 'addProjectV2ItemById')  { 'PVTI_item'; exit 0 }
if (`$args[0] -eq 'repo') { 'example-org/example-repo'; exit 0 }
'{}'
exit 0
"@ | Set-Content -Path (Join-Path $fake 'gh.ps1') -Encoding utf8NoBOM
"@echo off`r`npwsh -NoProfile -File `"$fake\gh.ps1`" %*" |
  Set-Content -Path (Join-Path $fake 'gh.cmd') -Encoding ascii
if (-not $IsWindows) { Set-Content -Path (Join-Path $fake 'gh') -Value "#!/bin/sh`nexec pwsh -NoProfile -File `"$fake/gh.ps1`" `"`$@`"" -Encoding ascii; & chmod +x (Join-Path $fake 'gh') }
$env:PATH = "$fake$([IO.Path]::PathSeparator)$env:PATH"

$failed = 0
function Check($name, $expected, $actual) {
  if ("$expected" -eq "$actual") { Write-Host "  ok   $name" }
  else { Write-Host "  FAIL $name`n       expected: $expected`n       actual:   $actual"; $script:failed++ }
}

$close = Join-Path $root 'bin/issue-close.ps1'
$repo = 'example-org/example-repo'
function Calls { @(Get-Content $log -ErrorAction SilentlyContinue) }

function ReasonSentFor($reason) {
  Remove-Item $log -ErrorAction SilentlyContinue
  $p = @{ Repo = $repo; Number = 270 }
  if ($reason) { $p.Reason = $reason }
  try { & $close @p | Out-Null } catch { }
  $line = @((Calls) | Where-Object { $_ -match 'api --method PATCH repos/' }) | Select-Object -First 1
  if ($line -match 'state_reason=(\S+)') { return $Matches[1] }
  return '(none)'
}

Write-Host 'the close reason that reaches gh api'
Check 'omitted -> completed'       'completed'   (ReasonSentFor $null)
Check 'not-planned -> not_planned' 'not_planned' (ReasonSentFor 'not-planned')
Check 'completed stays explicit'   'completed'   (ReasonSentFor 'completed')

Write-Host 'a reason GitHub does not know stops at the binder, before anything is sent'
Remove-Item $log -ErrorAction SilentlyContinue
$said = ''
try { & $close -Repo $repo -Number 270 -Reason superseded | Out-Null } catch { $said = $_.Exception.Message }
Check 'it throws'              'True' ([bool]($said -match 'superseded'))
Check 'nothing reached github' 0      @((Calls) | Where-Object { $_ -match 'api --method PATCH' }).Count

Write-Host 'the card is moved to done on every board the issue is on'
Remove-Item $log -ErrorAction SilentlyContinue
$out = @(& $close -Repo $repo -Number 270)
Check 'the close line'  '#270 -> closed'        $out[0]
Check 'the board line'  '#270 -> done (board example-org/998)' $out[1]
Check 'the option sent' 'True' ([bool]((Calls) -match 'oid=D1'))

# A repository on NO board is not a card that is missing: the issue tooling's own repository is
# deliberately unlinked, and reading the two alike ends the run after the issue has already
# been closed.
Write-Host 'an issue in a repository on no board is closed and says so'
$lonely = Join-Path $fake 'lonely'
New-Item -ItemType Directory -Path $lonely | Out-Null
@'
$a = $args -join ' '
if ($a -match 'projectItems')      { exit 0 }
if ($a -match 'projectsV2\(first') { exit 0 }
if ($args[0] -eq 'repo') { 'example-org/example-repo'; exit 0 }
'{}'
exit 0
'@ | Set-Content -Path (Join-Path $lonely 'gh.ps1') -Encoding utf8NoBOM
"@echo off`r`npwsh -NoProfile -File `"$lonely\gh.ps1`" %*" |
  Set-Content -Path (Join-Path $lonely 'gh.cmd') -Encoding ascii
if (-not $IsWindows) { Set-Content -Path (Join-Path $lonely 'gh') -Value "#!/bin/sh`nexec pwsh -NoProfile -File `"$lonely/gh.ps1`" `"`$@`"" -Encoding ascii; & chmod +x (Join-Path $lonely 'gh') }

$kept = $env:PATH
$env:PATH = "$lonely$([IO.Path]::PathSeparator)$env:PATH"
$out = @(& $close -Repo $repo -Number 270)
Check 'the close line' '#270 -> closed' $out[0]
Check 'and says why there is no card' "#270 -> done (issue only; $repo is on no board)" $out[1]
$env:PATH = $kept

Remove-Item -Recurse -Force $fake -ErrorAction SilentlyContinue
if ($failed -gt 0) { Write-Host "`n$failed failed"; exit 1 }
Write-Host "`nall passed"
