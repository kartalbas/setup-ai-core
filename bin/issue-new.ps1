<#
.SYNOPSIS
Create an issue and put it on the board in one step - labels, priority, status and,
where it belongs to an epic, the parent link.

.EXAMPLE
./issue-new.ps1 -Repo example-org/example-repo -Title "Put every new issue on its board, or nobody reading the board sees it" `
                -BodyFile ./body.md -Label type:feature,area:gate -Priority P1 -Parent 12 `
                -AskedBy kartalbas -AskedIn "issue #1, comment of 2026-09-03"

.NOTES
THE TITLE CARRIES TWO HALVES: the ACTION, and the STAKE - what is wrong today, or what it costs
if nobody does it - joined with ", so ", ", or " or a colon. "Add the board-sync command" names
an artifact and fits twenty other tickets; "Put every new issue on its board, or nobody reading
the board sees it" says what will be different (rules.md, the issue rules). A title outside that
shape is REPORTED and the issue is created anyway: whether a title reads well is a judgment, and
a script cannot make it.

NO ISSUE WITHOUT A PERSON'S YES. -AskedBy names the login of whoever said yes and -AskedIn where
they said it; the two are written into the first line of the body, so a ticket nobody asked for
reads as one on the board. Refusing here is the tool's half of that rule; whether the name is
true is the person's, and the name on the ticket is what makes a false one visible to them.

Writes the new issue number to stdout, so it can be captured and reused. When a parent is
named, the issue the new one was attached to - repository, number and title - is reported
to the host, where a capture of the number does not swallow it.

The parent may live in any repository: OWNER/REPO#N and REPO#N name one, and a bare
number stays an issue of the repository the new issue is created in. It is resolved
before the issue is created, so a parent that does not exist stops the run with
nothing made.

The rules require a label for the TYPE of work and one for the AREA it touches, plus a
priority; this refuses to create an issue that is missing either, because an unlabelled
ticket is invisible on a board grouped by anything but status.
#>
[CmdletBinding()]
param(
  [string]                         $Repo,
  [Parameter(Mandatory)][string]   $Title,
  [Parameter(Mandatory)][string]   $BodyFile,
  [Parameter(Mandatory)][string[]] $Label,
  [Parameter(Mandatory)][ValidateSet('P0','P1','P2','P3','P9', IgnoreCase=$true)][string] $Priority,
  # No issue without a person's yes (rules.md, the issue rules): who said yes, and where.
  [Parameter(Mandatory)][string]   $AskedBy,
  [Parameter(Mandatory)][string]   $AskedIn,
  [string] $Status   = 'todo',
  [string] $Parent   = '',
  # Deliberately EMPTY. It is resolved from the repo below, once the repo is known —
  # defaulting to @me here is what put every backend issue on whoever ran the command.
  [string] $Assignee = '',
  [string] $Project  = ''
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../lib/Board.psm1') -Force

if (-not $Repo) { $Repo = Get-DefaultRepo }
# An explicit -Assignee wins; otherwise the repo says who owns its issues.
if (-not $Assignee) { $Assignee = Get-AssigneeForRepo -Repo $Repo }
Set-Project -Number $Project -Repo $Repo | Out-Null
if (-not (Test-Path $BodyFile)) { Stop-WithError "no such body file: $BodyFile" }
if ($Label.Count -lt 2) { Stop-WithError 'at least two labels are required: one for the type of work, one for the area' }

# The parent is resolved before anything is created: a reference that resolves nowhere
# stops the run with nothing made, instead of leaving a fresh issue attached to nothing.
$parentIssue = $null
if ($Parent) { $parentIssue = Resolve-ParentIssue -Reference $Parent -Repo $Repo }

# The body is written whole into a temporary file, and the ORIGINAL is left alone: a caller's
# file is theirs, and a command that edits its own input cannot be run twice.
$asked = "$(Get-AskedPrefix)$($AskedBy -replace '^@', '') on $(Get-Date -Format 'yyyy-MM-dd') in $AskedIn."
$sent = Join-Path ([IO.Path]::GetTempPath()) "issue-new-$([guid]::NewGuid().ToString('N').Substring(0,8)).md"
Set-Content -Path $sent -Value ($asked + "`n`n" + [IO.File]::ReadAllText($BodyFile)) -NoNewline -Encoding utf8NoBOM

# Reported, not enforced. Every check above refuses; this one only names what a reader will
# struggle with, and the issue is created either way.
Write-TitleReport -Title $Title

$args = @('issue','create','--repo',$Repo,'--title',$Title,'--body-file',$sent,'--assignee',$Assignee)
foreach ($l in $Label) { $args += @('--label', $l) }

$url = Invoke-Gh @args
$num = [int]($url -split '/')[-1]

$item = Get-ItemId $Repo $num
Set-Select $item 'Status'   $Status
Set-Select $item 'Priority' $Priority

# The attach goes through the addSubIssue mutation, which takes node ids and is not bound
# to one repository the way the REST sub_issues endpoint is - posting a number there reads
# it in ONE repository, and a parent meant for another silently becomes whatever issue
# carries that number here.
if ($parentIssue) {
  $m = 'mutation($parent:ID!, $child:ID!) { addSubIssue(input:{issueId:$parent, subIssueId:$child}) { issue { number } } }'
  Invoke-Gh api graphql -f "parent=$($parentIssue.NodeId)" -f "child=$(Get-IssueNodeId $Repo $num)" -f "query=$m" | Out-Null
  Write-Host "#$num -> sub-issue of $($parentIssue.Repo)#$($parentIssue.Number)  $($parentIssue.Title)"
}

Remove-Item $sent -ErrorAction SilentlyContinue

$num
