<#
.SYNOPSIS
Add or remove an issue's assignees, without disturbing the ones already there.

.DESCRIPTION
Assignment is ADDITIVE by default, because the common case is a second name rather
than a replacement: the rules ask for the repository's responsible developer to be
added alongside whoever is doing the work, so they are informed. Replacing on every
call would quietly drop that person the next time somebody assigned a ticket.

-Replace sets the assignees to exactly the names given, and is the only way to
remove somebody by assignment; -Remove takes a name off and leaves the rest.

.EXAMPLE
./issue-assign.ps1 -Repo example-org/example-repo -Number 575 -Add kartalbas

.EXAMPLE
./issue-assign.ps1 -Number 575,569 -Add kartalbas

.EXAMPLE
./issue-assign.ps1 -Number 412 -Replace kartalbas

.NOTES
Prints the assignees the issue carries AFTER the change, per issue, so a call is
proven rather than assumed. The board is not touched: who owns a ticket is not a
column.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidatePattern('^[0-9]+\z', ErrorMessage = "the issue number must be numeric, not '{0}'")][string[]] $Number,
  [string[]] $Add,
  [string[]] $Remove,
  [string[]] $Replace,
  [string]   $Repo
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../lib/Board.psm1') -Force

# Refuse a call that changes nothing BEFORE the repository is resolved or GitHub is
# reached, so bad input costs nothing and cannot half-apply across several issues.
if (-not $Add -and -not $Remove -and -not $Replace) {
  Stop-WithError 'name -Add, -Remove or -Replace - an assignment that changes nothing is a mistake'
}
if ($Replace -and ($Add -or $Remove)) {
  Stop-WithError '-Replace states the whole set, so it cannot be combined with -Add or -Remove'
}

if (-not $Repo) { $Repo = Get-DefaultRepo }

foreach ($n in $Number) {
  $issue = ((Invoke-Gh api "repos/$Repo/issues/$n") -join "`n") | ConvertFrom-Json
  $current = @($issue.assignees | ForEach-Object { "$($_.login)" } | Where-Object { $_ })

  if ($Replace) {
    $wanted = @($Replace)
  } else {
    $wanted = @($current)
    foreach ($a in $Add) { if ($wanted -cnotcontains $a) { $wanted += $a } }
    foreach ($r in $Remove) { $wanted = @($wanted | Where-Object { $_ -cne $r }) }
  }

  # Say so and move on rather than sending a write that changes nothing: a no-op PATCH
  # still writes an event onto the issue's timeline, which reads later as a decision
  # somebody took.
  if (-not (Compare-Object -ReferenceObject @($current) -DifferenceObject @($wanted) -ErrorAction SilentlyContinue)) {
    "#$n -> unchanged ($(if ($current) { $current -join ', ' } else { 'nobody' }))"
    continue
  }

  $body = @{ assignees = @($wanted) } | ConvertTo-Json -Compress
  $body | gh api --method PATCH "repos/$Repo/issues/$n" --input - | Out-Null
  if ($LASTEXITCODE -ne 0) { Stop-WithError "could not set the assignees of $Repo#$n" }

  $after = ((Invoke-Gh api "repos/$Repo/issues/$n") -join "`n") | ConvertFrom-Json
  $now = @($after.assignees | ForEach-Object { "$($_.login)" } | Where-Object { $_ })
  "#$n -> $(if ($now) { $now -join ', ' } else { 'nobody' })"
}
