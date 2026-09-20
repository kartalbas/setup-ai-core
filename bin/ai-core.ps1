# The ai-core command. It lives in bin\ of the setup-ai-core clone and runs the scripts next to
# it: `ai-core <name>` runs bin\<name>.ps1 with the remaining arguments, in the current directory.
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
  Write-Host "Every command takes -Help. The machine and the checkouts:"
  Write-Host "  install, doctor, init, update, version"
  Write-Host "Inside a repository:"
  Write-Host "  session-start, graft, rules-check, solution-path"
  Write-Host ""
  Write-Host "Commands, from $core\bin:"
  Get-ChildItem -Path (Join-Path $core "bin") -Filter "*.ps1" | Sort-Object Name | ForEach-Object {
    $name = $_.BaseName
    if ($name -ceq "ai-core") { return }
    if ($name -ceq "graft-setup") { Write-Host "  graft (graft-setup)" } else { Write-Host "  $name" }
  }
  Write-Host "  update                     Pull setup-ai-core (git pull --ff-only in $core)"
  Write-Host "  version                    Print the setup-ai-core version"
  Write-Host "  help                       Show this help message"
}

switch -CaseSensitive ($Command) {
  'graft' {
    & pwsh -NoProfile -File (Join-Path $core "bin\graft-setup.ps1") @Arguments
    exit $LASTEXITCODE
  }
  'update' {
    Write-Host "--> Updating setup-ai-core at $core"
    & git -C $core pull --ff-only
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    Write-Host "--> The scripts are current everywhere; run ai-core init in a checkout to refresh its rules"
  }
  'version' { (Get-Content (Join-Path $core "VERSION") -Raw).Trim() }
  { $_ -in @('help', '-h', '--help') } { Show-Usage }
  default {
    $script = Join-Path $core "bin\$Command.ps1"
    if ($Command -cne "ai-core" -and (Test-Path $script)) {
      & pwsh -NoProfile -File $script @Arguments
      exit $LASTEXITCODE
    }
    Write-Host "error: unknown command '$Command'" -ForegroundColor Red
    Show-Usage
    exit 1
  }
}
