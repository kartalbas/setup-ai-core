<#
.SYNOPSIS
Transfer an issue to another repository.

.EXAMPLE
./issue-transfer.ps1 -Repo example-org/example-repo -Number 94 -TargetRepo example-org/other-repo

.NOTES
The card is NOT moved with the issue: the target repository resolves to its own board, and
which board the work belongs on after a transfer is a decision, not a consequence. board-sync
puts it on the right one, or item-move carries it across explicitly.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidatePattern('^[0-9]+\z', ErrorMessage = "the issue number must be numeric, not '{0}'")][string] $Number,
  [Parameter(Mandatory)][string] $TargetRepo,
  [string] $Repo
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../lib/Board.psm1') -Force

if ($TargetRepo -notmatch '^[^/\s]+/[^/\s]+\z') { Stop-WithError 'the target repository must be named OWNER/REPO' }
if (-not $Repo) { $Repo = Get-DefaultRepo }

Invoke-Gh issue transfer $Number $TargetRepo --repo $Repo
