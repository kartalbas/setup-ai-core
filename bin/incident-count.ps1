<#
.SYNOPSIS
How many tickets picked up each incident label, week by week.

.EXAMPLE
./incident-count.ps1

.EXAMPLE
./incident-count.ps1 -Repo example-org/example-repo -Weeks 12

.NOTES
One row per `incident:` label in labels.tsv, one column per ISO week, oldest week first.
It reads and prints; it sets no field and it writes no label.

With no repository named it reads BOTH boards. How well the tickets themselves are written is a
question about the organisation and not about one board, and an answer covering half of it reads
as an answer covering all of it. The boards are the org's own open projects, found the way
project-new finds the template - by asking - so a third board is included the day it exists
rather than the day somebody remembers to edit a number in here.

A ticket counts in the week it was CREATED, taken in UTC, so the same run on two machines in two
time zones puts the same ticket in the same column.
#>
[CmdletBinding()]
param([string[]] $Repo, [ValidatePattern('^[0-9]+\z', ErrorMessage = "--weeks must be numeric, not '{0}'")][string] $Weeks = '8')

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../lib/Board.psm1') -Force

# The window arrives as text, judged by the same rule the shell twin uses, and is converted once
# here. Left as text it would be compared as text: '10' -lt 1 answers True, because PowerShell
# converts the RIGHT operand to the left one's type and '10' sorts before '1'.
$span = [int]$Weeks
if ($span -lt 1) { Stop-WithError '-Weeks must be at least 1' }

function Get-IsoWeek {
  # The ISO year and week of a moment, in UTC. ISO puts the first days of January in the
  # last week of the year before, so the year has to come from the same calendar as the
  # week or the two disagree once every twelve months.
  param([Parameter(Mandatory)][datetime]$When)
  $utc = $When.ToUniversalTime()
  '{0}-W{1:d2}' -f [System.Globalization.ISOWeek]::GetYear($utc),
                    [System.Globalization.ISOWeek]::GetWeekOfYear($utc)
}

# Every repository of every open board of the organisation, without the template board - which
# is a shape to copy and tracks no work.
function Get-EveryBoardRepo {
  $q = 'query($o:String!) { organization(login:$o) { projectsV2(first:100) { nodes { number title closed } } } }'
  $boards = @(Invoke-Gh api graphql -f "o=$(Get-Org)" -f "query=$q" `
                --jq '.data.organization.projectsV2.nodes[] | select(.closed == false) | "\(.number)\t\(.title)"' |
              Where-Object { $_ -and -not (($_ -split "`t")[1]).StartsWith((Get-TemplateMark), [StringComparison]::Ordinal) })
  if ($boards.Count -eq 0) { Stop-WithError "no open board in $(Get-Org) - name the repositories to count over" }
  $found = @()
  foreach ($row in $boards) {
    Set-Project -Number (($row -split "`t")[0]) | Out-Null
    $found += @(Get-ProjectRepos)
  }
  return @($found | Where-Object { $_ } | Select-Object -Unique)
}

if (-not $Repo) {
  $Repo = Get-EveryBoardRepo
  if ($Repo.Count -eq 0) { Stop-WithError 'no repository is linked to an open board - name the repositories to count over' }
}

# The taxonomy is the list of incident labels - one definition, the same file issue-label and
# labels-sync read, held against its shape by the same reader.
$labels = @(Get-LabelNamesInGroup -Group 'incident')
if ($labels.Count -eq 0) { Stop-WithError 'labels.tsv holds no incident label - there is nothing to count' }

# The columns: the last N ISO weeks, oldest first, the current week last.
$now = [datetime]::UtcNow
$columns = @(for ($back = $span - 1; $back -ge 0; $back--) { Get-IsoWeek ($now.AddDays(-7 * $back)) })

# The first day the table can show anything for: the Monday of the oldest column. The query
# asks for that day onwards, so the reply holds what the window needs and nothing older.
$oldest = $now.AddDays(-7 * ($span - 1))
$firstDay = $oldest.AddDays(-((([int]$oldest.DayOfWeek) + 6) % 7)).ToString('yyyy-MM-dd')

# gh returns the newest Limit issues and says nothing about the rest, so a reply that reaches
# the limit is a count that may be short. It is refused rather than printed.
$limit = 500

$seen = @()
foreach ($r in $Repo) {
  # gh prints JSON over many lines, and each line arrives here as its own string. They
  # are joined back into one document first, or the parser stops at the end of line one.
  # The field list is QUOTED. Unquoted, the comma is PowerShell's array operator and the two
  # names reach gh as two arguments, which it refuses.
  $issues = @(((Invoke-Gh issue list --repo $r --state all --limit $limit `
    --search "created:>=$firstDay" --json 'createdAt,labels') -join "`n") | ConvertFrom-Json)
  if ($issues.Count -ge $limit) {
    Stop-WithError "more than $limit issues in the window for $r - the count would be partial"
  }
  foreach ($issue in $issues) {
    $week = Get-IsoWeek ([datetime]$issue.createdAt)
    foreach ($name in @($issue.labels.name)) {
      if ($name -clike 'incident:*') { $seen += [pscustomobject]@{ Label = $name; Week = $week } }
    }
  }
}

$line = '{0,-24}' -f 'label'
foreach ($week in $columns) { $line += '{0,9}' -f $week }
$line

foreach ($label in $labels) {
  $line = '{0,-24}' -f $label
  foreach ($week in $columns) {
    $line += '{0,9}' -f @($seen | Where-Object { $_.Label -ceq $label -and $_.Week -ceq $week }).Count
  }
  $line
}
