<#
The PowerShell twin of label-taxonomy.test.sh, asserting the SAME rules against
Get-LabelTaxonomy.

    pwsh -NoProfile -File test/label-taxonomy.test.ps1

Nothing reaches github.com: Get-LabelTaxonomy reads one file and calls nothing.

THE DEFECT THIS EXISTS AGAINST IS INVISIBLE, which is why it needs a test rather than a
reader. labels.tsv is read in three places - labels-sync creates the labels from it,
board-sync decides from it which ticket is missing one, issue-label refuses a name that is
not in it. board-sync's reading picks rows by their GROUP column. A row whose group is
misspelt is therefore not seen at all: it is not a type and not an area, so every ticket
carrying that label is reported as missing a label that is right there on it, and the run
stays green, because finding nothing is what green looks like. A row named `area:gate`
filed under group `type` is the same defect one turn worse - it is counted as the family
it is not, and the board then filters on a lie.

So the file is held against its shape ONCE, in lib/Board.psm1, and every reader comes
through there. Each shape below is planted into a copy of labels.tsv, and the run must
REFUSE and name the line.

THE PLANTED INNOCENT CASE is the repository's own labels.tsv, copied back and read at the
end: without it every refusal above could equally be a reader that refuses anything.

THE TRACKED FILE IS NEVER WRITTEN TO. Every plant goes into a copy in a temp directory,
named `labels.tsv` so the refusals still read as `labels.tsv:<line>`. Planting into the
repository's own file meant the two twins could not run at the same time - each read the
other's plant - and a killed run left the taxonomy damaged in the working tree.

THE PLANTED OLD READER shows what the refusals are worth. It is board-sync's parse as it
stood - a filter over the group column - run against the same misspelt file, and it
answers with an empty type list and no error, which is the silent failure in full.
#>

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([IO.Path]::GetTempPath()) "label-taxonomy-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $work -Force | Out-Null
$file = Join-Path $work 'labels.tsv'
$keep = Join-Path $work 'keep'
$failed = 0

Copy-Item (Join-Path $root 'templates/.ai-core/labels.tsv') $keep -Force
Import-Module (Join-Path $root 'lib/Board.psm1') -Force

function Test-Check { param($Name, $Expected, $Actual)
  if ("$Expected" -eq "$Actual") { "  ok   $Name" }
  else { "  FAIL $Name"; "       expected: $Expected"; "       actual:   $Actual"; $script:failed++ }
}

# What a run of Get-LabelTaxonomy did with the file as it stands: the message it stopped
# with, or 'read' when it did not stop at all.
function Get-Outcome {
  try { Get-LabelTaxonomy -Path $file | Out-Null; return 'read' }
  catch { return "$($_.Exception.Message)" }
}

# Whether a refusal names the line the reader has to open. A refusal that does not say
# which line to fix costs the same round trip as no refusal at all.
function Test-Names { param($Message, $Word)
  if ("$Message".Contains($Word)) { 'yes' } else { "no: $Message" }
}

function Set-Plant { param($Row)
  Copy-Item $keep $file -Force
  Add-Content -Path $file -Value $Row -NoNewline:$false
}

# The line the planted row lands on: the file as it stands plus one.
$plantedLine = (Get-Content $keep).Count + 1
$where = "labels.tsv:$plantedLine"

try {
  'a row board-sync could not read is refused, and the line is named'

  Set-Plant "typ`ttyp:bug`tD73A4A`tA mechanism that misbehaves today"
  Test-Check 'a group that is not one of the three' 'yes' (Test-Names (Get-Outcome) $where)

  # The name is one no other row carries, so the only rule that can fire here is the
  # prefix one. Planted as `area:gate` it tripped the duplicate rule instead, and the
  # check stayed green with the prefix rule taken out of the library.
  Set-Plant "type`tarea:not-declared-anywhere`tD73A4A`tA name no other row carries"
  Test-Check 'a name whose prefix is not its group' 'yes' (Test-Names (Get-Outcome) $where)

  Set-Plant "area`tarea`t1D76DB`tA name with no suffix at all"
  Test-Check 'a name that is the bare prefix' 'yes' (Test-Names (Get-Outcome) $where)

  Set-Plant "area`tarea:new`tblue`tA colour that is not six hex digits"
  Test-Check 'a colour that is not six hex digits' 'yes' (Test-Names (Get-Outcome) $where)

  Set-Plant "area`tarea:new`t1D76DB`t"
  Test-Check 'a row with no description' 'yes' (Test-Names (Get-Outcome) $where)

  Set-Plant "area`tarea:new`t1D76DB`tA description`tand a fifth column"
  Test-Check 'a row with a fifth column' 'yes' (Test-Names (Get-Outcome) $where)

  Set-Plant "area`tarea:gate`t1D76DB`tThe same name a second time"
  Test-Check 'a name declared twice' 'yes' (Test-Names (Get-Outcome) $where)

  # WHAT THE REFUSALS ARE WORTH. board-sync's old reading of the same misspelt file, so
  # the checks above are shown to be the guard and not a reader that refuses whatever it
  # is given.
  ''
  'what the reader that did not look answered for the same file'

  Set-Plant "typ`ttyp:bug`tD73A4A`tA mechanism that misbehaves today"
  $old = @(Get-Content $file | Where-Object { $_ -and -not $_.StartsWith('#') } |
             ForEach-Object { $c = $_ -split "`t"; if ($c[0] -eq 'type') { $c[1] } } |
             Where-Object { $_ -eq 'typ:bug' })
  Test-Check 'the plant: the old parse never saw the row' 0 $old.Count
  Test-Check 'the plant: and it ended without an error'   'no error' `
    $(try { Get-Content $file | Where-Object { $_ -match '^type' } | Out-Null; 'no error' } catch { "$_" })

  # THE INNOCENT CASE. The repository's own file, restored, must read.
  ''
  "the repository's own labels.tsv"

  Copy-Item $keep $file -Force
  Test-Check 'reads without refusing' 'read' (Get-Outcome)

  $all = @(Get-LabelTaxonomy -Path $file)
  $wrong = @($all | Where-Object { -not $_.Name.StartsWith("$($_.Group):") })
  Test-Check 'and every row carries its own prefix' 'ok' `
    $(if ($wrong) { ($wrong | ForEach-Object { "$($_.Group)/$($_.Name)" }) -join ' ' } else { 'ok' })

  Test-Check 'the type group is not empty'   'yes' $(if ((Get-LabelNamesInGroup -Group 'type'   -Path $file).Count) { 'yes' } else { 'no' })
  Test-Check 'the area group is not empty'   'yes' $(if ((Get-LabelNamesInGroup -Group 'area'   -Path $file).Count) { 'yes' } else { 'no' })
  Test-Check 'the closes group is not empty' 'yes' $(if ((Get-LabelNamesInGroup -Group 'closes' -Path $file).Count) { 'yes' } else { 'no' })

  # HOW MUCH THE READER COVERED, printed rather than assumed: a count that moves when a
  # line is added is what says the assertions above ran against the whole file.
  ''
  "labels.tsv declares $($all.Count) labels: " +
    "$((Get-LabelNamesInGroup -Group 'type'   -Path $file).Count) type, " +
    "$((Get-LabelNamesInGroup -Group 'area'   -Path $file).Count) area, " +
    "$((Get-LabelNamesInGroup -Group 'closes' -Path $file).Count) closes"
}
finally { Remove-Item -Recurse -Force $work -EA SilentlyContinue }

if ($failed -gt 0) { ''; "$failed failed"; exit 1 }
''; 'all passed'
