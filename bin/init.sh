#!/usr/bin/env bash
# Install or refresh the harness in a checkout, in a project folder, or in every repository
# under a folder. The scripts stay in the setup-ai-core clone and run as `ai-core <command>`;
# a checkout receives only data: the assembled rules, the configuration and the agent files.
#
#   init.sh [TARGET_DIR] [--all <folder>] [--no-doctor]
#
set -euo pipefail

for arg in "$@"; do
  if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
    echo "Usage: init.sh [TARGET_DIR] [--all <folder>] [--no-doctor]"
    echo ""
    echo "Installs or refreshes the harness in TARGET_DIR (default: the current directory):"
    echo "the assembled rules and the configuration in .ai-core/, the agent files (AGENTS.md,"
    echo ".claude/settings.json, ...) created once, everything registered in .git/info/exclude,"
    echo "and the Graft code graph. A folder that is no repository but holds repositories is a"
    echo "project folder: it gets an AGENTS.md that lists them."
    echo ""
    echo "Options:"
    echo "  -h, --help       Show this help message"
    echo "  --all <folder>   Init the folder itself and every git repository directly under it"
    echo "  --no-doctor      Do not run doctor first"
    echo ""
    echo "Examples:"
    echo "  ai-core init"
    echo "  ai-core init ../my-project"
    echo "  ai-core init --all ../my-org"
    exit 0
  fi
done

CORE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -d "$CORE_ROOT/templates" ] && [ -f "$CORE_ROOT/VERSION" ] || { echo "error: $CORE_ROOT is not a clone of setup-ai-core; run init from the clone (ai-core init)" >&2; exit 1; }

TARGET="."
RUN_DOCTOR=1
ALL_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --no-doctor) RUN_DOCTOR=0 ;;
    --all) shift; [ $# -gt 0 ] || { echo "error: --all needs a folder" >&2; exit 1; }; ALL_DIR="$1" ;;
    -*)       echo "error: unknown option '$1' (see --help)" >&2; exit 1 ;;
    *)        TARGET="$1" ;;
  esac
  shift
done

# The prerequisites first; nothing is deployed on a machine that cannot run the harness
if [ "$RUN_DOCTOR" -eq 1 ]; then
  bash "$CORE_ROOT/bin/doctor.sh" || { echo "error: fix the problems doctor reported, then run init again (or pass --no-doctor)." >&2; exit 1; }
fi

# --all: every git repository directly under the folder, then the folder itself
if [ -n "$ALL_DIR" ]; then
  ALL_DIR="$(cd "$ALL_DIR" && pwd)"
  OK=0; FAILED=""
  for repo in "$ALL_DIR"/*/; do
    repo="${repo%/}"
    [ -e "$repo/.git" ] || continue
    echo ""; echo "### $(basename "$repo")"
    if bash "${BASH_SOURCE[0]}" "$repo" --no-doctor; then OK=$((OK + 1)); else FAILED="$FAILED $(basename "$repo")"; fi
  done
  echo ""; echo "### $(basename "$ALL_DIR") (the folder itself)"
  bash "${BASH_SOURCE[0]}" "$ALL_DIR" --no-doctor || FAILED="$FAILED $(basename "$ALL_DIR")/"
  echo ""; echo "==> init --all: $OK repositories initialized${FAILED:+; failed:$FAILED}"
  [ -z "$FAILED" ]
  exit $?
fi

TARGET="$(cd "$TARGET" && pwd)"

# A project folder is no git work tree and holds git checkouts directly below it
PROJECT_FOLDER=0
if ! git -C "$TARGET" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  for d in "$TARGET"/*/; do [ -e "$d.git" ] && { PROJECT_FOLDER=1; break; }; done
fi

echo "=================================================="
echo "Initializing the harness in: $TARGET"
[ "$PROJECT_FOLDER" -eq 1 ] && echo "A project folder: the repositories below it get their own init"
echo "=================================================="
echo "--> From $CORE_ROOT"

AI_CORE_DIR="$TARGET/.ai-core"
AI_CORE_RULES="$AI_CORE_DIR/rules"
mkdir -p "$AI_CORE_RULES" "$AI_CORE_DIR/docs"
# Earlier versions copied the scripts into the checkout; they run from the clone now
rm -rf "$AI_CORE_DIR/bin"

# 1. Managed files, refreshed on every run: the rules, one file per section in setup-ai-core and
#    one assembled file in the checkout, each section headed by a comment naming its source; the
#    skills pointer; VERSION.
CORE_VERSION="$(tr -d '\r\n' < "$CORE_ROOT/VERSION")"
{
  for f in "$CORE_ROOT"/rules/[0-9][0-9]-*.md; do
    printf '<!-- setup-ai-core %s: rules/%s -->\n' "$CORE_VERSION" "$(basename "$f")"
    cat "$f"
    printf '\n'
  done
} > "$AI_CORE_RULES/rules.md"
cp -f "$CORE_ROOT/rules/skills.md" "$AI_CORE_RULES/skills.md"
cp -f "$CORE_ROOT/VERSION" "$AI_CORE_DIR/VERSION"

# 2. The agent files, created once and never overwritten: templates/ mirrors the target layout.
#    A project folder's AGENTS.md is generated instead: the list of its repositories, rewritten
#    on every run because the folder changes. The pointer file of an agent the project does not
#    serve (AGENTS in .ai-core/config.env, or the template's default before the file exists) is
#    not deployed.
CONFIG="$AI_CORE_DIR/config.env"; [ -f "$CONFIG" ] || CONFIG="$CORE_ROOT/templates/.ai-core/config.env"
AGENTS="$(grep -E '^[[:space:]]*AGENTS[[:space:]]*=' "$CONFIG" | tail -n1 | sed 's/^[^=]*=//; s/#.*//' | tr -d '"\r' | tr -d "'" | tr '[:upper:]' '[:lower:]' || true)"
serves() {  # serves <agent>: true when the project serves it, or names no agents at all
  [ -z "$AGENTS" ] || case " $AGENTS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}
(cd "$CORE_ROOT/templates" && find . -type f) | sed 's|^\./||' | while IFS= read -r rel; do
  [ "$PROJECT_FOLDER" -eq 1 ] && [ "$rel" = "AGENTS.md" ] && continue
  case "$rel" in
    .cursorrules) serves cursor || continue ;;
    .windsurfrules) serves windsurf || continue ;;
    .github/copilot-instructions.md) serves copilot || continue ;;
    .openhands/microagents/repo-rules.md) serves openhands || continue ;;
  esac
  if [ ! -e "$TARGET/$rel" ]; then
    mkdir -p "$(dirname "$TARGET/$rel")"
    cp "$CORE_ROOT/templates/$rel" "$TARGET/$rel"
    echo "--> Created $rel"
  else
    echo "--> Kept $rel (already present)"
  fi
done
if [ "$PROJECT_FOLDER" -eq 1 ]; then
  {
    printf '<!-- setup-ai-core %s: written by init for a project folder, rewritten on every run; put your own notes into .ai-core/rules/rules.local.md -->\n' "$CORE_VERSION"
    printf '# %s\n\n' "$(basename "$TARGET")"
    printf 'This folder holds git repositories. Each one carries its own map; read `<repository>/AGENTS.md` before you work in it, and run `ai-core session-start` inside it before the first action.\n\n'
    printf '| repository | map |\n| :--- | :--- |\n'
    for d in "$TARGET"/*/; do
      d="${d%/}"; [ -e "$d/.git" ] || continue
      printf '| `%s` | `%s/AGENTS.md` |\n' "$(basename "$d")" "$(basename "$d")"
    done
    printf '\nThe rules that bind every repository here: `.ai-core/rules/rules.md` (managed by the harness) and `.ai-core/rules/rules.local.md` (this project'"'"'s own, which wins).\n'
  } > "$TARGET/AGENTS.md"
  echo "--> Wrote AGENTS.md (the repositories of this folder)"
fi

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

# 4. The Graft code graph, built with the local Node.js or the whole init fails; no fallback.
echo "--> Graft"
if ! bash "$CORE_ROOT/bin/graft-setup.sh" "$TARGET"; then
  echo "error: the harness files are in place but the Graft code graph is not (see above). Fix the cause and run 'ai-core graft', or set GRAFT_EXECUTION_MODE=\"skip\" in .ai-core/config.env." >&2
  exit 1
fi

echo "=================================================="
echo "✓ Harness $CORE_VERSION in place. Run 'ai-core session-start' here to verify."
echo "=================================================="
