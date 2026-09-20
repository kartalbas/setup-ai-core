<#
.SYNOPSIS
Set which items a board view shows, by repo name.

.EXAMPLE
./view-filter.ps1 -Project 5 -View ALL-ISSUES -RepoName example-repo,other-repo
./view-filter.ps1 -Project 7 -View ALL-ISSUES -Clear

.NOTES
A board that carries several repos shows all of them by default, which is right for a
board that is read as a whole and wrong for one where a reader only ever wants their own
repos. The filter narrows the view; it removes nothing from the board, so a card hidden
here is still on it and still counts towards its epic.

Repos are named without the org, the way they appear in the board's own repo filter.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]   $Project,
  [string]                         $View = 'ALL-ISSUES',
  [string[]]                       $RepoName,
  [switch]                         $Clear
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../lib/Board.psm1') -Force

if (-not $Clear -and -not $RepoName) { Stop-WithError 'pass -RepoName, or -Clear to show everything again' }

Set-Project -Number $Project | Out-Null

$q = 'query($pid:ID!){ node(id:$pid){ ... on ProjectV2 { views(first:20){ nodes { id name filter } } } } }'
$rows = Invoke-Gh api graphql -f "pid=$(Get-ProjectId)" -f "query=$q" `
          --jq '.data.node.views.nodes[] | "\(.name)\t\(.id)"'
$hit = @($rows | Where-Object { ($_ -split "`t")[0] -ceq $View }) | Select-Object -First 1
if (-not $hit) {
  $names = ($rows | ForEach-Object { ($_ -split "`t")[0] }) -join ' '
  Stop-WithError "project $Project has no view named '$View'. It has: $names"
}
$viewId = ($hit -split "`t")[1]

# The filter uses the same syntax the board's own filter box takes. Several repos are
# one comma-separated repo: term, which is an OR.
$filter = if ($Clear) { '' } else { 'repo:' + (($RepoName | ForEach-Object { "$(Get-ProjectOrg)/$_" }) -join ',') }

$m = 'mutation($vid:ID!,$f:String!){ updateProjectV2View(input:{viewId:$vid, filter:$f}){ projectV2View { name filter } } }'
Invoke-Gh api graphql -f "vid=$viewId" -f "f=$filter" -f "query=$m" `
  --jq '.data.updateProjectV2View.projectV2View | "\(.name): \(if .filter == "" then "shows everything" else .filter end)"'
