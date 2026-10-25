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
for c in before mine tracked binary; do
  C="$WORK/agentsmd-$c"; mkdir -p "$C/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$C/.ai-core/config.env"; git init -q "$C"
  case "$c" in
    before) printf '# AGENTS.md \342\200\224 Repository Navigation & Operations\n\nthe generic file of before 1.3.20\n' > "$C/AGENTS.md" ;;
    mine) printf '# mine\n' > "$C/AGENTS.md" ;;
    binary) printf '<!-- ai-core ma\000p: mine -->\n' > "$C/AGENTS.md"; cp "$C/AGENTS.md" "$WORK/agentsmd-binary.want" ;;
    tracked) printf '# tracked\n' > "$C/AGENTS.md"; git -C "$C" add AGENTS.md; git -C "$C" commit -q -m tracked ;;
  esac
  bash "$ROOT/bin/init.sh" "$C" --no-doctor > "$C.log" 2>&1 || fail "init.sh with an AGENTS.md $c (see $C.log)"
  case "$c" in
    before) grep -q '^<!-- ai-core map: none yet' <<< "$(head -n1 "$C/AGENTS.md")" || fail "init.sh kept the generic AGENTS.md of before" ;;
    binary) cmp -s "$C/AGENTS.md" "$WORK/agentsmd-binary.want" || fail "init.sh overwrote an AGENTS.md with a NUL in its header" ;;
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
# The team modes come from a scratch home with a stand-in skill, so the line passes on every machine and refuses where the skill is missing
MH="$WORK/modes-home"; mkdir -p "$MH/.claude/skills/archify"
printf -- '---\nname: archify\n---\nARCHIFY BODY.\n' > "$MH/.claude/skills/archify/SKILL.md"
printf 'claude\tarchify\tskill:archify\t-\t-\n' > "$WORK/modes.tsv"
(cd "$WORK/checkout" && HOME="$MH" TEAM_MODES_FILE="$WORK/modes.tsv" "$ROOT/bin/ai-core" session-start > /dev/null) || fail "ai-core session-start in the target"
(cd "$WORK/checkout" && HOME="$MH" TEAM_MODES_FILE="$WORK/modes.tsv" "$ROOT/bin/ai-core" session-start --json > "$WORK/checkout.json")
jq -e --arg version "$(tr -d '\r\n' < "$ROOT/VERSION")" '.harness_version == $version' "$WORK/checkout.json" > /dev/null || fail "session-start harness_version is not the repository VERSION"
jq -e '.harness_source == null and .source_ready == null and .rule_sources == [] and .harness_current == true and .rules_present == true and .refused == false' "$WORK/checkout.json" > /dev/null || fail "session-start of a product checkout reports source facts or no assembled rules"
# --tool <one tool>, the form the hooks use: no skill and no rules are printed, so the output stays below what Claude Code passes whole
(cd "$WORK/checkout" && HOME="$MH" TEAM_MODES_FILE="$WORK/modes.tsv" bash "$ROOT/bin/session-start.sh" --tool claude > "$WORK/modes.log" 2>&1) || fail "session-start.sh --tool claude (see $WORK/modes.log)"
grep -aq 'ARCHIFY' "$WORK/modes.log" && fail "session-start.sh --tool claude printed a skill; the tool loads it when a task calls for it (see $WORK/modes.log)"
grep -aqE 'THE RULES OF THIS CHECKOUT|^## The code never lies' "$WORK/modes.log" && fail "session-start.sh --tool claude prints the rules; Claude Code loads them through AGENTS.md"
[ "$(wc -c < "$WORK/modes.log")" -le 9500 ] || fail "session-start.sh --tool claude wrote more than 9 500 bytes, more than Claude Code passes whole"
# After a compaction the hook's event says so on standard input, and the report names every rules file
# to read again; at a start it does not
(cd "$WORK/checkout" && printf '{"hook_event_name":"SessionStart","source":"compact"}' | HOME="$MH" TEAM_MODES_FILE="$WORK/modes.tsv" bash "$ROOT/bin/session-start.sh" --tool claude > "$WORK/compact.log" 2>&1) || fail "session-start.sh --tool claude after a compaction (see $WORK/compact.log)"
grep -aq '^After compaction: read every rules file whole again now' "$WORK/compact.log" || fail "session-start after a compaction does not ask for the rules again (see $WORK/compact.log)"
grep -aqx "  $WORK/checkout/.ai-core/rules/rules.md" "$WORK/compact.log" || fail "session-start after a compaction does not name the assembled rules file (see $WORK/compact.log)"
(cd "$WORK/checkout" && printf '{"hook_event_name":"SessionStart","source":"startup"}' | HOME="$MH" TEAM_MODES_FILE="$WORK/modes.tsv" bash "$ROOT/bin/session-start.sh" --tool claude > "$WORK/startup.log" 2>&1) || fail "session-start.sh --tool claude at a start (see $WORK/startup.log)"
grep -aq '^After compaction' "$WORK/startup.log" && fail "session-start at a start asks for the rules again, as after a compaction (see $WORK/startup.log)"
# ai-core not on the PATH of the session, whatever the PATH of this shell: session-start says how to
# call it; on the PATH, it says nothing of it
AI_CORE_CMD="$ROOT/bin/ai-core"
OFF_PATH="$(while IFS= read -r d; do [ -z "$d" ] || [ -e "$d/ai-core" ] || printf '%s:' "$d"; done <<< "$(tr ':' '\n' <<< "$PATH")")"
(cd "$WORK/checkout" && HOME="$MH" TEAM_MODES_FILE="$WORK/modes.tsv" PATH="$OFF_PATH" bash "$ROOT/bin/session-start.sh" > "$WORK/offpath.log" 2>&1)
grep -aqF "ai-core on PATH  : ✗ not in this session; call it as \"$AI_CORE_CMD\"" "$WORK/offpath.log" || fail "session-start.sh does not say that ai-core is missing from the PATH, and how to call it: $(grep -a 'ai-core on PATH\|Harness version' "$WORK/offpath.log")"
(cd "$WORK/checkout" && HOME="$MH" TEAM_MODES_FILE="$WORK/modes.tsv" PATH="$ROOT/bin:$PATH" bash "$ROOT/bin/session-start.sh" > "$WORK/onpath.log" 2>&1)
grep -aq 'Harness version' "$WORK/onpath.log" && ! grep -aq 'ai-core on PATH' "$WORK/onpath.log" || fail "session-start.sh warns about the PATH although ai-core is on it, or did not run (see $WORK/onpath.log)"
(cd "$WORK/checkout" && HOME="$MH" TEAM_MODES_FILE="$WORK/modes.tsv" bash "$ROOT/bin/session-start.sh" --tool claude --json | jq -e '.repository' > /dev/null) || fail "session-start.sh --tool claude --json is not JSON"
# A refusal under --json is JSON too: refused, with the lines of the team modes; a session that starts says refused: false
ME="$WORK/modes-home-empty"; mkdir -p "$ME/.claude"
(cd "$WORK/checkout" && HOME="$ME" TEAM_MODES_FILE="$WORK/modes.tsv" bash "$ROOT/bin/session-start.sh" --tool claude --json > "$WORK/refused.json" 2>/dev/null) && fail "session-start.sh --json exited 0 with the team modes missing"
jq -e '.refused == true and (.team_modes | any(startswith("MISSING")) and any(startswith("REFUSED")))' "$WORK/refused.json" > /dev/null || fail "session-start.sh --json does not refuse as JSON: $(tr -d '\r\n' < "$WORK/refused.json" | cut -c1-300)"
jq -e '.refused == false' "$WORK/checkout.json" > /dev/null || fail "session-start.sh --json does not say refused: false where the session starts"
echo "  --tool claude: no skill and no rules printed, at most 9 500 bytes, JSON under --json, a refusal under --json as JSON"

# The hook names ai-core by its full path, so a Claude Code started from a terminal without it on the PATH still runs it
[ "$(jq -r '[.hooks.SessionStart[].hooks[].command] | join("|")' "$WORK/checkout/.claude/settings.json")" = "\"$AI_CORE_CMD\" session-start --tool claude" ] || fail "the settings.json init.sh deployed does not start the session with ai-core by its full path: $(jq -c '.hooks.SessionStart' "$WORK/checkout/.claude/settings.json")"
[ "$(jq -r '[.hooks.PermissionRequest[].hooks[].command] | join("|")' "$WORK/checkout/.claude/settings.json")" = "\"$AI_CORE_CMD\" permission-request" ] || fail "the settings.json init.sh deployed does not answer a permission prompt through ai-core permission-request by its full path: $(jq -c '.hooks.PermissionRequest' "$WORK/checkout/.claude/settings.json")"
# OpenCode reads the nearest AGENTS.md and resolves no @ in it: opencode.json names the rules as its instructions
jq -e '(.instructions | index(".ai-core/rules/rules.md") != null and index(".ai-core/rules/skills.md") != null and index(".ai-core/rules/rules.local.md") != null)' "$WORK/checkout/opencode.json" > /dev/null || fail "init.sh did not lay an opencode.json with the rules: $(tr -d '\n' < "$WORK/checkout/opencode.json" 2>/dev/null)"
jq -e --slurpfile t "$ROOT/templates/.claude/settings.json" '(.permissions.deny == $t[0].permissions.deny) and (.permissions.deny | index("Read(**/.env)") != null) and (.permissions.deny | index("Bash(git push --force:*)") != null)' "$WORK/checkout/.claude/settings.json" > /dev/null || fail "the settings.json init.sh deployed lacks the denials of the template: $(jq -c '.permissions.deny' "$WORK/checkout/.claude/settings.json")"
# the secrets of a checkout (any *.env, *.pem, *.key, ~/.netrc) are neither read nor edited, git's hard cleanups are refused, and rm -rf stays allowed
for entry in 'Read(**/*.env)' 'Edit(**/*.env)' 'Read(!config.env)' 'Edit(!config.env)' 'Read(!*.example.env)' 'Edit(!*.example.env)' 'Read(**/*.pem)' 'Edit(**/*.pem)' 'Read(**/*.key)' 'Edit(**/*.key)' 'Read(~/.netrc)' 'Edit(~/.netrc)' 'Bash(git reset --hard:*)' 'Bash(git reset *--hard*)' 'Bash(git clean:*)'; do
  jq -e --arg e "$entry" '.permissions.deny | index($e) != null' "$WORK/checkout/.claude/settings.json" > /dev/null || fail "the settings.json init.sh deployed does not deny $entry"
done
# a ! entry carves out only of the rules listed before it: config.env, the harness's own file, and the files named
# *.example.env, the convention for a tracked template, stay readable (by name: such a file with real values is readable too)
for t in Read Edit; do
  for carve in config.env '*.example.env'; do
    jq -e --arg t "$t" --arg c "$carve" '.permissions.deny as $d | ($d | index($t + "(**/*.env)")) as $a | ($d | index($t + "(!" + $c + ")")) as $b | $a != null and $b != null and $b > $a' "$WORK/checkout/.claude/settings.json" > /dev/null || fail "the settings.json init.sh deployed does not list $t(!$carve) after $t(**/*.env)"
  done
done
# the innocent case: no other ! entry stands in the deployed file, whatever its spelling (!**/*.env, !/*.env and
# !./*.env each reopen a *.env that must stay denied), so a real secrets.env, a config.local.env and a .env stay under the deny
extra="$(jq -r '[.permissions.deny[] | select(test("^(Read|Edit)\\(!"))] - ["Read(!config.env)","Edit(!config.env)","Read(!*.example.env)","Edit(!*.example.env)"] | .[]' "$WORK/checkout/.claude/settings.json" | tr '\n' ' ')"
[ -z "$extra" ] || fail "the settings.json init.sh deployed carries ! entries beyond config.env and *.example.env, which reopen *.env files that must stay denied: $extra"
# the file for the claude -p runs from a throwaway folder: every denial of the template, **/ anchored at //, no ! entry
RUN_SETTINGS="${AI_CORE_HOME:-$HOME}/.ai-core/claude-run-settings.json"
jq -e --slurpfile t "$ROOT/templates/.claude/settings.json" '.permissions.deny as $d | [$t[0].permissions.deny[] | select(test("^[A-Za-z]+\\(!") | not) | sub("^(?<k>[A-Za-z]+)\\(\\*\\*/"; "\(.k)(//**/")] as $want | ($want - $d | length == 0) and ($d - $want | length == 0) and ($d | index("Read(//**/*.env)") != null) and ($d | index("Bash(git clean:*)") != null) and all($d[]; test("\\(!") | not)' "$RUN_SETTINGS" > /dev/null || fail "init.sh did not write the denials of the template, // anchored and without ! entries, to $RUN_SETTINGS: $(jq -c '.permissions.deny' "$RUN_SETTINGS" 2>&1)"
jq -e '[.permissions.deny[] | select(test("^Bash\\(rm( |:)"))] | length == 0' "$WORK/checkout/.claude/settings.json" > /dev/null || fail "the settings.json init.sh deployed denies rm: rm -rf of a temporary folder must stay allowed"
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
# A long CLAUDE.local.md of somebody's own: the import on its first line is read, and one without the import gets the note
for run in 3 4; do
  { [ "$run" = 4 ] || echo '@AGENTS.md'; for i in $(seq 1 20000); do printf 'line %s of the notes of somebody who writes a lot\n' "$i"; done; } > "$C/CLAUDE.local.md"
  bash "$ROOT/bin/init.sh" "$C" --no-doctor > "$WORK/claude-$run.log" 2>&1 || fail "init.sh with a long CLAUDE.local.md of somebody's own (see $WORK/claude-$run.log)"
done
! grep -aq 'note: CLAUDE.local.md is yours' "$WORK/claude-3.log" || fail "init.sh says that a long CLAUDE.local.md does not import AGENTS.md, though its first line does (see $WORK/claude-3.log)"
grep -aq 'note: CLAUDE.local.md is yours and does not import AGENTS.md' "$WORK/claude-4.log" || fail "init.sh did not say what to add to a long CLAUDE.local.md without the import (see $WORK/claude-4.log)"
[ ! -e "$WORK/checkout/CLAUDE.local.md" ] || fail "init.sh wrote CLAUDE.local.md into a checkout without a CLAUDE.md"
echo "  a repository with its own CLAUDE.md gets an untracked CLAUDE.local.md that imports AGENTS.md; somebody's own is kept, with a note"

section "the model table follows the harness: an older copy in a checkout is brought up to date and reported"
M="$WORK/models"; mkdir -p "$M/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$M/.ai-core/config.env"
printf 'claude\tplan\thigh-risk\tclaude-fable-5-1\tmax\n' > "$M/.ai-core/models.tsv"
bash "$ROOT/bin/init.sh" "$M" --no-doctor > "$M.log" 2>&1 || fail "init.sh on a checkout with an older model table (see $M.log)"
cmp -s "$M/.ai-core/models.tsv" "$ROOT/templates/.ai-core/models.tsv" || fail "init.sh kept an older model table instead of the harness's"
grep -aq '^  refreshed .*\.ai-core/models\.tsv' "$M.log" || fail "init.sh did not report the model table as refreshed: $(grep -a 'models' "$M.log")"
echo "  an older .ai-core/models.tsv is replaced by the harness's and reported"

section "the team-modes table follows the harness: an older copy in a checkout is brought up to date and reported"
TM="$WORK/team-modes"; mkdir -p "$TM/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$TM/.ai-core/config.env"
printf 'claude\tmode\ton\talways\t-\t-\n' > "$TM/.ai-core/team-modes.tsv"
bash "$ROOT/bin/init.sh" "$TM" --no-doctor > "$TM.log" 2>&1 || fail "init.sh on a checkout with an older team-modes table (see $TM.log)"
cmp -s "$TM/.ai-core/team-modes.tsv" "$ROOT/templates/.ai-core/team-modes.tsv" || fail "init.sh kept an older team-modes table instead of the harness's"
grep -aq '^  refreshed .*\.ai-core/team-modes\.tsv' "$TM.log" || fail "init.sh did not report the team-modes table as refreshed: $(grep -a 'team-modes' "$TM.log")"
echo "  an older .ai-core/team-modes.tsv is replaced by the harness's and reported"

section "the model table keeps agy to high effort, keeps high-risk off agy, never reviews on the build model, gives every plan its re-plan row and gives no mechanical package a plan check"
# Prints one line per broken row of the table in $1, nothing for a table that holds.
model_table_faults() {
  awk -F'\t' '
    /^#/ || NF < 5 { next }
    { base = $4; sub(/^(agy|codex):/, "", base); sub(/-(low|medium|high|xhigh|max)$/, "", base) }
    $4 ~ /^agy:/ && ($4 !~ /-high$/ || $5 != "-") { print "agy below or above high: " $0 }
    ($1 == "agy" || $4 ~ /^agy:/) && ($3 == "high-risk" || ($4 ~ /^agy:/ && $3 == "*")) { print "high-risk on agy: " $0 }
    ($1 == "agy" || $4 ~ /^agy:/) && $4 ~ /gemini/ { print "gemini on agy: " $0 }
    $2 == "build" { build[$1, $3] = base }
    $2 == "review" { review[$1, $3] = base }
    $2 == "plan-check" && $3 == "mechanical" { print "plan check of a mechanical package: " $0 }
    $2 == "plan" { plan[$1, $3] = 1 }
    $2 == "re-plan" { replan[$1, $3] = 1 }
    END {
      for (k in build) if ((k in review) && build[k] == review[k]) { split(k, a, SUBSEP); print "review on the build model: " a[1] " " a[2] }
      for (k in plan) if (!(k in replan)) { split(k, a, SUBSEP); print "plan without a re-plan row: " a[1] " " a[2] }
    }
  ' "$1"
  awk -F'\t' '
    /^#/ || NF < 5 { next }
    $1 == "codex" && $4 !~ /:/ { models[$4] = 1; efforts[$5] = 1; next }
    $4 ~ /^codex:/ { rows[++n] = $0; model[n] = substr($4, 7); effort[n] = $5 }
    END { for (i = 1; i <= n; i++) {
      if (!(model[i] in models)) print "unknown Codex model: " rows[i]
      if (effort[i] == "-" || !(effort[i] in efforts)) print "unsupported Codex effort: " rows[i]
    } }
  ' "$1"
}
[ -z "$(model_table_faults "$ROOT/templates/.ai-core/models.tsv")" ] || fail "the harness's model table breaks its own rules: $(model_table_faults "$ROOT/templates/.ai-core/models.tsv")"
T="$WORK/model-faults.tsv"
printf 'claude\tbuild\tnormal-hard\tagy:claude-sonnet-5-5-high\t-\nclaude\treview\tnormal-hard\tclaude-opus-5-5\txhigh\n' > "$T"
[ -z "$(model_table_faults "$T")" ] || fail "an agy build reviewed by Claude Opus was reported: $(model_table_faults "$T")"
for planted in 'claude\tbuild\tmechanical\tagy:claude-sonnet-5-5-high\txhigh' \
               'claude\tplan-check\tnormal-hard\tagy:claude-sonnet-5-5-medium\t-' \
               'claude\tbuild\thigh-risk\tagy:claude-opus-5-5-high\t-' \
               'agy\tplan\thigh-risk\tclaude-opus-5-5-high\t-\nagy\tre-plan\thigh-risk\tclaude-opus-5-5-high\t-' \
               'claude\thelper\t*\tagy:claude-sonnet-5-5-high\t-' \
               'agy\thelper\t*\tgemini-3.8-flash-medium\t-' \
               'agy\treview\tnormal-hard\tclaude-sonnet-5-5-high\t-\nagy\tbuild\tnormal-hard\tclaude-sonnet-5-5-high\t-' \
               'claude\tplan-check\tmechanical\tclaude-sonnet-5-5\thigh' \
               'claude\tplan\tnormal-hard\tclaude-fable-5-1\txhigh' \
               'claude\tplan\thigh-risk\tclaude-fable-5-1\txhigh\nclaude\tre-plan\tnormal-hard\tclaude-opus-5-5\tmax' \
               'claude\tplan\tnormal-hard\tclaude-fable-5-1\txhigh\nclaude\tre-plan\tnormal-hard\tclaude-opus-5-5\tmax\ncodex\tplan\tnormal-hard\tgpt-6-astra\txhigh'; do
  printf "$planted\n" > "$T"
  [ -n "$(model_table_faults "$T")" ] || fail "a planted broken row stayed green: $(printf "$planted")"
done
printf 'claude\tbuild\tmechanical\tagy:claude-sonnet-5-5-high\t-\nclaude\treview\tmechanical\tclaude-sonnet-5-5\thigh\n' > "$T"
[ -n "$(model_table_faults "$T")" ] || fail "a Claude Sonnet review of an agy Sonnet build stayed green"
printf 'claude\tplan\tnormal-hard\tclaude-fable-5-1\txhigh\nclaude\tre-plan\tnormal-hard\tclaude-opus-5-5\tmax\nagy\tplan\tnormal-hard\tclaude-opus-5-5-high\t-\nagy\tre-plan\tnormal-hard\tclaude-opus-5-5-high\t-\nclaude\tplan-check\tnormal-hard\tclaude-opus-5-5\thigh\n' > "$T"
[ -z "$(model_table_faults "$T")" ] || fail "plan rows that each have their re-plan row, and a plan check of a normal-hard package, were reported: $(model_table_faults "$T")"
native_codex() { awk -F'\t' '$1 == "codex" && $4 !~ /:/ && $0 !~ /^#/' "$ROOT/templates/.ai-core/models.tsv"; }
for planted in 'claude\tplan\thigh-risk\tcodex:not-a-model\tmax\nclaude\tre-plan\thigh-risk\tclaude-opus-5-5\tmax' 'claude\tplan\thigh-risk\tcodex:gpt-6-astra\t-\nclaude\tre-plan\thigh-risk\tclaude-opus-5-5\tmax' 'claude\tbuild\thigh-risk\tcodex:gpt-6-astra\tmax\nclaude\treview\thigh-risk\tgpt-6-astra\tmax'; do
  { native_codex; printf '%b\n' "$planted"; } > "$T"
  [ -n "$(model_table_faults "$T")" ] || fail "a planted Codex routing fault stayed green: $(printf '%b' "$planted")"
done
{ native_codex; printf 'claude\tplan\thigh-risk\tcodex:gpt-6-astra\tmax\nclaude\tre-plan\thigh-risk\tclaude-opus-5-5\tmax\n'; } > "$T"
[ -z "$(model_table_faults "$T")" ] || fail "a native Codex model at max was refused: $(model_table_faults "$T")"
echo "  agy rows run at high only, high-risk stays off agy, no agy row names Gemini, no review runs on its build model, every plan row has its re-plan row, and no mechanical package has a plan check"

section "the four points of a mechanical package read the same in the table header and in every skill text that states them"
mechanical_points='the change stays in one repository; it touches no contract between the project'"'"'s repositories and no contract outward; it touches no secret, no payment and not the push gate; the change of all its issues together is at most 150 lines outside tests, and each issue has its acceptance criteria'
# A file states the points when its text, with line breaks and comment marks read as one space, holds them whole.
states_mechanical_points() { tr '\n' ' ' < "$1" | sed -E 's/ # +/ /g' | tr -s ' ' | grep -qF -- "$mechanical_points"; }
P="$WORK/mechanical-points.txt"
printf '# class   mechanical (%s\n' "${mechanical_points/; it touches no secret/;$'\n'#         it touches no secret}" > "$P"
states_mechanical_points "$P" || fail "the four points, wrapped over two comment lines, were not found"
printf '# class   mechanical (%s\n' "${mechanical_points/no secret/no secrets}" > "$P"
! states_mechanical_points "$P" || fail "the four points with one word changed were accepted"
for file in templates/.ai-core/models.tsv skills/person-in-charge/SKILL.md skills/person-in-charge/briefs/plan.md; do
  states_mechanical_points "$ROOT/$file" || fail "$file does not state the four points of a mechanical package in the words of the other places"
done
echo "  the table header, SKILL.md and briefs/plan.md each hold the four points word for word; a changed word is refused"

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
for c in '"git", "reset", "--hard"' '"git", "clean"'; do grep -qxF "prefix_rule(pattern = [$c], decision = \"forbidden\")" "$R" || fail "init.sh did not forbid [$c] in Codex's command rules"; done
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

section "Antigravity gets the same text as always_on rules in .agents/rules/, each part at most its cut"
agy_init() {  # agy_init <dir> [flag]: init with a log of its own, for what this run alone said
  CODEX_HOME="$CODEX_HOME-folder" bash "$ROOT/bin/init.sh" "$1" --no-doctor ${2:+"$2"} > "$WORK/agy.log" 2>&1 || fail "init.sh in $1 (see $WORK/agy.log)"
}
ours_head() { printf -- '---\ntrigger: always_on\ndescription: the binding rules setup-ai-core 0 wrote out for this folder, part %s\n---\n' "$1"; }
our_parts() {  # the parts init wrote, by the writer their description names
  for p in "$A"/ai-core-[0-9][0-9].md; do
    if head -n 3 "$p" | grep -q '^description: the binding rules setup-ai-core '; then echo "$p"; fi
  done
}
parts_fit() {  # every part opens with agy's frontmatter and holds at most 24,000 bytes, and the cut was made
  set -- $(our_parts)
  [ "$#" -ge 2 ] || fail "init.sh wrote $# part(s) for a text of $(wc -c < "$O") bytes, so the cut was never made"
  for p in "$@"; do
    [ "$(head -n 2 "$p")" = "$(printf -- '---\ntrigger: always_on')" ] || fail "init.sh: $p does not open with the frontmatter agy needs"
    [ "$(wc -c < "$p")" -le 24000 ] || fail "init.sh: $p has $(wc -c < "$p") bytes, past the 24,000 agy reads"
  done
}
parts_hold() {  # parts_hold <how> <filter>: the bodies of the parts against the text Codex gets, both through <filter>
  # the x keeps the trailing line breaks, which $( ) would drop
  [ "$(for p in $(our_parts); do tail -n +5 "$p"; done | $2; echo x)" = "$(tail -n +2 "$O" | $2; echo x)" ] || fail "init.sh: the parts do not hold the text Codex gets, $1"
}
A="$F/repo/.agents/rules"
ours_head 9 > "$A/ai-core-09.md"; printf 'the project uses this name too\n' > "$A/ai-core-08.md"
printf 'descrip\000tion: the binding rules setup-ai-core user wrote this\n' > "$A/ai-core-07.md"; cp "$A/ai-core-07.md" "$WORK/own-part"
printf -- '---\ntrigger: manual\n---\nours\n' > "$A/mine.md"
agy_init "$F/repo" --dry-run
[ -e "$A/ai-core-09.md" ] || fail "init.sh --dry-run removed a part"
agy_init "$F/repo"
[ ! -e "$A/ai-core-09.md" ] || fail "init.sh kept a part of its own it no longer writes"
[ "$(cat "$A/ai-core-08.md")" = 'the project uses this name too' ] || fail "init.sh removed a file of the project's own that has a part's name"
cmp -s "$A/ai-core-07.md" "$WORK/own-part" || fail "init.sh changed a part containing a NUL"
! grep -q 'ignored null byte' "$WORK/agy.log" || fail "init.sh put a binary header into a shell variable"
[ "$(cat "$A/mine.md")" = "$(printf -- '---\ntrigger: manual\n---\nours')" ] || fail "init.sh touched a rule of the project's own in .agents/rules/"
parts_fit; parts_hold "line for line" cat
! grep -aq 'antigravity: warning' "$WORK/agy.log" || fail "init.sh warned of agy's budget for $(cat "$A"/ai-core-[0-9][0-9].md | wc -c) bytes"
[ -z "$(git -C "$F/repo" status --porcelain)" ] || fail "init.sh left the checkout dirty: $(git -C "$F/repo" status --porcelain | tr '\n' '|')"
# One line of 60,000 bytes in 30,000 characters: cut inside, by bytes, and past agy's budget
{ printf -- '- '; printf '\302\267%.0s' $(seq 30000); printf '\n'; } >> "$F/.ai-core/rules/rules.local.md"
agy_init "$F/repo"
parts_fit; parts_hold "with the line breaks taken out" 'tr -d \n'
grep -aq 'antigravity: warning: .agents/rules/ai-core-\*.md hold [0-9]* bytes' "$WORK/agy.log" || fail "init.sh did not warn of agy's budget for $(cat "$A"/ai-core-[0-9][0-9].md | wc -c) bytes"
# A file of the project's own in a slot init writes stays, and init says agy misses that part
printf 'the project wrote this part\n' > "$A/ai-core-02.md"
agy_init "$F/repo"
[ "$(cat "$A/ai-core-02.md")" = 'the project wrote this part' ] || fail "init.sh wrote over a file of the project's own in a slot it writes"
grep -aqF 'antigravity: .agents/rules/ai-core-02.md is the project'"'"'s own, so agy misses that part of the rules' "$WORK/agy.log" || fail "init.sh did not say that agy misses the part the project's own file holds"
rm "$A/ai-core-02.md"
# Where agy is not served, a part of init's own goes and a file of the project's own stays
N="$WORK/codex-none"
[ ! -e "$N/.agents/rules" ] || fail "init.sh wrote rules for Antigravity where it is not served"
mkdir -p "$N/.agents/rules"; ours_head 1 > "$N/.agents/rules/ai-core-01.md"; printf 'the project\n' > "$N/.agents/rules/ai-core-02.md"
CODEX_HOME="$CODEX_HOME-none" bash "$ROOT/bin/init.sh" "$N" --no-doctor > "$N.log" 2>&1
[ ! -e "$N/.agents/rules/ai-core-01.md" ] && [ -e "$N/.agents/rules/ai-core-02.md" ] || fail "init.sh where agy is not served kept a part of its own or removed the project's file"
# A part the repository tracks is neither written over nor removed
ours_head 1 > "$A/ai-core-01.md"; git -C "$F/repo" add -f .agents/rules/ai-core-01.md
git -C "$F/repo" -c user.name=check -c user.email=check@localhost commit -q -m "a tracked part"
agy_init "$F/repo"
[ "$(cat "$A/ai-core-01.md")" = "$(ours_head 1)" ] && [ -z "$(git -C "$F/repo" status --porcelain)" ] || fail "init.sh wrote over a part the repository tracks"
echo "  each part opens with trigger: always_on and holds at most 24,000 bytes, a line of 60,000 cut inside by bytes and agy's budget warned of; the parts hold the Codex text line for line; a stale part of init's own goes, a file of the project's own under that name, a part git tracks and another rule stay; nothing under --dry-run or where agy is not served, and the checkout stays clean"


section "session startup refreshes only safe default branches and keeps JSON separate"
FF_COPY="$WORK/refresh-copy"; mkdir -p "$FF_COPY"
cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/templates" "$FF_COPY/"
sed 's/^fast_forward_default_branch() {/fast_forward_default_branch_real() {/' "$ROOT/lib/common.sh" > "$FF_COPY/lib/common.sh"
sed -n '/^state() {/,/^}/p' "$ROOT/tests/default-branch.test.sh" >> "$FF_COPY/lib/common.sh"

cat >> "$FF_COPY/lib/common.sh" <<'WRAPPER'

git() { [ -z "${RECORD_GIT:-}" ] || printf '%s\n' "$*" >> "$RECORD_GIT"; command git "$@"; }
fast_forward_default_branch() {
  local rc=0 RECORD_GIT="$FF_TRACE/calls"
  mkdir -p "$FF_TRACE"; : > "$RECORD_GIT"
  state "$1" > "$FF_TRACE/before"
  fast_forward_default_branch_real "$1" || rc=$?
  state "$1" > "$FF_TRACE/after"
  printf '%s\n' "$rc" > "$FF_TRACE/rc"
  return "$rc"
}
WRAPPER
printf 'claude\tmode\talways\t-\t-\n' > "$WORK/refresh-modes"
make_gh_fake
FF_N=0
ff_fixture() {
 FF_N=$((FF_N+1)); FF_DIR="$WORK/startup-$FF_N"; mkdir -p "$FF_DIR"
 FF_DEFAULT="$1"; FF_SEED="$FF_DIR/seed"; FF_REPO="$FF_DIR/checkout"; FF_ORIGIN="$FF_DIR/origin.git"
 git init -qb "$FF_DEFAULT" "$FF_SEED"; printf 'base\n' > "$FF_SEED/tracked"; git -C "$FF_SEED" add tracked; git -C "$FF_SEED" commit -qm base
 git clone -q --bare "$FF_SEED" "$FF_ORIGIN"; git clone -q "$FF_ORIGIN" "$FF_REPO"
 bash "$ROOT/bin/init.sh" "$FF_REPO" --no-doctor > "$FF_DIR/init.log" 2>&1 || fail "startup fixture init"
 git -C "$FF_SEED" remote add origin "$FF_ORIGIN"
 git -C "$FF_SEED" pull -q --ff-only origin "$FF_DEFAULT"
 for commit in one two; do printf '%s\n' "$commit" > "$FF_SEED/remote-file"; git -C "$FF_SEED" add remote-file; git -C "$FF_SEED" commit -qm "$commit"; done
 git -C "$FF_SEED" push -q origin "$FF_DEFAULT"
 FF_TRACE="$FF_DIR/trace"; export FF_TRACE
}
ff_start() { ( cd "$FF_REPO" && PATH="$PATH_SH" TEAM_MODES_FILE="$WORK/refresh-modes" bash "$1/bin/session-start.sh" --tool claude --json > "$FF_DIR/result.json" 2> "$FF_DIR/diagnostic" ); }
for FF_DEFAULT in main master; do
 ff_fixture "$FF_DEFAULT"; ff_start "$FF_COPY" || fail "startup failed: $(cat "$FF_DIR/diagnostic")"
 [ "$(git -C "$FF_REPO" rev-parse HEAD)" = "$(git --git-dir="$FF_ORIGIN" rev-parse "$FF_DEFAULT")" ] || fail 'startup left clean default behind'
 jq -e '.refused == false and .uncommitted_files == 0' "$FF_DIR/result.json" > /dev/null || fail 'startup refresh corrupted JSON or stale status'
done
for state in staged unstaged untracked unmerged; do
 ff_fixture main
 case "$state" in
  staged) printf 'mine\n' > "$FF_REPO/tracked"; git -C "$FF_REPO" add tracked ;;
  unstaged) printf 'mine\n' > "$FF_REPO/tracked" ;;
  untracked) printf 'mine\n' > "$FF_REPO/loose" ;;
  unmerged)
   git -C "$FF_REPO" switch -qc conflict; printf 'other\n' > "$FF_REPO/tracked"; git -C "$FF_REPO" commit -qam other
   git -C "$FF_REPO" switch -q main; printf 'mine\n' > "$FF_REPO/tracked"; git -C "$FF_REPO" commit -qam mine
   git -C "$FF_REPO" merge conflict >/dev/null 2>&1 && fail 'startup conflict did not conflict' ;;
 esac
 ff_start "$FF_COPY" || fail 'startup stopped instead of reporting skipped refresh'
 cmp -s "$FF_TRACE/before" "$FF_TRACE/after" || fail "startup changed $state state"
 ! grep -q ' fetch ' "$FF_TRACE/calls" || fail "startup fetched before $state refusal"
 grep -qF "$FF_REPO" "$FF_DIR/diagnostic" || fail 'startup omission of dirty path'
 jq -e '.refused == false' "$FF_DIR/result.json" > /dev/null || fail 'dirty startup JSON corrupted'
done
ff_fixture main
sed 's/fast_forward_default_branch "\$PWD" || true/:/' "$ROOT/bin/session-start.sh" > "$FF_COPY/bin/session-start.sh"
ff_start "$FF_COPY" || fail 'startup mutant did not reach report'
[ "$(git -C "$FF_REPO" rev-parse HEAD)" != "$(git --git-dir="$FF_ORIGIN" rev-parse main)" ] || fail 'removed startup call mutant escaped'
echo "  clean main/master refresh; dirty states preserve all refs, FETCH_HEAD, index and files without fetch; removed caller stays behind"

exit 0
