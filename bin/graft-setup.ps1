# Build the Graft code graph of the target repository, natively or not at all.
#
#   graft-setup.ps1 [-TargetDir <path>] [-DryRun]
#
[CmdletBinding()]
param (
  [switch]$Help,
  [string]$TargetDir = ".",
  [switch]$DryRun
)

if ($Help -or $args -ccontains "-h" -or $args -ccontains "--help" -or $TargetDir -ceq "--help" -or $TargetDir -ceq "-h") {
  Write-Host "Usage: graft-setup.ps1 [-TargetDir <path>] [-DryRun]"
  Write-Host ""
  Write-Host "Wires Graft into the agents on this machine (graft init -y --no-build, no picker) and builds"
  Write-Host "the code graph with the Node.js on this machine (npx -y @nanonets/graft build)."
  Write-Host "Reads GRAFT_EXECUTION_MODE from .ai-core/config.env: native (default) or skip, and AGENTS: the"
  Write-Host "agents Graft is wired into (claude, codex, antigravity, gemini, cursor, windsurf, copilot;"
  Write-Host "openhands has no Graft wiring); empty means every agent Graft detects."
  Write-Host "There is no fallback: without Node.js and npx, native mode fails with exit 1."
  Write-Host "Whatever Graft writes into the repository is recorded in .git/info/exclude, so it is never committed."
  Write-Host ""
  Write-Host "Options:"
  Write-Host "  -TargetDir <path>   Target directory"
  Write-Host "  -DryRun             Report what Graft would write, in the repository and on the machine; build nothing"
  Write-Host "  -Help               Show this help message"
  Write-Host ""
  Write-Host "Examples:"
  Write-Host "  ai-core graft"
  Write-Host "  ai-core graft -DryRun"
  exit 0
}

$ErrorActionPreference = 'Stop'

# Graft's own lines "✓ what: path (state)" are read for the report: what it wrote into the
# repository and what on the machine (a path under the home directory), and with which state
function Write-GraftReport([string[]]$lines) {
  $repo = @(); $machine = @()
  $here = (Get-Location).Path
  foreach ($line in $lines) {
    $line = $line.TrimEnd("`r")
    if ($line.StartsWith('✓ wrote ', [StringComparison]::Ordinal)) { $path = $line.Substring(8); $state = 'wrote' }
    elseif ($line -cmatch '^✓[^:]*: (.*) \(([^()]*)\)$') { $path = $Matches[1]; $state = $Matches[2] }
    else { continue }
    if ($state -cnotin @('created', 'updated', 'appended', 'wrote')) { continue }
    $inRepo = $false
    foreach ($sep in @('\', '/')) { if ($path.StartsWith($here + $sep, [StringComparison]::Ordinal)) { $path = $path.Substring($here.Length + 1); $inRepo = $true } }
    if (-not $inRepo -and ($path.StartsWith($HOME, [StringComparison]::Ordinal) -or $path.StartsWith('~', [StringComparison]::Ordinal))) {
      $machine += "    $path ($state)"
    } else {
      $repo += "    $path ($state)"
    }
  }
  if ($repo.Count -gt 0) { Write-Host "  Graft wrote in the repository:"; foreach ($r in $repo) { Write-Host $r } }
  if ($machine.Count -gt 0) { Write-Host "  Graft wrote on the machine:"; foreach ($m in $machine) { Write-Host $m } }
}

# Graft prints UTF-8; the console decodes what it prints, so it decodes UTF-8 while this runs
$consoleEncoding = [Console]::OutputEncoding
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
Push-Location $TargetDir
try {
  $configFile = ".ai-core\config.env"
  $graftMode = "native"
  $agents = ""

  if (Test-Path $configFile) {
    Get-Content $configFile | Where-Object { $_ -match '^\s*[^#]' } | ForEach-Object {
      $name, $value = $_ -split '=', 2
      if ($null -eq $value) { return }
      # Same normalisation as graft-setup.sh: drop an inline comment, surrounding quotes and whitespace, lowercase the value
      $value = ($value -split '#', 2)[0]
      $val = $value.Trim(' ', "`t", "`r", '"', "'").ToLowerInvariant()
      if ($name.Trim() -ceq "GRAFT_EXECUTION_MODE") { $graftMode = $val }
      if ($name.Trim() -ceq "AGENTS") { $agents = $val }
    }
  }

  # The agents Graft wires, in Graft's own ids: codex reads AGENTS.md and ~\.codex, which Graft
  # calls "agents"; openhands has no wiring of its own. Empty: whatever Graft detects (-y).
  $graftAgents = @()
  foreach ($a in ($agents -split '\s+' | Where-Object { $_ })) {
    switch -CaseSensitive ($a) {
      'codex' { $graftAgents += 'agents' }
      { $_ -cin @('claude', 'antigravity', 'gemini', 'cursor', 'windsurf', 'copilot') } { $graftAgents += $a }
      'openhands' { }
      default { Write-Host "error: AGENTS in $configFile names '$a'; known are claude, codex, antigravity, openhands, gemini, cursor, windsurf, copilot" -ForegroundColor Red; exit 1 }
    }
  }
  $graftInit = if ($graftAgents.Count -gt 0) { @('init', '--agents') + $graftAgents + @('--no-build') } else { @('init', '-y', '--no-build') }

  if ($graftMode -notin @('native', 'skip')) {
    Write-Host "error: GRAFT_EXECUTION_MODE must be native or skip (got '$graftMode') in $configFile" -ForegroundColor Red
    exit 1
  }

  if ($graftMode -ceq "skip") {
    Write-Host "==> Graft: skipped by $configFile." -ForegroundColor Yellow
    exit 0
  }

  if (-not (Get-Command npx -ErrorAction SilentlyContinue)) {
    Write-Host "error: Graft needs Node.js with npx on this machine and there is no fallback. Install Node.js 20+ or set GRAFT_EXECUTION_MODE=`"skip`" in $configFile." -ForegroundColor Red
    exit 1
  }

  # What Graft writes into the repository (graft\, and the files graft init wires: GEMINI.md,
  # .gemini\, .claude\skills\graft\, ...) stays out of every commit: its own block in
  # .git\info\exclude, which keeps what earlier runs recorded and grows with what this run adds.
  $exclude = $null
  try { $exclude = git rev-parse --git-path info/exclude 2>$null; if ($LASTEXITCODE -ne 0) { $exclude = $null } } catch { $exclude = $null }
  if ($exclude -and -not [System.IO.Path]::IsPathRooted($exclude)) { $exclude = Join-Path (Get-Location).Path $exclude }
  $graftLines = [System.Collections.Generic.List[string]]@('/graft/')
  function Write-GraftBlock {
    $kept = @(); $skip = $false
    if (Test-Path $exclude) {
      foreach ($line in [System.IO.File]::ReadAllLines($exclude)) {
        if ($line -clike '# setup-ai-core graft start*') { $skip = $true }
        if (-not $skip) { $kept += $line }
        if ($line -clike '# setup-ai-core graft end*') { $skip = $false }
      }
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $exclude) | Out-Null
    $block = @('# setup-ai-core graft start: what Graft writes into the working tree, never into a commit') + $graftLines + @('# setup-ai-core graft end')
    [System.IO.File]::WriteAllText($exclude, (($kept + $block) -join "`n") + "`n")
  }
  function Get-Snapshot { try { @(git status --porcelain --untracked-files=all 2>$null) } catch { @() } }
  # -DryRun: what Graft would write, in the repository and on the machine, and nothing built
  if ($DryRun) {
    $out = @(); try { $out = @(& npx -y @nanonets/graft @graftInit --dry-run 2>&1 | ForEach-Object { "$_" }) } catch { $out = @() }
    Write-Host "  Graft would write (init):"
    $inSection = $false
    foreach ($line in $out) {
      $line = $line.TrimEnd("`r")
      if ($line.StartsWith('would write', [StringComparison]::Ordinal)) { $inSection = $true }
      if ($inSection) { Write-Host "    $line" }
      if ($line -ceq '') { $inSection = $false }
    }
    Write-Host "  Graft would build the graph into graft/ (not done: dry run)"
    exit 0
  }

  if ($exclude) {
    if (Test-Path $exclude) {
      $inBlock = $false
      foreach ($line in [System.IO.File]::ReadAllLines($exclude)) {
        if ($line -clike '# setup-ai-core graft start*') { $inBlock = $true; continue }
        if ($line -clike '# setup-ai-core graft end*') { $inBlock = $false; continue }
        if ($inBlock -and $line -and -not $graftLines.Contains($line)) { $graftLines.Add($line) }
      }
    }
    # What graft init wires into the repository, excluded whether it exists already or not
    $dry = @(); try { $dry = @(& npx -y @nanonets/graft @graftInit --dry-run 2>&1 | ForEach-Object { "$_" }) } catch { $dry = @() }
    $inRepo = $false
    foreach ($line in $dry) {
      if ($line -cmatch '^would write.*this repo:') { $inRepo = $true; continue }
      if (-not $line.StartsWith('  ', [StringComparison]::Ordinal)) { $inRepo = $false; continue }
      if ($inRepo) { $path = '/' + (($line.Trim() -split '\s+')[0]).Replace('\', '/'); if (-not $graftLines.Contains($path)) { $graftLines.Add($path) } }
    }
    Write-GraftBlock
    $before = Get-Snapshot
  }

  # Graft's own output is kept and shown whole only when something fails; what it changed is
  # reported in two lines afterwards
  Write-Host "==> Graft: wiring the agents and building the code graph (npx -y @nanonets/graft)..."
  $result = 0
  $out = @(& npx -y @nanonets/graft @graftInit 2>&1 | ForEach-Object { "$_" })
  if ($LASTEXITCODE -eq 0) { $out += @(& npx -y @nanonets/graft build 2>&1 | ForEach-Object { "$_" }) }
  if ($LASTEXITCODE -ne 0) { $result = 1 }
  if ($result -ne 0) { foreach ($line in $out) { Write-Host $line } }

  if ($exclude) {
    $changed = @()
    foreach ($line in Get-Snapshot) {
      if ($before -contains $line) { continue }
      if ($line.StartsWith('?? ', [StringComparison]::Ordinal)) {
        $path = '/' + $line.Substring(3)
        if (-not $graftLines.Contains($path)) { $graftLines.Add($path) }
      } else { $changed += $line.Substring(3) }
    }
    Write-GraftBlock
    if ($changed.Count -gt 0) { Write-Host "warning: Graft changed committed files: $($changed -join ' '). Review them with git diff; keep or restore them." -ForegroundColor Yellow }
  }

  if ($result -ne 0) {
    Write-Host "error: Graft build failed; see the output above. Fix the cause and run this script again, or set GRAFT_EXECUTION_MODE=`"skip`" in $configFile." -ForegroundColor Red
    exit 1
  }
  Write-GraftReport $out
  $wiring = @($out | Where-Object { $_.StartsWith('✓ wiring: ', [StringComparison]::Ordinal) }) | Select-Object -Last 1
  if ($wiring) { Write-Host "  Graft graph: $($wiring.Substring(10).TrimEnd("`r"))" }
  # One repository gets graft\index.md; a folder of repositories gets a workspace, graft\workspace.json
  if (Test-Path "graft\workspace.json") {
    Write-Host "==> Graft workspace created at $((Get-Location).Path)\graft\workspace.json: one graph over the repositories of this folder" -ForegroundColor Green
  } elseif ((Test-Path "graft\index.md") -or (Test-Path "graft\INDEX.md")) {
    Write-Host "==> Graft index created at $((Get-Location).Path)\graft\index.md" -ForegroundColor Green
  } else {
    Write-Host "error: Graft finished without writing graft\index.md." -ForegroundColor Red
    exit 1
  }
} finally {
  Pop-Location
  [Console]::OutputEncoding = $consoleEncoding
}
