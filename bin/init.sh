#!/usr/bin/env bash
# Install or refresh the harness in a checkout, in a project folder, or in every repository
# under a folder. The scripts stay in the setup-ai-core clone and run as `ai-core <command>`;
# a checkout receives only data: the assembled rules, the configuration and the agent files.
# Every file it touches is recorded and reported at the end; --dry-run reports without writing.
#
#   init.sh [TARGET_DIR] [--all <folder>] [--no-doctor] [--dry-run]
#
set -euo pipefail

for arg in "$@"; do
  if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
    echo "Usage: init.sh [TARGET_DIR] [--all <folder>] [--no-doctor] [--dry-run]"
    echo ""
    echo "Installs or refreshes the harness in TARGET_DIR (default: the current directory):"
    echo "the assembled rules and the configuration in .ai-core/, the agent files (AGENTS.md,"
    echo ".claude/settings.json, ...) created once, everything registered in .git/info/exclude and"
    echo "in a block of .gitignore, and the Graft code graph. A folder that is no repository but"
    echo "holds repositories is a project folder: it gets an AGENTS.md that lists them. The run ends"
    echo "with what it created, refreshed, kept and removed, and what Graft wrote on the machine."
    echo ""
    echo "Options:"
    echo "  -h, --help       Show this help message"
    echo "  --all <folder>   Init every git repository directly under the folder and every worktree under"
    echo "                   its .worktrees/, then the folder itself"
    echo "  --no-doctor      Do not run doctor first"
    echo "  --dry-run        Report what the run would create, refresh, keep and remove; write nothing"
    echo ""
    echo "Examples:"
    echo "  ai-core init"
    echo "  ai-core init ../my-project --dry-run"
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
DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --no-doctor) RUN_DOCTOR=0 ;;
    --dry-run) DRY=1 ;;
    --all) shift; [ $# -gt 0 ] || { echo "error: --all needs a folder" >&2; exit 1; }; ALL_DIR="$1" ;;
    -*)       echo "error: unknown option '$1' (see --help)" >&2; exit 1 ;;
    *)        TARGET="$1" ;;
  esac
  shift
done

# The prerequisites first; nothing is deployed on a machine that cannot run the harness. A dry
# run installs nothing either.
if [ "$RUN_DOCTOR" -eq 1 ]; then
  DOCTOR_ARGS=(); [ "$DRY" -eq 1 ] && DOCTOR_ARGS+=(--no-install)
  bash "$CORE_ROOT/bin/doctor.sh" ${DOCTOR_ARGS[@]+"${DOCTOR_ARGS[@]}"} || { echo "error: fix the problems doctor reported, then run init again (or pass --no-doctor)." >&2; exit 1; }
fi

# --all: every git repository directly under the folder, every worktree `ai-core start-issue` put
# under its .worktrees/<repository>/, then the folder itself
if [ -n "$ALL_DIR" ]; then
  ALL_DIR="$(cd "$ALL_DIR" && pwd)"
  OK=0; FAILED=""
  PASS=(--no-doctor); [ "$DRY" -eq 1 ] && PASS+=(--dry-run)
  for repo in "$ALL_DIR"/*/ "$ALL_DIR"/.worktrees/*/*/; do
    repo="${repo%/}"
    [ -e "$repo/.git" ] || continue
    name="${repo#"$ALL_DIR"/}"; repo_folder="${name#.worktrees/}"; repo_folder="${repo_folder%%/*}"
    case "$repo_folder" in *-ai-core) continue ;; esac   # a harness clone serves the repositories; it is not one of them, and neither is a worktree of one
    echo ""; echo "### $name"
    if bash "${BASH_SOURCE[0]}" "$repo" "${PASS[@]}"; then OK=$((OK + 1)); else FAILED="$FAILED $name"; fi
  done
  echo ""; echo "### $(basename "$ALL_DIR") (the folder itself)"
  bash "${BASH_SOURCE[0]}" "$ALL_DIR" "${PASS[@]}" || FAILED="$FAILED $(basename "$ALL_DIR")/"
  echo ""; echo "==> init --all: $OK repositories $([ "$DRY" -eq 1 ] && echo "would be" || echo "were") initialized${FAILED:+; failed:$FAILED}"
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
echo "Initializing the harness in: $TARGET$([ "$DRY" -eq 1 ] && echo ' (dry run: nothing is written)')"
[ "$PROJECT_FOLDER" -eq 1 ] && echo "A project folder: the repositories below it get their own init"
echo "=================================================="
echo "--> From $CORE_ROOT"

# 0. A linked worktree starts empty, because the harness is in no commit. Before anything else it
#    gets the checkout's own .ai-core data (its configuration, local rules and documents), and the
#    rest of this run assembles the harness over that, as it does in the checkout.
WORKTREE_DATA_FROM=""
if [ "$PROJECT_FOLDER" -eq 0 ] && [ ! -d "$TARGET/.ai-core" ]; then
  common="$(git -C "$TARGET" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || common=""
  if [ -n "$common" ] && [ "$common" != "$(git -C "$TARGET" rev-parse --path-format=absolute --git-dir 2>/dev/null)" ] && [ -d "$(dirname "$common")/.ai-core" ]; then
    WORKTREE_DATA_FROM="$(dirname "$common")"
    [ "$DRY" -eq 1 ] || cp -R "$WORKTREE_DATA_FROM/.ai-core" "$TARGET/.ai-core"
  fi
fi

# --- what this run does to the checkout is recorded here and reported at the end -------------
CREATED=""; REFRESHED=""; KEPT=""; REMOVED=""; TRACKED=""; UNCHANGED=0
note() {
  case "$1" in
    created) CREATED="$CREATED $2" ;; refreshed) REFRESHED="$REFRESHED $2" ;; kept) KEPT="$KEPT $2" ;;
    removed) REMOVED="$REMOVED $2" ;; tracked) TRACKED="$TRACKED $2" ;; unchanged) UNCHANGED=$((UNCHANGED + 1)) ;;
  esac
}
# put_file <source> <destination> <label> managed|once: one file, written only when it differs.
# A managed file keeps the block Graft appended to the checkout's copy, between its markers.
put_file() {
  local src="$1" dst="$2" label="$3" mode="$4" body
  if [ -e "$dst" ]; then
    if [ "$mode" = managed ] && grep -q '^<!-- graft:start -->' "$dst" && ! grep -q '^<!-- graft:start -->' "$src"; then
      body="$(cat "$src")"
      while [ -n "$body" ] && { [ "${body: -1}" = $'\n' ] || [ "${body: -1}" = $'\r' ]; }; do body="${body%?}"; done
      { printf '%s\n\n' "$body"; sed -n '/^<!-- graft:start -->/,/^<!-- graft:end -->/p' "$dst"; } > "$TMP/graft-kept"
      src="$TMP/graft-kept"
    fi
    if cmp -s "$src" "$dst"; then note unchanged "$label"; return 0; fi
    if [ "$mode" = once ]; then note kept "$label"; return 0; fi
    note refreshed "$label"
  else
    note created "$label"
  fi
  [ "$DRY" -eq 1 ] && return 0
  mkdir -p "$(dirname "$dst")"; cp -f "$src" "$dst"
}
put() { put_file "$1" "$TARGET/$2" "$2" "$3"; }   # put <source> <relative path> managed|once
# put_dir <source dir> <relative dir>: a managed directory, replaced whole
put_dir() {
  local src="$1" rel="$2" dst="$TARGET/$2"
  if [ -d "$dst" ]; then
    if diff -rq "$src" "$dst" >/dev/null 2>&1; then note unchanged "$rel/"; return 0; fi
    note refreshed "$rel/"
  else
    note created "$rel/"
  fi
  [ "$DRY" -eq 1 ] && return 0
  rm -rf "$dst"; mkdir -p "$dst"; cp -R "$src"/. "$dst/"
}
# drop <relative path>: what an earlier version left in the checkout
drop() { [ -e "$TARGET/$1" ] || return 0; note removed "$1"; [ "$DRY" -eq 1 ] || rm -rf "$TARGET/${1:?}"; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# The project harness: <org>/<prefix>-ai-core from the checkout's origin, its extends chain
# base first, cloned or pulled beside the repositories in the project folder, created from the
# skeleton when missing. A project folder gets the layers every repository under it shares; the
# harness clones under it serve the repositories and are none of them.
LAYERS=""; REPO_NAME=""
FOLDER="$TARGET"; [ "$PROJECT_FOLDER" -eq 1 ] || FOLDER="$(project_folder_of "$TARGET")"
chain_of() {  # chain_of <checkout>: the layer directories, base first, or nothing
  local parts org repo prefix
  parts="$(origin_parts "$1")" || return 0
  org="${parts%%	*}"; repo="${parts#*	}"
  case "$repo" in
    setup-ai-core) return 0 ;;
    *-ai-core) echo "error: $1 is a harness repository; init is for the repositories it serves" >&2; return 2 ;;
  esac
  prefix="$(harness_of "$repo")" || return 0
  if [ "$DRY" -eq 1 ]; then
    # nothing is moved, cloned or created on a dry run: a harness that is not there yet is announced instead
    if layer_chain "$org/$prefix-ai-core" "$CORE_ROOT" "$FOLDER" dry 2>"$TMP/chain.err"; then cat "$TMP/chain.err" >&2; return 0; fi
    if grep -q 'does not exist on GitHub' "$TMP/chain.err"; then echo "$org/$prefix-ai-core" > "$TMP/would-create"; else cat "$TMP/chain.err" >&2; fi
    return 0
  fi
  layer_chain "$org/$prefix-ai-core" "$CORE_ROOT" "$FOLDER" create
}
if [ "$PROJECT_FOLDER" -eq 1 ]; then
  FIRST=1
  for d in "$TARGET"/*/; do
    d="${d%/}"; [ -e "$d/.git" ] || continue
    case "$(basename "$d")" in *-ai-core) continue ;; esac
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
  LAYERS="$(chain_of "$TARGET")" || { echo "error: the project harness of $TARGET could not be had (see above); nothing was written" >&2; exit 1; }
fi
if [ -n "$LAYERS" ]; then
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    if [ -d "$l" ]; then
      echo "--> Project harness: $(git -C "$l" remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||; s|\.git$||') ($(git -C "$l" rev-parse --short HEAD 2>/dev/null)) at $l"
    else
      echo "--> Project harness: $(basename "$l") would be cloned to $l (dry run: not cloned)"
    fi
  done <<< "$LAYERS"
elif [ -f "$TMP/would-create" ]; then
  echo "--> Project harness: $(cat "$TMP/would-create") would be created from the skeleton, private, and this checkout would get it (dry run: not created)"
elif [ "$PROJECT_FOLDER" -eq 0 ]; then
  echo "--> No project harness: this checkout has no GitHub origin; the generic harness only"
fi

AI_CORE_DIR="$TARGET/.ai-core"
[ "$DRY" -eq 1 ] || mkdir -p "$AI_CORE_DIR/rules" "$AI_CORE_DIR/docs"
# Earlier versions copied the scripts into the checkout, and one wrote an MCP file Antigravity
# never reads; both are removed
drop .ai-core/bin
drop .agents/mcp_config.json

# 1. Managed files, refreshed on every run, later layer wins: the rules, one file per section in
#    setup-ai-core and in every layer (the same name replaces, a new name adds), assembled into one
#    file, each section headed by a comment naming its source; skills.md; VERSION; the skills of
#    every layer into both skill directories; the agents; the docs of every layer; the data files;
#    every file under repos/<repo>/ of the layers; STAMP with the commit of every layer.
CORE_VERSION="$(tr -d '\r\n' < "$CORE_ROOT/VERSION")"
SECTIONS="$TMP/sections"; mkdir -p "$SECTIONS"
for f in "$CORE_ROOT"/rules/[0-9][0-9]-*.md; do
  cp "$f" "$SECTIONS/"; printf 'setup-ai-core %s' "$CORE_VERSION" > "$SECTIONS/$(basename "$f").src"
done
SKILLS_MD="$CORE_ROOT/rules/skills.md"
STAMP="setup-ai-core $(git -C "$CORE_ROOT" rev-parse --short HEAD 2>/dev/null || echo "$CORE_VERSION")"
LAYER_FILES=""   # what the layers wrote, so the templates leave it alone
MAP_SRC=""       # a generated map, deployed with the binding rules on top once the rules are assembled
DEPLOYED=""      # what the layers put into the checkout, recorded in .ai-core/DEPLOYED
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
      put_dir "$s" ".claude/skills/$sname"; put_dir "$s" ".agents/skills/$sname"
      LAYER_FILES="$LAYER_FILES .claude/skills/$sname .agents/skills/$sname"; DEPLOYED="$DEPLOYED .claude/skills/$sname .agents/skills/$sname"
    done
    for a in "$l"/agents/*.md; do
      [ -f "$a" ] && [ "$(basename "$a")" != README.md ] || continue
      put "$a" ".claude/agents/$(basename "$a")" managed; LAYER_FILES="$LAYER_FILES .claude/agents/$(basename "$a")"; DEPLOYED="$DEPLOYED .claude/agents/$(basename "$a")"
    done
    if [ -d "$l/docs" ] && [ -n "$(ls -A "$l/docs" 2>/dev/null)" ]; then
      put_dir "$l/docs" ".ai-core/docs/$lname"; DEPLOYED="$DEPLOYED .ai-core/docs/$lname"
    fi
    for f in $DATA_FILES; do
      [ -f "$l/$f" ] || continue
      put "$l/$f" ".ai-core/$f" managed; LAYER_FILES="$LAYER_FILES .ai-core/$f"
    done
  done <<< "$LAYERS"
  # repos/<repo>/ of the innermost layer, in the layout of the checkout; a tracked file is never
  # overwritten
  INNER="$(printf '%s\n' "$LAYERS" | tail -n1)"
  if [ -n "$REPO_NAME" ] && [ -d "$INNER/repos/$REPO_NAME" ]; then
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      if git -C "$TARGET" ls-files --error-unmatch "$rel" >/dev/null 2>&1; then
        note tracked "$rel"
      else
        src="$INNER/repos/$REPO_NAME/$rel"
        # A generated map gets the binding rules on top once the rules are assembled (1a below)
        if [ "$rel" = AGENTS.md ] && head -n1 "$src" | grep -q '^<!-- ai-core map:'; then MAP_SRC="$src"; else put "$src" "$rel" managed; fi
        DEPLOYED="$DEPLOYED $rel"
      fi
      LAYER_FILES="$LAYER_FILES $rel"
    done <<< "$( (cd "$INNER/repos/$REPO_NAME" && find . -type f | LC_ALL=C sort) | sed 's|^\./||')"
  fi
fi
# What the layers put into the checkout is recorded in .ai-core/DEPLOYED, so what a layer no
# longer provides is taken out again at the next run; a file the repository tracks is left alone
PREV_DEPLOYED="$(tr -d '\r' < "$TARGET/.ai-core/DEPLOYED" 2>/dev/null || true)"
for p in $PREV_DEPLOYED; do
  case " $DEPLOYED " in *" $p "*) continue ;; esac
  [ -e "$TARGET/$p" ] || continue
  git -C "$TARGET" ls-files --error-unmatch "$p" >/dev/null 2>&1 && continue
  note removed "$p"; [ "$DRY" -eq 1 ] || rm -rf "$TARGET/${p:?}"
done
if [ -n "$DEPLOYED" ] || [ -n "$PREV_DEPLOYED" ]; then
  printf '%s\n' $DEPLOYED > "$TMP/DEPLOYED"; put "$TMP/DEPLOYED" .ai-core/DEPLOYED managed
fi
{
  # A section is written with LF and one blank line after it, whatever the clone it came from
  # checked out, so the two twins and two machines assemble the same bytes
  for f in "$SECTIONS"/[0-9][0-9]-*.md; do
    printf '<!-- %s: rules/%s -->\n' "$(cat "$f.src")" "$(basename "$f")"
    printf '%s\n\n' "$(tr -d '\r' < "$f")"
  done
} > "$TMP/rules.md"
put "$TMP/rules.md" .ai-core/rules/rules.md managed
put "$SKILLS_MD" .ai-core/rules/skills.md managed
put "$CORE_ROOT/VERSION" .ai-core/VERSION managed
printf '%s\n' "$STAMP" > "$TMP/STAMP"; put "$TMP/STAMP" .ai-core/STAMP managed

# 1a. The binding rules, on top of a generated map and in a project folder's AGENTS.md. Claude Code
#     loads a file an AGENTS.md names after @ at launch, whole, so the rules reach the agent from
#     its first prompt. It also loads the AGENTS.md of every directory above the one it starts in,
#     and a repository's when it works there, so a checkout inside a project folder whose rules
#     are the folder's names them without the @: imported twice, they would be loaded twice.
enclosing_folder() {  # enclosing_folder <dir>: the nearest directory above it that init equipped as a project folder
  local d="$1" up
  while up="$(dirname "$d")" && [ "$up" != "$d" ]; do
    d="$up"
    if [ -f "$d/.ai-core/rules/rules.md" ] && [ ! -e "$d/.git" ]; then echo "$d"; return 0; fi
  done
  return 1
}
same_text() {  # same_text <file> <file>: the same lines, the comment lines aside
  [ -f "$1" ] && [ -f "$2" ] && cmp -s <(tr -d '\r' < "$1" | grep -v '^<!-- ' || true) <(tr -d '\r' < "$2" | grep -v '^<!-- ' || true)
}
IMPORT_RULES=1; IMPORT_SKILLS=1; IMPORT_LOCAL=0
if [ "$PROJECT_FOLDER" -eq 0 ] && FOLDER="$(enclosing_folder "$TARGET")"; then
  same_text "$FOLDER/.ai-core/rules/rules.md" "$TMP/rules.md" && IMPORT_RULES=0
  same_text "$FOLDER/.ai-core/rules/skills.md" "$SKILLS_MD" && IMPORT_SKILLS=0
fi
[ -f "$AI_CORE_DIR/rules/rules.local.md" ] && ! same_text "$AI_CORE_DIR/rules/rules.local.md" "$CORE_ROOT/templates/.ai-core/rules/rules.local.md" && IMPORT_LOCAL=1
binding_block() {  # binding_block: lib/binding-rules.md, each file named after @ where this AGENTS.md is what loads it
  local r s l the="the same as the project folder's, which its AGENTS.md loads"
  if [ "$IMPORT_RULES" -eq 1 ]; then r='@.ai-core/rules/rules.md'; else r="\`.ai-core/rules/rules.md\`, $the"; fi
  if [ "$IMPORT_SKILLS" -eq 1 ]; then s='@.ai-core/rules/skills.md'; else s="\`.ai-core/rules/skills.md\`, $the"; fi
  if [ "$IMPORT_LOCAL" -eq 1 ]; then l='@.ai-core/rules/rules.local.md'; else l='`.ai-core/rules/rules.local.md`, still the template'; fi
  tr -d '\r' < "$CORE_ROOT/lib/binding-rules.md" | sed -e "s#{RULES}#$r#" -e "s#{SKILLS}#$s#" -e "s#{LOCAL}#$l#"
}
if [ -n "$MAP_SRC" ]; then
  { head -n2 "$MAP_SRC" | tr -d '\r'; echo ""; binding_block; echo '- `ai-core session-start` before any work; below is the map of this repository.'; echo ""; tail -n +3 "$MAP_SRC" | tr -d '\r' | awk 'NF{f=1} f'; } > "$TMP/AGENTS.map.md"
  put "$TMP/AGENTS.map.md" AGENTS.md managed
fi

# 2. The agent files, created once and never overwritten: templates/ mirrors the target layout.
#    A project folder's AGENTS.md is generated instead: the list of its repositories, rewritten
#    on every run because the folder changes. The file of an agent the project does not serve
#    (AGENTS in .ai-core/config.env, or the template's default before the file exists) is not
#    deployed.
CONFIG="$AI_CORE_DIR/config.env"; [ -f "$CONFIG" ] || CONFIG="$CORE_ROOT/templates/.ai-core/config.env"
AGENTS="$(grep -E '^[[:space:]]*AGENTS[[:space:]]*=' "$CONFIG" | tail -n1 | sed 's/^[^=]*=//; s/#.*//' | tr -d '"\r' | tr -d "'" | tr '[:upper:]' '[:lower:]' || true)"
serves() {  # serves <agent>: true when the project serves it, or names no agents at all
  [ -z "$AGENTS" ] || case " $AGENTS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  [ "$PROJECT_FOLDER" -eq 1 ] && [ "$rel" = "AGENTS.md" ] && continue
  case " $LAYER_FILES " in *" $rel "*) continue ;; esac
  case "$rel" in
    .cursorrules) serves cursor || continue ;;
    .windsurfrules) serves windsurf || continue ;;
    .github/copilot-instructions.md) serves copilot || continue ;;
    .openhands/microagents/repo-rules.md) serves openhands || continue ;;
    .codex/config.toml) serves codex || continue ;;
  esac
  put "$CORE_ROOT/templates/$rel" "$rel" once
done <<< "$( (cd "$CORE_ROOT/templates" && find . -type f | LC_ALL=C sort) | sed 's|^\./||')"
# The Claude Code hook that starts the session and the two permissions of the template (the ai-core
# commands, and every tool of the Graft MCP server, which only reads the code graph); a
# settings.json the checkout had before (created once, never overwritten) gets what it lacks of
# them merged in, the way Graft merges its hooks
HOOK='ai-core session-start --tool claude'
SETTINGS="$TARGET/.claude/settings.json"
SETTINGS_HAS='["Bash(ai-core:*)", "mcp__graft"] as $req | ([.hooks.SessionStart[]?.hooks[]?.command // empty] | index($c) != null) and (($req - (.permissions.allow // [])) | length == 0)'
SETTINGS_ADD='["Bash(ai-core:*)", "mcp__graft"] as $req | .hooks.SessionStart = (if ([.hooks.SessionStart[]?.hooks[]?.command // empty] | index($c)) != null then .hooks.SessionStart else ((.hooks.SessionStart // []) + [{hooks: [{type: "command", command: $c, timeout: 60}]}]) end) | .permissions.allow = ((.permissions.allow // []) + ($req - (.permissions.allow // [])))'
if [ -f "$SETTINGS" ] && command -v jq >/dev/null 2>&1 && ! jq -e --arg c "$HOOK" "$SETTINGS_HAS" "$SETTINGS" >/dev/null 2>&1; then
  jq --arg c "$HOOK" "$SETTINGS_ADD" "$SETTINGS" > "$TMP/settings.json" 2>/dev/null \
    && put_file "$TMP/settings.json" "$SETTINGS" ".claude/settings.json" managed
fi
# 2a. A repository with a CLAUDE.md of its own: Claude Code then reads that file and not AGENTS.md.
#     A CLAUDE.local.md beside it, which Claude Code loads the same way and git never sees, imports
#     AGENTS.md, so the map and the binding rules load there too. Created once and never taken out;
#     a CLAUDE.local.md that is somebody's own is left alone, and the run says what to add to it.
if [ "$PROJECT_FOLDER" -eq 0 ] && { [ -f "$TARGET/CLAUDE.md" ] || [ -f "$TARGET/.claude/CLAUDE.md" ]; }; then
  printf '%s\n%s\n' '<!-- written by ai-core init: this repository has its own CLAUDE.md, so Claude Code reads it instead of AGENTS.md; this import loads AGENTS.md as well, the map and the binding rules -->' '@AGENTS.md' > "$TMP/CLAUDE.local.md"
  put "$TMP/CLAUDE.local.md" CLAUDE.local.md once
  if [ -f "$TARGET/CLAUDE.local.md" ] && ! tr -d '\r' < "$TARGET/CLAUDE.local.md" | grep -qx '@AGENTS.md'; then
    echo "note: CLAUDE.local.md is yours and does not import AGENTS.md; add the line @AGENTS.md so Claude Code loads the map and the binding rules here"
  fi
fi
if [ "$PROJECT_FOLDER" -eq 1 ]; then
  {
    printf '<!-- setup-ai-core %s: written by init for a project folder, rewritten on every run; put your own notes into .ai-core/rules/rules.local.md -->\n' "$CORE_VERSION"
    printf '# %s\n\n' "$(basename "$TARGET")"
    printf 'This folder holds git repositories, each with its own map.\n\n'
    binding_block
    printf '%s\n\n' '- `ai-core session-start` before any work, here and in a repository before you work in it. A repository'"'"'s map is its `AGENTS.md`; Claude Code loads it when you work there, any other tool reads it first.'
    printf '| repository | map |\n| :--- | :--- |\n'
    for d in "$TARGET"/*/; do
      d="${d%/}"; [ -e "$d/.git" ] || continue
      case "$(basename "$d")" in *-ai-core) continue ;; esac
      printf '| `%s` | `%s/AGENTS.md` |\n' "$(basename "$d")" "$(basename "$d")"
    done
  } > "$TMP/AGENTS.md"
  put "$TMP/AGENTS.md" AGENTS.md managed
fi

# 3. Keep the harness out of the repository's history: every deployed path goes into the
#    clone's own exclude file, which no commit ever contains. Worktrees share it.
if EXCLUDE="$(cd "$TARGET" && git rev-parse --git-path info/exclude 2>/dev/null)"; then
  case "$EXCLUDE" in /*|[A-Za-z]:*) ;; *) EXCLUDE="$TARGET/$EXCLUDE" ;; esac
  {
    echo "# setup-ai-core start: the harness lives in the working tree only, never in a commit"
    echo "/.ai-core/"
    echo "/.claude/skills/"
    echo "/.claude/agents/"
    echo "/.agents/"
    echo "/CLAUDE.local.md"
    (cd "$CORE_ROOT/templates" && find . -type f | LC_ALL=C sort) | sed 's|^\./|/|'
    echo "# setup-ai-core end"
  } > "$TMP/block"
  # The block replaces the one an earlier run wrote, in its place, or is appended
  if [ -f "$EXCLUDE" ]; then
    awk -v block="$TMP/block" '
      function put() { while ((getline line < block) > 0) print line; close(block); written = 1 }
      /^# setup-ai-core start/ { put(); skip = 1 }
      !skip { print }
      /^# setup-ai-core end/ { skip = 0 }
      END { if (!written) put() }' "$EXCLUDE" > "$TMP/exclude"
  else
    cp "$TMP/block" "$TMP/exclude"
  fi
  put_file "$TMP/exclude" "$EXCLUDE" ".git/info/exclude" managed
else
  echo "note: $TARGET is not a git repository; nothing to exclude"
fi

# 3a. A repository that carries .githooks/pre-push (the shim that starts the push gate, ai-core
#     pre-push) is armed in this clone: core.hooksPath is the clone's own setting, never
#     committed, so a fresh clone gets it from its first init.
HOOKS_ARMED=0
if [ -f "$TARGET/.githooks/pre-push" ] && [ "$(git -C "$TARGET" config --get core.hooksPath 2>/dev/null)" != ".githooks" ]; then
  HOOKS_ARMED=1
  [ "$DRY" -eq 1 ] || git -C "$TARGET" config core.hooksPath .githooks
fi

# 3b. The project's .gitignore carries a block naming every file an agent or the harness puts
#     into a checkout (lib/gitignore-block), so no clone of this repository commits one, with or
#     without the harness. The block is rewritten between its markers and the rest of the file is
#     the project's; a path the project already ignores, with or without the slashes, is not
#     written twice, and when it ignores them all no block is written. A changed .gitignore is
#     the one thing init leaves for a commit.
# commit_gitignore <checkout>: the block committed on its own and pushed by ref to the branch
# checked out; a worktree is somebody's issue and keeps the change for its own commit. Prints the
# note for the report; the push's own output, the gate's among it, goes to the terminal.
commit_gitignore() {
  local dir="$1" branch
  if [ "$(git -C "$dir" rev-parse --git-dir)" != "$(git -C "$dir" rev-parse --git-common-dir)" ]; then echo "it goes out with this worktree's own commit"; return 0; fi
  git -C "$dir" add -- .gitignore
  git -C "$dir" commit -q -m 'the agent files of this repository are ignored' -m 'No-issue: the .gitignore block written by ai-core init' -- .gitignore >&2 || { echo "the commit failed (see above)"; return 0; }
  git -C "$dir" remote get-url origin >/dev/null 2>&1 || { echo "committed; no origin, not pushed"; return 0; }
  branch="$(git -C "$dir" symbolic-ref --short -q HEAD)" || { echo "committed; not on a branch, not pushed"; return 0; }
  if git -C "$dir" push --quiet origin "HEAD:$branch" >&2; then echo "committed and pushed to origin/$branch"; else echo "committed; the push was refused or failed (see above), the commit stays"; fi
}
GITIGNORE_CHANGED=0; GITIGNORE_NOTE=""
if git -C "$TARGET" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  GI="$TARGET/.gitignore"
  KEPT_LINES="$([ -f "$GI" ] && awk '/^# setup-ai-core start/{skip=1} !skip{print} /^# setup-ai-core end/{skip=0}' "$GI" | tr -d '\r' || true)"
  {
    [ -z "$KEPT_LINES" ] || printf '%s\n' "$KEPT_LINES"
    printf '%s\n' "$KEPT_LINES" | awk -v block="$CORE_ROOT/lib/gitignore-block" '
      function norm(s) { sub(/[[:space:]]+$/, "", s); sub(/^\//, "", s); sub(/\/$/, "", s); return s }
      $0 !~ /^#/ && $0 != "" { seen[norm($0)] = 1 }
      END {
        n = 0
        while ((getline line < block) > 0) { sub(/\r$/, "", line); if (line ~ /^#/) { marker[++m] = line; continue }; if (!(norm(line) in seen)) lines[++n] = line }
        if (n > 0) { print marker[1]; for (i = 1; i <= n; i++) print lines[i]; print marker[2] }
      }'
  } > "$TMP/gitignore"
  if ! { [ -f "$GI" ] && cmp -s "$TMP/gitignore" <(tr -d '\r' < "$GI"); }; then
    GITIGNORE_CHANGED=1
    if [ "$DRY" -eq 0 ]; then cp -f "$TMP/gitignore" "$GI"; GITIGNORE_NOTE="$(commit_gitignore "$TARGET")"; fi
  fi
fi

# 4. The Graft code graph, built with the local Node.js or the whole init fails; no fallback.
GRAFT_ARGS=(); [ "$DRY" -eq 1 ] && GRAFT_ARGS+=(--dry-run)
if ! bash "$CORE_ROOT/bin/graft-setup.sh" "$TARGET" ${GRAFT_ARGS[@]+"${GRAFT_ARGS[@]}"}; then
  echo "error: the harness files are in place but the Graft code graph is not (see above). Fix the cause and run 'ai-core graft', or set GRAFT_EXECUTION_MODE=\"skip\" in .ai-core/config.env." >&2
  exit 1
fi

# 5. The report: what this run did to the checkout, or would do
list() { printf '%s' "$1" | sed 's/^ //; s/ /, /g'; }
echo "=================================================="
if [ "$DRY" -eq 1 ]; then echo "init would change in $(basename "$TARGET"):"; else echo "init changed in $(basename "$TARGET"):"; fi
[ -z "$CREATED" ]   || echo "  created    $(list "$CREATED")"
[ -z "$REFRESHED" ] || echo "  refreshed  $(list "$REFRESHED")"
[ -z "$KEPT" ]      || echo "  kept       $(list "$KEPT") (yours: differs from the template, never overwritten)"
[ -z "$REMOVED" ]   || echo "  removed    $(list "$REMOVED")"
[ -z "$TRACKED" ]   || echo "  tracked    $(list "$TRACKED") (the repository commits these; repos/$REPO_NAME/ is not applied to them)"
echo "  unchanged  $UNCHANGED file(s)"
if [ "$GITIGNORE_CHANGED" -eq 1 ]; then
  if [ "$DRY" -eq 1 ]; then echo "  .gitignore would change and be committed: the agent files of this repository are ignored"
  else echo "  .gitignore changed: the agent files of this repository are ignored; $GITIGNORE_NOTE"; fi
fi
if [ -n "$WORKTREE_DATA_FROM" ]; then echo "  .ai-core $([ "$DRY" -eq 1 ] && echo "would be taken" || echo "taken") from the checkout $WORKTREE_DATA_FROM: a worktree starts with the checkout's configuration, local rules and documents"; fi
if [ "$HOOKS_ARMED" -eq 1 ]; then echo "  core.hooksPath $([ "$DRY" -eq 1 ] && echo "would be set" || echo "set") to .githooks: the push gate runs here"; fi
if [ "$DRY" -eq 1 ]; then echo "  nothing was written (dry run)"; else echo "✓ Harness $CORE_VERSION in place. Run 'ai-core session-start' here to verify."; fi
echo "=================================================="
