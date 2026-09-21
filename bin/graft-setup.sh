#!/usr/bin/env bash
# Build the Graft code graph of the target repository, natively or not at all.
#
#   graft-setup.sh [TARGET_DIR] [--dry-run]
#
set -euo pipefail

for arg in "$@"; do
  if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
    echo "Usage: graft-setup.sh [TARGET_DIR] [--dry-run]"
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
    echo "  --dry-run     Report what Graft would write, in the repository and on the machine; build nothing"
    echo "  -h, --help    Show this help message"
    echo ""
    echo "Examples:"
    echo "  ai-core graft"
    echo "  ai-core graft --dry-run"
    exit 0
  fi
done

TARGET="."; DRY=0
for arg in "$@"; do
  case "$arg" in --dry-run) DRY=1 ;; -*) echo "error: unknown argument '$arg' (see --help)" >&2; exit 2 ;; *) TARGET="$arg" ;; esac
done
cd "$TARGET"
# Graft's own lines "✓ what: path (state)" are read for the report: what it wrote into the
# repository and what on the machine (a path under the home directory), and with which state
HOME_WIN="$(cygpath -w "$HOME" 2>/dev/null || echo "$HOME")"
graft_lines() {  # graft_lines <graft output file>: "<state>\t<path>" per file Graft names; a path under this directory made relative
  local file="$1" line path state here here_win
  here="$(pwd)"; here_win="$(cygpath -w "$here" 2>/dev/null || echo "$here")"
  while IFS= read -r line; do
    line="${line%$'\r'}"
    case "$line" in
      "✓ wrote "*) path="${line#✓ wrote }"; state="wrote" ;;
      ✓*": "*"("*")") path="${line#*: }"; state="${path##*(}"; state="${state%)}"; path="${path% (*}" ;;
      *) continue ;;
    esac
    case "$state" in created|updated|appended|wrote) ;; *) continue ;; esac
    case "$path" in "$here_win\\"*|"$here/"*) path="${path#"$here_win"\\}"; path="${path#"$here"/}" ;; esac
    printf '%s\t%s\n' "$state" "$path"
  done < "$file"
}
report_graft() {  # report_graft <graft output file>
  local repo="" machine="" state path
  while IFS=$'\t' read -r state path; do
    [ -n "$path" ] || continue
    case "$path" in
      "$HOME"*|"$HOME_WIN"*|"~"*) machine="$machine"$'\n'"    $path ($state)" ;;
      *) repo="$repo"$'\n'"    $path ($state)" ;;
    esac
  done <<< "$(graft_lines "$1")"
  [ -z "$repo" ] || echo "  Graft wrote in the repository:$repo"
  [ -z "$machine" ] || echo "  Graft wrote on the machine:$machine"
}
# Graft wires every repository under a project folder, the harness clones (<name>-ai-core) among
# them. A harness clone is data, and ai-core push commits every file in it, so what Graft put
# into one is taken out again: a file it created, its block from a file it appended to, its
# graph and its MCP file.
strip_graft_block() {  # strip_graft_block <file>: Graft's block and the blank lines before it go; a file left empty goes too
  awk '/^<!-- graft:start -->/{skip=1} /^<!-- graft:end -->/{skip=0; next} !skip{n++; l[n]=$0} END{while(n>0 && l[n]=="") n--; for(i=1;i<=n;i++) print l[i]}' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
  [ -s "$1" ] || rm -f "$1"
}
take_out_of_harness_clones() {  # take_out_of_harness_clones <graft output file>
  local taken="" state path clone rel junk
  while IFS=$'\t' read -r state path; do
    [ -n "$path" ] || continue
    path="$(printf '%s' "$path" | tr '\\' '/')"
    clone="${path%%/*}"; rel="${path#*/}"
    case "$clone" in *-ai-core) ;; *) continue ;; esac
    [ "$clone" != "$path" ] && [ -d "$clone/.git" ] && [ -e "$path" ] || continue
    if grep -q '^<!-- graft:start -->' "$path" 2>/dev/null; then strip_graft_block "$path"
    elif git -C "$clone" ls-files --error-unmatch "$rel" >/dev/null 2>&1; then continue
    else rm -rf "$path"; fi
    taken="$taken $path"
  done <<< "$(graft_lines "$1")"
  # what Graft leaves without naming it, or named in an earlier run
  for clone in ./*-ai-core; do
    clone="${clone#./}"; [ -d "$clone/.git" ] || continue
    for junk in graft .mcp.json AGENTS.md; do
      [ -e "$clone/$junk" ] || continue
      git -C "$clone" ls-files --error-unmatch "$junk" >/dev/null 2>&1 && continue
      case " $taken " in *" $clone/$junk "*) continue ;; esac
      if [ "$junk" = AGENTS.md ]; then grep -q '^<!-- graft:start -->' "$clone/$junk" || continue; strip_graft_block "$clone/$junk"; else rm -rf "$clone/$junk"; fi
      taken="$taken $clone/$junk"
    done
  done
  [ -z "$taken" ] || echo "  taken out of the harness clones (data, not code): $(printf '%s' "$taken" | sed 's/^ //; s/ /, /g')"
}

CONFIG_FILE=".ai-core/config.env"
TMP_OUT="$(mktemp)"; trap 'rm -f "$TMP_OUT"' EXIT
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
# --dry-run: what Graft would write, in the repository and on the machine, and nothing built
if [ "$DRY" -eq 1 ]; then
  npx -y @nanonets/graft "${GRAFT_INIT[@]}" --dry-run > "$TMP_OUT" 2>&1 || true
  echo "  Graft would write (init):"
  sed -n '/^would write/,/^$/p' "$TMP_OUT" | sed 's/^/    /'
  echo "  Graft would build the graph into graft/ (not done: dry run)"
  exit 0
fi

if [ -n "$EXCLUDE" ]; then
  if [ -f "$EXCLUDE" ]; then
    while IFS= read -r line; do [ -n "$line" ] && add_line "$line"; done <<< "$(awk '/^# setup-ai-core graft start/{b=1; next} /^# setup-ai-core graft end/{b=0} b' "$EXCLUDE")"
  fi
  # What graft init wires into the repository, excluded whether it exists already or not
  while IFS= read -r line; do [ -n "$line" ] && add_line "/$line"; done <<< "$(npx -y @nanonets/graft "${GRAFT_INIT[@]}" --dry-run 2>&1 | tr -d '\r' | tr '\\' '/' | awk '/^would write.*this repo:/{b=1; next} !/^  /{b=0} b{print $1}')"
  write_block
  BEFORE="$(snapshot)"
fi

# Graft's own output is kept and shown whole only when something fails; what it changed is
# reported in two lines afterwards
echo "==> Graft: wiring the agents and building the code graph (npx -y @nanonets/graft)..."
RESULT=0
{ npx -y @nanonets/graft "${GRAFT_INIT[@]}" && npx -y @nanonets/graft build; } > "$TMP_OUT" 2>&1 || RESULT=1
if [ "$RESULT" -ne 0 ]; then cat "$TMP_OUT"; fi

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
report_graft "$TMP_OUT"
grep -a '^✓ wiring:' "$TMP_OUT" | tail -1 | sed 's/^✓ wiring: /  Graft graph: /' || true
take_out_of_harness_clones "$TMP_OUT"
# One repository gets graft/index.md; a folder of repositories gets a workspace, graft/workspace.json
if [ -f "graft/workspace.json" ]; then
  echo "==> Graft workspace created at $(pwd)/graft/workspace.json: one graph over the repositories of this folder"
elif [ -f "graft/index.md" ] || [ -f "graft/INDEX.md" ]; then
  echo "==> Graft index created at $(pwd)/graft/index.md"
else
  echo "error: Graft finished without writing graft/index.md." >&2; exit 1
fi
