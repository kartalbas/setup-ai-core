<#
.SYNOPSIS
Move a card. The board's Status is the only place a state is recorded, so this is how a
ticket travels from one column to the next.

.EXAMPLE
./issue-status.ps1 -Repo example-org/example-repo -Number 2,3,4 -Status implementing

.NOTES
The name is matched without case, both by the set below and by the board itself, and a
name the board does not carry stops the run and prints the ones it does. Measured on
2026-08-26, boards 6 and 7 both carry: backlog todo implementing testing done.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidatePattern('^[0-9]+\z', ErrorMessage = "the issue number must be numeric, not '{0}'")][string[]] $Number,
  [Parameter(Mandatory)][ValidateSet('backlog','todo','implementing','testing','done', IgnoreCase=$true)][string] $Status,
  [string] $Repo,
  [string] $Project = ''
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../lib/Board.psm1') -Force

if (-not $Repo) { $Repo = Get-DefaultRepo }
Set-Project -Number $Project -Repo $Repo | Out-Null

foreach ($n in $Number) {
  Set-Select (Get-ItemId $Repo $n) 'Status' $Status
  "#$n -> $Status"
}
