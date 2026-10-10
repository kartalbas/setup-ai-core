<#
.SYNOPSIS
Move each card to the state its git signals PROVE it has reached, so the board stops trailing
reality because a person forgot to move a card.

It reads only facts and moves FORWARD only. The signal:
  - a card in testing whose landed commit the newest release tag carries, and whose issue carries
    a proof record written after that landing                    -> closed + done
The proof record is a comment whose first line is "Proven on <environment>:", written by the
session that proved the released work; what it checked follows below that line, in the project's
own form, and is not read here. Without it a released card stays in testing, because a release is
not a proof.
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

THE RELEASE IS READ FROM THE CLONE, after one fetch: the newest tag by date that matches the first
environment of LIVE_TAGS in that clone's .ai-core/config.env ("prod=deploy/prod/* ..." gives
deploy/prod/*), or the newest tag of all where LIVE_TAGS names none. GitHub lists tags by name, so
its first tag is deploy/test/... beside deploy/prod/... and no release at all. A card whose work
landed in another repository is read in that repository's clone. A repository with no clone here,
in the checkout this runs in or beside it in the project folder, is named, and its cards stay.

THE CARDS ARE READ PER REPOSITORY: its open issues and their cards on this board, in one paged
query. start-issue and finish-issue run this for their own repository; read through the whole
board, that cost about 200 points of the hourly GraphQL budget per call on a board of 1000 cards.
Without a repository named, the board is read once to learn which repositories it holds.

The card is put in `implementing` by start-issue, at the moment the worktree is opened, and in
`testing` by finish-issue; both are a session's statement and this sweep writes neither. It never moves a card BACKWARD,
so a state a person set by hand stands. An EPIC carries no work and has no signals of its own: it
follows its sub-issues (Get-EpicTarget in lib/Board.psm1), back from testing to implementing too,
so a sub-issue moved by hand on the board moves its epic here too. Nothing is guessed: a card only moves on a signal.

-DryRun prints what it would do and writes nothing. Default is to apply, because the whole point
is that no person has to run it. It does not write the board itself: it calls issue-status and
issue-close, the movers that already handle every board a card is on. One writer, one set of
rules.

.EXAMPLE
./status-sync.ps1 -Project 6
#>
# The repositories come last and by position, as in the bash twin: `status-sync.ps1 owner/repo`
[CmdletBinding(PositionalBinding = $false)]
param(
  [string]   $Project = '',
  [switch]   $DryRun,
  [Parameter(Position = 0, ValueFromRemainingArguments)][string[]] $Repo = @()
)

Import-Module (Join-Path $PSScriptRoot '../lib/Board.psm1') -Force

# --- the decision, kept pure so a test can drive it without a board ------------

# Returns CLOSE for a card finish-issue moved to testing whose commit the newest release tag
# carries and whose issue carries a proof record after its landing, and '' for every other card;
# an epic follows its sub-issues instead.
function Get-DeriveTarget {
  param([string]$Current, [string]$OnMaster, [string]$Released, [string]$IsEpic, [string]$Proven = '0')
  if ($IsEpic -ceq '1') { return '' }
  if ($Current.ToLowerInvariant() -ceq 'testing' -and $OnMaster -ceq '1' -and $Released -ceq '1' -and $Proven -ceq '1') { return 'CLOSE' }
  return ''
}

# When dot-sourced by a test, stop here: the functions are defined, the sweep does not run.
if ($MyInvocation.InvocationName -eq '.') { return }

$ErrorActionPreference = 'Stop'

# --- what is read, once per repository ----------------------------------------

# THE OPEN ISSUES OF ONE REPOSITORY THAT HAVE A CARD ON THIS BOARD: status, number, sub-issue
# total, the commit finish-issue landed or '-', whether a proof record follows that landing, and
# the repository it landed in where that is another one, or '-'.
#
# The commit is the first one finish-issue listed in its newest "Landed on <branch>:" comment,
# the record it writes when it moves the card to testing; "Landed on <branch> of <owner/repo>:"
# names the repository the work landed in. A comment counts only when it came after the issue was
# last reopened: a ticket reopened for rework still carries the record of the work that closed it
# the first time. A proof record counts only when it came after that landing. Only the comments of
# the repository's owner, members and collaborators count: on a public repository anybody can
# write "Landed on" and "Proven on".
function Get-RepoCards { param([string]$R)
  $q = 'query($o:String!, $n:String!, $after:String) { repository(owner:$o, name:$n) {
    issues(states:OPEN, first:50, after:$after) { pageInfo { hasNextPage endCursor } nodes {
      number subIssuesSummary { total }
      projectItems(first:20) { nodes { project { number owner { ... on Organization { login } ... on User { login } } }
        status: fieldValueByName(name:"Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } } } }
      reopened: timelineItems(last:1, itemTypes:[REOPENED_EVENT]) { nodes { ... on ReopenedEvent { createdAt } } }
      comments(last:50) { nodes { createdAt body authorAssociation } } } } } }'
  $board = [int](Get-ProjectNumber); $org = Get-ProjectOrg
  $after = ''
  while ($true) {
    $call = @('api', 'graphql', '-f', "o=$($R.Split('/')[0])", '-f', "n=$($R.Split('/')[1])")
    if ($after) { $call += @('-f', "after=$after") }
    $page = ((Invoke-Gh @call -f "query=$q") -join "`n") | ConvertFrom-Json -DateKind String
    $issues = $page.data.repository.issues
    if ($null -eq $issues) { Stop-WithError "the open issues of $R were not answered" }
    foreach ($i in @($issues.nodes)) {
      $status = @($i.projectItems.nodes | Where-Object { $_.project.number -eq $board -and $_.project.owner.login -ieq $org } |
        ForEach-Object { if ($_.status.name) { $_.status.name } else { '' } }) | Select-Object -First 1
      if (-not $status) { continue }
      $reopenedAt = $i.reopened.nodes | Select-Object -First 1 -ExpandProperty createdAt -ErrorAction SilentlyContinue
      $said = @($i.comments.nodes | Where-Object { $_.authorAssociation -cin 'OWNER', 'MEMBER', 'COLLABORATOR' })
      $landed = @($said | Where-Object {
        $_.body.StartsWith('Landed on ', [StringComparison]::Ordinal) -and (-not $reopenedAt -or ($_.createdAt -gt $reopenedAt))
      } | Sort-Object { $_.createdAt }) | Select-Object -Last 1
      $first = if ($landed) { @($landed.body -split "`n" | Where-Object { $_ -cmatch '^- [0-9a-f]{7,40} ' }) | Select-Object -First 1 }
      $proven = if ($landed -and @($said | Where-Object {
        $_.body.StartsWith('Proven on ', [StringComparison]::Ordinal) -and $_.createdAt -gt $landed.createdAt }).Count -gt 0) { 1 } else { 0 }
      $elsewhere = if ($landed -and ($landed.body -split "`n")[0] -cmatch '^Landed on \S+ of ([^\s:]+/[^\s:]+):') { $Matches[1] } else { '-' }
      [pscustomobject]@{
        Status    = $status
        Number    = [int]$i.number
        Subs      = [int]$i.subIssuesSummary.total
        Sha       = $(if ($first) { $first.Split(' ')[1].Trim() } else { '-' })
        Proven    = $proven
        Elsewhere = $elsewhere
      }
    }
    if (-not $issues.pageInfo.hasNextPage) { break }
    $after = $issues.pageInfo.endCursor
  }
}

# THE CLONE OF <owner/repo> ON THIS MACHINE: the checkout this runs in when its origin is that
# repository, else a folder of the project folder whose origin is. '' where none is.
function Get-ProjectFolder {
  $common = "$(& git rev-parse --git-common-dir 2>$null)".Trim()
  if ($LASTEXITCODE -eq 0 -and $common) { Split-Path -Parent "$(& git -C (Join-Path $common '..') rev-parse --show-toplevel)".Trim() }
  else { (Get-Location).Path }
}
function Get-Clone { param([string]$R)
  $want = $R.ToLowerInvariant()
  $top = "$(& git rev-parse --show-toplevel 2>$null)".Trim(); if ($LASTEXITCODE -ne 0) { $top = '' }
  $dirs = @($top) + @(Get-ChildItem -Directory -LiteralPath (Get-ProjectFolder) -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
  foreach ($dir in $dirs) {
    if (-not $dir) { continue }
    $url = "$(& git -C $dir remote get-url origin 2>$null)".Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or -not $url) { continue }
    $url = $url -creplace '\.git$', ''
    if ($url.EndsWith("/$want", [StringComparison]::Ordinal) -or $url.EndsWith(":$want", [StringComparison]::Ordinal)) { return $dir }
  }
  ''
}

# THE TAGS OF THE RELEASE THAT CLOSES A CARD: the pattern of the first environment of LIVE_TAGS
# in a config.env, or every tag where it names none
function Get-ReleaseTagPattern { param([string]$Config)
  $line = if (Test-Path -LiteralPath $Config) { @(Get-Content -LiteralPath $Config | Where-Object { $_ -cmatch '^\s*LIVE_TAGS\s*=' }) | Select-Object -Last 1 }
  $line = "$line" -creplace '^[^=]*=', '' -creplace '#.*$', '' -creplace '["'']', ''
  foreach ($word in ($line -split '\s+')) { if ($word -cmatch '^.+=(.+)$') { return $Matches[1] } }
  '*'
}

# THE RELEASE OF ONE REPOSITORY, read once per run and kept in $script:Releases for the next card
# that asks: its clone (or ''), origin's default branch and the newest release tag by date (or '').
# It says once what it could not read.
#
# The pattern is LIVE_TAGS of the clone's own .ai-core/config.env: the project of that repository
# decides what its release is, never the folder this runs in. A tag counts only where origin has it
# on the same commit: a fetch never prunes and never moves a tag the clone holds, so a tag a
# refused push left in the clone, one deleted on origin or one origin moved would read as a
# release. Where a tag of the pattern stands on origin on another commit than in the clone, or not
# in the clone at all, which one is the newest is not known, and where origin cannot be listed,
# nothing is: then no tag counts. The fetch asks nobody for a password.
$script:Releases = @{}
function Read-Release { param([string]$R)
  if ($script:Releases.ContainsKey($R)) { return }
  $release = [pscustomobject]@{ Clone = (Get-Clone $R); Ref = ''; Tag = '' }
  $script:Releases[$R] = $release
  $clone = $release.Clone
  if (-not $clone) { "no clone of $R in $(Get-ProjectFolder), so no release of it is read and its cards in testing stay"; return }
  # git's stderr is text to read here, not an exception
  $kept = $ErrorActionPreference, $env:GIT_TERMINAL_PROMPT
  $ErrorActionPreference = 'Continue'; $env:GIT_TERMINAL_PROMPT = '0'
  try {
    # Without -q, because a quiet fetch that refuses to move a tag gives no reason at all
    $said = @(& git -C $clone fetch --tags origin 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) {
      $reason = @($said | Where-Object { $_ -cmatch '^(error|fatal):|^ ! ' }) | Select-Object -First 1
      $reason = if ($reason) { ($reason -creplace ' +', ' ').TrimStart(' ') } else { 'git gave no reason' }
      "fetching origin of $R in $clone failed: $reason; the refs it had are read"
    }
    try { Push-Location -LiteralPath $clone; $release.Ref = "origin/$(Get-OriginDefaultBranch)" } catch { $release.Ref = '' } finally { Pop-Location }
    $listing = @(& git -C $clone ls-remote --tags origin 2>$null | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) { "origin of $R could not be listed from $clone, so no tag of it counts as a release and its cards in testing stay"; return }
    # <tag> -> the commit it stands on: an annotated tag's own line names the tag object, its ^{} line the commit
    $remote = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    foreach ($line in $listing) {
      $sha, $ref = $line -split '\s+'
      if (-not $ref) { continue }
      $name = $ref -creplace '^refs/tags/', ''
      if ($name.EndsWith('^{}', [StringComparison]::Ordinal)) { $remote[$name.Substring(0, $name.Length - 3)] = $sha }
      elseif (-not $remote.ContainsKey($name)) { $remote[$name] = $sha }
    }
    # The pattern is matched here and never handed to git: pwsh expands a wildcard in a native
    # command's argument against the files of the current folder, a variable's too
    $pattern = Get-ReleaseTagPattern (Join-Path $clone '.ai-core/config.env')
    $names = [string[]]@($remote.Keys); [Array]::Sort($names, [StringComparer]::Ordinal)
    $odd = @($names | Where-Object { $_ -clike $pattern } | Where-Object {
      "$(& git -C $clone rev-parse -q --verify "refs/tags/$_^{commit}" 2>$null)".Trim() -cne $remote[$_] }) | Select-Object -First 1
    if ($odd) { "origin of $R has $odd on a commit its clone in $clone does not have it on, so no tag of it counts as a release and its cards in testing stay"; return }
    $release.Tag = "$(@(& git -C $clone tag --sort=-creatordate 2>$null) | ForEach-Object { "$_" } |
      Where-Object { $_ -clike $pattern -and $remote.ContainsKey($_) } | Select-Object -First 1)".Trim()
  } finally { $ErrorActionPreference, $env:GIT_TERMINAL_PROMPT = $kept }
}

# --- the sweep ----------------------------------------------------------------

# Without a board named, the board is the one the first repository named is linked to, so a
# repository whose checkout is elsewhere is swept on its own board
$first = if (-not $Project -and -not $env:GH_PROJECT_NUMBER -and $Repo.Count -gt 0 -and $Repo[0] -like '*/*') { $Repo[0] } else { '' }
Set-Project -Number $Project -Repo $first | Out-Null
$resolved = Get-ProjectNumber
$org = Get-ProjectOrg

# The repositories: the ones named, else every one with an active card on the board, which is read
# whole for that. A refused read stops the run: a board that never answered is no empty board.
$repos = if ($Repo.Count -gt 0) { @($Repo | ForEach-Object { if ($_ -like '*/*') { $_ } else { "$org/$_" } }) }
else {
  @(& (Join-Path $PSScriptRoot 'board-list.ps1') -Project $resolved | ForEach-Object {
    # board-list: status priority repo #number title
    if ("$_" -cmatch '^\s*(\S+)\s+\S+\s+(\S+)\s+#\d+\s' -and $Matches[1] -cne 'done') { if ($Matches[2] -like '*/*') { $Matches[2] } else { "$org/$($Matches[2])" } }
  } | Sort-Object -Unique -CaseSensitive)
}

$scanned = 0; $moved = 0
foreach ($full in $repos) {
  $label = if ($full.StartsWith("$org/", [StringComparison]::Ordinal)) { $full.Substring($org.Length + 1) } else { $full }
  foreach ($c in @(Get-RepoCards $full)) {
    $st = $c.Status; $num = $c.Number
    if ($st.ToLowerInvariant() -ceq 'done') { continue }
    $scanned++
    # An issue with sub-issues is an epic whatever their number, and follows them. One with a single
    # sub-issue is named: it is often an issue with work of its own and one dependency hung under
    # it, and closing it with that sub-issue would close the unfinished work.
    if ($c.Subs -eq 1) { "one child    $label#$num  (its state follows its one sub-issue; work of its own belongs in a sub-issue of its own, or it is closed with that sub-issue)" }
    if ($c.Subs -gt 0) { $target = Get-EpicTargetOnBoard -Repo $full -Number $num }
    else {
      if ($st.ToLowerInvariant() -cne 'testing') { continue }
      # The release of the repository the work landed in, read once where a card in testing asks
      $landed = if ($c.Elsewhere -cne '-') { $c.Elsewhere } else { $full }
      Read-Release $landed
      $release = $script:Releases[$landed]; $clone = $release.Clone; $ref = $release.Ref
      $tag = if ($landed -ceq $full) { $release.Tag } else { "$landed $($release.Tag)" }
      $onMaster = 0; $rel = 0
      if ($ref -and $c.Sha -cne '-') {
        $commit = "$(& git -C $clone rev-parse -q --verify "$($c.Sha)^{commit}" 2>$null)".Trim()
        if ($LASTEXITCODE -eq 0 -and $commit) {
          & git -C $clone merge-base --is-ancestor $commit $ref 2>$null; if ($LASTEXITCODE -eq 0) { $onMaster = 1 }
          if ($release.Tag) { & git -C $clone merge-base --is-ancestor $commit $release.Tag 2>$null; if ($LASTEXITCODE -eq 0) { $rel = 1 } }
        }
      }
      $target = Get-DeriveTarget -Current $st -OnMaster $onMaster -Released $rel -IsEpic 0 -Proven $c.Proven
      if (-not $target) {
        if ($rel -eq 1) { "proof due    $label#$num  (released in $tag, no ""Proven on"" record after its landing)" }
        continue
      }
    }
    if (-not $target) { continue }

    if ($target -ceq 'CLOSE') {
      $why = if ($c.Subs -gt 0) { 'every sub-issue done' } else { "released in $tag and proven" }
      if ($DryRun) { "would close  $label#$num  ($st -> done, $why)" }
      else { "close        $label#$num  ($st -> done, $why)"
        & (Join-Path $PSScriptRoot 'issue-close.ps1') -Repo $full -Number $num | Out-Null }
    } else {
      if ($DryRun) { "would move   $label#$num  ($st -> $target)" }
      else { "move         $label#$num  ($st -> $target)"
        & (Join-Path $PSScriptRoot 'issue-status.ps1') -Repo $full -Number $num -Status $target | Out-Null }
    }
    $moved++
  }
}

''
"$scanned active cards scanned, $moved $(if ($DryRun) { 'would move' } else { 'moved' }) on board $resolved."
