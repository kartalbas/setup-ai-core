# The PowerShell twin of issue-duplicate.test.sh, asserting the SAME direction. GitHub's
# "Duplicate of #N" syntax is directional FROM the issue receiving the comment, so a reversed
# call marks the canonical issue as the duplicate and nothing in the answer says so.
#
#   pwsh -File test/issue-duplicate.test.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fake = Join-Path ([IO.Path]::GetTempPath()) "gh-fake-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $fake | Out-Null
$log = Join-Path $fake 'calls.txt'

@"
`$a = `$args -join ' '
Add-Content -Path '$log' -Value `$a
if (`$a -match 'issues/412') { 'I_node412'; exit 0 }
if (`$a -match 'issues/421') { 'I_node421'; exit 0 }
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

$dup = Join-Path $root 'bin/issue-duplicate.ps1'
$repo = 'example-org/example-repo'
$other = 'example-org/other-repo'
function Calls { @(Get-Content $log -ErrorAction SilentlyContinue) }
function Clear-Log { Remove-Item $log -ErrorAction SilentlyContinue }

Write-Host 'the comment lands on the DUPLICATE and names the canonical issue'
Clear-Log
$out = (@(& $dup -CanonicalRepo $repo -CanonicalNumber 412 -DuplicateRepo $repo -DuplicateNumber 421) -join "`n")
Check 'the line'     "$repo#421 is marked as a duplicate of $repo#412" $out
Check 'the endpoint' 'True' ([bool]((Calls) -match [regex]::Escape("repos/$repo/issues/421/comments")))
Check 'the body'     'True' ([bool]((Calls) -match 'body=Duplicate of #412'))

Write-Host 'across repositories the reference carries the owner and the repository'
Clear-Log
$out = (@(& $dup -CanonicalRepo $other -CanonicalNumber 412 -DuplicateRepo $repo -DuplicateNumber 421) -join "`n")
Check 'the line' "$repo#421 is marked as a duplicate of $other#412" $out
Check 'the body' 'True' ([bool]((Calls) -match [regex]::Escape("body=Duplicate of $other#412")))

Write-Host '-Undo takes the relation off through the mutation, not through a comment'
Clear-Log
$out = (@(& $dup -CanonicalRepo $repo -CanonicalNumber 412 -DuplicateRepo $repo -DuplicateNumber 421 -Undo) -join "`n")
Check 'the line'     "$repo#421 is no longer marked as a duplicate of $repo#412" $out
Check 'the mutation' 'True'  ([bool]((Calls) -match 'unmarkIssueAsDuplicate'))
Check 'the two ids'  'True'  ([bool]((Calls) -match 'canonical=I_node412 -f duplicate=I_node421'))
Check 'no comment'   'False' ([bool]((Calls) -match 'comments'))

Write-Host 'a repository not named OWNER/REPO stops before GitHub is reached'
Clear-Log
$said = ''
try { & $dup -CanonicalRepo 'example-repo' -CanonicalNumber 412 -DuplicateRepo $repo -DuplicateNumber 421 | Out-Null }
catch { $said = $_.Exception.Message }
Check 'names which'  'True' ([bool]($said -match "the canonical issue's repository"))
Check 'nothing sent' 0      (Calls).Count

Clear-Log
$said = ''
try { & $dup -CanonicalRepo $repo -CanonicalNumber 412 -DuplicateRepo 'example-repo' -DuplicateNumber 421 | Out-Null }
catch { $said = $_.Exception.Message }
Check 'the other side too' 'True' ([bool]($said -match "the duplicate issue's repository"))
Check 'nothing sent'       0      (Calls).Count

Write-Host 'a number that is not one stops at the binder, before anything is sent'
Clear-Log
$said = ''
try { & $dup -CanonicalRepo $repo -CanonicalNumber 'many' -DuplicateRepo $repo -DuplicateNumber 421 | Out-Null }
catch { $said = $_.Exception.Message }
Check 'it throws'    'True' ([string]([bool]$said))
Check 'nothing sent' 0      (Calls).Count

Remove-Item -Recurse -Force $fake -ErrorAction SilentlyContinue
if ($failed -gt 0) { Write-Host "`n$failed failed"; exit 1 }
Write-Host "`nall passed"
