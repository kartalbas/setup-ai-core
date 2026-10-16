#!/usr/bin/env bash
# a checkout: bootstrap, install, the assembled rules, the second run, the session start; one section of the suite, run by tests/check.sh with the others
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

section "bootstrap"
mkdir -p "$WORK/checkout/.ai-core"
printf 'UPDATE_CHECK="never"\n' > "$WORK/checkout/.ai-core/config.env"
bash "$ROOT/bin/init.sh" "$WORK/checkout" --no-doctor > "$WORK/checkout.log" 2>&1 || fail "init.sh exited $? (see $WORK/checkout.log)"
if grep -aiE 'warning|error' "$WORK/checkout.log"; then fail "init.sh printed a warning or error"; fi

mkdir -p "$WORK/agents/.ai-core"; printf 'UPDATE_CHECK="never"\nAGENTS="cursor claude"\n' > "$WORK/agents/.ai-core/config.env"
bash "$ROOT/bin/init.sh" "$WORK/agents" --no-doctor > /dev/null 2>&1 || fail "init.sh with AGENTS"
[ -f "$WORK/agents/.cursorrules" ] || fail "init.sh did not deploy the pointer of a served agent"
[ ! -e "$WORK/agents/.windsurfrules" ] && [ ! -e "$WORK/agents/.github" ] && [ ! -e "$WORK/agents/.openhands" ] && [ ! -e "$WORK/agents/.agents/mcp_config.json" ] || fail "init.sh deployed the pointer of an agent the project does not serve"
echo "  AGENTS=\"cursor claude\": .cursorrules deployed; windsurf, copilot, openhands and antigravity files not"

mkdir -p "$WORK/typo/.ai-core"; printf 'UPDATE_CHECK="never"\nAGENTS="claude cursr"\n' > "$WORK/typo/.ai-core/config.env"
bash "$ROOT/bin/init.sh" "$WORK/typo" --no-doctor > "$WORK/typo.log" 2>&1 && fail "init.sh accepted an unknown name in AGENTS"
grep -aq "error: AGENTS in .* names 'cursr'; known are claude, codex, antigravity, openhands, gemini, cursor, windsurf, copilot" "$WORK/typo.log" || fail "init.sh did not name the unknown agent: $(tail -n 2 "$WORK/typo.log")"
jq -e '.statusLine.command | test("ai-core\" statusline$")' "$WORK/typo/.claude/settings.json" > /dev/null 2>&1 || fail "init.sh stopped before the settings.json when AGENTS named an unknown agent"
grep -aq 'Harness .* in place' "$WORK/typo.log" && fail "init.sh reported the harness in place although AGENTS names an unknown agent"
echo "  AGENTS=\"claude cursr\": init deploys the rest, exits 1 and names 'cursr'"

(cd "$WORK/checkout" && find . -type f | sort) > "$WORK/checkout.list"
echo "  $(wc -l < "$WORK/checkout.list") files"

section "AGENTS.md without a map: the generic one under the binding rules; one of before replaced, one the repository tracks or somebody's own kept"
A="$WORK/checkout/AGENTS.md"
grep -q '^<!-- ai-core map: none yet' <<< "$(head -n1 "$A")" && grep -qxF '## Binding rules' "$A" && grep -q '^- Before any work, read the three rules files below, whole, unless your tool has loaded them: .*every other tool loads none of them\.$' "$A" && grep -q '^- The engineering rules, .*: @\.ai-core/rules/rules\.md$' "$A" && grep -q '^- `ai-core --help`: ' "$A" && grep -qxF '# This repository has no map yet' "$A" || fail "init.sh did not put the binding rules on the generic map: $(head -n 12 "$A" | tr '\n' '|')"
for c in before mine tracked; do
  C="$WORK/agentsmd-$c"; mkdir -p "$C/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$C/.ai-core/config.env"; git init -q "$C"
  case "$c" in
    before) printf '# AGENTS.md \342\200\224 Repository Navigation & Operations\n\nthe generic file of before 1.3.20\n' > "$C/AGENTS.md" ;;
    mine) printf '# mine\n' > "$C/AGENTS.md" ;;
    tracked) printf '# tracked\n' > "$C/AGENTS.md"; git -C "$C" add AGENTS.md; git -C "$C" commit -q -m tracked ;;
  esac
  bash "$ROOT/bin/init.sh" "$C" --no-doctor > "$C.log" 2>&1 || fail "init.sh with an AGENTS.md $c (see $C.log)"
  case "$c" in
    before) grep -q '^<!-- ai-core map: none yet' <<< "$(head -n1 "$C/AGENTS.md")" || fail "init.sh kept the generic AGENTS.md of before" ;;
    *) [ "$(cat "$C/AGENTS.md")" = "# $c" ] && grep -aq '^  kept .*AGENTS\.md' "$C.log" || fail "init.sh overwrote an AGENTS.md that is $c, or did not report it kept: $(head -n1 "$C/AGENTS.md")" ;;
  esac
done
echo "  the generic map carries the binding rules; the file of before is replaced, one the repository tracks or somebody's own is kept and reported"

section "install: --source uses the clone as it is, --repo clones and a second run pulls, the ai-core command runs init"
bash "$ROOT/bin/install.sh" --source "$ROOT" --dir "$WORK/not-created" --no-path --no-doctor > "$WORK/install.log" 2>&1 || fail "install.sh --source (see $WORK/install.log)"
[ ! -e "$WORK/not-created" ] || fail "install.sh --source created something"
CORE="$WORK/home/.setup-ai-core"
bash "$ROOT/bin/install.sh" --repo "$ROOT" --dir "$CORE" --no-path --no-doctor > "$WORK/install.log" 2>&1 || fail "install.sh --repo (see $WORK/install.log)"
[ -d "$CORE/.git" ] || fail "install.sh --repo did not clone"
bash "$ROOT/bin/install.sh" --repo "$ROOT" --dir "$CORE" --no-path --no-doctor > "$WORK/install.log" 2>&1 || fail "install.sh second run (see $WORK/install.log)"
grep -q "updating" "$WORK/install.log" || fail "install.sh second run did not update"
[ "$("$CORE/bin/ai-core" version)" = "$(git -C "$CORE" show HEAD:VERSION | tr -d '\r\n')" ] || fail "ai-core version from the clone"
[ "$("$ROOT/bin/ai-core" version)" = "$(tr -d '\r\n' < "$ROOT/VERSION")" ] || fail "ai-core version"
"$ROOT/bin/ai-core" help > /dev/null || fail "ai-core help"
"$ROOT/bin/ai-core" no-such-command > /dev/null 2>&1 && fail "ai-core accepted an unknown command"
mkdir -p "$WORK/via-command/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$WORK/via-command/.ai-core/config.env"
"$ROOT/bin/ai-core" init "$WORK/via-command" --no-doctor > /dev/null 2>&1 || fail "ai-core init through the command"
(cd "$WORK/via-command" && find . -type f | sort) | diff - "$WORK/checkout.list" > /dev/null || fail "init through the command deployed a different file set"
echo "  --source leaves the clone alone, --repo clones and pulls, init through the command deploys the same files"
# The PATH in a throwaway home, twice: the line goes into the shell profile exactly once
PH="$WORK/path-home"; mkdir -p "$PH"; : > "$PH/.bashrc"
for run in 1 2; do
  env -u XDG_CONFIG_HOME HOME="$PH" bash "$ROOT/bin/install.sh" --source "$ROOT" --no-doctor > "$WORK/path.log" 2>&1 || fail "install.sh run $run with the PATH (see $WORK/path.log)"
done
[ "$(grep -c '# setup-ai-core' "$PH/.bashrc")" = 1 ] || fail "install.sh did not put ai-core on the PATH exactly once: $(cat "$PH/.bashrc")"
echo "  the PATH: once in the shell profile after two runs"

section "the assembled rules file: one section per source file, every rule tagged"
SECTIONS="$(ls "$ROOT"/rules/[0-9][0-9]-*.md | wc -l | tr -d " ")"
MARKERS="$(grep -c "^<!-- setup-ai-core " "$WORK/checkout/.ai-core/rules/rules.md")"
[ "$MARKERS" = "$SECTIONS" ] || fail "assembled rules.md has $MARKERS section markers, expected $SECTIONS"
bash "$ROOT/bin/rules-check.sh" "$WORK/checkout/.ai-core/rules/rules.md" > /dev/null || fail "rules-check on the assembled rules.md"
echo "  $SECTIONS sections assembled"

section "second run creates nothing"
bash "$ROOT/bin/init.sh" "$WORK/checkout" --no-doctor > "$WORK/checkout-2.log" 2>&1 || fail "init.sh second run"
grep -aqE '^  (created|refreshed|removed) ' "$WORK/checkout-2.log" && fail "init.sh is not idempotent: $(grep -aE '^  (created|refreshed|removed) ' "$WORK/checkout-2.log")"
grep -aq '^  unchanged  [1-9][0-9]* file(s)$' "$WORK/checkout-2.log" || fail "init.sh second run did not report the unchanged files"
(cd "$WORK/checkout" && find . -type f | sort) | diff - "$WORK/checkout.list" > /dev/null || fail "init.sh changed the file set on re-run"

section "session-start in the target"
[ ! -e "$WORK/checkout/.ai-core/bin" ] || fail "init.sh copied scripts into the checkout"
(cd "$WORK/checkout" && "$ROOT/bin/ai-core" session-start > /dev/null) || fail "ai-core session-start in the target"
(cd "$WORK/checkout" && "$ROOT/bin/ai-core" session-start --json > "$WORK/checkout.json")
jq -e --arg version "$(tr -d '\r\n' < "$ROOT/VERSION")" '.harness_version == $version' "$WORK/checkout.json" > /dev/null || fail "session-start harness_version is not the repository VERSION"
jq -e '.harness_source == null and .source_ready == null and .rule_sources == [] and .harness_current == true and .rules_present == true and .refused == false' "$WORK/checkout.json" > /dev/null || fail "session-start of a product checkout reports source facts or no assembled rules"
# --tool <one tool>, the form the hooks use: the modes of that tool are switched on at the end of the output, a skill whole with its level; a row at level - is not switched on; the rules are not printed
MH="$WORK/modes-home"; mkdir -p "$MH/.claude/skills/caveman" "$MH/.claude/skills/archify"; : > "$MH/.claude/.i-have-adhd-always"
printf -- '---\nname: caveman\n---\nCAVEMAN RULES: short.\n' > "$MH/.claude/skills/caveman/SKILL.md"
printf -- '---\nname: archify\n---\nARCHIFY BODY.\n' > "$MH/.claude/skills/archify/SKILL.md"
printf 'claude\tcaveman\tlite\tskill:caveman\t-\t-\nclaude\tarchify\t-\tskill:archify\t-\t-\nclaude\tponytail\tfull\talways:ponytail\t-\t-\nclaude\ti-have-adhd\ton\tfile:~/.claude/.i-have-adhd-always\t-\t-\n' > "$WORK/modes.tsv"
(cd "$WORK/checkout" && HOME="$MH" TEAM_MODES_FILE="$WORK/modes.tsv" bash "$ROOT/bin/session-start.sh" --tool claude > "$WORK/modes.log" 2>&1) || fail "session-start.sh --tool claude (see $WORK/modes.log)"
grep -aq '^CAVEMAN MODE ACTIVE — level: lite' "$WORK/modes.log" && grep -aq '^CAVEMAN RULES: short\.' "$WORK/modes.log" && grep -aq '^ARGUMENTS: lite' "$WORK/modes.log" || fail "session-start.sh --tool claude does not switch the caveman skill on (see $WORK/modes.log)"
grep -aq '^name: caveman' "$WORK/modes.log" && fail "session-start.sh prints the front matter of the skill"
grep -aq '^PONYTAIL MODE: full, switched on by its own hook' "$WORK/modes.log" && grep -aq '^I-HAVE-ADHD MODE: on, switched on by its own hook' "$WORK/modes.log" || fail "session-start.sh --tool claude does not name the plugin modes (see $WORK/modes.log)"
grep -aq 'ARCHIFY' "$WORK/modes.log" && fail "session-start.sh --tool claude switched on a skill at level - (see $WORK/modes.log)"
grep -aqE 'THE RULES OF THIS CHECKOUT|^## The code never lies' "$WORK/modes.log" && fail "session-start.sh --tool claude prints the rules; Claude Code loads them through AGENTS.md"
[ "$(wc -c < "$WORK/modes.log")" -le 9500 ] || fail "session-start.sh --tool claude wrote more than 9 500 bytes, more than Claude Code passes whole"
# ai-core not on the PATH of the session, whatever the PATH of this shell: session-start says how to
# call it; on the PATH, it says nothing of it
AI_CORE_CMD="$ROOT/bin/ai-core"
OFF_PATH="$(while IFS= read -r d; do [ -z "$d" ] || [ -e "$d/ai-core" ] || printf '%s:' "$d"; done <<< "$(tr ':' '\n' <<< "$PATH")")"
(cd "$WORK/checkout" && PATH="$OFF_PATH" bash "$ROOT/bin/session-start.sh" > "$WORK/offpath.log" 2>&1)
grep -aqF "ai-core on PATH  : ✗ not in this session; call it as \"$AI_CORE_CMD\"" "$WORK/offpath.log" || fail "session-start.sh does not say that ai-core is missing from the PATH, and how to call it: $(grep -a 'ai-core on PATH\|Harness version' "$WORK/offpath.log")"
(cd "$WORK/checkout" && PATH="$ROOT/bin:$PATH" bash "$ROOT/bin/session-start.sh" > "$WORK/onpath.log" 2>&1)
grep -aq 'Harness version' "$WORK/onpath.log" && ! grep -aq 'ai-core on PATH' "$WORK/onpath.log" || fail "session-start.sh warns about the PATH although ai-core is on it, or did not run (see $WORK/onpath.log)"
# A skill too long for what Claude Code passes whole is named with the call that loads it, and the output stays below the limit
MB="$WORK/modes-home-big"; mkdir -p "$MB/.claude/skills/caveman" "$MB/.claude/skills/archify"; : > "$MB/.claude/.i-have-adhd-always"
cp "$MH/.claude/skills/archify/SKILL.md" "$MB/.claude/skills/archify/SKILL.md"
{ printf -- '---\nname: caveman\n---\n'; for i in $(seq 1 240); do printf 'CAVEMAN LONG RULE %03d: keep the answer short and the substance whole.\n' "$i"; done; } > "$MB/.claude/skills/caveman/SKILL.md"
(cd "$WORK/checkout" && HOME="$MB" TEAM_MODES_FILE="$WORK/modes.tsv" bash "$ROOT/bin/session-start.sh" --tool claude > "$WORK/modes-big.log" 2>&1) || fail "session-start.sh --tool claude with a long skill (see $WORK/modes-big.log)"
grep -aq '^CAVEMAN MODE ACTIVE — level: lite: its skill is too long for this output; load it before your first answer, the skill `caveman` with the argument `lite`$' "$WORK/modes-big.log" || fail "session-start.sh does not name a skill too long with the call that loads it (see $WORK/modes-big.log)"
grep -aq 'CAVEMAN LONG RULE' "$WORK/modes-big.log" && fail "session-start.sh printed a skill too long for the hook's output"
[ "$(wc -c < "$WORK/modes-big.log")" -le 9500 ] || fail "session-start.sh with a long skill wrote more than 9 500 bytes"
(cd "$WORK/checkout" && HOME="$MH" TEAM_MODES_FILE="$WORK/modes.tsv" bash "$ROOT/bin/session-start.sh" --tool claude --json | jq -e '.repository' > /dev/null) || fail "session-start.sh --tool claude --json is not JSON"
# A refusal under --json is JSON too: refused, with the lines of the team modes; a session that starts says refused: false
ME="$WORK/modes-home-empty"; mkdir -p "$ME/.claude"
(cd "$WORK/checkout" && HOME="$ME" TEAM_MODES_FILE="$WORK/modes.tsv" bash "$ROOT/bin/session-start.sh" --tool claude --json > "$WORK/refused.json" 2>/dev/null) && fail "session-start.sh --json exited 0 with the team modes missing"
jq -e '.refused == true and (.team_modes | any(startswith("MISSING")) and any(startswith("REFUSED")))' "$WORK/refused.json" > /dev/null || fail "session-start.sh --json does not refuse as JSON: $(tr -d '\r\n' < "$WORK/refused.json" | cut -c1-300)"
jq -e '.refused == false' "$WORK/checkout.json" > /dev/null || fail "session-start.sh --json does not say refused: false where the session starts"
(cd "$WORK/checkout" && HOME="$MH" TEAM_MODES_FILE="$WORK/modes.tsv" bash "$ROOT/bin/session-start.sh" > "$WORK/modes-none.log" 2>&1) || fail "session-start.sh without --tool (see $WORK/modes-none.log)"
grep -aq 'MODE ACTIVE' "$WORK/modes-none.log" && fail "session-start.sh without --tool switches modes on"
echo "  --tool claude: the caveman skill printed whole with its level, a skill at level - not switched on, a skill too long named with its call, the plugin modes named, no rules, at most 9 500 bytes, nothing of it in the JSON or without --tool, a refusal under --json as JSON"

# The hook names ai-core by its full path, so a Claude Code started from a terminal without it on the PATH still runs it
[ "$(jq -r '[.hooks.SessionStart[].hooks[].command] | join("|")' "$WORK/checkout/.claude/settings.json")" = "\"$AI_CORE_CMD\" session-start --tool claude" ] || fail "the settings.json init.sh deployed does not start the session with ai-core by its full path: $(jq -c '.hooks.SessionStart' "$WORK/checkout/.claude/settings.json")"
[ "$(jq -r '[.hooks.PermissionRequest[].hooks[].command] | join("|")' "$WORK/checkout/.claude/settings.json")" = "\"$AI_CORE_CMD\" permission-request" ] || fail "the settings.json init.sh deployed does not answer a permission prompt through ai-core permission-request by its full path: $(jq -c '.hooks.PermissionRequest' "$WORK/checkout/.claude/settings.json")"
# OpenCode reads the nearest AGENTS.md and resolves no @ in it: opencode.json names the rules as its instructions
jq -e '(.instructions | index(".ai-core/rules/rules.md") != null and index(".ai-core/rules/skills.md") != null and index(".ai-core/rules/rules.local.md") != null)' "$WORK/checkout/opencode.json" > /dev/null || fail "init.sh did not lay an opencode.json with the rules: $(tr -d '\n' < "$WORK/checkout/opencode.json" 2>/dev/null)"
jq -e --slurpfile t "$ROOT/templates/.claude/settings.json" '(.permissions.deny == $t[0].permissions.deny) and (.permissions.deny | index("Read(**/.env)") != null) and (.permissions.deny | index("Bash(git push --force:*)") != null)' "$WORK/checkout/.claude/settings.json" > /dev/null || fail "the settings.json init.sh deployed lacks the denials of the template: $(jq -c '.permissions.deny' "$WORK/checkout/.claude/settings.json")"
jq -e '(.permissions.allow | index("Bash(ai-core:*)")) != null' "$WORK/checkout/.claude/settings.json" > /dev/null || fail "the settings.json deployed by init.sh does not allow the ai-core commands"
[ "$(jq -r '.statusLine.command' "$WORK/checkout/.claude/settings.json")" = "\"$AI_CORE_CMD\" statusline" ] || fail "the settings.json init.sh deployed does not record the usage windows through ai-core statusline by its full path: $(jq -c '.statusLine' "$WORK/checkout/.claude/settings.json")"

# A repository with a CLAUDE.md of its own: Claude Code reads that and not AGENTS.md, so init writes an untracked CLAUDE.local.md that imports AGENTS.md; somebody's own CLAUDE.local.md is left alone, with a note
C="$WORK/claude"; git init -q "$C"; mkdir -p "$C/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$C/.ai-core/config.env"
printf '# The project\n' > "$C/CLAUDE.md"; git -C "$C" add CLAUDE.md; git -C "$C" commit -q -m 'its own CLAUDE.md #1'
for run in 1 2; do
  [ "$run" = 1 ] || printf 'mine\n' > "$C/CLAUDE.local.md"
  bash "$ROOT/bin/init.sh" "$C" --no-doctor > "$WORK/claude-$run.log" 2>&1 || fail "init.sh in a repository with its own CLAUDE.md (see $WORK/claude-$run.log)"
  [ "$run" = 2 ] || [ "$(tail -n1 "$C/CLAUDE.local.md")" = '@AGENTS.md' ] || fail "init.sh did not write a CLAUDE.local.md that imports AGENTS.md"
  [ -z "$(git -C "$C" status --porcelain CLAUDE.local.md)" ] || fail "init.sh left CLAUDE.local.md visible to git"
done
[ "$(cat "$C/CLAUDE.local.md")" = mine ] && grep -aq 'note: CLAUDE.local.md is yours and does not import AGENTS.md' "$WORK/claude-2.log" || fail "init.sh overwrote somebody's own CLAUDE.local.md or did not say what to add (see $WORK/claude-2.log)"
[ ! -e "$WORK/checkout/CLAUDE.local.md" ] || fail "init.sh wrote CLAUDE.local.md into a checkout without a CLAUDE.md"
echo "  a repository with its own CLAUDE.md gets an untracked CLAUDE.local.md that imports AGENTS.md; somebody's own is kept, with a note"

section "the model table follows the harness: an older copy in a checkout is brought up to date and reported"
M="$WORK/models"; mkdir -p "$M/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$M/.ai-core/config.env"
printf 'claude\tplan\thigh-risk\tclaude-fable-5-1\tmax\n' > "$M/.ai-core/models.tsv"
bash "$ROOT/bin/init.sh" "$M" --no-doctor > "$M.log" 2>&1 || fail "init.sh on a checkout with an older model table (see $M.log)"
cmp -s "$M/.ai-core/models.tsv" "$ROOT/templates/.ai-core/models.tsv" || fail "init.sh kept an older model table instead of the harness's"
grep -aq '^  refreshed .*\.ai-core/models\.tsv' "$M.log" || fail "init.sh did not report the model table as refreshed: $(grep -a 'models' "$M.log")"
echo "  an older .ai-core/models.tsv is replaced by the harness's and reported"

section "the model table keeps agy to high effort, keeps high-risk off agy and never reviews on the build model"
# Prints one line per broken row of the table in $1, nothing for a table that holds.
model_table_faults() {
  awk -F'\t' '
    /^#/ || NF < 5 { next }
    { base = $4; sub(/^agy:/, "", base); sub(/-(low|medium|high|xhigh|max)$/, "", base) }
    $4 ~ /^agy:/ && ($4 !~ /-high$/ || $5 != "-") { print "agy below or above high: " $0 }
    ($1 == "agy" || $4 ~ /^agy:/) && ($3 == "high-risk" || ($4 ~ /^agy:/ && $3 == "*")) { print "high-risk on agy: " $0 }
    ($1 == "agy" || $4 ~ /^agy:/) && $4 ~ /gemini/ { print "gemini on agy: " $0 }
    $2 == "build" { build[$1, $3] = base }
    $2 == "review" { review[$1, $3] = base }
    END { for (k in build) if ((k in review) && build[k] == review[k]) { split(k, a, SUBSEP); print "review on the build model: " a[1] " " a[2] } }
  ' "$1"
}
[ -z "$(model_table_faults "$ROOT/templates/.ai-core/models.tsv")" ] || fail "the harness's model table breaks its own rules: $(model_table_faults "$ROOT/templates/.ai-core/models.tsv")"
T="$WORK/model-faults.tsv"
printf 'claude\tbuild\tnormal-hard\tagy:claude-sonnet-5-5-high\t-\nclaude\treview\tnormal-hard\tclaude-opus-5-5\txhigh\n' > "$T"
[ -z "$(model_table_faults "$T")" ] || fail "an agy build reviewed by Claude Opus was reported: $(model_table_faults "$T")"
for planted in 'claude\tbuild\tmechanical\tagy:claude-sonnet-5-5-high\txhigh' \
               'claude\tplan-check\tmechanical\tagy:claude-sonnet-5-5-medium\t-' \
               'claude\tbuild\thigh-risk\tagy:claude-opus-5-5-high\t-' \
               'agy\tplan\thigh-risk\tclaude-opus-5-5-high\t-' \
               'claude\thelper\t*\tagy:claude-sonnet-5-5-high\t-' \
               'agy\thelper\t*\tgemini-3.8-flash-medium\t-' \
               'agy\treview\tnormal-hard\tclaude-sonnet-5-5-high\t-\nagy\tbuild\tnormal-hard\tclaude-sonnet-5-5-high\t-'; do
  printf "$planted\n" > "$T"
  [ -n "$(model_table_faults "$T")" ] || fail "a planted broken row stayed green: $(printf "$planted")"
done
printf 'claude\tbuild\tmechanical\tagy:claude-sonnet-5-5-high\t-\nclaude\treview\tmechanical\tclaude-sonnet-5-5\thigh\n' > "$T"
[ -n "$(model_table_faults "$T")" ] || fail "a Claude Sonnet review of an agy Sonnet build stayed green"
echo "  agy rows run at high only, high-risk stays off agy, no agy row names Gemini, and no review runs on its build model"

section "Codex gets what Claude Code loads, written out in AGENTS.override.md, and its config reads it whole"
codex_init() {  # codex_init <dir>
  CODEX_HOME="$CODEX_HOME-folder" bash "$ROOT/bin/init.sh" "$1" --no-doctor >> "$F.log" 2>&1 || fail "init.sh in $1 (see $F.log)"
}
F="$WORK/codex-folder"; mkdir -p "$F/.ai-core" "$F/repo" "$CODEX_HOME-folder"
printf 'UPDATE_CHECK="never"\n' > "$F/.ai-core/config.env"; git -C "$F/repo" init -q
printf 'model = "m"\nproject_doc_max_bytes = 1000\n\n[profiles.p]\nproject_doc_max_bytes = 5\n' > "$CODEX_HOME-folder/config.toml"
printf "[auto_review]\npolicy = '''\nAllow:\n- [other-ai-core] Kept from another project.\n- [setup-ai-core] Stale.\n\nEnvironment:\n- [other-ai-core] Another fact.\n'''\n" > "$CODEX_HOME-folder/ai-core.config.toml"
codex_init "$F"
printf '\n- **The folder rule.** Planted by the check. [discipline]\n' >> "$F/.ai-core/rules/rules.local.md"
codex_init "$F"; codex_init "$F/repo"
O="$F/repo/AGENTS.override.md"
[ -f "$O" ] || fail "init.sh wrote no AGENTS.override.md in a checkout that serves Codex"
grep -q '^<!-- \.ai-core/rules/rules\.md, written out -->$' "$O" && grep -q '^<!-- \.ai-core/rules/skills\.md, written out -->$' "$O" || fail "init.sh: the checkout's override does not write out rules.md and skills.md"
grep -q '^## The code never lies to the person using it$' "$O" || fail "init.sh: the checkout's override lacks the text of rules.md"
grep -q 'The folder rule\.' "$O" || fail "init.sh: the checkout's override lacks the project folder's local rules"
grep -qxF '/AGENTS.override.md' "$F/repo/.git/info/exclude" || fail "init.sh did not keep AGENTS.override.md out of git"
[ -z "$(git -C "$F/repo" status --porcelain)" ] || fail "init.sh left the checkout dirty: $(git -C "$F/repo" status --porcelain | tr '\n' '|')"
[ "$(cat "$CODEX_HOME-folder/config.toml")" = "$(printf 'model = "m"\nproject_doc_max_bytes = 262144\n\n[profiles.p]\nproject_doc_max_bytes = 5')" ] || fail "init.sh wrote Codex's config wrong: $(tr '\n' '|' < "$CODEX_HOME-folder/config.toml")"
grep -aqF "  codex: project_doc_max_bytes set to 262144 in $CODEX_HOME-folder/config.toml" "$F.log" || fail "init.sh did not say it raised project_doc_max_bytes"
P="$CODEX_HOME-folder/ai-core.config.toml"
grep -qxF 'approvals_reviewer = "auto_review"' "$P" && grep -qxF 'network_access = false' "$P" || fail "init.sh wrote no Codex profile ai-core that closes the network and hands approvals to the reviewer"
grep -qF -- "- [setup-ai-core] $(grep -m1 '^allow' "$ROOT/auto-mode.tsv" | cut -f2)" "$P" || fail "init.sh: the profile ai-core lacks the auto-mode entries"
grep -aqF "the profile ai-core written to $P" "$F.log" || fail "init.sh did not say it wrote the profile ai-core"
grep -qxF -- '- [other-ai-core] Kept from another project.' "$P" && grep -qxF -- '- [other-ai-core] Another fact.' "$P" || fail "init.sh dropped another project's entries from the profile ai-core"
! grep -qxF -- '- [setup-ai-core] Stale.' "$P" || fail "init.sh kept a stale entry of its own layer in the profile ai-core"
R="$CODEX_HOME-folder/rules/ai-core.rules"
grep -qxF 'prefix_rule(pattern = ["ai-core"], decision = "allow")' "$R" || fail "init.sh did not allow ai-core in Codex's command rules"
grep -qxF 'prefix_rule(pattern = ["git", "push", "--force"], decision = "forbidden")' "$R" && ! grep -q '"--force"\], decision = "allow"' "$R" || fail "init.sh did not forbid what the template denies in Codex's command rules"
grep -aqF "the command rules written to $R" "$F.log" || fail "init.sh did not say it wrote the command rules"
# init.sh reads the template with jq; without it, init still runs and says it wrote no command rules
J="$WORK/no-jq-bin"; mkdir -p "$J"
IFS=: read -ra path_dirs <<< "$PATH"
for d in "${path_dirs[@]}"; do for f in "$d"/*; do
  n="${f##*/}"; [ -x "$f" ] && [ "$n" != jq ] && [ ! -e "$J/$n" ] && ln -s "$f" "$J/$n"
done; done 2>/dev/null
N="$WORK/codex-no-jq"; mkdir -p "$N/.ai-core" "$CODEX_HOME-no-jq"; printf 'UPDATE_CHECK="never"\n' > "$N/.ai-core/config.env"
PATH="$J" CODEX_HOME="$CODEX_HOME-no-jq" bash "$ROOT/bin/init.sh" "$N" --no-doctor > "$N.log" 2>&1 || fail "init.sh without jq failed where Codex is served: $(tail -2 "$N.log" | tr '\n' '|')"
[ ! -e "$CODEX_HOME-no-jq/rules" ] && grep -aq 'no command rules written: jq is missing' "$N.log" || fail "init.sh without jq did not say it wrote no command rules"
N="$WORK/codex-none"; mkdir -p "$N/.ai-core"; printf 'UPDATE_CHECK="never"\nAGENTS="claude"\n' > "$N/.ai-core/config.env"
X="$CODEX_HOME-none"; mkdir -p "$X"; printf 'project_doc_max_bytes = 999999\n' > "$X/config.toml"
CODEX_HOME="$X" bash "$ROOT/bin/init.sh" "$N" --no-doctor > "$N.log" 2>&1
[ ! -e "$N/AGENTS.override.md" ] && [ ! -e "$X/ai-core.config.toml" ] && [ ! -e "$X/rules" ] || fail "init.sh wrote AGENTS.override.md, the Codex profile or its command rules where Codex is not served"
[ "$(cat "$X/config.toml")" = 'project_doc_max_bytes = 999999' ] || fail "init.sh changed Codex's config where Codex is not served"
K="$WORK/codex-kept"; mkdir -p "$K/.ai-core" "$CODEX_HOME-kept"; printf 'UPDATE_CHECK="never"\n' > "$K/.ai-core/config.env"
git -C "$K" init -q; printf 'our own\n' > "$K/AGENTS.override.md"; git -C "$K" add AGENTS.override.md; git -C "$K" commit -q -m own
printf 'project_doc_max_bytes = 1_000_000\n' > "$CODEX_HOME-kept/config.toml"
CODEX_HOME="$CODEX_HOME-kept" bash "$ROOT/bin/init.sh" "$K" --no-doctor > "$K.log" 2>&1
[ "$(cat "$K/AGENTS.override.md")" = 'our own' ] || fail "init.sh overwrote an AGENTS.override.md the repository tracks"
[ "$(cat "$CODEX_HOME-kept/config.toml")" = 'project_doc_max_bytes = 1_000_000' ] || fail "init.sh lowered project_doc_max_bytes written with underscores"
echo "  a checkout in a project folder gets the folder's and its own AGENTS.md with rules.md, skills.md and the folder's local rules written out and kept out of git; Codex's config is raised before its first table, a table's key and a higher value stay, underscores read; an override the repository tracks is kept; the profile ai-core closes the network and gives the reviewer the auto-mode entries, another project's kept; nothing where Codex is not served"

exit 0
