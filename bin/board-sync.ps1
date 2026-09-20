<#
.SYNOPSIS
Put every issue of every linked repo on the one board, and report what that changed.

.EXAMPLE
./board-sync.ps1
./board-sync.ps1 -Repo example-org/example-repo

.NOTES
Adding an item twice is harmless, so this can be run as often as you like - it is the
sweep that catches an issue somebody created straight on github.com, which otherwise
exists but is invisible on the board.

It never sets a value itself. What is missing is reported, because a status or a priority
guessed by a script is a lie the board then tells everyone.

GitHub does set one, though: the project's built-in workflow stamps a Status on every item
AS IT IS ADDED - typically Todo for an open issue and Done for a closed one. That is why
the newly added items are listed separately below. They have a status nobody chose, and a
sweep that did not say so would quietly fill the Todo column with old work the next
morning.

An OPEN ticket missing a label and a CLOSED one are not the same report, and one number
over both hides the first. Measured over all eleven repositories on 2026-08-26: 20 issues are
open and 5 of them are missing a type or an area; 430 are closed and 104 of them are. Read as one
figure of 109 that is a backlog nobody will ever work off, and the five that can be fixed
this afternoon disappear into it. So the open ones are listed one by one, because somebody
is going to pick each of them up and label it as they do, and the closed ones are counted,
because a label put on a finished ticket by somebody who did not write it is a guess - and
this tool reports rather than guesses.

The priority report splits the same way, and the split has to be made here rather than left
to the reader. Measured with board-list across both boards on 2026-08-26: five cards carry no
priority and every one of them is CLOSED. Printed as the single figure "5" that reads as five
tickets waiting to be prioritised; split, it is five finished tickets nobody should guess a
value for and not one open ticket anybody can act on.

Every count here stands beside what it was counted out of. "5 missing" cannot be told apart
from a board of six cards or a board of six hundred, and it cannot be told apart from a run
that read nothing - which is what a refused query looks like from outside.
#>
[CmdletBinding()]
param([string[]] $Repo, [string] $Project = '')

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../lib/Board.psm1') -Force

$resolved = Set-Project -Number $Project
if (-not $Repo) { $Repo = @(Get-ProjectRepos) }

$types = Get-LabelNamesInGroup -Group 'type'
$areas = Get-LabelNamesInGroup -Group 'area'

# board-list.ps1 runs as its own script call and re-imports Board.psm1, which resets
# the module's project selection - pass the number down explicitly rather than letting
# it re-resolve and risk landing on a different project than the one being synced.
$list   = Join-Path $PSScriptRoot 'board-list.ps1'
$key    = { param($l) ($l -split '\s+')[2..3] -join ' ' }
$before = @(& $list -Project $resolved)

$openIssues = 0
$closedIssues = 0
$openGaps = 0
$closedGaps = 0
foreach ($r in $Repo) {
  $r
  $issues = Invoke-Gh issue list --repo $r --state all --limit 500 --json number,state,title,labels | ConvertFrom-Json
  foreach ($i in $issues) {
    Get-ItemId $r $i.number | Out-Null

    if ($i.state -ceq 'OPEN') { $openIssues++ } else { $closedIssues++ }

    $has = @($i.labels.name)
    $missing = @()
    if (-not ($has | Where-Object { $_ -cin $types })) { $missing += 'type' }
    if (-not ($has | Where-Object { $_ -cin $areas })) { $missing += 'area' }
    if (-not $missing) { continue }
    if ($i.state -ceq 'OPEN') {
      '  #{0,-4} missing label: {1,-12} {2}' -f $i.number, ($missing -join ' '), $i.title
      $openGaps++
    }
    else { $closedGaps++ }
  }
}

# READ ONCE, AND EVERY FIGURE BELOW COMES OUT OF THESE LINES. A colleague can move a card while
# the sweep runs, so a second read for the priority report would answer about a board the added
# items above were never counted against, with nothing on the screen saying so.
$after = @(& $list -Project $resolved)

# board-list renders one card per line as "<status> <priority> <repo> #<number> <title>", and a
# closed one ends in "[closed]". That is the whole shape the counts below read.
$openCards     = @($after       | Where-Object { $_ -cnotmatch '\[closed\]\z' })
$closedCards   = @($after       | Where-Object { $_ -cmatch   '\[closed\]\z' })
$openNoPrio    = @($openCards   | Where-Object { ($_ -split '\s+')[1] -eq '-' })
$closedNoPrioN = @($closedCards | Where-Object { ($_ -split '\s+')[1] -eq '-' }).Count

''
"$openGaps of $openIssues OPEN issues are missing a type or an area label, listed above"
"$closedGaps of $closedIssues closed issues are missing one too, and are not listed -"
"  labelling somebody else's finished ticket is a guess, and nothing on the board filters on it"

# A card is matched on its repo and its number, never on its whole line. The status and the
# priority columns can differ between the two reads - GitHub stamps a status onto an item as it
# is added, and a colleague can move a card while the sweep runs - so a whole-line comparison
# would report a card that was on the board all along as one that had just arrived.
$beforeKeys = @($before | ForEach-Object { & $key $_ })
$added      = @($after  | Where-Object { (& $key $_) -cnotin $beforeKeys })
if ($added) {
  ''
  "$($added.Count) of the $($after.Count) cards on the board were NOT on it before this run."
  'GitHub stamped each one with a status as it was added - it is the first word of every'
  'line below. Move whatever does not belong there:'
  $added | ForEach-Object { "  $_" }
}

''
if ($openNoPrio.Count -gt 0) {
  'OPEN cards on the board that carry no priority:'
  $openNoPrio | ForEach-Object { "  $_" }
  "$($openNoPrio.Count) of $($openCards.Count) OPEN cards carry no priority, listed above"
}
else {
  "$($openNoPrio.Count) of $($openCards.Count) OPEN cards carry no priority"
}
"$closedNoPrioN of $($closedCards.Count) closed cards carry none either, and are not listed -"
'  a priority put on a finished ticket by somebody who did not work it is a guess'
