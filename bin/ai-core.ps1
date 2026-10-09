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
  Write-Host "  install, doctor, init, push, update, version"
  Write-Host "Inside a repository:"
  Write-Host "  session-start, rules-check, solution-path"
  Write-Host ""
  Write-Host "Commands, from $core\bin:"
  Get-ChildItem -Path (Join-Path $core "bin") -Filter "*.ps1" | Sort-Object Name | ForEach-Object {
    $name = $_.BaseName
    if ($name -ceq "ai-core") { return }
    Write-Host "  $name"
  }
  Write-Host "  version                    Print the setup-ai-core version"
  Write-Host "  help                       Show this help message"
}

switch -CaseSensitive ($Command) {
  'version' { (Get-Content (Join-Path $core "VERSION") -Raw).Trim() }
  { $_ -in @('help', '-h', '--help') } { Show-Usage }
  default {
    $script = Join-Path $core "bin\$Command.ps1"
    if ($Command -cne "ai-core" -and (Test-Path $script)) {
      # Every command takes -Help: a script with a -Help switch answers it itself; any other shows
      # its comment-based help, which lists the parameters and which of them are required
      if ($Arguments.Count -gt 0 -and $Arguments[0] -cin @('-h', '--help', '-Help', '-help')) {
        if ((Get-Content -Raw -LiteralPath $script) -cmatch '\[switch\]\s*\$Help\b') { & pwsh -NoProfile -File $script -Help; exit $LASTEXITCODE }
        Get-Help $script | Out-String
        exit 0
      }
      & pwsh -NoProfile -File $script @Arguments
      exit $LASTEXITCODE
    }
    Write-Host "error: unknown command '$Command'" -ForegroundColor Red
    Show-Usage
    exit 1
  }
}
