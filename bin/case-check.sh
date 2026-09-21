#!/usr/bin/env bash
# Every spelling in bin/ and lib/ that silently accepts more than it says is refused here.
#
# TWO SPELLINGS ARE HELD, and the second is not a case question. A comparison against a text
# literal says whether it folds case, and a parameter is not declared with a type the binder
# converts a number into. The rule both share is that the spelling itself carries what the code
# accepts, so nobody has to keep a list or read a comment that has drifted. The command carries
# the name of the first of them and holds both.
#
# PowerShell's -eq -ne -match -notmatch -like -notlike -replace -split -contains -notcontains
# -in -notin all ignore case by DEFAULT, and every bash twin of them - [ = ], case, grep, awk -
# compares bytes. So a bare operator in the PowerShell half of a pair accepts a spelling the
# bash half refuses, and nothing on either side says so. These commands write to the platform:
# they create issues, edit bodies, move cards and mint tags, and a comparison that quietly
# matches more than it says can act on the wrong ticket.
#
# THE RULE IS THE SPELLING, NOT A LIST. A comparison whose operand is a text literal is written
# `-ceq` where it must compare bytes and `-ieq` where it folds case on purpose - the `i` form
# is the reason, written where it stays true, instead of a comment that drifts or an allow-list
# that has to be kept. A bare form is refused because it says neither.
#
# THREE CONSTRUCTS FOLD CASE WITH NO OPERATOR TO READ. `switch` matches without case, a
# `[ValidateSet]` binds without case, and a PowerShell `@{}` hashtable resolves its keys
# without case - `$h['type:bug']=$true; $h.ContainsKey('type:Bug')` answers True. The first
# two are read here. The third is not, because `@{}` is also how an ordinary object is
# written and a check that fired on every one of them would be switched off in a week; a
# hashtable whose keys are text is declared with [StringComparer]::Ordinal instead, and
# lib/Board.psm1, bin/schema-check.ps1 and bin/solution-path.ps1 are where that already is.
#
# WHAT IT DOES NOT SEE: a comparison between two VARIABLES -
# `$a -ceq $b` - carries no literal, so nothing here can tell a string comparison from a
# numeric one and none of them is judged. Nor is a comparison in test/, whose operands are
# written on both sides by this repository and whose bash twin is byte-exact.
#
# A LITERAL CARRIES CASE only where a letter survives its regex escapes and its character
# classes: `'^##[ \t]'` and `'^[0-9A-Fa-f]{6}$'` hold no case at all, and flagging them is how
# a check gets switched off.
#
# .StartsWith(string) and .EndsWith(string) compare by CULTURE, which is the same silent
# acceptance one class over: a zero-width joiner in front of the operand makes them answer True
# where `case`, `grep -F` and awk answer False. They are read here too.
#
# A NUMERIC PARAMETER TYPE IS THE SAME DEFECT WITH NO OPERATOR AT ALL. `[int] $Number` hands the
# conversion to the binder, which runs BEFORE the script's first line, so no guard written in the
# body can see what was typed: measured 2026-09-05, `-Number 12.6` bound to 13 and the command
# edited issue 13 in silence, where every shell twin's `case "$n" in ''|*[!0-9]*)` refused it -
# eleven of twelve inputs answered differently. So a param( block in bin/ or lib/ may not declare
# a type the binder converts a number into, and the parameter is [string] judged by the same rule
# the shell twin uses. THE RULE HAS NO EXCEPTION for a parameter nobody types on a command line,
# because a rule that has to know who calls a function is a rule nobody can apply by reading.
#
# WHAT IT STILL DOES NOT SEE: a [string] parameter written with no rule beside it. A string that
# holds a number looks exactly like every other string, so there is no spelling to refuse, and
# the twin tests are what hold that half.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

case "${1:-}" in
  -h|--help) echo "usage: case-check.sh [ROOT]"; exit 0 ;;
esac
[ $# -le 1 ] || { echo "error: usage: case-check.sh [ROOT]" >&2; exit 2; }
[ $# -eq 0 ] || ROOT="$1"

where=()
[ -d "$ROOT/bin" ] && where+=("$ROOT/bin")
[ -d "$ROOT/lib" ] && where+=("$ROOT/lib")
[ ${#where[@]} -gt 0 ] || { echo "error: $ROOT has neither a bin/ nor a lib/ to read" >&2; exit 2; }

files=()
while IFS= read -r f; do files+=("$f"); done < <(
  find "${where[@]}" -type f \( -name '*.ps1' -o -name '*.psm1' \) | LC_ALL=C sort)
[ ${#files[@]} -gt 0 ] || { echo "error: no PowerShell script under $ROOT" >&2; exit 2; }

awk -v root="$ROOT" '
  function short(p) { return (index(p, root "/") == 1) ? substr(p, length(root) + 2) : p }

  # What a literal holds once its escapes and character classes are gone. Both escape
  # characters count: the regex backslash, and the backtick PowerShell writes a tab with.
  function bare(s,   out, i, c, incl) {
    out = ""; incl = 0
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (c == "\\" || c == "`") { i++; continue }
      if (c == "[")  { incl = 1; continue }
      if (c == "]")  { incl = 0; continue }
      if (incl) continue
      out = out c
    }
    return out
  }

  # The line without its comment. A # inside a string is not one.
  function code(s,   out, i, c, q) {
    out = ""; q = ""
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (q == "") {
        if (c == "#") return out
        if (c == "\047" || c == "\"") q = c
      } else if (c == q) q = ""
      out = out c
    }
    return out
  }

  # The line with every quoted span emptied, so a parenthesis or a bracket standing inside a
  # string cannot end a param block or be read as a type name.
  function nostr(s,   out, i, c, q) {
    out = ""; q = ""
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (q == "") {
        if (c == "\047" || c == "\"") { q = c; out = out c c; continue }
        out = out c
      } else if (c == q) q = ""
    }
    return out
  }

  FNR == 1 { nfiles++; inblock = 0; pdepth = 0 }
  {
    if (inblock) { if ($0 ~ /#>/) inblock = 0; next }
    if ($0 ~ /^[ \t]*<#/) { if ($0 !~ /#>/) inblock = 1; next }
    line = code($0)

    rest = line
    while (match(rest, /(^|[^-A-Za-z0-9_])-(eq|ne|match|notmatch|like|notlike|replace|split|contains|notcontains|in|notin)[ \t]+["\047]/)) {
      hit = substr(rest, RSTART, RLENGTH)
      rest = substr(rest, RSTART + RLENGTH)
      op = hit; sub(/^[^-]*-/, "", op); sub(/[ \t]+["\047]$/, "", op)
      q = substr(hit, length(hit), 1)
      end = index(rest, q)
      if (end == 0) continue
      lit = substr(rest, 1, end - 1)
      rest = substr(rest, end + 1)
      if (bare(lit) !~ /[A-Za-z]/) continue
      seen++
      bad++
      printf "%s:%d compares with -%s against %s%s%s and does not say whether case is folded - write -c%s or -i%s\n",
             short(FILENAME), FNR, op, q, lit, q, op, op
    }

    # The literal-bearing comparisons that DO say it, so the green line can count them.
    rest = line
    while (match(rest, /(^|[^-A-Za-z0-9_])-[ci](eq|ne|match|notmatch|like|notlike|replace|split|contains|notcontains|in|notin)[ \t]+["\047]/)) {
      hit = substr(rest, RSTART, RLENGTH)
      rest = substr(rest, RSTART + RLENGTH)
      q = substr(hit, length(hit), 1)
      end = index(rest, q)
      if (end == 0) continue
      lit = substr(rest, 1, end - 1)
      rest = substr(rest, end + 1)
      if (bare(lit) ~ /[A-Za-z]/) seen++
    }

    if (line ~ /\.(StartsWith|EndsWith)\(/ && line !~ /StringComparison/) {
      bad++
      printf "%s:%d calls .StartsWith or .EndsWith with no StringComparison, which compares by culture - pass [StringComparison]::Ordinal\n",
             short(FILENAME), FNR
    }

    # Two constructs fold case with no operator to read. A [ValidateSet] is always over text,
    # so it always has to say; a switch is written -CaseSensitive whatever it switches on,
    # because a rule with an exception for the numeric ones is a rule nobody can apply.
    if (line ~ /\[ValidateSet\(/ && line !~ /IgnoreCase/) {
      bad++
      printf "%s:%d declares a [ValidateSet] that does not say whether case is folded - add IgnoreCase=$false or IgnoreCase=$true\n",
             short(FILENAME), FNR
    }
    if (line ~ /(^|[^-A-Za-z0-9_])switch[ \t]*\(/ && line !~ /-CaseSensitive/) {
      bad++
      printf "%s:%d opens a switch that does not say whether case is folded - write switch -CaseSensitive\n",
             short(FILENAME), FNR
    }

    # A NUMERIC PARAMETER TYPE, which is the binder converting before the script runs.
    #
    # Every param( block in bin/ and lib/ is tracked to its closing parenthesis, over as many
    # lines as it takes, with strings emptied first so a parenthesis inside a pattern does not
    # end it. Inside one, a type the binder converts a number into is refused, whatever the
    # parameter is called and whoever calls it - a rule with an exception for the ones nobody
    # types on a command line is a rule nobody can apply.
    plain = nostr(line)
    inside = ""
    i = 1
    while (i <= length(plain)) {
      if (pdepth == 0) {
        r = substr(plain, i)
        if (match(r, /(^|[^-A-Za-z0-9_$])[Pp][Aa][Rr][Aa][Mm][ \t]*\(/)) {
          nparam++
          pdepth = 1
          i = i + RSTART + RLENGTH - 1
        } else break
      } else {
        c = substr(plain, i, 1)
        if (c == "(") pdepth++
        else if (c == ")") { pdepth--; if (pdepth == 0) { i++; continue } }
        inside = inside c
        i++
      }
    }
    if (inside ~ /\[/ && tolower(inside) ~ /\[[ \t]*(system\.)?(byte|sbyte|int16|uint16|short|ushort|int|int32|uint32|uint|long|int64|ulong|uint64|single|float|double|decimal|bigint)(\[\])?[ \t]*\]/) {
      bad++
      printf "%s:%d declares a parameter with a numeric type, and the binder converts before the script runs - 12.6 arrives as 13. Write [string] and judge it with the rule the shell twin uses\n",
             short(FILENAME), FNR
    }
  }

  END {
    if (bad > 0) {
      printf "case-check: FAIL - %d spelling(s) in bin/ and lib/ accept more than they say\n", bad
      exit 1
    }
    printf "case-check: %d comparison(s) against a text literal in %d file(s), every one saying whether case is folded.\n", seen, nfiles
    printf "case-check: %d param block(s) in the same files, none declaring a type the binder converts.\n", nparam
  }
' "${files[@]}"
