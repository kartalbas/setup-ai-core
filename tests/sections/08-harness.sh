#!/usr/bin/env bash
# the project harness: created, cloned, moved, assembled, the maps; one section of the suite, run by tests/check.sh with the others
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

section "the project harness: created from the skeleton, cloned on another machine, its rules, skills, docs, data and repos/<repo>/ assembled, on both twins"
make_graft_fake; make_gh_fake
# A project repository: shop-web of example-org, with a README the fake Graft appends to
new_checkout() {  # new_checkout <dir> <repo name> [org]
  git init -q "$1"; echo readme > "$1/README.md"
  git -C "$1" add README.md; git -C "$1" -c user.name=check -c user.email=check@localhost commit -q -m init
  git -C "$1" config core.autocrlf false
  git -C "$1" remote add origin "https://github.com/${3:-example-org}/$2.git"
}
# Two machines with a project folder each; a harness clone lands beside the checkouts in it
mkdir -p "$WORK/home-sh" "$WORK/home-ps" "$WORK/org-sh" "$WORK/org-ps"
new_checkout "$WORK/org-sh/shop-web" shop-web
HOME="$WORK/home-sh" PATH="$PATH_SH" GRAFT_FAKE_LOG="$WORK/layers.args" bash "$ROOT/bin/init.sh" "$WORK/org-sh/shop-web" --no-doctor --dry-run > "$WORK/layers-sh-0.log" 2>&1 || fail "init.sh --dry-run before the project harness exists (see $WORK/layers-sh-0.log)"
grep -aq 'example-org/shop-ai-core would be created from the skeleton' "$WORK/layers-sh-0.log" || fail "init.sh --dry-run does not announce the harness it would create"
[ ! -e "$GH_FAKE/github.com/example-org/shop-ai-core.git" ] && [ ! -e "$WORK/org-sh/shop-ai-core" ] || fail "init.sh --dry-run created the project harness"
HOME="$WORK/home-sh" PATH="$PATH_SH" GRAFT_FAKE_LOG="$WORK/layers.args" bash "$ROOT/bin/init.sh" "$WORK/org-sh/shop-web" --no-doctor > "$WORK/layers-sh-1.log" 2>&1 || fail "init.sh with a new project harness (see $WORK/layers-sh-1.log)"
grep -aq 'created: example-org/shop-ai-core, private, from the skeleton' "$WORK/layers-sh-1.log" || fail "init.sh did not create the project harness (see $WORK/layers-sh-1.log)"
grep -aq '^--> Project harness: example-org/shop-ai-core (' "$WORK/layers-sh-1.log" || fail "init.sh did not name the project harness"
[ -d "$GH_FAKE/github.com/example-org/shop-ai-core.git" ] || fail "the harness was not pushed to GitHub"
[ -f "$WORK/org-sh/shop-ai-core/ai-core.json" ] && [ -f "$WORK/org-sh/shop-ai-core/labels.tsv" ] || fail "the clone beside the checkout lacks the skeleton"
[ "$(wc -l < "$WORK/org-sh/shop-web/.ai-core/STAMP" | tr -d ' ')" = 2 ] && grep -q '^shop-ai-core ' "$WORK/org-sh/shop-web/.ai-core/STAMP" || fail "STAMP does not name setup-ai-core and the harness: $(cat "$WORK/org-sh/shop-web/.ai-core/STAMP" | tr '\n' '|')"
cmp -s "$WORK/org-sh/shop-web/.ai-core/config.env" "$ROOT/templates/.ai-core/config.env" || fail "config.env of the checkout is not the harness's (the skeleton's copy of the template)"
# The skeleton's .gitattributes makes every checkout of the harness LF; a clone made before the
# skeleton carried it gets the rule on the next init, and ai-core push commits it (here the clone
# commits it itself, so the rest of this section sees the harness as created)
grep -qxF '* text=auto eol=lf' "$WORK/org-sh/shop-ai-core/.gitattributes" || fail "the created harness lacks the skeleton's .gitattributes"
git -C "$WORK/org-sh/shop-ai-core" rm -q .gitattributes && git -C "$WORK/org-sh/shop-ai-core" -c user.name=check -c user.email=check@localhost commit -q -m 'without attributes' && git -C "$WORK/org-sh/shop-ai-core" push -q origin HEAD 2>/dev/null || fail "could not take .gitattributes out of the harness clone"
HOME="$WORK/home-sh" PATH="$PATH_SH" GRAFT_FAKE_LOG="$WORK/layers.args" bash "$ROOT/bin/init.sh" "$WORK/org-sh/shop-web" --no-doctor --dry-run > "$WORK/layers-sh-attr-dry.log" 2>&1 || fail "init.sh --dry-run on a harness clone without .gitattributes (see $WORK/layers-sh-attr-dry.log)"
grep -aq "note: example-org/shop-ai-core would get the skeleton's .gitattributes (every file LF; dry run: not written)" "$WORK/layers-sh-attr-dry.log" || fail "init.sh --dry-run does not announce the skeleton's .gitattributes (see $WORK/layers-sh-attr-dry.log)"
[ ! -e "$WORK/org-sh/shop-ai-core/.gitattributes" ] || fail "init.sh --dry-run wrote .gitattributes into the harness clone"
HOME="$WORK/home-sh" PATH="$PATH_SH" GRAFT_FAKE_LOG="$WORK/layers.args" bash "$ROOT/bin/init.sh" "$WORK/org-sh/shop-web" --no-doctor > "$WORK/layers-sh-attr.log" 2>&1 || fail "init.sh on a harness clone without .gitattributes (see $WORK/layers-sh-attr.log)"
grep -aq 'note: example-org/shop-ai-core: .gitattributes from the skeleton written into .*shop-ai-core (every file LF); ai-core push commits it' "$WORK/layers-sh-attr.log" || fail "init.sh did not report the skeleton's .gitattributes for the older clone (see $WORK/layers-sh-attr.log)"
grep -qxF '* text=auto eol=lf' "$WORK/org-sh/shop-ai-core/.gitattributes" || fail "init.sh did not write the skeleton's rule into the older clone"
git -C "$WORK/org-sh/shop-ai-core" add .gitattributes && git -C "$WORK/org-sh/shop-ai-core" -c user.name=check -c user.email=check@localhost commit -q -m 'attributes again' && git -C "$WORK/org-sh/shop-ai-core" push -q origin HEAD 2>/dev/null || fail "could not commit .gitattributes back into the harness clone"
# The project fills its harness: a new rule section, a replaced one, a skill, a document, the map and config of shop-web
git clone -q "$GH_FAKE/github.com/example-org/shop-ai-core.git" "$WORK/author" 2>/dev/null
git -C "$WORK/author" config core.autocrlf false
mkdir -p "$WORK/author/skills/deploy" "$WORK/author/repos/shop-web/.ai-core"
printf '## Releases\n\n- **A release is a tag.** Nothing ships without one. [review]\n' > "$WORK/author/rules/35-releases.md"
printf '## Naming\n\n- **Names are English.** The project spells them its own way. [review]\n' > "$WORK/author/rules/50-naming.md"
printf -- '---\nname: deploy\ndescription: how this project deploys\n---\nRun the deploy script.\n' > "$WORK/author/skills/deploy/SKILL.md"
mkdir -p "$WORK/author/agents"; printf -- '---\nname: builder\ndescription: builds one issue\n---\nBuild it.\n' > "$WORK/author/agents/builder.md"; echo 'the agents of this layer' > "$WORK/author/agents/README.md"
printf '# Glossary\n\ntenant: a customer.\n' > "$WORK/author/docs/glossary.md"
printf '# shop-web\n\nThe map of shop-web.\n' > "$WORK/author/repos/shop-web/AGENTS.md"
printf 'AGENTS="claude"\nGRAFT_EXECUTION_MODE="skip"\n' > "$WORK/author/repos/shop-web/.ai-core/config.env"
git -C "$WORK/author" add -A; git -C "$WORK/author" -c user.name=check -c user.email=check@localhost commit -q -m "the project's own"; git -C "$WORK/author" push -q origin HEAD
HOME="$WORK/home-sh" PATH="$PATH_SH" GRAFT_FAKE_LOG="$WORK/layers.args" bash "$ROOT/bin/init.sh" "$WORK/org-sh/shop-web" --no-doctor > "$WORK/layers-sh-2.log" 2>&1 || fail "init.sh second run with the filled harness (see $WORK/layers-sh-2.log)"
assembled_ok() {  # assembled_ok <checkout> <twin>
  local c="$1" t="$2" hash
  hash="$(git -C "$WORK/author" rev-parse --short HEAD)"
  grep -q "^<!-- shop-ai-core $hash: rules/35-releases.md -->" "$c/.ai-core/rules/rules.md" || fail "$t: the harness's new section is not in rules.md"
  grep -q "^<!-- shop-ai-core $hash: rules/50-naming.md -->" "$c/.ai-core/rules/rules.md" || fail "$t: the harness's section did not replace the generic one"
  grep -q "^<!-- setup-ai-core .*: rules/50-naming.md -->" "$c/.ai-core/rules/rules.md" && fail "$t: the generic naming section is still there beside the replacement"
  [ "$(grep -c '^<!-- ' "$c/.ai-core/rules/rules.md")" = $((SECTIONS + 1)) ] || fail "$t: rules.md has $(grep -c '^<!-- ' "$c/.ai-core/rules/rules.md") sections, expected $((SECTIONS + 1))"
  bash "$ROOT/bin/rules-check.sh" "$c/.ai-core/rules/rules.md" > /dev/null || fail "$t: the assembled rules.md fails rules-check"
  [ -f "$c/.claude/skills/deploy/SKILL.md" ] && [ -f "$c/.agents/skills/deploy/SKILL.md" ] || fail "$t: the skill is not in both skill directories"
  [ -f "$c/.claude/agents/builder.md" ] || fail "$t: the agent definition is not in .claude/agents/"
  [ ! -e "$c/.claude/agents/README.md" ] || fail "$t: agents/README.md of the layer was deployed as an agent"
  [ -f "$c/.ai-core/docs/shop-ai-core/glossary.md" ] || fail "$t: the harness's docs are not under .ai-core/docs/shop-ai-core/"
  grep -q '^The map of shop-web' "$c/AGENTS.md" || fail "$t: AGENTS.md is not the map from repos/shop-web/"
  grep -q '^AGENTS="claude"' "$c/.ai-core/config.env" || fail "$t: config.env is not the one from repos/shop-web/.ai-core/"
  [ -f "$c/.ai-core/labels.tsv" ] && [ -f "$c/.ai-core/team-modes.tsv" ] || fail "$t: the data files did not come from the harness"
  [ -e "$c/.cursorrules" ] && fail "$t: a pointer file of an agent the harness does not serve was deployed"
  st="$(git -C "$c" status --porcelain | tr -d '\r' | sort | tr '\n' '|')"
  [ "$st" = " M README.md|" ] || [ -z "$st" ] || fail "$t: git status shows more than the new .gitignore (and the fake Graft's README.md): $st"
}
assembled_ok "$WORK/org-sh/shop-web" "init.sh"
# Another machine, the PowerShell twin: it holds the clone where an earlier version put it,
# ~/.shop-ai-core, and init moves it beside the checkout; without a clone the harness is cloned
# from GitHub; the checkout is assembled the same
new_checkout "$WORK/org-ps/shop-web" shop-web
git clone -q "$GH_FAKE/github.com/example-org/shop-ai-core.git" "$WORK/home-ps/.shop-ai-core" 2>/dev/null
HOME="$WORK/home-ps" USERPROFILE="$(native "$WORK/home-ps")" PATH="$PATH_SH" GRAFT_FAKE_LOG="$(native "$WORK/layers.args")" pwsh -NoProfile -File "$ROOT/bin/init.ps1" -TargetDir "$(native "$WORK/org-ps/shop-web")" -NoDoctor > "$WORK/layers-ps-1.log" 2>&1 || fail "init.ps1 with the old clone under the home directory (see $WORK/layers-ps-1.log)"
grep -aq 'created:' "$WORK/layers-ps-1.log" && fail "init.ps1 created a harness that exists"
grep -aq 'moved: example-org/shop-ai-core from ' "$WORK/layers-ps-1.log" || fail "init.ps1 did not report the move of the old clone (see $WORK/layers-ps-1.log)"
[ ! -e "$WORK/home-ps/.shop-ai-core" ] || fail "init.ps1 left the old clone under the home directory"
[ -f "$WORK/org-ps/shop-ai-core/ai-core.json" ] || fail "init.ps1 did not move the harness beside the checkout"
# The move an earlier run left halfway (the history here, the files still under the home directory beside an empty .git) is completed
mkdir -p "$WORK/home-ps/.shop-ai-core/.git"; mv "$WORK/org-ps/shop-ai-core"/[!.]* "$WORK/home-ps/.shop-ai-core/"
HOME="$WORK/home-ps" USERPROFILE="$(native "$WORK/home-ps")" PATH="$PATH_SH" GRAFT_FAKE_LOG="$(native "$WORK/layers.args")" pwsh -NoProfile -File "$ROOT/bin/init.ps1" -TargetDir "$(native "$WORK/org-ps/shop-web")" -NoDoctor > "$WORK/layers-ps-1c.log" 2>&1 || fail "init.ps1 completing an interrupted move (see $WORK/layers-ps-1c.log)"
grep -aq 'moved: example-org/shop-ai-core from ' "$WORK/layers-ps-1c.log" || fail "init.ps1 did not complete the interrupted move (see $WORK/layers-ps-1c.log)"
[ ! -e "$WORK/home-ps/.shop-ai-core" ] && [ -z "$(git -C "$WORK/org-ps/shop-ai-core" status --porcelain)" ] || fail "the interrupted move was not completed: $(git -C "$WORK/org-ps/shop-ai-core" status --porcelain | tr '\n' '|')"
rm -rf "$WORK/org-ps/shop-ai-core"
HOME="$WORK/home-ps" USERPROFILE="$(native "$WORK/home-ps")" PATH="$PATH_SH" GRAFT_FAKE_LOG="$(native "$WORK/layers.args")" pwsh -NoProfile -File "$ROOT/bin/init.ps1" -TargetDir "$(native "$WORK/org-ps/shop-web")" -NoDoctor > "$WORK/layers-ps-1b.log" 2>&1 || fail "init.ps1 with the harness to clone (see $WORK/layers-ps-1b.log)"
grep -aqE 'created:|moved:' "$WORK/layers-ps-1b.log" && fail "init.ps1 created or moved a harness that is on GitHub"
[ -f "$WORK/org-ps/shop-ai-core/ai-core.json" ] || fail "init.ps1 did not clone the harness beside the checkout"
assembled_ok "$WORK/org-ps/shop-web" "init.ps1"
cmp -s "$WORK/org-sh/shop-web/.ai-core/rules/rules.md" "$WORK/org-ps/shop-web/.ai-core/rules/rules.md" || fail "the assembled rules.md differs between the twins"
cmp -s "$WORK/org-sh/shop-web/.ai-core/STAMP" "$WORK/org-ps/shop-web/.ai-core/STAMP" || fail "STAMP differs between the twins"
cmp -s "$WORK/org-sh/shop-web/.ai-core/DEPLOYED" "$WORK/org-ps/shop-web/.ai-core/DEPLOYED" || fail "DEPLOYED differs between the twins: $(tr '\n' '|' < "$WORK/org-sh/shop-web/.ai-core/DEPLOYED") vs $(tr '\n' '|' < "$WORK/org-ps/shop-web/.ai-core/DEPLOYED")"
# What the harness no longer provides leaves the checkout: the skill and the agent go from the harness, init takes them out, on both twins
git -C "$WORK/author" rm -rq skills/deploy agents/builder.md; git -C "$WORK/author" -c user.name=check -c user.email=check@localhost commit -q -m "the skill and the agent go"; git -C "$WORK/author" push -q origin HEAD
HOME="$WORK/home-sh" PATH="$PATH_SH" GRAFT_FAKE_LOG="$WORK/layers.args" bash "$ROOT/bin/init.sh" "$WORK/org-sh/shop-web" --no-doctor > "$WORK/layers-sh-gone.log" 2>&1 || fail "init.sh after the harness dropped a skill and an agent (see $WORK/layers-sh-gone.log)"
HOME="$WORK/home-ps" USERPROFILE="$(native "$WORK/home-ps")" PATH="$PATH_SH" GRAFT_FAKE_LOG="$(native "$WORK/layers.args")" pwsh -NoProfile -File "$ROOT/bin/init.ps1" -TargetDir "$(native "$WORK/org-ps/shop-web")" -NoDoctor > "$WORK/layers-ps-gone.log" 2>&1 || fail "init.ps1 after the harness dropped a skill and an agent (see $WORK/layers-ps-gone.log)"
for t in sh ps; do
  c="$WORK/org-$t/shop-web"
  grep -aq '^  removed    .claude/skills/deploy, .agents/skills/deploy, .claude/agents/builder.md$' "$WORK/layers-$t-gone.log" || fail "init.$t does not report what it took out: $(grep -a '^  removed' "$WORK/layers-$t-gone.log")"
  [ ! -e "$c/.claude/skills/deploy" ] && [ ! -e "$c/.agents/skills/deploy" ] && [ ! -e "$c/.claude/agents/builder.md" ] || fail "init.$t left what the harness no longer provides"
  [ -f "$c/.ai-core/docs/shop-ai-core/glossary.md" ] && grep -q '^The map of shop-web' "$c/AGENTS.md" || fail "init.$t took out what the harness still provides"
  grep -q 'skills/deploy' "$c/.ai-core/DEPLOYED" && fail "init.$t still records the skill in DEPLOYED"
done
# The map: the agent CLI (a fake claude here) writes it, map puts it into the harness, pushes it and brings it into the checkout at once; people's rules kept; a bad output refused; on both twins
cat > "$WORK/ghbin/claude" <<'EOF'
#!/bin/sh
echo "$*" >> "$MAP_FAKE_LOG"
[ -z "${MAP_FAKE_BAD:-}" ] || { echo "Sure! Here is the map:"; exit 0; }
[ -z "${MAP_FAKE_NOISE:-}" ] || printf 'Done reading. Writing the map now.\n\n'
n="$(basename "$PWD")"
printf '# %s \342\200\224 the map\n\n## What it is\nA shop.%s\n\n## Shape\n- src/: the code\n\n## Build, check, run\n- npm test\n\n## Where to add things\n| a page | src/pages/ |\n\n## Rules of this repository\n(none yet: written by people, kept on every regeneration)\n' "$n" "${MAP_FAKE_NOTE:+ $MAP_FAKE_NOTE}"
[ -z "${MAP_FAKE_NOISE:-}" ] || printf '\n> Grant write permission and rerun.\n\ngraft saved ~0 tokens this turn\n'
EOF
chmod +x "$WORK/ghbin/claude"
cat > "$WORK/ghbin/claude.ps1" <<'EOF'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Add-Content -Path $env:MAP_FAKE_LOG -Value ($Rest -join ' ')
if ($env:MAP_FAKE_BAD) { 'Sure! Here is the map:'; exit 0 }
if ($env:MAP_FAKE_NOISE) { 'Done reading. Writing the map now.'; '' }
$n = Split-Path -Leaf (Get-Location).Path
"# $n $([char]0x2014) the map"; ''; '## What it is'; "A shop.$(if ($env:MAP_FAKE_NOTE) { ' ' + $env:MAP_FAKE_NOTE })"; ''; '## Shape'; '- src/: the code'; ''; '## Build, check, run'; '- npm test'; ''; '## Where to add things'; '| a page | src/pages/ |'; ''; '## Rules of this repository'; '(none yet: written by people, kept on every regeneration)'
if ($env:MAP_FAKE_NOISE) { ''; '> Grant write permission and rerun.'; ''; 'graft saved ~0 tokens this turn' }
exit 0
EOF
# codex writes its answer into the file named by --output-last-message; agy prints it, like claude
cat > "$WORK/ghbin/codex" <<'EOF'
#!/bin/sh
echo "$*" >> "$MAP_FAKE_LOG"
out=""; while [ $# -gt 0 ]; do [ "$1" = "--output-last-message" ] && out="$2"; shift; done
n="$(basename "$PWD")"
printf '# %s \342\200\224 the map\n\n## What it is\nA shop.\n\n## Shape\n- src/: the code\n\n## Build, check, run\n- npm test\n\n## Where to add things\n| a page | src/pages/ |\n\n## Rules of this repository\n(none yet: written by people, kept on every regeneration)\n' "$n" > "$out"
echo "codex: thinking..."
EOF
cat > "$WORK/ghbin/codex.ps1" <<'EOF'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)
Add-Content -Path $env:MAP_FAKE_LOG -Value ($Rest -join ' ')
$i = [Array]::IndexOf($Rest, '--output-last-message'); $out = $Rest[$i + 1]
$n = Split-Path -Leaf (Get-Location).Path
$map = @("# $n $([char]0x2014) the map", '', '## What it is', 'A shop.', '', '## Shape', '- src/: the code', '', '## Build, check, run', '- npm test', '', '## Where to add things', '| a page | src/pages/ |', '', '## Rules of this repository', '(none yet: written by people, kept on every regeneration)')
[System.IO.File]::WriteAllText($out, (($map -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding $false))
'codex: thinking...'
exit 0
EOF
sed 's/^echo "\$\*" >> "\$MAP_FAKE_LOG"$/echo "$*" >> "$MAP_FAKE_LOG"/' "$WORK/ghbin/claude" > "$WORK/ghbin/agy"; chmod +x "$WORK/ghbin/agy" "$WORK/ghbin/codex"
cp "$WORK/ghbin/claude.ps1" "$WORK/ghbin/agy.ps1"
MAPLOG="$WORK/map.args"
map_sh() { HOME="$WORK/home-sh" PATH="$PATH_SH" GRAFT_FAKE_LOG="$WORK/layers.args" MAP_FAKE_LOG="$MAPLOG" bash "$ROOT/bin/map.sh" "$@"; }
map_ps() { HOME="$WORK/home-ps" USERPROFILE="$(native "$WORK/home-ps")" PATH="$PATH_SH" GRAFT_FAKE_LOG="$(native "$WORK/layers.args")" MAP_FAKE_LOG="$(native "$MAPLOG")" MAP_FAKE_NOTE=ps pwsh -NoProfile -File "$ROOT/bin/map.ps1" "$@"; }
map_sh "$WORK/org-sh/shop-web" > "$WORK/map-sh-1.log" 2>&1 || fail "map.sh (see $WORK/map-sh-1.log)"
M="$WORK/org-sh/shop-ai-core/repos/shop-web/AGENTS.md"
head -n1 "$M" | grep -qE '^<!-- ai-core map: generated [0-9-]+ from [0-9a-f]+; ' && [ "$(sed -n 2p "$M")" = "# shop-web — the map" ] || fail "map.sh did not write the map into the harness: $(head -n2 "$M" 2>/dev/null | tr '\n' '|')"
[ -z "$(git -C "$WORK/org-sh/shop-ai-core" status --porcelain)" ] && [ "$(git -C "$WORK/org-sh/shop-ai-core" rev-list --count '@{upstream}..HEAD')" = 0 ] || fail "map.sh did not commit and push the harness"
head -n1 "$WORK/org-sh/shop-web/AGENTS.md" | grep -q 'ai-core map: generated' || fail "map.sh did not bring the map into the checkout"
grep -q -- '--allowedTools' "$MAPLOG" && grep -q 'Read the repository first, cheaply' "$MAPLOG" || fail "map.sh did not call the agent CLI with the prompt and the tools"
# people write a rule into the map and push it as they push any edit of the harness; the next generation keeps it
sed -i.bak 's/^(none yet: written by people, kept on every regeneration)$/- **Ship on Fridays never.** [review]/' "$M" && rm -f "$M.bak"
(cd "$WORK/org-sh/shop-web" && HOME="$WORK/home-sh" PATH="$PATH_SH" GRAFT_FAKE_LOG="$WORK/layers.args" bash "$ROOT/bin/push.sh" "a rule of this repository" > "$WORK/map-rule-push.log" 2>&1) || fail "push.sh with the rule people wrote (see $WORK/map-rule-push.log)"
MAP_FAKE_NOTE=v2 map_sh "$WORK/org-sh/shop-web" > "$WORK/map-sh-2.log" 2>&1 || fail "map.sh second run (see $WORK/map-sh-2.log)"
grep -q '^A shop\. v2$' "$M" && grep -q '^- \*\*Ship on Fridays never\.\*\* \[review\]$' "$M" && ! grep -q '^(none yet' "$M" || fail "map.sh did not regenerate and keep the rules people wrote: $(grep -n 'shop\.\|Fridays\|none yet' "$M" | tr '\n' '|')"
[ -z "$(git -C "$WORK/org-sh/shop-ai-core" status --porcelain)" ] || fail "map.sh second run left the harness uncommitted"
cp "$M" "$WORK/map.before"
MAP_FAKE_BAD=1 map_sh "$WORK/org-sh/shop-web" > "$WORK/map-sh-bad.log" 2>&1 && fail "map.sh accepted an output that is not a map"
grep -aq "not the map's shape" "$WORK/map-sh-bad.log" && cmp -s "$M" "$WORK/map.before" && [ -f "$WORK/org-sh/shop-web/.ai-core/map.rejected.md" ] || fail "map.sh: the refusal (see $WORK/map-sh-bad.log)"
# what the tool says before the title and after the file drops out
MAP_FAKE_NOISE=1 map_sh "$WORK/org-sh/shop-web" --dry-run > "$WORK/map-sh-noise.log" 2>&1 || fail "map.sh with a remark before and a tally after the file (see $WORK/map-sh-noise.log)"
grep -aq '^# shop-web — the map' "$WORK/map-sh-noise.log" && ! grep -aqE 'Done reading|Grant write|graft saved' "$WORK/map-sh-noise.log" || fail "map.sh kept what the tool said around the file (see $WORK/map-sh-noise.log)"
MAP_FAKE_NOISE=1 map_ps -TargetDir "$(native "$WORK/org-ps/shop-web")" -DryRun > "$WORK/map-ps-noise.log" 2>&1 || fail "map.ps1 with a remark before and a tally after the file (see $WORK/map-ps-noise.log)"
grep -aq '^# shop-web — the map' "$WORK/map-ps-noise.log" && ! grep -aqE 'Done reading|Grant write|graft saved' "$WORK/map-ps-noise.log" || fail "map.ps1 kept what the tool said around the file (see $WORK/map-ps-noise.log)"
map_sh "$WORK/org-sh/shop-web" --dry-run > "$WORK/map-sh-dry.log" 2>&1 || fail "map.sh --dry-run (see $WORK/map-sh-dry.log)"
grep -aq '^# shop-web — the map' "$WORK/map-sh-dry.log" && cmp -s "$M" "$WORK/map.before" || fail "map.sh --dry-run wrote something or printed nothing"
map_ps -TargetDir "$(native "$WORK/org-ps/shop-web")" > "$WORK/map-ps-1.log" 2>&1 || fail "map.ps1 (see $WORK/map-ps-1.log)"
MP="$WORK/org-ps/shop-ai-core/repos/shop-web/AGENTS.md"
head -n1 "$MP" | grep -qE '^<!-- ai-core map: generated [0-9-]+ from [0-9a-f]+; ' && grep -q '^A shop\. ps$' "$MP" && grep -q '^- \*\*Ship on Fridays never' "$MP" || fail "map.ps1 did not write the map or lost the rules people wrote: $(head -n5 "$MP" 2>/dev/null | tr '\n' '|')"
[ -z "$(git -C "$WORK/org-ps/shop-ai-core" status --porcelain)" ] && head -n1 "$WORK/org-ps/shop-web/AGENTS.md" | grep -q 'ai-core map: generated' || fail "map.ps1 did not push the harness and bring the map into the checkout"
MAP_FAKE_BAD=1 map_ps -TargetDir "$(native "$WORK/org-ps/shop-web")" > "$WORK/map-ps-bad.log" 2>&1 && fail "map.ps1 accepted an output that is not a map"
grep -aq "not the map's shape" "$WORK/map-ps-bad.log" || fail "map.ps1: the refusal (see $WORK/map-ps-bad.log)"
# the session start, with a table whose probes always pass: the fake homes hold no team modes
printf 'claude\tcaveman\tlite\talways\t-\t-\n' > "$WORK/always.tsv"
# codex and agy write the map the same way, named by AI_CORE_MAP_TOOL for one machine; a tool map does not know is refused
AI_CORE_MAP_TOOL=codex map_sh "$WORK/org-sh/shop-web" --dry-run > "$WORK/map-codex-sh.log" 2>&1 || fail "map.sh with codex (see $WORK/map-codex-sh.log)"
grep -aq '^# shop-web — the map' "$WORK/map-codex-sh.log" && grep -q 'exec --skip-git-repo-check -s read-only' "$MAPLOG" || fail "map.sh did not run codex exec read-only or printed no map (see $WORK/map-codex-sh.log)"
AI_CORE_MAP_TOOL=agy map_sh "$WORK/org-sh/shop-web" --dry-run > "$WORK/map-agy-sh.log" 2>&1 || fail "map.sh with agy (see $WORK/map-agy-sh.log)"
grep -aq '^# shop-web — the map' "$WORK/map-agy-sh.log" && grep -q -- '--print' "$MAPLOG" || fail "map.sh did not run agy --print or printed no map (see $WORK/map-agy-sh.log)"
AI_CORE_MAP_TOOL=codex map_ps -TargetDir "$(native "$WORK/org-ps/shop-web")" -DryRun > "$WORK/map-codex-ps.log" 2>&1 || fail "map.ps1 with codex (see $WORK/map-codex-ps.log)"
AI_CORE_MAP_TOOL=agy map_ps -TargetDir "$(native "$WORK/org-ps/shop-web")" -DryRun > "$WORK/map-agy-ps.log" 2>&1 || fail "map.ps1 with agy (see $WORK/map-agy-ps.log)"
grep -aq '^# shop-web — the map' "$WORK/map-codex-ps.log" && grep -aq '^# shop-web — the map' "$WORK/map-agy-ps.log" || fail "map.ps1 with codex or agy printed no map"
AI_CORE_MAP_TOOL=hermes map_sh "$WORK/org-sh/shop-web" --dry-run > "$WORK/map-hermes.log" 2>&1 && fail "map.sh accepted a tool it does not know"
grep -aq 'map runs with claude, codex or agy' "$WORK/map-hermes.log" || fail "map.sh does not name the tools it runs with (see $WORK/map-hermes.log)"
(cd "$WORK/org-sh/shop-web" && HOME="$WORK/home-sh" PATH="$PATH_SH" AI_CORE_UPDATE_CHECK=never TEAM_MODES_FILE="$WORK/always.tsv" bash "$ROOT/bin/session-start.sh" > "$WORK/map-session.log" 2>&1) || fail "session-start.sh with a map (see $WORK/map-session.log): $(tail -n 3 "$WORK/map-session.log" | tr '\n' '|')"
grep -aq '^Map              : ✓ Generated from [0-9a-f]*, current$' "$WORK/map-session.log" || fail "session-start.sh does not name the map: $(grep -a '^Map' "$WORK/map-session.log")"
echo x >> "$WORK/org-sh/shop-web/README.md"; git -C "$WORK/org-sh/shop-web" -c user.name=check -c user.email=check@localhost commit -qam 'A change #1'
(cd "$WORK/org-sh/shop-web" && HOME="$WORK/home-sh" PATH="$PATH_SH" AI_CORE_UPDATE_CHECK=never TEAM_MODES_FILE="$WORK/always.tsv" bash "$ROOT/bin/session-start.sh" --json > "$WORK/map-session.json" 2>/dev/null) || true
[ "$(jq -r '.map_behind' "$WORK/map-session.json")" = 1 ] || fail "session-start.sh --json does not count the commits behind the map: $(jq -c '{map_commit, map_behind}' "$WORK/map-session.json")"
(cd "$WORK/org-ps/shop-web" && HOME="$WORK/home-ps" USERPROFILE="$(native "$WORK/home-ps")" PATH="$PATH_SH" AI_CORE_UPDATE_CHECK=never TEAM_MODES_FILE="$(native "$WORK/always.tsv")" pwsh -NoProfile -File "$ROOT/bin/session-start.ps1" -Json > "$WORK/map-session-ps.json" 2>/dev/null) || true
[ "$(jq -r '.map_behind' "$WORK/map-session-ps.json")" = 0 ] || fail "session-start.ps1 -Json does not report the map: $(jq -c '{map_commit, map_behind}' "$WORK/map-session-ps.json")"
git -C "$WORK/author" pull -q --rebase 2>/dev/null || fail "the author clone could not take the maps"
# The PowerShell twin creates one too: store-api of the same organisation gets store-ai-core
new_checkout "$WORK/org-ps/store-api" store-api
HOME="$WORK/home-ps" USERPROFILE="$(native "$WORK/home-ps")" PATH="$PATH_SH" GRAFT_FAKE_LOG="$(native "$WORK/layers.args")" pwsh -NoProfile -File "$ROOT/bin/init.ps1" -TargetDir "$(native "$WORK/org-ps/store-api")" -NoDoctor -DryRun > "$WORK/layers-ps-0.log" 2>&1 || fail "init.ps1 -DryRun before the project harness exists (see $WORK/layers-ps-0.log)"
grep -aq 'example-org/store-ai-core would be created from the skeleton' "$WORK/layers-ps-0.log" || fail "init.ps1 -DryRun does not announce the harness it would create"
[ ! -e "$GH_FAKE/github.com/example-org/store-ai-core.git" ] && [ ! -e "$WORK/org-ps/store-ai-core" ] || fail "init.ps1 -DryRun created the project harness"
HOME="$WORK/home-ps" USERPROFILE="$(native "$WORK/home-ps")" PATH="$PATH_SH" GRAFT_FAKE_LOG="$(native "$WORK/layers.args")" pwsh -NoProfile -File "$ROOT/bin/init.ps1" -TargetDir "$(native "$WORK/org-ps/store-api")" -NoDoctor > "$WORK/layers-ps-2.log" 2>&1 || fail "init.ps1 with a new project harness (see $WORK/layers-ps-2.log)"
grep -aq 'created: example-org/store-ai-core, private, from the skeleton' "$WORK/layers-ps-2.log" || fail "init.ps1 did not create store-ai-core"
[ -d "$GH_FAKE/github.com/example-org/store-ai-core.git" ] || fail "store-ai-core was not pushed"
grep -qxF '* text=auto eol=lf' "$WORK/org-ps/store-ai-core/.gitattributes" || fail "the harness init.ps1 created lacks the skeleton's .gitattributes"
git -C "$WORK/org-ps/store-ai-core" rm -q .gitattributes && git -C "$WORK/org-ps/store-ai-core" -c user.name=check -c user.email=check@localhost commit -q -m 'without attributes' && git -C "$WORK/org-ps/store-ai-core" push -q origin HEAD 2>/dev/null || fail "could not take .gitattributes out of store-ai-core"
HOME="$WORK/home-ps" USERPROFILE="$(native "$WORK/home-ps")" PATH="$PATH_SH" GRAFT_FAKE_LOG="$(native "$WORK/layers.args")" pwsh -NoProfile -File "$ROOT/bin/init.ps1" -TargetDir "$(native "$WORK/org-ps/store-api")" -NoDoctor > "$WORK/layers-ps-attr.log" 2>&1 || fail "init.ps1 on a harness clone without .gitattributes (see $WORK/layers-ps-attr.log)"
grep -aq 'note: example-org/store-ai-core: .gitattributes from the skeleton written into .*store-ai-core (every file LF); ai-core push commits it' "$WORK/layers-ps-attr.log" || fail "init.ps1 did not report the skeleton's .gitattributes for the older clone (see $WORK/layers-ps-attr.log)"
grep -qxF '* text=auto eol=lf' "$WORK/org-ps/store-ai-core/.gitattributes" || fail "init.ps1 did not write the skeleton's rule into the older clone"
git -C "$WORK/org-ps/store-ai-core" add .gitattributes && git -C "$WORK/org-ps/store-ai-core" -c user.name=check -c user.email=check@localhost commit -q -m 'attributes again' && git -C "$WORK/org-ps/store-ai-core" push -q origin HEAD 2>/dev/null || fail "could not commit .gitattributes back into store-ai-core"
# extends: shop-ai-core now extends store-ai-core, so the chain is store first, then shop
printf '{ "setup-ai-core": ">=1.1.0", "extends": "example-org/store-ai-core" }\n' > "$WORK/author/ai-core.json"
git -C "$WORK/author" add -A; git -C "$WORK/author" -c user.name=check -c user.email=check@localhost commit -q -m extends; git -C "$WORK/author" push -q origin HEAD
HOME="$WORK/home-sh" PATH="$PATH_SH" GRAFT_FAKE_LOG="$WORK/layers.args" bash "$ROOT/bin/init.sh" "$WORK/org-sh/shop-web" --no-doctor > "$WORK/layers-sh-3.log" 2>&1 || fail "init.sh with an extends chain (see $WORK/layers-sh-3.log)"
[ "$(sed -n 2p "$WORK/org-sh/shop-web/.ai-core/STAMP" | cut -d' ' -f1)" = store-ai-core ] && [ "$(sed -n 3p "$WORK/org-sh/shop-web/.ai-core/STAMP" | cut -d' ' -f1)" = shop-ai-core ] || fail "the extends chain is not base first in STAMP: $(tr '\n' '|' < "$WORK/org-sh/shop-web/.ai-core/STAMP")"
[ -d "$WORK/org-sh/store-ai-core" ] || fail "the base of the chain was not cloned"
# A harness that cannot be had stops init before it writes: nocreate-org may not create repositories
new_checkout "$WORK/org-sh/nocreate-web" nocreate-web nocreate-org
HOME="$WORK/home-sh" PATH="$PATH_SH" GRAFT_FAKE_LOG="$WORK/layers.args" bash "$ROOT/bin/init.sh" "$WORK/org-sh/nocreate-web" --no-doctor > "$WORK/layers-nocreate-sh.log" 2>&1 && fail "init.sh assembled the generic harness although the project harness could not be had"
grep -aq 'could not create nocreate-org/nocreate-ai-core' "$WORK/layers-nocreate-sh.log" && grep -aq 'nothing was written' "$WORK/layers-nocreate-sh.log" || fail "init.sh does not say why it stopped (see $WORK/layers-nocreate-sh.log)"
[ ! -e "$WORK/org-sh/nocreate-web/.ai-core" ] || fail "init.sh wrote into the checkout although it stopped"
new_checkout "$WORK/org-ps/nocreate-web" nocreate-web nocreate-org
HOME="$WORK/home-ps" USERPROFILE="$(native "$WORK/home-ps")" PATH="$PATH_SH" GRAFT_FAKE_LOG="$(native "$WORK/layers.args")" pwsh -NoProfile -File "$ROOT/bin/init.ps1" -TargetDir "$(native "$WORK/org-ps/nocreate-web")" -NoDoctor > "$WORK/layers-nocreate-ps.log" 2>&1 && fail "init.ps1 assembled the generic harness although the project harness could not be had"
grep -aq 'could not create nocreate-org/nocreate-ai-core' "$WORK/layers-nocreate-ps.log" && grep -aq 'nothing was written' "$WORK/layers-nocreate-ps.log" || fail "init.ps1 does not say why it stopped (see $WORK/layers-nocreate-ps.log)"
[ ! -e "$WORK/org-ps/nocreate-web/.ai-core" ] || fail "init.ps1 wrote into the checkout although it stopped"
# A harness checkout is refused, and a project folder gets the layers its repositories share
new_checkout "$WORK/harness-checkout" shop-ai-core
HOME="$WORK/home-sh" PATH="$PATH_SH" GRAFT_FAKE_LOG="$WORK/layers.args" bash "$ROOT/bin/init.sh" "$WORK/harness-checkout" --no-doctor > "$WORK/layers-refused.log" 2>&1 && fail "init.sh accepted a harness repository"
grep -aq 'harness repository' "$WORK/layers-refused.log" || fail "init.sh did not say why the harness repository is refused"
mkdir -p "$WORK/folder/.ai-core"; printf 'GRAFT_EXECUTION_MODE="skip"\n' > "$WORK/folder/.ai-core/config.env"
new_checkout "$WORK/folder/shop-web" shop-web; new_checkout "$WORK/folder/store-api" store-api
git clone -q "$GH_FAKE/github.com/example-org/shop-ai-core.git" "$WORK/home-sh/.shop-ai-core" 2>/dev/null   # where an earlier version kept it
HOME="$WORK/home-sh" PATH="$PATH_SH" GRAFT_FAKE_LOG="$WORK/layers.args" bash "$ROOT/bin/init.sh" "$WORK/folder" --no-doctor > "$WORK/layers-folder.log" 2>&1 || fail "init.sh on a project folder with layers (see $WORK/layers-folder.log)"
[ "$(tr '\n' '|' < "$WORK/folder/.ai-core/STAMP" | sed 's/ [0-9a-f-]*|/|/g')" = "setup-ai-core|store-ai-core|" ] || fail "the project folder did not get the layer its repositories share: $(tr '\n' '|' < "$WORK/folder/.ai-core/STAMP")"
grep -aq 'moved: example-org/shop-ai-core from ' "$WORK/layers-folder.log" || fail "init.sh did not move the old clone beside the repositories (see $WORK/layers-folder.log)"
[ ! -e "$WORK/home-sh/.shop-ai-core" ] && [ -d "$WORK/folder/shop-ai-core/.git" ] && [ -d "$WORK/folder/store-ai-core/.git" ] || fail "the folder does not hold both harness clones"
grep -qE '^\| `(shop|store)-ai-core`' "$WORK/folder/AGENTS.md" && fail "the folder's AGENTS.md lists a harness clone as a repository"
grep -q '^| `shop-web` |' "$WORK/folder/AGENTS.md" && grep -q '^| `store-api` |' "$WORK/folder/AGENTS.md" || fail "the folder's AGENTS.md does not list its repositories"
git -C "$WORK/folder/shop-ai-core" ls-files -z | (cd "$WORK/folder/shop-ai-core" && xargs -0 rm -f)   # every tracked file gone, the history there: an interrupted move somebody cleaned up by hand
HOME="$WORK/home-sh" PATH="$PATH_SH" GRAFT_FAKE_LOG="$WORK/layers.args" bash "$ROOT/bin/init.sh" "$WORK/folder" --no-doctor > "$WORK/layers-folder-2.log" 2>&1 || fail "init.sh on the folder with a harness clone that lost its files (see $WORK/layers-folder-2.log)"
grep -aq 'restored: the files of example-org/shop-ai-core at ' "$WORK/layers-folder-2.log" || fail "init.sh did not restore the files of the harness clone (see $WORK/layers-folder-2.log)"
[ -z "$(git -C "$WORK/folder/shop-ai-core" status --porcelain)" ] || fail "the harness clone is not whole after the restore: $(git -C "$WORK/folder/shop-ai-core" status --porcelain | tr '\n' '|')"
# map --all: every repository under the folder, the harness clones excepted, one push, then init --all, on both twins
map_sh --all "$WORK/folder" > "$WORK/map-all-sh.log" 2>&1 || fail "map.sh --all (see $WORK/map-all-sh.log)"
grep -aq '^==> map --all: 2 map(s) were written$' "$WORK/map-all-sh.log" || fail "map.sh --all did not write the two maps: $(grep -a 'map --all' "$WORK/map-all-sh.log")"
for r in shop-web store-api; do
  h="$WORK/folder/${r%%-*}-ai-core/repos/$r/AGENTS.md"
  head -n1 "$h" | grep -q 'ai-core map: generated' && head -n1 "$WORK/folder/$r/AGENTS.md" | grep -q 'ai-core map: generated' || fail "map.sh --all: $r has no map in the harness or the checkout"
  [ -z "$(git -C "$WORK/folder/${r%%-*}-ai-core" status --porcelain)" ] || fail "map.sh --all did not push ${r%%-*}-ai-core"
done
map_ps -All "$(native "$WORK/folder")" > "$WORK/map-all-ps.log" 2>&1 || fail "map.ps1 -All (see $WORK/map-all-ps.log)"
grep -aq '^==> map -All: 2 map(s) were written$' "$WORK/map-all-ps.log" && grep -q '^A shop\. ps$' "$WORK/folder/store-api/AGENTS.md" || fail "map.ps1 -All did not write the two maps and bring them into the checkouts: $(grep -a 'map -All' "$WORK/map-all-ps.log"); store-api: $(grep -a 'A shop' "$WORK/folder/store-api/AGENTS.md")"
echo "  created, cloned, moved from the home directory, an interrupted move completed, lost files restored, assembled and compared on both twins; extends base first; a harness that cannot be had stops init; a harness checkout refused; the folder shares the base and its map skips the clones; maps written by the agent CLI, pushed and in the checkouts, people's rules kept, a bad output refused, --all over the folder, on both twins"
exit 0
