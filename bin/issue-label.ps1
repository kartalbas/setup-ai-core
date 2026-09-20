<#
.SYNOPSIS
Set which labels an issue carries - put labels on, take labels off, or both at once.

.DESCRIPTION
Every ticket carries at least one TYPE label and one AREA label. issue-new sets them
when a ticket is created; nothing sets them on a ticket that already stands, so without
this they are added by hand in one repository at a time — which is exactly what makes a
board-wide filter lie.

BOTH DIRECTIONS ARE NAMED, and neither of them is what a bare word means. Retiring a
label is one act with two halves, so the two halves are spelled the same way; a set
where one side carries the word and the other is silent cannot be searched for, and a
reader who finds -Remove and no -Add concludes that adding is somebody else's job.

A label outside the taxonomy is REFUSED on -Add and ACCEPTED on -Remove. Creating one
here would put it in one repository and not the others, and a filter across the board
would then quietly miss every ticket in the repositories that never got it. Adding a
label means adding a line to labels.tsv and running labels-sync. A name being retired
is out of labels.tsv by the time it comes off a ticket, so holding -Remove to the
taxonomy would refuse exactly the call it exists for.

WHAT IS SENT IS WHAT THE ISSUE ACTUALLY CARRIES. The labels are read before the edit, a
label already on the issue is not added again, and one that is not on it is not
removed. Measured on 2026-08-26: `gh issue edit --remove-label x` exits 1 with
"'x' not found" when the REPOSITORY has no label of that name, and exits 0 changing
nothing when the repository has it but the issue does not. Reading first turns the
first case - a misspelt name, or a second run after the label itself was deleted -
into a reported line instead of a dead run.

What is missing is REPORTED, never filled in. A type or an area guessed here is a lie
the board then tells everyone.

NO LABEL IS DELETED FROM A REPOSITORY HERE. Taking a label off one issue is undone by
naming that issue again. Deleting the label takes it off every issue that carries it in
one act, and the list of which issues those were goes with it, so nothing can say what
to put back. labels-sync leaves an undeclared label alone for the same reason.

.EXAMPLE
./issue-label.ps1 -Number 111,112 -Add type:bug,area:gate
./issue-label.ps1 -Number 72 -Add area:installation -Remove area:install
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidatePattern('^[0-9]+\z', ErrorMessage = "the issue number must be numeric, not '{0}'")][string[]] $Number,
  [string[]] $Add,
  [string[]] $Remove,
  [string]   $Repo
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../lib/Board.psm1') -Force

if (-not $Repo) { $Repo = Get-DefaultRepo }

$adds    = @(); if ($Add)    { $adds    = @($Add) }
$removes = @(); if ($Remove) { $removes = @($Remove) }

if ($adds.Count + $removes.Count -eq 0) {
  Stop-WithError 'nothing to do - name a label to add or to remove'
}

# THE SAME NAME ON BOTH SIDES IS REFUSED RATHER THAN ORDERED. gh takes --add-label and
# --remove-label in one call and nothing here says which of the two wins, so the result
# is whatever the server does with it - and the board would then carry a label nobody
# can predict from the command that set it.
foreach ($a in $adds) {
  if ($removes -ccontains $a) {
    Stop-WithError "'$a' is named to add and to remove - it can only be one of the two"
  }
}

$taxonomy = @(Get-LabelTaxonomy)
$known = @($taxonomy.Name)
$types = @(($taxonomy | Where-Object Group -ceq 'type').Name)
$areas = @(($taxonomy | Where-Object Group -ceq 'area').Name)

foreach ($l in $adds) {
  if ($known -cnotcontains $l) {
    Stop-WithError "`"$l`" is not in the taxonomy. Add it to labels.tsv and run labels-sync, so every repository has it."
  }
}

function Get-IssueLabels {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$n)
  @(Invoke-Gh issue view $n --repo $Repo --json labels -q '.labels[].name')
}

foreach ($n in $Number) {
  $before = Get-IssueLabels $n

  $willAdd    = @($adds    | Where-Object { $before -cnotcontains $_ })
  $already    = @($adds    | Where-Object { $before -ccontains   $_ })
  $willRemove = @($removes | Where-Object { $before -ccontains   $_ })
  $absent     = @($removes | Where-Object { $before -cnotcontains $_ })

  # A label name may hold a space - GitHub's own defaults include "help wanted" - so the
  # gh call is built as an argument array and splatted, never glued into one string.
  $edit = @()
  foreach ($l in $willAdd)    { $edit += '--add-label';    $edit += $l }
  foreach ($l in $willRemove) { $edit += '--remove-label'; $edit += $l }
  if ($edit.Count -gt 0) { Invoke-Gh issue edit $n --repo $Repo @edit | Out-Null }

  # The report is read from the labels the issue carries AFTER the edit and not from the
  # arguments this run was given. Removal is what makes a ticket without a type or
  # without an area common, so that verdict has to come from the ticket.
  $on = Get-IssueLabels $n

  $changes = ''
  foreach ($l in $willAdd)    { $changes += " +$l" }
  foreach ($l in $willRemove) { $changes += " -$l" }
  if (-not $changes) { $changes = ' unchanged' }

  $note = ''
  if ($already.Count) { $note += "  already on it: $($already -join ' ')" }
  if ($absent.Count)  { $note += "  not on it: $($absent -join ' ')" }
  if (-not ($on | Where-Object { $types -ccontains $_ })) { $note += '  MISSING a type label' }
  if (-not ($on | Where-Object { $areas -ccontains $_ })) { $note += '  MISSING an area label' }
  "#$n ->$changes$note"
}
