<#
.SYNOPSIS
Read an issue and its whole comment thread.

.EXAMPLE
./issue-thread.ps1 -Repo example-org/example-repo -Number 163

.EXAMPLE
./issue-thread.ps1 -Number 163 -Json

.NOTES
This reads and prints; it changes nothing on the issue and nothing on the board.

Without -Json it is laid out for a person: the title, the state, the labels, a blank
line, the body, then every comment behind a line naming who wrote it and when. With
-Json it is one object on one line, for a script that has to work the thread out rather
than read it.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidatePattern('^[0-9]+\z', ErrorMessage = "the issue number must be numeric, not '{0}'")][string] $Number,
  [string] $Repo,
  [switch] $Json
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../lib/Board.psm1') -Force

if (-not $Repo) { $Repo = Get-DefaultRepo }

$thread = Get-IssueThread -Repo $Repo -Number $Number

if ($Json) {
  $thread | ConvertTo-Json -Depth 5 -Compress
  return
}

# An issue with no label prints a dash, the way board-list prints a missing field: an
# empty space after "labels:" reads as a line somebody forgot to finish.
$labels = if ($thread.labels.Count -eq 0) { '-' } else { $thread.labels -join ', ' }

"#$($thread.number) $($thread.title)"
"state: $($thread.state)"
"labels: $labels"
''
$thread.body
foreach ($said in $thread.comments) {
  ''
  "--- $($said.author) $($said.created_at)"
  $said.body
}
