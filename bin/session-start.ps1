# Session Start Procedure for AI Coding Agents
#
#   session-start.ps1 [-Json]
#
[CmdletBinding()]
param (
  [switch]$Help,

  [switch]$Json
)

if ($Help -or $args -contains "-h" -or $args -contains "--help" -or ($args.Count -gt 0 -and ($args[0] -eq "--help" -or $args[0] -eq "-h"))) {
  Write-Host "Usage: session-start.ps1 [-Json] [-Help]"
  Write-Host ""
  Write-Host "Starts a new AI agent coding session by requesting task context and goal."
  Write-Host ""
  Write-Host "Options:"
  Write-Host "  -Help, -h, --help    Show this help message"
  Write-Host "  -Json                Print the same facts as JSON"
  Write-Host ""
  Write-Host "Exit status is 1 when the core rules file is missing (run init)."
  Write-Host ""
  Write-Host "Examples:"
  Write-Host "  ai-core session-start"
  Write-Host "  ai-core session-start -Json"
  exit 0
}

$ErrorActionPreference = 'Stop'

$root = (Get-Location).Path
$repoName = Split-Path -Leaf $root

$branch = "not-a-git-repo"
try {
  $branch = (git rev-parse --abbrev-ref HEAD 2>$null).Trim()
} catch {}

$dirtyCount = 0
try {
  $status = git status --porcelain 2>$null
  if ($status) { $dirtyCount = ($status | Measure-Object).Count }
} catch {}

$rulesPath = if (Test-Path ".ai-core\rules\rules.md") { ".ai-core/rules/rules.md" } elseif (Test-Path "rules\rules.md") { "rules/rules.md" } else { "" }
$rulesOk = ($rulesPath -ne "")
$localRulesOk = Test-Path ".ai-core\rules\rules.local.md"
$harnessVersion = if (Test-Path ".ai-core\VERSION") { (Get-Content ".ai-core\VERSION" -Raw).Trim() } else { "" }
$graftWorkspace = Test-Path "graft\workspace.json"
$graftOk = (Test-Path "graft\index.md") -or (Test-Path "graft\INDEX.md") -or $graftWorkspace

$ghLoggedIn = $false
$ghUser = ""
if (Get-Command gh -ErrorAction SilentlyContinue) {
  try {
    $null = gh auth status 2>$null
    if ($LASTEXITCODE -eq 0) {
      $ghLoggedIn = $true
      $ghUser = (gh api user -q .login 2>$null).Trim()
    }
  } catch {}
}

if ($Json) {
  [PSCustomObject]@{
    repository          = $repoName
    root                = $root
    branch              = $branch
    uncommitted_files   = $dirtyCount
    harness_version     = $harnessVersion
    rules_present       = $rulesOk
    rules_path          = $rulesPath
    local_rules_present = $localRulesOk
    graft_indexed       = $graftOk
    gh_authenticated    = $ghLoggedIn
    gh_user             = $ghUser
  } | ConvertTo-Json
  if ($rulesOk) { exit 0 } else { exit 1 }
}

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "AI Agent Session Start: $repoName" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "Branch           : $branch"
Write-Host "Uncommitted files: $dirtyCount"
Write-Host "Harness version  : $(if ($harnessVersion) { $harnessVersion } else { '✗ Missing (.ai-core/VERSION)' })"
Write-Host "Rules file       : $(if ($rulesOk) { "✓ Present ($rulesPath)" } else { '✗ Missing' })"
Write-Host "Local rules      : $(if ($localRulesOk) { '✓ Present (.ai-core/rules/rules.local.md)' } else { '– None' })"
Write-Host "Graft code graph : $(if ($graftWorkspace) { '✓ Workspace (graft/workspace.json)' } elseif ($graftOk) { '✓ Indexed (graft/index.md)' } else { '✗ Not indexed (run ai-core graft)' })"
if ($ghLoggedIn) {
  Write-Host "GitHub status    : ✓ Authenticated as @$ghUser" -ForegroundColor Green
} else {
  Write-Host "GitHub status    : ✗ Not logged in / gh missing" -ForegroundColor Yellow
}
Write-Host "==================================================" -ForegroundColor Cyan

if ($dirtyCount -gt 0) {
  Write-Host "warning: Working directory has $dirtyCount uncommitted changes:" -ForegroundColor Yellow
  git status --short
}

if (-not $rulesOk) {
  Write-Host "Not ready: no rules file found. Run setup-ai-core's init in this repository." -ForegroundColor Red
  exit 1
}
Write-Host "Ready for task execution." -ForegroundColor Green
