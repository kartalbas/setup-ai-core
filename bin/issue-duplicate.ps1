<#
.SYNOPSIS
Mark or unmark one issue as the native GitHub duplicate of another.

.EXAMPLE
./issue-duplicate.ps1 -CanonicalRepo example-org/example-repo -CanonicalNumber 412 -DuplicateRepo example-org/example-repo -DuplicateNumber 421

.NOTES
The direction is explicit because GitHub's "Duplicate of #N" comment syntax is directional
from the issue receiving the comment and is easy to reverse.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string] $CanonicalRepo,
  [Parameter(Mandatory)][ValidatePattern('^[0-9]+\z', ErrorMessage = "the canonical issue number must be numeric, not '{0}'")][string] $CanonicalNumber,
  [Parameter(Mandatory)][string] $DuplicateRepo,
  [Parameter(Mandatory)][ValidatePattern('^[0-9]+\z', ErrorMessage = "the duplicate issue number must be numeric, not '{0}'")][string] $DuplicateNumber,
  [switch] $Undo
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../lib/Board.psm1') -Force

if ($CanonicalRepo -notmatch '^[^/\s]+/[^/\s]+\z') { Stop-WithError "the canonical issue's repository must be named OWNER/REPO" }
if ($DuplicateRepo -notmatch '^[^/\s]+/[^/\s]+\z') { Stop-WithError "the duplicate issue's repository must be named OWNER/REPO" }

if ($Undo) {
  $canonicalId = Get-IssueNodeId $CanonicalRepo $CanonicalNumber
  $duplicateId = Get-IssueNodeId $DuplicateRepo $DuplicateNumber
  $mutation = 'mutation($canonical:ID!,$duplicate:ID!){unmarkIssueAsDuplicate(input:{canonicalId:$canonical,duplicateId:$duplicate}){duplicate{... on Issue{number}}}}'
  Invoke-Gh api graphql -f "canonical=$canonicalId" -f "duplicate=$duplicateId" -f "query=$mutation" | Out-Null
  $verb = 'is no longer marked as a duplicate of'
} else {
  $canonicalRef = "$CanonicalRepo#$CanonicalNumber"
  if ($CanonicalRepo -ceq $DuplicateRepo) { $canonicalRef = "#$CanonicalNumber" }
  Invoke-Gh api --method POST "repos/$DuplicateRepo/issues/$DuplicateNumber/comments" `
    -f "body=Duplicate of $canonicalRef" | Out-Null
  $verb = 'is marked as a duplicate of'
}

"$DuplicateRepo#$DuplicateNumber $verb $CanonicalRepo#$CanonicalNumber"
