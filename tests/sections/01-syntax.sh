#!/usr/bin/env bash
# the syntax of every script, and every rule tagged; one section of the suite, run by tests/check.sh with the others
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

section "syntax"
for f in "$ROOT"/bin/*.sh "$ROOT/bin/ai-core"; do bash -n "$f" || fail "bash -n $f"; done
# A grep -q stops at its first match and breaks the pipe of a printf or echo still writing into it;
# under pipefail the pipeline then fails although grep matched. A variable goes to grep as a here-string.
hits="$(grep -nE '(printf|echo) [^|]*\| *(tr [^|]*\| *)?grep +-[a-zA-Z]*q' "$ROOT"/bin/*.sh "$ROOT"/lib/*.sh "$ROOT"/tests/*.sh "$ROOT"/tests/sections/*.sh || true)"
[ -z "$hits" ] || fail "printf or echo piped into grep -q, which breaks the pipe under pipefail; give grep a here-string: $hits"
echo "  $(ls "$ROOT"/bin/*.sh | wc -l | tr -d ' ') bash scripts and the ai-core launcher parse"

section "no count of issues, cards or lines caps a package"
# Planners read such a count as a cap and split packages small, and every further package pays its
# plan, gate and review again; only the build's context budget cuts a package. Prints each line
# under the paths given that names a count as the most a package or a round may hold.
package_caps() {
  grep -rniE '(at most|up to|no more than)( about| approximately)? [0-9]+ (issues|cards|changed lines)' "$@" || true
}
P="$WORK/package-caps"; mkdir -p "$P"
printf -- '- of at least two issues, and of one only where a defect cannot wait\n' > "$P/innocent.md"
[ -z "$(package_caps "$P")" ] || fail "a minimum of two issues was reported as a cap: $(package_caps "$P")"
for planted in 'and of at most about 8 issues or 400 changed lines' 'clears up to 10 cards a round' \
               'one build of no more than approximately 400 changed lines'; do
  printf -- '- %s\n' "$planted" > "$P/planted.md"
  [ -n "$(package_caps "$P")" ] || fail "a planted cap stayed green: $planted"
done
[ -z "$(package_caps "$ROOT/rules" "$ROOT/skills")" ] || fail "a rule or a skill caps a package by a count: $(package_caps "$ROOT/rules" "$ROOT/skills")"
echo "  no rule and no skill caps a package by a count of issues, cards or changed lines"

section "every rule carries its enforcement tag"
bash "$ROOT/bin/rules-check.sh" "$ROOT/rules" > /dev/null || fail "rules-check.sh on rules/"
# A project harness is checked whole: a skill named for another folder and an agent below Sonnet are
# refused, a good skill and a good agent are not; without them it passes
H="$WORK/harness-check"; mkdir -p "$H/skills/good" "$H/skills/renamed" "$H/agents" "$H/rules"
printf -- '---\nname: good\ndescription: a good skill\n---\nbody\n' > "$H/skills/good/SKILL.md"
printf -- '---\nname: other\ndescription: named for another folder\n---\n' > "$H/skills/renamed/SKILL.md"
printf -- '---\nname: cheap\ndescription: runs on haiku\nmodel: haiku\n---\n' > "$H/agents/cheap.md"
printf -- '---\nname: fine\ndescription: runs on sonnet\nmodel: sonnet\n---\n' > "$H/agents/fine.md"
rc=0; out="$(bash "$ROOT/bin/rules-check.sh" "$H" 2>&1)" || rc=$?
problems="$(grep -v '^rules-check:' <<< "$out" | grep '[^[:space:]]' || true)"
[ "$rc" = 1 ] && [ "$(grep -c '[^[:space:]]' <<< "$problems")" = 2 ] && grep -q "renamed.SKILL.md: its name is 'other', not its folder's 'renamed'" <<< "$problems" && grep -q "cheap.md: model 'haiku' is below Sonnet" <<< "$problems" || fail "rules-check.sh on a harness with two faults (exit $rc): $out"
rm "$H/skills/renamed/SKILL.md" "$H/agents/cheap.md"
rc=0; out="$(bash "$ROOT/bin/rules-check.sh" "$H" 2>&1)" || rc=$?
[ "$rc" = 0 ] && grep -qF 'rules-check: 1 skill(s) and 1 agent(s), 0 with a problem; no rule section of its own.' <<< "$out" || fail "rules-check.sh on a good harness (exit $rc): $out"

section "every committed script carries its executable bit: a runner executes bin/*.sh directly"
bad="$(cd "$ROOT" && git ls-files -s | awk '$1 == "100644" {print $4}' | while IFS= read -r f; do [ "$(head -c 2 "$f" 2>/dev/null)" = "#!" ] && printf "%s " "$f"; done; true)"
[ -z "$bad" ] || fail "committed without the executable bit (git update-index --chmod=+x): $bad"
echo "  every file with a shebang is 100755 in the index"

exit 0
