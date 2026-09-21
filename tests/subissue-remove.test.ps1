# The PowerShell twin of subissue-remove.test.sh, asserting the SAME two sides: the endpoint's
# repository is the PARENT's and the id is the CHILD's, resolved in the child's own repository.
# Every repository numbers its own issues, and a number resolved in the wrong one is a real issue
# that the API accepts without a word.
#
#   pwsh -File test/subissue-remove.test.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fake = Join-Path ([IO.Path]::GetTempPath()) "gh-fake-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $fake | Out-Null
$log = Join-Path $fake 'calls.txt'

# Number 136 exists in BOTH repositories with different database ids, which is exactly the
# ambiguity under test - only the id says which one the call was pointed at.
@"
`$a = `$args -join ' '
Add-Content -Path '$log' -Value `$a
if (`$a -match 'api repos/example-org/example-repo/issues/136 ') { '9001'; exit 0 }
if (`$a -match 'api repos/example-org/other-repo/issues/136 ')   { '9002'; exit 0 }
if (`$a -match 'api repos/example-org/example-repo/issues/149 ') { '9003'; exit 0 }
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

$remove = Join-Path $root 'bin/subissue-remove.ps1'
$repo = 'example-org/example-repo'
$other = 'example-org/other-repo'
function Calls { @(Get-Content $log -ErrorAction SilentlyContinue) }
function Clear-Log { Remove-Item $log -ErrorAction SilentlyContinue }

Write-Host 'a child of the same repository is resolved there'
Clear-Log
$out = (@(& $remove -Repo $repo -Parent 241 -Child 149) -join "`n")
Check 'the line'     '#149 detached from #241' $out
Check 'the endpoint' 'True' ([bool]((Calls) -match [regex]::Escape("--method DELETE repos/$repo/issues/241/sub_issue")))
Check 'the id sent'  'True' ([bool]((Calls) -match 'sub_issue_id=9003'))

Write-Host 'a child named OWNER/REPO#N is resolved in ITS repository, not in the parent one'
Clear-Log
$out = (@(& $remove -Repo $repo -Parent 241 -Child "$other#136") -join "`n")
Check 'the line'              "$other#136 detached from #241" $out
Check 'the id was read there' 'True'  ([bool]((Calls) -match [regex]::Escape("api repos/$other/issues/136")))
Check 'and not here'          'False' ([bool]((Calls) -match [regex]::Escape("api repos/$repo/issues/136")))
Check 'the id sent'           'True'  ([bool]((Calls) -match 'sub_issue_id=9002'))
Check 'the endpoint is still the parent' 'True' ([bool]((Calls) -match [regex]::Escape("repos/$repo/issues/241/sub_issue")))

Write-Host 'several children are several calls'
Clear-Log
$out = @(& $remove -Repo $repo -Parent 241 -Child @('149', "$other#136"))
Check 'two DELETEs'   2 @((Calls) | Where-Object { $_ -match '--method DELETE' }).Count
Check 'both reported' 2 @($out | Where-Object { $_ -match 'detached from #241' }).Count

Write-Host 'the repo resolves from the checkout when left out'
Clear-Log
& $remove -Parent 241 -Child 149 | Out-Null
Check 'default repo' 'True' ([bool]((Calls) -match [regex]::Escape("repos/$repo/issues/241/sub_issue")))

Remove-Item -Recurse -Force $fake -ErrorAction SilentlyContinue
if ($failed -gt 0) { Write-Host "`n$failed failed"; exit 1 }
Write-Host "`nall passed"
