# What `issue-new` hands GitHub as the assignee.
#
# Run with a FAKE `gh` on PATH, so nothing is created and the arguments the command
# would have sent are recorded instead. That is the only way to test this: the rule
# is about what reaches `gh issue create`, and the bug it fixes was invisible until
# somebody read an issue afterwards and saw the wrong name on it.
#
# EVERY PLANT GOES INTO A FILE OF THIS RUN'S OWN. The reader takes the map as -Path,
# so nothing here writes the tracked assignees.tsv. A test that planted into the tracked
# file and wrote it back in a finally block would leave two suites in flight restoring
# twice, with the last restore writing whatever it had captured - the other suite's plant.
#
# The half below that runs bin/issue-new.ps1 runs a script that resolves the map for
# itself, which no parameter of this file reaches, so it is read against the TRACKED map.
# That map is empty on purpose, so what it proves is that the reader's own answer is what
# lands on `gh issue create --assignee`: `@me` is produced nowhere but inside the reader.
# Which answer the reader gives for a mapped repository is proven above, against the plant.
#
#   pwsh -File test/assignee.test.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fake = Join-Path ([IO.Path]::GetTempPath()) "gh-fake-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $fake | Out-Null
$log = Join-Path $fake 'calls.txt'
$map = Join-Path $fake 'assignees.tsv'

# The stand-in. It answers the few reads the command makes and records the create.
@"
`$ErrorActionPreference = 'Stop'
`$a = `$args
Add-Content -Path '$log' -Value (`$a -join ' ')
if (`$a[0] -eq 'issue' -and `$a[1] -eq 'create') { 'https://github.com/o/r/issues/123'; exit 0 }
if (`$a[0] -eq 'repo') { 'example-org/mapped-repo'; exit 0 }
if (`$a[0] -eq 'project') { '{"number":5,"id":"PVT_x"}'; exit 0 }
'{}'
exit 0
"@ | Set-Content -Path (Join-Path $fake 'gh.ps1') -Encoding utf8NoBOM

# A .cmd shim so `gh` resolves as a command on Windows.
"@echo off`r`npwsh -NoProfile -File `"$fake\gh.ps1`" %*" |
  Set-Content -Path (Join-Path $fake 'gh.cmd') -Encoding ascii

$failed = 0
function Check($name, $expected, $actual) {
  if ($expected -eq $actual) { Write-Host "  ok   $name" }
  else { Write-Host "  FAIL $name`n       expected: $expected`n       actual:   $actual"; $script:failed++ }
}

Import-Module (Join-Path $root 'lib/Board.psm1') -Force

try {
  "example-org/mapped-repo`tmapped-owner" | Set-Content $map -Encoding utf8NoBOM

  Write-Host 'the map decides the default'
  Check 'a mapped repo'    'mapped-owner' (Get-AssigneeForRepo -Repo 'example-org/mapped-repo' -Path $map)
  Check 'an unmapped repo' '@me'          (Get-AssigneeForRepo -Repo 'example-org/unmapped-repo' -Path $map)

  Write-Host 'a broken map stops before anything is created'
  "example-org/x`tone`tsurplus" | Set-Content $map -Encoding utf8NoBOM
  try { Get-AssigneeForRepo -Repo 'example-org/x' -Path $map; Check 'malformed row' 'threw' 'returned' }
  catch { Check 'malformed row' 'threw' 'threw' }

  "example-org/x`tone`nexample-org/x`ttwo" | Set-Content $map -Encoding utf8NoBOM
  try { Get-AssigneeForRepo -Repo 'example-org/x' -Path $map; Check 'duplicate row' 'threw' 'returned' }
  catch { Check 'duplicate row' 'threw' 'threw' }

  # WHITESPACE AROUND A COLUMN, which is the divergence example-tools#21 measured and #22 closed.
  # `example-org/x<SPACE><TAB>one` answered `one` here, because this reader trimmed six times, and
  # `@me` in the shell twin, which compared the raw field - one invisible space deciding who a new
  # issue lands on. The format is now stated in assignees.tsv's own header and both readers refuse
  # the row by name. The tab cases are the same question one class over: the shell twin's
  # `IFS=$'	' read` collapses a run of tabs and strips a leading one, so it used to see a valid
  # two-column row where this reader saw three columns and refused.
  Write-Host 'whitespace around a column is refused, and the row is named'

  function RefusedRow($line) {
    Set-Content -Path $map -Value $line -Encoding utf8NoBOM
    try { $a = Get-AssigneeForRepo -Repo 'example-org/x' -Path $map; return "answered: $a" }
    catch { return ($_.Exception.Message.Replace($map, 'MAP')) }
  }

  Check 'a space before the tab' `
    "error: MAP:1 has a space at the edge of a column, and the format allows none: 'example-org/x ' 'one'" `
    (RefusedRow "example-org/x `tone")
  Check 'a space after the tab' `
    "error: MAP:1 has a space at the edge of a column, and the format allows none: 'example-org/x' ' one'" `
    (RefusedRow "example-org/x`t one")
  Check 'two tabs' `
    "error: MAP:1 is not 'repo<TAB>login': example-org/x`t`tone" `
    (RefusedRow "example-org/x`t`tone")
  Check 'a leading tab' `
    "error: MAP:1 is not 'repo<TAB>login': `texample-org/x`tone" `
    (RefusedRow "`texample-org/x`tone")
  Check 'an indented comment' `
    "error: MAP:1 is not 'repo<TAB>login':   # example-org/x" `
    (RefusedRow '  # example-org/x')
  Check 'a line of spaces' `
    "error: MAP:1 is not 'repo<TAB>login':   " `
    (RefusedRow '  ')

  Write-Host 'a missing map stops too'
  try { Get-AssigneeForRepo -Repo 'example-org/x' -Path (Join-Path $fake 'nowhere.tsv'); Check 'absent file' 'threw' 'returned' }
  catch { Check 'absent file' 'threw' 'threw' }

  Write-Host 'and what actually reaches gh issue create'
  $env:PATH = "$fake;$env:PATH"
  $body = Join-Path $fake 'body.md'
  'body' | Set-Content $body -Encoding utf8NoBOM

  function AssigneeSentFor($repo, $explicit) {
    Remove-Item $log -ErrorAction SilentlyContinue
    # -Project skips the board lookup. What is under test is the assignee that reaches
    # `gh issue create`, and everything after that call is somebody else's rule.
    $p = @{
      Repo = $repo; Title = 't'; BodyFile = $body
      Label = @('correctness','frontend'); Priority = 'P2'; Project = 5
      AskedBy = 'kartalbas'; AskedIn = 'the test'
    }
    if ($explicit) { $p.Assignee = $explicit }
    try { & (Join-Path $root 'bin/issue-new.ps1') @p *>$null } catch { }
    $create = (Get-Content $log -ErrorAction SilentlyContinue | Where-Object { $_ -match '^issue create' }) | Select-Object -First 1
    if ($create -match '--assignee (\S+)') { return $Matches[1] }
    return '(none)'
  }

  Check 'the reader answers for it'  '@me'     (AssigneeSentFor 'example-org/unmapped-repo' $null)
  Check 'explicit wins over the map' 'someone' (AssigneeSentFor 'example-org/mapped-repo' 'someone')
}
finally {
  Remove-Item $fake -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failed -gt 0) { Write-Host "`n$failed failed"; exit 1 }
Write-Host "`nall passed"
