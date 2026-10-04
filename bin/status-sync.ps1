<#
.SYNOPSIS
Move each card to the state its git signals PROVE it has reached, so the board stops trailing
reality because a person forgot to move a card.

It reads only facts and moves FORWARD only. The signal:
  - a card in testing whose commit is carried by the newest tag  -> closed + done
A card reaches testing through finish-issue, which runs after the push that lands the issue. A
commit that names an issue says that it touches the issue, not that the issue is done: an issue
whose work lands in several steps carries such commits long before it is.

WHY THERE IS NO PULL-REQUEST SIGNAL. Work stays on master here: an issue is worked in a worktree
on a temporary branch, and that branch is a place to commit, not a statement that anything is
finished. An open worktree therefore proves nothing and is not read. What proves the work exists
is the commit landing on master, which is what the push hook lets through, and what proves it
shipped is a tag carrying that commit. A release here is a tag, because these repositories tag
rather than cut a GitHub release; whether that tag actually deployed is the pipeline's to alarm
on, not the board's.

The card is put in `implementing` by start-issue, at the moment the worktree is opened, and in
`testing` by finish-issue; both are a session's statement and this sweep writes neither. It never moves a card BACKWARD,
so a state a person set by hand stands. An EPIC carries no work and has no signals of its own: it
follows its sub-issues (Get-EpicTarget in lib/Board.psm1), so a sub-issue moved by hand on the
board moves its epic here too. Nothing is guessed: a card only moves on a signal.

-DryRun prints what it would do and writes nothing. Default is to apply, because the whole point
is that no person has to run it. It does not write the board itself: it calls issue-status and
issue-close, the movers that already handle every board a card is on. One writer, one set of
rules.

.EXAMPLE
./status-sync.ps1 -Project 6
#>
[CmdletBinding()]
param(
  [string]   $Project = '',
  [switch]   $DryRun,
  [string[]] $Repo = @()
)

Import-Module (Join-Path $PSScriptRoot '../lib/Board.psm1') -Force

# --- the decision, kept pure so a test can drive it without a board ------------

# Returns CLOSE for a card finish-issue moved to testing whose commit the newest tag carries, and ''
# for every other card; an epic follows its sub-issues instead.
function Get-DeriveTarget {
  param([string]$Current, [string]$OnMaster, [string]$Released, [string]$IsEpic)
  if ($IsEpic -ceq '1') { return '' }
  if ($Current.ToLowerInvariant() -ceq 'testing' -and $OnMaster -ceq '1' -and $Released -ceq '1') { return 'CLOSE' }
  return ''
}

# When dot-sourced by a test, stop here: the functions are defined, the sweep does not run.
if ($MyInvocation.InvocationName -eq '.') { return }

$ErrorActionPreference = 'Stop'

# --- reads about a repo, memoised for the run --------------------------------

$script:DefaultBranch = @{}; $script:LatestTag = @{}
function Get-RepoDefaultBranch { param($R)
  if (-not $script:DefaultBranch.ContainsKey($R)) { $script:DefaultBranch[$R] = (Invoke-Gh api "repos/$R" --jq '.default_branch') }
  $script:DefaultBranch[$R]
}
function Get-LatestTag { param($R)
  if (-not $script:LatestTag.ContainsKey($R)) {
    try { $script:LatestTag[$R] = (& gh api "repos/$R/tags" --jq '.[0].name // empty') } catch { $script:LatestTag[$R] = '' }
  }
  $script:LatestTag[$R]
}

# 1 when the sha is contained in the ref, else 0. `compare/REF...SHA` answers `behind` when the
# sha is an ancestor of the ref and `identical` when they are the same commit; both mean the ref
# carries it. One helper for two questions - is it on master, and is it in the newest tag -
# because a second implementation of "does this ref carry this commit" is a second answer.
function Test-ContainedIn { param($R, $Ref, $Sha)
  if (-not $Sha -or $Sha -eq '-') { return 0 }
  if (-not $Ref -or $Ref -eq '-') { return 0 }
  $st = & gh api "repos/$R/compare/$Ref...$Sha" --jq '.status' 2>$null
  if ($st -ceq 'behind' -or $st -ceq 'identical') { 1 } else { 0 }
}

# Every signal about one issue: state, the sub-issue total, and the commit finish-issue landed.
#
# The commit is the first one finish-issue listed in its "Landed on <branch>:" comment, the
# record it writes when it moves the card to testing. GitHub's REFERENCED_EVENT is not read: it is
# missing on issues whose commits are on master and in the newest tag.
function Get-Signals { param($R, $N)
  $o = $R.Split('/')[0]; $name = $R.Split('/')[1]
  $q = 'query($o:String!,$n:String!,$num:Int!){ repository(owner:$o,name:$n){ issue(number:$num){
    state subIssuesSummary{ total }
    reopened: timelineItems(last:1, itemTypes:[REOPENED_EVENT]){ nodes{ ... on ReopenedEvent{ createdAt } } }
    comments(last:50){ nodes{ createdAt body } } } } }'
  $json = ((Invoke-Gh api graphql -f "o=$o" -f "n=$name" -F "num=$N" -f "query=$q") -join "`n") | ConvertFrom-Json -DateKind String
  $i = $json.data.repository.issue
  # A comment only counts if it came AFTER the issue was last reopened: a ticket reopened for
  # rework still carries the record of the work that closed it the first time.
  $reopenedAt = $i.reopened.nodes | Select-Object -First 1 -ExpandProperty createdAt -ErrorAction SilentlyContinue
  $landed = @($i.comments.nodes | Where-Object {
    $_.body.StartsWith('Landed on ', [StringComparison]::Ordinal) -and (-not $reopenedAt -or ($_.createdAt -gt $reopenedAt))
  } | Sort-Object { $_.createdAt }) | Select-Object -Last 1
  $first = if ($landed) { @($landed.body -split "`n" | Where-Object { $_ -cmatch '^- [0-9a-f]{7,40} ' }) | Select-Object -First 1 }
  [pscustomobject]@{
    State = $i.state
    Subs  = [int]$i.subIssuesSummary.total
    Sha   = $(if ($first) { $first.Split(' ')[1] } else { '-' })
  }
}

# --- the sweep ----------------------------------------------------------------

Set-Project -Number $Project | Out-Null
$resolved = Get-ProjectNumber

$scanned = 0; $moved = 0
foreach ($line in (& (Join-Path $PSScriptRoot 'board-list.ps1') -Project $resolved)) {
  # board-list: status priority repo #number title
  if ($line -notmatch '^\s*(\S+)\s+(\S+)\s+(\S+)\s+#(\d+)\s') { continue }
  $st = $Matches[1]; $repoShort = $Matches[3]; $num = [int]$Matches[4]
  if ($st -ceq 'done') { continue }
  if ($Repo.Count -gt 0 -and -not ($Repo | Where-Object { $repoShort -ceq $_ -or $repoShort -ceq ($_.Split('/')[-1]) })) { continue }
  $full = if ($repoShort -like '*/*') { $repoShort } else { "$(Get-ProjectOrg)/$repoShort" }
  $scanned++

  $s = Get-Signals $full $num
  if ($s.State -cne 'OPEN') { continue }
  # An epic with ONE child is a plain issue (rules.md section 8); the sweep names it and, as
  # with every epic, moves nothing.
  if ($s.Subs -eq 1) { "one child    $repoShort#$num  (an epic with a single sub-issue is a plain issue, rules.md section 8)" }
  $epic = if ($s.Subs -gt 0) { 1 } else { 0 }
  $onMaster = Test-ContainedIn $full (Get-RepoDefaultBranch $full) $s.Sha
  $rel = 0; if ($onMaster -eq 1) { $rel = Test-ContainedIn $full (Get-LatestTag $full) $s.Sha }
  $target = if ($epic -eq 1) { Get-EpicTargetOnBoard -Repo $full -Number $num }
            else { Get-DeriveTarget -Current $st -OnMaster $onMaster -Released $rel -IsEpic $epic }
  if (-not $target) { continue }

  if ($target -ceq 'CLOSE') {
    $why = if ($epic -eq 1) { 'every sub-issue done' } else { "released in $(Get-LatestTag $full)" }
    if ($DryRun) { "would close  $repoShort#$num  ($st -> done, $why)" }
    else { "close        $repoShort#$num  ($st -> done, $why)"
      & (Join-Path $PSScriptRoot 'issue-close.ps1') -Repo $full -Number $num | Out-Null }
  } else {
    if ($DryRun) { "would move   $repoShort#$num  ($st -> $target)" }
    else { "move         $repoShort#$num  ($st -> $target)"
      & (Join-Path $PSScriptRoot 'issue-status.ps1') -Repo $full -Number $num -Status $target | Out-Null }
  }
  $moved++
}

''
"$scanned active cards scanned, $moved $(if ($DryRun) { 'would move' } else { 'moved' }) on board $resolved."
