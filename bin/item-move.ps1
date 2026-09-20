<#
.SYNOPSIS
Move a repository's cards from one board to another, keeping Status and Priority.

.EXAMPLE
./item-move.ps1 -Repo example-org/example-repo -From 6 -To 7

.EXAMPLE
./item-move.ps1 -Repo example-org/example-repo -From 6 -To 7 -DryRun

.NOTES
Unlinking a repository from a project does NOT take its cards off that project. The link decides
which repositories a project may draw new items from and where the project appears in a repo's own
Projects tab; a card already added is an object of its own and stays until it is removed. So a
repository that has moved to its own board leaves its whole history behind on the old one, where it
reads as work of that board's team. There are two boards here - 6 beta and 7 alpha - and a
repository that changes hands between them is exactly this call.

Moving is add-then-remove, in that order. Field values do not travel with a card - the target board
has its own fields and its own option ids - so Status and Priority are read off the source card and
written onto the new one by the scripts that already own those two fields, which resolve their
options by NAME against the target project. A value the target board has no option for is reported
and left unset rather than mapped onto the nearest one, because a card in the wrong column is a lie
the board then tells everyone.

The issue itself is never touched: no label, no state, no comment.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string] $Repo,
  [Parameter(Mandatory)][string] $From,
  [Parameter(Mandatory)][string] $To,
  [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../lib/Board.psm1') -Force

if ($From -ceq $To) { Stop-WithError '-From and -To are the same project' }

# Every card of this repository on the source board, with the two values worth carrying.
# One page of 100 does not cover a board that has run for a while, so this pages.
Set-Project -Number $From -Repo $Repo | Out-Null

$q = 'query($pid:ID!, $after:String) { node(id:$pid) { ... on ProjectV2 {
  items(first:100, after:$after) { pageInfo { hasNextPage endCursor }
    nodes { id
      content { ... on Issue { number repository { nameWithOwner } } }
      fieldValues(first:20) { nodes { ... on ProjectV2ItemFieldSingleSelectValue {
        name field { ... on ProjectV2SingleSelectField { name } } } } } } } } } }'

$rows = [System.Collections.Generic.List[object]]::new()
$after = $null
do {
  $call = @('api', 'graphql', '-f', "pid=$(Get-ProjectId)", '-f', "query=$q")
  if ($after) { $call += @('-f', "after=$after") }
  $page = ((Invoke-Gh @call) -join "`n" | ConvertFrom-Json).data.node.items
  foreach ($node in $page.nodes) {
    if ($null -eq $node.content.number) { continue }
    if ($node.content.repository.nameWithOwner -cne $Repo) { continue }
    $status = ''
    $priority = ''
    foreach ($v in $node.fieldValues.nodes) {
      if ($v.field.name -ceq 'Status')   { $status = $v.name }
      if ($v.field.name -ceq 'Priority') { $priority = $v.name }
    }
    $rows.Add([pscustomobject]@{ Number = $node.content.number; Status = $status; Priority = $priority })
  }
  $after = $page.pageInfo.endCursor
} while ($page.pageInfo.hasNextPage)

if ($rows.Count -eq 0) {
  "no cards from $Repo on project $From"
  return
}

"$($rows.Count) card(s) from $Repo on project $From"
foreach ($r in $rows) {
  '  #{0,-5} status={1,-14} priority={2}' -f $r.Number, ($(if ($r.Status) { $r.Status } else { '-' })), ($(if ($r.Priority) { $r.Priority } else { '-' }))
}

if ($DryRun) { 'dry run - nothing changed'; return }

$bin = $PSScriptRoot
foreach ($r in $rows) {
  # Add to the target first. A card that failed to land there must still be on the source board,
  # or the work would be on no board at all - the one outcome worse than being on the wrong one.
  Set-Project -Number $To -Repo $Repo | Out-Null
  Get-ItemId $Repo $r.Number | Out-Null
  if ($r.Status) {
    $canSetStatus = $true
    try { Get-OptionId 'Status' $r.Status | Out-Null }
    catch {
      if ($_.Exception.Message -cmatch "field 'Status' has no option") {
        "  #$($r.Number): Status '$($r.Status)' has no option on project $To; left unset"
        $canSetStatus = $false
      } else { throw }
    }
    if ($canSetStatus) { & (Join-Path $bin 'issue-status.ps1') -Project $To -Repo $Repo -Number $r.Number -Status $r.Status | Out-Null }
  }
  if ($r.Priority) {
    $canSetPriority = $true
    try { Get-OptionId 'Priority' $r.Priority | Out-Null }
    catch {
      if ($_.Exception.Message -cmatch "field 'Priority' has no option") {
        "  #$($r.Number): Priority '$($r.Priority)' has no option on project $To; left unset"
        $canSetPriority = $false
      } else { throw }
    }
    if ($canSetPriority) { & (Join-Path $bin 'issue-priority.ps1') -Project $To -Repo $Repo -Number $r.Number -Priority $r.Priority | Out-Null }
  }

  Set-Project -Number $From -Repo $Repo | Out-Null
  if (-not (Remove-BoardItem -Repo $Repo -Number $r.Number)) { "  #$($r.Number): was already off project $From" }
  '  #{0,-5} moved  status={1,-14} priority={2}' -f $r.Number, ($(if ($r.Status) { $r.Status } else { '-' })), ($(if ($r.Priority) { $r.Priority } else { '-' }))
}

'done - the issues themselves are untouched'
