# The push gate of every repository the harness serves, the PowerShell twin of pre-push.sh. Git
# starts the bash twin through the repository's .githooks/pre-push shim with its own standard
# input, one line per ref,
#
#   <local ref> <local sha> <remote ref> <remote sha>
#
# and with the working directory set to the tree being pushed. THAT TREE IS THE SUBJECT: every
# git call below reads the calling repository, and scripts\check.sh is that repository's own.
#
# What it judges, in this order, stopping at the first refusal:
#
#   1. the pushed commit is the one that is checked out
#   2. every pushed commit names its issue, or says why it does not
#   3. the team modes are installed
#   4. every Windows entry point in the tree is the one text, and not a copy that decides
#   5. the repository's own scripts\check.sh is green
#   6. gitleaks over the commits the push carries, in a repository that carries .gitleaks.toml
#
# Run from a prompt, with nothing on standard input, it judges what `git push` would send from
# the current branch: the commits its upstream does not have.
#
#   pre-push.ps1                              the gate, as git runs it
#   pre-push.ps1 -Install [-All <folder>]     write the shim into .githooks\pre-push and arm it
#
[CmdletBinding(PositionalBinding = $false)]
param (
  [switch]$Help,
  [switch]$Install,
  [string]$All = "",
  [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest = @()   # git's remote name and URL, not needed here
)

if ($Help -or $Rest -ccontains "-h" -or $Rest -ccontains "--help") {
  Write-Host "Usage: pre-push.ps1 [-Install [-All <folder>]]"
  Write-Host ""
  Write-Host "The push gate. Git runs it through the repository's .githooks/pre-push shim before a push"
  Write-Host "and it refuses the push, exit 1, when: a pushed commit is not the one checked out; a pushed"
  Write-Host "commit names no issue (#<n>), does not open with 'release:', touches more than *.md and"
  Write-Host "LICENSE files, and carries no 'No-issue: <who asked and why>' trailer; a team mode is"
  Write-Host "missing; a check.ps1 or build.ps1 differs from the one Windows entry point (lib/entry-point.ps1,"
  Write-Host "judged where scripts/check.sh exists); scripts/check.sh is red; or gitleaks finds a credential"
  Write-Host "in the pushed commits (where .gitleaks.toml exists). Merges are not judged; a deletion runs"
  Write-Host "no checks. Run from a prompt it judges the current branch against its upstream."
  Write-Host ""
  Write-Host "Options:"
  Write-Host "  -Install          Write the shim into .githooks/pre-push of the current repository and of"
  Write-Host "                    every worktree of it, set core.hooksPath to .githooks, commit the shim on"
  Write-Host "                    its own (No-issue: trailer) and push it by ref to the branch checked out,"
  Write-Host "                    through the gate; a worktree gets the file only. An unpushed commit that"
  Write-Host "                    names no issue and touches nothing but .gitignore gets the trailer that"
  Write-Host "                    says init wrote it, so the push goes through"
  Write-Host "  -All <folder>     With -Install: every git repository directly under the folder"
  Write-Host "  -Help             Show this help message"
  Write-Host ""
  Write-Host "Examples:"
  Write-Host "  ai-core pre-push"
  Write-Host "  ai-core pre-push -Install"
  Write-Host "  ai-core pre-push -Install -All ../my-org"
  exit 0
}

$ErrorActionPreference = 'Continue'
$coreRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$utf8 = New-Object System.Text.UTF8Encoding $false
if ($All -and -not $Install) { Write-Host "error: -All goes with -Install" -ForegroundColor Red; exit 2 }
if ($Install -and $Rest.Count -gt 0) { Write-Host "error: unexpected argument '$($Rest[0])' (see -Help)" -ForegroundColor Red; exit 2 }

function Deny-Push([string]$why) { [Console]::Error.WriteLine("pre-push: REFUSED — $why"); exit 1 }

# --- -Install: the shim, three lines that only start this gate -----------------------------
$shim = "#!/usr/bin/env bash`n# The push gate is ``ai-core pre-push`` (setup-ai-core); this file only starts it with git's own standard input.`ncommand -v ai-core >/dev/null 2>&1 || { echo `"pre-push: REFUSED — ai-core is not on the PATH of this shell, so nothing judged this push. Install setup-ai-core, or open a new terminal where its bin/ is on the PATH.`" >&2; exit 1; }`nexec ai-core pre-push `"`$@`"`n"
function Write-Shim([string]$dir) {  # the shim into <dir>\.githooks\pre-push; returns unchanged, refreshed or created
  $path = Join-Path $dir '.githooks\pre-push'
  $state = 'created'
  if (Test-Path -LiteralPath $path) {
    if ([System.IO.File]::ReadAllText($path).Replace("`r", "") -ceq $shim) { return 'unchanged' } else { $state = 'refreshed' }
  }
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
  [System.IO.File]::WriteAllText($path, $shim, $utf8)   # LF and no mark: git starts it through bash
  if (Get-Command chmod -ErrorAction SilentlyContinue) { & chmod +x $path }
  return $state
}
# The shim committed on its own, with the executable bit, and pushed by ref to the branch checked
# out; nothing when the commit already carries it
# An unpushed commit that names no issue and touches nothing but .gitignore was written by an
# init before init committed the block itself; it gets the trailer that says so, in one rebase of
# the unpushed commits, author kept. Git runs the two editors through its own sh.
function Add-GitignoreTrailer([string]$dir, [string]$label, [string]$branch) {
  & git -C $dir rev-parse -q --verify "origin/$branch" 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) { return $true }
  $shorts = @()
  foreach ($sha in @(& git -C $dir rev-list --reverse --no-merges "origin/$branch..HEAD" 2>$null | ForEach-Object { "$_" } | Where-Object { $_ })) {
    if ((& git -C $dir log -1 --format=%B $sha | Out-String) -cmatch '#[0-9]') { continue }
    if ("$(& git -C $dir log -1 --format=%s $sha)".StartsWith('release:', [StringComparison]::Ordinal)) { continue }
    if (((& git -C $dir log -1 "--format=%(trailers:key=No-issue,valueonly)" $sha | Out-String) -creplace '\s', '')) { continue }
    $files = @(& git -C $dir show --pretty=format: --name-only $sha 2>$null | ForEach-Object { "$_" } | Where-Object { $_ } | Sort-Object -Unique)
    if ($files.Count -ne 1 -or $files[0] -cne '.gitignore') { continue }
    $short = "$(& git -C $dir rev-parse --short $sha)"
    $shorts += $short
    Write-Host "pre-push: ${label}: $short ($(& git -C $dir log -1 --format=%s $sha)) touches only .gitignore and names no issue; it gets the trailer that says init wrote it"
  }
  if ($shorts.Count -eq 0) { return $true }
  $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-core-pre-push-" + [System.IO.Path]::GetRandomFileName())
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  $seq = (Join-Path $tmp 'seq.sh').Replace('\', '/'); $msg = (Join-Path $tmp 'msg.sh').Replace('\', '/')
  [System.IO.File]::WriteAllText($seq, (($shorts | ForEach-Object { "sed -i `"s/^pick $_ /reword $_ /`" `"`$1`"" }) -join "`n") + "`n", $utf8)
  [System.IO.File]::WriteAllText($msg, "printf `"\\nNo-issue: the .gitignore block written by ai-core init\\n`" >> `"`$1`"`n", $utf8)
  $env:GIT_SEQUENCE_EDITOR = "sh $seq"; $env:GIT_EDITOR = "sh $msg"
  try { & git -C $dir rebase -q -i "origin/$branch" 2>$null | Out-Null; $ok = ($LASTEXITCODE -eq 0) }
  finally { Remove-Item Env:GIT_SEQUENCE_EDITOR, Env:GIT_EDITOR -ErrorAction SilentlyContinue; Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
  if (-not $ok) { & git -C $dir rebase --abort 2>$null | Out-Null; [Console]::Error.WriteLine("pre-push: ${label}: the trailer could not be added; the commits are as they were"); return $false }
  return $true
}
# One path, with the executable bit, as one commit on HEAD, whatever else is staged; built from
# an index of its own, because `git commit -- <path>` reads the path from the working tree, which
# on Windows has no executable bit.
function Save-Only([string]$dir, [string]$path, [string]$subject, [string]$trailer) {
  $idx = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-core-index-" + [System.IO.Path]::GetRandomFileName())
  $env:GIT_INDEX_FILE = $idx
  try {
    & git -C $dir rev-parse -q --verify HEAD 2>$null | Out-Null
    $hasHead = ($LASTEXITCODE -eq 0)
    if ($hasHead) { & git -C $dir read-tree HEAD } else { & git -C $dir read-tree --empty }
    if ($LASTEXITCODE -ne 0) { return $false }
    & git -C $dir add --chmod=+x -- $path
    if ($LASTEXITCODE -ne 0) { return $false }
    $tree = "$(& git -C $dir write-tree)"
    if ($LASTEXITCODE -ne 0 -or -not $tree) { return $false }
  } finally { Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue; Remove-Item -Force $idx -ErrorAction SilentlyContinue }
  $commit = if ($hasHead) { "$(& git -C $dir commit-tree $tree -p HEAD -m $subject -m $trailer)" } else { "$(& git -C $dir commit-tree $tree -m $subject -m $trailer)" }
  if ($LASTEXITCODE -ne 0 -or -not $commit) { return $false }
  & git -C $dir update-ref HEAD $commit
  if ($LASTEXITCODE -ne 0) { return $false }
  & git -C $dir add --chmod=+x -- $path   # the index follows HEAD for this path, so it is clean
  return $true
}
function Send-Shim([string]$dir, [string]$label) {
  & git -C $dir ls-files --error-unmatch .githooks/pre-push 2>$null | Out-Null
  $tracked = ($LASTEXITCODE -eq 0)
  & git -C $dir diff --quiet HEAD -- .githooks/pre-push 2>$null
  if (-not ($tracked -and $LASTEXITCODE -eq 0)) {
    if (-not (Save-Only $dir '.githooks/pre-push' 'the push gate is ai-core pre-push' 'No-issue: written, committed and pushed by ai-core pre-push --install')) { [Console]::Error.WriteLine("pre-push: ${label}: the commit failed (see above); the shim is written"); return $false }
    Write-Host "pre-push: ${label}: committed $(& git -C $dir rev-parse --short HEAD)"
  }
  & git -C $dir remote get-url origin 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) { Write-Host "pre-push: ${label}: no origin; not pushed"; return $true }
  $branch = "$(& git -C $dir symbolic-ref --short -q HEAD 2>$null)"
  if ($LASTEXITCODE -ne 0 -or -not $branch) { [Console]::Error.WriteLine("pre-push: ${label}: not on a branch; not pushed"); return $false }
  & git -C $dir rev-parse -q --verify "origin/$branch" 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0 -and "$(& git -C $dir rev-list --count "origin/$branch..HEAD")" -ceq '0') { Write-Host "pre-push: ${label}: nothing to push"; return $true }
  if (-not (Add-GitignoreTrailer $dir $label $branch)) { return $false }
  & git -C $dir push --quiet origin "HEAD:$branch"
  if ($LASTEXITCODE -ne 0) { [Console]::Error.WriteLine("pre-push: ${label}: the push was refused or failed (see above); the commit stays"); return $false }
  Write-Host "pre-push: ${label}: pushed to origin/$branch"
  return $true
}
function Install-Shim([string]$dir) {  # $true written or unchanged, $false not a repository
  $name = Split-Path -Leaf $dir
  & git -C $dir rev-parse --is-inside-work-tree 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) { [Console]::Error.WriteLine("pre-push: $name is not a git repository; nothing installed"); return $false }
  # The hook runs only where git looks for it; the setting is the clone's own, never committed
  if ("$(& git -C $dir config --get core.hooksPath 2>$null)" -cne '.githooks') {
    & git -C $dir config core.hooksPath .githooks
    Write-Host "pre-push: ${name}: core.hooksPath set to .githooks"
  }
  # A relative core.hooksPath is read from the tree being pushed, so every worktree of the
  # repository carries its own copy of the shim, and git runs the file on disk, committed or not.
  # The checkout commits and pushes it; a worktree is somebody's issue and gets the file only.
  Write-Host "pre-push: ${name}: .githooks/pre-push $(Write-Shim $dir)"
  $own = [System.IO.Path]::GetFullPath($dir).TrimEnd('\', '/')
  foreach ($line in @(& git -C $dir worktree list --porcelain 2>$null | ForEach-Object { "$_" } | Where-Object { $_.StartsWith('worktree ', [StringComparison]::Ordinal) })) {
    $tree = [System.IO.Path]::GetFullPath($line.Substring(9)).TrimEnd('\', '/')
    if ($tree -ceq $own -or -not (Test-Path -LiteralPath $tree)) { continue }
    Write-Host "pre-push: $name (worktree $(Split-Path -Leaf $tree)): .githooks/pre-push $(Write-Shim $tree); it goes out with that worktree's own commit"
  }
  return (Send-Shim $dir $name)
}
if ($Install) {
  if ($All) {
    $allDir = (Resolve-Path $All).Path
    $ok = 0; $failed = @()
    foreach ($repo in (Get-ChildItem -Path $allDir -Directory | Where-Object { Test-Path (Join-Path $_.FullName '.git') })) {
      if (Install-Shim $repo.FullName) { $ok++ } else { $failed += $repo.Name }
    }
    Write-Host "==> pre-push -Install -All: the shim is in $ok repositories$(if ($failed) { '; failed: ' + ($failed -join ' ') })"
    if ($failed) { exit 1 } else { exit 0 }
  }
  if (Install-Shim (Get-Location).Path) { exit 0 } else { exit 1 }
}

# --- the gate --------------------------------------------------------------------------------
# Git exports GIT_DIR, GIT_WORK_TREE and GIT_INDEX_FILE to a hook. A check that starts git itself
# in a temporary directory would then act on the pushing repository instead of its own. Git
# started this hook in the tree being pushed, so every git call below finds the repository by the
# working directory and nothing needs the variables.
foreach ($v in @('GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_PREFIX', 'GIT_COMMON_DIR')) { Remove-Item -Path "Env:$v" -ErrorAction SilentlyContinue }
$root = "$(& git rev-parse --show-toplevel 2>$null)"
if ($LASTEXITCODE -ne 0 -or -not $root) { Write-Host "error: not inside a git repository" -ForegroundColor Red; exit 2 }
$head = "$(& git rev-parse HEAD 2>$null)"
if ($LASTEXITCODE -ne 0 -or -not $head) { Write-Host "error: this repository has no commit yet" -ForegroundColor Red; exit 2 }

# A sha of nothing but zeros, whatever length the repository's object format writes. SHA-1 sends
# forty digits and SHA-256 sends sixty-four, and a written-out constant reads the longer one as
# a real commit.
function Test-AllZero([string]$sha) { return ((-not $sha) -or ($sha -cmatch '^0+$')) }

# Git sends the ref lines on standard input. With nothing there - a prompt, an agent's shell,
# nothing piped - the subject is the push git would make from here: the current branch against
# its upstream, or against every remote ref when it has none yet.
$inputText = ''
if ([Console]::IsInputRedirected) { $inputText = [Console]::In.ReadToEnd() }
if (-not $inputText.Trim()) {
  $branch = "$(& git symbolic-ref --short -q HEAD 2>$null)"
  if ($LASTEXITCODE -ne 0 -or -not $branch) { Write-Host "error: not on a branch; nothing to judge" -ForegroundColor Red; exit 2 }
  $upstream = "$(& git rev-parse -q --verify '@{upstream}' 2>$null)"
  if ($LASTEXITCODE -ne 0 -or -not $upstream) { $upstream = '0000000000000000000000000000000000000000' }
  $upstreamName = "$(& git rev-parse --abbrev-ref '@{upstream}' 2>$null)"
  if ($LASTEXITCODE -ne 0 -or -not $upstreamName) { $upstreamName = 'every remote ref (no upstream yet)' }
  Write-Host "pre-push: judging $branch against $upstreamName"
  $inputText = "refs/heads/$branch $head refs/heads/$branch $upstream"
}

# Every commit this push sends, across every ref on standard input, and the ranges they came from.
$commits = @()
$scanRanges = @()
$pushing = $false
foreach ($line in ($inputText -split "`r?`n")) {
  $f = @($line.Trim() -split '\s+' | Where-Object { $_ })
  if ($f.Count -lt 2) { continue }
  $localRef = $f[0]; $localSha = $f[1]; $remoteRef = if ($f.Count -gt 2) { $f[2] } else { '' }; $remoteSha = if ($f.Count -gt 3) { $f[3] } else { '' }
  if (Test-AllZero $localSha) { continue }                   # a deletion sends no commit
  $pushing = $true
  # WHAT IS PUSHED IS RESOLVED TO A COMMIT FIRST. An annotated tag hands its own object's sha
  # here, never the commit it names, so comparing it to HEAD unresolved refuses every annotated
  # tag there is. Resolving it asks the question the refusal below means to ask: is the tree this
  # ref names the tree the checks read.
  $localCommit = "$(& git rev-parse --quiet --verify "$localSha^{commit}" 2>$null)"
  if ($LASTEXITCODE -ne 0 -or -not $localCommit) { $localCommit = $localSha }
  # Work is pushed by ref (`git push origin HEAD:<branch>`). A local sha that is not HEAD means
  # the tree the checks are about to run in is not the tree being sent.
  if ($localCommit -cne $head) { Deny-Push "$localRef is not what is checked out - push what you have: git push origin HEAD:$($remoteRef -creplace '^.*/', '')" }
  if (Test-AllZero $remoteSha) {
    # An all-zero remote sha is a ref the remote does not have yet, so there is no "before" to
    # compare with. Reading that as "everything reachable" judges the whole history - every commit
    # already published, by whatever rule held when it was written. A TAG is exactly that case: it
    # names a commit the branch already carries, so what it introduces is nothing at all.
    # Excluding every remote ref this checkout knows asks the question this loop means to ask -
    # which commits does this push add - and answers it with none where none are added.
    $range = "$localCommit --not --remotes=origin"
  } else {
    # A remote sha this checkout does not carry cannot be measured from. Letting `git rev-list`
    # fail quietly would leave the range empty, and an empty range is read below as a push with
    # nothing in it - so a force push over an unfetched remote would go out unjudged.
    & git cat-file -e "$remoteSha^{commit}" 2>$null
    if ($LASTEXITCODE -ne 0) { Deny-Push "the commit $remoteSha that $remoteRef points at is not in this checkout, so the commits being pushed cannot be listed. Run git fetch, then push again." }
    $range = "$remoteSha..$localCommit"
  }
  $commits += @(& git rev-list --no-merges @($range -split ' ') 2>$null | ForEach-Object { "$_" } | Where-Object { $_ })
  $scanRanges += $range
}

# Nothing to send, or nothing but deletions: there is nothing to judge and nothing to test.
if (-not $pushing) { exit 0 }
if ($commits.Count -eq 0) { Write-Host 'pre-push: nothing new to send.'; exit 0 }

# WHAT EXCUSES A COMMIT FROM NAMING AN ISSUE, and why each one is here:
#
#   a release stamp        the subject opens with `release:`; a version bump belongs to no issue
#   an explanation only    every file it touches is a `*.md` or a LICENSE; a typo in a document
#                          is not worth a ticket, and requiring one is how documents stop being
#                          corrected
#   a No-issue: trailer    somebody wrote down who asked and why there is no ticket. It is a
#                          sentence a reviewer reads, not a way around the rule
#
# THE NAME IS MATCHED WITHOUT ITS FOLDER. `LICENSE-MIT` and `docs/LICENSE` explain as much as
# `LICENSE` does, and a rule that reads the whole path gives one commit two verdicts depending
# on which repository it lands in.
function Test-ExplainsOnly([string]$sha) {
  $files = @(& git show --pretty=format: --name-only $sha 2>$null | ForEach-Object { "$_" } | Where-Object { $_ })
  if ($files.Count -eq 0) { return $false }
  foreach ($file in $files) {
    $base = $file -creplace '^.*/', ''
    if (-not ($base -clike '*.md' -or $base -clike 'LICENSE*')) { return $false }
  }
  return $true
}
$unnamed = 0
foreach ($sha in $commits) {
  $message = (& git log -1 --format=%B $sha | Out-String)
  $subject = "$(& git log -1 --format=%s $sha)"
  if ($message -cmatch '#[0-9]') { continue }
  if ($subject.StartsWith('release:', [StringComparison]::Ordinal)) { continue }
  # The trailer is read the way git reads a trailer, and it has to name a reason. Searching the
  # whole message for the two words accepts an empty `No-issue:` and accepts the words inside a
  # body sentence, and both of those are exactly the way around the rule this excuse is not.
  $trailer = ((& git log -1 "--format=%(trailers:key=No-issue,valueonly)" $sha | Out-String) -creplace '\s', '')
  if ($trailer) { continue }
  if (Test-ExplainsOnly $sha) { continue }
  [Console]::Error.WriteLine("pre-push: $(& git log -1 --format='%h %s' $sha) names no issue")
  $unnamed++
}
if ($unnamed -gt 0) { Deny-Push "$unnamed commit(s) name no issue. Write #<number> in the message, open the subject with 'release:', touch only files that explain, or add a 'No-issue: <who asked and why>' trailer." }

# The check prints one MISSING line per mode with the command that installs it, so it is never
# run quiet: the refusal sends the person to those lines.
& pwsh -NoProfile -File (Join-Path $coreRoot 'bin\team-modes-check.ps1')
if ($LASTEXITCODE -ne 0) { Deny-Push 'the team modes are missing - the lines above say which and how to install them' }

# THE WINDOWS ENTRY POINT IS ONE TEXT, AND THIS IS WHERE IT IS HELD. Where the checks are written
# in scripts\check.sh, check.ps1 and build.ps1 decide nothing: each starts the .sh file of its own
# name, so one text serves every repository. Overwrite one of them with two lines that print the
# verdict and exit 0 and the person at the keyboard reads that the checks passed while nothing
# ran. No other step here can see that, because every one of them reads the .sh side.
#
# THE FILE NAME IS THE RULE AND NO REPOSITORY IS LISTED. The name is matched in full and without
# its folder: a pattern of *check.ps1 would take bin\case-check.ps1 with it, and that is a twin
# implementation with a test of its own, not a copy of anything.
$checkSh = Join-Path $root 'scripts/check.sh'
if (Test-Path -LiteralPath $checkSh) {
  $entry = Join-Path $coreRoot 'lib\entry-point.ps1'
  if (-not (Test-Path -LiteralPath $entry)) { Deny-Push "$entry is missing, and it is the one text every Windows entry point copies." }
  $want = [System.IO.File]::ReadAllText($entry).Replace("`r", "")
  foreach ($door in (& git -C $root -c core.quotePath=false ls-files -- '*.ps1' | ForEach-Object { "$_" } | Where-Object { $_ })) {
    $base = $door -creplace '^.*/', ''
    if ($base -cne 'check.ps1' -and $base -cne 'build.ps1') { continue }
    $full = Join-Path $root $door
    if (-not (Test-Path -LiteralPath $full)) { continue }
    # Both sides are read without their carriage returns. A checkout that wrote CRLF runs the
    # same program, and refusing it would report drift where there is none.
    if ([System.IO.File]::ReadAllText($full).Replace("`r", "") -cne $want) {
      Deny-Push "$door is not the Windows entry point every repository carries. It starts the .sh file of its own name and decides nothing, and this copy says something else. Restore it: cp '$entry' '$full'"
    }
  }
}

# The wait is announced here and not earlier, so a push that is refused above is not first
# promised a run it never gets. How long it takes is the repository's own business. The Windows
# entry point beside the check starts it where there is one.
if (Test-Path -LiteralPath $checkSh) {
  Write-Host "pre-push: $root/scripts/check.sh runs here, before anything leaves this machine."
  $checkPs = Join-Path $root 'scripts/check.ps1'
  if (Test-Path -LiteralPath $checkPs) { & pwsh -NoProfile -File $checkPs } else { & bash $checkSh }
  if ($LASTEXITCODE -ne 0) { Deny-Push 'a check failed - the lines above name which one.' }
} else {
  Write-Host 'pre-push: no scripts/check.sh in this repository; nothing runs before the push.'
}

# THE COMMITS ARE SCANNED TOO, not only the working copy. scripts\check.sh reads one state: the
# files git would let you commit right now. A credential that was committed in one pushed commit
# and taken out again in a later one is not in that state, and it would leave this machine
# unread. The commits being pushed are the only place it still stands, and this hook is the only
# thing that knows which those are. The scan is armed by the file gitleaks reads its rules from,
# so a repository joins by carrying the configuration and no repository is named here.
if (Test-Path -LiteralPath (Join-Path $root '.gitleaks.toml')) {
  Write-Host 'pre-push: gitleaks over the commits this push carries.'
  if (-not (Get-Command gitleaks -ErrorAction SilentlyContinue)) { Deny-Push "gitleaks is not on this path, and $root/.gitleaks.toml says the commits being pushed are read for credentials." }
  foreach ($scanRange in $scanRanges) {
    & gitleaks git --no-banner "--log-opts=$scanRange" $root
    if ($LASTEXITCODE -ne 0) { Deny-Push 'a credential stands in a commit this push carries. The lines above name the commit, the file and the rule. Take it out of the history - a commit that is pushed cannot be recalled.' }
  }
}

Write-Host 'pre-push: every check passed.'
