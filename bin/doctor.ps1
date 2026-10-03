# Check the prerequisites of the harness on this machine; install what is missing where that
# can be automated; exit 1 with the instruction for what cannot.
#
#   doctor.ps1 [-NoInstall]
#
[CmdletBinding()]
param (
  [switch]$Help,
  [switch]$NoInstall
)

if ($Help -or $args -ccontains "-h" -or $args -ccontains "--help") {
  Write-Host "Usage: doctor.ps1 [-NoInstall]"
  Write-Host ""
  Write-Host "Checks Git, gh (with its login), Bash, PowerShell 7, Node.js 20+ with npx, and reports"
  Write-Host "the agent CLIs (claude, agy, codex). Missing required tools are installed with the"
  Write-Host "platform's package manager (winget, brew, apt-get). A login cannot be automated and"
  Write-Host "is reported with its command. Exit 1 when a required tool is still missing afterwards."
  Write-Host ""
  Write-Host "Options:"
  Write-Host "  -NoInstall    Only report; install nothing"
  Write-Host "  -Help         Show this help message"
  exit 0
}

$ErrorActionPreference = 'Continue'

$os = if ($IsWindows -or $env:OS -ceq 'Windows_NT') { 'windows' } elseif ($IsMacOS) { 'macos' } elseif ($IsLinux) { 'linux' } else { 'other' }
$pm = ''
switch -CaseSensitive ($os) {
  'windows' { if (Get-Command winget -ErrorAction SilentlyContinue) { $pm = 'winget' } }
  'macos' { if (Get-Command brew -ErrorAction SilentlyContinue) { $pm = 'brew' } }
  'linux' { if (Get-Command apt-get -ErrorAction SilentlyContinue) { $pm = 'apt-get' } }
}

$script:problems = 0
$script:installedSomething = $false

function Write-Report([string]$tool, [string]$status, [string]$detail) { Write-Host ("  {0,-12} {1,-12} {2}" -f $tool, $status, $detail) }
function Add-Problem { $script:problems++ }
function Test-Tool([string]$name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }

# On Windows a tool installed a moment ago is not on this shell's PATH yet
function Update-PathAfterInstall {
  if ($os -cne 'windows') { return }
  foreach ($d in @("C:\Program Files\Git\cmd", "C:\Program Files\nodejs", "C:\Program Files\PowerShell\7", "C:\Program Files\GitHub CLI", (Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links"))) {
    if ((Test-Path $d) -and ($env:Path -cnotlike "*$d*")) { $env:Path = "$env:Path;$d" }
  }
}

function Install-Tool([string]$tool, [string]$wingetId, [string]$brewFormula, [string]$aptPackage) {
  if ($NoInstall -or -not $pm) { return $false }
  Write-Host "--> Installing $tool with $pm..."
  switch -CaseSensitive ($pm) {
    'winget' { & winget install --id $wingetId -e --accept-source-agreements --accept-package-agreements --disable-interactivity | Out-Null }
    'brew' { & brew install $brewFormula | Out-Null }
    'apt-get' {
      if ((& id -u) -eq '0') { & apt-get install -y $aptPackage | Out-Null }
      elseif (Get-Command sudo -ErrorAction SilentlyContinue) { & sudo apt-get install -y $aptPackage | Out-Null }
      else { return $false }
    }
  }
  if ($LASTEXITCODE -ne 0) { return $false }
  $script:installedSomething = $true
  Update-PathAfterInstall
  return $true
}

function Get-Major([string]$version) { if ($version -match '(\d+)') { [int]$Matches[1] } else { 0 } }

Write-Host "==> doctor: $os, package manager: $(if ($pm) { $pm } else { 'none' })"

# Git
if (-not (Test-Tool git)) { [void](Install-Tool git Git.Git git git) }
if (Test-Tool git) { Write-Report git present ((& git --version 2>$null | Select-Object -First 1)) }
else { Write-Report git MISSING "install Git from https://git-scm.com"; Add-Problem }

# gh
if (-not (Test-Tool gh)) { [void](Install-Tool gh GitHub.cli gh gh) }
if (Test-Tool gh) {
  # the board commands write Projects v2, which a login with gh's default scopes cannot; a token
  # gh lists no scopes for (a fine-grained one, GH_TOKEN) is not judged
  $ghStatus = (& gh auth status 2>&1 | Out-String)
  if ($LASTEXITCODE -eq 0) {
    if ($ghStatus -cmatch 'Token scopes:' -and $ghStatus -cnotmatch "'project'") { Write-Report gh "no project scope" "the board commands read and write the project board; run: gh auth refresh -h github.com -s project"; Add-Problem }
    else { Write-Report gh present ("$(& gh --version 2>$null | Select-Object -First 1), logged in") }
  }
  else { Write-Report gh "not logged in" "run: gh auth login"; Add-Problem }
} else { Write-Report gh MISSING "install GitHub CLI from https://cli.github.com"; Add-Problem }

# Bash: Git Bash on Windows, the system shell elsewhere
if (Test-Tool bash) { Write-Report bash present ((& bash --version 2>$null | Select-Object -First 1) + $(if ($os -ceq 'windows') { ' (Git Bash)' } else { '' })) }
elseif ($os -ceq 'windows') { Write-Report bash MISSING "Git Bash comes with Git for Windows: winget install Git.Git"; Add-Problem }
else { Write-Report bash MISSING "install bash"; Add-Problem }

# PowerShell 7 (this script runs in it)
$pwshVersion = $PSVersionTable.PSVersion.ToString()
if ($PSVersionTable.PSVersion.Major -ge 7) { Write-Report pwsh present "PowerShell $pwshVersion" }
else { Write-Report pwsh "too old" "PowerShell $pwshVersion; 7 or newer is needed: winget install Microsoft.PowerShell"; Add-Problem }

# Node.js 20+ with npx
if (-not (Test-Tool node)) { [void](Install-Tool node OpenJS.NodeJS.LTS node nodejs) }
if (Test-Tool node) {
  $nodeVersion = (& node -v 2>$null | Select-Object -First 1)
  if ((Get-Major $nodeVersion) -ge 20) {
    if (-not (Test-Tool npx) -and $pm -ceq 'apt-get') { [void](Install-Tool npx npm npm npm) }
    if (Test-Tool npx) { Write-Report node present "Node.js $nodeVersion with npx" }
    else { Write-Report npx MISSING "Node.js $nodeVersion has no npx; install npm"; Add-Problem }
  } else { Write-Report node "too old" "Node.js $nodeVersion; 20 or newer is needed, see https://nodejs.org"; Add-Problem }
} else { Write-Report node MISSING "install Node.js 20 or newer from https://nodejs.org"; Add-Problem }

# jq: every board and issue command reads GitHub's answers through it
if (-not (Test-Tool jq)) { [void](Install-Tool jq jqlang.jq jq jq) }
if (Test-Tool jq) { Write-Report jq present ((& jq --version 2>$null | Select-Object -First 1)) }
else { Write-Report jq MISSING "install jq from https://jqlang.github.io/jq"; Add-Problem }

# Graft in the version setup-ai-core pins (lib\graft-version), installed globally: Graft's hooks and
# the graft command an agent runs take the global one, while init and the MCP servers name the pin.
# Another version, or none, is replaced; with -NoInstall it is reported.
$graftPin = ([System.IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\lib\graft-version'))).Trim()
if (Test-Tool npm) {
  $graftHave = ''
  foreach ($l in @(& npm ls -g @nanonets/graft --depth=0 2>$null | ForEach-Object { "$_" })) { if ($l -cmatch '@nanonets/graft@([0-9][^ ]*)') { $graftHave = $Matches[1]; break } }
  if ($graftHave -ceq $graftPin) { Write-Report graft present "Graft $graftPin, global" }
  elseif ($NoInstall) { Write-Report graft $(if ($graftHave) { $graftHave } else { 'absent' }) "setup-ai-core pins Graft $graftPin; run doctor without -NoInstall, or npm i -g @nanonets/graft@$graftPin" }
  else {
    $npmOut = @(& npm i -g "@nanonets/graft@$graftPin" 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -eq 0) { Write-Report graft installed "Graft $graftPin, global$(if ($graftHave) { ", was $graftHave" })" }
    else {
      Write-Report graft FAILED "npm i -g @nanonets/graft@$graftPin failed; npm said:"; Add-Problem
      # A parser of Graft that has no prebuilt binary here is compiled by node-gyp, which needs a C/C++ toolchain
      $gyp = @($npmOut | Where-Object { $_.Contains('gyp ERR!') } | Select-Object -First 3)
      if ($gyp.Count -gt 0) {
        $gyp | ForEach-Object { Write-Host "    $_" }
        $hint = switch -CaseSensitive ($os) {
          'linux' { if ($pm -ceq 'apt-get') { 'sudo apt-get install -y build-essential' } else { 'install make, gcc and g++' } }
          'macos' { 'xcode-select --install' }
          'windows' { 'winget install Microsoft.VisualStudio.2022.BuildTools --override "--passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"' }
          default { 'install make, gcc and g++' }
        }
        Write-Host "    npm had to compile a native module with node-gyp, which needs a C/C++ toolchain; install one, then run doctor again: $hint"
      } else { $npmOut | Select-Object -Last 5 | ForEach-Object { Write-Host "    $_" } }
    }
  }
}

# gitleaks, where a repository of this project folder carries .gitleaks.toml: the push gate reads
# every push there with `gitleaks git`, which came with gitleaks 8.19, and refuses the push without
# it. winget and brew have a recent one; apt's is 8.16 on every Ubuntu to date, so elsewhere the
# release comes from GitHub, into ~/.local/bin.
Import-Module (Join-Path $PSScriptRoot '..\lib\Layers.psm1') -Force
$leaksRepos = @(Get-ChildItem -Path (Get-ProjectFolderOf (Get-Location).Path) -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName '.gitleaks.toml') -PathType Leaf } | ForEach-Object { $_.Name })
if ($leaksRepos.Count -gt 0) {
  function Test-Gitleaks { if (-not (Test-Tool gitleaks)) { return $false }; & gitleaks git --help *> $null; return ($LASTEXITCODE -eq 0) }
  function Install-GitleaksRelease {
    $o = switch -CaseSensitive ($os) { 'linux' { 'linux' } 'macos' { 'darwin' } default { '' } }
    if (-not $o) { return $false }
    $a = switch -CaseSensitive ("$(& uname -m 2>$null)".Trim()) { 'x86_64' { 'x64' } 'amd64' { 'x64' } 'aarch64' { 'arm64' } 'arm64' { 'arm64' } 'armv7l' { 'armv7' } default { '' } }
    if (-not $a -or -not (Test-Tool gh) -or -not (Test-Tool tar)) { return $false }
    Write-Host "--> Installing gitleaks from its GitHub release into ~/.local/bin..."
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName()); $null = New-Item -ItemType Directory $tmp
    $localBin = Join-Path $HOME '.local/bin'
    try {
      & gh release download --repo gitleaks/gitleaks --pattern "gitleaks_*_$($o)_$($a).tar.gz" --dir $tmp *> $null
      if ($LASTEXITCODE -ne 0) { return $false }
      $null = New-Item -ItemType Directory -Force $localBin
      & tar -xzf (@(Get-ChildItem $tmp -Filter 'gitleaks_*.tar.gz')[0].FullName) -C $localBin gitleaks *> $null
      if ($LASTEXITCODE -ne 0) { return $false }
    } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    if (($env:PATH -split ':') -notcontains $localBin) { $env:PATH = $localBin + ':' + $env:PATH; $script:leaksNote = 'note: ~/.local/bin, where gitleaks is now, is not on the PATH of this shell; log in again (a login shell adds it once it exists) or add it to your profile' }
    $script:installedSomething = $true
    return $true
  }
  $leaksNote = ''; $leaksNew = $false
  if (-not (Test-Gitleaks) -and -not $NoInstall) {
    if ($pm -ceq 'winget' -or $pm -ceq 'brew') { $leaksNew = [bool](Install-Tool gitleaks Gitleaks.Gitleaks gitleaks '-') } else { $leaksNew = [bool](Install-GitleaksRelease) }
  }
  $how = switch -CaseSensitive ($os) { 'windows' { 'winget install --id Gitleaks.Gitleaks -e' } 'macos' { 'brew install gitleaks' } default { 'the gitleaks release for this machine from https://github.com/gitleaks/gitleaks/releases, unpacked into ~/.local/bin' } }
  if ($NoInstall) { $how = "run doctor without -NoInstall, which installs it, or: $how" }
  if (Test-Gitleaks) {
    $v = "$(& gitleaks version 2>$null | Select-Object -First 1)".Trim(); $v = if ($v -cmatch '^v?([0-9][0-9.]*)$') { " $($Matches[1])" } else { '' }
    Write-Report gitleaks $(if ($leaksNew) { 'installed' } else { 'present' }) "gitleaks$v, for .gitleaks.toml in: $($leaksRepos -join ' ')"
  }
  elseif (Test-Tool gitleaks) { Write-Report gitleaks 'too old' "$((Get-Command gitleaks).Source) has no 'gitleaks git', which the push gate runs (8.19 or newer); $how"; Add-Problem }
  else { Write-Report gitleaks MISSING "the push gate reads every push with it where .gitleaks.toml is: $($leaksRepos -join ' '); $how"; Add-Problem }
  if ($leaksNote) { Write-Host $leaksNote }
}

# An agent definition of this machine that names a model below Sonnet
foreach ($file in @(Get-ChildItem -Path (Join-Path $HOME '.claude\agents') -Filter '*.md' -File -ErrorAction SilentlyContinue)) {
  $m = ''
  foreach ($l in @([System.IO.File]::ReadAllLines($file.FullName) | Select-Object -Skip 1)) { if ($l.StartsWith('---', [StringComparison]::Ordinal)) { break }; if ($l -cmatch '^model:\s*(.*)$') { $m = $Matches[1].Trim().Trim('"', "'"); break } }
  if ($m.ToLowerInvariant().Contains('haiku')) { Write-Report agent 'below Sonnet' "$($file.FullName) names the model $m" }
}

# Agent CLIs: reported, never installed by doctor
$hints = @{
  claude = "Claude Code: https://claude.ai/install.ps1 or install.sh"
  agy    = "Antigravity: https://antigravity.google/cli/install.ps1 or install.sh"
  codex  = "Codex: npm install -g @openai/codex"
}
# Antigravity reads its MCP servers from one machine-wide file only (it does not read a file in
# the repository; tested); an empty one is not JSON, Graft cannot register there, so it is made valid.
foreach ($cli in @('claude', 'agy', 'codex')) {
  $cmd = Get-Command $cli -ErrorAction SilentlyContinue
  if ($cmd) { Write-Report $cli present $cmd.Source } else { Write-Report $cli absent $hints[$cli] }
  if ($cmd -and $cli -ceq 'agy') {
    $mcp = Join-Path $HOME '.gemini\config\mcp_config.json'
    if ((Test-Path $mcp) -and (Get-Item $mcp).Length -eq 0) {
      if ($NoInstall) { Write-Report 'agy mcp' MISSING "$mcp is empty; Antigravity cannot register MCP servers; run doctor without -NoInstall"; Add-Problem }
      else { [System.IO.File]::WriteAllText($mcp, '{}'); Write-Report 'agy mcp' repaired "$mcp was empty; it is {} now, and the next init registers the Graft server there" }
    }
  }
}

# A session-start hook in the machine-wide Claude Code settings that starts a script of an
# earlier layout (a session-start.sh or .ps1 beside the repositories): the repository's own
# .claude\settings.json carries the hook now, so the stale one is taken out.
$claudeSettings = Join-Path $HOME '.claude\settings.json'
if ((Test-Path $claudeSettings) -and (Test-Tool jq)) {
  $staleHooks = "$(& jq '[.hooks.SessionStart[]?.hooks[]?.command // empty | select(test(\"session-start\\\\.(sh|ps1)\"))] | length' $claudeSettings 2>$null)".Trim()
  if ($staleHooks -and [int]$staleHooks -gt 0) {
    if ($NoInstall) { Write-Report 'claude hook' stale "$claudeSettings starts a session-start script of an earlier layout; run doctor without -NoInstall to take it out"; Add-Problem }
    else {
      $repaired = (& jq '.hooks.SessionStart = [.hooks.SessionStart[]? | .hooks = [.hooks[]? | select((.command // \"\") | test(\"session-start\\\\.(sh|ps1)\") | not)] | select(.hooks | length > 0)]' $claudeSettings | Out-String)
      if ($LASTEXITCODE -eq 0 -and $repaired.Trim()) { [System.IO.File]::WriteAllText($claudeSettings, $repaired, (New-Object System.Text.UTF8Encoding $false)) }
      Write-Report 'claude hook' repaired "$claudeSettings started a session-start script of an earlier layout; taken out, the repository's own .claude/settings.json carries the hook now"
    }
  }
}

# Claude Code keeps a project's memory in ~/.claude/projects/<project>/memory. A tool of an earlier
# layout made that folder a link into a repository; where the target is gone, Claude Code cannot
# write a memory for that project, so the dead link is taken out and Claude Code makes a real
# folder at the next memory it writes. Nothing is lost: the target is not there.
$projectsDir = Join-Path $HOME '.claude\projects'
if (Test-Path -LiteralPath $projectsDir) {
  foreach ($dir in @(Get-ChildItem -LiteralPath $projectsDir -Directory -Force -ErrorAction SilentlyContinue)) {
    $link = Join-Path $dir.FullName 'memory'
    try { $item = Get-Item -LiteralPath $link -Force -ErrorAction Stop } catch { continue }
    if (-not $item.LinkType) { continue }
    $target = ($item.Target -join '')
    if ($target -and (Test-Path -LiteralPath $target)) { continue }
    if ($NoInstall) { Write-Report 'claude memory' stale "$link points at $target, which is gone; run doctor without -NoInstall to take the link out"; Add-Problem }
    else {
      if ($IsWindows) { [System.IO.Directory]::Delete($link) } else { [System.IO.File]::Delete($link) }   # the link only, never a target
      Write-Report 'claude memory' repaired "$link pointed at $target, which is gone; taken out, Claude Code makes a real folder at the next memory it writes"
    }
  }
}

# The team modes of every agent tool on this machine: checked, and installed when one is missing
# (team-modes.tsv says how, per tool). A plugin loads when the tool starts, so a fresh install
# needs the tool restarted; the check says which.
& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'team-modes-check.ps1') -Quiet 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
  Write-Report "team modes" present "every mode of every agent tool here is installed"
} elseif ($NoInstall) {
  Write-Report "team modes" MISSING "run: ai-core team-modes-install, then restart the tool"; Add-Problem
} else {
  Write-Host "--> installing the missing team modes (ai-core team-modes-install)..."
  & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'team-modes-install.ps1')
  $installed = ($LASTEXITCODE -eq 0)
  if ($installed) { & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'team-modes-check.ps1') -Quiet 2>$null | Out-Null; $installed = ($LASTEXITCODE -eq 0) }
  if ($installed) { Write-Report "team modes" installed "restart your agent tool: a plugin loads when the tool starts"; $script:installedSomething = $true }
  else { Write-Report "team modes" MISSING "the lines above say which mode and how; run: ai-core team-modes-check"; Add-Problem }
}

if ($script:installedSomething) { Write-Host "note: something was installed; open a new terminal if a tool is still reported missing." }

if ($script:problems -gt 0) {
  Write-Host "doctor: $($script:problems) problem(s); fix them and run doctor again."
  exit 1
}
Write-Host "doctor: OK"
