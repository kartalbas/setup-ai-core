#!/usr/bin/env pwsh
<#
.SYNOPSIS
Integrate the reviewed branch of one issue into the default branch: a merge commit that names the
issue and its reviewer, pushed through the gate.
.EXAMPLE
./integrate-issue.ps1 163 -ReviewedBy l4
.EXAMPLE
./integrate-issue.ps1 163 -Repo other-org/tracker -ReviewedBy l4
.NOTES
Between start-issue and finish-issue. Run it in the worktree of the issue, on its branch, once the
reviewer gave the GO. It fetches origin, puts the worktree on the newest origin/<default>, merges
the branch with --no-ff under the issue's title and a 'Reviewed-by: REVIEWER' trailer, pushes
HEAD:<default> through the gate, and checks the branch out again for finish-issue. The issue is read
in -Repo where it is given, else in the repository start-issue recorded on the branch, else in the
checkout's own.

A MERGE COMMIT, NOT A REBASE: the reviewed commits land as they were read, with the shas the
reviewer saw, and the one new commit carries the issue and the reviewer.

THE REVIEWER IS A NAME GIVEN, NOT A REVIEW PROVEN. Without -ReviewedBy this refuses; with it, the
name goes into the history, where it can be traced, and nothing here can tell whether the review
took place.

NOTHING IS LEFT HALF DONE. A conflict aborts the merge, a branch already in the default branch has
nothing to integrate, and a push the gate refuses reaches nothing; each time the branch is checked
out again and the cause is named.

THE LANDINGS OF ONE CLONE TAKE TURNS. Git fixes the old value of the remote branch when the push
starts, before the gate runs, so a landing that moves the default branch while another one's gate
runs refuses the other's push. From the fetch to the end of the push this holds the file
ai-core-landing in the clone's git directory, which every worktree of the clone shares and the twin
reads too: its process id and its issue. A landing that finds it held waits; one whose holder no
longer runs takes it over.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)][string] $Number = '',
  [string] $Repo = '',
  [string] $ReviewedBy = ''
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../lib/Board.psm1') -Force
$usage = 'usage: integrate-issue.ps1 NUMBER [-Repo OWNER/REPO] -ReviewedBy REVIEWER'

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

if (-not $Repo) { $Repo = Get-BranchIssueRepo -Branch $branch }
$where = if ($Repo) { @{ Repo = $Repo } } else { @{} }
try { $raw = (@(& (Join-Path $PSScriptRoot 'issue-thread.ps1') -Number $Number @where -Json) -join "`n").Trim() }
catch { Stop-WithError "the issue could not be read: $($_.Exception.Message)" }
$title = "$(($raw | ConvertFrom-Json -DateKind String).title)"
$ref = Get-IssueRef -Repo $Repo -Number $Number
# The subject the gate takes is 72 characters at most, so a longer one falls back, shortest last
$subject = "$title ($ref)"
if (-not $title -or $subject.Length -gt 72) { $subject = "Merge $branch ($ref)" }
if ($subject.Length -gt 72) { $subject = "Merge issue-$Number ($ref)" }

$landing = Join-Path (Invoke-Git rev-parse --path-format=absolute --git-common-dir).Text 'ai-core-landing'
# ponytail: two waiters that find the same dead holder can both take over, and the push then still
# refuses the second, as it does without the lock; a holder's process id that an unrelated process
# took over keeps the lock held, and the waiting line names that process
$waited = $false; $missing = 0; $nameless = 0
while ($true) {
  try {
    $held = [System.IO.File]::Open($landing, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes("$PID`t$ref`n"); $held.Write($bytes, 0, $bytes.Length); $held.Dispose()
    break
  } catch [System.IO.IOException] { $said = $_.Exception.Message }
  # Gone between the two steps is a lock just released; gone twice in a row, one never written
  try { $holder = [System.IO.File]::ReadAllText($landing).TrimEnd("`n") }
  catch [System.IO.FileNotFoundException] {
    $missing++; if ($missing -ge 2) { Stop-WithError "the landing lock $landing could not be written: $said" }; continue
  }
  catch [System.IO.IOException] { $holder = '' }
  $missing = 0; $holderPid, $holderIssue = $holder -split "`t", 2
  # A lock still without its process id after the poll was never finished: nobody holds it
  $dead = ''
  if ($holderPid -cmatch '^\d{1,9}$') {
    $nameless = 0
    if (-not (Get-Process -Id ([int]$holderPid) -ErrorAction SilentlyContinue)) { $dead = "the landing lock of $holderIssue, whose process $holderPid no longer runs" }
  } else { $nameless++; if ($nameless -ge 2) { $dead = "a landing lock that names no process: '$holder'" } }
  if ($dead) {
    try { Remove-Item -LiteralPath $landing -Force } catch [System.Management.Automation.ItemNotFoundException] { }
    [Console]::Error.WriteLine("taken over: $dead"); $nameless = 0; continue
  }
  if (-not $waited -and $nameless -eq 0) { $waited = $true; [Console]::Error.WriteLine("waiting: $holderIssue is landing from this clone (process $holderPid); this one lands after it") }
  Start-Sleep -Seconds 2
}
try {
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
  Write-Host "next: ai-core finish-issue $(if ($Repo) { "$Number -Repo $Repo" } else { $Number })"
} finally {
  if ((Test-Path -LiteralPath $landing) -and ([System.IO.File]::ReadAllText($landing) -split "`t")[0] -ceq "$PID") { Remove-Item -LiteralPath $landing -Force }
}
