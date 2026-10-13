#!/usr/bin/env bash
# session-start where the harness is not installed; one section of the suite, run by tests/check.sh with the others
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

section "session-start fails where the harness is not installed"
mkdir -p "$WORK/none"
(cd "$WORK/none" && bash "$ROOT/bin/session-start.sh" > /dev/null 2>&1) && fail "session-start.sh exited 0 without rules"
(cd "$WORK/none" && pwsh -NoProfile -File "$(native "$ROOT/bin/session-start.ps1")" > /dev/null 2>&1) && fail "session-start.ps1 exited 0 without rules"

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

start_source() { # start_source <twin> <directory> <format> <expected exit>
  local twin="$1" dir="$2" format="$3" expected="$4" rc=0
  if [ "$twin" = sh ]; then
    (cd "$dir" && bash "$ROOT/bin/session-start.sh" ${format:+--json}) > "$WORK/start-$twin.log" 2>&1 || rc=$?
  else
    (cd "$dir" && pwsh -NoProfile -File "$(native "$ROOT/bin/session-start.ps1")" ${format:+-Json}) > "$WORK/start-$twin.log" 2>&1 || rc=$?
  fi
  [ "$rc" = "$expected" ] || fail "source start.$twin ($format): expected exit $expected, got $rc: $(cat "$WORK/start-$twin.log")"
  if [ "$format" = json ]; then
    jq -e --argjson ready "$([ "$expected" = 0 ] && echo true || echo false)" '.source_ready == $ready and .refused == ($ready | not)' "$WORK/start-$twin.log" >/dev/null || fail "source start.$twin has false readiness facts"
  elif [ "$expected" = 0 ]; then
    grep -aF 'Harness state    : ✓ Source inputs validated (no assembly)' "$WORK/start-$twin.log" >/dev/null || fail "source start.$twin claims assembly"
    grep -aF 'Map              : – Harness source: read README.md' "$WORK/start-$twin.log" >/dev/null || fail "source start.$twin recommends a product map"
    grep -aF 'run ai-core init' "$WORK/start-$twin.log" >/dev/null && fail "source start.$twin recommends init"
  fi
  [ ! -e "$dir/.ai-core" ] && [ ! -e "$dir/AGENTS.md" ] || fail "startup wrote product files into a source"
}

section "a tracked harness source starts without product assembly, on both twins"
for t in sh ps1; do
  start_source "$t" "$source_repo" '' 0
  start_source "$t" "$source_repo" json 0
  cp "$WORK/start-$t.log" "$WORK/source-$t.json"
done
node - "$WORK/source-sh.json" "$WORK/source-ps1.json" <<'JS'
const fs = require('fs');
const [a, b] = process.argv.slice(2).map(p => JSON.parse(fs.readFileSync(p, 'utf8')));
const normalize = p => p.replace(/\\/g, '/').replace(/^\/([a-z])\//i, (_, d) => `${d.toUpperCase()}:/`);
for (const v of [a, b]) {
  v.root = normalize(v.root);
  v.rule_sources = v.rule_sources.map(normalize);
  if (v.harness_source !== 'example-org/shop-ai-core' || v.harness_current !== null || v.rules_present || v.rules_path !== '' || v.rule_sources.length !== 2) throw Error('source facts are incorrect');
}
if (JSON.stringify(a) !== JSON.stringify(b)) {
  for (const k of Object.keys(a)) if (JSON.stringify(a[k]) !== JSON.stringify(b[k])) throw Error(`twins disagree on ${k}`);
}
JS

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
  for t in sh ps1; do start_source "$t" "$broken" json 1; done
done

section "a valid local inherited source is read base first"
base="$WORK/base-ai-core"; git clone -q "$source_repo" "$base"
git -C "$base" remote set-url origin https://github.com/example-org/base-ai-core.git
printf '{"setup-ai-core":">=1.1.0","extends":"example-org/base-ai-core"}\n' > "$source_repo/ai-core.json"
for t in sh ps1; do
  start_source "$t" "$source_repo" json 0
  jq -e '.rule_sources | length == 3 and (.[1] | gsub("\\\\"; "/") | endswith("base-ai-core/rules"))' "$WORK/start-$t.log" >/dev/null || fail "source start.$t omitted inherited rules"
done
git -C "$source_repo" restore ai-core.json

section "the command source itself validates direct source files and counterparts"
setup_source="$WORK/setup-source"; git clone -q "$ROOT" "$setup_source"
git -C "$setup_source" remote set-url origin https://github.com/example-org/setup-ai-core.git
for t in sh ps1; do start_source "$t" "$setup_source" json 0; done
for defect in invalid-version counterpart; do
  if [ "$defect" = invalid-version ]; then printf 'invalid\n' > "$setup_source/VERSION"
  else rm "$setup_source/bin/session-start.ps1"; fi
  for t in sh ps1; do start_source "$t" "$setup_source" json 1; done
  git -C "$setup_source" restore VERSION bin/session-start.ps1
done

section "missing generic source inputs refuse instead of producing partial JSON or READY"
command_source="$WORK/command-source"; git clone -q "$ROOT" "$command_source"
cp "$ROOT/bin/session-start.sh" "$ROOT/bin/session-start.ps1" "$command_source/bin/"
cp "$ROOT/lib/layers.sh" "$ROOT/lib/Layers.psm1" "$command_source/lib/"
for defect in missing-version empty-version missing-skill-rules missing-section; do
  case "$defect" in
    missing-version) rm "$command_source/VERSION" ;;
    empty-version) : > "$command_source/VERSION" ;;
    missing-skill-rules) rm "$command_source/rules/skills.md" ;;
    missing-section) rm "$command_source/rules/10-the-code-never-lies.md" ;;
  esac
  for t in sh ps1; do
    rc=0
    if [ "$t" = sh ]; then (cd "$source_repo" && bash "$command_source/bin/session-start.sh" --json) > "$WORK/generic-$t.json" 2>&1 || rc=$?
    else (cd "$source_repo" && pwsh -NoProfile -File "$(native "$command_source/bin/session-start.ps1")" -Json) > "$WORK/generic-$t.json" 2>&1 || rc=$?; fi
    [ "$rc" = 1 ] || fail "$defect passed on $t"
    jq -e '.refused and .source_ready == false and (.source_error | length > 0)' "$WORK/generic-$t.json" >/dev/null || fail "$defect produced incorrect JSON on $t"
  done
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
  for t in sh ps1; do
    rc=0
    if [ "$t" = sh ]; then (cd "$bad" && bash "$ROOT/bin/session-start.sh" --json) > "$WORK/impostor-$t.json" 2>&1 || rc=$?
    else (cd "$bad" && pwsh -NoProfile -File "$(native "$ROOT/bin/session-start.ps1")" -Json) > "$WORK/impostor-$t.json" 2>&1 || rc=$?; fi
    [ "$rc" = 1 ] || fail "$impostor passed source start.$t"
  done
done

section "source worktrees use their actual Git origin and stay unassembled"
git -C "$source_repo" worktree add -q -b source-work "$WORK/source-work"
for t in sh ps1; do start_source "$t" "$WORK/source-work" json 0; done

section "the checkout shim leaves source worktrees unassembled"
(cd "$WORK/source-work" && PATH="$ROOT/bin:$PATH" bash "$ROOT/.githooks/post-checkout" old new 1 > "$WORK/source-hook.log" 2>&1) || fail "source checkout hook failed"
[ ! -e "$WORK/source-work/.ai-core" ] || fail "source checkout hook assembled product files"
grep -aF 'post-checkout: harness source;' "$WORK/source-hook.log" >/dev/null || fail "source checkout hook omitted source workflow"

section "init still refuses sources before copying a main checkout's old assembly"
mkdir -p "$source_repo/.ai-core/rules"
printf 'old product assembly\n' > "$source_repo/.ai-core/rules/rules.md"
for t in sh ps1; do
  rc=0
  if [ "$t" = sh ]; then bash "$ROOT/bin/init.sh" "$WORK/source-work" --no-doctor > "$WORK/init-source-$t.log" 2>&1 || rc=$?
  else pwsh -NoProfile -File "$(native "$ROOT/bin/init.ps1")" -TargetDir "$(native "$WORK/source-work")" -NoDoctor > "$WORK/init-source-$t.log" 2>&1 || rc=$?; fi
  [ "$rc" = 1 ] && [ ! -e "$WORK/source-work/.ai-core" ] || fail "init.$t assembled a source worktree"
done

section "missing team modes refuse a valid source before readiness processing"
printf 'codex\tmissing\ton\tfile:/a-path-that-does-not-exist\t-\t-\n' > "$WORK/missing-modes.tsv"
for t in sh ps1; do
  rc=0
  if [ "$t" = sh ]; then (cd "$source_repo" && TEAM_MODES_FILE="$WORK/missing-modes.tsv" bash "$ROOT/bin/session-start.sh" --tool codex --json) > "$WORK/mode-$t.json" 2>&1 || rc=$?
  else (cd "$source_repo" && TEAM_MODES_FILE="$(native "$WORK/missing-modes.tsv")" pwsh -NoProfile -File "$(native "$ROOT/bin/session-start.ps1")" -Tool codex -Json) > "$WORK/mode-$t.json" 2>&1 || rc=$?; fi
  [ "$rc" = 1 ] || fail "missing source modes passed on $t"
  jq -e '.refused and (.team_modes | any(startswith("MISSING")))' "$WORK/mode-$t.json" >/dev/null || fail "missing source modes were not reported on $t"
done
exit 0
