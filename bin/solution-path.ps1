<#
.SYNOPSIS
Check a solution path and post it under its issue.

.EXAMPLE
./solution-path.ps1 -Number 163 -File ./solution-path.md

.EXAMPLE
./solution-path.ps1 -Number 163 -File ./solution-path.md -Check

.NOTES
The seven fields and the reuse manifest are what makes a decision reviewable: where a person
meets it, what they see today, what runs behind that, the decision itself, the options with
what each costs, the recommendation, the code facts, and the list of everything that already
exists and that this change touches or resembles. A missing field is not a formatting slip -
it is the part of the answer that was not thought through, and it is cheapest to notice before
the code is written.

A section is measured by what it CONTAINS and not by whether its heading is there, because a
heading with nothing under it reads as a filled-in field to every list that counts headings.

-Check validates and posts nothing, for a writer who wants to know before they send.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidatePattern('^[0-9]+\z', ErrorMessage = "the issue number must be numeric, not '{0}'")][string] $Number,
  [Parameter(Mandatory)][string] $File,
  [switch] $Check
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../lib/Board.psm1') -Force

# The headings a solution path must carry, in the order a reader walks them.
$Required = @(
  'Where a person meets this'
  'What they see today'
  'What the system does behind it'
  'The decision'
  'Options'
  'Recommendation'
  'Code facts'
  'Reuse manifest'
)

if (-not (Test-Path -LiteralPath $File)) { Stop-WithError "there is no file at $File" }

function Get-Sections {
  # What each "## " heading has under it, down to the next one of the same level. A deeper
  # heading stands INSIDE its section and neither opens nor ends one. A heading that stands
  # twice is recorded as well, because only one of its two bodies is ever read.
  param([Parameter(Mandatory)][string]$Path)
  $sections = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
  $doubled = [System.Collections.Generic.List[string]]::new()
  $current = $null
  $held = [System.Collections.Generic.List[string]]::new()
  foreach ($line in [IO.File]::ReadAllLines($Path)) {
    if ($line -match '^##[ \t]') {
      if ($null -ne $current) { $sections[$current] = ($held -join "`n").Trim() }
      $current = $line.Substring(3).Trim()
      if ($sections.Contains($current) -and -not $doubled.Contains($current)) { $doubled.Add($current) }
      $held.Clear()
      continue
    }
    if ($null -ne $current) { $held.Add($line) }
  }
  if ($null -ne $current) { $sections[$current] = ($held -join "`n").Trim() }
  return [pscustomobject]@{ Sections = $sections; Doubled = $doubled }
}

$read = Get-Sections -Path $File
$sections = $read.Sections

# A required heading that stands twice is refused before anything else is judged. Only one of
# its two bodies is ever read, and which one it is differs between the two shells, so the same
# file would be accepted by one and refused by the other.
$doubled = @($Required | Where-Object { $read.Doubled -ccontains $_ })
if ($doubled.Count -gt 0) {
  Write-Error "$File names `"## $($doubled -join '", "## ')`" twice." -ErrorAction Continue
  Stop-WithError 'a required heading may stand only once - with two of them one body is read and the other is not'
}

$absent = @($Required | Where-Object { -not $sections.Contains($_) })
$empty = @($Required | Where-Object { $sections.Contains($_) -and $sections[$_] -eq '' })

if ($absent.Count -gt 0 -or $empty.Count -gt 0) {
  if ($absent.Count -gt 0) {
    Write-Error "$File has no `"## $($absent -join '", no "## ')`" heading." -ErrorAction Continue
  }
  if ($empty.Count -gt 0) {
    Write-Error "$File leaves `"$($empty -join '", "')`" empty." -ErrorAction Continue
  }
  Stop-WithError 'write those sections, then run this again - code starts after the solution path is posted'
}

"$File carries all $($Required.Count) sections."

if ($Check) {
  'Checked only - nothing was posted.'
  return
}

# The file travels as a file: its backticks, quotes and newlines reach GitHub as they were
# written, because no shell reads them on the way.
try { & (Join-Path $PSScriptRoot 'issue-comment.ps1') -Number $Number -BodyFile $File }
catch { Stop-WithError "the solution path was NOT posted: $($_.Exception.Message)" }
