# The PowerShell twin of issue-transfer.test.sh, asserting the SAME single call and the SAME
# silence about the board.
#
#   pwsh -File test/issue-transfer.test.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fake = Join-Path ([IO.Path]::GetTempPath()) "gh-fake-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $fake | Out-Null
$log = Join-Path $fake 'calls.txt'

@"
`$a = `$args -join ' '
Add-Content -Path '$log' -Value `$a
if (`$args[0] -eq 'repo') { 'example-org/example-repo'; exit 0 }
'https://github.com/example-org/other-repo/issues/7'
exit 0
"@ | Set-Content -Path (Join-Path $fake 'gh.ps1') -Encoding utf8NoBOM
"@echo off`r`npwsh -NoProfile -File `"$fake\gh.ps1`" %*" |
  Set-Content -Path (Join-Path $fake 'gh.cmd') -Encoding ascii
$env:PATH = "$fake;$env:PATH"

$failed = 0
function Check($name, $expected, $actual) {
  if ("$expected" -eq "$actual") { Write-Host "  ok   $name" }
  else { Write-Host "  FAIL $name`n       expected: $expected`n       actual:   $actual"; $script:failed++ }
}

$transfer = Join-Path $root 'bin/issue-transfer.ps1'
$repo = 'example-org/example-repo'
$target = 'example-org/other-repo'
function Calls { @(Get-Content $log -ErrorAction SilentlyContinue) }
function Clear-Log { Remove-Item $log -ErrorAction SilentlyContinue }

Write-Host 'the whole call, and nothing else'
Clear-Log
$out = (@(& $transfer -Repo $repo -Number 94 -TargetRepo $target) -join "`n")
Check 'the call'        "issue transfer 94 $target --repo $repo" ((Calls) -join "`n")
Check 'what gh printed' 'https://github.com/example-org/other-repo/issues/7' $out
Check 'no board write'  'False' ([bool]((Calls) -match 'graphql'))

Write-Host 'the repo resolves from the checkout when left out'
Clear-Log
& $transfer -Number 94 -TargetRepo $target | Out-Null
Check 'default repo' 'True' ([bool]((Calls) -match [regex]::Escape("--repo $repo")))

Write-Host 'a target not named OWNER/REPO stops before GitHub is reached'
Clear-Log
$said = ''
try { & $transfer -Repo $repo -Number 94 -TargetRepo 'other-repo' | Out-Null } catch { $said = $_.Exception.Message }
Check 'says which'   'True' ([bool]($said -match 'the target repository must be named OWNER/REPO'))
Check 'nothing sent' 0      (Calls).Count

Write-Host 'a number that is not one stops at the binder, before anything is sent'
Clear-Log
$said = ''
try { & $transfer -Repo $repo -Number 'ninety-four' -TargetRepo $target | Out-Null } catch { $said = $_.Exception.Message }
Check 'it throws'    'True' ([string]([bool]$said))
Check 'nothing sent' 0      (Calls).Count

Write-Host 'a refused transfer stops the run rather than printing a url that is not one'
$refusing = Join-Path $fake 'refusing'
New-Item -ItemType Directory -Path $refusing | Out-Null
@'
if ($args[0] -eq 'repo') { 'example-org/example-repo'; exit 0 }
'{"message":"Must have admin rights"}'
[Console]::Error.WriteLine('gh: HTTP 403')
exit 1
'@ | Set-Content -Path (Join-Path $refusing 'gh.ps1') -Encoding utf8NoBOM
"@echo off`r`npwsh -NoProfile -File `"$refusing\gh.ps1`" %*" |
  Set-Content -Path (Join-Path $refusing 'gh.cmd') -Encoding ascii

$kept = $env:PATH
$env:PATH = "$refusing;$env:PATH"
$said = ''
try { & $transfer -Repo $repo -Number 94 -TargetRepo $target | Out-Null } catch { $said = $_.Exception.Message }
Check 'it throws and names the call' 'True' ([bool]($said -match 'failed with exit code 1'))
$env:PATH = $kept

Remove-Item -Recurse -Force $fake -ErrorAction SilentlyContinue
if ($failed -gt 0) { Write-Host "`n$failed failed"; exit 1 }
Write-Host "`nall passed"
