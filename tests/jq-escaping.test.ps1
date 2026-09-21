# What reaches gh, and what an archived card survives. The PowerShell twin of
# jq-escaping.test.sh, asserting the SAME rules against the same lib.
#
#   pwsh -File test/jq-escaping.test.ps1
#
# Nothing is written to a real board: `gh` is a stand-in on PATH. It records every call,
# and for a graphql read it runs the REAL jq over a canned payload with the jq program it
# was handed - so a program that arrives mangled fails here exactly as it fails against
# github.com, with jq's own compile error.
#
# TWO WAYS A QUERY COMES BACK WITHOUT ROWS, and the stand-in reproduces both. Each was measured
# against github.com with gh 2.98.0, and they need different guards because they look nothing alike.
#
#   FAKE_GH_REFUSE      the server REFUSES. The FULL error body goes to STDOUT, where the rows would
#                       be, the one-line complaint goes to stderr, and gh exits 1. The --jq program
#                       is not run at all, so nothing filters the body out.
#   FAKE_GH_WRONG_KIND  the server ACCEPTS and answers `{}` with exit 0, which is what a query for a
#                       board's id gets when the id it names belongs to a repository instead. No
#                       status check can tell that from an answer; only the value can.
#
# The innocent case above them is what says a clean answer means the callers looked, rather than
# that nothing was looking.
#
# THE `gh: ...` LINES IN THE REFUSAL SECTION BELONG THERE. They are the stand-in's stderr, and a
# console handle is where a native command writes it, so nothing in this file can capture it. Seeing
# them is the point: the complaint naming the refused query reaches the screen instead of a redirect.
#
# The payloads carry a double quote, a backslash, a dollar sign and three non-ASCII
# characters in the title, because that is what a board title, an issue title and a label
# are allowed to contain, because every jq program in this repository is built out of
# double-quoted strings, and because what gh writes back is UTF-8 whatever the console
# code page says.
#
# WHAT THIS DOES NOT REACH: a tab or a newline INSIDE one of those values. Every jq program
# here packs its fields into one tab-separated line, so a value carrying either separator
# splits the row and the reader downstream mis-reads it. Nothing on the board carries one
# today, and whether GitHub accepts one in a title cannot be established without writing to
# GitHub, so the row format is left as it is and this is stated rather than covered.
#
# The last section drops the stand-in and points `gh` at the real jq binary, which does
# nothing but print the argument vector it was started with. That is the only way to read
# back what a PROCESS receives, and the stand-in cannot do it: PowerShell runs a `gh.ps1`
# found on PATH inside this very process. The newline lives there, on the way OUT, where an
# argument is one string and no line separates anything.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fake = Join-Path ([IO.Path]::GetTempPath()) "gh-jq-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$env:GH_CACHE_DIRECTORY = Join-Path $fake 'cache'
$ghDir = Join-Path $fake 'gh'
New-Item -ItemType Directory -Path $ghDir -Force | Out-Null

# A board number no real project carries, so the cache this writes cannot be mistaken for
# a live board's - and is removed again below.
$projectNumber = 999999

$failed = 0

# A MISMATCH IS ALSO PRINTED AS CODE POINTS, because the two lines above it can read as the
# opposite of the truth. When this console is not on UTF-8, a correct character is written out
# as a byte the terminal cannot show and a mangled one is written out as the bytes it was
# mangled from - so the wrong value is the one that looks right. The numbers cannot do that.
function Points($s) { (([int[]][char[]]"$s") -join ',') }

function Check($name, $expected, $actual) {
  if ($expected -ceq $actual) { Write-Host "  ok   $name"; return }
  $points = if ("$expected$actual" -match '[^\x00-\x7f]') {
    "`n       expected code points: $(Points $expected)`n       actual   code points: $(Points $actual)"
  } else { '' }
  Write-Host "  FAIL $name`n       expected: $expected`n       actual:   $actual$points"
  $script:failed++
}

# The characters a title is allowed to carry and a jq program is built out of. The JSON
# form is derived from the same string rather than typed twice, so the payloads below and
# the expected values cannot drift apart.
#
# The three non-ASCII characters are written as code points so this file stays plain ASCII
# and the assertion cannot turn on how an editor or git stored it. U+00B7 is the middle dot
# the epic titles on this board are written with, U+00FC an umlaut, U+20AC a euro sign -
# one, two and three UTF-8 bytes, so a decoder reading the wrong code page is wrong
# differently for each of them.
$nonAscii  = "$([char]0x00B7) $([char]0x00FC) $([char]0x20AC)"
$nasty     = "a `"quoted`" title with \ and `$dollar $nonAscii"
$nastyJson = $nasty | ConvertTo-Json

try {
  # --- the canned answers -----------------------------------------------------

  @"
{"data":{"repository":{"projectsV2":{"nodes":[
  {"number":$projectNumber,"title":$nastyJson,"closed":false},
  {"number":12,"title":"[TEMPLATE] shape","closed":false},
  {"number":3,"title":"an old board","closed":true}]}}}}
"@ | Set-Content (Join-Path $ghDir 'repo-projects.json') -Encoding utf8NoBOM

  '{"data":{"organization":{"projectV2":{"id":"PVT_kwtestboard"}}}}' |
    Set-Content (Join-Path $ghDir 'project-id.json') -Encoding utf8NoBOM

  # Three items on three different boards and two different archive states. Only the one
  # that is archived AND on this board may come back.
  @'
{"data":{"repository":{"issue":{"projectItems":{"nodes":[
  {"id":"PVTI_otherboard","isArchived":true,"project":{"id":"PVT_kwotherboard"}},
  {"id":"PVTI_archived","isArchived":true,"project":{"id":"PVT_kwtestboard"}},
  {"id":"PVTI_live","isArchived":false,"project":{"id":"PVT_kwtestboard"}}]}}}}}
'@ | Set-Content (Join-Path $ghDir 'archived.json') -Encoding utf8NoBOM

  '{"data":{"repository":{"issue":{"projectItems":{"nodes":[]}}}}}' |
    Set-Content (Join-Path $ghDir 'no-archived.json') -Encoding utf8NoBOM

  '{"data":{"addProjectV2ItemById":{"item":{"id":"PVTI_added"}}}}' |
    Set-Content (Join-Path $ghDir 'added.json') -Encoding utf8NoBOM

  '{"node_id":"I_kwissue","id":8008}' |
    Set-Content (Join-Path $ghDir 'issue.json') -Encoding utf8NoBOM

  # What a refused query answers with, copied from what github.com answered gh 2.98.0 for a node id
  # it could not resolve. It is a whole JSON document on the channel the rows come back on, and its
  # first field is not a row.
  '{"data":{"node":null},"errors":[{"type":"NOT_FOUND","path":["node"],"locations":[{"line":1,"column":19}],"message":"Could not resolve to a node with the global id of ''PVT_kwtestboard''"}]}' |
    Set-Content (Join-Path $ghDir 'refused.json') -Encoding utf8NoBOM

  @"
{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"fieldValues":{"nodes":[
     {"name":"Todo","field":{"name":"Status"}},
     {"name":"P1","field":{"name":"Priority"}}]},
   "content":{"number":7,"title":$nastyJson,"state":"OPEN","repository":{"name":"example-repo"}}},
  {"fieldValues":{"nodes":[]},
   "content":{"number":8,"title":"plain","state":"CLOSED","repository":{"name":"example-repo"}}}]}}}}
"@ | Set-Content (Join-Path $ghDir 'items.json') -Encoding utf8NoBOM

  # --- the stand-in -----------------------------------------------------------

  @"
`$ErrorActionPreference = 'Stop'
`$d = '$ghDir'
`$a = `$args
Add-Content -Path (Join-Path `$d 'calls') -Value (`$a -join ' ')

# Both answers-without-rows come before anything is parsed: the real ones are decided by the
# server and reach every query alike, whatever it asked for.
if (`$env:FAKE_GH_REFUSE) {
  Get-Content (Join-Path `$d 'refused.json')
  [Console]::Error.WriteLine("gh: `$(`$env:FAKE_GH_REFUSE)")
  exit 1
}
if (`$env:FAKE_GH_WRONG_KIND) { '{}'; exit 0 }

`$prog = `$null; `$query = ''; `$num = ''; `$rest = ''
for (`$i = 0; `$i -lt `$a.Count; `$i++) {
  if (`$a[`$i] -eq '--jq' -and `$i + 1 -lt `$a.Count) { `$prog = `$a[`$i + 1] }
  if (`$a[`$i] -like 'query=*')          { `$query = `$a[`$i].Substring(6) }
  if (`$a[`$i] -like 'num=*')            { `$num   = `$a[`$i].Substring(4) }
  if (`$a[`$i] -like 'repos/*/issues/*') { `$rest  = `$a[`$i] }
}

`$payload = switch -Wildcard (`$query) {
  '*addProjectV2ItemById*'  { 'added.json'; break }
  '*projectItems*'          { if (`$num -eq '8') { 'no-archived.json' } else { 'archived.json' }; break }
  '*projectsV2(first:50)*'  { 'repo-projects.json'; break }
  '*projectV2(number:*'     { 'project-id.json'; break }
  '*items(first:100*'       { 'items.json'; break }
  default                   { if (`$rest) { 'issue.json' } else { `$null } }
}
if (-not `$payload) {
  [Console]::Error.WriteLine("fake gh: nothing canned for: `$(`$a -join ' ')")
  exit 64
}

# The program goes through a FILE, so this hop adds no escaping of its own and what jq
# compiles is exactly the bytes gh was handed.
#
# gh writes LF on Windows and the jq binary writes CRLF, so the CR is dropped here. A
# stand-in that answered differently from the real command would put the callers' line
# handling under test instead of their escaping.
if (`$prog) {
  `$pf = Join-Path `$d 'prog.jq'
  Set-Content -Path `$pf -Value `$prog -NoNewline -Encoding utf8NoBOM
  (& jq -r -f `$pf (Join-Path `$d `$payload)) | ForEach-Object { `$_ -replace "``r", '' }
  exit `$LASTEXITCODE
}
Get-Content (Join-Path `$d `$payload)
exit 0
"@ | Set-Content -Path (Join-Path $ghDir 'gh.ps1') -Encoding utf8NoBOM

  # THE STAND-IN RUNS IN THE CALLER'S OWN PROCESS, AND THE REAL jq BINARY INSIDE IT DOES NOT.
  #
  # PowerShell resolves a bare `gh` to a `gh.ps1` on PATH and runs it as a script, in process,
  # so nothing this file writes is encoded and decoded on the way to the stand-in. What the
  # stand-in then does IS a native call: it runs the real jq binary, and jq's answer crosses a
  # process boundary back into this process exactly as gh's would. So the payload above is
  # decoded under whatever encoding the callers set, and the encoding is under test here too.
  #
  # Putting the stand-in behind a .cmd shim to force a second process does not work: a .cmd
  # re-parses %*, and every query here is a multi-line argument, which it splits.

  Import-Module (Join-Path $root 'lib/Board.psm1') -Force

  $calls = Join-Path $ghDir 'calls'
  function Calls { if (Test-Path $calls) { Get-Content $calls -Raw } else { '' } }
  Set-Content -Path $calls -Value '' -NoNewline -Encoding utf8NoBOM

  $env:PATH = "$ghDir$([IO.Path]::PathSeparator)$env:PATH"

  Write-Host 'a title with a quote, a backslash, a dollar and non-ASCII survives the trip'
  Check 'the board is resolved from its repo' "$projectNumber" `
        (Resolve-ProjectForRepo -Repo 'example-org/example-repo')

  Set-Project -Number "$projectNumber" | Out-Null
  Check 'the project id is read back' 'PVT_kwtestboard' (Get-ProjectId)

  Write-Host 'an archived card is found from the issue, and stays archived'
  Check 'the archived item on THIS board' 'PVTI_archived' `
        (Get-ArchivedItemId -Repo 'example-org/example-repo' -Number 7)

  Set-Content -Path $calls -Value '' -NoNewline -Encoding utf8NoBOM
  Check 'Get-ItemId hands the archived id back' 'PVTI_archived' `
        (Get-ItemId 'example-org/example-repo' 7)
  Check 'and adds nothing' 'no add' $(if ((Calls) -match 'addProjectV2ItemById') { 'added' } else { 'no add' })

  Set-Content -Path $calls -Value '' -NoNewline -Encoding utf8NoBOM
  Check 'an issue with no item is still added' 'PVTI_added' `
        (Get-ItemId 'example-org/example-repo' 8)
  Check 'by the add mutation' 'added' $(if ((Calls) -match 'addProjectV2ItemById') { 'added' } else { 'nothing was added' })

  Write-Host 'and the board reads back with the title intact'
  $rows = @(& (Join-Path $root 'bin/board-list.ps1') -Project $projectNumber) |
            ForEach-Object { $_ -replace ' +', ' ' }
  Check 'an open card keeps its status, priority and title' `
        "Todo P1 example-repo #7 $nasty" `
        (@($rows | Where-Object { $_ -like '*#7 *' }) -join '')
  Check 'a card with no field values reads as - -, and closed says so' `
        '- - example-repo #8 plain [closed]' `
        (@($rows | Where-Object { $_ -like '*#8 *' }) -join '')

  Write-Host 'a refused query is not an empty result'
  $env:FAKE_GH_REFUSE = "Could not resolve to a node with the global id of 'PVT_kwtestboard'"

  Set-Content -Path $calls -Value '' -NoNewline -Encoding utf8NoBOM
  $stopped = 'no'; $item = $null
  try { $item = Get-ArchivedItemId -Repo 'example-org/example-repo' -Number 7 } catch { $stopped = 'yes' }
  Check 'Get-ArchivedItemId stops' 'yes' $stopped
  Check 'and hands back no item id' 'yes' $(if ("$item" -match 'PVTI_') { 'no' } else { 'yes' })

  # THE ONE THAT COSTS A CARD. A refusal read as "this issue has no archived item" is not a wrong
  # line on a screen: the next call takes the card OUT of the archive, which is the owner's decision
  # and nothing else's. So what is asserted is that the mutation was never reached.
  Set-Content -Path $calls -Value '' -NoNewline -Encoding utf8NoBOM
  $stopped = 'no'; $id = $null
  try { $id = Get-ItemId 'example-org/example-repo' 7 } catch { $stopped = 'yes' }
  Check 'Get-ItemId stops rather than adding' 'yes' $stopped
  Check 'and nothing reached the board' 'no add' $(if ((Calls) -match 'addProjectV2ItemById') { 'added' } else { 'no add' })
  Check 'and no item id is handed back' 'yes' $(if ("$id" -match 'PVTI_') { 'no' } else { 'yes' })

  $stopped = 'no'; $refusedRows = @()
  try { $refusedRows = @(& (Join-Path $root 'bin/board-list.ps1') -Project $projectNumber) } catch { $stopped = 'yes' }
  Check 'board-list stops' 'yes' $stopped
  Check 'and prints no card' 0 $refusedRows.Count

  $env:FAKE_GH_REFUSE = $null

  Write-Host 'a query gh accepts, answering with something that is not a board'
  $cache = Join-Path $env:GH_CACHE_DIRECTORY "$projectNumber"

  $env:FAKE_GH_WRONG_KIND = '1'
  Remove-Item $cache -Recurse -Force -ErrorAction SilentlyContinue
  $stopped = 'no'; $boardId = $null
  try { $boardId = Get-ProjectId } catch { $stopped = 'yes' }
  Check 'Get-ProjectId stops' 'yes' $stopped
  Check 'and hands back no id' 'yes' $(if ("$boardId" -match 'PVT_') { 'no' } else { 'yes' })
  # The cache is the answer for every later run, and nothing asks again once it is not empty.
  Check 'and nothing is cached as an answer' 'nothing cached' `
        $(if (Test-Path (Join-Path $cache 'project-id')) { "cached $(Get-Content (Join-Path $cache 'project-id') -Raw)" } else { 'nothing cached' })
  $env:FAKE_GH_WRONG_KIND = $null

  # The same value already sitting in the cache, which is how a machine that ran this tooling before
  # the guard existed is found. Nothing asks gh at all on this path.
  New-Item -ItemType Directory -Force -Path $cache | Out-Null
  Set-Content -Path (Join-Path $cache 'project-id') -Value '{}' -NoNewline -Encoding utf8NoBOM
  $stopped = 'no'; $refusal = ''
  try { Get-ProjectId | Out-Null } catch { $stopped = 'yes'; $refusal = "$_" }
  Check 'a cached non-id stops it too' 'yes' $stopped
  Check 'and names the file holding it' 'yes' $(if ($refusal -like "*project-id*") { 'yes' } else { 'no' })
  Remove-Item $cache -Recurse -Force -ErrorAction SilentlyContinue

  Write-Host 'what the process itself receives'
  # The caller's setting is deliberately the hostile one: Invoke-Gh must not depend on it.
  $PSNativeCommandArgumentPassing = 'Legacy'
  Set-Alias -Name gh -Value (Get-Command jq).Source -Scope Global
  $program = @'
.data.node.items.nodes[]
| select(.content.state == "CLOSED")
| "\(.number)\t\(.title)"
'@
  $title = "He said `"no`" \ path\to `$HOME`nand a second line $nonAscii"
  $seen  = Invoke-Gh -n --args '$ARGS.positional' -- $program $title | ConvertFrom-Json
  Check 'a jq program arrives verbatim' $program ($seen[0] -replace "`r", '')
  Check 'a title arrives verbatim'      $title   ($seen[1] -replace "`r", '')
}
finally {
  Remove-Item alias:gh -ErrorAction SilentlyContinue
  Remove-Item $fake -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failed -gt 0) { Write-Host "`n$failed failed"; exit 1 }
Write-Host "`nall passed"
