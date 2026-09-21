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
  & gh auth status *> $null
  if ($LASTEXITCODE -eq 0) { Write-Report gh present ("$(& gh --version 2>$null | Select-Object -First 1), logged in") }
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
