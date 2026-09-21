# The PowerShell twin of issue-thread.test.sh, asserting the SAME shape and the SAME layout.
# Two implementations of one reader are two chances to drift, and this is what makes the drift
# fail rather than surprise somebody months later.
#
# Run with a FAKE gh on PATH, so the issue and its comments are fixed text and nothing leaves
# the machine.
#
#   pwsh -File test/issue-thread.test.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fake = Join-Path ([IO.Path]::GetTempPath()) "gh-fake-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $fake | Out-Null
$log = Join-Path $fake 'calls.txt'

@"
`$a = `$args -join ' '
Add-Content -Path '$log' -Value `$a
if (`$a -match 'comments') {
  '[ { "user": { "login": "kadir" }, "created_at": "2026-08-20T09:00:00Z", "body": "First read." },'
  '  { "user": { "login": "anton" }, "created_at": "2026-08-21T11:30:00Z", "body": "Second read." } ]'
  exit 0
}
if (`$a -match 'issues/') {
  '{ "number": 163, "title": "Carry the value through every renderer", "state": "open",'
  '  "labels": [ { "name": "type:bug" }, { "name": "area:tooling" } ],'
  '  "body": "The reader drops the value." }'
  exit 0
}
'example-org/example-repo'
exit 0
"@ | Set-Content -Path (Join-Path $fake 'gh.ps1') -Encoding utf8NoBOM
"@echo off`r`npwsh -NoProfile -File `"$fake\gh.ps1`" %*" |
  Set-Content -Path (Join-Path $fake 'gh.cmd') -Encoding ascii
if (-not $IsWindows) { Set-Content -Path (Join-Path $fake 'gh') -Value "#!/bin/sh`nexec pwsh -NoProfile -File `"$fake/gh.ps1`" `"`$@`"" -Encoding ascii; & chmod +x (Join-Path $fake 'gh') }
$env:PATH = "$fake;$env:PATH"

$failed = 0
function Check($name, $expected, $actual) {
  if ("$expected" -eq "$actual") { Write-Host "  ok   $name" }
  else { Write-Host "  FAIL $name`n       expected: $expected`n       actual:   $actual"; $script:failed++ }
}

$thread = Join-Path $root 'bin/issue-thread.ps1'
$repo = 'example-org/example-repo'

Write-Host 'both reads reach GitHub, and neither writes'
Remove-Item $log -ErrorAction SilentlyContinue
& $thread -Repo $repo -Number 163 | Out-Null
$calls = @(Get-Content $log)
Check 'the issue is read'     1 @($calls | Where-Object { $_ -eq "api repos/$repo/issues/163" }).Count
Check 'the comments are read' 1 @($calls | Where-Object { $_ -eq "api --paginate repos/$repo/issues/163/comments" }).Count
Check 'nothing was written'   0 @($calls | Where-Object { $_ -match 'method (POST|PATCH|PUT|DELETE)|mutation' }).Count

Write-Host 'the json is one object a script can read'
$json = (@(& $thread -Repo $repo -Number 163 -Json) -join '')
# -DateKind String on the way BACK too: without it this test's own parser turns the timestamp
# into a DateTime and the check would be about the parser, not about what the command printed.
$o = $json | ConvertFrom-Json -DateKind String
Check 'one line'      1 @(& $thread -Repo $repo -Number 163 -Json).Count
Check 'number'      163 $o.number
Check 'title'         'Carry the value through every renderer' $o.title
Check 'state'         'open' $o.state
Check 'labels'        'type:bug area:tooling' ($o.labels -join ' ')
Check 'body'          'The reader drops the value.' $o.body
Check 'two comments'  2 @($o.comments).Count
Check 'first author'  'kadir' $o.comments[0].author
Check 'first time'    '2026-08-20T09:00:00Z' $o.comments[0].created_at
Check 'second body'   'Second read.' $o.comments[1].body

Write-Host 'the plain layout is what a person reads'
$out = (@(& $thread -Repo $repo -Number 163) -join "`n")
$expected = @(
  '#163 Carry the value through every renderer'
  'state: open'
  'labels: type:bug, area:tooling'
  ''
  'The reader drops the value.'
  ''
  '--- kadir 2026-08-20T09:00:00Z'
  'First read.'
  ''
  '--- anton 2026-08-21T11:30:00Z'
  'Second read.'
) -join "`n"
Check 'every line, in order' $expected $out

Write-Host 'the repo resolves from the checkout when left out'
Remove-Item $log -ErrorAction SilentlyContinue
& $thread -Number 163 -Json | Out-Null
Check 'default repo' 'True' ([bool](@(Get-Content $log) | Where-Object { $_ -match "repos/$repo/issues/163" }))

# An issue with nothing on it is the case the twins drifted on: an empty label list read back
# as one label that is nothing, so the dash never printed and the JSON carried a null.
Write-Host 'an issue with no label and no comment says so'
$bare = Join-Path $fake 'bare'
New-Item -ItemType Directory -Path $bare | Out-Null
@'
$a = $args -join ' '
if ($a -match 'comments') { '[]'; exit 0 }
if ($a -match 'issues/')  { '{"number":7,"title":"Bare","state":"closed","labels":[],"body":null}'; exit 0 }
'example-org/example-repo'
exit 0
'@ | Set-Content -Path (Join-Path $bare 'gh.ps1') -Encoding utf8NoBOM
"@echo off`r`npwsh -NoProfile -File `"$bare\gh.ps1`" %*" |
  Set-Content -Path (Join-Path $bare 'gh.cmd') -Encoding ascii
if (-not $IsWindows) { Set-Content -Path (Join-Path $bare 'gh') -Value "#!/bin/sh`nexec pwsh -NoProfile -File `"$bare/gh.ps1`" `"`$@`"" -Encoding ascii; & chmod +x (Join-Path $bare 'gh') }

$kept = $env:PATH
$env:PATH = "$bare;$env:PATH"
Check 'labels read as a dash' 'labels: -' (@(& $thread -Repo $repo -Number 7)[2])
Check 'the json carries an empty list' `
  '{"number":7,"title":"Bare","state":"closed","labels":[],"body":"","comments":[]}' `
  (@(& $thread -Repo $repo -Number 7 -Json) -join '')
$env:PATH = $kept

# The team's texts use the em dash everywhere. Both twins print UTF-8, so the same thread reads
# the same from either of them.
Write-Host 'an em dash comes out as an em dash'
$dashed = Join-Path $fake 'dashed'
New-Item -ItemType Directory -Path $dashed | Out-Null
@'
$a = $args -join ' '
if ($a -match 'comments') { '[{"user":{"login":"kadir"},"created_at":"2026-08-20T09:00:00Z","body":"one — two"}]'; exit 0 }
if ($a -match 'issues/')  { '{"number":9,"title":"Dashed","state":"open","labels":[],"body":"a — b"}'; exit 0 }
'example-org/example-repo'
exit 0
'@ | Set-Content -Path (Join-Path $dashed 'gh.ps1') -Encoding utf8NoBOM
"@echo off`r`npwsh -NoProfile -File `"$dashed\gh.ps1`" %*" |
  Set-Content -Path (Join-Path $dashed 'gh.cmd') -Encoding ascii
if (-not $IsWindows) { Set-Content -Path (Join-Path $dashed 'gh') -Value "#!/bin/sh`nexec pwsh -NoProfile -File `"$dashed/gh.ps1`" `"`$@`"" -Encoding ascii; & chmod +x (Join-Path $dashed 'gh') }

$env:PATH = "$dashed;$env:PATH"
$dashedOut = @(& $thread -Repo $repo -Number 9)
Check 'in the body'  'a — b'     $dashedOut[4]
Check 'in a comment' 'one — two' $dashedOut[7]
$env:PATH = $kept

# A refused read is not an empty issue. gh writes its error body to stdout, which the parser
# would take for the issue, so the read goes through Invoke-Gh and the run stops.
Write-Host 'a refused read stops the run rather than printing an empty issue'
$refusing = Join-Path $fake 'refusing'
New-Item -ItemType Directory -Path $refusing | Out-Null
@'
$a = $args -join ' '
if ($a -match 'issues/') { '{"message":"Not Found"}'; [Console]::Error.WriteLine('gh: Not Found (HTTP 404)'); exit 1 }
'example-org/example-repo'
exit 0
'@ | Set-Content -Path (Join-Path $refusing 'gh.ps1') -Encoding utf8NoBOM
"@echo off`r`npwsh -NoProfile -File `"$refusing\gh.ps1`" %*" |
  Set-Content -Path (Join-Path $refusing 'gh.cmd') -Encoding ascii
if (-not $IsWindows) { Set-Content -Path (Join-Path $refusing 'gh') -Value "#!/bin/sh`nexec pwsh -NoProfile -File `"$refusing/gh.ps1`" `"`$@`"" -Encoding ascii; & chmod +x (Join-Path $refusing 'gh') }

$env:PATH = "$refusing;$env:PATH"
$refused = ''
try { & $thread -Repo $repo -Number 404 | Out-Null; $refused = '(no refusal)' }
catch { $refused = $_.Exception.Message }
Check 'it throws and names the call' 'True' ([bool]($refused -match 'failed with exit code 1'))
$env:PATH = $kept

Remove-Item -Recurse -Force $fake -ErrorAction SilentlyContinue
if ($failed -gt 0) { Write-Host "`n$failed failed"; exit 1 }
Write-Host "`nall passed"
