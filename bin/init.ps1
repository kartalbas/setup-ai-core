# Install or refresh the harness in a checkout, in a project folder, or in every repository
# under a folder. The scripts stay in the setup-ai-core clone and run as `ai-core <command>`;
# a checkout receives only data: the assembled rules, the configuration and the agent files.
# Every file it touches is recorded and reported at the end; -DryRun reports without writing.
#
#   init.ps1 [-TargetDir <path>] [-All <folder>] [-NoDoctor] [-DryRun]
#
[CmdletBinding()]
param (
  [switch]$Help,
  [string]$TargetDir = ".",
  [string]$All = "",
  [switch]$NoDoctor,
  [switch]$DryRun
)

if ($Help -or $args -ccontains "-h" -or $args -ccontains "--help" -or $TargetDir -ceq "--help" -or $TargetDir -ceq "-h") {
  Write-Host "Usage: init.ps1 [-TargetDir <path>] [-All <folder>] [-NoDoctor] [-DryRun]"
  Write-Host ""
  Write-Host "Installs or refreshes the harness in TargetDir (default: the current directory):"
  Write-Host "the assembled rules and the configuration in .ai-core\, the agent files (AGENTS.md,"
  Write-Host ".claude\settings.json, ...) created once, everything registered in .git\info\exclude and"
  Write-Host "in a block of .gitignore, and the Graft code graph. A folder that is no repository but"
  Write-Host "holds repositories is a project folder: it gets an AGENTS.md that lists them. The run ends"
  Write-Host "with what it created, refreshed, kept and removed, and what Graft wrote on the machine."
  Write-Host ""
  Write-Host "Options:"
  Write-Host "  -TargetDir <path>   Target directory (default: current)"
  Write-Host "  -All <folder>       Init the folder itself, then every git repository directly under it and every"
  Write-Host "                      worktree under its .worktrees\, then the folder's Graft workspace over them"
  Write-Host "  -NoDoctor           Do not run doctor first"
  Write-Host "  -DryRun             Report what the run would create, refresh, keep and remove; write nothing"
  Write-Host "  -Help               Show this help message"
  Write-Host ""
  Write-Host "Examples:"
  Write-Host "  ai-core init"
  Write-Host "  ai-core init -TargetDir ../my-project -DryRun"
  Write-Host "  ai-core init -All ../my-org"
  exit 0
}

$ErrorActionPreference = 'Stop'

$coreRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not ((Test-Path (Join-Path $coreRoot "templates")) -and (Test-Path (Join-Path $coreRoot "VERSION")))) {
  Write-Host "error: $coreRoot is not a clone of setup-ai-core; run init from the clone (ai-core init)" -ForegroundColor Red; exit 1
}
Import-Module (Join-Path $coreRoot 'lib\Layers.psm1') -Force

# The prerequisites first; nothing is deployed on a machine that cannot run the harness. A dry
# run installs nothing either. Doctor runs in the folder init serves, so it sees what the
# repositories of that project folder need (gitleaks, where one carries .gitleaks.toml).
if (-not $NoDoctor) {
  $doctorArgs = @(); if ($DryRun) { $doctorArgs += '-NoInstall' }
  $doctorIn = if ($All) { $All } else { $TargetDir }
  $doctorIn = if (Test-Path -LiteralPath $doctorIn -PathType Container) { (Resolve-Path -LiteralPath $doctorIn).Path } else { (Get-Location).Path }
  & pwsh -NoProfile -WorkingDirectory $doctorIn -File (Join-Path $coreRoot "bin\doctor.ps1") @doctorArgs
  if ($LASTEXITCODE -ne 0) { Write-Host "error: fix the problems doctor reported, then run init again (or pass -NoDoctor)." -ForegroundColor Red; exit 1 }
}

# -All: the folder itself first, as a repository compares its rules with the folder's (1a), then
# every git repository directly under it, every worktree `ai-core start-issue` put under its
# .worktrees\<repository>\, then the folder's Graft workspace: Graft wires every repository below
# the folder, and an AGENTS.md it wrote before init would be kept as the repository's own
if ($All) {
  $allDir = (Resolve-Path $All).Path
  $ok = 0; $failed = @(); $folderOk = $true
  $pass = @('-NoDoctor'); if ($DryRun) { $pass += '-DryRun' }
  Write-Host ""; Write-Host "### $(Split-Path -Leaf $allDir) (the folder itself)"
  $env:AI_CORE_GRAFT_LATER = '1'
  & pwsh -NoProfile -File $MyInvocation.MyCommand.Path -TargetDir $allDir @pass
  if ($LASTEXITCODE -ne 0) { $folderOk = $false }
  Remove-Item Env:AI_CORE_GRAFT_LATER
  # Worktrees whose work landed a day ago or more go first (finish-issue -Sweep): a rollout frees
  # what nobody finished, and does not init a worktree that is about to go
  foreach ($r in @(Get-ChildItem -LiteralPath $allDir -Directory | Where-Object { $_.Name -cnotlike '*-ai-core' -and (Test-Path (Join-Path $_.FullName '.git')) })) {
    $trees = @(& git -C $r.FullName worktree list --porcelain 2>$null | Where-Object { "$_".StartsWith('worktree ', [StringComparison]::Ordinal) })
    if ($trees.Count -le 1) { continue }
    Write-Host ""; Write-Host "### $($r.Name): worktrees whose work landed"
    $sweepArgs = @('-Sweep'); if ($DryRun) { $sweepArgs += '-DryRun' }
    Push-Location $r.FullName
    try { & pwsh -NoProfile -File (Join-Path $coreRoot 'bin/finish-issue.ps1') @sweepArgs 2>&1 | ForEach-Object { Write-Host "  $_" } } finally { Pop-Location }
  }
  $checkouts = @(Get-ChildItem -LiteralPath $allDir -Directory | ForEach-Object { [pscustomobject]@{ Name = $_.Name; RepoFolder = $_.Name; Path = $_.FullName } })
  $worktrees = Join-Path $allDir '.worktrees'
  if (Test-Path -LiteralPath $worktrees) {
    foreach ($r in Get-ChildItem -LiteralPath $worktrees -Directory) {
      $checkouts += @(Get-ChildItem -LiteralPath $r.FullName -Directory | ForEach-Object { [pscustomobject]@{ Name = ".worktrees/$($r.Name)/$($_.Name)"; RepoFolder = $r.Name; Path = $_.FullName } })
    }
  }
  # a harness clone serves the repositories; it is not one of them, and neither is a worktree of one
  foreach ($repo in $checkouts | Where-Object { $_.RepoFolder -cnotlike '*-ai-core' -and (Test-Path (Join-Path $_.Path ".git")) }) {
    Write-Host ""; Write-Host "### $($repo.Name)"
    & pwsh -NoProfile -File $MyInvocation.MyCommand.Path -TargetDir $repo.Path @pass
    if ($LASTEXITCODE -eq 0) { $ok++ } else { $failed += $repo.Name }
  }
  Write-Host ""; Write-Host "### $(Split-Path -Leaf $allDir) (the folder itself): the Graft workspace over its repositories"
  $graftArgs = @(); if ($DryRun) { $graftArgs += '-DryRun' }
  & pwsh -NoProfile -File (Join-Path $coreRoot "bin\graft-setup.ps1") -TargetDir $allDir @graftArgs
  if ($LASTEXITCODE -ne 0) { $folderOk = $false }
  if (-not $folderOk) { $failed += "$(Split-Path -Leaf $allDir)/" }
  Write-Host ""; Write-Host "==> init -All: $ok repositories $(if ($DryRun) { 'would be' } else { 'were' }) initialized$(if ($failed) { '; failed: ' + ($failed -join ' ') })"
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
Write-Host "Initializing the harness in: $target$(if ($DryRun) { ' (dry run: nothing is written)' })" -ForegroundColor Cyan
if ($projectFolder) { Write-Host "A project folder: the repositories below it get their own init" -ForegroundColor Cyan }
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "--> From $coreRoot"

# 0. A linked worktree starts empty, because the harness is in no commit. Before anything else it
#    gets the checkout's own .ai-core data (its configuration, local rules and documents), and the
#    rest of this run assembles the harness over that, as it does in the checkout.
$worktreeDataFrom = ''
if ($inWorkTree -and -not (Test-Path (Join-Path $target '.ai-core'))) {
  $common = "$(& git -C $target rev-parse --path-format=absolute --git-common-dir 2>$null)"
  $gitDir = "$(& git -C $target rev-parse --path-format=absolute --git-dir 2>$null)"
  if ($common -and $common -cne $gitDir -and (Test-Path (Join-Path (Split-Path -Parent $common) '.ai-core'))) {
    $worktreeDataFrom = Split-Path -Parent $common
    if (-not $DryRun) { Copy-Item -Recurse -Path (Join-Path $worktreeDataFrom '.ai-core') -Destination (Join-Path $target '.ai-core') }
  }
}

# --- what this run does to the checkout is recorded here and reported at the end -------------
$report = @{ created = @(); refreshed = @(); kept = @(); removed = @(); tracked = @(); unchanged = 0 }
$utf8 = New-Object System.Text.UTF8Encoding $false
function Add-Note([string]$kind, [string]$label) {
  if ($kind -ceq 'unchanged') { $report.unchanged++ } else { $report[$kind] += $label }
}
function Test-SameFile([string]$a, [string]$b) {
  $x = [System.IO.File]::ReadAllBytes($a); $y = [System.IO.File]::ReadAllBytes($b)
  return ($x.Length -eq $y.Length) -and [System.Linq.Enumerable]::SequenceEqual($x, $y)
}
# The path of a directory as the file system reports it: an 8.3 short form (C:\Users\RUNNER~1)
# resolved to the long one, so a relative path cut from it matches what Get-ChildItem reports
function Get-LongPath([string]$dir) { return (Get-Item -LiteralPath $dir -Force).FullName.TrimEnd('\', '/') }
function Test-SameDir([string]$a, [string]$b) {
  $a = Get-LongPath $a; $b = Get-LongPath $b
  $fa = @(Get-ChildItem -LiteralPath $a -Recurse -File -Force | ForEach-Object { $_.FullName.Substring($a.Length + 1) } | Sort-Object)
  $fb = @(Get-ChildItem -LiteralPath $b -Recurse -File -Force | ForEach-Object { $_.FullName.Substring($b.Length + 1) } | Sort-Object)
  if (($fa -join "`n") -cne ($fb -join "`n")) { return $false }
  foreach ($f in $fa) { if (-not (Test-SameFile (Join-Path $a $f) (Join-Path $b $f))) { return $false } }
  return $true
}
# Put-File <source> <destination> <label> managed|once: one file, written only when it differs.
# A managed file keeps the block Graft appended to the checkout's copy, between its markers.
function Put-File([string]$src, [string]$dst, [string]$label, [string]$mode) {
  if (Test-Path -LiteralPath $dst) {
    if ($mode -ceq 'managed') {
      $block = [regex]::Match([System.IO.File]::ReadAllText($dst), '(?s)(?:^|(?<=\n))<!-- graft:start -->.*?(?:^|\n)<!-- graft:end -->[^\n]*\n?')
      if ($block.Success -and -not [regex]::IsMatch([System.IO.File]::ReadAllText($src), '(?m)^<!-- graft:start -->')) {
        [System.IO.File]::WriteAllText((Join-Path $tmp 'graft-kept'), [System.IO.File]::ReadAllText($src).TrimEnd("`r", "`n") + "`n`n" + $block.Value, $utf8)
        $src = Join-Path $tmp 'graft-kept'
      }
    }
    if (Test-SameFile $src $dst) { Add-Note unchanged $label; return }
    if ($mode -ceq 'once') { Add-Note kept $label; return }
    Add-Note refreshed $label
  } else {
    Add-Note created $label
  }
  if ($DryRun) { return }
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
  Copy-Item -LiteralPath $src -Destination $dst -Force
}
function Put([string]$src, [string]$rel, [string]$mode) { Put-File $src (Join-Path $target $rel) $rel $mode }   # Put <source> <relative path> managed|once
# Put-Dir <source dir> <relative dir>: a managed directory, replaced whole
function Put-Dir([string]$src, [string]$rel) {
  $dst = Join-Path $target $rel
  if (Test-Path -LiteralPath $dst) {
    if (Test-SameDir $src $dst) { Add-Note unchanged "$rel/"; return }
    Add-Note refreshed "$rel/"
  } else {
    Add-Note created "$rel/"
  }
  if ($DryRun) { return }
  if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $dst | Out-Null
  Copy-Item -Path (Join-Path $src '*') -Destination $dst -Recurse -Force
}
# Drop <relative path>: what an earlier version left in the checkout
function Drop([string]$rel) {
  $p = Join-Path $target $rel
  if (-not (Test-Path -LiteralPath $p)) { return }
  Add-Note removed $rel
  if (-not $DryRun) { Remove-Item -LiteralPath $p -Recurse -Force }
}

# The project harness: <org>/<prefix>-ai-core from the checkout's origin, its extends chain
# base first, cloned or pulled beside the repositories in the project folder, created from the
# skeleton when missing. A project folder gets the layers every repository under it shares; the
# harness clones under it serve the repositories and are none of them.
$layers = @(); $repoName = ""
$folder = if ($projectFolder) { $target } else { Get-ProjectFolderOf $target }
function Get-ChainOf([string]$checkout) {
  # the layer directories, base first, or an empty list; a harness checkout is refused
  $parts = Get-OriginParts $checkout
  if (-not $parts) { return @() }
  if ($parts[1] -ceq 'setup-ai-core') { return @() }
  if ($parts[1].EndsWith('-ai-core', [StringComparison]::Ordinal)) { throw "REFUSED: $checkout is a harness repository; init is for the repositories it serves" }
  $prefix = Get-HarnessOf $parts[1]
  if (-not $prefix) { return @() }
  if ($DryRun) {
    # nothing is created on a dry run: a harness that is not there yet is announced instead
    try { return @(Resolve-LayerChain -Full "$($parts[0])/$prefix-ai-core" -Root $coreRoot -Folder $folder -Dry) }
    catch {
      if ("$($_.Exception.Message)" -clike '*does not exist on GitHub*') { $script:wouldCreate = "$($parts[0])/$prefix-ai-core" }
      else { Write-Host "error: $($_.Exception.Message)" -ForegroundColor Yellow }
      return @()
    }
  }
  return @(Resolve-LayerChain -Full "$($parts[0])/$prefix-ai-core" -Root $coreRoot -Folder $folder -Create)
}
$script:wouldCreate = ''
if ($projectFolder) {
  $first = $true
  foreach ($d in (Get-ChildItem -Path $target -Directory | Where-Object { $_.Name -cnotlike '*-ai-core' -and (Test-Path (Join-Path $_.FullName ".git")) })) {
    $chain = @(); try { $chain = @(Get-ChainOf $d.FullName) } catch { $chain = @() }
    if ($first) { $layers = $chain; $first = $false; continue }
    $common = @()
    for ($i = 0; $i -lt [Math]::Min($layers.Count, $chain.Count); $i++) { if ($layers[$i] -ceq $chain[$i]) { $common += $layers[$i] } else { break } }
    $layers = $common
    if ($layers.Count -eq 0) { break }
  }
} else {
  $parts = Get-OriginParts $target; if ($parts) { $repoName = $parts[1] }
  try { $layers = @(Get-ChainOf $target) } catch { Write-Host "error: $($_.Exception.Message); nothing was written" -ForegroundColor Red; exit 1 }
}
if ($layers.Count -gt 0) {
  foreach ($l in $layers) {
    if (-not (Test-Path $l)) { Write-Host "--> Project harness: $(Split-Path -Leaf $l) would be cloned to $l (dry run: not cloned)"; continue }
    $o = "$(& git -C $l remote get-url origin 2>$null)" -creplace '.*github\.com[:/]', '' -creplace '\.git$', ''
    Write-Host "--> Project harness: $o ($(& git -C $l rev-parse --short HEAD 2>$null)) at $l"
  }
} elseif ($script:wouldCreate) {
  Write-Host "--> Project harness: $($script:wouldCreate) would be created from the skeleton, private, and this checkout would get it (dry run: not created)"
} elseif (-not $projectFolder) {
  Write-Host "--> No project harness: this checkout has no GitHub origin; the generic harness only"
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-core-init-" + [System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$aiCoreDir = Join-Path $target ".ai-core"
if (-not $DryRun) { foreach ($dir in @((Join-Path $aiCoreDir 'rules'), (Join-Path $aiCoreDir 'docs'))) { New-Item -ItemType Directory -Force -Path $dir | Out-Null } }
# Earlier versions copied the scripts into the checkout, and one wrote an MCP file Antigravity
# never reads; both are removed
Drop '.ai-core/bin'
Drop '.agents/mcp_config.json'

# 1. Managed files, refreshed on every run, later layer wins: the rules, one file per section in
#    setup-ai-core and in every layer (the same name replaces, a new name adds), assembled into one
#    file, each section headed by a comment naming its source; skills.md; VERSION; the skills of
#    every layer into both skill directories; the agents; the docs of every layer; the data files;
#    every file under repos\<repo>\ of the layers; STAMP with the commit of every layer.
$coreVersion = (Get-Content (Join-Path $coreRoot "VERSION") -Raw).Trim()
$sections = @{}   # name -> @{ Path; Source }
Get-ChildItem -Path (Join-Path $coreRoot "rules") -File | Where-Object { $_.Name -cmatch "^[0-9][0-9]-.*\.md$" } | ForEach-Object { $sections[$_.Name] = @{ Path = $_.FullName; Source = "setup-ai-core $coreVersion" } }
$skillsMd = Join-Path $coreRoot "rules\skills.md"
$coreCommit = "$(& git -C $coreRoot rev-parse --short HEAD 2>$null)".Trim(); if (-not $coreCommit) { $coreCommit = $coreVersion }
$stamp = @("setup-ai-core $coreCommit")
$layerFiles = @()   # what the layers wrote, so the templates leave it alone
$mapSrc = $null     # a generated map, deployed with the binding rules on top once the rules are assembled
$deployed = @()     # what the layers put into the checkout, recorded in .ai-core\DEPLOYED
$dataFiles = @('config.env', 'labels.tsv', 'assignees.tsv', 'team-modes.tsv', 'team.tsv')
# The skills of setup-ai-core itself, before the layers': a layer's skill of the same name replaces
# the directory whole, so the more specific layer wins, as it does for the rules.
if (Test-Path (Join-Path $coreRoot 'skills')) {
  foreach ($s in (Get-ChildItem -Path (Join-Path $coreRoot 'skills') -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'SKILL.md') })) {
    Put-Dir $s.FullName ".claude/skills/$($s.Name)"; Put-Dir $s.FullName ".agents/skills/$($s.Name)"
    $layerFiles += @(".claude/skills/$($s.Name)", ".agents/skills/$($s.Name)"); $deployed += @(".claude/skills/$($s.Name)", ".agents/skills/$($s.Name)")
  }
}
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
      Put-Dir $s.FullName ".claude/skills/$($s.Name)"; Put-Dir $s.FullName ".agents/skills/$($s.Name)"
      $layerFiles += @(".claude/skills/$($s.Name)", ".agents/skills/$($s.Name)"); $deployed += @(".claude/skills/$($s.Name)", ".agents/skills/$($s.Name)")
    }
  }
  if (Test-Path (Join-Path $l 'agents')) {
    foreach ($a in (Get-ChildItem -Path (Join-Path $l 'agents') -File -Filter '*.md' | Where-Object { $_.Name -cne 'README.md' })) {
      Put $a.FullName ".claude/agents/$($a.Name)" managed; $layerFiles += ".claude/agents/$($a.Name)"; $deployed += ".claude/agents/$($a.Name)"
    }
  }
  if ((Test-Path (Join-Path $l 'docs')) -and (Get-ChildItem -Path (Join-Path $l 'docs') -Force | Select-Object -First 1)) {
    Put-Dir (Join-Path $l 'docs') ".ai-core/docs/$lname"; $deployed += ".ai-core/docs/$lname"
  }
  foreach ($f in $dataFiles) {
    if (Test-Path (Join-Path $l $f)) { Put (Join-Path $l $f) ".ai-core/$f" managed; $layerFiles += ".ai-core/$f" }
  }
}
# repos\<repo>\ of the innermost layer, in the layout of the checkout; a tracked file is never overwritten
if ($layers.Count -gt 0 -and $repoName -and (Test-Path (Join-Path $layers[-1] "repos\$repoName"))) {
  $inner = Get-LongPath (Join-Path $layers[-1] "repos\$repoName")
  $relFiles = @(Get-ChildItem -Path $inner -Recurse -File -Force | ForEach-Object { $_.FullName.Substring($inner.Length + 1).Replace('\', '/') })
  [Array]::Sort($relFiles, [StringComparer]::Ordinal)
  foreach ($rel in $relFiles) {
    & git -C $target ls-files --error-unmatch $rel 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Add-Note tracked $rel } else {
      $src = Join-Path $inner $rel
      # A generated map gets the binding rules on top once the rules are assembled (1a below)
      $first = @([System.IO.File]::ReadAllLines($src) | Select-Object -First 1)
      if ($rel -ceq 'AGENTS.md' -and $first.Count -gt 0 -and "$($first[0])".StartsWith('<!-- ai-core map:', [StringComparison]::Ordinal)) { $mapSrc = $src } else { Put $src $rel managed }
      $deployed += $rel
    }
    $layerFiles += $rel
  }
}
# What the layers put into the checkout is recorded in .ai-core\DEPLOYED, so what a layer no
# longer provides is taken out again at the next run; a file the repository tracks is left alone
$prevDeployed = @(); $deployedFile = Join-Path $aiCoreDir 'DEPLOYED'
if (Test-Path -LiteralPath $deployedFile) { $prevDeployed = @(Get-Content $deployedFile | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) }
foreach ($p in $prevDeployed) {
  if ($deployed -ccontains $p) { continue }
  $full = Join-Path $target $p
  if (-not (Test-Path -LiteralPath $full)) { continue }
  & git -C $target ls-files --error-unmatch $p 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) { continue }
  Add-Note removed $p
  if (-not $DryRun) { Remove-Item -LiteralPath $full -Recurse -Force }
}
if ($deployed.Count -gt 0 -or $prevDeployed.Count -gt 0) {
  [System.IO.File]::WriteAllText((Join-Path $tmp 'DEPLOYED'), (($deployed -join "`n") + "`n"), $utf8)
  Put (Join-Path $tmp 'DEPLOYED') '.ai-core/DEPLOYED' managed
}
# A section is written with LF and one blank line after it, whatever the clone it came from
# checked out, so the two twins and two machines assemble the same bytes
$assembled = New-Object System.Text.StringBuilder
foreach ($name in ($sections.Keys | Sort-Object)) {
  [void]$assembled.Append("<!-- $($sections[$name].Source): rules/$name -->`n")
  [void]$assembled.Append((Get-Content $sections[$name].Path -Raw).Replace("`r`n", "`n").TrimEnd() + "`n`n")
}
[System.IO.File]::WriteAllText((Join-Path $tmp 'rules.md'), $assembled.ToString(), $utf8)
Put (Join-Path $tmp 'rules.md') '.ai-core/rules/rules.md' managed
Put $skillsMd '.ai-core/rules/skills.md' managed
Put (Join-Path $coreRoot 'VERSION') '.ai-core/VERSION' managed
[System.IO.File]::WriteAllText((Join-Path $tmp 'STAMP'), (($stamp -join "`n") + "`n"), $utf8)
Put (Join-Path $tmp 'STAMP') '.ai-core/STAMP' managed

# 1a. The binding rules, on top of the map (a generated one, or the generic one of templates\ where
#     the repository has none) and in a project folder's AGENTS.md. Claude Code
#     loads a file an AGENTS.md names after @ at launch, whole, so the rules reach the agent from
#     its first prompt. It also loads the AGENTS.md of every directory above the one it starts in,
#     and a repository's when it works there, so a checkout inside a project folder whose rules
#     are the folder's names them without the @: imported twice, they would be loaded twice.
function Get-EnclosingFolder([string]$dir) {  # the nearest directory above it that init equipped as a project folder
  $d = [System.IO.Path]::GetFullPath($dir)
  while ($true) {
    $up = [System.IO.Path]::GetDirectoryName($d)
    if (-not $up -or $up -ceq $d) { return $null }
    $d = $up
    if ((Test-Path -LiteralPath (Join-Path $d '.ai-core\rules\rules.md') -PathType Leaf) -and -not (Test-Path -LiteralPath (Join-Path $d '.git'))) { return $d }
  }
}
function Test-SameText([string]$a, [string]$b) {  # the same lines, the comment lines aside
  if (-not ((Test-Path -LiteralPath $a -PathType Leaf) -and (Test-Path -LiteralPath $b -PathType Leaf))) { return $false }
  $x = @([System.IO.File]::ReadAllLines($a) | ForEach-Object { $_.TrimEnd("`r") } | Where-Object { -not $_.StartsWith('<!-- ', [StringComparison]::Ordinal) }) -join "`n"
  $y = @([System.IO.File]::ReadAllLines($b) | ForEach-Object { $_.TrimEnd("`r") } | Where-Object { -not $_.StartsWith('<!-- ', [StringComparison]::Ordinal) }) -join "`n"
  return ($x -ceq $y)
}
$importRules = $true; $importSkills = $true; $importLocal = $false
if (-not $projectFolder) {
  $folder = Get-EnclosingFolder $target
  if ($folder) {
    if (Test-SameText (Join-Path $folder '.ai-core\rules\rules.md') (Join-Path $tmp 'rules.md')) { $importRules = $false }
    if (Test-SameText (Join-Path $folder '.ai-core\rules\skills.md') $skillsMd) { $importSkills = $false }
  }
}
$localRules = Join-Path $aiCoreDir 'rules\rules.local.md'
if ((Test-Path -LiteralPath $localRules -PathType Leaf) -and -not (Test-SameText $localRules (Join-Path $coreRoot 'templates\.ai-core\rules\rules.local.md'))) { $importLocal = $true }
function Get-BindingBlock {  # lib\binding-rules.md, each file named after @ where this AGENTS.md is what loads it
  $the = "the same as the project folder's, which its AGENTS.md loads"
  $r = if ($importRules) { '@.ai-core/rules/rules.md' } else { "``.ai-core/rules/rules.md``, $the" }
  $s = if ($importSkills) { '@.ai-core/rules/skills.md' } else { "``.ai-core/rules/skills.md``, $the" }
  $l = if ($importLocal) { '@.ai-core/rules/rules.local.md' } else { '`.ai-core/rules/rules.local.md`, still the template' }
  return @([System.IO.File]::ReadAllLines((Join-Path $coreRoot 'lib\binding-rules.md')) | ForEach-Object { $_.TrimEnd("`r").Replace('{RULES}', $r).Replace('{SKILLS}', $s).Replace('{LOCAL}', $l) })
}
# A repository the harness has no map for gets the generic one the same way, where its AGENTS.md
# is none yet or one init wrote (a map, or the generic file of before 1.3.20); one the repository
# tracks, or somebody's own, is kept
if (-not $mapSrc -and -not $projectFolder -and $layerFiles -cnotcontains 'AGENTS.md') {
  $agentsMd = Join-Path $target 'AGENTS.md'
  & git -C $target ls-files --error-unmatch AGENTS.md 2>$null | Out-Null
  $agentsTracked = ($LASTEXITCODE -eq 0)
  $agentsOurs = -not (Test-Path -LiteralPath $agentsMd -PathType Leaf) -or ("$(@([System.IO.File]::ReadAllLines($agentsMd)) | Select-Object -First 1)" -cmatch '^(<!-- ai-core map:|# AGENTS\.md .* Repository Navigation & Operations)')
  if (-not $agentsOurs) {   # nothing in it outside Graft's block: Graft wires every repository of a project folder, one init has not reached yet among them
    $inGraft = $false; $outside = 0
    foreach ($l in [System.IO.File]::ReadAllLines($agentsMd)) {
      if ($l -cmatch '^<!-- graft:start -->') { $inGraft = $true }
      if (-not $inGraft -and $l.Trim()) { $outside++ }
      if ($l -cmatch '^<!-- graft:end -->') { $inGraft = $false }
    }
    $agentsOurs = ($outside -eq 0)
  }
  if (-not $agentsTracked -and $agentsOurs) { $mapSrc = Join-Path $coreRoot 'templates\AGENTS.md' } else { Add-Note kept 'AGENTS.md' }
}
if ($mapSrc) {
  $ml = @([System.IO.File]::ReadAllLines($mapSrc) | ForEach-Object { $_.TrimEnd("`r") })
  $rest = @($ml | Select-Object -Skip 2); while ($rest.Count -gt 0 -and -not $rest[0].Trim()) { $rest = @($rest | Select-Object -Skip 1) }
  $withContract = @($ml[0], $ml[1], '') + @(Get-BindingBlock) + @('- `ai-core session-start` before any work; below is the map of this repository.', '') + $rest
  [System.IO.File]::WriteAllText((Join-Path $tmp 'AGENTS.map.md'), (($withContract -join "`n") + "`n"), $utf8)
  Put (Join-Path $tmp 'AGENTS.map.md') 'AGENTS.md' managed
}

# 2. The agent files, created once and never overwritten: templates\ mirrors the target layout.
#    AGENTS.md is the map (1a); a project folder's is generated instead: the list of its
#    repositories, rewritten on every run because the folder changes. The file of an agent the project does not serve
#    (AGENTS in .ai-core\config.env, or the template's default before the file exists) is not
#    deployed.
$templates = Get-LongPath (Join-Path $coreRoot "templates")
$config = Join-Path $aiCoreDir "config.env"; if (-not (Test-Path $config)) { $config = Join-Path $templates ".ai-core\config.env" }
$agentsLine = Get-Content $config | Where-Object { $_ -cmatch '^\s*AGENTS\s*=' } | Select-Object -Last 1
$agents = if ($agentsLine) { ((($agentsLine -split '=', 2)[1] -split '#', 2)[0]).Trim(' ', "`t", "`r", '"', "'").ToLowerInvariant() } else { "" }
$served = @($agents -split '\s+' | Where-Object { $_ })
function Test-Serves([string]$agent) { return ($served.Count -eq 0 -or ($served -ccontains $agent)) }
$pointerOf = @{ '.cursorrules' = 'cursor'; '.windsurfrules' = 'windsurf'; '.github/copilot-instructions.md' = 'copilot'; '.openhands/microagents/repo-rules.md' = 'openhands'; '.codex/config.toml' = 'codex' }
# the template files in byte order, the order the bash twin lists them in
$templateFiles = @(Get-ChildItem -Path $templates -Recurse -File -Force | ForEach-Object { $_.FullName.Substring($templates.Length + 1).Replace('\', '/') })
[Array]::Sort($templateFiles, [StringComparer]::Ordinal)
foreach ($rel in $templateFiles) {
  if ($rel -ceq "AGENTS.md") { continue }
  if ($layerFiles -ccontains $rel) { continue }
  if ($pointerOf.ContainsKey($rel) -and -not (Test-Serves $pointerOf[$rel])) { continue }
  if ($rel -ceq '.claude/settings.json' -and (Get-Command jq -ErrorAction SilentlyContinue)) { continue }   # written below, the hook with the full path
  # an opencode.json without the template's instructions (Graft writes one with its MCP server only) gets them added
  $own = Join-Path $target $rel
  if ($rel -ceq 'opencode.json' -and (Get-Command jq -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $own -PathType Leaf)) {
    & jq -e --slurpfile t (Join-Path $templates $rel) '($t[0].instructions - (.instructions // [])) | length == 0' $own 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
      $merged = (& jq --slurpfile t (Join-Path $templates $rel) '.instructions = ((.instructions // []) + ($t[0].instructions - (.instructions // [])))' $own 2>$null | Out-String)
      if ($LASTEXITCODE -eq 0 -and $merged.Trim()) {
        [System.IO.File]::WriteAllText((Join-Path $tmp 'opencode.json'), $merged.Replace("`r`n", "`n"), $utf8)
        Put-File (Join-Path $tmp 'opencode.json') $own $rel managed
      }
      continue
    }
  }
  Put (Join-Path $templates $rel) $rel once
}
# The Claude Code hook that starts the session, the permissions of the template (the ai-core
# commands, and every tool of the Graft MCP server, which only reads the code graph) and its denials
# (the secrets of a checkout and the credentials of the machine are not read, a push is not forced),
# each list read from the template. The hook
# names ai-core by its full path on this machine, so a Claude Code started from a terminal opened
# before the install still runs it; the file is the machine's, never committed. A settings.json the
# checkout had before (created once, never overwritten) gets what it lacks merged in, the way Graft
# merges its hooks, and an ai-core hook of an older form gives way to this one. Without jq the
# template stays as it is.
$aiCoreCmd = (Join-Path $coreRoot 'bin/ai-core').Replace('\', '/')
if ($aiCoreCmd -cmatch '^[a-z]:') { $aiCoreCmd = $aiCoreCmd.Substring(0, 1).ToUpperInvariant() + $aiCoreCmd.Substring(1) }
$hook = "`"$aiCoreCmd`" session-start --tool claude"
$settings = Join-Path $target '.claude\settings.json'
$settingsTemplate = Join-Path $coreRoot 'templates\.claude\settings.json'
# The context at which Claude Code compacts: the project's AUTO_COMPACT_WINDOW, the template's
# where the project's config.env has none
function Get-CompactWindow([string]$File) {
  $line = @(Get-Content -LiteralPath $File -ErrorAction SilentlyContinue | Where-Object { $_ -cmatch '^\s*AUTO_COMPACT_WINDOW\s*=' }) | Select-Object -Last 1
  if ($line) { ((($line -split '=', 2)[1] -split '#', 2)[0]).Trim(' ', "`t", "`r", '"', "'") } else { '' }
}
$compact = Get-CompactWindow $config; if (-not $compact) { $compact = Get-CompactWindow (Join-Path $templates '.ai-core\config.env') }
if ($compact -ceq 'auto') { $compact = '"auto"' }
elseif ($compact -cnotmatch '^[0-9]+\z' -or [long]$compact -lt 100000 -or [long]$compact -gt 1000000) {
  Write-Host "error: AUTO_COMPACT_WINDOW in .ai-core/config.env is a number of tokens from 100000 to 1000000 or `"auto`", not '$compact'" -ForegroundColor Red; exit 1
}
$settingsHas = 'def ours: (.command // "") | test("ai-core.? session-start --tool claude$"); ($t[0].permissions.allow // []) as $allow | ($t[0].permissions.deny // []) as $deny | ([.hooks.SessionStart[]?.hooks[]? | select(ours) | .command] == [$c]) and (($allow - (.permissions.allow // [])) | length == 0) and (($deny - (.permissions.deny // [])) | length == 0) and (.autoCompactWindow == $w)'
$settingsAdd = 'def ours: (.command // "") | test("ai-core.? session-start --tool claude$"); ($t[0].permissions.allow // []) as $allow | ($t[0].permissions.deny // []) as $deny | .hooks.SessionStart = ([.hooks.SessionStart[]? | .hooks = [.hooks[]? | select(ours | not)] | select(.hooks | length > 0)] + [{hooks: [{type: "command", command: $c, timeout: 60}]}]) | .permissions.allow = ((.permissions.allow // []) + ($allow - (.permissions.allow // []))) | .permissions.deny = ((.permissions.deny // []) + ($deny - (.permissions.deny // []))) | .autoCompactWindow = $w'
if (Get-Command jq -ErrorAction SilentlyContinue) {
  $settingsSrc = if (Test-Path -LiteralPath $settings) { $settings } else { $settingsTemplate }
  $stale = $true
  if ($settingsSrc -ceq $settings) { & jq -e --arg c $hook --argjson w $compact --slurpfile t $settingsTemplate $settingsHas $settings 2>$null | Out-Null; $stale = ($LASTEXITCODE -ne 0) }
  if ($stale) {
    $merged = (& jq --arg c $hook --argjson w $compact --slurpfile t $settingsTemplate $settingsAdd $settingsSrc 2>$null | Out-String)
    if ($LASTEXITCODE -eq 0 -and $merged.Trim()) {
      [System.IO.File]::WriteAllText((Join-Path $tmp 'settings.json'), $merged.Replace("`r`n", "`n"), $utf8)
      Put-File (Join-Path $tmp 'settings.json') $settings '.claude/settings.json' managed
    }
  }
}
# 2a. A repository with a CLAUDE.md of its own: Claude Code then reads that file and not AGENTS.md.
#     A CLAUDE.local.md beside it, which Claude Code loads the same way and git never sees, imports
#     AGENTS.md, so the map and the binding rules load there too. Created once and never taken out;
#     a CLAUDE.local.md that is somebody's own is left alone, and the run says what to add to it.
if (-not $projectFolder -and ((Test-Path -LiteralPath (Join-Path $target 'CLAUDE.md') -PathType Leaf) -or (Test-Path -LiteralPath (Join-Path $target '.claude\CLAUDE.md') -PathType Leaf))) {
  [System.IO.File]::WriteAllText((Join-Path $tmp 'CLAUDE.local.md'), "<!-- written by ai-core init: this repository has its own CLAUDE.md, so Claude Code reads it instead of AGENTS.md; this import loads AGENTS.md as well, the map and the binding rules -->`n@AGENTS.md`n", $utf8)
  Put (Join-Path $tmp 'CLAUDE.local.md') 'CLAUDE.local.md' once
  $own = Join-Path $target 'CLAUDE.local.md'
  if ((Test-Path -LiteralPath $own -PathType Leaf) -and -not (@([System.IO.File]::ReadAllLines($own) | ForEach-Object { $_.TrimEnd("`r") }) -ccontains '@AGENTS.md')) {
    Write-Host "note: CLAUDE.local.md is yours and does not import AGENTS.md; add the line @AGENTS.md so Claude Code loads the map and the binding rules here"
  }
}
if ($projectFolder) {
  $map = New-Object System.Text.StringBuilder
  [void]$map.Append("<!-- setup-ai-core ${coreVersion}: written by init for a project folder, rewritten on every run; put your own notes into .ai-core/rules/rules.local.md -->`n")
  [void]$map.Append("# $(Split-Path -Leaf $target)`n`n")
  [void]$map.Append("This folder holds git repositories, each with its own map.`n`n")
  foreach ($line in @(Get-BindingBlock)) { [void]$map.Append("$line`n") }
  [void]$map.Append("- ``ai-core session-start`` before any work, here and in a repository before you work in it. A repository's map is its ``AGENTS.md``; Claude Code loads it when you work there, any other tool reads it first.`n`n")
  [void]$map.Append("| repository | map |`n| :--- | :--- |`n")
  Get-ChildItem -Path $target -Directory | Where-Object { $_.Name -cnotlike '*-ai-core' -and (Test-Path (Join-Path $_.FullName ".git")) } | ForEach-Object {
    [void]$map.Append("| ``$($_.Name)`` | ``$($_.Name)/AGENTS.md`` |`n")
  }
  [System.IO.File]::WriteAllText((Join-Path $tmp 'AGENTS.md'), $map.ToString(), $utf8)
  Put (Join-Path $tmp 'AGENTS.md') 'AGENTS.md' managed
}

# 3. Keep the harness out of the repository's history: every deployed path goes into the
#    clone's own exclude file, which no commit ever contains. Worktrees share it.
Push-Location $target
try {
  $exclude = $null
  try { $exclude = git rev-parse --git-path info/exclude 2>$null; if ($LASTEXITCODE -ne 0) { $exclude = $null } } catch { $exclude = $null }
  if ($exclude) {
    if (-not [System.IO.Path]::IsPathRooted($exclude)) { $exclude = Join-Path $target $exclude }
    $block = @('# setup-ai-core start: the harness lives in the working tree only, never in a commit', '/.ai-core/', '/.claude/skills/', '/.claude/agents/', '/.agents/', '/CLAUDE.local.md')
    $block += $templateFiles | ForEach-Object { '/' + $_ }
    $block += '# setup-ai-core end'
    # The block replaces the one an earlier run wrote, in its place, or is appended
    $lines = @(); $skip = $false; $written = $false
    if (Test-Path $exclude) {
      foreach ($line in [System.IO.File]::ReadAllLines($exclude)) {
        if ($line -clike '# setup-ai-core start*') { $lines += $block; $skip = $true; $written = $true }
        if (-not $skip) { $lines += $line }
        if ($line -clike '# setup-ai-core end*') { $skip = $false }
      }
    }
    if (-not $written) { $lines += $block }
    [System.IO.File]::WriteAllText((Join-Path $tmp 'exclude'), ($lines -join "`n") + "`n", $utf8)
    Put-File (Join-Path $tmp 'exclude') $exclude '.git/info/exclude' managed
  } else {
    Write-Host "note: $target is not a git repository; nothing to exclude"
  }
} finally {
  Pop-Location
}

# 3a. A repository that carries .githooks\pre-push (the shim that starts the push gate, ai-core
#     pre-push) is armed in this clone: core.hooksPath is the clone's own setting, never
#     committed, so a fresh clone gets it from its first init.
$hooksArmed = $false
if ((Test-Path (Join-Path $target '.githooks\pre-push')) -and ("$(& git -C $target config --get core.hooksPath 2>$null)" -cne '.githooks')) {
  $hooksArmed = $true
  if (-not $DryRun) { & git -C $target config core.hooksPath .githooks }
}

# 3b. The project's .gitignore carries a block naming every file an agent or the harness puts
#     into a checkout (lib\gitignore-block), so no clone of this repository commits one, with or
#     without the harness. The block is rewritten between its markers and the rest of the file is
#     the project's; a path the project already ignores, with or without the slashes, is not
#     written twice, and when it ignores them all no block is written. A changed .gitignore is
#     the one thing init leaves for a commit.
# The block committed on its own and pushed by ref to the branch checked out; a worktree is
# somebody's issue and keeps the change for its own commit. Returns the note for the report.
function Send-Gitignore([string]$dir) {
  if ("$(& git -C $dir rev-parse --git-dir 2>$null)" -cne "$(& git -C $dir rev-parse --git-common-dir 2>$null)") { return "it goes out with this worktree's own commit" }
  & git -C $dir add -- .gitignore
  & git -C $dir commit -q -m 'the agent files of this repository are ignored' -m 'No-issue: the .gitignore block written by ai-core init' -- .gitignore
  if ($LASTEXITCODE -ne 0) { return "the commit failed (see above)" }
  & git -C $dir remote get-url origin 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) { return "committed; no origin, not pushed" }
  $branch = "$(& git -C $dir symbolic-ref --short -q HEAD 2>$null)"
  if ($LASTEXITCODE -ne 0 -or -not $branch) { return "committed; not on a branch, not pushed" }
  & git -C $dir push --quiet origin "HEAD:$branch"
  if ($LASTEXITCODE -eq 0) { return "committed and pushed to origin/$branch" }
  return "committed; the push was refused or failed (see above), the commit stays"
}
# The .gitignore the checkout should have, $wanted, against the one it has, $current
$buildGitignore = {
  $kept = @(); $skip = $false
  if (Test-Path $gi) {
    foreach ($line in [System.IO.File]::ReadAllLines($gi)) {
      if ($line -clike '# setup-ai-core start*') { $skip = $true }
      if (-not $skip) { $kept += $line }
      if ($line -clike '# setup-ai-core end*') { $skip = $false }
    }
  }
  $seen = @{}; foreach ($line in $kept) { if ($line -and -not $line.StartsWith('#', [StringComparison]::Ordinal)) { $seen[$line.Trim().Trim('/')] = $true } }
  $markers = @(); $missing = @()
  foreach ($line in [System.IO.File]::ReadAllLines((Join-Path $coreRoot "lib\gitignore-block"))) {
    if ($line.StartsWith('#', [StringComparison]::Ordinal)) { $markers += $line; continue }
    if (-not $seen.ContainsKey($line.Trim().Trim('/'))) { $missing += $line }
  }
  $block = if ($missing.Count -gt 0) { @($markers[0]) + $missing + @($markers[1]) } else { @() }
  $wanted = (($kept + $block) -join "`n") + "`n"
  $current = if (Test-Path $gi) { [System.IO.File]::ReadAllText($gi).Replace("`r`n", "`n") } else { $null }
}
$gitignoreChanged = $false; $gitignoreNote = ''; $gitignoreBehind = $false
if ($inWorkTree) {
  $gi = Join-Path $target ".gitignore"
  . $buildGitignore
  if ($current -cne $wanted) {
    $gitignoreChanged = $true
    if (-not $DryRun) {
      # The commit goes on top of what the origin has: the checkout catches up first (a worktree
      # keeps the change for its own commit), and the block is built again from what came
      $caught = [pscustomobject]@{ Ok = $true; Note = '' }
      if ("$(& git -C $target rev-parse --git-dir 2>$null)" -ceq "$(& git -C $target rev-parse --git-common-dir 2>$null)") { $caught = Sync-Checkout $target }
      if (-not $caught.Ok) { $gitignoreBehind = $true; $gitignoreNote = $caught.Note }
      else {
        if ($caught.Note) { . $buildGitignore }
        if ($current -cne $wanted) { [System.IO.File]::WriteAllText($gi, $wanted, $utf8); $gitignoreNote = "$(if ($caught.Note) { "$($caught.Note); " })$(Send-Gitignore $target)" }
        else { $gitignoreChanged = $false; $gitignoreNote = $caught.Note }
      }
    }
  }
}

# 3c. Shims git skips for want of the executable bit (a copy that drops the file modes writes them
#     so) leave the push gate off: in a checkout, ai-core pre-push -Install sets the bit, commits
#     and pushes it, and a worktree gets it with that commit. A hook of the project's own that git
#     skips is named, not changed.
$shimsMode = 0
$shimFile = Join-Path $target '.githooks/pre-push'
if ((Test-Path -LiteralPath (Join-Path $target '.git') -PathType Container) -and (Test-Path -LiteralPath $shimFile)) {
  $modeless = @(& git -C $target ls-files -s -- .githooks/pre-push .githooks/post-checkout 2>$null | Where-Object { "$_" -cnotmatch '^100755 ' })
  $offDisk = (-not $IsWindows) -and -not ((Get-Item -LiteralPath $shimFile).UnixFileMode -band [System.IO.UnixFileMode]::UserExecute)
  if ($modeless.Count -gt 0 -or $offDisk) {
    $shimsMode = 1
    if (-not $DryRun) {
      Push-Location $target
      try { & pwsh -NoProfile -File (Join-Path $coreRoot "bin\pre-push.ps1") -Install } finally { Pop-Location }
      if ($LASTEXITCODE -ne 0) { $shimsMode = 2 }
    }
  }
}
$skippedHooks = @(& git -C $target ls-files -s -- .githooks 2>$null | ForEach-Object { "$_" } | Where-Object { $_.StartsWith('100644 ', [StringComparison]::Ordinal) } | ForEach-Object { ($_ -split "`t", 2)[1] } | Where-Object { $_ -cne '.githooks/pre-push' -and $_ -cne '.githooks/post-checkout' })

# 4. The Graft code graph, built with the local Node.js or the whole init fails; no fallback. For a
#    project folder, init -All builds it after the repositories (AI_CORE_GRAFT_LATER).
$graftArgs = @(); if ($DryRun) { $graftArgs += '-DryRun' }
if (-not $env:AI_CORE_GRAFT_LATER) { & pwsh -NoProfile -File (Join-Path $coreRoot "bin\graft-setup.ps1") -TargetDir $target @graftArgs }
if (-not $env:AI_CORE_GRAFT_LATER -and $LASTEXITCODE -ne 0) {
  Write-Host "error: the harness files are in place but the Graft code graph is not (see above). Fix the cause and run 'ai-core graft', or set GRAFT_EXECUTION_MODE=`"skip`" in .ai-core/config.env." -ForegroundColor Red
  Remove-Item -LiteralPath $tmp -Recurse -Force
  exit 1
}
Remove-Item -LiteralPath $tmp -Recurse -Force

# 5. The report: what this run did to the checkout, or would do
Write-Host "==================================================" -ForegroundColor Green
Write-Host "init $(if ($DryRun) { 'would change' } else { 'changed' }) in $(Split-Path -Leaf $target):"
if ($report.created.Count -gt 0)   { Write-Host "  created    $($report.created -join ', ')" }
if ($report.refreshed.Count -gt 0) { Write-Host "  refreshed  $($report.refreshed -join ', ')" }
if ($report.kept.Count -gt 0)      { Write-Host "  kept       $($report.kept -join ', ') (yours: differs from the template, never overwritten)" }
if ($report.removed.Count -gt 0)   { Write-Host "  removed    $($report.removed -join ', ')" }
if ($report.tracked.Count -gt 0)   { Write-Host "  tracked    $($report.tracked -join ', ') (the repository commits these; repos/$repoName/ is not applied to them)" }
Write-Host "  unchanged  $($report.unchanged) file(s)"
if ($gitignoreChanged) {
  if ($DryRun) { Write-Host "  .gitignore would change and be committed: the agent files of this repository are ignored" }
  elseif ($gitignoreBehind) { Write-Host "  .gitignore not written: this checkout is $gitignoreNote" }
  else { Write-Host "  .gitignore changed: the agent files of this repository are ignored; $gitignoreNote" }
} elseif ($gitignoreNote) { Write-Host "  .gitignore: $gitignoreNote; the block was there already" }
if ($worktreeDataFrom) { Write-Host "  .ai-core $(if ($DryRun) { 'would be taken' } else { 'taken' }) from the checkout ${worktreeDataFrom}: a worktree starts with the checkout's configuration, local rules and documents" }
if ($hooksArmed) { Write-Host "  core.hooksPath $(if ($DryRun) { 'would be set' } else { 'set' }) to .githooks: the push gate runs here" }
if ($shimsMode -eq 1 -and $DryRun) { Write-Host "  the shims in .githooks are not executable, so git skips the push gate: ai-core pre-push --install would make them so" }
elseif ($shimsMode -eq 1) { Write-Host "  the shims in .githooks were not executable, so git skipped the push gate: ai-core pre-push --install made them so" }
elseif ($shimsMode -eq 2) { Write-Host "  the shims in .githooks are not executable, so git skips the push gate, and ai-core pre-push --install failed (see above)" }
foreach ($hook in $skippedHooks) { Write-Host "  $hook is not executable, so git skips it; it is the project's own and stays as it is" }
if ($DryRun) { Write-Host "  nothing was written (dry run)" } else { Write-Host "✓ Harness $coreVersion in place. Run 'ai-core session-start' here to verify." -ForegroundColor Green }
Write-Host "==================================================" -ForegroundColor Green
if ($shimsMode -eq 2) { exit 1 }
