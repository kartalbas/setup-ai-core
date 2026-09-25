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
function Get-GraftLines([string[]]$lines) {
  # one @{ State; Path } per file Graft names; a path under this directory made relative
  $here = (Get-Location).Path; $found = @()
  foreach ($line in $lines) {
    $line = $line.TrimEnd("`r")
    if ($line.StartsWith('✓ wrote ', [StringComparison]::Ordinal)) { $path = $line.Substring(8); $state = 'wrote' }
    elseif ($line -cmatch '^✓[^:]*: (.*) \(([^()]*)\)$') { $path = $Matches[1]; $state = $Matches[2] }
    else { continue }
    if ($state -cnotin @('created', 'updated', 'appended', 'wrote')) { continue }
    foreach ($sep in @('\', '/')) { if ($path.StartsWith($here + $sep, [StringComparison]::Ordinal)) { $path = $path.Substring($here.Length + 1) } }
    $found += , @{ State = $state; Path = $path }
  }
  return , $found
}
function Write-GraftReport([string[]]$lines) {
  $repo = @(); $machine = @()
  foreach ($e in (Get-GraftLines $lines)) {
    if ($e.Path.StartsWith($HOME, [StringComparison]::Ordinal) -or $e.Path.StartsWith('~', [StringComparison]::Ordinal)) { $machine += "    $($e.Path) ($($e.State))" }
    else { $repo += "    $($e.Path) ($($e.State))" }
  }
  if ($repo.Count -gt 0) { Write-Host "  Graft wrote in the repository:"; foreach ($r in $repo) { Write-Host $r } }
  if ($machine.Count -gt 0) { Write-Host "  Graft wrote on the machine:"; foreach ($m in $machine) { Write-Host $m } }
}
# Graft wires every repository under a project folder, the harness clones (<name>-ai-core) among
# them. A harness clone is data, and ai-core push commits every file in it, so what Graft put
# into one is taken out again: a file it created, its block from a file it appended to, its
# graph and its MCP file.
# The .NET file calls below resolve a relative path against the process directory, not against
# Set-Location, so the path is made absolute first
function Test-GraftBlock([string]$file) {
  if (-not [System.IO.Path]::IsPathRooted($file)) { $file = Join-Path (Get-Location).Path $file }
  return (Test-Path -LiteralPath $file -PathType Leaf) -and ([System.IO.File]::ReadAllText($file) -cmatch '(?m)^<!-- graft:start -->')
}
function Remove-GraftBlock([string]$file) {
  # Graft's block and the blank lines before it go; a file left empty goes too
  if (-not [System.IO.Path]::IsPathRooted($file)) { $file = Join-Path (Get-Location).Path $file }
  $kept = @(); $skip = $false
  foreach ($line in [System.IO.File]::ReadAllLines($file)) {
    if ($line -ceq '<!-- graft:start -->') { $skip = $true }
    if ($line -ceq '<!-- graft:end -->') { $skip = $false; continue }
    if (-not $skip) { $kept += $line }
  }
  $text = ($kept -join "`n").TrimEnd("`n", "`r")
  if ($text) { [System.IO.File]::WriteAllText($file, $text + "`n", (New-Object System.Text.UTF8Encoding $false)) } else { Remove-Item -LiteralPath $file -Force }
}
function Test-GraftOnly([string]$path) {  # nothing in it but comments, blank lines and Graft's own paths (graft/, its cache, its graph)
  foreach ($line in [System.IO.File]::ReadAllLines($path)) {
    if ($line -cmatch '^\s*(#.*)?$' -or $line -cmatch '^!?/?graft/(\.cache/|\.graph/)?$') { continue }
    return $false
  }
  return $true
}
function Remove-GraftFromHarnessClones([string[]]$lines) {
  $taken = @()
  foreach ($e in (Get-GraftLines $lines)) {
    $p = $e.Path.Replace('\', '/'); $parts = $p -split '/', 2
    if ($parts.Count -lt 2 -or $parts[0] -cnotlike '*-ai-core' -or -not (Test-Path (Join-Path $parts[0] '.git')) -or -not (Test-Path -LiteralPath $p)) { continue }
    if (Test-GraftBlock $p) { Remove-GraftBlock $p }
    else {
      & git -C $parts[0] ls-files --error-unmatch $parts[1] 2>$null | Out-Null
      if ($LASTEXITCODE -eq 0) { continue }
      Remove-Item -LiteralPath $p -Recurse -Force
    }
    $taken += $p
  }
  # what Graft leaves without naming it, or named in an earlier run
  foreach ($c in (Get-ChildItem -Directory -Filter '*-ai-core' | Where-Object { Test-Path (Join-Path $_.FullName '.git') })) {
    foreach ($junk in @('graft', '.mcp.json', 'AGENTS.md', '.gitignore', '.ignore')) {
      $p = Join-Path $c.FullName $junk
      if (-not (Test-Path -LiteralPath $p) -or ($taken -ccontains "$($c.Name)/$junk")) { continue }
      & git -C $c.FullName ls-files --error-unmatch $junk 2>$null | Out-Null
      if ($LASTEXITCODE -eq 0) { continue }
      if ($junk -ceq 'AGENTS.md') { if (-not (Test-GraftBlock $p)) { continue }; Remove-GraftBlock $p }
      elseif ($junk -ceq '.gitignore' -or $junk -ceq '.ignore') { if (-not (Test-GraftOnly $p)) { continue }; Remove-Item -LiteralPath $p -Force }
      else { Remove-Item -LiteralPath $p -Recurse -Force }
      $taken += "$($c.Name)/$junk"
    }
  }
  if ($taken.Count -gt 0) { Write-Host "  taken out of the harness clones (data, not code): $($taken -join ', ')" }
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
  Remove-GraftFromHarnessClones $out
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
