#!/usr/bin/env bash
# The session start: what an agent reads before its first action, in a repository or in a
# project folder. It refuses when a team mode is missing, prints the state of the checkout and,
# in a worktree of an issue, that issue's thread.
#
#   session-start.sh [--json] [--tool NAME ...]
#
set -euo pipefail

for arg in "$@"; do
  if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
  echo "Usage: session-start.sh [--json] [--tool NAME ...]"
  echo ""
  echo "The first step of every session. It runs team-modes-check and refuses when a mode is"
  echo "missing; it prints the branch, the uncommitted files, the harness version, the rules, the"
  echo "Graft graph and the gh login; in a worktree named issue-N-... it prints the thread of issue N"
  echo "and whether it is assigned to you."
  echo ""
  echo "Options:"
  echo "  -h, --help    Show this help message"
  echo "  --json        Print the same facts as JSON"
  echo "  --tool NAME   Check the team modes of this tool only (repeatable); with one tool, the"
  echo "                form the hooks use, its modes are switched on at the end of the output"
  echo ""
  echo "Exit status is 1 when a team mode is missing or the rules file is missing (run init)."
  echo ""
  echo "Examples:"
  echo "  ai-core session-start"
  echo "  ai-core session-start --json"
  exit 0
  fi
done

CORE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
as_json=0; tool_args=(); TOOL=""; TOOL_N=0
while [ $# -gt 0 ]; do
  case "$1" in
    --json|-Json) as_json=1; shift ;;
    --tool) [ $# -ge 2 ] || { echo "error: --tool needs a value" >&2; exit 2; }; tool_args+=(--tool "$2"); TOOL="$2"; TOOL_N=$((TOOL_N + 1)); shift 2 ;;
    *) echo "error: unknown argument '$1' (see --help)" >&2; exit 2 ;;
  esac
done

# 1. The gate: no session without the team modes. team-modes-check prints its own lines and the
#    refusal; nothing else is printed before it.
if ! modes="$(bash "$CORE/bin/team-modes-check.sh" ${tool_args[@]+"${tool_args[@]}"} 2>&1)"; then
  printf '%s\n' "$modes"
  exit 1
fi

# 2. The checkout
ROOT="$(pwd)"
REPO_NAME="$(basename "$ROOT")"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "not-a-git-repo")"
DIRTY_COUNT="$({ git status --porcelain 2>/dev/null || true; } | wc -l | tr -d ' ')"

RULES_PATH=""
if [ -f ".ai-core/rules/rules.md" ]; then
  RULES_PATH=".ai-core/rules/rules.md"
elif [ -f "rules/rules.md" ]; then
  RULES_PATH="rules/rules.md"
fi
RULES_OK=0
[ -n "$RULES_PATH" ] && RULES_OK=1
LOCAL_RULES_OK=0
[ -f ".ai-core/rules/rules.local.md" ] && LOCAL_RULES_OK=1
HARNESS_VERSION=""
[ -f ".ai-core/VERSION" ] && HARNESS_VERSION="$(tr -d '\r\n' < .ai-core/VERSION)"
GRAFT_OK=0
{ [ -f "graft/index.md" ] || [ -f "graft/INDEX.md" ] || [ -f "graft/workspace.json" ]; } && GRAFT_OK=1

# The harness this checkout was assembled from (.ai-core/STAMP, one line per layer: name and
# commit) against the clones beside the repositories; and the releases, asked from the origins by
# update --check, unless UPDATE_CHECK is "never" (config.env, or AI_CORE_UPDATE_CHECK in the
# environment). Nothing is updated here; the lines say what to run.
. "$CORE/lib/layers.sh"
FOLDER="$(project_folder_of "$ROOT")"
HARNESS_CURRENT=true; HARNESS_STAMP=""
if [ -f ".ai-core/STAMP" ]; then
  HARNESS_STAMP="$( { tr -d '\r' < .ai-core/STAMP | grep -v '^$' || true; } | tr '\n' ';' | sed 's/;$//')"
  while read -r lname lcommit; do
    [ -n "$lname" ] || continue
    if [ "$lname" = setup-ai-core ]; then ldir="$CORE"; else ldir="$FOLDER/$lname"; fi
    [ -d "$ldir" ] || continue
    [ "$(git -C "$ldir" rev-parse --short HEAD 2>/dev/null)" = "$lcommit" ] || HARNESS_CURRENT=false
  done < <(tr -d '\r' < .ai-core/STAMP)
else
  HARNESS_CURRENT=false
fi
UPDATE_CHECK="${AI_CORE_UPDATE_CHECK:-}"
[ -n "$UPDATE_CHECK" ] || UPDATE_CHECK="$( { grep -E '^[[:space:]]*UPDATE_CHECK[[:space:]]*=' .ai-core/config.env 2>/dev/null || true; } | tail -n1 | sed 's/^[^=]*=//; s/#.*//' | tr -d '"\r ' | tr -d "'")" || true
RELEASE_LINES=""; RELEASE_STATE="skipped"   # current | available | unreachable | skipped
if [ "$UPDATE_CHECK" != never ]; then
  rc=0; RELEASE_LINES="$(bash "$CORE/bin/update.sh" --check 2>/dev/null)" || rc=$?
  case $rc in 0) RELEASE_STATE=current ;; 2) RELEASE_STATE=available ;; *) RELEASE_STATE=unreachable ;; esac
fi

GH_LOGGED_IN=0
GH_USER=""
if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    GH_LOGGED_IN=1
    GH_USER="$(gh api user -q .login 2>/dev/null || echo "")"
  fi
fi

# 3. The issue of this worktree: a branch or a directory named issue-N-<slug> carries issue N.
#    Its thread is read through issue-thread, and issue-mine says whether it is assigned to you.
worktree_issue_number() {  # worktree_issue_number <name>
  local tail="${1##*/}" number
  case "$tail" in
    issue-[0-9]*) number="${tail#issue-}"; number="${number%%-*}"
                  case "$number" in ''|*[!0-9]*) return 0 ;; esac; echo "$number" ;;
  esac
}
ISSUE="$(worktree_issue_number "$BRANCH")"
[ -n "$ISSUE" ] || ISSUE="$(worktree_issue_number "$ROOT")"
THREAD=""; THREAD_JSON="null"; ASSIGNED=false; MINE=""
if [ -n "$ISSUE" ]; then
  if THREAD_JSON="$(bash "$CORE/bin/issue-thread.sh" "$ISSUE" --json 2>&1)"; then
    THREAD="$(printf '%s' "$THREAD_JSON" | jq -r '
      "#\(.number) \(.title)",
      "state: \(.state)",
      "labels: \(if (.labels | length) == 0 then "-" else (.labels | join(", ")) end)",
      "",
      .body,
      (.comments[] | "", "--- \(.author) \(.created_at)", .body)')"
  else
    THREAD="The thread of #$ISSUE could not be read: $THREAD_JSON"; THREAD_JSON="null"
  fi
  if MINE="$(bash "$CORE/bin/issue-mine.sh" "$ISSUE" 2>&1)"; then ASSIGNED=true; fi
fi

# 4. The team modes of the tool this session runs in, switched on. A mode that is a skill is
#    printed whole with its level: the hook's output is the agent's context, so the agent runs
#    with it from the first prompt. A plugin switches itself on through its own hook and is named
#    with its level. For one --tool, the form the hooks use, and in the text output only.
MODES_TEXT=""
if [ "$TOOL_N" -eq 1 ] && [ "$as_json" -eq 0 ]; then
  TABLE="${TEAM_MODES_FILE:-$(. "$CORE/lib/board.sh"; data_file team-modes.tsv)}"
  while IFS=$'\t' read -r _ mode level pr _; do
    [ -n "$mode" ] || continue
    upper="$(printf '%s' "$mode" | tr '[:lower:]' '[:upper:]')"
    case "$pr" in
      skill:*)
        name="${pr#skill:}"; skill=""
        for d in "$HOME/.$TOOL/skills/$name" "$PWD/.$TOOL/skills/$name" "$HOME/.agents/skills/$name" "$PWD/.agents/skills/$name"; do
          [ -f "$d/SKILL.md" ] && { skill="$d/SKILL.md"; break; }
        done
        [ -n "$skill" ] || continue
        MODES_TEXT="$MODES_TEXT$upper MODE ACTIVE — level: $level ($skill follows; it binds this session)"$'\n'"$(awk 'NR==1 && /^---/{f=1; next} f && /^---/{f=0; next} !f' "$skill" | tr -d '\r')"$'\n'"ARGUMENTS: $level"$'\n\n' ;;
      *) MODES_TEXT="$MODES_TEXT$upper MODE: $level, switched on by its own hook"$'\n' ;;
    esac
  done <<< "$(tr -d '\r' < "$TABLE" | awk -F'\t' -v t="$TOOL" '!/^#/ && NF >= 5 && $1 == t')"
fi

bool() { [ "$1" -eq 1 ] && echo true || echo false; }

if [ "$as_json" -eq 1 ]; then
  printf '%s' "$THREAD_JSON" | jq -n \
    --arg repository "$REPO_NAME" --arg root "$ROOT" --arg branch "$BRANCH" \
    --argjson uncommitted_files "$DIRTY_COUNT" --arg harness_version "$HARNESS_VERSION" \
    --argjson rules_present "$(bool $RULES_OK)" --arg rules_path "$RULES_PATH" \
    --argjson local_rules_present "$(bool $LOCAL_RULES_OK)" --argjson graft_indexed "$(bool $GRAFT_OK)" \
    --argjson gh_authenticated "$(bool $GH_LOGGED_IN)" --arg gh_user "$GH_USER" \
    --argjson harness_current "$HARNESS_CURRENT" --arg harness_stamp "$HARNESS_STAMP" \
    --arg release_state "$RELEASE_STATE" --arg release_lines "$RELEASE_LINES" \
    --arg issue "$ISSUE" --argjson assigned "$ASSIGNED" \
    '{ repository: $repository, root: $root, branch: $branch, uncommitted_files: $uncommitted_files,
       harness_version: $harness_version, harness_current: $harness_current, harness_stamp: $harness_stamp,
       release_state: $release_state, release_lines: $release_lines,
       rules_present: $rules_present, rules_path: $rules_path,
       local_rules_present: $local_rules_present, graft_indexed: $graft_indexed,
       gh_authenticated: $gh_authenticated, gh_user: $gh_user,
       issue: (if $issue == "" then null else ($issue | tonumber) end), assigned: $assigned, thread: input }'
  exit $((1 - RULES_OK))
fi

echo "=================================================="
echo "AI Agent Session Start: $REPO_NAME"
echo "=================================================="
echo "Branch           : $BRANCH"
echo "Uncommitted files: $DIRTY_COUNT"
echo "Harness version  : $([ -n "$HARNESS_VERSION" ] && echo "$HARNESS_VERSION" || echo "✗ Missing (.ai-core/VERSION)")"
echo "Harness state    : $([ "$HARNESS_CURRENT" = true ] && echo "✓ Assembled from the current harness" || echo "✗ Assembled from an older harness (run ai-core init)")"
case "$RELEASE_STATE" in
  current)     echo "Releases         : ✓ Current" ;;
  available)   echo "Releases         : ! Available (run ai-core update)"; printf '%s\n' "$RELEASE_LINES" | sed 's/^/                   /' ;;
  unreachable) echo "Releases         : – Could not reach an origin"; printf '%s\n' "$RELEASE_LINES" | sed 's/^/                   /' ;;
  skipped)     echo "Releases         : – Not checked (UPDATE_CHECK=never)" ;;
esac
echo "Rules file       : $([ $RULES_OK -eq 1 ] && echo "✓ Present ($RULES_PATH)" || echo "✗ Missing")"
echo "Local rules      : $([ $LOCAL_RULES_OK -eq 1 ] && echo "✓ Present (.ai-core/rules/rules.local.md)" || echo "– None")"
echo "Graft code graph : $([ $GRAFT_OK -eq 1 ] && { [ -f graft/workspace.json ] && echo "✓ Workspace (graft/workspace.json)" || echo "✓ Indexed (graft/index.md)"; } || echo "✗ Not indexed (run ai-core graft)")"
if [ "$GH_LOGGED_IN" -eq 1 ]; then
  echo "GitHub status    : ✓ Authenticated as @$GH_USER"
else
  echo "GitHub status    : ✗ Not logged in / gh missing"
fi
echo "=================================================="

if [ "$DIRTY_COUNT" -gt 0 ]; then
  echo "warning: Working directory has $DIRTY_COUNT uncommitted changes:"
  git status --short
fi

if [ -n "$ISSUE" ]; then
  echo ""
  echo "This worktree carries issue #$ISSUE. ${MINE}"
  echo ""
  printf '%s\n' "$THREAD"
  echo ""
fi

if [ "$RULES_OK" -eq 0 ]; then
  echo "Not ready: no rules file found. Run ai-core init in this repository." >&2
  exit 1
fi
echo "Ready for task execution."
[ -z "$MODES_TEXT" ] || { echo ""; printf '%s' "$MODES_TEXT"; }
