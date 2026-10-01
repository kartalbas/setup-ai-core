#!/usr/bin/env pwsh
<#
.SYNOPSIS
Open the team of one project in one terminal window, one tab per session.
.DESCRIPTION
The coordinator starts as the person in charge; two sessions of each model start with no prompt
and so cost nothing until the coordinator sends them a package. A session is named
<first three letters of the folder>-<model>-<index>, so the coordinator finds its workers with
ListAgents. The tabs open in Ptyxis or gnome-terminal on Linux and in Windows Terminal on Windows;
AI_CORE_TERMINAL names one of the three where the first one found is not the one wanted. -DryRun
prints the team and opens nothing.
.EXAMPLE
./team-open.ps1 ~/repos/shop -DryRun
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)][string] $Folder = '',
  [switch] $DryRun,
  [switch] $Help
)

$ErrorActionPreference = 'Stop'
$usage = 'usage: team-open.ps1 PROJECT_FOLDER [-DryRun]'
function Stop-With([string]$message, [int]$code = 1) { [Console]::Error.WriteLine("error: $message"); exit $code }

if ($Help) { $usage; exit 0 }
if (-not $Folder) { Stop-With $usage 2 }
if (-not (Test-Path -LiteralPath $Folder -PathType Container)) { Stop-With "$Folder is not a folder" }
$Folder = (Resolve-Path -LiteralPath $Folder).Path.TrimEnd('/', '\')
$name = Split-Path -Leaf $Folder
$prefix = if ($name.Length -gt 3) { $name.Substring(0, 3) } else { $name }

# <name> <model> <effort>: the coordinator first, then the pairs
$team = @(
  @("$prefix-opus-1", 'opus', 'max'),
  @("$prefix-fable-1", 'fable', 'max'),
  @("$prefix-fable-2", 'fable', 'max'),
  @("$prefix-opus-2", 'opus', 'high'),
  @("$prefix-opus-3", 'opus', 'high'),
  @("$prefix-sonnet-1", 'sonnet', 'max'),
  @("$prefix-sonnet-2", 'sonnet', 'max')
)
$lead = "$prefix-opus-1"
$leadPrompt = "You are the person in charge of the project $name."

$terminal = "$env:AI_CORE_TERMINAL"
if (-not $terminal) {
  foreach ($t in @('ptyxis', 'gnome-terminal', 'wt')) { if (Get-Command $t -ErrorAction SilentlyContinue) { $terminal = $t; break } }
}
if ($terminal -and $terminal -cnotin @('ptyxis', 'gnome-terminal', 'wt')) {
  Stop-With "AI_CORE_TERMINAL names '$terminal'; the terminals supported are ptyxis, gnome-terminal and wt"
}

"team of $name, in $(if ($terminal) { $terminal } else { 'no supported terminal' }):"
foreach ($s in $team) { '  {0,-14} {1,-7} {2,-5}{3}' -f $s[0], $s[1], $s[2], $(if ($s[0] -ceq $lead) { ' the person in charge' } else { '' }) }
if ($DryRun) { exit 0 }
if (-not $terminal) { Stop-With 'no supported terminal: install Ptyxis or gnome-terminal (Linux), or Windows Terminal (Windows)' }
if (-not (Get-Command $terminal -ErrorAction SilentlyContinue)) { Stop-With "$terminal is not installed" }

$first = $true
foreach ($s in $team) {
  $n, $m, $e = $s
  $cmd = "claude -n $n --model $m --effort $e"
  if ($n -ceq $lead) { $cmd = "$cmd '$leadPrompt'" }
  switch -CaseSensitive ($terminal) {
    'ptyxis'         { & ptyxis $(if ($first) { '--new-window' } else { '--tab' }) -T $n -d $Folder -- bash -lc "$cmd; exec bash" }
    'gnome-terminal' { & gnome-terminal $(if ($first) { '--window' } else { '--tab' }) "--title=$n" "--working-directory=$Folder" -- bash -lc "$cmd; exec bash" }
    'wt'             { & wt -w $name new-tab --title $n -d $Folder pwsh -NoLogo -NoExit -Command $cmd }
  }
  if ($LASTEXITCODE -ne 0) { Stop-With "$terminal could not open the tab of $n" }
  # The window stands before its tabs are sent: a tab goes into the window that is active
  if ($first) { Start-Sleep -Seconds 1 }
  $first = $false
}
"opened: the 7 sessions of $name"
