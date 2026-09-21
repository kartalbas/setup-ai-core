# The PowerShell twin of asked-by.test.sh: no issue without a person's yes. issue-new refuses
# without the person and the place, and writes both into the first line of the body it sends.
#
#   pwsh -File test/asked-by.test.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fake = Join-Path ([IO.Path]::GetTempPath()) "gh-fake-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$env:GH_CACHE_DIRECTORY = Join-Path $fake 'cache'
New-Item -ItemType Directory -Path $fake | Out-Null
$log = Join-Path $fake 'calls.txt'
$sent = Join-Path $fake 'sent-body.md'
$PROJECT = 999990

# On `issue create` the fake keeps a copy of the body file it was handed, because the tool
# deletes its temporary body the moment the call returns.
@"
`$a = `$args -join ' '
Add-Content -Path '$log' -Value `$a
if (`$a -match 'issue create') {
  for (`$i = 0; `$i -lt `$args.Count; `$i++) {
    if (`$args[`$i] -eq '--body-file') { Copy-Item `$args[`$i + 1] '$sent' -Force }
  }
  'https://github.com/example-org/example-repo/issues/999'
  exit 0
}
if (`$a -match 'projectItems') { exit 0 }
if (`$a -match 'addProjectV2ItemById') { 'PVTI_new'; exit 0 }
'{}'
exit 0
"@ | Set-Content -Path (Join-Path $fake 'gh.ps1') -Encoding utf8NoBOM
"@echo off`r`npwsh -NoProfile -File `"$fake\gh.ps1`" %*" |
  Set-Content -Path (Join-Path $fake 'gh.cmd') -Encoding ascii
if (-not $IsWindows) { Set-Content -Path (Join-Path $fake 'gh') -Value "#!/bin/sh`nexec pwsh -NoProfile -File `"$fake/gh.ps1`" `"`$@`"" -Encoding ascii; & chmod +x (Join-Path $fake 'gh') }
$env:PATH = "$fake;$env:PATH"

# The board answers, seeded so no lookup has to be faked.
$cache = Join-Path $env:GH_CACHE_DIRECTORY "$PROJECT"
New-Item -ItemType Directory -Force -Path $cache | Out-Null
Set-Content -Path (Join-Path $cache 'project-id') -Value "PVT_kwasked$PROJECT" -NoNewline
Set-Content -Path (Join-Path $cache 'fields.tsv') -Value "Status`tF1`ttodo`tO1`nPriority`tF2`tP1`tO2"

$failed = 0
function Check($name, $expected, $actual) {
  if ("$expected" -eq "$actual") { Write-Host "  ok   $name" }
  else { Write-Host "  FAIL $name`n       expected: $expected`n       actual:   $actual"; $script:failed++ }
}

$issueNew = Join-Path $root 'bin/issue-new.ps1'
$body = Join-Path $fake 'body.md'
'the body' | Set-Content $body -Encoding utf8NoBOM

function New-Issue([hashtable]$extra) {
  Remove-Item $log, $sent -ErrorAction SilentlyContinue
  $p = @{
    Repo = 'example-org/example-repo'
    Title = 'Put every new issue on its board, or nobody reading the board sees it'
    BodyFile = $body; Label = @('type:feature', 'area:tooling'); Priority = 'P1'; Project = $PROJECT
  }
  foreach ($k in $extra.Keys) { $p[$k] = $extra[$k] }
  $script:said = ''
  try { & $issueNew @p 6>$null | Out-Null; return $true } catch { $script:said = $_.Exception.Message; return $false }
}
function Calls { @(Get-Content $log -ErrorAction SilentlyContinue) }

# -AskedBy and -AskedIn are Mandatory, and PowerShell's binder is where a missing one stops. In
# a non-interactive run it throws rather than prompting, so the refusal is the binder's and the
# check is that NOTHING reached gh.
Write-Host 'without -AskedBy the issue is refused before gh is called'
$ran = New-Issue @{ AskedIn = 'issue #12' }
Check 'refused'            'False' ([string]$ran)
Check 'nothing reached gh' 'False' ([bool]((Calls) -match 'issue create'))

Write-Host 'without -AskedIn the issue is refused too'
$ran = New-Issue @{ AskedBy = 'kartalbas' }
Check 'refused'            'False' ([string]$ran)
Check 'nothing reached gh' 'False' ([bool]((Calls) -match 'issue create'))

Write-Host 'with both, the body starts with who said yes and where, and the original body follows'
$ran = New-Issue @{ AskedBy = 'kartalbas'; AskedIn = 'issue #12, comment of 2026-09-03' }
$today = Get-Date -Format 'yyyy-MM-dd'
$lines = @(Get-Content $sent -ErrorAction SilentlyContinue)
Check 'the issue was created' 'True' ([bool]((Calls) -match 'issue create'))
Check 'first line names the person, the day and the place' `
  "Asked for by @kartalbas on $today in issue #12, comment of 2026-09-03." $lines[0]
Check 'the original body follows after a blank line' 'the body' $lines[2]

Write-Host 'a leading @ on the login is not doubled'
$ran = New-Issue @{ AskedBy = '@kartalbas'; AskedIn = 'the chat' }
Check 'one @' 'True' ([bool](@(Get-Content $sent)[0] -match 'by @kartalbas on'))

# The caller's own file is theirs. A tool that wrote the line into it could not be run twice
# without the line standing there twice.
Write-Host "the caller's body file is left as it was"
Check 'still one line' 'the body' ((Get-Content $body) -join "`n")

Remove-Item -Recurse -Force $fake, $cache -ErrorAction SilentlyContinue
if ($failed -gt 0) { Write-Host "`n$failed failed"; exit 1 }
Write-Host "`nall passed"
