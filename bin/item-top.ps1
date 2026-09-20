<#
.SYNOPSIS
Put cards at the top of the board, in the order they are named.

.EXAMPLE
./item-top.ps1 -Repo example-org/example-repo -Number 42

.EXAMPLE
./item-top.ps1 -Repo example-org/example-repo -Number 373,372,371

.EXAMPLE
./item-top.ps1 -Project 6 -Number 42

.NOTES
epics-top.ps1 does the same act for every epic on a board, found by title. This one takes the
numbers, for an order somebody worked out.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidatePattern('^[0-9]+\z', ErrorMessage = "the issue number must be numeric, not '{0}'")][string[]] $Number,
  [string] $Repo,
  # The board to reorder. Left out, it is resolved from the repo - and a repo keeps one live
  # board, which is the same rule every other script here follows.
  [string] $Project
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../lib/Board.psm1') -Force

if (-not $Repo) { $Repo = Get-DefaultRepo }
Set-Project -Number $Project -Repo $Repo | Out-Null

# The order the names arrive in is the order the cards end in: each one is moved directly under
# the card moved before it, and the first is moved above everything. Moving each to the top
# instead would hand back the names reversed - the one outcome nobody asking for this wants.
$under = ''
foreach ($n in $Number) {
  $item = Get-ItemId $Repo $n
  Set-ItemTop -ItemId $item -AfterId $under
  $under = $item
  "#$n -> top"
}
