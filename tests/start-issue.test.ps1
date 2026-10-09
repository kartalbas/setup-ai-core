# The PowerShell twin of start-issue.test.sh, asserting the SAME refusals and the SAME worktree.
#
# It runs inside a temporary repository with a temporary origin, both built and deleted here,
# and with a FAKE gh on PATH: no real worktree is created anywhere and nothing leaves the
# machine.
#
#   pwsh -File test/start-issue.test.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fake = Join-Path ([IO.Path]::GetTempPath()) "start-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$env:GH_CACHE_DIRECTORY = Join-Path $fake 'cache'
New-Item -ItemType Directory -Path $fake | Out-Null
$log = Join-Path $fake 'calls.txt'
# The board number is one no board has, so the ids this test invents land in a cache directory
# of their own and are taken away with it.
$env:GH_PROJECT_NUMBER = '999980'

@"
`$a = `$args -join ' '
Add-Content -Path '$log' -Value `$a
if (`$a -match 'repo view')           { 'example-org/example-repo'; exit 0 }
# The issue of another repository (the cross-repository case below): asked of this repository,
# the same number is Not Found, so a read in the wrong one shows as a failure, not a wrong title.
if (`$a -match 'other-org/tracker/issues/[0-9]+/comments') { '[]'; exit 0 }
if (`$a -match 'other-org/tracker/issues/') { '{"number":171,"title":"Alert on a stuck run","state":"open","labels":[],"assignees":[{"login":"tester"}],"body":"The rule lands in the other repository."}'; exit 0 }
if (`$a -match 'issues/171') { '{"message":"Not Found"}'; [Console]::Error.WriteLine('gh: Not Found (HTTP 404)'); exit 1 }
if (`$a -match 'comments')            { '[]'; exit 0 }
if (`$a -match '--jq .node_id')       { 'I_node163'; exit 0 }
if (`$a -match 'projectV2\(number:')  { 'PVT_kwstart'; exit 0 }
if (`$a -match 'fields\(first:50\)')  { 'Status' + [char]9 + 'FID' + [char]9 + 'todo' + [char]9 + 'OPT_todo'; 'Status' + [char]9 + 'FID' + [char]9 + 'implementing' + [char]9 + 'OPT_impl'; exit 0 }
if (`$a -match 'addProjectV2ItemById') { 'PVTI_item163'; exit 0 }
if (`$a -match 'projectItems')        { exit 0 }
if (`$a -match 'projectsV2\(first' -and (Test-Path '$fake/no-board')) { exit 0 }
if (`$a -match 'graphql')             { '{}'; exit 0 }
if (`$a -match 'api user')            { '{"login":"tester"}'; exit 0 }
if (`$a -match 'issues/165') {
  # U+212A KELVIN SIGN, written as a code point so this file stays plain ASCII.
  '{"number":165,"title":"Read the ' + [char]0x212A + 'ELVIN board","state":"open","labels":[],"assignees":[{"login":"tester"}],"body":"x"}'
  exit 0
}
if (`$a -match 'issues/') {
  `$who = if (`$env:ASSIGNEE) { `$env:ASSIGNEE } else { 'tester' }
  '{"number":163,"title":"Read the board whole","state":"open","labels":[],"assignees":[{"login":"' + `$who + '"}],"body":"The count is a guess."}'
  exit 0
}
'{}'
exit 0
"@ | Set-Content -Path (Join-Path $fake 'gh.ps1') -Encoding utf8NoBOM
"@echo off`r`npwsh -NoProfile -File `"$fake\gh.ps1`" %*" |
  Set-Content -Path (Join-Path $fake 'gh.cmd') -Encoding ascii
if (-not $IsWindows) { Set-Content -Path (Join-Path $fake 'gh') -Value "#!/bin/sh`nexec pwsh -NoProfile -File `"$fake/gh.ps1`" `"`$@`"" -Encoding ascii; & chmod +x (Join-Path $fake 'gh') }
$env:PATH = "$fake$([IO.Path]::PathSeparator)$env:PATH"
# The team modes are not what this test proves; a table whose probes always pass keeps the
# gate out of the way. team-modes.test.ps1 proves the gate itself.
$modesTable = Join-Path $fake 'team-modes.tsv'
Set-Content -Path $modesTable -Value "claude`tcaveman`tlite`talways`t-`t-" -Encoding utf8NoBOM
$env:TEAM_MODES_FILE = $modesTable

$failed = 0
function Check($name, $expected, $actual) {
  if ("$expected" -eq "$actual") { Write-Host "  ok   $name" }
  else { Write-Host "  FAIL $name`n       expected: $expected`n       actual:   $actual"; $script:failed++ }
}

# git is given an identity and a default branch here, so the test does not depend on whatever
# the machine's own configuration happens to be.
function Dress([string]$Path) {
  & git -C $Path config user.email 'test@example.invalid'
  & git -C $Path config user.name 'test'
  & git -C $Path config commit.gpgsign false
  & git -C $Path config core.autocrlf false
}

$origin = Join-Path $fake 'origin.git'
$checkouts = Join-Path $fake 'checkouts'
$work = Join-Path $checkouts 'example-repo'
New-Item -ItemType Directory -Force -Path $checkouts | Out-Null
& git -c init.defaultBranch=master init -q --bare $origin
& git -c init.defaultBranch=master init -q $work
Dress $work
'one' | Set-Content -Path (Join-Path $work 'README.md') -Encoding utf8NoBOM
& git -C $work add -A; & git -C $work commit -q -m 'the first commit'
& git -C $work remote add origin $origin
& git -C $work push -q -u origin master
& git -C $work remote set-head origin -a | Out-Null
# The main checkout carries the harness data a worktree inherits; nothing reaches the network
New-Item -ItemType Directory -Force -Path (Join-Path $work '.ai-core') | Out-Null
[IO.File]::WriteAllText((Join-Path $work '.ai-core/config.env'), ('UPDATE_CHECK="never"' + "`n"))
Add-Content -Path (Join-Path $work '.git/info/exclude') -Value '/.ai-core/'

$start = Join-Path $root 'bin/start-issue.ps1'
function Invoke-Start([int]$Number) {
  Push-Location $work
  try {
    $script:said = ''
    $script:printed = @()
    try { $script:printed = @(& $start -Number $Number 2>&1 | ForEach-Object { "$_" }) }
    catch { $script:said = $_.Exception.Message }
    return ($script:said -eq '')
  } finally { Pop-Location }
}
function Branches { ((& git -C $work for-each-ref '--format=%(refname:short)' refs/heads) -join ' ') }
function WorktreeCount { @((& git -C $work worktree list --porcelain) | Where-Object { $_ -match '^worktree ' }).Count }
function Calls { @(Get-Content $log -ErrorAction SilentlyContinue) }

Write-Host 'a working copy with changes in it opens no worktree'
'unsaved' | Add-Content -Path (Join-Path $work 'README.md')
$ok = Invoke-Start 163
Check 'it throws'      'False' ([string]$ok)
Check 'it says which'  'True'  ([bool]($said -match 'the working copy has changes'))
Check 'no branch made' 'master' (Branches)
Check 'one worktree'   1 (WorktreeCount)
& git -C $work checkout -q -- README.md

Write-Host 'a master behind origin is pulled first, not branched from'
$other = Join-Path $fake 'other'
& git clone -q $origin $other
Dress $other
'two' | Add-Content -Path (Join-Path $other 'README.md')
& git -C $other add -A; & git -C $other commit -q -m 'a commit somebody else pushed'
& git -C $other push -q origin HEAD:master
$ok = Invoke-Start 163
Check 'it throws'       'False' ([string]$ok)
Check 'it says how far' 'True'  ([bool]($said -match 'master is 1 commit\(s\) behind origin/master'))
Check 'no branch made'  'master' (Branches)
& git -C $work pull -q --ff-only origin master

Write-Host "somebody else's issue opens no worktree"
Remove-Item $log -ErrorAction SilentlyContinue
$env:ASSIGNEE = 'somebody'
$ok = Invoke-Start 163
$env:ASSIGNEE = $null
Check 'it throws'      'False' ([string]$ok)
Check 'it names both'  'True'  ([bool]($said -match '#163 is assigned to @somebody, not to @tester'))
Check 'no branch made' 'master' (Branches)
Check 'the card did not move' 'False' ([bool]((Calls) -match 'oid=OPT_impl'))

# A worktree of another issue whose work landed three days ago: the run that opens the next one
# removes it (finish-issue -Sweep)
$old = Join-Path $checkouts '.worktrees/example-repo/issue-170-old'
New-Item -ItemType Directory -Force -Path (Join-Path $checkouts '.worktrees/example-repo') | Out-Null
& git -C $work worktree add -q -b issue-170-old $old origin/master 2>$null
Dress $old
'old' | Add-Content -Path (Join-Path $old 'README.md')
& git -C $old add -A
$env:GIT_AUTHOR_DATE = $env:GIT_COMMITTER_DATE = [DateTime]::UtcNow.AddDays(-3).ToString('yyyy-MM-ddTHH:mm:ssZ')
try { & git -C $old commit -q -m 'An old change (#170)' } finally { $env:GIT_AUTHOR_DATE = $null; $env:GIT_COMMITTER_DATE = $null }
& git -C $old push -q origin HEAD:master 2>$null
& git -C $work pull -q --ff-only origin master 2>$null

Write-Host 'the worktree, the card and the thread come out of one run'
Remove-Item $log -ErrorAction SilentlyContinue
$ok = Invoke-Start 163
$tree = Join-Path $checkouts '.worktrees/example-repo/issue-163-read-the-board-whole'
Check 'it does not throw'  'True' ([string]$ok)
Check 'the worktree line'  'True' ([bool]($printed[0] -match '^Worktree .*issue-163-read-the-board-whole on issue-163-read-the-board-whole, cut from origin/master\.$'))
Check 'it is there'        'True' ([string](Test-Path -LiteralPath $tree))
Check 'two worktrees'      2 (WorktreeCount)
Check 'the branch'         'issue-163-read-the-board-whole master' (Branches)
Check 'the card moved'     '#163 -> implementing' $printed[1]
Check 'to that option'     'True' ([bool]((Calls) -match 'oid=OPT_impl'))
Check 'the thread'         1 @($printed | Where-Object { $_ -eq '#163 Read the board whole' }).Count
Check 'the landed worktree of #170 is gone' 'False' ([string](Test-Path -LiteralPath $old))
Check 'and named'          'True' ([bool](@($printed | Where-Object { $_ -match 'issue-170-old: landed, removed$' }).Count))
Check 'the board is not read whole' 0 (@(Calls | Where-Object { $_.Contains('items(first:100, after:') }).Count)
Check 'the worktree is on the new branch' 'issue-163-read-the-board-whole' `
  (((& git -C $tree rev-parse --abbrev-ref HEAD) -join '').Trim())

Write-Host 'a worktree for that number already there is not opened twice'
$ok = Invoke-Start 163
Check 'it throws'           'False' ([string]$ok)
Check 'it names it'         'True'  ([bool]($said -match 'a branch for this issue exists already: issue-163-read-the-board-whole'))
Check 'still two worktrees' 2 (WorktreeCount)

# WHAT SEPARATES THE TWO TWINS. The title answered for issue 165 carries U+212A KELVIN SIGN, which
# .ToLowerInvariant() maps to `k` and `tr '[:upper:]' '[:lower:]'` leaves alone, so the same issue
# produced issue-165-read-the-kelvin-board on this shell and issue-165-read-the-elvin-board on the
# other. Both twins assert the same name here, which is what makes the pair provable rather than
# merely both green.
Write-Host 'the two folds answer alike on a letter only one of them lowercases'
$ok = Invoke-Start 165
$made = @((& git -C $work for-each-ref '--format=%(refname:short)' refs/heads) |
  Where-Object { $_ -clike 'issue-165*' })
Check 'it does not throw' 'True' ([string]$ok)
Check 'the slug folds A-Z and nothing else' 'issue-165-read-the-elvin-board' ($made -join ' ')

Write-Host 'a repository on no board: the worktree opens, and the status says it has nowhere to go'
New-Item -ItemType File -Path (Join-Path $fake 'no-board') | Out-Null
Set-Content -Path $log -Value $null
$env:GH_PROJECT_NUMBER = ''
$ok = Invoke-Start 166
Check 'it does not throw'      'True'  ([string]$ok)
Check 'it says so'             'True'  ([bool](@($printed) -ceq '#166 -> implementing not set: example-org/example-repo is on no board'))
Check 'no warning'             'False' ([bool](($printed -join "`n") -match 'did NOT move'))
Check 'no card was looked for' 0       (@(Calls | Where-Object { $_ -match 'addProjectV2ItemById' }).Count)
Write-Host 'issue-priority on a repository on no board says so and exits zero'
Push-Location $work
try { $said = (@(& (Join-Path $root 'bin/issue-priority.ps1') -Number 166 -Priority P2 2>&1 | ForEach-Object { "$_" }) -join "`n") } finally { Pop-Location }
Check 'it says so'             '#166 -> P2 not set: example-org/example-repo is on no board' $said
$env:GH_PROJECT_NUMBER = '999980'
Remove-Item -Path (Join-Path $fake 'no-board')

Write-Host 'an origin/HEAD naming a branch the remote no longer has: the default branch is asked of the remote'
& git -C $work symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/gone
$ok = Invoke-Start 168
Check 'it does not throw'      'True' ([string]$ok)
Check 'cut from origin/master' 'True' ([bool](@($printed) -cmatch '^Worktree .*issue-168-.*, cut from origin/master\.$'))
& git -C $work remote set-head origin -a | Out-Null

Write-Host 'an issue of another repository: cut here, read there, and its repository recorded on the branch'
New-Item -ItemType File -Path (Join-Path $fake 'no-board') | Out-Null
Set-Content -Path $log -Value $null
$env:GH_PROJECT_NUMBER = ''
Push-Location $work
try { $said = ''; $printed = @(& $start -Number 171 -Repo other-org/tracker 2>&1 | ForEach-Object { "$_" }) }
catch { $said = $_.Exception.Message } finally { Pop-Location }
$cut = 'issue-171-alert-on-a-stuck-run'
Check 'it does not throw'               '' $said
Check 'the branch carries the number'    $cut ((& git -C $work for-each-ref '--format=%(refname:short)' refs/heads | Where-Object { $_ -like 'issue-171*' }) -join ' ')
Check 'the repository is recorded on it' 'other-org/tracker' (& git -C $work config --get "branch.$cut.issueRepository")
Check 'the issue was read there'         'True' ([bool](Calls | Where-Object { $_ -match 'other-org/tracker/issues/171' }))
Check 'and never here'                   0 (@(Calls | Where-Object { $_ -match 'example-org/example-repo/issues' }).Count)

Write-Host 'its own repository, named in another case, is no other repository'
Push-Location $work
try { $said = ''; $null = @(& $start -Number 172 -Repo Example-Org/Example-Repo 2>&1) }
catch { $said = $_.Exception.Message } finally { Pop-Location }
Check 'it does not throw'               '' $said
Check 'nothing is recorded'              '' "$(& git -C $work config --get-regexp '^branch\.issue-172-.*\.issuerepository$')"

Write-Host 'session-start in that worktree reads the issue where the branch says, and ends ready'
$wt = Join-Path $checkouts ".worktrees/example-repo/$cut"
$env:AI_CORE_UPDATE_CHECK = 'never'
function Invoke-SessionStart { Push-Location $wt; try { @(& pwsh -NoProfile -File (Join-Path $root 'bin/session-start.ps1') @args 2>&1 | ForEach-Object { "$_" }) } finally { Pop-Location } }
$out = Invoke-SessionStart
Check 'it exits zero'                    0 $LASTEXITCODE
Check 'it names the issue by its repository' 'True' ([bool](@($out) -cmatch '^This worktree carries issue other-org/tracker#171\.'))
Check 'it carries the thread'            'True' ([bool](($out -join "`n").Contains('The rule lands in the other repository.')))
Check 'it ends ready'                    'True' ([bool](@($out) -ceq 'Ready for task execution.'))
Check 'the JSON names the repository'    'other-org/tracker' ((Invoke-SessionStart -Json) -join "`n" | ConvertFrom-Json).issue_repository

Write-Host 'an issue that cannot be read: the start does not end as if it had been read'
& git -C $work config --unset "branch.$cut.issueRepository"
$out = Invoke-SessionStart
Check 'it exits zero'                    0 $LASTEXITCODE
Check 'no plain ready'                   'False' ([bool](@($out) -ceq 'Ready for task execution.'))
Check 'the last line names the miss'     'True' ([bool](@($out)[-1] -cmatch '^Ready for task execution, but WITHOUT the issue: #171 could not be read \('))
$json = (Invoke-SessionStart -Json) -join "`n" | ConvertFrom-Json
Check 'the JSON names no repository'     'True' ([bool]($json.PSObject.Properties.Name -contains 'issue_repository' -and $null -eq $json.issue_repository))
& git -C $work worktree remove --force $wt 2>$null | Out-Null
$env:GH_PROJECT_NUMBER = '999980'
Remove-Item -Path (Join-Path $fake 'no-board')

Set-Location $root
& git -C $work worktree remove --force $tree 2>$null | Out-Null
Remove-Item -Recurse -Force $fake -ErrorAction SilentlyContinue
$env:GH_PROJECT_NUMBER = $null
if ($failed -gt 0) { Write-Host "`n$failed failed"; exit 1 }
Write-Host "`nall passed"
