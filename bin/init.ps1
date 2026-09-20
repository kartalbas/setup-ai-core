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

if ($Help -or $args -ccontains "-h" -or $args -ccontains "--help" -or $TargetDir -ceq "--help" -or $TargetDir -ceq "-h") {
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
Import-Module (Join-Path $coreRoot 'lib\Layers.psm1') -Force

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

# The project harness: <org>/<prefix>-ai-core from the checkout's origin, its extends chain
# base first, cloned or pulled to ~\.<name>-ai-core, created from the skeleton when missing.
# A project folder gets the layers every repository under it shares.
$layers = @(); $repoName = ""
function Get-ChainOf([string]$checkout) {
  # the layer directories, base first, or an empty list; a harness checkout is refused
  $parts = Get-OriginParts $checkout
  if (-not $parts) { return @() }
  if ($parts[1] -ceq 'setup-ai-core') { return @() }
  if ($parts[1].EndsWith('-ai-core', [StringComparison]::Ordinal)) { throw "REFUSED: $checkout is a harness repository; init is for the repositories it serves" }
  $prefix = Get-HarnessOf $parts[1]
  if (-not $prefix) { return @() }
  try { return @(Resolve-LayerChain -Full "$($parts[0])/$prefix-ai-core" -Root $coreRoot -Create) }
  catch { Write-Host "error: $($_.Exception.Message)" -ForegroundColor Yellow; return @() }
}
if ($projectFolder) {
  $first = $true
  foreach ($d in (Get-ChildItem -Path $target -Directory | Where-Object { Test-Path (Join-Path $_.FullName ".git") })) {
    $chain = @(); try { $chain = @(Get-ChainOf $d.FullName) } catch { $chain = @() }
    if ($first) { $layers = $chain; $first = $false; continue }
    $common = @()
    for ($i = 0; $i -lt [Math]::Min($layers.Count, $chain.Count); $i++) { if ($layers[$i] -ceq $chain[$i]) { $common += $layers[$i] } else { break } }
    $layers = $common
    if ($layers.Count -eq 0) { break }
  }
} else {
  $parts = Get-OriginParts $target; if ($parts) { $repoName = $parts[1] }
  try { $layers = @(Get-ChainOf $target) } catch { Write-Host "error: $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
}
if ($layers.Count -gt 0) {
  foreach ($l in $layers) {
    $o = "$(& git -C $l remote get-url origin 2>$null)" -creplace '.*github\.com[:/]', '' -creplace '\.git$', ''
    Write-Host "--> Project harness: $o ($(& git -C $l rev-parse --short HEAD 2>$null)) at $l"
  }
} elseif (-not $projectFolder) {
  Write-Host "--> No project harness: this checkout has no GitHub origin, or the harness could not be had; the generic harness only"
}

$aiCoreDir = Join-Path $target ".ai-core"
$aiCoreRules = Join-Path $aiCoreDir "rules"
foreach ($dir in @($aiCoreRules, (Join-Path $aiCoreDir "docs"))) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
# Earlier versions copied the scripts into the checkout, and one wrote an MCP file Antigravity
# never reads; both are removed
if (Test-Path (Join-Path $aiCoreDir "bin")) { Remove-Item -Recurse -Force (Join-Path $aiCoreDir "bin") }
if (Test-Path (Join-Path $target ".agents\mcp_config.json")) { Remove-Item -Force (Join-Path $target ".agents\mcp_config.json") }

# 1. Managed files, refreshed on every run, later layer wins: the rules, one file per section in
#    setup-ai-core and in every layer (the same name replaces, a new name adds), assembled into one
#    file, each section headed by a comment naming its source; skills.md; VERSION; the skills of
#    every layer into both skill directories; the docs of every layer; the data files; every file
#    under repos\<repo>\ of the layers; STAMP with the commit of every layer.
$coreVersion = (Get-Content (Join-Path $coreRoot "VERSION") -Raw).Trim()
$utf8 = New-Object System.Text.UTF8Encoding $false
$sections = @{}   # name -> @{ Path; Source }
Get-ChildItem -Path (Join-Path $coreRoot "rules") -File | Where-Object { $_.Name -cmatch "^[0-9][0-9]-.*\.md$" } | ForEach-Object { $sections[$_.Name] = @{ Path = $_.FullName; Source = "setup-ai-core $coreVersion" } }
$skillsMd = Join-Path $coreRoot "rules\skills.md"
$coreCommit = "$(& git -C $coreRoot rev-parse --short HEAD 2>$null)".Trim(); if (-not $coreCommit) { $coreCommit = $coreVersion }
$stamp = @("setup-ai-core $coreCommit")
$layerFiles = @()   # what the layers wrote, so the templates leave it alone
$dataFiles = @('config.env', 'labels.tsv', 'assignees.tsv', 'team-modes.tsv')
foreach ($l in $layers) {
  $lname = (Split-Path -Leaf $l).TrimStart('.')
  $lcommit = "$(& git -C $l rev-parse --short HEAD 2>$null)".Trim(); if (-not $lcommit) { $lcommit = '-' }
  $stamp += "$lname $lcommit"
  if (Test-Path (Join-Path $l 'rules')) {
    Get-ChildItem -Path (Join-Path $l 'rules') -File | Where-Object { $_.Name -cmatch "^[0-9][0-9]-.*\.md$" } | ForEach-Object { $sections[$_.Name] = @{ Path = $_.FullName; Source = "$lname $lcommit" } }
  }
  if (Test-Path (Join-Path $l 'rules\skills.md')) { $skillsMd = Join-Path $l 'rules\skills.md' }
  if (Test-Path (Join-Path $l 'skills')) {
    foreach ($s in (Get-ChildItem -Path (Join-Path $l 'skills') -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'SKILL.md') })) {
      foreach ($dst in @((Join-Path $target ".claude\skills\$($s.Name)"), (Join-Path $target ".agents\skills\$($s.Name)"))) {
        if (Test-Path $dst) { Remove-Item -Recurse -Force $dst }
        New-Item -ItemType Directory -Force -Path $dst | Out-Null
        Copy-Item -Recurse -Force (Join-Path $s.FullName '*') $dst
      }
      $layerFiles += @(".claude\skills\$($s.Name)", ".agents\skills\$($s.Name)")
    }
  }
  if (Test-Path (Join-Path $l 'agents')) {
    foreach ($a in (Get-ChildItem -Path (Join-Path $l 'agents') -File -Filter '*.md')) {
      New-Item -ItemType Directory -Force -Path (Join-Path $target '.claude\agents') | Out-Null
      Copy-Item -Force $a.FullName (Join-Path $target ".claude\agents\$($a.Name)"); $layerFiles += ".claude\agents\$($a.Name)"
    }
  }
  if ((Test-Path (Join-Path $l 'docs')) -and (Get-ChildItem -Path (Join-Path $l 'docs') -Force | Select-Object -First 1)) {
    $dd = Join-Path $aiCoreDir "docs\$lname"
    if (Test-Path $dd) { Remove-Item -Recurse -Force $dd }
    New-Item -ItemType Directory -Force -Path $dd | Out-Null
    Copy-Item -Recurse -Force (Join-Path $l 'docs\*') $dd
  }
  foreach ($f in $dataFiles) {
    if (Test-Path (Join-Path $l $f)) { Copy-Item -Force (Join-Path $l $f) (Join-Path $aiCoreDir $f); $layerFiles += ".ai-core\$f" }
  }
}
# repos\<repo>\ of the innermost layer, in the layout of the checkout; a tracked file is never overwritten
if ($layers.Count -gt 0 -and $repoName -and (Test-Path (Join-Path $layers[-1] "repos\$repoName"))) {
  $inner = Join-Path $layers[-1] "repos\$repoName"
  foreach ($f in (Get-ChildItem -Path $inner -Recurse -File -Force)) {
    $rel = $f.FullName.Substring($inner.Length + 1)
    & git -C $target ls-files --error-unmatch ($rel.Replace('\', '/')) 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host "--> Kept $($rel.Replace('\', '/')) (tracked by the repository; repos/$repoName/$($rel.Replace('\', '/')) is not applied)"; $layerFiles += $rel; continue }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent (Join-Path $target $rel)) | Out-Null
    Copy-Item -Force $f.FullName (Join-Path $target $rel)
    $layerFiles += $rel
  }
  Write-Host "--> Applied repos/$repoName/ of $((Split-Path -Leaf $layers[-1]).TrimStart('.'))"
}
$assembled = New-Object System.Text.StringBuilder
foreach ($name in ($sections.Keys | Sort-Object)) {
  [void]$assembled.Append("<!-- $($sections[$name].Source): rules/$name -->`n")
  [void]$assembled.Append((Get-Content $sections[$name].Path -Raw).Replace("`r`n", "`n").TrimEnd() + "`n`n")
}
[System.IO.File]::WriteAllText((Join-Path $aiCoreRules "rules.md"), $assembled.ToString(), $utf8)
Copy-Item -Force $skillsMd (Join-Path $aiCoreRules "skills.md")
Copy-Item -Force (Join-Path $coreRoot "VERSION") (Join-Path $aiCoreDir "VERSION")
[System.IO.File]::WriteAllText((Join-Path $aiCoreDir "STAMP"), (($stamp -join "`n") + "`n"), $utf8)

# 2. The agent files, created once and never overwritten: templates\ mirrors the target layout.
#    A project folder's AGENTS.md is generated instead: the list of its repositories, rewritten
#    on every run because the folder changes. The pointer file of an agent the project does not
#    serve (AGENTS in .ai-core\config.env, or the template's default before the file exists) is
#    not deployed.
$templates = Join-Path $coreRoot "templates"
$config = Join-Path $aiCoreDir "config.env"; if (-not (Test-Path $config)) { $config = Join-Path $templates ".ai-core\config.env" }
$agentsLine = Get-Content $config | Where-Object { $_ -cmatch '^\s*AGENTS\s*=' } | Select-Object -Last 1
$agents = if ($agentsLine) { ((($agentsLine -split '=', 2)[1] -split '#', 2)[0]).Trim(' ', "`t", "`r", '"', "'").ToLowerInvariant() } else { "" }
$served = @($agents -split '\s+' | Where-Object { $_ })
function Test-Serves([string]$agent) { return ($served.Count -eq 0 -or ($served -ccontains $agent)) }
$pointerOf = @{ '.cursorrules' = 'cursor'; '.windsurfrules' = 'windsurf'; '.github\copilot-instructions.md' = 'copilot'; '.openhands\microagents\repo-rules.md' = 'openhands'; '.codex\config.toml' = 'codex' }
Get-ChildItem -Path $templates -Recurse -File -Force | ForEach-Object {
  $rel = $_.FullName.Substring($templates.Length + 1)
  if ($projectFolder -and $rel -ceq "AGENTS.md") { return }
  if ($layerFiles -ccontains $rel) { return }
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
        if ($line -clike '# setup-ai-core start*') { $skip = $true }
        if (-not $skip) { $kept += $line }
        if ($line -clike '# setup-ai-core end*') { $skip = $false }
      }
    }
    $block = @('# setup-ai-core start: the harness lives in the working tree only, never in a commit', '/.ai-core/', '/.claude/skills/', '/.claude/agents/', '/.agents/')
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

# 3b. The project's .gitignore carries a block naming every file an agent or the harness puts
#     into a checkout (lib\gitignore-block), so no clone of this repository commits one, with or
#     without the harness. The block is rewritten between its markers and the rest of the file is
#     the project's. A changed .gitignore is the one thing init leaves for a commit.
if ($inWorkTree) {
  $gi = Join-Path $target ".gitignore"
  $kept = @(); $skip = $false
  if (Test-Path $gi) {
    foreach ($line in [System.IO.File]::ReadAllLines($gi)) {
      if ($line -clike '# setup-ai-core start*') { $skip = $true }
      if (-not $skip) { $kept += $line }
      if ($line -clike '# setup-ai-core end*') { $skip = $false }
    }
  }
  # A path the project already ignores, with or without the slashes, is not written twice; when it
  # ignores them all, no block is written
  $seen = @{}; foreach ($line in $kept) { if ($line -and -not $line.StartsWith('#', [StringComparison]::Ordinal)) { $seen[$line.Trim().Trim('/')] = $true } }
  $markers = @(); $missing = @()
  foreach ($line in [System.IO.File]::ReadAllLines((Join-Path $coreRoot "lib\gitignore-block"))) {
    if ($line.StartsWith('#', [StringComparison]::Ordinal)) { $markers += $line; continue }
    if (-not $seen.ContainsKey($line.Trim().Trim('/'))) { $missing += $line }
  }
  $block = if ($missing.Count -gt 0) { @($markers[0]) + $missing + @($markers[1]) } else { @() }
  $wanted = (($kept + $block) -join "`n") + "`n"
  $current = if (Test-Path $gi) { [System.IO.File]::ReadAllText($gi).Replace("`r`n", "`n") } else { $null }
  if ($current -cne $wanted) {
    [System.IO.File]::WriteAllText($gi, $wanted, $utf8)
    Write-Host "--> .gitignore: the agent files of this repository are ignored; commit .gitignore once"
  }
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
