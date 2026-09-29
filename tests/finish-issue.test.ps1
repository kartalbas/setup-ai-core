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
if (`$a -match 'comments')            { '[]'; exit 0 }
if (`$a -match '--jq .node_id')       { 'I_node163'; exit 0 }
if (`$a -match 'projectV2\(number:')  { 'PVT_kwfinish'; exit 0 }
if (`$a -match 'fields\(first:50\)')  { Get-Content -Path '$board'; exit 0 }
if (`$a -match 'addProjectV2ItemById') { 'PVTI_item163'; exit 0 }
if (`$a -match 'projectItems')        { exit 0 }
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
  param([string]$Number = '', [switch]$Sweep, [switch]$DryRun)
  Push-Location $work
  try {
    $script:said = ''
    $script:printed = ''
    try { $script:printed = (@(& $finish -Number $Number -Sweep:$Sweep -DryRun:$DryRun 2>&1 | ForEach-Object { "$_" }) -join "`n") }
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
Check 'it names the commit' 'True'  ([bool]($said -match 'has 1 commit\(s\) origin/master does not have'))
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

foreach ($w in @('issue-202-fresh', 'issue-203-never-committed', 'issue-204-open-work')) { & git -C $work worktree remove --force (Join-Path $trees $w) 2>$null | Out-Null }
Remove-Item -Recurse -Force $fake -ErrorAction SilentlyContinue
$env:GH_PROJECT_NUMBER = $null
if ($failed -gt 0) { Write-Host "`n$failed failed"; exit 1 }
Write-Host "`nall passed"
