#!/usr/bin/env bash
# Install the harness on this machine, once: the engine under ~/.ai-core/engine, the ai-core
# command under ~/.ai-core/bin, the PATH entry, and a first doctor run.
#
#   install.sh [--engine <clone>] [--no-path] [--no-doctor]
#
set -euo pipefail

AI_CORE_HOME="${AI_CORE_HOME:-$HOME/.ai-core}"
REPO_URL="https://github.com/kartalbas/setup-ai-core"
ENGINE_SRC=""
ADD_PATH=1
RUN_DOCTOR=1

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      echo "Usage: install.sh [--engine <clone>] [--no-path] [--no-doctor]"
      echo ""
      echo "Installs the harness on this machine, once. Clones the engine to \$AI_CORE_HOME/engine"
      echo "(default ~/.ai-core/engine), puts the ai-core command into \$AI_CORE_HOME/bin, adds that"
      echo "directory to the PATH, and runs doctor."
      echo ""
      echo "Options:"
      echo "  --engine <clone>  Use an existing clone of setup-ai-core as the engine (a link, no copy)"
      echo "  --no-path         Do not touch the shell profiles"
      echo "  --no-doctor       Do not run doctor at the end"
      echo "  -h, --help        Show this help message"
      exit 0 ;;
    --engine) shift; [ $# -gt 0 ] || { echo "error: --engine needs a path" >&2; exit 1; }; ENGINE_SRC="$1" ;;
    --no-path) ADD_PATH=0 ;;
    --no-doctor) RUN_DOCTOR=0 ;;
    *) echo "error: unknown option '$1' (see --help)" >&2; exit 1 ;;
  esac
  shift
done

case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) OS=windows ;; *) OS=posix ;; esac
ENGINE="$AI_CORE_HOME/engine"
BIN="$AI_CORE_HOME/bin"
mkdir -p "$BIN"

echo "==> Installing setup-ai-core under $AI_CORE_HOME"

# 1. The engine: a link to an existing clone, or a fresh clone from GitHub
if [ -n "$ENGINE_SRC" ]; then
  ENGINE_SRC="$(cd "$ENGINE_SRC" && pwd)"
  { [ -f "$ENGINE_SRC/VERSION" ] && [ -d "$ENGINE_SRC/templates" ]; } || { echo "error: $ENGINE_SRC is not a clone of setup-ai-core" >&2; exit 1; }
  if [ -e "$ENGINE" ] || [ -L "$ENGINE" ]; then
    if [ -L "$ENGINE" ]; then
      if [ "$OS" = windows ]; then MSYS_NO_PATHCONV=1 cmd /c rmdir "$(cygpath -w "$ENGINE")"; else rm "$ENGINE"; fi
    else
      echo "error: $ENGINE exists and is not a link; remove it first or omit --engine" >&2; exit 1
    fi
  fi
  if [ "$OS" = windows ]; then
    MSYS_NO_PATHCONV=1 cmd /c mklink /J "$(cygpath -w "$ENGINE")" "$(cygpath -w "$ENGINE_SRC")" >/dev/null
  else
    ln -s "$ENGINE_SRC" "$ENGINE"
  fi
  echo "--> Engine: $ENGINE -> $ENGINE_SRC"
elif [ -d "$ENGINE/.git" ] || [ -L "$ENGINE" ]; then
  echo "--> Engine already at $ENGINE; pulling"
  git -C "$ENGINE" pull --ff-only
else
  echo "--> Cloning $REPO_URL to $ENGINE"
  git clone --quiet "$REPO_URL" "$ENGINE"
fi

# 2. The command: thin launchers that resolve everything from the engine at run time
cp -f "$ENGINE/bin/ai-core" "$ENGINE/bin/ai-core.ps1" "$ENGINE/bin/ai-core.cmd" "$BIN/"
chmod +x "$BIN/ai-core"
echo "--> Command: $BIN/ai-core"

# 3. PATH
if [ "$ADD_PATH" -eq 1 ]; then
  LINE="export PATH=\"$BIN:\$PATH\"  # setup-ai-core"
  ADDED=""
  for profile in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
    [ -f "$profile" ] || continue
    grep -qF '# setup-ai-core' "$profile" || { printf '\n%s\n' "$LINE" >> "$profile"; ADDED="$ADDED $(basename "$profile")"; }
  done
  if [ ! -f "$HOME/.bashrc" ] && [ ! -f "$HOME/.zshrc" ] && [ ! -f "$HOME/.profile" ]; then
    printf '%s\n' "$LINE" > "$HOME/.profile"; ADDED=" .profile"
  fi
  [ -n "$ADDED" ] && echo "--> PATH: added $BIN to$ADDED (open a new terminal)" || echo "--> PATH: already set in the shell profiles"
  [ "$OS" = windows ] && echo "note: for PowerShell and cmd on Windows run bin\\install.ps1 too, which sets the user PATH."
fi

echo "==> Installed engine $(tr -d '\r\n' < "$ENGINE/VERSION")."
export PATH="$BIN:$PATH"

# 4. doctor
if [ "$RUN_DOCTOR" -eq 1 ]; then
  echo ""
  bash "$ENGINE/bin/doctor.sh" || { echo "install: the harness is installed; doctor found problems (above)."; exit 1; }
fi
echo "Next: cd into a repository and run 'ai-core init'."
