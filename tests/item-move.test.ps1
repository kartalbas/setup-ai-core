# The PowerShell twin of item-move.test.sh, asserting the SAME order of the two writes.
#
# A card is ADDED to the target board before it is removed from the source one. A card that
# failed to land on the target must still be on the source, or the work would be on no board at
# all - which is the one outcome worse than being on the wrong one.
#
#   pwsh -File test/item-move.test.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fake = Join-Path ([IO.Path]::GetTempPath()) "gh-fake-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$env:GH_CACHE_DIRECTORY = Join-Path $fake 'cache'
New-Item -ItemType Directory -Path $fake | Out-Null
$log = Join-Path $fake 'calls.txt'
$FROM = 999983
$TO = 999982

# One card on the source board: #42, status testing, priority P1.
@"
`$a = (`$args -join ' ') -replace '\r?\n', ' '
Add-Content -Path '$log' -Value `$a
if (`$a -match 'fieldValues') {
  '{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},'
  ' "nodes":[{"id":"PVTI_from42",'
  '  "content":{"number":42,"repository":{"nameWithOwner":"example-org/example-repo"}},'
  '  "fieldValues":{"nodes":[{"name":"testing","field":{"name":"Status"}},'
  '                          {"name":"P1","field":{"name":"Priority"}}]}}]}}}}'
  exit 0
}
if (`$a -match 'items\(first:100') {
  '{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},'
  ' "nodes":[{"id":"PVTI_from42",'
  '  "content":{"number":42,"repository":{"nameWithOwner":"example-org/example-repo"}}}]}}}}'
  exit 0
}
if (`$a -match 'addProjectV2ItemById') { 'PVTI_to42'; exit 0 }
if (`$a -match 'deleteProjectV2Item')  { '{}'; exit 0 }
if (`$a -match 'projectItems')         { exit 0 }
if (`$a -match 'issues/42')            { 'I_node42'; exit 0 }
if (`$args[0] -eq 'repo') { 'example-org/example-repo'; exit 0 }
'{}'
exit 0
"@ | Set-Content -Path (Join-Path $fake 'gh.ps1') -Encoding utf8NoBOM
"@echo off`r`npwsh -NoProfile -File `"$fake\gh.ps1`" %*" |
  Set-Content -Path (Join-Path $fake 'gh.cmd') -Encoding ascii
$env:PATH = "$fake;$env:PATH"

foreach ($n in @($FROM, $TO)) {
  $dir = Join-Path $env:GH_CACHE_DIRECTORY "$n"
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  Set-Content -Path (Join-Path $dir 'project-id') -Value "PVT_kwmove$n" -NoNewline
  Set-Content -Path (Join-Path $dir 'fields.tsv') -Value "Status`tF1`ttesting`tS_$n`nPriority`tF2`tP1`tP_$n"
}

$failed = 0
function Check($name, $expected, $actual) {
  if ("$expected" -eq "$actual") { Write-Host "  ok   $name" }
  else { Write-Host "  FAIL $name`n       expected: $expected`n       actual:   $actual"; $script:failed++ }
}

$move = Join-Path $root 'bin/item-move.ps1'
$repo = 'example-org/example-repo'
function Calls { @(Get-Content $log -ErrorAction SilentlyContinue) }
function Clear-Log { Remove-Item $log -ErrorAction SilentlyContinue }
function FirstIndexOf($pattern) {
  $rows = Calls
  for ($i = 0; $i -lt $rows.Count; $i++) { if ($rows[$i] -match $pattern) { return $i } }
  return -1
}

Write-Host '-DryRun reports the card and writes nothing'
Clear-Log
$out = @(& $move -Repo $repo -From $FROM -To $TO -DryRun)
Check 'the count'       "1 card(s) from $repo on project $FROM" $out[0]
Check 'the card'        'True' ([bool]($out -match '#42.*status=testing.*priority=P1'))
Check 'and says so'     'dry run - nothing changed' $out[-1]
Check 'nothing added'   -1 (FirstIndexOf 'addProjectV2ItemById')
Check 'nothing removed' -1 (FirstIndexOf 'deleteProjectV2Item')

Write-Host 'the card is added to the target BEFORE it is taken off the source'
Clear-Log
$out = @(& $move -Repo $repo -From $FROM -To $TO)
$added = FirstIndexOf 'addProjectV2ItemById'
$removed = FirstIndexOf 'deleteProjectV2Item'
Check 'both happened' 'True' ([string](($added -ge 0) -and ($removed -ge 0)))
Check 'add first'     'True' ([string]($added -lt $removed))
Check 'the last line' 'done - the issues themselves are untouched' $out[-1]

Write-Host 'the two values are written on the TARGET board, resolved against its own options'
Check 'the status'   'True' ([bool]((Calls) -match "oid=S_$TO"))
Check 'the priority' 'True' ([bool]((Calls) -match "oid=P_$TO"))

Write-Host 'a value the target board has no option for is reported and left unset'
Clear-Log
Set-Content -Path (Join-Path $env:GH_CACHE_DIRECTORY "$TO/fields.tsv") -Value "Status`tF1`tbacklog`tS_other"
$out = @(& $move -Repo $repo -From $FROM -To $TO)
Check 'the status is named'      'True' ([bool]($out -match "Status 'testing' has no option on project $TO; left unset"))
Check 'the priority too'         'True' ([bool]($out -match "Priority 'P1' has no option on project $TO; left unset"))
Check 'and the card still moved' 'True' ([string]((FirstIndexOf 'deleteProjectV2Item') -ge 0))

Write-Host 'the same board on both sides is refused'
Clear-Log
$said = ''
try { & $move -Repo $repo -From $FROM -To $FROM | Out-Null } catch { $said = $_.Exception.Message }
Check 'says why'     'True' ([bool]($said -match 'are the same project'))
Check 'nothing sent' 0      (Calls).Count

Remove-Item -Recurse -Force $fake -ErrorAction SilentlyContinue
if ($failed -gt 0) { Write-Host "`n$failed failed"; exit 1 }
Write-Host "`nall passed"
