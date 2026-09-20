<#
.SYNOPSIS
Close issues as completed (the default) or as not planned, and put their board cards in done.

.EXAMPLE
./issue-close.ps1 -Repo example-org/example-repo -Number 2,3,4

.EXAMPLE
./issue-close.ps1 -Repo example-org/example-repo -Number 270 -Reason not-planned
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidatePattern('^[0-9]+\z', ErrorMessage = "the issue number must be numeric, not '{0}'")][string[]] $Number,
  [string] $Repo,
  # A superseded or rejected design closes as not planned. Recording it as completed says
  # work shipped when it did not.
  [ValidateSet('completed', 'not-planned', IgnoreCase=$false)][string] $Reason = 'completed'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../lib/Board.psm1') -Force

if (-not $Repo) { $Repo = Get-DefaultRepo }

# The close is reported on its own line and each board on its own after it: the issue is
# closed ONCE, but its cards are plural - a sub-issue of a cross-repository epic sits on two
# boards, and one line saying "closed, done" about one of them is false about the other.
$stateReason = if ($Reason -ceq 'not-planned') { 'not_planned' } else { $Reason }
foreach ($n in $Number) {
  Invoke-Gh api --method PATCH "repos/$Repo/issues/$n" -f state=closed -f "state_reason=$stateReason" | Out-Null

  "#$n -> closed"
  Invoke-OnEveryBoard -Repo $Repo -Number $n -Field 'Status' -Option 'done' -Printed 'done'
}
