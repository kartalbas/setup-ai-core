# The PowerShell twin of status-sync.test.sh, asserting the SAME state machine against the SAME
# inputs. Two implementations of one rule are two chances to drift; this is what makes the drift
# fail rather than surprise somebody months later.
#
# The sweep itself is not driven here - the decision is, because that is where the rules live.
# The script stops before the sweep when it is DOT-SOURCED, so Get-DeriveTarget can be called
# directly and no board is reached at all.
#
#   pwsh -File test/status-sync.test.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$failed = 0
function Check($name, $expected, $actual) {
  if ("$expected" -eq "$actual") { Write-Host "  ok   $name" }
  else { Write-Host "  FAIL $name`n       expected: [$expected]`n       actual:   [$actual]"; $script:failed++ }
}

. (Join-Path $root 'bin/status-sync.ps1')

Write-Host 'a commit on master alone moves nothing: it touches the issue, it does not finish it'
Check 'from todo'         '' (Get-DeriveTarget -Current 'todo' -OnMaster 1 -Released 0 -IsEpic 0)
Check 'from backlog'      '' (Get-DeriveTarget -Current 'backlog' -OnMaster 1 -Released 0 -IsEpic 0)
Check 'from implementing' '' (Get-DeriveTarget -Current 'implementing' -OnMaster 1 -Released 0 -IsEpic 0)

Write-Host 'a released and proven commit closes only a card finish-issue moved to testing'
Check 'from testing'      'CLOSE' (Get-DeriveTarget -Current 'testing' -OnMaster 1 -Released 1 -IsEpic 0 -Proven 1)
Check 'the board spells it Testing' 'CLOSE' (Get-DeriveTarget -Current 'Testing' -OnMaster 1 -Released 1 -IsEpic 0 -Proven 1)
Check 'not from todo'     '' (Get-DeriveTarget -Current 'todo' -OnMaster 1 -Released 1 -IsEpic 0 -Proven 1)
Check 'not from implementing, whose work may land in more steps' '' (Get-DeriveTarget -Current 'implementing' -OnMaster 1 -Released 1 -IsEpic 0 -Proven 1)

Write-Host 'a release is not a proof'
Check 'released, no proof record'  '' (Get-DeriveTarget -Current 'testing' -OnMaster 1 -Released 1 -IsEpic 0 -Proven 0)
Check 'proven, not released'       '' (Get-DeriveTarget -Current 'testing' -OnMaster 1 -Released 0 -IsEpic 0 -Proven 1)

Write-Host 'it never moves a card backward'
Check 'testing stays testing' '' (Get-DeriveTarget -Current 'testing' -OnMaster 1 -Released 0 -IsEpic 0)
Check 'done stays done'       '' (Get-DeriveTarget -Current 'done' -OnMaster 1 -Released 1 -IsEpic 0 -Proven 1)

# The card is put in implementing by start-issue, at the moment the worktree is opened. That
# column is a person's statement, so the sweep never writes it and never reads a worktree.
Write-Host 'an open worktree is not a signal, so nothing moves without a commit on master'
Check 'nothing at all'           '' (Get-DeriveTarget -Current 'todo' -OnMaster 0 -Released 0 -IsEpic 0)
Check 'a tag without the commit' '' (Get-DeriveTarget -Current 'todo' -OnMaster 0 -Released 1 -IsEpic 0)
Check 'implementing stays where a person put it' '' (Get-DeriveTarget -Current 'implementing' -OnMaster 0 -Released 0 -IsEpic 0)

Write-Host 'no commit moves an epic, whatever the signal: an epic follows its sub-issues'
Check 'epic with a released commit'  '' (Get-DeriveTarget -Current 'todo' -OnMaster 1 -Released 1 -IsEpic 1 -Proven 1)
Check 'epic with a commit on master' '' (Get-DeriveTarget -Current 'todo' -OnMaster 1 -Released 0 -IsEpic 1)

Write-Host 'the ranks are what forbid a backward move'
Check 'backlog'       0 (Get-StatusRank 'backlog')
Check 'todo'          0 (Get-StatusRank 'todo')
Check 'implementing'  1 (Get-StatusRank 'implementing')
Check 'testing'       2 (Get-StatusRank 'testing')
Check 'done'          3 (Get-StatusRank 'done')
Check 'CLOSE is done' 3 (Get-StatusRank 'CLOSE')

# --- the signal path, driven end to end against a stand-in gh and a real clone ----
#
# The same cases as status-sync.test.sh, against the same clone of the same commits and tags:
#   abc13 deploy/prod/1 (LIVE_TAGS' first environment) ... abc18 deploy/prod/2 and 0.1-newest,
#         the newest tag by date and the last of all by name
#   abc19 deploy/test/9, the newest by date but for 0.1-newest
#   abc20 on master, in no tag
# and the same cards: #12 implementing on master, #13 released and proven, #14 an epic with one
# sub-issue, #15 of another organisation, #16 reopened after its landing, #17 moved by hand, #18
# released without a proof record and proven by a stranger, #19 on test only, #20 in no tag and
# on the second page with a newer prod tag in the clone that origin never had, #22 landed in
# example-org/tools, which has no clone here.

$fake = Join-Path ([IO.Path]::GetTempPath()) "status-sync-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$env:GH_CACHE_DIRECTORY = Join-Path $fake 'cache'
$ghDir = Join-Path $fake 'gh'
New-Item -ItemType Directory -Path $ghDir -Force | Out-Null
$calls = Join-Path $fake 'calls.txt'
$projectNumber = 999995
$projectId = 'PVT_kwstatussync'
$cache = Join-Path $env:GH_CACHE_DIRECTORY "$projectNumber"
New-Item -ItemType Directory -Path $cache -Force | Out-Null
Set-Content -Path (Join-Path $cache 'project-id') -Value $projectId -NoNewline
Set-Content -Encoding utf8NoBOM -Path (Join-Path $fake 'empty.json') -Value '{}'
Set-Content -Encoding utf8NoBOM -Path (Join-Path $fake 'project-id.json') -Value ('{"data":{"organization":{"projectV2":{"id":"' + $projectId + '"}}}}')

# The clone and its origin. Commit and tag dates are set, so "newest by date" is not left to the
# speed of the machine.
function Git-At([string]$Dir, [long]$At, [string[]]$GitArgs) {  # git in Dir with its dates set to At
  $env:GIT_AUTHOR_DATE = "@$At +0000"; $env:GIT_COMMITTER_DATE = $env:GIT_AUTHOR_DATE
  try { & git -C $Dir -c user.name=check -c user.email=check@localhost @GitArgs } finally { Remove-Item Env:GIT_AUTHOR_DATE, Env:GIT_COMMITTER_DATE }
}
function CommitAt([string]$Dir, [long]$At, [string]$Subject) {
  Set-Content -LiteralPath (Join-Path $Dir "$At.txt") -Value $Subject
  & git -C $Dir add -A
  Git-At $Dir $At @('commit', '-q', '-m', $Subject)
  "$(& git -C $Dir rev-parse HEAD)".Trim()
}
function TagAt([string]$Dir, [string]$Tag, [long]$At) { Git-At $Dir $At @('tag', '-a', '-m', $Tag, $Tag) }
$origin = Join-Path $fake 'remote/example-org/example-repo.git'; $seed = Join-Path $fake 'seed'; $clone = Join-Path $fake 'folder/example-repo'
& git init -q --bare $origin; & git init -q $seed; & git -C $seed checkout -q -b master
$c12 = CommitAt $seed 1700000012 'Work of #12'
$c13 = CommitAt $seed 1700000013 'Land #13'; TagAt $seed 'deploy/prod/1' 1700000013
$c16 = CommitAt $seed 1700000016 'Land #16'
$c18 = CommitAt $seed 1700000018 'Land #18'; TagAt $seed 'deploy/prod/2' 1700000018; TagAt $seed '0.1-newest' 1700000099
$c19 = CommitAt $seed 1700000019 'Land #19'; TagAt $seed 'deploy/test/9' 1700000019
$c20 = CommitAt $seed 1700000020 'Land #20'
& git -C $seed push -q $origin master --tags
& git -C $origin symbolic-ref HEAD refs/heads/master
New-Item -ItemType Directory -Path (Join-Path $fake 'folder') -Force | Out-Null
& git clone -q $origin $clone
# The tags reach the clone through the fetch status-sync makes, not through the clone
foreach ($t in @(& git -C $clone tag -l)) { & git -C $clone tag -d $t | Out-Null }
# A release run whose push was refused left this tag in the clone alone, newer than every other
Git-At $clone 1700000300 @('tag', '-a', '-m', 'never pushed', 'deploy/prod/3', $c20)
$liveTags = 'LIVE_TAGS="prod=deploy/prod/* test=deploy/test/*"'
New-Item -ItemType Directory -Path (Join-Path $clone '.ai-core') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $clone '.ai-core/config.env') -Value $liveTags

function Card($number, $title, $status, $owner = 'example-org') {
  '{"fieldValues":{"nodes":[{"name":"' + $status + '","field":{"name":"Status"}}]},"content":{"number":' +
  $number + ',"title":"' + $title + '","state":"OPEN","repository":{"name":"example-repo","nameWithOwner":"' + $owner + '/example-repo"}}}'
}
Set-Content -Encoding utf8NoBOM -Path (Join-Path $fake 'board.json') -Value (
  '{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[' +
  ((Card 12 'A commit of its own is on master' 'implementing'),
   (Card 15 'An issue of another organisation on this board' 'todo' 'other-org') -join ',') + ']}}}}')

# An open issue as the query of one repository reads it: its card on this board, and the cards of
# board 5 and of a board numbered like this one under another owner, which are not this board's
# Every comment is written by a member, but for the one stranger's
function Landed($at, $sha, $repo = '') {
  $of = if ($repo) { " of $repo" } else { '' }
  '{"createdAt":"' + $at + '","authorAssociation":"MEMBER","body":"Landed on master' + $of + ':\n\n- ' + $sha.Substring(0, 7) + ' Its subject\n- 1111111 an older commit"}'
}
function Proven($at, $association = 'MEMBER') { '{"createdAt":"' + $at + '","authorAssociation":"' + $association + '","body":"Proven on prod:\n\n- TC-1 PASS"}' }
function Issue($number, $status, $subs, $comments, $reopenedAt = '') {
  $reopened = if ($reopenedAt) { '{"createdAt":"' + $reopenedAt + '"}' } else { '' }
  '{"number":' + $number + ',"subIssuesSummary":{"total":' + $subs + '},"projectItems":{"nodes":[' +
  '{"project":{"number":5,"owner":{"login":"example-org"}},"status":{"name":"done"}},' +
  '{"project":{"number":' + $projectNumber + ',"owner":{"login":"other-org"}},"status":{"name":"done"}},' +
  '{"project":{"number":' + $projectNumber + ',"owner":{"login":"example-org"}},"status":{"name":"' + $status + '"}}]},' +
  '"reopened":{"nodes":[' + $reopened + ']},"comments":{"nodes":[' + $comments + ']}}'
}
function Page($hasNext, $cursor, $nodes) { '{"data":{"repository":{"issues":{"pageInfo":{"hasNextPage":' + $hasNext + ',"endCursor":' + $cursor + '},"nodes":[' + ($nodes -join ',') + ']}}}}' }
Set-Content -Encoding utf8NoBOM -Path (Join-Path $fake 'issues-1.json') -Value (Page 'true' '"c1"' @(
  (Issue 12 'implementing' 0 (Landed '2026-09-01T10:00:00Z' $c12)),
  (Issue 13 'testing' 0 (((Landed '2026-08-01T10:00:00Z' '0000000'), (Landed '2026-09-01T10:00:00Z' $c13), (Proven '2026-09-02T10:00:00Z'), '{"createdAt":"2026-09-03T10:00:00Z","authorAssociation":"MEMBER","body":"Looks good, see 2222222"}') -join ',')),
  (Issue 14 'todo' 1 ''),
  (Issue 16 'testing' 0 (((Landed '2026-09-01T10:00:00Z' $c16), (Proven '2026-09-02T10:00:00Z')) -join ',') '2026-09-05T10:00:00Z'),
  (Issue 17 'testing' 0 '{"createdAt":"2026-09-01T10:00:00Z","authorAssociation":"MEMBER","body":"Done in\n- abc1717 by hand"}')))
Set-Content -Encoding utf8NoBOM -Path (Join-Path $fake 'issues-2.json') -Value (Page 'false' 'null' @(
  (Issue 18 'testing' 0 (((Proven '2026-08-30T10:00:00Z'), (Landed '2026-09-01T10:00:00Z' $c18), (Proven '2026-09-02T10:00:00Z' 'NONE')) -join ',')),
  (Issue 22 'testing' 0 (((Landed '2026-09-01T10:00:00Z' $c13 'example-org/tools'), (Proven '2026-09-02T10:00:00Z')) -join ',')),
  (Issue 19 'testing' 0 (((Landed '2026-09-01T10:00:00Z' $c19), (Proven '2026-09-02T10:00:00Z')) -join ',')),
  (Issue 20 'testing' 0 (((Landed '2026-09-01T10:00:00Z' $c20), (Proven '2026-09-02T10:00:00Z')) -join ',')),
  (Issue 21 '' 0 '')))
Set-Content -Encoding utf8NoBOM -Path (Join-Path $fake 'issues-other.json') -Value (Page 'false' 'null' @((Issue 15 'todo' 0 '')))
# #14's one sub-issue was moved to testing by hand on the board; the epic itself stands in todo
Set-Content -Encoding utf8NoBOM -Path (Join-Path $fake 'epic-14.json') -Value '{"data":{"repository":{"issue":{"state":"OPEN","projectItems":{"nodes":[{"project":{"number":999995,"owner":{"login":"example-org"}},"status":{"name":"todo"}}]},"subIssues":{"nodes":[{"state":"OPEN","projectItems":{"nodes":[{"project":{"number":999995,"owner":{"login":"example-org"}},"status":{"name":"testing"}}]}}]}}}}}'

# The stand-in RUNS the --jq program the caller gave, the way gh does. Answering the raw
# document instead would let a script that never reads its answer pass.
@"
`$ErrorActionPreference = 'Stop'
`$line = `$args -join ' '
Add-Content -LiteralPath '$calls' -Value `$line
if     (`$line -like '*subIssues(first*')                    { `$doc = 'epic-14.json' }
elseif (`$line -like '*projectV2(number:*')                  { `$doc = 'project-id.json' }
elseif (`$line -like '*items(first:100, after:*')            { `$doc = 'board.json' }
elseif (`$line -like '*o=other-org*issues(states:OPEN*')     { `$doc = 'issues-other.json' }
elseif (`$line -like '*after=c1*issues(states:OPEN*')        { `$doc = 'issues-2.json' }
elseif (`$line -like '*issues(states:OPEN*')                 { `$doc = 'issues-1.json' }
elseif (`$line -like '*--method PATCH*')                     { `$doc = 'empty.json' }
elseif (Test-Path -LiteralPath (Join-Path '$fake' 'lenient')) { exit 0 }
else { [Console]::Error.WriteLine("the stand-in gh has no answer for: `$line"); exit 9 }
`$prog = ''
for (`$i = 0; `$i -lt `$args.Count - 1; `$i++) { if (`$args[`$i] -eq '--jq') { `$prog = `$args[`$i + 1] } }
`$answer = Get-Content -Raw (Join-Path '$fake' `$doc)
if (`$prog) { `$answer | & jq -r `$prog } else { `$answer }
exit 0
"@ | Set-Content -Path (Join-Path $ghDir 'gh.ps1') -Encoding utf8NoBOM
$env:PATH = "$ghDir$([IO.Path]::PathSeparator)$env:PATH"

function CallCount($text) { @(@(Get-Content -LiteralPath $calls -EA SilentlyContinue) | Where-Object { $_.Contains($text) }).Count }
# The repositories go by position, as the bash twin takes them
function Sync([string]$Dir, [string[]]$Repo = @(), [switch]$Apply, [switch]$BoardFromEnvironment) {
  Set-Content -LiteralPath $calls -Value $null
  Push-Location -LiteralPath $Dir
  try {
    $a = @('-NoProfile', '-File', (Join-Path $root 'bin/status-sync.ps1')) + $Repo
    if ($BoardFromEnvironment) { $env:GH_PROJECT_NUMBER = "$projectNumber" } else { $a += @('-Project', $projectNumber) }
    if (-not $Apply) { $a += '-DryRun' }
    $script:run = @(& pwsh @a 2>&1 | ForEach-Object { "$_" }); $script:rc = $LASTEXITCODE
  } finally { Pop-Location; Remove-Item Env:GH_PROJECT_NUMBER -ErrorAction SilentlyContinue }
}
function Lines($pattern) { (@($script:run | Where-Object { $_ -like $pattern }) -join "`n") }

try {
  Write-Host 'one repository named: its issues in one query, its release from the clone'
  Sync $clone 'example-org/example-repo'
  Check 'exit 0' 0 $rc
  Check 'released on the first environment and proven: would close' `
    'would close  example-repo#13  (testing -> done, released in deploy/prod/2 and proven)' (Lines 'would close*')
  Check 'released without a proof record after its landing: due, and it stays' `
    'proof due    example-repo#18  (released in deploy/prod/2, no "Proven on" record after its landing)' (Lines 'proof due*')
  Check 'an epic with one sub-issue is named' `
    'one child    example-repo#14  (its state follows its one sub-issue; work of its own belongs in a sub-issue of its own, or it is closed with that sub-issue)' (Lines 'one child*')
  Check 'and follows its sub-issue moved by hand' 'would move   example-repo#14  (todo -> testing)' (Lines 'would move   example-repo#14*')
  Check 'nothing else moves: not on master alone, not reopened, not by hand, not on test only, not untagged' `
    '' "$(@($run | Where-Object { $_ -cmatch 'example-repo#(12|16|17|19|20|22)' -and $_ -cnotlike 'proof due*' }))"
  Check 'a landing in another repository is read there, and that one has no clone here' `
    "no clone of example-org/tools in $(Join-Path $fake 'folder'), so no release of it is read and its cards in testing stay" (Lines 'no clone*')
  Check 'and the count says what it read, both pages' "9 active cards scanned, 2 would move on board $projectNumber." $run[-1]
  Check 'the board is not read' 0 (CallCount 'items(first:100')
  Check 'the issues are read once per page' 2 (CallCount 'issues(states:OPEN')
  Check 'nothing asks GitHub for a tag or a compare' 0 @(@(Get-Content -LiteralPath $calls) | Where-Object { $_ -cmatch '/tags|/compare/' }).Count
  & git -C $clone rev-parse -q --verify refs/tags/deploy/prod/2 *>$null
  Check 'the fetch brought the tags' 'yes' $(if ($LASTEXITCODE -eq 0) { 'yes' } else { 'no' })
  & git -C $clone rev-parse -q --verify refs/tags/deploy/prod/3 *>$null
  Check 'and kept the one origin never had, which no fetch prunes' 'yes' $(if ($LASTEXITCODE -eq 0) { 'yes' } else { 'no' })

  Write-Host 'the repositories alone, the board from GH_PROJECT_NUMBER: by position they are no board'
  Sync $clone @('example-org/example-repo', 'other-org/example-repo') -BoardFromEnvironment
  Check 'exit 0' 0 $rc
  Check 'both are read' "10 active cards scanned, 2 would move on board $projectNumber." $run[-1]

  Write-Host 'without LIVE_TAGS the newest tag by date decides, whatever its name'
  Set-Content -LiteralPath (Join-Path $clone '.ai-core/config.env') -Value ''
  Sync $clone 'example-org/example-repo'
  Check 'the newest tag is 0.1-newest, which carries #13 and not #19' `
    'would close  example-repo#13  (testing -> done, released in 0.1-newest and proven)' (Lines 'would close*')
  Set-Content -LiteralPath (Join-Path $clone '.ai-core/config.env') -Value $liveTags

  Write-Host 'no repository named: the board is read to learn its repositories, each read under its owner'
  Sync $clone
  Check 'exit 0' 0 $rc
  Check 'the board is read once' 1 (CallCount 'items(first:100, after:')
  Check 'a repository of another organisation is read under its owner' 1 (CallCount 'graphql -f o=other-org -f n=example-repo')
  Check 'its card is counted' "10 active cards scanned, 2 would move on board $projectNumber." $run[-1]

  Write-Host 'a repository with no clone here: said, and its cards in testing stay'
  Sync $fake 'example-org/example-repo'
  Check 'it says so' "no clone of example-org/example-repo in $fake, so no release of it is read and its cards in testing stay" (Lines 'no clone of example-org/example-repo *')
  Check 'nothing closes' '' (Lines 'would close*')
  Sync (Join-Path $fake 'folder') 'example-org/example-repo'
  Check 'from the project folder, the clone in it is found, and LIVE_TAGS read from the clone' 'would close  example-repo#13  (testing -> done, released in deploy/prod/2 and proven)' (Lines 'would close*')

  Write-Host 'without -DryRun: the closing card is closed through issue-close, and nothing else is'
  # issue-close asks more than the close, where the issue stands on boards and under an epic, and
  # the stand-in answers every such question with nothing
  New-Item -ItemType File -Path (Join-Path $fake 'lenient') -Force | Out-Null
  Sync $clone 'example-org/example-repo' -Apply
  Check 'exit 0' 0 $rc
  Check 'it says so' 'close        example-repo#13  (testing -> done, released in deploy/prod/2 and proven)' (Lines 'close *')
  Check '#13 is closed' 1 (CallCount 'api --method PATCH repos/example-org/example-repo/issues/13 ')
  Check 'and no other issue' 1 @(@(Get-Content -LiteralPath $calls) | Where-Object { $_ -cmatch 'api --method PATCH repos/.*/issues/' }).Count
  Remove-Item -LiteralPath (Join-Path $fake 'lenient')
}
finally {
  Remove-Item -Recurse -Force $fake, $cache -ErrorAction SilentlyContinue
}

Write-Host ''
if ($failed -gt 0) { Write-Host "$failed failed"; exit 1 }
Write-Host 'all passed'
