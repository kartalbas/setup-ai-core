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

# The team is the project's: its harness's team.tsv where init laid one into the folder, else the
# default of setup-ai-core. One @(name, model, effort) per session, the coordinator first.
$teamFile = Join-Path $Folder '.ai-core/team.tsv'
if (-not (Test-Path -LiteralPath $teamFile)) { $teamFile = Join-Path $PSScriptRoot '../templates/.ai-core/team.tsv' }
$workers = @(); $lead = ''; $leadRow = $null; $no = 0
foreach ($line in [System.IO.File]::ReadAllLines($teamFile)) {
  $no++
  $f = @($line.TrimEnd("`r") -split "`t")
  if (-not $f[0] -or $f[0].StartsWith('#', [StringComparison]::Ordinal)) { continue }
  $role = $f[0]
  if ($role -cne 'coordinator' -and $role -cne 'worker') { Stop-With "${teamFile}:${no}: the role is coordinator or worker, not '$role'" }
  if ($f.Count -ne 4 -or -not $f[1]) { Stop-With "${teamFile}:${no}: a row is role, model, effort and count, tab-separated" }
  $model, $effort, $count = $f[1], $f[2], $f[3]
  if ($model.ToLowerInvariant().Contains('haiku')) { Stop-With "${teamFile}:${no}: '$model' is below Sonnet, the floor of the harness" }
  if ($effort -cnotin @('low', 'medium', 'high', 'xhigh', 'max')) { Stop-With "${teamFile}:${no}: the effort is low, medium, high, xhigh or max, not '$effort'" }
  if ($count -cnotmatch '^[0-9]+\z' -or [int]$count -eq 0) { Stop-With "${teamFile}:${no}: the count is a whole number above 0, not '$count'" }
  if ($role -ceq 'coordinator') {
    if ($leadRow -or [int]$count -ne 1) { Stop-With "${teamFile}:${no}: there is one coordinator, and only one" }
    $leadRow = @($model, $effort)
  }
  for ($i = 0; $i -lt [int]$count; $i++) {
    if ($role -ceq 'coordinator') { $workers += ,@('', $model, $effort, 'lead') } else { $workers += ,@('', $model, $effort, 'worker') }
  }
}
if (-not $leadRow) { Stop-With "$teamFile names no coordinator" }
# Names are counted per model in the order of the rows, as the sh twin counts them
$team = @(); $seen = @{}
foreach ($w in $workers) {
  $seen[$w[1]] = 1 + $(if ($seen.ContainsKey($w[1])) { $seen[$w[1]] } else { 0 })
  $entry = @("$prefix-$($w[1])-$($seen[$w[1]])", $w[1], $w[2])
  if ($w[3] -ceq 'lead') { $lead = $entry[0]; $team = @(,$entry) + $team } else { $team += ,$entry }
}
# The coordinator gets its team from the table that starts it, so model and effort cannot drift
$members = @($team | Where-Object { $_[0] -cne $lead } | ForEach-Object { "$($_[0]) $($_[1]) $($_[2])" }) -join ', '
$leadPrompt = "You are the person in charge of the project $name. Your team: $members."

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
