# Build the Graft code graph of the target repository, natively or not at all.
#
#   graft-setup.ps1 [-TargetDir <path>]
#
[CmdletBinding()]
param (
  [switch]$Help,
  [string]$TargetDir = "."
)

if ($Help -or $args -contains "-h" -or $args -contains "--help" -or $TargetDir -eq "--help" -or $TargetDir -eq "-h") {
  Write-Host "Usage: graft-setup.ps1 [-TargetDir <path>]"
  Write-Host ""
  Write-Host "Wires Graft into the agents on this machine (graft init -y --no-build, no picker) and builds"
  Write-Host "the code graph with the Node.js on this machine (npx -y @nanonets/graft build)."
  Write-Host "Reads GRAFT_EXECUTION_MODE from .ai-core/config.env: native (default) or skip."
  Write-Host "There is no fallback: without Node.js and npx, native mode fails with exit 1."
  Write-Host "Whatever Graft writes into the repository is recorded in .git/info/exclude, so it is never committed."
  Write-Host ""
  Write-Host "Options:"
  Write-Host "  -TargetDir <path>   Target directory"
  Write-Host "  -Help               Show this help message"
  Write-Host ""
  Write-Host "Examples:"
  Write-Host "  ai-core graft"
  exit 0
}

$ErrorActionPreference = 'Stop'

Push-Location $TargetDir
try {
  $configFile = ".ai-core\config.env"
  $graftMode = "native"

  if (Test-Path $configFile) {
    Get-Content $configFile | Where-Object { $_ -match '^\s*[^#]' } | ForEach-Object {
      $name, $value = $_ -split '=', 2
      if ($null -eq $value) { return }
      # Same normalisation as graft-setup.sh: drop an inline comment, surrounding quotes and whitespace, lowercase the value
      $value = ($value -split '#', 2)[0]
      $val = $value.Trim(' ', "`t", "`r", '"', "'").ToLowerInvariant()
      if ($name.Trim() -ceq "GRAFT_EXECUTION_MODE") { $graftMode = $val }
    }
  }

  if ($graftMode -notin @('native', 'skip')) {
    Write-Host "error: GRAFT_EXECUTION_MODE must be native or skip (got '$graftMode') in $configFile" -ForegroundColor Red
    exit 1
  }

  if ($graftMode -eq "skip") {
    Write-Host "==> Graft: skipped by $configFile." -ForegroundColor Yellow
    exit 0
  }

  if (-not (Get-Command npx -ErrorAction SilentlyContinue)) {
    Write-Host "error: Graft needs Node.js with npx on this machine and there is no fallback. Install Node.js 20+ or set GRAFT_EXECUTION_MODE=`"skip`" in $configFile." -ForegroundColor Red
    exit 1
  }

  # What Graft writes into the repository (graft\, and the files graft init wires: GEMINI.md,
  # .gemini\, .claude\skills\graft\, ...) stays out of every commit: its own block in
  # .git\info\exclude, which keeps what earlier runs recorded and grows with what this run adds.
  $exclude = $null
  try { $exclude = git rev-parse --git-path info/exclude 2>$null; if ($LASTEXITCODE -ne 0) { $exclude = $null } } catch { $exclude = $null }
  if ($exclude -and -not [System.IO.Path]::IsPathRooted($exclude)) { $exclude = Join-Path (Get-Location).Path $exclude }
  $graftLines = [System.Collections.Generic.List[string]]@('/graft/')
  function Write-GraftBlock {
    $kept = @(); $skip = $false
    if (Test-Path $exclude) {
      foreach ($line in [System.IO.File]::ReadAllLines($exclude)) {
        if ($line -like '# setup-ai-core graft start*') { $skip = $true }
        if (-not $skip) { $kept += $line }
        if ($line -like '# setup-ai-core graft end*') { $skip = $false }
      }
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $exclude) | Out-Null
    $block = @('# setup-ai-core graft start: what Graft writes into the working tree, never into a commit') + $graftLines + @('# setup-ai-core graft end')
    [System.IO.File]::WriteAllText($exclude, (($kept + $block) -join "`n") + "`n")
  }
  function Get-Snapshot { try { @(git status --porcelain --untracked-files=all 2>$null) } catch { @() } }
  if ($exclude) {
    if (Test-Path $exclude) {
      $inBlock = $false
      foreach ($line in [System.IO.File]::ReadAllLines($exclude)) {
        if ($line -like '# setup-ai-core graft start*') { $inBlock = $true; continue }
        if ($line -like '# setup-ai-core graft end*') { $inBlock = $false; continue }
        if ($inBlock -and $line -and -not $graftLines.Contains($line)) { $graftLines.Add($line) }
      }
    }
    # What graft init wires into the repository, excluded whether it exists already or not
    $dry = @(); try { $dry = @(& npx -y @nanonets/graft init -y --no-build --dry-run 2>&1 | ForEach-Object { "$_" }) } catch { $dry = @() }
    $inRepo = $false
    foreach ($line in $dry) {
      if ($line -match '^would write.*this repo:') { $inRepo = $true; continue }
      if (-not $line.StartsWith('  ')) { $inRepo = $false; continue }
      if ($inRepo) { $path = '/' + (($line.Trim() -split '\s+')[0]).Replace('\', '/'); if (-not $graftLines.Contains($path)) { $graftLines.Add($path) } }
    }
    Write-GraftBlock
    $before = Get-Snapshot
  }

  Write-Host "==> Graft: building the code graph with npx -y @nanonets/graft..."
  $result = 0
  & npx -y @nanonets/graft init -y --no-build
  if ($LASTEXITCODE -eq 0) { & npx -y @nanonets/graft build }
  if ($LASTEXITCODE -ne 0) { $result = 1 }

  if ($exclude) {
    $changed = @()
    foreach ($line in Get-Snapshot) {
      if ($before -contains $line) { continue }
      if ($line.StartsWith('?? ')) {
        $path = '/' + $line.Substring(3)
        if (-not $graftLines.Contains($path)) { $graftLines.Add($path) }
      } else { $changed += $line.Substring(3) }
    }
    Write-GraftBlock
    if ($changed.Count -gt 0) { Write-Host "warning: Graft changed committed files: $($changed -join ' '). Review them with git diff; keep or restore them." -ForegroundColor Yellow }
  }

  if ($result -ne 0) {
    Write-Host "error: Graft build failed; see the output above. Fix the cause and run this script again, or set GRAFT_EXECUTION_MODE=`"skip`" in $configFile." -ForegroundColor Red
    exit 1
  }
  # One repository gets graft\index.md; a folder of repositories gets a workspace, graft\workspace.json
  if (Test-Path "graft\workspace.json") {
    Write-Host "==> Graft workspace created at $((Get-Location).Path)\graft\workspace.json: one graph over the repositories of this folder" -ForegroundColor Green
  } elseif ((Test-Path "graft\index.md") -or (Test-Path "graft\INDEX.md")) {
    Write-Host "==> Graft index created at $((Get-Location).Path)\graft\index.md" -ForegroundColor Green
  } else {
    Write-Host "error: Graft finished without writing graft\index.md." -ForegroundColor Red
    exit 1
  }
} finally {
  Pop-Location
}
