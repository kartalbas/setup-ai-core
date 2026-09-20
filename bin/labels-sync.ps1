<#
.SYNOPSIS
Apply labels.tsv to a repo. Existing labels are updated in place, so running this twice
changes nothing the second time.

.EXAMPLE
./labels-sync.ps1
./labels-sync.ps1 -Repo example-org/example-repo
./labels-sync.ps1 -All -Project 5

.NOTES
It only adds and updates. A label that is in the repo but not in labels.tsv is reported
and left alone - deleting one would strip it off every issue that carries it.

-All means every repo on ONE board, so it needs to know which board. It takes the same
answer as every other script: -Project, else GH_PROJECT_NUMBER, else the board the
current directory's repo is linked to.
#>
[CmdletBinding()]
param([string[]] $Repo, [switch] $All, [string] $Project = '')

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../lib/Board.psm1') -Force

if ($All) {
  Set-Project -Number $Project | Out-Null
  $Repo = @(Get-ProjectRepos)
}
elseif (-not $Repo) { $Repo = @(Get-DefaultRepo) }

# Read once, before the first repo is touched. The taxonomy is held against its own shape in
# Get-LabelTaxonomy, and a file that cannot be read must stop the run rather than create part of
# it in the first repository and then die in the second.
$defs = @(Get-LabelTaxonomy)

foreach ($r in $Repo) {
  $r
  foreach ($d in $defs) {
    Invoke-Gh label create $d.Name --repo $r --color $d.Color --description $d.Description --force | Out-Null
    '  {0,-8} {1}' -f $d.Group, $d.Name
  }

  $extra = (Invoke-Gh label list --repo $r --limit 200 --json name --jq '.[].name') |
             Where-Object { $_ -cnotin $defs.Name }
  if ($extra) {
    '  not in labels.tsv, left alone:'
    $extra | ForEach-Object { "    $_" }
  }
}
