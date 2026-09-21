#!/usr/bin/env bash
# What every section of the suite starts with: the root, fail, native, a throwaway directory of
# its own, and the stand-ins a section puts on the PATH. Sourced by tests/sections/*.sh; not run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
# pwsh on Windows needs a native path
native() { cygpath -w "$1" 2>/dev/null || echo "$1"; }
section() { echo "==> $1"; }
WORK="$(mktemp -d)"
[ -n "${KEEP_WORK:-}" ] || trap 'rm -rf "$WORK"' EXIT   # KEEP_WORK=1 leaves the directory for a look
# the number of generic rule sections, what an assembled rules.md is measured against
SECTIONS="$(ls "$ROOT"/rules/[0-9][0-9]-*.md | wc -l | tr -d ' ')"

# A push init makes to an origin that is not there fails at once instead of asking for a login
export GIT_TERMINAL_PROMPT=0
# The commits init and pre-push --install make in the scratch repositories need an identity, and a
# runner has none configured
export GIT_AUTHOR_NAME=check GIT_AUTHOR_EMAIL=check@localhost GIT_COMMITTER_NAME=check GIT_COMMITTER_EMAIL=check@localhost
# pwsh on Linux colours an error record even when it is captured, and a test that reads the text
# then reads escape codes; NO_COLOR is honoured by PowerShell 7.2+
export NO_COLOR=1
# session-start does not ask the origins here: nothing in this suite reaches the network
export AI_CORE_UPDATE_CHECK=never
# A team-modes table whose probes always pass, so the tools of this machine never decide a check
printf 'claude\tmode\ton\talways\t-\t-\ncodex\tmode\ton\talways\t-\t-\ngemini\tmode\ton\talways\t-\t-\n' > "$WORK/modes.tsv"; export TEAM_MODES_FILE="$WORK/modes.tsv"

# A stand-in Graft: npx on the PATH that writes what the real one writes and logs its arguments
make_graft_fake() {
mkdir -p "$WORK/graftbin"
cat > "$WORK/graftbin/npx" <<'EOF'
#!/bin/sh
echo "$*" >> "$GRAFT_FAKE_LOG"
case "$*" in *--dry-run*) printf 'would write - this repo:\n  GEMINI.md               fenced graft section\n  .gemini\\settings.json   mcpServers.graft\n\nwould write - your machine, affects ALL repos:\n  ~\\.codex\\config.toml   [mcp_servers.graft]\n' >&2; exit 0 ;; esac
case "$3" in
  init) echo graft > GEMINI.md; mkdir -p .gemini; echo '{}' > .gemini/settings.json; grep -q '^<!-- graft:start -->' AGENTS.md 2>/dev/null || printf '\n<!-- graft:start -->\ngraft\n<!-- graft:end -->\n' >> AGENTS.md; echo graft >> README.md; printf '\342\234\223 agents: %s/AGENTS.md (appended)\n\342\234\223 mcp codex: ~/.codex/config.toml (updated)\n' "$(pwd)"
        for d in *-ai-core; do [ -d "$d/.git" ] && { echo graft > "$d/AGENTS.md"; printf '\342\234\223 agents: %s/%s/AGENTS.md (created)\n' "$(pwd)" "$d"; }; done ;;
  build) mkdir -p graft; echo index > graft/index.md; printf '\342\234\223 wiring: 2 nodes (1 file, 1 function), 1 edges, 1 cards [javascript]\n' ;;
esac
exit 0
EOF
chmod +x "$WORK/graftbin/npx"
printf '@echo %%* >> "%%GRAFT_FAKE_LOG%%"\r\n@set DRY=0\r\n@for %%%%a in (%%*) do @if "%%%%a"=="--dry-run" set DRY=1\r\n@if "%%DRY%%"=="1" (echo would write - this repo:& echo   GEMINI.md               fenced graft section& echo   .gemini\\settings.json   mcpServers.graft& echo.& echo would write - your machine, affects ALL repos:& echo   ~\\.codex\\config.toml   [mcp_servers.graft]) 1>&2 & exit /b 0\r\n@if "%%3"=="init" (echo graft> GEMINI.md & mkdir .gemini 2>nul & echo {}> .gemini\\settings.json & findstr /b /c:"<!-- graft:start -->" AGENTS.md >nul 2>nul || node -e "require(\047fs\047).appendFileSync(\047AGENTS.md\047,\047\\n<!-- graft:start -->\\ngraft\\n<!-- graft:end -->\\n\047)" & echo graft>> README.md & echo \342\234\223 agents: %%CD%%\\AGENTS.md (appended^)& echo \342\234\223 mcp codex: ~\\.codex\\config.toml (updated^))\r\n@if "%%3"=="init" for /d %%%%d in (*-ai-core) do @if exist "%%%%d\\.git" (echo graft> "%%%%d\\AGENTS.md" & echo \342\234\223 agents: %%CD%%\\%%%%d\\AGENTS.md (created^))\r\n@if "%%3"=="build" (mkdir graft 2>nul & echo index> graft\\index.md & echo \342\234\223 wiring: 2 nodes (1 file, 1 function^), 1 edges, 1 cards [javascript])\r\n@exit /b 0\r\n' > "$WORK/graftbin/npx.cmd"
}

# A stand-in gh keeps GitHub on this disk: bare repositories under $GH_FAKE/github.com/<org>/<name>.git
make_gh_fake() {
GH_FAKE="$WORK/github"; mkdir -p "$GH_FAKE/github.com/example-org" "$WORK/ghbin"; export GH_FAKE
cat > "$WORK/ghbin/gh" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "repo view")   [ -d "$GH_FAKE/github.com/$3.git" ] ;;
  "repo clone")  git clone -q "$GH_FAKE/github.com/$3.git" "$4" ;;
  "repo create") [ "${3%%/*}" != nocreate-org ] && git init -q --bare "$GH_FAKE/github.com/$3.git" && git -C "$6" remote add origin "$GH_FAKE/github.com/$3.git" && git -C "$6" push -q -u origin HEAD ;;
  "run list") echo '[{"status":"completed","conclusion":"success"}]' ;;
  "auth status") exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/ghbin/gh"
GH_FAKE_WIN="$(native "$GH_FAKE" | sed 's|\\|/|g')"
printf '@echo off\r\nif "%%1 %%2"=="repo view" (if exist "%s/github.com/%%3.git" (exit /b 0) else (exit /b 1))\r\nif "%%1 %%2"=="repo clone" (git clone -q "%s/github.com/%%3.git" "%%4" & exit /b %%ERRORLEVEL%%)\r\nif "%%1 %%2 %%3"=="repo create nocreate-org/nocreate-ai-core" exit /b 1\r\nif "%%1 %%2"=="repo create" (git init -q --bare "%s/github.com/%%3.git" & git -C "%%6" remote add origin "%s/github.com/%%3.git" & git -C "%%6" push -q -u origin HEAD & exit /b %%ERRORLEVEL%%)\r\nif "%%1 %%2"=="auth status" exit /b 0\r\nif "%%1 %%2"=="run list" (echo [{"status":"completed","conclusion":"success"}] & exit /b 0)\r\nexit /b 1\r\n' "$GH_FAKE_WIN" "$GH_FAKE_WIN" "$GH_FAKE_WIN" "$GH_FAKE_WIN" > "$WORK/ghbin/gh.cmd"
PATH_SH="$WORK/ghbin:$WORK/graftbin:$PATH"
}
