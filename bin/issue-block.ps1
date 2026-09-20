<#
.SYNOPSIS
Mark an existing issue as blocked by another existing issue, across repositories.

.EXAMPLE
./issue-block.ps1 -BlockedRepo example-org/example-repo -BlockedNumber 359 `
                  -ByRepo example-org/other-repo -ByNumber 311

.NOTES
Both issues are named by repository and number; the ids are resolved here and never stored.
The relationship is GitHub's own `blocked by` - the thing the board and the REST surface
expose - and not a sentence in a body, which nothing could query or clear.

A refusal is answered with what to do next: a dependency that already exists says so and
changes nothing, and a missing endpoint names what to check.
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
# `Invoke-Gh` throws it away, so this one call reads the stream itself to tell the two
# fixable refusals apart.
# The preference is lowered for THIS CALL ONLY. With it at Stop, PowerShell turns a native
# command's failure into a terminating error of its own before the status below is read, and the
# two sentences this script exists to write - "already blocked", "not found" - are never reached.
$id = Get-IssueDbId $ByRepo $ByNumber
$kept = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
  $answer = & gh api --method POST "repos/$BlockedRepo/issues/$BlockedNumber/dependencies/blocked_by" `
    -F "issue_id=$id" 2>&1
} finally { $ErrorActionPreference = $kept }
if ($LASTEXITCODE -ne 0) {
  $said = ($answer | ForEach-Object { $_.ToString() }) -join ' '
  if ($said -match '422') {
    Stop-WithError "$BlockedRepo#$BlockedNumber is already blocked by $ByRepo#$ByNumber - nothing was changed"
  } elseif ($said -match '404') {
    Stop-WithError 'an issue was not found - check OWNER/REPO and the numbers on both sides'
  }
  Stop-WithError $said
}
"$BlockedRepo#$BlockedNumber is blocked by $ByRepo#$ByNumber"
