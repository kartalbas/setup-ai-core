# The PowerShell twin of title-report.test.sh, asserting the SAME three reports against the SAME
# titles. Two implementations of one reader are two chances to drift, and the length check is
# exactly where they drifted: an em dash is three bytes and one character.
#
#   pwsh -File test/title-report.test.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fake = Join-Path ([IO.Path]::GetTempPath()) "gh-fake-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$env:GH_CACHE_DIRECTORY = Join-Path $fake 'cache'
New-Item -ItemType Directory -Path $fake | Out-Null
$log = Join-Path $fake 'calls.txt'
$PROJECT = 999988

@"
`$a = `$args -join ' '
Add-Content -Path '$log' -Value `$a
if (`$a -match 'issue create') { 'https://github.com/example-org/example-repo/issues/999'; exit 0 }
if (`$a -match 'projectItems') { exit 0 }
if (`$a -match 'addProjectV2ItemById') { 'PVTI_new'; exit 0 }
'{}'
exit 0
"@ | Set-Content -Path (Join-Path $fake 'gh.ps1') -Encoding utf8NoBOM
"@echo off`r`npwsh -NoProfile -File `"$fake\gh.ps1`" %*" |
  Set-Content -Path (Join-Path $fake 'gh.cmd') -Encoding ascii
if (-not $IsWindows) { Set-Content -Path (Join-Path $fake 'gh') -Value "#!/bin/sh`nexec pwsh -NoProfile -File `"$fake/gh.ps1`" `"`$@`"" -Encoding ascii; & chmod +x (Join-Path $fake 'gh') }
$env:PATH = "$fake$([IO.Path]::PathSeparator)$env:PATH"

$cache = Join-Path $env:GH_CACHE_DIRECTORY "$PROJECT"
New-Item -ItemType Directory -Force -Path $cache | Out-Null
Set-Content -Path (Join-Path $cache 'project-id') -Value "PVT_kwtitle$PROJECT" -NoNewline
Set-Content -Path (Join-Path $cache 'fields.tsv') -Value "Status`tF1`ttodo`tO1`nPriority`tF2`tP1`tO2"

$failed = 0
function Check($name, $expected, $actual) {
  if ("$expected" -eq "$actual") { Write-Host "  ok   $name" }
  else { Write-Host "  FAIL $name`n       expected: $expected`n       actual:   $actual"; $script:failed++ }
}

$issueNew  = Join-Path $root 'bin/issue-new.ps1'
$issueEdit = Join-Path $root 'bin/issue-edit.ps1'
$repo = 'example-org/example-repo'
$body = Join-Path $fake 'body.md'
'the body' | Set-Content $body -Encoding utf8NoBOM

$good = 'Put every new issue on its board, or nobody reading the board sees it'
$exactly70 = 'a' * 70
$over70 = 'a' * 71

# The report goes to the host stream, so it is captured with 6>&1 and nothing else is.
function New-WithTitle($title) {
  Remove-Item $log -ErrorAction SilentlyContinue
  $said = & $issueNew -Repo $repo -Title $title -BodyFile $body `
    -Label @('type:feature', 'area:tooling') -Priority P1 -Project $PROJECT `
    -AskedBy kartalbas -AskedIn 'the test' 6>&1 | Out-String
  return $said
}
function Calls { @(Get-Content $log -ErrorAction SilentlyContinue) }

Write-Host 'issue-new reports a long title and creates the issue anyway'
$out = New-WithTitle $over70
Check 'says how long it is'   'True' ([bool]($out -match 'title is 71 characters, over 70'))
Check 'says what a title is'  'True' ([bool]($out -match 'one sentence a stranger understands'))
Check 'the issue was created' 'True' ([bool]((Calls) -match 'issue create'))

Write-Host 'seventy characters is not over seventy'
$out = New-WithTitle $exactly70
Check 'nothing said about the length' 'False' ([bool]($out -match 'over 70'))

Write-Host 'a title of seventy with an em dash in it is not over seventy either'
$out = New-WithTitle (('a' * 68) + [char]0x2014 + 'x')
Check 'nothing said about the length' 'False' ([bool]($out -match 'over 70'))

# A CHARACTER OUTSIDE THE BASIC MULTILINGUAL PLANE IS STILL ONE CHARACTER. .NET stores it as a
# surrogate pair, so `.Length` counts it twice where the shell twin counts one code point.
Write-Host 'a title of seventy ending in an emoji is not over seventy either'
$emoji = [char]::ConvertFromUtf32(0x1F600)
$out = New-WithTitle (('a' * 69) + $emoji)
Check 'nothing said about the length' 'False' ([bool]($out -match 'over 70'))
$out = New-WithTitle (('a' * 70) + $emoji)
Check 'and seventy-one is counted as seventy-one' 'True' ([bool]($out -match 'title is 71 characters, over 70'))

Write-Host 'issue-new reports a backtick and creates the issue anyway'
$out = New-WithTitle 'Fix the `board_items` reader, or every card past the first hundred is missing'
Check 'names the backtick'      'True' ([bool]($out -match 'title contains a backtick'))
Check 'says no code in a title' 'True' ([bool]($out -match 'no code name in a title'))
Check 'the issue was created'   'True' ([bool]((Calls) -match 'issue create'))

# A title that names an artifact and no stake fits twenty other tickets. The shape reported is
# narrow on purpose: one of six verbs AND none of the three joins.
Write-Host 'a title that names an action and no stake is reported'
$out = New-WithTitle 'Add the board-sync command'
Check 'names the missing stake' 'True' ([bool]($out -match 'title names an action and no stake'))
Check 'the issue was created'   'True' ([bool]((Calls) -match 'issue create'))

Write-Host 'the same verb WITH a stake draws no line'
$out = New-WithTitle 'Add the board-sync command, or an issue filed on github.com is on no board'
Check 'silent about the stake' 'False' ([bool]($out -match 'no stake'))
$out = New-WithTitle 'Add the board-sync command: an issue filed on github.com is on no board'
Check 'a colon joins the halves too' 'False' ([bool]($out -match 'no stake'))

Write-Host 'a verb outside the six is not judged at all'
$out = New-WithTitle 'Refuse a push whose commit names no issue'
Check 'silent about the stake' 'False' ([bool]($out -match 'no stake'))

Write-Host 'a title that reads well draws no title line at all'
$out = New-WithTitle $good
Check 'nothing said about the title' 'False' ([bool]($out -match 'title (is|contains|names)'))

Write-Host 'issue-edit reads a new title the same way'
Remove-Item $log -ErrorAction SilentlyContinue
$out = & $issueEdit -Repo $repo -Number 163 -Title $over70 6>&1 | Out-String
Check 'says how long it is' 'True' ([bool]($out -match 'title is 71 characters, over 70'))
Check 'the edit was sent'   'True' ([bool]((Calls) -match 'method PATCH'))

Remove-Item $log -ErrorAction SilentlyContinue
$out = & $issueEdit -Repo $repo -Number 163 -Title 'Add the board-sync command' 6>&1 | Out-String
Check 'names the missing stake' 'True' ([bool]($out -match 'title names an action and no stake'))

Write-Host 'an edit with no title has no title to read'
Remove-Item $log -ErrorAction SilentlyContinue
$out = & $issueEdit -Repo $repo -Number 163 -BodyFile $body 6>&1 | Out-String
Check 'nothing said about the title' 'False' ([bool]($out -match 'title (is|contains|names)'))

Remove-Item -Recurse -Force $fake, $cache -ErrorAction SilentlyContinue
if ($failed -gt 0) { Write-Host "`n$failed failed"; exit 1 }
Write-Host "`nall passed"
