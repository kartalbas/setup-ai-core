#!/usr/bin/env pwsh
<#
.SYNOPSIS
What runs now, or with -Tokens (and where no agent runs) the pace and the forecast.
.DESCRIPTION
lib/status-help.txt says what it prints.
.EXAMPLE
./status.ps1 -Project 1 -Tokens -Issues
#>
[CmdletBinding()]
param([string] $Project = '', [switch] $Tokens, [switch] $Issues, [switch] $Help)

$ErrorActionPreference = 'Stop'
if ($Help) { 'usage: status.ps1 [-Project N] [-Tokens] [-Issues]'; Get-Content -LiteralPath (Join-Path $PSScriptRoot '../lib/status-help.txt'); exit 0 }
Import-Module (Join-Path $PSScriptRoot '../lib/Board.psm1') -Force
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { Stop-WithError 'status counts with node, and node is not on the PATH' }
# Outside a repository there is none to find the board from, and the board is named instead
if (-not $Project -and -not $env:GH_PROJECT_NUMBER) {
  & git rev-parse --git-dir 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) { Stop-WithError 'outside a repository, name the board - status -Project N' }
}
Set-Project -Number $Project | Out-Null

# The project folder: the one the repositories and their .worktrees stand in, found from a worktree
# too; outside a repository, the folder you stand in
$common = "$(& git rev-parse --git-common-dir 2>$null)".Trim()
$folder = if ($common) { Split-Path -Parent "$(& git -C (Join-Path $common '..') rev-parse --show-toplevel)".Trim() } else { (Get-Location).Path }
# The limit as usage.ps1 reads it: USAGE_STOP_AT of the project's config.env, else 92
$top = "$(& git rev-parse --show-toplevel 2>$null)".Trim(); if (-not $top) { $top = (Get-Location).Path }
$stop = ''
$config = Join-Path $top '.ai-core/config.env'
if (Test-Path -LiteralPath $config) {
  $line = @(Get-Content -LiteralPath $config | Where-Object { $_ -cmatch '^\s*USAGE_STOP_AT\s*=' }) | Select-Object -Last 1
  if ($line) { $stop = (($line -split '=', 2)[1] -split '#', 2)[0].Trim(' ', "`t", "`r", '"', "'") }
}
if (-not $stop) { $stop = '92' }

$work = Join-Path ([IO.Path]::GetTempPath()) "ai-core-status-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $work | Out-Null
try {
  $columns = Join-Path $work 'columns'; $items = Join-Path $work 'items'
  Set-Content -LiteralPath $columns -Value @(Get-Fields | Where-Object { $_.Field -ieq 'status' } | ForEach-Object { $_.Option })
  Set-Content -LiteralPath $items -Value @()
  $q = 'query($pid:ID!, $after:String) { node(id:$pid) { ... on ProjectV2 {
    items(first:100, after:$after) { pageInfo { hasNextPage endCursor } nodes {
      status: fieldValueByName(name:"Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } }
      priority: fieldValueByName(name:"Priority") { ... on ProjectV2ItemFieldSingleSelectValue { name } }
      content { ... on Issue { number title state closedAt body repository { nameWithOwner }
        parent { number repository { nameWithOwner } } subIssuesSummary { total } } } } } } } }'
  # One card a line, then the cursor of the next page where there is one
  $cards = '(.data.node.items.nodes[] | tojson), (.data.node.items.pageInfo | select(.hasNextPage) | "after \(.endCursor)")'
  $after = ''
  do {
    $more = if ($after) { @('-f', "after=$after") } else { @() }
    $out = @(Invoke-Gh api graphql -f "pid=$(Get-ProjectId)" @more -f "query=$q" --jq $cards)
    Add-Content -LiteralPath $items -Value @($out | Where-Object { $_.StartsWith('{', [StringComparison]::Ordinal) })
    $after = "$(@($out | Where-Object { $_.StartsWith('after ', [StringComparison]::Ordinal) }) | Select-Object -First 1)" -creplace '^after ', ''
  } while ($after)

  $flags = @('--items-file', $items, '--columns-file', $columns, '--board', "$(Get-ProjectOrg)/$(Get-ProjectNumber)",
             '--folder', $folder, '--stop-at', $stop)
  # Every process: its id, its parent, the seconds it runs and its command line, a tab between;
  # AI_CORE_PROCESSES names a file that stands in for it. Only the default view reads it.
  if (-not $Tokens -and -not $Issues) {
    $processes = Join-Path $work 'processes'
    if ($env:AI_CORE_PROCESSES) { Copy-Item -LiteralPath $env:AI_CORE_PROCESSES -Destination $processes }
    elseif ($IsWindows) {
      $at = Get-Date
      Set-Content -LiteralPath $processes -Value @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine } | ForEach-Object {
        "$($_.ProcessId)`t$($_.ParentProcessId)`t$([int]($at - $_.CreationDate).TotalSeconds)`t$($_.CommandLine)" })
    } else {
      Set-Content -LiteralPath $processes -Value @(& ps -A -o 'pid=,ppid=,etime=,command=' | ForEach-Object {
        if ($_ -cmatch '^\s*(\d+)\s+(\d+)\s+(\S+)\s+(.*)$') { "$($Matches[1])`t$($Matches[2])`t$($Matches[3])`t$($Matches[4])" } })
    }
    # How to reach each agent: Claude Code's list of its sessions, and where /proc shows them the
    # codex rollout files the processes hold open, "/proc/<pid>/fd<tab><path>"; AI_CORE_AGENTS and
    # AI_CORE_ROLLOUTS name files that stand in for them. A failed list reaches the page as its text.
    $agents = Join-Path $work 'agents'
    $rollouts = Join-Path $work 'rollouts'
    if ($env:AI_CORE_AGENTS) { Copy-Item -LiteralPath $env:AI_CORE_AGENTS -Destination $agents }
    elseif (Get-Command claude -ErrorAction SilentlyContinue) {
      $list = & claude agents --json 2> $null
      Set-Content -LiteralPath $agents -Value $(if ($LASTEXITCODE -eq 0) { $list } else { 'claude agents --json failed' })
    } else { Set-Content -LiteralPath $agents -Value @() }
    if ($env:AI_CORE_ROLLOUTS) { Copy-Item -LiteralPath $env:AI_CORE_ROLLOUTS -Destination $rollouts }
    elseif (Test-Path -LiteralPath '/proc' -PathType Container) {
      # find exits 1 on the processes it may not read, other users' or ended ones; what it read stands
      Set-Content -LiteralPath $rollouts -Value @(& find /proc -mindepth 3 -maxdepth 3 -path '/proc/*/fd/*' -lname '*/rollout-*.jsonl' -printf '%h\t%l\n' 2> $null)
    } else { Set-Content -LiteralPath $rollouts -Value @() }
    $flags += @('--processes-file', $processes, '--agents-file', $agents, '--rollouts-file', $rollouts)
  }
  if ($Tokens) { $flags += '--tokens' }
  if ($Issues) { $flags += '--issues' }
  & node (Join-Path $PSScriptRoot '../lib/status.mjs') @flags
  $rc = $LASTEXITCODE
} finally {
  Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue
}
exit $rc
