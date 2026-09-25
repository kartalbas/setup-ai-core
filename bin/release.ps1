# Cut a release of setup-ai-core: the tag vX.Y.Z on the commit VERSION names, pushed to origin.
# For whoever maintains setup-ai-core, run in its clone. install and update follow the newest
# tag, so what is not tagged reaches nobody.
#
#   release.ps1 <version>
#
# One command does the whole release: VERSION gets the version when it does not carry it yet,
# committed on its own as `release: <version>`; whatever is not pushed goes to origin by ref;
# then the command waits for the check run of that commit (gh run list, every 20 seconds, 30
# minutes at most; AI_CORE_RELEASE_POLL and AI_CORE_RELEASE_WAIT, in seconds, for a suite) and
# tags it when the run is green. It refuses, naming what is missing, when the tree is not clean,
# the branch is not the default branch, origin has moved on, the tag exists, or the checks are
# red or do not finish. Nothing is tagged red.
[CmdletBinding(PositionalBinding = $false)]
param (
  [switch]$Help,
  [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest = @()
)

if ($Help -or $Rest -ccontains "-h" -or $Rest -ccontains "--help") {
  Write-Host "Usage: release.ps1 <version>"
  Write-Host ""
  Write-Host "Releases <version> from this clone of setup-ai-core in one run: writes VERSION and commits"
  Write-Host "'release: <version>' when VERSION does not carry it yet, pushes what is not pushed, waits for"
  Write-Host "the check run of that commit and tags it v<version>, pushed, when the run is green."
  Write-Host "Refuses, naming what is missing, when the tree is not clean, this is not the default branch,"
  Write-Host "origin has moved on, the tag exists, or the checks are red or do not finish in 30 minutes."
  Write-Host ""
  Write-Host "Options:"
  Write-Host "  -Help         Show this help message"
  Write-Host ""
  Write-Host "Examples:"
  Write-Host "  ai-core release 1.2.0"
  exit 0
}

$ErrorActionPreference = 'Continue'
$core = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if ($Rest.Count -ne 1) { Write-Host "error: release takes one argument, the version (see -Help)" -ForegroundColor Red; exit 2 }
$version = $Rest[0]
if ($version -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { Write-Host "error: '$version' is not a version of the form X.Y.Z" -ForegroundColor Red; exit 2 }
$tag = "v$version"
function Deny-Release([string]$why) { [Console]::Error.WriteLine("release: REFUSED — $why"); exit 1 }

if (@(& git -C $core status --porcelain 2>$null | ForEach-Object { "$_" } | Where-Object { $_ }).Count -gt 0) { Deny-Release "the tree is not clean; commit or stash first" }
$branch = "$(& git -C $core symbolic-ref --short -q HEAD 2>$null)".Trim()
if ($LASTEXITCODE -ne 0 -or -not $branch) { Deny-Release "not on a branch; a release is cut on the default branch" }
$default = ("$(& git -C $core rev-parse --abbrev-ref origin/HEAD 2>$null)" -creplace '^origin/', '').Trim()
if (-not $default) { $default = $branch }
if ($branch -cne $default) { Deny-Release "on $branch, not on $default" }
& git -C $core fetch --quiet --tags origin
if ($LASTEXITCODE -ne 0) { Deny-Release "could not reach origin" }
& git -C $core rev-parse -q --verify "refs/tags/$tag" 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) { Deny-Release "$tag exists already" }
& git -C $core rev-parse -q --verify "origin/$branch" 2>$null | Out-Null
$hasOrigin = ($LASTEXITCODE -eq 0)
if ($hasOrigin -and "$(& git -C $core rev-list --count "HEAD..origin/$branch")".Trim() -cne '0') { Deny-Release "origin/$branch has moved on; pull first" }

# 1. VERSION carries the version, committed on its own
$have = (Get-Content (Join-Path $core 'VERSION') -Raw).Trim()
if ($have -cne $version) {
  [System.IO.File]::WriteAllText((Join-Path $core 'VERSION'), "$version`n", (New-Object System.Text.UTF8Encoding $false))
  & git -C $core commit --quiet -m "release: $version" -- VERSION
  if ($LASTEXITCODE -ne 0) { Deny-Release "could not commit VERSION" }
  Write-Host "release: VERSION $have -> $version, committed as 'release: $version'"
}

# 2. The commit is on origin, with whatever was not pushed before it
$sha = "$(& git -C $core rev-parse HEAD)".Trim()
$onOrigin = if ($hasOrigin) { "$(& git -C $core rev-parse "origin/$branch" 2>$null)".Trim() } else { '' }
if ($onOrigin -cne $sha) {
  & git -C $core push --quiet origin "HEAD:$branch"
  if ($LASTEXITCODE -ne 0) { Deny-Release "could not push $branch (see above)" }
  Write-Host "release: $($sha.Substring(0, 7)) pushed to origin/$branch"
}

# 3. The checks for exactly this commit, on every runner: one workflow run, completed and green,
#    waited for
$poll = if ($env:AI_CORE_RELEASE_POLL) { [int]$env:AI_CORE_RELEASE_POLL } else { 20 }
$limit = if ($env:AI_CORE_RELEASE_WAIT) { [int]$env:AI_CORE_RELEASE_WAIT } else { 1800 }
$minutes = [int][math]::Floor($limit / 60)
$deadline = (Get-Date).AddSeconds($limit); $waiting = $false
while ($true) {
  $runs = (& gh run list --commit $sha --workflow check --json status,conclusion --limit 5 2>$null | Out-String)
  if ($LASTEXITCODE -ne 0 -or -not $runs.Trim()) { Deny-Release "gh could not list the workflow runs of $sha (is gh logged in?)" }
  $list = @($runs | ConvertFrom-Json)
  if ($list.Count -gt 0 -and @($list | Where-Object { $_.status -cne 'completed' }).Count -eq 0) { break }
  if ((Get-Date) -ge $deadline) { Deny-Release "the checks for $sha did not finish in $minutes minute(s); run 'ai-core release $version' again when they have" }
  if (-not $waiting) { Write-Host "release: waiting for the checks of $($sha.Substring(0, 7)) (asked every ${poll}s, $minutes minute(s) at most)"; $waiting = $true }
  Start-Sleep -Seconds $poll
}
if (@($list | Where-Object { $_.conclusion -ceq 'success' }).Count -eq 0) { Deny-Release "the checks for $sha are not green; nothing is released red" }

# The tag goes on the commit whose checks were waited for, not on whatever HEAD is by now: a
# commit made during the wait was never checked
& git -C $core tag -a $tag -m "release: $version" $sha
if ($LASTEXITCODE -ne 0) { Deny-Release "could not tag" }
& git -C $core push --quiet origin "refs/tags/$tag"
if ($LASTEXITCODE -ne 0) { & git -C $core tag -d $tag 2>$null | Out-Null; Deny-Release "could not push ${tag}; the tag is removed again" }
Write-Host "release: $tag on $($sha.Substring(0, 7)), pushed; install and update follow it now"
exit 0
