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
  local dir="$1" format="$2" expected="$3" rc=0
  (cd "$dir" && bash "$ROOT/bin/session-start.sh" ${format:+--json}) > "$WORK/start.log" 2>&1 || rc=$?
  [ "$rc" = "$expected" ] || fail "source start ($format): expected exit $expected, got $rc: $(cat "$WORK/start.log")"
  if [ "$format" = json ]; then
    jq -e --argjson ready "$([ "$expected" = 0 ] && echo true || echo false)" '.source_ready == $ready and .refused == ($ready | not) and ((.source_error | length > 0) == ($ready | not))' "$WORK/start.log" >/dev/null || fail "source start has false readiness facts"
  elif [ "$expected" = 0 ]; then
    grep -aF 'Harness state    : ✓ Source inputs validated (no assembly)' "$WORK/start.log" >/dev/null || fail "source start claims assembly"
    grep -aF 'Map              : – Harness source: read README.md' "$WORK/start.log" >/dev/null || fail "source start recommends a product map"
    grep -aF 'run ai-core init' "$WORK/start.log" >/dev/null && fail "source start recommends init"
  fi
  [ ! -e "$dir/.ai-core" ] && [ ! -e "$dir/AGENTS.md" ] || fail "startup wrote product files into a source"
}

section "a tracked harness source starts without product assembly"
start_source "$source_repo" '' 0
start_source "$source_repo" json 0
jq -e '.harness_source == "example-org/shop-ai-core" and .harness_current == null and .rules_present == false and .rules_path == "" and (.rule_sources | length) == 2' "$WORK/start.log" >/dev/null || fail "source facts are incorrect"

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
