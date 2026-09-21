# Cut a release of setup-ai-core: the tag vX.Y.Z on the commit checked out, pushed to origin.
# For whoever maintains setup-ai-core, run in its clone. install and update follow the newest
# tag, so what is not tagged reaches nobody.
#
#   release.ps1 <version>
#
# A release is cut only when VERSION carries the version, the tree is clean, the commit is on
# the default branch and pushed, and the checks were green on both runners for exactly this
# commit (gh run list). Whatever is missing is named, and nothing is tagged.
[CmdletBinding(PositionalBinding = $false)]
param (
  [switch]$Help,
  [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest = @()
)

if ($Help -or $Rest -ccontains "-h" -or $Rest -ccontains "--help") {
  Write-Host "Usage: release.ps1 <version>"
  Write-Host ""
  Write-Host "Tags the commit checked out in this clone of setup-ai-core as v<version> and pushes the tag."
  Write-Host "Refuses, naming what is missing, unless VERSION carries <version>, the tree is clean, the commit"
  Write-Host "is on the default branch and pushed, and the checks were green on both runners for this commit."
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

$have = (Get-Content (Join-Path $core 'VERSION') -Raw).Trim()
if ($have -cne $version) { Deny-Release "VERSION carries $have, not ${version}; a release carries the version the file says" }
if (@(& git -C $core status --porcelain 2>$null | ForEach-Object { "$_" } | Where-Object { $_ }).Count -gt 0) { Deny-Release "the tree is not clean; commit or stash first" }
$branch = "$(& git -C $core symbolic-ref --short -q HEAD 2>$null)".Trim()
if ($LASTEXITCODE -ne 0 -or -not $branch) { Deny-Release "not on a branch; a release is cut on the default branch" }
$default = ("$(& git -C $core rev-parse --abbrev-ref origin/HEAD 2>$null)" -creplace '^origin/', '').Trim()
if (-not $default) { $default = $branch }
if ($branch -cne $default) { Deny-Release "on $branch, not on $default" }
& git -C $core fetch --quiet --tags origin
if ($LASTEXITCODE -ne 0) { Deny-Release "could not reach origin" }
$sha = "$(& git -C $core rev-parse HEAD)".Trim()
if ("$(& git -C $core rev-parse "origin/$branch")".Trim() -cne $sha) { Deny-Release "$branch is not pushed, or origin/$branch has moved on; push or pull first" }
& git -C $core rev-parse -q --verify "refs/tags/$tag" 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) { Deny-Release "$tag exists already" }

# The checks for exactly this commit, on every runner: one workflow run, completed and green
$runs = (& gh run list --commit $sha --workflow check --json status,conclusion --limit 5 2>$null | Out-String)
if ($LASTEXITCODE -ne 0 -or -not $runs.Trim()) { Deny-Release "gh could not list the workflow runs of $sha (is gh logged in?)" }
$list = @($runs | ConvertFrom-Json)
if ($list.Count -eq 0) { Deny-Release "no workflow run for $sha yet; push, let the checks run, then release" }
if (@($list | Where-Object { $_.status -cne 'completed' }).Count -gt 0) { Deny-Release "the checks for $sha are still running" }
if (@($list | Where-Object { $_.conclusion -ceq 'success' }).Count -eq 0) { Deny-Release "the checks for $sha are not green; nothing is released red" }

& git -C $core tag -a $tag -m "release: $version"
if ($LASTEXITCODE -ne 0) { Deny-Release "could not tag" }
& git -C $core push --quiet origin "refs/tags/$tag"
if ($LASTEXITCODE -ne 0) { & git -C $core tag -d $tag 2>$null | Out-Null; Deny-Release "could not push ${tag}; the tag is removed again" }
Write-Host "release: $tag on $($sha.Substring(0, 7)), pushed; install and update follow it now"
exit 0
