<#
.SYNOPSIS
Every repository of the organisation and the open board it is linked to.

.EXAMPLE
./repo-boards.ps1

.NOTES
Exits 1 when any repository is linked to NO open board, or to more than one. Exits 0 when
every one of them resolves to exactly one, which is the state every other script in bin/
needs.

WHY NOTHING ELSE COULD ANSWER THIS. Every other path into this tooling starts from a
repository and asks which board it resolves to, so a repository that resolves to none
stops that one call and is never counted; and board-sync sweeps "every repo linked to the
project", which by construction can never reach a repository linked to no project. The
question has to be asked from the ORGANISATION, which is the one side that can list a
repository nobody linked.

WHAT IT COSTS TO BE WRONG. An issue filed in an unlinked repository is on no board, so it
is invisible to whoever reads progress off the board, and it stays invisible until
somebody remembers it exists. Linked to more than one, the resolution is ambiguous and
every script refuses until a number is passed by hand.

The template board is not a board work is tracked on, so it does not count as a link - the
same rule Resolve-ProjectForRepo applies when it resolves one repository. A CLOSED project
does not count either, for the same reason: a repository keeps its old boards after they
are closed.

AN ARCHIVED REPOSITORY IS LISTED AND NOT COUNTED AGAINST THE RUN. It takes no new issues,
so a board link would put nothing on a board; reporting it as a gap would be a red nobody
can clear except by linking a dead repository.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../lib/Board.psm1') -Force

# Read from the module rather than typed here, so the two spellings of the mark cannot
# disagree with each other.
$mark = Get-TemplateMark

$q = 'query($o:String!, $after:String) { organization(login:$o) { repositories(first:100, after:$after) { pageInfo { hasNextPage endCursor } nodes { nameWithOwner isArchived projectsV2(first:50) { nodes { number title closed } } } } } }'

$repos = @()
$after = $null
do {
  $call = @('api', 'graphql', '-f', "o=$(Get-Org)", '-f', "query=$q")
  if ($after) { $call += @('-f', "after=$after") }
  $page = (Invoke-Gh @call | ConvertFrom-Json).data.organization.repositories
  $repos += $page.nodes
  $after = $page.pageInfo.endCursor
} while ($page.pageInfo.hasNextPage)

$unlinked = 0
$ambiguous = 0
$archived = 0
$counted = 0

foreach ($r in $repos) {
  if ($r.isArchived) {
    '  {0,-34} archived, not counted' -f $r.nameWithOwner
    $archived++
    continue
  }

  $boards = @($r.projectsV2.nodes |
    Where-Object { -not $_.closed -and -not "$($_.title)".StartsWith($mark, [StringComparison]::Ordinal) } |
    ForEach-Object { "$($_.number) $($_.title)" })

  $counted++
  if ($boards.Count -eq 0) {
    '  {0,-34} LINKED TO NO OPEN BOARD' -f $r.nameWithOwner
    $unlinked++
  }
  elseif ($boards.Count -eq 1) {
    '  {0,-34} {1}' -f $r.nameWithOwner, $boards[0]
  }
  else {
    '  {0,-34} LINKED TO {1} BOARDS: {2}' -f $r.nameWithOwner, $boards.Count, ($boards -join ', ')
    $ambiguous++
  }
}

''
"$counted repositories read, $archived archived and left out of the count"

# A COUNT WITH NO DENOMINATOR SAYS NOTHING, so both halves are printed even when they are
# zero - a run that found nothing and a run that looked at nothing print differently.
"$unlinked linked to no open board, $ambiguous linked to more than one"

if ($unlinked + $ambiguous -gt 0) { exit 1 }
