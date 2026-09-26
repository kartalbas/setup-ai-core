#!/usr/bin/env bash
# the syntax of every script, and every rule tagged; one section of the suite, run by tests/check.sh with the others
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

section "syntax"
for f in "$ROOT"/bin/*.sh "$ROOT/bin/ai-core"; do bash -n "$f" || fail "bash -n $f"; done
# A grep -q stops at its first match and breaks the pipe of a printf or echo still writing into it;
# under pipefail the pipeline then fails although grep matched. A variable goes to grep as a here-string.
hits="$(grep -nE '(printf|echo) [^|]*\| *(tr [^|]*\| *)?grep +-[a-zA-Z]*q' "$ROOT"/bin/*.sh "$ROOT"/lib/*.sh "$ROOT"/tests/*.sh "$ROOT"/tests/sections/*.sh || true)"
[ -z "$hits" ] || fail "printf or echo piped into grep -q, which breaks the pipe under pipefail; give grep a here-string: $hits"
PS_EXPECTED="$(ls "$ROOT"/bin/*.ps1 | wc -l | tr -d ' ')"
PS_SCANNED="$(CHECK_ROOT="$(native "$ROOT")" pwsh -NoProfile -Command '
  $bad = 0; $n = 0
  Get-ChildItem (Join-Path $env:CHECK_ROOT "bin/*.ps1") | ForEach-Object {
    $n++
    $e = $null
    [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$e) | Out-Null
    if ($e) { [Console]::Error.WriteLine("  $($_.Name): $($e[0].Message)"); $bad = 1 }
  }
  Write-Output $n
  exit $bad
')" || fail "PowerShell parse"
[ "$PS_SCANNED" = "$PS_EXPECTED" ] || fail "PowerShell parse scanned $PS_SCANNED of $PS_EXPECTED scripts"
echo "  $(ls "$ROOT"/bin/*.sh | wc -l | tr -d ' ') bash scripts, the ai-core launcher and $PS_SCANNED PowerShell scripts parse"

section "every rule carries its enforcement tag, on both twins"
bash "$ROOT/bin/rules-check.sh" "$ROOT/rules" > /dev/null || fail "rules-check.sh on rules/"
# A project harness is checked whole: a skill named for another folder and an agent below Sonnet are
# refused, a good skill and a good agent are not; without them it passes
H="$WORK/harness-check"; mkdir -p "$H/skills/good" "$H/skills/renamed" "$H/agents" "$H/rules"
printf -- '---\nname: good\ndescription: a good skill\n---\nbody\n' > "$H/skills/good/SKILL.md"
printf -- '---\nname: other\ndescription: named for another folder\n---\n' > "$H/skills/renamed/SKILL.md"
printf -- '---\nname: cheap\ndescription: runs on haiku\nmodel: haiku\n---\n' > "$H/agents/cheap.md"
printf -- '---\nname: fine\ndescription: runs on sonnet\nmodel: sonnet\n---\n' > "$H/agents/fine.md"
for t in sh ps1; do
  if [ "$t" = sh ]; then rc=0; out="$(bash "$ROOT/bin/rules-check.sh" "$H" 2>&1)" || rc=$?; else rc=0; out="$(pwsh -NoProfile -File "$ROOT/bin/rules-check.ps1" -RulesFile "$(native "$H")" 2>&1)" || rc=$?; fi
  problems="$(grep -v '^rules-check:' <<< "$out" | grep '[^[:space:]]' || true)"
  [ "$rc" = 1 ] && [ "$(grep -c '[^[:space:]]' <<< "$problems")" = 2 ] && grep -q "renamed.SKILL.md: its name is 'other', not its folder's 'renamed'" <<< "$problems" && grep -q "cheap.md: model 'haiku' is below Sonnet" <<< "$problems" || fail "rules-check.$t on a harness with two faults (exit $rc): $out"
done
rm "$H/skills/renamed/SKILL.md" "$H/agents/cheap.md"
for t in sh ps1; do
  if [ "$t" = sh ]; then rc=0; out="$(bash "$ROOT/bin/rules-check.sh" "$H" 2>&1)" || rc=$?; else rc=0; out="$(pwsh -NoProfile -File "$ROOT/bin/rules-check.ps1" -RulesFile "$(native "$H")" 2>&1)" || rc=$?; fi
  [ "$rc" = 0 ] && grep -qF 'rules-check: 1 skill(s) and 1 agent(s), 0 with a problem; no rule section of its own.' <<< "$out" || fail "rules-check.$t on a good harness (exit $rc): $out"
done
pwsh -NoProfile -File "$ROOT/bin/rules-check.ps1" -RulesFile "$(native "$ROOT/rules")" > /dev/null || fail "rules-check.ps1 on rules/"

section "every committed script carries its executable bit: a Windows clone records none, and a runner executes bin/*.sh directly"
bad="$(cd "$ROOT" && git ls-files -s | awk '$1 == "100644" {print $4}' | while IFS= read -r f; do [ "$(head -c 2 "$f" 2>/dev/null)" = "#!" ] && printf "%s " "$f"; done; true)"
[ -z "$bad" ] || fail "committed without the executable bit (git update-index --chmod=+x): $bad"
echo "  every file with a shebang is 100755 in the index"

exit 0
