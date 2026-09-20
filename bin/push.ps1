# Commit and push what changed in the project harness clones on this machine, then refresh the
# checkout this runs in. Editing the harness is: change a file under ~\.<name>-ai-core, then
# `ai-core push`; every colleague gets it at their next init.
#
#   push.ps1 [-Message <text>] [-Harness <name>]
#
[CmdletBinding()]
param (
  [switch]$Help,
  [Parameter(Position = 0)][string]$Message = "",
  [string]$Harness = ""
)

if ($Help -or $Message -ceq "-h" -or $Message -ceq "--help" -or $args -ccontains "-h" -or $args -ccontains "--help") {
  Write-Host "Usage: push.ps1 [-Message <text>] [-Harness <name>]"
  Write-Host ""
  Write-Host "Commits everything that changed in every project harness clone on this machine"
  Write-Host "(~\.<name>-ai-core), pulls with rebase and pushes to its origin; then runs init in the"
  Write-Host "current directory when it carries the harness, so this checkout is current at once."
  Write-Host ""
  Write-Host "Options:"
  Write-Host "  -Message <text>   The commit message; default: the files that changed"
  Write-Host "  -Harness <name>   Only this harness, e.g. shop-ai-core"
  Write-Host "  -Help             Show this help message"
  Write-Host ""
  Write-Host "Examples:"
  Write-Host "  ai-core push `"the naming skill: one more trap`""
  Write-Host "  ai-core push -Harness shop-ai-core"
  exit 0
}
if ($args.Count -gt 0) { Write-Host "error: unknown argument '$($args[0])' (see -Help)"; exit 2 }

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$core = Split-Path -Parent $PSScriptRoot

$pushed = 0; $failed = @(); $seen = 0
foreach ($d in (Get-ChildItem -Path $HOME -Directory -Force -Filter '.*-ai-core' | Where-Object { Test-Path (Join-Path $_.FullName '.git') } | Sort-Object Name)) {
  $dir = $d.FullName; $name = $d.Name.TrimStart('.')
  if ($Harness -and $name -cne $Harness) { continue }
  $seen++
  $origin = "$(& git -C $dir remote get-url origin 2>$null)".Trim()
  if ($LASTEXITCODE -ne 0 -or -not $origin) { Write-Host "${name}: no origin, not pushed ($dir)"; continue }
  $origin = $origin -creplace '.*github\.com[:/]', '' -creplace '\.git$', ''
  # 1. commit what changed
  $changed = @(& git -C $dir status --porcelain 2>$null | ForEach-Object { "$_".TrimEnd("`r") } | Where-Object { $_ })
  if ($changed.Count -gt 0) {
    $msg = $Message
    if (-not $msg) {
      $msg = (($changed | Select-Object -First 3 | ForEach-Object { $_.Substring(3) }) -join ', ')
      if ($changed.Count -gt 3) { $msg = "$msg (+$($changed.Count - 3))" }
    }
    & git -C $dir add -A
    & git -C $dir commit -q -m $msg
    if ($LASTEXITCODE -ne 0) { $failed += $name; Write-Host "${name}: commit failed"; continue }
    Write-Host "${name}: committed $($changed.Count) file(s): $msg"
  }
  # 2. push what is ahead of origin, after taking what colleagues pushed
  $ahead = "$(& git -C $dir rev-list --count '@{upstream}..HEAD' 2>$null)".Trim()
  if ($LASTEXITCODE -ne 0 -or -not $ahead) { $ahead = '1' }
  if ([int]$ahead -gt 0) {
    & git -C $dir pull --rebase --quiet 2>$null | Out-Null
    & git -C $dir push --quiet -u origin HEAD
    if ($LASTEXITCODE -eq 0) { Write-Host "${name}: pushed to $origin"; $pushed++ }
    else { $failed += $name; Write-Host "${name}: push failed; see above" }
  } else {
    Write-Host "${name}: nothing to push"
  }
}
if ($seen -eq 0) { Write-Host "push: no project harness clone under $HOME$(if ($Harness) { " named $Harness" })"; exit 1 }
if ($failed.Count -gt 0) { Write-Host "push: failed: $($failed -join ' ')"; exit 1 }

# 3. this checkout is current at once
if ((Test-Path '.ai-core') -and $pushed -gt 0) {
  Write-Host "--> Refreshing this checkout"
  & pwsh -NoProfile -File (Join-Path $core 'bin\init.ps1') -TargetDir . -NoDoctor 2>&1 | Out-Null
  if ($LASTEXITCODE -eq 0) { Write-Host "--> This checkout is current" } else { Write-Host "note: init here reported a problem; run ai-core init to see it" }
}
