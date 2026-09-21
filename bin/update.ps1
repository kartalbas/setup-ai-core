# Update this machine: setup-ai-core to its newest release, and every project harness clone
# (~\.<name>-ai-core) to its origin. Nothing updates by itself; this is the command that does.
#
#   update.ps1 [-Check] [-Main]
#
# A release is a tag vX.Y.Z of setup-ai-core, set when the checks are green on both runners
# (ai-core release). install checks out the newest one, and update moves to the newest one; a
# clone with uncommitted changes or commits not pushed is left alone and named. -Main follows
# the development branch instead, which is what a clone of somebody working on setup-ai-core
# does. -Check fetches and reports, and changes nothing: exit 0 when everything is current,
# 2 when a release or commits are available, 1 when an origin could not be reached.
[CmdletBinding(PositionalBinding = $false)]
param (
  [switch]$Help,
  [switch]$Check,
  [switch]$Main,
  [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest = @()
)

if ($Help -or $Rest -ccontains "-h" -or $Rest -ccontains "--help") {
  Write-Host "Usage: update.ps1 [-Check] [-Main]"
  Write-Host ""
  Write-Host "Moves setup-ai-core to its newest release (a tag vX.Y.Z; a clone with uncommitted changes"
  Write-Host "or commits not pushed is left alone and named) and pulls every project harness clone on"
  Write-Host "this machine (~\.<name>-ai-core) from its origin. Nothing updates by itself."
  Write-Host ""
  Write-Host "Options:"
  Write-Host "  -Check        Fetch and report only: exit 0 when everything is current, 2 when a release or"
  Write-Host "                commits are available, 1 when an origin could not be reached"
  Write-Host "  -Main         Follow the development branch of setup-ai-core instead of its releases"
  Write-Host "  -Help         Show this help message"
  Write-Host ""
  Write-Host "Examples:"
  Write-Host "  ai-core update"
  Write-Host "  ai-core update -Check"
  exit 0
}
if ($Rest.Count -gt 0) { Write-Host "error: unknown option '$($Rest[0])' (see -Help)" -ForegroundColor Red; exit 2 }

$ErrorActionPreference = 'Continue'
$core = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

# A fetch that gives up on a dead line instead of hanging a session start
function Invoke-Fetch([string]$dir) { & git -C $dir -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=5 fetch --quiet --tags origin 2>$null; return ($LASTEXITCODE -eq 0) }
function Get-NewestRelease([string]$dir) { return "$(@(& git -C $dir tag --list 'v[0-9]*' --sort=-v:refname 2>$null | ForEach-Object { "$_" } | Where-Object { $_ })[0])" }
function Get-ReleaseOf([string]$dir) { $t = "$(& git -C $dir describe --tags --exact-match HEAD 2>$null)"; if ($LASTEXITCODE -eq 0) { return $t.Trim() } else { return '' } }
function Get-BranchOf([string]$dir) { $b = "$(& git -C $dir symbolic-ref --short -q HEAD 2>$null)"; if ($LASTEXITCODE -eq 0) { return $b.Trim() } else { return '' } }
function Get-BehindBy([string]$dir, [string]$branch) { $n = "$(& git -C $dir rev-list --count "HEAD..origin/$branch" 2>$null)"; if ($LASTEXITCODE -eq 0 -and $n) { return [int]$n } else { return 0 } }

$status = 0   # what -Check answers
# --- setup-ai-core ------------------------------------------------------------------------------
$branch = Get-BranchOf $core; $here = Get-ReleaseOf $core
if (-not (Invoke-Fetch $core)) {
  Write-Host "setup-ai-core: could not reach origin"; $status = 1
} else {
  $newest = Get-NewestRelease $core
  if ($Check) {
    if ($branch) {
      $n = Get-BehindBy $core $branch
      if ($n -gt 0) { Write-Host "setup-ai-core: follows $branch, behind by $n commit(s)"; $status = 2 } else { Write-Host "setup-ai-core: follows $branch, current" }
      if ($newest -and $newest -cne $here) { Write-Host "setup-ai-core: the newest release is $newest (ai-core update moves a clean clone there)" }
    } elseif (-not $newest) {
      Write-Host "setup-ai-core: no release yet"
    } elseif ($newest -ceq $here) {
      Write-Host "setup-ai-core: current ($here)"
    } else {
      Write-Host "setup-ai-core: release $newest available (this machine: $(if ($here) { $here } else { 'no release' }))"; $status = 2
    }
  } else {
    $dirty = @(& git -C $core status --porcelain 2>$null | ForEach-Object { "$_" } | Where-Object { $_ }).Count
    $ahead = 0
    if ($branch) { $a = "$(& git -C $core rev-list --count "origin/$branch..HEAD" 2>$null)"; if ($LASTEXITCODE -eq 0 -and $a) { $ahead = [int]$a } }
    if ($dirty -gt 0 -or $ahead -gt 0) {
      Write-Host "--> setup-ai-core at ${core}: left alone ($dirty uncommitted change(s), $ahead commit(s) not pushed)"
    } elseif ($Main -or -not $newest) {
      if (-not $branch) {
        & git -C $core checkout --quiet main 2>$null
        if ($LASTEXITCODE -ne 0) { & git -C $core checkout --quiet master 2>$null }
        $branch = Get-BranchOf $core
      }
      & git -C $core pull --quiet --ff-only origin $branch
      if ($LASTEXITCODE -eq 0) { Write-Host "--> setup-ai-core at ${core}: follows $branch$(if (-not $newest) { ' (no release yet)' }), pulled" } else { Write-Host "--> setup-ai-core at ${core}: could not be pulled (see above)" }
    } elseif (-not $branch -and $newest -ceq $here) {
      Write-Host "--> setup-ai-core at ${core}: current, release $here"
    } else {
      & git -C $core checkout --quiet $newest
      if ($LASTEXITCODE -eq 0) { Write-Host "--> setup-ai-core at ${core}: release $newest (was $(if ($branch) { $branch } else { $here }))" } else { Write-Host "--> setup-ai-core at ${core}: could not move to $newest (see above)" }
    }
  }
}

# --- the project harness clones ------------------------------------------------------------
foreach ($d in (Get-ChildItem -Path $HOME -Directory -Force -Filter '.*-ai-core' | Where-Object { Test-Path (Join-Path $_.FullName '.git') })) {
  $name = $d.Name.TrimStart('.'); $dir = $d.FullName
  if ($name -ceq 'setup-ai-core') { continue }   # the clone itself, handled above
  if (-not (Invoke-Fetch $dir)) { Write-Host "${name}: could not reach origin"; $status = 1; continue }
  $b = Get-BranchOf $dir
  if (-not $b) { $b = ("$(& git -C $dir rev-parse --abbrev-ref origin/HEAD 2>$null)" -creplace '^origin/', '').Trim() }
  $n = Get-BehindBy $dir $b
  if ($Check) {
    if ($n -gt 0) { Write-Host "${name}: behind by $n commit(s)"; $status = 2 } else { Write-Host "${name}: current" }
  } elseif ($n -eq 0) {
    Write-Host "--> $name at ${dir}: current"
  } else {
    & git -C $dir pull --quiet --ff-only origin $b
    if ($LASTEXITCODE -eq 0) { Write-Host "--> $name at ${dir}: pulled $n commit(s)" } else { Write-Host "--> $name at ${dir}: could not be pulled (see above)" }
  }
}

if ($Check) { exit $status }
Write-Host "--> The scripts are current everywhere; run ai-core init in a checkout to bring it to this state"
exit 0
