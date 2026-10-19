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
    echo ".claude/settings.json, ...) created once, and everything registered in .git/info/exclude"
    echo "and in a block of .gitignore. A folder that is no repository but holds repositories is a"
    echo "project folder: it gets an AGENTS.md that lists them. The run ends with what it created,"
    echo "refreshed, kept and removed."
    echo ""
    echo "Options:"
    echo "  -h, --help       Show this help message"
    echo "  --all <folder>   Init the folder itself, then every git repository directly under it and every"
    echo "                   worktree under its .worktrees/"
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

# Source worktrees must be refused before inherited product data or settings can be copied.
if [ -z "$ALL_DIR" ] && [ -d "$TARGET" ] && harness_source_of "$TARGET" >/dev/null 2>&1; then
  echo "error: $TARGET is a harness repository; init is for the repositories it serves" >&2
  exit 1
fi

# The prerequisites first; nothing is deployed on a machine that cannot run the harness. A dry
# run installs nothing either. Doctor runs in the folder init serves, so it sees what the
# repositories of that project folder need (gitleaks, where one carries .gitleaks.toml).
if [ "$RUN_DOCTOR" -eq 1 ]; then
  DOCTOR_ARGS=(); [ "$DRY" -eq 1 ] && DOCTOR_ARGS+=(--no-install)
  ( cd "${ALL_DIR:-$TARGET}" 2>/dev/null || true; bash "$CORE_ROOT/bin/doctor.sh" ${DOCTOR_ARGS[@]+"${DOCTOR_ARGS[@]}"} ) || { echo "error: fix the problems doctor reported, then run init again (or pass --no-doctor)." >&2; exit 1; }
fi

# --all: the folder itself first, as a repository compares its rules with the folder's (1a), then
# every git repository directly under it and every worktree `ai-core start-issue` put under its
# .worktrees/<repository>/
if [ -n "$ALL_DIR" ]; then
  ALL_DIR="$(cd "$ALL_DIR" && pwd)"
  OK=0; FAILED=""; FOLDER_OK=1
  PASS=(--no-doctor); [ "$DRY" -eq 1 ] && PASS+=(--dry-run)
  echo ""; echo "### $(basename "$ALL_DIR") (the folder itself)"
  bash "${BASH_SOURCE[0]}" "$ALL_DIR" "${PASS[@]}" || FOLDER_OK=0
  # Worktrees whose work landed a day ago or more go first (finish-issue --sweep): a rollout frees
  # what nobody finished, and does not init a worktree that is about to go
  for repo in "$ALL_DIR"/*/; do
    repo="${repo%/}"
    [ -e "$repo/.git" ] || continue
    case "${repo##*/}" in *-ai-core) continue ;; esac
    [ "$(git -C "$repo" worktree list --porcelain 2>/dev/null | grep '^worktree ' | grep -v -c -E "/\.ai-core/neighbours/|/\.worktrees/[^/]*/origin-|$LANDING_WORKTREE_RE")" -gt 1 ] || continue
    echo ""; echo "### ${repo##*/}: worktrees whose work landed"
    (cd "$repo" && bash "$CORE_ROOT/bin/finish-issue.sh" --sweep $([ "$DRY" -eq 1 ] && echo --dry-run)) 2>&1 | sed 's/^/  /' || true
  done
  for repo in "$ALL_DIR"/*/ "$ALL_DIR"/.worktrees/*/*/; do
    repo="${repo%/}"
    [ -e "$repo/.git" ] || continue
    case "$repo" in "$ALL_DIR"/.worktrees/*) [ ! -L "$repo" ] || continue ;; esac   # a link beside the worktrees is a neighbour checkout, initialized as itself
    case "$repo" in "$ALL_DIR"/.worktrees/*/origin-*) continue ;; esac                # a neighbour's published copy is read by checks, never worked in: the harness has no reader there
    [[ "$repo" =~ $LANDING_WORKTREE_RE ]] && continue   # the temporary worktree of a landing (integrate-issue --from-origin) is gone when the landing ends, and nobody works in it
    name="${repo#"$ALL_DIR"/}"; repo_folder="${name##*/}"
    # a worktree is named by the checkout it belongs to, whichever way .worktrees/ is laid out
    # (a broken worktree has no checkout to name: it is walked as before)
    case "$name" in .worktrees/*) repo_folder="$(cd "$repo" && cd "$(git rev-parse --git-common-dir 2>/dev/null)" && cd .. && basename "$PWD")" || repo_folder="" ;; esac
    case "$repo_folder" in *-ai-core) continue ;; esac   # a harness clone serves the repositories; it is not one of them, and neither is a worktree of one
    echo ""; echo "### $name"
    if bash "${BASH_SOURCE[0]}" "$repo" "${PASS[@]}"; then OK=$((OK + 1)); else FAILED="$FAILED $name"; fi
  done
  [ "$FOLDER_OK" -eq 1 ] || FAILED="$FAILED $(basename "$ALL_DIR")/"
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

# 0b. A check of the repository may read a neighbour checkout of the project folder through `..`,
#     and in a worktree `..` is .worktrees/<repository>/, where no neighbour stands: the check then
#     finds nothing and proves less than in the checkout. So every other checkout of the folder
#     gets a link there, and `..` finds the same neighbours from the worktree. The link leads to
#     what the neighbour published, its origin's default branch, kept as a detached worktree
#     .ai-core/neighbours/<neighbour>/origin-<branch>: the neighbour's checkout is somebody's working copy,
#     on another branch or with a change nobody published, and a check that read it would judge
#     that instead. A neighbour without an origin is linked as its checkout; one whose origin
#     names no default branch is too, and is named. An entry that stands there already is left as
#     it is, except a link this step made, which follows the published branch, also when the origin
#     renames it. A link of this shape whose checkout is gone since leads nowhere and goes; a link
#     of anybody else stays. The copy stands outside .worktrees/, because a project's own tool may
#     read that folder as the places of work and would count the copy as one more.
NEIGHBOURS_LINKED=""; NEIGHBOURS_IN=""; NEIGHBOURS_UNLINKED=""; NEIGHBOURS_HELD=""; NEIGHBOURS_UNPUBLISHED=""; NEIGHBOURS_BLOCKED=""; NEIGHBOURS_LEFT=""; NEIGHBOURS_MOVED=""; NEIGHBOURS_UNMOVED=""
# neighbour_published <checkout> <name>: sets NEIGHBOUR_TARGET, the link's target from the container,
# or empties it where the copy stands but cannot be used
neighbour_published() {
  local ref branch copy
  NEIGHBOUR_TARGET="../../$2"
  git -C "$1" remote get-url origin >/dev/null 2>&1 || return 0
  # refs/remotes/origin/HEAD, which the fetch below asked the origin for
  ref="$(git -C "$1" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)" || ref=""
  # a dry run fetched nothing, so a missing origin/HEAD says nothing about the origin there
  [ -n "$ref" ] || { [ "$DRY" -eq 1 ] || NEIGHBOURS_UNPUBLISHED="$NEIGHBOURS_UNPUBLISHED $2"; return 0; }
  branch="${ref#origin/}"; copy="$folder/.ai-core/neighbours/$2/origin-$branch"
  if [ -e "$copy" ] && [ ! -e "$copy/.git" ]; then
    # Not a worktree (pruned, or somebody's folder): it is never moved, so a link to it would age
    NEIGHBOURS_BLOCKED="$NEIGHBOURS_BLOCKED $2"; NEIGHBOUR_TARGET=""; return 0
  fi
  if [ "$DRY" -eq 0 ]; then
    if [ -e "$copy/.git" ]; then
      # Moved only while nothing in it is somebody's: no change in the tree and no commit the
      # origin lacks, which a checkout of the origin's branch would leave behind unnamed
      if [ -z "$(git -C "$copy" status --porcelain 2>/dev/null)" ] && git -C "$copy" merge-base --is-ancestor HEAD "$ref" 2>/dev/null; then
        git -C "$copy" checkout -q --detach "$ref" 2>/dev/null || true
      else NEIGHBOURS_HELD="$NEIGHBOURS_HELD $2"; fi
    else
      # A second init at the same moment may have added it: then it is used as it stands. Git
      # also refuses where it still registers a copy whose folder was removed by hand; that
      # registration may hold the only name of a commit, so it is named, never pruned here.
      if ! git -C "$1" worktree add -q --detach "$copy" "$ref" >/dev/null 2>&1 && [ ! -e "$copy/.git" ]; then
        NEIGHBOURS_BLOCKED="$NEIGHBOURS_BLOCKED $2"; NEIGHBOUR_TARGET=""; return 0
      fi
    fi
  fi
  NEIGHBOUR_TARGET="../../.ai-core/neighbours/$2/origin-$branch"
}
if [ "$PROJECT_FOLDER" -eq 0 ]; then
  common="$(git -C "$TARGET" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || common=""
  if [ -n "$common" ] && [ "$common" != "$(git -C "$TARGET" rev-parse --path-format=absolute --git-dir 2>/dev/null)" ]; then
    main="$(dirname "$common")"; folder="$(dirname "$main")"
    container="$(dirname "$(git -C "$TARGET" rev-parse --show-toplevel)")"
    if [ "$container" = "$folder/.worktrees/${main##*/}" ]; then
      NEIGHBOURS_IN=".worktrees/${main##*/}/"
      # The published branches are fetched first, all at once: one at a time costs a round trip
      # each. The origin also names its default branch, which a clone records but a pushed
      # `git init` never does. No prompt: a neighbour whose origin wants a login the shell does not
      # hold would stop init for a repository the issue never touched.
      if [ "$DRY" -eq 0 ]; then
        for neighbour in "$folder"/*/; do
          neighbour="${neighbour%/}"
          [ -d "$neighbour/.git" ] && [ "$neighbour" != "$main" ] || continue
          git -C "$neighbour" remote get-url origin >/dev/null 2>&1 || continue
          { GIT_TERMINAL_PROMPT=0 git -C "$neighbour" fetch -q origin \
              && GIT_TERMINAL_PROMPT=0 git -C "$neighbour" remote set-head origin --auto; } >/dev/null 2>&1 < /dev/null &
        done
        wait
      fi
      # A copy that still stands in .worktrees/ moves out with all it holds, and every link of the
      # folder's worktrees that leads to it follows it. Only what git registers as a worktree of
      # that neighbour is moved: a folder of the same name that is somebody else's stays.
      for neighbour in "$folder"/*/; do
        neighbour="${neighbour%/}"; name="${neighbour##*/}"
        [ -d "$neighbour/.git" ] || continue
        while IFS= read -r old; do
          [ -f "$old/.git" ] || continue
          rel="${old#"$folder/.worktrees/$name/"}"; new="$folder/.ai-core/neighbours/$name/$rel"
          [ "$DRY" -eq 0 ] || { NEIGHBOURS_MOVED="$NEIGHBOURS_MOVED $name"; continue; }
          if [ -e "$new" ] || ! mkdir -p "$(dirname "$new")" || ! git -C "$neighbour" worktree move "$old" "$new" >/dev/null 2>&1; then
            NEIGHBOURS_UNMOVED="$NEIGHBOURS_UNMOVED ${old#"$folder"/}"; continue
          fi
          d="$(dirname "$old")"; while [ "$d" != "$folder/.worktrees" ] && rmdir "$d" 2>/dev/null; do d="$(dirname "$d")"; done
          for link in "$folder"/.worktrees/*/"$name"; do
            [ -L "$link" ] && [ "$(readlink "$link")" = "../$name/$rel" ] || continue
            rm -f "$link"; ln -s "../../.ai-core/neighbours/$name/$rel" "$link"
          done
          NEIGHBOURS_MOVED="$NEIGHBOURS_MOVED $name"
        done < <(git -C "$neighbour" worktree list --porcelain 2>/dev/null | awk -v p="worktree $folder/.worktrees/$name/origin-" 'index($0, p) == 1 { print substr($0, 10) }')
      done
      for neighbour in "$folder"/*/; do
        neighbour="${neighbour%/}"; name="${neighbour##*/}"
        [ -d "$neighbour/.git" ] && [ "$neighbour" != "$main" ] || continue
        if [ -L "$container/$name" ]; then
          case "$(readlink "$container/$name")" in
            "../../$name"|"../../.ai-core/neighbours/$name/origin-"*|"../$name/origin-"*)
              # A link this step made follows what the neighbour publishes now: the copy moves
              # with the origin, and the link with a renamed default branch
              neighbour_published "$neighbour" "$name"
              [ -n "$NEIGHBOUR_TARGET" ] && [ "$NEIGHBOUR_TARGET" != "$(readlink "$container/$name")" ] || continue
              case "$(readlink "$container/$name")" in "../../.ai-core/neighbours/$name/origin-"*) NEIGHBOURS_LEFT="$NEIGHBOURS_LEFT $(readlink "$container/$name" | sed "s|^\.\./\.\./||")" ;; esac
              [ "$DRY" -ne 0 ] || { rm -f "$container/$name"; ln -s "$NEIGHBOUR_TARGET" "$container/$name"; }
              NEIGHBOURS_LINKED="$NEIGHBOURS_LINKED $name"; continue ;;
          esac
        fi
        [ ! -e "$container/$name" ] && [ ! -L "$container/$name" ] || continue
        neighbour_published "$neighbour" "$name"
        [ -n "$NEIGHBOUR_TARGET" ] || continue
        [ "$DRY" -ne 0 ] || ln -s "$NEIGHBOUR_TARGET" "$container/$name"
        NEIGHBOURS_LINKED="$NEIGHBOURS_LINKED $name"
      done
      for link in "$container"/*; do
        name="${link##*/}"
        [ -L "$link" ] && [ ! -e "$link" ] || continue
        to="$(readlink "$link")" || continue; to="${to%/}"
        case "$to" in "../../.ai-core/neighbours/$name/origin-"*|"../$name/origin-"*) [ ! -d "$folder/$name/.git" ] || continue ;;   # a published copy whose checkout went
          *) [ "${to##*/}" = "$name" ] && (cd "$container" && [ "$(dirname "$to")" -ef "$folder" ]) || continue ;; esac
        [ "$DRY" -eq 1 ] || rm -f "$link"
        NEIGHBOURS_UNLINKED="$NEIGHBOURS_UNLINKED $name"
      done
    fi
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
# put_file <source> <destination> <label> managed|once: one file, written only when it differs
put_file() {
  local src="$1" dst="$2" label="$3" mode="$4"
  if [ -e "$dst" ]; then
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
    if grep -q "does not exist on $(forge_name)" "$TMP/chain.err"; then echo "$org/$prefix-ai-core" > "$TMP/would-create"; else cat "$TMP/chain.err" >&2; fi
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
      echo "--> Project harness: $(git -C "$l" remote get-url origin 2>/dev/null | sed "s|.*$(forge_host)[:/]||; s|\.git\$||") ($(git -C "$l" rev-parse --short HEAD 2>/dev/null)) at $l"
    else
      echo "--> Project harness: $(basename "$l") would be cloned to $l (dry run: not cloned)"
    fi
  done <<< "$LAYERS"
elif [ -f "$TMP/would-create" ]; then
  echo "--> Project harness: $(cat "$TMP/would-create") would be created from the skeleton, private, and this checkout would get it (dry run: not created)"
elif [ "$PROJECT_FOLDER" -eq 0 ]; then
  echo "--> No project harness: this checkout has no $(forge_name) origin; the generic harness only"
fi

# The auto-mode entries of setup-ai-core and of every layer, read before anything is written, so a
# line init cannot read stops it here; step 2b writes them. Each is tagged with its layer's name.
AUTO_MODE_LAYERS="setup-ai-core"
: > "$TMP/auto-mode.tsv"
read_auto_mode() {  # read_auto_mode <file> <layer>
  local line no=0
  [ -f "$1" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    no=$((no + 1)); line="${line%$'\r'}"
    if [ "$no" -eq 1 ]; then line="${line#$'\xef\xbb\xbf'}"; fi   # a byte-order mark
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in
      allow$'\t'?*|environment$'\t'?*) case "${line#*$'\t'}" in *$'\t'*) ;; *) printf '%s\t[%s] %s\n' "${line%%$'\t'*}" "$2" "${line#*$'\t'}" >> "$TMP/auto-mode.tsv"; continue ;; esac ;;
    esac
    echo "error: $1:$no is no auto-mode entry: the list (allow or environment), one tab, then the entry; nothing was written" >&2
    return 1
  done < "$1"
}
read_auto_mode "$CORE_ROOT/auto-mode.tsv" setup-ai-core || exit 1
if [ -n "$LAYERS" ]; then
  while IFS= read -r l; do
    # a layer a dry run has not cloned is no layer of this run: its entries in the settings stay
    [ -d "$l" ] || continue
    lname="$(basename "$l")"; lname="${lname#.}"
    AUTO_MODE_LAYERS="$AUTO_MODE_LAYERS"$'\n'"$lname"
    read_auto_mode "$l/auto-mode.tsv" "$lname" || exit 1
  done <<< "$LAYERS"
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
AGENTS_SRC=""    # the AGENTS.md this run deploys, read for the Codex override (2c)
DEPLOYED=""      # what the layers put into the checkout, recorded in .ai-core/DEPLOYED
DATA_FILES="config.env labels.tsv assignees.tsv team-modes.tsv models.tsv"
# The skills of setup-ai-core itself, before the layers': a layer's skill of the same name replaces
# the directory whole, so the more specific layer wins, as it does for the rules.
for s in "$CORE_ROOT"/skills/*/; do
  [ -f "$s/SKILL.md" ] || continue
  sname="$(basename "$s")"
  put_dir "$s" ".claude/skills/$sname"; put_dir "$s" ".agents/skills/$sname"
  LAYER_FILES="$LAYER_FILES .claude/skills/$sname .agents/skills/$sname"; DEPLOYED="$DEPLOYED .claude/skills/$sname .agents/skills/$sname"
done
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
        if [ "$rel" = AGENTS.md ] && head -n1 "$src" | grep -q '^<!-- ai-core map:'; then MAP_SRC="$src"; else put "$src" "$rel" managed; [ "$rel" = AGENTS.md ] && AGENTS_SRC="$src"; fi
        DEPLOYED="$DEPLOYED $rel"
      fi
      LAYER_FILES="$LAYER_FILES $rel"
    done <<< "$( (cd "$INNER/repos/$REPO_NAME" && find . -type f | LC_ALL=C sort) | sed 's|^\./||')"
  fi
fi
# What the layers put into the checkout is recorded in .ai-core/DEPLOYED, so what a layer no
# longer provides is taken out again at the next run; a file the repository tracks is left alone
PREV_DEPLOYED="$( { tr -d '\r' < "$TARGET/.ai-core/DEPLOYED"; } 2>/dev/null || true)"
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
  # checked out, so two machines assemble the same bytes
  for f in "$SECTIONS"/[0-9][0-9]-*.md; do
    printf '<!-- %s: rules/%s -->\n' "$(cat "$f.src")" "$(basename "$f")"
    printf '%s\n\n' "$(tr -d '\r' < "$f")"
  done
} > "$TMP/rules.md"
put "$TMP/rules.md" .ai-core/rules/rules.md managed
put "$SKILLS_MD" .ai-core/rules/skills.md managed
put "$CORE_ROOT/VERSION" .ai-core/VERSION managed
printf '%s\n' "$STAMP" > "$TMP/STAMP"; put "$TMP/STAMP" .ai-core/STAMP managed

# 1a. The binding rules, on top of the map (a generated one, or the generic one of templates/ where
#     the repository has none) and in a project folder's AGENTS.md. Claude Code
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
# A repository the harness has no map for gets the generic one the same way, where its AGENTS.md
# is none yet or one init wrote (a map, or the generic file of before 1.3.20); one the repository
# tracks, or somebody's own, is kept
if [ -z "$MAP_SRC" ] && [ "$PROJECT_FOLDER" -eq 0 ] && [[ " $LAYER_FILES " != *" AGENTS.md "* ]]; then
  if ! git -C "$TARGET" ls-files --error-unmatch AGENTS.md >/dev/null 2>&1 && { [ ! -f "$TARGET/AGENTS.md" ] || grep -qE '^(<!-- ai-core map:|# AGENTS\.md .* Repository Navigation & Operations)' <<< "$(head -n1 "$TARGET/AGENTS.md")"; }; then
    MAP_SRC="$CORE_ROOT/templates/AGENTS.md"
  else
    note kept AGENTS.md
  fi
fi
if [ -n "$MAP_SRC" ]; then
  { head -n2 "$MAP_SRC" | tr -d '\r'; echo ""; binding_block; echo '- `ai-core session-start` before any work; below is the map of this repository.'; echo ""; tail -n +3 "$MAP_SRC" | tr -d '\r' | awk 'NF{f=1} f'; } > "$TMP/AGENTS.map.md"
  put "$TMP/AGENTS.map.md" AGENTS.md managed; AGENTS_SRC="$TMP/AGENTS.map.md"
fi

# 2. The agent files, created once and never overwritten: templates/ mirrors the target layout.
#    AGENTS.md is the map (1a); a project folder's is generated instead: the list of its
#    repositories, rewritten on every run because the folder changes. The file of an agent the project does not serve
#    (AGENTS in .ai-core/config.env, or the template's default before the file exists) is not
#    deployed.
CONFIG="$AI_CORE_DIR/config.env"; [ -f "$CONFIG" ] || CONFIG="$CORE_ROOT/templates/.ai-core/config.env"
AGENTS="$(grep -E '^[[:space:]]*AGENTS[[:space:]]*=' "$CONFIG" | tail -n1 | sed 's/^[^=]*=//; s/#.*//' | tr -d '"\r' | tr -d "'" | tr '[:upper:]' '[:lower:]' || true)"
AGENTS_UNKNOWN=""   # the first name no agent has; the run still deploys the rest and fails at its end
for a in $AGENTS; do
  case "$a" in
    claude|codex|antigravity|openhands|gemini|cursor|windsurf|copilot) ;;
    *) [ -n "$AGENTS_UNKNOWN" ] || AGENTS_UNKNOWN="$a" ;;
  esac
done
serves() {  # serves <agent>: true when the project serves it, or names no agents at all
  [ -z "$AGENTS" ] || case " $AGENTS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  [ "$rel" = "AGENTS.md" ] && continue
  case " $LAYER_FILES " in *" $rel "*) continue ;; esac
  case "$rel" in
    .cursorrules) serves cursor || continue ;;
    .windsurfrules) serves windsurf || continue ;;
    .github/copilot-instructions.md) serves copilot || continue ;;
    .openhands/microagents/repo-rules.md) serves openhands || continue ;;
    .claude/settings.json) if command -v jq >/dev/null 2>&1; then continue; fi ;;   # written below, the hook with the full path
    .githooks/commit-msg) continue ;;   # written in 3a, where the push gate is armed
    .ai-core/models.tsv|.ai-core/team-modes.tsv) put "$CORE_ROOT/templates/$rel" "$rel" managed; continue ;;   # the harness's tables, kept current; a project's own comes from its harness layer
    opencode.json)   # one without the template's instructions gets them added
      if command -v jq >/dev/null 2>&1 && [ -f "$TARGET/$rel" ] && ! jq -e --slurpfile t "$CORE_ROOT/templates/$rel" '($t[0].instructions - (.instructions // [])) | length == 0' "$TARGET/$rel" >/dev/null 2>&1; then
        jq --slurpfile t "$CORE_ROOT/templates/$rel" '.instructions = ((.instructions // []) + ($t[0].instructions - (.instructions // [])))' "$TARGET/$rel" 2>/dev/null | tr -d '\r' > "$TMP/opencode.json" \
          && [ -s "$TMP/opencode.json" ] && put_file "$TMP/opencode.json" "$TARGET/$rel" "$rel" managed
        continue
      fi ;;
  esac
  put "$CORE_ROOT/templates/$rel" "$rel" once
done <<< "$( (cd "$CORE_ROOT/templates" && find . -type f | LC_ALL=C sort) | sed 's|^\./||')"
# The Claude Code hook that starts the session, the hook that denies a permission prompt in a
# background session, where nobody would answer it (bin/permission-request.sh), the status line
# that records the account's usage windows for `ai-core usage` (bin/statusline.sh), the permissions
# of the template (the ai-core
# commands) and its denials (the secrets of a checkout and the credentials of the machine are not
# read, a push is not forced, git reset --hard and git clean are refused), each list read from the template, and its empty attribution, so
# Claude Code asks no session to sign a commit or a pull request, which the commit rules forbid.
# The hooks and the status line name ai-core by its full path on this machine, so a Claude Code
# started from a terminal opened before the install still runs them; the file is the machine's,
# never committed. A settings.json the checkout had before (created once, never overwritten) gets
# what it lacks merged in, and an ai-core hook of an older form gives way to this one. Without jq the template stays as it is.
AI_CORE_CMD="$CORE_ROOT/bin/ai-core"
HOOK="\"$AI_CORE_CMD\" session-start --tool claude"
STATUS_LINE="\"$AI_CORE_CMD\" statusline"
PERMISSION_HOOK="\"$AI_CORE_CMD\" permission-request"
SETTINGS="$TARGET/.claude/settings.json"
SETTINGS_TEMPLATE="$CORE_ROOT/templates/.claude/settings.json"
SETTINGS_HAS='def ours: (.command // "") | test("ai-core.? session-start --tool claude$"); def ours_p: (.command // "") | test("ai-core.? permission-request$"); ($t[0].permissions.allow // []) as $allow | ($t[0].permissions.deny // []) as $deny | ([.hooks.SessionStart[]?.hooks[]? | select(ours) | .command] == [$c]) and ([.hooks.PermissionRequest[]?.hooks[]? | select(ours_p) | .command] == [$p]) and (($allow - (.permissions.allow // [])) | length == 0) and (($deny - (.permissions.deny // [])) | length == 0) and (has("autoCompactWindow") | not) and (.statusLine.command == $s) and (.attribution == ((.attribution // {}) + $t[0].attribution))'
SETTINGS_ADD='def ours: (.command // "") | test("ai-core.? session-start --tool claude$"); def ours_p: (.command // "") | test("ai-core.? permission-request$"); ($t[0].permissions.allow // []) as $allow | ($t[0].permissions.deny // []) as $deny | .hooks.SessionStart = ([.hooks.SessionStart[]? | .hooks = [.hooks[]? | select(ours | not)] | select(.hooks | length > 0)] + [{hooks: [{type: "command", command: $c, timeout: 60}]}]) | .hooks.PermissionRequest = ([.hooks.PermissionRequest[]? | .hooks = [.hooks[]? | select(ours_p | not)] | select(.hooks | length > 0)] + [{hooks: [{type: "command", command: $p, timeout: 10}]}]) | .permissions.allow = ((.permissions.allow // []) + ($allow - (.permissions.allow // []))) | .permissions.deny = ((.permissions.deny // []) + ($deny - (.permissions.deny // []))) | del(.autoCompactWindow) | .statusLine = {type: "command", command: $s} | .attribution = ((.attribution // {}) + $t[0].attribution)'
if command -v jq >/dev/null 2>&1; then
  src="$SETTINGS"; [ -f "$src" ] || src="$SETTINGS_TEMPLATE"
  if [ "$src" != "$SETTINGS" ] || ! jq -e --arg c "$HOOK" --arg p "$PERMISSION_HOOK" --arg s "$STATUS_LINE" --slurpfile t "$SETTINGS_TEMPLATE" "$SETTINGS_HAS" "$SETTINGS" >/dev/null 2>&1; then
    jq --arg c "$HOOK" --arg p "$PERMISSION_HOOK" --arg s "$STATUS_LINE" --slurpfile t "$SETTINGS_TEMPLATE" "$SETTINGS_ADD" "$src" 2>/dev/null | tr -d '\r' > "$TMP/settings.json" \
      && [ -s "$TMP/settings.json" ] && put_file "$TMP/settings.json" "$SETTINGS" ".claude/settings.json" managed
  fi
fi
# The deny list for the `claude -p` runs the skills start from a throwaway folder, which read no
# checkout's .claude/settings.json: the template's denials in one file under the ai-core home, for
# `--settings`. A pattern starting with **/ is anchored at //, the filesystem root, because a
# relative one reaches only below the throwaway folder; a ! entry is left out, because Claude
# Code reads a ! pattern relative to the current folder and so cannot carve out of a //-rule.
RUN_SETTINGS="${AI_CORE_HOME:-$HOME}/.ai-core/claude-run-settings.json"
RUN_SETTINGS_MAKE='{permissions: {deny: [.permissions.deny[] | select(test("^[A-Za-z]+\\(!") | not) | sub("^(?<t>[A-Za-z]+)\\(\\*\\*/"; "\(.t)(//**/")]}}'
if command -v jq >/dev/null 2>&1 && jq "$RUN_SETTINGS_MAKE" "$SETTINGS_TEMPLATE" 2>/dev/null | tr -d '\r' > "$TMP/claude-run-settings.json" && [ -s "$TMP/claude-run-settings.json" ]; then
  put_file "$TMP/claude-run-settings.json" "$RUN_SETTINGS" "$RUN_SETTINGS" managed
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
  put "$TMP/AGENTS.md" AGENTS.md managed; AGENTS_SRC="$TMP/AGENTS.md"
fi

# 2c. Codex reads AGENTS.override.md in place of AGENTS.md, from the git root down only, raw: it
#     follows no @ import and never sees the project folder's AGENTS.md above a checkout. Where it is
#     served it gets one file with what Claude Code loads there, the folder's AGENTS.md and this
#     one, each with every file it names after @ written out. Codex reads it up to
#     project_doc_max_bytes, which 2d raises.
codex_override() {  # codex_override <AGENTS.md> <directory its @ paths are relative to>, pair after pair
  local line p
  printf '<!-- setup-ai-core %s: written by init for Codex, which reads this file in place of AGENTS.md and follows no @ import: what Claude Code loads here, each file named after @ written out -->\n' "$CORE_VERSION"
  while [ "$#" -ge 2 ]; do
    while IFS= read -r line || [ -n "$line" ]; do
      printf '%s\n' "$line"
      for p in $(grep -o '@[^[:space:]`]*' <<< "$line" | cut -c2-); do
        [ -f "$2/$p" ] || continue
        printf '\n<!-- %s, written out -->\n' "$p"; tr -d '\r' < "$2/$p"; printf '\n'
      done
    done < <(tr -d '\r' < "$1")
    shift 2
  done
}
CODEX_OVERRIDE_BYTES=0
[ -z "$AGENTS_SRC" ] && [ -f "$TARGET/AGENTS.md" ] && AGENTS_SRC="$TARGET/AGENTS.md"
if serves codex && [ -n "$AGENTS_SRC" ]; then
  set --
  if [ "$PROJECT_FOLDER" -eq 0 ] && FOLDER="$(enclosing_folder "$TARGET")" && [ -f "$FOLDER/AGENTS.md" ]; then set -- "$FOLDER/AGENTS.md" "$FOLDER"; fi
  codex_override "$@" "$AGENTS_SRC" "$TARGET" > "$TMP/AGENTS.override.md"
  if git -C "$TARGET" ls-files --error-unmatch AGENTS.override.md >/dev/null 2>&1; then
    note tracked AGENTS.override.md
  else
    put "$TMP/AGENTS.override.md" AGENTS.override.md managed
    CODEX_OVERRIDE_BYTES="$(wc -c < "$TMP/AGENTS.override.md" | tr -d ' ')"
  fi
fi

# 2d. Codex's user config, the machine's file, gets project_doc_max_bytes at least CODEX_DOC_BYTES,
#     so the override is read whole; a higher value stays. The key is top-level, so it goes before
#     the first table. A Codex that never ran here has no folder yet, and none is created.
CODEX_DOC_BYTES=262144
CODEX_NOTE=""
if serves codex; then
  CODEX_CONFIG="${CODEX_HOME:-$HOME/.codex}/config.toml"
  if [ -d "$(dirname "$CODEX_CONFIG")" ]; then
    codex_doc_bytes=""
    if [ -f "$CODEX_CONFIG" ]; then
      codex_doc_bytes="$(awk '/^\[/ { exit } /^project_doc_max_bytes[ \t]*=/ { sub(/^[^=]*=[ \t]*/, ""); if (match($0, /^[0-9][0-9_]*/)) { v = substr($0, 1, RLENGTH); gsub(/_/, "", v); print v }; exit }' "$CODEX_CONFIG")"
    fi
    if [ "${codex_doc_bytes:-0}" -lt "$CODEX_DOC_BYTES" ]; then
      CODEX_NOTE="project_doc_max_bytes $([ "$DRY" -eq 1 ] && echo "would be set" || echo "set") to $CODEX_DOC_BYTES in $CODEX_CONFIG, so Codex reads AGENTS.override.md whole"
      if [ "$DRY" -eq 0 ]; then
        { [ -f "$CODEX_CONFIG" ] && tr -d '\r' < "$CODEX_CONFIG" || true; } | awk -v line="project_doc_max_bytes = $CODEX_DOC_BYTES" '
          /^\[/ { if (!done) print line; done = 1; table = 1 }
          /^project_doc_max_bytes[ \t]*=/ && !table { if (!done) print line; done = 1; next }
          { print }
          END { if (!done) print line }' > "$TMP/codex-config.toml"
        cat "$TMP/codex-config.toml" > "$CODEX_CONFIG"
      fi
      codex_doc_bytes="$CODEX_DOC_BYTES"
    fi
    if [ "$CODEX_OVERRIDE_BYTES" -gt "$codex_doc_bytes" ]; then
      CODEX_NOTE="${CODEX_NOTE:+$CODEX_NOTE; }warning: AGENTS.override.md has $CODEX_OVERRIDE_BYTES bytes, more than project_doc_max_bytes ($codex_doc_bytes) in $CODEX_CONFIG, so Codex cuts it"
    fi
    # 2e. Where the user runs Codex with approval_policy never and the network open, it checks
    #     nothing. The profile ai-core, which every session the harness starts loads (-p ai-core),
    #     closes the network and hands every approval request, a blocked network call among them,
    #     to Codex's reviewing subagent, with the auto-mode entries of the layers as its policy:
    #     what Claude Code's classifier reads. The user's config.toml stays as it is.
    CODEX_PROFILE="$(dirname "$CODEX_CONFIG")/ai-core.config.toml"
    # The machine has one profile and several project folders, so it holds the entries of every
    # one, as Claude Code's settings do: those of the layers this run assembled are replaced, every
    # other layer's stay, in their order, before this run's.
    : > "$TMP/codex-entries.tsv"
    if [ -f "$CODEX_PROFILE" ]; then
      tr -d '\r' < "$CODEX_PROFILE" | awk -v layers="$AUTO_MODE_LAYERS" -v end="'''" '
        BEGIN { n = split(layers, a, "\n"); for (i = 1; i <= n; i++) mine["[" a[i] "]"] = 1 }
        $0 == "Allow:" { list = "allow"; next }
        $0 == "Environment:" { list = "environment"; next }
        $0 == end { list = ""; next }
        list != "" && substr($0, 1, 3) == "- [" && index($0, "] ") > 0 {
          text = substr($0, 3); if (!(substr(text, 1, index(text, "]")) in mine)) print list "\t" text
        }' > "$TMP/codex-entries.tsv"
    fi
    cat "$TMP/auto-mode.tsv" >> "$TMP/codex-entries.tsv"
    {
      printf '# setup-ai-core %s: written by ai-core init, rewritten on every run. The profile of every Codex\n' "$CORE_VERSION"
      printf '# session the harness starts (codex exec -p ai-core): the network closed, and every approval\n'
      printf '# request decided by the reviewing subagent against the auto-mode entries of the layers.\n'
      printf 'approval_policy = "on-request"\napprovals_reviewer = "auto_review"\nsandbox_mode = "workspace-write"\n\n'
      printf '[sandbox_workspace_write]\nnetwork_access = false\n\n[auto_review]\n'
      printf '%s\n' "policy = '''"
      printf '%s\n' "These entries come from the auto-mode files of the harness and of the project's layers; Claude Code's classifier reads the same. An entry under Allow permits an action that would otherwise be refused; an entry under Environment describes this environment."
      printf '\nAllow:\n'; awk -F '\t' '$1 == "allow" { print "- " $2 }' "$TMP/codex-entries.tsv"
      printf '\nEnvironment:\n'; awk -F '\t' '$1 == "environment" { print "- " $2 }' "$TMP/codex-entries.tsv"
      printf '%s\n' "'''"
    } > "$TMP/ai-core.config.toml"
    if ! cmp -s "$TMP/ai-core.config.toml" "$CODEX_PROFILE"; then
      CODEX_NOTE="${CODEX_NOTE:+$CODEX_NOTE; }the profile ai-core $([ "$DRY" -eq 1 ] && echo "would be written" || echo "written") to $CODEX_PROFILE"
      [ "$DRY" -eq 1 ] || cat "$TMP/ai-core.config.toml" > "$CODEX_PROFILE"
    fi
    # 2f. The template's permissions tell Claude Code which commands run without asking and which
    #     never run. Codex gets the same as prefix rules, from every *.rules file of its rules
    #     folder: a command whose every part an allow rule matches runs without the reviewer and
    #     outside the sandbox, so the harness's own commands cost no review; a forbidden one is
    #     refused; everything else stays with the reviewer.
    CODEX_RULES="$(dirname "$CODEX_CONFIG")/rules/ai-core.rules"
    if ! command -v jq >/dev/null 2>&1; then   # the template is read with jq, as in the settings step
      CODEX_NOTE="${CODEX_NOTE:+$CODEX_NOTE; }no command rules written: jq is missing"
    else
      {
        printf '# setup-ai-core %s: written by ai-core init, rewritten on every run. The commands Claude Code\n' "$CORE_VERSION"
        printf '# runs without asking or never runs (templates/.claude/settings.json, the entries of the form\n# Bash(words:*)), the same in Codex.\n'
        for list in allow:allow deny:forbidden; do
          tr -d '\r' < "$SETTINGS_TEMPLATE" | jq -r --arg l "${list%%:*}" '.permissions[$l][]? | select(test("^Bash\\([^:]*:\\*\\)$")) | .[5:-3]' \
            | while IFS= read -r c; do
                printf 'prefix_rule(pattern = [%s], decision = "%s")\n' "$(printf '%s\n' $c | sed 's/.*/"&"/' | paste -sd, - | sed 's/,/, /g')" "${list#*:}"
              done
        done
      } > "$TMP/ai-core.rules"
      if ! cmp -s "$TMP/ai-core.rules" "$CODEX_RULES"; then
        CODEX_NOTE="${CODEX_NOTE:+$CODEX_NOTE; }the command rules $([ "$DRY" -eq 1 ] && echo "would be written" || echo "written") to $CODEX_RULES"
        [ "$DRY" -eq 1 ] || { mkdir -p "$(dirname "$CODEX_RULES")" && cat "$TMP/ai-core.rules" > "$CODEX_RULES"; }
      fi
    fi
  fi
fi

# 2f. Antigravity (agy) follows no @ import either, and keeps a rule through a compaction only as an
#     always_on rule in .agents/rules/, which it cuts after 24,000 bytes; all always_on rules share
#     20,000 tokens, and past that it keeps only a pointer to the largest. Where it is served it gets
#     the text Codex gets, without Codex's header, cut at line ends into parts of at most the cut,
#     frontmatter counted, each with the frontmatter agy discards a rule without; a line longer than
#     a part is cut inside, where agy would cut it anyway. A part carries its writer in its
#     description, so a file of the project's own under the same name, or one git tracks, is never
#     written over or removed; a part of init's own that is no longer written is removed.
AGY_PART_BYTES=24000
AGY_NOTE=""
agy_part_ours() { head -n 3 "$1" 2>/dev/null | grep -q '^description: the binding rules setup-ai-core '; }
agy_part_tracked() { git -C "$TARGET" ls-files --error-unmatch "$1" >/dev/null 2>&1; }
mkdir -p "$TMP/agy-rules"
if serves antigravity && [ -n "$AGENTS_SRC" ]; then
  set --
  if [ "$PROJECT_FOLDER" -eq 0 ] && FOLDER="$(enclosing_folder "$TARGET")" && [ -f "$FOLDER/AGENTS.md" ]; then set -- "$FOLDER/AGENTS.md" "$FOLDER"; fi
  codex_override "$@" "$AGENTS_SRC" "$TARGET" | tail -n +2 | LC_ALL=C awk -v max="$AGY_PART_BYTES" -v dir="$TMP/agy-rules" -v version="$CORE_VERSION" '
    function part() { n++; f = sprintf("%s/ai-core-%02d.md", dir, n); empty = 1
      head = sprintf("---\ntrigger: always_on\ndescription: the binding rules setup-ai-core %s wrote out for this folder, part %d\n---\n", version, n)
      printf "%s", head > f; size = length(head) }
    BEGIN { part() }
    { line = $0
      while (size + length(line) + 1 > max) {
        if (!empty) { close(f); part(); continue }
        room = max - size - 1; print substr(line, 1, room) > f; line = substr(line, room + 1); close(f); part()
      }
      print line > f; size += length(line) + 1; empty = 0 }'
  agy_bytes=0
  for p in "$TMP"/agy-rules/ai-core-*.md; do
    rel=".agents/rules/$(basename "$p")"
    if agy_part_tracked "$rel"; then note tracked "$rel"
    elif [ -e "$TARGET/$rel" ] && ! agy_part_ours "$TARGET/$rel"; then
      note kept "$rel"; AGY_NOTE="${AGY_NOTE:+$AGY_NOTE; }$rel is the project's own, so agy misses that part of the rules"
    else put "$p" "$rel" managed; fi
    agy_bytes=$((agy_bytes + $(wc -c < "$p")))
  done
  # About 4 bytes of English make a token; agy counts the real ones, so this only warns.
  if [ "$agy_bytes" -gt 80000 ]; then
    AGY_NOTE="${AGY_NOTE:+$AGY_NOTE; }warning: .agents/rules/ai-core-*.md hold $agy_bytes bytes, about $((agy_bytes / 4)) tokens, past the 20,000 tokens agy keeps of its always_on rules, so it keeps only a pointer to the largest part"
  fi
fi
for p in "$TARGET"/.agents/rules/ai-core-[0-9][0-9].md; do
  rel=".agents/rules/$(basename "$p")"
  [ -e "$p" ] && [ ! -e "$TMP/agy-rules/$(basename "$p")" ] && agy_part_ours "$p" && ! agy_part_tracked "$rel" && drop "$rel"
done

# 2b. The auto-mode entries go into Claude Code's user settings, the machine's file, because its
#     classifier reads autoMode there and in managed settings, never in a repository's settings.
#     lib/auto-mode.jq merges them: the entries of the layers this run assembled are replaced, every
#     other entry stays. A Claude Code that never ran here has no folder yet, and none is created.
AUTO_MODE_FILE=""; AUTO_MODE_NOTE=""
AUTO_MODE_CHANGES='("allow", "environment") as $l | ((($n[0].autoMode[$l] // []) - ($o[0].autoMode[$l] // []))[] | "added to \($l): \(.)"), ((($o[0].autoMode[$l] // []) - ($n[0].autoMode[$l] // []))[] | "removed from \($l): \(.)")'
if serves claude && ! command -v jq >/dev/null 2>&1; then
  AUTO_MODE_NOTE="jq is missing, so no entry was written into Claude Code's user settings; install jq and run init again"
elif serves claude; then
  CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; AUTO_MODE_FILE="$CLAUDE_DIR/settings.json"
  printf '%s\n' "$AUTO_MODE_LAYERS" > "$TMP/auto-mode-layers.txt"
  if [ ! -d "$CLAUDE_DIR" ]; then
    AUTO_MODE_NOTE="$CLAUDE_DIR does not exist, so Claude Code has not run on this machine; no entry written"
  else
    # Claude Code and every init on this machine write this one file. The merge replaces it only
    # while it still holds what was read, and goes round again otherwise. It is written in place,
    # not renamed over, so a settings file that is a link stays one and keeps its mode.
    AUTO_MODE_NOTE="$AUTO_MODE_FILE changed while init merged into it, three times over; no entry written, run init again"
    for try in 1 2 3; do
      if [ -f "$AUTO_MODE_FILE" ]; then cp -f "$AUTO_MODE_FILE" "$TMP/user-settings-read.json"; else echo '{}' > "$TMP/user-settings-read.json"; fi
      if ! jq --rawfile e "$TMP/auto-mode.tsv" --rawfile l "$TMP/auto-mode-layers.txt" -f "$CORE_ROOT/lib/auto-mode.jq" "$TMP/user-settings-read.json" 2>/dev/null | tr -d '\r' > "$TMP/user-settings.json" || [ ! -s "$TMP/user-settings.json" ]; then
        AUTO_MODE_NOTE="$AUTO_MODE_FILE is no JSON object with lists in autoMode, so no entry was written; repair it and run init again"; break
      fi
      jq -rn --slurpfile o "$TMP/user-settings-read.json" --slurpfile n "$TMP/user-settings.json" "$AUTO_MODE_CHANGES" | tr -d '\r' > "$TMP/auto-mode-changes.txt"
      if [ ! -s "$TMP/auto-mode-changes.txt" ] || [ "$DRY" -eq 1 ]; then AUTO_MODE_NOTE=""; break; fi
      if [ -f "$AUTO_MODE_FILE" ] && ! cmp -s "$AUTO_MODE_FILE" "$TMP/user-settings-read.json"; then continue; fi
      cp -f "$TMP/user-settings.json" "$AUTO_MODE_FILE"; AUTO_MODE_NOTE=""; break
    done
  fi
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
    echo "/AGENTS.override.md"
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
#     committed, so a fresh clone gets it from its first init. Beside it stands
#     .githooks/commit-msg, which judges the gate's message rules as the commit is made; it is
#     the harness's, in the exclude file like the rest, unless the repository commits its own.
HOOKS_ARMED=0
if [ -f "$TARGET/.githooks/pre-push" ] && [ "$(git -C "$TARGET" config --get core.hooksPath 2>/dev/null)" != ".githooks" ]; then
  HOOKS_ARMED=1
  [ "$DRY" -eq 1 ] || git -C "$TARGET" config core.hooksPath .githooks
fi
if [ -f "$TARGET/.githooks/pre-push" ] && ! git -C "$TARGET" ls-files --error-unmatch .githooks/commit-msg >/dev/null 2>&1; then
  put "$CORE_ROOT/templates/.githooks/commit-msg" .githooks/commit-msg managed
fi

# 3a2. A checkout whose origin is on the forge signs in the way the forge asks, by a setting in its own
#      .git/config (the forge's clone_sign_in); a forge that signs in once for the machine sets nothing.
SIGN_IN_MODE=""; [ "$DRY" -eq 0 ] || SIGN_IN_MODE=dry
SIGN_IN_NOTE="$(clone_sign_in "$TARGET" $SIGN_IN_MODE)"

# 3b. The project's .gitignore carries a block naming every file an agent or the harness puts
#     into a checkout (lib/gitignore-block), so no clone of this repository commits one, with or
#     without the harness. The block is rewritten where it stands, between its markers, and every
#     other line is the project's, kept as it is; a file without a block gets it at its end. A path
#     the project already ignores, with or without the slashes, is not written twice, and when it
#     ignores them all no block is written. Only the main checkout writes the block and commits
#     it: a worktree is somebody's issue, takes the block when it rebases, and until then the
#     exclude file it shares with its checkout keeps the deployed files out of git status.
# commit_gitignore <checkout>: the block committed on its own and pushed by ref to the branch
# checked out, which catch_up has made sure of. Prints the note for the report; the push's own
# output, the gate's among it, goes to the terminal. A push that is refused or fails takes the
# commit back and returns 1: a commit nobody pushes leaves the checkout off its origin, and the
# next start-issue there refuses it.
commit_gitignore() {
  local dir="$1" branch
  git -C "$dir" add -- .gitignore
  git -C "$dir" commit -q -m 'the agent files of this repository are ignored' -m 'No-issue: the .gitignore block written by ai-core init' -- .gitignore >&2 || { echo "the commit failed (see above)"; return 0; }
  git -C "$dir" remote get-url origin >/dev/null 2>&1 || { echo "committed; no origin, not pushed"; return 0; }
  branch="$(git -C "$dir" symbolic-ref --short -q HEAD)"
  if git -C "$dir" push --quiet origin "HEAD:$branch" >&2; then echo "committed and pushed to origin/$branch"; return 0; fi
  git -C "$dir" reset -q --keep HEAD~1 >&2 || { echo "committed; the push was refused or failed (see above), and init could not take its commit back"; return 0; }
  echo "the push was refused or failed (see above), so init took its commit back"; return 1
}
gitignore_build() {  # the .gitignore the checkout should have, into $TMP/gitignore
  if [ -f "$GI" ]; then tr -d '\r' < "$GI" > "$TMP/gitignore-now"; else : > "$TMP/gitignore-now"; fi
  # Two passes over the file: the first collects the project's lines, the second writes the file
  # with the block in the place of the first one it holds
  awk -v block="$CORE_ROOT/lib/gitignore-block" '
    function norm(s) { sub(/[[:space:]]+$/, "", s); sub(/^\//, "", s); sub(/\/$/, "", s); return s }
    function put(   i, k) {
      placed = 1
      for (i = 1; i <= e; i++) if (!(norm(entry[i]) in seen)) miss[++k] = entry[i]
      if (k) { print marker[1]; for (i = 1; i <= k; i++) print miss[i]; print marker[2] }
    }
    BEGIN { while ((getline line < block) > 0) { sub(/\r$/, "", line); if (line ~ /^#/) marker[++m] = line; else entry[++e] = line } }
    NR == FNR {
      if (/^# setup-ai-core start/) skip = 1
      if (!skip && $0 !~ /^#/ && $0 != "") seen[norm($0)] = 1
      if (/^# setup-ai-core end/) skip = 0
      next
    }
    FNR == 1 { skip = 0 }
    /^# setup-ai-core start/ { if (!placed) put(); skip = 1 }
    !skip { print }
    /^# setup-ai-core end/ { skip = 0 }
    END { if (!placed) put() }' "$TMP/gitignore-now" "$TMP/gitignore-now" > "$TMP/gitignore"
}
gitignore_differs() { ! { [ -f "$GI" ] && cmp -s "$TMP/gitignore" <(tr -d '\r' < "$GI"); }; }
# A start line without its end leaves no way to tell the block from the project's lines after it
gitignore_open() { [ -f "$GI" ] && tr -d '\r' < "$GI" | awk '/^# setup-ai-core start/ { open = 1 } /^# setup-ai-core end/ { open = 0 } END { exit !open }'; }
GITIGNORE_CHANGED=0; GITIGNORE_NOTE=""; GITIGNORE_BEHIND=0; GITIGNORE_REFUSED=0; GITIGNORE_OPEN=0; GITIGNORE_PULLED=""
GI="$TARGET/.gitignore"; MAIN_CHECKOUT=0
git -C "$TARGET" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  && [ "$(git -C "$TARGET" rev-parse --git-dir)" = "$(git -C "$TARGET" rev-parse --git-common-dir)" ] && MAIN_CHECKOUT=1
if [ "$MAIN_CHECKOUT" -eq 1 ] && gitignore_open; then
  GITIGNORE_OPEN=1
elif [ "$MAIN_CHECKOUT" -eq 1 ]; then
  gitignore_build
  if gitignore_differs; then
    GITIGNORE_CHANGED=1
    if [ "$DRY" -eq 0 ]; then
      # The commit goes on top of what the origin has: the checkout catches up first, and the
      # block is built again from what came
      CAUGHT="$(catch_up "$TARGET")" || GITIGNORE_BEHIND=1
      if [ "$GITIGNORE_BEHIND" -eq 1 ]; then GITIGNORE_NOTE="$CAUGHT"
      else
        [ -z "$CAUGHT" ] || gitignore_build
        if [ -n "$CAUGHT" ] && gitignore_open; then GITIGNORE_CHANGED=0; GITIGNORE_OPEN=1; GITIGNORE_PULLED="$CAUGHT"
        elif git -C "$TARGET" remote get-url origin >/dev/null 2>&1 && [ -n "$(git -C "$TARGET" status --porcelain -- .gitignore)" ]; then
          # A .gitignore with changes of its own would go out to the origin in init's commit, and a
          # refused push would take them back with it: the block waits until they are committed
          GITIGNORE_REFUSED=1; GITIGNORE_NOTE="${CAUGHT:+$CAUGHT; }it has changes of its own; commit them or take them back, then run this again"
        elif gitignore_differs; then
          # a file with CRLF line ends keeps them: the block is written the way the file already is
          if [ -f "$GI" ] && ! tr -d '\r' < "$GI" | cmp -s - "$GI"; then awk '{ printf "%s\r\n", $0 }' "$TMP/gitignore" > "$GI"; else cp -f "$TMP/gitignore" "$GI"; fi
          GITIGNORE_SENT="$(commit_gitignore "$TARGET")" || GITIGNORE_REFUSED=1
          GITIGNORE_NOTE="${CAUGHT:+$CAUGHT; }$GITIGNORE_SENT"
        else GITIGNORE_CHANGED=0; GITIGNORE_NOTE="$CAUGHT"; fi
      fi
    fi
  fi
fi

# 3c. Shims git skips for want of the executable bit (a copy that drops the file modes writes them
#     so) leave the push gate off: in a checkout, ai-core pre-push --install sets the bit, commits
#     and pushes it, and a worktree gets it with that commit. A hook of the project's own that git
#     skips is named, not changed.
SHIMS_MODE=0
if [ -d "$TARGET/.git" ] && [ -f "$TARGET/.githooks/pre-push" ] \
  && { [ -n "$(git -C "$TARGET" ls-files -s -- .githooks/pre-push .githooks/post-checkout | awk '$1 != "100755"')" ] || [ ! -x "$TARGET/.githooks/pre-push" ]; }; then
  SHIMS_MODE=1
  [ "$DRY" -eq 1 ] || ( cd "$TARGET" && bash "$CORE_ROOT/bin/pre-push.sh" --install ) || SHIMS_MODE=2
fi
SKIPPED_HOOKS="$(git -C "$TARGET" ls-files -s -- .githooks 2>/dev/null | awk '$1 == "100644" && $4 != ".githooks/pre-push" && $4 != ".githooks/post-checkout" { print $4 }' || true)"

# 4. The report: what this run did to the checkout, or would do
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
  elif [ "$GITIGNORE_BEHIND" -eq 1 ]; then echo "  .gitignore not written: this checkout is $GITIGNORE_NOTE"
  elif [ "$GITIGNORE_REFUSED" -eq 1 ]; then echo "  .gitignore not written: $GITIGNORE_NOTE"
  else echo "  .gitignore changed: the agent files of this repository are ignored; $GITIGNORE_NOTE"; fi
elif [ -n "$GITIGNORE_NOTE" ]; then echo "  .gitignore: $GITIGNORE_NOTE; the block was there already"
fi
[ "$GITIGNORE_OPEN" -eq 0 ] || echo "  .gitignore not written: ${GITIGNORE_PULLED:+$GITIGNORE_PULLED; }it has a '# setup-ai-core start' line and no '# setup-ai-core end' after it; end the block or delete its start line, then run this again"
if [ -n "$WORKTREE_DATA_FROM" ]; then echo "  .ai-core $([ "$DRY" -eq 1 ] && echo "would be taken" || echo "taken") from the checkout $WORKTREE_DATA_FROM: a worktree starts with the checkout's configuration, local rules and documents"; fi
if [ -n "$NEIGHBOURS_LINKED" ]; then echo "  links to the neighbour checkouts $([ "$DRY" -eq 1 ] && echo "would be made" || echo "made") in $NEIGHBOURS_IN:$NEIGHBOURS_LINKED; .. finds them from the worktree as from the checkout"; fi
if [ -n "$NEIGHBOURS_HELD" ]; then echo "  the published copies of these neighbours carry a change or a commit their origin lacks, so they were not moved to their origin's newest commit:$NEIGHBOURS_HELD (in .ai-core/neighbours/<neighbour>/origin-<branch>)"; fi
if [ -n "$NEIGHBOURS_UNPUBLISHED" ]; then echo "  the origins of these neighbours named no default branch, so they are linked as their checkouts, with whatever stands in them:$NEIGHBOURS_UNPUBLISHED"; fi
if [ -n "$NEIGHBOURS_BLOCKED" ]; then echo "  these neighbours got no link to their published copy, because .ai-core/neighbours/<neighbour>/origin-<branch> cannot become one: a folder that is no worktree stands there, or git still registers a copy whose folder was removed ('git -C <neighbour> worktree list' shows it as prunable); a link that stood there before stays as it was:$NEIGHBOURS_BLOCKED"; fi
if [ -n "$NEIGHBOURS_LEFT" ]; then echo "  the links now follow a renamed default branch; the copies of the old one stay, as nothing removes a worktree here:$NEIGHBOURS_LEFT"; fi
if [ -n "$NEIGHBOURS_MOVED" ]; then echo "  the published copies of these neighbours $([ "$DRY" -eq 1 ] && echo "would move" || echo moved) out of .worktrees/ to .ai-core/neighbours/, with all they hold, and the links of every worktree $([ "$DRY" -eq 1 ] && echo "would follow" || echo followed):$NEIGHBOURS_MOVED"; fi
if [ -n "$NEIGHBOURS_UNMOVED" ]; then echo "  these published copies could not move out of .worktrees/ (their place in .ai-core/neighbours/ is taken, or git refused the move), so a tool that reads .worktrees/ as the places of work still counts them:$NEIGHBOURS_UNMOVED"; fi
if [ -n "$NEIGHBOURS_UNLINKED" ]; then echo "  links to checkouts that are gone $([ "$DRY" -eq 1 ] && echo "would be removed" || echo "removed") in $NEIGHBOURS_IN:$NEIGHBOURS_UNLINKED"; fi
if [ -n "$SIGN_IN_NOTE" ]; then echo "  $SIGN_IN_NOTE"; fi
if [ "$HOOKS_ARMED" -eq 1 ]; then echo "  core.hooksPath $([ "$DRY" -eq 1 ] && echo "would be set" || echo "set") to .githooks: the push gate runs here"; fi
if [ "$SHIMS_MODE" -eq 1 ] && [ "$DRY" -eq 1 ]; then echo "  the shims in .githooks are not executable, so git skips the push gate: ai-core pre-push --install would make them so"
elif [ "$SHIMS_MODE" -eq 1 ]; then echo "  the shims in .githooks were not executable, so git skipped the push gate: ai-core pre-push --install made them so"
elif [ "$SHIMS_MODE" -eq 2 ]; then echo "  the shims in .githooks are not executable, so git skips the push gate, and ai-core pre-push --install failed (see above)"; fi
for hook in $SKIPPED_HOOKS; do echo "  $hook is not executable, so git skips it; it is the project's own and stays as it is"; done
if [ -n "$AUTO_MODE_NOTE" ]; then echo "  auto mode: $AUTO_MODE_NOTE"
elif [ -s "$TMP/auto-mode-changes.txt" ]; then
  echo "  auto mode: $AUTO_MODE_FILE $([ "$DRY" -eq 1 ] && echo "would change" || echo "changed"):"
  sed 's/^/    /' "$TMP/auto-mode-changes.txt"
fi
if [ -n "$CODEX_NOTE" ]; then echo "  codex: $CODEX_NOTE"; fi
if [ -n "$AGY_NOTE" ]; then echo "  antigravity: $AGY_NOTE"; fi
if [ "$DRY" -eq 1 ]; then echo "  nothing was written (dry run)"; elif [ -z "$AGENTS_UNKNOWN" ]; then echo "✓ Harness $CORE_VERSION in place. Run 'ai-core session-start' here to verify."; fi
echo "=================================================="
if [ -n "$AGENTS_UNKNOWN" ]; then echo "error: AGENTS in $CONFIG names '$AGENTS_UNKNOWN'; known are claude, codex, antigravity, openhands, gemini, cursor, windsurf, copilot" >&2; exit 1; fi
[ "$SHIMS_MODE" -ne 2 ]
