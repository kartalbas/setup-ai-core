<#
The PowerShell twin of field-option-add.test.sh, asserting the SAME rules against
bin/field-option-add.ps1.

    pwsh -NoProfile -File test/field-option-add.test.ps1

NOTHING REACHES github.com. A stand-in `gh` answers the field query, keeps the request body
of the mutation, and answers that too. A cached project id is seeded for a board number no
real project carries, so no board is ever resolved.

THE CLASS THIS HOLDS CLOSED. The mutation
updateProjectV2Field REPLACES a single-select field's whole option list. Every option in
the list carries an OPTIONAL id: with it, GitHub updates the option that already exists;
WITHOUT it, GitHub creates a new one and deletes the old. So a list of the same names, the
same colours and the same descriptions, sent without ids, looks like a no-op and is not one
- it swaps every option for a fresh one and CLEARS the field on every card that carried a
value. Measured on 2026-08-26: adding P9 to the two boards this way emptied the Priority
column of 18 cards. The answer said nothing, because the answer is the list of option
NAMES, and the names were right.

So the assertion is about the ID, not about the names: every option that already existed
goes back with the id it already had, and the new one goes without.

THE PLANTED DEFECT is the body without the ids - the same names, colours and descriptions,
sent as a list GitHub reads as new options - asserted to be the thing this test catches.

THE PLANTED INNOCENT CASE is an option the field already has: nothing is sent at all, so a
run that sends a correct body is not the only way to pass.
#>

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fake = Join-Path ([IO.Path]::GetTempPath()) "field-option-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$env:GH_CACHE_DIRECTORY = Join-Path $fake 'cache'
$ghDir = Join-Path $fake 'gh'
New-Item -ItemType Directory -Path $ghDir -Force | Out-Null
$projectNumber = 999991
$cache = Join-Path $env:GH_CACHE_DIRECTORY "$projectNumber"
$failed = 0

New-Item -ItemType Directory -Path $cache -Force | Out-Null
Set-Content -Path (Join-Path $cache 'project-id') -Value "PVT_kwboard$projectNumber" -NoNewline

# The board as the query answers it: one Priority field with four options, each with its own
# id, and one option carrying a description so the null-to-empty rule is exercised.
@'
{"data":{"node":{"fields":{"nodes":[
  {"id":"PVTSSF_status","name":"Status","options":[
    {"id":"OPT_todo","name":"todo","color":"BLUE","description":"want doing now"}]},
  {"id":"PVTSSF_priority","name":"Priority","options":[
    {"id":"OPT_p0","name":"P0","color":"GRAY","description":null},
    {"id":"OPT_p1","name":"P1","color":"GRAY","description":null},
    {"id":"OPT_p2","name":"P2","color":"GRAY","description":null},
    {"id":"OPT_p3","name":"P3","color":"GRAY","description":null}]}
]}}}}
'@ | Set-Content -Path (Join-Path $fake 'fields.json') -Encoding utf8NoBOM

@'
{"data":{"updateProjectV2Field":{"projectV2Field":{"options":[
  {"id":"OPT_p0","name":"P0"},{"id":"OPT_p1","name":"P1"},{"id":"OPT_p2","name":"P2"},
  {"id":"OPT_p3","name":"P3"},{"id":"OPT_p9","name":"P9"}]}}}}
'@ | Set-Content -Path (Join-Path $fake 'mutation.json') -Encoding utf8NoBOM

# The stand-in keeps the request body of the mutation and RUNS the --jq program the caller
# gave, the way gh does. Answering the raw document instead would let a script that never
# reads its answer pass.
@"
`$ErrorActionPreference = 'Stop'
Add-Content -Path (Join-Path '$fake' 'calls') -Value (`$args -join ' ')
`$prog = ''
for (`$i = 0; `$i -lt `$args.Count - 1; `$i++) {
  if (`$args[`$i] -eq '--input') { Copy-Item `$args[`$i + 1] (Join-Path '$fake' 'body.json') -Force }
  if (`$args[`$i] -eq '--jq')    { `$prog = `$args[`$i + 1] }
}
`$answer = if (`$args -contains '--input') { Get-Content -Raw (Join-Path '$fake' 'mutation.json') }
          else { Get-Content -Raw (Join-Path '$fake' 'fields.json') }
if (`$prog) { `$answer | & jq -r `$prog } else { `$answer }
exit 0
"@ | Set-Content -Path (Join-Path $ghDir 'gh.ps1') -Encoding utf8NoBOM
$env:PATH = "$ghDir;$env:PATH"

function Check($name, $expected, $actual) {
  if ("$expected" -eq "$actual") { Write-Host "  ok   $name" }
  else { Write-Host "  FAIL $name`n       expected: $expected`n       actual:   $actual"; $script:failed++ }
}

function Invoke-Run {
  Remove-Item (Join-Path $fake 'calls'), (Join-Path $fake 'body.json') -Force -EA SilentlyContinue
  (& pwsh -NoProfile -File (Join-Path $root 'bin/field-option-add.ps1') -Project $projectNumber @args 2>&1 |
     ForEach-Object { "$_" }) -join ' '
}

function Get-Body { Get-Content -Raw (Join-Path $fake 'body.json') | ConvertFrom-Json }

try {
  'the option list the mutation is sent'

  $out = Invoke-Run -Field Priority -Name P9 -Color GRAY
  Check 'the run reports the new list' "board ${projectNumber}: field 'Priority' now has P0 P1 P2 P3 P9" $out

  $body = Get-Body
  # The ids the body carries for the options that already existed, in order. This is the
  # whole assertion: a body naming the four ids updates four options, a body naming none
  # replaces them.
  Check 'every option that already existed keeps its id, and the new one has none' 'OPT_p0 OPT_p1 OPT_p2 OPT_p3 NONE' `
        ((@($body.variables.opts | ForEach-Object { if ($_.id) { $_.id } else { 'NONE' } })) -join ' ')
  Check 'the names go with them, in order' 'P0 P1 P2 P3 P9' (@($body.variables.opts.name) -join ' ')
  Check 'a null description is sent as empty, never as null' 'yes' `
        $(if (@($body.variables.opts | Where-Object { $null -eq $_.description })) { 'no' } else { 'yes' })
  Check 'the field written to is the one that was asked for' 'PVTSSF_priority' $body.variables.fid

  # THE PLANTED DEFECT: the body with the same names and colours and the ids
  # dropped. Without it the assertion above passes equally well for a check that looks at
  # nothing.
  $plant = @($body.variables.opts | ForEach-Object { [pscustomobject]@{ name = $_.name; color = $_.color; description = $_.description } })
  Check 'the plant: a body without ids carries the same names' 'P0 P1 P2 P3 P9' (@($plant.name) -join ' ')
  Check 'the plant: and this test would have caught it' 'NONE NONE NONE NONE NONE' `
        ((@($plant | ForEach-Object { if ($_.PSObject.Properties['id'] -and $_.id) { $_.id } else { 'NONE' } })) -join ' ')

  ''
  'the board cache'

  Check 'the option set cached before the run is deleted' 'gone' `
        $(if (Test-Path (Join-Path $cache 'fields.tsv')) { 'still there' } else { 'gone' })

  # THE INNOCENT CASE. An option the field already has: nothing is sent, so the run above
  # is shown to have sent something because it had something to send.
  ''
  'an option the field already has'

  $out = Invoke-Run -Field Priority -Name P2 -Color GRAY
  Check 'is reported and nothing is sent' "board ${projectNumber}: field 'Priority' already has 'P2' - nothing sent" $out
  Check 'and no mutation reached the board' 'no body' `
        $(if (Test-Path (Join-Path $fake 'body.json')) { 'a body was sent' } else { 'no body' })

  ''
  'a field the board does not have'

  $out = Invoke-Run -Field 'Priorität' -Name P9 -Color GRAY
  Check 'stops, and names the fields there are' 'yes' `
        $(if ($out -like '*There is: Status Priority*') { 'yes' } else { "no: $out" })
  Check 'and no mutation reached the board' 'no body' `
        $(if (Test-Path (Join-Path $fake 'body.json')) { 'a body was sent' } else { 'no body' })
}
finally {
  Remove-Item -Recurse -Force $fake, $cache -EA SilentlyContinue
}

if ($failed -gt 0) { ''; "$failed failed"; exit 1 }
''; 'all passed'
