# The PowerShell twin of issue-mine.test.sh, asserting the SAME three answers.
#
# Run with a FAKE gh on PATH, so nothing leaves the machine.
#
#   pwsh -File test/issue-mine.test.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fake = Join-Path ([IO.Path]::GetTempPath()) "gh-fake-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $fake | Out-Null

@'
$a = $args -join ' '
if ($a -match 'api user')   { '{"login":"tester"}'; exit 0 }
if ($a -match 'issues/163') { '{"number":163,"assignees":[{"login":"tester"},{"login":"anton"}]}'; exit 0 }
if ($a -match 'issues/164') { '{"number":164,"assignees":[{"login":"anton"},{"login":"kadir"}]}'; exit 0 }
if ($a -match 'issues/165') { '{"number":165,"assignees":[]}'; exit 0 }
'example-org/example-repo'
exit 0
'@ | Set-Content -Path (Join-Path $fake 'gh.ps1') -Encoding utf8NoBOM
"@echo off`r`npwsh -NoProfile -File `"$fake\gh.ps1`" %*" |
  Set-Content -Path (Join-Path $fake 'gh.cmd') -Encoding ascii
if (-not $IsWindows) { Set-Content -Path (Join-Path $fake 'gh') -Value "#!/bin/sh`nexec pwsh -NoProfile -File `"$fake/gh.ps1`" `"`$@`"" -Encoding ascii; & chmod +x (Join-Path $fake 'gh') }
$env:PATH = "$fake;$env:PATH"

$failed = 0
function Check($name, $expected, $actual) {
  if ("$expected" -eq "$actual") { Write-Host "  ok   $name" }
  else { Write-Host "  FAIL $name`n       expected: $expected`n       actual:   $actual"; $script:failed++ }
}
$mine = Join-Path $root 'bin/issue-mine.ps1'
$repo = 'example-org/example-repo'
function Invoke-Mine {
  $script:out = (@(& $mine @args 2>&1 | ForEach-Object { "$_" }) -join "`n")
  return $LASTEXITCODE
}

Write-Host 'an issue assigned to the account is mine, among others or alone'
$rc = Invoke-Mine -Repo $repo -Number 163
Check 'exits zero' 0 $rc
Check 'it says so'  '#163 is assigned to @tester.' $out

Write-Host "somebody else's issue is refused, and the line names them and me"
$rc = Invoke-Mine -Repo $repo -Number 164
Check 'exits nonzero' 1 $rc
Check 'the line' 'REFUSED: #164 is assigned to @anton, @kadir, not to @tester - ask them or the product owner to reassign it.' $out

Write-Host "nobody's issue is refused too - the product owner assigns it first"
$rc = Invoke-Mine -Repo $repo -Number 165
Check 'exits nonzero' 1 $rc
Check 'the line' 'REFUSED: #165 is assigned to nobody - the product owner assigns it before it is taken up.' $out

Write-Host 'the repo may be left out inside a checkout'
$rc = Invoke-Mine -Number 163
Check 'exits zero' 0 $rc

# A refused read has an empty assignee list in it, and an empty list is the ONE answer that
# start-issue reads as "nobody has it" - which is a statement about the issue the issue never
# made. The read goes through Invoke-Gh, so a refusal stops the run instead.
Write-Host 'a refused read is not an issue assigned to nobody'
$refusing = Join-Path $fake 'refusing'
New-Item -ItemType Directory -Path $refusing | Out-Null
@'
$a = $args -join ' '
if ($a -match 'api user') { '{"login":"tester"}'; exit 0 }
if ($a -match 'issues/')  { '{"message":"Not Found"}'; [Console]::Error.WriteLine('gh: Not Found (HTTP 404)'); exit 1 }
'example-org/example-repo'
exit 0
'@ | Set-Content -Path (Join-Path $refusing 'gh.ps1') -Encoding utf8NoBOM
"@echo off`r`npwsh -NoProfile -File `"$refusing\gh.ps1`" %*" |
  Set-Content -Path (Join-Path $refusing 'gh.cmd') -Encoding ascii
if (-not $IsWindows) { Set-Content -Path (Join-Path $refusing 'gh') -Value "#!/bin/sh`nexec pwsh -NoProfile -File `"$refusing/gh.ps1`" `"`$@`"" -Encoding ascii; & chmod +x (Join-Path $refusing 'gh') }

$kept = $env:PATH
$env:PATH = "$refusing;$env:PATH"
$said = ''
try { & $mine -Repo $repo -Number 404 | Out-Null; $said = '(no refusal)' } catch { $said = $_.Exception.Message }
Check 'it throws'               'True' ([bool]($said -match 'failed with exit code 1'))
Check 'and does not say nobody' 'False' ([bool]($said -match 'assigned to nobody'))
$env:PATH = $kept

Remove-Item -Recurse -Force $fake -ErrorAction SilentlyContinue
if ($failed -gt 0) { Write-Host "`n$failed failed"; exit 1 }
Write-Host "`nall passed"
