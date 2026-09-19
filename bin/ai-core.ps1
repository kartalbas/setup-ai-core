# The ai-core command: runs the engine's scripts from the machine-level engine clone.
#
#   ai-core <command> [arguments]
#
[CmdletBinding()]
param (
  [Parameter(Position = 0)][string]$Command = "help",
  [Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments = @()
)

$ErrorActionPreference = 'Stop'

$aiCoreHome = if ($env:AI_CORE_HOME) { $env:AI_CORE_HOME } else { Join-Path $HOME ".ai-core" }
$engine = Join-Path $aiCoreHome "engine"

function Show-Usage {
  Write-Host "Usage: ai-core <command> [arguments]"
  Write-Host ""
  Write-Host "Commands:"
  Write-Host "  init [-TargetDir <dir>] [-All <folder>] [-NoDoctor] [-Remote]"
  Write-Host "                                      Install or refresh the harness in a checkout, or in every repository under a folder"
  Write-Host "  doctor [-NoInstall]                 Check the prerequisites on this machine, install what is missing"
  Write-Host "  update                              Pull the engine (git pull --ff-only in $engine)"
  Write-Host "  session-start [-Json]               The session start of the current repository"
  Write-Host "  graft [-TargetDir <dir>]            Build the Graft code graph"
  Write-Host "  solution-path -File <file> ...      Validate a solution path"
  Write-Host "  rules-check [-RulesFile <path>]     Validate enforcement tags"
  Write-Host "  version                             Print the engine version"
  Write-Host "  help                                Show this help message"
}

if (-not (Test-Path $engine -PathType Container)) {
  Write-Host "error: no engine at $engine; run the installer first (bin\install.ps1)" -ForegroundColor Red
  exit 1
}

switch ($Command) {
  { $_ -in @('init', 'doctor', 'session-start', 'solution-path', 'rules-check') } {
    & pwsh -NoProfile -File (Join-Path $engine "bin\$Command.ps1") @Arguments
    exit $LASTEXITCODE
  }
  'graft' {
    & pwsh -NoProfile -File (Join-Path $engine "bin\graft-setup.ps1") @Arguments
    exit $LASTEXITCODE
  }
  'update' {
    Write-Host "--> Updating the engine at $engine"
    & git -C $engine pull --ff-only
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    foreach ($f in @("ai-core", "ai-core.ps1", "ai-core.cmd")) { Copy-Item -Force (Join-Path $engine "bin$f") (Join-Path $aiCoreHome "bin$f") }
    Write-Host "--> Command refreshed; run ai-core init in your checkouts to refresh their copies"
  }
  'version' { (Get-Content (Join-Path $engine "VERSION") -Raw).Trim() }
  { $_ -in @('help', '-h', '--help') } { Show-Usage }
  default {
    Write-Host "error: unknown command '$Command'" -ForegroundColor Red
    Show-Usage
    exit 1
  }
}
