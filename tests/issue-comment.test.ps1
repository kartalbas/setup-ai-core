# The PowerShell twin of issue-comment.test.sh, asserting the SAME contract: an inline body
# travels as --body, a file travels as --body-file so no shell reads its backticks and newlines
# on the way, and a call naming both or neither stops before GitHub is reached.
#
#   pwsh -File test/issue-comment.test.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fake = Join-Path ([IO.Path]::GetTempPath()) "gh-fake-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $fake | Out-Null
$log = Join-Path $fake 'calls.txt'

@"
`$a = `$args -join ' '
Add-Content -Path '$log' -Value `$a
if (`$args[0] -eq 'repo') { 'example-org/example-repo'; exit 0 }
'https://github.com/example-org/example-repo/issues/94#issuecomment-1'
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

$comment = Join-Path $root 'bin/issue-comment.ps1'
$repo = 'example-org/example-repo'
$bodyFile = Join-Path $fake 'comment.md'
'A body with a `backtick` in it.' | Set-Content $bodyFile -Encoding utf8NoBOM

function Calls { @(Get-Content $log -ErrorAction SilentlyContinue) }
function Clear-Log { Remove-Item $log -ErrorAction SilentlyContinue }

Write-Host 'an inline body still travels as --body'
Clear-Log
& $comment -Repo $repo -Number 94 -Body 'Comment here' | Out-Null
Check 'the whole call' "issue comment 94 --repo $repo --body Comment here" ((Calls) -join "`n")

Write-Host 'a file travels as --body-file, never as its content'
Clear-Log
& $comment -Repo $repo -Number 94 -BodyFile $bodyFile | Out-Null
Check 'the flag'           'True'  ([bool]((Calls) -match [regex]::Escape("--body-file $bodyFile")))
Check 'the issue and repo' 'True'  ([bool]((Calls) -match [regex]::Escape("issue comment 94 --repo $repo")))
Check 'no inline body'     'False' ([bool]((Calls) -match '--body '))

Write-Host 'what gh prints is what the caller gets'
$out = (@(& $comment -Repo $repo -Number 94 -BodyFile $bodyFile) -join "`n")
Check 'the comment url' 'https://github.com/example-org/example-repo/issues/94#issuecomment-1' $out

Write-Host 'the repo resolves from the checkout when left out'
Clear-Log
& $comment -Number 94 -BodyFile $bodyFile | Out-Null
Check 'default repo' 'True' ([bool]((Calls) -match [regex]::Escape("--repo $repo")))

Write-Host 'an unusable call stops before GitHub is reached'
foreach ($case in @(
  @{ Name = 'no body at all';         Args = @{ Repo = $repo; Number = 94 } }
  @{ Name = 'both a body and a file'; Args = @{ Repo = $repo; Number = 94; Body = 'Comment here'; BodyFile = $bodyFile } }
  @{ Name = 'a file that is not there'; Args = @{ Repo = $repo; Number = 94; BodyFile = (Join-Path $fake 'nope.md') } }
)) {
  Clear-Log
  $threw = $false
  $said = ''
  # A HASHTABLE held in its own variable, because `@` splats a VARIABLE name: `@($case.Args)`
  # is an array cast, which hands the command one positional argument and fails at the binder -
  # a refusal that would let every check below pass without the command ever running.
  $p = $case.Args
  try { & $comment @p | Out-Null } catch { $threw = $true; $said = $_.Exception.Message }
  Check "$($case.Name): throws"       'True' ([string]$threw)
  Check "$($case.Name): nothing sent" 0      (Calls).Count
  if ($case.Name -eq 'a file that is not there') {
    Check 'the missing file is named' 'True' ([bool]($said -match 'does not exist'))
  }
}

Remove-Item -Recurse -Force $fake -ErrorAction SilentlyContinue
if ($failed -gt 0) { Write-Host "`n$failed failed"; exit 1 }
Write-Host "`nall passed"
