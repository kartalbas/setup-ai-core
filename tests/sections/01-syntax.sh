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
