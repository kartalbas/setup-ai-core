# The PowerShell twin of issue-assign.test.sh, asserting the SAME assignee set on the wire.
#
# --Add keeps whoever is already there, -Remove takes one name off and leaves the rest, -Replace
# states the whole set, and a call that would change nothing sends no PATCH at all - a no-op
# PATCH still writes an event onto the timeline, which reads later as a decision somebody took.
#
#   pwsh -File test/issue-assign.test.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fake = Join-Path ([IO.Path]::GetTempPath()) "gh-fake-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $fake | Out-Null
$log = Join-Path $fake 'calls.txt'
$body = Join-Path $fake 'body.json'

# The issue carries two assignees. On a PATCH the stand-in keeps the body it was handed on
# stdin, because that body is the whole contract.
@"
`$a = `$args -join ' '
Add-Content -Path '$log' -Value `$a
if (`$a -match '--method PATCH') { `$input | Set-Content -Path '$body' -Encoding utf8NoBOM; '{}'; exit 0 }
if (`$args[0] -eq 'repo') { 'example-org/example-repo'; exit 0 }
'{"number":575,"assignees":[{"login":"kartalbas"},{"login":"anton"}]}'
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

$assign = Join-Path $root 'bin/issue-assign.ps1'
$repo = 'example-org/example-repo'
function Calls { @(Get-Content $log -ErrorAction SilentlyContinue) }
function Reset { Remove-Item $log, $body -ErrorAction SilentlyContinue }
# The set that reached GitHub, sorted, so the comparison is about membership and not order.
function Sent {
  $text = (Get-Content $body -Raw -ErrorAction SilentlyContinue)
  if (-not $text) { return '(none)' }
  return (($text | ConvertFrom-Json).assignees | Sort-Object) -join ','
}
function PatchCount { @((Calls) | Where-Object { $_ -match '--method PATCH' }).Count }

Write-Host '-Add keeps whoever is already there'
Reset
& $assign -Repo $repo -Number 575 -Add kadir | Out-Null
Check 'the whole set' 'anton,kadir,kartalbas' (Sent)
Check 'one PATCH'     1 (PatchCount)

Write-Host '-Remove takes one name off and leaves the rest'
Reset
& $assign -Repo $repo -Number 575 -Remove anton | Out-Null
Check 'the whole set' 'kartalbas' (Sent)

Write-Host '-Replace states the whole set'
Reset
& $assign -Repo $repo -Number 575 -Replace kadir | Out-Null
Check 'the whole set' 'kadir' (Sent)

Write-Host 'a call that changes nothing sends no PATCH'
Reset
$out = (@(& $assign -Repo $repo -Number 575 -Add kartalbas) -join "`n")
Check 'no PATCH'    0 (PatchCount)
Check 'and says so' '#575 -> unchanged (kartalbas, anton)' $out

Write-Host 'the repo resolves from the checkout when left out'
Reset
& $assign -Number 575 -Add kadir | Out-Null
Check 'default repo' 'True' ([bool]((Calls) -match [regex]::Escape("repos/$repo/issues/575")))

Write-Host 'a batch is one read and one write per issue'
Reset
$out = @(& $assign -Repo $repo -Number 575, 576 -Add kadir)
Check 'two PATCHes'   2 (PatchCount)
Check 'both reported' 2 @($out | Where-Object { $_ -match '^#' }).Count

Write-Host 'a call that names no direction stops before GitHub is reached'
Reset
$said = ''
try { & $assign -Repo $repo -Number 575 | Out-Null } catch { $said = $_.Exception.Message }
Check 'says what to name' 'True' ([bool]($said -match 'name -Add, -Remove or -Replace'))
Check 'nothing sent'      0      (Calls).Count

Write-Host '-Replace cannot be combined with the additive flags'
Reset
$said = ''
try { & $assign -Repo $repo -Number 575 -Replace kadir -Add anton | Out-Null } catch { $said = $_.Exception.Message }
Check 'says why'     'True' ([bool]($said -match 'states the whole set'))
Check 'nothing sent' 0      (Calls).Count

Remove-Item -Recurse -Force $fake -ErrorAction SilentlyContinue
if ($failed -gt 0) { Write-Host "`n$failed failed"; exit 1 }
Write-Host "`nall passed"
