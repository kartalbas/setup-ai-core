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
  Write-Host "Builds the Graft code graph with the Node.js on this machine (npx -y @nanonets/graft)."
  Write-Host "Reads GRAFT_EXECUTION_MODE from .ai-core/config.env: native (default) or skip."
  Write-Host "There is no fallback: without Node.js and npx, native mode fails with exit 1."
  Write-Host ""
  Write-Host "Options:"
  Write-Host "  -TargetDir <path>   Target directory"
  Write-Host "  -Help               Show this help message"
  Write-Host ""
  Write-Host "Examples:"
  Write-Host "  pwsh -File .ai-core/bin/graft-setup.ps1 -TargetDir ."
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

  Write-Host "==> Graft: building the code graph with npx -y @nanonets/graft..."
  & npx -y @nanonets/graft init
  if ($LASTEXITCODE -eq 0) { & npx -y @nanonets/graft build }
  if ($LASTEXITCODE -ne 0) {
    Write-Host "error: Graft build failed; see the output above. Fix the cause and run this script again, or set GRAFT_EXECUTION_MODE=`"skip`" in $configFile." -ForegroundColor Red
    exit 1
  }
  if (-not ((Test-Path "graft\index.md") -or (Test-Path "graft\INDEX.md"))) {
    Write-Host "error: Graft finished without writing graft\index.md." -ForegroundColor Red
    exit 1
  }
  Write-Host "==> Graft index created at $((Get-Location).Path)\graft\index.md" -ForegroundColor Green
} finally {
  Pop-Location
}
