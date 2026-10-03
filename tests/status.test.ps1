# The PowerShell twin of status.test.sh, asserting the SAME page: the usage, the pace, the cost, the
# tokens of the day (an answer written twice counted once, every session counted, an older one not), the plan
# with the week pausing both workers, what is ready to close, and the second page of the board.
#
#   pwsh -File tests/status.test.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([IO.Path]::GetTempPath()) "status-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$folder = Join-Path $work 'example'
$now = 1790000000
$env:HOME = Join-Path $work 'home'; $env:AI_CORE_HOME = $env:HOME
$env:AI_CORE_TRANSCRIPTS = Join-Path $work 'transcripts'
$env:GH_ORG = 'example-org'; $env:GH_CACHE_DIRECTORY = Join-Path $work 'cache'
$env:AI_CORE_NOW = "$now"; $env:TZ = 'UTC'
foreach ($d in "$env:HOME/.ai-core", "$folder/.ai-core", "$work/cache/7", "$work/bin") { New-Item -ItemType Directory -Force -Path $d | Out-Null }

$failed = 0
function Check($name, $expected, $actual) {
  if ("$expected" -ceq "$actual") { Write-Host "  ok   $name" }
  else { Write-Host "  FAIL $name`n       expected: $expected`n       actual:   $actual"; $script:failed++ }
}
function When([long]$s) { [DateTimeOffset]::FromUnixTimeSeconds($s).UtcDateTime.ToString('ddd dd.MM. HH:mm', [Globalization.CultureInfo]::InvariantCulture) }
function Iso([long]$s) { [DateTimeOffset]::FromUnixTimeSeconds($s).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture) }

try {
  # The board: its id and columns cached, its cards on two pages behind a fake gh
  Set-Content -LiteralPath "$work/cache/7/project-id" -Value 'PVT_example7'
  Set-Content -LiteralPath "$work/cache/7/fields.tsv" -Value @("Status`tF1`tBacklog`tO1", "Status`tF1`tTodo`tO2", "Status`tF1`tIn progress`tO3", "Status`tF1`tDone`tO4")
  function Card($Number, $Status, $Priority, $State, $ClosedAt, $Parent, $Subs, $Title, $Body = '') {
    $repo = @{ nameWithOwner = 'example-org/example-repo' }
    @{
      status = @{ name = $Status }
      priority = if ($Priority -ceq '-') { $null } else { @{ name = $Priority } }
      content = @{
        number = $Number; title = $Title; state = $State; body = $Body; repository = $repo
        closedAt = if ($ClosedAt -ceq '-') { $null } else { Iso $ClosedAt }
        parent = if ($Parent -ceq '-') { $null } else { @{ number = $Parent; repository = $repo } }
        subIssuesSummary = @{ total = $Subs }
      }
    } | ConvertTo-Json -Depth 5 -Compress
  }
  $page1 = @(
    Card 1 'In progress' P1 OPEN - - 3 'Package: alpha' "The alpha work.`nWorker: exa-sonnet-1`n"
    Card 2 'In progress' P2 OPEN - 1 0 'Second'
    Card 3 Todo P1 OPEN - 1 0 'Third'
    Card 4 Done P2 CLOSED ($now - 7200) 1 0 'Fourth'
    Card 5 Todo P2 OPEN - - 1 'Package: beta'
    Card 6 Done P2 CLOSED ($now - 3600) 5 0 'Sixth'
    Card 21 Todo P2 OPEN - - 1 'Package: gamma' "Worker: exa-hand-1`n"
    Card 22 Todo P2 OPEN - 21 0 'Twenty-second'
    foreach ($n in 9..12) { Card $n Done - CLOSED ($now - ($n - 5) * 3600) - 0 "Closed $n" }
    foreach ($n in 13..20) { Card $n Done - CLOSED ($now - ($n - 7) * 86400) - 0 "Closed $n" }
    '{"status":{"name":"Todo"},"priority":null,"content":{}}'
    'after c2'
  )
  Set-Content -LiteralPath "$work/page1" -Value $page1
  Set-Content -LiteralPath "$work/page2" -Value @((Card 7 Todo - OPEN - - 0 'Seventh'), (Card 8 Done - OPEN - - 0 'Eighth'))
  @"
`$a = `$args -join ' '
if (`$a -cmatch 'after=c2') { Get-Content -LiteralPath '$work/page2'; exit 0 }
if (`$a -cmatch 'items\(first') { Get-Content -LiteralPath '$work/page1'; exit 0 }
[Console]::Error.WriteLine("unexpected gh call: `$a"); exit 1
"@ | Set-Content -Path (Join-Path $work 'bin/gh.ps1') -Encoding utf8NoBOM
  "@echo off`r`npwsh -NoProfile -File `"$work\bin\gh.ps1`" %*" | Set-Content -Path (Join-Path $work 'bin/gh.cmd') -Encoding ascii
  if (-not $IsWindows) { Set-Content -Path (Join-Path $work 'bin/gh') -Value "#!/bin/sh`nexec pwsh -NoProfile -File `"$work/bin/gh.ps1`" `"`$@`"" -Encoding ascii; & chmod +x (Join-Path $work 'bin/gh') }
  # The process list is read by the default view only, and through AI_CORE_PROCESSES there: a ps
  # that refuses proves -Tokens never asks for it.
  if (-not $IsWindows) { Set-Content -Path (Join-Path $work 'bin/ps') -Value "#!/bin/sh`necho 'ps: unknown option -- A' >&2; exit 1" -Encoding ascii; & chmod +x (Join-Path $work 'bin/ps') }
  $env:PATH = "$(Join-Path $work 'bin')$([IO.Path]::PathSeparator)$env:PATH"

  # The team, the usage now and its history, and the transcripts of the folder's sessions
  Set-Content -LiteralPath "$folder/.ai-core/team.tsv" -Value @("coordinator`topus`tmax`t1", "worker`tsonnet`tmax`t2")
  Set-Content -LiteralPath "$env:HOME/.ai-core/usage.json" -Value ('{"recorded_at":' + $now + ',"rate_limits":{"five_hour":{"used_percentage":25,"resets_at":' + ($now + 3600) + '},"seven_day":{"used_percentage":89,"resets_at":' + ($now + 432000) + '}}}')
  Set-Content -LiteralPath "$env:HOME/.ai-core/usage.log" -Value @(
    "$($now - 10800) 1 $($now + 3600) 83 $($now + 432000)", "$($now - 7200) 13 $($now + 3600) 86 $($now + 432000)", "$now 25 $($now + 3600) 89 $($now + 432000)")
  $sessions = Join-Path $env:AI_CORE_TRANSCRIPTS ($folder -creplace '[^A-Za-z0-9]', '-')
  New-Item -ItemType Directory -Force -Path $sessions | Out-Null
  function Answer($At, $Cwd, $Id, $In, $Out, $Created, $Read) {
    @{ type = 'assistant'; timestamp = (Iso $At); cwd = $Cwd; message = @{ id = $Id; usage = @{ input_tokens = $In; output_tokens = $Out; cache_creation_input_tokens = $Created; cache_read_input_tokens = $Read } } } | ConvertTo-Json -Depth 5 -Compress
  }
  $four = Join-Path $folder '.worktrees/example-repo/issue-4-fix'
  Set-Content -LiteralPath (Join-Path $sessions 'session.jsonl') -Value @(
    (@{ type = 'user'; cwd = $four } | ConvertTo-Json -Compress)
    Answer ($now - 7200) $four m1 100 50 10 1000
    Answer ($now - 7200) $four m1 100 50 10 1000
    Answer ($now - 3600) $folder m2 5000 0 0 0
    Answer ($now - 1800) (Join-Path $folder '.worktrees/example-repo/issue-6-add') m3 200 100 0 0
    Answer ($now - 2 * 86400) $folder m4 99999 0 0 0
  )
  # Another folder of the machine used as many fresh tokens in the same hours: it carries half the rise
  New-Item -ItemType Directory -Force -Path (Join-Path $env:AI_CORE_TRANSCRIPTS '-elsewhere') | Out-Null
  Set-Content -LiteralPath (Join-Path $env:AI_CORE_TRANSCRIPTS '-elsewhere/session.jsonl') -Value (Answer ($now - 3600) '/elsewhere' o1 5460 0 0 0)

  Push-Location $folder
  try { $lines = @(& pwsh -NoProfile -File (Join-Path $root 'bin/status.ps1') -Project example-org/7 -Issues 2>&1 | ForEach-Object { "$_" }); $rc = $LASTEXITCODE }
  finally { Pop-Location }
  function Line($Text) { "$(@($lines | Where-Object { $_.Contains($Text) }) | Select-Object -First 1)".Trim() -creplace ' +', ' ' }
  function Keys($Header) {
    $on = $false; $keys = @()
    foreach ($l in $lines) {
      if ($l.StartsWith($Header)) { $on = $true; continue }
      if ($on -and $l.StartsWith('    ')) { $keys += ($l.Trim() -csplit ' +')[1] } elseif ($on) { break }
    }
    $keys -join ' '
  }

  Write-Host 'the head of the page'
  Check 'exit 0'        0 $rc
  Check 'the board'     "example · board example-org/7 · $(When $now)" $lines[0]
  Check 'the usage'     "usage 5h 25 % (reset $(When ($now + 3600))) · week 89 % (reset $(When ($now + 432000))) · limit 92 %" (Line 'usage ')
  Check 'the pace'      'pace 6 issues closed in the last 24 hours, 1.0 a day over 14 days; 2 workers, shared evenly: too few packages name their worker' (Line 'pace ')
  Check 'the cost'      "cost this folder raises the 5h window 4.0 % and the week 1.00 % an hour, 50 % of the machine's fresh tokens; at the pace of 24 hours, 4.00 % of the week per issue closed here" (Line 'cost ')
  Write-Host 'the tokens of the day: an answer written twice counts once, every session counts, an older answer does not'
  Check 'the tokens'    'tokens in 24 hours the sessions of this folder used 5k fresh and read 1k from the cache: 910 fresh and 167 from the cache per closed issue' (Line 'tokens ')
  Check 'the context'   'context 2k per answer on average, 5k the largest, over 3 answers in 24 hours' (Line 'context ')
  Check 'the open work' 'open 8 issues · 3 packages, 1 ready to close · 2 outside packages' (Line 'open ')
  Write-Host 'the plan: each named package on its worker, a session started by hand in place of a free lane, the rest on the one that frees first, the week pausing both'
  Check 'the worker'    'exa-sonnet-1 sonnet max 3.0 issues a day' (Line 'exa-sonnet-1')
  Check 'its package'   "▸ example-repo#1 alpha 2 $(When $now) $(When ($now + 5 * 86400 + 52200))" (Line '▸ example-repo#1')
  Check 'the hand-started session' 'exa-hand-1 a model team.tsv does not name 3.0 issues a day' (Line 'exa-hand-1 ')
  Check 'its package, as written' "▸ example-repo#21 gamma 1 $(When $now) $(When ($now + 5 * 86400 + 23400))" (Line '▸ example-repo#21')
  Check 'the lanes stay the team' '' (Line 'exa-sonnet-2')
  Check 'the rest'      "· outside packages 1 issue 1 $(When ($now + 5 * 86400 + 23400)) $(When ($now + 5 * 86400 + 52200))" (Line '· outside packages')
  Check 'the pause'     "PAUSES week $(When ($now + 5400)) until $(When ($now + 5 * 86400))" (Line 'PAUSES')
  Check 'the end'       "DONE about $(When ($now + 5 * 86400 + 52200)), an estimate from the pace of the last 24 hours, the measured rise of the windows and the pauses" (Line 'DONE')
  Check 'ready'         'CLOSE every sub-issue closed: example-repo#5' (Line 'CLOSE')
  Check 'open on Done'  'CHECK open on Done: example-repo#8' (Line 'CHECK')
  Write-Host 'every open issue, by package, in work order, the second page among them'
  Check 'a package'     'example-repo#1 alpha (2)' (Line 'example-repo#1 alpha (')
  Check 'nearest done first' 'example-repo#2 example-repo#3' (Keys '  example-repo#1 alpha (')
  Check 'outside'       'example-repo#8 example-repo#7' (Keys '  outside packages')
  Write-Host 'without -Tokens: the agents that run now, from the process list alone'
  function Run([string[]] $More) { Push-Location $folder; try { @(& pwsh -NoProfile -File (Join-Path $root 'bin/status.ps1') -Project example-org/7 @More 2>&1 | ForEach-Object { "$_" }) } finally { Pop-Location } }
  $env:AI_CORE_PROCESSES = Join-Path $work 'no-processes'
  Set-Content -LiteralPath $env:AI_CORE_PROCESSES -Value @()
  $nothing = Run
  Remove-Item Env:AI_CORE_PROCESSES
  $tokens = Run '-Tokens'
  Check 'no agent runs: the pace and the forecast, as with -Tokens' ($tokens -join "`n") ($nothing -join "`n")
  Check 'and they are there' 1 @($nothing | Where-Object { $_.StartsWith('pace ') }).Count
  $env:AI_CORE_PROCESSES = Join-Path $work 'processes'
  Set-Content -LiteralPath $env:AI_CORE_PROCESSES -Value @(
    "100`t1`t1-01:00:00`tclaude --resume exa-lead", "101`t100`t05:00`tbash run.sh",
    "102`t101`t03:00`tcodex exec -m big-model -c model_reasoning_effort=high work on example-repo#1",
    "103`t102`t02:00`tagy -p nested child --model cheap-model --effort high",
    "104`t1`t01:02:03`tcodex exec resume thread-w2 --json", "105`t1`t10`tsleep 30", "106`t1`t01:00`tgit log agy -p",
    "107`t1`t2-00:00:00`t/home/x/.local/bin/claude --chrome-native-host",
    "108`t100`t01:00`tnode /usr/lib/node_modules/gemini-cli/bin/gemini.js -p check example-repo#3",
    "109`t1`t05:00`tagy")
  $view = Run
  $rc = $LASTEXITCODE
  Remove-Item Env:AI_CORE_PROCESSES
  function VLine($Text) { "$(@($view | Where-Object { $_.Contains($Text) }) | Select-Object -First 1)".Trim() -creplace ' +', ' ' }
  Check 'exit 0'        0 $rc
  Check 'line 1: the time and the board counts' "example · board example-org/7 · $(When $now) · Backlog 0 · Todo 5 · In progress 2 · Done 15" $view[0]
  Check 'a session, named by its resume' '│ claude exa-lead │ 100 │ │ 1500 min │ │ session │' (VLine '│ claude exa-lead ')
  Check 'the runs it started, through a script too, newest first' '│ └ gemini │ 108 │ │ 1 min │ example-repo#3 │ run │' (VLine '└ gemini')
  Check 'with model and effort' '│ └ codex │ 102 │ big-model · high │ 3 min │ example-repo#1 │ run │' (VLine '└ codex')
  Check 'a run a run started' '│ └ agy │ 103 │ cheap-model · high │ 2 min │ │ run │' (VLine '└ agy')
  Check 'indented one step deeper' 1 @($view | Where-Object { $_.StartsWith('│     └ agy ') }).Count
  Check 'a run no agent started stands alone' '│ codex │ 104 │ │ 62 min │ │ resumed run │' (VLine '│ codex ')
  Check 'an agent CLI without a prompt is a session' '│ agy │ 109 │ │ 5 min │ │ session │' (VLine '│ agy ')
  Check 'in this order' '100 108 102 103 104 109' ((@($view | ForEach-Object { $c = $_.Split('│'); if ($c.Count -gt 3 -and $c[2].Trim() -cmatch '^\d+$') { $c[2].Trim() } })) -join ' ')
  Check 'no helper, no tool word in another command' 'AGENTS 6 running: 1 claude, 1 gemini, 2 codex, 2 agy' (VLine ' running: ')
  Check 'no token lines' '' (VLine 'pace ')
  Write-Host 'outside a repository with no board named: refused, naming -Project'
  Push-Location $folder
  try { $refused = (@(& pwsh -NoProfile -File (Join-Path $root 'bin/status.ps1') 2>&1 | ForEach-Object { "$_" }) -join ' '); $rc = $LASTEXITCODE }
  finally { Pop-Location }
  Check 'exit 1'        1 $rc
  Check 'the line'      'yes' $(if ($refused.Contains('outside a repository, name the board - status -Project N')) { 'yes' } else { $refused })
} finally {
  Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue
}

if ($failed -gt 0) { Write-Host ''; $lines | ForEach-Object { Write-Host $_ }; Write-Host "`n$failed failed"; exit 1 }
Write-Host "`nall passed"
