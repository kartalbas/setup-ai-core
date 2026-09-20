<#
.SYNOPSIS
Edit an existing issue's title and/or body.

.EXAMPLE
./issue-edit.ps1 -Repo example-org/example-repo -Number 12 -Title "New title"

.EXAMPLE
./issue-edit.ps1 -Number 12 -BodyFile ./body.md

.NOTES
At least one of title and body is required - a call that changes nothing is a mistake, and
refusing it here is cheaper than a run against GitHub that also changes nothing. The body
file must exist before GitHub is called. Only the fields the caller supplied are sent.

A new title is read the way issue-new reads a first one, and the report is a report: a title
carries an ACTION and its STAKE - what is wrong today, or what it costs if nobody does it -
joined with ", so ", ", or " or a colon (rules.md, the issue rules). "Add the board-sync
command" names an artifact and fits twenty other tickets; "Put every new issue on its board,
or nobody reading the board sees it" says what will be different. The edit is sent either way.

THE ASKED-FOR LINE SURVIVES THE EDIT. It is kept, not asked for and not composed - see below.
#>
[CmdletBinding()]
param(
  [string] $Repo,
  [Parameter(Mandatory)][ValidatePattern('^[0-9]+\z', ErrorMessage = "the issue number must be numeric, not '{0}'")][string] $Number,
  [string] $Title,
  [string] $BodyFile
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../lib/Board.psm1') -Force

# Refuse a pointless or impossible edit BEFORE anything is resolved or sent.
if (-not $Title -and -not $BodyFile) {
  Stop-WithError 'name a -Title or a -BodyFile - an edit that changes nothing is a mistake'
}
if ($BodyFile -and -not (Test-Path $BodyFile)) {
  Stop-WithError "the body file does not exist: $BodyFile"
}

if (-not $Repo) { $Repo = Get-DefaultRepo }

# Reported, not enforced.
if ($Title) { Write-TitleReport -Title $Title }

# THE FIRST LINE OF AN ISSUE BODY NAMES WHO ASKED FOR THE WORK, AND PATCH REPLACES THE WHOLE
# BODY. A file that does not carry that line therefore deletes it, with exit 0 and a verdict
# saying the edit went through, and nothing reports the loss.
#
# So the line is KEPT: where the new body does not open with one, the issue's current first line
# is read, and where THAT is an asked-for line it is put back on a temporary copy. The line that
# lands is the one the issue already carried. The alternative - refusing the body and telling the
# caller to carry the line - is an instruction to compose one from what the caller believes, and
# an invented line is indistinguishable on the board from a true one. Preserving beats refusing
# exactly because the rule says that line cannot be invented later.
#
# THE READ HAPPENS ONLY WHERE IT IS NEEDED. The body file's own first line is looked at first, so
# a body that already carries the line reaches GitHub once. Measured:
# the PATCH takes about 650 ms and the read about 470 ms, so the second call is paid only by an
# edit that would otherwise have destroyed the line. When that read is refused the edit STOPS,
# because the alternative is sending a body known to be missing the line.
#
# WHERE THE ISSUE ITSELF CARRIES NO SUCH LINE - an older issue, or one opened on the web - there
# is nothing to keep. That is reported and the body is sent as given: a command reports what a
# ticket is missing and never fills it in.
#
# The caller's own file is left alone, the way issue-new leaves it: a command that edits its
# input cannot be run twice.
$send = $BodyFile
$kept = ''
if ($BodyFile -and -not "$(@(Get-Content -LiteralPath $BodyFile -TotalCount 1)[0])".StartsWith((Get-AskedPrefix), [StringComparison]::Ordinal)) {
  # GitHub writes a body back with CRLF line endings, and the carriage return would travel into
  # the line being put back.
  $first = "$(@(Invoke-Gh api "repos/$Repo/issues/$Number" --jq '.body')[0])".TrimEnd("`r")
  if ($first.StartsWith((Get-AskedPrefix), [StringComparison]::Ordinal)) {
    $send = Join-Path ([IO.Path]::GetTempPath()) "issue-edit-$([guid]::NewGuid().ToString('N').Substring(0,8)).md"
    Set-Content -Path $send -Value ($first + "`n`n" + [IO.File]::ReadAllText($BodyFile)) -NoNewline -Encoding utf8NoBOM
    $kept = ', asked-for line kept'
  } else {
    Write-Host "$Repo#$Number carries no asked-for line, so there is none to keep - an edit is not the place to invent one"
  }
}

$call = @('api', '--method', 'PATCH', "repos/$Repo/issues/$Number")
if ($Title) { $call += @('-f', "title=$Title") }
if ($BodyFile) { $call += @('-F', "body=@$send") }
Invoke-Gh @call | Out-Null
if ($send -ne $BodyFile) { Remove-Item $send -ErrorAction SilentlyContinue }

$changed = @()
if ($Title) { $changed += 'title' }
if ($BodyFile) { $changed += 'body' }
"#$Number -> edited ($($changed -join ' and ')$kept)"
