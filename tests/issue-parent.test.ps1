# Which issue a new issue is attached to when -Parent is given. The PowerShell twin of
# issue-parent.test.sh, asserting the SAME rules against bin/issue-new.ps1.
#
#   pwsh -File test/issue-parent.test.ps1
#
# THE CLASS THIS HOLDS CLOSED. A parent number is only a number: every repository counts
# its own issues, so the same number resolves in every one of them, to unrelated issues.
# The REST sub_issues endpoint reads the number in the ONE repository it is posted to,
# accepts it, and answers success - so a parent meant for another repository silently
# became whatever issue carried that number locally. The guards are Resolve-ParentIssue
# in lib/Board.psm1, which resolves the reference against GitHub BEFORE anything is
# created and refuses one that resolves nowhere, and the addSubIssue mutation, which
# takes two node ids and is bound to no repository. What is asserted is the node id the
# mutation was sent, because that is the identity that cannot mean a different issue
# elsewhere.
#
# NOTHING REACHES github.com. A stand-in `gh` is on PATH for the whole run: it holds the
# issues that exist in a directory of files, answers the parent lookup from it the way gh
# answers - rows with exit 0, or the error body on stdout with a complaint on stderr and
# exit 1 - and records every call. The board lookups are fed from a seeded cache under a
# board number no real project carries.
#
# WHAT THIS DOES NOT REACH, named rather than counted:
#   - whether github.com accepts the addSubIssue mutation it is sent. Only the calls are
#     asserted; anything gh or the server would refuse is their own check.
#   - the title's characters. jq-escaping.test.ps1 is where a quote, a backslash and
#     non-ASCII in a value are held; the titles here are plain.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fake = Join-Path ([IO.Path]::GetTempPath()) "gh-fake-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$env:GH_CACHE_DIRECTORY = Join-Path $fake 'cache'
New-Item -ItemType Directory -Path $fake | Out-Null
$log = Join-Path $fake 'calls.txt'
$issues = Join-Path $fake 'issues'
$repo = 'example-org/example-repo'
# A board number no real project carries, so the cache this seeds cannot be mistaken for
# a live board's - and is removed again below. The Bash twin uses its own number, so the
# two can run at the same time without reading each other's cache.
$PROJECT = 999991

# The issues that exist: one file per issue, holding "<node id>`t<title>". Number 33
# exists in BOTH repositories with different node ids, which is exactly the ambiguity
# under test - only the node id says which one the mutation was pointed at.
New-Item -ItemType Directory -Path (Join-Path $issues 'example-org/other-repo'), (Join-Path $issues 'example-org/example-repo') -Force | Out-Null
"I_other33`tCollect the rebuild work"   | Set-Content (Join-Path $issues 'example-org/other-repo/33')   -Encoding utf8NoBOM
"I_example33`tAn unrelated local issue" | Set-Content (Join-Path $issues 'example-org/example-repo/33') -Encoding utf8NoBOM
"I_example44`tThe local epic"           | Set-Content (Join-Path $issues 'example-org/example-repo/44') -Encoding utf8NoBOM

# The board answers, seeded so no lookup has to be faked: the project id and the two
# single-select fields issue-new sets.
$cache = Join-Path $env:GH_CACHE_DIRECTORY "$PROJECT"
New-Item -ItemType Directory -Path $cache -Force | Out-Null
Set-Content -Path (Join-Path $cache 'project-id') -Value "PVT_kwfake$PROJECT" -NoNewline
Set-Content -Path (Join-Path $cache 'fields.tsv') -Value "Status`tF1`tTodo`tO1`nPriority`tF2`tP2`tO2"

# The stand-in. It records what it was asked, answers the reads issue-new makes, and
# refuses anything else - a call outside this list is issue-new resolving something it
# was not asked to resolve.
@'
$a = $args
Add-Content -Path '__LOG__' -Value ($a -join ' ')
$line = $a -join ' '
if ($a[0] -eq 'issue' -and $a[1] -eq 'create') { 'https://github.com/example-org/example-repo/issues/123'; exit 0 }
if ($a[0] -eq 'api' -and $a[1] -eq 'graphql') {
  if ($line.Contains('addSubIssue'))                   { '{}'; exit 0 }
  if ($line.Contains('updateProjectV2ItemFieldValue')) { '{}'; exit 0 }
  if ($line.Contains('addProjectV2ItemById'))          { 'PVTI_item1'; exit 0 }
  if ($line.Contains('projectItems'))                  { exit 0 }
  if ($line.Contains('issue(number:')) {
    $o = ''; $n = ''; $num = ''
    foreach ($t in $a) {
      if ($t -like 'o=*')   { $o   = $t.Substring(2) }
      elseif ($t -like 'n=*')   { $n   = $t.Substring(2) }
      elseif ($t -like 'num=*') { $num = $t.Substring(4) }
    }
    $f = Join-Path '__ISSUES__' "$o/$n/$num"
    if (Test-Path $f) { (Get-Content $f -Raw).TrimEnd(); exit 0 }
    '{"data":{"repository":{"issue":null}},"errors":[{"message":"Could not resolve to an Issue"}]}'
    [Console]::Error.WriteLine("gh: Could not resolve to an Issue with the number of $num. (repository.issue)")
    exit 1
  }
}
if ($a[0] -eq 'api' -and $a[1] -like 'repos/*/issues/*') { 'I_child123'; exit 0 }
[Console]::Error.WriteLine("the stand-in was asked something it does not answer: $line")
exit 1
'@.Replace('__LOG__', $log).Replace('__ISSUES__', $issues) |
  Set-Content -Path (Join-Path $fake 'gh.ps1') -Encoding utf8NoBOM

# A .cmd shim so `gh` resolves as a command on Windows.
"@echo off`r`npwsh -NoProfile -File `"$fake\gh.ps1`" %*" |
  Set-Content -Path (Join-Path $fake 'gh.cmd') -Encoding ascii
if (-not $IsWindows) { Set-Content -Path (Join-Path $fake 'gh') -Value "#!/bin/sh`nexec pwsh -NoProfile -File `"$fake/gh.ps1`" `"`$@`"" -Encoding ascii; & chmod +x (Join-Path $fake 'gh') }

$failed = 0
function Check($name, $expected, $actual) {
  if ($expected -eq $actual) { Write-Host "  ok   $name" }
  else { Write-Host "  FAIL $name`n       expected: $expected`n       actual:   $actual"; $script:failed++ }
}

try {
  $env:PATH = "$fake$([IO.Path]::PathSeparator)$env:PATH"
  $body = Join-Path $fake 'body.md'
  'body' | Set-Content $body -Encoding utf8NoBOM
  $info = Join-Path $fake 'info.txt'
  $issueNew = Join-Path $root 'bin/issue-new.ps1'

  function NewIssue($parent) {
    Remove-Item $log, $info -ErrorAction SilentlyContinue
    $p = @{
      Repo = $repo; Title = 't'; BodyFile = $body
      Label = @('type:bug', 'area:tooling'); Priority = 'P2'; Project = $PROJECT
      AskedBy = 'kartalbas'; AskedIn = 'the test'
    }
    if ($null -ne $parent) { $p.Parent = "$parent" }
    $script:stdout = $null
    $script:refusal = ''
    try { $script:stdout = & $issueNew @p 6> $info }
    catch { $script:refusal = $_.Exception.Message }
  }

  # Whether the mutation was sent this parent node id, with the new issue as the child.
  function AttachedTo($nodeId) {
    $sent = @(Get-Content $log -ErrorAction SilentlyContinue | Where-Object { $_ -like "*parent=$nodeId -f child=I_child123*" })
    if ($sent.Count -gt 0) { return 'yes' }
    $any = @(Get-Content $log -ErrorAction SilentlyContinue | Where-Object { $_ -match 'parent=' })
    return "no: $(if ($any) { $any -join '; ' } else { 'no attach was sent' })"
  }

  # Whether a message names the word the caller got wrong. A refusal that does not say
  # which word to fix costs the same round trip as no refusal at all.
  function Names($message, $word) {
    if ("$message".Contains($word)) { return 'yes' }
    return "no: $message"
  }

  function Report { (Get-Content $info -ErrorAction SilentlyContinue) | Where-Object { $_ -like '*sub-issue of*' } }
  function Created { @(Get-Content $log -ErrorAction SilentlyContinue | Where-Object { $_ -like 'issue create*' }).Count }

  # --- 1. a parent in another repository -------------------------------------------------------

  Write-Host 'a parent in another repository is the issue that is attached to'

  NewIssue 'example-org/other-repo#33'
  Check 'the run succeeds, and stdout stays the number, capturable' '123' "$stdout"
  Check "the attach names THAT repository's issue 33" 'yes' (AttachedTo 'I_other33')
  Check 'and the report says which issue, by repository, number and title' `
        '#123 -> sub-issue of example-org/other-repo#33  Collect the rebuild work' (Report)

  NewIssue 'other-repo#33'
  Check 'REPO#N reads the owner from the repo the issue is created in' 'yes' (AttachedTo 'I_other33')

  # --- 2. a bare number keeps today's meaning --------------------------------------------------

  Write-Host ''
  Write-Host 'a bare number stays an issue of the same repository'

  NewIssue 44
  Check 'the run succeeds'                    '123' "$stdout"
  Check 'the attach names the local issue 44' 'yes' (AttachedTo 'I_example44')
  Check 'and the report says so' `
        '#123 -> sub-issue of example-org/example-repo#44  The local epic' (Report)

  # --- 3. a parent that does not exist ---------------------------------------------------------

  Write-Host ''
  Write-Host 'a parent that does not exist refuses before anything is created'

  NewIssue 'example-org/other-repo#77'
  Check 'the run stops'             '' "$stdout"
  Check 'naming what was asked for' 'yes' (Names $refusal 'the parent issue example-org/other-repo#77')
  Check 'and no issue was created'  0 (Created)

  NewIssue 'bogus'
  Check 'a reference that is no reference is refused' 'yes' `
        (Names $refusal "'bogus' is not an issue reference")
  Check 'before gh was asked anything' 0 @(Get-Content $log -ErrorAction SilentlyContinue).Count

  # WHAT SEPARATES THE TWO TWINS. .NET's $ matches at the end of the string OR immediately before
  # a final newline, so `-notmatch '^[0-9]+$'` accepted "12`n" while the shell twin's `case` glob
  # refused it, and one reference resolved a parent on one side and was refused on the other. Both
  # twins assert the same two answers here, which is what makes the pair provable rather than
  # merely both green.
  NewIssue "12`n"
  Check 'a number with a trailing newline is refused' 'yes' `
        (Names $refusal 'is not an issue reference')
  Check 'before gh was asked anything' 0 @(Get-Content $log -ErrorAction SilentlyContinue).Count

  NewIssue ' 12'
  Check 'a number with a leading space is refused' 'yes' `
        (Names $refusal "' 12' is not an issue reference")
  Check 'before gh was asked anything' 0 @(Get-Content $log -ErrorAction SilentlyContinue).Count

  # --- 4. the innocent case --------------------------------------------------------------------

  Write-Host ''
  Write-Host 'and with no parent named, nothing is resolved and nothing attached'

  NewIssue $null
  Check 'the run succeeds, stdout stays the number' '123' "$stdout"
  Check 'no attach was sent' 0 @(Get-Content $log -ErrorAction SilentlyContinue | Where-Object { $_ -like '*addSubIssue*' }).Count
  Check 'and nothing was reported' 0 @(Report).Count
}
finally {
  Remove-Item $fake, $cache -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failed -gt 0) { Write-Host "`n$failed failed"; exit 1 }
Write-Host "`nall passed"
