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
#   5. the names of the new directories are derived from the families the trees carry
#   6. the repository's own scripts\check.sh is green
#   7. gitleaks over the commits the push carries, in a repository that carries .gitleaks.toml
#
# Run from a prompt, with nothing on standard input, it judges what `git push` would send from
# the current branch: the commits its upstream does not have.
#
#   pre-push.ps1                              the gate, as git runs it
#   pre-push.ps1 -Install [-All <folder>]     write the two shims into .githooks\ and arm them
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
  Write-Host "judged where scripts/check.sh exists); a file the push adds or changes starts with #! and is"
  Write-Host "not executable; a subject is longer than 72 characters; a message carries an assistant's or a"
  Write-Host "vendor's attribution; an added comment names an issue as (#<n>) or <repo>#<n>; an existing"
  Write-Host "migrations/*.sql is changed or removed (a 'Migration: <why>' trailer allows it); one spelling"
  Write-Host "of a script changes without the other where x.sh and x.ps1 both stand (a 'Twin: <why>' trailer"
  Write-Host "allows it); a new directory's name is invented where the families"
  Write-Host "of the trees give it (a 'Naming: <why>' trailer keeps one); scripts/check.sh is red; or gitleaks"
  Write-Host "finds a credential in the pushed commits (where .gitleaks.toml exists). Merges are not judged; a deletion runs"
  Write-Host "no checks. Run from a prompt it judges the current branch against its upstream."
  Write-Host ""
  Write-Host "Options:"
  Write-Host "  -Install          Write the two shims, .githooks/pre-push (this gate) and .githooks/post-checkout"
  Write-Host "                    (ai-core init in a new worktree), into the current repository and every"
  Write-Host "                    worktree of it, set core.hooksPath to .githooks, commit them on their own"
  Write-Host "                    (No-issue: trailer) and push by ref to the branch checked out, through the"
  Write-Host "                    gate; a worktree gets the files only. An unpushed commit that names no"
  Write-Host "                    issue and touches nothing but .gitignore gets the trailer that says init"
  Write-Host "                    wrote it, so the push goes through. The checkout catches up with its"
  Write-Host "                    origin first; one behind it with work of its own gets nothing"
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

Import-Module (Join-Path $coreRoot 'lib\Layers.psm1') -Force
function Deny-Push([string]$why) { [Console]::Error.WriteLine("pre-push: REFUSED — $why"); exit 1 }

# --- -Install: two shims; the first only starts this gate ------------------------------------
$shim = "#!/usr/bin/env bash`n# The push gate is ``ai-core pre-push`` (setup-ai-core); this file only starts it with git's own standard input.`ncommand -v ai-core >/dev/null 2>&1 || { echo `"pre-push: REFUSED — ai-core is not on the PATH of this shell, so nothing judged this push. Install setup-ai-core, or open a new terminal where its bin/ is on the PATH.`" >&2; exit 1; }`nexec ai-core pre-push `"`$@`"`n"
# The second shim: the harness is in no commit, so a worktree starts without it. Git runs
# .githooks/post-checkout in the new tree after `git worktree add` (third argument 1, as after
# any branch checkout), and where .ai-core/ is missing the shim starts `ai-core init`. It exits 0
# whatever happened, because a failing hook fails the checkout too; what went wrong is on stderr.
$shimCheckout = "#!/usr/bin/env bash`n# A new worktree starts with the harness: git runs this file after ``git worktree add`` and after every checkout; where .ai-core/ is missing, ``ai-core init`` (setup-ai-core) writes it.`n[ `"`${3:-0}`" = 1 ] && [ ! -d .ai-core ] || exit 0`nunset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR`ncommand -v ai-core >/dev/null 2>&1 || { echo `"post-checkout: ai-core is not on the PATH of this shell, so this worktree has no harness yet; run ai-core init here before you start`" >&2; exit 0; }`nai-core init --no-doctor || echo `"post-checkout: the harness is NOT complete in this worktree (see above); run ai-core init here before you start`" >&2`n"
$shimPaths = @('.githooks/pre-push', '.githooks/post-checkout')
# Git runs the shims through bash, and a shim checked out with CRLF fails on the first line; the
# repository's .gitattributes gets a rule for them where no rule makes them check out with LF.
$attrRule = '.githooks/* text eol=lf'
$script:attrAdded = $false
function Write-Attributes([string]$dir) {  # the rule into <dir>\.gitattributes when nothing makes the shims LF; returns unchanged or added
  $eol = "$(& git -C $dir check-attr eol -- .githooks/pre-push 2>$null)"
  if ($eol.Trim().EndsWith(': lf', [StringComparison]::Ordinal)) { return 'unchanged' }
  $path = Join-Path $dir '.gitattributes'
  $text = if (Test-Path -LiteralPath $path) { [System.IO.File]::ReadAllText($path) } else { '' }
  if ($text.Length -gt 0 -and -not $text.EndsWith("`n", [StringComparison]::Ordinal)) { $text += "`n" }
  [System.IO.File]::WriteAllText($path, $text + $attrRule + "`n", $utf8)
  return 'added'
}
function Write-Shim([string]$dir, [string]$hook, [string]$text) {  # the text into <dir>\.githooks\<hook>; returns unchanged, refreshed or created
  $path = Join-Path $dir ".githooks\$hook"
  $state = 'created'
  if (Test-Path -LiteralPath $path) {
    if ([System.IO.File]::ReadAllText($path).Replace("`r", "") -ceq $text) {
      if ($IsWindows -or ((Get-Item -LiteralPath $path).UnixFileMode -band [System.IO.UnixFileMode]::UserExecute)) { return 'unchanged' }
      & chmod +x $path; return 'made executable'
    } else { $state = 'refreshed' }
  }
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
  [System.IO.File]::WriteAllText($path, $text, $utf8)   # LF and no mark: git starts it through bash
  if (Get-Command chmod -ErrorAction SilentlyContinue) { & chmod +x $path }
  return $state
}
function Write-Shims([string]$dir, [string]$label, [string]$suffix, [switch]$Checkout) {  # both shims, one report line each, and the attributes rule where it is missing
  Write-Host "pre-push: ${label}: .githooks/pre-push $(Write-Shim $dir 'pre-push' $shim)$suffix"
  Write-Host "pre-push: ${label}: .githooks/post-checkout $(Write-Shim $dir 'post-checkout' $shimCheckout)$suffix"
  if ((Write-Attributes $dir) -ceq 'added') {
    Write-Host "pre-push: ${label}: .gitattributes: $attrRule added; the shims check out LF everywhere$suffix"
    if ($Checkout) { $script:attrAdded = $true }
  }
}
# The shims committed on their own, with the executable bit, and pushed by ref to the branch
# checked out; nothing when the commit already carries them
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
# The paths, the shims with the executable bit, as one commit on HEAD, whatever else is staged;
# built from an index of its own, because `git commit -- <path>` reads the path from the working
# tree, which on Windows has no executable bit.
function Add-Paths([string]$dir, [string[]]$paths) {  # into the index git works on; the shims with the executable bit
  foreach ($p in $paths) {
    if ($p.StartsWith('.githooks/', [StringComparison]::Ordinal)) { & git -C $dir add --chmod=+x -- $p } else { & git -C $dir add -- $p }
    if ($LASTEXITCODE -ne 0) { return $false }
  }
  return $true
}
function Save-Only([string]$dir, [string]$subject, [string]$trailer, [string[]]$paths) {
  $idx = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-core-index-" + [System.IO.Path]::GetRandomFileName())
  $env:GIT_INDEX_FILE = $idx
  try {
    & git -C $dir rev-parse -q --verify HEAD 2>$null | Out-Null
    $hasHead = ($LASTEXITCODE -eq 0)
    if ($hasHead) { & git -C $dir read-tree HEAD } else { & git -C $dir read-tree --empty }
    if ($LASTEXITCODE -ne 0) { return $false }
    if (-not (Add-Paths $dir $paths)) { return $false }
    $tree = "$(& git -C $dir write-tree)"
    if ($LASTEXITCODE -ne 0 -or -not $tree) { return $false }
  } finally { Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue; Remove-Item -Force $idx -ErrorAction SilentlyContinue }
  $commit = if ($hasHead) { "$(& git -C $dir commit-tree $tree -p HEAD -m $subject -m $trailer)" } else { "$(& git -C $dir commit-tree $tree -m $subject -m $trailer)" }
  if ($LASTEXITCODE -ne 0 -or -not $commit) { return $false }
  & git -C $dir update-ref HEAD $commit
  if ($LASTEXITCODE -ne 0) { return $false }
  Add-Paths $dir $paths | Out-Null   # the index follows HEAD for these paths, so it is clean
  return $true
}
function Send-Shim([string]$dir, [string]$label) {
  $paths = @($shimPaths); if ($script:attrAdded) { $paths += '.gitattributes' }
  & git -C $dir ls-files --error-unmatch @paths 2>$null | Out-Null
  $tracked = ($LASTEXITCODE -eq 0)
  & git -C $dir diff --quiet HEAD -- @paths 2>$null
  $same = ($tracked -and $LASTEXITCODE -eq 0)
  # a commit whose shims lack the executable bit (a copy that drops the file modes writes them so) is
  # one git skips them in: it gets a commit of its own as well
  $modeless = @(& git -C $dir ls-tree HEAD -- @shimPaths 2>$null | Where-Object { "$_" -cnotmatch '^100755 ' })
  if (-not ($same -and $modeless.Count -eq 0)) {
    if (-not (Save-Only $dir 'the hooks of ai-core: the push gate, init in a new worktree' 'No-issue: written, committed and pushed by ai-core pre-push --install' $paths)) { [Console]::Error.WriteLine("pre-push: ${label}: the commit failed (see above); the shims are written"); return $false }
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
# A gitleaks that can run the scan of this gate: `gitleaks git` came with gitleaks 8.19
function Test-GitleaksGit { if (-not (Get-Command gitleaks -ErrorAction SilentlyContinue)) { return $false }; & gitleaks git --help *> $null; return ($LASTEXITCODE -eq 0) }
function Install-Shim([string]$dir) {  # $true written or unchanged, $false not a repository
  $name = Split-Path -Leaf $dir
  & git -C $dir rev-parse --is-inside-work-tree 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) { [Console]::Error.WriteLine("pre-push: $name is not a git repository; nothing installed"); return $false }
  # The shims go out through this gate: where .gitleaks.toml arms its scan and no gitleaks can run
  # it, their push is refused and the commit stays behind, so nothing is written
  if ((Test-Path -LiteralPath (Join-Path $dir '.gitleaks.toml') -PathType Leaf) -and -not (Test-GitleaksGit)) {
    [Console]::Error.WriteLine("pre-push: ${name}: .gitleaks.toml arms the gitleaks scan of this gate, and no gitleaks 8.19 or newer is on this path, so the push of the shims would be refused; nothing installed. Run ai-core doctor here, which installs it, then this again."); return $false
  }
  # Their commit goes on top of what the origin has: the checkout catches up first
  $caught = Sync-Checkout $dir
  if (-not $caught.Ok) { [Console]::Error.WriteLine("pre-push: ${name}: this checkout is $($caught.Note); nothing installed"); return $false }
  if ($caught.Note) { Write-Host "pre-push: ${name}: $($caught.Note)" }
  # The hook runs only where git looks for it; the setting is the clone's own, never committed
  if ("$(& git -C $dir config --get core.hooksPath 2>$null)" -cne '.githooks') {
    & git -C $dir config core.hooksPath .githooks
    Write-Host "pre-push: ${name}: core.hooksPath set to .githooks"
  }
  # A relative core.hooksPath is read from the tree git works in, so every worktree of the
  # repository carries its own copy of the shims, and git runs the files on disk, committed or not.
  # The checkout commits and pushes them; a worktree is somebody's issue and gets the files only.
  $script:attrAdded = $false
  Write-Shims $dir $name '' -Checkout
  $own = [System.IO.Path]::GetFullPath($dir).TrimEnd('\', '/')
  foreach ($line in @(& git -C $dir worktree list --porcelain 2>$null | ForEach-Object { "$_" } | Where-Object { $_.StartsWith('worktree ', [StringComparison]::Ordinal) })) {
    $tree = [System.IO.Path]::GetFullPath($line.Substring(9)).TrimEnd('\', '/')
    if ($tree -ceq $own -or -not (Test-Path -LiteralPath $tree)) { continue }
    Write-Shims $tree "$name (worktree $(Split-Path -Leaf $tree))" "; it goes out with that worktree's own commit"
  }
  if (-not (Send-Shim $dir $name)) { return $false }
  # a hook of the project's own that git skips for want of the executable bit is named, not changed
  foreach ($line in @(& git -C $dir ls-tree HEAD -- .githooks/ 2>$null | ForEach-Object { "$_" } | Where-Object { $_.StartsWith('100644 ', [StringComparison]::Ordinal) })) {
    Write-Host "pre-push: ${name}: $(($line -split "`t", 2)[1]) is not executable, so git skips it; it is the project's own and stays as it is"
  }
  return $true
}
if ($Install) {
  if ($All) {
    $allDir = (Resolve-Path $All).Path
    $ok = 0; $failed = @()
    foreach ($repo in (Get-ChildItem -Path $allDir -Directory | Where-Object { Test-Path (Join-Path $_.FullName '.git') })) {
      if (Install-Shim $repo.FullName) { $ok++ } else { $failed += $repo.Name }
    }
    Write-Host "==> pre-push -Install -All: the hooks are in $ok repositories$(if ($failed) { '; failed: ' + ($failed -join ' ') })"
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

# The default branch: origin/HEAD where it names a branch this clone has, else what the origin
# names (a clone keeps origin/HEAD pointing at a branch the origin renamed since), else master
$default = "$(& git symbolic-ref --short -q refs/remotes/origin/HEAD 2>$null)".Trim()
& git rev-parse -q --verify "refs/remotes/$default" 2>$null | Out-Null
if (-not $default -or $LASTEXITCODE -ne 0) {
  $default = "$(& git ls-remote --symref origin HEAD 2>$null | ForEach-Object { if ("$_" -cmatch '^ref: refs/heads/(\S+)\s+HEAD$') { $Matches[1] } })".Trim()
}
if ($default.StartsWith('origin/', [StringComparison]::Ordinal)) { $default = $default.Substring(7) }
if (-not $default) { $default = 'master' }

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
    # A push that is not a fast-forward drops commits the remote has. On the default branch that is
    # history everybody else builds on, so it is refused, whatever tool or person forced it.
    if ($remoteRef -ceq "refs/heads/$default") {
      & git merge-base --is-ancestor $remoteSha $localCommit 2>$null
      if ($LASTEXITCODE -ne 0) { Deny-Push "the push to $default is not a fast-forward: it would drop commits the remote has. Fetch, rebase onto origin/$default and push again; a force push to the default branch is refused." }
    }
    # What the remote carries on ANY ref is published already. A branch that merged the default
    # branch brings every commit the default branch gained since the fork; judging those again
    # holds commits other flows wrote to today's rules, and the branch could only catch up by a
    # rebase and a force push.
    $range = "$localCommit ^$remoteSha --not --remotes=origin"
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

# A FILE THAT STARTS WITH #! IS RUN BY ITS NAME, so it carries the executable bit: without it
# ./release/release.sh fails and git skips a hook in .githooks. A tool that writes files (an agent's,
# a copy made through an API) leaves the bit off, and git keeps what it was given. Judged on what the
# push adds or changes, as the commit checked out has it; a file the push does not touch is left alone.
$touched = @($commits | ForEach-Object { & git -c core.quotePath=false diff-tree --no-commit-id --root -r --name-only --diff-filter=AMR $_ 2>$null } | ForEach-Object { "$_" } | Where-Object { $_ } | Sort-Object -Unique -CaseSensitive)
$modeless = @()
foreach ($path in $touched) {
  if ("$(& git ls-tree $head -- $path 2>$null)" -cnotmatch '^100644 ') { continue }
  $blob = "$(& git rev-parse "${head}:$path" 2>$null)".Trim()
  if (-not $blob) { continue }
  $bytes = [byte[]](& git cat-file blob $blob 2>$null | Select-Object -First 1 | ForEach-Object { [System.Text.Encoding]::UTF8.GetBytes("$_") })
  if ($bytes.Count -ge 2 -and $bytes[0] -eq 0x23 -and $bytes[1] -eq 0x21) { $modeless += $path }
}
if ($modeless.Count -gt 0) {
  $list = ' ' + ($modeless -join ' ')
  Deny-Push "these files start with #! and are not executable, so running them by name fails and git skips a hook among them:$list. Set the bit and commit it: git update-index --chmod=+x$list"
}

# THE COMMIT MESSAGES (the commit rules). A subject is at most 72 characters, because the log, the
# tracker and every list view cut a longer one and the rest is lost where it is read; and no
# message carries an assistant's or a vendor's attribution, because the history names who answers
# for a change, and a tool cannot.
$long = @(); $attributed = @()
foreach ($sha in $commits) {
  $short = "$(& git log -1 --format=%h $sha)".Trim()
  $subject = "$(& git log -1 --format=%s $sha)"
  if ($subject.Length -gt 72) { $long += "  $short has $($subject.Length) characters: $subject" }
  $message = (@(& git log -1 --format=%B $sha) -join "`n")
  if ($message -imatch '(?m)^co-authored-by:.*(claude|codex|gemini|copilot|chatgpt|anthropic|openai)|generated (with|by) \[?(claude|codex|gemini|copilot|chatgpt)') { $attributed += $short }
}
if ($long.Count -gt 0) {
  Deny-Push "these subjects are longer than 72 characters:`n$($long -join "`n")`n  Shorten each to one sentence of at most 72 that says what changed, with git commit --amend for the last commit or git rebase -i for an earlier one."
}
if ($attributed.Count -gt 0) {
  Deny-Push "these commits carry an assistant's or a vendor's attribution: $($attributed -join ' '). Take the line out of the message (git commit --amend, or git rebase -i), because the history names who answers for a change."
}

# AN ISSUE NUMBER IS NEVER WRITTEN INTO A COMMENT (the comment rules): it sends the reader to a
# tracker that moves on while the line stays. What the line needs is said in the comment, and the
# issue is named in the commit message. Judged on the lines the push adds, in the two spellings a
# number is written in, a hash and digits in brackets, and a repository's name, a hash and digits;
# a number in code that is no comment is left alone.
$numbered = @()
foreach ($sha in $commits) {
  $file = ''
  foreach ($raw in @(& git -c core.quotePath=false show --format= --unified=0 --no-color $sha -- . ':!*.md' ':!*.json' ':!*.lock' ':!CHANGELOG*' 2>$null)) {
    $l = "$raw"
    if ($l.StartsWith('+++ ', [StringComparison]::Ordinal)) { $file = $l.Substring(6); continue }
    if (-not $l.StartsWith('+', [StringComparison]::Ordinal)) { continue }
    $line = $l.Substring(1)
    # the comment is the whole line where it opens one, else what follows a trailing // or /*
    $trailing = [regex]::Match($line, '[^:]//|/\*')
    if ($line -cmatch '^\s*(#|\*|--|;|//|/\*|<!--)') { $comment = $line }
    elseif ($trailing.Success) { $comment = $line.Substring($trailing.Index) }
    else { continue }
    if ($comment -cmatch '\(#[0-9]+\)|[A-Za-z0-9._-]+#[0-9]+') { $numbered += "  ${file}: $line" }
  }
}
if ($numbered.Count -gt 0) {
  Deny-Push "these added comments name an issue by its number:`n$($numbered -join "`n")`n  Say in the comment what the line needs, and name the issue in the commit message."
}

# A MIGRATION THAT REACHED A DATABASE IS NEVER CHANGED (the database rules): the schema moves
# forward through a new migration. One that never left this machine may still change, and the
# commit that changes it says so in a 'Migration: <why>' trailer.
$migrated = @()
foreach ($sha in $commits) {
  if ("$(& git log -1 '--format=%(trailers:key=Migration,valueonly)' $sha)".Trim()) { continue }
  $migrated += @(& git -c core.quotePath=false diff-tree --no-commit-id --root -r --name-only --diff-filter=MDR $sha 2>$null | ForEach-Object { "$_" } | Where-Object { $_ -cmatch '(^|/)migrations/[^/]+\.sql$' })
}
if ($migrated.Count -gt 0) {
  Deny-Push "these migrations exist already and are changed or removed: $($migrated -join ' ')`n  Move the schema forward with a new migration. A migration that never reached a database may change in a commit with a 'Migration: <why>' trailer."
}

# THE TWO SPELLINGS OF A SCRIPT CHANGE TOGETHER (the harness rules): where x.sh and x.ps1 both stand,
# they are one program, and a push that changes one of them changes the other. Where a fault lives in
# one spelling alone, a commit of the push says so in a 'Twin: <why>' trailer. The Windows entry
# point is no twin: where scripts/check.sh stands, a check.ps1 or build.ps1 is the one text held
# above, which starts the .sh of its own name and never changes with it.
[string[]]$allChanged = @($commits | ForEach-Object { & git -c core.quotePath=false diff-tree --no-commit-id --root -r --name-only $_ 2>$null } | ForEach-Object { "$_" } | Where-Object { $_ } | Select-Object -Unique)
[Array]::Sort($allChanged, [StringComparer]::Ordinal)
$twinExcused = @($commits | Where-Object { "$(& git log -1 '--format=%(trailers:key=Twin,valueonly)' $_)".Trim() }).Count -gt 0
$oneSided = @()
if (-not $twinExcused) {
  $treeSet = [System.Collections.Generic.HashSet[string]]::new([string[]]@(& git -c core.quotePath=false ls-tree -r --name-only $head 2>$null | ForEach-Object { "$_" }), [StringComparer]::Ordinal)
  $changedSet = [System.Collections.Generic.HashSet[string]]::new($allChanged, [StringComparer]::Ordinal)
  foreach ($path in $allChanged) {
    if ($path.EndsWith('.sh', [StringComparison]::Ordinal)) { $other = $path.Substring(0, $path.Length - 3) + '.ps1'; $ps1 = $other }
    elseif ($path.EndsWith('.ps1', [StringComparison]::Ordinal)) { $other = $path.Substring(0, $path.Length - 4) + '.sh'; $ps1 = $path }
    else { continue }
    $ps1Name = $ps1 -creplace '^.*/', ''
    if ((Test-Path -LiteralPath $checkSh) -and ($ps1Name -ceq 'check.ps1' -or $ps1Name -ceq 'build.ps1')) { continue }
    if (-not ($treeSet.Contains($path) -and $treeSet.Contains($other))) { continue }
    if (-not $changedSet.Contains($other)) { $oneSided += "$path (not $other)" }
  }
}
if ($oneSided.Count -gt 0) {
  Deny-Push "one spelling of a script changed without the other: $($oneSided -join ' ')`n  Change both in this push. Where the fault lives in one spelling alone, give a commit a 'Twin: <why>' trailer."
}

# THE NAMES A PUSH ADDS ARE DERIVED, NOT INVENTED (the naming rules). No list is kept: the
# families are read from the trees themselves. Two things are held against every new directory:
#   - `<a>` beside `<a>-<x>`, or `<a>-<x>` beside `<a>`, names one member of a family and leaves
#     the other unnamed: every member says which side it is on, or none does.
#   - `<owner>-<x>`, where the owner is a repository of this project folder, names a part of that
#     repository, so `<x>` is one of its top-level directories. This is held in a directory that
#     mirrors the repositories, where two or more entries carry a repository's name; elsewhere a
#     name that happens to open with one (post-processing) refers to no repository.
# A repository's owner word is its name after the project prefix (acme-shop: shop), or its whole
# name where it has none. A word that is a top-level directory in two or more repositories is a
# word of structure (docs, deploy, scripts), no repository's name, and is not held. A commit with a
# 'Naming: <why>' trailer keeps the names it adds, and says why to whoever reads it.
function Get-NamingFindings {
  $folder = Get-ProjectFolderOf $root
  $main = (Resolve-Path (Join-Path "$(& git -C $root rev-parse --path-format=absolute --git-common-dir)".Trim() '..')).Path
  $words = @(& git -C $root ls-tree -d --name-only HEAD 2>$null | ForEach-Object { "$_" } | Where-Object { $_ })
  $owners = @()
  foreach ($d in @(Get-ChildItem -LiteralPath $folder -Directory -ErrorAction SilentlyContinue)) {
    if (-not (Test-Path -LiteralPath (Join-Path $d.FullName '.git'))) { continue }
    if ($d.Name -clike '*-ai-core') { continue }
    if ((Resolve-Path -LiteralPath $d.FullName).Path -eq $main) { continue }
    $parts = @(& git -C $d.FullName ls-tree -d --name-only HEAD 2>$null | ForEach-Object { "$_" } | Where-Object { $_ })
    $words += $parts
    $owner = if ($d.Name.Contains('-')) { $d.Name.Substring($d.Name.IndexOf('-') + 1) } else { $d.Name }
    $owners += [pscustomobject]@{ Owner = $owner; Repo = $d.Name; Parts = $parts }
  }
  $structure = @($words | Group-Object -CaseSensitive | Where-Object { $_.Count -ge 2 } | ForEach-Object { $_.Name })
  foreach ($sha in $commits) {
    if ("$(& git log -1 '--format=%(trailers:key=Naming,valueonly)' $sha)".Trim()) { continue }
    $dirs = @(& git diff-tree --no-commit-id --root -r --name-only --diff-filter=A $sha | ForEach-Object { "$_" } | ForEach-Object {
        $segs = $_ -split '/'; for ($i = 1; $i -lt $segs.Count; $i++) { ($segs[0..($i - 1)] -join '/') } } | Sort-Object -Unique -CaseSensitive)
    foreach ($dir in $dirs) {
      & git cat-file -e "${sha}^:$dir" 2>$null; if ($LASTEXITCODE -eq 0) { continue }
      $seg = ($dir -split '/')[-1]; $parent = if ($dir.Contains('/')) { $dir.Substring(0, $dir.LastIndexOf('/') + 1) } else { '' }
      $entries = @(& git ls-tree -d --name-only $(if ($parent) { "${sha}:$($parent.TrimEnd('/'))" } else { $sha }) 2>$null | ForEach-Object { "$_" })
      if ($seg.Contains('-')) {
        $base = $seg.Substring(0, $seg.IndexOf('-'))
        if ($entries -ccontains $base) { "$parent$base beside $parent${seg}: one member of the family says its side, the other does not; name every member, or none" }
      } else {
        foreach ($o in @($entries | Where-Object { $_.StartsWith("$seg-", [StringComparison]::Ordinal) })) { "$parent$seg beside $parent${o}: one member of the family says its side, the other does not; name every member, or none" }
      }
      $held = @($owners | Where-Object { $structure -cnotcontains $_.Owner })
      $mirrors = 0
      foreach ($o in $held) { $mirrors += @($entries | Where-Object { $_ -ceq $o.Owner -or $_.StartsWith("$($o.Owner)-", [StringComparison]::Ordinal) -or $_.StartsWith("$($o.Owner)_", [StringComparison]::Ordinal) }).Count }
      if ($mirrors -lt 2) { continue }
      foreach ($o in $owners) {
        if ($seg.Length -le $o.Owner.Length + 1) { continue }
        if (-not ($seg.StartsWith("$($o.Owner)-", [StringComparison]::Ordinal) -or $seg.StartsWith("$($o.Owner)_", [StringComparison]::Ordinal))) { continue }
        if ($structure -ccontains $o.Owner) { continue }
        $rest = $seg.Substring($o.Owner.Length + 1)
        if ($o.Parts -cnotcontains $rest) { "$dir names a part of the repository $($o.Repo), and $($o.Repo) has no $rest; its parts are $($o.Parts -join ', ')" }
      }
    }
  }
}
$findings = @(Get-NamingFindings | Sort-Object -Unique -CaseSensitive)
if ($findings.Count -gt 0) {
  foreach ($f in $findings) { [Console]::Error.WriteLine("pre-push: $f") }
  Deny-Push "the names above are invented where they should be derived from what they belong to. Rename them, or give the commit that adds them a 'Naming: <why>' trailer."
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
  if (-not (Test-GitleaksGit)) { Deny-Push "no gitleaks 8.19 or newer (the one with 'gitleaks git') is on this path, and $root/.gitleaks.toml says the commits being pushed are read for credentials. Run ai-core doctor in this repository, which installs it." }
  foreach ($scanRange in $scanRanges) {
    & gitleaks git --no-banner "--log-opts=$scanRange" $root
    if ($LASTEXITCODE -ne 0) { Deny-Push 'a credential stands in a commit this push carries. The lines above name the commit, the file and the rule. Take it out of the history - a commit that is pushed cannot be recalled.' }
  }
}

Write-Host 'pre-push: nothing refused this push.'
