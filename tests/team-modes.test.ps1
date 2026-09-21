# The PowerShell twin of team-modes.test.sh, asserting the SAME gate against the SAME table.
#
# A fake claude on PATH answers `plugin list`, and a temporary HOME holds or lacks the skill
# folder, so every state a machine can be in is arranged here without touching this one.
#
#   pwsh -File test/team-modes.test.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fake = Join-Path ([IO.Path]::GetTempPath()) "team-modes-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $fake | Out-Null
$plugins = Join-Path $fake 'plugins.txt'

# The fake tool: `claude plugin list` names what the test says is installed.
@"
if ((`$args -join ' ') -eq 'plugin list') { Get-Content '$plugins' }
exit 0
"@ | Set-Content -Path (Join-Path $fake 'claude.ps1') -Encoding utf8NoBOM
Set-Content -Path (Join-Path $fake 'claude.cmd') -Value "@pwsh -NoProfile -File `"$fake\claude.ps1`" %*" -Encoding ascii
if (-not $IsWindows) { Set-Content -Path (Join-Path $fake 'claude') -Value "#!/bin/sh`nexec pwsh -NoProfile -File `"$fake/claude.ps1`" `"`$@`"" -Encoding ascii; & chmod +x (Join-Path $fake 'claude') }
$env:PATH = "$fake;$env:PATH"
$env:HOME = Join-Path $fake 'home'
New-Item -ItemType Directory -Path $env:HOME | Out-Null
$env:TEAM_MODES_FILE = Join-Path $root 'templates/.ai-core/team-modes.tsv'
# The skill probe also looks in the current directory's skill folders, and a project-level
# install in this checkout would count as installed; the test runs from its own directory.
Set-Location $fake

$failed = 0
function Check($name, $expected, $actual) {
  if ("$expected" -eq "$actual") { Write-Host "  ok   $name" }
  else { Write-Host "  FAIL $name`n       expected: $expected`n       actual:   $actual"; $script:failed++ }
}
$check = Join-Path $root 'bin/team-modes-check.ps1'
# A HASHTABLE, not an array: splatting an array binds by position, and '-Tool' would arrive
# as a value instead of naming the parameter.
function RunCheck([hashtable] $callArgs) {
  $script:out = (& $check @callArgs 6>&1 2>&1 | Out-String)
  $script:code = $LASTEXITCODE
}
function Count($pattern) { @(($script:out -split "`r?`n") | Where-Object { $_ -match $pattern }).Count }

Write-Host 'nothing installed: three MISSING lines with their install commands, and a refusal'
Set-Content -Path $plugins -Value '' -Encoding utf8NoBOM
RunCheck @{ Tool = 'claude' }
Check 'exit 1'                       1 $code
Check 'three missing'                3 (Count '^MISSING')
Check 'caveman names its installer'  'True' ([bool]($out -match 'MISSING .*caveman.*npx skills add JuliusBrussee/caveman'))
Check 'ponytail names its installer' 'True' ([bool]($out -match 'MISSING .*ponytail.*claude plugin install ponytail@ponytail'))
Check 'the refusal says no work starts' 'True' ([bool]($out -match 'REFUSED: 3 mode\(s\) missing.*No work starts'))

Write-Host 'the two plugins installed, the skill not: one MISSING'
Set-Content -Path $plugins -Value "Installed plugins:`n  ponytail@ponytail`n  i-have-adhd@i-have-adhd" -Encoding utf8NoBOM
RunCheck @{ Tool = 'claude' }
Check 'exit 1'        1 $code
Check 'one missing'   1 (Count '^MISSING')
Check 'it is caveman' 'True' ([bool]($out -match 'MISSING .*caveman'))

Write-Host 'all three installed: every line ok, exit 0'
New-Item -ItemType Directory -Path (Join-Path $env:HOME '.claude/skills/caveman') -Force | Out-Null
RunCheck @{ Tool = 'claude' }
Check 'exit 0'              0 $code
Check 'three ok'            3 (Count '^ok ')
Check 'says all present'    'True' ([bool]($out -match 'team modes: all 3 present for: claude'))
Check 'and names the level' 'True' ([bool]($out -match 'ok\s+claude caveman \(lite\)'))

Write-Host 'the shared .agents/skills folder counts as installed too'
Remove-Item -Recurse -Force (Join-Path $env:HOME '.claude/skills/caveman')
New-Item -ItemType Directory -Path (Join-Path $env:HOME '.agents/skills/caveman') -Force | Out-Null
RunCheck @{ Tool = 'claude' }
Check 'exit 0' 0 $code

Write-Host 'a row without a probe is refused as unverifiable, never guessed'
$noProbe = Join-Path $fake 'no-probe.tsv'
Set-Content -Path $noProbe -Value "hermes`tcaveman`tlite`tnone`t-`t-" -Encoding utf8NoBOM
$kept = $env:TEAM_MODES_FILE
$env:TEAM_MODES_FILE = $noProbe
RunCheck @{ Tool = 'hermes' }
Check 'exit 1'                    1 $code
Check 'names the unverified mode' 'True' ([bool]($out -match 'UNVERIFIED\s+hermes caveman: no probe yet'))
$env:TEAM_MODES_FILE = $kept

Write-Host 'a tool the table does not know is refused with the row to add'
RunCheck @{ Tool = 'hermes' }
Check 'exit 1'        1 $code
Check 'asks for rows' 'True' ([bool]($out -match 'UNVERIFIED\s+hermes: no rows'))

Write-Host 'a table that is not there is a refusal, not an empty pass'
$env:TEAM_MODES_FILE = Join-Path $fake 'no-such-table.tsv'
RunCheck @{ Tool = 'claude' }
Check 'exit 1'  1 $code
Check 'says so' 'True' ([bool]($out -match 'REFUSED: .*is missing - it is the table of the team modes'))
$env:TEAM_MODES_FILE = $kept

Write-Host 'a table whose probes always pass is what the other tests use'
$always = Join-Path $fake 'always.tsv'
Set-Content -Path $always -Value "claude`tcaveman`tlite`talways`t-`t-" -Encoding utf8NoBOM
$env:TEAM_MODES_FILE = $always
RunCheck @{ Tool = 'claude' }
Check 'exit 0' 0 $code
$env:TEAM_MODES_FILE = $kept

Write-Host 'team-modes-install -DryRun prints the install command of every missing mode and runs nothing'
Set-Content -Path $plugins -Value '' -Encoding utf8NoBOM
Remove-Item -Recurse -Force (Join-Path $env:HOME '.agents/skills/caveman') -ErrorAction SilentlyContinue
$out = (& (Join-Path $root 'bin/team-modes-install.ps1') -Tool claude -DryRun 6>&1 2>&1 | Out-String)
$code = $LASTEXITCODE
Check 'exit 0'                 0 $code
Check 'three install lines'    3 (Count '^installing ')
Check 'ponytail command whole' 'True' ([bool]($out -match 'installing  claude ponytail: claude plugin marketplace add DietrichGebert/ponytail && claude plugin install ponytail@ponytail'))

# EVERY MISSING ROW'S COMMAND RUNS, NOT ONLY THE FIRST ONE, and both halves of a command
# joined with `&&` run. The shell twin reads the check's report over standard input and hands
# that input to whatever it starts, so a command reading one character swallows the rows under
# it; this twin holds the same table to the same answer. A cmdlet install command sets no exit
# status of its own, and the check that ran a moment earlier exited 1, so this also holds that
# a stale status is not read as a failed install.
Write-Host 'team-modes-install runs the command of every missing row, and both halves of each'
$marks = Join-Path $fake 'marks.txt'
Set-Content -Path $marks -Value '' -Encoding utf8NoBOM
$standin = Join-Path $fake 'standin.tsv'
Set-Content -Path $standin -Encoding utf8NoBOM -Value @(
  '# a stand-in table: no probe here is on this machine, so every row is missing'
  "probetool`tcaveman`tlite`tfile:$fake/nowhere-a`tAdd-Content -LiteralPath '$marks' -Value 'caveman-a' && Add-Content -LiteralPath '$marks' -Value 'caveman-b'`t-"
  "probetool`tponytail`tfull`tfile:$fake/nowhere-b`tAdd-Content -LiteralPath '$marks' -Value 'ponytail-a' && Add-Content -LiteralPath '$marks' -Value 'ponytail-b'`t-"
  "probetool`ti-have-adhd`ton`tfile:$fake/nowhere-c`tAdd-Content -LiteralPath '$marks' -Value 'adhd-a' && Add-Content -LiteralPath '$marks' -Value 'adhd-b'`t-"
)
$env:TEAM_MODES_FILE = $standin
$out = (& (Join-Path $root 'bin/team-modes-install.ps1') -Tool probetool 6>&1 2>&1 | Out-String)
$code = $LASTEXITCODE
Check 'exit 0'               0 $code
Check 'three install lines'  3 (Count '^installing ')
Check 'the count says three' 'True' ([bool]($out -match 'installed 3, failed 0, skipped 0\.'))
Check 'every half of every row ran, in order' 'caveman-a caveman-b ponytail-a ponytail-b adhd-a adhd-b' `
  ((@(Get-Content -LiteralPath $marks) | Where-Object { $_ }) -join ' ')

Write-Host 'an install command that ends non-zero is counted FAILED and the run is red'
$standinBad = Join-Path $fake 'standin-bad.tsv'
Set-Content -Path $standinBad -Encoding utf8NoBOM -Value @(
  "probetool`tcaveman`tlite`tfile:$fake/nowhere-a`tpwsh -NoProfile -Command 'exit 3'`t-"
)
$env:TEAM_MODES_FILE = $standinBad
$out = (& (Join-Path $root 'bin/team-modes-install.ps1') -Tool probetool 6>&1 2>&1 | Out-String)
$code = $LASTEXITCODE
Check 'exit 1'           1 $code
Check 'the row is named' 'True' ([bool]($out -match 'FAILED\s+probetool caveman: the install command exited 3\.'))
Check 'the count'        'True' ([bool]($out -match 'installed 0, failed 1, skipped 0\.'))
$env:TEAM_MODES_FILE = $kept

Write-Host 'session-start refuses before printing anything when a mode is missing'
Set-Location $root
$out = (& (Join-Path $root 'bin/session-start.ps1') -Tool claude 6>&1 2>&1 | Out-String)
$code = $LASTEXITCODE
Check 'exit 1'                     1 $code
Check 'it refuses'                 'True'  ([bool]($out -match 'REFUSED'))
Check 'no registries printed'      'False' ([bool]($out -match '## Registries'))

Set-Location $root
Remove-Item -Recurse -Force $fake -ErrorAction SilentlyContinue
if ($failed -gt 0) { Write-Host "`n$failed failed"; exit 1 }
Write-Host "`nall passed"
