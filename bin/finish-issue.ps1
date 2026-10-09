#!/usr/bin/env pwsh
<#
.SYNOPSIS
Close the worktree of one issue once its work has landed, move its card one column on, and say in
the issue what landed.
.EXAMPLE
./finish-issue.ps1 163
./finish-issue.ps1 163 -Repo other-org/tracker
./finish-issue.ps1 -Sweep -DryRun
.NOTES
The counterpart of start-issue. A worktree left behind after its work landed holds a copy of the
repository and its build output, gigabytes on a machine with several sessions, and a card left in
implementing tells everyone the work is still going on. Run it from the checkout or from any
worktree of the repository, after the push that lands the work. The issue, its card and its comment
are in -Repo where it is given, else in the repository start-issue recorded on the issue's branch,
else in the checkout's own.

NOTHING THAT HAS NOT LANDED IS REMOVED. A worktree with changes, or with a commit origin's default
branch does not have, stops the run and is named; the work in it is somebody's.

THE CARD MOVES TO THE COLUMN AFTER implementing, read from the board's own order: on a board with
a testing column the card goes there, and the owner closes the issue after review. Where the next
column is done, the card stays, because done is what closing the issue sets.

-Sweep removes every worktree of this repository whose work has landed and has rested for a day,
and names the others it leaves; start-issue and init -All run it, so a worktree nobody finished
does not stay for good. A worktree that was never committed in is left alone.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)][string] $Number = '',
  [string] $Repo = '',
  [switch] $Sweep,
  [switch] $DryRun,
  [switch] $Landed
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../lib/Board.psm1') -Force
$usage = 'usage: finish-issue.ps1 NUMBER [-Repo OWNER/REPO] [-Landed] | finish-issue.ps1 -Sweep [-DryRun]'
# A landed worktree younger than this is left to the session that may still be working in it
$restSeconds = 24 * 3600

function Invoke-Git {
  # Both streams are wanted, and a line on stderr is text to read, not an exception
  $kept = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & git @args 2>&1
    return [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Text = ((@($out) -join "`n").Trim()) }
  } finally { $ErrorActionPreference = $kept }
}

if ($Sweep) {
  if ($Number -or $Repo -or $Landed) { Stop-WithError $usage }
} else {
  if ($Number -notmatch '^[0-9]+\z') { Stop-WithError "the issue number must be numeric, not '$Number' - $usage" }
  if ($DryRun) { Stop-WithError "-DryRun goes with -Sweep - $usage" }
}

& git rev-parse --show-toplevel *>$null
if ($LASTEXITCODE -ne 0) { Stop-WithError 'not inside a git working copy - run this from the repository the work belongs to' }

$fetched = Invoke-Git fetch origin
if (-not $fetched.Ok) { Stop-WithError "could not reach origin: $($fetched.Text) - what has landed is measured against what origin has right now" }
$default = Get-OriginDefaultBranch

# The main checkout, as start-issue finds it: the worktrees are removed from there, so this answers
# the same from inside the worktree being removed.
$common = (Invoke-Git rev-parse --git-common-dir).Text
$main = (Invoke-Git -C (Join-Path $common '..') rev-parse --show-toplevel).Text
# The run goes on from the main checkout: started inside the worktree it removes, every step after
# the removal would run in a directory that is gone
Set-Location -LiteralPath $main

# Every worktree that carries an issue branch, as { Path; Branch }
function Get-IssueWorktrees {
  $path = $null
  foreach ($line in ((Invoke-Git -C $main worktree list --porcelain).Text -split "`n")) {
    if ($line.StartsWith('worktree ', [StringComparison]::Ordinal)) { $path = $line.Substring(9) }
    elseif ($line -cmatch '^branch refs/heads/(issue-[0-9]+(-.*)?)$') { [pscustomobject]@{ Path = $path; Branch = $Matches[1] } }
  }
}
# The worktree carries the name of the issue its branch belongs to, as start-issue names it. A
# package is worked in the worktree of its first issue with each issue's branch checked out in
# turn, and that worktree is not the later issues' to remove.
function Test-OwnWorktree([string]$path, [string]$branch) {
  $n = ($branch.Substring(6) -csplit '-', 2)[0]
  $leaf = Split-Path -Leaf $path
  return ($leaf -ceq "issue-$n" -or $leaf.StartsWith("issue-$n-", [StringComparison]::Ordinal))
}
# The commits of the branch whose change is not on origin's default branch, as "<sha> <subject>".
# A branch that landed by cherry-pick has new commits upstream, so ancestry alone would hold it
# back; git cherry compares the changes. A git cherry that fails answers a line of its own, so a
# branch it cannot read never counts as landed.
function Get-Unlanded([string]$branch) {
  $c = Invoke-Git -C $main cherry -v "origin/$default" "refs/heads/$branch"
  if (-not $c.Ok) { return @("? $($c.Text)") }
  return @($c.Text -split "`n" | Where-Object { $_.StartsWith('+ ', [StringComparison]::Ordinal) } | ForEach-Object { $_.Substring(2) })
}
function Test-Landed([string]$branch) { return (@(Get-Unlanded $branch).Count -eq 0) }
function Test-WorkedIn([string]$branch) {
  $log = Invoke-Git -C $main reflog show --format=%gs "refs/heads/$branch"
  return [bool](@($log.Text -split "`n" | Where-Object { $_ -and -not $_.StartsWith('branch: Created', [StringComparison]::Ordinal) }).Count)
}
function Test-Clean([string]$path) { return -not (Invoke-Git -C $path status --porcelain).Text }
function Remove-IssueWorktree([string]$path, [string]$branch) {
  $r = Invoke-Git -C $main worktree remove $path
  if (-not $r.Ok) { Stop-WithError "the worktree $path could not be removed: $($r.Text)" }
  $b = Invoke-Git -C $main branch -D $branch
  if (-not $b.Ok) { Stop-WithError "the branch $branch could not be deleted: $($b.Text)" }
}

if ($Sweep) {
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  foreach ($w in @(Get-IssueWorktrees)) {
    if (-not (Test-OwnWorktree $w.Path $w.Branch)) { "worktree $($w.Path): named for another issue, holds $($w.Branch), stays" }
    elseif (-not (Test-Clean $w.Path)) { "worktree $($w.Path): has changes, stays" }
    elseif (-not (Test-Landed $w.Branch)) { "worktree $($w.Path): has work origin/$default does not have yet, stays" }
    elseif (-not (Test-WorkedIn $w.Branch)) { "worktree $($w.Path): never committed in, stays" }
    elseif (($now - [long](Invoke-Git -C $main log -1 --format=%ct "refs/heads/$($w.Branch)").Text) -lt $restSeconds) {
      "worktree $($w.Path): landed less than a day ago, stays; finish-issue removes it at once"
    }
    elseif ($DryRun) { "worktree $($w.Path): landed, would be removed" }
    else { Remove-IssueWorktree $w.Path $w.Branch; "worktree $($w.Path): landed, removed" }
  }
  exit 0
}

# --- one issue ---------------------------------------------------------------------------------
# The record is read from the issue's branch, which can outlive its worktree
if (-not $Repo) {
  foreach ($b in @(& git for-each-ref '--format=%(refname:short)' "refs/heads/issue-$Number" "refs/heads/issue-$Number-*")) {
    $Repo = Get-BranchIssueRepo -Branch $b
    if ($Repo) { break }
  }
}
$ref = Get-IssueRef -Repo $Repo -Number $Number
$where = if ($Repo) { @{ Repo = $Repo } } else { @{} }
try { $raw = (@(& (Join-Path $PSScriptRoot 'issue-thread.ps1') -Number $Number @where -Json) -join "`n").Trim() }
catch { Stop-WithError "the issue could not be read: $($_.Exception.Message)" }
$thread = $raw | ConvertFrom-Json -DateKind String
$state = "$($thread.state)".ToLowerInvariant()
$found = $false
foreach ($w in @(Get-IssueWorktrees | Where-Object { $_.Branch -ceq "issue-$Number" -or $_.Branch.StartsWith("issue-$Number-", [StringComparison]::Ordinal) })) {
  if (-not (Test-OwnWorktree $w.Path $w.Branch)) {
    "the worktree $($w.Path) is named for another issue and has $($w.Branch) checked out: it stays, and the branch with it"
    continue
  }
  $found = $true
  if (-not (Test-Clean $w.Path)) {
    Stop-WithError "the worktree $($w.Path) has changes - commit and push them, or put them aside, then run this again"
  }
  $missing = @(Get-Unlanded $w.Branch)
  if ($missing.Count -gt 0) {
    # Work that landed in another shape, a resolved conflict or a changed context, is the owner's
    # word against git's: -Landed takes it, and only for an issue somebody closed.
    if (-not $Landed) {
      Stop-WithError "the worktree $($w.Path) has $($missing.Count) commit(s) whose change is not on origin/$default - push them, then run this again; where they landed in another shape, run finish-issue $Number --landed once the issue is closed"
    }
    if ($state -cne 'closed') {
      Stop-WithError "--landed removes the work of a closed issue only, and $ref is open - close it once its work is on origin/$default"
    }
    "removed with --landed, these commits not found on origin/${default} by their change:"
    $missing | ForEach-Object { "  $_" }
  }
  Remove-IssueWorktree $w.Path $w.Branch
  "Worktree $($w.Path) and its branch $($w.Branch) removed: its work is on origin/$default. Open $main to go on."
}
if (-not $found) { "no worktree of issue $Number stands here - only the card and the issue are brought up to date" }

# The card: one column past implementing, as the board orders them, unless that column is done
if ($state -ceq 'closed') {
  'the issue is closed already - its card stays where closing put it'
} elseif (Test-OnNoBoard -Repo ($repo = if ($Repo) { $Repo } else { Get-DefaultRepo })) {
  "$repo is on no board - there is no card to move"
} else {
  Set-Project -Number '' -Repo $repo | Out-Null
  $options = @(Get-Fields | Where-Object { $_.Field -ieq 'Status' } | ForEach-Object { $_.Option })
  $at = [Array]::FindIndex([string[]]$options, [Predicate[string]] { param($o) $o.ToLowerInvariant() -ceq 'implementing' })
  $next = if ($at -ge 0 -and $at + 1 -lt $options.Count) { $options[$at + 1] } else { '' }
  if (-not $next) { 'the board has no column after implementing - the card stays; move it by hand' }
  elseif ($next.ToLowerInvariant() -ceq 'done') { 'the column after implementing is done, which closing the issue sets - the card stays for the owner' }
  else {
    try { & (Join-Path $PSScriptRoot 'issue-status.ps1') -Number $Number -Status $next -Repo $repo }
    catch { Write-Error "the card did NOT move: $($_.Exception.Message) - move it to $next by hand" -ErrorAction Continue }
  }
}

# What landed, in the issue, for whoever reads it next
# The reference stands alone: '#<N>' must not match '<OWNER/REPO>#<N>', an issue of another repository
$commits = (Invoke-Git -C $main log "origin/$default" -E "--grep=(^|[^A-Za-z0-9._/-])$($ref.Replace('.', '\.'))([^0-9]|$)" '--format=- %h %s' -n 20).Text
if (-not $commits) { $commits = "- (no commit on origin/$default names $ref)" }
# An issue of another repository is told which repository the commits are in
$landedOn = if ($ref -ceq "#$Number") { $default } else { "$default of $(Get-DefaultRepo)" }
$body = "Landed on ${landedOn}:`n`n$commits`n"
try { & (Join-Path $PSScriptRoot 'issue-comment.ps1') -Number $Number -Body $body @where | Out-Null; 'the issue says what landed' }
catch { Write-Error 'the issue was NOT told what landed - add the commits by hand' -ErrorAction Continue }
