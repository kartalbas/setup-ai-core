# The PowerShell twin of incident-count.test.sh, asserting the SAME table against the SAME
# issues. The ISO week is where the two shells could drift - .NET and GNU date derive it
# differently at the turn of the year - so both count the same tickets into the same columns.
#
#   pwsh -File test/incident-count.test.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fake = Join-Path ([IO.Path]::GetTempPath()) "incident-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$env:GH_CACHE_DIRECTORY = Join-Path $fake 'cache'
New-Item -ItemType Directory -Path $fake | Out-Null
$log = Join-Path $fake 'calls.txt'

function IsoWeek([datetime]$When) {
  $utc = $When.ToUniversalTime()
  '{0}-W{1:d2}' -f [System.Globalization.ISOWeek]::GetYear($utc), [System.Globalization.ISOWeek]::GetWeekOfYear($utc)
}
$now = [datetime]::UtcNow
$thisWeek = IsoWeek $now
$lastWeek = IsoWeek $now.AddDays(-7)
$nowStamp = $now.ToString('yyyy-MM-ddTHH:mm:ssZ')
$weekBack = $now.AddDays(-7).ToString('yyyy-MM-ddTHH:mm:ssZ')
$longAgo  = $now.AddDays(-400).ToString('yyyy-MM-ddTHH:mm:ssZ')

# Two open boards plus a template board that tracks no work. The numbers are ones no real board
# carries, so the ids this test invents land in cache directories of their own.
#
# THE ID QUERY IS MATCHED BEFORE THE BOARD LIST. Its own text names organization(login:) as well,
# so an arm matching that first would answer the id query with a list of boards - and the run
# would stop on a project id that is a table.
@"
`$a = (`$args -join ' ') -replace '\r?\n', ' '
Add-Content -Path '$log' -Value `$a
if (`$a -match 'issue list') {
  '[ { "createdAt": "$nowStamp", "labels": [ { "name": "incident:title" }, { "name": "area:tooling" } ] },'
  '  { "createdAt": "$nowStamp", "labels": [ { "name": "incident:title" } ] },'
  '  { "createdAt": "$weekBack", "labels": [ { "name": "incident:context" } ] },'
  '  { "createdAt": "$longAgo",  "labels": [ { "name": "incident:title" } ] },'
  '  { "createdAt": "$nowStamp", "labels": [ { "name": "type:feature" }, { "name": "area:tooling" } ] } ]'
  exit 0
}
if (`$a -match 'projectV2\(number:')     { 'PVT_kwincident'; exit 0 }
if (`$a -match 'projectsV2\(first:100\)') {
  '996' + [char]9 + 'beta'
  '997' + [char]9 + 'alpha'
  '999' + [char]9 + '[TEMPLATE] the shape'
  exit 0
}
if (`$a -match 'repositories') { 'example-org/example-repo'; exit 0 }
'example-org/example-repo'
exit 0
"@ | Set-Content -Path (Join-Path $fake 'gh.ps1') -Encoding utf8NoBOM
"@echo off`r`npwsh -NoProfile -File `"$fake\gh.ps1`" %*" |
  Set-Content -Path (Join-Path $fake 'gh.cmd') -Encoding ascii
$env:PATH = "$fake;$env:PATH"

$failed = 0
function Check($name, $expected, $actual) {
  if ("$expected" -eq "$actual") { Write-Host "  ok   $name" }
  else { Write-Host "  FAIL $name`n       expected: $expected`n       actual:   $actual"; $script:failed++ }
}

$count = Join-Path $root 'bin/incident-count.ps1'
$repo = 'example-org/example-repo'
function Calls { @(Get-Content $log -ErrorAction SilentlyContinue) }
function Clear-Log { Remove-Item $log -ErrorAction SilentlyContinue }
function Matching($pattern) { @((Calls) | Where-Object { $_ -match $pattern }).Count }
function Row($rows, $label) { @($rows | Where-Object { $_ -match "^$([regex]::Escape($label)) " })[0] }
function Cells($row) { @(($row -split '\s+') | Where-Object { $_ -ne '' }) }

Write-Host 'a named repo is read once, and nothing is written'
Clear-Log
$out = @(& $count -Repo $repo)
Check 'one issue list'      1 (Matching ([regex]::Escape("issue list --repo $repo")))
Check 'the state is all'    1 (Matching '--state all')
Check 'nothing was written' 0 (Matching 'method (POST|PATCH|PUT|DELETE)|mutation|label create|issue edit')
Check 'no board was asked'  0 (Matching 'projectsV2\(first:100\)')

Write-Host 'the table has a row per incident label and a column per week'
Check 'header names the weeks'     'True' ([bool]($out[0] -match "$lastWeek.*$thisWeek"))
Check 'eight columns by default'   8 ((Cells $out[0]).Count - 1)
Check 'six rows, one per label'    6 ($out.Count - 1)
Check 'every incident label named' 'True' ([string](
  @('duplicate','context','question','title','released-wrong','unasked') |
    ForEach-Object { [bool](Row $out "incident:$_") } | Where-Object { -not $_ } | Measure-Object).Count.Equals(0))

Write-Host 'the counts land in the right week'
$title = Cells (Row $out 'incident:title')
$context = Cells (Row $out 'incident:context')
$question = Cells (Row $out 'incident:question')
Check 'two incident:title this week'   '2' $title[-1]
Check 'one incident:context last week' '1' $context[-2]
Check 'incident:question has none'     0 (($question[1..($question.Count - 1)] | Measure-Object -Sum).Sum)
Check 'the ticket from last year is outside the window' 0 `
  (($title[1..($title.Count - 2)] | Measure-Object -Sum).Sum)

Write-Host 'a label that is not an incident is not counted'
Check 'no type row' 'False' ([bool]($out -match '^type:'))

# How well the tickets themselves are written is a question about the organisation and not
# about one board, and an answer covering half of it reads as an answer covering all of it.
Write-Host 'with no repository named it reads every open board, and not the template'
Clear-Log
$out = @(& $count)
Check 'the boards were asked'  1 (Matching 'projectsV2\(first:100\)')
Check 'the first was resolved' 1 (Matching 'num=996')
Check 'the second too'         1 (Matching 'num=997')
Check 'the template was not'   0 (Matching 'num=999')

Write-Host '-Weeks changes the window'
$out = @(& $count -Repo $repo -Weeks 3)
Check 'three columns' 3 ((Cells $out[0]).Count - 1)

Write-Host 'a window below one is refused'
$said = ''
try { & $count -Repo $repo -Weeks 0 | Out-Null } catch { $said = $_.Exception.Message }
Check 'says so' 'True' ([bool]($said -match '-Weeks must be at least 1'))

Remove-Item -Recurse -Force $fake -ErrorAction SilentlyContinue
if ($failed -gt 0) { Write-Host "`n$failed failed"; exit 1 }
Write-Host "`nall passed"
