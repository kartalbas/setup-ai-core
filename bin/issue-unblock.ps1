<#
.SYNOPSIS
Clear a `blocked by` dependency between two issues, across repositories.

.EXAMPLE
./issue-unblock.ps1 -BlockedRepo example-org/example-repo -BlockedNumber 103 `
                    -ByRepo example-org/other-repo -ByNumber 325

.NOTES
The mirror of issue-block.ps1, and it exists for the same reason that one does: a dependency
somebody recorded by hand is one nobody can clear by hand, and a stale blocker is worse than
none - it holds work off the board that nothing is actually waiting for.

A refusal is answered with what to do next: a dependency that is not there says so and changes
nothing, and a missing endpoint names what to check.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string] $BlockedRepo,
  [Parameter(Mandatory)][ValidatePattern('^[0-9]+\z', ErrorMessage = "the blocked issue number must be numeric, not '{0}'")][string] $BlockedNumber,
  [Parameter(Mandatory)][string] $ByRepo,
  [Parameter(Mandatory)][ValidatePattern('^[0-9]+\z', ErrorMessage = "the blocking issue number must be numeric, not '{0}'")][string] $ByNumber
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../lib/Board.psm1') -Force

# Malformed names stop HERE, before GitHub is called at all.
if ($BlockedRepo -notmatch '^[^/\s]+/[^/\s]+\z') {
  Stop-WithError "the blocked issue's repository must be named OWNER/REPO"
}
if ($ByRepo -notmatch '^[^/\s]+/[^/\s]+\z') {
  Stop-WithError "the blocking issue's repository must be named OWNER/REPO"
}

# THE ENDPOINT'S REPO IS THE BLOCKED ISSUE'S and the id is the BLOCKER's database id -
# resolved here, sent once, stored nowhere. gh's stderr carries the status code and
# `Invoke-Gh` throws it away, so this one call reads the stream itself to tell the one
# fixable refusal apart.
# The preference is lowered for THIS CALL ONLY. With it at Stop, PowerShell turns a native
# command's failure into a terminating error of its own before the status below is read, and the
# sentence this script exists to write - "not blocked by" - is never reached.
$id = Get-IssueDbId $ByRepo $ByNumber
$kept = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
  $answer = & gh api --method DELETE "repos/$BlockedRepo/issues/$BlockedNumber/dependencies/blocked_by/$id" 2>&1
} finally { $ErrorActionPreference = $kept }
if ($LASTEXITCODE -ne 0) {
  $said = ($answer | ForEach-Object { $_.ToString() }) -join ' '
  if ($said -match '404') {
    Stop-WithError "$BlockedRepo#$BlockedNumber is not blocked by $ByRepo#$ByNumber - nothing was changed"
  }
  Stop-WithError $said
}
"$BlockedRepo#$BlockedNumber is no longer blocked by $ByRepo#$ByNumber"
