# Bootstrap a target repository with setup-ai-core agnostic harness
#
#   init.ps1 [-TargetDir <path>] [-All <folder>] [-NoDoctor] [-Remote]
#
# Supports:
# - Claude Code (.claude)
# - OpenHands (.openhands)
# - OpenAI Codex & OpenCode (AGENTS.md)
# - Google Antigravity (.gemini & AGENTS.md)
# - Cursor (.cursorrules)
# - Windsurf (.windsurfrules)
# - Aider (.aider.conf.yml)
# - GitHub Copilot (.github/copilot-instructions.md)
#
[CmdletBinding()]
param (
  [switch]$Help,
  [string]$TargetDir = ".",
  [string]$All = "",
  [switch]$NoDoctor,
  [switch]$Remote
)

if ($Help -or $args -contains "-h" -or $args -contains "--help" -or $TargetDir -eq "--help" -or $TargetDir -eq "-h") {
  Write-Host "Usage: init.ps1 [-TargetDir <path>] [-All <folder>] [-NoDoctor] [-Remote]"
  Write-Host ""
  Write-Host "Bootstraps a target repository with the setup-ai-core agnostic harness."
  Write-Host ""
  Write-Host "Options:"
  Write-Host "  -TargetDir <path>   Target directory (default: current)"
  Write-Host "  -All <folder>       Run init in every git repository directly under <folder>"
  Write-Host "  -NoDoctor           Do not run doctor first"
  Write-Host "  -Remote             Force remote mode (download from GitHub)"
  Write-Host "  -Help               Show this help message"
  Write-Host ""
  Write-Host "Examples:"
  Write-Host "  pwsh -File init.ps1 -TargetDir ."
  Write-Host "  pwsh -File init.ps1 -TargetDir ../my-project"
  Write-Host "  pwsh -File init.ps1 -All ../my-org"
  exit 0
}

$ErrorActionPreference = 'Stop'

# A local clone is recognised by templates\ and VERSION next to bin\; a deployed
# .ai-core\ has neither. $MyInvocation.MyCommand.Path is null when piped into iex.
$coreRoot = ""
if ($MyInvocation.MyCommand.Path) {
  $candidate = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
  if ((Test-Path (Join-Path $candidate "templates")) -and (Test-Path (Join-Path $candidate "VERSION"))) { $coreRoot = $candidate }
}
# -All: doctor once, then init in every git repository directly under the folder
if ($All) {
  $allDir = (Resolve-Path $All).Path
  if (-not $NoDoctor) {
    & pwsh -NoProfile -File (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "doctor.ps1")
    if ($LASTEXITCODE -ne 0) { Write-Host "error: fix the problems doctor reported, then run init again (or pass -NoDoctor)." -ForegroundColor Red; exit 1 }
  }
  $ok = 0; $failed = @()
  foreach ($repo in Get-ChildItem -Path $allDir -Directory | Where-Object { Test-Path (Join-Path $_.FullName ".git") }) {
    Write-Host ""; Write-Host "### $($repo.Name)"
    $params = @('-TargetDir', $repo.FullName, '-NoDoctor'); if ($Remote) { $params += '-Remote' }
    & pwsh -NoProfile -File $MyInvocation.MyCommand.Path @params
    if ($LASTEXITCODE -eq 0) { $ok++ } else { $failed += $repo.Name }
  }
  Write-Host ""; Write-Host "==> init -All: $ok repositories initialized$(if ($failed) { '; failed: ' + ($failed -join ' ') })"
  if ($failed) { exit 1 } else { exit 0 }
}

$target = (Resolve-Path $TargetDir).Path
$archiveUrl = "https://github.com/kartalbas/setup-ai-core/archive/refs/heads/main.zip"

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "Initializing Agnostic AI Core Harness in: $target" -ForegroundColor Cyan
Write-Host "Target Environment : Agnostic (Multi-Agent)" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

# Source: the local clone, or one archive download so remote installs get the same files
$srcTmp = ""
if (-not $coreRoot -or $Remote) {
  $srcTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("setup-ai-core-" + [System.Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $srcTmp | Out-Null
  Write-Host "--> Downloading setup-ai-core ($archiveUrl)..."
  Invoke-WebRequest -Uri $archiveUrl -OutFile (Join-Path $srcTmp "src.zip")
  Expand-Archive -Path (Join-Path $srcTmp "src.zip") -DestinationPath $srcTmp
  $coreRoot = Join-Path $srcTmp "setup-ai-core-main"
} else {
  Write-Host "--> Deploying from local clone: $coreRoot"
}

# The prerequisites first; nothing is deployed on a machine that cannot run the harness
if (-not $NoDoctor) {
  & pwsh -NoProfile -File (Join-Path $coreRoot "bin\doctor.ps1")
  if ($LASTEXITCODE -ne 0) {
    if ($srcTmp) { Remove-Item -Recurse -Force $srcTmp }
    Write-Host "error: fix the problems doctor reported, then run init again (or pass -NoDoctor)." -ForegroundColor Red
    exit 1
  }
}

# Ensure target isolation folder exists (.ai-core)
$aiCoreDir = Join-Path $target ".ai-core"
$aiCoreBin = Join-Path $aiCoreDir "bin"
$aiCoreRules = Join-Path $aiCoreDir "rules"
$aiCoreDocs = Join-Path $aiCoreDir "docs"

foreach ($dir in @($aiCoreDir, $aiCoreBin, $aiCoreRules, $aiCoreDocs)) {
  if (-not (Test-Path $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
}

# 2. Deploy Rules, Automation Scripts and VERSION into .ai-core (always refreshed).
#    The rules are one file per section in setup-ai-core and one assembled file in the checkout,
#    each section headed by a comment that names its source.
$coreVersion = (Get-Content (Join-Path $coreRoot "VERSION") -Raw).Trim()
$assembled = New-Object System.Text.StringBuilder
Get-ChildItem -Path (Join-Path $coreRoot "rules") -File | Where-Object { $_.Name -match "^[0-9][0-9]-.*\.md$" } | Sort-Object Name | ForEach-Object {
  [void]$assembled.Append("<!-- setup-ai-core ${coreVersion}: rules/$($_.Name) -->`n")
  [void]$assembled.Append((Get-Content $_.FullName -Raw).Replace("`r`n", "`n").TrimEnd() + "`n`n")
}
[System.IO.File]::WriteAllText((Join-Path $aiCoreRules "rules.md"), $assembled.ToString(), (New-Object System.Text.UTF8Encoding $false))
Copy-Item -Force (Join-Path $coreRoot "rules\skills.md") (Join-Path $aiCoreRules "skills.md")
# init itself is not deployed: run from the target it would treat .ai-core as its source
foreach ($s in @("session-start", "solution-path", "rules-check", "install-skills", "graft-setup")) {
  Copy-Item -Force (Join-Path $coreRoot "bin\$s.sh") (Join-Path $aiCoreBin "$s.sh")
  Copy-Item -Force (Join-Path $coreRoot "bin\$s.ps1") (Join-Path $aiCoreBin "$s.ps1")
}
Copy-Item -Force (Join-Path $coreRoot "VERSION") (Join-Path $aiCoreDir "VERSION")

# 3. Deploy bridge files, created once and never overwritten: templates\ mirrors the target layout
$templates = Join-Path $coreRoot "templates"
Get-ChildItem -Path $templates -Recurse -File -Force | ForEach-Object {
  $rel = $_.FullName.Substring($templates.Length + 1)
  $dst = Join-Path $target $rel
  if (-not (Test-Path $dst)) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
    Copy-Item $_.FullName $dst
    Write-Host "--> Created $($rel.Replace('\', '/'))"
  } else {
    Write-Host "--> Kept $($rel.Replace('\', '/')) (already present)"
  }
}
# The Claude Code helpers are harness code and are always refreshed
Copy-Item -Force (Join-Path $templates ".claude\helpers\*.cjs") (Join-Path $target ".claude\helpers")

# 4. Keep the harness out of the repository's history: every deployed path goes into the
#    clone's own exclude file, which no commit ever contains. Worktrees share it.
Push-Location $target
try {
  $exclude = $null
  try { $exclude = git rev-parse --git-path info/exclude 2>$null; if ($LASTEXITCODE -ne 0) { $exclude = $null } } catch { $exclude = $null }
  if ($exclude) {
    if (-not [System.IO.Path]::IsPathRooted($exclude)) { $exclude = Join-Path $target $exclude }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $exclude) | Out-Null
    $kept = @(); $skip = $false
    if (Test-Path $exclude) {
      foreach ($line in [System.IO.File]::ReadAllLines($exclude)) {
        if ($line -like '# setup-ai-core start*') { $skip = $true }
        if (-not $skip) { $kept += $line }
        if ($line -like '# setup-ai-core end*') { $skip = $false }
      }
    }
    $block = @('# setup-ai-core start: the harness lives in the working tree only, never in a commit', '/.ai-core/', '/graft/')
    $block += Get-ChildItem -Path $templates -Recurse -File -Force | ForEach-Object { '/' + $_.FullName.Substring($templates.Length + 1).Replace('\', '/') }
    $block += '# setup-ai-core end'
    [System.IO.File]::WriteAllText($exclude, (($kept + $block) -join "`n") + "`n")
    Write-Host "--> Registered the harness in ${exclude}: nothing to commit"
  } else {
    Write-Host "note: $target is not a git repository; nothing to exclude"
  }
} finally {
  Pop-Location
}

# 5. Skills pointer and the Graft code graph. Graft is built with the local Node.js or the
#    whole init fails; there is no fallback.
Write-Host "--> Installing / verifying agent skills..."
Push-Location $target; try { & pwsh -NoProfile -File (Join-Path $aiCoreBin "install-skills.ps1") } finally { Pop-Location }

Write-Host "--> Setting up Graft code intelligence..."
& pwsh -NoProfile -File (Join-Path $aiCoreBin "graft-setup.ps1") -TargetDir $target
$graftExit = $LASTEXITCODE

if ($srcTmp) { Remove-Item -Recurse -Force $srcTmp }

if ($graftExit -ne 0) {
  Write-Host "error: the harness files are in place but the Graft code graph is not (see above). Fix the cause and run 'pwsh -File .ai-core/bin/graft-setup.ps1', or set GRAFT_EXECUTION_MODE=`"skip`" in .ai-core/config.env." -ForegroundColor Red
  exit 1
}

Write-Host "==================================================" -ForegroundColor Green
Write-Host "✓ Agnostic AI Core Harness successfully initialized!" -ForegroundColor Green
Write-Host "Supported Agents: Claude Code, OpenHands, Codex, Antigravity, Cursor, Windsurf, Aider" -ForegroundColor Green
Write-Host "Run 'pwsh -File .ai-core/bin/session-start.ps1' to verify." -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Green
