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
. "$CORE_ROOT/lib/layers.sh"

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

# The project harness: <org>/<prefix>-ai-core from the checkout's origin, its extends chain
# base first, cloned or pulled to ~/.<name>-ai-core, created from the skeleton when missing.
# A project folder gets the layers every repository under it shares.
LAYERS=""; REPO_NAME=""
chain_of() {  # chain_of <checkout>: the layer directories, base first, or nothing
  local parts org repo prefix
  parts="$(origin_parts "$1")" || return 0
  org="${parts%%	*}"; repo="${parts#*	}"
  case "$repo" in
    setup-ai-core) return 0 ;;
    *-ai-core) echo "error: $1 is a harness repository; init is for the repositories it serves" >&2; return 2 ;;
  esac
  prefix="$(harness_of "$repo")" || return 0
  layer_chain "$org/$prefix-ai-core" "$CORE_ROOT" create
}
if [ "$PROJECT_FOLDER" -eq 1 ]; then
  FIRST=1
  for d in "$TARGET"/*/; do
    d="${d%/}"; [ -e "$d/.git" ] || continue
    chain="$(chain_of "$d")" || chain=""
    if [ "$FIRST" -eq 1 ]; then LAYERS="$chain"; FIRST=0; continue; fi
    # keep the leading lines the two chains share
    common=""; i=1
    while :; do
      a="$(printf '%s\n' "$LAYERS" | sed -n "${i}p")"; b="$(printf '%s\n' "$chain" | sed -n "${i}p")"
      [ -n "$a" ] && [ "$a" = "$b" ] || break
      common="${common:+$common
}$a"; i=$((i + 1))
    done
    LAYERS="$common"
    [ -n "$LAYERS" ] || break
  done
else
  parts="$(origin_parts "$TARGET" || true)"; REPO_NAME="${parts#*	}"
  LAYERS="$(chain_of "$TARGET")" || { rc=$?; [ "$rc" -eq 2 ] && exit 1; LAYERS=""; }
fi
if [ -n "$LAYERS" ]; then
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    echo "--> Project harness: $(git -C "$l" remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||; s|\.git$||') ($(git -C "$l" rev-parse --short HEAD 2>/dev/null)) at $l"
  done <<< "$LAYERS"
elif [ "$PROJECT_FOLDER" -eq 0 ]; then
  echo "--> No project harness: this checkout has no GitHub origin, or the harness could not be had; the generic harness only"
fi

AI_CORE_DIR="$TARGET/.ai-core"
AI_CORE_RULES="$AI_CORE_DIR/rules"
mkdir -p "$AI_CORE_RULES" "$AI_CORE_DIR/docs"
# Earlier versions copied the scripts into the checkout; they run from the clone now
rm -rf "$AI_CORE_DIR/bin"

# 1. Managed files, refreshed on every run, later layer wins: the rules, one file per section in
#    setup-ai-core and in every layer (the same name replaces, a new name adds), assembled into one
#    file, each section headed by a comment naming its source; skills.md; VERSION; the skills of
#    every layer into both skill directories; the docs of every layer; the data files; every file
#    under repos/<repo>/ of the layers; STAMP with the commit of every layer.
CORE_VERSION="$(tr -d '\r\n' < "$CORE_ROOT/VERSION")"
SECTIONS="$(mktemp -d)"; trap 'rm -rf "$SECTIONS"' EXIT
for f in "$CORE_ROOT"/rules/[0-9][0-9]-*.md; do
  cp "$f" "$SECTIONS/"; printf 'setup-ai-core %s' "$CORE_VERSION" > "$SECTIONS/$(basename "$f").src"
done
SKILLS_MD="$CORE_ROOT/rules/skills.md"
STAMP="setup-ai-core $(git -C "$CORE_ROOT" rev-parse --short HEAD 2>/dev/null || echo "$CORE_VERSION")"
LAYER_FILES=""   # what the layers wrote, so the templates leave it alone
DATA_FILES="config.env labels.tsv assignees.tsv team-modes.tsv"
if [ -n "$LAYERS" ]; then
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    lname="$(basename "$l")"; lname="${lname#.}"
    lcommit="$(git -C "$l" rev-parse --short HEAD 2>/dev/null || echo "-")"
    STAMP="$STAMP"$'\n'"$lname $lcommit"
    for f in "$l"/rules/[0-9][0-9]-*.md; do
      [ -f "$f" ] || continue
      cp -f "$f" "$SECTIONS/"; printf '%s %s' "$lname" "$lcommit" > "$SECTIONS/$(basename "$f").src"
    done
    [ -f "$l/rules/skills.md" ] && SKILLS_MD="$l/rules/skills.md"
    for s in "$l"/skills/*/; do
      [ -f "$s/SKILL.md" ] || continue
      sname="$(basename "$s")"
      for dst in "$TARGET/.claude/skills/$sname" "$TARGET/.agents/skills/$sname"; do
        rm -rf "$dst"; mkdir -p "$dst"; cp -R "$s"/. "$dst/"
      done
      LAYER_FILES="$LAYER_FILES .claude/skills/$sname .agents/skills/$sname"
    done
    for a in "$l"/agents/*.md; do
      [ -f "$a" ] || continue
      mkdir -p "$TARGET/.claude/agents"; cp -f "$a" "$TARGET/.claude/agents/"; LAYER_FILES="$LAYER_FILES .claude/agents/$(basename "$a")"
    done
    if [ -d "$l/docs" ] && [ -n "$(ls -A "$l/docs" 2>/dev/null)" ]; then
      rm -rf "$AI_CORE_DIR/docs/$lname"; mkdir -p "$AI_CORE_DIR/docs/$lname"; cp -R "$l/docs"/. "$AI_CORE_DIR/docs/$lname/"
    fi
    for f in $DATA_FILES; do
      [ -f "$l/$f" ] || continue
      cp -f "$l/$f" "$AI_CORE_DIR/$f"; LAYER_FILES="$LAYER_FILES .ai-core/$f"
    done
  done <<< "$LAYERS"
  # repos/<repo>/ of the innermost layer, in the layout of the checkout; a tracked file is never
  # overwritten
  INNER="$(printf '%s\n' "$LAYERS" | tail -n1)"
  if [ -n "$REPO_NAME" ] && [ -d "$INNER/repos/$REPO_NAME" ]; then
    (cd "$INNER/repos/$REPO_NAME" && find . -type f) | sed 's|^\./||' | while IFS= read -r rel; do
      if git -C "$TARGET" ls-files --error-unmatch "$rel" >/dev/null 2>&1; then
        echo "--> Kept $rel (tracked by the repository; repos/$REPO_NAME/$rel is not applied)"; continue
      fi
      mkdir -p "$(dirname "$TARGET/$rel")"; cp -f "$INNER/repos/$REPO_NAME/$rel" "$TARGET/$rel"
    done
    LAYER_FILES="$LAYER_FILES $( (cd "$INNER/repos/$REPO_NAME" && find . -type f) | sed 's|^\./||' | tr '\n' ' ')"
    echo "--> Applied repos/$REPO_NAME/ of $(basename "$INNER" | sed 's/^\.//')"
  fi
fi
{
  # A section is written with LF and one blank line after it, whatever the clone it came from
  # checked out, so the two twins and two machines assemble the same bytes
  for f in "$SECTIONS"/[0-9][0-9]-*.md; do
    printf '<!-- %s: rules/%s -->\n' "$(cat "$f.src")" "$(basename "$f")"
    printf '%s\n\n' "$(tr -d '\r' < "$f")"
  done
} > "$AI_CORE_RULES/rules.md"
cp -f "$SKILLS_MD" "$AI_CORE_RULES/skills.md"
cp -f "$CORE_ROOT/VERSION" "$AI_CORE_DIR/VERSION"
printf '%s\n' "$STAMP" > "$AI_CORE_DIR/STAMP"

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
  case " $LAYER_FILES " in *" $rel "*) continue ;; esac
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
      echo "/.claude/skills/"
      echo "/.claude/agents/"
      echo "/.agents/"
      (cd "$CORE_ROOT/templates" && find . -type f) | sed 's|^\./|/|'
      echo "# setup-ai-core end"
    } > "$EXCLUDE.tmp" && mv "$EXCLUDE.tmp" "$EXCLUDE"
    echo "--> Registered the harness in $EXCLUDE: nothing to commit"
  )
else
  echo "note: $TARGET is not a git repository; nothing to exclude"
fi

# 3b. The project's .gitignore carries a block naming every file an agent or the harness puts
#     into a checkout (lib/gitignore-block), so no clone of this repository commits one, with or
#     without the harness. The block is rewritten between its markers and the rest of the file is
#     the project's; a path the project already ignores, with or without the slashes, is not
#     written twice, and when it ignores them all no block is written. A changed .gitignore is
#     the one thing init leaves for a commit.
if git -C "$TARGET" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  GI="$TARGET/.gitignore"
  KEPT="$([ -f "$GI" ] && awk '/^# setup-ai-core start/{skip=1} !skip{print} /^# setup-ai-core end/{skip=0}' "$GI" | tr -d '\r' || true)"
  {
    [ -z "$KEPT" ] || printf '%s\n' "$KEPT"
    printf '%s\n' "$KEPT" | awk -v block="$CORE_ROOT/lib/gitignore-block" '
      function norm(s) { sub(/[[:space:]]+$/, "", s); sub(/^\//, "", s); sub(/\/$/, "", s); return s }
      $0 !~ /^#/ && $0 != "" { seen[norm($0)] = 1 }
      END {
        n = 0
        while ((getline line < block) > 0) { sub(/\r$/, "", line); if (line ~ /^#/) { marker[++m] = line; continue }; if (!(norm(line) in seen)) lines[++n] = line }
        if (n > 0) { print marker[1]; for (i = 1; i <= n; i++) print lines[i]; print marker[2] }
      }'
  } > "$GI.tmp"
  if [ -f "$GI" ] && cmp -s "$GI.tmp" "$GI"; then
    rm -f "$GI.tmp"
  else
    mv "$GI.tmp" "$GI"
    echo "--> .gitignore: the agent files of this repository are ignored; commit .gitignore once"
  fi
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
