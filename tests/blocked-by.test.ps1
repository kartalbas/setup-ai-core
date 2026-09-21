# The PowerShell twin of blocked-by.test.sh, asserting the SAME side of the relationship.
#
# issue-block.ps1 and issue-unblock.ps1 are one relationship written twice, so they are held here
# together: the endpoint's repository is the BLOCKED issue's and the id is the BLOCKER's database
# id. Written the other way round the dependency points backwards, and GitHub accepts it.
#
#   pwsh -File test/blocked-by.test.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fake = Join-Path ([IO.Path]::GetTempPath()) "gh-fake-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $fake | Out-Null
$log = Join-Path $fake 'calls.txt'

@"
`$a = `$args -join ' '
Add-Content -Path '$log' -Value `$a
if (`$a -match 'issues/311') { '9311'; exit 0 }
if (`$a -match 'issues/359') { '9359'; exit 0 }
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

$block = Join-Path $root 'bin/issue-block.ps1'
$unblock = Join-Path $root 'bin/issue-unblock.ps1'
$blocked = 'example-org/example-repo'
$by = 'example-org/other-repo'
function Calls { @(Get-Content $log -ErrorAction SilentlyContinue) }
function Clear-Log { Remove-Item $log -ErrorAction SilentlyContinue }

Write-Host 'the endpoint is the blocked issue, the id is the blocker'
Clear-Log
$out = (@(& $block -BlockedRepo $blocked -BlockedNumber 359 -ByRepo $by -ByNumber 311) -join "`n")
Check 'the line'     "$blocked#359 is blocked by $by#311" $out
Check 'the endpoint' 'True' ([bool]((Calls) -match [regex]::Escape("repos/$blocked/issues/359/dependencies/blocked_by")))
Check 'the id read'  'True' ([bool]((Calls) -match [regex]::Escape("api repos/$by/issues/311")))
Check 'the id sent'  'True' ([bool]((Calls) -match 'issue_id=9311'))

Write-Host 'the mirror addresses the same side, with the id in the path'
Clear-Log
$out = (@(& $unblock -BlockedRepo $blocked -BlockedNumber 359 -ByRepo $by -ByNumber 311) -join "`n")
Check 'the line'     "$blocked#359 is no longer blocked by $by#311" $out
Check 'the method'   'True' ([bool]((Calls) -match '--method DELETE'))
Check 'the endpoint' 'True' ([bool]((Calls) -match [regex]::Escape("repos/$blocked/issues/359/dependencies/blocked_by/9311")))

Write-Host 'a dependency that is already there says so and changes nothing'
$existing = Join-Path $fake 'existing'
New-Item -ItemType Directory -Path $existing | Out-Null
# The stand-in answers the way gh answers a refusal: the error BODY on stdout, where the rows
# would be, and a one-line complaint on stderr. The status code the script reads is in the body.
@'
if (($args -join ' ') -match 'issues/311( |$)') { '9311'; exit 0 }
'{"message":"Validation Failed","status":"422"}'
[Console]::Error.WriteLine('gh: HTTP 422: Validation Failed')
exit 1
'@ | Set-Content -Path (Join-Path $existing 'gh.ps1') -Encoding utf8NoBOM
"@echo off`r`npwsh -NoProfile -File `"$existing\gh.ps1`" %*" |
  Set-Content -Path (Join-Path $existing 'gh.cmd') -Encoding ascii
if (-not $IsWindows) { Set-Content -Path (Join-Path $existing 'gh') -Value "#!/bin/sh`nexec pwsh -NoProfile -File `"$existing/gh.ps1`" `"`$@`"" -Encoding ascii; & chmod +x (Join-Path $existing 'gh') }

$kept = $env:PATH
$env:PATH = "$existing$([IO.Path]::PathSeparator)$env:PATH"
$said = ''
try { & $block -BlockedRepo $blocked -BlockedNumber 359 -ByRepo $by -ByNumber 311 | Out-Null } catch { $said = $_.Exception.Message }
Check 'says so' 'True' ([bool]($said -match "already blocked by $([regex]::Escape($by))#311 - nothing was changed"))
$env:PATH = $kept

Write-Host 'a dependency that is not there says so on the way out'
$absent = Join-Path $fake 'absent'
New-Item -ItemType Directory -Path $absent | Out-Null
@'
if (($args -join ' ') -match 'issues/311( |$)') { '9311'; exit 0 }
'{"message":"Not Found","status":"404"}'
[Console]::Error.WriteLine('gh: HTTP 404: Not Found')
exit 1
'@ | Set-Content -Path (Join-Path $absent 'gh.ps1') -Encoding utf8NoBOM
"@echo off`r`npwsh -NoProfile -File `"$absent\gh.ps1`" %*" |
  Set-Content -Path (Join-Path $absent 'gh.cmd') -Encoding ascii
if (-not $IsWindows) { Set-Content -Path (Join-Path $absent 'gh') -Value "#!/bin/sh`nexec pwsh -NoProfile -File `"$absent/gh.ps1`" `"`$@`"" -Encoding ascii; & chmod +x (Join-Path $absent 'gh') }

$env:PATH = "$absent$([IO.Path]::PathSeparator)$env:PATH"
$said = ''
try { & $unblock -BlockedRepo $blocked -BlockedNumber 359 -ByRepo $by -ByNumber 311 | Out-Null } catch { $said = $_.Exception.Message }
Check 'says so' 'True' ([bool]($said -match "is not blocked by $([regex]::Escape($by))#311 - nothing was changed"))
$env:PATH = $kept

Write-Host 'a repository not named OWNER/REPO stops before GitHub is reached'
foreach ($command in @($block, $unblock)) {
  $name = Split-Path -Leaf $command
  Clear-Log
  $said = ''
  try { & $command -BlockedRepo 'example-repo' -BlockedNumber 359 -ByRepo $by -ByNumber 311 | Out-Null } catch { $said = $_.Exception.Message }
  Check "${name}: names which"  'True' ([bool]($said -match "the blocked issue's repository"))
  Check "${name}: nothing sent" 0      (Calls).Count
  Clear-Log
  $said = ''
  try { & $command -BlockedRepo $blocked -BlockedNumber 359 -ByRepo 'other-repo' -ByNumber 311 | Out-Null } catch { $said = $_.Exception.Message }
  Check "${name}: the other side too" 'True' ([bool]($said -match "the blocking issue's repository"))
  Check "${name}: still nothing sent" 0      (Calls).Count
}

Remove-Item -Recurse -Force $fake -ErrorAction SilentlyContinue
if ($failed -gt 0) { Write-Host "`n$failed failed"; exit 1 }
Write-Host "`nall passed"
