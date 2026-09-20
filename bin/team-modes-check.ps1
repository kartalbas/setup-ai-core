<#
.SYNOPSIS
Are the three team modes installed for the agent tools on this machine?

.EXAMPLE
./team-modes-check.ps1

.EXAMPLE
./team-modes-check.ps1 -Tool claude -Quiet

.NOTES
Reads team-modes.tsv, one row per tool and mode, and probes each row for the tools named with
-Tool - or, without it, for every tool whose command is on PATH. Prints one line per row and,
where a mode is missing, the command that installs it. Exits 1 when any mode is missing or
unverifiable, because the rules say no work starts without the three, and this check is what
makes that sentence true: session-start, start-issue and the push hook run it first.

The activation inside a session (the mode's own slash command at its level) is not something a
file on disk can prove; session-start prints the three commands for the agent to run.

TEAM_MODES_FILE overrides the table, for tests.
#>
[CmdletBinding()]
param(
  [string[]] $Tool = @(),
  [switch]   $Quiet
)

$ErrorActionPreference = 'Stop'
$root  = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot '../lib/Board.psm1') -Force
$table = if ($env:TEAM_MODES_FILE) { $env:TEAM_MODES_FILE } else { Get-DataFile 'team-modes.tsv' }
if (-not (Test-Path $table)) { Write-Host "REFUSED: $table is missing - it is the table of the team modes."; exit 1 }

function Say($text) { if (-not $Quiet) { Write-Host $text } }

$rows = Get-Content $table | Where-Object { $_ -and -not $_.StartsWith('#', [StringComparison]::Ordinal) } | ForEach-Object {
  $f = $_ -split "`t"
  if ($f.Count -ge 5) { [pscustomobject]@{ Tool = $f[0]; Mode = $f[1]; Level = $f[2]; Probe = $f[3]; Install = $f[4]; Verified = $(if ($f.Count -ge 6) { $f[5] } else { '-' }) } }
}

# Without -Tool, the tool that RUNS this session is the one checked, read from the variables
# each tool sets in its shells: a tool that is merely installed beside it must not hold the
# session up. Where no tool runs (a person in a plain terminal), every tool the table knows and
# whose command is on this PATH is checked. A machine with none of them gets a note and a green
# exit: there is nothing here to hold, and refusing would stop a person who works through a tool
# this table has never heard of.
if ($Tool.Count -eq 0) {
  if ($env:CLAUDECODE) { $Tool = @('claude') }
  elseif ($env:CODEX_SANDBOX -or $env:CODEX_SANDBOX_NETWORK_DISABLED -or $env:CODEX_THREAD_ID) { $Tool = @('codex') }
  elseif ($env:GEMINI_CLI) { $Tool = @('gemini') }
}
if ($Tool.Count -eq 0) {
  $Tool = @($rows | Select-Object -ExpandProperty Tool -Unique | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue })
  if ($Tool.Count -eq 0) {
    Say "team modes: no agent tool from $(Split-Path -Leaf $table) is on PATH, so nothing is checked here."
    exit 0
  }
}

# Each tool lists what it installed with its own command, and puts skills in its own folder.
# The shared .agents/skills folder is where the skills installer writes for every tool at once.
function Get-PluginList($tool) {
  try {
    switch -CaseSensitive ($tool) {
      'claude' { return (& claude plugin list 2>$null | Out-String) }
      # Codex lists every plugin its marketplaces offer, installed or not, so the name alone
      # proves nothing; the lines that say "not installed" are dropped first.
      'codex'  { return ((& codex plugin list 2>$null | Where-Object { $_ -inotmatch 'not installed' }) -join "`n") }
      'gemini' { return (& gemini extensions list 2>$null | Out-String) }
      default  { return '' }
    }
  } catch { return '' }
}
# The home directory is read from HOME where it is set - the sh twin and the tests set it -
# and from the shell's own idea of it otherwise.
$homeDir = if ($env:HOME) { $env:HOME } else { $HOME }
function Test-Probe($tool, $probe) {  # 0 installed, 1 missing, 2 no probe
  $kind, $name = $probe -split ':', 2
  switch -CaseSensitive ($kind) {
    'always' { return 0 }
    'none'   { return 2 }
    'plugin' { if ((Get-PluginList $tool) -imatch [regex]::Escape($name)) { return 0 } else { return 1 } }
    'skill'  {
      foreach ($d in @("$homeDir/.$tool/skills/$name", "./.$tool/skills/$name", "$homeDir/.agents/skills/$name", "./.agents/skills/$name")) {
        if (Test-Path $d -PathType Container) { return 0 }
      }
      return 1
    }
    'file'   { if (Test-Path ($name -replace '^~', $homeDir)) { return 0 } else { return 1 } }
    default  { return 2 }
  }
}

$missing = 0; $unverified = 0; $checked = 0
foreach ($t in $Tool) {
  $mine = @($rows | Where-Object { $_.Tool -ceq $t })
  if ($mine.Count -eq 0) {
    Say "UNVERIFIED  ${t}: no rows in $(Split-Path -Leaf $table) - whoever uses this tool adds them (probe and install per mode)."
    $unverified++
    continue
  }
  foreach ($r in $mine) {
    $checked++
    $install = if ($r.Install) { $r.Install } else { '-' }
    switch -CaseSensitive (Test-Probe $t $r.Probe) {
      0 { Say "ok          $t $($r.Mode) ($($r.Level))" }
      2 { Say "UNVERIFIED  $t $($r.Mode): no probe yet - fill the row in $(Split-Path -Leaf $table) (its install column says: $install)."; $unverified++ }
      default { Say "MISSING     $t $($r.Mode) ($($r.Level)) - install: $install"; $missing++ }
    }
  }
}

if ($missing -gt 0 -or $unverified -gt 0) {
  Write-Host "REFUSED: $missing mode(s) missing, $unverified unverifiable, for: $($Tool -join ' '). Run team-modes-install, restart the tool, then start again. No work starts without the three modes."
  exit 1
}
Say "team modes: all $checked present for: $($Tool -join ' ')."
exit 0
