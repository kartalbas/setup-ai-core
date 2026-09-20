<#
.SYNOPSIS
Does every mutation this repository sends name a field the interface really has?

.EXAMPLE
./schema-check.ps1

.EXAMPLE
./schema-check.ps1 ../some/other/checkout

.NOTES
It reads every .sh, .ps1 and .psm1 under bin/ and lib/ of the directory named - this repository
when none is - finds the GraphQL mutations written in them, and holds each one against the schema
github.com publishes. Two things are asked of every mutation: the root field must be one the
interface has, and the field asked of its answer must stand on that mutation's payload type.

WHY THIS IS A COMMAND AND NOT A TEST. Every test here runs against a fake gh on PATH, so nothing
in test/ reaches github.com and nothing there can know whether a field name is real. That is what
let `updateProjectV2ItemPosition(...) { projectV2Item { id } }` stand in lib/board.sh and
lib/Board.psm1 under two green tests: the interface validates a mutation document before it
executes it, so it refuses the whole thing and no card moves. This is the one step of
scripts/check.ps1 that reaches github.com, and it stands beside the two suites rather than inside
them, so test/ keeps reaching nothing.

IT IS RED WHEN THE INTERFACE CANNOT BE READ, and never skipped. A check that passes itself when it
could not look reports green for a question nobody asked.

WHAT IT READS AND WHAT IT DOES NOT, named rather than counted. It reads the FIRST field asked of
each mutation's answer. It does not read deeper selections, it does not read queries, and it does
not read the fields of the input object.

COMMENTS ARE DROPPED BEFORE ANYTHING IS MATCHED, and both shells write them differently. A line
whose first character is a hash is dropped, and so is a PowerShell block comment - the lines from
the one that opens it to the one that closes it. Without the second, a mutation quoted in a help
block is counted as code, and the two twins then disagree about the same tree, because the shell
twin drops that same sentence when it stands in a .sh file. A block comment opened in the middle
of a line is not dropped; no file here writes one.

ONE CALL ANSWERS EVERYTHING. The Mutation type's own fields carry both the name of every mutation
and, one level down, the fields of the payload it answers with.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)][string] $Directory
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../lib/Board.psm1') -Force

$root = if ($Directory) { $Directory } else { Split-Path -Parent $PSScriptRoot }
if (-not (Test-Path -LiteralPath $root -PathType Container)) {
  [Console]::Error.WriteLine("error: there is no directory at $root")
  exit 2
}
$root = (Resolve-Path -LiteralPath $root).Path -replace '\\', '/'

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
  [Console]::Error.WriteLine('error: gh is not on PATH, and the schema is read through it')
  exit 2
}

$where = @('bin', 'lib') | Where-Object { Test-Path -LiteralPath "$root/$_" -PathType Container }
if ($where.Count -eq 0) {
  [Console]::Error.WriteLine("error: $root has neither a bin/ nor a lib/ to read")
  exit 2
}

# Invoke-Gh is the one place that tells a refusal from an answer, because gh writes its error body
# to stdout where the schema would be and exits non-zero. It throws on a refusal, and the throw is
# caught here so the run ends with the sentence that says no mutation was checked.
$query = '{ __type(name:"Mutation") { fields { name type { name fields { name } } } } }'
try { $answer = (@(Invoke-Gh api graphql -f "query=$query") -join "`n") }
catch {
  [Console]::Error.WriteLine($_.Exception.Message)
  [Console]::Error.WriteLine('schema-check: FAIL - the interface could not be read, so no mutation was checked')
  exit 1
}

# ORDINAL, so a mutation spelled `AddProjectV2ItemById` is refused the way the awk twin refuses
# it. A PowerShell hashtable resolves its keys WITHOUT case, so the lookup below would find the
# real `addProjectV2ItemById` under the wrong spelling and report the source as checked.
$payload = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
$fields  = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
foreach ($m in ($answer | ConvertFrom-Json).data.__type.fields) {
  $payload[$m.name] = if ($m.type.name) { $m.type.name } else { '-' }
  $fields[$m.name] = (@($m.type.fields.name) -join ',')
}
if ($payload.Count -eq 0) {
  [Console]::Error.WriteLine('schema-check: FAIL - the interface named no mutation, so there was nothing to check against')
  exit 1
}

$paths = [string[]]@(
  Get-ChildItem -LiteralPath ($where | ForEach-Object { "$root/$_" }) -Recurse -File |
    Where-Object { $_.Extension -cin '.sh', '.ps1', '.psm1' } |
    ForEach-Object { $_.FullName -replace '\\', '/' }
)
if ($paths.Count -eq 0) {
  [Console]::Error.WriteLine("schema-check: FAIL - no script was found under $root")
  exit 1
}
# Ordinal, so the two twins list their refusals in the same order. The shell twin sorts under
# LC_ALL=C for the same reason: a locale that folds punctuation would order the same names
# differently and the two commands would answer differently for one tree.
[Array]::Sort($paths, [StringComparer]::Ordinal)

# The file is read twice over one buffer. A mutation document runs over several physical lines in
# a .sh file, so the lines are joined with a space first and the match is made on the whole thing.
# Each pass advances past the OPENING PARENTHESIS of the match it just took, not past the whole
# match: a mutation document opens `mutation(...) { <root>(`, so a pass that consumed its whole
# match would swallow the root name and never see the selection under it.
$documentRe = [regex] 'mutation[ \t]*(\([^)]*\))?[ \t]*\{[ \t]*[A-Za-z_][A-Za-z0-9_]*'
$callRe = [regex] '[A-Za-z_][A-Za-z0-9_]*\([^)]*\)[ \t]*\{[ \t]*[A-Za-z_][A-Za-z0-9_]*'

function Get-Named {
  # The identifier a match ends on. The pattern ends with `{ <identifier>`, and the greedy `.*`
  # runs to the LAST brace of the match - the selection brace. Cutting at the FIRST one would
  # hand back the input object, because `input:{` opens a brace of its own.
  param([string]$Hit)
  return ($Hit -replace '^.*\{[ \t]*', '')
}

function Get-LineOf {
  # The physical line a name is called on. The buffer has lost the line breaks, so the line is
  # found by looking the call up again in the lines that were kept.
  param([string[]]$Lines, [string]$Name)
  for ($i = 0; $i -lt $Lines.Length; $i++) {
    if ($Lines[$i].Contains($Name + '(')) { return $i + 1 }
  }
  return 0
}

$seen = 0
$bad = 0
foreach ($path in $paths) {
  $lines = [IO.File]::ReadAllLines($path)
  $kept = [System.Collections.Generic.List[string]]::new()
  $inblock = $false
  foreach ($line in $lines) {
    if ($line -match '^[ \t]*<#') { $inblock = $true }
    if ($inblock) { if ($line -match '#>[ \t]*\z') { $inblock = $false }; continue }
    if ($line -notmatch '^[ \t]*#') { $kept.Add($line) }
  }
  $buf = ' ' + ($kept -join ' ')
  $short = if ($path.StartsWith("$root/", [StringComparison]::Ordinal)) { $path.Substring($root.Length + 1) } else { $path }

  $at = 0
  while ($true) {
    $m = $documentRe.Match($buf, $at)
    if (-not $m.Success) { break }
    $name = Get-Named $m.Value
    if (-not $payload.ContainsKey($name)) {
      $bad++
      '{0}:{1} names `{2}`, and the interface has no mutation of that name' -f
        $short, (Get-LineOf $lines $name), $name
    }
    $at = $m.Index + $m.Value.IndexOf('{') + 1
  }

  $at = 0
  while ($true) {
    $m = $callRe.Match($buf, $at)
    if (-not $m.Success) { break }
    $open = $m.Value.IndexOf('(')
    $name = $m.Value.Substring(0, $open)
    if ($payload.ContainsKey($name)) {
      $asked = Get-Named $m.Value
      $seen++
      # Contains is ordinal and case sensitive; -like would fold the case, and a field spelled
      # `Items` where the interface has `items` would be accepted.
      if (-not ("," + $fields[$name] + ",").Contains("," + $asked + ",")) {
        $bad++
        '{0}:{1} asks `{2}` for `{3}`, and {4} has: {5}' -f
          $short, (Get-LineOf $lines $name), $name, $asked, $payload[$name], $fields[$name]
      }
    }
    $at = $m.Index + $open + 1
  }
}

''
if ($bad -gt 0) {
  'schema-check: {0} mutation selection(s) in {1} file(s), {2} refused.' -f $seen, $paths.Count, $bad
  exit 1
}
'schema-check: {0} mutation selection(s) in {1} file(s), every one on the payload the interface publishes.' -f $seen, $paths.Count
exit 0
