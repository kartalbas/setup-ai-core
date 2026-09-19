#!/usr/bin/env bash
# Build the Graft code graph of the target repository, natively or not at all.
#
#   graft-setup.sh [TARGET_DIR]
#
set -euo pipefail

for arg in "$@"; do
  if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
    echo "Usage: graft-setup.sh [TARGET_DIR]"
    echo ""
    echo "Builds the Graft code graph with the Node.js on this machine (npx -y @nanonets/graft)."
    echo "Reads GRAFT_EXECUTION_MODE from .ai-core/config.env: native (default) or skip."
    echo "There is no fallback: without Node.js and npx, native mode fails with exit 1."
    echo ""
    echo "Options:"
    echo "  -h, --help    Show this help message"
    echo ""
    echo "Examples:"
    echo "  bash .ai-core/bin/graft-setup.sh ."
    exit 0
  fi
done

TARGET="${1:-.}"
cd "$TARGET"

CONFIG_FILE=".ai-core/config.env"
GRAFT_EXECUTION_MODE="native"

if [ -f "$CONFIG_FILE" ]; then
  while IFS='=' read -r key value || [ -n "$key" ]; do
    if [[ "$key" =~ ^[[:space:]]*# ]] || [ -z "$key" ]; then continue; fi
    key="$(echo "$key" | tr -d '[:space:]')"
    # Strip inline comments, quotes and whitespace from the value, then lowercase it
    value="${value%%#*}"
    val="$(echo "$value" | tr -d '[:space:]"'\' | tr -d '\r')"
    val_lower="$(echo "$val" | tr '[:upper:]' '[:lower:]')"
    if [ "$key" = "GRAFT_EXECUTION_MODE" ]; then GRAFT_EXECUTION_MODE="$val_lower"; fi
  done < "$CONFIG_FILE"
fi

case "$GRAFT_EXECUTION_MODE" in
  native|skip) ;;
  *) echo "error: GRAFT_EXECUTION_MODE must be native or skip (got '$GRAFT_EXECUTION_MODE') in $CONFIG_FILE" >&2; exit 1 ;;
esac

if [ "$GRAFT_EXECUTION_MODE" = "skip" ]; then
  echo "==> Graft: skipped by $CONFIG_FILE."
  exit 0
fi

if ! command -v npx >/dev/null 2>&1; then
  echo "error: Graft needs Node.js with npx on this machine and there is no fallback. Install Node.js 20+ or set GRAFT_EXECUTION_MODE=\"skip\" in $CONFIG_FILE." >&2
  exit 1
fi

echo "==> Graft: building the code graph with npx -y @nanonets/graft..."
if ! { npx -y @nanonets/graft init && npx -y @nanonets/graft build; }; then
  echo "error: Graft build failed; see the output above. Fix the cause and run this script again, or set GRAFT_EXECUTION_MODE=\"skip\" in $CONFIG_FILE." >&2
  exit 1
fi
[ -f "graft/index.md" ] || [ -f "graft/INDEX.md" ] || { echo "error: Graft finished without writing graft/index.md." >&2; exit 1; }
echo "==> Graft index created at $(pwd)/graft/index.md"
