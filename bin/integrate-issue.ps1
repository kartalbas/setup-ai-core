#!/usr/bin/env pwsh
<#
.SYNOPSIS
Integrate the reviewed branch of one issue into the default branch: a merge commit that names the
issue and its reviewer, pushed through the gate.
.EXAMPLE
./integrate-issue.ps1 163 -ReviewedBy l4
.NOTES
Between start-issue and finish-issue. Run it in the worktree of the issue, on its branch, once the
reviewer gave the GO. It fetches origin, puts the worktree on the newest origin/<default>, merges
the branch with --no-ff under the issue's title and a 'Reviewed-by: REVIEWER' trailer, pushes
HEAD:<default> through the gate, and checks the branch out again for finish-issue.

A MERGE COMMIT, NOT A REBASE: the reviewed commits land as they were read, with the shas the
reviewer saw, and the one new commit carries the issue and the reviewer.

THE REVIEWER IS A NAME GIVEN, NOT A REVIEW PROVEN. Without -ReviewedBy this refuses; with it, the
name goes into the history, where it can be traced, and nothing here can tell whether the review
took place.

NOTHING IS LEFT HALF DONE. A conflict aborts the merge, a branch already in the default branch has
nothing to integrate, and a push the gate refuses reaches nothing; each time the branch is checked
out again and the cause is named.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)][string] $Number = '',
  [string] $ReviewedBy = ''
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../lib/Board.psm1') -Force
$usage = 'usage: integrate-issue.ps1 NUMBER -ReviewedBy REVIEWER'

function Invoke-Git {
  # Both streams are wanted, and a line on stderr is text to read, not an exception
  $kept = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & git @args 2>&1
    return [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Text = ((@($out) -join "`n").Trim()) }
  } finally { $ErrorActionPreference = $kept }
}

if ($Number -notmatch '^[0-9]+\z') { Stop-WithError "the issue number must be numeric, not '$Number' - $usage" }
if (-not $ReviewedBy.Trim()) { Stop-WithError "who reviewed the work? -ReviewedBy names the reviewer whose GO this integrates - $usage" }
if ($ReviewedBy.Contains("`n")) { Stop-WithError '-ReviewedBy takes one line' }

if (-not (Invoke-Git rev-parse --show-toplevel).Ok) { Stop-WithError "not inside a git working copy - run this in the worktree of issue $Number" }
$head = Invoke-Git symbolic-ref --short -q HEAD
$branch = if ($head.Ok) { $head.Text } else { '' }
if (-not ($branch -ceq "issue-$Number" -or $branch.StartsWith("issue-$Number-", [StringComparison]::Ordinal))) {
  Stop-WithError "this runs in the worktree of issue $Number, on its branch issue-$Number-*; here $(if ($branch) { $branch } else { 'no branch' }) is checked out"
}
if ((Invoke-Git status --porcelain).Text) { Stop-WithError 'the worktree has changes - commit them for the review, or put them aside, then run this again' }

try { $raw = (@(& (Join-Path $PSScriptRoot 'issue-thread.ps1') -Number $Number -Json) -join "`n").Trim() }
catch { Stop-WithError "the issue could not be read: $($_.Exception.Message)" }
$title = "$(($raw | ConvertFrom-Json -DateKind String).title)"
$subject = "$title (#$Number)"
if (-not $title -or $subject.Length -gt 72) { $subject = "Merge $branch (#$Number)" }

$fetched = Invoke-Git fetch origin
if (-not $fetched.Ok) { Stop-WithError "could not reach origin: $($fetched.Text)" }
$default = Get-OriginDefaultBranch

# The worktree goes back to the branch it was on, and the run stops
function Stop-OnBranch([string] $Reason) {
  if (-not (Invoke-Git switch -q $branch).Ok) { Write-Host "error: the branch $branch could not be checked out again - run git switch $branch" -ForegroundColor Red }
  Stop-WithError $Reason
}

if (-not (Invoke-Git rev-list -n1 $branch --not "origin/$default").Text) { Stop-WithError "nothing to integrate: $branch is in origin/$default already" }
$switched = Invoke-Git switch -q --detach "origin/$default"
if (-not $switched.Ok) { Stop-WithError "the worktree could not be put on origin/${default}: $($switched.Text)" }
$merge = Invoke-Git merge -q --no-ff --no-edit $branch -m $subject -m "Reviewed-by: $ReviewedBy"
if (-not $merge.Ok) {
  Write-Host $merge.Text
  $null = Invoke-Git merge --abort
  Stop-OnBranch "$branch does not merge cleanly into origin/$default - bring origin/$default into the branch, get the review of the result, then run this again"
}
$merged = (Invoke-Git rev-parse --short HEAD).Text
& git push origin "HEAD:$default"
if ($LASTEXITCODE -ne 0) { Stop-OnBranch "the push was refused (see above) - nothing reached origin, and $branch is checked out again" }
if (-not (Invoke-Git switch -q $branch).Ok) { Stop-WithError "$merged is on origin/$default, but $branch could not be checked out again - run git switch $branch before finish-issue" }
Write-Host "integrated: $merged on origin/$default, $subject, Reviewed-by: $ReviewedBy"
Write-Host "next: ai-core finish-issue $Number"
