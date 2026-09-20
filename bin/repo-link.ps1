<#
.SYNOPSIS
Link a repo to a project, and give it the label taxonomy at the same time.

.EXAMPLE
./repo-link.ps1 -Project 5
./repo-link.ps1 -Project 5 -Repo example-org/other-repo

.NOTES
Run this once per new repo. Without the link its issues can still be added to the board
by hand, but the repo does not appear in the board's own repo filter.

-Project is mandatory here: the whole point of this script is to create the link that
every other script uses to find the project from the repo, so that link cannot itself be
resolved from the repo - it does not exist yet.
#>
[CmdletBinding()]
param([string[]] $Repo, [Parameter(Mandatory)][string] $Project)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../lib/Board.psm1') -Force

if (-not $Repo) { $Repo = @(Get-DefaultRepo) }
Set-Project -Number "$Project" | Out-Null

$q = 'mutation($pid:ID!, $rid:ID!) { linkProjectV2ToRepository(input:{projectId:$pid, repositoryId:$rid}) { repository { nameWithOwner } } }'
foreach ($r in $Repo) {
  $rid = Invoke-Gh api "repos/$r" --jq '.node_id'
  $name = Invoke-Gh api graphql -f "pid=$(Get-ProjectId)" -f "rid=$rid" -f "query=$q" `
            --jq '.data.linkProjectV2ToRepository.repository.nameWithOwner'
  "linked: $name"
}

& (Join-Path $PSScriptRoot 'labels-sync.ps1') -Repo $Repo
