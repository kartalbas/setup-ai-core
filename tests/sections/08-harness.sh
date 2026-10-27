#!/usr/bin/env bash
# the project harness: created, cloned, moved, assembled, the maps; one section of the suite, run by tests/check.sh with the others
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

section "the project harness: created from the skeleton, cloned on another machine, its rules, skills, docs, data and repos/<repo>/ assembled"
make_gh_fake
# A project repository: shop-web of example-org, with a README
new_checkout() {  # new_checkout <dir> <repo name> [org]
  git init -q "$1"; echo readme > "$1/README.md"
  git -C "$1" add README.md; git -C "$1" -c user.name=check -c user.email=check@localhost commit -q -m init
  git -C "$1" remote add origin "https://github.com/${3:-example-org}/$2.git"
}
# Two machines with a project folder each; a harness clone lands beside the checkouts in it
mkdir -p "$WORK/home-sh" "$WORK/home-second" "$WORK/org-sh" "$WORK/org-second"
new_checkout "$WORK/org-sh/shop-web" shop-web
HOME="$WORK/home-sh" PATH="$PATH_SH" bash "$ROOT/bin/init.sh" "$WORK/org-sh/shop-web" --no-doctor --dry-run > "$WORK/layers-sh-0.log" 2>&1 || fail "init.sh --dry-run before the project harness exists (see $WORK/layers-sh-0.log)"
grep -aq 'example-org/shop-ai-core would be created from the skeleton' "$WORK/layers-sh-0.log" || fail "init.sh --dry-run does not announce the harness it would create"
[ ! -e "$GH_FAKE/github.com/example-org/shop-ai-core.git" ] && [ ! -e "$WORK/org-sh/shop-ai-core" ] || fail "init.sh --dry-run created the project harness"
HOME="$WORK/home-sh" PATH="$PATH_SH" bash "$ROOT/bin/init.sh" "$WORK/org-sh/shop-web" --no-doctor > "$WORK/layers-sh-1.log" 2>&1 || fail "init.sh with a new project harness (see $WORK/layers-sh-1.log)"
grep -aq 'created: example-org/shop-ai-core, private, from the skeleton' "$WORK/layers-sh-1.log" || fail "init.sh did not create the project harness (see $WORK/layers-sh-1.log)"
grep -aq '^--> Project harness: example-org/shop-ai-core (' "$WORK/layers-sh-1.log" || fail "init.sh did not name the project harness"
[ -d "$GH_FAKE/github.com/example-org/shop-ai-core.git" ] || fail "the harness was not pushed to GitHub"
[ -f "$WORK/org-sh/shop-ai-core/ai-core.json" ] && [ -f "$WORK/org-sh/shop-ai-core/labels.tsv" ] || fail "the clone beside the checkout lacks the skeleton"
[ ! -e "$WORK/org-sh/shop-ai-core/models.tsv" ] || fail "the new harness pins a copy of the model table, so a later table of setup-ai-core never reaches it"
[ ! -e "$WORK/org-sh/shop-ai-core/team-modes.tsv" ] || fail "the new harness pins a copy of the team-modes table, so a later table of setup-ai-core never reaches it"
[ "$(wc -l < "$WORK/org-sh/shop-web/.ai-core/STAMP" | tr -d ' ')" = 2 ] && grep -q '^shop-ai-core ' "$WORK/org-sh/shop-web/.ai-core/STAMP" || fail "STAMP does not name setup-ai-core and the harness: $(cat "$WORK/org-sh/shop-web/.ai-core/STAMP" | tr '\n' '|')"
cmp -s "$WORK/org-sh/shop-web/.ai-core/config.env" "$ROOT/templates/.ai-core/config.env" || fail "config.env of the checkout is not the harness's (the skeleton's copy of the template)"
# The skeleton's .gitattributes makes every checkout of the harness LF; a clone made before the
# skeleton carried it gets the lines it lacks on the next init, and ai-core push commits them (here
# the clone commits them itself, so the rest of this section sees the harness as created). The
# older clone has no .gitattributes.
grep -qxF '* text=auto eol=lf' "$WORK/org-sh/shop-ai-core/.gitattributes" || fail "the created harness lacks the skeleton's .gitattributes"
git -C "$WORK/org-sh/shop-ai-core" rm -q .gitattributes && git -C "$WORK/org-sh/shop-ai-core" -c user.name=check -c user.email=check@localhost commit -q -m 'an older harness' && git -C "$WORK/org-sh/shop-ai-core" push -q origin HEAD 2>/dev/null || fail "could not make the harness clone an older one"
HOME="$WORK/home-sh" PATH="$PATH_SH" bash "$ROOT/bin/init.sh" "$WORK/org-sh/shop-web" --no-doctor --dry-run > "$WORK/layers-sh-attr-dry.log" 2>&1 || fail "init.sh --dry-run on a harness clone without .gitattributes (see $WORK/layers-sh-attr-dry.log)"
grep -aq "note: example-org/shop-ai-core would get the skeleton's .gitattributes (every file LF; dry run: not written)" "$WORK/layers-sh-attr-dry.log" || fail "init.sh --dry-run does not announce the skeleton's .gitattributes (see $WORK/layers-sh-attr-dry.log)"
[ ! -e "$WORK/org-sh/shop-ai-core/.gitattributes" ] || fail "init.sh --dry-run wrote into the harness clone"
HOME="$WORK/home-sh" PATH="$PATH_SH" bash "$ROOT/bin/init.sh" "$WORK/org-sh/shop-web" --no-doctor > "$WORK/layers-sh-attr.log" 2>&1 || fail "init.sh on a harness clone without .gitattributes (see $WORK/layers-sh-attr.log)"
grep -aq 'note: example-org/shop-ai-core: .gitattributes from the skeleton written into .*shop-ai-core (every file LF); ai-core push commits it' "$WORK/layers-sh-attr.log" || fail "init.sh did not report the skeleton's .gitattributes for the older clone (see $WORK/layers-sh-attr.log)"
grep -qxF '* text=auto eol=lf' "$WORK/org-sh/shop-ai-core/.gitattributes" || fail "init.sh did not write the skeleton's rule into the older clone"
git -C "$WORK/org-sh/shop-ai-core" add .gitattributes && git -C "$WORK/org-sh/shop-ai-core" -c user.name=check -c user.email=check@localhost commit -q -m 'the skeleton file again' && git -C "$WORK/org-sh/shop-ai-core" push -q origin HEAD 2>/dev/null || fail "could not commit .gitattributes back into the harness clone"
# The project fills its harness: a new rule section, a replaced one, a skill, a document, the map and config of shop-web
git clone -q "$GH_FAKE/github.com/example-org/shop-ai-core.git" "$WORK/author" 2>/dev/null
mkdir -p "$WORK/author/skills/deploy" "$WORK/author/repos/shop-web/.ai-core"
printf '## Releases\n\n- **A release is a tag.** Nothing ships without one. [review]\n' > "$WORK/author/rules/35-releases.md"
printf '## Naming\n\n- **Names are English.** The project spells them its own way. [review]\n' > "$WORK/author/rules/50-naming.md"
printf -- '---\nname: deploy\ndescription: how this project deploys\n---\nRun the deploy script.\n' > "$WORK/author/skills/deploy/SKILL.md"
mkdir -p "$WORK/author/agents"; printf -- '---\nname: builder\ndescription: builds one issue\n---\nBuild it.\n' > "$WORK/author/agents/builder.md"; echo 'the agents of this layer' > "$WORK/author/agents/README.md"
printf '# Glossary\n\ntenant: a customer.\n' > "$WORK/author/docs/glossary.md"
printf '# shop-web\n\nThe map of shop-web.\n' > "$WORK/author/repos/shop-web/AGENTS.md"
printf 'AGENTS="claude"\nUPDATE_CHECK="never"\n' > "$WORK/author/repos/shop-web/.ai-core/config.env"
printf 'plan\tmechanical\tclaude-sonnet-5-5\tmedium\tno\n' > "$WORK/author/models.tsv"
git -C "$WORK/author" add -A; git -C "$WORK/author" -c user.name=check -c user.email=check@localhost commit -q -m "the project's own"; git -C "$WORK/author" push -q origin HEAD
HOME="$WORK/home-sh" PATH="$PATH_SH" bash "$ROOT/bin/init.sh" "$WORK/org-sh/shop-web" --no-doctor > "$WORK/layers-sh-2.log" 2>&1 || fail "init.sh second run with the filled harness (see $WORK/layers-sh-2.log)"
assembled_ok() {  # assembled_ok <checkout> <label>
  local c="$1" t="$2" hash
  hash="$(git -C "$WORK/author" rev-parse --short HEAD)"
  grep -q "^<!-- shop-ai-core $hash: rules/35-releases.md -->" "$c/.ai-core/rules/rules.md" || fail "$t: the harness's new section is not in rules.md"
  grep -q "^<!-- shop-ai-core $hash: rules/50-naming.md -->" "$c/.ai-core/rules/rules.md" || fail "$t: the harness's section did not replace the generic one"
  grep -q "^<!-- setup-ai-core .*: rules/50-naming.md -->" "$c/.ai-core/rules/rules.md" && fail "$t: the generic naming section is still there beside the replacement"
  [ "$(grep -c '^<!-- ' "$c/.ai-core/rules/rules.md")" = $((SECTIONS + 1)) ] || fail "$t: rules.md has $(grep -c '^<!-- ' "$c/.ai-core/rules/rules.md") sections, expected $((SECTIONS + 1))"
  bash "$ROOT/bin/rules-check.sh" "$c/.ai-core/rules/rules.md" > /dev/null || fail "$t: the assembled rules.md fails rules-check"
  [ -f "$c/.claude/skills/deploy/SKILL.md" ] && [ -f "$c/.agents/skills/deploy/SKILL.md" ] || fail "$t: the skill is not in both skill directories"
  [ -f "$c/.claude/skills/person-in-charge/SKILL.md" ] && [ -f "$c/.agents/skills/person-in-charge/SKILL.md" ] || fail "$t: the skill of setup-ai-core is not in both skill directories"
  for dir in .claude .agents; do
    cmp -s "$ROOT/skills/person-in-charge/SKILL.md" "$c/$dir/skills/person-in-charge/SKILL.md" || fail "$t: stale coordinator instructions in $dir"
    for tool in claude codex agy; do
      cmp -s "$ROOT/skills/person-in-charge/references/$tool.md" "$c/$dir/skills/person-in-charge/references/$tool.md" || fail "$t: stale $tool reference in $dir"
    done
  done
  [ -f "$c/.claude/agents/builder.md" ] || fail "$t: the agent definition is not in .claude/agents/"
  [ ! -e "$c/.claude/agents/README.md" ] || fail "$t: agents/README.md of the layer was deployed as an agent"
  [ -f "$c/.ai-core/docs/shop-ai-core/glossary.md" ] || fail "$t: the harness's docs are not under .ai-core/docs/shop-ai-core/"
  grep -q '^The map of shop-web' "$c/AGENTS.md" || fail "$t: AGENTS.md is not the map from repos/shop-web/"
  grep -q '^AGENTS="claude"' "$c/.ai-core/config.env" && grep -q '^UPDATE_CHECK="never"' "$c/.ai-core/config.env" || fail "$t: config.env does not carry the keys of repos/shop-web/.ai-core/"
  [ "$(grep -cE '^(AGENTS|UPDATE_CHECK)=' "$c/.ai-core/config.env")" = 2 ] && grep -q '^MAP_TOOL=' "$c/.ai-core/config.env" || fail "$t: config.env is not the layer's with the keys of repos/shop-web/.ai-core/ laid over it"
  [ -f "$c/.ai-core/labels.tsv" ] && [ -f "$c/.ai-core/team-modes.tsv" ] || fail "$t: the data files did not come from the harness"
  cmp -s "$c/.ai-core/models.tsv" "$WORK/author/models.tsv" || fail "$t: models.tsv is not the harness's own"
  cmp -s "$c/.ai-core/team-modes.tsv" "$ROOT/templates/.ai-core/team-modes.tsv" || fail "$t: a harness without its own team-modes table did not give the checkout setup-ai-core's"
  [ -e "$c/.cursorrules" ] && fail "$t: a pointer file of an agent the harness does not serve was deployed"
  st="$(git -C "$c" status --porcelain | tr -d '\r' | sort | tr '\n' '|')"
  [ -z "$st" ] || fail "$t: git status is not clean after init: $st"
}
assembled_ok "$WORK/org-sh/shop-web" "init.sh"
# Another machine: it holds the clone where an earlier version put it, ~/.shop-ai-core, and init
# moves it beside the checkout; without a clone the harness is cloned from GitHub; the checkout is
# assembled the same
new_checkout "$WORK/org-second/shop-web" shop-web
git clone -q "$GH_FAKE/github.com/example-org/shop-ai-core.git" "$WORK/home-second/.shop-ai-core" 2>/dev/null
HOME="$WORK/home-second" PATH="$PATH_SH" bash "$ROOT/bin/init.sh" "$WORK/org-second/shop-web" --no-doctor > "$WORK/layers-second-1.log" 2>&1 || fail "init.sh with the old clone under the home directory (see $WORK/layers-second-1.log)"
grep -aq 'created:' "$WORK/layers-second-1.log" && fail "init.sh created a harness that exists"
grep -aq 'moved: example-org/shop-ai-core from ' "$WORK/layers-second-1.log" || fail "init.sh did not report the move of the old clone (see $WORK/layers-second-1.log)"
[ ! -e "$WORK/home-second/.shop-ai-core" ] || fail "init.sh left the old clone under the home directory"
[ -f "$WORK/org-second/shop-ai-core/ai-core.json" ] || fail "init.sh did not move the harness beside the checkout"
# The move an earlier run left halfway (the history here, the files still under the home directory beside an empty .git) is completed
mkdir -p "$WORK/home-second/.shop-ai-core/.git"; mv "$WORK/org-second/shop-ai-core"/[!.]* "$WORK/home-second/.shop-ai-core/"
HOME="$WORK/home-second" PATH="$PATH_SH" bash "$ROOT/bin/init.sh" "$WORK/org-second/shop-web" --no-doctor > "$WORK/layers-second-1c.log" 2>&1 || fail "init.sh completing an interrupted move (see $WORK/layers-second-1c.log)"
grep -aq 'moved: example-org/shop-ai-core from ' "$WORK/layers-second-1c.log" || fail "init.sh did not complete the interrupted move (see $WORK/layers-second-1c.log)"
[ ! -e "$WORK/home-second/.shop-ai-core" ] && [ -z "$(git -C "$WORK/org-second/shop-ai-core" status --porcelain)" ] || fail "the interrupted move was not completed: $(git -C "$WORK/org-second/shop-ai-core" status --porcelain | tr '\n' '|')"
# A copy that is not whole is refused however long the comparison of the two directories runs, and the old
# directory stays; a whole copy beside many files of the new place's own is moved however long that list runs
M="$WORK/move-long"; long_name="$(printf 'f%.0s' {1..200})"
git init -q "$M/old"; git -C "$M/old" -c user.name=check -c user.email=check@localhost commit -q --allow-empty -m "the harness"
mkdir -p "$M/old/many" "$M/new/many"
for i in $(seq 1000 2999); do printf 'here\n' > "$M/old/many/$long_name-$i"; printf 'changed\n' > "$M/new/many/$long_name-$i"; done
( . "$ROOT/lib/layers.sh"; move_layer example-org/long-ai-core "$M/old" "$M/new" ) > "$M/refused.log" 2>&1 && fail "move_layer moved a copy in which 2000 files differ"
[ -d "$M/old/many" ] && grep -aq 'example-org/long-ai-core is not whole at' "$M/refused.log" || fail "move_layer removed the old directory of a copy that is not whole, after a long comparison: $(head -c 300 "$M/refused.log")"
rm -rf "$M/new" "$M/old/many"; mkdir -p "$M/new/many"
for i in $(seq 1000 2999); do printf 'its own\n' > "$M/new/many/$long_name-$i"; done
( . "$ROOT/lib/layers.sh"; move_layer example-org/long-ai-core "$M/old" "$M/new" ) > "$M/moved.log" 2>&1 || fail "move_layer refused a whole copy beside 2000 files of the new place's own: $(head -c 300 "$M/moved.log")"
[ ! -e "$M/old" ] && [ -d "$M/new/.git" ] || fail "move_layer did not complete the move of a whole copy beside 2000 files of the new place's own"
rm -rf "$WORK/org-second/shop-ai-core"
HOME="$WORK/home-second" PATH="$PATH_SH" bash "$ROOT/bin/init.sh" "$WORK/org-second/shop-web" --no-doctor > "$WORK/layers-second-1b.log" 2>&1 || fail "init.sh with the harness to clone (see $WORK/layers-second-1b.log)"
grep -aqE 'created:|moved:' "$WORK/layers-second-1b.log" && fail "init.sh created or moved a harness that is on GitHub"
[ -f "$WORK/org-second/shop-ai-core/ai-core.json" ] || fail "init.sh did not clone the harness beside the checkout"
assembled_ok "$WORK/org-second/shop-web" "second machine"
# What the harness no longer provides leaves the checkout: the skill and the agent go from the harness, init takes them out
git -C "$WORK/author" rm -rq skills/deploy agents/builder.md; git -C "$WORK/author" -c user.name=check -c user.email=check@localhost commit -q -m "the skill and the agent go"; git -C "$WORK/author" push -q origin HEAD
HOME="$WORK/home-sh" PATH="$PATH_SH" bash "$ROOT/bin/init.sh" "$WORK/org-sh/shop-web" --no-doctor > "$WORK/layers-sh-gone.log" 2>&1 || fail "init.sh after the harness dropped a skill and an agent (see $WORK/layers-sh-gone.log)"
c="$WORK/org-sh/shop-web"
grep -aq '^  removed    .claude/skills/deploy, .agents/skills/deploy, .claude/agents/builder.md$' "$WORK/layers-sh-gone.log" || fail "init.sh does not report what it took out: $(grep -a '^  removed' "$WORK/layers-sh-gone.log")"
[ ! -e "$c/.claude/skills/deploy" ] && [ ! -e "$c/.agents/skills/deploy" ] && [ ! -e "$c/.claude/agents/builder.md" ] || fail "init.sh left what the harness no longer provides"
[ -f "$c/.ai-core/docs/shop-ai-core/glossary.md" ] && grep -q '^The map of shop-web' "$c/AGENTS.md" || fail "init.sh took out what the harness still provides"
grep -q 'skills/deploy' "$c/.ai-core/DEPLOYED" && fail "init.sh still records the skill in DEPLOYED"
# The auto-mode entries of setup-ai-core and of the harness go into Claude Code's user settings, each
# led by its layer: the person's own entry, another layer's and "$defaults" stay, an untagged copy of
# a layer's entry gives way, a list init creates starts with "$defaults", a second run writes the
# same, an entry the harness drops leaves, and a line init cannot read stops it before it writes.
# init.sh finds the settings under HOME.
printf '# the shop'"'"'s own\nallow\tA shop entry moved by hand.\nenvironment\tKey internal services: the shop run manager.\n' > "$WORK/author/auto-mode.tsv"
git -C "$WORK/author" add auto-mode.tsv; git -C "$WORK/author" -c user.name=check -c user.email=check@localhost commit -q -m "the shop's auto-mode entries"; git -C "$WORK/author" push -q origin HEAD
mkdir -p "$WORK/home-sh/.claude"
s="$WORK/home-sh/.claude/settings.json"
printf '{"model":"opus","autoMode":{"allow":["$defaults","Own entry.","[other-ai-core] Another layer.","A shop entry moved by hand."]}}\n' > "$s"
cp "$s" "$WORK/settings-before.json"
auto_mode_init() {  # auto_mode_init <log> [--dry-run]
  env -u CLAUDE_CONFIG_DIR HOME="$WORK/home-sh" PATH="$PATH_SH" bash "$ROOT/bin/init.sh" "$WORK/org-sh/shop-web" --no-doctor ${2:+--dry-run} > "$1" 2>&1
}
generic="$(grep -v '^#' "$ROOT/auto-mode.tsv" | awk -F'\t' '$1 == "allow" { print "[setup-ai-core] " $2 }' | jq -Rn '[inputs]')"
[ "$(jq length <<< "$generic")" -gt 0 ] || fail "auto-mode.tsv of setup-ai-core carries no allow entry to look for"
auto_mode_init "$WORK/auto-mode-dry.log" dry || fail "init.sh --dry-run with the harness's auto-mode entries (see $WORK/auto-mode-dry.log)"
grep -aq '^  auto mode: .*settings.json would change:$' "$WORK/auto-mode-dry.log" || fail "init.sh --dry-run does not say the auto-mode entries would change (see $WORK/auto-mode-dry.log)"
cmp -s "$s" "$WORK/settings-before.json" || fail "init.sh --dry-run wrote the user settings"
auto_mode_init "$WORK/auto-mode-1.log" || fail "init.sh with the harness's auto-mode entries (see $WORK/auto-mode-1.log)"
for line in 'added to allow: [shop-ai-core] A shop entry moved by hand.' 'removed from allow: A shop entry moved by hand.' 'added to environment: $defaults' 'added to environment: [shop-ai-core] Key internal services: the shop run manager.'; do
  grep -aqxF "    $line" "$WORK/auto-mode-1.log" || fail "init.sh does not report '$line' (see $WORK/auto-mode-1.log)"
done
jq -e --argjson g "$generic" '.model == "opus"
  and .autoMode.allow == (["$defaults", "Own entry.", "[other-ai-core] Another layer."] + $g + ["[shop-ai-core] A shop entry moved by hand."])
  and .autoMode.environment == ["$defaults", "[shop-ai-core] Key internal services: the shop run manager."]' "$s" > /dev/null \
  || fail "init.sh merged the auto-mode entries wrongly: $(jq -c .autoMode "$s")"
jq -e '[.autoMode.allow[] | select(startswith("[setup-ai-core] Ending a hung test or check process tree is allowed, also as a retry after an earlier refusal, when a phase session of the same coordinator started it,") and endswith("never to a process of another session or coordinator, named in the coordinator'"'"'s report with its PIDs and age."))] | length == 1' "$s" > /dev/null \
  || fail "init.sh did not write the entry that lets a coordinator end the hung test tree of its finished worker: $(jq -c .autoMode.allow "$s")"
cp "$s" "$WORK/settings-1.json"
auto_mode_init "$WORK/auto-mode-2.log" || fail "init.sh second run with the same auto-mode entries (see $WORK/auto-mode-2.log)"
cmp -s "$s" "$WORK/settings-1.json" || fail "init.sh changed the user settings on a second run with the same entries"
grep -aq '^  auto mode:' "$WORK/auto-mode-2.log" && fail "init.sh reports an auto-mode change on a second run with the same entries"
# the same entries in another order are no change
jq '.autoMode.allow |= ([.[] | select(startswith("["))] + [.[] | select(startswith("[") | not)])' "$s" > "$WORK/reordered.json" && cp "$WORK/reordered.json" "$s"
auto_mode_init "$WORK/auto-mode-order.log" || fail "init.sh with the entries in another order (see $WORK/auto-mode-order.log)"
cmp -s "$s" "$WORK/reordered.json" || fail "init.sh rewrote a list whose entries stood only in another order"
printf 'allow\tA shop entry moved by hand.\n' > "$WORK/author/auto-mode.tsv"
git -C "$WORK/author" -c user.name=check -c user.email=check@localhost commit -qam "the run manager entry goes"; git -C "$WORK/author" push -q origin HEAD
auto_mode_init "$WORK/auto-mode-gone.log" || fail "init.sh after the harness dropped an auto-mode entry (see $WORK/auto-mode-gone.log)"
grep -aqxF '    removed from environment: [shop-ai-core] Key internal services: the shop run manager.' "$WORK/auto-mode-gone.log" || fail "init.sh does not report the dropped entry (see $WORK/auto-mode-gone.log)"
jq -e '.autoMode.environment == ["$defaults"] and (.autoMode.allow | index("[shop-ai-core] A shop entry moved by hand.")) != null' "$s" > /dev/null || fail "init.sh left the dropped entry or lost the kept one: $(jq -c .autoMode "$s")"
printf 'allow\tA shop entry moved by hand.\ndeny\tNo list of the classifier is called so.\n' > "$WORK/author/auto-mode.tsv"
git -C "$WORK/author" -c user.name=check -c user.email=check@localhost commit -qam "a line init cannot read"; git -C "$WORK/author" push -q origin HEAD
cp "$s" "$WORK/settings-bad.json"; cp "$WORK/org-sh/shop-web/.ai-core/STAMP" "$WORK/stamp-bad"
auto_mode_init "$WORK/auto-mode-bad.log" && fail "init.sh went on with a line it cannot read in auto-mode.tsv"
grep -aq 'auto-mode.tsv:2 is no auto-mode entry: the list (allow or environment), one tab, then the entry; nothing was written' "$WORK/auto-mode-bad.log" || fail "init.sh does not name the line it cannot read (see $WORK/auto-mode-bad.log)"
cmp -s "$s" "$WORK/settings-bad.json" && cmp -s "$WORK/org-sh/shop-web/.ai-core/STAMP" "$WORK/stamp-bad" || fail "init.sh wrote before it stopped at the line it cannot read"
printf '\357\273\277# a byte-order mark first, as some editors write it\nallow\tA shop entry moved by hand.\n' > "$WORK/author/auto-mode.tsv"
git -C "$WORK/author" -c user.name=check -c user.email=check@localhost commit -qam "a byte-order mark"; git -C "$WORK/author" push -q origin HEAD
auto_mode_init "$WORK/auto-mode-bom.log" || fail "init.sh refused auto-mode.tsv for its byte-order mark (see $WORK/auto-mode-bom.log)"
git -C "$WORK/author" rm -q auto-mode.tsv; git -C "$WORK/author" -c user.name=check -c user.email=check@localhost commit -q -m "no auto-mode entries"; git -C "$WORK/author" push -q origin HEAD
auto_mode_init "$WORK/auto-mode-none.log" || fail "init.sh after the harness dropped its auto-mode.tsv (see $WORK/auto-mode-none.log)"
grep -aqxF '    removed from allow: [shop-ai-core] A shop entry moved by hand.' "$WORK/auto-mode-none.log" || fail "init.sh does not report the entries of the dropped table (see $WORK/auto-mode-none.log)"
jq -e '[(.autoMode.allow + .autoMode.environment)[] | select(startswith("[shop-ai-core] "))] | length == 0' "$s" > /dev/null || fail "init.sh left entries of a harness that carries no auto-mode.tsv: $(jq -c .autoMode "$s")"
# A settings folder that is not there, settings that are no JSON object and a folder without settings:
# the first two say so and write nothing, the third gets its file; and a dry run whose harness is not
# cloned yet keeps that harness's entries
init_with() {  # init_with <settings folder> <checkout> <log> [dry]
  CLAUDE_CONFIG_DIR="$1" HOME="$WORK/home-sh" PATH="$PATH_SH" bash "$ROOT/bin/init.sh" "$2" --no-doctor ${4:+--dry-run} > "$3" 2>&1
}
mkdir -p "$WORK/org-dry"; new_checkout "$WORK/org-dry/shop-web" shop-web
mkdir -p "$WORK/claude-bad" "$WORK/claude-new" "$WORK/claude-dry"; printf '{"autoMode":' > "$WORK/claude-bad/settings.json"
printf '{"autoMode":{"allow":["$defaults","[shop-ai-core] Kept while the harness is not cloned."]}}\n' > "$WORK/claude-dry/settings.json"
init_with "$WORK/claude-missing" "$WORK/org-sh/shop-web" "$WORK/auto-mode-missing.log" || fail "init.sh without a settings folder (see $WORK/auto-mode-missing.log)"
grep -aq '^  auto mode: .*claude-missing does not exist, so Claude Code has not run on this machine; no entry written$' "$WORK/auto-mode-missing.log" || fail "init.sh does not say it wrote no entry for want of a settings folder (see $WORK/auto-mode-missing.log)"
[ ! -e "$WORK/claude-missing" ] || fail "init.sh created the settings folder of a Claude Code that never ran"
init_with "$WORK/claude-bad" "$WORK/org-sh/shop-web" "$WORK/auto-mode-bad-json.log" || fail "init.sh with settings that are no JSON (see $WORK/auto-mode-bad-json.log)"
grep -aq '^  auto mode: .*settings.json is no JSON object with lists in autoMode, so no entry was written; repair it and run init again$' "$WORK/auto-mode-bad-json.log" || fail "init.sh does not say the settings are no JSON object (see $WORK/auto-mode-bad-json.log)"
[ "$(cat "$WORK/claude-bad/settings.json")" = '{"autoMode":' ] || fail "init.sh wrote settings it could not read"
init_with "$WORK/claude-new" "$WORK/org-sh/shop-web" "$WORK/auto-mode-new.log" || fail "init.sh with a settings folder and no settings (see $WORK/auto-mode-new.log)"
jq -e --argjson g "$generic" '.autoMode.allow == (["$defaults"] + $g) and (.autoMode | has("environment") | not)' "$WORK/claude-new/settings.json" > /dev/null || fail "init.sh wrote the new settings wrongly: $(cat "$WORK/claude-new/settings.json" 2>&1)"
init_with "$WORK/claude-dry" "$WORK/org-dry/shop-web" "$WORK/auto-mode-uncloned.log" dry || fail "init.sh --dry-run with the harness not cloned yet (see $WORK/auto-mode-uncloned.log)"
grep -aq 'shop-ai-core would be cloned' "$WORK/auto-mode-uncloned.log" || fail "init.sh --dry-run did not find the harness uncloned (see $WORK/auto-mode-uncloned.log)"
grep -aq 'removed from allow: \[shop-ai-core\]' "$WORK/auto-mode-uncloned.log" && fail "init.sh --dry-run would remove the entries of a harness it has not cloned (see $WORK/auto-mode-uncloned.log)"
# The map: the agent CLI (a fake claude here) writes it, map puts it into the harness, pushes it and brings it into the checkout at once; people's rules kept; a bad output refused
cat > "$WORK/ghbin/claude" <<'EOF'
#!/bin/sh
echo "$*" >> "$MAP_FAKE_LOG"
[ -z "${MAP_FAKE_BAD:-}" ] || { echo "Sure! Here is the map:"; exit 0; }
[ -z "${MAP_FAKE_NOISE:-}" ] || printf 'Done reading. Writing the map now.\n\n'
n="$(basename "$PWD")"
printf '# %s \342\200\224 the map\n\n## What it is\nA shop.%s\n\n## Shape\n- src/: the code\n\n## Build, check, run\n- npm test\n\n## Where to add things\n| a page | src/pages/ |\n\n## Rules of this repository\n(none yet: written by people, kept on every regeneration)\n' "$n" "${MAP_FAKE_NOTE:+ $MAP_FAKE_NOTE}"
[ -z "${MAP_FAKE_NOISE:-}" ] || printf '\n> Grant write permission and rerun.\n\ntokens saved this turn\n'
EOF
chmod +x "$WORK/ghbin/claude"
# codex writes its answer into the file named by --output-last-message; agy prints it, like claude
cat > "$WORK/ghbin/codex" <<'EOF'
#!/bin/sh
echo "$*" >> "$MAP_FAKE_LOG"
out=""; while [ $# -gt 0 ]; do [ "$1" = "--output-last-message" ] && out="$2"; shift; done
n="$(basename "$PWD")"
printf '# %s \342\200\224 the map\n\n## What it is\nA shop.\n\n## Shape\n- src/: the code\n\n## Build, check, run\n- npm test\n\n## Where to add things\n| a page | src/pages/ |\n\n## Rules of this repository\n(none yet: written by people, kept on every regeneration)\n' "$n" > "$out"
echo "codex: thinking..."
EOF
# agy answers `agy models` the way a signed-in agy does, or the way one does that is not (MAP_FAKE_SIGNED_OUT)
{ head -n1 "$WORK/ghbin/claude"; cat <<'EOF'
if [ "${1:-}" = models ]; then
  [ -z "${MAP_FAKE_SIGNED_OUT:-}" ] || { echo 'Using file-based token storage because SSH session detected'; echo 'not signed in'; exit 1; }
  printf 'gemini-3.8-flash-high\tGemini 3.8 Flash (High)\n'; exit 0
fi
case " $* " in *" --settings "*) echo "flags provided but not defined: -settings" >&2; exit 2 ;; esac   # agy has no such flag
EOF
tail -n +2 "$WORK/ghbin/claude"; } > "$WORK/ghbin/agy"; chmod +x "$WORK/ghbin/agy" "$WORK/ghbin/codex"
MAPLOG="$WORK/map.args"
map_run() { HOME="$WORK/home-sh" AI_CORE_HOME="$WORK/home-sh" PATH="$PATH_SH" MAP_FAKE_LOG="$MAPLOG" bash "$ROOT/bin/map.sh" "$@"; }
mkdir -p "$WORK/home-sh/.ai-core" && printf '{"permissions":{"deny":["Read(//**/*.env)"]}}\n' > "$WORK/home-sh/.ai-core/claude-run-settings.json"
map_run "$WORK/org-sh/shop-web" > "$WORK/map-1.log" 2>&1 || fail "map.sh (see $WORK/map-1.log)"
M="$WORK/org-sh/shop-ai-core/repos/shop-web/AGENTS.md"
head -n1 "$M" | grep -qE '^<!-- ai-core map: generated [0-9-]+ from [0-9a-f]+; ' && [ "$(sed -n 2p "$M")" = "# shop-web — the map" ] || fail "map.sh did not write the map into the harness: $(head -n2 "$M" 2>/dev/null | tr '\n' '|')"
[ -z "$(git -C "$WORK/org-sh/shop-ai-core" status --porcelain)" ] && [ "$(git -C "$WORK/org-sh/shop-ai-core" rev-list --count '@{upstream}..HEAD')" = 0 ] || fail "map.sh did not commit and push the harness"
head -n1 "$WORK/org-sh/shop-web/AGENTS.md" | grep -q 'ai-core map: generated' || fail "map.sh did not bring the map into the checkout"
# The checkout's copy opens with the contract after the header and the title; the harness's copy stays the tool's
[ "$(sed -n 4p "$WORK/org-sh/shop-web/AGENTS.md")" = '## Binding rules' ] && grep -q '^- The engineering rules, .*: @\.ai-core/rules/rules\.md$' "$WORK/org-sh/shop-web/AGENTS.md" && grep -q '^- When a skill or a tool is used: @\.ai-core/rules/skills\.md$' "$WORK/org-sh/shop-web/AGENTS.md" && grep -q '^## What it is' "$WORK/org-sh/shop-web/AGENTS.md" || fail "the map in the checkout, no project folder around it, does not open with the binding rules imported: $(sed -n 4,9p "$WORK/org-sh/shop-web/AGENTS.md" | tr '\n' '|')"
grep -q '^## Binding rules' "$M" && fail "the map in the harness carries the contract; init adds it to the checkout's copy"
grep -q -- '--allowedTools' "$MAPLOG" && grep -q 'Read the repository first, cheaply' "$MAPLOG" || fail "map.sh did not call the agent CLI with the prompt and the tools"
grep -q -- "--settings $WORK/home-sh/.ai-core/claude-run-settings.json" "$MAPLOG" || fail "map.sh did not hand claude the denials of the run settings file: $(tail -c 300 "$MAPLOG")"
# a map run may use only Read, Glob and Grep, so claude starts without the account's connectors; planted: the start without the flag, in a copy
map_start_is_strict() { grep -- '--allowedTools' "$1" | grep -q -- '--strict-mcp-config'; }
map_start_is_strict "$MAPLOG" || fail "map.sh started claude without --strict-mcp-config: $(tail -c 300 "$MAPLOG")"
mkdir -p "$WORK/planted-map"; cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/templates" "$WORK/planted-map/"; cp "$ROOT/VERSION" "$WORK/planted-map/"
sed -i.bak 's/ --strict-mcp-config//' "$WORK/planted-map/bin/map.sh"
HOME="$WORK/home-sh" AI_CORE_HOME="$WORK/home-sh" PATH="$PATH_SH" MAP_FAKE_LOG="$WORK/planted-map.args" bash "$WORK/planted-map/bin/map.sh" "$WORK/org-sh/shop-web" --dry-run > "$WORK/map-planted.log" 2>&1 || fail "map.sh without the flag, in a copy, did not run (see $WORK/map-planted.log)"
grep -q -- '--allowedTools' "$WORK/planted-map.args" && ! map_start_is_strict "$WORK/planted-map.args" || fail "the check for --strict-mcp-config did not go red on a map start without it: $(tail -c 300 "$WORK/planted-map.args")"
mv "$WORK/home-sh/.ai-core/claude-run-settings.json" "$WORK/run-settings.bak"
map_run "$WORK/org-sh/shop-web" --dry-run > "$WORK/map-nosettings.log" 2>&1 && fail "map.sh ran claude without the run settings file"
grep -q 'claude-run-settings.json does not exist' "$WORK/map-nosettings.log" || fail "map.sh did not say the run settings file is missing: $(tail -c 300 "$WORK/map-nosettings.log")"
mv "$WORK/run-settings.bak" "$WORK/home-sh/.ai-core/claude-run-settings.json"
# people write a rule into the map and push it as they push any edit of the harness; the next generation keeps it
sed -i.bak 's/^(none yet: written by people, kept on every regeneration)$/- **Ship on Fridays never.** [review]/' "$M" && rm -f "$M.bak"
(cd "$WORK/org-sh/shop-web" && HOME="$WORK/home-sh" PATH="$PATH_SH" bash "$ROOT/bin/push.sh" "a rule of this repository" > "$WORK/map-rule-push.log" 2>&1) || fail "push.sh with the rule people wrote (see $WORK/map-rule-push.log)"
MAP_FAKE_NOTE=v2 map_run "$WORK/org-sh/shop-web" > "$WORK/map-2.log" 2>&1 || fail "map.sh second run (see $WORK/map-2.log)"
grep -q '^A shop\. v2$' "$M" && grep -q '^- \*\*Ship on Fridays never\.\*\* \[review\]$' "$M" && ! grep -q '^(none yet' "$M" || fail "map.sh did not regenerate and keep the rules people wrote: $(grep -n 'shop\.\|Fridays\|none yet' "$M" | tr '\n' '|')"
[ -z "$(git -C "$WORK/org-sh/shop-ai-core" status --porcelain)" ] || fail "map.sh second run left the harness uncommitted"
# a config.env of the checkout that is there and cannot be read stops map before it asks an agent CLI; planted: the old reader asks the default one
. "$ROOT/tests/unreadable.sh"
old_reader_copy "$ROOT" "$WORK/map-old-reader" || fail "no copy of the harness with the old reader"
map_dry() {  # map_dry <harness root>: map.sh of that harness over shop-web as a dry run, then a last line rc=<n>; the calls of the agent CLI are in $MAPLOG
  local out rc=0; : > "$MAPLOG"
  out="$(HOME="$WORK/home-sh" AI_CORE_HOME="$WORK/home-sh" PATH="$PATH_SH" MAP_FAKE_LOG="$MAPLOG" bash "$1/bin/map.sh" "$WORK/org-sh/shop-web" --dry-run 2>&1)" || rc=$?
  printf '%s\nrc=%s\n' "$out" "$rc"
}
map_stopped() {  # map_stopped <what map_dry printed>: yes where map failed, named config.env of shop-web once, and asked no agent CLI
  if [ "$(tail -n1 <<< "$1")" != rc=0 ] && [ "$(grep -acF -- "$WORK/org-sh/shop-web/.ai-core/config.env exists but cannot be read" <<< "$1")" = 1 ] && [ ! -s "$MAPLOG" ]; then echo yes; else echo no; fi
}
MAP_CONFIG="$WORK/org-sh/shop-web/.ai-core/config.env"
[ "$(map_stopped "$(map_dry "$ROOT")")" = no ] && [ -s "$MAPLOG" ] || fail "map.sh over a readable config.env did not ask the agent CLI"
make_unreadable "$MAP_CONFIG" || fail "the config.env of shop-web cannot be made unreadable"
[ "$(map_stopped "$(map_dry "$ROOT")")" = yes ] || fail "map.sh went on with a config.env it cannot read, or did not name it: $(map_dry "$ROOT" | tail -3 | tr '\n' '|')"
[ "$(map_stopped "$(map_dry "$WORK/map-old-reader")")" = no ] && [ -s "$MAPLOG" ] || fail "planted: map.sh with the old reader did not ask the default agent CLI, so the check cannot go red"
chmod 644 "$MAP_CONFIG"
mv "$MAP_CONFIG" "$WORK/map-config.real"; ln -s "$WORK/map-config.gone" "$MAP_CONFIG"
[ "$(map_stopped "$(map_dry "$ROOT")")" = yes ] || fail "map.sh took the template for a config.env that is a link to nothing: $(map_dry "$ROOT" | tail -3 | tr '\n' '|')"
rm "$MAP_CONFIG"; mv "$WORK/map-config.real" "$MAP_CONFIG"
[ "$(map_stopped "$(map_dry "$ROOT")")" = no ] && [ -s "$MAPLOG" ] || fail "map.sh does not ask the agent CLI again once config.env can be read"
cp "$M" "$WORK/map.before"
MAP_FAKE_BAD=1 map_run "$WORK/org-sh/shop-web" > "$WORK/map-bad.log" 2>&1 && fail "map.sh accepted an output that is not a map"
grep -aq "not the map's shape" "$WORK/map-bad.log" && cmp -s "$M" "$WORK/map.before" && [ -f "$WORK/org-sh/shop-web/.ai-core/map.rejected.md" ] || fail "map.sh: the refusal (see $WORK/map-bad.log)"
# what the tool says before the title and after the file drops out
MAP_FAKE_NOISE=1 map_run "$WORK/org-sh/shop-web" --dry-run > "$WORK/map-noise.log" 2>&1 || fail "map.sh with a remark before and a tally after the file (see $WORK/map-noise.log)"
grep -aq '^# shop-web — the map' "$WORK/map-noise.log" && ! grep -aqE 'Done reading|Grant write|tokens saved' "$WORK/map-noise.log" || fail "map.sh kept what the tool said around the file (see $WORK/map-noise.log)"
map_run "$WORK/org-sh/shop-web" --dry-run > "$WORK/map-dry.log" 2>&1 || fail "map.sh --dry-run (see $WORK/map-dry.log)"
grep -aq '^# shop-web — the map' "$WORK/map-dry.log" && cmp -s "$M" "$WORK/map.before" || fail "map.sh --dry-run wrote something or printed nothing"
# the session start, with a table whose probes always pass: the fake homes hold no team modes
printf 'claude\tmode\talways\t-\t-\ncodex\tmode\talways\t-\t-\n' > "$WORK/always.tsv"
# codex and agy write the map the same way, named by AI_CORE_MAP_TOOL for one machine; a tool map does not know is refused
AI_CORE_MAP_TOOL=codex map_run "$WORK/org-sh/shop-web" --dry-run > "$WORK/map-codex.log" 2>&1 || fail "map.sh with codex (see $WORK/map-codex.log)"
grep -aq '^# shop-web — the map' "$WORK/map-codex.log" && grep -q 'exec --skip-git-repo-check -s read-only' "$MAPLOG" || fail "map.sh did not run codex exec read-only or printed no map (see $WORK/map-codex.log)"
AI_CORE_MAP_TOOL=agy map_run "$WORK/org-sh/shop-web" --dry-run > "$WORK/map-agy.log" 2>&1 || fail "map.sh with agy (see $WORK/map-agy.log)"
grep -aq '^# shop-web — the map' "$WORK/map-agy.log" && grep -q -- '--print' "$MAPLOG" || fail "map.sh did not run agy --print or printed no map (see $WORK/map-agy.log)"
# One machine names its CLI and its model; the project's model goes only with the project's own CLI
map_model() { map_run "$WORK/org-sh/shop-web" --dry-run > "$WORK/map-model.log" 2>&1 || fail "map.sh with a model (see $WORK/map-model.log)"; }
C="$WORK/org-sh/shop-web/.ai-core/config.env"; cp "$C" "$WORK/map-config.bak"; printf 'MAP_MODEL="claude-sonnet-5"\n' >> "$C"
: > "$MAPLOG"; map_model
grep -q -- '--model claude-sonnet-5' "$MAPLOG" || fail "map.sh did not hand the project's model to the project's CLI: $(tail -c 200 "$MAPLOG")"
: > "$MAPLOG"; AI_CORE_MAP_TOOL=agy map_model
! grep -q 'claude-sonnet-5' "$MAPLOG" || fail "map.sh handed the project's model to the CLI this machine names: $(tail -c 200 "$MAPLOG")"
: > "$MAPLOG"; AI_CORE_MAP_TOOL=agy AI_CORE_MAP_MODEL=gemini-3.8-flash-high map_model
grep -q -- '--model gemini-3.8-flash-high' "$MAPLOG" && ! grep -q 'claude-sonnet-5' "$MAPLOG" || fail "map.sh did not hand this machine's model to this machine's CLI: $(tail -c 200 "$MAPLOG")"
mv -f "$WORK/map-config.bak" "$C"
# An agy that cannot run in this session is found before the map is asked for, and over SSH with the reason
: > "$MAPLOG"
MAP_FAKE_SIGNED_OUT=1 SSH_CONNECTION='192.0.2.1 50000 192.0.2.2 22' AI_CORE_MAP_TOOL=agy map_run "$WORK/org-sh/shop-web" --dry-run > "$WORK/map-agy-out.log" 2>&1 && fail "map.sh ran with an agy that is not signed in"
grep -aq 'agy models failed, so agy cannot write the map in this session: not signed in; over SSH agy keeps its token in a file, not in the desktop keychain' "$WORK/map-agy-out.log" && ! grep -q -- '--print' "$MAPLOG" || fail "map.sh did not stop before the map with the reason agy cannot run (see $WORK/map-agy-out.log)"
AI_CORE_MAP_TOOL=hermes map_run "$WORK/org-sh/shop-web" --dry-run > "$WORK/map-hermes.log" 2>&1 && fail "map.sh accepted a tool it does not know"
grep -aq 'map runs with claude, codex or agy' "$WORK/map-hermes.log" || fail "map.sh does not name the tools it runs with (see $WORK/map-hermes.log)"
(cd "$WORK/org-sh/shop-web" && HOME="$WORK/home-sh" PATH="$PATH_SH" AI_CORE_UPDATE_CHECK=never TEAM_MODES_FILE="$WORK/always.tsv" bash "$ROOT/bin/session-start.sh" > "$WORK/map-session.log" 2>&1) || fail "session-start.sh with a map (see $WORK/map-session.log): $(tail -n 3 "$WORK/map-session.log" | tr '\n' '|')"
grep -aq '^Map              : ✓ Generated from [0-9a-f]*, current$' "$WORK/map-session.log" || fail "session-start.sh does not name the map: $(grep -a '^Map' "$WORK/map-session.log")"
grep -aq '^GitHub status    : ✓ Authenticated as @' "$WORK/map-session.log" || fail "session-start.sh does not keep the GitHub sign-in line as it was: $(grep -a 'status    :' "$WORK/map-session.log")"
mkdir -p "$WORK/ghdown"; printf '#!/bin/sh\nexit 1\n' > "$WORK/ghdown/gh"; chmod +x "$WORK/ghdown/gh"
(cd "$WORK/org-sh/shop-web" && HOME="$WORK/home-sh" PATH="$WORK/ghdown:$PATH_SH" AI_CORE_UPDATE_CHECK=never TEAM_MODES_FILE="$WORK/always.tsv" bash "$ROOT/bin/session-start.sh" > "$WORK/map-session-down.log" 2>&1) || fail "session-start.sh with gh signed out (see $WORK/map-session-down.log)"
grep -aq '^GitHub status    : ✗ Not logged in / gh missing$' "$WORK/map-session-down.log" || fail "session-start.sh does not keep the GitHub sign-in line as it was when gh is signed out: $(grep -a 'status    :' "$WORK/map-session-down.log")"
echo x >> "$WORK/org-sh/shop-web/README.md"; git -C "$WORK/org-sh/shop-web" -c user.name=check -c user.email=check@localhost commit -qam 'A change #1'
(cd "$WORK/org-sh/shop-web" && HOME="$WORK/home-sh" PATH="$PATH_SH" AI_CORE_UPDATE_CHECK=never TEAM_MODES_FILE="$WORK/always.tsv" bash "$ROOT/bin/session-start.sh" --json > "$WORK/map-session.json" 2>/dev/null) || true
[ "$(jq -r '.map_behind' "$WORK/map-session.json")" = 1 ] || fail "session-start.sh --json does not count the commits behind the map: $(jq -c '{map_commit, map_behind}' "$WORK/map-session.json")"
# A map the code gives again word for word is confirmed: its header moves to the commit it was
# confirmed at, pushed, and the distance is gone; a second run at that commit leaves it alone.
H="$WORK/org-sh/shop-ai-core/repos/shop-web/AGENTS.md"
MAP_FAKE_NOTE=v3 map_run "$WORK/org-sh/shop-web" > "$WORK/map-own.log" 2>&1 || fail "map.sh writing its own map (see $WORK/map-own.log)"
echo y >> "$WORK/org-sh/shop-web/README.md"; git -C "$WORK/org-sh/shop-web" -c user.name=check -c user.email=check@localhost commit -qam 'A change the map does not see #3'
head="$(git -C "$WORK/org-sh/shop-web" rev-parse --short HEAD)"
MAP_FAKE_NOTE=v3 map_run "$WORK/org-sh/shop-web" > "$WORK/map-confirm.log" 2>&1 || fail "map.sh confirming the map (see $WORK/map-confirm.log)"
grep -aq "^--> Map confirmed at $head, its content unchanged: " "$WORK/map-confirm.log" && head -n1 "$H" | grep -q " from $head;" || fail "map.sh did not confirm the unchanged map at $head: $(grep -a '^--> Map' "$WORK/map-confirm.log"; head -n1 "$H")"
[ -z "$(git -C "$WORK/org-sh/shop-ai-core" status --porcelain)" ] && [ "$(git -C "$WORK/org-sh/shop-ai-core" rev-list --count '@{upstream}..HEAD')" = 0 ] || fail "map.sh did not push the confirmed map"
before="$(git -C "$WORK/org-sh/shop-ai-core" rev-parse HEAD)"
MAP_FAKE_NOTE=v3 map_run "$WORK/org-sh/shop-web" > "$WORK/map-again.log" 2>&1 || fail "map.sh a second time (see $WORK/map-again.log)"
grep -aq '^--> Map unchanged: ' "$WORK/map-again.log" && [ "$(git -C "$WORK/org-sh/shop-ai-core" rev-parse HEAD)" = "$before" ] || fail "map.sh wrote the map again at the commit it was confirmed at (see $WORK/map-again.log)"
(cd "$WORK/org-sh/shop-web" && HOME="$WORK/home-sh" PATH="$PATH_SH" AI_CORE_UPDATE_CHECK=never TEAM_MODES_FILE="$WORK/always.tsv" bash "$ROOT/bin/session-start.sh" --json > "$WORK/map-session-2.json" 2>/dev/null) || fail "session-start.sh after the confirmation"
[ "$(jq -r '.map_behind' "$WORK/map-session-2.json")" = 0 ] || fail "session-start.sh still counts commits behind a map confirmed at HEAD: $(jq -c '{map_commit, map_behind}' "$WORK/map-session-2.json")"
git -C "$WORK/author" pull -q --rebase 2>/dev/null || fail "the author clone could not take the maps"
# Another project of the same organisation: store-api gets store-ai-core
new_checkout "$WORK/org-sh/store-api" store-api
HOME="$WORK/home-sh" PATH="$PATH_SH" bash "$ROOT/bin/init.sh" "$WORK/org-sh/store-api" --no-doctor > "$WORK/layers-store.log" 2>&1 || fail "init.sh with a new project harness (see $WORK/layers-store.log)"
grep -aq 'created: example-org/store-ai-core, private, from the skeleton' "$WORK/layers-store.log" || fail "init.sh did not create store-ai-core"
[ -d "$GH_FAKE/github.com/example-org/store-ai-core.git" ] || fail "store-ai-core was not pushed"
# A harness repository that exists on GitHub but is empty, made by hand by whoever has the right
# to create it under that owner: the first init fills it from the skeleton and pushes
git init -q --bare "$GH_FAKE/github.com/example-org/blank-ai-core.git"
new_checkout "$WORK/org-sh/blank-web" blank-web
HOME="$WORK/home-sh" PATH="$PATH_SH" bash "$ROOT/bin/init.sh" "$WORK/org-sh/blank-web" --no-doctor > "$WORK/layers-empty.log" 2>&1 || fail "init.sh with an empty harness repository (see $WORK/layers-empty.log)"
grep -aq "filled: example-org/blank-ai-core, empty on GitHub, from the skeleton, at " "$WORK/layers-empty.log" || fail "init.sh did not say it filled the empty harness (see $WORK/layers-empty.log)"
grep -aq 'created:' "$WORK/layers-empty.log" && fail "init.sh created a harness that exists"
[ -f "$WORK/org-sh/blank-ai-core/ai-core.json" ] && [ -f "$WORK/org-sh/blank-ai-core/labels.tsv" ] && [ -f "$WORK/org-sh/blank-ai-core/.gitattributes" ] || fail "the filled harness lacks the skeleton"
[ "$(git -C "$GH_FAKE/github.com/example-org/blank-ai-core.git" rev-list --count HEAD 2>/dev/null)" = 1 ] || fail "init.sh did not push the filled harness to GitHub"
[ -z "$(git -C "$WORK/org-sh/blank-ai-core" status --porcelain)" ] || fail "the filled harness is not clean"
grep -q "^blank-ai-core " "$WORK/org-sh/blank-web/.ai-core/STAMP" || fail "the checkout was not assembled from the filled harness: $(tr '\n' '|' < "$WORK/org-sh/blank-web/.ai-core/STAMP")"
# The same repository cloned by hand before init ran: the clone has no commit and the origin has
# none either; a dry run says what would happen and writes nothing, the run fills and pushes
git init -q --bare "$GH_FAKE/github.com/example-org/hollow-ai-core.git"
new_checkout "$WORK/org-sh/hollow-web" hollow-web
git clone -q "$GH_FAKE/github.com/example-org/hollow-ai-core.git" "$WORK/org-sh/hollow-ai-core" 2>/dev/null
HOME="$WORK/home-sh" PATH="$PATH_SH" bash "$ROOT/bin/init.sh" "$WORK/org-sh/hollow-web" --no-doctor --dry-run > "$WORK/layers-hollow-dry.log" 2>&1 || fail "init.sh --dry-run with an empty clone of an empty harness repository (see $WORK/layers-hollow-dry.log)"
HOME="$WORK/home-sh" PATH="$PATH_SH" bash "$ROOT/bin/init.sh" "$WORK/org-sh/hollow-web" --no-doctor > "$WORK/layers-hollow.log" 2>&1 || fail "init.sh with an empty clone of an empty harness repository (see $WORK/layers-hollow.log)"
grep -aq "note: example-org/hollow-ai-core is empty here and on GitHub and would be filled from the skeleton (dry run: not written)" "$WORK/layers-hollow-dry.log" || fail "init.sh dry run does not announce the fill of the empty clone (see $WORK/layers-hollow-dry.log)"
grep -aq "filled: example-org/hollow-ai-core, empty on GitHub, from the skeleton, at " "$WORK/layers-hollow.log" || fail "init.sh did not fill the empty clone (see $WORK/layers-hollow.log)"
[ -f "$WORK/org-sh/hollow-ai-core/ai-core.json" ] && [ -f "$WORK/org-sh/hollow-ai-core/labels.tsv" ] || fail "the filled clone lacks the skeleton"
[ ! -e "$WORK/org-sh/hollow-ai-core/models.tsv" ] || fail "the filled clone pins a copy of the model table"
[ "$(git -C "$GH_FAKE/github.com/example-org/hollow-ai-core.git" rev-list --count HEAD 2>/dev/null)" = 1 ] || fail "init.sh did not push the filled clone to GitHub"
[ -z "$(git -C "$WORK/org-sh/hollow-ai-core" status --porcelain)" ] || fail "the filled clone is not clean"
grep -q "^hollow-ai-core " "$WORK/org-sh/hollow-web/.ai-core/STAMP" || fail "the checkout was not assembled from the filled clone: $(tr '\n' '|' < "$WORK/org-sh/hollow-web/.ai-core/STAMP")"
# extends: shop-ai-core now extends store-ai-core, so the chain is store first, then shop
printf '{ "setup-ai-core": ">=1.1.0", "extends": "example-org/store-ai-core" }\n' > "$WORK/author/ai-core.json"
git -C "$WORK/author" add -A; git -C "$WORK/author" -c user.name=check -c user.email=check@localhost commit -q -m extends; git -C "$WORK/author" push -q origin HEAD
HOME="$WORK/home-sh" PATH="$PATH_SH" bash "$ROOT/bin/init.sh" "$WORK/org-sh/shop-web" --no-doctor > "$WORK/layers-sh-3.log" 2>&1 || fail "init.sh with an extends chain (see $WORK/layers-sh-3.log)"
[ "$(sed -n 2p "$WORK/org-sh/shop-web/.ai-core/STAMP" | cut -d' ' -f1)" = store-ai-core ] && [ "$(sed -n 3p "$WORK/org-sh/shop-web/.ai-core/STAMP" | cut -d' ' -f1)" = shop-ai-core ] || fail "the extends chain is not base first in STAMP: $(tr '\n' '|' < "$WORK/org-sh/shop-web/.ai-core/STAMP")"
[ -d "$WORK/org-sh/store-ai-core" ] || fail "the base of the chain was not cloned"
# A harness that cannot be had stops init before it writes: nocreate-org may not create repositories
new_checkout "$WORK/org-sh/nocreate-web" nocreate-web nocreate-org
HOME="$WORK/home-sh" PATH="$PATH_SH" bash "$ROOT/bin/init.sh" "$WORK/org-sh/nocreate-web" --no-doctor > "$WORK/layers-nocreate-sh.log" 2>&1 && fail "init.sh assembled the generic harness although the project harness could not be had"
grep -aq 'could not create nocreate-org/nocreate-ai-core' "$WORK/layers-nocreate-sh.log" && grep -aq 'nothing was written' "$WORK/layers-nocreate-sh.log" || fail "init.sh does not say why it stopped (see $WORK/layers-nocreate-sh.log)"
[ ! -e "$WORK/org-sh/nocreate-web/.ai-core" ] || fail "init.sh wrote into the checkout although it stopped"
# A harness checkout is refused, and a project folder gets the layers its repositories share
new_checkout "$WORK/harness-checkout" shop-ai-core
HOME="$WORK/home-sh" PATH="$PATH_SH" bash "$ROOT/bin/init.sh" "$WORK/harness-checkout" --no-doctor > "$WORK/layers-refused.log" 2>&1 && fail "init.sh accepted a harness repository"
grep -aq 'harness repository' "$WORK/layers-refused.log" || fail "init.sh did not say why the harness repository is refused"
mkdir -p "$WORK/folder/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$WORK/folder/.ai-core/config.env"
new_checkout "$WORK/folder/shop-web" shop-web; new_checkout "$WORK/folder/store-api" store-api
carry_harness "$WORK/folder/shop-web" "$WORK/folder/store-api"
git clone -q "$GH_FAKE/github.com/example-org/shop-ai-core.git" "$WORK/home-sh/.shop-ai-core" 2>/dev/null   # where an earlier version kept it
HOME="$WORK/home-sh" PATH="$PATH_SH" bash "$ROOT/bin/init.sh" "$WORK/folder" --no-doctor > "$WORK/layers-folder.log" 2>&1 || fail "init.sh on a project folder with layers (see $WORK/layers-folder.log)"
[ "$(tr '\n' '|' < "$WORK/folder/.ai-core/STAMP" | sed 's/ [0-9a-f-]*|/|/g')" = "setup-ai-core|store-ai-core|" ] || fail "the project folder did not get the layer its repositories share: $(tr '\n' '|' < "$WORK/folder/.ai-core/STAMP")"
grep -aq 'moved: example-org/shop-ai-core from ' "$WORK/layers-folder.log" || fail "init.sh did not move the old clone beside the repositories (see $WORK/layers-folder.log)"
[ ! -e "$WORK/home-sh/.shop-ai-core" ] && [ -d "$WORK/folder/shop-ai-core/.git" ] && [ -d "$WORK/folder/store-ai-core/.git" ] || fail "the folder does not hold both harness clones"
grep -qE '^\| `(shop|store)-ai-core`' "$WORK/folder/AGENTS.md" && fail "the folder's AGENTS.md lists a harness clone as a repository"
grep -q '^| `shop-web` |' "$WORK/folder/AGENTS.md" && grep -q '^| `store-api` |' "$WORK/folder/AGENTS.md" || fail "the folder's AGENTS.md does not list its repositories"
git -C "$WORK/folder/shop-ai-core" ls-files -z | (cd "$WORK/folder/shop-ai-core" && xargs -0 rm -f)   # every tracked file gone, the history there: an interrupted move somebody cleaned up by hand
HOME="$WORK/home-sh" PATH="$PATH_SH" bash "$ROOT/bin/init.sh" "$WORK/folder" --no-doctor > "$WORK/layers-folder-2.log" 2>&1 || fail "init.sh on the folder with a harness clone that lost its files (see $WORK/layers-folder-2.log)"
grep -aq 'restored: the files of example-org/shop-ai-core at ' "$WORK/layers-folder-2.log" || fail "init.sh did not restore the files of the harness clone (see $WORK/layers-folder-2.log)"
[ -z "$(git -C "$WORK/folder/shop-ai-core" status --porcelain)" ] || fail "the harness clone is not whole after the restore: $(git -C "$WORK/folder/shop-ai-core" status --porcelain | tr '\n' '|')"
# map --all: every repository under the folder, the harness clones excepted, one push, then init --all
map_run --all "$WORK/folder" > "$WORK/map-all.log" 2>&1 || fail "map.sh --all (see $WORK/map-all.log)"
grep -aq '^==> map --all: 2 map(s) were written$' "$WORK/map-all.log" || fail "map.sh --all did not write the two maps: $(grep -a 'map --all' "$WORK/map-all.log")"
for r in shop-web store-api; do
  h="$WORK/folder/${r%%-*}-ai-core/repos/$r/AGENTS.md"
  head -n1 "$h" | grep -q 'ai-core map: generated' && head -n1 "$WORK/folder/$r/AGENTS.md" | grep -q 'ai-core map: generated' || fail "map.sh --all: $r has no map in the harness or the checkout"
  [ -z "$(git -C "$WORK/folder/${r%%-*}-ai-core" status --porcelain)" ] || fail "map.sh --all did not push ${r%%-*}-ai-core"
done
# The binding rules in a project folder: its AGENTS.md imports them; a checkout whose rules are the folder's names them without the @, one whose harness adds rules imports its own
binding_ok() {  # binding_ok
  grep -q '^- The engineering rules, .*: @\.ai-core/rules/rules\.md$' "$WORK/folder/AGENTS.md" && grep -q '^- When a skill or a tool is used: @\.ai-core/rules/skills\.md$' "$WORK/folder/AGENTS.md" && grep -q '^| `shop-web` |' "$WORK/folder/AGENTS.md" || fail "the folder's AGENTS.md does not import the rules: $(sed -n 4,11p "$WORK/folder/AGENTS.md" | tr '\n' '|')"
  grep -q '@\.ai-core/rules/rules\.md' "$WORK/folder/store-api/AGENTS.md" && fail "store-api has the folder's rules and imports them a second time"
  grep -q "^- The engineering rules, .*: \`.ai-core/rules/rules.md\`, the same as the project folder's, which its AGENTS.md loads$" "$WORK/folder/store-api/AGENTS.md" || fail "store-api's map does not name the folder's rules: $(sed -n 4,9p "$WORK/folder/store-api/AGENTS.md" | tr '\n' '|')"
  grep -q '^- The engineering rules, .*: @\.ai-core/rules/rules\.md$' "$WORK/folder/shop-web/AGENTS.md" || fail "shop-web, whose harness adds rules the folder lacks, does not import its own: $(sed -n 4,9p "$WORK/folder/shop-web/AGENTS.md" | tr '\n' '|')"
}
binding_ok
# An origin that moved to a host other than the configured forge's must not make init take the harness out of a checkout it assembled
tree_digest() {  # tree_digest <checkout or folder>: every file outside a .git, with its content
  (cd "$1" && find . -name .git -prune -o -type f -print0 | sort -z | xargs -0 cksum)
}
mkdir -p "$WORK/moved"
cp -R "$WORK/org-sh/shop-web" "$WORK/moved/shop-web"
grep -q '^shop-ai-core ' "$WORK/moved/shop-web/.ai-core/STAMP" || fail "the checkout to move does not carry its layer in STAMP"
git -C "$WORK/moved/shop-web" remote set-url origin https://forge.example.test/example-org/shop-web.git
before="$(tree_digest "$WORK/moved/shop-web")"
for dry in "" --dry-run; do
  HOME="$WORK/home-sh" PATH="$PATH_SH" bash "$ROOT/bin/init.sh" "$WORK/moved/shop-web" --no-doctor $dry > "$WORK/moved-refused.log" 2>&1 && fail "init.sh${dry:+ $dry} went on with an origin on another forge than the configured one (see $WORK/moved-refused.log)"
  grep -aq 'is on forge.example.test, which is not the host of the configured forge (GitHub)' "$WORK/moved-refused.log" || fail "init.sh${dry:+ $dry} does not name the origin's host and the configured forge (see $WORK/moved-refused.log)"
  grep -aq 'shop-ai-core' "$WORK/moved-refused.log" && grep -aq 'FORGE, TRACKER and, for Forgejo, FORGEJO_URL and FORGEJO_TOKEN_COMMAND' "$WORK/moved-refused.log" || fail "init.sh${dry:+ $dry} does not name the harness or the settings to set (see $WORK/moved-refused.log)"
  grep -aq 'Nothing was written' "$WORK/moved-refused.log" && ! grep -aq '^  removed' "$WORK/moved-refused.log" || fail "init.sh${dry:+ $dry} went on to remove files (see $WORK/moved-refused.log)"
  [ "$(tree_digest "$WORK/moved/shop-web")" = "$before" ] || fail "init.sh${dry:+ $dry} changed the checkout it refused"
done
# a worktree not yet initialized has no .ai-core of its own: the STAMP of its main checkout names the layer
git -C "$WORK/moved/shop-web" worktree add -q -b issue-1-moved "$WORK/moved/shop-web-issue-1" 2>/dev/null || fail "no worktree for the moved checkout"
HOME="$WORK/home-sh" PATH="$PATH_SH" bash "$ROOT/bin/init.sh" "$WORK/moved/shop-web-issue-1" --no-doctor > "$WORK/moved-worktree.log" 2>&1 && fail "init.sh went on in a new worktree of a checkout whose origin moved (see $WORK/moved-worktree.log)"
grep -aq 'This checkout was assembled from store-ai-core shop-ai-core,' "$WORK/moved-worktree.log" && [ ! -e "$WORK/moved/shop-web-issue-1/.ai-core" ] || fail "init.sh did not refuse the new worktree by its main checkout's layer, or wrote into it (see $WORK/moved-worktree.log)"
# innocent cases: a checkout without an origin, one that never had a layer, one whose origin is on the configured forge
cp -R "$WORK/org-sh/shop-web" "$WORK/moved/no-origin"; git -C "$WORK/moved/no-origin" remote remove origin
HOME="$WORK/home-sh" PATH="$PATH_SH" bash "$ROOT/bin/init.sh" "$WORK/moved/no-origin" --no-doctor > "$WORK/moved-no-origin.log" 2>&1 || fail "init.sh refused a checkout without an origin (see $WORK/moved-no-origin.log)"
grep -aq '^--> No project harness: this checkout has no GitHub origin; the generic harness only$' "$WORK/moved-no-origin.log" || fail "init.sh does not fall back to the generic harness without an origin (see $WORK/moved-no-origin.log)"
git init -q "$WORK/moved/never"; git -C "$WORK/moved/never" remote add origin https://forge.example.test/example-org/never-web.git
HOME="$WORK/home-sh" PATH="$PATH_SH" bash "$ROOT/bin/init.sh" "$WORK/moved/never" --no-doctor > "$WORK/moved-never.log" 2>&1 || fail "init.sh refused a checkout that never had a project harness (see $WORK/moved-never.log)"
grep -aq '^--> No project harness: this checkout has no GitHub origin; the generic harness only$' "$WORK/moved-never.log" || fail "init.sh does not fall back to the generic harness for a checkout that never had a layer (see $WORK/moved-never.log)"
HOME="$WORK/home-sh" PATH="$PATH_SH" bash "$ROOT/bin/init.sh" "$WORK/org-sh/shop-web" --no-doctor > "$WORK/moved-same-forge.log" 2>&1 || fail "init.sh refused a checkout whose origin is on the configured forge (see $WORK/moved-same-forge.log)"
# a checkout configured for the forge its origin moved to is judged by its own settings, wherever init is started
cp -R "$WORK/org-sh/shop-web" "$WORK/moved/configured"
git -C "$WORK/moved/configured" remote set-url origin https://forge.example.test/example-org/shop-web.git
printf 'FORGE="forgejo"\nFORGEJO_URL="https://forge.example.test"\n' >> "$WORK/moved/configured/.ai-core/config.env"
inside=0; (cd "$WORK/moved/configured" && HOME="$WORK/home-sh" PATH="$PATH_SH" bash "$ROOT/bin/init.sh" "$WORK/moved/configured" --no-doctor --dry-run) > "$WORK/moved-configured-inside.log" 2>&1 || inside=$?
outside=0; (cd "$WORK" && HOME="$WORK/home-sh" PATH="$PATH_SH" bash "$ROOT/bin/init.sh" "$WORK/moved/configured" --no-doctor --dry-run) > "$WORK/moved-configured-outside.log" 2>&1 || outside=$?
grep -aq 'which is not the host of the configured forge' "$WORK/moved-configured-outside.log" && fail "init.sh started outside a checkout configured for Forgejo judged it by the settings of the directory it was started in (see $WORK/moved-configured-outside.log)"
[ "$outside" = "$inside" ] && cmp -s "$WORK/moved-configured-inside.log" "$WORK/moved-configured-outside.log" || fail "init.sh gives another result started outside the checkout than inside it (exit $outside against $inside; see $WORK/moved-configured-outside.log)"
# a project folder whose repositories moved: init --all inits the folder first, and it would take the shared layer out of it
cp -R "$WORK/folder" "$WORK/moved/folder"
grep -q '^store-ai-core ' "$WORK/moved/folder/.ai-core/STAMP" || fail "the folder to move does not carry its layer in STAMP"
for r in shop-web store-api; do git -C "$WORK/moved/folder/$r" remote set-url origin "https://forge.example.test/example-org/$r.git"; done
before="$(tree_digest "$WORK/moved/folder")"
HOME="$WORK/home-sh" PATH="$PATH_SH" bash "$ROOT/bin/init.sh" "$WORK/moved/folder" --no-doctor > "$WORK/moved-folder.log" 2>&1 && fail "init.sh went on in a project folder whose repositories moved to another forge (see $WORK/moved-folder.log)"
grep -aq 'This project folder was assembled from store-ai-core, and init would remove everything' "$WORK/moved-folder.log" || fail "init.sh does not say that the project folder would lose its harness (see $WORK/moved-folder.log)"
[ "$(tree_digest "$WORK/moved/folder")" = "$before" ] || fail "init.sh changed the project folder it refused"
rm -rf "$WORK/moved"
section "a new project harness is committed under the identity of the person who runs init, never a made-up one"
F="$WORK/fill"; mkdir -p "$F"
printf '[user]\n\tname = Ada Lovelace\n\temail = person@example.com\n' > "$F/identity"
printf '[user]\n\tuseConfigOnly = true\n' > "$F/none"
(
  unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
  export GIT_CONFIG_NOSYSTEM=1
  . "$ROOT/lib/layers.sh"
  git init -q "$F/mine"
  GIT_CONFIG_GLOBAL="$F/identity" fill_layer "$F/mine" "$ROOT" || exit 11
  [ "$(git -C "$F/mine" log -1 --format='%ae %ce')" = 'person@example.com person@example.com' ] || exit 12
  git init -q "$F/nobody"
  if GIT_CONFIG_GLOBAL="$F/none" fill_layer "$F/nobody" "$ROOT" 2>/dev/null; then exit 13; fi
  if git -C "$F/nobody" rev-parse -q --verify HEAD >/dev/null; then exit 14; fi
  # the create path says what is missing and creates nothing, instead of blaming GitHub
  if out="$(HOME="$F/home" PATH="$PATH_SH" GIT_CONFIG_GLOBAL="$F/none" ensure_layer example-org/nobody-ai-core "$ROOT" "$F/folder" create 2>&1)"; then exit 15; fi
  case "$out" in *'example-org/nobody-ai-core is not created: git holds no identity to commit it under'*) ;; *) exit 16 ;; esac
  case "$out" in *'gh is not logged in'*) exit 17 ;; esac
  if [ -e "$F/folder/nobody-ai-core" ]; then exit 18; fi
) || fail "a new project harness: not committed under the configured identity, committed where git holds none, or not refused by name where git holds none (exit $?)"
echo "  created, cloned, an empty one on GitHub filled from the skeleton (cloned by init or by hand), moved from the home directory, an interrupted move completed, lost files restored, assembled; extends base first; a harness that cannot be had stops init; a harness checkout refused; the folder shares the base and its map skips the clones; maps written by the agent CLI, pushed and in the checkouts, people's rules kept, a bad output refused, --all over the folder"

section "a repository's config.env is laid over its layer's key by key; every other file of repos/<repo>/ still replaces the whole file"
LAY="$WORK/lay"; LAY_RAN="$WORK/lay-ran"; mkdir -p "$LAY" "$LAY_RAN" "$WORK/home-lay"
make_layer() {  # make_layer <name> [name of the layer it extends]: the project harness <name>-ai-core on the stand-in GitHub, and its author clone; the skeleton's .gitattributes makes every file LF, so LAYER_KEEPS_CRLF=1 leaves it out
  git init -q --bare "$GH_FAKE/github.com/example-org/$1-ai-core.git"
  git clone -q "$GH_FAKE/github.com/example-org/$1-ai-core.git" "$LAY/author-$1" 2>/dev/null
  [ -n "${LAYER_KEEPS_CRLF:-}" ] || cp "$ROOT/skeleton/.gitattributes" "$LAY/author-$1/"
  if [ -n "${2:-}" ]; then printf '{ "setup-ai-core": ">=1.1.0", "extends": "example-org/%s-ai-core" }\n' "$2" > "$LAY/author-$1/ai-core.json"
  else printf '{ "setup-ai-core": ">=1.1.0" }\n' > "$LAY/author-$1/ai-core.json"; fi
  publish_layer "$1" "the harness"
}
publish_layer() {  # publish_layer <name> <message>: what the author clone holds goes to the stand-in GitHub, where the next init pulls it
  git -C "$LAY/author-$1" add -A
  git -C "$LAY/author-$1" -c user.name=check -c user.email=check@localhost commit -q --allow-empty -m "$2"
  git -C "$LAY/author-$1" push -q origin HEAD 2>/dev/null || fail "could not publish $1-ai-core"
}
lay_init() {  # lay_init <checkout> <log name> [init option...]: init as a person runs it, its log in $WORK/<log name>.log
  local checkout="$1" log="$WORK/$2.log"; shift 2
  HOME="$WORK/home-lay" PATH="$PATH_SH" bash "${INIT_ROOT:-$ROOT}/bin/init.sh" "$checkout" --no-doctor "$@" > "$log" 2>&1 || fail "init.sh on $checkout (see $log)"
}
read_node() {  # read_node <file> <key>: what lib/status-live.mjs reads for the key
  node --input-type=module -e 'const { configValue } = await import(process.argv[1]); console.log(configValue(process.argv[2], process.argv[3]));' "$ROOT/lib/status-live.mjs" "$1" "$2"
}
reads_as() {  # reads_as <file> <other file> <key>: the readers of config.env, Bash and Node, give the key the same value in both files
  [ "$(config_value_in_file "$1" "$3" unset)" = "$(config_value_in_file "$2" "$3" unset)" ] && [ "$(read_node "$1" "$3")" = "$(read_node "$2" "$3")" ]
}
mutant_root() {  # mutant_root <sed expression>: a copy of the tree with one planted defect in bin/init.sh, in $WORK/mutant; prints its path
  rm -rf "$WORK/mutant"; mkdir -p "$WORK/mutant"
  cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/templates" "$ROOT/skeleton" "$ROOT/rules" "$ROOT/skills" "$ROOT/auto-mode.tsv" "$ROOT/VERSION" "$WORK/mutant/"
  sed -i.bak "$1" "$WORK/mutant/bin/init.sh"
  cmp -s "$ROOT/bin/init.sh" "$WORK/mutant/bin/init.sh" && fail "the planted defect changed nothing in bin/init.sh: $1"
  printf '%s' "$WORK/mutant"
}
printf '#!/bin/sh\ntouch "%s/reader"\n' "$LAY_RAN" > "$WORK/lay-reader.sh"; chmod +x "$WORK/lay-reader.sh"

# The layer: AGENTS names one agent, so a checkout that lost the key serves every pointer file
make_layer lay
LA="$LAY/author-lay"
cat > "$LA/config.env" <<CONF
AGENTS="cursor"
UPDATE_CHECK="never"
CI_GATE="none"
LIVE_TAGS="prod=deploy/prod/* test=deploy/test/*"
LIVE_RELEASE_COMMAND="$WORK/lay-reader.sh"
USAGE_STOP_AT="90"
CONF
printf 'plan\tmechanical\tclaude-sonnet-5-5\tmedium\tno\n' > "$LA/models.tsv"
mkdir -p "$LA/repos/lay-web/.ai-core"
printf 'LIVE_TAGS="prod=landed"\n' > "$LA/repos/lay-web/.ai-core/config.env"
printf 'plan\tmechanical\tclaude-sonnet-5-5\thigh\tno\n' > "$LA/repos/lay-web/.ai-core/models.tsv"
printf 'the layer\n' > "$LA/repos/lay-web/notes.txt"; printf 'the layer\n' > "$LA/repos/lay-web/kept.txt"
publish_layer lay "the layer"
new_checkout "$LAY/lay-web" lay-web; new_checkout "$LAY/lay-plain" lay-plain
lay_init "$LAY/lay-web" lay-web-1; lay_init "$LAY/lay-plain" lay-plain-1
inherits_layer() {  # inherits_layer <checkout> <the LIVE_TAGS it declares>: every key of the layer's config.env as the layer has it but LIVE_TAGS, and the agent files the inherited AGENTS selects
  local c="$1" key
  for key in AGENTS UPDATE_CHECK CI_GATE LIVE_RELEASE_COMMAND USAGE_STOP_AT; do
    [ "$(config_value_in_file "$c/.ai-core/config.env" "$key" unset)" = "$(config_value_in_file "$LA/config.env" "$key" unset)" ] || return 1
  done
  [ "$(config_value_in_file "$c/.ai-core/config.env" LIVE_TAGS unset)" = "$2" ] && [ "$(read_node "$c/.ai-core/config.env" LIVE_TAGS)" = "$2" ] && [ "$(cd "$c" && config_file_value LIVE_TAGS unset)" = "$2" ] || return 1
  [ -e "$c/.cursorrules" ] && [ ! -e "$c/.windsurfrules" ]
}
is_layer_config() {  # is_layer_config <checkout>: its config.env is the layer's, byte for byte
  cmp -s "$LA/config.env" "$1/.ai-core/config.env"
}
is_layer_config "$LAY/lay-plain" || fail "a repository without a config.env of its own did not get the layer's, byte for byte: $(cat "$LAY/lay-plain/.ai-core/config.env")"
inherits_layer "$LAY/lay-web" "prod=landed" || fail "a repository whose config.env holds only LIVE_TAGS lost keys of its layer: $(cat "$LAY/lay-web/.ai-core/config.env")"
[ "$(grep -c '^LIVE_TAGS' "$LAY/lay-web/.ai-core/config.env")" = 1 ] || fail "the layer's LIVE_TAGS stands beside the repository's: $(cat "$LAY/lay-web/.ai-core/config.env")"
grep -qx '.ai-core/config.env' "$LAY/lay-web/.ai-core/DEPLOYED" && ! grep -qx '.ai-core/config.env' "$LAY/lay-plain/.ai-core/DEPLOYED" || fail "DEPLOYED does not record the repository's config.env, or records the layer's alone: $(tr '\n' ' ' < "$LAY/lay-web/.ai-core/DEPLOYED")|$(tr '\n' ' ' < "$LAY/lay-plain/.ai-core/DEPLOYED")"
cmp -s "$LA/repos/lay-web/.ai-core/models.tsv" "$LAY/lay-web/.ai-core/models.tsv" && cmp -s "$LA/repos/lay-web/notes.txt" "$LAY/lay-web/notes.txt" || fail "another file of repos/lay-web/ was not applied whole"
# innocent: a second run with nothing changed writes nothing, and the bytes stay
before="$(cksum < "$LAY/lay-web/.ai-core/config.env")"
lay_init "$LAY/lay-web" lay-web-2
[ "$(cksum < "$LAY/lay-web/.ai-core/config.env")" = "$before" ] && ! grep -aE '^  (created|refreshed) .*\.ai-core/config\.env' "$WORK/lay-web-2.log" || fail "a second init changed the config.env it had laid (see $WORK/lay-web-2.log)"
# the reader a config.env names and a shell expression in it are copied and read, never run
printf 'LIVE_TAGS="prod=command test=command"\nSHELL_EXPRESSION="$(touch %s/expression) `touch %s/backticks`"\n' "$LAY_RAN" "$LAY_RAN" > "$LA/repos/lay-web/.ai-core/config.env"
printf 'INHERITED_EXPRESSION="$(touch %s/inherited)"\n' "$LAY_RAN" >> "$LA/config.env"
publish_layer lay "the project reads a command"
lay_init "$LAY/lay-web" lay-web-3
[ "$(config_value_in_file "$LAY/lay-web/.ai-core/config.env" LIVE_TAGS unset)" = "prod=command test=command" ] && [ "$(cd "$LAY/lay-web" && config_file_value LIVE_RELEASE_COMMAND unset)" = "$WORK/lay-reader.sh" ] || fail "LIVE_TAGS and the inherited LIVE_RELEASE_COMMAND did not both survive: $(cat "$LAY/lay-web/.ai-core/config.env")"
grep -qxF "SHELL_EXPRESSION=\"\$(touch $LAY_RAN/expression) \`touch $LAY_RAN/backticks\`\"" "$LAY/lay-web/.ai-core/config.env" && grep -qxF "INHERITED_EXPRESSION=\"\$(touch $LAY_RAN/inherited)\"" "$LAY/lay-web/.ai-core/config.env" || fail "a shell expression of a config.env was not copied as it stands: $(cat "$LAY/lay-web/.ai-core/config.env")"
[ -z "$(ls -A "$LAY_RAN")" ] || fail "init ran what a config.env names: $(ls "$LAY_RAN" | tr '\n' ' ')"
printf 'LIVE_TAGS="prod=landed"\n' > "$LA/repos/lay-web/.ai-core/config.env"
sed -i.bak '/^INHERITED_EXPRESSION/d' "$LA/config.env"; rm -f "$LA/config.env.bak"
publish_layer lay "the project reads no command"

# The planted defect, a whole-file replacement, goes red for the repository that has its own file and
# stays green for the one that has none
planted="$(mutant_root 's|lay_config "\$CONFIG_BASE" "\$CONFIG_OVERRIDE" "\$TMP/config.env"|cp -f "$CONFIG_OVERRIDE" "$TMP/config.env"|')"
new_checkout "$LAY/mutant-web" lay-web; new_checkout "$LAY/mutant-plain" lay-plain
INIT_ROOT="$planted" lay_init "$LAY/mutant-web" mutant-web; INIT_ROOT="$planted" lay_init "$LAY/mutant-plain" mutant-plain
inherits_layer "$LAY/mutant-web" "prod=landed" && fail "planted: replacing the whole file still gave the repository every key of its layer"
is_layer_config "$LAY/mutant-plain" || fail "planted: replacing the whole file changed the config.env of a repository that has no file of its own"

# A file of comments, an empty one, and one that sets two keys
printf '# every key of the layer, nothing of its own\n\n' > "$LA/repos/lay-web/.ai-core/config.env"
publish_layer lay "a comment only"; lay_init "$LAY/lay-web" lay-web-5
is_layer_config "$LAY/lay-web" || fail "an override of comments only changed the layer's config.env: $(cat "$LAY/lay-web/.ai-core/config.env")"
: > "$LA/repos/lay-web/.ai-core/config.env"
publish_layer lay "an empty file"; lay_init "$LAY/lay-web" lay-web-6
is_layer_config "$LAY/lay-web" || fail "an empty override changed the layer's config.env: $(cat "$LAY/lay-web/.ai-core/config.env")"
# An override in UTF-16 assigns no key that a reader sees, so it gives the layer's file
printf '\377\376L\000I\000V\000E\000_\000T\000A\000G\000S\000=\000x\000\n\000C\000I\000_\000G\000A\000T\000E\000=\000g\000\n\000' > "$LA/repos/lay-web/.ai-core/config.env"
publish_layer lay "a file in UTF-16"; lay_init "$LAY/lay-web" lay-web-utf16
is_layer_config "$LAY/lay-web" || fail "an override in UTF-16, which no reader of config.env can read, did not give the layer's config.env: $(cat -v "$LAY/lay-web/.ai-core/config.env")"
planted="$(mutant_root 's|done < <(grep -E "\$assignment" "\$override")|done < "$override"|')"
new_checkout "$LAY/mutant-utf16-web" lay-web
if HOME="$WORK/home-lay" PATH="$PATH_SH" bash "$planted/bin/init.sh" "$LAY/mutant-utf16-web" --no-doctor > "$WORK/mutant-utf16.log" 2>&1 && is_layer_config "$LAY/mutant-utf16-web"; then
  fail "planted: keys taken with read, which drops the NUL bytes of a file in UTF-16, went unseen"
fi
printf 'LIVE_TAGS="prod=landed"\nCI_GATE="gate"\n' > "$LA/repos/lay-web/.ai-core/config.env"
publish_layer lay "two keys"; lay_init "$LAY/lay-web" lay-web-7
[ "$(config_value_in_file "$LAY/lay-web/.ai-core/config.env" CI_GATE unset)" = gate ] && [ "$(config_value_in_file "$LAY/lay-web/.ai-core/config.env" LIVE_TAGS unset)" = "prod=landed" ] && [ "$(config_value_in_file "$LAY/lay-web/.ai-core/config.env" UPDATE_CHECK unset)" = never ] || fail "the two keys of the override, or the layer's others, are wrong: $(cat "$LAY/lay-web/.ai-core/config.env")"
is_layer_config "$LAY/lay-plain" || fail "one repository's override reached a repository that has none"

# A key the layer adds later reaches every repository at the next init; one it changes or drops follows it
printf 'ADDED_LATER="yes"\n' >> "$LA/config.env"
sed -i.bak -e 's/^UPDATE_CHECK=.*/UPDATE_CHECK="session-start"/' -e '/^USAGE_STOP_AT/d' "$LA/config.env"; rm -f "$LA/config.env.bak"
publish_layer lay "the layer moves"; lay_init "$LAY/lay-web" lay-web-8; lay_init "$LAY/lay-plain" lay-plain-8
for c in lay-web lay-plain; do
  [ "$(config_value_in_file "$LAY/$c/.ai-core/config.env" ADDED_LATER unset)" = yes ] || fail "$c: a key the layer added did not arrive: $(cat "$LAY/$c/.ai-core/config.env")"
  [ "$(config_value_in_file "$LAY/$c/.ai-core/config.env" UPDATE_CHECK unset)" = session-start ] || fail "$c: a key the layer changed did not follow"
  [ "$(config_value_in_file "$LAY/$c/.ai-core/config.env" USAGE_STOP_AT unset)" = unset ] || fail "$c: a key the layer dropped stayed from the file before"
done
[ "$(config_value_in_file "$LAY/lay-web/.ai-core/config.env" CI_GATE unset)" = gate ] && is_layer_config "$LAY/lay-plain" || fail "the layer's move reached the override's key, or missed the repository without an override"
# an assignment taken out of the override gives the layer's value back
printf 'LIVE_TAGS="prod=landed"\n' > "$LA/repos/lay-web/.ai-core/config.env"
publish_layer lay "one key less"; lay_init "$LAY/lay-web" lay-web-9
[ "$(config_value_in_file "$LAY/lay-web/.ai-core/config.env" CI_GATE unset)" = none ] && [ "$(config_value_in_file "$LAY/lay-web/.ai-core/config.env" LIVE_TAGS unset)" = "prod=landed" ] || fail "an assignment taken out of the override did not give the layer's back: $(cat "$LAY/lay-web/.ai-core/config.env")"

# --dry-run moves nothing and reports the action: before a fresh write, and before an update
new_checkout "$LAY/fresh-web" lay-web
lay_init "$LAY/fresh-web" fresh-dry --dry-run
[ ! -e "$LAY/fresh-web/.ai-core" ] && grep -aqE '^  created .*\.ai-core/config\.env' "$WORK/fresh-dry.log" || fail "a dry run before a fresh write wrote, or did not report the config.env (see $WORK/fresh-dry.log)"
planted="$(mutant_root 's|put "\$TMP/config.env" .ai-core/config.env managed;|mkdir -p "$TARGET/.ai-core"; cp -f "$TMP/config.env" "$TARGET/.ai-core/config.env";|')"
new_checkout "$LAY/mutant-dry-web" lay-web
INIT_ROOT="$planted" lay_init "$LAY/mutant-dry-web" mutant-dry --dry-run
[ -e "$LAY/mutant-dry-web/.ai-core/config.env" ] || fail "planted: a dry run that writes the config.env left no trace for the check to see"
lay_init "$LAY/fresh-web" fresh-1
printf 'DRY_PROBE="1"\n' >> "$LA/config.env"; publish_layer lay "a key to see in a dry run"
cp "$LAY/fresh-web/.ai-core/config.env" "$WORK/fresh-config-before"; before="$(tree_digest "$LAY/fresh-web")"; state="$(git -C "$LAY/fresh-web" status --porcelain)"
lay_init "$LAY/fresh-web" fresh-dry-2 --dry-run
cmp -s "$WORK/fresh-config-before" "$LAY/fresh-web/.ai-core/config.env" && [ "$(tree_digest "$LAY/fresh-web")" = "$before" ] && [ "$(git -C "$LAY/fresh-web" status --porcelain)" = "$state" ] && grep -aqE '^  refreshed .*\.ai-core/config\.env' "$WORK/fresh-dry-2.log" || fail "a dry run before an update changed the checkout, or did not report the config.env (see $WORK/fresh-dry-2.log)"
# a tracked config.env is left alone and said so, with an override of the repository and without one: the layer's file and the merge stay unwritten
make_tracked() {  # make_tracked <dir> <repository>: a checkout that commits its own config.env and kept.txt
  new_checkout "$1" "$2"; mkdir -p "$1/.ai-core"
  printf 'TRACKED_OWN="yes"\n' > "$1/.ai-core/config.env"; printf 'mine\n' > "$1/kept.txt"
  git -C "$1" add -f .ai-core/config.env kept.txt; git -C "$1" commit -q -m "its own files"
}
make_tracked "$LAY/tracked-web" lay-web; make_tracked "$LAY/tracked-plain" lay-plain
lay_init "$LAY/tracked-web" tracked-web; lay_init "$LAY/tracked-plain" tracked-plain
[ "$(cat "$LAY/tracked-web/.ai-core/config.env")" = 'TRACKED_OWN="yes"' ] && git -C "$LAY/tracked-web" diff --quiet && grep -aqE '^  tracked .*\.ai-core/config\.env' "$WORK/tracked-web.log" || fail "a tracked config.env of a repository with an override was written over, or not reported tracked (see $WORK/tracked-web.log)"
[ "$(cat "$LAY/tracked-web/kept.txt")" = mine ] && grep -aqE '^  tracked .*kept\.txt' "$WORK/tracked-web.log" && cmp -s "$LA/repos/lay-web/notes.txt" "$LAY/tracked-web/notes.txt" || fail "a tracked file of repos/lay-web/ was written over, or an untracked one was not applied whole (see $WORK/tracked-web.log)"
[ "$(cat "$LAY/tracked-plain/.ai-core/config.env")" = 'TRACKED_OWN="yes"' ] && git -C "$LAY/tracked-plain" diff --quiet && grep -aqE '^  tracked .*\.ai-core/config\.env' "$WORK/tracked-plain.log" || fail "a tracked config.env of a repository without an override was written over by the layer's, or not reported tracked (see $WORK/tracked-plain.log)"
planted="$(mutant_root 's|if \[ -n "\$CONFIG_BASE" \] \&\& ! keep_tracked .ai-core/config.env; then|if [ -n "$CONFIG_BASE" ]; then|')"
make_tracked "$LAY/mutant-tracked-web" lay-web; make_tracked "$LAY/mutant-tracked-plain" lay-plain
INIT_ROOT="$planted" lay_init "$LAY/mutant-tracked-web" mutant-tracked-web; INIT_ROOT="$planted" lay_init "$LAY/mutant-tracked-plain" mutant-tracked-plain
[ "$(cat "$LAY/mutant-tracked-web/.ai-core/config.env")" = 'TRACKED_OWN="yes"' ] && fail "planted: writing the merge over a tracked file was not caught"
[ "$(cat "$LAY/mutant-tracked-plain/.ai-core/config.env")" = 'TRACKED_OWN="yes"' ] && fail "planted: writing the layer's config.env over a tracked file was not caught"
[ "$(cat "$LAY/mutant-tracked-web/kept.txt")" = mine ] || fail "planted: the tracked file of repos/lay-web/ changed with the tracked check of config.env"
# every other file of repos/<repo>/ still replaces the whole untracked target
printf 'edited by hand\n' > "$LAY/lay-web/notes.txt"
lay_init "$LAY/lay-web" lay-web-notes
cmp -s "$LA/repos/lay-web/notes.txt" "$LAY/lay-web/notes.txt" || fail "another file of repos/lay-web/ no longer replaces the untracked target whole"
# a linked worktree starts from the data of its checkout and lays the same file
git -C "$LAY/lay-web" worktree add -q -b issue-353-lay "$LAY/lay-web-tree" 2>/dev/null || fail "no linked worktree of lay-web"
lay_init "$LAY/lay-web-tree" lay-tree
cmp -s "$LAY/lay-web/.ai-core/config.env" "$LAY/lay-web-tree/.ai-core/config.env" && ! grep -aE '^  (created|refreshed) .*\.ai-core/config\.env' "$WORK/lay-tree.log" || fail "a linked worktree did not lay the config.env its checkout has (see $WORK/lay-tree.log)"
# a project folder takes the layers' config.env whole: the file of one of its repositories is laid over nothing
mkdir -p "$LAY/folder"; new_checkout "$LAY/folder/lay-web" lay-web; new_checkout "$LAY/folder/lay-plain" lay-plain
carry_harness "$LAY/folder/lay-web" "$LAY/folder/lay-plain"
lay_init "$LAY/folder" lay-folder
is_layer_config "$LAY/folder" || fail "a project folder did not get the config.env of its layers whole (see $WORK/lay-folder.log): $(cat "$LAY/folder/.ai-core/config.env")"

# The override file taken out gives the layer's own back, and nothing of what the layer provides is removed
git -C "$LA" rm -q repos/lay-web/.ai-core/config.env repos/lay-web/.ai-core/models.tsv
publish_layer lay "the overrides go"
planted="$(mutant_root 's|case " \$DEPLOYED \$LAYER_FILES " in|case " $DEPLOYED " in|')"
cp -R "$LAY/lay-web" "$LAY/mutant-gone-web"
INIT_ROOT="$planted" lay_init "$LAY/mutant-gone-web" mutant-gone
[ -f "$LAY/mutant-gone-web/.ai-core/config.env" ] && fail "planted: a removal that ignores what the layers still provide kept the layer's config.env"
lay_init "$LAY/lay-web" lay-web-10
is_layer_config "$LAY/lay-web" || fail "without its override the repository did not get the layer's config.env: $(cat "$LAY/lay-web/.ai-core/config.env" 2>&1)"
cmp -s "$LA/models.tsv" "$LAY/lay-web/.ai-core/models.tsv" || fail "without its override the repository did not get the layer's models.tsv"
grep -aqE '^  removed .*\.ai-core/(config\.env|models\.tsv)' "$WORK/lay-web-10.log" && fail "init reported removing what the layer still provides (see $WORK/lay-web-10.log)"
grep -qx '.ai-core/config.env' "$LAY/lay-web/.ai-core/DEPLOYED" && fail "DEPLOYED still records the override that is gone"

# A layer without a config.env keeps the file of the repository as it stands; along an extends chain the last config.env
# is the base whole, and only the innermost layer's file of the repository is laid over it
make_layer nobase
mkdir -p "$LAY/author-nobase/repos/nobase-web/.ai-core"
printf 'UPDATE_CHECK="never"\nLIVE_TAGS="prod=landed"\n' > "$LAY/author-nobase/repos/nobase-web/.ai-core/config.env"
publish_layer nobase "a file of the repository, none of the layer"
new_checkout "$LAY/nobase-web" nobase-web; lay_init "$LAY/nobase-web" nobase
cmp -s "$LAY/author-nobase/repos/nobase-web/.ai-core/config.env" "$LAY/nobase-web/.ai-core/config.env" || fail "a repository's config.env, with no config.env of the layer, was not applied as it stands: $(cat "$LAY/nobase-web/.ai-core/config.env")"
make_layer chainbase
mkdir -p "$LAY/author-chainbase/repos/chain-web/.ai-core"
printf 'AGENTS="windsurf"\nOUTER_ONLY="outer"\nSHARED="outer"\n' > "$LAY/author-chainbase/config.env"
printf 'OUTER_OVERRIDE="outer"\nSHARED="outer-override"\n' > "$LAY/author-chainbase/repos/chain-web/.ai-core/config.env"
publish_layer chainbase "the base of the chain"
make_layer chain chainbase
mkdir -p "$LAY/author-chain/repos/chain-web/.ai-core"
printf 'AGENTS="cursor"\nSHARED="inner"\nINNER_ONLY="inner"\n' > "$LAY/author-chain/config.env"
printf 'SHARED="inner-override"\n' > "$LAY/author-chain/repos/chain-web/.ai-core/config.env"
publish_layer chain "the inner layer"
new_checkout "$LAY/chain-web" chain-web; lay_init "$LAY/chain-web" chain-1
printf 'AGENTS="cursor"\nSHARED="inner-override"\nINNER_ONLY="inner"\n' > "$WORK/chain-wanted"
cmp -s "$WORK/chain-wanted" "$LAY/chain-web/.ai-core/config.env" || fail "along an extends chain the inner config.env is not the base whole with the inner layer's file of the repository laid over it: $(cat "$LAY/chain-web/.ai-core/config.env")"
git -C "$LAY/author-chain" rm -q config.env; publish_layer chain "no config.env of the inner layer"; lay_init "$LAY/chain-web" chain-2
printf 'AGENTS="windsurf"\nOUTER_ONLY="outer"\nSHARED="inner-override"\n' > "$WORK/chain-wanted"
cmp -s "$WORK/chain-wanted" "$LAY/chain-web/.ai-core/config.env" || fail "along an extends chain the last config.env is not the base, or the outer layer's file of the repository was laid: $(cat "$LAY/chain-web/.ai-core/config.env")"

# A repository's file that repeats every key of its layer, as the copies of today do, reads in both readers as it did when it replaced the layer's
LAYER_KEEPS_CRLF=1 make_layer copy
mkdir -p "$LAY/author-copy/repos/copy-web/.ai-core"
cat > "$LAY/author-copy/layer.tmp" <<CONF
# the layer's own file
AGENTS="claude cursor"
UPDATE_CHECK=never
CI_GATE = 'none'   # a gate
LIVE_TAGS="prod=deploy/prod/* test=deploy/test/*"
USAGE_STOP_AT=92
ONLY_IN_LAYER="its own line ends in CRLF"
EMPTY_IN_LAYER="from the layer"
SHELL_EXPRESSION="\$(touch $LAY_RAN/s1) \`touch $LAY_RAN/s2\`"
REPEATED=first
REPEATED=second
LAST_IN_LAYER=kept
CONF
awk 'NR == 2 || NR == 7 { printf "%s\r\n", $0; next } { print }' "$LAY/author-copy/layer.tmp" > "$LAY/author-copy/layer-crlf.tmp"
printf '%s' "$(cat "$LAY/author-copy/layer-crlf.tmp")" > "$LAY/author-copy/config.env"; rm -f "$LAY/author-copy"/layer*.tmp
COPY="$LAY/author-copy/repos/copy-web/.ai-core/config.env"
printf '%s\r\n' '# the copy of today' 'AGENTS="claude"' '   UPDATE_CHECK = session-start # why' "CI_GATE='gate'" 'LIVE_TAGS="prod=landed"' 'USAGE_STOP_AT=' 'EMPTY_IN_LAYER=""' \
  "SHELL_EXPRESSION='\$(touch $LAY_RAN/s3) \`touch $LAY_RAN/s4\`'" 'REPEATED=one' 'LIVE_TAGS="prod=landed test=command" # the last' 'ONLY_IN_COPY="mine"' > "$COPY"
printf 'REPEATED=two # the last' >> "$COPY"
publish_layer copy "a layer, and a copy of it"
new_checkout "$LAY/copy-web" copy-web; lay_init "$LAY/copy-web" copy-1
grep -q "$(printf '\r')" "$LAY/copy-ai-core/repos/copy-web/.ai-core/config.env" || fail "the copy lost its CRLF before init read it"
copy_keys="AGENTS UPDATE_CHECK CI_GATE LIVE_TAGS USAGE_STOP_AT ONLY_IN_LAYER EMPTY_IN_LAYER SHELL_EXPRESSION REPEATED ONLY_IN_COPY LAST_IN_LAYER"
reads_like_before() {  # reads_like_before <checkout>: every key reads as in the copy where the copy sets it, as in the layer's file where it does not
  local key wanted
  for key in $copy_keys; do
    wanted="$LAY/author-copy/config.env"; grep -Eq "^[[:space:]]*$key[[:space:]]*=" "$COPY" && wanted="$COPY"
    reads_as "$1/.ai-core/config.env" "$wanted" "$key" || { echo "$key"; return 1; }
  done
}
unread="$(reads_like_before "$LAY/copy-web")" || fail "a repository's file repeating every key of the layer reads another value for $unread than it did when it replaced the layer's: $(cat "$LAY/copy-web/.ai-core/config.env")"
CM="$LAY/copy-web/.ai-core/config.env"
[ "$(config_value_in_file "$CM" EMPTY_IN_LAYER unset)" = unset ] && [ "$(config_value_in_file "$CM" USAGE_STOP_AT unset)" = unset ] && [ "$(config_value_in_file "$CM" REPEATED unset)" = two ] && [ "$(config_value_in_file "$CM" LAST_IN_LAYER unset)" = kept ] && [ "$(config_value_in_file "$CM" ONLY_IN_COPY unset)" = mine ] && [ "$(config_value_in_file "$CM" UPDATE_CHECK unset)" = session-start ] || fail "the copy's empty values, repeated assignments, spaces or the layer's last line without a newline read wrong: $(cat "$CM")"
[ -z "$(ls -A "$LAY_RAN")" ] || fail "init ran an expression of a config.env: $(ls "$LAY_RAN" | tr '\n' ' ')"
# planted: a pattern that needs no space around the key and its =, and an init that runs what it copies, are both seen
planted="$(mutant_root "s/assignment='^\[\[:space:\]\]\*(/assignment='^(/")"
new_checkout "$LAY/mutant-copy-web" copy-web; new_checkout "$LAY/mutant-chain-web" chain-web
INIT_ROOT="$planted" lay_init "$LAY/mutant-copy-web" mutant-copy; INIT_ROOT="$planted" lay_init "$LAY/mutant-chain-web" mutant-chain
reads_like_before "$LAY/mutant-copy-web" > /dev/null && fail "planted: a key written with spaces around it was not recognized, and the copy still read as before"
cmp -s "$WORK/chain-wanted" "$LAY/mutant-chain-web/.ai-core/config.env" || fail "planted: the config.env changed for a repository whose file holds only keys with no space around them"
planted="$(mutant_root 's|if \[ -z "\$keys" \]; then|{ . "$base"; } >/dev/null 2>\&1 \|\| true; if [ -z "$keys" ]; then|')"
new_checkout "$LAY/mutant-runs-web" copy-web
INIT_ROOT="$planted" lay_init "$LAY/mutant-runs-web" mutant-runs
[ -n "$(ls -A "$LAY_RAN")" ] || fail "planted: an init that runs the layer's config.env left no trace for the check to see"
rm -f "$LAY_RAN"/*
# the documents say how a repository's config.env works
for doc in README.md skeleton/README.md skeleton/repos/README.md; do
  grep -q 'key by key' "$ROOT/$doc" || fail "$doc does not say that a repository's config.env is laid over the layer's key by key"
done
echo "  lay: a repository's config.env keeps every key of its layer and a plain one gets the layer's bytes; a later key, a change, a drop, an override of nothing, one in UTF-16 and one taken out follow; a full copy reads as before; no expression runs; a tracked file is left; dry runs write nothing; a linked worktree and a project folder keep their scope; a planted whole-file write, a stale removal, a tracked write, a write past the dry run, a pattern without spaces, keys taken past grep and an init that runs its input are each caught"

section "a file the repository tracks is never written over by init: each data file, one layer and an extends chain, an override, a dry run, a worktree; the local and the remote catalog agree"
TRK="$WORK/trk"; mkdir -p "$TRK/committed"
DATA_NAMES="config.env labels.tsv assignees.tsv team-modes.tsv models.tsv"
data_row() {  # data_row <file> <who>: valid lines of that data file, marked with who wrote them
  case "$1" in
    config.env) printf 'DATA_MARK="%s"\n' "$2" ;;
    labels.tsv) printf 'area\tarea:%s\t0E8A16\tDeclared by %s\n' "$2" "$2" ;;
    assignees.tsv) printf 'example-repo\t%s\n' "$2" ;;
    team-modes.tsv) printf 'claude\tmode-%s\talways\t-\t-\n' "$2" ;;
    models.tsv) printf 'plan\tmechanical\tclaude-sonnet-5-5\tmedium\tno\nbuild\tmechanical\tclaude-sonnet-5-5\t%s\tno\n' "$2" ;;
  esac
}
for f in $DATA_NAMES; do data_row "$f" tracked > "$TRK/committed/$f"; done
# the chain: trkbase carries all five files, trk (which extends it) its own config.env, labels.tsv and models.tsv, and two overrides
make_layer trkbase; make_layer trk trkbase
for f in $DATA_NAMES; do data_row "$f" base > "$LAY/author-trkbase/$f"; done
for f in config.env labels.tsv models.tsv; do data_row "$f" layer > "$LAY/author-trk/$f"; done
mkdir -p "$LAY/author-trk/repos/trk-web/.ai-core" "$LAY/author-trk/repos/trk-ov/.ai-core"
for f in config.env labels.tsv; do data_row "$f" override > "$LAY/author-trk/repos/trk-web/.ai-core/$f"; done
data_row labels.tsv override > "$LAY/author-trk/repos/trk-ov/.ai-core/labels.tsv"
publish_layer trkbase "the base layer"; publish_layer trk "the inner layer"
# a layer with none of the five files: the harness's own tables and templates are what a repository gets
make_layer bare
make_tracked_data() {  # make_tracked_data <dir> <repo name> [file to leave out...]: a checkout that commits its data files, each with its own row
  local dir="$1" name="$2" f
  new_checkout "$dir" "$name"; mkdir -p "$dir/.ai-core"; shift 2
  for f in $DATA_NAMES; do case " $* " in *" $f "*) ;; *) data_row "$f" tracked > "$dir/.ai-core/$f" ;; esac; done
  git -C "$dir" add -f .ai-core; git -C "$dir" -c user.name=check -c user.email=check@localhost commit -q -m "its own data files"
}
tracked_kept() {  # tracked_kept <checkout> <log> [file to leave out...]: nothing printed, status 0 where every committed data file stands as committed, git status is empty, and the report names each as tracked and winning; else why, status 1
  local c="$1" log="$2" f; shift 2
  [ -z "$(git -C "$c" status --porcelain)" ] || { echo "git status shows: $(git -C "$c" status --porcelain | tr '\n' '|')"; return 1; }
  for f in $DATA_NAMES; do
    case " $* " in *" $f "*) continue ;; esac
    cmp -s "$TRK/committed/$f" "$c/.ai-core/$f" || { echo ".ai-core/$f is not what is committed"; return 1; }
    grep -aE '^  tracked ' "$log" | grep -q "\.ai-core/$f" || { echo "the report does not name .ai-core/$f as tracked"; return 1; }
  done
  grep -aE '^  tracked ' "$log" | grep -q 'wins over the layers' || { echo "the report does not say that the tracked file wins over the layers' copy"; return 1; }
}
# one layer with an override and an extends chain, every data file tracked, the old layer's files each different
make_tracked_data "$LAY/trk-web" trk-web; make_tracked_data "$LAY/trk-bare" trk-bare
lay_init "$LAY/trk-web" trk-web; lay_init "$LAY/trk-bare" trk-bare
tracked_kept "$LAY/trk-web" "$WORK/trk-web.log" > "$WORK/tracked-kept.out" || fail "init wrote over a tracked data file of a repository with an override over a chain of two layers: $(cat "$WORK/tracked-kept.out")"
tracked_kept "$LAY/trk-bare" "$WORK/trk-bare.log" > "$WORK/tracked-kept.out" || fail "init wrote over a tracked data file of a repository with no override: $(cat "$WORK/tracked-kept.out")"
# a second run adds nothing and a dry run writes nothing
before="$(tree_digest "$LAY/trk-web")"
lay_init "$LAY/trk-web" trk-web-2
[ "$(tree_digest "$LAY/trk-web")" = "$before" ] && ! grep -aE '^  (created|refreshed) .*\.ai-core/(config\.env|labels\.tsv|assignees\.tsv|team-modes\.tsv|models\.tsv)' "$WORK/trk-web-2.log" || fail "a second init added or changed a data file (see $WORK/trk-web-2.log)"
tracked_kept "$LAY/trk-web" "$WORK/trk-web-2.log" > "$WORK/tracked-kept.out" || fail "a second init did not report the tracked data files: $(cat "$WORK/tracked-kept.out")"
lay_init "$LAY/trk-web" trk-web-dry --dry-run
[ "$(tree_digest "$LAY/trk-web")" = "$before" ] && tracked_kept "$LAY/trk-web" "$WORK/trk-web-dry.log" > "$WORK/tracked-kept.out" || fail "a dry run wrote, or did not report the tracked data files: $(cat "$WORK/tracked-kept.out")"
# innocent: a repository that tracks none gets the layers' files, the inner layer's where both have one, and the override over the layer
new_checkout "$LAY/trk-plain" trk-plain; lay_init "$LAY/trk-plain" trk-plain
cmp -s "$LAY/author-trk/labels.tsv" "$LAY/trk-plain/.ai-core/labels.tsv" && cmp -s "$LAY/author-trk/models.tsv" "$LAY/trk-plain/.ai-core/models.tsv" && cmp -s "$LAY/author-trkbase/assignees.tsv" "$LAY/trk-plain/.ai-core/assignees.tsv" && cmp -s "$LAY/author-trkbase/team-modes.tsv" "$LAY/trk-plain/.ai-core/team-modes.tsv" && cmp -s "$LAY/author-trk/config.env" "$LAY/trk-plain/.ai-core/config.env" \
  || fail "an untracked data file is no longer the layer's: $(cat "$LAY/trk-plain/.ai-core/labels.tsv")"
new_checkout "$LAY/trk-ov" trk-ov; lay_init "$LAY/trk-ov" trk-ov
cmp -s "$LAY/author-trk/repos/trk-ov/.ai-core/labels.tsv" "$LAY/trk-ov/.ai-core/labels.tsv" || fail "the override of a repository no longer replaces the layer's labels.tsv: $(cat "$LAY/trk-ov/.ai-core/labels.tsv")"
echo 'edited by hand' >> "$LAY/trk-plain/.ai-core/labels.tsv"; lay_init "$LAY/trk-plain" trk-plain-2
cmp -s "$LAY/author-trk/labels.tsv" "$LAY/trk-plain/.ai-core/labels.tsv" && grep -aqE '^  refreshed .*\.ai-core/labels\.tsv' "$WORK/trk-plain-2.log" || fail "an untracked data file edited by hand was not refreshed from the layer (see $WORK/trk-plain-2.log)"
# the local catalog and the remote one agree: the same label is admitted and the same unknown one refused, in each source of precedence
mkdir -p "$WORK/remote-gh" "$WORK/elsewhere/other"
cat > "$WORK/remote-gh/gh" <<'EOF'
#!/usr/bin/env bash
# gh api over the bare repositories of the stand-in GitHub: the head commit, and a file at a commit as the contents API gives it
[ "$1" = api ] || exit 1
path="${2%%\?*}"; ref=""; case "$2" in *\?ref=*) ref="${2#*\?ref=}" ;; esac
repo="$(printf '%s' "$path" | cut -d/ -f2,3)"; bare="$GH_FAKE/github.com/$repo.git"
[ -d "$bare" ] || { echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }
case "$path" in
  repos/*/*/commits/HEAD) git -C "$bare" rev-parse HEAD ;;
  repos/*/*/contents/*)
    file="${path#repos/$repo/contents/}"
    git -C "$bare" cat-file -e "$ref:$file" 2>/dev/null || { echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }
    jq -n --arg content "$(git -C "$bare" show "$ref:$file" | base64)" --argjson size "$(git -C "$bare" cat-file -s "$ref:$file")" '{type: "file", encoding: "base64", size: $size, content: $content}' ;;
esac
EOF
chmod +x "$WORK/remote-gh/gh"; git init -q "$WORK/elsewhere/other"
publish_repository() {  # publish_repository <checkout> <name>: the checkout's branch on the stand-in GitHub, where the remote reader finds it
  local branch; branch="$(git -C "$1" symbolic-ref --short HEAD)"
  git init -q --bare "$GH_FAKE/github.com/example-org/$2.git"; git -C "$GH_FAKE/github.com/example-org/$2.git" symbolic-ref HEAD "refs/heads/$branch"
  git -C "$1" push -q "$GH_FAKE/github.com/example-org/$2.git" "HEAD:refs/heads/$branch"
}
publish_repository "$LAY/trk-web" trk-web; publish_repository "$LAY/trk-ov" trk-ov; publish_repository "$LAY/trk-plain" trk-plain
taxonomy() {  # taxonomy <local|remote> <repo name> [checkout]: the labels of the project of that repository, read where init left them (in the checkout, $LAY/<repo name> unless one is named) or from the forge
  local where="$1" name="$2" dir="${3:-$LAY/$2}" path="$PATH_SH"
  [ "$where" = local ] || { dir="$WORK/elsewhere/other"; path="$WORK/remote-gh:$PATH_SH"; }
  ( cd "$dir" && PATH="$path" bash -c '. "$1/lib/board.sh"; target_labels_tsv "example-org/$2"' _ "$ROOT" "$name" 2>&1 )
}
catalogs_agree() {  # catalogs_agree <repo name> <the label only its catalog declares> <label no catalog of it declares>: yes where both readers give one catalog, with the first label and without the second
  local here there
  here="$(taxonomy local "$1")"; there="$(taxonomy remote "$1")"
  [ "$here" = "$there" ] && grep -q "area:$2" <<< "$here" && ! grep -q "area:$3" <<< "$here" && echo yes || echo "no: local [$(grep area: <<< "$here" | tr '\t\n' ' ')] remote [$(grep area: <<< "$there" | tr '\t\n' ' ')]"
}
[ "$(catalogs_agree trk-web tracked override)" = yes ] || fail "a repository that tracks its catalog: the local and the remote reader differ, or the tracked rows are not the ones read: $(catalogs_agree trk-web tracked override)"
[ "$(catalogs_agree trk-web tracked layer)" = yes ] && [ "$(catalogs_agree trk-web tracked base)" = yes ] || fail "the tracked catalog is merged with a layer's: $(catalogs_agree trk-web tracked layer)"
[ "$(catalogs_agree trk-ov override layer)" = yes ] || fail "a repository with an override of its own: the local and the remote reader differ: $(catalogs_agree trk-ov override layer)"
[ "$(catalogs_agree trk-plain layer base)" = yes ] || fail "a repository served by its layer alone: the local and the remote reader differ: $(catalogs_agree trk-plain layer base)"
# planted: the old init writes the layer's catalog over the tracked one, and the local reader then answers what the remote one does not
planted="$(mutant_root 's|else put_data "\$l/\$f" ".ai-core/\$f"; fi|else put "$l/$f" ".ai-core/$f" managed; fi|')"
make_tracked_data "$LAY/mutant-trk-web" trk-web; INIT_ROOT="$planted" lay_init "$LAY/mutant-trk-web" mutant-trk-web
tracked_kept "$LAY/mutant-trk-web" "$WORK/mutant-trk-web.log" > /dev/null && fail "planted: an init that writes the layer's data file over a tracked one was not caught"
[ "$(taxonomy local trk-web "$LAY/mutant-trk-web")" != "$(taxonomy remote trk-web)" ] || fail "planted: the catalog the old init left reads like the tracked one, so the readers' agreement cannot go red"
# planted: the old config branch, with the override and without
planted="$(mutant_root 's|if \[ -n "\$CONFIG_BASE" \] \&\& ! keep_tracked .ai-core/config.env; then|if [ -n "$CONFIG_BASE" ]; then|')"
make_tracked_data "$LAY/mutant-config-web" trk-web; make_tracked_data "$LAY/mutant-config-bare" trk-bare
INIT_ROOT="$planted" lay_init "$LAY/mutant-config-web" mutant-config-web; INIT_ROOT="$planted" lay_init "$LAY/mutant-config-bare" mutant-config-bare
tracked_kept "$LAY/mutant-config-web" "$WORK/mutant-config-web.log" > /dev/null && fail "planted: the layer's config.env laid over a tracked one, with an override, was not caught"
tracked_kept "$LAY/mutant-config-bare" "$WORK/mutant-config-bare.log" > /dev/null && fail "planted: the layer's config.env written over a tracked one, with no override, was not caught"
# no layer provides the tables: the harness's own are managed, and a tracked table is never replaced by them; a removed one stays removed
make_tracked_data "$LAY/bare-web" bare-web; lay_init "$LAY/bare-web" bare-web
tracked_kept "$LAY/bare-web" "$WORK/bare-web.log" > "$WORK/tracked-kept.out" || fail "init wrote the harness's own data files over tracked ones, no layer providing them: $(cat "$WORK/tracked-kept.out")"
planted="$(mutant_root 's|put_data "\$CORE_ROOT/templates/\$rel" "\$rel"; continue|put "$CORE_ROOT/templates/$rel" "$rel" managed; continue|')"
make_tracked_data "$LAY/mutant-bare-web" bare-web; INIT_ROOT="$planted" lay_init "$LAY/mutant-bare-web" mutant-bare-web
tracked_kept "$LAY/mutant-bare-web" "$WORK/mutant-bare-web.log" > /dev/null && fail "planted: the harness's own tables written over tracked ones were not caught"
# a tracked file changed or removed in the working tree stays as it is: init restores nothing of HEAD, and puts nothing of a layer or a template in its place
make_tracked_data "$LAY/edit-web" trk-web; lay_init "$LAY/edit-web" edit-web
printf 'edited by hand\n' >> "$LAY/edit-web/.ai-core/labels.tsv"; cp "$LAY/edit-web/.ai-core/labels.tsv" "$WORK/edited-labels"
rm "$LAY/edit-web/.ai-core/assignees.tsv" "$LAY/edit-web/.ai-core/models.tsv"
lay_init "$LAY/edit-web" edit-web-2
cmp -s "$WORK/edited-labels" "$LAY/edit-web/.ai-core/labels.tsv" && [ ! -e "$LAY/edit-web/.ai-core/assignees.tsv" ] && [ ! -e "$LAY/edit-web/.ai-core/models.tsv" ] \
  && [ "$(git -C "$LAY/edit-web" status --porcelain | tr '\n' '|')" = " D .ai-core/assignees.tsv| M .ai-core/labels.tsv| D .ai-core/models.tsv|" ] || fail "a tracked file changed or removed by hand was restored or written over: $(git -C "$LAY/edit-web" status --porcelain | tr '\n' '|')"
make_tracked_data "$LAY/gone-web" bare-web; lay_init "$LAY/gone-web" gone-web
rm "$LAY/gone-web/.ai-core/labels.tsv" "$LAY/gone-web/.ai-core/config.env" "$LAY/gone-web/.ai-core/team-modes.tsv"
lay_init "$LAY/gone-web" gone-web-2
[ ! -e "$LAY/gone-web/.ai-core/labels.tsv" ] && [ ! -e "$LAY/gone-web/.ai-core/config.env" ] && [ ! -e "$LAY/gone-web/.ai-core/team-modes.tsv" ] || fail "a removed tracked file was made again from a template of the harness: $(ls "$LAY/gone-web/.ai-core" | tr '\n' ' ')"
planted="$(mutant_root '/\.ai-core\/config\.env|\.ai-core\/labels\.tsv|\.ai-core\/assignees\.tsv) keep_tracked "\$rel" \&\& continue ;;/d')"
make_tracked_data "$LAY/mutant-gone-bare" bare-web; INIT_ROOT="$planted" lay_init "$LAY/mutant-gone-bare" mutant-gone-bare
rm "$LAY/mutant-gone-bare/.ai-core/labels.tsv"; INIT_ROOT="$planted" lay_init "$LAY/mutant-gone-bare" mutant-gone-bare-2
[ -e "$LAY/mutant-gone-bare/.ai-core/labels.tsv" ] || fail "planted: a removed tracked file made again from the template was not seen"
# a worktree of a repository that tracks a file under .ai-core/ still takes the checkout's own untracked .ai-core data: its configuration, local rules and documents
make_tracked_data "$LAY/wt-web" bare-web config.env assignees.tsv team-modes.tsv models.tsv; lay_init "$LAY/wt-web" wt-web
printf 'WT_MARK="from the checkout"\n' >> "$LAY/wt-web/.ai-core/config.env"
printf 'a rule of the checkout\n' >> "$LAY/wt-web/.ai-core/rules/rules.local.md"; mkdir -p "$LAY/wt-web/.ai-core/docs"; printf 'a document of the checkout\n' > "$LAY/wt-web/.ai-core/docs/note.md"
git -C "$LAY/wt-web" worktree add -q -b issue-358-wt "$LAY/wt-tree" 2>/dev/null || fail "no worktree of wt-web"
[ -f "$LAY/wt-tree/.ai-core/labels.tsv" ] && [ ! -e "$LAY/wt-tree/.ai-core/config.env" ] || fail "the worktree of the repository does not start as the test needs it: a tracked labels.tsv and nothing else under .ai-core/"
worktree_took() {  # worktree_took <worktree> <log>: nothing printed where it holds the checkout's config.env, local rules and document, and the tracked catalog as committed; else why
  local t="$1" log="$2"
  grep -q '^WT_MARK="from the checkout"$' "$t/.ai-core/config.env" 2>/dev/null || { echo "the worktree did not take the checkout's config.env"; return 1; }
  cmp -s "$LAY/wt-web/.ai-core/rules/rules.local.md" "$t/.ai-core/rules/rules.local.md" || { echo "the worktree did not take the checkout's local rules"; return 1; }
  cmp -s "$LAY/wt-web/.ai-core/docs/note.md" "$t/.ai-core/docs/note.md" || { echo "the worktree did not take the checkout's documents"; return 1; }
  cmp -s "$TRK/committed/labels.tsv" "$t/.ai-core/labels.tsv" && [ -z "$(git -C "$t" status --porcelain)" ] || { echo "the tracked labels.tsv of the worktree is not as committed: $(git -C "$t" status --porcelain | tr '\n' '|')"; return 1; }
  grep -aq "^  \.ai-core taken from the checkout $LAY/wt-web" "$log" || { echo "the report does not say that .ai-core was taken from the checkout"; return 1; }
}
planted="$(mutant_root 's|if \[ "\$PROJECT_FOLDER" -eq 0 \] \&\& \[ ! -f "\$TARGET/.ai-core/STAMP" \]; then|if [ "$PROJECT_FOLDER" -eq 0 ] \&\& [ ! -d "$TARGET/.ai-core" ]; then|')"
git -C "$LAY/wt-web" worktree add -q -b issue-358-old "$LAY/wt-old" 2>/dev/null || fail "no second worktree of wt-web"
before="$(tree_digest "$LAY/wt-tree")"
lay_init "$LAY/wt-tree" wt-dry --dry-run
[ "$(tree_digest "$LAY/wt-tree")" = "$before" ] && grep -aq '^  \.ai-core would be taken from the checkout' "$WORK/wt-dry.log" || fail "a dry run in the worktree wrote, or did not say what it would take (see $WORK/wt-dry.log)"
lay_init "$LAY/wt-tree" wt-tree
worktree_took "$LAY/wt-tree" "$WORK/wt-tree.log" > "$WORK/tracked-kept.out" || fail "a worktree of a repository that tracks a file under .ai-core/ did not get the checkout's data: $(cat "$WORK/tracked-kept.out")"
INIT_ROOT="$planted" lay_init "$LAY/wt-old" wt-old
worktree_took "$LAY/wt-old" "$WORK/wt-old.log" > /dev/null && fail "planted: the worktree that copies .ai-core only where the folder is missing, which a tracked file made, was not caught"
lay_init "$LAY/wt-tree" wt-tree-2
! grep -aq '^  \.ai-core taken' "$WORK/wt-tree-2.log" && grep -q '^WT_MARK="from the checkout"$' "$LAY/wt-tree/.ai-core/config.env" || fail "a second init in the worktree took the checkout's data again (see $WORK/wt-tree-2.log)"
echo "  tracked data: five files, a layer, a chain with an override, no layer, a dry run, a second run, a changed and a removed file, a worktree, and the local and remote catalog agree; each planted copy of the old init is caught, the untracked case still follows the layer"

# a tracked config.env that cannot be read stops init where it reads the agents the project serves; planted: with AGENTS read as empty, init serves every agent
old_reader_copy "$ROOT" "$WORK/init-old-reader" || fail "no copy of the harness with the old reader"
unreadable_checkout() {  # unreadable_checkout <dir>: a checkout whose tracked config.env serves cursor alone and cannot be read
  new_checkout "$1" bare-unreadable; mkdir -p "$1/.ai-core"; printf 'AGENTS="cursor"\n' > "$1/.ai-core/config.env"
  git -C "$1" add -f .ai-core/config.env; git -C "$1" -c user.name=check -c user.email=check@localhost commit -q -m "its own settings"
  make_unreadable "$1/.ai-core/config.env" || fail "the config.env of $1 cannot be made unreadable"
}
init_unreadable() {  # init_unreadable <harness root> <checkout>: init with tracker and forge in the environment, so that only the read of AGENTS meets the file; its output, then rc=<n>
  local out rc=0
  out="$(HOME="$WORK/home-lay" PATH="$PATH_SH" TRACKER=github FORGE=github bash "$1/bin/init.sh" "$2" --no-doctor 2>&1)" || rc=$?
  printf '%s\nrc=%s\n' "$out" "$rc"
}
init_stopped() {  # init_stopped <what init_unreadable printed> <checkout>: yes where init failed, named the file once, and served an agent AGENTS does not name
  if [ "$(tail -n1 <<< "$1")" != rc=0 ] && [ "$(grep -acF -- "$2/.ai-core/config.env exists but cannot be read" <<< "$1")" = 1 ] && [ ! -e "$2/.windsurfrules" ]; then echo yes; else echo no; fi
}
unreadable_checkout "$LAY/unreadable-new"
got="$(init_unreadable "$ROOT" "$LAY/unreadable-new")"
[ "$(init_stopped "$got" "$LAY/unreadable-new")" = yes ] || fail "init went on with a tracked config.env it cannot read, or did not name it: $(tail -4 <<< "$got" | tr '\n' '|')"
unreadable_checkout "$LAY/unreadable-old"
got="$(init_unreadable "$WORK/init-old-reader" "$LAY/unreadable-old")"
[ "$(init_stopped "$got" "$LAY/unreadable-old")" = no ] && [ -e "$LAY/unreadable-old/.windsurfrules" ] || fail "planted: init with the old reader did not serve every agent for the file it cannot read, so the check cannot go red: $(tail -4 <<< "$got" | tr '\n' '|')"
cat > "$WORK/old-agents.sed" <<'SED'
s@^AGENTS="\$(config_value_in_file "\$CONFIG" AGENTS "")" || exit 1$@AGENTS="$(grep -E '^[[:space:]]*AGENTS[[:space:]]*=' "$CONFIG" | tail -n1 | sed 's/^[^=]*=//; s/\#.*//' | tr -d '"\\r' | tr -d "'" || true)"@
SED
planted="$(mutant_root "$(cat "$WORK/old-agents.sed")")"
unreadable_checkout "$LAY/unreadable-mutant"
got="$(init_unreadable "$planted" "$LAY/unreadable-mutant")"
[ "$(init_stopped "$got" "$LAY/unreadable-mutant")" = no ] && [ -e "$LAY/unreadable-mutant/.windsurfrules" ] || fail "planted: the raw read of AGENTS that turns an unreadable file into every agent was not caught: $(tail -4 <<< "$got" | tr '\n' '|')"
chmod 600 "$LAY/unreadable-new/.ai-core/config.env"
got="$(init_unreadable "$ROOT" "$LAY/unreadable-new")"
[ "$(tail -n1 <<< "$got")" = rc=0 ] && [ -e "$LAY/unreadable-new/.cursorrules" ] && [ ! -e "$LAY/unreadable-new/.windsurfrules" ] || fail "innocent: init over the same file, readable, does not serve cursor alone: $(tail -4 <<< "$got" | tr '\n' '|')"
echo "  an unreadable config.env: map asks no agent CLI, and init serves no agent by default; planted: the old reader and the raw read of AGENTS each go on"

section "Forgejo project settings: a fresh clone and a template-only checkout find their harness in one init"
make_forgejo_project
PATH_CURL="$WORK/ghbin:$PATH_CURL"
project="$WORK/forge folder"; author="$WORK/forge-author"
git init -q "$author"; cp -R "$ROOT/skeleton/." "$author/"
cat > "$author/config.env" <<CONF
AGENTS="claude"
UPDATE_CHECK="never"
TRACKER="forgejo"
FORGE="forgejo"
FORGEJO_URL="$FORGE_URL"
FORGEJO_TOKEN_COMMAND="cat $WORK/ftoken"
CONF
git -C "$author" add -A; git -C "$author" commit -q -m "The project harness"
git init -q --bare "$REMOTE/example-org/shop-ai-core.git"
git -C "$author" remote add origin "$REMOTE/example-org/shop-ai-core.git"
git -C "$author" push -qu origin HEAD
forgejo_repo example-org/shop-ai-core 1
seed="$WORK/forge-seed"; git init -q "$seed"
git -C "$seed" commit -q --allow-empty -m "The project repository"
mkdir -p "$project/.ai-core"
cp "$author/config.env" "$project/.ai-core/config.env"
printf 'setup-ai-core %s\nshop-ai-core %s\n' "$(git -C "$ROOT" rev-parse --short HEAD)" "$(git -C "$author" rev-parse --short HEAD)" > "$project/.ai-core/STAMP"

tracker_files() {  # tracker_files <checkout>
  ( cd "$1" && bash -c '
    . "$1/lib/common.sh"
    for key in TRACKER FORGE FORGEJO_URL FORGEJO_TOKEN_COMMAND; do
      config_file_of "$key"
    done
  ' _ "$ROOT" )
}
assert_tracker_file() {  # assert_tracker_file <checkout> <expected file> <case>
  local files
  files="$(tracker_files "$1" | sort -u)"
  [ "$files" = "$2" ] || fail "$3: the four tracker settings read $files instead of $2"
}
project_setting() {  # project_setting <checkout> <key> <default>
  ( cd "$1" && bash -c '. "$1/lib/common.sh"; config_value "$2" "$3"' _ "$ROOT" "$2" "$3" )
}

own="$project/shop-own"; git init -q "$own"; mkdir -p "$own/.ai-core"
git -C "$own" remote add origin "$FORGE_URL/example-org/shop-own.git"
printf 'FORGE="github"\nTRACKER="github"\nFORGEJO_URL="https://own.example.test"\n' > "$own/.ai-core/config.env"
assert_tracker_file "$own" "$own/.ai-core/config.env" "a checkout with no STAMP keeps its own config"
cp "$project/.ai-core/STAMP" "$own/.ai-core/STAMP"
assert_tracker_file "$own" "$own/.ai-core/config.env" "a checkout assembled from a layer keeps its own config"
[ "$(project_setting "$own" FORGE none)" = github ] && [ "$(project_setting "$own" FORGEJO_URL none)" = https://own.example.test ] || fail "the project's settings replaced a layer's own settings"

outside="$WORK/outside/shop-web"; git init -q "$outside"
git -C "$outside" remote add origin "$FORGE_URL/example-org/shop-web.git"
assert_tracker_file "$outside" "$outside/.ai-core/config.env" "a checkout outside a project folder"
[ "$(project_setting "$outside" FORGE github)" = github ] || fail "a checkout outside a project folder no longer uses the default forge"
PATH="$PATH_CURL" bash "$ROOT/bin/init.sh" "$outside" --no-doctor > "$WORK/project-outside.log" 2>&1 || fail "init outside a project folder failed"
[ "$(awk '{ print $1 }' "$outside/.ai-core/STAMP")" = setup-ai-core ] || fail "init outside a project folder no longer assembles setup-ai-core alone"
rm -rf "$outside/.ai-core"
mkdir -p "$WORK/outside/.ai-core"; cp "$project/.ai-core/config.env" "$WORK/outside/.ai-core/config.env"
assert_tracker_file "$outside" "$outside/.ai-core/config.env" "a parent with config but no STAMP"
printf 'setup-ai-core abc123\n' > "$WORK/outside/.ai-core/STAMP"
assert_tracker_file "$outside" "$outside/.ai-core/config.env" "a parent with no project layer"
mkdir -p "$WORK/outside/nested"; git init -q "$WORK/outside/nested/shop-web"
cp "$project/.ai-core/STAMP" "$WORK/outside/.ai-core/STAMP"
assert_tracker_file "$WORK/outside/nested/shop-web" "$WORK/outside/nested/shop-web/.ai-core/config.env" "an assembled grandparent is not the project folder"
git init -q "$WORK/outside"
assert_tracker_file "$outside" "$outside/.ai-core/config.env" "a parent checkout is not a project folder"
elsewhere="$project/other-web"; git init -q "$elsewhere"
git -C "$elsewhere" remote add origin https://github.com/example-org/other-web.git
assert_tracker_file "$elsewhere" "$elsewhere/.ai-core/config.env" "a checkout whose origin is not on the folder's Forgejo"
[ "$(project_setting "$elsewhere" FORGE github)" = github ] || fail "a GitHub checkout in a Forgejo project folder no longer uses GitHub"
rm -rf "$elsewhere"

github="$WORK/github-project"; mkdir -p "$github/.ai-core"
cp "$ROOT/templates/.ai-core/config.env" "$github/.ai-core/config.env"
printf 'TRACKER="forgejo"\nFORGEJO_URL="https://shop.example.test"\n' >> "$github/.ai-core/config.env"
cp "$project/.ai-core/STAMP" "$github/.ai-core/STAMP"
git init -q "$github/shop-web"; git -C "$github/shop-web" remote add origin https://github.com/example-org/shop-web.git
assert_tracker_file "$github/shop-web" "$github/shop-web/.ai-core/config.env" "a fresh clone in a GitHub project"
[ "$(project_setting "$github/shop-web" FORGE github)" = github ] || fail "a GitHub project no longer uses GitHub"
( cd "$github/shop-web" && PATH="$PATH_SH" bash -c '. "$1/lib/layers.sh"; [ "$(origin_parts "$PWD")" = "$(printf "example-org\tshop-web")" ]' _ "$ROOT" ) || fail "a GitHub project no longer finds its harness from the origin"
PATH="$PATH_SH" bash "$ROOT/bin/init.sh" "$github/shop-web" --no-doctor > "$WORK/project-github.log" 2>&1 || fail "init in a GitHub project failed: $(tail -5 "$WORK/project-github.log")"
grep -q '^shop-ai-core ' "$github/shop-web/.ai-core/STAMP" || fail "init in a GitHub project did not find its harness"
echo "  controls: layer config kept; GitHub unchanged; no fallback outside an assembled project folder, through a grandparent, from a parent checkout, or for an origin off the folder's Forgejo"

check_project_init() {  # check_project_init <fresh|template>
  local state="$1" checkout="$project/shop-$1" log="$WORK/project-$1.log"
  local files tree="$WORK/trees/shop-$1" tree_files
  git clone -q --bare "$seed" "$REMOTE/example-org/shop-$state.git"
  git clone -q "$REMOTE/example-org/shop-$state.git" "$checkout"
  git -C "$checkout" remote set-url origin "$FORGE_URL/example-org/shop-$state.git"
  if [ "$state" = template ]; then
    mv "$project/.ai-core" "$WORK/folder-data"
    PATH="$PATH_CURL" bash "$ROOT/bin/init.sh" "$checkout" --no-doctor > "$log" 2>&1 || fail "the first init before the project folder was assembled: $(tail -5 "$log")"
    mv "$WORK/folder-data" "$project/.ai-core"
    cmp -s "$ROOT/templates/.ai-core/config.env" "$checkout/.ai-core/config.env" || fail "the first init did not reproduce the template config"
    [ "$(awk '{ print $1 }' "$checkout/.ai-core/STAMP")" = setup-ai-core ] || fail "the first init already found a project layer"
  fi
  files="$(tracker_files "$checkout" | sort -u)"
  git -C "$checkout" worktree add -q -b "issue-329-$state" "$tree"
  mkdir -p "$tree/.ai-core"; printf 'AGENTS="cursor"\nFORGE="github"\n' > "$tree/.ai-core/config.env"
  tree_files="$(tracker_files "$tree" | sort -u)"
  [ "$(project_setting "$tree" AGENTS none)" = cursor ] || fail "$state: a non-tracker setting did not stay in the worktree"
  PATH="$PATH_CURL" bash "$ROOT/bin/init.sh" "$checkout" --no-doctor > "$log" 2>&1 || fail "$state: init failed: $(tail -5 "$log")"
  grep -q '^shop-ai-core ' "$checkout/.ai-core/STAMP" || fail "$state: one init did not find the project harness"
  cmp -s "$author/config.env" "$checkout/.ai-core/config.env" || fail "$state: one init did not copy the harness config"
  [ "$(git -C "$checkout" config --local --get-all "credential.$FORGE_URL.helper")" = "$(printf '\n!ai-core git-credential')" ] || fail "$state: one init did not set the sign-in line"
  [ "$files" = "$project/.ai-core/config.env" ] && [ "$tree_files" = "$files" ] || fail "$state: the clone and its worktree did not read all four tracker settings from the main checkout's project folder"
  assert_tracker_file "$checkout" "$checkout/.ai-core/config.env" "$state: the assembled checkout reads its own config"
  [ "$(project_setting "$checkout" FORGE none)" = forgejo ] || fail "$state: the assembled checkout did not keep Forgejo"
  echo "  $state: one init found the harness, copied its config, and set the sign-in line"
}
check_project_init fresh
check_project_init template
exit 0
