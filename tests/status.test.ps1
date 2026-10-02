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
  $env:PATH = "$(Join-Path $work 'bin')$([IO.Path]::PathSeparator)$env:PATH"

  # The team, the usage now and its history, and the transcripts of the folder's sessions
  Set-Content -LiteralPath "$folder/.ai-core/team.tsv" -Value @("coordinator`topus`tmax`t1", "worker`tsonnet`tmax`t2")
  Set-Content -LiteralPath "$env:HOME/.ai-core/usage.json" -Value ('{"recorded_at":' + $now + ',"rate_limits":{"five_hour":{"used_percentage":25,"resets_at":' + ($now + 3600) + '},"seven_day":{"used_percentage":89,"resets_at":' + ($now + 432000) + '}}}')
  Set-Content -LiteralPath "$env:HOME/.ai-core/usage.log" -Value @(
    "$($now - 10800) 5 $($now + 3600) 85 $($now + 432000)", "$($now - 7200) 15 $($now + 3600) 87 $($now + 432000)", "$now 25 $($now + 3600) 89 $($now + 432000)")
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
  Check 'the cost'      'cost an issue closed here raises the 5h window 10.0 % and the week 2.00 %' (Line 'cost ')
  Write-Host 'the tokens of the day: an answer written twice counts once, every session counts, an older answer does not'
  Check 'the tokens'    'tokens in 24 hours the sessions of this folder used 5k fresh and read 1k from the cache: 910 fresh and 167 from the cache per closed issue' (Line 'tokens ')
  Check 'the context'   'context 2k per answer on average, 5k the largest, over 3 answers in 24 hours' (Line 'context ')
  Check 'the open work' 'open 8 issues · 3 packages, 1 ready to close · 2 outside packages' (Line 'open ')
  Write-Host 'the plan: each named package on its worker, a session started by hand in place of a free lane, the rest on the one that frees first, the week pausing both'
  Check 'the worker'    'exa-sonnet-1 sonnet max 3.0 issues a day' (Line 'exa-sonnet-1')
  Check 'its package'   "▸ example-repo#1 alpha 2 $(When $now) $(When ($now + 5 * 86400 + 28800))" (Line '▸ example-repo#1')
  Check 'the hand-started session' 'exa-hand-1 a model team.tsv does not name 3.0 issues a day' (Line 'exa-hand-1 ')
  Check 'its package, as written' "▸ example-repo#21 gamma 1 $(When $now) $(When ($now + 28800))" (Line '▸ example-repo#21')
  Check 'the lanes stay the team' '' (Line 'exa-sonnet-2')
  Check 'the rest'      "· outside packages 1 issue 1 $(When ($now + 5 * 86400)) $(When ($now + 5 * 86400 + 28800))" (Line '· outside packages')
  Check 'the pause'     "PAUSES week $(When ($now + 28800)) until $(When ($now + 5 * 86400))" (Line 'PAUSES')
  Check 'the end'       "DONE about $(When ($now + 5 * 86400 + 28800)), an estimate from the pace of the last 24 hours, the cost per issue and the pauses" (Line 'DONE')
  Check 'ready'         'CLOSE every sub-issue closed: example-repo#5' (Line 'CLOSE')
  Check 'open on Done'  'CHECK open on Done: example-repo#8' (Line 'CHECK')
  Write-Host 'every open issue, by package, in work order, the second page among them'
  Check 'a package'     'example-repo#1 alpha (2)' (Line 'example-repo#1 alpha (')
  Check 'nearest done first' 'example-repo#2 example-repo#3' (Keys '  example-repo#1 alpha (')
  Check 'outside'       'example-repo#8 example-repo#7' (Keys '  outside packages')
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
