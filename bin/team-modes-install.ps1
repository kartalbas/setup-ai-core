<#
.SYNOPSIS
Install the team modes that team-modes-check reports as missing.

.EXAMPLE
./team-modes-install.ps1

.EXAMPLE
./team-modes-install.ps1 -Tool claude -DryRun

.NOTES
Runs the install column of team-modes.tsv for every missing mode of the tools named with -Tool
- or, without it, of every tool whose command is on PATH. A row without a probe or without an
install command is reported, never guessed at. After it, the tool has to be started again: a
plugin loads when the tool starts, and a session that was already running does not see it.

It is run by a person, or by an agent on that person's word; it changes the machine.
#>
[CmdletBinding()]
param(
  [string[]] $Tool = @(),
  [switch]   $DryRun
)

$ErrorActionPreference = 'Stop'
$root  = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot '../lib/Board.psm1') -Force
$table = if ($env:TEAM_MODES_FILE) { $env:TEAM_MODES_FILE } else { Get-DataFile 'team-modes.tsv' }
if (-not (Test-Path $table)) { Write-Host "REFUSED: $table is missing - it is the table of the team modes."; exit 1 }

$rows = Get-Content $table | Where-Object { $_ -and -not $_.StartsWith('#', [StringComparison]::Ordinal) } | ForEach-Object {
  $f = $_ -split "`t"
  if ($f.Count -ge 5) { [pscustomobject]@{ Tool = $f[0]; Mode = $f[1]; Install = $f[4] } }
}
if ($Tool.Count -eq 0) {
  $Tool = @($rows | Select-Object -ExpandProperty Tool -Unique | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue })
  if ($Tool.Count -eq 0) { Write-Host "team modes: no agent tool from $(Split-Path -Leaf $table) is on PATH; pass -Tool to name one."; exit 0 }
}

# The check decides what is missing, so the two never disagree about it. One line of its
# report per mode, and the MISSING lines are the ones to act on.
$installed = 0; $failed = 0; $skipped = 0
foreach ($t in $Tool) {
  $report = & (Join-Path $PSScriptRoot 'team-modes-check.ps1') -Tool $t 6>&1 2>&1 | Out-String
  foreach ($line in ($report -split "`r?`n")) {
    if ($line -cmatch '^MISSING\s+\S+\s+(\S+)') {
      $mode = $Matches[1]
      $install = ($rows | Where-Object { $_.Tool -ceq $t -and $_.Mode -ceq $mode } | Select-Object -First 1).Install
      if (-not $install -or $install -eq '-') { Write-Host "SKIPPED     $t ${mode}: no install command in the table; see the mode's own documentation."; $skipped++; continue }
      Write-Host "installing  $t ${mode}: $install"
      if ($DryRun) { continue }
      # The install column is a shell line, and `&&` inside it is what PowerShell 7 runs as is.
      #
      # THE STATUS IS CLEARED FIRST AND $? IS READ WITH IT. $LASTEXITCODE holds the status of
      # the last NATIVE program, and the modes check above is one: it exits 1 whenever a mode is
      # missing, which is the only state this loop runs in. An install command written as
      # cmdlets sets no status of its own, so the check's 1 would still be standing and every
      # such command would be reported as failed. $? is what says whether the command itself
      # succeeded, the way the shell twin reads the status of `bash -c`.
      $global:LASTEXITCODE = 0
      Invoke-Expression $install
      if ($? -and ($LASTEXITCODE -eq 0 -or $null -eq $LASTEXITCODE)) { $installed++ }
      else { Write-Host "FAILED      $t ${mode}: the install command exited $LASTEXITCODE."; $failed++ }
    } elseif ($line -cmatch '^UNVERIFIED') { Write-Host $line; $skipped++ }
    elseif ($line -cmatch '^(ok|team modes)') { Write-Host $line }
  }
}

Write-Host ''
Write-Host "installed $installed, failed $failed, skipped $skipped."
if ($installed -gt 0) { Write-Host 'Start the tool again now: a plugin loads when the tool starts, and a running session does not see it.' }
if ($failed -gt 0 -or $skipped -gt 0) { exit 1 }
exit 0
