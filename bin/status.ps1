#!/usr/bin/env pwsh
<#
.SYNOPSIS
The state of the work on one board and the plan for the rest, printed the same way every time.
.DESCRIPTION
The usage windows, the pace, what an issue costs, every worker's packages with their start and end,
the pauses at the usage limit, the end of the work, and what is ready to close. It is counted from
the board, the team, the usage the status line records and the session transcripts; no model is
involved. This script reads the board; lib/status.mjs counts, so status.sh prints the same page.
-Issues adds every open issue, by package.
.EXAMPLE
./status.ps1 -Project 1 -Issues
#>
[CmdletBinding()]
param([string] $Project = '', [switch] $Issues, [switch] $Help)

$ErrorActionPreference = 'Stop'
if ($Help) { 'usage: status.ps1 [-Project N] [-Issues]'; exit 0 }
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
  if ($Issues) { $flags += '--issues' }
  & node (Join-Path $PSScriptRoot '../lib/status.mjs') @flags
  $rc = $LASTEXITCODE
} finally {
  Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue
}
exit $rc
