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
if (`$a -match 'comments')            { '[]'; exit 0 }
if (`$a -match '--jq .node_id')       { 'I_node163'; exit 0 }
if (`$a -match 'projectV2\(number:')  { 'PVT_kwstart'; exit 0 }
if (`$a -match 'fields\(first:50\)')  { 'Status' + [char]9 + 'FID' + [char]9 + 'todo' + [char]9 + 'OPT_todo'; 'Status' + [char]9 + 'FID' + [char]9 + 'implementing' + [char]9 + 'OPT_impl'; exit 0 }
if (`$a -match 'addProjectV2ItemById') { 'PVTI_item163'; exit 0 }
if (`$a -match 'projectItems')        { exit 0 }
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
$env:PATH = "$fake;$env:PATH"
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
# The main checkout carries the harness data a worktree inherits; Graft stays off, nothing reaches the network
New-Item -ItemType Directory -Force -Path (Join-Path $work '.ai-core') | Out-Null
[IO.File]::WriteAllText((Join-Path $work '.ai-core/config.env'), ('GRAFT_EXECUTION_MODE="skip"' + "`n"))
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

Set-Location $root
& git -C $work worktree remove --force $tree 2>$null | Out-Null
Remove-Item -Recurse -Force $fake -ErrorAction SilentlyContinue
$env:GH_PROJECT_NUMBER = $null
if ($failed -gt 0) { Write-Host "`n$failed failed"; exit 1 }
Write-Host "`nall passed"
