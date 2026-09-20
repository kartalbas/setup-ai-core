<#
.SYNOPSIS
Add a comment to an issue.

.EXAMPLE
./issue-comment.ps1 -Repo example-org/example-repo -Number 94 -Body "Comment here"

.EXAMPLE
./issue-comment.ps1 -Number 94 -BodyFile ./comment.md

.NOTES
The body comes inline or from a file, and exactly one of the two. A long comment belongs
in a file. Its backticks, quotes and newlines then reach GitHub as they were written,
because no shell reads them on the way. The file must exist before GitHub is called. What
gh prints - the comment URL - is passed straight through.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidatePattern('^[0-9]+\z', ErrorMessage = "the issue number must be numeric, not '{0}'")][string] $Number,
  [string] $Body,
  [string] $BodyFile,
  [string] $Repo
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../lib/Board.psm1') -Force

# Refuse an empty or a double-sourced comment BEFORE anything is resolved or sent.
if (-not $Body -and -not $BodyFile) {
  Stop-WithError 'name a body or a -BodyFile - a comment with no text is a mistake'
}
if ($Body -and $BodyFile) {
  Stop-WithError 'name a body or a -BodyFile, not both - which one is the comment is not for a script to guess'
}
if ($BodyFile -and -not (Test-Path $BodyFile)) {
  Stop-WithError "the body file does not exist: $BodyFile"
}

if (-not $Repo) { $Repo = Get-DefaultRepo }

if ($BodyFile) { Invoke-Gh issue comment $Number --repo $Repo --body-file $BodyFile }
else           { Invoke-Gh issue comment $Number --repo $Repo --body $Body }
