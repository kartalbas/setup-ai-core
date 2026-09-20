<#
.SYNOPSIS
Open the worktree for one issue, move its card, and print what the issue asks for.

.EXAMPLE
./start-issue.ps1 -Number 163

.NOTES
The three happen together on purpose. A worktree cut from a stale master carries work nobody
asked for; a card left in the previous column tells everyone else the work has not started; and
code written without reading the issue is a change measured against a memory of it. Any one of
them done alone is often not done.

WORK STAYS ON master. There is no feature branch and no pull request: the change is pushed with
`git push origin HEAD:master` and the hook decides whether it may go. What this creates is a
WORKTREE - a second working directory of the same repository - so several issues can be open at
once without one of them holding the checkout, and so a run of the checks in one is not
disturbed by an edit in another. The worktree stands OUTSIDE the repository, under
../.worktrees/<repo>/, because a worktree committed into the tree it is a worktree of is a loop
nobody unpicks. Its branch is temporary and carries the worktree's own name; it exists so the
worktree has somewhere to commit, and it is deleted with the worktree.

It is run from inside the repository the work belongs to. The default branch is READ from
origin/HEAD and never assumed.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidatePattern('^[0-9]+\z', ErrorMessage = "the issue number must be numeric, not '{0}'")][string] $Number
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../lib/Board.psm1') -Force

function Invoke-Git {
  # git writes diagnostics to stderr; both streams are wanted here, because a refusal names
  # what git said. The preference is lowered for the call only, so a line on stderr is text
  # to read and not an exception thrown into the middle of the answer.
  $kept = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & git @args 2>&1
    return [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Text = ((@($out) -join "`n").Trim()) }
  } finally { $ErrorActionPreference = $kept }
}

& git rev-parse --show-toplevel *>$null
if ($LASTEXITCODE -ne 0) {
  Stop-WithError 'not inside a git working copy - run this from the repository the work belongs to'
}

# No worktree without the three team modes, for the same reason session-start refuses without
# them: the rules say no work starts, and a worktree is where work starts.
$modes = & (Join-Path $PSScriptRoot 'team-modes-check.ps1') 6>&1 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
  [Console]::Error.WriteLine($modes.TrimEnd())
  Stop-WithError 'the team modes are missing - the lines above say which and how to install them'
}

# Everything below is measured against what origin has right now, so the refs come first.
$fetched = Invoke-Git fetch origin
if (-not $fetched.Ok) {
  Stop-WithError "could not reach origin: $($fetched.Text) - fix the connection first, this worktree is cut from what origin has"
}

$dirty = Invoke-Git status --porcelain
if ($dirty.Text -ne '') {
  Stop-WithError 'the working copy has changes - commit or put them aside before opening a worktree'
}

$head = Invoke-Git symbolic-ref refs/remotes/origin/HEAD
if (-not $head.Ok -or $head.Text -eq '') {
  Stop-WithError "cannot read the default branch from origin/HEAD - run 'git remote set-head origin -a', then run this again"
}
$default = $head.Text -creplace '^refs/remotes/origin/', ''

$counted = Invoke-Git rev-list --count "$default..origin/$default"
if (-not $counted.Ok -or $counted.Text -eq '') {
  Stop-WithError "cannot compare $default with origin/$default - is the remote branch there?"
}
if ([int]$counted.Text -ne 0) {
  Stop-WithError "$default is $($counted.Text) commit(s) behind origin/$default - pull, then run this again"
}

# No worktree without an issue: the title is what it is named after, and the thread is what the
# change will be measured against.
$reader = Join-Path $PSScriptRoot 'issue-thread.ps1'
try { $raw = (@(& $reader -Number $Number -Json) -join "`n").Trim() }
catch { Stop-WithError "no worktree without an issue - the issue could not be read: $($_.Exception.Message)" }
$thread = $raw | ConvertFrom-Json -DateKind String
$title = "$($thread.title)"
if ($title.Trim() -eq '') {
  Stop-WithError "issue $Number has no title, so no worktree name can be built from it"
}

# Only an issue assigned to you is taken up (rules.md, the issue rules): the worktree is not cut
# for somebody else's issue, and not for one nobody has been given yet.
$mine = @(& (Join-Path $PSScriptRoot 'issue-mine.ps1') -Number $Number 2>&1 | ForEach-Object { "$_" }) -join "`n"
if ($LASTEXITCODE -ne 0) { Stop-WithError $mine }

# The readable half of the name. Everything that is not a letter or a digit becomes a hyphen,
# runs of hyphens collapse, and the result is cut to forty characters - the name is read in a
# directory listing beside a dozen others, and a whole title carried into it makes that listing
# unreadable.
$slug = ((ConvertTo-AsciiLowercase -Text $title) -creplace '[^a-z0-9]+', '-').Trim('-')
if ($slug.Length -gt 40) { $slug = $slug.Substring(0, 40) }
$slug = $slug.TrimEnd('-')
$name = "issue-$Number-$slug"

# Where the worktrees stand: beside the CHECKOUT, never inside it, and grouped per repository so
# two repositories working the same issue number do not collide. The main checkout is found
# through --git-common-dir, so this answers the same from inside another worktree.
$common = (Invoke-Git rev-parse --git-common-dir).Text
$main = (Resolve-Path (Join-Path $common '..')).Path -replace '\\', '/'
$repoFolder = $main.Substring($main.LastIndexOf('/') + 1)
$container = "$($main.Substring(0, $main.LastIndexOf('/')))/.worktrees/$repoFolder"
$path = "$container/$name"

$taken = @((Invoke-Git for-each-ref '--format=%(refname:short)' refs/heads refs/remotes/origin).Text -split "`n" |
  Where-Object { $_ -cmatch "(^|/)issue-$Number(-|$)" })
if ($taken.Count -gt 0) {
  Stop-WithError "a branch for this issue exists already: $($taken -join ', ') - use its worktree instead"
}
if (Test-Path -LiteralPath $path) {
  Stop-WithError "$path is already there - use it, or remove it with 'git worktree remove'"
}

New-Item -ItemType Directory -Force -Path $container | Out-Null
$made = Invoke-Git worktree add -b $name $path "origin/$default"
if (-not $made.Ok) { Stop-WithError "the worktree could not be created: $($made.Text)" }
"Worktree $path on $name, cut from origin/$default."

# The card and the worktree move together, and a card that did not move is said out loud rather
# than left for the next person to notice on the board.
try { & (Join-Path $PSScriptRoot 'issue-status.ps1') -Number $Number -Status implementing }
catch { Write-Error "the card did NOT move: $($_.Exception.Message) - move it before you start" -ErrorAction Continue }

# The harness is not in the repository, so the new worktree gets it here: the main checkout's own
# .ai-core data (its config, its local rules, its documents) and then init, which assembles the
# rules and builds the graph. A worktree that starts without them starts without the rules.
if (Test-Path (Join-Path $main '.ai-core')) {
  if (Test-Path (Join-Path $path '.ai-core')) { Remove-Item -Recurse -Force (Join-Path $path '.ai-core') }
  Copy-Item -Recurse (Join-Path $main '.ai-core') (Join-Path $path '.ai-core')
}
& pwsh -NoProfile -File (Join-Path (Split-Path -Parent $PSScriptRoot) 'bin\init.ps1') -TargetDir $path -NoDoctor
if ($LASTEXITCODE -ne 0) { Write-Host "the harness is NOT complete in the worktree: run 'ai-core init' there before you start" }

try { & $reader -Number $Number } catch { }
