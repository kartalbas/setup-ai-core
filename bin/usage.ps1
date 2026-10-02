#!/usr/bin/env pwsh
<#
.SYNOPSIS
What the account's usage windows stand at, as the status line last recorded them, and whether one
has reached the limit at which every session finishes the step in hand and waits for its reset.
.DESCRIPTION
Exit 0: every window below the limit. Exit 3: a window at the limit or more. Exit 2: nothing
recorded yet, or a wrong argument. A window whose reset time has passed counts as reset. One model's
own weekly quota is not among the windows Claude Code hands the status line, so it is not here either.
The limit is -StopAt, else USAGE_STOP_AT of the project's config.env, else 92.
.EXAMPLE
./usage.ps1 -StopAt 92
#>
[CmdletBinding()]
param([string] $StopAt = '', [switch] $Help)

if ($Help) { 'usage: usage.ps1 [-StopAt N]'; exit 0 }
if (-not $StopAt) {
  # The project's limit: USAGE_STOP_AT of its config.env, 92 where it sets none
  $top = "$(& git rev-parse --show-toplevel 2>$null)".Trim(); if (-not $top) { $top = (Get-Location).Path }
  $config = Join-Path $top '.ai-core/config.env'
  if (Test-Path -LiteralPath $config) {
    $line = @(Get-Content -LiteralPath $config | Where-Object { $_ -cmatch '^\s*USAGE_STOP_AT\s*=' }) | Select-Object -Last 1
    if ($line) { $StopAt = (($line -split '=', 2)[1] -split '#', 2)[0].Trim(' ', "`t", "`r", '"', "'") }
  }
  if (-not $StopAt) { $StopAt = '92' }
}
if ($StopAt -cnotmatch '^[0-9]+\z') { [Console]::Error.WriteLine("error: -StopAt takes a whole percentage, not '$StopAt'"); exit 2 }
$stop = [int]$StopAt
$home_ = if ($env:AI_CORE_HOME) { $env:AI_CORE_HOME } elseif ($env:HOME) { $env:HOME } else { $env:USERPROFILE }
$file = Join-Path $home_ '.ai-core/usage.json'
if (-not (Test-Path -LiteralPath $file)) { [Console]::Error.WriteLine('no usage recorded yet: the status line records it once a session has had an answer'); exit 2 }
$record = Get-Content -Raw -LiteralPath $file | ConvertFrom-Json
function When([long]$t) { [DateTimeOffset]::FromUnixTimeSeconds($t).ToLocalTime().ToString('ddd HH:mm', [Globalization.CultureInfo]::InvariantCulture) }
$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); $reached = $false
foreach ($w in $record.rate_limits.PSObject.Properties) {
  $used = if ($null -ne $w.Value.used_percentage) { [double]$w.Value.used_percentage } else { 0.0 }
  $resets = if ($null -ne $w.Value.resets_at) { [long]$w.Value.resets_at } else { 0 }
  if ($resets -gt 0 -and $resets -le $now) { $used = 0.0; $note = "reset since $(When $resets)" } else { $note = "resets $(When $resets)" }
  '{0,-10} {1,3} %  {2}' -f $w.Name, [math]::Floor($used), $note
  if ($used -ge $stop) { $reached = $true }
}
"recorded $(When ([long]$record.recorded_at)), limit $stop %"
if ($reached) { "a window stands at $stop % or more: finish the step in hand, commit and report it, then wait for its reset"; exit 3 }
