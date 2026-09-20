<#
.SYNOPSIS
Attach an existing issue to an epic as a real GitHub sub-issue, which is what makes the
epic's progress bar count. Issues that merely mention each other do not.

.EXAMPLE
./subissue-add.ps1 -Repo example-org/example-repo -Parent 1 -Child 2,3,4

.NOTES
Parent and child are issues, and the link between them lives on the issues - so this
touches no board and takes no project.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidatePattern('^[0-9]+\z', ErrorMessage = "the parent issue number must be numeric, not '{0}'")][string] $Parent,
  [Parameter(Mandatory)][ValidatePattern('^[0-9]+\z', ErrorMessage = "the child issue number must be numeric, not '{0}'")][string[]] $Child,
  [string] $Repo
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../lib/Board.psm1') -Force

if (-not $Repo) { $Repo = Get-DefaultRepo }

foreach ($c in $Child) {
  Invoke-Gh api --method POST "repos/$Repo/issues/$Parent/sub_issues" `
    -F "sub_issue_id=$(Get-IssueDbId $Repo $c)" | Out-Null
  "#$c -> #$Parent"
}
