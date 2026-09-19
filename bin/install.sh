#!/usr/bin/env bash
# Install setup-ai-core on this machine, once: the clone at ~/.setup-ai-core, its bin/ on the
# PATH, and a first doctor run.
#
#   install.sh [--source <clone>] [--dir <path>] [--no-path] [--no-doctor]
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
      echo "Usage: install.sh [--source <clone>] [--dir <path>] [--no-path] [--no-doctor]"
      echo ""
      echo "Installs setup-ai-core on this machine, once: clones it to ~/.setup-ai-core, adds its bin/"
      echo "directory (where the ai-core command lives) to the PATH, and runs doctor."
      echo ""
      echo "Options:"
      echo "  --source <clone>  Use an existing clone of setup-ai-core instead of cloning: ~/.setup-ai-core becomes a link to it"
      echo "  --dir <path>      Install somewhere else than ~/.setup-ai-core"
      echo "  --no-path         Do not touch the shell profiles"
      echo "  --no-doctor       Do not run doctor at the end"
      echo "  -h, --help        Show this help message"
      exit 0 ;;
    --source) shift; [ $# -gt 0 ] || { echo "error: --source needs a path" >&2; exit 1; }; SOURCE="$1" ;;
    --dir) shift; [ $# -gt 0 ] || { echo "error: --dir needs a path" >&2; exit 1; }; DIR="$1" ;;
    --no-path) ADD_PATH=0 ;;
    --no-doctor) RUN_DOCTOR=0 ;;
    *) echo "error: unknown option '$1' (see --help)" >&2; exit 1 ;;
  esac
  shift
done

case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) OS=windows ;; *) OS=posix ;; esac
mkdir -p "$(dirname "$DIR")"

echo "==> Installing setup-ai-core at $DIR"

# 1. The clone: a link to an existing one, or a fresh clone from GitHub
if [ -n "$SOURCE" ]; then
  SOURCE="$(cd "$SOURCE" && pwd)"
  { [ -f "$SOURCE/VERSION" ] && [ -d "$SOURCE/templates" ]; } || { echo "error: $SOURCE is not a clone of setup-ai-core" >&2; exit 1; }
  if [ -L "$DIR" ]; then
    if [ "$OS" = windows ]; then MSYS_NO_PATHCONV=1 cmd /c rmdir "$(cygpath -w "$DIR")"; else rm "$DIR"; fi
  elif [ -e "$DIR" ]; then
    echo "error: $DIR exists and is not a link; remove it first or omit --source" >&2; exit 1
  fi
  if [ "$OS" = windows ]; then
    MSYS_NO_PATHCONV=1 cmd /c mklink /J "$(cygpath -w "$DIR")" "$(cygpath -w "$SOURCE")" >/dev/null
  else
    ln -s "$SOURCE" "$DIR"
  fi
  echo "--> $DIR -> $SOURCE"
elif [ -d "$DIR/.git" ] || [ -L "$DIR" ]; then
  echo "--> Already at $DIR; pulling"
  git -C "$DIR" pull --ff-only
else
  echo "--> Cloning $REPO_URL"
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

echo "==> Installed setup-ai-core $(tr -d '\r\n' < "$DIR/VERSION")."

# 3. doctor
if [ "$RUN_DOCTOR" -eq 1 ]; then
  echo ""
  bash "$DIR/bin/doctor.sh" || { echo "install: setup-ai-core is installed; doctor found problems (above)."; exit 1; }
fi
echo "Next: cd into a repository and run 'ai-core init'."
