<#
.SYNOPSIS
Reopen issues and put every board card back in ready.

.EXAMPLE
./issue-reopen.ps1 -Repo example-org/example-repo -Number 412
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidatePattern('^[0-9]+\z', ErrorMessage = "the issue number must be numeric, not '{0}'")][string[]] $Number,
  [string] $Repo
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../lib/Board.psm1') -Force

if (-not $Repo) { $Repo = Get-DefaultRepo }

# Every board is checked for the column before any issue is reopened: a board of an older
# layout has no `ready`, and a reopened issue whose card could not move would stand half-done.
foreach ($n in $Number) { Test-OptionOnEveryBoard -Repo $Repo -Number $n -Field 'Status' -Option 'ready' }

foreach ($n in $Number) {
  Invoke-Gh api --method PATCH "repos/$Repo/issues/$n" -f state=open | Out-Null

  "#$n -> reopened"
  Invoke-OnEveryBoard -Repo $Repo -Number $n -Field 'Status' -Option 'ready' -Printed 'ready'
}
