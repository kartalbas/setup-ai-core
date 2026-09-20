# What happens to an argument this repository does not take, and to a flag without its value.
#
#   pwsh -File test/argument-binding.test.ps1
#
# THE CLASS THIS HOLDS CLOSED. A plain PowerShell function does not refuse a parameter name it
# does not have: the binder drops the NAME AND ITS VALUE into $args, leaves the parameter it was
# meant for empty, and the run continues on whatever that emptiness defaults to. In this
# repository that default is the board of the CURRENT DIRECTORY, which is a real board - so a call
# naming a board acted on a different one and nothing on either side said so. The guard is
# [CmdletBinding()] on every function in lib/Board.psm1 and on every script in bin/, and it is
# held here rather than by discipline because a function added without it re-opens exactly that.
#
# NOTHING REACHES A REAL BOARD, INCLUDING WHEN A CHECK FAILS. A stand-in `gh` is on PATH for the
# whole run: it records what it was asked and answers an empty board. Sections 1 to 4 need no gh
# at all while the guards hold, because a binder error happens before any body runs - but a run
# with [CmdletBinding()] MISSING is exactly what those sections are for, and such a run walks on
# to the board lookup, against github.com if the stand-in were installed later. Section 5
# additionally seeds one cached project id per board number, so which board the script acted on
# can be read back from the id it sent.
#
# THE PLANTED CASES, so a green run means the checks looked rather than that nothing was there.
# Section 1 builds a throwaway module holding one advanced and one PLAIN function and puts both
# through the same reflection and the same misspelt call: the plain one must be reported and must
# swallow the misspelt name, or the check is measuring nothing. Every section below it carries an
# innocent case - the correct spelling, the value that is there - beside the refusal.
#
# WHAT THIS DOES NOT REACH, named rather than counted:
#   - Invoke-Gh, which is deliberately NOT an advanced function. Section 1 asserts that it is the
#     one exception and lib/Board.psm1 says why; a name it does not have falls through to gh,
#     which answers `unknown command "5" for "gh"`.
#   - the bash twin's stricter rule for a value beginning with a dash. PowerShell BINDS
#     `-Title '-x marks the spot'` because its parser still knows which words were quoted; bash
#     cannot know that and refuses. lib/board.sh states the asymmetry and what it costs, and
#     test/argument-binding.test.sh holds the bash side of it.
#   - whether gh accepts what it is handed. That is gh's own check and is not asked here.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fake = Join-Path ([IO.Path]::GetTempPath()) "gh-bind-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$env:GH_CACHE_DIRECTORY = Join-Path $fake 'cache'
$ghDir = Join-Path $fake 'gh'
New-Item -ItemType Directory -Path $ghDir -Force | Out-Null

# Two board numbers no real project carries, so the caches these seed cannot be mistaken for a
# live board's - and are removed again below. They differ so which one a run used can be read off
# the project id it sent.
$given = 999996
$fromEnvironment = 999995

# The stand-in, installed before the first check. It records what it was asked and answers a board
# with no cards, which is enough for every script this suite drives.
@"
`$ErrorActionPreference = 'Stop'
Add-Content -Path (Join-Path '$ghDir' 'calls') -Value (`$args -join ' ')
'{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}'
exit 0
"@ | Set-Content -Path (Join-Path $ghDir 'gh.ps1') -Encoding utf8NoBOM
$env:PATH = "$ghDir;$env:PATH"

$failed = 0
function Check($name, $expected, $actual) {
  if ($expected -eq $actual) { Write-Host "  ok   $name" }
  else { Write-Host "  FAIL $name`n       expected: $expected`n       actual:   $actual"; $script:failed++ }
}

# What a call did: the message it stopped with, or 'bound' when it did not stop at all.
function Refusal([scriptblock]$call) {
  try { & $call | Out-Null; return 'bound' } catch { return ($_.Exception.Message -replace "`r?`n", ' ') }
}

# Whether a message names the parameter the caller got wrong. A refusal that does not say which
# word to fix costs the same round trip as no refusal at all.
function Names($message, $word) { if ($message -like "*$word*") { 'yes' } else { "no: $message" } }

# THE BINDER'S OWN SENTENCE, MATCHED WHOLE, and not merely the misspelt word appearing somewhere.
# The word alone is not enough to tell a refusal from the defect: a run whose value was swallowed
# falls through to the current directory and stops with "... is not linked to an open project -
# run repo-link, or pass -Project <number>", which carries the word "Project" and is the exact
# wrong answer this suite exists to catch.
function BinderRefused([string]$name, [scriptblock]$call) {
  $m = Refusal $call
  if ($m -like "*A parameter cannot be found that matches parameter name '$name'*") { "refused $name" }
  else { "no: $m" }
}

Import-Module (Join-Path $root 'lib/Board.psm1') -Force

try {
  # --- 1. every function that takes an argument refuses a name it does not have ---------------

  Write-Host 'every function in lib/Board.psm1 is an advanced function, and Invoke-Gh is the exception'

  # Read back from the module itself, so a function ADDED without the attribute is caught rather
  # than a list in this file going stale.
  $plain = @(
    (Get-Module Board).ExportedFunctions.Keys |
      Where-Object { -not (Get-Command $_).CmdletBinding } |
      Sort-Object
  )
  Check 'Invoke-Gh is the only plain function' 'Invoke-Gh' ($plain -join ' ')

  $exported = @((Get-Module Board).ExportedFunctions.Keys)
  Check 'and every other exported function is advanced' ($exported.Count - 1) `
        (@($exported | Where-Object { (Get-Command $_).CmdletBinding }).Count)

  # THE PLANTED DEFECT. A module with one advanced and one plain function, put through the same
  # reflection and the same misspelt call. Without it, both assertions above pass equally well for
  # a predicate that reports nothing at all.
  $plantDir = Join-Path $fake 'plant'
  New-Item -ItemType Directory -Path $plantDir -Force | Out-Null
  @'
function Get-PlantAdvanced { [CmdletBinding()] param([string]$Number) "Number=[$Number]" }
function Get-PlantPlain    { param([string]$Number) "Number=[$Number] args=[$($args -join '|')]" }
Export-ModuleMember -Function Get-PlantAdvanced, Get-PlantPlain
'@ | Set-Content -Path (Join-Path $plantDir 'Plant.psm1') -Encoding utf8NoBOM
  Import-Module (Join-Path $plantDir 'Plant.psm1') -Force

  Check 'the plant: the reflection reports a plain function' 'Get-PlantPlain' `
        (@((Get-Module Plant).ExportedFunctions.Keys |
            Where-Object { -not (Get-Command $_).CmdletBinding }) -join ' ')
  Check 'the plant: a plain function swallows a misspelt name' 'bound' `
        (Refusal { Get-PlantPlain -Projekt 6 })
  Check 'the plant: the advanced one refuses it' 'refused Projekt' `
        (BinderRefused 'Projekt' { Get-PlantAdvanced -Projekt 6 })
  Remove-Module Plant -Force

  # --- 2. a parameter name the function does not have ----------------------------------------

  Write-Host ''
  Write-Host 'a name lib/Board.psm1 does not have stops the call'

  # The instance the ticket was written for: epics-top.ps1 called Set-Project -Project, and
  # Set-Project takes -Number.
  Check 'Set-Project -Project is refused'  'refused Project' (BinderRefused 'Project' { Set-Project -Project $given })
  Check 'Get-CacheDir -Project is refused' 'refused Project' (BinderRefused 'Project' { Get-CacheDir -Project $given })
  Check 'Get-FieldId -Feld is refused'     'refused Feld'    (BinderRefused 'Feld'    { Get-FieldId -Feld Status })

  # The innocent case, or the three above pass for a module that refuses everything.
  Check 'the spelling it does have is bound' "$given" (Set-Project -Number "$given")

  # --- 3. a flag without its value ------------------------------------------------------------

  Write-Host ''
  Write-Host 'a flag whose value is missing, or is the next flag'

  $boardList = Join-Path $root 'bin/board-list.ps1'
  $epicsTop  = Join-Path $root 'bin/epics-top.ps1'
  $issueNew  = Join-Path $root 'bin/issue-new.ps1'

  Check 'board-list.ps1 -Project with nothing after it' 'yes' `
        (Names (Refusal { & $boardList -Project }) 'Missing an argument')
  Check 'board-list.ps1 -Project followed by -Status'   'yes' `
        (Names (Refusal { & $boardList -Project -Status Todo }) 'Missing an argument')
  Check 'epics-top.ps1 -Project followed by -DryRun'    'yes' `
        (Names (Refusal { & $epicsTop -Project -DryRun }) 'Missing an argument')
  Check 'issue-new.ps1 -Title followed by -Repo'        'yes' `
        (Names (Refusal { & $issueNew -Title -Repo x }) 'Missing an argument')

  $fieldAdd   = Join-Path $root 'bin/field-option-add.ps1'
  $repoBoards = Join-Path $root 'bin/repo-boards.ps1'
  $issueLabel = Join-Path $root 'bin/issue-label.ps1'
  # issue-label takes two names that are one letter apart in effect: -Add puts a label on and
  # -Remove takes it off. -Number is Mandatory, so it is given on both calls below and the only
  # thing left for the binder to object to is the name under test.
  Check 'issue-label.ps1 -Remove with nothing after it' 'yes' `
        (Names (Refusal { & $issueLabel -Number 8 -Remove }) 'Missing an argument')
  Check 'issue-label.ps1 -Remooove is refused' 'yes' `
        (Names (Refusal { & $issueLabel -Number 8 -Remooove tooling }) 'Remooove')
  Check 'field-option-add.ps1 -Field with nothing after it' 'yes' `
        (Names (Refusal { & $fieldAdd -Field }) 'Missing an argument')
  Check 'field-option-add.ps1 -Feld is refused'  'yes' `
        (Names (Refusal { & $fieldAdd -Feld Priority }) 'Feld')
  Check 'repo-boards.ps1 -Project is refused'    'yes' `
        (Names (Refusal { & $repoBoards -Project 6 }) 'Project')
  # The colour is a closed set, and a name outside it stops at the binder rather than at the API.
  Check 'field-option-add.ps1 -Color Puce is refused' 'yes' `
        (Names (Refusal { & $fieldAdd -Field Priority -Name P9 -Color Puce }) 'Puce')

  # --- 4. a number that is not a number --------------------------------------------------------

  # THE TWELVE INPUTS, and the reason example-tools#22 exists. Measured 2026-09-05, `[int]` binding
  # against the shell twin's `case "$n" in ''|*[!0-9]*)` answered differently on ELEVEN of them,
  # and `-Number 12.6` bound to 13 - the command edited the neighbouring issue and said nothing.
  # The same twelve are driven here and in the shell twin, and the two tables must read the same,
  # line for line.
  #
  # solution-path is what they are driven through, because it reaches NOTHING: no board, no gh,
  # no network. A number that passes the rule runs to the end against a file that carries all
  # eight sections, so 'ran' and 'refused' say exactly which side of the rule the input fell on.
  #
  # `-12` is refused on both sides for two different reasons: here the rule refuses it, and there
  # it is an argument beginning with a dash, which the shell's parse loop refuses because bash
  # cannot tell it from a flag. The asymmetry is the one named at the top of this file; both
  # refuse.

  Write-Host ''
  Write-Host 'a number that is not a number is refused, on the same twelve inputs as the shell twin'

  $solutionPath = Join-Path $root 'bin/solution-path.ps1'
  $spFile = Join-Path $fake 'path.md'
  $spBody = @(
    '## Where a person meets this', '', 'x', ''
    '## What they see today', '', 'x', ''
    '## What the system does behind it', '', 'x', ''
    '## The decision', '', 'x', ''
    '## Options', '', 'x', ''
    '## Recommendation', '', 'x', ''
    '## Code facts', '', 'x', ''
    '## Reuse manifest', '', 'x'
  )
  Set-Content -Path $spFile -Value $spBody -Encoding utf8NoBOM

  function NumberAnswer([string]$value) {
    if ((Refusal { & $solutionPath -Check -Number $value -File $spFile }) -ceq 'bound') { 'ran' } else { 'refused' }
  }

  Check 'a whole number'        'ran'     (NumberAnswer '12')
  Check 'a trailing newline'    'refused' (NumberAnswer "12`n")
  Check 'a leading space'       'refused' (NumberAnswer ' 12')
  Check 'a trailing space'      'refused' (NumberAnswer '12 ')
  Check 'a leading plus'        'refused' (NumberAnswer '+12')
  Check 'a leading minus'       'refused' (NumberAnswer '-12')
  Check 'rounding down'         'refused' (NumberAnswer '12.4')
  Check 'rounding UP to 13'     'refused' (NumberAnswer '12.6')
  Check 'scientific notation'   'refused' (NumberAnswer '1e2')
  Check 'a thousands separator' 'refused' (NumberAnswer '1,234')
  Check 'hexadecimal'           'refused' (NumberAnswer '0x1F')
  Check 'Arabic-Indic digits'   'refused' (NumberAnswer '١٢')

  # The board number arrives at Set-Project, from a parameter or from the environment, and is
  # judged there - one guard for every command that passes one in.
  Check 'board-list.ps1 -Project abc' 'yes' `
        (Names (Refusal { & $boardList -Project abc }) "the board number must be numeric, not 'abc'")
  Check 'epics-top.ps1 -Project abc'  'yes' `
        (Names (Refusal { & $epicsTop -Project abc }) "the board number must be numeric, not 'abc'")
  $env:GH_PROJECT_NUMBER = '12.6'
  Check 'GH_PROJECT_NUMBER=12.6'      'yes' `
        (Names (Refusal { & $epicsTop -DryRun }) "the board number must be numeric, not '12.6'")
  $env:GH_PROJECT_NUMBER = $null

  # --- 5. the board named is the board acted on -----------------------------------------------

  # THE ONE THAT COSTS A CARD, and the reason the ticket exists. The two sections above catch a
  # misspelt name at the binder; this one catches the SILENT case underneath it - the number
  # arriving nowhere and the board being resolved from somewhere else, which no error announces
  # because the other board is a real board.
  #
  # Which board a run acted on is read back from the project id it sent gh. One cached id per
  # board number, so the two cannot be confused, and no lookup is needed to get them.

  Write-Host ''
  Write-Host 'the board named on the command line is the board that is acted on'

  foreach ($n in @($given, $fromEnvironment)) {
    New-Item -ItemType Directory -Force -Path (Join-Path $env:GH_CACHE_DIRECTORY "$n") | Out-Null
    Set-Content -Path (Join-Path $env:GH_CACHE_DIRECTORY "$n/project-id") -Value "PVT_kwboard$n" -NoNewline -Encoding utf8NoBOM
  }

  $calls = Join-Path $ghDir 'calls'
  function BoardReached([hashtable]$scriptArgs) {
    Set-Content -Path $calls -Value '' -NoNewline -Encoding utf8NoBOM
    & $epicsTop @scriptArgs *>$null
    $said = Get-Content $calls -Raw
    if ($said -match 'pid=(PVT_kwboard\d+)') { return $Matches[1] }
    return "no board id was sent, and gh was asked: $said"
  }

  $env:GH_PROJECT_NUMBER = "$fromEnvironment"

  Check 'the number given on the command line wins over the environment' "PVT_kwboard$given" `
        (BoardReached @{ Project = $given; DryRun = $true })

  # The innocent case: with nothing on the command line the environment is what is left, so the
  # assertion above measures the argument arriving and not a board that was never a choice.
  Check 'and with no number given, the environment is used' "PVT_kwboard$fromEnvironment" `
        (BoardReached @{ DryRun = $true })

  # And the board was never resolved from the directory this test happens to run in. That lookup
  # is the fallback a lost value lands on, and it is silent because it succeeds.
  BoardReached @{ Project = $given; DryRun = $true } | Out-Null
  Check 'the current directory was never asked' 'not asked' `
        $(if ((Get-Content $calls -Raw) -match 'repo view') { 'gh repo view was called' } else { 'not asked' })
}
finally {
  $env:GH_PROJECT_NUMBER = $null
  Remove-Module Plant -Force -ErrorAction SilentlyContinue
  Remove-Item $fake -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failed -gt 0) { Write-Host "`n$failed failed"; exit 1 }
Write-Host "`nall passed"
