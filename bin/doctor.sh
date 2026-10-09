#!/usr/bin/env bash
# Check the prerequisites of the harness on this machine; install what is missing where that
# can be automated; exit 1 with the instruction for what cannot.
#
#   doctor.sh [--no-install]
#
set -euo pipefail

NO_INSTALL=0
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      echo "Usage: doctor.sh [--no-install]"
      echo ""
      echo "Checks Git, gh (with its login), Bash, PowerShell 7, Node.js 20+ with npx, and reports"
      echo "the agent CLIs (claude, agy, codex). Missing required tools are installed with the"
      echo "platform's package manager (winget, brew, apt-get). A login cannot be automated and"
      echo "is reported with its command. Exit 1 when a required tool is still missing afterwards."
      echo ""
      echo "Options:"
      echo "  --no-install  Only report; install nothing"
      echo "  -h, --help    Show this help message"
      exit 0 ;;
    --no-install) NO_INSTALL=1 ;;
    *) echo "error: unknown option '$arg' (see --help)" >&2; exit 1 ;;
  esac
done

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) OS=windows ;;
  Darwin) OS=macos ;;
  Linux) OS=linux ;;
  *) OS=other ;;
esac

PM=""
case "$OS" in
  windows) command -v winget >/dev/null 2>&1 && PM=winget ;;
  macos) command -v brew >/dev/null 2>&1 && PM=brew ;;
  linux) command -v apt-get >/dev/null 2>&1 && PM=apt-get ;;
esac

PROBLEMS=0
INSTALLED_SOMETHING=0

report() { printf '  %-12s %-12s %s\n' "$1" "$2" "$3"; }
problem() { PROBLEMS=$((PROBLEMS + 1)); }

# On Windows a tool installed a moment ago is not on this shell's PATH yet
refresh_path() {
  [ "$OS" = windows ] || return 0
  for d in "/c/Program Files/Git/cmd" "/c/Program Files/nodejs" "/c/Program Files/PowerShell/7" "/c/Program Files/GitHub CLI"; do
    [ -d "$d" ] && PATH="$PATH:$d"
  done
  [ -n "${LOCALAPPDATA:-}" ] && [ -d "$LOCALAPPDATA/Microsoft/WinGet/Links" ] && PATH="$PATH:$LOCALAPPDATA/Microsoft/WinGet/Links"
  return 0
}

# install <tool> <winget id> <brew formula> <apt package>
install_tool() {
  local tool="$1" winget_id="$2" brew_formula="$3" apt_pkg="$4"
  [ "$NO_INSTALL" -eq 0 ] || return 1
  [ -n "$PM" ] || return 1
  echo "--> Installing $tool with $PM..."
  case "$PM" in
    winget) winget install --id "$winget_id" -e --accept-source-agreements --accept-package-agreements --disable-interactivity >/dev/null || return 1 ;;
    brew) brew install "$brew_formula" >/dev/null || return 1 ;;
    apt-get)
      if [ "$(id -u)" = 0 ]; then apt-get install -y "$apt_pkg" >/dev/null || return 1
      elif command -v sudo >/dev/null 2>&1; then sudo apt-get install -y "$apt_pkg" >/dev/null || return 1
      else return 1; fi ;;
  esac
  INSTALLED_SOMETHING=1
  refresh_path
}

major_of() { echo "$1" | sed -E 's/^[^0-9]*([0-9]+).*/\1/'; }

echo "==> doctor: $OS, package manager: ${PM:-none}"

# Git
if ! command -v git >/dev/null 2>&1; then install_tool git Git.Git git git || true; fi
if command -v git >/dev/null 2>&1; then
  report git present "$(git --version 2>/dev/null | head -1)"
else
  report git MISSING "install Git from https://git-scm.com"; problem
fi

# gh
if ! command -v gh >/dev/null 2>&1; then install_tool gh GitHub.cli gh gh || true; fi
if command -v gh >/dev/null 2>&1; then
  # the board commands write Projects v2, which a login with gh's default scopes cannot; a token
  # gh lists no scopes for (a fine-grained one, GH_TOKEN) is not judged
  if gh_status="$(gh auth status 2>&1)"; then
    if grep -q 'Token scopes:' <<< "$gh_status" && ! grep -q "'project'" <<< "$gh_status"; then
      report gh "no project scope" "the board commands read and write the project board; run: gh auth refresh -h github.com -s project"; problem
    else
      report gh present "$(gh --version 2>/dev/null | head -1), logged in"
    fi
  else
    report gh "not logged in" "run: gh auth login"; problem
  fi
else
  report gh MISSING "install GitHub CLI from https://cli.github.com"; problem
fi

# Bash (this script runs in it)
report bash present "${BASH_VERSION%%(*}$([ "$OS" = windows ] && echo ' (Git Bash)')"

# PowerShell 7: required on Windows, optional elsewhere
if ! command -v pwsh >/dev/null 2>&1 && [ "$OS" = windows ]; then install_tool pwsh Microsoft.PowerShell powershell powershell || true; fi
if command -v pwsh >/dev/null 2>&1; then
  PWSH_VERSION="$(pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null | tr -d '\r')"
  if [ "$(major_of "$PWSH_VERSION")" -ge 7 ] 2>/dev/null; then
    report pwsh present "PowerShell $PWSH_VERSION"
  else
    report pwsh "too old" "PowerShell $PWSH_VERSION; 7 or newer is needed"; problem
  fi
elif [ "$OS" = windows ]; then
  report pwsh MISSING "install PowerShell 7: winget install Microsoft.PowerShell"; problem
else
  report pwsh optional "not installed; the .sh twins are enough here"
fi

# Node.js 20+ with npx
if ! command -v node >/dev/null 2>&1; then install_tool node OpenJS.NodeJS.LTS node nodejs || true; fi
if command -v node >/dev/null 2>&1; then
  NODE_VERSION="$(node -v 2>/dev/null | tr -d '\r')"
  if [ "$(major_of "$NODE_VERSION")" -ge 20 ] 2>/dev/null; then
    if command -v npx >/dev/null 2>&1; then
      report node present "Node.js $NODE_VERSION with npx"
    else
      if [ "$PM" = apt-get ]; then install_tool npx npm npm npm || true; fi
      if command -v npx >/dev/null 2>&1; then report node present "Node.js $NODE_VERSION with npx"; else report npx MISSING "Node.js $NODE_VERSION has no npx; install npm"; problem; fi
    fi
  else
    report node "too old" "Node.js $NODE_VERSION; 20 or newer is needed, see https://nodejs.org"; problem
  fi
else
  report node MISSING "install Node.js 20 or newer from https://nodejs.org"; problem
fi

# jq: every board and issue command reads GitHub's answers through it
if ! command -v jq >/dev/null 2>&1; then install_tool jq jqlang.jq jq jq || true; fi
if command -v jq >/dev/null 2>&1; then
  report jq present "$(jq --version 2>/dev/null | head -1)"
else
  report jq MISSING "install jq from https://jqlang.github.io/jq"; problem
fi

# gitleaks, where a repository of this project folder carries .gitleaks.toml: the push gate reads
# every push there with `gitleaks git`, which came with gitleaks 8.19, and refuses the push without
# it. winget and brew have a recent one; apt's is 8.16 on every Ubuntu to date, so elsewhere the
# release comes from GitHub, into ~/.local/bin.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/layers.sh"
LEAKS_REPOS=""
for f in "$(project_folder_of "$PWD")"/*/.gitleaks.toml; do [ -f "$f" ] || continue; LEAKS_REPOS="$LEAKS_REPOS $(basename "$(dirname "$f")")"; done
if [ -n "$LEAKS_REPOS" ]; then
  leaks_ok() { command -v gitleaks >/dev/null 2>&1 && gitleaks git --help >/dev/null 2>&1; }
  leaks_release() {
    local os arch tmp rc=0
    case "$OS" in linux) os=linux ;; macos) os=darwin ;; *) return 1 ;; esac
    case "$(uname -m)" in x86_64|amd64) arch=x64 ;; aarch64|arm64) arch=arm64 ;; armv7l) arch=armv7 ;; *) return 1 ;; esac
    command -v gh >/dev/null 2>&1 && command -v tar >/dev/null 2>&1 || return 1
    echo "--> Installing gitleaks from its GitHub release into ~/.local/bin..."
    tmp="$(mktemp -d)"
    { gh release download --repo gitleaks/gitleaks --pattern "gitleaks_*_${os}_${arch}.tar.gz" --dir "$tmp" >/dev/null 2>&1 \
      && mkdir -p "$HOME/.local/bin" && tar -xzf "$tmp"/gitleaks_*.tar.gz -C "$HOME/.local/bin" gitleaks; } || rc=1
    rm -rf "$tmp"
    [ "$rc" -eq 0 ] || return 1
    case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH"; LEAKS_NOTE="note: ~/.local/bin, where gitleaks is now, is not on the PATH of this shell; log in again (a login shell adds it once it exists) or add it to your profile" ;; esac
    INSTALLED_SOMETHING=1
  }
  LEAKS_NOTE=""; LEAKS_NEW=0
  if ! leaks_ok && [ "$NO_INSTALL" -eq 0 ]; then
    case "$PM" in winget|brew) install_tool gitleaks Gitleaks.Gitleaks gitleaks - && LEAKS_NEW=1 ;; *) leaks_release && LEAKS_NEW=1 ;; esac
  fi
  case "$OS" in
    windows) how="winget install --id Gitleaks.Gitleaks -e" ;;
    macos) how="brew install gitleaks" ;;
    *) how="the gitleaks release for this machine from https://github.com/gitleaks/gitleaks/releases, unpacked into ~/.local/bin" ;;
  esac
  [ "$NO_INSTALL" -eq 0 ] || how="run doctor without --no-install, which installs it, or: $how"
  if leaks_ok; then
    v="$(gitleaks version 2>/dev/null | tr -d '\r' | sed -n '1s/^v\{0,1\}\([0-9][0-9.]*\)$/\1/p')"
    report gitleaks "$([ "$LEAKS_NEW" -eq 1 ] && echo installed || echo present)" "gitleaks${v:+ $v}, for .gitleaks.toml in:$LEAKS_REPOS"
  elif command -v gitleaks >/dev/null 2>&1; then report gitleaks "too old" "$(command -v gitleaks) has no 'gitleaks git', which the push gate runs (8.19 or newer); $how"; problem
  else report gitleaks MISSING "the push gate reads every push with it where .gitleaks.toml is:$LEAKS_REPOS; $how"; problem; fi
  [ -z "$LEAKS_NOTE" ] || echo "$LEAKS_NOTE"
fi

# An agent definition of this machine that names a model below Sonnet
for f in "$HOME"/.claude/agents/*.md; do
  [ -f "$f" ] || continue
  m="$(sed -n '2,/^---/{s/^model:[[:space:]]*//p;}' "$f" | head -n1 | tr -d "\r\"'")"
  case "$(tr '[:upper:]' '[:lower:]' <<< "$m")" in *haiku*) report agent "below Sonnet" "$f names the model $m" ;; esac
done

# Agent CLIs: reported, never installed by doctor
for cli in claude agy codex; do
  if command -v "$cli" >/dev/null 2>&1; then
    report "$cli" present "$(command -v "$cli")"
  else
    case "$cli" in
      claude) hint="Claude Code: https://claude.ai/install.ps1 or install.sh" ;;
      agy) hint="Antigravity: https://antigravity.google/cli/install.ps1 or install.sh" ;;
      codex) hint="Codex: npm install -g @openai/codex" ;;
    esac
    report "$cli" absent "$hint"
  fi
done

# A session-start hook in the machine-wide Claude Code settings that starts a script of an
# earlier layout (a session-start.sh or .ps1 beside the repositories): the repository's own
# .claude/settings.json carries the hook now, so the stale one is taken out.
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
if [ -f "$CLAUDE_SETTINGS" ] && command -v jq >/dev/null 2>&1; then
  STALE_HOOKS="$(jq '[.hooks.SessionStart[]?.hooks[]?.command // empty | select(test("session-start\\.(sh|ps1)"))] | length' "$CLAUDE_SETTINGS" 2>/dev/null || echo 0)"
  if [ "$STALE_HOOKS" -gt 0 ]; then
    if [ "$NO_INSTALL" -eq 1 ]; then report "claude hook" stale "$CLAUDE_SETTINGS starts a session-start script of an earlier layout; run doctor without --no-install to take it out"; problem
    else
      jq '.hooks.SessionStart = [.hooks.SessionStart[]? | .hooks = [.hooks[]? | select((.command // "") | test("session-start\\.(sh|ps1)") | not)] | select(.hooks | length > 0)]' "$CLAUDE_SETTINGS" > "$CLAUDE_SETTINGS.tmp" && mv "$CLAUDE_SETTINGS.tmp" "$CLAUDE_SETTINGS"
      report "claude hook" repaired "$CLAUDE_SETTINGS started a session-start script of an earlier layout; taken out, the repository's own .claude/settings.json carries the hook now"
    fi
  fi
fi

# Claude Code keeps a project's memory in ~/.claude/projects/<project>/memory. A tool of an earlier
# layout made that folder a link into a repository; where the target is gone, Claude Code cannot
# write a memory for that project, so the dead link is taken out and Claude Code makes a real
# folder at the next memory it writes. Nothing is lost: the target is not there.
for link in "$HOME"/.claude/projects/*/memory; do
  [ -L "$link" ] && [ ! -e "$link/" ] || continue
  target="$(readlink "$link" || true)"
  if [ "$NO_INSTALL" -eq 1 ]; then report "claude memory" stale "$link points at $target, which is gone; run doctor without --no-install to take the link out"; problem
  else rm "$link" && report "claude memory" repaired "$link pointed at $target, which is gone; taken out, Claude Code makes a real folder at the next memory it writes"; fi
done

# The team modes of every agent tool on this machine: checked, and installed when one is missing
# (team-modes.tsv says how, per tool). A plugin loads when the tool starts, so a fresh install
# needs the tool restarted; the check says which.
DOCTOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if bash "$DOCTOR_DIR/team-modes-check.sh" --quiet >/dev/null 2>&1; then
  report "team modes" present "every mode of every agent tool here is installed"
elif [ "$NO_INSTALL" -eq 1 ]; then
  report "team modes" MISSING "run: ai-core team-modes-install, then restart the tool"; problem
else
  echo "--> installing the missing team modes (ai-core team-modes-install)..."
  if bash "$DOCTOR_DIR/team-modes-install.sh" && bash "$DOCTOR_DIR/team-modes-check.sh" --quiet >/dev/null 2>&1; then
    report "team modes" installed "restart your agent tool: a plugin loads when the tool starts"
    INSTALLED_SOMETHING=1
  else
    report "team modes" MISSING "the lines above say which mode and how; run: ai-core team-modes-check"; problem
  fi
fi

if [ "$INSTALLED_SOMETHING" -eq 1 ]; then
  echo "note: something was installed; open a new terminal if a tool is still reported missing."
fi

if [ "$PROBLEMS" -gt 0 ]; then
  echo "doctor: $PROBLEMS problem(s); fix them and run doctor again."
  exit 1
fi
echo "doctor: OK"
