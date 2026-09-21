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
Set-Content -Path (Join-Path $stub 'gitleaks.cmd') -Value "@echo %*>> `"$leaksArgs`"`r`n@if `"%PROBE_LEAKS%`"==`"red`" (echo gitleaks: a credential stands in this range & exit /b 1)`r`n@exit /b 0" -Encoding ascii
if (-not $IsWindows) { Set-Content -Path (Join-Path $stub 'gitleaks') -Value "#!/bin/sh`necho `"`$*`" >> `"$leaksArgs`"`n[ `"`${PROBE_LEAKS:-green}`" = green ] || { echo 'gitleaks: a credential stands in this range'; exit 1; }`nexit 0" -Encoding ascii; & chmod +x (Join-Path $stub 'gitleaks') }
$env:PATH = "$stub;$env:PATH"

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
Check 'every check passed'         'True' (Says 'pre-push: every check passed')
$ran = @(Get-Content $checkRuns | Where-Object { $_ })[-1]
Check 'and the check that ran is the WORKTREE one' 'True' ($ran.Replace('\', '/') -clike '*/.worktrees/app/issue-5-probe/scripts/check.sh')

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
$leaks = @(Get-Content $leaksArgs | Where-Object { $_ })[-1]
Check 'gitleaks read that range'  'True' ($leaks -clike "git --no-banner --log-opts=$before..$(Sha $repo HEAD) *")

Write-Host 'a credential in a pushed commit refuses, and says it cannot be recalled'
$env:PROBE_LEAKS = 'red'
OnlyNew $repo
Remove-Item Env:PROBE_LEAKS
Check 'exit 1'             1 $rc
Check 'it says what to do' 'True' (Says 'a commit that is pushed cannot be recalled')

# --- the Windows entry point, held against the one text it copies ----------------------------
function Stub-Ps1([string]$path) { Write-Lf $path "Write-Host 'check: OK — every check green'`nexit 0`n" }
function PushWt { Judge $wt (Sha $wt HEAD) (Sha $repo master) }

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
Write-Host '-Install writes the shim, arms the clone, and says what to commit'
$fresh = Join-Path $fake 'fresh'; & git init -q -b master $fresh
Push-Location $fresh
try { $out = (& pwsh -NoProfile -File $gate -Install 2>&1 | Out-String); $rc = $LASTEXITCODE } finally { Pop-Location }
Check 'exit 0'                        0 $rc
Check 'created, with the executable bit to commit' 'True' (Says 'fresh: \.githooks/pre-push created; commit it with the executable bit: git add --chmod=\+x \.githooks/pre-push')
Check 'core.hooksPath set'            '.githooks' "$(& git -C $fresh config --get core.hooksPath)"
$shimText = [System.IO.File]::ReadAllText((Join-Path $fresh '.githooks\pre-push'))
Check 'the shim starts the gate'      'True' ($shimText.Contains("`nexec ai-core pre-push `"`$@`"`n"))
Check 'four lines, LF'                4 (([regex]::Matches($shimText, "`n")).Count)
Check 'it refuses without ai-core on the PATH' 'True' ($shimText.Contains('ai-core is not on the PATH of this shell'))
Check 'no carriage return'            'False' ($shimText.Contains("`r"))
Push-Location $fresh
try { $out = (& pwsh -NoProfile -File $gate -Install 2>&1 | Out-String); $rc = $LASTEXITCODE } finally { Pop-Location }
Check 'a second run: unchanged'       'True' (Says 'fresh: \.githooks/pre-push unchanged')
Check 'and nothing about hooksPath'   'False' (Says 'hooksPath')
Write-Lf (Join-Path $fresh '.githooks\pre-push') "#!/usr/bin/env bash`nexec bash ../tooling/hooks/pre-push `"`$@`"`n"
Push-Location $fresh
try { $out = (& pwsh -NoProfile -File $gate -Install 2>&1 | Out-String); $rc = $LASTEXITCODE } finally { Pop-Location }
Check 'a shim of another kind: refreshed' 'True' (Says 'fresh: \.githooks/pre-push refreshed; commit it')
Check 'and it is the shim again'      'True' ([System.IO.File]::ReadAllText((Join-Path $fresh '.githooks\pre-push')).Contains('exec ai-core pre-push'))

Write-Host 'every worktree of the repository gets the shim too: a push runs the file of the tree it comes from'
& git -C $fresh config user.email 'test@example.invalid'; & git -C $fresh config user.name 'test'
& git -C $fresh add -A; & git -C $fresh commit -q -m 'Carry the shim #9'
Write-Lf (Join-Path $fresh '.githooks\pre-push') "#!/usr/bin/env bash`nexec bash ../tooling/hooks/pre-push `"`$@`"`n"
& git -C $fresh commit -q -am 'An older shim, as a worktree branched off it would carry #9'
$freshWt = Join-Path $fake 'fresh-wt'; & git -C $fresh worktree add -q -b issue-9-probe $freshWt master
Push-Location $fresh
try { $out = (& pwsh -NoProfile -File $gate -Install 2>&1 | Out-String); $rc = $LASTEXITCODE } finally { Pop-Location }
Check 'exit 0'                              0 $rc
Check 'the main checkout: refreshed'        'True' (Says '(?m)^pre-push: fresh: \.githooks/pre-push refreshed')
Check 'the worktree: refreshed, and named'  'True' (Says '(?m)^pre-push: fresh \(worktree fresh-wt\): \.githooks/pre-push refreshed')
Check 'the worktree carries the shim'       'True' ([System.IO.File]::ReadAllText((Join-Path $freshWt '.githooks\pre-push')).Contains('exec ai-core pre-push'))
& git -C $fresh worktree remove --force $freshWt 2>$null | Out-Null

Write-Host '-Install -All: every repository under a folder, a plain folder skipped'
$folder = Join-Path $fake 'folder'; New-Item -ItemType Directory -Path (Join-Path $folder 'not-a-repo') -Force | Out-Null
foreach ($r in @('one', 'two')) { & git init -q -b master (Join-Path $folder $r) }
$out = (& pwsh -NoProfile -File $gate -Install -All $folder 2>&1 | Out-String); $rc = $LASTEXITCODE
Check 'exit 0'                      0 $rc
Check 'two repositories'            'True' (Says 'the shim is in 2 repositories')
Check 'both carry the shim'         'True' ((Test-Path (Join-Path $folder 'one\.githooks\pre-push')) -and (Test-Path (Join-Path $folder 'two\.githooks\pre-push')))
Check 'the plain folder does not'   'False' (Test-Path (Join-Path $folder 'not-a-repo\.githooks'))
Push-Location (Join-Path $folder 'not-a-repo')
try { $out = (& pwsh -NoProfile -File $gate -Install 2>&1 | Out-String); $rc = $LASTEXITCODE } finally { Pop-Location }
Check '-Install outside a repository: exit 1' 1 $rc

& git -C $repo worktree remove --force $wt 2>$null | Out-Null
Set-Location $root
Remove-Item -Recurse -Force $fake -ErrorAction SilentlyContinue
if ($failed -gt 0) { Write-Host "`n$failed failed"; exit 1 }
Write-Host "`nall passed"
exit 0
