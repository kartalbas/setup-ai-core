# The ai-core command. It lives in bin\ of the setup-ai-core clone (~\.setup-ai-core on a
# developer's machine) and runs the scripts next to it.
#
#   ai-core <command> [arguments]
#
[CmdletBinding()]
param (
  [Parameter(Position = 0)][string]$Command = "help",
  [Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments = @()
)

$ErrorActionPreference = 'Stop'

$core = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

function Show-Usage {
  Write-Host "Usage: ai-core <command> [arguments]"
  Write-Host ""
  Write-Host "Commands:"
  Write-Host "  init [-TargetDir <dir>] [-All <folder>] [-NoDoctor] [-Remote]"
  Write-Host "                                      Install or refresh the harness in a checkout, or in every repository under a folder"
  Write-Host "  doctor [-NoInstall]                 Check the prerequisites on this machine, install what is missing"
  Write-Host "  update                              Pull setup-ai-core (git pull --ff-only in $core)"
  Write-Host "  session-start [-Json]               The session start of the current repository"
  Write-Host "  graft [-TargetDir <dir>]            Build the Graft code graph"
  Write-Host "  solution-path -File <file> ...      Validate a solution path"
  Write-Host "  rules-check [-RulesFile <path>]     Validate enforcement tags"
  Write-Host "  version                             Print the setup-ai-core version"
  Write-Host "  help                                Show this help message"
}

switch ($Command) {
  { $_ -in @('init', 'doctor', 'session-start', 'solution-path', 'rules-check') } {
    & pwsh -NoProfile -File (Join-Path $core "bin\$Command.ps1") @Arguments
    exit $LASTEXITCODE
  }
  'graft' {
    & pwsh -NoProfile -File (Join-Path $core "bin\graft-setup.ps1") @Arguments
    exit $LASTEXITCODE
  }
  'update' {
    Write-Host "--> Updating setup-ai-core at $core"
    & git -C $core pull --ff-only
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    Write-Host "--> Run ai-core init in your checkouts to refresh their copies"
  }
  'version' { (Get-Content (Join-Path $core "VERSION") -Raw).Trim() }
  { $_ -in @('help', '-h', '--help') } { Show-Usage }
  default {
    Write-Host "error: unknown command '$Command'" -ForegroundColor Red
    Show-Usage
    exit 1
  }
}
