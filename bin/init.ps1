# Install or refresh the harness in a checkout, in a project folder, or in every repository
# under a folder. The scripts stay in the setup-ai-core clone and run as `ai-core <command>`;
# a checkout receives only data: the assembled rules, the configuration and the agent files.
#
#   init.ps1 [-TargetDir <path>] [-All <folder>] [-NoDoctor]
#
[CmdletBinding()]
param (
  [switch]$Help,
  [string]$TargetDir = ".",
  [string]$All = "",
  [switch]$NoDoctor
)

if ($Help -or $args -contains "-h" -or $args -contains "--help" -or $TargetDir -eq "--help" -or $TargetDir -eq "-h") {
  Write-Host "Usage: init.ps1 [-TargetDir <path>] [-All <folder>] [-NoDoctor]"
  Write-Host ""
  Write-Host "Installs or refreshes the harness in TargetDir (default: the current directory):"
  Write-Host "the assembled rules and the configuration in .ai-core\, the agent files (AGENTS.md,"
  Write-Host ".claude\settings.json, ...) created once, everything registered in .git\info\exclude,"
  Write-Host "and the Graft code graph. A folder that is no repository but holds repositories is a"
  Write-Host "project folder: it gets an AGENTS.md that lists them."
  Write-Host ""
  Write-Host "Options:"
  Write-Host "  -TargetDir <path>   Target directory (default: current)"
  Write-Host "  -All <folder>       Init the folder itself and every git repository directly under it"
  Write-Host "  -NoDoctor           Do not run doctor first"
  Write-Host "  -Help               Show this help message"
  Write-Host ""
  Write-Host "Examples:"
  Write-Host "  ai-core init"
  Write-Host "  ai-core init -TargetDir ../my-project"
  Write-Host "  ai-core init -All ../my-org"
  exit 0
}

$ErrorActionPreference = 'Stop'

$coreRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not ((Test-Path (Join-Path $coreRoot "templates")) -and (Test-Path (Join-Path $coreRoot "VERSION")))) {
  Write-Host "error: $coreRoot is not a clone of setup-ai-core; run init from the clone (ai-core init)" -ForegroundColor Red; exit 1
}

# The prerequisites first; nothing is deployed on a machine that cannot run the harness
if (-not $NoDoctor) {
  & pwsh -NoProfile -File (Join-Path $coreRoot "bin\doctor.ps1")
  if ($LASTEXITCODE -ne 0) { Write-Host "error: fix the problems doctor reported, then run init again (or pass -NoDoctor)." -ForegroundColor Red; exit 1 }
}

# -All: every git repository directly under the folder, then the folder itself
if ($All) {
  $allDir = (Resolve-Path $All).Path
  $ok = 0; $failed = @()
  foreach ($repo in Get-ChildItem -Path $allDir -Directory | Where-Object { Test-Path (Join-Path $_.FullName ".git") }) {
    Write-Host ""; Write-Host "### $($repo.Name)"
    & pwsh -NoProfile -File $MyInvocation.MyCommand.Path -TargetDir $repo.FullName -NoDoctor
    if ($LASTEXITCODE -eq 0) { $ok++ } else { $failed += $repo.Name }
  }
  Write-Host ""; Write-Host "### $(Split-Path -Leaf $allDir) (the folder itself)"
  & pwsh -NoProfile -File $MyInvocation.MyCommand.Path -TargetDir $allDir -NoDoctor
  if ($LASTEXITCODE -ne 0) { $failed += "$(Split-Path -Leaf $allDir)/" }
  Write-Host ""; Write-Host "==> init -All: $ok repositories initialized$(if ($failed) { '; failed: ' + ($failed -join ' ') })"
  if ($failed) { exit 1 } else { exit 0 }
}

$target = (Resolve-Path $TargetDir).Path

# A project folder is no git work tree and holds git checkouts directly below it
$projectFolder = $false
$inWorkTree = $false
try { & git -C $target rev-parse --is-inside-work-tree 2>$null | Out-Null; $inWorkTree = ($LASTEXITCODE -eq 0) } catch { $inWorkTree = $false }
if (-not $inWorkTree) {
  $projectFolder = [bool](Get-ChildItem -Path $target -Directory | Where-Object { Test-Path (Join-Path $_.FullName ".git") } | Select-Object -First 1)
}

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "Initializing the harness in: $target" -ForegroundColor Cyan
if ($projectFolder) { Write-Host "A project folder: the repositories below it get their own init" -ForegroundColor Cyan }
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "--> From $coreRoot"

$aiCoreDir = Join-Path $target ".ai-core"
$aiCoreRules = Join-Path $aiCoreDir "rules"
foreach ($dir in @($aiCoreRules, (Join-Path $aiCoreDir "docs"))) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
# Earlier versions copied the scripts into the checkout; they run from the clone now
if (Test-Path (Join-Path $aiCoreDir "bin")) { Remove-Item -Recurse -Force (Join-Path $aiCoreDir "bin") }

# 1. Managed files, refreshed on every run: the rules, one file per section in setup-ai-core and
#    one assembled file in the checkout, each section headed by a comment naming its source; the
#    skills pointer; VERSION.
$coreVersion = (Get-Content (Join-Path $coreRoot "VERSION") -Raw).Trim()
$assembled = New-Object System.Text.StringBuilder
Get-ChildItem -Path (Join-Path $coreRoot "rules") -File | Where-Object { $_.Name -match "^[0-9][0-9]-.*\.md$" } | Sort-Object Name | ForEach-Object {
  [void]$assembled.Append("<!-- setup-ai-core ${coreVersion}: rules/$($_.Name) -->`n")
  [void]$assembled.Append((Get-Content $_.FullName -Raw).Replace("`r`n", "`n").TrimEnd() + "`n`n")
}
$utf8 = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText((Join-Path $aiCoreRules "rules.md"), $assembled.ToString(), $utf8)
Copy-Item -Force (Join-Path $coreRoot "rules\skills.md") (Join-Path $aiCoreRules "skills.md")
Copy-Item -Force (Join-Path $coreRoot "VERSION") (Join-Path $aiCoreDir "VERSION")

# 2. The agent files, created once and never overwritten: templates\ mirrors the target layout.
#    A project folder's AGENTS.md is generated instead: the list of its repositories, rewritten
#    on every run because the folder changes. The pointer file of an agent the project does not
#    serve (AGENTS in .ai-core\config.env, or the template's default before the file exists) is
#    not deployed.
$templates = Join-Path $coreRoot "templates"
$config = Join-Path $aiCoreDir "config.env"; if (-not (Test-Path $config)) { $config = Join-Path $templates ".ai-core\config.env" }
$agentsLine = Get-Content $config | Where-Object { $_ -match '^\s*AGENTS\s*=' } | Select-Object -Last 1
$agents = if ($agentsLine) { ((($agentsLine -split '=', 2)[1] -split '#', 2)[0]).Trim(' ', "`t", "`r", '"', "'").ToLowerInvariant() } else { "" }
$served = @($agents -split '\s+' | Where-Object { $_ })
function Test-Serves([string]$agent) { return ($served.Count -eq 0 -or ($served -ccontains $agent)) }
$pointerOf = @{ '.cursorrules' = 'cursor'; '.windsurfrules' = 'windsurf'; '.github\copilot-instructions.md' = 'copilot'; '.openhands\microagents\repo-rules.md' = 'openhands' }
Get-ChildItem -Path $templates -Recurse -File -Force | ForEach-Object {
  $rel = $_.FullName.Substring($templates.Length + 1)
  if ($projectFolder -and $rel -ceq "AGENTS.md") { return }
  if ($pointerOf.ContainsKey($rel) -and -not (Test-Serves $pointerOf[$rel])) { return }
  $dst = Join-Path $target $rel
  if (-not (Test-Path $dst)) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
    Copy-Item $_.FullName $dst
    Write-Host "--> Created $($rel.Replace('\', '/'))"
  } else {
    Write-Host "--> Kept $($rel.Replace('\', '/')) (already present)"
  }
}
if ($projectFolder) {
  $map = New-Object System.Text.StringBuilder
  [void]$map.Append("<!-- setup-ai-core ${coreVersion}: written by init for a project folder, rewritten on every run; put your own notes into .ai-core/rules/rules.local.md -->`n")
  [void]$map.Append("# $(Split-Path -Leaf $target)`n`n")
  [void]$map.Append("This folder holds git repositories. Each one carries its own map; read ``<repository>/AGENTS.md`` before you work in it, and run ``ai-core session-start`` inside it before the first action.`n`n")
  [void]$map.Append("| repository | map |`n| :--- | :--- |`n")
  Get-ChildItem -Path $target -Directory | Where-Object { Test-Path (Join-Path $_.FullName ".git") } | ForEach-Object {
    [void]$map.Append("| ``$($_.Name)`` | ``$($_.Name)/AGENTS.md`` |`n")
  }
  [void]$map.Append("`nThe rules that bind every repository here: ``.ai-core/rules/rules.md`` (managed by the harness) and ``.ai-core/rules/rules.local.md`` (this project's own, which wins).`n")
  [System.IO.File]::WriteAllText((Join-Path $target "AGENTS.md"), $map.ToString(), $utf8)
  Write-Host "--> Wrote AGENTS.md (the repositories of this folder)"
}

# 3. Keep the harness out of the repository's history: every deployed path goes into the
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
    $block = @('# setup-ai-core start: the harness lives in the working tree only, never in a commit', '/.ai-core/')
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

# 4. The Graft code graph, built with the local Node.js or the whole init fails; no fallback.
Write-Host "--> Graft"
& pwsh -NoProfile -File (Join-Path $coreRoot "bin\graft-setup.ps1") -TargetDir $target
if ($LASTEXITCODE -ne 0) {
  Write-Host "error: the harness files are in place but the Graft code graph is not (see above). Fix the cause and run 'ai-core graft', or set GRAFT_EXECUTION_MODE=`"skip`" in .ai-core/config.env." -ForegroundColor Red
  exit 1
}

Write-Host "==================================================" -ForegroundColor Green
Write-Host "✓ Harness $coreVersion in place. Run 'ai-core session-start' here to verify." -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Green
