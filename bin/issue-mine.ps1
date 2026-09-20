<#
.SYNOPSIS
Is this issue assigned to the account this session runs as?

.DESCRIPTION
  issue-mine.ps1 -Number N [-Repo OWNER/REPO]

Exit 0 and one line when the account (gh's login) is among the issue's assignees. Exit 1 with
a REFUSED line otherwise - an issue assigned to nobody as much as one assigned to somebody
else. This is the one check behind start-issue and session-start: only an issue assigned to
you is taken up (rules.md, the issue rules).
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidatePattern('^[0-9]+\z', ErrorMessage = "the issue number must be numeric, not '{0}'")][string] $Number,
  [string] $Repo
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../lib/Board.psm1') -Force

if (-not $Repo) { $Repo = Get-DefaultRepo }

$login = "$(((Invoke-Gh api user) -join "`n" | ConvertFrom-Json).login)"
if ($login -eq '') { Stop-WithError "cannot read who gh is logged in as - run 'gh auth status'" }
$issue = ((Invoke-Gh api "repos/$Repo/issues/$Number") -join "`n") | ConvertFrom-Json
$assignees = @($issue.assignees | ForEach-Object { "$($_.login)" } | Where-Object { $_ })

if ($assignees -ccontains $login) { "#$Number is assigned to @$login."; exit 0 }
if ($assignees.Count -eq 0) {
  "REFUSED: #$Number is assigned to nobody - the product owner assigns it before it is taken up."
} else {
  "REFUSED: #$Number is assigned to $(($assignees | ForEach-Object { "@$_" }) -join ', '), not to @$login - ask them or the product owner to reassign it."
}
exit 1
