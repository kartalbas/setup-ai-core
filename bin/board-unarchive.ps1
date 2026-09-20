<#
.SYNOPSIS
Bring archived cards back into view.

.DESCRIPTION
Nothing on this board is ever archived — closed items stay in view, because a board is
read to see what was done as much as what is left. GitHub ships a built-in workflow that
archives an item the moment its issue closes, and where that workflow is on, every card
this tooling moves to Done disappears from the column it was just put in.

The workflow itself is not scriptable: Projects' built-in workflows have no API, so
turning "auto-archive items" off is a thing a person does once in the board's settings.
Until then this is a broom, and a broom is not a fix — it reports how many it swept, so
the number itself says whether the workflow is still on.

.EXAMPLE
./board-unarchive.ps1
./board-unarchive.ps1 -Repo example-org/alpha-cloud -Number 97,100
#>
[CmdletBinding()]
param(
  [ValidatePattern('^[0-9]+\z', ErrorMessage = "the issue number must be numeric, not '{0}'")][string[]] $Number,
  [string] $Repo,
  [string] $Project = ''
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../lib/Board.psm1') -Force

function Restore-Item {
  [CmdletBinding()]
  param([string] $ItemId)
  $q = 'mutation($pid:ID!, $iid:ID!) { unarchiveProjectV2Item(input:{projectId:$pid, itemId:$iid}) { item { id } } }'
  Invoke-Gh api graphql -f "pid=$(Get-ProjectId)" -f "iid=$ItemId" -f "query=$q" `
    --jq '.data.unarchiveProjectV2Item.item.id' | Out-Null
}

if ($Number) {
  if (-not $Repo) { $Repo = Get-DefaultRepo }
  Set-Project -Number $Project -Repo $Repo | Out-Null
  foreach ($n in $Number) {
    $id = Get-ArchivedItemId $Repo $n
    if (-not $id) { "#$n is not archived"; continue }
    Restore-Item $id
    "#$n -> back on the board"
  }
  return
}

Set-Project -Number $Project -Repo (Get-DefaultRepo) | Out-Null
$swept = 0
foreach ($r in Get-ProjectRepos) {
  foreach ($n in (Invoke-Gh issue list --repo $r --state closed --limit 200 --json number --jq '.[].number')) {
    $id = Get-ArchivedItemId $r $n
    if (-not $id) { continue }
    Restore-Item $id
    "  $r#$n -> back on the board"
    $swept++
  }
}
"$swept card(s) brought back. A number above zero means the board's auto-archive workflow is still on — turn it off in the board's settings, or they go again on the next close."
