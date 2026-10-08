# The PowerShell twin of integrate-issue.test.sh, asserting the SAME refusals, merge commit and
# worktree states.
#
# It runs inside a temporary repository with a temporary origin, both built and deleted here, and
# with a FAKE gh on PATH: nothing leaves the machine.
#
#   pwsh -File tests/integrate-issue.test.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fake = Join-Path ([IO.Path]::GetTempPath()) "integrate-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$env:GH_CACHE_DIRECTORY = Join-Path $fake 'cache'
New-Item -ItemType Directory -Path $fake | Out-Null
$title = Join-Path $fake 'title.txt'

@"
`$a = `$args -join ' '
if (`$a -match 'repo view') { 'example-org/example-repo'; exit 0 }
if (`$a -match 'comments')  { '[]'; exit 0 }
if (`$a -match 'issues/') {
  '{"number":77,"title":"' + (Get-Content -Path '$title' -Raw).Trim() + '","state":"open","labels":[],"assignees":[],"body":"b"}'
  exit 0
}
'{}'
exit 0
"@ | Set-Content -Path (Join-Path $fake 'gh.ps1') -Encoding utf8NoBOM
"@echo off`r`npwsh -NoProfile -File `"$fake\gh.ps1`" %*" |
  Set-Content -Path (Join-Path $fake 'gh.cmd') -Encoding ascii
if (-not $IsWindows) { Set-Content -Path (Join-Path $fake 'gh') -Value "#!/bin/sh`nexec pwsh -NoProfile -File `"$fake/gh.ps1`" `"`$@`"" -Encoding ascii; & chmod +x (Join-Path $fake 'gh') }
$env:PATH = "$fake$([IO.Path]::PathSeparator)$env:PATH"
Set-Content -Path $title -Value 'Read the board whole' -Encoding utf8NoBOM

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
$work = Join-Path $fake 'checkouts/example-repo'
$trees = Join-Path $fake 'checkouts/.worktrees/example-repo'
New-Item -ItemType Directory -Force -Path $trees | Out-Null
& git -c init.defaultBranch=master init -q --bare $origin
& git -c init.defaultBranch=master init -q $work
Dress $work
'one' | Set-Content -Path (Join-Path $work 'README.md') -Encoding utf8NoBOM
& git -C $work add -A; & git -C $work commit -q -m 'Start #1'
& git -C $work remote add origin $origin
& git -C $work push -q origin master 2>$null
& git -C $work remote set-head origin -a | Out-Null

# The worktree of an issue, as start-issue cuts it, with one commit in it
function New-Tree([string]$Number, [string]$Slug) {
  $tree = Join-Path $trees "issue-$Number-$Slug"
  & git -C $work worktree add -q -b "issue-$Number-$Slug" $tree origin/master 2>$null
  Dress $tree
  $Slug | Set-Content -Path (Join-Path $tree "$Slug.txt") -Encoding utf8NoBOM
  & git -C $tree add -A; & git -C $tree commit -q -m "Write $Slug #$Number"
  return $tree
}
$integrate = Join-Path $root 'bin/integrate-issue.ps1'
function Invoke-Integrate([string]$In, [string[]]$Arguments) {
  Push-Location $In
  try {
    $script:out = (@(& pwsh -NoProfile -File $integrate @Arguments 2>&1 | ForEach-Object { "$_" }) -join "`n")
    $script:rc = $LASTEXITCODE
  } finally { Pop-Location }
}
function Tip { "$(& git --git-dir=$origin rev-parse master)" }
function Says([string]$Text) { [string]$script:out.Contains($Text) }
function On-Branch([string]$Tree) { "$(& git -C $Tree symbolic-ref --short HEAD)" }

$wt = New-Tree '77' 'board'
$before = Tip

Write-Host 'no reviewer, no issue branch, or a tree with changes is refused before anything moves'
Invoke-Integrate $wt @('77')
Check 'without -ReviewedBy: exit 1'    1 $rc
Check 'it asks who reviewed'           'True' (Says 'who reviewed the work?')
Invoke-Integrate $work @('77', '-ReviewedBy', 'l4')
Check 'outside the issue branch: exit 1' 1 $rc
'loose' | Set-Content -Path (Join-Path $wt 'loose.txt') -Encoding utf8NoBOM
Invoke-Integrate $wt @('77', '-ReviewedBy', 'l4')
Check 'a tree with changes: exit 1'    1 $rc
Remove-Item -LiteralPath (Join-Path $wt 'loose.txt')
Check 'origin did not move'            $before (Tip)

Write-Host 'a clean run leaves one merge commit with the title and the trailer, and the branch checked out'
Invoke-Integrate $wt @('77', '-ReviewedBy', 'l4')
Check 'exit 0'                         0 $rc
Check 'the first parent is the old tip' $before "$(& git --git-dir=$origin rev-parse 'master^1')"
Check 'the second parent is the branch' "$(& git -C $wt rev-parse HEAD)" "$(& git --git-dir=$origin rev-parse 'master^2')"
Check 'the subject is the title and the issue' 'Read the board whole (#77)' "$(& git --git-dir=$origin log -1 --format=%s master)"
Check 'it carries the trailer'         'l4' "$((& git --git-dir=$origin log -1 '--format=%(trailers:key=Reviewed-by,valueonly)' master) -join '')"
Check 'the worktree is on its branch again' 'issue-77-board' (On-Branch $wt)

Write-Host 'a branch already integrated has nothing to integrate'
$after = Tip
Invoke-Integrate $wt @('77', '-ReviewedBy', 'l4')
Check 'exit 1'                         1 $rc
Check 'it says so'                     'True' (Says 'nothing to integrate')
Check 'origin did not move'            $after (Tip)

Write-Host 'a title too long for a subject gives way to the branch'
Set-Content -Path $title -Value 'Read every column of the board whole and in its own order, or a card is lost' -Encoding utf8NoBOM
$wt2 = New-Tree '78' 'columns'
Invoke-Integrate $wt2 @('78', '-ReviewedBy', 'l4')
Check 'exit 0'                         0 $rc
Check 'the subject names the branch'   'Merge issue-78-columns (#78)' "$(& git --git-dir=$origin log -1 --format=%s master)"
Set-Content -Path $title -Value 'Read the board whole' -Encoding utf8NoBOM

Write-Host 'a conflict leaves origin as it was and the worktree on its branch'
$wt3 = New-Tree '79' 'clash'
& git -C $work pull -q origin master 2>$null
'theirs' | Set-Content -Path (Join-Path $work 'clash.txt') -Encoding utf8NoBOM
& git -C $work add -A; & git -C $work commit -q -m 'Write clash first #9'; & git -C $work push -q origin master 2>$null
$after = Tip
Invoke-Integrate $wt3 @('79', '-ReviewedBy', 'l4')
Check 'exit 1'                         1 $rc
Check 'it names the conflict'          'True' (Says 'does not merge cleanly')
Check 'origin did not move'            $after (Tip)
Check 'the worktree is on its branch'  'issue-79-clash' (On-Branch $wt3)
Check 'and no merge is left open'      '' "$(& git -C $wt3 status --porcelain)"

Write-Host 'a push the hook refuses reaches nothing, and the branch is checked out again'
$wt4 = New-Tree '80' 'refused'
$hooks = Join-Path $fake 'hooks'
New-Item -ItemType Directory -Force -Path $hooks | Out-Null
Set-Content -Path (Join-Path $hooks 'pre-push') -Value "#!/bin/sh`necho 'pre-push: REFUSED - planted'`nexit 1" -Encoding ascii
if (-not $IsWindows) { & chmod +x (Join-Path $hooks 'pre-push') }
& git -C $work config core.hooksPath $hooks
$after = Tip
Invoke-Integrate $wt4 @('80', '-ReviewedBy', 'l4')
Check 'exit 1'                         1 $rc
Check 'it says nothing reached origin' 'True' (Says 'nothing reached origin')
Check 'origin did not move'            $after (Tip)
Check 'the worktree is on its branch'  'issue-80-refused' (On-Branch $wt4)

Remove-Item -Recurse -Force $fake -ErrorAction SilentlyContinue
if ($failed -gt 0) { Write-Host "`n$failed failed"; exit 1 }
Write-Host "`nall passed"
