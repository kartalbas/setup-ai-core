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

Write-Host 'a commit on master moves a card to testing'
Check 'from todo'         'testing' (Get-DeriveTarget -Current 'todo' -OnMaster 1 -Released 0 -IsEpic 0)
Check 'from backlog'      'testing' (Get-DeriveTarget -Current 'backlog' -OnMaster 1 -Released 0 -IsEpic 0)
Check 'from implementing' 'testing' (Get-DeriveTarget -Current 'implementing' -OnMaster 1 -Released 0 -IsEpic 0)

Write-Host 'a commit carried by the newest tag closes the issue'
Check 'from todo'         'CLOSE' (Get-DeriveTarget -Current 'todo' -OnMaster 1 -Released 1 -IsEpic 0)
Check 'from implementing' 'CLOSE' (Get-DeriveTarget -Current 'implementing' -OnMaster 1 -Released 1 -IsEpic 0)
Check 'from testing'      'CLOSE' (Get-DeriveTarget -Current 'testing' -OnMaster 1 -Released 1 -IsEpic 0)

Write-Host 'it never moves a card backward'
Check 'testing stays testing' '' (Get-DeriveTarget -Current 'testing' -OnMaster 1 -Released 0 -IsEpic 0)
Check 'done stays done'       '' (Get-DeriveTarget -Current 'done' -OnMaster 1 -Released 1 -IsEpic 0)

# The card is put in implementing by start-issue, at the moment the worktree is opened. That
# column is a person's statement, so the sweep never writes it and never reads a worktree.
Write-Host 'an open worktree is not a signal, so nothing moves without a commit on master'
Check 'nothing at all'           '' (Get-DeriveTarget -Current 'todo' -OnMaster 0 -Released 0 -IsEpic 0)
Check 'a tag without the commit' '' (Get-DeriveTarget -Current 'todo' -OnMaster 0 -Released 1 -IsEpic 0)
Check 'implementing stays where a person put it' '' (Get-DeriveTarget -Current 'implementing' -OnMaster 0 -Released 0 -IsEpic 0)

Write-Host 'it never moves an epic, whatever the signal'
Check 'epic with a released commit'  '' (Get-DeriveTarget -Current 'todo' -OnMaster 1 -Released 1 -IsEpic 1)
Check 'epic with a commit on master' '' (Get-DeriveTarget -Current 'todo' -OnMaster 1 -Released 0 -IsEpic 1)

Write-Host 'the ranks are what forbid a backward move'
Check 'backlog'       0 (Get-StatusRank 'backlog')
Check 'todo'          0 (Get-StatusRank 'todo')
Check 'implementing'  1 (Get-StatusRank 'implementing')
Check 'testing'       2 (Get-StatusRank 'testing')
Check 'done'          3 (Get-StatusRank 'done')
Check 'CLOSE is done' 3 (Get-StatusRank 'CLOSE')

# --- the signal path, driven end to end against a stand-in gh -----------------
#
# The decision above is pure, and everything that FEEDS it is not. The timeline query that finds
# the newest commit naming an issue, the two `compare/<ref>...<sha>` reads that say whether a ref
# carries it, the board list and the memo are what a change breaks, and a suite that only calls
# Get-DeriveTarget cannot tell the two twins apart on any of them.
#
# NOTHING REACHES github.com. A stand-in `gh` on PATH answers the board, the signals of each
# issue, the default branch, the tag list and each compare, and writes down every call it was
# given, so the READS are held as well as the two lines the sweep prints.
#
# THE TWO PLANTED CARDS, one per signal:
#   #12 implementing, its commit behind master and not in the tag   -> would move to testing
#   #13 todo, its commit behind master and identical to the tag     -> would close, released

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

function Card($number, $title, $status) {
  '{"fieldValues":{"nodes":[{"name":"' + $status + '","field":{"name":"Status"}}]},"content":{"number":' +
  $number + ',"title":"' + $title + '","state":"OPEN","repository":{"name":"example-repo"}}}'
}
Set-Content -Encoding utf8NoBOM -Path (Join-Path $fake 'board.json') -Value (
  '{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[' +
  ((Card 12 'A commit of its own is on master' 'implementing'),
   (Card 13 'A commit of its own is in the newest tag' 'todo'),
   (Card 14 'An epic with one child' 'todo') -join ',') + ']}}}}')

# One REFERENCED_EVENT, from a commit in the issue's own repository, after no reopening.
function Signals($sha) {
  '{"data":{"repository":{"issue":{"state":"OPEN","subIssuesSummary":{"total":0},"reopened":{"nodes":[]},' +
  '"timelineItems":{"nodes":[{"createdAt":"2026-09-01T10:00:00Z","isCrossRepository":false,"commit":{"oid":"' +
  $sha + '","committedDate":"2026-09-01T10:00:00Z"}}]}}}}}'
}
Set-Content -Encoding utf8NoBOM -Path (Join-Path $fake 'project-id.json') -Value ('{"data":{"organization":{"projectV2":{"id":"' + $projectId + '"}}}}')
Set-Content -Encoding utf8NoBOM -Path (Join-Path $fake 'signals-12.json') -Value (Signals 'sha12')
Set-Content -Encoding utf8NoBOM -Path (Join-Path $fake 'signals-13.json') -Value (Signals 'sha13')
Set-Content -Encoding utf8NoBOM -Path (Join-Path $fake 'signals-14.json') -Value '{"data":{"repository":{"issue":{"state":"OPEN","subIssuesSummary":{"total":1},"reopened":{"nodes":[]},"timelineItems":{"nodes":[]}}}}}'
Set-Content -Encoding utf8NoBOM -Path (Join-Path $fake 'repo.json') -Value '{"default_branch":"master"}'
Set-Content -Encoding utf8NoBOM -Path (Join-Path $fake 'tags.json') -Value '[{"name":"0.8.100"}]'
Set-Content -Encoding utf8NoBOM -Path (Join-Path $fake 'compare-master-sha12.json')  -Value '{"status":"behind"}'
Set-Content -Encoding utf8NoBOM -Path (Join-Path $fake 'compare-tag-sha12.json')     -Value '{"status":"ahead"}'
Set-Content -Encoding utf8NoBOM -Path (Join-Path $fake 'compare-master-sha13.json')  -Value '{"status":"behind"}'
Set-Content -Encoding utf8NoBOM -Path (Join-Path $fake 'compare-tag-sha13.json')     -Value '{"status":"identical"}'

# The stand-in RUNS the --jq program the caller gave, the way gh does. Answering the raw
# document instead would let a script that never reads its answer pass.
@"
`$ErrorActionPreference = 'Stop'
`$line = `$args -join ' '
Add-Content -LiteralPath '$calls' -Value `$line
if     (`$line -like '*projectV2(number:*')             { `$doc = 'project-id.json' }
elseif (`$line -like '*items(first:100, after:*')       { `$doc = 'board.json' }
elseif (`$line -like '*num=12*')                        { `$doc = 'signals-12.json' }
elseif (`$line -like '*num=13*')                        { `$doc = 'signals-13.json' }
elseif (`$line -like '*num=14*')                        { `$doc = 'signals-14.json' }
elseif (`$line -like '*compare/master...sha12*')        { `$doc = 'compare-master-sha12.json' }
elseif (`$line -like '*compare/0.8.100...sha12*')       { `$doc = 'compare-tag-sha12.json' }
elseif (`$line -like '*compare/master...sha13*')        { `$doc = 'compare-master-sha13.json' }
elseif (`$line -like '*compare/0.8.100...sha13*')       { `$doc = 'compare-tag-sha13.json' }
elseif (`$line -like '*/tags*')                         { `$doc = 'tags.json' }
elseif (`$line -like '*repos/example-org/example-repo*') { `$doc = 'repo.json' }
else { [Console]::Error.WriteLine("the stand-in gh has no answer for: `$line"); exit 9 }
`$prog = ''
for (`$i = 0; `$i -lt `$args.Count - 1; `$i++) { if (`$args[`$i] -eq '--jq') { `$prog = `$args[`$i + 1] } }
`$answer = Get-Content -Raw (Join-Path '$fake' `$doc)
if (`$prog) { `$answer | & jq -r `$prog } else { `$answer }
exit 0
"@ | Set-Content -Path (Join-Path $ghDir 'gh.ps1') -Encoding utf8NoBOM
$env:PATH = "$ghDir$([IO.Path]::PathSeparator)$env:PATH"

function CallCount($text) { @(@(Get-Content -LiteralPath $calls -EA SilentlyContinue) | Where-Object { $_.Contains($text) }).Count }

try {
  Write-Host 'the sweep, driven against a stand-in gh: one card per signal'
  $run = @(& pwsh -NoProfile -File (Join-Path $root 'bin/status-sync.ps1') -Project $projectNumber -DryRun 2>&1 |
    ForEach-Object { "$_" })
  Check 'exit 0' 0 $LASTEXITCODE
  Check 'a commit on master would move the card to testing' `
    'would move   example-repo#12  (implementing -> testing)' (@($run | Where-Object { $_ -like 'would move*' }))[0]
  Check 'a commit the newest tag carries would close the issue' `
    'would close  example-repo#13  (todo -> done, released in 0.8.100)' (@($run | Where-Object { $_ -like 'would close*' }))[0]
  Check 'an epic with one sub-issue is named and not moved' `
    'one child    example-repo#14  (an epic with a single sub-issue is a plain issue, rules.md section 8)' (@($run | Where-Object { $_ -like 'one child*' }))[0]
  Check 'and the count says what it read' `
    "3 active cards scanned, 2 would move on board $projectNumber." $run[-1]

  Write-Host 'the compare is asked once per question, with the ref as base and the commit as head'
  Check 'is the commit of #12 on master' 1 (CallCount 'compare/master...sha12')
  Check 'is it in the newest tag'        1 (CallCount 'compare/0.8.100...sha12')
  Check 'is the commit of #13 on master' 1 (CallCount 'compare/master...sha13')
  Check 'is it in the newest tag'        1 (CallCount 'compare/0.8.100...sha13')

  # The memo exists so a board of two hundred cards in one repository does not ask for the same
  # default branch two hundred times.
  Write-Host 'the memo answers: one read per repository for the run, not one per card'
  Check 'the default branch, once for both cards' 1 (CallCount 'repos/example-org/example-repo --jq .default_branch')
  Check 'the tag list, once for both cards'       1 (CallCount 'repos/example-org/example-repo/tags')
}
finally {
  Remove-Item -Recurse -Force $fake, $cache -ErrorAction SilentlyContinue
}

Write-Host ''
if ($failed -gt 0) { Write-Host "$failed failed"; exit 1 }
Write-Host 'all passed'
