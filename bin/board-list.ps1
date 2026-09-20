<#
.SYNOPSIS
What is on the board right now, in column order: status, priority, repo, number, title.

.EXAMPLE
./board-list.ps1
./board-list.ps1 -Status Todo
./board-list.ps1 -Status Todo -RepoName example-repo

.NOTES
This is the check after a batch of changes - the board is the single source of truth for
state, so reading it back is how a move is proven rather than assumed.
#>
[CmdletBinding()]
param([string] $Status, [string] $RepoName, [string] $Project = '')

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../lib/Board.psm1') -Force

Set-Project -Number $Project | Out-Null

$q = @'
query($pid:ID!, $endCursor:String) { node(id:$pid) { ... on ProjectV2 {
  items(first:100, after:$endCursor) {
    pageInfo { hasNextPage endCursor }
    nodes {
      fieldValues(first:20) { nodes { ... on ProjectV2ItemFieldSingleSelectValue {
        name field { ... on ProjectV2SingleSelectField { name } } } } }
      content { ... on Issue { number title state repository { name } } }
    } } } } }
'@

$jq = @'
.data.node.items.nodes[] | select(.content.number != null)
| { n: .content.number, t: .content.title, r: .content.repository.name, closed: (.content.state == "CLOSED"),
    s: ([.fieldValues.nodes[] | select(.field.name == "Status")   | .name] | first // "-"),
    p: ([.fieldValues.nodes[] | select(.field.name == "Priority") | .name] | first // "-") }
| "\(.s)\t\(.p)\t\(.r)\t\(.n)\t\(.t)\t\(if .closed then "closed" else "" end)"
'@

$rows = Invoke-Gh api graphql --paginate -f "pid=$(Get-ProjectId)" -f "query=$q" --jq $jq |
  Where-Object { $_ } |
  ForEach-Object {
    $s, $p, $r, $n, $t, $c = $_ -split "`t"
    [pscustomobject]@{ Status = $s; Priority = $p; Repo = $r; Number = [int]$n; Title = $t; Closed = $c }
  }

if ($Status)   { $rows = $rows | Where-Object Status -ceq $Status }
if ($RepoName) { $rows = $rows | Where-Object Repo   -ceq $RepoName }

$rows | Sort-Object Status, Priority, Repo, Number | ForEach-Object {
  '{0,-15} {1,-3} {2,-22} #{3,-4} {4}{5}' -f $_.Status, $_.Priority, $_.Repo, $_.Number, $_.Title,
    $(if ($_.Closed) { "  [$($_.Closed)]" } else { '' })
}
