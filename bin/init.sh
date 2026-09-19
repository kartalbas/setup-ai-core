#!/usr/bin/env bash
# Bootstrap a target repository with setup-ai-core agnostic harness
#
#   init.sh [TARGET_DIR] [--all <folder>] [--no-doctor] [--remote]
#
# Supports:
# - Claude Code (.claude)
# - OpenHands (.openhands)
# - OpenAI Codex & OpenCode (AGENTS.md)
# - Google Antigravity (.gemini & AGENTS.md)
# - Cursor (.cursorrules)
# - Windsurf (.windsurfrules)
# - Aider (.aider.conf.yml)
# - GitHub Copilot (.github/copilot-instructions.md)
#
set -euo pipefail

for arg in "$@"; do
  if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
    echo "Usage: init.sh [TARGET_DIR] [--all <folder>] [--no-doctor] [--remote]"
    echo ""
    echo "Bootstraps a target repository with the setup-ai-core agnostic harness."
    echo ""
    echo "Options:"
    echo "  -h, --help       Show this help message"
    echo "  --all <folder>   Run init in every git repository directly under <folder>"
    echo "  --no-doctor      Do not run doctor first"
    echo "  --remote         Force remote mode (download from GitHub even if local repo exists)"
    echo ""
    echo "Examples:"
    echo "  bash init.sh ."
    echo "  bash init.sh ../my-project"
    echo "  bash init.sh --all ../my-org"
    exit 0
  fi
done

# A local clone is recognised by templates/ and VERSION next to bin/; a deployed
# .ai-core/ has neither. BASH_SOURCE is empty when the script is piped into bash.
CORE_ROOT=""
if [ -n "${BASH_SOURCE[0]:-}" ]; then
  CANDIDATE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  [ -d "$CANDIDATE/templates" ] && [ -f "$CANDIDATE/VERSION" ] && CORE_ROOT="$CANDIDATE"
fi

TARGET="."
REMOTE_MODE=0
RUN_DOCTOR=1
ALL_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --remote) REMOTE_MODE=1 ;;
    --no-doctor) RUN_DOCTOR=0 ;;
    --all) shift; [ $# -gt 0 ] || { echo "error: --all needs a folder" >&2; exit 1; }; ALL_DIR="$1" ;;
    -*)       echo "error: unknown option '$1' (see --help)" >&2; exit 1 ;;
    *)        TARGET="$1" ;;
  esac
  shift
done

# --all: doctor once, then init in every git repository directly under the folder
if [ -n "$ALL_DIR" ]; then
  ALL_DIR="$(cd "$ALL_DIR" && pwd)"
  if [ "$RUN_DOCTOR" -eq 1 ]; then
    bash "$(dirname "${BASH_SOURCE[0]}")/doctor.sh" || { echo "error: fix the problems doctor reported, then run init again (or pass --no-doctor)." >&2; exit 1; }
  fi
  OK=0; FAILED=""
  for repo in "$ALL_DIR"/*/; do
    repo="${repo%/}"
    [ -e "$repo/.git" ] || continue
    echo ""; echo "### $(basename "$repo")"
    ARGS=("$repo" --no-doctor); [ "$REMOTE_MODE" -eq 1 ] && ARGS+=(--remote)
    if bash "${BASH_SOURCE[0]}" "${ARGS[@]}"; then OK=$((OK + 1)); else FAILED="$FAILED $(basename "$repo")"; fi
  done
  echo ""; echo "==> init --all: $OK repositories initialized${FAILED:+; failed:$FAILED}"
  [ -z "$FAILED" ]
  exit $?
fi

TARGET="$(cd "$TARGET" && pwd)"
ARCHIVE_URL="https://github.com/kartalbas/setup-ai-core/archive/refs/heads/main.tar.gz"

echo "=================================================="
echo "Initializing Agnostic AI Core Harness in: $TARGET"
echo "Target Environment : Agnostic (Multi-Agent)"
echo "=================================================="

# Source: the local clone, or one archive download so remote installs get the same files
if [ -z "$CORE_ROOT" ] || [ "$REMOTE_MODE" -eq 1 ]; then
  SRC_TMP="$(mktemp -d)"
  trap 'rm -rf "$SRC_TMP"' EXIT
  echo "--> Downloading setup-ai-core ($ARCHIVE_URL)..."
  curl -sSfL "$ARCHIVE_URL" | tar -xz -C "$SRC_TMP"
  CORE_ROOT="$SRC_TMP/setup-ai-core-main"
else
  echo "--> Deploying from local clone: $CORE_ROOT"
fi

# The prerequisites first; nothing is deployed on a machine that cannot run the harness
if [ "$RUN_DOCTOR" -eq 1 ]; then
  bash "$CORE_ROOT/bin/doctor.sh" || { echo "error: fix the problems doctor reported, then run init again (or pass --no-doctor)." >&2; exit 1; }
fi

# Ensure target isolation directory exists (.ai-core)
AI_CORE_DIR="$TARGET/.ai-core"
AI_CORE_BIN="$AI_CORE_DIR/bin"
AI_CORE_RULES="$AI_CORE_DIR/rules"
AI_CORE_DOCS="$AI_CORE_DIR/docs"

mkdir -p "$AI_CORE_DIR" "$AI_CORE_BIN" "$AI_CORE_RULES" "$AI_CORE_DOCS"

# 1. Deploy Rules, Automation Scripts and VERSION (always refreshed).
#    The rules are one file per section in setup-ai-core and one assembled file in the checkout,
#    each section headed by a comment that names its source.
CORE_VERSION="$(tr -d '\r\n' < "$CORE_ROOT/VERSION")"
{
  for f in "$CORE_ROOT"/rules/[0-9][0-9]-*.md; do
    printf '<!-- setup-ai-core %s: rules/%s -->\n' "$CORE_VERSION" "$(basename "$f")"
    cat "$f"
    printf '\n'
  done
} > "$AI_CORE_RULES/rules.md"
cp -f "$CORE_ROOT/rules/skills.md" "$AI_CORE_RULES/skills.md"
# init itself is not deployed: run from the target it would treat .ai-core as its source
for s in session-start solution-path rules-check install-skills graft-setup; do
  cp -f "$CORE_ROOT/bin/$s.sh" "$CORE_ROOT/bin/$s.ps1" "$AI_CORE_BIN/"
done
chmod +x "$AI_CORE_BIN/"*.sh
cp -f "$CORE_ROOT/VERSION" "$AI_CORE_DIR/VERSION"

# 2. Deploy bridge files, created once and never overwritten: templates/ mirrors the target layout
(cd "$CORE_ROOT/templates" && find . -type f) | sed 's|^\./||' | while IFS= read -r rel; do
  if [ ! -e "$TARGET/$rel" ]; then
    mkdir -p "$(dirname "$TARGET/$rel")"
    cp "$CORE_ROOT/templates/$rel" "$TARGET/$rel"
    echo "--> Created $rel"
  else
    echo "--> Kept $rel (already present)"
  fi
done
# The Claude Code helpers are harness code and are always refreshed
cp -f "$CORE_ROOT/templates/.claude/helpers/"*.cjs "$TARGET/.claude/helpers/"

# 3. Keep the harness out of the repository's history: every deployed path goes into the
#    clone's own exclude file, which no commit ever contains. Worktrees share it.
if EXCLUDE="$(cd "$TARGET" && git rev-parse --git-path info/exclude 2>/dev/null)"; then
  (
    cd "$TARGET"
    mkdir -p "$(dirname "$EXCLUDE")"
    {
      [ -f "$EXCLUDE" ] && awk '/^# setup-ai-core start/{skip=1} !skip{print} /^# setup-ai-core end/{skip=0}' "$EXCLUDE"
      echo "# setup-ai-core start: the harness lives in the working tree only, never in a commit"
      echo "/.ai-core/"
      (cd "$CORE_ROOT/templates" && find . -type f) | sed 's|^\./|/|'
      echo "# setup-ai-core end"
    } > "$EXCLUDE.tmp" && mv "$EXCLUDE.tmp" "$EXCLUDE"
    echo "--> Registered the harness in $EXCLUDE: nothing to commit"
  )
else
  echo "note: $TARGET is not a git repository; nothing to exclude"
fi

# 4. Skills pointer and the Graft code graph. Graft is built with the local Node.js or the
#    whole init fails; there is no fallback.
echo "--> Installing / verifying agent skills..."
(cd "$TARGET" && bash "$AI_CORE_BIN/install-skills.sh")

echo "--> Setting up Graft code intelligence..."
if ! bash "$AI_CORE_BIN/graft-setup.sh" "$TARGET"; then
  echo "error: the harness files are in place but the Graft code graph is not (see above). Fix the cause and run 'bash .ai-core/bin/graft-setup.sh', or set GRAFT_EXECUTION_MODE=\"skip\" in .ai-core/config.env." >&2
  exit 1
fi

echo "=================================================="
echo "✓ Agnostic AI Core Harness successfully initialized!"
echo "Supported Agents: Claude Code, OpenHands, Codex, Antigravity, Cursor, Windsurf, Aider"
echo "Run 'bash .ai-core/bin/session-start.sh' to verify."
echo "=================================================="
