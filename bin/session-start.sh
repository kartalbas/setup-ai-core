#!/usr/bin/env bash
# Session Start Procedure for AI Coding Agents
#
#   session-start.sh [--json]
#
set -euo pipefail

for arg in "$@"; do
  if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
  echo "Usage: session-start.sh [options]"
  echo ""
  echo "Starts a new AI agent coding session by requesting task context and goal."
  echo ""
  echo "Options:"
  echo "  -h, --help    Show this help message"
  echo "  --json        Print the same facts as JSON"
  echo ""
  echo "Exit status is 1 when the core rules file is missing (run init)."
  echo ""
  echo "Examples:"
  echo "  ai-core session-start"
  echo "  ai-core session-start --json"
  exit 0
  fi
done

as_json=0
if [ "${1:-}" = "--json" ] || [ "${1:-}" = "-Json" ]; then
  as_json=1
fi

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

GH_LOGGED_IN=0
GH_USER=""
if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    GH_LOGGED_IN=1
    GH_USER="$(gh api user -q .login 2>/dev/null || echo "")"
  fi
fi

bool() { [ "$1" -eq 1 ] && echo true || echo false; }

if [ "$as_json" -eq 1 ]; then
  cat <<JSON
{
  "repository": "$REPO_NAME",
  "root": "$ROOT",
  "branch": "$BRANCH",
  "uncommitted_files": $DIRTY_COUNT,
  "harness_version": "$HARNESS_VERSION",
  "rules_present": $(bool $RULES_OK),
  "rules_path": "$RULES_PATH",
  "local_rules_present": $(bool $LOCAL_RULES_OK),
  "graft_indexed": $(bool $GRAFT_OK),
  "gh_authenticated": $(bool $GH_LOGGED_IN),
  "gh_user": "$GH_USER"
}
JSON
  exit $((1 - RULES_OK))
fi

echo "=================================================="
echo "AI Agent Session Start: $REPO_NAME"
echo "=================================================="
echo "Branch           : $BRANCH"
echo "Uncommitted files: $DIRTY_COUNT"
echo "Harness version  : $([ -n "$HARNESS_VERSION" ] && echo "$HARNESS_VERSION" || echo "✗ Missing (.ai-core/VERSION)")"
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

if [ "$RULES_OK" -eq 0 ]; then
  echo "Not ready: no rules file found. Run ai-core init in this repository." >&2
  exit 1
fi
echo "Ready for task execution."
