#!/usr/bin/env bash
# Does the case check see a comparison that does not say whether it folds case, and does it
# leave the ones that carry no case alone?
#
#   bash test/case-check.test.sh
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

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fake="$(mktemp -d)"
trap 'rm -rf "$fake"' EXIT

failed=0
check() {  # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}

tree="$fake/tree"
mkdir -p "$tree/bin" "$tree/lib"

# THE INNOCENTS. Every one of these is a shape this repository really writes, and not one of
# them may be reported: a numeric comparison, a regex whose only letters are escapes, a regex
# whose only letters are a character-class range, a tab, and the two spellings that DO say
# whether they fold case.
cat > "$tree/bin/innocent.ps1" <<'PS'
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
PS

cat > "$tree/lib/Board.psm1" <<'PS'
function Get-Thing {
  [CmdletBinding()]
  param([ValidateSet('completed', 'not-planned', IgnoreCase=$false)][string]$Reason)
  return $Reason
}
PS

green='case-check: 2 comparison(s) against a text literal in 2 file(s), every one saying whether case is folded.
case-check: 2 param block(s) in the same files, none declaring a type the binder converts.'

out="$(bash "$root/bin/case-check.sh" "$tree" 2>&1)"; rc=$?
check 'a clean tree is green'   '0' "$rc"
check 'and it counts what it read' "$green" "$out"

# THE PLANTED DEFECT: a bare -eq against a literal that carries case, on the line that decides
# whether an issue is counted open.
printf '%s\n' "if (\$i.state -eq 'OPEN') { \$open++ }" > "$tree/bin/planted.ps1"
out="$(bash "$root/bin/case-check.sh" "$tree" 2>&1)"; rc=$?
check 'a bare -eq is refused' '1' "$rc"
check 'and it is named with its line and its operand' \
  "bin/planted.ps1:1 compares with -eq against 'OPEN' and does not say whether case is folded - write -ceq or -ieq" \
  "$(printf '%s\n' "$out" | head -n 1)"
check 'and nothing else is named' \
  'case-check: FAIL - 1 spelling(s) in bin/ and lib/ accept more than they say' \
  "$(printf '%s\n' "$out" | tail -n 1)"

# .StartsWith(string) compares by CULTURE, so a zero-width joiner in front of the operand makes
# it answer True where the bash twin's `case` answers False. Same shape, one class over.
printf '%s\n' 'if ($title.StartsWith($mark)) { }' > "$tree/bin/planted.ps1"
out="$(bash "$root/bin/case-check.sh" "$tree" 2>&1 | head -n 1)"
check 'a culture-sensitive StartsWith is refused' \
  'bin/planted.ps1:1 calls .StartsWith or .EndsWith with no StringComparison, which compares by culture - pass [StringComparison]::Ordinal' \
  "$out"

# A [ValidateSet] binds without case, so -Reason NOT-PLANNED is accepted here and refused by the
# bash twin's `case`. It carries no operator, so no grep over operator names finds it.
printf '%s\n' "  [ValidateSet('completed', 'not-planned')][string] \$Reason" > "$tree/bin/planted.ps1"
out="$(bash "$root/bin/case-check.sh" "$tree" 2>&1 | head -n 1)"
check 'a case-blind ValidateSet is refused' \
  'bin/planted.ps1:1 declares a [ValidateSet] that does not say whether case is folded - add IgnoreCase=$false or IgnoreCase=$true' \
  "$out"

# switch matches without case too, and it is how a status is ranked and a probe is dispatched.
printf '%s\n' "switch (\$Status) { 'done' { 3 } }" > "$tree/bin/planted.ps1"
out="$(bash "$root/bin/case-check.sh" "$tree" 2>&1 | head -n 1)"
check 'a case-blind switch is refused' \
  'bin/planted.ps1:1 opens a switch that does not say whether case is folded - write switch -CaseSensitive' \
  "$out"

# A NUMERIC PARAMETER TYPE, which is the binder converting before the script runs: `-Number 12.6`
# binds 13 and the command edits the neighbouring issue in silence, where the bash twin refuses.
# Written over four lines, so the block is tracked past the line the `param(` stands on.
printf '%s\n' 'param(' '  [Parameter(Mandatory)][int[]] $Number,' '  [string] $Repo' ')' > "$tree/bin/planted.ps1"
out="$(bash "$root/bin/case-check.sh" "$tree" 2>&1 | head -n 1)"
check 'a numeric parameter type is refused' \
  'bin/planted.ps1:2 declares a parameter with a numeric type, and the binder converts before the script runs - 12.6 arrives as 13. Write [string] and judge it with the rule the shell twin uses' \
  "$out"

# The safe form of the same parameter, in the same four lines: green, so what the check refuses is
# the type and not the parameter.
printf '%s\n' 'param(' "  [Parameter(Mandatory)][ValidatePattern('^[0-9]+\z')][string[]] \$Number," '  [string] $Repo' ')' > "$tree/bin/planted.ps1"
bash "$root/bin/case-check.sh" "$tree" >/dev/null 2>&1
check 'and the [string] form of it is green' '0' "$?"

rm -f "$tree/bin/planted.ps1"
out="$(bash "$root/bin/case-check.sh" "$tree" 2>&1)"; rc=$?
check 'and taking it away makes the run green again' '0' "$rc"
check 'over the same count as before' "$green" "$out"

# The check refuses a tree it cannot read rather than reporting it clean, because finding nothing
# is what green looks like.
mkdir -p "$fake/empty"
out="$(bash "$root/bin/case-check.sh" "$fake/empty" 2>&1)"; rc=$?
check 'a tree with no bin/ and no lib/ is refused' '2' "$rc"
check 'and it says which tree'  "error: $fake/empty has neither a bin/ nor a lib/ to read" "$out"

[ "$failed" -eq 0 ] || exit 1
