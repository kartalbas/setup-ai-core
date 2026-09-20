<#
The PowerShell twin of issue-label.test.sh, asserting the SAME rules against
bin/issue-label.ps1 and expecting the SAME report lines.

    pwsh -NoProfile -File test/issue-label.test.ps1

NOTHING REACHES github.com. A stand-in `gh` holds the labels of each issue in a file,
answers `issue view` from it and applies `issue edit` to it, so the assertion is the
label set the issue is left carrying and not merely the words the script printed. No
board is resolved either: issue-label never selects a project.

THE STAND-IN REFUSES WHAT gh REFUSES. Measured against github.com on 2026-08-26:

  gh issue edit 12 --repo example-org/example-tools --remove-label does-not-exist-anywhere
    -> failed to update ...: 'does-not-exist-anywhere' not found        exit 1
  gh issue edit 12 --repo example-org/example-tools --remove-label type:bug   (not on it)
    -> https://github.com/example-org/example-tools/issues/12               exit 0

So a name the REPOSITORY does not carry kills the run, and a name the ISSUE does not
carry is a no-op. That is the whole reason issue-label reads the issue's labels before
it sends anything, and the stand-in models both answers so the difference can be shown.

THE PLANTED DEFECTS, one per shape this suite catches, each replayed against the
stand-in so it is shown RED rather than argued about:
  - the edit call with its --remove-label half dropped, which is issue-label as it
    stood: the retired label is still on the issue afterwards.
  - the removal sent without reading the issue first: gh exits 1 and the run is dead.
  - a label name holding a space, split in two the way a glued command line splits it:
    gh is asked to remove 'help', which the repository does not have, and exits 1.

THE PLANTED INNOCENT CASES, so a green run means the checks looked: a run that only
adds, a second run of the same call that changes nothing, and a removal of a name the
taxonomy declares nothing about, which must be allowed.

WHAT THIS DOES NOT REACH, named rather than counted:
  - the taxonomy itself. The names used below are read from the tracked labels.tsv:
    type:bug, type:chore, area:installation and area:tooling are declared there and
    area:install, tooling and design are not, which is the retirement this ticket is
    about. A change to that file that undeclares one of the first four, or declares one
    of the last three, turns this suite red and is meant to.
  - whether gh accepts what it is handed. Only the two answers measured above are
    modelled; anything else gh does is gh's own check.
#>

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fake = Join-Path ([IO.Path]::GetTempPath()) "issue-label-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$ghDir = Join-Path $fake 'gh'
New-Item -ItemType Directory -Path $ghDir -Force | Out-Null
$ghScript = Join-Path $ghDir 'gh.ps1'
$repo = 'example-org/example-repo'
$calls = Join-Path $fake 'calls'
$failed = 0

# The labels the REPOSITORY carries. labels-sync leaves a retired name alone, so the
# names taken off tickets below are all still here - which is why removing them works.
@'
type:bug
type:chore
area:installation
area:tooling
area:install
tooling
design
help wanted
'@ | Set-Content -Path (Join-Path $fake 'repo-labels') -Encoding utf8NoBOM

@"
`$a = @(`$args)
Add-Content -Path (Join-Path '$fake' 'calls') -Value (`$a -join ' ')
`$sub = `$a[1]
`$num = `$a[2]
`$issue = Join-Path '$fake' "issue-`$num"
if (`$sub -eq 'view') { Get-Content `$issue; exit 0 }
if (`$sub -eq 'edit') {
  `$adds = @(); `$removes = @()
  for (`$i = 3; `$i -lt (`$a.Count - 1); `$i++) {
    if (`$a[`$i] -eq '--add-label')         { `$adds    += `$a[`$i + 1]; `$i++ }
    elseif (`$a[`$i] -eq '--remove-label')  { `$removes += `$a[`$i + 1]; `$i++ }
  }
  `$repoLabels = @(Get-Content (Join-Path '$fake' 'repo-labels'))
  foreach (`$l in (@(`$adds) + @(`$removes))) {
    if (`$repoLabels -notcontains `$l) {
      [Console]::Error.WriteLine("failed to update https://github.com/$repo/issues/`${num}: '`$l' not found")
      [Console]::Error.WriteLine('failed to update 1 issue')
      exit 1
    }
  }
  `$on = @(Get-Content `$issue) | Where-Object { `$removes -notcontains `$_ }
  `$on = @(`$on)
  foreach (`$l in `$adds) { if (`$on -notcontains `$l) { `$on += `$l } }
  Set-Content -Path `$issue -Value `$on -Encoding utf8NoBOM
  "https://github.com/$repo/issues/`$num"
  exit 0
}
[Console]::Error.WriteLine("the stand-in was asked something it does not answer: `$sub")
exit 1
"@ | Set-Content -Path $ghScript -Encoding utf8NoBOM
$env:PATH = "$ghDir;$env:PATH"

function Check($name, $expected, $actual) {
  if ("$expected" -eq "$actual") { Write-Host "  ok   $name" }
  else { Write-Host "  FAIL $name`n       expected: $expected`n       actual:   $actual"; $script:failed++ }
}

# One file per issue, holding the labels it carries.
function Set-Issue([int]$n, [string[]]$Labels) {
  Set-Content -Path (Join-Path $fake "issue-$n") -Value $Labels -Encoding utf8NoBOM
}
function Get-Issue([int]$n) { (@(Get-Content (Join-Path $fake "issue-$n")) -join ' ') }

# The script is called in this process rather than in a child pwsh, because `pwsh -File`
# hands the script plain strings and never parses one. Measured on pwsh 7.6.5 against a
# param([int[]]$Number, [string[]]$Add) script: `-File s.ps1 -Number 100,101 -Add a,b`
# arrives as Number=[100101] and Add=[a,b] - one number and one label, not two of each.
# A harness that could not pass two numbers or two labels in one call would leave the shape
# this ticket is about untested.
function Invoke-Run {
  [CmdletBinding()]
  param([int[]] $Number, [string[]] $Add, [string[]] $Remove)
  Set-Content -Path $calls -Value '' -NoNewline -Encoding utf8NoBOM
  $call = @{}
  $call['Repo']   = $repo
  $call['Number'] = $Number
  if ($Add)    { $call['Add']    = $Add }
  if ($Remove) { $call['Remove'] = $Remove }
  try { (& (Join-Path $root 'bin/issue-label.ps1') @call | ForEach-Object { "$_" }) -join "`n" }
  catch { ($_.Exception.Message -replace "`r?`n", ' ') }
}
function Get-Edits { @(Get-Content $calls | Where-Object { $_ -like 'issue edit *' }).Count }
function Get-EditCall { @(Get-Content $calls | Where-Object { $_ -like 'issue edit *' })[0] }

# A plant, replayed straight against the stand-in the way a script that trusted its
# arguments would have sent it. Run as its own process so gh's exit code and the sentence
# it wrote to stderr are both readable.
function Invoke-Plant {
  $out = (& pwsh -NoProfile -File $ghScript @args 2>&1 | ForEach-Object { "$_" }) -join ' '
  [pscustomobject]@{ Code = $LASTEXITCODE; Said = $out }
}

try {
  # --- 1. retiring a label and putting its replacement on, in one call ------------------------

  Write-Host 'a retired label off and its replacement on, in one call'

  Set-Issue 72 @('type:bug', 'area:install')
  $out = Invoke-Run -Number 72 -Add area:installation -Remove area:install
  Check 'the run says what it did' '#72 -> +area:installation -area:install' $out
  Check 'the retired name is gone and the rest is untouched' 'type:bug area:installation' (Get-Issue 72)
  Check 'one edit was sent, carrying both halves' `
        "issue edit 72 --repo $repo --add-label area:installation --remove-label area:install" (Get-EditCall)

  # THE PLANTED DEFECT: an edit that only ever adds.
  # Replayed against the same starting point, the retired label is still there afterwards.
  Set-Issue 72 @('type:bug', 'area:install')
  Invoke-Plant issue edit 72 --repo $repo --add-label area:installation | Out-Null
  Check 'the plant: an edit with no remove half leaves the retired name on' `
        'type:bug area:install area:installation' (Get-Issue 72)

  # --- 2. a name the taxonomy no longer declares ----------------------------------------------

  Write-Host ''
  Write-Host 'a name labels.tsv does not declare comes off, and does not go on'

  Set-Issue 8 @('tooling', 'design', 'type:chore', 'area:tooling')
  $out = Invoke-Run -Number 8 -Remove tooling, design
  Check 'both retired names come off' '#8 -> -tooling -design' $out
  Check 'and the declared ones stay'  'type:chore area:tooling' (Get-Issue 8)

  Set-Issue 8 @('type:chore', 'area:tooling')
  $out = Invoke-Run -Number 8 -Add tooling
  Check 'the same name is refused on --add' 'yes' `
        $(if ($out -like '*"tooling" is not in the taxonomy*') { 'yes' } else { "no: $out" })
  Check 'and nothing was sent' 0 (Get-Edits)

  # --- 3. a label the issue does not carry ----------------------------------------------------

  Write-Host ''
  Write-Host 'a label the issue does not carry is reported, and the run stays green'

  Set-Issue 84 @('type:bug', 'area:tooling')
  $out = Invoke-Run -Number 84 -Remove area:instal
  Check 'it is named, and nothing changed' '#84 -> unchanged  not on it: area:instal' $out
  Check 'the labels are as they were'      'type:bug area:tooling' (Get-Issue 84)
  Check 'and no edit was sent'             0 (Get-Edits)

  # THE PLANTED DEFECT: the same removal sent without reading the issue first, which is
  # what a script that trusted its arguments would send.
  $plant = Invoke-Plant issue edit 84 --repo $repo --remove-label area:instal
  Check 'the plant: sent unread, gh refuses it' 1 $plant.Code
  Check 'the plant: and says which name' 'yes' `
        $(if ($plant.Said -like "*'area:instal' not found*") { 'yes' } else { "no: $($plant.Said)" })

  # --- 4. what the ticket is left missing -----------------------------------------------------

  Write-Host ''
  Write-Host 'a ticket left without a type or an area is named'

  Set-Issue 95 @('type:bug', 'area:tooling')
  $out = Invoke-Run -Number 95 -Remove type:bug
  Check 'the missing family is named' '#95 -> -type:bug  MISSING a type label' $out

  Set-Issue 96 @('type:bug', 'area:tooling')
  $out = Invoke-Run -Number 96 -Remove area:tooling
  Check 'and so is the other one' '#96 -> -area:tooling  MISSING an area label' $out

  # --- 5. a label name holding a space --------------------------------------------------------

  Write-Host ''
  Write-Host 'a label name holding a space stays one argument'

  Set-Issue 97 @('help wanted', 'type:bug', 'area:tooling')
  $out = Invoke-Run -Number 97 -Remove 'help wanted'
  Check 'it comes off whole' '#97 -> -help wanted' $out
  Check 'and nothing else went with it' 'type:bug area:tooling' (Get-Issue 97)

  # THE PLANTED DEFECT: the same name split in two, the way a glued command line splits it.
  Set-Issue 97 @('help wanted', 'type:bug', 'area:tooling')
  $plant = Invoke-Plant issue edit 97 --repo $repo --remove-label help wanted
  Check 'the plant: split in two, gh is asked for a label that does not exist' 'yes' `
        $(if ($plant.Said -like "*'help' not found*") { 'yes' } else { "no: $($plant.Said)" })
  Check 'the plant: and the issue keeps it' 'help wanted type:bug area:tooling' (Get-Issue 97)

  # --- 6. the same name on both sides ---------------------------------------------------------

  Write-Host ''
  Write-Host 'the same name to add and to remove'

  Set-Issue 98 @('type:bug', 'area:tooling')
  $out = Invoke-Run -Number 98 -Add area:tooling -Remove area:tooling
  Check 'is refused, and named' 'yes' `
        $(if ($out -like "*'area:tooling' is named to add and to remove*") { 'yes' } else { "no: $out" })
  Check 'and nothing was sent' 0 (Get-Edits)

  # --- 7. the innocent cases ------------------------------------------------------------------

  Write-Host ''
  Write-Host 'a run that only adds, and a second run of it'

  Set-Issue 99 @('type:bug')
  $out = Invoke-Run -Number 99 -Add area:tooling
  Check 'the label goes on'        '#99 -> +area:tooling' $out
  Check 'and the issue carries it' 'type:bug area:tooling' (Get-Issue 99)

  $out = Invoke-Run -Number 99 -Add area:tooling
  Check 'running it again changes nothing' '#99 -> unchanged  already on it: area:tooling' $out
  Check 'and no edit was sent'             0 (Get-Edits)

  Write-Host ''
  Write-Host 'a call that names no label'

  Set-Issue 102 @('type:bug', 'area:tooling')
  $out = Invoke-Run -Number 102
  Check 'naming no label stops the run' 'error: nothing to do - name a label to add or to remove' $out
  Check 'and nothing was sent' 0 (Get-Edits)

  # The Bash twin has one refusal this one cannot: a positional label where a number
  # belongs. -Number is [int[]], so a word that is not a number stops at the binder with
  # "Cannot convert value", which test/argument-binding.test.ps1 holds for the scripts that
  # take a board number. The two shells answer differently for exactly that input.

  Write-Host ''
  Write-Host 'several issues in one call'

  Set-Issue 100 @('type:bug', 'area:install')
  Set-Issue 101 @('type:bug')
  $out = Invoke-Run -Number 100, 101 -Add area:installation -Remove area:install
  Check 'each one reports its own line' `
        "#100 -> +area:installation -area:install`n#101 -> +area:installation  not on it: area:install" $out
}
finally {
  Remove-Item $fake -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failed -gt 0) { Write-Host "`n$failed failed"; exit 1 }
Write-Host "`nall passed"
