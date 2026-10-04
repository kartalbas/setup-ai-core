# The PowerShell twin of status.test.sh, asserting the SAME page: the usage, the pace, the cost, the
# tokens of the day (an answer written twice counted once, every session counted, an older one not), what
# is ready to close, and the second page of the board.
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
    Card 1 'In progress' P1 OPEN - - 3 'alpha' "The alpha work.`n"
    Card 2 'In progress' P2 OPEN - 1 0 'Second'
    Card 3 Todo P1 OPEN - 1 0 'Third'
    Card 4 Done P2 CLOSED ($now - 7200) 1 0 'Fourth'
    Card 5 Todo P2 OPEN - - 1 'beta'
    Card 6 Done P2 CLOSED ($now - 3600) 5 0 'Sixth'
    Card 21 Todo P2 OPEN - - 1 'gamma'
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

  # The usage now and its history, and the transcripts of the folder's sessions
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
  Check 'the pace'      'pace 6 issues closed in the last 24 hours, 1.0 a day over 14 days' (Line 'pace ')
  Check 'the cost'      "cost this folder raises the 5h window 4.0 % and the week 1.00 % an hour, 50 % of the machine's fresh tokens; at the pace of 24 hours, 4.00 % of the week per issue closed here" (Line 'cost ')
  Write-Host 'the tokens of the day: an answer written twice counts once, every session counts, an older answer does not'
  Check 'the tokens'    'tokens in 24 hours the sessions of this folder used 5k fresh and read 1k from the cache: 910 fresh and 167 from the cache per closed issue' (Line 'tokens ')
  Check 'the context'   'context 2k per answer on average, 5k the largest, over 3 answers in 24 hours' (Line 'context ')
  Check 'the open work' 'open 8 issues · 3 epics, 1 ready to close · 2 outside epics' (Line 'open ')
  Write-Host 'no plan by worker and no forecast: the coordinator says who works on what'
  Check 'no plan'       0 @($lines | Where-Object { $_ -cmatch '^(PLAN BY WORKER|PAUSES|DONE) ' }).Count
  Check 'ready'         'CLOSE every sub-issue closed: example-repo#5' (Line 'CLOSE')
  Check 'open on Done'  'CHECK open on Done: example-repo#8' (Line 'CHECK')
  Write-Host 'every open issue, by epic, in work order, the second page among them'
  Check 'an epic'      'example-repo#1 alpha (2)' (Line 'example-repo#1 alpha (')
  Check 'nearest done first' 'example-repo#2 example-repo#3' (Keys '  example-repo#1 alpha (')
  Check 'outside'       'example-repo#8 example-repo#7' (Keys '  outside epics')
  Write-Host 'without -Tokens: the agents that run now, from the process list alone'
  function Run([string[]] $More) { Push-Location $folder; try { @(& pwsh -NoProfile -File (Join-Path $root 'bin/status.ps1') -Project example-org/7 @More 2>&1 | ForEach-Object { "$_" }) } finally { Pop-Location } }
  # Claude Code's list of its sessions and the codex rollout files held open, through their
  # stand-ins: the default view reads them with the process list
  $env:AI_CORE_AGENTS = Join-Path $work 'no-agents'
  $env:AI_CORE_ROLLOUTS = Join-Path $work 'no-rollouts'
  Set-Content -LiteralPath $env:AI_CORE_AGENTS -Value @()
  Set-Content -LiteralPath $env:AI_CORE_ROLLOUTS -Value @()
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
    "109`t1`t05:00`tagy", "110`t1`t30:00`t/home/x/.local/bin/claude daemon run --origin transient",
    "111`t110`t29:00`tclaude bg-pty-host --bg-pty-host /tmp/x.sock 200 50 -- /home/x/.local/share/claude/versions/2.1.289 --session-id 22222222-2222-2222-2222-222222222222",
    "112`t111`t29:00`t/home/x/.local/share/claude/versions/2.1.289 --session-id 22222222-2222-2222-2222-222222222222 --name l1-sonnet5.5-low-100k-ab123 --model sonnet --effort low")
  $env:AI_CORE_AGENTS = Join-Path $work 'agents'
  Set-Content -LiteralPath $env:AI_CORE_AGENTS -Value @(
    '[{"pid":100,"kind":"interactive","name":"exa-lead","sessionId":"11111111-1111-1111-1111-111111111111","id":null},',
    '{"pid":112,"kind":"background","name":"l1-sonnet5.5-low-100k-ab123","sessionId":"22222222-2222-2222-2222-222222222222","id":"22222222"}]')
  $env:AI_CORE_ROLLOUTS = Join-Path $work 'rollouts'
  Set-Content -LiteralPath $env:AI_CORE_ROLLOUTS -Value @(
    "/proc/102/fd`t/home/x/.codex/sessions/2026/10/04/rollout-2026-10-04T11-52-48-01a106c2-71cd-7451-94ce-508f6229cd5b.jsonl",
    "/proc/100/fd`t/home/x/.codex/sessions/2026/10/04/rollout-2026-10-04T11-00-00-01a10000-0000-7000-8000-000000000000.jsonl")
  $view = Run
  $rc = $LASTEXITCODE
  $env:AI_CORE_AGENTS = Join-Path $work 'bad-agents'
  Set-Content -LiteralPath $env:AI_CORE_AGENTS -Value 'claude agents --json failed'
  $broken = Run
  Remove-Item Env:AI_CORE_PROCESSES, Env:AI_CORE_AGENTS, Env:AI_CORE_ROLLOUTS
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
  Check 'a background session runs from the versioned binary' '│ claude l1-sonnet5.5 │ 112 │ sonnet · low │ 29 min │ │ session │' (VLine '│ claude l1-sonnet5.5 ')
  Check 'its daemon and terminal host are no agents' 0 @($view | Where-Object { $_ -cmatch '│ 11[01] +│' }).Count
  Check 'in this order' '100 108 102 103 104 112 109' ((@($view | ForEach-Object { $c = $_.Split('│'); if ($c.Count -gt 3 -and $c[2].Trim() -cmatch '^\d+$') { $c[2].Trim() } })) -join ' ')
  Check 'no helper, no tool word in another command' 'AGENTS 7 running: 2 claude, 1 gemini, 2 codex, 2 agy' (VLine ' running: ')
  Check 'no token lines' '' (VLine 'pace ')
  Write-Host 'the command that reaches each agent, from what its CLI reports'
  function Reach($Page, $AgentPid) {
    $on = $false
    foreach ($l in $Page) { if ($on -and $l.StartsWith("  $AgentPid ")) { return ($l.Trim() -creplace ' +', ' ') }; if ($l -ceq 'REACH') { $on = $true } }
    ''
  }
  Check 'an interactive session: resume it, a rollout it holds changes nothing' '100 exa-lead claude --resume 11111111-1111-1111-1111-111111111111' (Reach $view 100)
  Check 'a background session: attach to it' '112 l1-sonnet5.5-low-100k-ab123 claude attach 22222222' (Reach $view 112)
  Check 'a codex process: the rollout it holds open' '102 codex codex resume 01a106c2-71cd-7451-94ce-508f6229cd5b' (Reach $view 102)
  Check 'a codex process that holds none: a dash' '104 codex —' (Reach $view 104)
  Check 'an agent its CLI says nothing about: a dash' '109 agy —' (Reach $view 109)
  $after = $false
  Check 'every agent, in the order of the table' '100 108 102 103 104 112 109' ((@($view | ForEach-Object { if ($after -and $_ -cmatch '^  (\d+) ') { $Matches[1] }; if ($_ -ceq 'REACH') { $after = $true } })) -join ' ')
  Check 'a list that failed is shown, not swallowed' 'claude agents --json gave no list: claude agents --json failed' "$(@($broken | Where-Object { $_.Contains('gave no list') }) | Select-Object -First 1)".Trim()
  Check 'and no command is guessed' '100 claude —' (Reach $broken 100)
  # Where no stand-in names the rollouts, the twin asks find, which exits 1 on the processes it may
  # not read; what it found still reaches the page. Without /proc there is nothing to ask.
  $held = '104 codex —'
  $path = $env:PATH
  if (Test-Path -LiteralPath '/proc' -PathType Container) {
    $findBin = Join-Path $work 'findbin'
    New-Item -ItemType Directory -Path $findBin | Out-Null
    Set-Content -Path (Join-Path $findBin 'find') -Encoding ascii -Value "#!/bin/sh`nprintf '%s\t%s\n' /proc/104/fd /x/rollout-2026-10-04T12-00-00-01a10444-0000-7000-8000-000000000444.jsonl`nexit 1"
    & chmod +x (Join-Path $findBin 'find')
    $env:PATH = "$findBin$([IO.Path]::PathSeparator)$env:PATH"
    $held = '104 codex codex resume 01a10444-0000-7000-8000-000000000444'
  }
  $env:AI_CORE_PROCESSES = Join-Path $work 'processes'
  $env:AI_CORE_AGENTS = Join-Path $work 'agents'
  $found = Run
  $rc = $LASTEXITCODE
  $env:PATH = $path
  Remove-Item Env:AI_CORE_PROCESSES, Env:AI_CORE_AGENTS
  Check 'a find that exits 1 stops nothing' 0 $rc
  Check 'and what it found reaches the page' $held (Reach $found 104)
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
