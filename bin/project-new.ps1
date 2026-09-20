<#
.SYNOPSIS
Create a board by copying an existing one, so a new board has the same fields, the same
options and the same views as the boards already in use.

.EXAMPLE
./project-new.ps1 -Title project-example
./project-new.ps1 -Title project-example -Like 5

.NOTES
Writes the new project number to stdout.

With no -Like the source is the org's template board, found by its title rather than by a
number written down here, so renumbering or replacing the template does not break this.

Copying rather than building the fields one call at a time is deliberate: a hand-built
board drifts from the others in the details nobody checks - an option colour, a
description, the order of the columns - and those are exactly what makes two boards read
differently to the same person. The items of the source board are not copied.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string] $Title,
  [ValidatePattern('^[0-9]+\z', ErrorMessage = "the board number must be numeric, not '{0}'")][string] $Like = ''
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../lib/Board.psm1') -Force

$org = Invoke-Gh api graphql -f "o=$(Get-Org)" `
         -f 'query=query($o:String!){ organization(login:$o){ id } }' --jq '.data.organization.id'

if (-not $Like) { $Like = Get-TemplateProjectNumber }

$src = Invoke-Gh api graphql -f "o=$(Get-Org)" -F "n=$Like" `
         -f 'query=query($o:String!,$n:Int!){ organization(login:$o){ projectV2(number:$n){ id } } }' `
         --jq '.data.organization.projectV2.id'
if (-not $src) { Stop-WithError "no project $Like in $(Get-Org) to copy from" }

$m = 'mutation($pid:ID!,$oid:ID!,$t:String!){ copyProjectV2(input:{projectId:$pid, ownerId:$oid, title:$t, includeDraftIssues:false}){ projectV2 { number url } } }'
$made = Invoke-Gh api graphql -f "pid=$src" -f "oid=$org" -f "t=$Title" -f "query=$m" `
          --jq '.data.copyProjectV2.projectV2 | "\(.number)\t\(.url)"'

$num, $url = $made -split "`t"
"created: $Title  ->  $url"
$num
