#!/usr/bin/env bash
# Verify the harness itself: syntax of every script, and that both installers
# deploy the same files and leave a target where session-start runs.
#
#   bash tests/check.sh
#
# Needs bash, pwsh and node. Runs Graft in skip mode, so nothing touches the network.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
# pwsh on Windows needs a native path
native() { cygpath -w "$1" 2>/dev/null || echo "$1"; }

echo "==> syntax"
for f in "$ROOT"/bin/*.sh "$ROOT/bin/ai-core"; do bash -n "$f" || fail "bash -n $f"; done
PS_EXPECTED="$(ls "$ROOT"/bin/*.ps1 | wc -l | tr -d ' ')"
PS_SCANNED="$(CHECK_ROOT="$(native "$ROOT")" pwsh -NoProfile -Command '
  $bad = 0; $n = 0
  Get-ChildItem (Join-Path $env:CHECK_ROOT "bin/*.ps1") | ForEach-Object {
    $n++
    $e = $null
    [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$e) | Out-Null
    if ($e) { [Console]::Error.WriteLine("  $($_.Name): $($e[0].Message)"); $bad = 1 }
  }
  Write-Output $n
  exit $bad
')" || fail "PowerShell parse"
[ "$PS_SCANNED" = "$PS_EXPECTED" ] || fail "PowerShell parse scanned $PS_SCANNED of $PS_EXPECTED scripts"
echo "  $(ls "$ROOT"/bin/*.sh | wc -l | tr -d ' ') bash scripts, the ai-core launcher and $PS_SCANNED PowerShell scripts parse"

echo "==> every rule carries its enforcement tag, on both twins"
bash "$ROOT/bin/rules-check.sh" "$ROOT/rules" > /dev/null || fail "rules-check.sh on rules/"
pwsh -NoProfile -File "$ROOT/bin/rules-check.ps1" -RulesFile "$(native "$ROOT/rules")" > /dev/null || fail "rules-check.ps1 on rules/"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> doctor reports an old Node.js and a missing gh login the same way on both twins"
mkdir -p "$WORK/doctorbin"
printf '#!/bin/sh\necho v18.0.0\n' > "$WORK/doctorbin/node"
printf '#!/bin/sh\nif [ "$1" = "--version" ]; then echo "gh version 0.0.0"; else exit 1; fi\n' > "$WORK/doctorbin/gh"
chmod +x "$WORK/doctorbin/node" "$WORK/doctorbin/gh"
printf '@echo v18.0.0\r\n' > "$WORK/doctorbin/node.cmd"
printf '@if "%%1"=="--version" (echo gh version 0.0.0) else (exit /b 1)\r\n' > "$WORK/doctorbin/gh.cmd"
PATH="$WORK/doctorbin:$PATH" bash "$ROOT/bin/doctor.sh" --no-install > "$WORK/doctor.sh.log" 2>&1 && fail "doctor.sh exited 0 with an old Node.js"
PATH="$WORK/doctorbin:$PATH" pwsh -NoProfile -File "$ROOT/bin/doctor.ps1" -NoInstall > "$WORK/doctor.ps1.log" 2>&1 && fail "doctor.ps1 exited 0 with an old Node.js"
for t in sh ps1; do
  grep -aq 'node .*too old' "$WORK/doctor.$t.log" || fail "doctor.$t did not report the old Node.js"
  grep -aq 'gh .*not logged in' "$WORK/doctor.$t.log" || fail "doctor.$t did not report the missing gh login"
  grep -aq 'doctor: 2 problem' "$WORK/doctor.$t.log" || fail "doctor.$t did not count 2 problems"
done
echo "  both exit 1 with the same two problems"

echo "==> bootstrap both twins"
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
  [ ! -e "$WORK/agents-$t/.windsurfrules" ] && [ ! -e "$WORK/agents-$t/.github" ] && [ ! -e "$WORK/agents-$t/.openhands" ] || fail "init.$t deployed the pointer of an agent the project does not serve"
done
echo "  AGENTS=\"cursor claude\": .cursorrules deployed, .windsurfrules, copilot and openhands not, on both twins"

(cd "$WORK/sh" && find . -type f | sort) > "$WORK/sh.list"
(cd "$WORK/ps1" && find . -type f | sort) > "$WORK/ps1.list"
if ! diff "$WORK/sh.list" "$WORK/ps1.list"; then fail "init.sh and init.ps1 deployed different files"; fi
echo "  $(wc -l < "$WORK/sh.list") files, identical on both twins"

echo "==> install: --source uses the clone as it is, --repo clones and a second run pulls, the ai-core command runs init, on both twins"
bash "$ROOT/bin/install.sh" --source "$ROOT" --dir "$WORK/not-created-sh" --no-path --no-doctor > "$WORK/install.sh.log" 2>&1 || fail "install.sh --source (see $WORK/install.sh.log)"
[ ! -e "$WORK/not-created-sh" ] || fail "install.sh --source created something"
CORE_SH="$WORK/home-sh/.setup-ai-core"
bash "$ROOT/bin/install.sh" --repo "$ROOT" --dir "$CORE_SH" --no-path --no-doctor > "$WORK/install.sh.log" 2>&1 || fail "install.sh --repo (see $WORK/install.sh.log)"
[ -d "$CORE_SH/.git" ] || fail "install.sh --repo did not clone"
bash "$ROOT/bin/install.sh" --repo "$ROOT" --dir "$CORE_SH" --no-path --no-doctor > "$WORK/install.sh.log" 2>&1 || fail "install.sh second run (see $WORK/install.sh.log)"
grep -q "pulling" "$WORK/install.sh.log" || fail "install.sh second run did not pull"
[ "$("$CORE_SH/bin/ai-core" version)" = "$(tr -d '\r\n' < "$ROOT/VERSION")" ] || fail "ai-core version from the clone"
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
grep -q "pulling" "$WORK/install.ps1.log" || fail "install.ps1 second run did not pull"
[ "$(pwsh -NoProfile -File "$CORE_PS/bin/ai-core.ps1" version | tr -d '\r')" = "$(tr -d '\r\n' < "$ROOT/VERSION")" ] || fail "ai-core.ps1 version from the clone"
mkdir -p "$WORK/via-ps/.ai-core"; printf 'GRAFT_EXECUTION_MODE="skip"\n' > "$WORK/via-ps/.ai-core/config.env"
pwsh -NoProfile -File "$ROOT/bin/ai-core.ps1" init -TargetDir "$(native "$WORK/via-ps")" -NoDoctor > /dev/null 2>&1 || fail "ai-core.ps1 init through the command"
(cd "$WORK/via-ps" && find . -type f | sort) | diff - "$WORK/sh.list" > /dev/null || fail "init.ps1 through the command deployed a different file set"
echo "  --source leaves the clone alone, --repo clones and pulls, init through both commands deploys the same files"

echo "==> the assembled rules file: one section per source file, identical on both twins, every rule tagged"
SECTIONS="$(ls "$ROOT"/rules/[0-9][0-9]-*.md | wc -l | tr -d " ")"
MARKERS="$(grep -c "^<!-- setup-ai-core " "$WORK/sh/.ai-core/rules/rules.md")"
[ "$MARKERS" = "$SECTIONS" ] || fail "assembled rules.md has $MARKERS section markers, expected $SECTIONS"
cmp -s "$WORK/sh/.ai-core/rules/rules.md" "$WORK/ps1/.ai-core/rules/rules.md" || fail "assembled rules.md differs between the twins"
bash "$ROOT/bin/rules-check.sh" "$WORK/sh/.ai-core/rules/rules.md" > /dev/null || fail "rules-check on the assembled rules.md"
echo "  $SECTIONS sections assembled"

echo "==> second run creates nothing"
bash "$ROOT/bin/init.sh" "$WORK/sh" --no-doctor 2>&1 | grep -q 'Created' && fail "init.sh is not idempotent"
pwsh -NoProfile -File "$ROOT/bin/init.ps1" -TargetDir "$(native "$WORK/ps1")" -NoDoctor 2>&1 | grep -aq 'Created' && fail "init.ps1 is not idempotent"
(cd "$WORK/sh" && find . -type f | sort) | diff - "$WORK/sh.list" > /dev/null || fail "init.sh changed the file set on re-run"

echo "==> session-start in each target (with a team-modes table whose probes always pass, so the tools of this machine do not decide)"
printf "claude	mode	on	always	-	-
codex	mode	on	always	-	-
gemini	mode	on	always	-	-
" > "$WORK/modes.tsv"; export TEAM_MODES_FILE="$WORK/modes.tsv"
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

echo "==> nothing to commit after init, in a clone and in a worktree, for both twins"
for twin in sh ps1; do
  git init -q "$WORK/repo-$twin"
  git -C "$WORK/repo-$twin" -c user.name=check -c user.email=check@localhost commit -q --allow-empty -m init
  git -C "$WORK/repo-$twin" worktree add -q "$WORK/wt-$twin" > /dev/null 2>&1 || fail "git worktree add"
  for t in "repo-$twin" "wt-$twin"; do
    mkdir -p "$WORK/$t/.ai-core"
    printf 'GRAFT_EXECUTION_MODE="skip"\n' > "$WORK/$t/.ai-core/config.env"
    for run in 1 2; do
      if [ "$twin" = sh ]; then
        bash "$ROOT/bin/init.sh" "$WORK/$t" --no-doctor > /dev/null 2>&1 || fail "init.sh in $t (run $run)"
      else
        pwsh -NoProfile -File "$ROOT/bin/init.ps1" -TargetDir "$(native "$WORK/$t")" -NoDoctor > /dev/null 2>&1 || fail "init.ps1 in $t (run $run)"
      fi
      if [ "$run" = 1 ]; then
        dirty="$(git -C "$WORK/$t" status --porcelain | tr -d '\r')"
        [ "$dirty" = "?? .gitignore" ] || [ "$dirty" = " M .gitignore" ] || fail "init.$twin in $t left something besides .gitignore: $(echo "$dirty" | tr '\n' ' ')"
        git -C "$WORK/$t" add .gitignore
        git -C "$WORK/$t" -c user.name=check -c user.email=check@localhost commit -q -m ignore
      fi
    done
    dirty="$(git -C "$WORK/$t" status --porcelain)"
    [ -z "$dirty" ] || fail "init.$twin left untracked files in $t: $(echo "$dirty" | tr '\n' ' ')"
  done
  n="$(grep -c '^# setup-ai-core start' "$WORK/repo-$twin/.git/info/exclude")"
  [ "$n" = 1 ] || fail "exclude block written $n times by init.$twin"
done
echo "  git status empty in 4 targets; exclude block written once each"

echo "==> the .gitignore block: rewritten in place, a path the project ignores already is not written twice, on both twins"
for twin in sh ps1; do
  git init -q "$WORK/gi-$twin"; mkdir -p "$WORK/gi-$twin/.ai-core"; printf 'GRAFT_EXECUTION_MODE="skip"\n' > "$WORK/gi-$twin/.ai-core/config.env"
  printf 'node_modules/\n.claude/\ngraft\n' > "$WORK/gi-$twin/.gitignore"
  for run in 1 2; do
    if [ "$twin" = sh ]; then bash "$ROOT/bin/init.sh" "$WORK/gi-$twin" --no-doctor > /dev/null 2>&1 || fail "init.sh gitignore run $run"
    else pwsh -NoProfile -File "$ROOT/bin/init.ps1" -TargetDir "$(native "$WORK/gi-$twin")" -NoDoctor > /dev/null 2>&1 || fail "init.ps1 gitignore run $run"; fi
  done
  GI="$WORK/gi-$twin/.gitignore"
  [ "$(grep -c '^# setup-ai-core start' "$GI")" = 1 ] || fail "init.$twin wrote the .gitignore block $(grep -c '^# setup-ai-core start' "$GI") times"
  [ "$(grep -c 'claude' "$GI")" = 1 ] && [ "$(grep -c 'graft' "$GI")" = 1 ] || fail "init.$twin wrote a path the project already ignores: $(tr '\n' '|' < "$GI")"
  grep -qxF '/AGENTS.md' "$GI" && grep -qxF 'node_modules/' "$GI" || fail "init.$twin lost a line of the project's .gitignore or the block"
  head -1 "$GI" | grep -q '^node_modules/$' || fail "init.$twin moved the project's own lines"
done
cmp -s <(tr -d '\r' < "$WORK/gi-sh/.gitignore") <(tr -d '\r' < "$WORK/gi-ps1/.gitignore") || fail "the .gitignore differs between the twins"
echo "  one block, no duplicate of .claude/ and graft, the project's lines first, identical on both twins"

echo "==> a failing Graft build fails init, on both twins (fake npx on the PATH, no network)"
mkdir -p "$WORK/fakebin"
printf '#!/bin/sh\necho "fake npx: tests never reach the network" >&2\nexit 1\n' > "$WORK/fakebin/npx"
printf '@echo fake npx: tests never reach the network 1>&2\r\n@exit /b 1\r\n' > "$WORK/fakebin/npx.cmd"
chmod +x "$WORK/fakebin/npx"
for twin in sh ps1; do
  mkdir -p "$WORK/nograft-$twin"
  if [ "$twin" = sh ]; then
    PATH="$WORK/fakebin:$PATH" bash "$ROOT/bin/init.sh" "$WORK/nograft-$twin" --no-doctor > "$WORK/nograft-$twin.log" 2>&1 && fail "init.sh exited 0 although Graft failed"
  else
    PATH="$WORK/fakebin:$PATH" pwsh -NoProfile -File "$ROOT/bin/init.ps1" -TargetDir "$(native "$WORK/nograft-$twin")" -NoDoctor > "$WORK/nograft-$twin.log" 2>&1 && fail "init.ps1 exited 0 although Graft failed"
  fi
  grep -aq 'code graph is not' "$WORK/nograft-$twin.log" || fail "init.$twin did not explain the Graft failure"
  [ -f "$WORK/nograft-$twin/AGENTS.md" ] || fail "init.$twin failed before deploying the harness files"
done
echo "  both exit 1 with the harness files in place"

echo "==> a Graft that succeeds: called without the picker, everything it wrote excluded, the committed file it changed named, on both twins"
mkdir -p "$WORK/graftbin"
cat > "$WORK/graftbin/npx" <<'EOF'
#!/bin/sh
echo "$*" >> "$GRAFT_FAKE_LOG"
case "$*" in *--dry-run*) printf 'would write - this repo:\n  GEMINI.md               fenced graft section\n  .gemini\\settings.json   mcpServers.graft\n\nwould write - your machine, affects ALL repos:\n  ~\\.codex\\config.toml   [mcp_servers.graft]\n' >&2; exit 0 ;; esac
case "$3" in
  init) echo graft > GEMINI.md; mkdir -p .gemini; echo '{}' > .gemini/settings.json; echo graft >> AGENTS.md; echo graft >> README.md ;;
  build) mkdir -p graft; echo index > graft/index.md ;;
esac
exit 0
EOF
chmod +x "$WORK/graftbin/npx"
printf '@echo %%* >> "%%GRAFT_FAKE_LOG%%"\r\n@set DRY=0\r\n@for %%%%a in (%%*) do @if "%%%%a"=="--dry-run" set DRY=1\r\n@if "%%DRY%%"=="1" (echo would write - this repo:& echo   GEMINI.md               fenced graft section& echo   .gemini\\settings.json   mcpServers.graft& echo.& echo would write - your machine, affects ALL repos:& echo   ~\\.codex\\config.toml   [mcp_servers.graft]) 1>&2 & exit /b 0\r\n@if "%%3"=="init" (echo graft> GEMINI.md & mkdir .gemini 2>nul & echo {}> .gemini\\settings.json & echo graft>> AGENTS.md & echo graft>> README.md)\r\n@if "%%3"=="build" (mkdir graft 2>nul & echo index> graft\\index.md)\r\n@exit /b 0\r\n' > "$WORK/graftbin/npx.cmd"
for twin in sh ps1; do
  git init -q "$WORK/graft-$twin"
  echo readme > "$WORK/graft-$twin/README.md"
  git -C "$WORK/graft-$twin" add README.md
  git -C "$WORK/graft-$twin" -c user.name=check -c user.email=check@localhost commit -q -m init
  git -C "$WORK/graft-$twin" config core.autocrlf false
  echo wired-earlier > "$WORK/graft-$twin/GEMINI.md"
  : > "$WORK/graft-$twin.args"
  for run in 1 2; do
    if [ "$twin" = sh ]; then
      GRAFT_FAKE_LOG="$WORK/graft-$twin.args" PATH="$WORK/graftbin:$PATH" bash "$ROOT/bin/init.sh" "$WORK/graft-$twin" --no-doctor >> "$WORK/graft-$twin.log" 2>&1 || fail "init.sh with a succeeding Graft (run $run, see $WORK/graft-$twin.log)"
    else
      GRAFT_FAKE_LOG="$(native "$WORK/graft-$twin.args")" PATH="$WORK/graftbin:$PATH" pwsh -NoProfile -File "$ROOT/bin/init.ps1" -TargetDir "$(native "$WORK/graft-$twin")" -NoDoctor >> "$WORK/graft-$twin.log" 2>&1 || fail "init.ps1 with a succeeding Graft (run $run, see $WORK/graft-$twin.log)"
    fi
  done
  grep -aq '^-y @nanonets/graft init --agents claude agents antigravity --no-build' "$WORK/graft-$twin.args" || fail "init.$twin did not wire the agents of config.env without the picker (args: $(tr '\n' '|' < "$WORK/graft-$twin.args"))"
  grep -aq '^-y @nanonets/graft build' "$WORK/graft-$twin.args" || fail "init.$twin did not run graft build"
  [ "$(git -C "$WORK/graft-$twin" status --porcelain | tr -d '\r' | sort | tr '\n' '|')" = " M README.md|?? .gitignore|" ] || fail "init.$twin: git status after Graft is not the changed README.md and the new .gitignore: $(git -C "$WORK/graft-$twin" status --porcelain | tr '\n' ' ')"
  grep -aq 'Graft changed committed files: README.md' "$WORK/graft-$twin.log" || fail "init.$twin did not name the committed file Graft changed"
  for p in /graft/ /GEMINI.md /.gemini/settings.json; do
    grep -qxF "$p" "$WORK/graft-$twin/.git/info/exclude" || fail "init.$twin: $p missing from the Graft exclude block"
  done
  [ "$(grep -c '^# setup-ai-core graft start' "$WORK/graft-$twin/.git/info/exclude")" = 1 ] || fail "Graft exclude block written more than once by init.$twin"
done
echo "  both twins: no picker, GEMINI.md (there before) and .gemini/ excluded after two runs, README.md named"

echo "==> init runs doctor first and deploys nothing when it fails, on both twins"
mkdir -p "$WORK/nodoc-sh" "$WORK/nodoc-ps"
PATH="$WORK/doctorbin:$PATH" bash "$ROOT/bin/init.sh" "$WORK/nodoc-sh" > "$WORK/nodoc-sh.log" 2>&1 && fail "init.sh exited 0 although doctor failed"
PATH="$WORK/doctorbin:$PATH" pwsh -NoProfile -File "$ROOT/bin/init.ps1" -TargetDir "$(native "$WORK/nodoc-ps")" > "$WORK/nodoc-ps.log" 2>&1 && fail "init.ps1 exited 0 although doctor failed"
for t in sh ps; do
  grep -aq 'doctor reported' "$WORK/nodoc-$t.log" || fail "init in nodoc-$t did not point at doctor"
  [ -e "$WORK/nodoc-$t/.ai-core" ] && fail "init in nodoc-$t deployed files although doctor failed"
done
echo "  both stop before deploying"

echo "==> init --all: every git repository under a folder, a failing one reported, both twins"
for twin in sh ps; do
  mkdir -p "$WORK/all-$twin"
  for r in one two; do git init -q "$WORK/all-$twin/$r"; mkdir -p "$WORK/all-$twin/$r/.ai-core"; printf 'GRAFT_EXECUTION_MODE="skip"\n' > "$WORK/all-$twin/$r/.ai-core/config.env"; done
  git init -q "$WORK/all-$twin/broken"; mkdir -p "$WORK/all-$twin/broken/.ai-core"; printf 'GRAFT_EXECUTION_MODE="bogus"\n' > "$WORK/all-$twin/broken/.ai-core/config.env"
  mkdir -p "$WORK/all-$twin/not-a-repo" "$WORK/all-$twin/.ai-core"; printf 'GRAFT_EXECUTION_MODE="skip"\n' > "$WORK/all-$twin/.ai-core/config.env"
  if [ "$twin" = sh ]; then
    bash "$ROOT/bin/init.sh" --all "$WORK/all-$twin" --no-doctor > "$WORK/all-$twin.log" 2>&1 && fail "init.sh --all exited 0 with a failing repository"
  else
    pwsh -NoProfile -File "$ROOT/bin/init.ps1" -All "$(native "$WORK/all-$twin")" -NoDoctor > "$WORK/all-$twin.log" 2>&1 && fail "init.ps1 -All exited 0 with a failing repository"
  fi
  grep -aq '2 repositories initialized; failed: broken' "$WORK/all-$twin.log" || fail "init --all summary wrong for $twin: $(grep -a 'repositories initialized' "$WORK/all-$twin.log")"
  [ -f "$WORK/all-$twin/one/AGENTS.md" ] && [ -f "$WORK/all-$twin/two/AGENTS.md" ] || fail "init --all did not initialize the good repositories ($twin)"
  [ -e "$WORK/all-$twin/not-a-repo/.ai-core" ] && fail "init --all touched a folder that is not a repository ($twin)"
  grep -q 'written by init for a project folder' "$WORK/all-$twin/AGENTS.md" || fail "init --all did not write the project folder's AGENTS.md ($twin)"
  for r in one two broken; do grep -q "| \`$r\` | \`$r/AGENTS.md\` |" "$WORK/all-$twin/AGENTS.md" || fail "the project folder's AGENTS.md does not list $r ($twin)"; done
  grep -q 'not-a-repo' "$WORK/all-$twin/AGENTS.md" && fail "the project folder's AGENTS.md lists a folder that is not a repository ($twin)"
  [ -f "$WORK/all-$twin/.ai-core/rules/rules.md" ] || fail "init --all did not give the project folder the rules ($twin)"
done
diff <(sed "s/^# all-sh$/# FOLDER/" "$WORK/all-sh/AGENTS.md") <(sed "s/^# all-ps$/# FOLDER/" "$WORK/all-ps/AGENTS.md") > /dev/null || fail "the project folder's AGENTS.md differs between the twins"
echo "  2 initialized, 1 failed and named, the plain folder untouched, the folder's AGENTS.md lists the three, on both twins"

echo "==> session-start fails where the harness is not installed"
mkdir -p "$WORK/none"
(cd "$WORK/none" && bash "$ROOT/bin/session-start.sh" > /dev/null 2>&1) && fail "session-start.sh exited 0 without rules"
(cd "$WORK/none" && pwsh -NoProfile -File "$(native "$ROOT/bin/session-start.ps1")" > /dev/null 2>&1) && fail "session-start.ps1 exited 0 without rules"

echo "==> the board and issue commands: both suites against a fake gh, then the case check of every twin"
bash "$ROOT/tests/run-all.sh" > "$WORK/suite.sh.log" 2>&1 || { tail -30 "$WORK/suite.sh.log"; fail "bash tests/run-all.sh"; }
pwsh -NoProfile -File "$ROOT/tests/run-all.ps1" > "$WORK/suite.ps1.log" 2>&1 || { tail -30 "$WORK/suite.ps1.log"; fail "pwsh tests/run-all.ps1"; }
echo "  $(tail -3 "$WORK/suite.sh.log" | grep -a 'tests:' | head -1); $(tail -3 "$WORK/suite.ps1.log" | grep -a 'tests:' | head -1)"
bash "$ROOT/bin/case-check.sh" > "$WORK/case.sh.log" 2>&1 || { cat "$WORK/case.sh.log"; fail "bash bin/case-check.sh"; }
pwsh -NoProfile -File "$ROOT/bin/case-check.ps1" > "$WORK/case.ps1.log" 2>&1 || { cat "$WORK/case.ps1.log"; fail "pwsh bin/case-check.ps1"; }
echo "  case check green on both twins (schema-check needs github.com and runs in CI)"

echo "OK"
