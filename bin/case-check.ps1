<#
.SYNOPSIS
Every spelling in bin/ and lib/ that silently accepts more than it says is refused here.

.DESCRIPTION
TWO SPELLINGS ARE HELD, and the second is not a case question. A comparison against a text
literal says whether it folds case, and a parameter is not declared with a type the binder
converts a number into. The rule both share is that the spelling itself carries what the code
accepts, so nobody has to keep a list or read a comment that has drifted. The command carries the
name of the first of them and holds both.

PowerShell's -eq -ne -match -notmatch -like -notlike -replace -split -contains -notcontains
-in -notin all ignore case by DEFAULT, and every bash twin of them - [ = ], case, grep, awk -
compares bytes. So a bare operator in the PowerShell half of a pair accepts a spelling the
bash half refuses, and nothing on either side says so. These commands write to the platform:
they create issues, edit bodies, move cards and mint tags, and a comparison that quietly
matches more than it says can act on the wrong ticket.

THE RULE IS THE SPELLING, NOT A LIST. A comparison whose operand is a text literal is written
`-ceq` where it must compare bytes and `-ieq` where it folds case on purpose - the `i` form is
the reason, written where it stays true, instead of a comment that drifts or an allow-list that
has to be kept. A bare form is refused because it says neither.

THREE CONSTRUCTS FOLD CASE WITH NO OPERATOR TO READ. `switch` matches without case, a
[ValidateSet] binds without case, and a PowerShell @{} hashtable resolves its keys without
case - $h['type:bug']=$true; $h.ContainsKey('type:Bug') answers True. The first two are read
here. The third is not, because @{} is also how an ordinary object is written and a check that
fired on every one of them would be switched off in a week; a hashtable whose keys are text is
declared with [StringComparer]::Ordinal instead, and lib/Board.psm1, bin/schema-check.ps1 and
bin/solution-path.ps1 are where that already is.

WHAT IT DOES NOT SEE: a comparison between two VARIABLES -
`$a -ceq $b` - carries no literal, so nothing here can tell a string comparison from a numeric
one and none of them is judged. Nor is a comparison in test/, whose operands are written on
both sides by this repository and whose bash twin is byte-exact.

A LITERAL CARRIES CASE only where a letter survives its escapes and its character classes:
'^##[ \t]' and '^[0-9A-Fa-f]{6}$' hold no case at all, and flagging them is how a check gets
switched off.

.StartsWith(string) and .EndsWith(string) compare by CULTURE, which is the same silent
acceptance one class over: a zero-width joiner in front of the operand makes them answer True
where case, grep -F and awk answer False. They are read here too.

A NUMERIC PARAMETER TYPE IS THE SAME DEFECT WITH NO OPERATOR AT ALL. [int] $Number hands the
conversion to the binder, which runs BEFORE the script's first line, so no guard written in the
body can see what was typed: measured 2026-09-05, -Number 12.6 bound to 13 and the command edited
issue 13 in silence, where every shell twin's `case "$n" in ''|*[!0-9]*)` refused it - eleven of
twelve inputs answered differently. So a param( block in bin/ or lib/ may not declare a type the
binder converts a number into, and the parameter is [string] judged by the same rule the shell
twin uses. THE RULE HAS NO EXCEPTION for a parameter nobody types on a command line, because a
rule that has to know who calls a function is a rule nobody can apply by reading.

WHAT IT STILL DOES NOT SEE: a [string] parameter written with no rule beside it. A string that
holds a number looks exactly like every other string, so there is no spelling to refuse, and the
twin tests are what hold that half.

.EXAMPLE
./case-check.ps1
#>
[CmdletBinding()]
param([string] $Root)

$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path }
$root = (Resolve-Path -LiteralPath $Root).Path -creplace '\\', '/'

$where = @('bin', 'lib') | Where-Object { Test-Path -LiteralPath "$root/$_" -PathType Container }
if ($where.Count -eq 0) {
  [Console]::Error.WriteLine("error: $root has neither a bin/ nor a lib/ to read")
  exit 2
}

# Ordinal, so the two twins name their files in the same order. The shell twin sorts under
# LC_ALL=C for the same reason.
$paths = [string[]]@(
  Get-ChildItem -LiteralPath ($where | ForEach-Object { "$root/$_" }) -Recurse -File |
    Where-Object { $_.Extension -cin '.ps1', '.psm1' } |
    ForEach-Object { $_.FullName -creplace '\\', '/' })
if ($paths.Count -eq 0) {
  [Console]::Error.WriteLine("error: no PowerShell script under $root")
  exit 2
}
[Array]::Sort($paths, [StringComparer]::Ordinal)

# What a literal holds once its escapes and character classes are gone. Both escape characters
# count: the regex backslash, and the backtick PowerShell writes a tab with.
function Get-Bare {
  [CmdletBinding()]
  param([Parameter(Mandatory)][AllowEmptyString()][string]$Literal)
  $out = [Text.StringBuilder]::new()
  $inClass = $false
  for ($i = 0; $i -lt $Literal.Length; $i++) {
    $c = $Literal[$i]
    if ($c -ceq '\' -or $c -ceq '`') { $i++; continue }
    if ($c -ceq '[') { $inClass = $true; continue }
    if ($c -ceq ']') { $inClass = $false; continue }
    if ($inClass) { continue }
    [void]$out.Append($c)
  }
  return $out.ToString()
}

# The line without its comment. A # inside a string is not one.
function Get-Code {
  [CmdletBinding()]
  param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)
  $out = [Text.StringBuilder]::new()
  $q = ''
  foreach ($c in $Line.ToCharArray()) {
    if ($q -ceq '') {
      if ($c -ceq '#') { return $out.ToString() }
      if ($c -ceq "'" -or $c -ceq '"') { $q = "$c" }
    } elseif ("$c" -ceq $q) { $q = '' }
    [void]$out.Append($c)
  }
  return $out.ToString()
}

# The line with every quoted span emptied, so a parenthesis or a bracket standing inside a
# string cannot end a param block or be read as a type name.
function Get-NoString {
  [CmdletBinding()]
  param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)
  $out = [Text.StringBuilder]::new()
  $q = ''
  foreach ($c in $Line.ToCharArray()) {
    if ($q -ceq '') {
      if ($c -ceq "'" -or $c -ceq '"') { $q = "$c"; [void]$out.Append($c); [void]$out.Append($c); continue }
      [void]$out.Append($c)
    } elseif ("$c" -ceq $q) { $q = '' }
  }
  return $out.ToString()
}

$ops = 'eq|ne|match|notmatch|like|notlike|replace|split|contains|notcontains|in|notin'
$bare = [regex]::new("(^|[^-A-Za-z0-9_])-($ops)[ \t]+[""']")
$said = [regex]::new("(^|[^-A-Za-z0-9_])-[ci]($ops)[ \t]+[""']")

# A NUMERIC PARAMETER TYPE, which is the binder converting before the script runs.
$opens = [regex]::new('(^|[^-A-Za-z0-9_$])param[ \t]*\(', 'IgnoreCase')
$numeric = [regex]::new(
  '\[[ \t]*(system\.)?(byte|sbyte|int16|uint16|short|ushort|int|int32|uint32|uint|long|int64|ulong|uint64|single|float|double|decimal|bigint)(\[\])?[ \t]*\]',
  'IgnoreCase')

$found = [System.Collections.Generic.List[string]]::new()
$seen = 0
$blocks = 0
foreach ($path in $paths) {
  $short = if ($path.StartsWith("$root/", [StringComparison]::Ordinal)) { $path.Substring($root.Length + 1) } else { $path }
  $no = 0
  $inBlock = $false
  $depth = 0
  foreach ($raw in [IO.File]::ReadAllLines($path)) {
    $no++
    if ($inBlock) { if ($raw -cmatch '#>') { $inBlock = $false }; continue }
    if ($raw -cmatch '^[ \t]*<#') { if ($raw -cnotmatch '#>') { $inBlock = $true }; continue }
    $line = Get-Code -Line $raw

    foreach ($re in @($bare, $said)) {
      $rest = $line
      while ($true) {
        $m = $re.Match($rest)
        if (-not $m.Success) { break }
        $q = $m.Value[$m.Value.Length - 1]
        $rest = $rest.Substring($m.Index + $m.Length)
        $end = $rest.IndexOf($q)
        if ($end -lt 0) { break }
        $lit = $rest.Substring(0, $end)
        $rest = $rest.Substring($end + 1)
        if ((Get-Bare -Literal $lit) -cnotmatch '[A-Za-z]') { continue }
        $seen++
        if ($re -eq $said) { continue }
        $op = ($m.Value -creplace '^[^-]*-', '') -creplace "[ \t]+[""']$", ''
        $found.Add("${short}:$no compares with -$op against $q$lit$q and does not say whether case is folded - write -c$op or -i$op")
      }
    }

    if ($line -cmatch '\.(StartsWith|EndsWith)\(' -and $line -cnotmatch 'StringComparison') {
      $found.Add("${short}:$no calls .StartsWith or .EndsWith with no StringComparison, which compares by culture - pass [StringComparison]::Ordinal")
    }
    # Two constructs fold case with no operator to read. A [ValidateSet] is always over text,
    # so it always has to say; a switch is written -CaseSensitive whatever it switches on,
    # because a rule with an exception for the numeric ones is a rule nobody can apply.
    if ($line -cmatch '\[ValidateSet\(' -and $line -cnotmatch 'IgnoreCase') {
      $found.Add("${short}:$no declares a [ValidateSet] that does not say whether case is folded - add IgnoreCase=`$false or IgnoreCase=`$true")
    }
    if ($line -cmatch '(^|[^-A-Za-z0-9_])switch[ \t]*\(' -and $line -cnotmatch '-CaseSensitive') {
      $found.Add("${short}:$no opens a switch that does not say whether case is folded - write switch -CaseSensitive")
    }

    # Every param( block is tracked to its closing parenthesis, over as many lines as it takes,
    # with strings emptied first so a parenthesis inside a pattern does not end it. Inside one,
    # a type the binder converts a number into is refused, whatever the parameter is called and
    # whoever calls it - a rule with an exception for the ones nobody types on a command line is
    # a rule nobody can apply.
    $plain = Get-NoString -Line $line
    $inside = [Text.StringBuilder]::new()
    $i = 0
    while ($i -lt $plain.Length) {
      if ($depth -eq 0) {
        $m = $opens.Match($plain, $i)
        if (-not $m.Success) { break }
        $blocks++
        $depth = 1
        $i = $m.Index + $m.Length
      } else {
        $c = $plain[$i]
        if ($c -ceq '(') { $depth++ }
        elseif ($c -ceq ')') { $depth--; if ($depth -eq 0) { $i++; continue } }
        [void]$inside.Append($c)
        $i++
      }
    }
    if ($numeric.IsMatch($inside.ToString())) {
      $found.Add("${short}:$no declares a parameter with a numeric type, and the binder converts before the script runs - 12.6 arrives as 13. Write [string] and judge it with the rule the shell twin uses")
    }
  }
}

if ($found.Count -gt 0) {
  $found
  "case-check: FAIL - $($found.Count) spelling(s) in bin/ and lib/ accept more than they say"
  exit 1
}
"case-check: $seen comparison(s) against a text literal in $($paths.Count) file(s), every one saying whether case is folded."
"case-check: $blocks param block(s) in the same files, none declaring a type the binder converts."
