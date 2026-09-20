# The PowerShell twin of schema-check.test.sh, asserting the SAME refusals over the SAME tree.
#
#   pwsh -File test/schema-check.test.ps1
#
# THE CLASS THIS HOLDS CLOSED. github.com validates a mutation document before it executes it, so a
# field that is not on the payload refuses the whole mutation and nothing happens on the board. No
# test in this repository could see that: every one of them runs against a fake gh that answers
# whatever it is told. `updateProjectV2ItemPosition(...) { projectV2Item { id } }` therefore stood
# in lib/board.sh and lib/Board.psm1 under two green tests, and item-top moved no card.
#
# WHAT IS FAKED HERE, AND WHAT IS NOT. The interface is faked: gh answers a small hand-written
# introspection payload naming two mutations, so this test reaches nothing, exactly like every
# other one. What is NOT faked is the reading - the check walks a real directory of real files and
# the refusals below are the ones it printed. Proving that the payload it reads is the real one is
# the command's own job when scripts/check.ps1 runs it, and it is not a test's job at all.
#
# THE PLANTED DEFECT AND THE PLANTED INNOCENT. The tree starts with two mutations the interface
# has, and the run must be GREEN over them - without that, a refusal below could be the check
# refusing everything. Then a file asking for a field the payload does not carry is planted, and
# then a file naming a mutation the interface does not have, and each must be named with its line.
# Taking both away must make the run green again.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fake = Join-Path ([IO.Path]::GetTempPath()) "schema-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $fake | Out-Null
$log = Join-Path $fake 'calls.txt'

$failed = 0
function Check($name, $expected, $actual) {
  if ("$expected" -eq "$actual") { Write-Host "  ok   $name" }
  else { Write-Host "  FAIL $name`n       expected: $expected`n       actual:   $actual"; $script:failed++ }
}

# The stand-in interface. Two mutations, each with the fields its payload really carries, which is
# all the check asks for. A `refuse` file turns it into a server that says no.
@'
{"data":{"__type":{"fields":[
  {"name":"updateProjectV2ItemPosition","type":{"name":"UpdateProjectV2ItemPositionPayload",
    "fields":[{"name":"clientMutationId"},{"name":"items"}]}},
  {"name":"addProjectV2ItemById","type":{"name":"AddProjectV2ItemByIdPayload",
    "fields":[{"name":"clientMutationId"},{"name":"item"}]}}
]}}}
'@ | Set-Content -Path (Join-Path $fake 'schema.json') -Encoding utf8NoBOM

@"
Add-Content -Path '$log' -Value ((`$args -join ' ') -replace '\r?\n', ' ')
if (Test-Path '$fake/refuse') { '{"errors":[{"message":"Bad credentials"}]}'; exit 1 }
Get-Content -Raw '$fake/schema.json'
exit 0
"@ | Set-Content -Path (Join-Path $fake 'gh.ps1') -Encoding utf8NoBOM
"@echo off`r`npwsh -NoProfile -File `"$fake\gh.ps1`" %*" |
  Set-Content -Path (Join-Path $fake 'gh.cmd') -Encoding ascii
$env:PATH = "$fake;$env:PATH"

# The tree the check is pointed at. Its two files are the innocent case, and both are written the
# way this repository writes a mutation: over several physical lines, inside a quoted argument.
$tree = Join-Path $fake 'tree'
New-Item -ItemType Directory -Path "$tree/bin" -Force | Out-Null
New-Item -ItemType Directory -Path "$tree/lib" -Force | Out-Null

@'
#!/usr/bin/env bash
add_card() {
  gh api graphql -f query='
    mutation($pid:ID!, $cid:ID!) {
      addProjectV2ItemById(input:{projectId:$pid, contentId:$cid}) { item { id } } }'
}
'@ | Set-Content -Path "$tree/bin/board-sync.sh" -Encoding utf8NoBOM

@'
#!/usr/bin/env bash
item_top() {
  gh api graphql -f query='
    mutation($pid:ID!, $iid:ID!) {
      updateProjectV2ItemPosition(input:{projectId:$pid, itemId:$iid}) { items { totalCount } } }'
}
'@ | Set-Content -Path "$tree/lib/board.sh" -Encoding utf8NoBOM

$command = Join-Path $root 'bin/schema-check.ps1'
$out = @()
function Invoke-Check {
  # In its OWN process, which is how scripts/check.ps1 runs it. The command writes a refusal to
  # stderr with [Console]::Error, and that handle belongs to the process: run in this one, the
  # sentence goes straight to the terminal and `2>&1` never sees it, so a test reading it back
  # would find nothing and pass for the wrong reason.
  param([string[]]$Arguments)
  Remove-Item $log -ErrorAction SilentlyContinue
  $script:out = @(& pwsh -NoProfile -File $command @Arguments 2>&1 | ForEach-Object { "$_" })
  return $LASTEXITCODE
}
function Line($word) { return (@($script:out | Where-Object { $_.Contains($word) }) + @(''))[0] }
function Last { return $script:out[-1] }

Write-Host 'the innocent tree is green, and the count says how much was read'
$rc = Invoke-Check @($tree)
Check 'exits zero' 0 $rc
Check 'the count'  'schema-check: 2 mutation selection(s) in 2 file(s), every one on the payload the interface publishes.' (Last)
Check 'one call to the interface, not one per file' 1 @(Get-Content $log).Count

Write-Host 'a field the payload does not carry is refused, with the file and the line'
@'
#!/usr/bin/env bash
gh api graphql -f query='
  mutation($pid:ID!, $iid:ID!) {
    updateProjectV2ItemPosition(input:{projectId:$pid, itemId:$iid}) { projectV2Item { id } } }'
'@ | Set-Content -Path "$tree/bin/plant.sh" -Encoding utf8NoBOM
$rc = Invoke-Check @($tree)
Check 'exits nonzero' $true ($rc -ne 0)
Check 'names the file, the line, the mutation and the field' `
      'bin/plant.sh:4 asks `updateProjectV2ItemPosition` for `projectV2Item`, and UpdateProjectV2ItemPositionPayload has: clientMutationId,items' `
      (Line 'plant.sh')
Check 'the count' 'schema-check: 3 mutation selection(s) in 3 file(s), 1 refused.' (Last)
Check 'the two correct ones are not named' '' ((Line 'board-sync.sh') + (Line 'lib/board.sh'))

Write-Host 'a mutation the interface does not have is refused too'
@'
#!/usr/bin/env bash
gh api graphql -f query='
  mutation($pid:ID!) {
    updateProjectV2ItemPositions(input:{projectId:$pid}) { items { totalCount } } }'
'@ | Set-Content -Path "$tree/bin/unknown.sh" -Encoding utf8NoBOM
$rc = Invoke-Check @($tree)
Check 'exits nonzero' $true ($rc -ne 0)
Check 'names the mutation' `
      'bin/unknown.sh:4 names `updateProjectV2ItemPositions`, and the interface has no mutation of that name' `
      (Line 'unknown.sh')
Check 'the count, and the unknown one is not counted as a selection' `
      'schema-check: 3 mutation selection(s) in 4 file(s), 2 refused.' (Last)

Write-Host 'with both plants taken away the run is green again, so the refusals were the plants'
Remove-Item "$tree/bin/plant.sh", "$tree/bin/unknown.sh"
$rc = Invoke-Check @($tree)
Check 'exits zero' 0 $rc
Check 'the count'  'schema-check: 2 mutation selection(s) in 2 file(s), every one on the payload the interface publishes.' (Last)

Write-Host 'an interface that refuses makes the run RED, never green and never skipped'
New-Item -ItemType File -Path "$fake/refuse" | Out-Null
$rc = Invoke-Check @($tree)
Remove-Item "$fake/refuse"
Check 'exits nonzero' $true ($rc -ne 0)
Check 'says nothing was checked' `
      'schema-check: FAIL - the interface could not be read, so no mutation was checked' `
      (Line 'no mutation was checked')
Check 'and never prints a green verdict' '' (Line 'every one on the payload')

Write-Host 'a comment naming a mutation is not code'
@'
#!/usr/bin/env bash
# updateProjectV2ItemPosition(input:{projectId:$pid}) { projectV2Item { id } } is the defect
'@ | Set-Content -Path "$tree/bin/comment.sh" -Encoding utf8NoBOM
@'
<#
.NOTES
updateProjectV2ItemPosition(input:{projectId:$pid}) { projectV2Item { id } } is the defect
#>
Write-Host 'nothing is sent here'
'@ | Set-Content -Path "$tree/bin/help.ps1" -Encoding utf8NoBOM
$rc = Invoke-Check @($tree)
Check 'exits zero' 0 $rc
Check 'neither the shell comment nor the help block was counted' `
      'schema-check: 2 mutation selection(s) in 4 file(s), every one on the payload the interface publishes.' (Last)
Remove-Item "$tree/bin/comment.sh", "$tree/bin/help.ps1"

# The binder is what refuses a name this command does not have, which is why every function here
# carries [CmdletBinding()]. The shell twin has to write that refusal itself and answers 2; this
# side stops before the script runs at all, so the status is the binder's and not the script's.
Write-Host 'a misspelt flag is refused, never read as a directory'
$rc = Invoke-Check @('-Dirctory', $tree)
Check 'does not run'   $true ($rc -ne 0)
Check 'names the word' $true ((Line 'Dirctory') -ne '')

Write-Host 'a directory that is not there is named'
$rc = Invoke-Check @("$fake/nowhere")
Check 'exits two'      2 $rc
Check 'names the path' $true ((Line "$fake/nowhere") -ne '')

Remove-Item -Recurse -Force $fake -ErrorAction SilentlyContinue
if ($failed -gt 0) { Write-Host "`n$failed failed"; exit 1 }
Write-Host "`nall passed"
