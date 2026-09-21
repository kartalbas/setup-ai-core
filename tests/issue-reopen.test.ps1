# The PowerShell twin of issue-reopen.test.sh, asserting the SAME state on the wire and the SAME
# column the card goes back to.
#
#   pwsh -File test/issue-reopen.test.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fake = Join-Path ([IO.Path]::GetTempPath()) "gh-fake-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$env:GH_CACHE_DIRECTORY = Join-Path $fake 'cache'
New-Item -ItemType Directory -Path $fake | Out-Null
$log = Join-Path $fake 'calls.txt'

@"
`$a = `$args -join ' '
Add-Content -Path '$log' -Value `$a
if (`$a -match 'projectItems')      { 'example-org/998' + [char]9 + 'PVTI_item'; exit 0 }
if (`$a -match 'projectV2\(number') { 'PVT_kwreopen'; exit 0 }
if (`$a -match 'fields\(first:50')  { 'Status' + [char]9 + 'F1' + [char]9 + 'todo' + [char]9 + 'T1'; 'Status' + [char]9 + 'F1' + [char]9 + 'done' + [char]9 + 'D1'; exit 0 }
if (`$args[0] -eq 'repo') { 'example-org/example-repo'; exit 0 }
'{}'
exit 0
"@ | Set-Content -Path (Join-Path $fake 'gh.ps1') -Encoding utf8NoBOM
"@echo off`r`npwsh -NoProfile -File `"$fake\gh.ps1`" %*" |
  Set-Content -Path (Join-Path $fake 'gh.cmd') -Encoding ascii
if (-not $IsWindows) { Set-Content -Path (Join-Path $fake 'gh') -Value "#!/bin/sh`nexec pwsh -NoProfile -File `"$fake/gh.ps1`" `"`$@`"" -Encoding ascii; & chmod +x (Join-Path $fake 'gh') }
$env:PATH = "$fake;$env:PATH"

$failed = 0
function Check($name, $expected, $actual) {
  if ("$expected" -eq "$actual") { Write-Host "  ok   $name" }
  else { Write-Host "  FAIL $name`n       expected: $expected`n       actual:   $actual"; $script:failed++ }
}

$reopen = Join-Path $root 'bin/issue-reopen.ps1'
$repo = 'example-org/example-repo'
function Calls { @(Get-Content $log -ErrorAction SilentlyContinue) }
function Clear-Log { Remove-Item $log -ErrorAction SilentlyContinue }

Write-Host 'the state that reaches gh, and the column the card goes back to'
Clear-Log
$out = @(& $reopen -Repo $repo -Number 412)
Check 'the state'       'True' ([bool]((Calls) -match 'state=open'))
Check 'the issue'       'True' ([bool]((Calls) -match [regex]::Escape("api --method PATCH repos/$repo/issues/412")))
Check 'the reopen line' '#412 -> reopened' $out[0]
Check 'the board line'  '#412 -> todo (board example-org/998)' $out[1]
Check 'the option sent' 'True' ([bool]((Calls) -match 'oid=T1'))

Write-Host 'a batch is one call per issue'
Clear-Log
$out = @(& $reopen -Repo $repo -Number 412, 413)
Check 'two PATCHes'   2 @((Calls) | Where-Object { $_ -match 'api --method PATCH' }).Count
Check 'both reported' 2 @($out | Where-Object { $_ -match '-> reopened' }).Count

Write-Host 'the repo resolves from the checkout when left out'
Clear-Log
& $reopen -Number 412 | Out-Null
Check 'default repo' 'True' ([bool]((Calls) -match [regex]::Escape("repos/$repo/issues/412")))

Write-Host 'a number that is not one stops at the binder, before anything is sent'
Clear-Log
$said = ''
try { & $reopen -Repo $repo -Number 412, 'not-a-number' | Out-Null } catch { $said = $_.Exception.Message }
Check 'it throws'    'True' ([string]([bool]$said))
Check 'nothing sent' 0      @((Calls) | Where-Object { $_ -match 'api --method PATCH' }).Count

Write-Host 'a refused PATCH stops the run rather than reporting a reopen'
$refusing = Join-Path $fake 'refusing'
New-Item -ItemType Directory -Path $refusing | Out-Null
@'
if ($args[0] -eq 'repo') { 'example-org/example-repo'; exit 0 }
'{"message":"Not Found"}'
[Console]::Error.WriteLine('gh: HTTP 404')
exit 1
'@ | Set-Content -Path (Join-Path $refusing 'gh.ps1') -Encoding utf8NoBOM
"@echo off`r`npwsh -NoProfile -File `"$refusing\gh.ps1`" %*" |
  Set-Content -Path (Join-Path $refusing 'gh.cmd') -Encoding ascii
if (-not $IsWindows) { Set-Content -Path (Join-Path $refusing 'gh') -Value "#!/bin/sh`nexec pwsh -NoProfile -File `"$refusing/gh.ps1`" `"`$@`"" -Encoding ascii; & chmod +x (Join-Path $refusing 'gh') }

$kept = $env:PATH
$env:PATH = "$refusing;$env:PATH"
$threw = $false
$printed = @()
try { $printed = @(& $reopen -Repo $repo -Number 412) } catch { $threw = $true }
Check 'it throws'        'True'  ([string]$threw)
Check 'no reopened line' 'False' ([bool]($printed -match '-> reopened'))
$env:PATH = $kept

Remove-Item -Recurse -Force $fake -ErrorAction SilentlyContinue
if ($failed -gt 0) { Write-Host "`n$failed failed"; exit 1 }
Write-Host "`nall passed"
