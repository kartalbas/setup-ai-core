# Lift every epic to the top of the board, above every ordinary ticket.
#
#   epics-top.ps1                  the board the current directory's repo is linked to
#   epics-top.ps1 -Project N       a named board
#   epics-top.ps1 -DryRun          print what would move, change nothing
#
# A board column has more rows than fit on a screen, and it is read from the top. An epic
# scrolled below the fold is an epic nobody sees, and with it goes the only thing that says
# which of the tickets underneath belong together. Priority orders the WORK; an epic is not
# work, it is the heading the work stands under, so it is not sorted in among it.
#
# An epic is recognised by its title, which is how a reader recognises one too: the
# convention is `EPIC - <what it covers>`. Nothing else on the board carries that prefix.
#
# The board keeps ONE order for all its items and every view honours it within whatever it
# groups by, so lifting an item to the top of that order puts it at the top of its column
# whichever column it currently stands in. `updateProjectV2ItemPosition` with no `afterId`
# means the top; the epics are therefore moved in reverse, so the first one listed ends up
# first on the board.

[CmdletBinding()]
param([string]$Project = '', [switch]$DryRun)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\lib\Board.psm1') -Force

Set-Project -Number $Project | Out-Null

# Title comes from the issue, not from the board: the board carries no title field, and an
# epic is an epic because of what its issue says.
$epics = @()
foreach ($item in Get-BoardItems) {
    if (-not $item.content.number) { continue }
    $repo = $item.content.repository.nameWithOwner
    $number = $item.content.number
    # A title that cannot be read STOPS the run. Hiding the error leaves an empty title, which
    # matches no epic prefix and leaves the epic where it was - so a refused query would end
    # with "epics: none on this board".
    $title = Invoke-Gh issue view $number --repo $repo --json title --jq '.title'
    if ($title -cmatch '^EPIC(\s|:)') {
        $epics += [pscustomobject]@{ Id = $item.id; Repo = $repo; Number = $number; Title = $title }
    }
}

if ($epics.Count -eq 0) { Write-Host 'epics: none on this board'; exit 0 }

# Reversed, because each move goes to the very top and the last one moved wins the top slot.
[array]::Reverse($epics)

$query = 'mutation($pid:ID!, $iid:ID!) {
  updateProjectV2ItemPosition(input:{projectId:$pid, itemId:$iid}) { items { totalCount } } }'

foreach ($e in $epics) {
    if ($DryRun) { Write-Host "would lift  $($e.Repo)#$($e.Number)  $($e.Title)"; continue }
    Invoke-Gh api graphql -f "pid=$(Get-ProjectId)" -f "iid=$($e.Id)" -f "query=$query" | Out-Null
    Write-Host "lifted      $($e.Repo)#$($e.Number)  $($e.Title)"
}

if (-not $DryRun) { Write-Host "epics: $($epics.Count) at the top of board $(Get-ProjectNumber)" }
