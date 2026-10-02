#!/usr/bin/env pwsh
<#
.SYNOPSIS
The status line command, which graft-setup puts into .claude/settings.json.
.DESCRIPTION
Claude Code hands it the session's state as JSON on standard input; the account's usage windows in
it, rate_limits with used_percentage and resets_at per window, are recorded in ~/.ai-core/usage.json,
where `ai-core usage` reads them for every session of the machine. Then Graft's status line runs on
the same input, as before; without it a short line of the model and the windows is shown.
#>
[CmdletBinding()]
param([switch] $Help)

if ($Help) { "usage: statusline.ps1  (Claude Code's status line JSON on standard input)"; exit 0 }
$text = [Console]::In.ReadToEnd()
$home_ = if ($env:AI_CORE_HOME) { $env:AI_CORE_HOME } elseif ($env:HOME) { $env:HOME } else { $env:USERPROFILE }
$state = $null
try { $state = $text | ConvertFrom-Json } catch { $state = $null }
if ($state -and $state.rate_limits -and @($state.rate_limits.PSObject.Properties).Count -gt 0) {
  $dir = Join-Path $home_ '.ai-core'
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $record = [ordered]@{ recorded_at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); rate_limits = $state.rate_limits }
  $file = Join-Path $dir 'usage.json'
  [System.IO.File]::WriteAllText("$file.$PID", ($record | ConvertTo-Json -Depth 6 -Compress) + "`n", (New-Object System.Text.UTF8Encoding $false))
  Move-Item -Force -LiteralPath "$file.$PID" -Destination $file
  # The history, at most one line a minute, so `ai-core status` can measure what a closed issue
  # costs of a window: <epoch> <five-hour %> <its reset> <weekly %> <its reset>
  $log = Join-Path $dir 'usage.log'; $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $last = 0; if (Test-Path -LiteralPath $log) { $tail = @(Get-Content -LiteralPath $log -Tail 1); if ($tail) { $last = [long](($tail[0] -split ' ')[0]) } }
  if ($now - $last -ge 60) {
    function V($x) { if ($null -eq $x) { '-' } else { "$x" } }
    $r = $state.rate_limits
    $line = "$now $(V $r.five_hour.used_percentage) $(V $r.five_hour.resets_at) $(V $r.seven_day.used_percentage) $(V $r.seven_day.resets_at)"
    [System.IO.File]::AppendAllText($log, "$line`n", (New-Object System.Text.UTF8Encoding $false))
  }
}
$root = if ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR } else { '.' }
$graft = Join-Path $root '.claude/helpers/graft-statusline.cjs'
if ((Test-Path -LiteralPath $graft) -and (Get-Command node -ErrorAction SilentlyContinue)) {
  $text | & node $graft
} elseif ($state) {
  $parts = @()
  if ($state.model.display_name) { $parts += "$($state.model.display_name)" }
  if ($null -ne $state.rate_limits.five_hour.used_percentage) { $parts += "5h $([math]::Floor([double]$state.rate_limits.five_hour.used_percentage)) %" }
  if ($null -ne $state.rate_limits.seven_day.used_percentage) { $parts += "week $([math]::Floor([double]$state.rate_limits.seven_day.used_percentage)) %" }
  $parts -join ' · '
}
