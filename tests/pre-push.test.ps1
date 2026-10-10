# The PowerShell twin of pre-push.test.sh: what the push gate lets out of a checkout, and what
# it refuses, asserted against bin\pre-push.ps1 with the SAME cases.
#
#   pwsh -File tests/pre-push.test.ps1
#
# NOTHING IS PUSHED and github.com is never reached. A scratch repository is built in a
# temporary directory and git's own input is fed to the gate by hand - one line per ref. The
# team modes come from a table of this test, scripts/check.sh is a stand-in that writes down
# which working tree it ran in (started through the Windows entry point beside it, as the gate
# does), and gitleaks is a stub that writes down its arguments.

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$fake = Join-Path ([IO.Path]::GetTempPath()) "pre-push-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $fake | Out-Null
$gate = Join-Path $root 'bin\pre-push.ps1'
$utf8 = New-Object System.Text.UTF8Encoding $false
function Write-Lf([string]$path, [string]$text) { [System.IO.File]::WriteAllText($path, $text, $utf8) }

$failed = 0
function Check($name, $expected, $actual) {
  if ("$expected" -eq "$actual") { Write-Host "  ok   $name" }
  else { Write-Host "  FAIL $name`n       expected: [$expected]`n       actual:   [$actual]"; $script:failed++ }
}

$parent = Join-Path $fake 'checkouts'
$repo = Join-Path $parent 'app'
$wt = Join-Path $parent '.worktrees\app\issue-5-probe'
$checkRuns = Join-Path $fake 'check-runs.txt'
Write-Lf $checkRuns ''

# The team modes: a table whose probes pass, and one whose probe cannot. The check reads the rows
# of the tools on PATH, and a stub claude on PATH is the tool it finds.
$green = Join-Path $fake 'modes-green.tsv'; $red = Join-Path $fake 'modes-red.tsv'
Write-Lf $green "claude`tmode`ton`talways`t-`t-`n"
Write-Lf $red "claude`tcaveman`tlite`tfile:$fake/never-there`tnpx skills add example/caveman -g`t-`n"
$env:TEAM_MODES_FILE = $green
$stub = Join-Path $fake 'stub'; New-Item -ItemType Directory -Path $stub | Out-Null
Set-Content -Path (Join-Path $stub 'claude.cmd') -Value "@exit /b 0" -Encoding ascii
if (-not $IsWindows) { Set-Content -Path (Join-Path $stub 'claude') -Value "#!/bin/sh`nexit 0" -Encoding ascii; & chmod +x (Join-Path $stub 'claude') }
# The gitleaks stub writes down every argument it was given
$leaksArgs = Join-Path $fake 'leaks-args.txt'
# Asked for the help of `gitleaks git`, it has the subcommand unless PROBE_LEAKS is old, a gitleaks from before 8.19
Set-Content -Path (Join-Path $stub 'gitleaks.cmd') -Value "@if `"%2`"==`"--help`" (if `"%PROBE_LEAKS%`"==`"old`" (exit /b 1) else (exit /b 0))`r`n@echo %*>> `"$leaksArgs`"`r`n@if `"%PROBE_LEAKS%`"==`"red`" (echo gitleaks: a credential stands in this range & exit /b 1)`r`n@exit /b 0" -Encoding ascii
if (-not $IsWindows) { Set-Content -Path (Join-Path $stub 'gitleaks') -Value "#!/bin/sh`ncase `"`$*`" in *--help) [ `"`${PROBE_LEAKS:-green}`" != old ]; exit ;; esac`necho `"`$*`" >> `"$leaksArgs`"`n[ `"`${PROBE_LEAKS:-green}`" = green ] || { echo 'gitleaks: a credential stands in this range'; exit 1; }`nexit 0" -Encoding ascii; & chmod +x (Join-Path $stub 'gitleaks') }
# A second ai-core behind the stand-in, the way a developer's shell carries its own: a run without
# ai-core on the PATH has to take both away
$machine = Join-Path $fake 'machine'; New-Item -ItemType Directory -Path $machine | Out-Null
Write-Lf (Join-Path $machine 'ai-core') "#!/bin/sh`nexit 0`n"
if (-not $IsWindows) { & chmod +x (Join-Path $machine 'ai-core') }
$env:PATH = "$stub$([IO.Path]::PathSeparator)$machine$([IO.Path]::PathSeparator)$env:PATH"

# The repository: the stand-in check writes down its own path, which says which working tree it
# was started in; both Windows entry points are the one text, and one .ps1 is neither.
New-Item -ItemType Directory -Path (Join-Path $repo 'scripts'), (Join-Path $repo 'bin') -Force | Out-Null
Write-Lf (Join-Path $repo 'scripts\check.sh') @"
#!/usr/bin/env bash
printf '%s\n' "`$0" >> "$($checkRuns.Replace('\', '/'))"
if [ "`${PROBE_CHECK:-green}" = green ]; then echo 'check: OK — every check green'; exit 0; fi
echo 'check: FAIL — the stand-in was told to be red'
exit 1
"@
if (-not $IsWindows) { & chmod +x (Join-Path $repo 'scripts\check.sh') }
Copy-Item (Join-Path $root 'lib\entry-point.ps1') (Join-Path $repo 'scripts\check.ps1')
Copy-Item (Join-Path $root 'lib\entry-point.ps1') (Join-Path $repo 'build.ps1')
Write-Lf (Join-Path $repo 'bin\case-check.ps1') "#!/usr/bin/env pwsh`nWrite-Host `"not a shim, and never was`"`n"
& git -C $repo init -q -b master
& git -C $repo config user.email 'test@example.invalid'
& git -C $repo config user.name 'test'
& git -C $repo config core.autocrlf false
& git -C $repo add -A
& git -C $repo commit -q -m 'Set the repository up for the gate probe #1'

function Commit([string]$path, [string]$message) {  # one file, one commit
  $full = Join-Path $repo $path
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $full) | Out-Null
  [System.IO.File]::AppendAllText($full, "a line`n", $utf8)
  & git -C $repo add -- $path
  $message | & git -C $repo commit -q -F -
}

# One ref line, fed the way git feeds it. The gate runs with the working tree as its directory,
# which is what git does before it starts a hook.
function Judge([string]$tree, [string]$local, [string]$remote) {
  Push-Location $tree
  try { $script:out = ("refs/heads/master $local refs/heads/master $remote" | & pwsh -NoProfile -File $gate origin 'https://example.invalid/x.git' 2>&1 | Out-String); $script:rc = $LASTEXITCODE }
  finally { Pop-Location }
}
function OnlyNew([string]$tree) { Judge $tree "$(& git -C $tree rev-parse HEAD)" "$(& git -C $tree rev-parse HEAD~1)" }
function Says($pattern) { return [bool]($script:out -match $pattern) }
function Sha([string]$tree, [string]$rev) { return "$(& git -C $tree rev-parse $rev)" }

$zeros40 = '0' * 40
$zeros64 = '0' * 64

# --- the push from a worktree ------------------------------------------------------------------
Write-Host 'a push from a worktree runs the check of the WORKTREE'
& git -C $repo worktree add -q -b issue-5-probe $wt master
[System.IO.File]::AppendAllText((Join-Path $wt 'notes-5.txt'), "a line`n", $utf8)
& git -C $wt add -- notes-5.txt
& git -C $wt commit -q -m 'Probe the gate from a worktree #5'
Write-Lf $checkRuns ''
Judge $wt (Sha $wt HEAD) (Sha $repo master)
Check 'exit 0'                     0 $rc
Check 'the check ran'              'True' (Says 'check: OK')
Check 'nothing refused the push'   'True' (Says 'pre-push: nothing refused this push')
$ran = @(Get-Content $checkRuns | Where-Object { $_ })[-1]
Check 'and the check that ran is the WORKTREE one' 'True' ($ran.Replace('\', '/') -clike '*/.worktrees/app/issue-5-probe/scripts/check.sh')

Write-Host 'a push to the default branch that is not a fast-forward is refused, origin/HEAD naming a branch this clone does not have'
& git -C $repo commit -q --allow-empty -m 'master moves on while the worktree works #5'
& git -C $repo symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main   # as a clone keeps it after the origin renamed its default branch
Judge $wt (Sha $wt HEAD) (Sha $repo master)
Check 'exit 1'                     1 $rc
Check 'it says why'                'True' (Says 'the push to master is not a fast-forward')
& git -C $repo symbolic-ref --delete refs/remotes/origin/HEAD
& git -C $repo reset -q --hard HEAD~1

# --- the team modes ---------------------------------------------------------------------------
Write-Host 'a red modes check refuses, and the lines the refusal points at are in the output'
$env:TEAM_MODES_FILE = $red
OnlyNew $wt
$env:TEAM_MODES_FILE = $green
Check 'exit 1'                    1 $rc
Check 'the MISSING line is there' 'True' (Says '(?m)^MISSING .*claude caveman')
Check 'and the refusal names the modes' 'True' (Says 'the team modes are missing')

Write-Host 'a red scripts/check.sh refuses'
$env:PROBE_CHECK = 'red'
OnlyNew $wt
Remove-Item Env:PROBE_CHECK
Check 'exit 1'          1 $rc
Check 'and says which'  'True' (Says 'check: FAIL')

# --- what excuses a commit from naming an issue ----------------------------------------------
# --- a file that starts with #! carries the executable bit ------------------------------------
Write-Host 'a pushed file that starts with #! and is not executable is refused, with the command that sets the bit'
$runner = Join-Path $repo 'tools/run.sh'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $runner) | Out-Null
Write-Lf $runner "#!/bin/sh`necho run`n"
if (-not $IsWindows) { & chmod -x $runner }
& git -C $repo add --chmod=-x -- tools/run.sh; & git -C $repo commit -q -m 'Add a runner #7'
OnlyNew $repo
Check 'exit 1'                         1 $rc
Check 'it names the file and the command' 'True' (Says ([regex]::Escape('git update-index --chmod=+x tools/run.sh')))
Write-Host 'the bit set by a later commit of the same push passes'
& git -C $repo update-index --chmod=+x -- tools/run.sh; if (-not $IsWindows) { & chmod +x $runner }
& git -C $repo commit -q -m 'Make the runner executable #7'
Judge $repo (Sha $repo HEAD) (Sha $repo HEAD~2)
Check 'exit 0'                         0 $rc
Write-Host 'a file without the bit that the push does not touch holds nothing up'
& git -C $repo update-index --chmod=-x -- tools/run.sh; if (-not $IsWindows) { & chmod -x $runner }
& git -C $repo commit -q -m 'The runner without the bit, as an older commit left it #7'
Commit 'src/thing.txt' 'Touch another file #7'
OnlyNew $repo
Check 'exit 0'                         0 $rc
& git -C $repo rm -q -- tools/run.sh; & git -C $repo commit -q -m 'Remove the runner #7'

# --- the commit messages, the comments, the migrations and the twins ----------------------------
function Amend([string]$message) { $message | & git -C $repo commit -q --amend -F - }
Write-Host 'a subject of 73 characters is refused and named; one of 72 passes'
Commit 'src/thing.txt' (('A' * 70) + ' #7')
OnlyNew $repo
Check 'exit 1'                         1 $rc
Check 'it counts the characters'       'True' (Says 'has 73 characters')
Amend (('A' * 69) + ' #7')
OnlyNew $repo
Check 'exit 0'                         0 $rc
Write-Host "an assistant's attribution is refused; a person as co-author passes"
Commit 'src/thing.txt' "Tune the reader #7`n`nCo-Authored-By: Claude <noreply@anthropic.com>"
OnlyNew $repo
Check 'exit 1'                         1 $rc
Check 'it says why'                    'True' (Says "an assistant's or a vendor's attribution")
Amend "Tune the reader #7`n`nCo-Authored-By: Ada Lovelace <ada@example.invalid>"
OnlyNew $repo
Check 'exit 0'                         0 $rc
Write-Host 'an assistant as author or committer is refused; a person who shares the name passes'
& git -C $repo commit -q --amend --no-edit '--author=Claude <noreply@anthropic.com>'
OnlyNew $repo
Check 'an assistant as author: exit 1' 1 $rc
Check 'it names the identity'          'True' (Says ([regex]::Escape('author Claude <noreply@anthropic.com>')))
& git -C $repo commit -q --amend --no-edit --reset-author
$env:GIT_COMMITTER_NAME = 'Claude'; $env:GIT_COMMITTER_EMAIL = 'noreply@anthropic.com'
& git -C $repo commit -q --amend --no-edit
Remove-Item Env:GIT_COMMITTER_NAME, Env:GIT_COMMITTER_EMAIL
OnlyNew $repo
Check 'an assistant as committer alone: exit 1' 1 $rc
Check 'it says why'                    'True' (Says 'name an assistant as author or committer')
& git -C $repo commit -q --amend --no-edit '--author=claude[bot] <209825114+claude[bot]@users.noreply.github.com>'
OnlyNew $repo
Check "an assistant's GitHub bot: exit 1" 1 $rc
& git -C $repo commit -q --amend --no-edit '--author=Claude Monet <claude@example.invalid>'
OnlyNew $repo
Check 'a person named Claude: exit 0'  0 $rc
& git -C $repo commit -q --amend --no-edit '--author=dependabot[bot] <49699333+dependabot[bot]@users.noreply.github.com>'
OnlyNew $repo
Check 'a bot that is no assistant: exit 0' 0 $rc
& git -C $repo commit -q --amend --no-edit --reset-author
Write-Host 'an added comment naming an issue as (#12) or <repo>#12 is refused; a number in code passes'
$n = 12  # the number is put together, so this line is no comment naming an issue to the gate itself
Write-Lf (Join-Path $repo 'src/app.js') "const a = 1; // read the board whole (#$n)`n"
Write-Lf (Join-Path $repo 'src/app.py') "# see acme-shop#12 for the order`n"
& git -C $repo add src/app.js src/app.py; & git -C $repo commit -q -m 'Read the board whole #12'
OnlyNew $repo
Check 'exit 1'                         1 $rc
Check 'it names the (#12) line'        'True' (Says ([regex]::Escape("src/app.js: const a = 1; // read the board whole (#$n)")))
Check 'it names the <repo>#12 line'    'True' (Says ([regex]::Escape('src/app.py: # see acme-shop#12 for the order')))
& git -C $repo reset -q --hard HEAD~1
Write-Lf (Join-Path $repo 'src/app.js') "const ref = `"acme-shop#12`"; // the order the board reads`n"
& git -C $repo add src/app.js; & git -C $repo commit -q -m 'Read the board whole #12'
OnlyNew $repo
Check 'exit 0'                         0 $rc
Write-Host "a migration added passes; changed later it is refused, and passes with a 'Migration:' trailer"
Commit 'db/migrations/0001_init.sql' 'Add the first migration #8'
OnlyNew $repo
Check 'exit 0'                         0 $rc
Commit 'db/migrations/0001_init.sql' 'Change the first migration #8'
OnlyNew $repo
Check 'exit 1'                         1 $rc
Check 'it names the migration'         'True' (Says ([regex]::Escape('changed or removed: db/migrations/0001_init.sql')))
Amend "Change the first migration #8`n`nMigration: it never left this machine"
OnlyNew $repo
Check 'exit 0'                         0 $rc
Write-Host "one spelling of a script changed alone is refused; both pass, and so does a 'Twin:' trailer"
New-Item -ItemType Directory -Force -Path (Join-Path $repo 'tools') | Out-Null
Write-Lf (Join-Path $repo 'tools/tidy.sh') "echo one`n"; Write-Lf (Join-Path $repo 'tools/tidy.ps1') "Write-Host 'one'`n"
& git -C $repo add tools; & git -C $repo commit -q -m 'Add the tidy twins #9'
OnlyNew $repo
Check 'exit 0 for both added'          0 $rc
Commit 'tools/tidy.sh' 'Tidy the sh spelling #9'
OnlyNew $repo
Check 'exit 1'                         1 $rc
Check 'it names the other spelling'    'True' (Says ([regex]::Escape('tools/tidy.sh (not tools/tidy.ps1)')))
Commit 'tools/tidy.ps1' 'Tidy the ps1 spelling #9'
Judge $repo (Sha $repo HEAD) (Sha $repo HEAD~2)
Check 'exit 0 for both in one push'    0 $rc
Commit 'tools/tidy.sh' "Tidy the sh spelling #9`n`nTwin: the fault is a bash quoting one"
OnlyNew $repo
Check 'exit 0 with the trailer'        0 $rc
Write-Host 'the Windows entry point is no twin: scripts/check.sh changed alone passes'
[System.IO.File]::AppendAllText((Join-Path $repo 'scripts/check.sh'), "# the checks the push runs`n", $utf8)
& git -C $repo add --chmod=+x scripts/check.sh; & git -C $repo commit -q -m 'Say what the checks run #9'
OnlyNew $repo
Check 'exit 0'                         0 $rc
& git -C $repo reset -q --hard HEAD~1
Write-Host 'a .ps1 that is the Windows entry point is no twin whatever its name; one with code of its own is'
Write-Lf (Join-Path $repo 'scripts/test.sh') "#!/usr/bin/env bash`necho tests`n"
if (-not $IsWindows) { & chmod +x (Join-Path $repo 'scripts/test.sh') }
Copy-Item (Join-Path $root 'lib\entry-point.ps1') (Join-Path $repo 'scripts/test.ps1')
& git -C $repo add --chmod=+x scripts/test.sh; & git -C $repo add scripts/test.ps1; & git -C $repo commit -q -m 'Add the test entry #9'
[System.IO.File]::AppendAllText((Join-Path $repo 'scripts/test.sh'), "# one more test`n", $utf8)
& git -C $repo add --chmod=+x scripts/test.sh; & git -C $repo commit -q -m 'Run one more test #9'
OnlyNew $repo
Check 'test.sh changed beside the entry point: exit 0' 0 $rc
Write-Lf (Join-Path $repo 'scripts/test.ps1') "Write-Host 'tests of its own'`n"
& git -C $repo add scripts/test.ps1; & git -C $repo commit -q -m 'Give the test entry code of its own #9'
[System.IO.File]::AppendAllText((Join-Path $repo 'scripts/test.sh'), "# another test`n", $utf8)
& git -C $repo add --chmod=+x scripts/test.sh; & git -C $repo commit -q -m 'Run another test #9'
OnlyNew $repo
Check 'test.sh changed beside a .ps1 with code: exit 1' 1 $rc
Check 'it names the other spelling'    'True' (Says ([regex]::Escape('scripts/test.sh (not scripts/test.ps1)')))
& git -C $repo rm -q -r -- tools db src/app.js scripts/test.sh scripts/test.ps1; & git -C $repo commit -q -m 'Remove the probes #9'

# --- a branch that merges the default branch -------------------------------------------------
Write-Host 'a branch that merges the default branch is judged on what it adds, not on what the default branch published'
$base = Sha $repo HEAD
& git -C $repo checkout -q -b issue-11-catch-up
Commit 'src/branch.txt' 'Start the branch work #11'
$branchTip = Sha $repo HEAD
& git -C $repo update-ref refs/remotes/origin/issue-11-catch-up $branchTip   # the branch is on the remote
& git -C $repo checkout -q master
Commit 'src/elsewhere.txt' 'A commit another flow wrote on the default branch'   # names no issue
& git -C $repo update-ref refs/remotes/origin/master HEAD                       # and is published
& git -C $repo checkout -q issue-11-catch-up
& git -C $repo merge -q --no-edit -m 'Catch up with master #11' master
function PushBranch {
  Push-Location $repo
  try { $script:out = ("refs/heads/issue-11-catch-up $(Sha $repo HEAD) refs/heads/issue-11-catch-up $branchTip" | & pwsh -NoProfile -File $gate origin 'https://example.invalid/x.git' 2>&1 | Out-String); $script:rc = $LASTEXITCODE }
  finally { Pop-Location }
}
PushBranch
Check 'exit 0'                         0 $rc
Check 'the merge, a tree the remote never had, is checked' 'True' (Says 'check: OK')
& git -C $repo update-ref refs/remotes/origin/issue-11-catch-up (Sha $repo HEAD)   # the merge is published now
Push-Location $repo
try { $out = ("refs/tags/v0.1 $(Sha $repo HEAD) refs/tags/v0.1 $zeros40" | & pwsh -NoProfile -File $gate origin 'https://example.invalid/x.git' 2>&1 | Out-String) }
finally { Pop-Location }
Check 'a tag on a published commit sends nothing new' 'True' (Says 'pre-push: nothing new to send')
Write-Host 'a new commit on that branch that names no issue is still refused'
Commit 'src/branch.txt' 'More branch work'
PushBranch
Check 'exit 1'                         1 $rc
Check 'it names that commit'           'True'  (Says ([regex]::Escape("$(& git -C $repo rev-parse --short HEAD) More branch work")))
Check 'and not the published one'      'False' (Says 'A commit another flow wrote')
& git -C $repo checkout -q master; & git -C $repo reset -q --hard $base; & git -C $repo branch -q -D issue-11-catch-up
& git -C $repo update-ref -d refs/remotes/origin/master; & git -C $repo update-ref -d refs/remotes/origin/issue-11-catch-up

# --- a default branch that goes live -----------------------------------------------------------
Write-Host 'where the default branch goes live, a landing without a Reviewed-by trailer is refused'
New-Item -ItemType Directory -Force -Path (Join-Path $repo '.ai-core') | Out-Null
Write-Lf (Join-Path $repo '.ai-core/config.env') "DEFAULT_BRANCH_IS_LIVE=`"yes`"`n"
$exclude = Join-Path $repo '.git/info/exclude'
if (-not (Select-String -LiteralPath $exclude -SimpleMatch -Pattern '/.ai-core/' -Quiet -ErrorAction SilentlyContinue)) { Add-Content -LiteralPath $exclude -Value '/.ai-core/' }
Commit 'src/thing.txt' 'Land a change on a live branch #16'
OnlyNew $repo
Check 'exit 1'                         1 $rc
Check 'it names the trailer'           'True' (Says ([regex]::Escape("git commit --amend --trailer 'Reviewed-by: <reviewer>'")))
Write-Host 'with the trailer it lands'
"Land a change on a live branch #16`n`nReviewed-by: a critic session" | & git -C $repo commit -q --amend -F -
OnlyNew $repo
Check 'exit 0'                         0 $rc
Write-Host 'a push to another branch is not held to it'
Commit 'src/thing.txt' 'Work on an issue branch #16'
Push-Location $repo
try { $script:out = ("refs/heads/issue-16-x $(Sha $repo HEAD) refs/heads/issue-16-x $(Sha $repo HEAD~1)" | & pwsh -NoProfile -File $gate origin 'https://example.invalid/x.git' 2>&1 | Out-String); $script:rc = $LASTEXITCODE }
finally { Pop-Location }
Check 'exit 0'                         0 $rc
Write-Host 'a live repository without scripts/check.sh is refused even with the trailer'
$aside = Join-Path $fake 'check.sh.aside'
Move-Item -LiteralPath (Join-Path $repo 'scripts/check.sh') -Destination $aside
"Work on an issue branch #16`n`nReviewed-by: a critic session" | & git -C $repo commit -q --amend -F -
OnlyNew $repo
Check 'exit 1'                         1 $rc
Check 'it says nothing would test it'  'True' (Says ([regex]::Escape('has no scripts/check.sh, so nothing would test what goes live')))
Move-Item -LiteralPath $aside -Destination (Join-Path $repo 'scripts/check.sh')
Write-Host 'the harness-wide list form: the repository named in it is live, one not named is not'
Write-Lf (Join-Path $repo '.ai-core/config.env') "DEFAULT_BRANCH_IS_LIVE=`"other-repo $(Split-Path -Leaf $repo)`"`n"
Commit 'src/thing.txt' 'Land a change named in the list #16'
OnlyNew $repo
Check 'exit 1 where it is named'       1 $rc
Write-Lf (Join-Path $repo '.ai-core/config.env') "DEFAULT_BRANCH_IS_LIVE=`"other-repo`"`n"
OnlyNew $repo
Check 'exit 0 where it is not'         0 $rc
Write-Host 'without the setting nothing changes'
Remove-Item -LiteralPath (Join-Path $repo '.ai-core/config.env')
Commit 'src/thing.txt' 'Land a change on an ordinary branch #16'
OnlyNew $repo
Check 'exit 0'                         0 $rc
Write-Host 'a fast-forward landing of a branch origin carries already is checked, and held to the live rule'
Commit 'src/landed.txt' 'Land a branch that origin carries already #74'
& git -C $repo update-ref refs/remotes/origin/issue-74-landed HEAD   # pushed for review before it lands
Write-Lf $checkRuns ''
OnlyNew $repo
Check 'exit 0'                         0 $rc
Check 'it is not called nothing new'   'False' (Says 'pre-push: nothing new to send')
Check 'the check runs'                 'True' ([bool]((Get-Content $checkRuns -Raw) -replace '\s', ''))
Write-Lf (Join-Path $repo '.ai-core/config.env') "DEFAULT_BRANCH_IS_LIVE=`"yes`"`n"
OnlyNew $repo
Check 'where the branch goes live, without the trailer: exit 1' 1 $rc
Check 'it names the trailer'           'True' (Says ([regex]::Escape("git commit --amend --trailer 'Reviewed-by: <reviewer>'")))
Write-Host 'a push that moves nothing lands nothing, also where the branch goes live'
Write-Lf $checkRuns ''
Judge $repo (Sha $repo HEAD) (Sha $repo HEAD)
Check 'exit 0'                         0 $rc
Check 'it sends nothing new'           'True' (Says 'pre-push: nothing new to send')
Check 'and runs no check'              '' ((Get-Content $checkRuns -Raw) -replace '\s', '')
Remove-Item -LiteralPath (Join-Path $repo '.ai-core/config.env')
& git -C $repo update-ref -d refs/remotes/origin/issue-74-landed

Write-Host 'a commit naming its issue anywhere in the message passes'
Commit 'src/thing.txt' "Read the install order from one file`n`nIt closes #163."
OnlyNew $repo
Check 'exit 0' 0 $rc

Write-Host 'a release stamp passes'
Commit 'src/thing.txt' 'release: 0.8.100'
OnlyNew $repo
Check 'exit 0' 0 $rc

Write-Host 'a commit with no number and no excuse is refused, and is named'
Commit 'src/thing.txt' 'Change a thing'
OnlyNew $repo
Check 'exit 1'              1 $rc
Check 'the commit is named' 'True' (Says 'Change a thing names no issue')
Check 'the check never ran' 'False' (Says 'check: OK')

Write-Host 'a No-issue trailer naming a reason passes'
Commit 'src/thing.txt' "Change a thing`n`nNo-issue: the product owner asked for it on 2026-09-03"
OnlyNew $repo
Check 'exit 0' 0 $rc

Write-Host 'an EMPTY No-issue trailer is no reason, and is refused'
Commit 'src/thing.txt' "Change a thing`n`nNo-issue:"
OnlyNew $repo
Check 'exit 1' 1 $rc

Write-Host 'the two words inside a body sentence are not a trailer'
Commit 'src/thing.txt' "Change a thing`n`nThere is No-issue: for this one because nobody asked."
OnlyNew $repo
Check 'exit 1' 1 $rc

Write-Host 'a commit that only explains passes, whatever folder the file stands in'
Commit 'docs/notes.md' 'Correct a typo'
OnlyNew $repo
Check 'a markdown file'      0 $rc
Commit 'LICENSE-MIT' 'Add the licence text'
OnlyNew $repo
Check 'LICENSE-MIT'          0 $rc
Commit 'docs/LICENSE' 'Add the licence text under docs'
OnlyNew $repo
Check 'docs/LICENSE'         0 $rc
Commit 'src/notes.txt' 'Write a note that is not a document'
OnlyNew $repo
Check 'and a file that explains nothing is refused' 1 $rc

# --- the shape of a sha -----------------------------------------------------------------------
Write-Host 'an all-zero remote sha judges every commit, at forty digits and at sixty-four'
$headSha = Sha $repo HEAD
Judge $repo $headSha $zeros40
Check 'forty zeros: the history is judged and this one names no issue' 1 $rc
Judge $repo $headSha $zeros64
Check 'sixty-four zeros: the same verdict' 1 $rc

Write-Host 'an all-zero LOCAL sha is a deletion: no commit is judged and no check is run'
Write-Lf $checkRuns ''
Judge $repo $zeros64 $headSha
Check 'exit 0'                     0 $rc
Check 'the modes check never ran'  'False' (Says 'team modes')
Check 'and neither did check.sh'   '' ((Get-Content $checkRuns -Raw) -replace '\s', '')

Write-Host 'a remote sha this checkout does not carry is refused, with what to do about it'
Judge $repo $headSha 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'
Check 'exit 1'            1 $rc
Check 'it says git fetch' 'True' (Says 'Run git fetch, then push again')

Write-Host 'a local sha that is not what is checked out is refused'
Judge $repo (Sha $repo 'HEAD~1') (Sha $repo 'HEAD~2')
Check 'exit 1'               1 $rc
Check 'it says what to push' 'True' (Says 'push what you have: git push origin HEAD:master')

Write-Host 'a working tree that differs from the pushed commit is refused, and names the files'
Commit 'src/clean.txt' 'Write a commit to push #17'
Write-Lf (Join-Path $repo 'src/loose.txt') "not committed`n"
OnlyNew $repo
Check 'an untracked file: exit 1'      1 $rc
Check 'it names the file'              'True' (Says ([regex]::Escape('?? src/loose.txt')))
Remove-Item (Join-Path $repo 'src/loose.txt'); [System.IO.File]::AppendAllText((Join-Path $repo 'src/clean.txt'), "more`n", $utf8)
OnlyNew $repo
Check 'an unstaged change: exit 1'     1 $rc
& git -C $repo add src/clean.txt
OnlyNew $repo
Check 'a staged change: exit 1'        1 $rc
& git -C $repo reset -q --hard
[System.IO.File]::AppendAllText((Join-Path $repo '.git/info/exclude'), "loose.log`n", $utf8); Write-Lf (Join-Path $repo 'src/loose.log') "ignored`n"
OnlyNew $repo
Check 'an ignored file counts not: exit 0' 0 $rc
Remove-Item (Join-Path $repo 'src/loose.log')

Write-Host 'a deploy ref put on a commit origin already carries passes from a checkout that moved on'
function Deploy([string]$local, [string]$remote = $zeros40) {  # put the deploy ref on that commit, new by default
  Push-Location $repo
  try { $script:out = ("refs/heads/deploy $local refs/heads/deploy/test $remote" | & pwsh -NoProfile -File $gate origin 'https://example.invalid/x.git' 2>&1 | Out-String); $script:rc = $LASTEXITCODE }
  finally { Pop-Location }
}
& git -C $repo update-ref refs/remotes/origin/release-probe HEAD~1   # the release stands on origin
Write-Lf $checkRuns ''
Deploy (Sha $repo 'HEAD~1')
Check 'exit 0'                         0 $rc
Check 'it sends nothing new'           'True' (Says 'pre-push: nothing new to send')
Check 'and runs no check'              '' ((Get-Content $checkRuns -Raw) -replace '\s', '')
Judge $repo (Sha $repo 'HEAD~1') (Sha $repo 'HEAD~2')
Check 'the default branch still takes only what is checked out' 1 $rc
Deploy (Sha $repo 'HEAD~1') (Sha $repo 'HEAD~2')
Check 'an existing deploy ref moves the same way' 0 $rc
Deploy (Sha $repo 'HEAD~1^{tree}')
Check 'a tree is no commit, and is refused' 1 $rc
Write-Host 'a commit origin does not carry is still refused there'
Commit 'src/unpushed.txt' 'Write a commit origin does not have #16'
Commit 'src/unpushed.txt' 'Move on past it #16'
Deploy (Sha $repo 'HEAD~1')
Check 'exit 1'                         1 $rc
Check 'it says what to push'           'True' (Says 'push what you have: git push origin HEAD:deploy/test')
& git -C $repo reset -q --hard HEAD~2
& git -C $repo update-ref -d refs/remotes/origin/release-probe

# --- an annotated tag --------------------------------------------------------------------------
Write-Host 'an annotated tag naming the checked-out commit is not read as a foreign ref'
Commit 'src/thing.txt' 'Stamp a version for the probe #15'
& git -C $repo tag -a -m 'release 0.8.999' v0.8.999
Judge $repo (Sha $repo 'v0.8.999') (Sha $repo 'HEAD~1')
Check 'exit 0'                        0 $rc
Check 'and it is not called foreign'  'False' (Says 'is not what is checked out')

# --- the credential scan, armed by a file and by no name -------------------------------------
Write-Host 'with no .gitleaks.toml in the tree, the commits are not scanned'
Write-Lf $leaksArgs ''
Commit 'src/thing.txt' 'Push once without the scan armed #15'
OnlyNew $repo
Check 'exit 0'                 0 $rc
Check 'gitleaks never ran'     '' ((Get-Content $leaksArgs -Raw) -replace '\s', '')

Write-Host 'a .gitleaks.toml in the tree arms the scan, over the range the push carries'
Write-Lf $leaksArgs ''
Commit '.gitleaks.toml' 'Arm the credential scan of the probe #15'
$before = Sha $repo 'HEAD~1'
Judge $repo (Sha $repo HEAD) $before
Check 'exit 0'                    0 $rc
# The cmd stand-in writes its arguments with echo %*, which keeps the quotes around one with spaces
$leaks = @(Get-Content $leaksArgs | Where-Object { $_ })[-1] -creplace '"', ''
Check 'gitleaks read that range'  'True' ($leaks -clike "git --no-banner --log-opts=$(Sha $repo HEAD) ^$before --not --remotes=origin *")

Write-Host 'a credential in a pushed commit refuses, and says it cannot be recalled'
$env:PROBE_LEAKS = 'red'
OnlyNew $repo
Remove-Item Env:PROBE_LEAKS
Check 'exit 1'             1 $rc
Check 'it says what to do' 'True' (Says 'a commit that is pushed cannot be recalled')

Write-Host 'a gitleaks without gitleaks git, one from before 8.19, refuses and names doctor'
$env:PROBE_LEAKS = 'old'
OnlyNew $repo
Remove-Item Env:PROBE_LEAKS
Check 'exit 1'             1 $rc
Check 'it names doctor'    'True' ((Says 'no gitleaks 8.19 or newer') -and (Says 'Run ai-core doctor'))

# --- the names a push adds, derived from the families the trees already carry -------------------
# Two sibling repositories beside the one pushed: acme-shop has the parts backend, docs and
# frontend; acme-docs has docs and guide, so docs is a word of structure, no repository's name.
foreach ($s in @('acme-shop', 'acme-docs')) { $d = Join-Path $parent $s; & git init -q -b master $d; & git -C $d config user.email 'test@example.invalid'; & git -C $d config user.name 'test' }
foreach ($p in @('backend', 'docs', 'frontend')) { New-Item -ItemType Directory -Force -Path (Join-Path $parent "acme-shop\$p") | Out-Null; Write-Lf (Join-Path $parent "acme-shop\$p\a.txt") "x`n" }
foreach ($p in @('docs', 'guide')) { New-Item -ItemType Directory -Force -Path (Join-Path $parent "acme-docs\$p") | Out-Null; Write-Lf (Join-Path $parent "acme-docs\$p\a.txt") "x`n" }
foreach ($s in @('acme-shop', 'acme-docs')) { $d = Join-Path $parent $s; & git -C $d add -A; & git -C $d commit -q -m 'The repository #1' }
function Add-Dirs([string]$message, [string[]]$dirs) {  # one file in each new directory, one commit
  foreach ($d in $dirs) { New-Item -ItemType Directory -Force -Path (Join-Path $repo $d) | Out-Null; Write-Lf (Join-Path $repo "$d\en.json") "{}`n"; & git -C $repo add -- "$d/en.json" }
  $message | & git -C $repo commit -q -F -
}

Write-Host 'a family half named, and a part a sibling repository does not have: refused, with both'
Add-Dirs 'Add the shop texts #20' @('catalog/shop', 'catalog/shop-server')
OnlyNew $repo
Check 'exit 1'                      1 $rc
Check 'the half-named family'       'True' (Says 'catalog/shop beside catalog/shop-server: one member of the family says its side, the other does not')
Check 'the part the sibling lacks'  'True' (Says 'catalog/shop-server names a part of the repository acme-shop, and acme-shop has no server; its parts are backend, docs, frontend')
& git -C $repo reset -q --hard HEAD~1

Write-Host 'names derived from the family pass'
Add-Dirs 'Add the shop texts, named after its parts #20' @('catalog/shop-backend', 'catalog/shop-frontend')
OnlyNew $repo
Check 'exit 0'                      0 $rc

Write-Host "a word of structure is no repository's name: manual/docs-extra is not held against acme-docs"
Add-Dirs 'Add the extra documents #21' @('manual/docs-extra')
OnlyNew $repo
Check 'exit 0'                      0 $rc

Write-Host "a lone name that opens with a repository's name mirrors nothing: manual/shop-notes passes"
Add-Dirs 'Add the notes of the shop visit #23' @('manual/shop-notes')
OnlyNew $repo
Check 'exit 0'                      0 $rc

Write-Host 'a Naming: trailer keeps a name, and says why'
Add-Dirs "Add the server texts #22`n`nNaming: the product owner calls this part server" @('catalog/shop-server')
OnlyNew $repo
Check 'exit 0'                      0 $rc

# A move is read by its content, so every file below differs from every other: git pairs files of
# equal content across folders at will.
$mark = Sha $repo HEAD
function Seed-Dirs([string]$message, [string[]]$dirs) {  # one file of its own content in each, one commit
  foreach ($d in $dirs) { New-Item -ItemType Directory -Force -Path (Join-Path $repo $d) | Out-Null; Write-Lf (Join-Path $repo "$d/en.json") "{`"seed`":`"$d`"}`n"; & git -C $repo add -- "$d/en.json" }
  & git -C $repo commit -q -m $message
}
function Moved([string]$message, [string]$from, [string]$to) {  # one git mv, one commit
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent (Join-Path $repo $to)) | Out-Null
  & git -C $repo mv $from $to; & git -C $repo commit -q -m $message
}
Write-Host 'a folder moved with git mv keeps the names inside it'
Seed-Dirs 'Add the workshop seeds #24' @('apps/workshop/seeds', 'apps/workshop/seeds-demo')
Moved 'Rename the workshop app #24' 'apps/workshop' 'apps/bike-workshop'
OnlyNew $repo
Check 'exit 0'                      0 $rc

Write-Host 'a member moved to a new half name is refused'
Moved 'Rename the demo seeds #24' 'apps/bike-workshop/seeds-demo' 'apps/bike-workshop/seeds-x'
OnlyNew $repo
Check 'exit 1'                      1 $rc
Check 'the half-named family'       'True' (Says 'apps/bike-workshop/seeds beside apps/bike-workshop/seeds-x: one member of the family')

Write-Host 'a folder moved beside a member of a family it did not stand beside is refused'
Seed-Dirs 'Add the lab seeds #24' @('plain/seeds', 'lab/seeds-demo')
Moved 'Move the plain seeds to the lab #24' 'plain/seeds' 'lab/seeds'
OnlyNew $repo
Check 'exit 1'                      1 $rc
Check 'the half-named family'       'True' (Says 'lab/seeds beside lab/seeds-demo: one member of the family')

Write-Host 'a member moved from its family to another member of the same name is refused'
Seed-Dirs 'Add the kiosk seeds #24' @('kiosk/seeds', 'kiosk/seeds-demo', 'stall/seeds-demo')
Moved 'Move the kiosk seeds to the stall #24' 'kiosk/seeds' 'stall/seeds'
OnlyNew $repo
Check 'exit 1'                      1 $rc
Check 'the half-named family'       'True' (Says 'stall/seeds beside stall/seeds-demo: one member of the family')

Write-Host 'a member moved to the top, beside a member there, is refused'
Seed-Dirs 'Add the market plants #24' @('market/plants', 'market/plants-demo', 'plants-demo')
Moved 'Move the market plants to the top #24' 'market/plants' 'plants'
OnlyNew $repo
Check 'exit 1'                      1 $rc
Check 'the half-named family'       'True' (Says '(?m)^pre-push: plants beside plants-demo: one member of the family')

Write-Host 'a folder moved whole keeps its names, also where git pairs its empty files across'
foreach ($d in @('depot/seeds', 'depot/seeds-demo')) { New-Item -ItemType Directory -Force -Path (Join-Path $repo $d) | Out-Null; Write-Lf (Join-Path $repo "$d/.gitkeep") '' }
& git -C $repo add -- depot; & git -C $repo commit -q -m 'Add the depot #24'
& git -C $repo mv depot big-depot; New-Item -ItemType Directory -Force -Path (Join-Path $repo 'aaa') | Out-Null; Write-Lf (Join-Path $repo 'aaa/.gitkeep') ''; & git -C $repo add -- aaa
& git -C $repo commit -q -m 'Rename the depot, and add aaa #24'
OnlyNew $repo
Check 'exit 0'                      0 $rc

Write-Host 'a family copied out by moving one file of each member, the members staying, is refused'
foreach ($d in @('tools/seeds', 'tools/seeds-demo')) { New-Item -ItemType Directory -Force -Path (Join-Path $repo $d) | Out-Null; foreach ($f in @('a', 'b')) { Write-Lf (Join-Path $repo "$d/$f.json") "{`"seed`":`"$d/$f`"}`n" } }
& git -C $repo add -- tools; & git -C $repo commit -q -m 'Add the tool seeds #24'
foreach ($d in @('yard/seeds', 'yard/seeds-demo')) { New-Item -ItemType Directory -Force -Path (Join-Path $repo $d) | Out-Null }
& git -C $repo mv tools/seeds/a.json yard/seeds/a.json; & git -C $repo mv tools/seeds-demo/a.json yard/seeds-demo/a.json
& git -C $repo commit -q -m 'Move one tool seed of each into the yard #24'
OnlyNew $repo
Check 'exit 1'                      1 $rc
Check 'the half-named family'       'True' (Says 'yard/seeds beside yard/seeds-demo: one member of the family')

Write-Host 'a moved folder that names a part only where it lands is refused'
Seed-Dirs 'Add the shop api notes #24' @('misc/shop-api')
Moved 'Move the shop api notes into the catalog #24' 'misc/shop-api' 'catalog/shop-api'
OnlyNew $repo
Check 'exit 1'                      1 $rc
Check 'the part the sibling lacks'  'True' (Says 'catalog/shop-api names a part of the repository acme-shop, and acme-shop has no api')

Write-Host 'a name below a folder of non-ASCII letters is read, not skipped'
Seed-Dirs 'Add the demo seeds of the fields #24' @('über/lab/seeds-demo')
Seed-Dirs 'Add the seeds of the fields #24' @('über/lab/seeds')
OnlyNew $repo
Check 'exit 1'                      1 $rc
Check 'the half-named family'       'True' (Says 'über/lab/seeds beside über/lab/seeds-demo: one member of the family')

Write-Host 'a member of non-ASCII letters is read beside its sibling, not skipped'
Seed-Dirs 'Add the green seeds of the fields #24' @('feld/grün')
Seed-Dirs 'Add the green demo seeds of the fields #24' @('feld/grün-demo')
OnlyNew $repo
Check 'exit 1'                      1 $rc
Check 'the half-named family'       'True' (Says 'feld/grün beside feld/grün-demo: one member of the family')

# A folder name on Windows cannot hold a double quote, which git quotes in every path it prints
if ($IsWindows) { Write-Host '  skip a name below a folder with a double quote: Windows forbids the character' }
else {
  Write-Host 'a name below a folder with a double quote is read, not skipped'
  Seed-Dirs 'Add the demo seeds of the quoted lab #24' @('q"x/lab/seeds-demo')
  Seed-Dirs 'Add the seeds of the quoted lab #24' @('q"x/lab/seeds')
  OnlyNew $repo
  Check 'exit 1'                      1 $rc
  Check 'the half-named family'       'True' (Says 'q"x/lab/seeds beside q"x/lab/seeds-demo: one member of the family')

  Write-Host 'a folder with a double quote moved with git mv keeps the names inside it'
  Seed-Dirs 'Add the seeds of the quoted shop #24' @('q"x/shop/seeds', 'q"x/shop/seeds-demo')
  Moved 'Rename the quoted shop #24' 'q"x/shop' 'q"x/bike-shop'
  OnlyNew $repo
  Check 'exit 0'                      0 $rc
}
& git -C $repo reset -q --hard $mark

# --- the Windows entry point, held against the one text it copies ----------------------------
function Stub-Ps1([string]$path) { Write-Lf $path "Write-Host 'check: OK — every check green'`nexit 0`n" }
# against the commit the worktree branched from: master has moved on since, and a push over that
# would be a force push, which the gate refuses
function PushWt { Judge $wt (Sha $wt HEAD) "$(& git -C $wt merge-base HEAD master)".Trim() }

Write-Host 'a Windows entry point that is not the one text is refused, under either of its two names'
PushWt
Check 'both entry points and the .ps1 that is neither: exit 0' 0 $rc
Stub-Ps1 (Join-Path $wt 'scripts\check.ps1')
PushWt
Check 'the green stub at scripts/check.ps1: exit 1' 1 $rc
Check 'the refusal names the file' 'True' (Says 'scripts/check\.ps1 is not the Windows entry point every repository carries')
Check 'and says how to restore it' 'True' (Says 'Restore it: cp ')
& git -C $wt checkout -q -- scripts/check.ps1
Stub-Ps1 (Join-Path $wt 'build.ps1')
PushWt
Check 'the green stub at build.ps1: exit 1' 1 $rc
& git -C $wt checkout -q -- build.ps1
PushWt
Check 'both restored: exit 0' 0 $rc

# --- a repository without a check entry point --------------------------------------------------
Write-Host 'a repository without scripts/check.sh: nothing runs before the push, and no entry point is judged'
$bare = Join-Path $fake 'bare.git'; & git init -q --bare -b master $bare
$plain = Join-Path $fake 'plain'; & git init -q -b master $plain
& git -C $plain config user.email 'test@example.invalid'; & git -C $plain config user.name 'test'
Write-Lf (Join-Path $plain 'build.ps1') "Write-Host `"decides on its own`"`n"
& git -C $plain add -A; & git -C $plain commit -q -m 'A repository with no check #7'
& git -C $plain remote add origin $bare; & git -C $plain push -q -u origin master 2>$null
Write-Lf (Join-Path $plain 'more.txt') "more`n"; & git -C $plain add -A; & git -C $plain commit -q -m 'Add more #7'
OnlyNew $plain
Check 'exit 0'                            0 $rc
Check 'it says nothing runs'              'True' (Says 'no scripts/check\.sh in this repository')
Check 'the own build.ps1 is not refused'  'False' (Says 'Windows entry point')

# --- from a prompt: the current branch against its upstream ----------------------------------
Write-Host 'with nothing on standard input, the branch is judged against its upstream'
Push-Location $plain
try { $out = (& pwsh -NoProfile -File $gate 2>&1 | Out-String); $rc = $LASTEXITCODE } finally { Pop-Location }
Check 'exit 0'                 0 $rc
Check 'it names the upstream'  'True' (Says 'pre-push: judging master against origin/master')
& git -C $plain commit -q --allow-empty -m 'An empty commit that names nothing'
Push-Location $plain
try { $out = (& pwsh -NoProfile -File $gate 2>&1 | Out-String); $rc = $LASTEXITCODE } finally { Pop-Location }
Check 'a new unnamed commit is refused' 1 $rc
& git -C $plain reset -q --hard HEAD~1

# --- -Install: the shim -----------------------------------------------------------------------
Write-Host '-Install writes the shim, arms the clone, commits the shim on its own and says it has no origin to push to'
$fresh = Join-Path $fake 'fresh'; & git init -q -b master $fresh
& git -C $fresh config user.email 'test@example.invalid'; & git -C $fresh config user.name 'test'
Write-Lf (Join-Path $fresh 'open.txt') "work in progress`n"; & git -C $fresh add open.txt   # somebody's staged work stays out of the commit
function InstallIn([string]$tree) { Push-Location $tree; try { $script:out = (& pwsh -NoProfile -File $gate -Install 2>&1 | Out-String); $script:rc = $LASTEXITCODE } finally { Pop-Location } }
InstallIn $fresh
Check 'exit 0'                        0 $rc
Check 'created'                       'True' (Says '(?m)^pre-push: fresh: \.githooks/pre-push created\r?$')
Check 'post-checkout created'         'True' (Says '(?m)^pre-push: fresh: \.githooks/post-checkout created\r?$')
$checkoutText = [System.IO.File]::ReadAllText((Join-Path $fresh '.githooks\post-checkout'))
Check 'post-checkout starts init where .ai-core is missing' 'True' ($checkoutText.Contains("`nai-core init --no-doctor || echo `"post-checkout: the harness is NOT complete in this worktree (see above); run ai-core init here before you start`" >&2`n"))
Check 'post-checkout: LF, no carriage return' 'False' ($checkoutText.Contains("`r"))
Check 'the attributes rule, so the shims check out LF' 'True' ((Says '(?m)^pre-push: fresh: \.gitattributes: \.githooks/\* text eol=lf added; the shims check out LF everywhere\r?$') -and (@([System.IO.File]::ReadAllLines((Join-Path $fresh '.gitattributes'))) -ccontains '.githooks/* text eol=lf'))
Check 'git reads it'                  '.githooks/pre-push: eol: lf' "$(& git -C $fresh check-attr eol -- .githooks/pre-push)"
Check 'core.hooksPath set'            '.githooks' "$(& git -C $fresh config --get core.hooksPath)"
$shimText = [System.IO.File]::ReadAllText((Join-Path $fresh '.githooks\pre-push'))
Check 'the shim starts the gate'      'True' ($shimText.Contains("`nexec ai-core pre-push `"`$@`"`n"))
Check 'four lines, LF'                4 (([regex]::Matches($shimText, "`n")).Count)
Check 'it refuses without ai-core on the PATH' 'True' ($shimText.Contains('ai-core is not on the PATH of this shell'))
Check 'no carriage return'            'False' ($shimText.Contains("`r"))
Check 'committed'                     'True' (Says '(?m)^pre-push: fresh: committed [0-9a-f]')
Check 'no origin, not pushed'         'True' (Says '(?m)^pre-push: fresh: no origin; not pushed\r?$')
Check 'the commit subject'            'the hooks of ai-core: the push gate, init in a new worktree' "$(& git -C $fresh log -1 --format=%s)"
Check 'the No-issue trailer'          'written, committed and pushed by ai-core pre-push --install' ((& git -C $fresh log -1 "--format=%(trailers:key=No-issue,valueonly)" | Out-String).Trim())
Check 'the shims and the rule in the commit' '.gitattributes .githooks/post-checkout .githooks/pre-push' ((@(& git -C $fresh show --pretty=format: --name-only HEAD | Where-Object { $_ }) -join ' '))
Check 'the rule file is plain'        '100644' ("$(& git -C $fresh ls-tree HEAD .gitattributes)".Substring(0, 6))
Check 'with the executable bit'       '100755' ("$(& git -C $fresh ls-tree HEAD .githooks/pre-push)".Substring(0, 6))
Check 'post-checkout too'             '100755' ("$(& git -C $fresh ls-tree HEAD .githooks/post-checkout)".Substring(0, 6))
Check 'the staged work is still staged, uncommitted' 'A  open.txt' "$(& git -C $fresh status --porcelain open.txt)"
$head1 = "$(& git -C $fresh rev-parse HEAD)"
InstallIn $fresh
Check 'a second run: unchanged'       'True' (Says '(?m)^pre-push: fresh: \.githooks/pre-push unchanged\r?$')
Check 'post-checkout unchanged too'   'True' (Says '(?m)^pre-push: fresh: \.githooks/post-checkout unchanged\r?$')
Check 'and nothing about .gitattributes' 'False' (Says 'gitattributes')
Check 'and no new commit'             $head1 "$(& git -C $fresh rev-parse HEAD)"
Check 'and nothing about hooksPath'   'False' (Says 'hooksPath')
Write-Lf (Join-Path $fresh '.githooks\pre-push') "#!/usr/bin/env bash`nexec bash ../tooling/hooks/pre-push `"`$@`"`n"
& git -C $fresh commit -q -am 'An older shim, as a repository of the old tooling carries #9'
InstallIn $fresh
Check 'a shim of another kind: refreshed and committed' 'True' ((Says '(?m)^pre-push: fresh: \.githooks/pre-push refreshed\r?$') -and (Says '(?m)^pre-push: fresh: committed'))
Check 'and it is the shim again'      'True' ([System.IO.File]::ReadAllText((Join-Path $fresh '.githooks\pre-push')).Contains('exec ai-core pre-push'))

Write-Host 'post-checkout: a worktree cut from the checkout starts ai-core init; a branch checkout where .ai-core is present starts nothing'
# git starts the shim through bash, and bash finds ai-core on the PATH: a stub that writes down its arguments
$shimArgs = (Join-Path $fake 'shim-args.txt').Replace('\', '/')
Write-Lf (Join-Path $stub 'ai-core') "#!/bin/sh`nprintf '[%s] ' `"`$*`" >> `"$shimArgs`"`nexit 0`n"
if (-not $IsWindows) { & chmod +x (Join-Path $stub 'ai-core') }
New-Item -ItemType Directory -Path (Join-Path $fresh '.ai-core') -Force | Out-Null
& git -C $fresh checkout -q -b probe-branch 2>$null
Check 'nothing started in the checkout' 'False' (Test-Path $shimArgs)
$freshWt = Join-Path $fake 'fresh-wt'
$wtErr = (& git -C $fresh worktree add -q --detach $freshWt HEAD 2>&1 | Out-String); $rc = $LASTEXITCODE
Check 'git worktree add: exit 0'      0 $rc
Check 'ai-core init started in the new worktree' '[init --no-doctor] ' "$(if (Test-Path $shimArgs) { [System.IO.File]::ReadAllText($shimArgs) })"
Check 'nothing on stderr'             '' $wtErr.Trim()
& git -C $fresh worktree remove --force $freshWt 2>$null | Out-Null
Remove-Item -Force $shimArgs -ErrorAction SilentlyContinue

Write-Host 'post-checkout without ai-core on the PATH: the worktree is made, exit 0, and stderr says what to run'
$pathBefore = $env:PATH
# every directory that holds an ai-core leaves the PATH, the stand-in's and the machine's
$env:PATH = (@($env:PATH -split [IO.Path]::PathSeparator | Where-Object { $_ -and -not (Test-Path -LiteralPath (Join-Path $_ 'ai-core') -ErrorAction SilentlyContinue) -and -not (Test-Path -LiteralPath (Join-Path $_ 'ai-core.exe') -ErrorAction SilentlyContinue) }) -join [IO.Path]::PathSeparator)
try { $out = (& git -C $fresh worktree add -q --detach $freshWt HEAD 2>&1 | Out-String); $rc = $LASTEXITCODE } finally { $env:PATH = $pathBefore }
Check 'exit 0'                        0 $rc
Check 'the worktree is there'         'True' (Test-Path $freshWt)
Check 'it names the cause'            'True' (Says 'post-checkout: ai-core is not on the PATH of this shell, so this worktree has no harness yet; run ai-core init here before you start')
& git -C $fresh worktree remove --force $freshWt 2>$null | Out-Null
& git -C $fresh checkout -q master 2>$null; & git -C $fresh branch -q -D probe-branch 2>$null
Remove-Item -Recurse -Force (Join-Path $fresh '.ai-core')

Write-Host 'with an origin, the commit is pushed by ref, through the gate'
# git starts the shim through bash, and bash finds ai-core on the PATH: a stub that exits 0
Write-Lf (Join-Path $stub 'ai-core') "#!/bin/sh`nexit 0`n"
if (-not $IsWindows) { & chmod +x (Join-Path $stub 'ai-core') }
$originBare = Join-Path $fake 'origin.git'; & git init -q --bare -b master $originBare
$pushed = Join-Path $fake 'pushed'; & git init -q -b master $pushed
& git -C $pushed config user.email 'test@example.invalid'; & git -C $pushed config user.name 'test'
Write-Lf (Join-Path $pushed 'a.txt') "a`n"; & git -C $pushed add -A; & git -C $pushed commit -q -m 'Start #3'
& git -C $pushed remote add origin $originBare; & git -C $pushed push -q -u origin master 2>$null
# two clones of this state, which the origin moves past below: one clean, one with a change of its own
foreach ($c in @('behind', 'dirty')) { $d = Join-Path $fake $c; & git clone -q $originBare $d 2>$null; & git -C $d config user.email 'test@example.invalid'; & git -C $d config user.name 'test' }
[System.IO.File]::AppendAllText((Join-Path $fake 'dirty\a.txt'), "mine`n", $utf8)
InstallIn $pushed
Check 'exit 0'                        0 $rc
Check 'pushed to origin/master'       'True' (Says '(?m)^pre-push: pushed: pushed to origin/master\r?$')
Check 'the origin has the commit'     "$(& git -C $pushed rev-parse HEAD)" "$(& git -C $originBare rev-parse master)"

Write-Host 'an unpushed commit that touches only .gitignore and names no issue gets the trailer, and the push goes through'
Write-Lf (Join-Path $pushed '.gitignore') "node_modules/`n"; & git -C $pushed add .gitignore; & git -C $pushed commit -q -m 'chore: ignore node_modules'
InstallIn $pushed
Check 'exit 0'                        0 $rc
Check 'the shim needs no commit of its own' 'False' (Says '(?m)^pre-push: pushed: committed')
Check 'it says which commit and why'  'True' (Says 'chore: ignore node_modules\) touches only \.gitignore and names no issue; it gets the trailer')
Check 'the trailer is on that commit' 'the .gitignore block written by ai-core init' ((& git -C $pushed log -1 "--format=%(trailers:key=No-issue,valueonly)" HEAD | Out-String).Trim())
Check 'its subject is kept'           'chore: ignore node_modules' "$(& git -C $pushed log -1 --format=%s HEAD)"
Check 'pushed'                        'True' (Says '(?m)^pre-push: pushed: pushed to origin/master\r?$')
Check 'the origin has it all'         "$(& git -C $pushed rev-parse HEAD)" "$(& git -C $originBare rev-parse master)"

Write-Host 'a clone the origin has moved past catches up first: the shims arrive with it, no second commit, nothing to push'
InstallIn (Join-Path $fake 'behind')
Check 'exit 0'                        0 $rc
Check 'it says it caught up'          'True' (Says '(?m)^pre-push: behind: pulled 2 commit\(s\) from origin/master first\r?$')
Check 'the shims came with it'        'True' (Says '(?m)^pre-push: behind: \.githooks/pre-push unchanged\r?$')
Check 'no commit of its own'          'False' (Says '(?m)^pre-push: behind: committed')
Check 'level with the origin'         "$(& git -C $originBare rev-parse master)" "$(& git -C (Join-Path $fake 'behind') rev-parse HEAD)"

Write-Host 'a clone behind its origin with a change of its own: nothing written, nothing committed, and why'
$headD = "$(& git -C (Join-Path $fake 'dirty') rev-parse HEAD)"
InstallIn (Join-Path $fake 'dirty')
Check 'exit 1'                        1 $rc
Check 'it says why'                   'True' (Says '(?m)^pre-push: dirty: this checkout is 2 commit\(s\) behind origin/master, with changes to tracked files; pull, then run this again; nothing installed\r?$')
Check 'no shims'                      'False' (Test-Path (Join-Path $fake 'dirty\.githooks'))
Check 'no commit'                     $headD "$(& git -C (Join-Path $fake 'dirty') rev-parse HEAD)"

Write-Host "shims committed without the executable bit, as a copy that drops the file modes leaves them: committed with it and pushed; the project's own hook named and left"
$before = "$(& git -C $pushed rev-parse HEAD)"
Write-Lf (Join-Path $pushed '.githooks\pre-commit') "#!/bin/sh`nexit 0`n"
& git -C $pushed add --chmod=-x .githooks/pre-push .githooks/post-checkout .githooks/pre-commit
if (-not $IsWindows) { & chmod -x (Join-Path $pushed '.githooks/pre-push') (Join-Path $pushed '.githooks/post-checkout') (Join-Path $pushed '.githooks/pre-commit') }
& git -C $pushed -c advice.ignoredHook=false commit -q -m 'The hooks as a copy without the file modes writes them #4'; & git -C $pushed push -q --no-verify origin HEAD:master 2>$null
InstallIn $pushed
Check 'exit 0'                        0 $rc
Check 'committed'                     'True' (Says '(?m)^pre-push: pushed: committed ')
Check 'the origin has the bit'        '100755 100755' ((@(& git -C $originBare ls-tree master -- .githooks/post-checkout .githooks/pre-push) | ForEach-Object { ("$_" -split '\s+')[0] }) -join ' ')
Check "the project's own hook is named" 'True' (Says "(?m)^pre-push: pushed: \.githooks/pre-commit is not executable, so git skips it; it is the project's own and stays as it is\r?$")
Check 'and left as it is'             '100644' ("$(& git -C $originBare ls-tree master -- .githooks/pre-commit)" -split '\s+')[0]
& git -C $pushed push -q --no-verify --force origin "${before}:master" 2>$null; & git -C $pushed reset -q --hard $before

Write-Host 'an unpushed commit that touches something else and names no issue is still refused, by the gate'
Write-Lf (Join-Path $pushed 'x.txt') "x`n"; & git -C $pushed add x.txt; & git -C $pushed commit -q -m 'Add x without a ticket'
Write-Lf (Join-Path $pushed '.githooks\pre-push') "#!/usr/bin/env bash`nexec bash ../tooling/hooks/pre-push `"`$@`"`n"
# the real gate this time: git starts the shim, the shim starts ai-core, which is the clone's own gate here
Write-Lf (Join-Path $stub 'ai-core') "#!/bin/sh`nexec bash `"$($root.Replace('\', '/'))/bin/pre-push.sh`" `"`$@`"`n"
if (-not $IsWindows) { & chmod +x (Join-Path $stub 'ai-core') }
InstallIn $pushed
Check 'exit 1'                        1 $rc
Check 'the gate names the commit'     'True' (Says 'Add x without a ticket names no issue')
Check 'the push was refused, the commit stays' 'True' (Says 'the push was refused or failed \(see above\); the commit stays')
& git -C $pushed reset -q --hard origin/master   # the foreign commit goes; the origin is where the last push left it
Write-Lf (Join-Path $stub 'ai-core') "#!/bin/sh`nexit 0`n"

Write-Host 'every worktree of the repository gets the shim too, and only the checkout commits it'
Write-Lf (Join-Path $pushed '.githooks\pre-push') "#!/usr/bin/env bash`nexec bash ../tooling/hooks/pre-push `"`$@`"`n"
& git -C $pushed commit -q -am 'An older shim, as a worktree branched off it would carry #9'
$pushedWt = Join-Path $fake 'pushed-wt'; & git -C $pushed worktree add -q -b issue-9-probe $pushedWt master
$headBefore = "$(& git -C $pushed rev-parse HEAD)"
InstallIn $pushed
Check 'exit 0'                              0 $rc
Check 'the checkout: refreshed, committed, pushed' 'True' ((Says '(?m)^pre-push: pushed: \.githooks/pre-push refreshed\r?$') -and (Says '(?m)^pre-push: pushed: pushed to origin/master\r?$'))
Check 'the worktree: refreshed, and left to its own commit' 'True' (Says "(?m)^pre-push: pushed \(worktree pushed-wt\): \.githooks/pre-push refreshed; it goes out with that worktree's own commit\r?$")
Check 'the worktree carries the shim'       'True' ([System.IO.File]::ReadAllText((Join-Path $pushedWt '.githooks\pre-push')).Contains('exec ai-core pre-push'))
Check 'and post-checkout, carried already'          'True' ((Says "(?m)^pre-push: pushed \(worktree pushed-wt\): \.githooks/post-checkout unchanged; it goes out with that worktree's own commit\r?$") -and [System.IO.File]::ReadAllText((Join-Path $pushedWt '.githooks\post-checkout')).Contains('ai-core init --no-doctor'))
Check 'the worktree has it uncommitted'     ' M .githooks/pre-push' "$(& git -C $pushedWt status --porcelain .githooks/pre-push)"
Check 'the checkout moved by one commit'    $headBefore "$(& git -C $pushed rev-parse HEAD~1)"
& git -C $pushed worktree remove --force $pushedWt 2>$null | Out-Null

Write-Host '-Install -All: every repository under a folder, a plain folder skipped; a repository whose .gitattributes already makes the shims LF gets no rule'
$folder = Join-Path $fake 'folder'; New-Item -ItemType Directory -Path (Join-Path $folder 'not-a-repo') -Force | Out-Null
foreach ($r in @('one', 'two')) { $d = Join-Path $folder $r; & git init -q -b master $d; & git -C $d config user.email 'test@example.invalid'; & git -C $d config user.name 'test' }
Write-Lf (Join-Path $folder 'one\.gitattributes') "* text=auto eol=lf`n"; & git -C (Join-Path $folder 'one') add .gitattributes; & git -C (Join-Path $folder 'one') commit -q -m 'LF everywhere #2'
$out = (& pwsh -NoProfile -File $gate -Install -All $folder 2>&1 | Out-String); $rc = $LASTEXITCODE
Check 'exit 0'                      0 $rc
Check 'one: no rule added'          'False' (Says '(?m)^pre-push: one: \.gitattributes')
Check 'one: its .gitattributes is as it was' '* text=auto eol=lf' ([System.IO.File]::ReadAllText((Join-Path $folder 'one\.gitattributes')).Trim())
Check 'one: the shims alone in the commit' '.githooks/post-checkout .githooks/pre-push' ((@(& git -C (Join-Path $folder 'one') show --pretty=format: --name-only HEAD | Where-Object { $_ }) -join ' '))
Check 'two: the rule added'         'True' (Says '(?m)^pre-push: two: \.gitattributes: \.githooks/\* text eol=lf added')
Check 'two repositories'            'True' (Says 'the hooks are in 2 repositories')
Check 'both carry the shim, committed' 'True' (("$(& git -C (Join-Path $folder 'one') log -1 --format=%s)" -ceq 'the hooks of ai-core: the push gate, init in a new worktree') -and ("$(& git -C (Join-Path $folder 'two') log -1 --format=%s)" -ceq 'the hooks of ai-core: the push gate, init in a new worktree'))
Check 'the plain folder does not'   'False' (Test-Path (Join-Path $folder 'not-a-repo\.githooks'))
Push-Location (Join-Path $folder 'not-a-repo')
try { $out = (& pwsh -NoProfile -File $gate -Install 2>&1 | Out-String); $rc = $LASTEXITCODE } finally { Pop-Location }
Check '-Install outside a repository: exit 1' 1 $rc

Write-Host '-Install where .gitleaks.toml arms the scan and no gitleaks can run it: nothing written, nothing committed, doctor named'
$leaky = Join-Path $fake 'leaky'; & git init -q -b master $leaky; & git -C $leaky config user.email 'test@example.invalid'; & git -C $leaky config user.name 'test'
Write-Lf (Join-Path $leaky '.gitleaks.toml') "[extend]`nuseDefault = true`n"; & git -C $leaky add .gitleaks.toml; & git -C $leaky commit -q -m 'Arm the credential scan #15'
$head0 = "$(& git -C $leaky rev-parse HEAD)".Trim()
$env:PROBE_LEAKS = 'old'
Push-Location $leaky
try { $out = (& pwsh -NoProfile -File $gate -Install 2>&1 | Out-String); $rc = $LASTEXITCODE } finally { Pop-Location; Remove-Item Env:PROBE_LEAKS }
Check 'exit 1'                      1 $rc
Check 'it names doctor'             'True' (Says 'so the push of the shims would be refused; nothing installed\. Run ai-core doctor here')
Check 'no shims'                    'False' (Test-Path (Join-Path $leaky '.githooks'))
Check 'core.hooksPath untouched'    '' ("$(& git -C $leaky config --get core.hooksPath)".Trim())
Check 'no commit'                   $head0 ("$(& git -C $leaky rev-parse HEAD)".Trim())

& git -C $repo worktree remove --force $wt 2>$null | Out-Null
Set-Location $root
Remove-Item -Recurse -Force $fake -ErrorAction SilentlyContinue
if ($failed -gt 0) { Write-Host "`n$failed failed"; exit 1 }
Write-Host "`nall passed"
exit 0
