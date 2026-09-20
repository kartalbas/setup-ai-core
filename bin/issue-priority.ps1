<#
.SYNOPSIS
Set the board Priority: P0 blocker, P1 high, P2 normal, P3 low, P9 parked.

.EXAMPLE
./issue-priority.ps1 -Repo example-org/example-repo -Number 2,3 -Priority P1
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidatePattern('^[0-9]+\z', ErrorMessage = "the issue number must be numeric, not '{0}'")][string[]] $Number,
  [Parameter(Mandatory)][ValidateSet('P0','P1','P2','P3','P9', IgnoreCase=$true)][string] $Priority,
  [string] $Repo,
  [string] $Project = ''
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../lib/Board.psm1') -Force

if (-not $Repo) { $Repo = Get-DefaultRepo }
Set-Project -Number $Project -Repo $Repo | Out-Null

foreach ($n in $Number) {
  Set-Select (Get-ItemId $Repo $n) 'Priority' $Priority
  "#$n -> $Priority"
}
