<#
The PowerShell twin of board-sync.test.sh, asserting the SAME report against
bin/board-sync.ps1.

    pwsh -NoProfile -File test/board-sync.test.ps1

NOTHING REACHES github.com. A stand-in `gh` is on PATH for the whole run and answers a
prepared board, a prepared repository list and a prepared issue list, so every shape below is
one somebody would otherwise have to create real cards to produce - a card carrying no
priority, a closed card carrying none, a card GitHub stamped a status onto as it was added. A
project id is seeded into the cache under a board number of this run's own, and the stand-in
answers the id query as well, so no real board is ever resolved and no run depends on what
another one left behind.

THE CLASS THIS HOLDS CLOSED. This sweep is the one report the owner reads to find out what is
missing, and a REPORT is only worth what a reader can act on. A ticket that is OPEN and
carries no priority is work somebody can still decide about, so it is named with its repo, its
number and its title. A CLOSED one is not: a priority put on a finished ticket by somebody who
did not work it is a guess, and this tool reports rather than guesses. Held as one number the
two are indistinguishable, and the one ticket that can be fixed disappears into a count that
is mostly finished work.

THE PLANTED DEFECTS, one of each shape the report has to tell apart:
  #3 and #5 are OPEN and carry no priority   -> both named, one per line
  #2 is CLOSED and carries none              -> counted, never named
  #2 carries no label at all, and is closed  -> counted, never named
  #3 carries an area label and no type       -> named, because it is open

THE PLANTED INNOCENT CASES are #1 and #4, which carry a priority and both labels. Neither may
appear anywhere in the report - without them a script that named every card it read would pass
every assertion above. A whole innocent BOARD is run at the end for the same reason one level
up: nothing missing anywhere, and the run must still say what it looked at.

EVERY COUNT IS ASSERTED WITH ITS DENOMINATOR. "1 missing" reads the same on a board of two
cards and a board of two hundred, and it reads the same on a run that read nothing at all.
#>

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fake = Join-Path ([IO.Path]::GetTempPath()) "board-sync-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$env:GH_CACHE_DIRECTORY = Join-Path $fake 'cache'
$ghDir = Join-Path $fake 'gh'
New-Item -ItemType Directory -Path $ghDir -Force | Out-Null
$projectNumber = 999997
$projectId = 'PVT_kwboardtest'
$cache = Join-Path $env:GH_CACHE_DIRECTORY "$projectNumber"
$failed = 0

New-Item -ItemType Directory -Path $cache -Force | Out-Null
Set-Content -Path (Join-Path $cache 'project-id') -Value $projectId -NoNewline

function Check($name, $expected, $actual) {
  if ("$expected" -eq "$actual") { Write-Host "  ok   $name" }
  else { Write-Host "  FAIL $name`n       expected: $expected`n       actual:   $actual"; $script:failed++ }
}

# A block of lines as one string, so a report is asserted whole and a line that moved is shown
# next to the line it moved from.
function Join-Lines([string[]]$lines) { $lines -join '|' }

# The block that opens with this exact line, and the given number of lines after it.
function Get-Block([string[]]$lines, [string]$first, [int]$more) {
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -eq $first) { return ($lines[$i..($i + $more)] -join '|') }
  }
  return "no line reading: $first"
}

# --- the prepared answers -----------------------------------------------------

# The stand-in answers the project-id query as well as the rest, so a run whose seeded cache is
# gone asks for the id and is given the same one. Without it the verdict depends on a file under
# the repository surviving the whole run, and a run that lost it goes red about the stand-in
# instead of about board-sync.
Set-Content -Encoding utf8NoBOM -Path (Join-Path $fake 'project-id.json') `
  -Value ('{"data":{"organization":{"projectV2":{"id":"' + $projectId + '"}}}}')
Set-Content -Encoding utf8NoBOM -Path (Join-Path $fake 'repos.json') `
  -Value '{"data":{"node":{"repositories":{"nodes":[{"nameWithOwner":"example-org/example"}]}}}}'
Set-Content -Encoding utf8NoBOM -Path (Join-Path $fake 'archived.json') `
  -Value '{"data":{"repository":{"issue":{"projectItems":{"nodes":[]}}}}}'
Set-Content -Encoding utf8NoBOM -Path (Join-Path $fake 'node.json') `
  -Value '{"node_id":"I_kwexample"}'
Set-Content -Encoding utf8NoBOM -Path (Join-Path $fake 'item.json') `
  -Value '{"data":{"addProjectV2ItemById":{"item":{"id":"PVTI_kwexample"}}}}'

# One card as the board query answers it. A card with no priority simply has no Priority value
# among its field values, which is how the board answers for a field nobody set - board-list
# turns that absence into the "-" column this report reads.
function Card($number, $title, $state, $status, $priority) {
  $prio = if ($priority -eq '-') { '' }
          else { ',{"name":"' + $priority + '","field":{"name":"Priority"}}' }
  '{"fieldValues":{"nodes":[{"name":"' + $status + '","field":{"name":"Status"}}' + $prio +
  ']},"content":{"number":' + $number + ',"title":"' + $title + '","state":"' + $state +
  '","repository":{"name":"example"}}}'
}
function Board([string[]]$cards) {
  '{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[' +
  ($cards -join ',') + ']}}}}'
}
function Issue($number, $state, $title, [string[]]$labels) {
  $names = (@($labels | Where-Object { $_ } | ForEach-Object { '{"name":"' + $_ + '"}' })) -join ','
  '{"number":' + $number + ',"state":"' + $state + '","title":"' + $title + '","labels":[' + $names + ']}'
}
function Issues([string[]]$issues) { '[' + ($issues -join ',') + ']' }

# The stand-in answers each query by what it asked for, and RUNS the --jq program the caller
# gave, the way gh does. Answering the raw document instead would let a script that never
# reads its answer pass. The two board reads are answered from two different documents, so
# what was on the board before the sweep and what is on it after are genuinely different.
@"
`$ErrorActionPreference = 'Stop'
`$line = `$args -join ' '
if     (`$line -like '*projectV2(number:*')       { `$doc = 'project-id.json' }
elseif (`$line -like '*repositories(first:100)*') { `$doc = 'repos.json' }
elseif (`$line -like '*items(first:100, after:*') {
  `$counter = Join-Path '$fake' 'reads'
  `$n = if (Test-Path `$counter) { [int](Get-Content `$counter -Raw) } else { 0 }
  `$n++
  Set-Content -Path `$counter -Value `$n -NoNewline
  `$doc = "board-`$n.json"
}
elseif (`$line -like '*issue list*')            { `$doc = 'issues.json' }
elseif (`$line -like '*projectItems(first:20*') { `$doc = 'archived.json' }
elseif (`$line -like '*addProjectV2ItemById*')  { `$doc = 'item.json' }
elseif (`$line -like '*/issues/*')              { `$doc = 'node.json' }
else { [Console]::Error.WriteLine("the stand-in gh has no answer for: `$line"); exit 9 }
# A query the stand-in recognised but has no document for - a THIRD read of the board is the one
# that happens - refuses by name. Handed to jq instead it dies about a file, which reads as a
# broken test rather than as the run asking one time too often.
`$path = Join-Path '$fake' `$doc
if (-not (Test-Path `$path)) { [Console]::Error.WriteLine("the stand-in gh has no `$doc prepared"); exit 9 }
`$prog = ''
for (`$i = 0; `$i -lt `$args.Count - 1; `$i++) { if (`$args[`$i] -eq '--jq') { `$prog = `$args[`$i + 1] } }
`$answer = Get-Content -Raw `$path
if (`$prog) { `$answer | & jq -r `$prog } else { `$answer }
exit 0
"@ | Set-Content -Path (Join-Path $ghDir 'gh.ps1') -Encoding utf8NoBOM
$env:PATH = "$ghDir$([IO.Path]::PathSeparator)$env:PATH"

function Invoke-Sweep {
  Remove-Item (Join-Path $fake 'reads') -Force -EA SilentlyContinue
  @(& pwsh -NoProfile -File (Join-Path $root 'bin/board-sync.ps1') -Project $projectNumber 2>&1 |
      ForEach-Object { "$_" })
}

try {
  # --- the board with a gap of every shape ------------------------------------

  # #5 is on the board after the sweep and not before it, which is the item GitHub stamps a
  # status onto as it is added.
  $onBoardBefore = Board @(
    (Card 1 'Add the job-completion endpoint' 'OPEN' 'todo' 'P1'),
    (Card 2 'Rename the sweep that no longer sweeps' 'CLOSED' 'done' '-'),
    (Card 3 'Read the install order from one file' 'OPEN' 'todo' '-'),
    (Card 4 'Take a label off an issue' 'CLOSED' 'done' 'P2'))
  $onBoardAfter = Board @(
    (Card 1 'Add the job-completion endpoint' 'OPEN' 'todo' 'P1'),
    (Card 2 'Rename the sweep that no longer sweeps' 'CLOSED' 'done' '-'),
    (Card 3 'Read the install order from one file' 'OPEN' 'todo' '-'),
    (Card 4 'Take a label off an issue' 'CLOSED' 'done' 'P2'),
    (Card 5 'Name the tickets that carry no priority' 'OPEN' 'todo' '-'))

  Set-Content -Encoding utf8NoBOM -Path (Join-Path $fake 'board-1.json') -Value $onBoardBefore
  Set-Content -Encoding utf8NoBOM -Path (Join-Path $fake 'board-2.json') -Value $onBoardAfter
  Set-Content -Encoding utf8NoBOM -Path (Join-Path $fake 'issues.json') -Value (Issues @(
    (Issue 1 'OPEN'   'Add the job-completion endpoint'          @('type:feature', 'area:tooling')),
    (Issue 2 'CLOSED' 'Rename the sweep that no longer sweeps'   @()),
    (Issue 3 'OPEN'   'Read the install order from one file'     @('area:tooling')),
    (Issue 4 'CLOSED' 'Take a label off an issue'                @('type:feature', 'area:tooling')),
    (Issue 5 'OPEN'   'Name the tickets that carry no priority'  @('type:bug', 'area:tooling'))))

  'the whole report, which is what both shells are held to'

  $out = Invoke-Sweep
  Check 'reads line for line' (Join-Lines @(
    'example-org/example',
    '  #3    missing label: type         Read the install order from one file',
    '',
    '1 of 3 OPEN issues are missing a type or an area label, listed above',
    '1 of 2 closed issues are missing one too, and are not listed -',
    "  labelling somebody else's finished ticket is a guess, and nothing on the board filters on it",
    '',
    '1 of the 5 cards on the board were NOT on it before this run.',
    'GitHub stamped each one with a status as it was added - it is the first word of every',
    'line below. Move whatever does not belong there:',
    '  todo            -   example                #5    Name the tickets that carry no priority',
    '',
    'OPEN cards on the board that carry no priority:',
    '  todo            -   example                #3    Read the install order from one file',
    '  todo            -   example                #5    Name the tickets that carry no priority',
    '2 of 3 OPEN cards carry no priority, listed above',
    '1 of 2 closed cards carry none either, and are not listed -',
    '  a priority put on a finished ticket by somebody who did not work it is a guess')) (Join-Lines $out)

  ''
  'the priority gap'

  Check 'every OPEN card that carries none is named, with its repo, its number and its title' (Join-Lines @(
    'OPEN cards on the board that carry no priority:',
    '  todo            -   example                #3    Read the install order from one file',
    '  todo            -   example                #5    Name the tickets that carry no priority')) `
    (Get-Block $out 'OPEN cards on the board that carry no priority:' 2)

  Check 'the count beside them says what they were counted out of' `
    '2 of 3 OPEN cards carry no priority, listed above' `
    ((@($out | Where-Object { $_ -like '*OPEN cards carry no priority*' })) -join '|')

  Check 'the CLOSED one is counted, with its own denominator' `
    '1 of 2 closed cards carry none either, and are not listed -' `
    ((@($out | Where-Object { $_ -like '*closed cards carry none either*' })) -join '|')

  Check 'and the CLOSED one is nowhere named' 0 `
    (@($out | Where-Object { $_ -like '*Rename the sweep that no longer sweeps*' }).Count)

  ''
  'the label gap, which is the report this one was made to match'

  Check 'the OPEN issue missing a label is named and counted out of the open ones' (Join-Lines @(
    '  #3    missing label: type         Read the install order from one file',
    '1 of 3 OPEN issues are missing a type or an area label, listed above')) `
    ((@($out | Where-Object { $_ -like '  #3 *' -or $_ -like '*OPEN issues are missing*' })) -join '|')

  Check 'the CLOSED one is counted out of the closed ones' `
    '1 of 2 closed issues are missing one too, and are not listed -' `
    ((@($out | Where-Object { $_ -like '*closed issues are missing*' })) -join '|')

  ''
  'the card GitHub stamped a status onto as it was added'

  Check 'is listed with the column it landed in, not with its number alone' (Join-Lines @(
    '1 of the 5 cards on the board were NOT on it before this run.',
    'GitHub stamped each one with a status as it was added - it is the first word of every',
    'line below. Move whatever does not belong there:',
    '  todo            -   example                #5    Name the tickets that carry no priority')) `
    (Get-Block $out '1 of the 5 cards on the board were NOT on it before this run.' 3)

  ''
  'the board is read once for both reports'

  Check 'twice in all - before the sweep and after it, never a third time' 2 `
    ([int](Get-Content (Join-Path $fake 'reads') -Raw))

  ''
  'the innocent cards'

  Check 'a card that carries a priority and both labels appears nowhere' 0 `
    (@($out | Where-Object {
        $_ -like '*Add the job-completion endpoint*' -or $_ -like '*Take a label off an issue*' }).Count)

  # THE INNOCENT BOARD. Nothing missing anywhere: every card carries a priority, every issue
  # carries both labels, and nothing was added. The run must still say what it looked at, or a
  # board with no gaps could not be told from a board that was never read.
  ''
  'a board and a repository with nothing missing'

  $nothingMissing = Board @(
    (Card 1 'Add the job-completion endpoint' 'OPEN' 'todo' 'P1'),
    (Card 2 'Rename the sweep that no longer sweeps' 'CLOSED' 'done' 'P3'),
    (Card 3 'Read the install order from one file' 'OPEN' 'todo' 'P2'),
    (Card 4 'Take a label off an issue' 'CLOSED' 'done' 'P2'),
    (Card 5 'Name the tickets that carry no priority' 'OPEN' 'todo' 'P1'))
  Set-Content -Encoding utf8NoBOM -Path (Join-Path $fake 'board-1.json') -Value $nothingMissing
  Set-Content -Encoding utf8NoBOM -Path (Join-Path $fake 'board-2.json') -Value $nothingMissing
  Set-Content -Encoding utf8NoBOM -Path (Join-Path $fake 'issues.json') -Value (Issues @(
    (Issue 1 'OPEN'   'Add the job-completion endpoint'          @('type:feature', 'area:tooling')),
    (Issue 2 'CLOSED' 'Rename the sweep that no longer sweeps'   @('type:chore', 'area:tooling')),
    (Issue 3 'OPEN'   'Read the install order from one file'     @('type:feature', 'area:tooling')),
    (Issue 4 'CLOSED' 'Take a label off an issue'                @('type:feature', 'area:tooling')),
    (Issue 5 'OPEN'   'Name the tickets that carry no priority'  @('type:bug', 'area:tooling'))))

  $clean = Invoke-Sweep
  Check 'reports nothing missing, and still says what it read' (Join-Lines @(
    'example-org/example',
    '',
    '0 of 3 OPEN issues are missing a type or an area label, listed above',
    '0 of 2 closed issues are missing one too, and are not listed -',
    "  labelling somebody else's finished ticket is a guess, and nothing on the board filters on it",
    '',
    '0 of 3 OPEN cards carry no priority',
    '0 of 2 closed cards carry none either, and are not listed -',
    '  a priority put on a finished ticket by somebody who did not work it is a guess')) (Join-Lines $clean)

  Check 'and prints no list header above nothing' 0 `
    (@($clean | Where-Object { $_ -eq 'OPEN cards on the board that carry no priority:' }).Count)
}
finally {
  Remove-Item -Recurse -Force $fake, $cache -EA SilentlyContinue
}

if ($failed -gt 0) { ''; "$failed failed"; exit 1 }
''; 'all passed'
