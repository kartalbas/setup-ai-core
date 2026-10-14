#!/usr/bin/env bash
# session-start where the harness is not installed; one section of the suite, run by tests/check.sh with the others
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

section "session-start fails where the harness is not installed"
mkdir -p "$WORK/none"
(cd "$WORK/none" && bash "$ROOT/bin/session-start.sh" > /dev/null 2>&1) && fail "session-start.sh exited 0 without rules"

make_gh_fake
export PATH="$PATH_SH"
source_repo="$WORK/renamed-source"
git init -q "$source_repo"
git -C "$source_repo" remote add origin https://github.com/example-org/shop-ai-core.git
cp -R "$ROOT/skeleton/." "$source_repo/"
git -C "$source_repo" add .
git -C "$source_repo" commit -qm 'the project source #1'
printf '## Checked\n\n- **A real rule.** Every rule carries its enforcement. [review]\n' > "$source_repo/rules/35-checked.md"
git -C "$source_repo" add rules/35-checked.md; git -C "$source_repo" commit -qm 'the source rule #1'

start_source() { # start_source <directory> <format> <expected exit>
  local dir="$1" format="$2" expected="$3" rc=0 had=0
  [ ! -e "$dir/AGENTS.md" ] || had=1
  (cd "$dir" && bash "$ROOT/bin/session-start.sh" ${format:+--json}) > "$WORK/start.log" 2>&1 || rc=$?
  [ "$rc" = "$expected" ] || fail "source start ($format): expected exit $expected, got $rc: $(cat "$WORK/start.log")"
  if [ "$format" = json ]; then
    jq -e --argjson ready "$([ "$expected" = 0 ] && echo true || echo false)" '.source_ready == $ready and .refused == ($ready | not) and ((.source_error | length > 0) == ($ready | not))' "$WORK/start.log" >/dev/null || fail "source start has false readiness facts"
  elif [ "$expected" = 0 ]; then
    grep -aF 'Harness state    : ✓ Source inputs validated (no assembly)' "$WORK/start.log" >/dev/null || fail "source start claims assembly"
    grep -aF 'Map              : – Harness source: read README.md' "$WORK/start.log" >/dev/null || fail "source start recommends a product map"
    grep -aF 'run ai-core init' "$WORK/start.log" >/dev/null && fail "source start recommends init"
  fi
  [ ! -e "$dir/.ai-core" ] || fail "startup wrote the assembled harness into a source"
  if [ "$expected" = 0 ]; then
    # The tool loads AGENTS.md: it names each rule file where it is written, base layer first
    local file
    for file in "$ROOT"/rules/[0-9]*.md; do
      grep -aqxF "  - @$file" "$dir/AGENTS.md" || grep -aqxF "  - @${file#"$dir"/}" "$dir/AGENTS.md" || fail "the source's AGENTS.md does not name the base rule file ${file##*/} where it is written: $(cat "$dir/AGENTS.md" 2>&1)"
    done
    if [ -f "$dir/rules/35-checked.md" ]; then
      grep -aqxF '  - @rules/35-checked.md' "$dir/AGENTS.md" || fail "the source's AGENTS.md does not name its own rule file"
      [ "$(grep -n "@$ROOT/rules/" "$dir/AGENTS.md" | head -1 | cut -d: -f1)" -lt "$(grep -n '@rules/35-checked.md' "$dir/AGENTS.md" | cut -d: -f1)" ] || fail "the source's AGENTS.md does not name the base layer first"
    fi
    grep -aqF -- "- When a skill or a tool is used: @$ROOT/rules/skills.md" "$dir/AGENTS.md" || fail "the source's AGENTS.md does not name the skills file where it is written"
    grep -aq 'rules\.md' "$dir/AGENTS.md" && fail "the source's AGENTS.md names an assembled copy"
    [ -z "$(git -C "$dir" status --porcelain -- AGENTS.md)" ] || fail "the source's AGENTS.md shows in its status"
  else
    [ "$had" = 1 ] || [ ! -e "$dir/AGENTS.md" ] || fail "a source refused at start got an AGENTS.md"
  fi
}

section "a tracked harness source starts without product assembly"
start_source "$source_repo" '' 0
start_source "$source_repo" json 0
jq -e '.harness_source == "example-org/shop-ai-core" and .harness_current == null and .rules_present == false and .rules_path == "" and (.rule_sources | length) == 2' "$WORK/start.log" >/dev/null || fail "source facts are incorrect"

section "a source's AGENTS.md left by an old assembly is replaced, and an unchanged one is not written"
stale="$WORK/stale-source"; git clone -q "$source_repo" "$stale"
git -C "$stale" remote set-url origin https://github.com/example-org/shop-ai-core.git
# PLANTED: the AGENTS.md an assembly wrote, which loads a copy of the rules that ages
printf '# old\n- The engineering rules: @.ai-core/rules/rules.md\n' > "$stale/AGENTS.md"
printf '# a last line without its newline' > "$stale/.git/info/exclude"
start_source "$stale" '' 0
grep -aq 'Rule files       : AGENTS.md names the [1-9][0-9]* rule files' "$WORK/start.log" || fail "session start does not say how many rule files AGENTS.md names: $(cat "$WORK/start.log")"
touch -d '2000-01-01' "$stale/AGENTS.md"
start_source "$stale" '' 0
[ "$(date -r "$stale/AGENTS.md" +%Y)" = 2000 ] || fail "session start rewrote an AGENTS.md whose text had not changed"
[ "$(grep -c '^/AGENTS.md$' "$stale/.git/info/exclude")" = 1 ] || fail "session start registered AGENTS.md in the exclude file not exactly once: $(cat "$stale/.git/info/exclude")"
grep -qx '# a last line without its newline' "$stale/.git/info/exclude" || fail "session start joined its entry to the exclude file's last line"
printf '## Added\n\n- **A new rule.** It is read at once. [review]\n' > "$stale/rules/36-added.md"
git -C "$stale" add rules/36-added.md; git -C "$stale" commit -qm 'a new rule #1'
start_source "$stale" '' 0
grep -aqxF '  - @rules/36-added.md' "$stale/AGENTS.md" || fail "a rule file added to the source is not named at the next session start"

section "a source that commits its own AGENTS.md keeps it, and a space in a rule file's path is escaped"
mine="$WORK/committed-source"; git clone -q "$source_repo" "$mine"
git -C "$mine" remote set-url origin https://github.com/example-org/shop-ai-core.git
# PLANTED: the source's own AGENTS.md, which is somebody's work
printf '# ours\n' > "$mine/AGENTS.md"; git -C "$mine" add AGENTS.md; git -C "$mine" -c user.email=t@example.invalid -c user.name=t commit -qm 'our own AGENTS.md #1'
(cd "$mine" && bash "$ROOT/bin/session-start.sh") > "$WORK/mine.log" 2>&1 || fail "a source with a committed AGENTS.md is refused: $(cat "$WORK/mine.log")"
[ "$(cat "$mine/AGENTS.md")" = '# ours' ] || fail "session start overwrote the source's committed AGENTS.md"
[ -z "$(git -C "$mine" status --porcelain)" ] || fail "session start left a change in a source with a committed AGENTS.md: $(git -C "$mine" status --porcelain)"
grep -q '^/AGENTS.md$' "$mine/.git/info/exclude" && fail "session start excluded a committed AGENTS.md"
grep -aq 'Rule files       : – AGENTS.md is committed here' "$WORK/mine.log" || fail "session start does not say it left the committed AGENTS.md: $(cat "$WORK/mine.log")"
spaced="$WORK/spaced-source"; git clone -q "$source_repo" "$spaced"
git -C "$spaced" remote set-url origin https://github.com/example-org/shop-ai-core.git
printf '## Spaced\n\n- **A rule in a spaced file.** It is named. [review]\n' > "$spaced/rules/36 spaced.md"
git -C "$spaced" add "rules/36 spaced.md"; git -C "$spaced" -c user.email=t@example.invalid -c user.name=t commit -qm 'a spaced rule file #1'
(cd "$spaced" && bash "$ROOT/bin/session-start.sh") > "$WORK/spaced.log" 2>&1 || fail "a source with a spaced rule file is refused: $(cat "$WORK/spaced.log")"
grep -aqxF '  - @rules/36\ spaced.md' "$spaced/AGENTS.md" || fail "the space in a rule file's path is not escaped: $(grep -a spaced "$spaced/AGENTS.md")"

section "a source that also holds an assembled rules file reports it as measured"
assembled="$WORK/assembled-source"; git clone -q "$source_repo" "$assembled"
git -C "$assembled" remote set-url origin https://github.com/example-org/shop-ai-core.git
mkdir -p "$assembled/.ai-core/rules"; printf 'assembled\n' > "$assembled/.ai-core/rules/rules.md"
(cd "$assembled" && bash "$ROOT/bin/session-start.sh" --json) > "$WORK/assembled.json" 2>&1 || fail "a source with an assembled rules file is refused: $(cat "$WORK/assembled.json")"
jq -e '.rules_present == true and .rules_path == ".ai-core/rules/rules.md"' "$WORK/assembled.json" >/dev/null || fail "a source with an assembled rules file reports no rules file"

section "an origin is a harness source only by its repository name"
. "$ROOT/lib/layers.sh"
classify() { # classify <repository name or ->  prints the source identity, or "product"
  local dir="$WORK/classify-$1"; git init -q "$dir"
  [ "$1" = - ] || git -C "$dir" remote add origin "https://github.com/example-org/$1.git"
  harness_source_of "$dir" || echo product
}
for name in ai-core ai-core-web my-ai-core-tool -; do
  [ "$(classify "$name")" = product ] || fail "$name is classified as a harness source"
done
[ "$(classify setup-ai-core)" = example-org/setup-ai-core ] || fail "a fork of setup-ai-core is not a harness source"
[ "$(classify x-ai-core)" = example-org/x-ai-core ] || fail "x-ai-core is not a harness source"

section "source readiness rejects missing, invalid and incompatible inputs"
for defect in manifest multiple-manifests missing-manifest missing-readme missing-rules missing-section rule skill version extends cycle; do
  broken="$WORK/broken-$defect"
  git clone -q "$source_repo" "$broken"
  git -C "$broken" remote set-url origin https://github.com/example-org/shop-ai-core.git
  case "$defect" in
    manifest) printf 'invalid\n' > "$broken/ai-core.json" ;;
    multiple-manifests) printf '{}\n{"setup-ai-core":">=1.1.0"}\n' > "$broken/ai-core.json" ;;
    missing-manifest) rm "$broken/ai-core.json" ;;
    missing-readme) rm "$broken/README.md" ;;
    missing-rules) rm -r "$broken/rules" ;;
    missing-section) rm "$broken/rules/35-checked.md" ;;
    rule) printf '## Broken\n\n- **A rule with no enforcement.**\n' > "$broken/rules/35-broken.md" ;;
    skill) mkdir -p "$broken/skills/broken"; printf 'no front matter\n' > "$broken/skills/broken/SKILL.md" ;;
    version) printf '{"setup-ai-core":">=9999.0.0"}\n' > "$broken/ai-core.json" ;;
    extends) printf '{"setup-ai-core":">=1.1.0","extends":"example-org/missing-ai-core"}\n' > "$broken/ai-core.json" ;;
    cycle) printf '{"setup-ai-core":">=1.1.0","extends":"example-org/shop-ai-core"}\n' > "$broken/ai-core.json" ;;
  esac
  start_source "$broken" json 1
done

section "a valid local inherited source is read base first"
base="$WORK/base-ai-core"; git clone -q "$source_repo" "$base"
git -C "$base" remote set-url origin https://github.com/example-org/base-ai-core.git
printf '{"setup-ai-core":">=1.1.0","extends":"example-org/base-ai-core"}\n' > "$source_repo/ai-core.json"
start_source "$source_repo" json 0
jq -e '.rule_sources | length == 3 and (.[1] | endswith("base-ai-core/rules"))' "$WORK/start.log" >/dev/null || fail "source start omitted inherited rules"
git -C "$source_repo" restore ai-core.json

section "the command source itself validates its direct source files"
setup_source="$WORK/setup-source"; git clone -q "$ROOT" "$setup_source"
git -C "$setup_source" remote set-url origin https://github.com/example-org/setup-ai-core.git
start_source "$setup_source" json 0
printf 'invalid\n' > "$setup_source/VERSION"
start_source "$setup_source" json 1
git -C "$setup_source" restore VERSION
rm "$setup_source/lib/layers.sh"
start_source "$setup_source" json 1
git -C "$setup_source" restore lib/layers.sh

section "missing generic source inputs refuse instead of producing partial JSON or READY"
command_source="$WORK/command-source"; git clone -q "$ROOT" "$command_source"
cp "$ROOT/bin/session-start.sh" "$command_source/bin/"
cp "$ROOT/lib/layers.sh" "$command_source/lib/"
for defect in missing-version empty-version missing-skill-rules missing-section; do
  case "$defect" in
    missing-version) rm "$command_source/VERSION" ;;
    empty-version) : > "$command_source/VERSION" ;;
    missing-skill-rules) rm "$command_source/rules/skills.md" ;;
    missing-section) rm "$command_source/rules/10-the-code-never-lies.md" ;;
  esac
  rc=0
  (cd "$source_repo" && bash "$command_source/bin/session-start.sh" --json) > "$WORK/generic.json" 2>&1 || rc=$?
  [ "$rc" = 1 ] || fail "$defect passed"
  jq -e '.refused and .source_ready == false and (.source_error | length > 0)' "$WORK/generic.json" >/dev/null || fail "$defect produced incorrect JSON"
  git -C "$command_source" restore VERSION rules
done

section "a source suffix, untracked skeleton or product origin cannot claim readiness"
for impostor in suffix untracked product; do
  bad="$WORK/$impostor-ai-core"; git init -q "$bad"
  git -C "$bad" remote add origin https://github.com/example-org/shop-ai-core.git
  if [ "$impostor" != suffix ]; then cp -R "$ROOT/skeleton/." "$bad/"; fi
  if [ "$impostor" = product ]; then
    git -C "$bad" add .; git -C "$bad" commit -qm 'a product #1'
    git -C "$bad" remote set-url origin https://github.com/example-org/shop-web.git
  fi
  rc=0
  (cd "$bad" && bash "$ROOT/bin/session-start.sh" --json) > "$WORK/impostor.json" 2>&1 || rc=$?
  [ "$rc" = 1 ] || fail "$impostor passed source start"
done

section "source worktrees use their actual Git origin and stay unassembled"
git -C "$source_repo" worktree add -q -b source-work "$WORK/source-work"
start_source "$WORK/source-work" json 0

section "the checkout shim leaves source worktrees unassembled"
(cd "$WORK/source-work" && PATH="$ROOT/bin:$PATH" bash "$ROOT/.githooks/post-checkout" old new 1 > "$WORK/source-hook.log" 2>&1) || fail "source checkout hook failed"
[ ! -e "$WORK/source-work/.ai-core" ] || fail "source checkout hook assembled product files"
grep -aF 'post-checkout: harness source;' "$WORK/source-hook.log" >/dev/null || fail "source checkout hook omitted source workflow"

section "init still refuses sources before copying a main checkout's old assembly"
mkdir -p "$source_repo/.ai-core/rules"
printf 'old product assembly\n' > "$source_repo/.ai-core/rules/rules.md"
rc=0
bash "$ROOT/bin/init.sh" "$WORK/source-work" --no-doctor > "$WORK/init-source.log" 2>&1 || rc=$?
[ "$rc" = 1 ] && [ ! -e "$WORK/source-work/.ai-core" ] || fail "init assembled a source worktree"

section "missing team modes refuse a valid source before readiness processing"
printf 'codex\tmissing\ton\tfile:/a-path-that-does-not-exist\t-\t-\n' > "$WORK/missing-modes.tsv"
rc=0
(cd "$source_repo" && TEAM_MODES_FILE="$WORK/missing-modes.tsv" bash "$ROOT/bin/session-start.sh" --tool codex --json) > "$WORK/mode.json" 2>&1 || rc=$?
[ "$rc" = 1 ] || fail "missing source modes passed"
jq -e '.refused and (.team_modes | any(startswith("MISSING")))' "$WORK/mode.json" >/dev/null || fail "missing source modes were not reported"
exit 0
