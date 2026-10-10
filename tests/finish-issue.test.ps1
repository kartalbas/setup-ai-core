# The PowerShell twin of finish-issue.test.sh, asserting the SAME refusals, removals and card moves.
#
# It runs inside a temporary repository with a temporary origin, both built and deleted here, and
# with a FAKE gh on PATH: nothing leaves the machine.
#
#   pwsh -File test/finish-issue.test.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fake = Join-Path ([IO.Path]::GetTempPath()) "finish-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$env:GH_CACHE_DIRECTORY = Join-Path $fake 'cache'
New-Item -ItemType Directory -Path $fake | Out-Null
$log = Join-Path $fake 'calls.txt'
$board = Join-Path $fake 'board.tsv'
$state = Join-Path $fake 'state.txt'
$env:GH_PROJECT_NUMBER = '999983'

@"
`$a = `$args -join ' '
Add-Content -Path '$log' -Value `$a
if (`$a -match 'repo view')           { 'example-org/example-repo'; exit 0 }
if (`$a -match 'issue comment')       { 'https://example.invalid/example-org/example-repo/issues/163#issuecomment-1'; exit 0 }
# status-sync's query of the repository's issues names comments and projectItems too
if (`$a -match 'issues\(states:OPEN') { if (Test-Path '$fake/issues-down') { [Console]::Error.WriteLine('the issues are down'); exit 1 }; '{"data":{"repository":{"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}'; exit 0 }
if (`$a -match 'comments')            { '[]'; exit 0 }
if (`$a -match '--jq .node_id')       { 'I_node163'; exit 0 }
if (`$a -match 'projectV2\(number:')  { 'PVT_kwfinish'; exit 0 }
if (`$a -match 'fields\(first:50\)')  { Get-Content -Path '$board'; exit 0 }
if (`$a -match 'addProjectV2ItemById') { 'PVTI_item163'; exit 0 }
if (`$a -match 'projectItems')        { exit 0 }
if (`$a -match 'projectsV2\(first' -and (Test-Path '$fake/no-board')) { exit 0 }
if (`$a -match 'graphql')             { '{}'; exit 0 }
if (`$a -match 'api user')            { '{"login":"tester"}'; exit 0 }
if (`$a -match 'issues/') {
  '{"number":163,"title":"Read the board whole","state":"' + (Get-Content -Path '$state' -Raw).Trim() + '","labels":[],"assignees":[],"body":"The count is a guess."}'
  exit 0
}
'{}'
exit 0
"@ | Set-Content -Path (Join-Path $fake 'gh.ps1') -Encoding utf8NoBOM
"@echo off`r`npwsh -NoProfile -File `"$fake\gh.ps1`" %*" |
  Set-Content -Path (Join-Path $fake 'gh.cmd') -Encoding ascii
if (-not $IsWindows) { Set-Content -Path (Join-Path $fake 'gh') -Value "#!/bin/sh`nexec pwsh -NoProfile -File `"$fake/gh.ps1`" `"`$@`"" -Encoding ascii; & chmod +x (Join-Path $fake 'gh') }
$env:PATH = "$fake$([IO.Path]::PathSeparator)$env:PATH"
$t = [char]9
function Set-Board([string[]]$Columns) {
  Set-Content -Path $board -Value ($Columns | ForEach-Object { "Status${t}FID${t}$_${t}OPT_$_" }) -Encoding utf8NoBOM
  Remove-Item -Recurse -Force $env:GH_CACHE_DIRECTORY -ErrorAction SilentlyContinue
}
Set-Board @('todo', 'implementing', 'testing', 'done')
Set-Content -Path $state -Value 'open' -Encoding utf8NoBOM

$failed = 0
function Check($name, $expected, $actual) {
  if ("$expected" -eq "$actual") { Write-Host "  ok   $name" }
  else { Write-Host "  FAIL $name`n       expected: $expected`n       actual:   $actual"; $script:failed++ }
}
function Dress([string]$Path) {
  & git -C $Path config user.email 'test@example.invalid'
  & git -C $Path config user.name 'test'
  & git -C $Path config commit.gpgsign false
  & git -C $Path config core.autocrlf false
}

$origin = Join-Path $fake 'origin.git'
$checkouts = Join-Path $fake 'checkouts'
$work = Join-Path $checkouts 'example-repo'
$trees = Join-Path $checkouts '.worktrees/example-repo'
New-Item -ItemType Directory -Force -Path $trees | Out-Null
& git -c init.defaultBranch=master init -q --bare $origin
& git -c init.defaultBranch=master init -q $work
Dress $work
'one' | Set-Content -Path (Join-Path $work 'README.md') -Encoding utf8NoBOM
& git -C $work add -A; & git -C $work commit -q -m 'the first commit'
& git -C $work remote add origin $origin
& git -C $work push -q -u origin master 2>$null
& git -C $work remote set-head origin -a | Out-Null

$finish = Join-Path $root 'bin/finish-issue.ps1'
function Invoke-Finish {
  param([string]$Number = '', [switch]$Sweep, [switch]$DryRun, [switch]$Landed, [string]$In = '')
  Push-Location $(if ($In) { $In } else { $work })
  try {
    $script:said = ''
    $script:printed = ''
    try { $script:printed = (@(& $finish -Number $Number -Sweep:$Sweep -DryRun:$DryRun -Landed:$Landed 2>&1 | ForEach-Object { "$_" }) -join "`n") }
    catch { $script:said = $_.Exception.Message }
    return ($script:said -eq '')
  } finally { Pop-Location }
}
function Open-Tree([string]$Branch) { & git -C $work worktree add -q -b $Branch (Join-Path $trees $Branch) origin/master 2>$null; Dress (Join-Path $trees $Branch) }
function Land([string]$Branch, [string]$Message, [string]$Date = '') {
  $tree = Join-Path $trees $Branch
  $Message | Add-Content -Path (Join-Path $tree 'README.md')
  & git -C $tree add -A
  $env:GIT_AUTHOR_DATE = $Date; $env:GIT_COMMITTER_DATE = $Date
  try { & git -C $tree commit -q -m $Message } finally { $env:GIT_AUTHOR_DATE = $null; $env:GIT_COMMITTER_DATE = $null }
  & git -C $tree push -q origin HEAD:master 2>$null
  & git -C $work pull -q --ff-only origin master 2>$null
}
function Has-Tree([string]$Branch) { [string](Test-Path (Join-Path $trees $Branch)) }
function Has-Branch([string]$Branch) { & git -C $work rev-parse -q --verify "refs/heads/$Branch" *>$null; [string]($LASTEXITCODE -eq 0) }
function Calls { (@(Get-Content $log -ErrorAction SilentlyContinue) -join "`n") }
function Moves { @(Get-Content $log -ErrorAction SilentlyContinue | Where-Object { $_ -match 'oid=OPT_' }).Count }

Write-Host 'a worktree with changes stays, and says why'
$b = 'issue-163-read-the-board-whole'
Open-Tree $b
'unsaved' | Add-Content -Path (Join-Path $trees "$b/README.md")
$ok = Invoke-Finish -Number 163
Check 'it throws'          'False' ([string]$ok)
Check 'it says which'      'True'  ([bool]($said -match 'issue-163-read-the-board-whole has changes'))
Check 'the worktree stays' 'True'  (Has-Tree $b)
& git -C (Join-Path $trees $b) checkout -q -- README.md

Write-Host 'a worktree with a commit origin does not have stays, and says so'
'mine' | Add-Content -Path (Join-Path $trees "$b/README.md")
& git -C (Join-Path $trees $b) commit -q -am 'Not pushed yet (#163)'
$ok = Invoke-Finish -Number 163
Check 'it throws'           'False' ([string]$ok)
Check 'it names the commit' 'True'  ([bool]($said -match 'has 1 commit\(s\) whose change is not on origin/master'))
Check 'the worktree stays'  'True'  (Has-Tree $b)

Write-Host 'a landed worktree goes with its branch, the card moves to testing, and the issue says what landed'
& git -C (Join-Path $trees $b) push -q origin HEAD:master 2>$null
Set-Content -Path $log -Value $null
Set-Board @('todo', 'implementing', 'testing', 'done')
$ok = Invoke-Finish -Number 163
Check 'it runs'               'True'  ([string]$ok)
Check 'the worktree is gone'  'False' (Has-Tree $b)
Check 'the branch is gone'    'False' (Has-Branch $b)
Check 'the card moved to testing' 1   (@(Get-Content $log | Where-Object { $_ -match 'oid=OPT_testing' }).Count)
Check 'the issue was told'    'True'  ([bool]((Calls) -match '(?s)issue comment 163 .*Landed on master:.*Not pushed yet \(#163\)'))
Check 'the board is not read whole' 0 (@(Get-Content $log | Where-Object { $_.Contains('items(first:100, after:') }).Count)
Check 'the cards of its repository are swept, in one query (status-sync)' 1 (@(Get-Content $log | Where-Object { $_.Contains('issues(states:OPEN') }).Count)

Write-Host 'a status-sync that fails is said, and finish-issue still completes'
New-Item -ItemType File -Path (Join-Path $fake 'issues-down') | Out-Null
Set-Content -Path $log -Value $null
Remove-Item -Recurse -Force $env:GH_CACHE_DIRECTORY -ErrorAction SilentlyContinue
$ok = Invoke-Finish -Number 163
Check 'it runs'               'True'  ([string]$ok)
Check 'it says so'            'True'  ([bool]($printed -cmatch '(?m)^status-sync did NOT run for example-org/example-repo: '))
Remove-Item -Path (Join-Path $fake 'issues-down')

Write-Host 'run inside the worktree it removes, it goes on from the main checkout and still moves the card'
Open-Tree 'issue-170-run-from-inside'
Land 'issue-170-run-from-inside' 'Run from inside (#170)'
Set-Content -Path $log -Value $null
$ok = Invoke-Finish -Number 170 -In (Join-Path $trees 'issue-170-run-from-inside')
Check 'it runs'               'True'  ([string]$ok)
Check 'the worktree is gone'  'False' (Has-Tree 'issue-170-run-from-inside')
Check 'the card moved to testing' 1   (@(Get-Content $log | Where-Object { $_ -match 'oid=OPT_testing' }).Count)

Write-Host "a package worktree, named for its first issue, stays when a later issue's branch in it is finished"
Open-Tree 'issue-177-package'
& git -C (Join-Path $trees 'issue-177-package') checkout -q -b issue-182-a-later-part origin/master 2>$null
Land 'issue-177-package' 'A later part (#182)'
Set-Content -Path $log -Value $null
$ok = Invoke-Finish -Number 182 -In (Join-Path $trees 'issue-177-package')
Check 'it runs'                    'True' ([string]$ok)
Check 'the package worktree stays' 'True' (Has-Tree 'issue-177-package')
Check 'and the branch in it'       'True' (Has-Branch 'issue-182-a-later-part')
Check 'it says why'                'True' ([bool]($printed -match 'issue-177-package is named for another issue and has issue-182-a-later-part checked out: it stays'))
Check 'the card of #182 moved'     1      (@(Get-Content $log | Where-Object { $_ -match 'oid=OPT_testing' }).Count)

Write-Host 'where the column after implementing is done, the card stays for the owner'
Set-Board @('todo', 'implementing', 'done')
Set-Content -Path $log -Value $null
$ok = Invoke-Finish -Number 163
Check 'it runs'               'True' ([string]$ok)
Check 'it says so'            'True' ([bool]($printed -match 'the column after implementing is done'))
Check 'the card did not move' 0      (Moves)

Write-Host 'a closed issue keeps its card'
Set-Content -Path $state -Value 'closed' -Encoding utf8NoBOM
Set-Content -Path $log -Value $null
$ok = Invoke-Finish -Number 163
Check 'it runs'               'True' ([string]$ok)
Check 'it says so'            'True' ([bool]($printed -match 'the issue is closed already'))
Check 'the card did not move' 0      (Moves)
Set-Content -Path $state -Value 'open' -Encoding utf8NoBOM

Write-Host '-Sweep removes a landed worktree that has rested for a day, and names every other'
Open-Tree 'issue-201-rested'
Land 'issue-201-rested' 'An old change (#201)' ([DateTime]::UtcNow.AddDays(-2).ToString('yyyy-MM-ddTHH:mm:ssZ'))
Open-Tree 'issue-202-fresh'
Land 'issue-202-fresh' 'A change of today (#202)'
Open-Tree 'issue-203-never-committed'
Open-Tree 'issue-204-open-work'
'unsaved' | Add-Content -Path (Join-Path $trees 'issue-204-open-work/README.md')
Set-Content -Path $log -Value $null
$ok = Invoke-Finish -Sweep -DryRun
Check 'dry run: it runs'               'True' ([string]$ok)
Check 'dry run: it would remove the rested one' 'True' ([bool]($printed -match 'issue-201-rested: landed, would be removed'))
Check 'dry run: nothing removed'       'True' (Has-Tree 'issue-201-rested')
$ok = Invoke-Finish -Sweep
Check 'it runs'                        'True'  ([string]$ok)
Check 'the rested one is gone'         'False' (Has-Tree 'issue-201-rested')
Check 'with its branch'                'False' (Has-Branch 'issue-201-rested')
Check 'the fresh one stays'            'True'  (Has-Tree 'issue-202-fresh')
Check 'and says why'                   'True'  ([bool]($printed -match 'issue-202-fresh: landed less than a day ago'))
Check 'the uncommitted one stays'      'True'  (Has-Tree 'issue-203-never-committed')
Check 'the one with changes stays'     'True'  (Has-Tree 'issue-204-open-work')
Check 'the sweep moves no card'        0       (Moves)
Check 'a package worktree holding a later issue stays' 'True' ([bool]($printed -match 'issue-177-package: named for another issue, holds issue-182-a-later-part, stays'))

Write-Host 'a repository on no board: the landed worktree goes, no card is looked for, and the issue is told'
Open-Tree 'issue-167-keep-the-harness-off-the-board'
Land 'issue-167-keep-the-harness-off-the-board' 'Keep the harness off the board (#167)'
New-Item -ItemType File -Path (Join-Path $fake 'no-board') | Out-Null
Set-Content -Path $log -Value $null
Remove-Item -Recurse -Force $env:GH_CACHE_DIRECTORY -ErrorAction SilentlyContinue
$env:GH_PROJECT_NUMBER = ''
$ok = Invoke-Finish -Number 167
Check 'it runs'                'True'  ([string]$ok)
Check 'the worktree is gone'   'False' (Has-Tree 'issue-167-keep-the-harness-off-the-board')
Check 'it says so'             'True'  ([bool]($printed -cmatch '(?m)^example-org/example-repo is on no board - there is no card to move\r?$'))
Check 'no card was moved'      0       (Moves)
Check 'and no card is swept'   0       (@(Get-Content $log | Where-Object { $_.Contains('issues(states:OPEN') }).Count)
Check 'the issue was told'     'True'  ([bool]((Calls) -match '(?s)issue comment 167 .*Landed on master:.*Keep the harness off the board \(#167\)'))
$env:GH_PROJECT_NUMBER = '999983'
Remove-Item -Path (Join-Path $fake 'no-board')

# The issue lives in other-org/tracker and its work landed here: start-issue recorded that on the
# branch, so the issue is read, its board asked and its comment posted there, never here.
Write-Host 'an issue of another repository: read, asked and told there, from the record on its branch'
Open-Tree 'issue-169-alert-on-a-stuck-run'
& git -C $work config branch.issue-169-alert-on-a-stuck-run.issueRepository other-org/tracker
Land 'issue-169-alert-on-a-stuck-run' 'Alert on a stuck run (other-org/tracker#169)'
New-Item -ItemType File -Path (Join-Path $fake 'no-board') | Out-Null
Set-Content -Path $log -Value $null
Remove-Item -Recurse -Force $env:GH_CACHE_DIRECTORY -ErrorAction SilentlyContinue
$env:GH_PROJECT_NUMBER = ''
$ok = Invoke-Finish -Number 169
Check 'it runs'                'True'  ([string]$ok)
Check 'the worktree is gone'   'False' (Has-Tree 'issue-169-alert-on-a-stuck-run')
Check 'the record went with the branch' '' "$(& git -C $work config --get branch.issue-169-alert-on-a-stuck-run.issueRepository)"
Check 'the issue was read there' 'True' ([bool]((Calls) -match 'other-org/tracker/issues/169'))
Check 'its board was asked'    'True'  ([bool]($printed -cmatch '(?m)^other-org/tracker is on no board - there is no card to move\r?$'))
Check 'the issue was told there' 'True' ([bool]((Calls) -match '(?s)issue comment 169 --repo other-org/tracker .*Landed on master of example-org/example-repo:.*\(other-org/tracker#169\)'))

Write-Host "this repository's own issue of the same number is not told of the other one's commit"
Open-Tree 'issue-169-own-fix'
Land 'issue-169-own-fix' 'Own fix (#169)'
Set-Content -Path $log -Value $null
Remove-Item -Recurse -Force $env:GH_CACHE_DIRECTORY -ErrorAction SilentlyContinue
$ok = Invoke-Finish -Number 169
Check 'it runs'                'True'  ([string]$ok)
Check 'its own commit is named' 'True' ([bool]((Calls) -match '(?s)issue comment 169 --repo example-org/example-repo .*Landed on master:.*Own fix \(#169\)'))
Check 'the other one is not'   'False' ([bool]((Calls) -match 'other-org/tracker#169'))

Write-Host 'a branch that outlived its worktree still says where its issue lives'
& git -C $work branch -q issue-175-gone origin/master
& git -C $work config branch.issue-175-gone.issueRepository other-org/tracker
Set-Content -Path $log -Value $null
Remove-Item -Recurse -Force $env:GH_CACHE_DIRECTORY -ErrorAction SilentlyContinue
$ok = Invoke-Finish -Number 175
Check 'the issue was read there' 'True' ([bool]((Calls) -match 'other-org/tracker/issues/175'))
Check 'and never here'         'False' ([bool]((Calls) -match 'example-org/example-repo/issues/175'))
Check 'no commit names it, so it is refused under its own name' `
  'error: no commit on origin/master names other-org/tracker#175: nothing of it has landed, so the card stays and the issue is not told; a commit that touches an issue names it' $said
& git -C $work branch -q -D issue-175-gone
$env:GH_PROJECT_NUMBER = '999983'
Remove-Item -Path (Join-Path $fake 'no-board')

Write-Host 'an issue no commit on the default branch names has not landed: refused, no card moves, no word on the issue'
Set-Content -Path $log -Value $null
Remove-Item -Recurse -Force $env:GH_CACHE_DIRECTORY -ErrorAction SilentlyContinue
$ok = Invoke-Finish -Number 177
Check 'it is refused'          'False' ([string]$ok)
Check 'it says why'            'error: no commit on origin/master names #177: nothing of it has landed, so the card stays and the issue is not told; a commit that touches an issue names it' $said
Check 'no card moved'          0       (Moves)
Check 'the issue was not told' 'False' ([bool]((Calls) -match 'issue comment 177'))
Check 'no card is swept'       0       (@(Get-Content $log | Where-Object { $_.Contains('issues(states:OPEN') }).Count)

Write-Host 'an origin/HEAD naming a branch the remote no longer has: the default branch is asked of the remote'
Open-Tree 'issue-168-read-the-default-branch'
Land 'issue-168-read-the-default-branch' 'Read the default branch from the remote (#168)'
& git -C $work symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/gone
$ok = Invoke-Finish -Number 168
Check 'it runs'                'True'  ([string]$ok)
Check 'the worktree is gone'   'False' (Has-Tree 'issue-168-read-the-default-branch')
& git -C $work remote set-head origin -a | Out-Null

Write-Host 'a branch that landed by cherry-pick goes without a flag'
Open-Tree 'issue-173-landed-by-cherry-pick'
'picked' | Add-Content -Path (Join-Path $trees 'issue-173-landed-by-cherry-pick/README.md')
& git -C (Join-Path $trees 'issue-173-landed-by-cherry-pick') commit -q -am 'Land by cherry-pick (#173)'
& git -C $work pull -q --ff-only origin master 2>$null
& git -C $work cherry-pick "$(& git -C (Join-Path $trees 'issue-173-landed-by-cherry-pick') rev-parse HEAD)" | Out-Null
& git -C $work push -q origin master 2>$null
$ok = Invoke-Finish -Number 173
Check 'it runs'                'True'  ([string]$ok)
Check 'the worktree is gone'   'False' (Has-Tree 'issue-173-landed-by-cherry-pick')

Write-Host 'a branch whose change landed in another shape stays, and names --landed'
Open-Tree 'issue-174-landed-changed'
'mine' | Add-Content -Path (Join-Path $trees 'issue-174-landed-changed/README.md')
& git -C (Join-Path $trees 'issue-174-landed-changed') commit -q -am 'Land in another shape (#174)'
'mine, as the conflict was resolved' | Add-Content -Path (Join-Path $work 'README.md')
& git -C $work commit -q -am 'Land in another shape, resolved (#174)'
& git -C $work push -q origin master 2>$null
$ok = Invoke-Finish -Number 174
Check 'it throws'              'False' ([string]$ok)
Check 'it names --landed'      'True'  ([bool]($said -match 'run finish-issue 174 --landed once the issue is closed'))
Check 'the worktree stays'     'True'  (Has-Tree 'issue-174-landed-changed')
Write-Host '--landed on an open issue is refused'
$ok = Invoke-Finish -Number 174 -Landed
Check 'it throws'              'False' ([string]$ok)
Check 'it says the issue is open' 'True' ([bool]($said -match '--landed removes the work of a closed issue only, and #174 is open'))
Check 'the worktree stays'     'True'  (Has-Tree 'issue-174-landed-changed')
Write-Host '--landed on a closed issue removes the worktree and names the commit it did not find'
Set-Content -Path $state -Value 'closed' -Encoding utf8NoBOM
$ok = Invoke-Finish -Number 174 -Landed
Check 'it runs'                'True'  ([string]$ok)
Check 'the worktree is gone'   'False' (Has-Tree 'issue-174-landed-changed')
Check 'it names the commit'    'True'  ([bool]($printed -cmatch '(?m)^  [0-9a-f]+ Land in another shape \(#174\)\r?$'))
Set-Content -Path $state -Value 'open' -Encoding utf8NoBOM

foreach ($w in @('issue-202-fresh', 'issue-203-never-committed', 'issue-204-open-work')) { & git -C $work worktree remove --force (Join-Path $trees $w) 2>$null | Out-Null }
Remove-Item -Recurse -Force $fake -ErrorAction SilentlyContinue
$env:GH_PROJECT_NUMBER = $null
if ($failed -gt 0) { Write-Host "`n$failed failed"; exit 1 }
Write-Host "`nall passed"
