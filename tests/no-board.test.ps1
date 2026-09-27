# The PowerShell twin of no-board.test.sh: -NoBoard files an issue in a repository that is linked
# to no open board and touches no board, and it is refused everywhere it would keep work off a
# board that exists.
#
#   pwsh -File tests/no-board.test.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fake = Join-Path ([IO.Path]::GetTempPath()) "gh-fake-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$env:GH_CACHE_DIRECTORY = Join-Path $fake 'cache'
New-Item -ItemType Directory -Path $fake | Out-Null
$log = Join-Path $fake 'calls.txt'

# A fake gh that writes down every call. The repository in the request decides whether it is
# linked: example-harness answers no open project, every other repository answers one.
@"
`$a = `$args -join ' '
Add-Content -Path '$log' -Value `$a
if (`$a -match 'n=example-harness.*projectsV2') { exit 0 }
if (`$a -match 'projectsV2') { "9``tBoard Nine"; exit 0 }
if (`$a -match 'issue create') { 'https://github.com/example-org/example-harness/issues/999'; exit 0 }
if (`$a -match 'projectItems') { exit 0 }
if (`$a -match 'addProjectV2ItemById') { 'PVTI_new'; exit 0 }
'{}'
exit 0
"@ | Set-Content -Path (Join-Path $fake 'gh.ps1') -Encoding utf8NoBOM
"@echo off`r`npwsh -NoProfile -File `"$fake\gh.ps1`" %*" |
  Set-Content -Path (Join-Path $fake 'gh.cmd') -Encoding ascii
if (-not $IsWindows) { Set-Content -Path (Join-Path $fake 'gh') -Value "#!/bin/sh`nexec pwsh -NoProfile -File `"$fake/gh.ps1`" `"`$@`"" -Encoding ascii; & chmod +x (Join-Path $fake 'gh') }
$env:PATH = "$fake$([IO.Path]::PathSeparator)$env:PATH"

$failed = 0
function Check($name, $expected, $actual) {
  if ("$expected" -eq "$actual") { Write-Host "  ok   $name" }
  else { Write-Host "  FAIL $name`n       expected: $expected`n       actual:   $actual"; $script:failed++ }
}
function Called([string]$pattern) { [bool]((@(Get-Content $log -ErrorAction SilentlyContinue)) -match $pattern) }

$issueNew = Join-Path $root 'bin/issue-new.ps1'
$body = Join-Path $fake 'body.md'
'the body' | Set-Content $body -Encoding utf8NoBOM
$harness = 'example-org/example-harness'; $linked = 'example-org/example-repo'

function New-Issue([string]$repo, [hashtable]$extra) {
  Remove-Item $log -ErrorAction SilentlyContinue
  $p = @{
    Repo = $repo; Title = 'Put every new issue on its board, or nobody reading the board sees it'
    BodyFile = $body; Label = @('type:feature', 'area:tooling'); AskedBy = 'kartalbas'; AskedIn = 'the test'
  }
  foreach ($k in $extra.Keys) { $p[$k] = $extra[$k] }
  $script:said = ''
  try { $script:said = (& $issueNew @p 6>&1 | Out-String); return $true } catch { $script:said = $_.Exception.Message; return $false }
}

Write-Host 'a repository on no board: the issue is filed, and no board is touched'
$ran = New-Issue $harness @{ NoBoard = $true }
Check 'filed'                     'True' ([string]$ran)
Check 'the issue is created'      'True' (Called 'issue create')
Check 'no card is added'          'False' (Called 'addProjectV2ItemById')
Check 'no field is written'       'False' (Called 'updateProjectV2ItemFieldValue')
Check 'it says so'                'True' ([bool]($said -match '(?m)^#999 -> on no board: example-org/example-harness is linked to none\r?$'))

Write-Host 'a repository that IS on a board: refused, nothing filed'
$ran = New-Issue $linked @{ NoBoard = $true }
Check 'refused'                   'False' ([string]$ran)
Check 'nothing filed'             'False' (Called 'issue create')
Check 'it says why'               'True' ([bool]($said -match 'is linked to an open project, so -NoBoard would keep this issue off a board that exists'))

Write-Host 'a field of the board or the board itself, named with the flag: refused'
foreach ($extra in @(@{ Priority = 'P2' }, @{ Status = 'todo' }, @{ Project = '9' })) {
  $name = @($extra.Keys)[0]
  $extra.NoBoard = $true
  $ran = New-Issue $harness $extra
  Check "with -${name}: refused"                  'False' ([string]$ran)
  Check "with -${name}: nothing filed"            'False' (Called 'issue create')
  Check "with -${name}: it says they contradict"  'True' ([bool]($said -match 'contradict each other'))
}

Write-Host 'the flag does not relax the two labels'
$ran = New-Issue $harness @{ NoBoard = $true; Label = @('area:tooling') }
Check 'refused'                   'False' ([string]$ran)
Check 'it names the labels'       'True' ([bool]($said -match 'at least two labels are required'))

Write-Host 'without the flag, a repository on no board is still refused'
$ran = New-Issue $harness @{ Priority = 'P2' }
Check 'refused'                   'False' ([string]$ran)
Check 'nothing filed'             'False' (Called 'issue create')

Remove-Item -Recurse -Force $fake -ErrorAction SilentlyContinue
if ($failed -gt 0) { Write-Host "`n$failed failed"; exit 1 }
Write-Host "`nall passed"
exit 0
