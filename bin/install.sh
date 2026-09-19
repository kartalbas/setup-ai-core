#!/usr/bin/env bash
# Install setup-ai-core on this machine, once: a clone (or the one you already have), its bin/
# on the PATH, and a first doctor run.
#
#   install.sh [--source <clone>] [--dir <path>] [--repo <url>] [--no-path] [--no-doctor]
#
set -euo pipefail

REPO_URL="https://github.com/kartalbas/setup-ai-core"
DIR="$HOME/.setup-ai-core"
SOURCE=""
ADD_PATH=1
RUN_DOCTOR=1

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      echo "Usage: install.sh [--source <clone>] [--dir <path>] [--repo <url>] [--no-path] [--no-doctor]"
      echo ""
      echo "Installs setup-ai-core on this machine, once: clones it to ~/.setup-ai-core (or uses the"
      echo "clone you already have), adds its bin/ directory, where the ai-core command lives, to the"
      echo "PATH, and runs doctor."
      echo ""
      echo "Options:"
      echo "  --source <clone>  Use this existing clone of setup-ai-core; nothing is cloned or linked"
      echo "  --dir <path>      Clone somewhere else than ~/.setup-ai-core"
      echo "  --repo <url>      Clone from this URL or path instead of GitHub (a mirror, a fork)"
      echo "  --no-path         Do not touch the shell profiles"
      echo "  --no-doctor       Do not run doctor at the end"
      echo "  -h, --help        Show this help message"
      exit 0 ;;
    --source) shift; [ $# -gt 0 ] || { echo "error: --source needs a path" >&2; exit 1; }; SOURCE="$1" ;;
    --dir) shift; [ $# -gt 0 ] || { echo "error: --dir needs a path" >&2; exit 1; }; DIR="$1" ;;
    --repo) shift; [ $# -gt 0 ] || { echo "error: --repo needs a URL or path" >&2; exit 1; }; REPO_URL="$1" ;;
    --no-path) ADD_PATH=0 ;;
    --no-doctor) RUN_DOCTOR=0 ;;
    *) echo "error: unknown option '$1' (see --help)" >&2; exit 1 ;;
  esac
  shift
done

case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) OS=windows ;; *) OS=posix ;; esac

# 1. The clone: the one named with --source, or one at $DIR, cloned when missing
if [ -n "$SOURCE" ]; then
  DIR="$(cd "$SOURCE" && pwd)"
  { [ -f "$DIR/VERSION" ] && [ -d "$DIR/templates" ]; } || { echo "error: $DIR is not a clone of setup-ai-core" >&2; exit 1; }
  echo "==> Using the clone at $DIR"
elif [ -d "$DIR/.git" ]; then
  echo "==> setup-ai-core is already at $DIR; pulling"
  git -C "$DIR" pull --ff-only
else
  echo "==> Cloning $REPO_URL to $DIR"
  mkdir -p "$(dirname "$DIR")"
  git clone --quiet "$REPO_URL" "$DIR"
fi
chmod +x "$DIR/bin/ai-core" "$DIR"/bin/*.sh

# 2. PATH: bin/ of the clone, where the ai-core command lives
BIN="$DIR/bin"
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
export PATH="$BIN:$PATH"

echo "==> setup-ai-core $(tr -d '\r\n' < "$DIR/VERSION") at $DIR"

# 3. doctor
if [ "$RUN_DOCTOR" -eq 1 ]; then
  echo ""
  bash "$DIR/bin/doctor.sh" || { echo "install: setup-ai-core is installed; doctor found problems (above)."; exit 1; }
fi
echo "Next: cd into a repository and run 'ai-core init'."
