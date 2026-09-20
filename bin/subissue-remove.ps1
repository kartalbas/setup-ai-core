<#
.SYNOPSIS
Detach a sub-issue from its epic, leaving both issues standing.

.EXAMPLE
./subissue-remove.ps1 -Repo example-org/example-repo -Parent 112 -Child 149,150

.EXAMPLE
./subissue-remove.ps1 -Repo example-org/example-repo -Parent 241 -Child 'example-org/other-repo#136'

.NOTES
The counterpart to subissue-add.ps1, and needed for the same reason it is: a child has
exactly ONE parent, so moving work under the epic it really belongs to is a detach
followed by an attach. Without this the only way to correct a wrong parent is to close
the issue and file it again, which throws away its comments and its history.

A child may name its own repo as OWNER/REPO#N, exactly as subissue-add.ps1 takes it -
a cross-repository child could be attached through the tooling but not detached, so
freeing it for a new parent meant the hand edit the tooling exists to stop.

The link lives on the issues, so this touches no board and takes no project.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidatePattern('^[0-9]+\z', ErrorMessage = "the parent issue number must be numeric, not '{0}'")][string] $Parent,
  [Parameter(Mandatory)][string[]] $Child,
  [string] $Repo
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../lib/Board.psm1') -Force

if (-not $Repo) { $Repo = Get-DefaultRepo }

foreach ($c in $Child) {
  # THE ENDPOINT'S REPO IS THE PARENT'S and the id is the CHILD's - so a child living
  # in another repository is resolved there, not in the parent's.
  $childRepo = $Repo
  $childNum = $c
  if ($c -match '^(.+)/([^/]+)#(\d+)\z') {
    $childRepo = "$($Matches[1])/$($Matches[2])"
    $childNum = $Matches[3]
  }
  # The number is judged AFTER the split, the way the shell twin judges it, because a child may
  # name its own repository and the digits are only the last field of that.
  if ($childNum -cnotmatch '^[0-9]+\z') {
    Stop-WithError "the child issue number must be numeric, not '$childNum' - write a number, or OWNER/REPO#N"
  }

  Invoke-Gh api --method DELETE "repos/$Repo/issues/$Parent/sub_issue" `
    -F "sub_issue_id=$(Get-IssueDbId $childRepo $childNum)" | Out-Null
  if ($childRepo -ceq $Repo) { "#$childNum detached from #$Parent" } else { "$childRepo#$childNum detached from #$Parent" }
}
