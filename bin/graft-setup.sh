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
    echo "Wires Graft into the agents on this machine (graft init -y --no-build, no picker) and builds"
    echo "the code graph with the Node.js on this machine (npx -y @nanonets/graft build)."
    echo "Reads GRAFT_EXECUTION_MODE from .ai-core/config.env: native (default) or skip, and AGENTS: the"
    echo "agents Graft is wired into (claude, codex, antigravity, gemini, cursor, windsurf, copilot;"
    echo "openhands has no Graft wiring); empty means every agent Graft detects."
    echo "There is no fallback: without Node.js and npx, native mode fails with exit 1."
    echo "Whatever Graft writes into the repository is recorded in .git/info/exclude, so it is never committed."
    echo ""
    echo "Options:"
    echo "  -h, --help    Show this help message"
    echo ""
    echo "Examples:"
    echo "  ai-core graft"
    exit 0
  fi
done

TARGET="${1:-.}"
cd "$TARGET"

CONFIG_FILE=".ai-core/config.env"
GRAFT_EXECUTION_MODE="native"
AGENTS=""

if [ -f "$CONFIG_FILE" ]; then
  while IFS='=' read -r key value || [ -n "$key" ]; do
    if [[ "$key" =~ ^[[:space:]]*# ]] || [ -z "$key" ]; then continue; fi
    key="$(echo "$key" | tr -d '[:space:]')"
    # Strip inline comments, quotes and whitespace from the value, then lowercase it
    value="${value%%#*}"
    val="$(echo "$value" | tr -d '[:space:]"'\' | tr -d '\r')"
    val_lower="$(echo "$val" | tr '[:upper:]' '[:lower:]')"
    if [ "$key" = "GRAFT_EXECUTION_MODE" ]; then GRAFT_EXECUTION_MODE="$val_lower"; fi
    if [ "$key" = "AGENTS" ]; then AGENTS="$(echo "$value" | tr -d '"\r' | tr -d "'" | tr '[:upper:]' '[:lower:]')"; fi
  done < "$CONFIG_FILE"
fi

# The agents Graft wires, in Graft's own ids: codex reads AGENTS.md and ~/.codex, which Graft
# calls "agents"; openhands has no wiring of its own. Empty: whatever Graft detects (-y).
GRAFT_AGENTS=()
for a in $AGENTS; do
  case "$a" in
    codex) GRAFT_AGENTS+=(agents) ;;
    claude|antigravity|gemini|cursor|windsurf|copilot) GRAFT_AGENTS+=("$a") ;;
    openhands) ;;
    *) echo "error: AGENTS in $CONFIG_FILE names '$a'; known are claude, codex, antigravity, openhands, gemini, cursor, windsurf, copilot" >&2; exit 1 ;;
  esac
done
if [ ${#GRAFT_AGENTS[@]} -gt 0 ]; then GRAFT_INIT=(init --agents "${GRAFT_AGENTS[@]}" --no-build); else GRAFT_INIT=(init -y --no-build); fi

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

# What Graft writes into the repository (graft/, and the files graft init wires: GEMINI.md,
# .gemini/, .claude/skills/graft/, ...) stays out of every commit: its own block in
# .git/info/exclude, which keeps what earlier runs recorded and grows with what this run adds.
EXCLUDE=""
EXCLUDE="$(git rev-parse --git-path info/exclude 2>/dev/null)" || EXCLUDE=""
GRAFT_LINES="/graft/"
add_line() { case $'\n'"$GRAFT_LINES"$'\n' in *$'\n'"$1"$'\n'*) ;; *) GRAFT_LINES="$GRAFT_LINES"$'\n'"$1" ;; esac; }
write_block() {
  mkdir -p "$(dirname "$EXCLUDE")"
  {
    [ -f "$EXCLUDE" ] && awk '/^# setup-ai-core graft start/{skip=1} !skip{print} /^# setup-ai-core graft end/{skip=0}' "$EXCLUDE"
    echo "# setup-ai-core graft start: what Graft writes into the working tree, never into a commit"
    printf '%s\n' "$GRAFT_LINES"
    echo "# setup-ai-core graft end"
  } > "$EXCLUDE.tmp" && mv "$EXCLUDE.tmp" "$EXCLUDE"
}
snapshot() { git status --porcelain --untracked-files=all 2>/dev/null || true; }
if [ -n "$EXCLUDE" ]; then
  if [ -f "$EXCLUDE" ]; then
    while IFS= read -r line; do [ -n "$line" ] && add_line "$line"; done <<< "$(awk '/^# setup-ai-core graft start/{b=1; next} /^# setup-ai-core graft end/{b=0} b' "$EXCLUDE")"
  fi
  # What graft init wires into the repository, excluded whether it exists already or not
  while IFS= read -r line; do [ -n "$line" ] && add_line "/$line"; done <<< "$(npx -y @nanonets/graft "${GRAFT_INIT[@]}" --dry-run 2>&1 | tr -d '\r' | tr '\\' '/' | awk '/^would write.*this repo:/{b=1; next} !/^  /{b=0} b{print $1}')"
  write_block
  BEFORE="$(snapshot)"
fi

echo "==> Graft: building the code graph with npx -y @nanonets/graft..."
RESULT=0
{ npx -y @nanonets/graft "${GRAFT_INIT[@]}" && npx -y @nanonets/graft build; } || RESULT=1

if [ -n "$EXCLUDE" ]; then
  CHANGED=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case $'\n'"$BEFORE"$'\n' in *$'\n'"$line"$'\n'*) continue ;; esac
    case "$line" in
      "?? "*) add_line "/${line#\?\? }" ;;
      *) CHANGED="$CHANGED ${line#???}" ;;
    esac
  done <<< "$(snapshot)"
  write_block
  [ -z "$CHANGED" ] || echo "warning: Graft changed committed files:$CHANGED. Review them with git diff; keep or restore them." >&2
fi

if [ "$RESULT" -ne 0 ]; then
  echo "error: Graft build failed; see the output above. Fix the cause and run this script again, or set GRAFT_EXECUTION_MODE=\"skip\" in $CONFIG_FILE." >&2
  exit 1
fi
# One repository gets graft/index.md; a folder of repositories gets a workspace, graft/workspace.json
if [ -f "graft/workspace.json" ]; then
  echo "==> Graft workspace created at $(pwd)/graft/workspace.json: one graph over the repositories of this folder"
elif [ -f "graft/index.md" ] || [ -f "graft/INDEX.md" ]; then
  echo "==> Graft index created at $(pwd)/graft/index.md"
else
  echo "error: Graft finished without writing graft/index.md." >&2; exit 1
fi
