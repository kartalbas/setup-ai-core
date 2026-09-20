<#
The PowerShell twin of repo-boards.test.sh, asserting the SAME rules against
bin/repo-boards.ps1.

    pwsh -NoProfile -File test/repo-boards.test.ps1

NOTHING REACHES github.com. A stand-in `gh` is on PATH for the whole run and answers a
prepared organisation, so every case below is a shape somebody would otherwise have to
create real repositories to produce - a closed board, a template board, two boards on one
repository, a second page.

THE CLASS THIS HOLDS CLOSED. An issue filed in a repository that is linked to no board is
on no board, and it stays invisible until somebody remembers it exists. Nothing else in
bin/ can report that: every other path starts from a repository and asks which board it
resolves to, so a repository that resolves to none stops that one call and is never
counted, and board-sync sweeps "every repo linked to the project", which by construction
cannot reach a repository linked to no project.

WHAT COUNTS AS A LINK is the same rule Resolve-ProjectForRepo applies to one repository,
and each half of it is planted here: a CLOSED project is not a link, because a repository
keeps its old boards after they are closed; the TEMPLATE board is not a link, because it
is a shape to copy and no work is tracked on it. Read either as a link and the report says
a repository is covered when nothing sweeps it.

THE PLANTED INNOCENT CASE is an organisation where every repository resolves to exactly
one open board: it must pass, or every red above could equally be a script that refuses
whatever it is handed.

THE SECOND PAGE is planted too. The organisation is read a page at a time, and a script
that took the first page only would report an organisation that is entirely linked while
the repository nobody linked sits on page two.
#>

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fake = Join-Path ([IO.Path]::GetTempPath()) "repo-boards-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$ghDir = Join-Path $fake 'gh'
New-Item -ItemType Directory -Path $ghDir -Force | Out-Null
$failed = 0

# The stand-in answers one prepared page per call, so a run that reads a second page gets
# the second file and a run that stops after the first never sees it.
@"
`$ErrorActionPreference = 'Stop'
`$counter = Join-Path '$fake' 'n'
`$n = if (Test-Path `$counter) { [int](Get-Content `$counter -Raw) } else { 0 }
`$n++
Set-Content -Path `$counter -Value `$n -NoNewline
Get-Content -Raw (Join-Path '$fake' "page-`$n.json")
exit 0
"@ | Set-Content -Path (Join-Path $ghDir 'gh.ps1') -Encoding utf8NoBOM
$env:PATH = "$ghDir;$env:PATH"

function Check($name, $expected, $actual) {
  if ("$expected" -eq "$actual") { Write-Host "  ok   $name" }
  else { Write-Host "  FAIL $name`n       expected: $expected`n       actual:   $actual"; $script:failed++ }
}

# One repository node. The board list is written out by the caller as JSON.
function Node($name, $archived, $boards) {
  '{"nameWithOwner":"example-org/' + $name + '","isArchived":' + $archived +
  ',"projectsV2":{"nodes":[' + $boards + ']}}'
}
function Board($number, $title, $closed) {
  '{"number":' + $number + ',"title":"' + $title + '","closed":' + $closed + '}'
}
function Page($more, [string[]]$nodes) {
  '{"data":{"organization":{"repositories":{"pageInfo":{"hasNextPage":' + $more +
  ',"endCursor":"CUR"},"nodes":[' + ($nodes -join ',') + ']}}}}'
}
function Set-Pages([string[]]$pages) {
  Remove-Item (Join-Path $fake 'n') -Force -EA SilentlyContinue
  for ($i = 0; $i -lt $pages.Count; $i++) {
    Set-Content -Path (Join-Path $fake "page-$($i + 1).json") -Value $pages[$i] -Encoding utf8NoBOM
  }
}

# Runs the sweep against the prepared pages and appends "exit=N", so both halves of the
# answer are asserted from one string.
function Sweep {
  Remove-Item (Join-Path $fake 'n') -Force -EA SilentlyContinue
  $out = & pwsh -NoProfile -File (Join-Path $root 'bin/repo-boards.ps1') 2>&1
  @($out) + @("exit=$LASTEXITCODE")
}

# The verdict line, which is what a caller acts on. Matched WITH case, the way the Bash
# twin's grep matches it: the per-repository line shouts LINKED TO NO OPEN BOARD, and a
# case-blind match would pull it in beside the summary and assert two lines as one.
function Verdict { (Sweep | Where-Object { $_ -cmatch 'linked to no open board|^exit=' }) -join ' ' }

$oneLinked = Node 'one' 'false' (Board 6 'beta' 'false')

try {
  'a repository linked to no open board'

  Set-Pages @((Page 'false' @($oneLinked, (Node 'lost' 'false' ''))))
  Check 'is named' 'yes' `
        $(if ((Sweep) -match 'example-org/lost\s+LINKED TO NO OPEN BOARD') { 'yes' } else { 'no' })
  Check 'is counted, and the run is red' '1 linked to no open board, 0 linked to more than one exit=1' (Verdict)

  ''
  'what does not count as a link'

  Set-Pages @((Page 'false' @($oneLinked, (Node 'closed_only' 'false' (Board 5 'the old board' 'true')))))
  Check 'a CLOSED project is not a link' '1 linked to no open board, 0 linked to more than one exit=1' (Verdict)

  Set-Pages @((Page 'false' @($oneLinked, (Node 'template_only' 'false' (Board 9 '[TEMPLATE] shape to copy' 'false')))))
  Check 'the TEMPLATE board is not a link' '1 linked to no open board, 0 linked to more than one exit=1' (Verdict)

  ''
  'a repository linked to more than one open board'

  Set-Pages @((Page 'false' @($oneLinked,
    (Node 'both' 'false' ((Board 6 'beta' 'false') + ',' + (Board 7 'alpha' 'false'))))))
  Check 'is named with both boards' 'yes' `
        $(if ((Sweep) -match 'example-org/both\s+LINKED TO 2 BOARDS: 6 beta, 7 alpha') { 'yes' } else { 'no' })
  Check 'and the run is red' 'exit=1' (@(Sweep)[-1])

  ''
  'an archived repository'

  Set-Pages @((Page 'false' @($oneLinked, (Node 'dead' 'true' ''))))
  Check 'is listed and left out of the count' '1 repositories read, 1 archived and left out of the count' `
        ((Sweep | Where-Object { $_ -match 'repositories read' }) -join ' ')
  Check 'and does not make the run red' 'exit=0' (@(Sweep)[-1])

  ''
  'the second page'

  Set-Pages @((Page 'true' @($oneLinked)), (Page 'false' @((Node 'lost' 'false' ''))))
  Check 'is read, and what is on it is counted' '1 linked to no open board, 0 linked to more than one exit=1' (Verdict)

  # THE INNOCENT CASE. Every repository on exactly one open board, and one of them ALSO
  # carrying a closed board and a template board - which must not turn into a second link
  # and make it ambiguous.
  ''
  'an organisation where every repository resolves to exactly one board'

  Set-Pages @((Page 'false' @($oneLinked,
    (Node 'two' 'false' ((Board 7 'alpha' 'false') + ',' + (Board 5 'the old board' 'true') + ',' +
                         (Board 9 '[TEMPLATE] shape to copy' 'false'))))))
  Check 'passes' '0 linked to no open board, 0 linked to more than one' `
        ((Sweep | Where-Object { $_ -match 'linked to no open board' }) -join ' ')
  Check 'and the run is green' 'exit=0' (@(Sweep)[-1])
  Check 'and the one with three boards resolves to its open one' 'yes' `
        $(if ((Sweep) -match 'example-org/two\s+7 alpha') { 'yes' } else { 'no' })
}
finally { Remove-Item -Recurse -Force $fake -EA SilentlyContinue }

if ($failed -gt 0) { ''; "$failed failed"; exit 1 }
''; 'all passed'
