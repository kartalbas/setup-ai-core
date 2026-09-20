# The PowerShell twin of case-check.test.sh, asserting the SAME refusals over the SAME tree.
#
#   pwsh -File test/case-check.test.ps1
#
# THE CLASS THIS HOLDS CLOSED. Every PowerShell command here is one half of a pair whose bash
# half compares bytes, and PowerShell's -eq -match -like -contains -in all ignore case by
# default. A bare one accepts a spelling its twin refuses - `--add TYPE:BUG`, `-Reason
# NOT-PLANNED`, a `## options` heading, a `[Review]` tag - and these commands write to the
# platform, so a comparison that quietly matches more than it says can act on the wrong ticket.
#
# THE PLANTED INNOCENTS ARE HALF THE TEST, and the half that decides whether this check is still
# switched on next month. A check that fires on `-eq 0`, on `-match '^##[ \t]'` or on a tab is a
# check somebody deletes, so the tree below carries every one of those shapes and the run must
# stay green over them. The defects are planted one at a time on top of that green tree, so a
# refusal can only be the one being planted.
#
# WHAT IS FAKED HERE: nothing at all. The check reaches no platform and reads no cache - it walks
# a directory of files, and the tree below is a real one written into a temporary directory.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fake = Join-Path ([IO.Path]::GetTempPath()) "case-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $fake | Out-Null

$failed = 0
function Check($name, $expected, $actual) {
  if ("$expected" -ceq "$actual") { Write-Host "  ok   $name" }
  else { Write-Host "  FAIL $name`n       expected: $expected`n       actual:   $actual"; $script:failed++ }
}

$tree = Join-Path $fake 'tree'
New-Item -ItemType Directory -Path "$tree/bin", "$tree/lib" -Force | Out-Null
function Run-Check($at) {
  $out = @(& pwsh -NoProfile -File (Join-Path $root 'bin/case-check.ps1') -Root $at 2>&1 |
           ForEach-Object { "$_" })
  return [pscustomobject]@{ Code = $LASTEXITCODE; Lines = $out; Text = ($out -join "`n") }
}

# THE INNOCENTS. Every one of these is a shape this repository really writes, and not one of
# them may be reported: a numeric comparison, a regex whose only letters are escapes, a regex
# whose only letters are a character-class range, a tab, and the two spellings that DO say
# whether they fold case.
@'
<#
.SYNOPSIS
A block comment naming -eq 'OPEN', which is not code and may not be reported.
#>
if ($LASTEXITCODE -ne 0) { exit 1 }
if ($rows.Count -eq 0) { exit 1 }
if ($line -cmatch '^##[ \t]') { }
if ($color -cnotmatch '^[0-9A-Fa-f]{6}$') { }
$c = $line -csplit "`t"
if ($state -ceq 'OPEN') { }
if ($said -inotmatch 'not installed') { }
$p = $path -creplace '\\', '/'
# a comment naming -eq 'OPEN', which is not code either
if ($name.StartsWith('#', [StringComparison]::Ordinal)) { }
switch -CaseSensitive ($tool) { 'claude' { } }
$n = [int]$text
function Get-One {
  [CmdletBinding()]
  param(
    [ValidatePattern('^[0-9]+\z')][string] $Number,
    [Parameter(Mandatory)][datetime] $When
  )
}
'@ | Set-Content -Path "$tree/bin/innocent.ps1" -Encoding utf8NoBOM

@'
function Get-Thing {
  [CmdletBinding()]
  param([ValidateSet('completed', 'not-planned', IgnoreCase=$false)][string]$Reason)
  return $Reason
}
'@ | Set-Content -Path "$tree/lib/Board.psm1" -Encoding utf8NoBOM

$green = @'
case-check: 2 comparison(s) against a text literal in 2 file(s), every one saying whether case is folded.
case-check: 2 param block(s) in the same files, none declaring a type the binder converts.
'@.Trim()

$r = Run-Check $tree
Check 'a clean tree is green' '0' $r.Code
Check 'and it counts what it read' $green $r.Text

# THE PLANTED DEFECT: a bare -eq against a literal that carries case, on the line that decides
# whether an issue is counted open.
Set-Content -Path "$tree/bin/planted.ps1" -Encoding utf8NoBOM -Value "if (`$i.state -eq 'OPEN') { `$open++ }"
$r = Run-Check $tree
Check 'a bare -eq is refused' '1' $r.Code
Check 'and it is named with its line and its operand' `
  "bin/planted.ps1:1 compares with -eq against 'OPEN' and does not say whether case is folded - write -ceq or -ieq" `
  $r.Lines[0]
Check 'and nothing else is named' `
  'case-check: FAIL - 1 spelling(s) in bin/ and lib/ accept more than they say' `
  $r.Lines[-1]

# .StartsWith(string) compares by CULTURE, so a zero-width joiner in front of the operand makes
# it answer True where the bash twin's `case` answers False. Same shape, one class over.
Set-Content -Path "$tree/bin/planted.ps1" -Encoding utf8NoBOM -Value 'if ($title.StartsWith($mark)) { }'
Check 'a culture-sensitive StartsWith is refused' `
  'bin/planted.ps1:1 calls .StartsWith or .EndsWith with no StringComparison, which compares by culture - pass [StringComparison]::Ordinal' `
  (Run-Check $tree).Lines[0]

# A [ValidateSet] binds without case, so -Reason NOT-PLANNED is accepted here and refused by the
# bash twin's `case`. It carries no operator, so no grep over operator names finds it.
Set-Content -Path "$tree/bin/planted.ps1" -Encoding utf8NoBOM -Value "  [ValidateSet('completed', 'not-planned')][string] `$Reason"
Check 'a case-blind ValidateSet is refused' `
  'bin/planted.ps1:1 declares a [ValidateSet] that does not say whether case is folded - add IgnoreCase=$false or IgnoreCase=$true' `
  (Run-Check $tree).Lines[0]

# switch matches without case too, and it is how a status is ranked and a probe is dispatched.
Set-Content -Path "$tree/bin/planted.ps1" -Encoding utf8NoBOM -Value "switch (`$Status) { 'done' { 3 } }"
Check 'a case-blind switch is refused' `
  'bin/planted.ps1:1 opens a switch that does not say whether case is folded - write switch -CaseSensitive' `
  (Run-Check $tree).Lines[0]

# A NUMERIC PARAMETER TYPE, which is the binder converting before the script runs: -Number 12.6
# binds 13 and the command edits the neighbouring issue in silence, where the bash twin refuses.
# Written over four lines, so the block is tracked past the line the param( stands on.
Set-Content -Path "$tree/bin/planted.ps1" -Encoding utf8NoBOM -Value @(
  'param(', '  [Parameter(Mandatory)][int[]] $Number,', '  [string] $Repo', ')')
Check 'a numeric parameter type is refused' `
  'bin/planted.ps1:2 declares a parameter with a numeric type, and the binder converts before the script runs - 12.6 arrives as 13. Write [string] and judge it with the rule the shell twin uses' `
  (Run-Check $tree).Lines[0]

# The safe form of the same parameter, in the same four lines: green, so what the check refuses is
# the type and not the parameter.
Set-Content -Path "$tree/bin/planted.ps1" -Encoding utf8NoBOM -Value @(
  'param(', "  [Parameter(Mandatory)][ValidatePattern('^[0-9]+\z')][string[]] `$Number,", '  [string] $Repo', ')')
Check 'and the [string] form of it is green' '0' (Run-Check $tree).Code

Remove-Item "$tree/bin/planted.ps1" -Force
$r = Run-Check $tree
Check 'and taking it away makes the run green again' '0' $r.Code
Check 'over the same count as before' $green $r.Text

# The check refuses a tree it cannot read rather than reporting it clean, because finding nothing
# is what green looks like.
$empty = Join-Path $fake 'empty'
New-Item -ItemType Directory -Path $empty -Force | Out-Null
$r = Run-Check $empty
Check 'a tree with no bin/ and no lib/ is refused' '2' $r.Code
Check 'and it says which tree' "error: $($empty -creplace '\\', '/') has neither a bin/ nor a lib/ to read" $r.Text

Remove-Item -Recurse -Force $fake -ErrorAction SilentlyContinue
if ($failed -gt 0) { exit 1 }
