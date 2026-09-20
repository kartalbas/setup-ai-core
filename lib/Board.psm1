#Requires -Version 7.5

# Shared helpers for every script in bin/*.ps1. The PowerShell twin of lib/board.sh -
# same behaviour, same cache files, so the two can be used interchangeably on the
# same working copy.
#
# THE VERSION IS REFUSED HERE, AT THE IMPORT, AND NOWHERE ELSE. Get-IssueThread reads JSON with
# `ConvertFrom-Json -DateKind String`, which arrived in PowerShell 7.5. On an older shell that
# switch is a binder error from deep inside a function, and the person reads a sentence about a
# parameter name instead of one naming the version. Every bin/*.ps1 imports this module first,
# so one line here answers for all of them.
#
# The board is addressed by NAME throughout - "Status", "Todo", "P1". The ids behind
# those names are looked up from GitHub and cached; a name that no longer exists stops
# the script with the list of names that do, because writing a stale id succeeds
# silently and puts the card in the wrong column.
#
# Neither a project nor a repo is baked in. The repo comes from the caller or from the
# directory the caller stands in; the project is whichever project that repo is linked
# to. A repo linked to no project, or to more than one, stops the script rather than
# guessing - a guess here writes a card onto the wrong board.
#
# EVERY FUNCTION HERE CARRIES [CmdletBinding()], AND Invoke-Gh IS THE ONE EXCEPTION.
#
# A function without it is not an advanced function, and a plain function does not refuse a
# parameter name it does not have: PowerShell drops the name AND its value into $args, leaves
# the parameter it was meant for empty, and runs on whatever that emptiness defaults to. Here
# that default is the board of the current directory, which is a real board - so a call naming
# a board writes to a different one and nothing on either side says so. Adding a parameter to a
# function below without adding [CmdletBinding()] re-opens exactly that.

$script:Root = Split-Path -Parent $PSScriptRoot

# WHAT gh WRITES IS UTF-8, AND THIS IS WHERE PowerShell IS TOLD SO.
#
# PowerShell decodes a native command's standard output with [Console]::OutputEncoding, which
# on Windows is the console code page - ibm437 on a default installation. gh writes UTF-8, so
# the two bytes of the middle dot in an epic title come back as two box-drawing characters, an
# umlaut comes back as two, and a euro sign as three. The run still exits 0, so nothing says
# the title being printed is not the title GitHub holds.
#
# It is set here and not inside Invoke-Gh because [Console]::OutputEncoding belongs to the
# PROCESS, and several scripts in bin/ run gh directly instead of through Invoke-Gh. Importing
# this module is the one thing every one of them does first, so this reaches all of them.
[Console]::OutputEncoding = [Text.Encoding]::UTF8

function Stop-WithError { [CmdletBinding()] param([string]$Message) throw "error: $Message" }

# --- where the data lives -----------------------------------------------------

# THE DATA FILES ARE THE PROJECT'S, NOT THE HARNESS'S: labels.tsv, assignees.tsv, team-modes.tsv.
# A checkout carries them in .ai-core\, put there by init; the clone's templates hold the
# defaults a project starts from. Every reader asks here, so the two twins and every command
# read the same file: the one of the repository the caller stands in, or of the project folder.
function Get-DataDir {
  [CmdletBinding()] param()
  $top = $null
  try { $top = & git rev-parse --show-toplevel 2>$null; if ($LASTEXITCODE -ne 0) { $top = $null } } catch { $top = $null }
  if (-not $top) { $top = (Get-Location).Path }
  return (Join-Path $top '.ai-core')
}
function Get-DataFile {
  [CmdletBinding()] param([Parameter(Mandatory)][string]$Name)
  $f = Join-Path (Get-DataDir) $Name
  if (Test-Path $f) { return $f }
  return (Join-Path $script:Root "templates/.ai-core/$Name")
}

function ConvertTo-AsciiLowercase {
  # A to Z lowercased, and every other character left exactly as it stands.
  #
  # THE SHELL TWINS FOLD WITH `tr '[:upper:]' '[:lower:]'`, WHICH MAPS A-Z AND NOTHING ELSE, and
  # .ToLowerInvariant() folds every uppercase letter Unicode knows. The two part company on any
  # character Unicode lowercases into ASCII: U+212A KELVIN SIGN becomes `k` on the .NET side and
  # stays itself on the shell side, so one issue title produces two worktree names. Measured
  # on the bytes 4B C3 84 4B E2 84 AA: `tr` answers 6B C3 84 6B E2 84 AA.
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
  return $Text -creplace '[A-Z]', { $_.Value.ToLowerInvariant() }
}

function Invoke-Gh {
  # THE ONE FUNCTION IN THIS FILE THAT STAYS A PLAIN FUNCTION, because [CmdletBinding()] would
  # take gh's arguments away from it. Measured on pwsh 7.6.5.
  #
  # [CmdletBinding()] REMOVES $args. An advanced function has none, so the splat below would
  # have nothing to hand gh - and the call never gets that far, it stops at the binder:
  #
  #   function A { [CmdletBinding()] param() $args }
  #   A api graphql -f q=x  ->  A positional parameter cannot be found that accepts argument 'api'.
  #
  # The one advanced shape that still takes a whole command line is a parameter declared
  # ValueFromRemainingArguments, and that parameter does NOT receive every token: the binder
  # takes the common parameters and their unambiguous prefixes FIRST, and what it takes never
  # reaches gh. Against param([Parameter(ValueFromRemainingArguments=$true)][string[]]$GhArgs):
  #
  #   A api -Verbose      ->  GhArgs=[api]        and $VerbosePreference flipped to Continue
  #   A api -d value      ->  GhArgs=[api|value]  -d bound to -Debug, the flag is gone from the call
  #   A api -v value      ->  GhArgs=[api|value]  -v bound to -Verbose, the flag is gone from the call
  #   A api -o value      ->  the parameter name 'o' is ambiguous. Possible matches include:
  #                           -OutVariable -OutBuffer.
  #   A api -Project 5    ->  GhArgs=[api|-Project|5]
  #
  # The last line is the class this file is guarding: a name Board.psm1 does not have falls
  # through to gh either way, and gh answers `unknown command "5" for "gh"`. So the advanced
  # form buys no refusal for that class while silently dropping one-letter gh flags out of the
  # command line and refusing five more outright. gh refuses a flag it does not have, which is
  # where that check belongs.
  #
  # Arguments reach gh EXACTLY as written, double quotes and all.
  #
  # Every jq program in this repository is built out of double-quoted strings - `== "CLOSED"`,
  # `// "-"`, `"\(.number)\t\(.title)"`. Under the LEGACY argument passing that PowerShell used
  # before 7.3 those quotes are dropped on the way to the process: jq is handed `== CLOSED`,
  # and the call dies with a jq syntax error that nothing on the board explains. The pin sits
  # here because this is the one place every gh call goes through, and what a caller's profile
  # has set is not something a script may depend on.
  $PSNativeCommandArgumentPassing = 'Standard'

  # EVERY gh CALL IN THIS REPOSITORY GOES THROUGH HERE, and this is why.
  #
  # A refused query is not an empty result. When the server refuses, gh writes the whole error body
  # to STDOUT - where the rows would be - puts a one-line complaint on stderr, and exits non-zero.
  # It does that even when --jq was given, because the jq program never runs at all. So a caller
  # that reads stdout and counts lines reads the complaint as data: a board with one row that is
  # not a card, a repo linked to no project, an archived card that is not there.
  #
  # The exit status is the one signal that tells an answer from a refusal, whatever shape the rows
  # have, so it is checked here and the output is handed back only when gh said it answered. What
  # it wrote to stderr is left alone: that is the sentence naming why, and a `2>$null` on the call
  # leaves nothing on the screen but a run that stopped.
  #
  # WHAT THIS CANNOT SAY is whether the answer is the one that was asked for: a query gh accepts
  # answers `{}` with exit 0 when the id it was given belongs to something else. That is a question
  # about the VALUE, and it is asked where the value is used - see Get-ProjectId.
  $out = & gh @args
  if ($LASTEXITCODE -ne 0) {
    $answered = ($out -join ' ')
    Stop-WithError ("gh $($args -join ' ') failed with exit code $LASTEXITCODE" +
                    $(if ($answered) { ", and answered: $answered" }))
  }
  return $out
}

# THE ORGANISATION, for a command that names no repository: GH_ORG in the environment, then
# GH_ORG= in the checkout's .ai-core\config.env (the project's setting, put there by init), then
# the owner of the repository the caller stands in. The harness itself names none: it serves many.
function Get-Org {
  [CmdletBinding()] param()
  if ($env:GH_ORG) { return $env:GH_ORG }
  # Resolved once per process: the answer is kept in the environment so no later call asks gh again
  $config = Join-Path (Get-DataDir) 'config.env'
  if (Test-Path $config) {
    $line = Get-Content $config | Where-Object { $_ -cmatch '^\s*GH_ORG\s*=' } | Select-Object -Last 1
    if ($line) {
      $v = (($line -split '=', 2)[1] -split '#', 2)[0].Trim(' ', "`t", "`r", '"', "'")
      if ($v) { $env:GH_ORG = $v; return $v }
    }
  }
  $r = & gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $r) { Stop-WithError 'no organisation: set GH_ORG in .ai-core/config.env or the environment, or run this inside a repository of it' }
  $env:GH_ORG = ($r.Trim() -split '/', 2)[0]
  return $env:GH_ORG
}

# --- the label taxonomy -------------------------------------------------------

# The groups a row may stand in. The group is also the PREFIX the label carries, so a
# row in group `area` is named `area:something` - the two cannot be told apart and so
# cannot disagree.
$script:LabelGroups = @('type', 'area', 'closes', 'incident')

function Get-LabelTaxonomy {
  # EVERY READER OF labels.tsv COMES THROUGH HERE, and the file is held against its
  # shape before a single name leaves this function.
  #
  # The file is read by labels-sync to create the labels, by board-sync to decide which
  # ticket is missing one, and by issue-label to refuse a name outside the taxonomy.
  # Three readers parsing it three ways, none of them looking at what it found, is what
  # this closes: a row whose group is misspelt is simply not seen by board-sync's group
  # filter, so every ticket in the organisation is reported as missing a label that is
  # on it, and the run stays green because finding nothing is what green looks like. A
  # row named `area:gate` filed under group `type` is the same defect one step worse -
  # it is counted as the family it is not.
  # THE FILE IS A PARAMETER, defaulting to the repository's own. A reader that could only
  # ever read one path would force the test to plant its shapes into the tracked file and
  # put it back afterwards - so the two twins could not run at the same time without each
  # reading the other's plant, and a killed run would leave the taxonomy damaged in the working
  # tree.
  [CmdletBinding()]
  param([string]$Path)

  $file = if ($Path) { $Path } else { Get-DataFile 'labels.tsv' }
  if (-not (Test-Path $file)) { Stop-WithError "missing label taxonomy: $file" }

  $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  $no = 0
  foreach ($line in [IO.File]::ReadAllLines($file)) {
    $no++
    if ($line -eq '' -or $line.StartsWith('#', [StringComparison]::Ordinal)) { continue }
    $c = $line -split "`t"
    $group = $c[0]
    $name  = if ($c.Count -gt 1) { $c[1] } else { '' }
    $color = if ($c.Count -gt 2) { $c[2] } else { '' }
    $desc  = if ($c.Count -gt 3) { $c[3] } else { '' }

    if ($script:LabelGroups -cnotcontains $group) {
      Stop-WithError "${file}:${no} is in group '$group', and there is only $($script:LabelGroups -join ' ')"
    }
    if (-not $name.StartsWith("${group}:", [StringComparison]::Ordinal) -or $name.Length -le $group.Length + 1) {
      Stop-WithError "${file}:${no} is in group '$group' but is named '$name' - a row's name carries its own group as its prefix"
    }
    if ($color -notmatch '^[0-9A-Fa-f]{6}\z') {
      Stop-WithError "${file}:${no} has '$color' where a six-digit hex colour belongs"
    }
    if (-not $desc) {
      Stop-WithError "${file}:${no} has no description, and every label on the board carries one"
    }
    if ($c.Count -gt 4) { Stop-WithError "${file}:${no} has more than four columns: $line" }
    if (-not $seen.Add($name)) { Stop-WithError "${file}:${no} declares '$name' a second time" }

    [pscustomobject]@{ Group = $group; Name = $name; Color = $color; Description = $desc }
  }
}

function Get-LabelNamesInGroup {
  # The names of one group, in the order the file declares them.
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Group, [string]$Path)
  @(Get-LabelTaxonomy -Path $Path | Where-Object Group -ceq $Group | ForEach-Object Name)
}

# --- repositories -------------------------------------------------------------

function Get-AssigneeForRepo {
  # Who a new issue in this repo belongs to.
  #
  # An issue lands on whoever OWNS the repository, not on whoever typed the command,
  # and the mapping is a file both shells read so the two cannot drift. A repo nobody
  # listed falls back to @me — a new repo should assign to the person setting it up
  # rather than refuse, and adding a line is how that stops.
  #
  # It is called AFTER the repo is known. Resolving a default before that is what
  # produced the wrong assignee in the first place.
  #
  # THE FILE IS A PARAMETER, defaulting to the repository's own, for the reason written above
  # Get-LabelTaxonomy: a reader that could only ever read one path would force the test to plant
  # into the tracked file and put it back afterwards, so two suites running at once would each
  # restore what the other planted and the tracked map would hold a test's plant.
  #
  # A COLUMN IS THE BYTES BETWEEN THE TABS, and the file's own header says so. A row carries
  # exactly one tab and neither column may begin or end with a space. A row that breaks that is
  # refused by name rather than repaired: trimming would have this reader decide what somebody
  # meant, and the shell twin compares the raw field, so `example-org/x <TAB>one` would answer
  # `one` here and `@me` there; refusing to match without saying so hands the issue to @me with
  # nobody told.
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][string]$Repo, [string]$Path)

  $file = if ($Path) { $Path } else { Get-DataFile 'assignees.tsv' }
  if (-not (Test-Path $file)) { Stop-WithError "missing assignee map: $file" }

  $found = $null
  $no = 0
  foreach ($line in [IO.File]::ReadAllLines($file)) {
    $no++
    if ($line -ceq '' -or $line.StartsWith('#', [StringComparison]::Ordinal)) { continue }
    # Exactly two tab-separated columns. A third means somebody wrote something the
    # next reader would take for data.
    $cols = $line -csplit "`t"
    if ($cols.Count -ne 2 -or -not $cols[0] -or -not $cols[1]) {
      Stop-WithError "${file}:${no} is not 'repo<TAB>login': $line"
    }
    if ($cols[0].StartsWith(' ', [StringComparison]::Ordinal) -or $cols[0].EndsWith(' ', [StringComparison]::Ordinal) -or
        $cols[1].StartsWith(' ', [StringComparison]::Ordinal) -or $cols[1].EndsWith(' ', [StringComparison]::Ordinal)) {
      Stop-WithError "${file}:${no} has a space at the edge of a column, and the format allows none: '$($cols[0])' '$($cols[1])'"
    }
    if ($cols[0] -ceq $Repo) {
      if ($null -ne $found) {
        Stop-WithError "$file lists $Repo twice - which one is right is not for a script to guess"
      }
      $found = $cols[1]
    }
  }

  if ($null -eq $found) { return '@me' }
  return $found
}

function Get-DefaultRepo {
  # Which repo to act on. A colleague standing in their own checkout does not have to
  # type it; anyone driving another repo from elsewhere passes it explicitly.
  # The ONE gh call that does not go through Invoke-Gh, and it still checks the same signal. What
  # it would gain there is gh's answer in the message, and there is none to gain: this call answers
  # with a name or with nothing. What a person needs here is what to type instead, so that is what
  # it says, and gh's own line on stderr says whether standing outside a checkout was the reason.
  [CmdletBinding()]
  param()
  $r = & gh repo view --json nameWithOwner --jq '.nameWithOwner'
  if ($LASTEXITCODE -ne 0 -or -not $r) { Stop-WithError 'not inside a GitHub repo - pass the repo as OWNER/REPO' }
  return $r.Trim()
}

# --- the project --------------------------------------------------------------

# Set once per process by every bin script, so the whole run acts on one board.
$script:Project = $null
$script:ProjectOrg = $null

function Set-Project {
  # Resolution order: what the caller asked for, then the environment, then the single
  # project the repo is linked to. Nothing is defaulted beyond that.
  #
  # EVERY BOARD NUMBER ARRIVES HERE, from a -Project parameter, from GH_PROJECT_NUMBER or from
  # the repo's own link, so this is where one is judged and there is no second copy of the rule
  # in the commands that pass one in. It is the twin of the same line in set_project.
  [CmdletBinding()]
  [OutputType([string])]
  param([string]$Number, [string]$Repo)

  # A BOARD IS WRITTEN N OR ORG/N - see set_project in lib/board.sh, of which this is the twin.
  $n = if ($Number) { $Number } elseif ($env:GH_PROJECT_NUMBER) { $env:GH_PROJECT_NUMBER } else { $null }
  $org = $null
  if ("$n" -match '/') {
    $org, $n = "$n" -split '/', 2
    if (-not $org -or -not $n) { Stop-WithError "a board is written N or ORG/N, not '$(if ($Number) { $Number } else { $env:GH_PROJECT_NUMBER })'" }
  }
  if (-not $n) {
    if (-not $Repo) { $Repo = Get-DefaultRepo }
    $n = Resolve-ProjectForRepo $Repo
  }
  if ("$n" -cnotmatch '^[0-9]+\z') { Stop-WithError "the board number must be numeric, not '$n'" }
  if (-not $org) { $org = if ($Repo) { ($Repo -split '/', 2)[0] } else { Get-Org } }
  $script:Project = "$n"
  $script:ProjectOrg = "$org"
  return $script:Project
}

# The organisation the selected board lives under - see Set-Project for how it is chosen.
function Get-ProjectOrg {
  [CmdletBinding()]
  param()
  if (-not $script:ProjectOrg) { Stop-WithError 'no project selected - call Set-Project first' }
  return $script:ProjectOrg
}

function Get-ProjectNumber {
  [CmdletBinding()]
  param()
  if (-not $script:Project) { Stop-WithError 'no project selected - call Set-Project first' }
  return $script:Project
}

# A board whose title starts with this is a shape to copy, never a board work is tracked
# on. It stays unlinked from every repo, and is skipped here in case somebody links it.
$script:TemplateMark = '[TEMPLATE]'

# Read by the scripts that decide what counts as a link to a board. Without it the mark
# would be typed a second time in bin/, and two spellings of it disagree in silence.
function Get-TemplateMark { [CmdletBinding()] param() $script:TemplateMark }

function Get-TemplateProjectNumber {
  # The one open board carrying the template mark. Found by title so replacing the
  # template does not mean editing a number into a script.
  [CmdletBinding()]
  param()
  $q = 'query($o:String!) { organization(login:$o) { projectsV2(first:100) { nodes { number title closed } } } }'
  $rows = @(Invoke-Gh api graphql -f "o=$(Get-Org)" -f "query=$q" `
              --jq '.data.organization.projectsV2.nodes[] | select(.closed == false) | "\(.number)\t\(.title)"' |
            Where-Object { $_ -and (($_ -split "`t")[1]).StartsWith($script:TemplateMark, [StringComparison]::Ordinal) })
  if ($rows.Count -eq 0) { Stop-WithError "no open project whose title starts with '$($script:TemplateMark)' in $(Get-Org) - pass -Project / --like to name a board to copy" }
  if ($rows.Count -gt 1) { Stop-WithError "more than one open template board in $(Get-Org): $(($rows | ForEach-Object { ($_ -split "`t")[0] }) -join ' ')" }
  return ($rows[0] -split "`t")[0]
}

function Resolve-ProjectForRepo {
  # A repo keeps its old boards after they are closed, so the live board is the one open
  # project it is linked to. Counting the closed ones would make every long-lived repo
  # ambiguous and force an explicit number on every call.
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Repo)
  $owner, $name = $Repo -split '/', 2
  $q = 'query($o:String!,$n:String!) { repository(owner:$o, name:$n) { projectsV2(first:50) { nodes { number title closed } } } }'
  $rows = @(Invoke-Gh api graphql -f "o=$owner" -f "n=$name" -f "query=$q" `
              --jq '.data.repository.projectsV2.nodes[] | select(.closed == false) | "\(.number)\t\(.title)"' |
            Where-Object { $_ -and -not (($_ -split "`t")[1]).StartsWith($script:TemplateMark, [StringComparison]::Ordinal) })

  if ($rows.Count -eq 0) {
    Stop-WithError "$Repo is not linked to an open project - run repo-link, or pass -Project <number>"
  }
  if ($rows.Count -gt 1) {
    $list = ($rows | ForEach-Object { $p = $_ -split "`t"; "$($p[0]) $($p[1])" }) -join ', '
    Stop-WithError "$Repo is linked to more than one open project ($list) - pass -Project <number>"
  }
  return ($rows[0] -split "`t")[0]
}

function Get-ProjectId {
  [CmdletBinding()]
  param()
  $f = Join-Path (Get-CacheDir) 'project-id'
  $cached = if (Test-Path $f) { Get-Content $f -Raw -EA SilentlyContinue } else { $null }

  if ($cached) {
    $id = "$cached".Trim()
    $from = "the id cached in $f"
  } else {
    $q = 'query($org:String!, $num:Int!) { organization(login:$org) { projectV2(number:$num) { id } } }'
    $id = "$(Invoke-Gh api graphql -f "org=$(Get-ProjectOrg)" -F "num=$(Get-ProjectNumber)" `
              -f "query=$q" --jq '.data.organization.projectV2.id')".Trim()
    if (-not $id) { Stop-WithError "cannot read project $(Get-ProjectNumber) of $(Get-ProjectOrg) - is the CLI authenticated with write access to the org?" }
    $from = "the answer for project $(Get-ProjectNumber) of $(Get-ProjectOrg)"
  }

  # WHETHER gh ANSWERED IS NOT WHETHER IT ANSWERED THIS. A query naming an id that belongs to
  # something other than a board is ACCEPTED: it comes back as `{}` with exit 0, which no status
  # check can tell from a real answer. So the value itself is held against the one shape a project
  # id has, wherever it came from.
  #
  # It is checked BEFORE the cache is written, because a file written here is the answer for every
  # later run - nothing asks again once it is not empty - and AFTER the cache is read, because the
  # file can be older than this check, or written by hand. Matched case-sensitively, the way the
  # Bash twin matches it.
  if ($id -cnotlike 'PVT_*') { Stop-WithError "$from is not a project id: $id" }

  if (-not $cached) {
    New-Item -ItemType Directory -Force -Path (Get-CacheDir) | Out-Null
    Set-Content -Path $f -Value $id -NoNewline
  }
  return $id
}

# One cache directory per board. Sharing one would hand a board the other's field and
# option ids, and the API accepts a foreign id without complaining.
#
# WHERE THE CACHE STANDS IS AN ENVIRONMENT VARIABLE, defaulting to the checkout's own
# .cache. A test runs a command that caches, so a cache fixed under the checkout is a
# directory two runs of the same command share, and the loser reads a board id that is not
# its own. Every test points this at its own temporary directory, which is why no test
# writes inside the tree it is testing.
function Get-CacheRoot {
  [CmdletBinding()] param()
  if ($env:GH_CACHE_DIRECTORY) { $env:GH_CACHE_DIRECTORY } else { Join-Path (Get-DataDir) '.cache' }
}
# A board of the organisation (Get-Org) caches under its number; a board of another organisation
# under that organisation's name and its number - the twin of cache_dir in lib/board.sh.
function Get-CacheDir {
  [CmdletBinding()] param()
  if ((Get-ProjectOrg) -eq (Get-Org)) { Join-Path (Get-CacheRoot) "$(Get-ProjectNumber)" }
  else { Join-Path (Get-CacheRoot) "$(Get-ProjectOrg)/$(Get-ProjectNumber)" }
}

function Get-Fields {
  # Every single-select field with all of its options, as objects.
  [CmdletBinding()]
  param()
  $f = Join-Path (Get-CacheDir) 'fields.tsv'
  if (-not (Test-Path $f) -or -not (Get-Content $f -Raw -EA SilentlyContinue)) {
    New-Item -ItemType Directory -Force -Path (Get-CacheDir) | Out-Null
    $q = 'query($pid:ID!) { node(id:$pid) { ... on ProjectV2 { fields(first:50) { nodes { ... on ProjectV2SingleSelectField { id name options { id name } } } } } } }'
    $jq = '.data.node.fields.nodes[] | select(.name != null) | .name as $n | .id as $f | .options[] | "\($n)\t\($f)\t\(.name)\t\(.id)"'
    $rows = Invoke-Gh api graphql -f "pid=$(Get-ProjectId)" -f "query=$q" --jq $jq
    Set-Content -Path $f -Value $rows
  }
  # And what the cache holds is held against the shape of a row, not trusted. Invoke-Gh covers what
  # THIS run writes; the file it reads can be older than that, or written by hand. Without this a
  # lookup reports a board that has no fields, which is a statement about the board, and on this
  # path the board was never asked.
  Get-Content $f | Where-Object { $_ } | ForEach-Object {
    $p = $_ -split "`t"
    if ($p.Count -lt 4) { Stop-WithError "$f does not hold field rows - delete $(Get-CacheDir) and run again. It holds: $_" }
    [pscustomobject]@{ Field = $p[0]; FieldId = $p[1]; Option = $p[2]; OptionId = $p[3] }
  }
}

function Get-FieldId {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Field)
  $all = Get-Fields
  $hit = $all | Where-Object Field -ceq $Field | Select-Object -First 1
  if (-not $hit) { Stop-WithError "no single-select field named '$Field' on the board. There is: $(($all.Field | Select-Object -Unique) -join ' ')" }
  return $hit.FieldId
}

function Get-OptionId {
  # THE ONE LOOKUP HERE THAT FOLDS CASE, and the bash twin folds it the same way with
  # `tolower($1)==tolower(f) && tolower($3)==tolower(n)`. A board names its options however
  # whoever made it typed them - `todo` on this one, `Todo` on the next - and nobody typing a
  # command remembers which. The reason stands in full above option_id in lib/board.sh.
  # What is NOT relaxed is whether the option exists.
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Field, [Parameter(Mandatory)][string]$Option)
  $all = Get-Fields
  $hit = $all | Where-Object { $_.Field -eq $Field -and $_.Option -eq $Option } | Select-Object -First 1
  if (-not $hit) { Stop-WithError "field '$Field' has no option '$Option'. It has: $((($all | Where-Object Field -eq $Field).Option) -join ' ')" }
  return $hit.OptionId
}

function Clear-BoardCache { [CmdletBinding()] param() Remove-Item -Recurse -Force (Get-CacheRoot) -EA SilentlyContinue }

function Get-ProjectRepos {
  # Every repo linked to the selected project.
  [CmdletBinding()]
  param()
  $q = 'query($pid:ID!) { node(id:$pid) { ... on ProjectV2 { repositories(first:100) { nodes { nameWithOwner } } } } }'
  Invoke-Gh api graphql -f "pid=$(Get-ProjectId)" -f "query=$q" --jq '.data.node.repositories.nodes[].nameWithOwner'
}

function Get-RepoOpenProjects {
  # The open boards a repo is linked to, EMPTY where it is linked to none. It answers the
  # question rather than deciding what to do about the answer, because two callers want
  # opposite things from "none": naming a board has to fail, and setting a field on a card
  # that cannot exist has to succeed quietly.
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Repo)
  $owner, $name = $Repo -split '/', 2
  $q = 'query($o:String!,$n:String!) { repository(owner:$o, name:$n) { projectsV2(first:50) { nodes { number title closed } } } }'
  @(Invoke-Gh api graphql -f "o=$owner" -f "n=$name" -f "query=$q" `
      --jq '.data.repository.projectsV2.nodes[] | select(.closed == false) | "\(.number)\t\(.title)"' |
    Where-Object { $_ -and -not (($_ -split "`t")[1]).StartsWith($script:TemplateMark, [StringComparison]::Ordinal) })
}

# --- issues -------------------------------------------------------------------

# HOW THE FIRST LINE OF EVERY ISSUE BODY OPENS. `issue-new` builds that line out of arguments it
# requires, and `issue-edit` recognizes it to keep it on a body that does not carry it. The two
# are the writer and the reader of one sentence, so the opening stands here once: a prefix
# changed in the writer alone would leave the reader keeping nothing and reporting nothing.
$script:AskedPrefix = 'Asked for by @'
function Get-AskedPrefix { [CmdletBinding()] param() $script:AskedPrefix }

function Write-TitleReport {
  # WHAT IS WRONG WITH A TITLE. Every check here REPORTS, and the call still goes through.
  # Whether a title reads well is a judgment, and a script cannot make it; a refusal here
  # would stop a real ticket over wording the writer may have chosen on purpose.
  #
  # THE THIRD REPORT IS ABOUT THE STAKE. A title carries an action and what it costs, joined
  # with ", so ", ", or " or a colon (rules.md, the issue rules). The shape reported here is
  # narrow on purpose: it opens with one of six verbs that name an artifact and carries none
  # of the three joins, which is the exact shape of "Add the board-sync command" - a title
  # that fits twenty other tickets. A title outside that shape is not judged at all.
  #
  # The length is counted in CODE POINTS, which is what the shell twin counts. A .NET string is
  # UTF-16, so `.Length` counts an emoji or any other character outside the Basic Multilingual
  # Plane as two, and a title of seventy characters ending in one would be reported over the
  # limit here and under it there.
  [CmdletBinding()]
  param([Parameter(Mandatory)][AllowEmptyString()][string]$Title)

  $length = @($Title.EnumerateRunes()).Count
  if ($length -gt 70) {
    Write-Host "title is $length characters, over 70 - a title is one sentence a stranger understands; the reason and the code go into the body"
  }
  if ($Title.Contains('`')) {
    Write-Host 'title contains a backtick - no code name in a title'
  }
  $narrow = @('Add ', 'Create ', 'Write ', 'Implement ', 'Introduce ', 'Define ')
  if (($narrow | Where-Object { $Title.StartsWith($_, [StringComparison]::Ordinal) }) -and
      -not ($Title.Contains(', so ') -or $Title.Contains(', or ') -or $Title.Contains(':'))) {
    Write-Host 'title names an action and no stake - write what is wrong today or what it costs, joined with ", so ", ", or " or a colon'
  }
}

function Get-IssueThread {
  # An issue and its whole comment thread, as one object:
  #   {number,title,state,labels,body,comments:[{author,created_at,body}]}
  #
  # The comments are paged. A thread on an epic often runs past one page, and a page that is
  # dropped makes the thread look settled when it is not.
  #
  # gh prints JSON over many lines and each line arrives here as its own string, so they are
  # joined back into one document before the parser sees them.
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string]$Number)

  # -DateKind String keeps `created_at` the string GitHub sent. Without it the parser turns
  # every timestamp into a DateTime and prints it back in the machine's own locale, so the same
  # thread reads differently on two machines and differently from the shell twin.
  $issue = ((Invoke-Gh api "repos/$Repo/issues/$Number") -join "`n") | ConvertFrom-Json -DateKind String
  $comments = @(((Invoke-Gh api --paginate "repos/$Repo/issues/$Number/comments") -join "`n") | ConvertFrom-Json -DateKind String)

  [pscustomobject]@{
    number   = $issue.number
    title    = $issue.title
    state    = $issue.state
    labels   = @($issue.labels | ForEach-Object { $_.name })
    body     = "$($issue.body)"
    comments = @($comments | ForEach-Object {
      [pscustomobject]@{ author = $_.user.login; created_at = $_.created_at; body = "$($_.body)" }
    })
  }
}

# GitHub gives an issue two identities: a node id for GraphQL and a numeric database
# id for the REST sub-issue endpoint. Both are needed.
function Get-IssueNodeId { [CmdletBinding()] param([string]$Repo, [string]$Number) Invoke-Gh api "repos/$Repo/issues/$Number" --jq '.node_id' }
function Get-IssueDbId   { [CmdletBinding()] param([string]$Repo, [string]$Number) Invoke-Gh api "repos/$Repo/issues/$Number" --jq '.id' }

function Resolve-ParentIssue {
  # A parent reference from the command line: OWNER/REPO#N, REPO#N, or a bare number. The
  # owner defaults to the owner of the repository being acted on, and a bare number stays
  # an issue of that repository itself.
  #
  # THE REFERENCE IS RESOLVED, NOT TRUSTED. Every repository numbers its own issues, so a
  # number meant for one repository resolves in any other, to whatever issue happens to
  # carry it there - and the sub-issue API accepts that issue without a word. Asking for
  # the issue first turns a reference that resolves nowhere into a refusal that names what
  # was asked for, and hands back the title so the caller can show which issue it found.
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Reference, [Parameter(Mandatory)][string]$Repo)

  if ($Reference.Contains('#')) {
    $prepo, $num = $Reference -split '#', 2
    if (-not $prepo) { Stop-WithError "'$Reference' is not an issue reference - write OWNER/REPO#N, REPO#N, or an issue number" }
    if (-not $prepo.Contains('/')) { $prepo = "$(($Repo -split '/')[0])/$prepo" }
  } else {
    $prepo = $Repo
    $num = $Reference
  }
  # \z AND NEVER $, HERE AND IN EVERY REGULAR EXPRESSION IN bin/ AND lib/. .NET's $ matches at the
  # end of the string OR immediately before a final newline, so "12`n" passed this check and the
  # `case` glob of the shell twin refused it - the same reference resolved a parent on one side and
  # was refused on the other. \z means the end of the string and nothing else, so the spelling
  # itself says which was meant. Nothing refuses a $ written here tomorrow.
  if ($num -notmatch '^[0-9]+\z') { Stop-WithError "'$Reference' is not an issue reference - write OWNER/REPO#N, REPO#N, or an issue number" }

  $owner, $name = $prepo -split '/', 2
  $q = 'query($o:String!, $n:String!, $num:Int!) { repository(owner:$o, name:$n) { issue(number:$num) { id title } } }'
  try {
    $row = "$(Invoke-Gh api graphql -f "o=$owner" -f "n=$name" -F "num=$num" -f "query=$q" `
                --jq '.data.repository.issue | "\(.id)\t\(.title)"')"
  } catch {
    Stop-WithError "cannot read the parent issue $prepo#$num - $($_.Exception.Message -creplace '^error: ', '')"
  }
  $nodeId, $title = $row -split "`t", 2
  [pscustomobject]@{ Repo = $prepo; Number = [int]$num; NodeId = $nodeId; Title = $title }
}

function Get-ArchivedItemId {
  # The id of this issue's ARCHIVED item on this board, or nothing when it has none.
  #
  # Asked of the ISSUE and not of the project, because a project's item list leaves archived items
  # out - which is what makes an archived card look absent to everything that reads the board.
  #
  # THE BOARD IS PICKED OUT HERE AND NOT INSIDE THE jq PROGRAM. jq asks which items are archived;
  # which of them are on THIS board is decided afterwards, against a value that stays a value.
  # Writing the id into the program text instead makes the program depend on what the id contains,
  # and jq reads a double quote or a backslash in it as program, not as data.
  [CmdletBinding()]
  param([string]$Repo, [string]$Number)
  $owner, $name = $Repo -split '/', 2
  $projectId = Get-ProjectId
  $q = 'query($o:String!, $n:String!, $num:Int!) { repository(owner:$o, name:$n) {
          issue(number:$num) { projectItems(first:20, includeArchived:true) {
            nodes { id isArchived project { id } } } } } }'
  $jq = '.data.repository.issue.projectItems.nodes[] | select(.isArchived) | "\(.project.id)\t\(.id)"'
  @(Invoke-Gh api graphql -f "o=$owner" -f "n=$name" -F "num=$Number" -f "query=$q" --jq $jq) |
    Where-Object { $_ -and ($_ -split "`t")[0] -ceq $projectId } |
    ForEach-Object { ($_ -split "`t")[1] } |
    Select-Object -First 1
}

function Get-ItemId {
  # The board item for an issue, adding it to the board if it is not on it yet.
  # Adding twice is harmless - GitHub returns the existing item.
  #
  # ARCHIVED STAYS ARCHIVED. Archiving is the owner's decision and nothing else's, and the mutation
  # below does not merely return an existing item - it takes it back OUT of the archive. So a card
  # somebody deliberately put away is on the board again after the next sweep, with nobody having
  # asked for it. It cannot be caught by looking at the board either: a project's item list leaves
  # archived items out, so the sweep sees no card, concludes one is missing, and adds it.
  [CmdletBinding()]
  param([string]$Repo, [string]$Number)
  $existing = Get-ArchivedItemId -Repo $Repo -Number $Number
  if ($existing) { return $existing }
  $q = 'mutation($pid:ID!, $cid:ID!) { addProjectV2ItemById(input:{projectId:$pid, contentId:$cid}) { item { id } } }'
  Invoke-Gh api graphql -f "pid=$(Get-ProjectId)" -f "cid=$(Get-IssueNodeId $Repo $Number)" -f "query=$q" `
    --jq '.data.addProjectV2ItemById.item.id'
}

function Get-IssueBoardItems {
  # Every open board this issue has a card on, one "<project number>\t<item id>" per line.
  #
  # The issue's own projectItems is the authoritative list. A REPO resolves to one board, but
  # an ISSUE can be on several - a cross-repository epic pulls its child onto its own board -
  # and a card that is stale on the second board makes that board lie to whoever filters it.
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string]$Number)
  $owner, $name = $Repo -split '/', 2
  # One `OWNER/N<tab><item id>` per open board - the board named with its owner, the twin of
  # issue_board_items in lib/board.sh (example-tools#26).
  $q = 'query($o:String!, $n:String!, $num:Int!) { repository(owner:$o, name:$n) {
          issue(number:$num) { projectItems(first:20) {
            nodes { id project { number closed owner { ... on Organization { login } ... on User { login } } } } } } } }'
  $jq = '.data.repository.issue.projectItems.nodes[] | select(.project.closed == false) | "\(.project.owner.login)/\(.project.number)\t\(.id)"'
  @(Invoke-Gh api graphql -f "o=$owner" -f "n=$name" -F "num=$Number" -f "query=$q" --jq $jq |
    Where-Object { $_ })
}

function Invoke-OnEveryBoard {
  # One single-select write, applied to EVERY board the issue is on, printing one line per
  # board - a partial result must not read as a complete one. Each iteration selects its board
  # first, so the per-board caches stay coherent.
  #
  # An issue on no card has TWO causes which must not be treated alike. A repository with a
  # board and an issue that never got a card: add it. A repository on no board at all: there is
  # nothing to add and nothing to set, and the issue tooling's own repository is deliberately
  # one of those. Reading both as "card missing" made every close, reopen, status and priority
  # on such an issue die after the issue itself had already been changed.
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Repo,
    [Parameter(Mandatory)][string]$Number,
    [Parameter(Mandatory)][string]$Field,
    [Parameter(Mandatory)][string]$Option,
    [Parameter(Mandatory)][string]$Printed
  )
  $rows = Get-IssueBoardItems -Repo $Repo -Number $Number
  if ($rows.Count -eq 0) {
    if ((Get-RepoOpenProjects -Repo $Repo).Count -eq 0) {
      "#$Number -> $Printed (issue only; $Repo is on no board)"
      return
    }
    Set-Project -Number '' -Repo $Repo | Out-Null
    Set-Select (Get-ItemId $Repo $Number) $Field $Option
    "#$Number -> $Printed (board $(Get-ProjectOrg)/$(Get-ProjectNumber), card added)"
    return
  }
  foreach ($row in $rows) {
    $bnum, $bitem = $row -split "`t", 2
    Set-Project -Number $bnum | Out-Null
    Set-Select $bitem $Field $Option
    "#$Number -> $Printed (board $bnum)"
  }
}

function Set-ItemTop {
  # Put one card at the top of the board, or directly under another one.
  #
  # -AfterId is what makes a NAMED ORDER possible: moving each card to the top would reverse
  # the names into a stack, so the caller hands the card moved before this one and this lands
  # right beneath it. With no -AfterId the card goes above everything, which is what the FIRST
  # name in a list wants. An empty string is no argument at all, since an omitted GraphQL
  # variable is the absence of a value and not one that is empty.
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$ItemId, [string]$AfterId)
  $q = 'mutation($pid:ID!, $iid:ID!, $after:ID) { updateProjectV2ItemPosition(input:{projectId:$pid, itemId:$iid, afterId:$after}) { items { totalCount } } }'
  $call = @('api', 'graphql', '-f', "pid=$(Get-ProjectId)", '-f', "iid=$ItemId")
  if ($AfterId) { $call += @('-f', "after=$AfterId") }
  $call += @('-f', "query=$q")
  Invoke-Gh @call | Out-Null
}

function Get-BoardItems {
  # Every card on this board, paged. A board outgrows one page of 100 quickly, and a
  # single unpaged query silently reports the rest as absent.
  [CmdletBinding()]
  param()
  $q = 'query($pid:ID!, $after:String) { node(id:$pid) { ... on ProjectV2 { items(first:100, after:$after) { pageInfo { hasNextPage endCursor } nodes { id content { ... on Issue { number repository { nameWithOwner } } } } } } } }'
  $after = $null
  do {
    $call = @('api', 'graphql', '-f', "pid=$(Get-ProjectId)", '-f', "query=$q")
    if ($after) { $call += @('-f', "after=$after") }
    $page = (Invoke-Gh @call | ConvertFrom-Json).data.node.items
    $page.nodes
    $after = $page.pageInfo.endCursor
  } while ($page.pageInfo.hasNextPage)
}

function Remove-BoardItem {
  # Takes a card off this board. The issue itself is untouched.
  [CmdletBinding()]
  [OutputType([bool])]
  param([string]$Repo, [string]$Number)
  $item = Get-BoardItems |
    Where-Object { $_.content.number -eq $Number -and $_.content.repository.nameWithOwner -ceq $Repo } |
    Select-Object -First 1
  if (-not $item) { return $false }
  $m = 'mutation($pid:ID!, $iid:ID!) { deleteProjectV2Item(input:{projectId:$pid, itemId:$iid}) { deletedItemId } }'
  Invoke-Gh api graphql -f "pid=$(Get-ProjectId)" -f "iid=$($item.id)" -f "query=$m" | Out-Null
  return $true
}

function Set-Select {
  [CmdletBinding()]
  param([string]$ItemId, [string]$Field, [string]$Option)
  $q = 'mutation($pid:ID!, $iid:ID!, $fid:ID!, $oid:String!) { updateProjectV2ItemFieldValue(input:{projectId:$pid, itemId:$iid, fieldId:$fid, value:{singleSelectOptionId:$oid}}) { projectV2Item { id } } }'
  Invoke-Gh api graphql -f "pid=$(Get-ProjectId)" -f "iid=$ItemId" `
    -f "fid=$(Get-FieldId $Field)" -f "oid=$(Get-OptionId $Field $Option)" -f "query=$q" | Out-Null
}

Export-ModuleMember -Function Stop-WithError, ConvertTo-AsciiLowercase, Invoke-Gh, Get-Org, Get-DataDir, Get-DataFile, Get-LabelTaxonomy, Get-LabelNamesInGroup,
  Set-Project, Get-ProjectNumber, Get-ProjectOrg,
  Get-TemplateProjectNumber, Get-TemplateMark, Resolve-ProjectForRepo, Get-RepoOpenProjects, Get-ProjectId, Get-CacheDir, Get-Fields, Get-FieldId, Get-OptionId,
  Clear-BoardCache, Get-DefaultRepo, Get-AssigneeForRepo, Get-ProjectRepos, Get-IssueNodeId, Get-IssueDbId,
  Write-TitleReport, Get-AskedPrefix, Get-IssueThread, Get-IssueBoardItems, Invoke-OnEveryBoard, Set-ItemTop,
  Resolve-ParentIssue, Get-ItemId, Get-ArchivedItemId, Get-BoardItems, Remove-BoardItem, Set-Select
