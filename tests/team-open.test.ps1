# The PowerShell twin of team-open.test.sh: the same team, read off a stand-in terminal; no
# window opens. The run itself is asserted where a stand-in can record its arguments as given,
# which a .cmd file on Windows cannot.
#
#   pwsh -File tests/team-open.test.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fake = Join-Path ([IO.Path]::GetTempPath()) "team-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$bin = Join-Path $fake 'bin'
New-Item -ItemType Directory -Force -Path $bin, (Join-Path $fake 'repos/digitaplatform') | Out-Null
$calls = Join-Path $fake 'calls.txt'
if (-not $IsWindows) {
  Set-Content -Path (Join-Path $bin 'ptyxis') -Value "#!/usr/bin/env bash`nprintf '%s|' `"`$@`" >> '$calls'; printf '\n' >> '$calls'" -Encoding ascii
  & chmod +x (Join-Path $bin 'ptyxis')
}
$env:PATH = "$bin$([IO.Path]::PathSeparator)$env:PATH"
$env:AI_CORE_TERMINAL = 'ptyxis'
$project = (Resolve-Path (Join-Path $fake 'repos/digitaplatform')).Path.TrimEnd('/', '\')

$failed = 0
function Check($name, $expected, $actual) {
  if ("$expected" -ceq "$actual") { Write-Host "  ok   $name" }
  else { Write-Host "  FAIL $name`n       expected: [$expected]`n       actual:   [$actual]"; $script:failed++ }
}
function Run([string[]]$arguments) {
  $script:out = (& pwsh -NoProfile -File (Join-Path $root 'bin/team-open.ps1') @arguments 2>&1 | Out-String)
  $script:rc = $LASTEXITCODE
}

Write-Host 'the team of a folder, each named after the first three letters of it'
Run @($project, '-DryRun')
Check 'exit 0' 0 $rc
$team = @(
  '  dig-opus-1     opus    max   the person in charge',
  '  dig-fable-1    fable   max  ',
  '  dig-fable-2    fable   max  ',
  '  dig-opus-2     opus    high ',
  '  dig-opus-3     opus    high ',
  '  dig-sonnet-1   sonnet  max  ',
  '  dig-sonnet-2   sonnet  max  '
) -join "`n"
Check 'the team' $team ((@($out -split "`r?`n" | Where-Object { $_.StartsWith('  ', [StringComparison]::Ordinal) })) -join "`n")
Check 'nothing opened' 'False' ([string](Test-Path $calls))

if (-not $IsWindows) {
  Write-Host 'the run opens one window and six tabs, each session with its name, model and effort'
  Run @($project)
  Check 'exit 0' 0 $rc
  $lines = @(Get-Content $calls)
  Check 'seven calls' 7 $lines.Count
  Check 'the window, the person in charge' "--new-window|-T|dig-opus-1|-d|$project|--|bash|-lc|claude -n dig-opus-1 --model opus --effort max 'You are the person in charge of the project digitaplatform. Your team: dig-fable-1 fable max, dig-fable-2 fable max, dig-opus-2 opus high, dig-opus-3 opus high, dig-sonnet-1 sonnet max, dig-sonnet-2 sonnet max.'; exec bash|" $lines[0]
  Check 'a tab, a worker with no prompt' "--tab|-T|dig-sonnet-2|-d|$project|--|bash|-lc|claude -n dig-sonnet-2 --model sonnet --effort max; exec bash|" $lines[6]
  Check 'and it says so' 'True' ([bool]($out -cmatch '(?m)^opened: the 7 sessions of digitaplatform\r?$'))
}

Write-Host "a project's own team.tsv sets the team"
New-Item -ItemType Directory -Force -Path (Join-Path $project '.ai-core') | Out-Null
[System.IO.File]::WriteAllText((Join-Path $project '.ai-core/team.tsv'), "coordinator`tsonnet`thigh`t1`nworker`tfable`tmax`t1`n")
Run @($project, '-DryRun')
Check 'exit 0' 0 $rc
Check 'its team' (@('  dig-sonnet-1   sonnet  high  the person in charge', '  dig-fable-1    fable   max  ') -join "`n") ((@($out -split "`r?`n" | Where-Object { $_.StartsWith('  ', [StringComparison]::Ordinal) })) -join "`n")
Write-Host 'a model below the floor of the harness is refused'
[System.IO.File]::WriteAllText((Join-Path $project '.ai-core/team.tsv'), "coordinator`topus`tmax`t1`nworker`thaiku`tmax`t2`n")
Run @($project, '-DryRun')
Check 'exit 1' 1 $rc
Check 'it names it' 'True' ([bool]($out -cmatch "'haiku' is below Sonnet"))
Remove-Item -Recurse -Force (Join-Path $project '.ai-core')

Write-Host 'a folder that is not there is refused'
Run @((Join-Path $fake 'nowhere'))
Check 'exit 1' 1 $rc
Check 'it names it' 'True' ([bool]($out -cmatch 'is not a folder'))

Write-Host 'a terminal that is not supported is refused by name'
$env:AI_CORE_TERMINAL = 'xterm'
Run @($project)
Check 'exit 1' 1 $rc
Check 'it names it' 'True' ([bool]($out -cmatch "AI_CORE_TERMINAL names 'xterm'"))

$env:AI_CORE_TERMINAL = $null
Remove-Item -Recurse -Force $fake -ErrorAction SilentlyContinue
if ($failed -gt 0) { Write-Host "`n$failed failed"; exit 1 }
Write-Host "`nall passed"
