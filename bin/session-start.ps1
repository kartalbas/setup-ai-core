# The session start: what an agent reads before its first action, in a repository or in a
# project folder. It refuses when a team mode is missing, prints the state of the checkout and,
# in a worktree of an issue, that issue's thread.
#
#   session-start.ps1 [-Json] [-Tool NAME ...]
#
[CmdletBinding()]
param (
  [switch]$Help,
  [switch]$Json,
  [string[]]$Tool = @()
)

if ($Help -or $args -ccontains "-h" -or $args -ccontains "--help" -or ($args.Count -gt 0 -and ($args[0] -ceq "--help" -or $args[0] -ceq "-h"))) {
  Write-Host "Usage: session-start.ps1 [-Json] [-Tool NAME ...] [-Help]"
  Write-Host ""
  Write-Host "The first step of every session. It runs team-modes-check and refuses when a mode is"
  Write-Host "missing; it prints the branch, the uncommitted files, the harness version, the rules, the"
  Write-Host "Graft graph and the gh login; in a worktree named issue-N-... it prints the thread of issue N"
  Write-Host "and whether it is assigned to you."
  Write-Host ""
  Write-Host "Options:"
  Write-Host "  -Help, -h, --help    Show this help message"
  Write-Host "  -Json                Print the same facts as JSON"
  Write-Host "  -Tool NAME           Check the team modes of this tool only (repeatable); with one tool, the"
  Write-Host "                       form the hooks use, its modes are switched on at the end of the output"
  Write-Host ""
  Write-Host "Exit status is 1 when a team mode is missing or the rules file is missing (run init)."
  Write-Host ""
  Write-Host "Examples:"
  Write-Host "  ai-core session-start"
  Write-Host "  ai-core session-start -Json"
  exit 0
}
if ($args.Count -gt 0) { Write-Host "error: unknown argument '$($args[0])' (see -Help)" -ForegroundColor Red; exit 2 }

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$core = Split-Path -Parent $PSScriptRoot

# 1. The gate: no session without the team modes. team-modes-check prints its own lines and the
#    refusal; nothing else is printed before it.
$toolArgs = @(); foreach ($t in $Tool) { $toolArgs += @('-Tool', $t) }
$modes = & pwsh -NoProfile -File (Join-Path $core "bin\team-modes-check.ps1") @toolArgs 2>&1 | ForEach-Object { "$_" }
if ($LASTEXITCODE -ne 0) { $modes | ForEach-Object { Write-Host $_ }; exit 1 }

# 2. The checkout
$root = (Get-Location).Path
$repoName = Split-Path -Leaf $root
$branch = "not-a-git-repo"
try {
  $b = git rev-parse --abbrev-ref HEAD 2>$null
  if ($LASTEXITCODE -eq 0 -and $b) { $branch = "$b".Trim() }
} catch {}
$dirtyCount = 0
try {
  $status = git status --porcelain 2>$null
  if ($status) { $dirtyCount = ($status | Measure-Object).Count }
} catch {}

$rulesPath = if (Test-Path ".ai-core\rules\rules.md") { ".ai-core/rules/rules.md" } elseif (Test-Path "rules\rules.md") { "rules/rules.md" } else { "" }
$rulesOk = ($rulesPath -ne "")
$localRulesOk = Test-Path ".ai-core\rules\rules.local.md"
$harnessVersion = if (Test-Path ".ai-core\VERSION") { (Get-Content ".ai-core\VERSION" -Raw).Trim() } else { "" }
$graftWorkspace = Test-Path "graft\workspace.json"
$graftOk = (Test-Path "graft\index.md") -or (Test-Path "graft\INDEX.md") -or $graftWorkspace
# The map: an AGENTS.md written by ai-core map names in its first line the commit it came
# from; the distance to HEAD says whether it is current
$mapCommit = ''; $mapBehind = ''
if ($branch -cne 'not-a-git-repo' -and (Test-Path 'AGENTS.md')) {
  $first = "$(Get-Content 'AGENTS.md' -TotalCount 1)".TrimEnd("`r")
  if ($first -cmatch 'ai-core map: generated [0-9-]+ from ([0-9a-f]+)') {
    $mapCommit = $Matches[1]
    $n = "$(& git rev-list --count "$mapCommit..HEAD" 2>$null)".Trim(); if ($LASTEXITCODE -eq 0 -and $n) { $mapBehind = $n }
  }
}

# The harness this checkout was assembled from (.ai-core\STAMP, one line per layer: name and
# commit) against the clones beside the repositories; and the releases, asked from the origins by
# update -Check, unless UPDATE_CHECK is "never" (config.env, or AI_CORE_UPDATE_CHECK in the
# environment). Nothing is updated here; the lines say what to run.
Import-Module (Join-Path $core 'lib\Layers.psm1') -Force
$folder = Get-ProjectFolderOf $root
$harnessCurrent = $true; $harnessStamp = ''
if (Test-Path ".ai-core\STAMP") {
  $stampLines = @(Get-Content ".ai-core\STAMP" | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
  $harnessStamp = $stampLines -join ';'
  foreach ($line in $stampLines) {
    $parts = @($line -split ' '); $lname = $parts[0]; $lcommit = if ($parts.Count -gt 1) { $parts[1] } else { '' }
    $ldir = if ($lname -ceq 'setup-ai-core') { $core } else { Join-Path $folder $lname }
    if (-not (Test-Path $ldir)) { continue }
    if ("$(& git -C $ldir rev-parse --short HEAD 2>$null)".Trim() -cne $lcommit) { $harnessCurrent = $false }
  }
} else { $harnessCurrent = $false }
$updateCheck = "$env:AI_CORE_UPDATE_CHECK"
if (-not $updateCheck -and (Test-Path ".ai-core\config.env")) {
  $l = Get-Content ".ai-core\config.env" | Where-Object { $_ -cmatch '^\s*UPDATE_CHECK\s*=' } | Select-Object -Last 1
  if ($l) { $updateCheck = ((($l -split '=', 2)[1] -split '#', 2)[0]).Trim(' ', "`t", "`r", '"', "'") }
}
$releaseLines = ''; $releaseState = 'skipped'   # current | available | unreachable | skipped
if ($updateCheck -cne 'never') {
  $releaseLines = ((& pwsh -NoProfile -File (Join-Path $core "bin\update.ps1") -Check 2>$null | Out-String) -replace "`r`n", "`n").TrimEnd()
  if ($LASTEXITCODE -eq 0) { $releaseState = 'current' } elseif ($LASTEXITCODE -eq 2) { $releaseState = 'available' } else { $releaseState = 'unreachable' }
}

$ghLoggedIn = $false
$ghUser = ""
if (Get-Command gh -ErrorAction SilentlyContinue) {
  try {
    $null = gh auth status 2>$null
    if ($LASTEXITCODE -eq 0) {
      $ghLoggedIn = $true
      $ghUser = (gh api user -q .login 2>$null).Trim()
    }
  } catch {}
}

# 3. The issue of this worktree: a branch or a directory named issue-N-<slug> carries issue N.
#    Its thread is read through issue-thread, and issue-mine says whether it is assigned to you.
function Get-WorktreeIssueNumber([string]$name) {
  $tail = ($name -split '[\\/]')[-1]
  if ($tail -cmatch '^issue-([0-9]+)(-|$)') { return $Matches[1] }
  return ""
}
$issue = Get-WorktreeIssueNumber $branch
if (-not $issue) { $issue = Get-WorktreeIssueNumber $root }
$thread = ""; $threadObject = $null; $assigned = $false; $mine = ""
if ($issue) {
  $raw = & pwsh -NoProfile -File (Join-Path $core "bin\issue-thread.ps1") $issue -Json 2>&1 | ForEach-Object { "$_" }
  if ($LASTEXITCODE -eq 0) {
    $threadObject = ($raw -join "`n") | ConvertFrom-Json
    $lines = @("#$($threadObject.number) $($threadObject.title)", "state: $($threadObject.state)",
      "labels: $(if ($threadObject.labels.Count -eq 0) { '-' } else { $threadObject.labels -join ', ' })", "", $threadObject.body)
    foreach ($c in $threadObject.comments) { $lines += @("", "--- $($c.author) $($c.created_at)", $c.body) }
    $thread = $lines -join "`n"
  } else {
    $thread = "The thread of #$issue could not be read: $($raw -join ' ')"
  }
  $mine = (& pwsh -NoProfile -File (Join-Path $core "bin\issue-mine.ps1") $issue 2>&1 | ForEach-Object { "$_" }) -join ' '
  if ($LASTEXITCODE -eq 0) { $assigned = $true }
}

# 4. The team modes of the tool this session runs in, switched on. The hook's output is the
#    agent's context, but Claude Code passes a hook's output whole only up to a size: in a measured
#    run of Claude Code 2.1.282, 10 000 characters arrived whole and 15 000 arrived as a 2 KB
#    preview, the rest in a file the agent never opens. So the output of one -Tool stays below
#    $hookLimit: a mode that is a skill is printed whole with its level where it fits and named
#    with the skill call that loads it where it does not, and the issue thread and the list of
#    uncommitted files are cut to leave room. A row whose level is "-" is a skill that loads when
#    a task calls for it; it is not switched on here. A plugin switches itself on through its own
#    hook and is named with its level. For one -Tool, the form the hooks use, in the text output only.
$hookLimit = 9500
$modesText = @(); $modesShort = @()
if ($Tool.Count -eq 1 -and -not $Json) {
  Import-Module (Join-Path $core 'lib\Board.psm1') -Force
  $table = if ($env:TEAM_MODES_FILE) { $env:TEAM_MODES_FILE } else { Get-DataFile 'team-modes.tsv' }
  $t = $Tool[0]; $homeDir = if ($env:HOME) { $env:HOME } else { $HOME }
  foreach ($row in @(Get-Content $table | Where-Object { $_ -and -not $_.StartsWith('#', [StringComparison]::Ordinal) })) {
    $c = $row.TrimEnd("`r") -split "`t"
    if ($c.Count -lt 5 -or $c[0] -cne $t -or $c[2] -ceq '-') { continue }
    $mode = $c[1]; $level = $c[2]; $pr = $c[3]; $upper = $mode.ToUpperInvariant()
    if ($pr.StartsWith('skill:', [StringComparison]::Ordinal)) {
      $name = $pr.Substring(6); $skill = $null
      foreach ($d in @((Join-Path $homeDir ".$t/skills/$name"), (Join-Path $root ".$t/skills/$name"), (Join-Path $homeDir ".agents/skills/$name"), (Join-Path $root ".agents/skills/$name"))) {
        if (Test-Path -LiteralPath (Join-Path $d 'SKILL.md') -PathType Leaf) { $skill = Join-Path $d 'SKILL.md'; break }
      }
      if (-not $skill) { continue }
      $body = @(); $front = $false; $n = 0
      foreach ($line in [System.IO.File]::ReadAllLines($skill)) {
        $n++
        if ($n -eq 1 -and $line -ceq '---') { $front = $true; continue }
        if ($front) { if ($line -ceq '---') { $front = $false }; continue }
        $body += $line
      }
      $modesText += "$upper MODE ACTIVE — level: $level ($skill follows; it binds this session)"; $modesText += $body; $modesText += "ARGUMENTS: $level"; $modesText += ''
      $modesShort += "$upper MODE ACTIVE — level: ${level}: its skill is too long for this output; load it before your first answer, the skill ``$name`` with the argument ``$level``"
    } else { $modesText += "$upper MODE: $level, switched on by its own hook"; $modesShort += "$upper MODE: $level, switched on by its own hook" }
  }
  if ("$thread".Length -gt 3000) { $thread = "$thread".Substring(0, 3000) + "`n[the thread goes on: ai-core issue-thread $issue]" }
  $budget = 1200 + "$thread".Length + "$mine".Length
  if ($dirtyCount -gt 0) { $budget += 1700 }
  if ($budget + ($modesText -join "`n").Length -gt $hookLimit) { $modesText = $modesShort }
}

if ($Json) {
  [PSCustomObject]@{
    repository          = $repoName
    root                = $root
    branch              = $branch
    uncommitted_files   = $dirtyCount
    harness_version     = $harnessVersion
    harness_current     = $harnessCurrent
    harness_stamp       = $harnessStamp
    release_state       = $releaseState
    release_lines       = $releaseLines
    rules_present       = $rulesOk
    rules_path          = $rulesPath
    local_rules_present = $localRulesOk
    graft_indexed       = $graftOk
    gh_authenticated    = $ghLoggedIn
    gh_user             = $ghUser
    map_commit          = $mapCommit
    map_behind          = $(if ($mapBehind -ne '') { [int]$mapBehind } else { $null })
    issue               = $(if ($issue) { [int]$issue } else { $null })
    assigned            = $assigned
    thread              = $threadObject
  } | ConvertTo-Json -Depth 6
  if ($rulesOk) { exit 0 } else { exit 1 }
}

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "AI Agent Session Start: $repoName" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "Branch           : $branch"
Write-Host "Uncommitted files: $dirtyCount"
Write-Host "Harness version  : $(if ($harnessVersion) { $harnessVersion } else { '✗ Missing (.ai-core/VERSION)' })"
Write-Host "Harness state    : $(if ($harnessCurrent) { '✓ Assembled from the current harness' } else { '✗ Assembled from an older harness (run ai-core init)' })"
# A Claude Code started from a terminal opened before the install runs this through the full path in
# its hook, while its own shell does not find ai-core: say how to call it there
if (-not (Get-Command ai-core -ErrorAction SilentlyContinue)) {
  $aiCoreCmd = (Join-Path $core 'bin/ai-core').Replace('\', '/')
  if ($aiCoreCmd -cmatch '^[a-z]:') { $aiCoreCmd = $aiCoreCmd.Substring(0, 1).ToUpperInvariant() + $aiCoreCmd.Substring(1) }
  Write-Host "ai-core on PATH  : ✗ not in this session; call it as `"$aiCoreCmd`", or start the agent from a terminal opened after the install"
}
if ($releaseState -ceq 'current') { Write-Host "Releases         : ✓ Current" }
elseif ($releaseState -ceq 'available') { Write-Host "Releases         : ! Available (run ai-core update)"; foreach ($rl in ($releaseLines -split "`n")) { Write-Host "                   $rl" } }
elseif ($releaseState -ceq 'unreachable') { Write-Host "Releases         : – Could not reach an origin"; foreach ($rl in ($releaseLines -split "`n")) { Write-Host "                   $rl" } }
else { Write-Host "Releases         : – Not checked (UPDATE_CHECK=never)" }
Write-Host "Rules file       : $(if ($rulesOk) { "✓ Present ($rulesPath)" } else { '✗ Missing' })"
Write-Host "Local rules      : $(if ($localRulesOk) { '✓ Present (.ai-core/rules/rules.local.md)' } else { '– None' })"
Write-Host "Graft code graph : $(if ($graftWorkspace) { '✓ Workspace (graft/workspace.json)' } elseif ($graftOk) { '✓ Indexed (graft/index.md)' } else { '✗ Not indexed (run ai-core graft)' })"
if ($branch -ceq 'not-a-git-repo') { Write-Host "Map              : – A project folder: AGENTS.md lists its repositories" }
elseif (-not $mapCommit) { Write-Host "Map              : – Generic (run ai-core map)" }
elseif ($mapBehind -eq '') { Write-Host "Map              : ? Generated from $mapCommit, a commit this clone does not have" }
elseif ([int]$mapBehind -eq 0) { Write-Host "Map              : ✓ Generated from $mapCommit, current" }
else { Write-Host "Map              : ! Generated from $mapCommit, $mapBehind commit(s) behind (run ai-core map)" }
if ($ghLoggedIn) {
  Write-Host "GitHub status    : ✓ Authenticated as @$ghUser" -ForegroundColor Green
} else {
  Write-Host "GitHub status    : ✗ Not logged in / gh missing" -ForegroundColor Yellow
}
Write-Host "==================================================" -ForegroundColor Cyan

if ($dirtyCount -gt 0) {
  Write-Host "warning: Working directory has $dirtyCount uncommitted changes:" -ForegroundColor Yellow
  if ($Tool.Count -eq 1 -and -not $Json) {
    $status = @(git status --short)
    $status | Select-Object -First 20 | ForEach-Object { Write-Host $_ }
    if ($status.Count -gt 20) { Write-Host "... and $($status.Count - 20) more (git status)" }
  } else {
    git status --short
  }
}

if ($issue) {
  Write-Host ""
  Write-Host "This worktree carries issue #$issue. $mine"
  Write-Host ""
  Write-Host $thread
  Write-Host ""
}

if (-not $rulesOk) {
  Write-Host "Not ready: no rules file found. Run ai-core init in this repository." -ForegroundColor Red
  exit 1
}
Write-Host "Ready for task execution." -ForegroundColor Green
if ($modesText.Count -gt 0) { Write-Host ""; foreach ($l in $modesText) { Write-Host $l } }
