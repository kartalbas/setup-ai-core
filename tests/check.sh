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
# A team-modes table whose probes always pass, so the tools of this machine never decide a check
printf 'claude\tmode\ton\talways\t-\t-\ncodex\tmode\ton\talways\t-\t-\ngemini\tmode\ton\talways\t-\t-\n' > "$WORK/modes.tsv"; export TEAM_MODES_FILE="$WORK/modes.tsv"

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
  [ ! -e "$WORK/agents-$t/.windsurfrules" ] && [ ! -e "$WORK/agents-$t/.github" ] && [ ! -e "$WORK/agents-$t/.openhands" ] && [ ! -e "$WORK/agents-$t/.codex" ] && [ ! -e "$WORK/agents-$t/.agents/mcp_config.json" ] || fail "init.$t deployed the pointer of an agent the project does not serve"
done
echo "  AGENTS=\"cursor claude\": .cursorrules deployed; windsurf, copilot, openhands, codex and antigravity files not, on both twins"

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
bash "$ROOT/bin/init.sh" "$WORK/sh" --no-doctor > "$WORK/sh-2.log" 2>&1 || fail "init.sh second run"
pwsh -NoProfile -File "$ROOT/bin/init.ps1" -TargetDir "$(native "$WORK/ps1")" -NoDoctor > "$WORK/ps1-2.log" 2>&1 || fail "init.ps1 second run"
for t in sh ps1; do
  grep -aqE '^  (created|refreshed|removed) ' "$WORK/$t-2.log" && fail "init.$t is not idempotent: $(grep -aE '^  (created|refreshed|removed) ' "$WORK/$t-2.log")"
  grep -aq '^  unchanged  [1-9][0-9]* file(s)$' "$WORK/$t-2.log" || fail "init.$t second run did not report the unchanged files"
done
(cd "$WORK/sh" && find . -type f | sort) | diff - "$WORK/sh.list" > /dev/null || fail "init.sh changed the file set on re-run"

echo "==> session-start in each target"
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
  init) echo graft > GEMINI.md; mkdir -p .gemini; echo '{}' > .gemini/settings.json; grep -q '^<!-- graft:start -->' AGENTS.md 2>/dev/null || printf '\n<!-- graft:start -->\ngraft\n<!-- graft:end -->\n' >> AGENTS.md; echo graft >> README.md; printf '\342\234\223 agents: %s/AGENTS.md (appended)\n\342\234\223 mcp codex: ~/.codex/config.toml (updated)\n' "$(pwd)" ;;
  build) mkdir -p graft; echo index > graft/index.md; printf '\342\234\223 wiring: 2 nodes (1 file, 1 function), 1 edges, 1 cards [javascript]\n' ;;
esac
exit 0
EOF
chmod +x "$WORK/graftbin/npx"
printf '@echo %%* >> "%%GRAFT_FAKE_LOG%%"\r\n@set DRY=0\r\n@for %%%%a in (%%*) do @if "%%%%a"=="--dry-run" set DRY=1\r\n@if "%%DRY%%"=="1" (echo would write - this repo:& echo   GEMINI.md               fenced graft section& echo   .gemini\\settings.json   mcpServers.graft& echo.& echo would write - your machine, affects ALL repos:& echo   ~\\.codex\\config.toml   [mcp_servers.graft]) 1>&2 & exit /b 0\r\n@if "%%3"=="init" (echo graft> GEMINI.md & mkdir .gemini 2>nul & echo {}> .gemini\\settings.json & findstr /b /c:"<!-- graft:start -->" AGENTS.md >nul 2>nul || node -e "require(\047fs\047).appendFileSync(\047AGENTS.md\047,\047\\n<!-- graft:start -->\\ngraft\\n<!-- graft:end -->\\n\047)" & echo graft>> README.md & echo \342\234\223 agents: %%CD%%\\AGENTS.md (appended^)& echo \342\234\223 mcp codex: ~\\.codex\\config.toml (updated^))\r\n@if "%%3"=="build" (mkdir graft 2>nul & echo index> graft\\index.md & echo \342\234\223 wiring: 2 nodes (1 file, 1 function^), 1 edges, 1 cards [javascript])\r\n@exit /b 0\r\n' > "$WORK/graftbin/npx.cmd"
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

echo "==> the report and --dry-run: a dry run writes nothing and says what a run would do; a run and a second run report the same on both twins"
init_twin() {  # init_twin <sh|ps1> <dir> <log> [--dry-run]: init with the fake Graft on the PATH
  local twin="$1" dir="$2" log="$3"; shift 3
  if [ "$twin" = sh ]; then
    GRAFT_FAKE_LOG="$WORK/report.args" PATH="$WORK/graftbin:$PATH" bash "$ROOT/bin/init.sh" "$dir" --no-doctor "$@" > "$log" 2>&1
  else
    local ps=(); for a in "$@"; do [ "$a" = --dry-run ] && ps+=(-DryRun); done
    GRAFT_FAKE_LOG="$(native "$WORK/report.args")" PATH="$WORK/graftbin:$PATH" pwsh -NoProfile -File "$ROOT/bin/init.ps1" -TargetDir "$(native "$dir")" -NoDoctor ${ps[@]+"${ps[@]}"} > "$log" 2>&1
  fi
}
report_of() { sed -n '/^init would change in /,/^====/p; /^init changed in /,/^====/p' "$1" | grep -a '^  ' | tr -d '\r'; }   # the report lines of a log
for twin in sh ps1; do
  D="$WORK/report-$twin"; : > "$WORK/report.args"
  git init -q "$D"; echo readme > "$D/README.md"; git -C "$D" add README.md
  git -C "$D" -c user.name=check -c user.email=check@localhost commit -q -m init
  git -C "$D" config core.autocrlf false
  mkdir -p "$D/.ai-core/bin"; echo old > "$D/.ai-core/bin/left-behind"
  printf 'AGENTS="claude codex"\n' > "$D/.ai-core/config.env"
  # 1. the dry run
  init_twin "$twin" "$D" "$WORK/report-$twin-dry.log" --dry-run || fail "init.$twin --dry-run failed (see $WORK/report-$twin-dry.log)"
  [ "$(git -C "$D" status --porcelain --untracked-files=all | tr -d '\r' | sort | tr '\n' '|')" = "?? .ai-core/bin/left-behind|?? .ai-core/config.env|" ] || fail "init.$twin --dry-run wrote or removed something: $(git -C "$D" status --porcelain --untracked-files=all | tr '\n' ' ')"
  [ ! -e "$D/.git/info/exclude" ] || ! grep -q 'setup-ai-core' "$D/.git/info/exclude" || fail "init.$twin --dry-run wrote the exclude file"
  grep -aq "^init would change in report-$twin:" "$WORK/report-$twin-dry.log" || fail "init.$twin --dry-run has no report"
  grep -a '^  created ' "$WORK/report-$twin-dry.log" | grep -q 'AGENTS.md' || fail "init.$twin --dry-run does not list AGENTS.md as created"
  grep -a '^  created ' "$WORK/report-$twin-dry.log" | grep -q '.codex/config.toml' || fail "init.$twin --dry-run does not list the codex file as created"
  grep -a '^  created ' "$WORK/report-$twin-dry.log" | grep -q '.cursorrules' && fail "init.$twin --dry-run lists the file of an agent the project does not serve"
  grep -aq '^  removed    .ai-core/bin$' "$WORK/report-$twin-dry.log" || fail "init.$twin --dry-run does not list .ai-core/bin as removed"
  grep -aq '^  kept       .ai-core/config.env ' "$WORK/report-$twin-dry.log" || fail "init.$twin --dry-run does not list config.env as kept"
  grep -aq '^  .gitignore would change' "$WORK/report-$twin-dry.log" || fail "init.$twin --dry-run does not say .gitignore would change"
  grep -aq '^  nothing was written (dry run)$' "$WORK/report-$twin-dry.log" || fail "init.$twin --dry-run does not say that nothing was written"
  grep -aq '^  Graft would write (init):$' "$WORK/report-$twin-dry.log" && grep -aq '^      GEMINI.md ' "$WORK/report-$twin-dry.log" && grep -aq 'codex.config.toml' "$WORK/report-$twin-dry.log" || fail "init.$twin --dry-run does not show what Graft would write"
  grep -aq 'Graft would build the graph' "$WORK/report-$twin-dry.log" || fail "init.$twin --dry-run does not say the graph is not built"
  grep -aq 'graft build' "$WORK/report.args" && fail "init.$twin --dry-run built the graph"
  # 2. the run: what the dry run announced, done and reported the same way
  init_twin "$twin" "$D" "$WORK/report-$twin-1.log" || fail "init.$twin run 1 failed (see $WORK/report-$twin-1.log)"
  [ -f "$D/AGENTS.md" ] && [ ! -e "$D/.ai-core/bin" ] || fail "init.$twin run 1 did not do what the dry run announced"
  diff <(report_of "$WORK/report-$twin-dry.log" | sed 's/would change/changed/; s/^  nothing was written (dry run)$//' | grep .) <(report_of "$WORK/report-$twin-1.log") > /dev/null || fail "init.$twin: the run reports something else than its dry run announced: $(diff <(report_of "$WORK/report-$twin-dry.log") <(report_of "$WORK/report-$twin-1.log"))"
  grep -aq '^  Graft wrote in the repository:$' "$WORK/report-$twin-1.log" && grep -aq '^    AGENTS.md (appended)$' "$WORK/report-$twin-1.log" || fail "init.$twin does not report what Graft wrote in the repository: $(grep -a 'Graft' "$WORK/report-$twin-1.log" | tr '\n' '|')"
  grep -aq '^  Graft wrote on the machine:$' "$WORK/report-$twin-1.log" && grep -aq '^    ~.\.codex.config.toml (updated)$' "$WORK/report-$twin-1.log" || fail "init.$twin does not report what Graft wrote on the machine: $(grep -a 'Graft' "$WORK/report-$twin-1.log" | tr '\n' '|')"
  grep -aq '^  Graft graph: 2 nodes' "$WORK/report-$twin-1.log" || fail "init.$twin does not report the graph"
  # 3. the second run: nothing created, refreshed or removed; the exclude file untouched
  cp "$D/.git/info/exclude" "$WORK/report-$twin.exclude"
  init_twin "$twin" "$D" "$WORK/report-$twin-2.log" || fail "init.$twin run 2 failed (see $WORK/report-$twin-2.log)"
  grep -aqE '^  (created|refreshed|removed) ' "$WORK/report-$twin-2.log" && fail "init.$twin run 2 changed something: $(grep -aE '^  (created|refreshed|removed) ' "$WORK/report-$twin-2.log")"
  grep -aq '^  .gitignore changed' "$WORK/report-$twin-2.log" && fail "init.$twin run 2 changed .gitignore again"
  cmp -s "$D/.git/info/exclude" "$WORK/report-$twin.exclude" || fail "init.$twin run 2 rewrote the exclude file"
  # 4. a project folder: its AGENTS.md is generated on every run and keeps the block Graft appends to it
  F="$WORK/folder-$twin"; mkdir -p "$F"; git init -q "$F/app"
  init_twin "$twin" "$F" "$WORK/folder-$twin-1.log" || fail "init.$twin on a project folder failed (see $WORK/folder-$twin-1.log)"
  grep -q '^<!-- graft:start -->' "$F/AGENTS.md" || fail "the fake Graft did not append its block to the folder's AGENTS.md ($twin)"
  init_twin "$twin" "$F" "$WORK/folder-$twin-2.log" || fail "init.$twin run 2 on a project folder failed (see $WORK/folder-$twin-2.log)"
  grep -aqE '^  (created|refreshed|removed) ' "$WORK/folder-$twin-2.log" && fail "init.$twin run 2 on a project folder changed something: $(grep -aE '^  (created|refreshed|removed) ' "$WORK/folder-$twin-2.log")"
  [ "$(grep -c '^<!-- graft:start -->' "$F/AGENTS.md")" = 1 ] && grep -q '^| `app` |' "$F/AGENTS.md" || fail "the folder's AGENTS.md lost the map or Graft's block ($twin)"
done
for run in dry 1 2; do
  diff <(report_of "$WORK/report-sh-$run.log" | sed 's/report-sh/report-TWIN/') <(report_of "$WORK/report-ps1-$run.log" | sed 's/report-ps1/report-TWIN/') > /dev/null || fail "the report of run $run differs between the twins: $(diff <(report_of "$WORK/report-sh-$run.log") <(report_of "$WORK/report-ps1-$run.log"))"
done
echo "  dry run: nothing written, created/removed/kept/.gitignore and Graft's lists announced; run 1 reports the same; run 2 only unchanged files, the folder's AGENTS.md keeps Graft's block; identical on both twins"

echo "==> the project harness: created from the skeleton, cloned on another machine, its rules, skills, docs, data and repos/<repo>/ assembled, on both twins"
# A stand-in gh keeps GitHub on this disk: bare repositories under $GH_FAKE/github.com/<org>/<name>.git
GH_FAKE="$WORK/github"; mkdir -p "$GH_FAKE/github.com/example-org" "$WORK/ghbin"; export GH_FAKE
cat > "$WORK/ghbin/gh" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "repo view")   [ -d "$GH_FAKE/github.com/$3.git" ] ;;
  "repo clone")  git clone -q "$GH_FAKE/github.com/$3.git" "$4" ;;
  "repo create") git init -q --bare "$GH_FAKE/github.com/$3.git" && git -C "$6" remote add origin "$GH_FAKE/github.com/$3.git" && git -C "$6" push -q -u origin HEAD ;;
  "auth status") exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/ghbin/gh"
GH_FAKE_WIN="$(native "$GH_FAKE" | sed 's|\\|/|g')"
printf '@echo off\r\nif "%%1 %%2"=="repo view" (if exist "%s/github.com/%%3.git" (exit /b 0) else (exit /b 1))\r\nif "%%1 %%2"=="repo clone" (git clone -q "%s/github.com/%%3.git" "%%4" & exit /b %%ERRORLEVEL%%)\r\nif "%%1 %%2"=="repo create" (git init -q --bare "%s/github.com/%%3.git" & git -C "%%6" remote add origin "%s/github.com/%%3.git" & git -C "%%6" push -q -u origin HEAD & exit /b %%ERRORLEVEL%%)\r\nif "%%1 %%2"=="auth status" exit /b 0\r\nexit /b 1\r\n' "$GH_FAKE_WIN" "$GH_FAKE_WIN" "$GH_FAKE_WIN" "$GH_FAKE_WIN" > "$WORK/ghbin/gh.cmd"
# A project repository: shop-web of example-org, with a README the fake Graft appends to
new_checkout() {  # new_checkout <dir> <repo name>
  git init -q "$1"; echo readme > "$1/README.md"
  git -C "$1" add README.md; git -C "$1" -c user.name=check -c user.email=check@localhost commit -q -m init
  git -C "$1" config core.autocrlf false
  git -C "$1" remote add origin "https://github.com/example-org/$2.git"
}
PATH_SH="$WORK/ghbin:$WORK/graftbin:$PATH"
mkdir -p "$WORK/home-sh" "$WORK/home-ps"
new_checkout "$WORK/shop-web-sh" shop-web
HOME="$WORK/home-sh" PATH="$PATH_SH" GRAFT_FAKE_LOG="$WORK/layers.args" bash "$ROOT/bin/init.sh" "$WORK/shop-web-sh" --no-doctor --dry-run > "$WORK/layers-sh-0.log" 2>&1 || fail "init.sh --dry-run before the project harness exists (see $WORK/layers-sh-0.log)"
grep -aq 'example-org/shop-ai-core would be created from the skeleton' "$WORK/layers-sh-0.log" || fail "init.sh --dry-run does not announce the harness it would create"
[ ! -e "$GH_FAKE/github.com/example-org/shop-ai-core.git" ] && [ ! -e "$WORK/home-sh/.shop-ai-core" ] || fail "init.sh --dry-run created the project harness"
HOME="$WORK/home-sh" PATH="$PATH_SH" GRAFT_FAKE_LOG="$WORK/layers.args" bash "$ROOT/bin/init.sh" "$WORK/shop-web-sh" --no-doctor > "$WORK/layers-sh-1.log" 2>&1 || fail "init.sh with a new project harness (see $WORK/layers-sh-1.log)"
grep -aq 'created: example-org/shop-ai-core, private, from the skeleton' "$WORK/layers-sh-1.log" || fail "init.sh did not create the project harness (see $WORK/layers-sh-1.log)"
grep -aq '^--> Project harness: example-org/shop-ai-core (' "$WORK/layers-sh-1.log" || fail "init.sh did not name the project harness"
[ -d "$GH_FAKE/github.com/example-org/shop-ai-core.git" ] || fail "the harness was not pushed to GitHub"
[ -f "$WORK/home-sh/.shop-ai-core/ai-core.json" ] && [ -f "$WORK/home-sh/.shop-ai-core/labels.tsv" ] || fail "the clone at ~/.shop-ai-core lacks the skeleton"
[ "$(wc -l < "$WORK/shop-web-sh/.ai-core/STAMP" | tr -d ' ')" = 2 ] && grep -q '^shop-ai-core ' "$WORK/shop-web-sh/.ai-core/STAMP" || fail "STAMP does not name setup-ai-core and the harness: $(cat "$WORK/shop-web-sh/.ai-core/STAMP" | tr '\n' '|')"
cmp -s "$WORK/shop-web-sh/.ai-core/config.env" "$ROOT/templates/.ai-core/config.env" || fail "config.env of the checkout is not the harness's (the skeleton's copy of the template)"
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
HOME="$WORK/home-sh" PATH="$PATH_SH" GRAFT_FAKE_LOG="$WORK/layers.args" bash "$ROOT/bin/init.sh" "$WORK/shop-web-sh" --no-doctor > "$WORK/layers-sh-2.log" 2>&1 || fail "init.sh second run with the filled harness (see $WORK/layers-sh-2.log)"
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
  [ "$st" = " M README.md|?? .gitignore|" ] || [ "$st" = "?? .gitignore|" ] || fail "$t: git status shows more than the new .gitignore (and the fake Graft's README.md): $st"
}
assembled_ok "$WORK/shop-web-sh" "init.sh"
# Another machine, the PowerShell twin: the harness exists on GitHub, so it is cloned, and the checkout is assembled the same
new_checkout "$WORK/shop-web-ps" shop-web
HOME="$WORK/home-ps" USERPROFILE="$(native "$WORK/home-ps")" PATH="$PATH_SH" GRAFT_FAKE_LOG="$(native "$WORK/layers.args")" pwsh -NoProfile -File "$ROOT/bin/init.ps1" -TargetDir "$(native "$WORK/shop-web-ps")" -NoDoctor > "$WORK/layers-ps-1.log" 2>&1 || fail "init.ps1 with the cloned project harness (see $WORK/layers-ps-1.log)"
grep -aq 'created:' "$WORK/layers-ps-1.log" && fail "init.ps1 created a harness that exists"
[ -f "$WORK/home-ps/.shop-ai-core/ai-core.json" ] || fail "init.ps1 did not clone the harness to ~/.shop-ai-core"
assembled_ok "$WORK/shop-web-ps" "init.ps1"
cmp -s "$WORK/shop-web-sh/.ai-core/rules/rules.md" "$WORK/shop-web-ps/.ai-core/rules/rules.md" || fail "the assembled rules.md differs between the twins"
cmp -s "$WORK/shop-web-sh/.ai-core/STAMP" "$WORK/shop-web-ps/.ai-core/STAMP" || fail "STAMP differs between the twins"
# The PowerShell twin creates one too: store-api of the same organisation gets store-ai-core
new_checkout "$WORK/store-api-ps" store-api
HOME="$WORK/home-ps" USERPROFILE="$(native "$WORK/home-ps")" PATH="$PATH_SH" GRAFT_FAKE_LOG="$(native "$WORK/layers.args")" pwsh -NoProfile -File "$ROOT/bin/init.ps1" -TargetDir "$(native "$WORK/store-api-ps")" -NoDoctor -DryRun > "$WORK/layers-ps-0.log" 2>&1 || fail "init.ps1 -DryRun before the project harness exists (see $WORK/layers-ps-0.log)"
grep -aq 'example-org/store-ai-core would be created from the skeleton' "$WORK/layers-ps-0.log" || fail "init.ps1 -DryRun does not announce the harness it would create"
[ ! -e "$GH_FAKE/github.com/example-org/store-ai-core.git" ] && [ ! -e "$WORK/home-ps/.store-ai-core" ] || fail "init.ps1 -DryRun created the project harness"
HOME="$WORK/home-ps" USERPROFILE="$(native "$WORK/home-ps")" PATH="$PATH_SH" GRAFT_FAKE_LOG="$(native "$WORK/layers.args")" pwsh -NoProfile -File "$ROOT/bin/init.ps1" -TargetDir "$(native "$WORK/store-api-ps")" -NoDoctor > "$WORK/layers-ps-2.log" 2>&1 || fail "init.ps1 with a new project harness (see $WORK/layers-ps-2.log)"
grep -aq 'created: example-org/store-ai-core, private, from the skeleton' "$WORK/layers-ps-2.log" || fail "init.ps1 did not create store-ai-core"
[ -d "$GH_FAKE/github.com/example-org/store-ai-core.git" ] || fail "store-ai-core was not pushed"
# extends: shop-ai-core now extends store-ai-core, so the chain is store first, then shop
printf '{ "setup-ai-core": ">=1.1.0", "extends": "example-org/store-ai-core" }\n' > "$WORK/author/ai-core.json"
git -C "$WORK/author" add -A; git -C "$WORK/author" -c user.name=check -c user.email=check@localhost commit -q -m extends; git -C "$WORK/author" push -q origin HEAD
HOME="$WORK/home-sh" PATH="$PATH_SH" GRAFT_FAKE_LOG="$WORK/layers.args" bash "$ROOT/bin/init.sh" "$WORK/shop-web-sh" --no-doctor > "$WORK/layers-sh-3.log" 2>&1 || fail "init.sh with an extends chain (see $WORK/layers-sh-3.log)"
[ "$(sed -n 2p "$WORK/shop-web-sh/.ai-core/STAMP" | cut -d' ' -f1)" = store-ai-core ] && [ "$(sed -n 3p "$WORK/shop-web-sh/.ai-core/STAMP" | cut -d' ' -f1)" = shop-ai-core ] || fail "the extends chain is not base first in STAMP: $(tr '\n' '|' < "$WORK/shop-web-sh/.ai-core/STAMP")"
[ -d "$WORK/home-sh/.store-ai-core" ] || fail "the base of the chain was not cloned"
# A harness checkout is refused, and a project folder gets the layers its repositories share
new_checkout "$WORK/harness-checkout" shop-ai-core
HOME="$WORK/home-sh" PATH="$PATH_SH" GRAFT_FAKE_LOG="$WORK/layers.args" bash "$ROOT/bin/init.sh" "$WORK/harness-checkout" --no-doctor > "$WORK/layers-refused.log" 2>&1 && fail "init.sh accepted a harness repository"
grep -aq 'harness repository' "$WORK/layers-refused.log" || fail "init.sh did not say why the harness repository is refused"
mkdir -p "$WORK/folder/.ai-core"; printf 'GRAFT_EXECUTION_MODE="skip"\n' > "$WORK/folder/.ai-core/config.env"
new_checkout "$WORK/folder/shop-web" shop-web; new_checkout "$WORK/folder/store-api" store-api
HOME="$WORK/home-sh" PATH="$PATH_SH" GRAFT_FAKE_LOG="$WORK/layers.args" bash "$ROOT/bin/init.sh" "$WORK/folder" --no-doctor > "$WORK/layers-folder.log" 2>&1 || fail "init.sh on a project folder with layers (see $WORK/layers-folder.log)"
[ "$(tr '\n' '|' < "$WORK/folder/.ai-core/STAMP" | sed 's/ [0-9a-f-]*|/|/g')" = "setup-ai-core|store-ai-core|" ] || fail "the project folder did not get the layer its repositories share: $(tr '\n' '|' < "$WORK/folder/.ai-core/STAMP")"
echo "  created, cloned, assembled and compared on both twins; extends base first; a harness checkout refused; the folder shares the base"

echo "==> push: what changed in a harness clone is committed and pushed, a second run has nothing, on both twins"
for twin in sh ps1; do
  H="$WORK/push-home-$twin"; mkdir -p "$H"
  git init -q --bare "$WORK/push-origin-$twin.git"
  git clone -q "$WORK/push-origin-$twin.git" "$H/.shop-ai-core" 2>/dev/null
  git -C "$H/.shop-ai-core" config core.autocrlf false
  echo one > "$H/.shop-ai-core/README.md"; git -C "$H/.shop-ai-core" add -A; git -C "$H/.shop-ai-core" -c user.name=check -c user.email=check@localhost commit -q -m first; git -C "$H/.shop-ai-core" push -q -u origin HEAD
  mkdir -p "$H/.shop-ai-core/rules"; printf '## Releases\n\n- **A release is a tag.** [review]\n' > "$H/.shop-ai-core/rules/35-releases.md"
  if [ "$twin" = sh ]; then
    (cd "$WORK" && HOME="$H" GIT_AUTHOR_NAME=check GIT_AUTHOR_EMAIL=check@localhost GIT_COMMITTER_NAME=check GIT_COMMITTER_EMAIL=check@localhost bash "$ROOT/bin/push.sh" "the release rule" > "$WORK/push-$twin.log" 2>&1) || fail "push.sh (see $WORK/push-$twin.log)"
    (cd "$WORK" && HOME="$H" bash "$ROOT/bin/push.sh" > "$WORK/push-$twin-2.log" 2>&1) || fail "push.sh second run (see $WORK/push-$twin-2.log)"
  else
    (cd "$WORK" && HOME="$H" USERPROFILE="$(native "$H")" GIT_AUTHOR_NAME=check GIT_AUTHOR_EMAIL=check@localhost GIT_COMMITTER_NAME=check GIT_COMMITTER_EMAIL=check@localhost pwsh -NoProfile -File "$ROOT/bin/push.ps1" "the release rule" > "$WORK/push-$twin.log" 2>&1) || fail "push.ps1 (see $WORK/push-$twin.log)"
    (cd "$WORK" && HOME="$H" USERPROFILE="$(native "$H")" pwsh -NoProfile -File "$ROOT/bin/push.ps1" > "$WORK/push-$twin-2.log" 2>&1) || fail "push.ps1 second run (see $WORK/push-$twin-2.log)"
  fi
  grep -aq 'shop-ai-core: committed 1 file(s): the release rule' "$WORK/push-$twin.log" || fail "push.$twin did not commit with the message (see $WORK/push-$twin.log)"
  grep -aq 'shop-ai-core: pushed to' "$WORK/push-$twin.log" || fail "push.$twin did not push"
  [ "$(git -C "$WORK/push-origin-$twin.git" log --format=%s -1)" = "the release rule" ] || fail "push.$twin: origin does not carry the commit"
  grep -aq 'shop-ai-core: nothing to push' "$WORK/push-$twin-2.log" || fail "push.$twin second run did not say nothing to push"
done
echo "  committed with the message, pushed to origin, nothing on the second run, on both twins"

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
    bash "$ROOT/bin/init.sh" --all "$WORK/all-$twin" --no-doctor --dry-run > "$WORK/all-$twin-dry.log" 2>&1 && fail "init.sh --all --dry-run exited 0 with a failing repository"
    bash "$ROOT/bin/init.sh" --all "$WORK/all-$twin" --no-doctor > "$WORK/all-$twin.log" 2>&1 && fail "init.sh --all exited 0 with a failing repository"
  else
    pwsh -NoProfile -File "$ROOT/bin/init.ps1" -All "$(native "$WORK/all-$twin")" -NoDoctor -DryRun > "$WORK/all-$twin-dry.log" 2>&1 && fail "init.ps1 -All -DryRun exited 0 with a failing repository"
    pwsh -NoProfile -File "$ROOT/bin/init.ps1" -All "$(native "$WORK/all-$twin")" -NoDoctor > "$WORK/all-$twin.log" 2>&1 && fail "init.ps1 -All exited 0 with a failing repository"
  fi
  grep -aq '2 repositories would be initialized; failed: broken' "$WORK/all-$twin-dry.log" || fail "init --all --dry-run summary wrong for $twin: $(grep -a 'repositories' "$WORK/all-$twin-dry.log")"
  [ "$(grep -ac '^init would change in ' "$WORK/all-$twin-dry.log")" = 3 ] || fail "init --all --dry-run did not report every repository and the folder ($twin)"
  grep -aq '^  created .*AGENTS.md' "$WORK/all-$twin.log" || fail "init --all did not report what it created ($twin)"
  grep -aq '2 repositories were initialized; failed: broken' "$WORK/all-$twin.log" || fail "init --all summary wrong for $twin: $(grep -a 'repositories' "$WORK/all-$twin.log")"
  [ -f "$WORK/all-$twin/one/AGENTS.md" ] && [ -f "$WORK/all-$twin/two/AGENTS.md" ] || fail "init --all did not initialize the good repositories ($twin)"
  [ -e "$WORK/all-$twin/not-a-repo/.ai-core" ] && fail "init --all touched a folder that is not a repository ($twin)"
  grep -q 'written by init for a project folder' "$WORK/all-$twin/AGENTS.md" || fail "init --all did not write the project folder's AGENTS.md ($twin)"
  for r in one two broken; do grep -q "| \`$r\` | \`$r/AGENTS.md\` |" "$WORK/all-$twin/AGENTS.md" || fail "the project folder's AGENTS.md does not list $r ($twin)"; done
  grep -q 'not-a-repo' "$WORK/all-$twin/AGENTS.md" && fail "the project folder's AGENTS.md lists a folder that is not a repository ($twin)"
  [ -f "$WORK/all-$twin/.ai-core/rules/rules.md" ] || fail "init --all did not give the project folder the rules ($twin)"
done
diff <(sed "s/^# all-sh$/# FOLDER/" "$WORK/all-sh/AGENTS.md") <(sed "s/^# all-ps$/# FOLDER/" "$WORK/all-ps/AGENTS.md") > /dev/null || fail "the project folder's AGENTS.md differs between the twins"
echo "  2 initialized, 1 failed and named, the plain folder untouched, the folder's AGENTS.md lists the three, on both twins"

echo "==> init arms a clone that carries .githooks/pre-push: core.hooksPath set, reported, once; a dry run only says so; both twins"
for twin in sh ps1; do
  H="$WORK/hooks-$twin"; git init -q "$H"; mkdir -p "$H/.githooks" "$H/.ai-core"
  printf '#!/usr/bin/env bash\nexec ai-core pre-push "$@"\n' > "$H/.githooks/pre-push"
  printf 'GRAFT_EXECUTION_MODE="skip"\n' > "$H/.ai-core/config.env"
  if [ "$twin" = sh ]; then
    bash "$ROOT/bin/init.sh" "$H" --no-doctor --dry-run > "$WORK/hooks-$twin-dry.log" 2>&1 || fail "init.sh --dry-run on a repository with the shim (see $WORK/hooks-$twin-dry.log)"
    bash "$ROOT/bin/init.sh" "$H" --no-doctor > "$WORK/hooks-$twin-1.log" 2>&1 || fail "init.sh on a repository with the shim (see $WORK/hooks-$twin-1.log)"
    bash "$ROOT/bin/init.sh" "$H" --no-doctor > "$WORK/hooks-$twin-2.log" 2>&1 || fail "init.sh second run on a repository with the shim"
  else
    pwsh -NoProfile -File "$ROOT/bin/init.ps1" -TargetDir "$(native "$H")" -NoDoctor -DryRun > "$WORK/hooks-$twin-dry.log" 2>&1 || fail "init.ps1 -DryRun on a repository with the shim (see $WORK/hooks-$twin-dry.log)"
    pwsh -NoProfile -File "$ROOT/bin/init.ps1" -TargetDir "$(native "$H")" -NoDoctor > "$WORK/hooks-$twin-1.log" 2>&1 || fail "init.ps1 on a repository with the shim (see $WORK/hooks-$twin-1.log)"
    pwsh -NoProfile -File "$ROOT/bin/init.ps1" -TargetDir "$(native "$H")" -NoDoctor > "$WORK/hooks-$twin-2.log" 2>&1 || fail "init.ps1 second run on a repository with the shim"
  fi
  grep -aq '^  core.hooksPath would be set to .githooks: the push gate runs here$' "$WORK/hooks-$twin-dry.log" || fail "init.$twin --dry-run does not say core.hooksPath would be set"
  grep -aq '^  core.hooksPath set to .githooks: the push gate runs here$' "$WORK/hooks-$twin-1.log" || fail "init.$twin does not report core.hooksPath"
  [ "$(git -C "$H" config --get core.hooksPath)" = ".githooks" ] || fail "init.$twin did not set core.hooksPath"
  grep -aq 'core.hooksPath' "$WORK/hooks-$twin-2.log" && fail "init.$twin reports core.hooksPath again on the second run"
done
echo "  core.hooksPath set once and reported, the dry run announces it, on both twins"

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
