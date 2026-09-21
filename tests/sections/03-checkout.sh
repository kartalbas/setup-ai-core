#!/usr/bin/env bash
# a checkout on both twins: bootstrap, install, the assembled rules, the second run, the session start; one section of the suite, run by tests/check.sh with the others
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

section "bootstrap both twins"
for t in sh ps1; do
  mkdir -p "$WORK/$t/.ai-core"
  printf 'GRAFT_EXECUTION_MODE="skip"\n' > "$WORK/$t/.ai-core/config.env"
done
bash "$ROOT/bin/init.sh" "$WORK/sh" --no-doctor > "$WORK/sh.log" 2>&1 || fail "init.sh exited $? (see $WORK/sh.log)"
pwsh -NoProfile -File "$ROOT/bin/init.ps1" -TargetDir "$(native "$WORK/ps1")" -NoDoctor > "$WORK/ps1.log" 2>&1 || fail "init.ps1 exited $?"
for t in sh ps1; do
  if grep -aiE 'warning|error' "$WORK/$t.log"; then fail "init.$t printed a warning or error"; fi
done

for t in sh ps1; do
  mkdir -p "$WORK/agents-$t/.ai-core"; printf 'GRAFT_EXECUTION_MODE="skip"\nAGENTS="cursor claude"\n' > "$WORK/agents-$t/.ai-core/config.env"
done
bash "$ROOT/bin/init.sh" "$WORK/agents-sh" --no-doctor > /dev/null 2>&1 || fail "init.sh with AGENTS"
pwsh -NoProfile -File "$ROOT/bin/init.ps1" -TargetDir "$(native "$WORK/agents-ps1")" -NoDoctor > /dev/null 2>&1 || fail "init.ps1 with AGENTS"
for t in sh ps1; do
  [ -f "$WORK/agents-$t/.cursorrules" ] || fail "init.$t did not deploy the pointer of a served agent"
  [ ! -e "$WORK/agents-$t/.windsurfrules" ] && [ ! -e "$WORK/agents-$t/.github" ] && [ ! -e "$WORK/agents-$t/.openhands" ] && [ ! -e "$WORK/agents-$t/.codex" ] && [ ! -e "$WORK/agents-$t/.agents/mcp_config.json" ] || fail "init.$t deployed the pointer of an agent the project does not serve"
done
echo "  AGENTS=\"cursor claude\": .cursorrules deployed; windsurf, copilot, openhands, codex and antigravity files not, on both twins"

(cd "$WORK/sh" && find . -type f | sort) > "$WORK/sh.list"
(cd "$WORK/ps1" && find . -type f | sort) > "$WORK/ps1.list"
if ! diff "$WORK/sh.list" "$WORK/ps1.list"; then fail "init.sh and init.ps1 deployed different files"; fi
echo "  $(wc -l < "$WORK/sh.list") files, identical on both twins"

section "install: --source uses the clone as it is, --repo clones and a second run pulls, the ai-core command runs init, on both twins"
bash "$ROOT/bin/install.sh" --source "$ROOT" --dir "$WORK/not-created-sh" --no-path --no-doctor > "$WORK/install.sh.log" 2>&1 || fail "install.sh --source (see $WORK/install.sh.log)"
[ ! -e "$WORK/not-created-sh" ] || fail "install.sh --source created something"
CORE_SH="$WORK/home-sh/.setup-ai-core"
bash "$ROOT/bin/install.sh" --repo "$ROOT" --dir "$CORE_SH" --no-path --no-doctor > "$WORK/install.sh.log" 2>&1 || fail "install.sh --repo (see $WORK/install.sh.log)"
[ -d "$CORE_SH/.git" ] || fail "install.sh --repo did not clone"
bash "$ROOT/bin/install.sh" --repo "$ROOT" --dir "$CORE_SH" --no-path --no-doctor > "$WORK/install.sh.log" 2>&1 || fail "install.sh second run (see $WORK/install.sh.log)"
grep -q "updating" "$WORK/install.sh.log" || fail "install.sh second run did not update"
[ "$("$CORE_SH/bin/ai-core" version)" = "$(git -C "$CORE_SH" show HEAD:VERSION | tr -d '\r\n')" ] || fail "ai-core version from the clone"
[ "$("$ROOT/bin/ai-core" version)" = "$(tr -d '\r\n' < "$ROOT/VERSION")" ] || fail "ai-core version"
"$ROOT/bin/ai-core" help > /dev/null || fail "ai-core help"
"$ROOT/bin/ai-core" no-such-command > /dev/null 2>&1 && fail "ai-core accepted an unknown command"
mkdir -p "$WORK/via-sh/.ai-core"; printf 'GRAFT_EXECUTION_MODE="skip"\n' > "$WORK/via-sh/.ai-core/config.env"
"$ROOT/bin/ai-core" init "$WORK/via-sh" --no-doctor > /dev/null 2>&1 || fail "ai-core init through the command"
(cd "$WORK/via-sh" && find . -type f | sort) | diff - "$WORK/sh.list" > /dev/null || fail "init through the command deployed a different file set"
pwsh -NoProfile -File "$ROOT/bin/install.ps1" -Source "$(native "$ROOT")" -Dir "$(native "$WORK/not-created-ps")" -NoPath -NoDoctor > "$WORK/install.ps1.log" 2>&1 || fail "install.ps1 -Source (see $WORK/install.ps1.log)"
[ ! -e "$WORK/not-created-ps" ] || fail "install.ps1 -Source created something"
CORE_PS="$WORK/home-ps/.setup-ai-core"
pwsh -NoProfile -File "$ROOT/bin/install.ps1" -Repo "$(native "$ROOT")" -Dir "$(native "$CORE_PS")" -NoPath -NoDoctor > "$WORK/install.ps1.log" 2>&1 || fail "install.ps1 -Repo (see $WORK/install.ps1.log)"
[ -d "$CORE_PS/.git" ] || fail "install.ps1 -Repo did not clone"
pwsh -NoProfile -File "$ROOT/bin/install.ps1" -Repo "$(native "$ROOT")" -Dir "$(native "$CORE_PS")" -NoPath -NoDoctor > "$WORK/install.ps1.log" 2>&1 || fail "install.ps1 second run (see $WORK/install.ps1.log)"
grep -q "updating" "$WORK/install.ps1.log" || fail "install.ps1 second run did not update"
[ "$(pwsh -NoProfile -File "$CORE_PS/bin/ai-core.ps1" version | tr -d '\r')" = "$(git -C "$CORE_PS" show HEAD:VERSION | tr -d '\r\n')" ] || fail "ai-core.ps1 version from the clone"
mkdir -p "$WORK/via-ps/.ai-core"; printf 'GRAFT_EXECUTION_MODE="skip"\n' > "$WORK/via-ps/.ai-core/config.env"
pwsh -NoProfile -File "$ROOT/bin/ai-core.ps1" init -TargetDir "$(native "$WORK/via-ps")" -NoDoctor > /dev/null 2>&1 || fail "ai-core.ps1 init through the command"
(cd "$WORK/via-ps" && find . -type f | sort) | diff - "$WORK/sh.list" > /dev/null || fail "init.ps1 through the command deployed a different file set"
echo "  --source leaves the clone alone, --repo clones and pulls, init through both commands deploys the same files"

section "the assembled rules file: one section per source file, identical on both twins, every rule tagged"
SECTIONS="$(ls "$ROOT"/rules/[0-9][0-9]-*.md | wc -l | tr -d " ")"
MARKERS="$(grep -c "^<!-- setup-ai-core " "$WORK/sh/.ai-core/rules/rules.md")"
[ "$MARKERS" = "$SECTIONS" ] || fail "assembled rules.md has $MARKERS section markers, expected $SECTIONS"
cmp -s "$WORK/sh/.ai-core/rules/rules.md" "$WORK/ps1/.ai-core/rules/rules.md" || fail "assembled rules.md differs between the twins"
bash "$ROOT/bin/rules-check.sh" "$WORK/sh/.ai-core/rules/rules.md" > /dev/null || fail "rules-check on the assembled rules.md"
echo "  $SECTIONS sections assembled"

section "second run creates nothing"
bash "$ROOT/bin/init.sh" "$WORK/sh" --no-doctor > "$WORK/sh-2.log" 2>&1 || fail "init.sh second run"
pwsh -NoProfile -File "$ROOT/bin/init.ps1" -TargetDir "$(native "$WORK/ps1")" -NoDoctor > "$WORK/ps1-2.log" 2>&1 || fail "init.ps1 second run"
for t in sh ps1; do
  grep -aqE '^  (created|refreshed|removed) ' "$WORK/$t-2.log" && fail "init.$t is not idempotent: $(grep -aE '^  (created|refreshed|removed) ' "$WORK/$t-2.log")"
  grep -aq '^  unchanged  [1-9][0-9]* file(s)$' "$WORK/$t-2.log" || fail "init.$t second run did not report the unchanged files"
done
(cd "$WORK/sh" && find . -type f | sort) | diff - "$WORK/sh.list" > /dev/null || fail "init.sh changed the file set on re-run"

section "session-start in each target"
[ ! -e "$WORK/sh/.ai-core/bin" ] || fail "init.sh copied scripts into the checkout"
(cd "$WORK/sh" && "$ROOT/bin/ai-core" session-start > /dev/null) || fail "ai-core session-start in bash target"
(cd "$WORK/sh" && "$ROOT/bin/ai-core" session-start --json > "$WORK/sh.json")
(cd "$WORK/ps1" && pwsh -NoProfile -File "$(native "$ROOT/bin/ai-core.ps1")" session-start > /dev/null) || fail "ai-core.ps1 session-start in pwsh target"
(cd "$WORK/ps1" && pwsh -NoProfile -File "$(native "$ROOT/bin/ai-core.ps1")" session-start -Json > "$WORK/ps1.json")
node -e '
  const fs = require("fs");
  const [a, b] = process.argv.slice(1, 3).map(f => JSON.parse(fs.readFileSync(f, "utf8")));
  const ka = Object.keys(a).sort().join(","), kb = Object.keys(b).sort().join(",");
  if (ka !== kb) { console.error("  keys differ:\n   sh : " + ka + "\n   ps1: " + kb); process.exit(1); }
  // repository and root name the two different temp directories; everything else must agree in value and type
  for (const k of Object.keys(a).filter(k => k !== "repository" && k !== "root")) {
    if (JSON.stringify(a[k]) !== JSON.stringify(b[k])) { console.error("  " + k + ": sh=" + JSON.stringify(a[k]) + " ps1=" + JSON.stringify(b[k])); process.exit(1); }
  }
  if (a.harness_version !== fs.readFileSync(process.argv[3], "utf8").trim()) { console.error("  harness_version " + a.harness_version + " is not the repository VERSION"); process.exit(1); }
' "$WORK/sh.json" "$WORK/ps1.json" "$ROOT/VERSION" || fail "session-start JSON differs between twins"
# --tool <one tool>, the form the hooks use: the modes of that tool are switched on at the end of the output, a skill whole with its level
MH="$WORK/modes-home"; mkdir -p "$MH/.claude/skills/caveman"; : > "$MH/.claude/.i-have-adhd-always"
printf -- '---\nname: caveman\n---\nCAVEMAN RULES: short.\n' > "$MH/.claude/skills/caveman/SKILL.md"
printf 'claude\tcaveman\tlite\tskill:caveman\t-\t-\nclaude\tponytail\tfull\talways:ponytail\t-\t-\nclaude\ti-have-adhd\ton\tfile:~/.claude/.i-have-adhd-always\t-\t-\n' > "$WORK/modes.tsv"
(cd "$WORK/sh" && HOME="$MH" TEAM_MODES_FILE="$WORK/modes.tsv" bash "$ROOT/bin/session-start.sh" --tool claude > "$WORK/modes-sh.log" 2>&1) || fail "session-start.sh --tool claude (see $WORK/modes-sh.log)"
(cd "$WORK/ps1" && HOME="$MH" USERPROFILE="$(native "$MH")" TEAM_MODES_FILE="$(native "$WORK/modes.tsv")" pwsh -NoProfile -File "$ROOT/bin/session-start.ps1" -Tool claude > "$WORK/modes-ps1.log" 2>&1) || fail "session-start.ps1 -Tool claude (see $WORK/modes-ps1.log)"
for twin in sh ps1; do
  grep -aq '^CAVEMAN MODE ACTIVE — level: lite' "$WORK/modes-$twin.log" && grep -aq '^CAVEMAN RULES: short\.' "$WORK/modes-$twin.log" && grep -aq '^ARGUMENTS: lite' "$WORK/modes-$twin.log" || fail "session-start.$twin --tool claude does not switch the caveman skill on (see $WORK/modes-$twin.log)"
  grep -aq '^name: caveman' "$WORK/modes-$twin.log" && fail "session-start.$twin prints the front matter of the skill"
  grep -aq '^PONYTAIL MODE: full, switched on by its own hook' "$WORK/modes-$twin.log" && grep -aq '^I-HAVE-ADHD MODE: on, switched on by its own hook' "$WORK/modes-$twin.log" || fail "session-start.$twin --tool claude does not name the plugin modes (see $WORK/modes-$twin.log)"
done
(cd "$WORK/sh" && HOME="$MH" TEAM_MODES_FILE="$WORK/modes.tsv" bash "$ROOT/bin/session-start.sh" --tool claude --json | jq -e '.repository' > /dev/null) || fail "session-start.sh --tool claude --json is not JSON"
(cd "$WORK/sh" && HOME="$MH" TEAM_MODES_FILE="$WORK/modes.tsv" bash "$ROOT/bin/session-start.sh" > "$WORK/modes-none.log" 2>&1) || fail "session-start.sh without --tool (see $WORK/modes-none.log)"
grep -aq 'MODE ACTIVE' "$WORK/modes-none.log" && fail "session-start.sh without --tool switches modes on"
echo "  --tool claude: the caveman skill printed whole with its level, the plugin modes named, nothing of it in the JSON or without --tool, on both twins"

for t in sh ps1; do grep -q 'ai-core session-start --tool claude' "$WORK/$t/.claude/settings.json" || fail "the template settings.json deployed by init.$t carries no session-start hook"; done
exit 0
