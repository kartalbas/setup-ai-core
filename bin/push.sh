#!/usr/bin/env bash
# Commit and push what changed in the project harness clones of this project folder, then
# refresh the checkout this runs in. Editing the harness is: change a file in the clone beside
# the repositories (<folder>/<name>-ai-core), then `ai-core push`; every colleague gets it at
# their next init.
#
#   push.sh [MESSAGE] [--harness <name>]
#
set -euo pipefail

for arg in "$@"; do
  if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
    echo "Usage: push.sh [MESSAGE] [--harness <name>]"
    echo ""
    echo "Commits everything that changed in every project harness clone of this project folder"
    echo "(<folder>/<name>-ai-core, beside the repositories; the folder of the checkout you stand in),"
    echo "pulls with rebase and pushes to its origin; then runs init in the current directory when"
    echo "it carries the harness, so this checkout is current at once."
    echo ""
    echo "Options:"
    echo "  MESSAGE           The commit message; default: the files that changed. It is the reason the"
    echo "                    push gate wants: unless it names an issue (#<n>) or carries a No-issue:"
    echo "                    trailer, the commit gets 'No-issue: <message>, committed and pushed by ai-core push'"
    echo "  --harness <name>  Only this harness, e.g. shop-ai-core"
    echo "  -h, --help        Show this help message"
    echo ""
    echo "Examples:"
    echo "  ai-core push \"the naming skill: one more trap\""
    echo "  ai-core push --harness shop-ai-core"
    exit 0
  fi
done

CORE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MESSAGE=""; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --harness) [ $# -ge 2 ] || { echo "error: --harness needs a name" >&2; exit 2; }; ONLY="$2"; shift 2 ;;
    -*) echo "error: unknown argument '$1' (see --help)" >&2; exit 2 ;;
    *) [ -z "$MESSAGE" ] || { echo "error: one message only (quote it)" >&2; exit 2; }; MESSAGE="$1"; shift ;;
  esac
done

. "$CORE/lib/layers.sh"
FOLDER="$(project_folder_of "$(pwd)")"
pushed=0; failed=""; seen=0
for dir in "$FOLDER"/*-ai-core; do
  [ "$(basename "$dir")" != setup-ai-core ] || continue   # the clone of setup-ai-core is no project harness
  [ -d "$dir/.git" ] || continue
  name="$(basename "$dir")"
  [ -z "$ONLY" ] || [ "$name" = "$ONLY" ] || continue
  seen=$((seen + 1))
  origin="$(git -C "$dir" remote get-url origin 2>/dev/null)" || { echo "$name: no origin, not pushed ($dir)"; continue; }
  origin="$(printf '%s' "$origin" | sed 's|.*github.com[:/]||; s|\.git$||')"
  # 1. commit what changed
  changed="$(git -C "$dir" status --porcelain | tr -d '\r')"
  if [ -n "$changed" ]; then
    count="$(printf '%s\n' "$changed" | grep -c .)"
    msg="$MESSAGE"
    if [ -z "$msg" ]; then
      msg="$(printf '%s\n' "$changed" | sed 's/^...//' | head -3 | paste -sd, - | sed 's/,/, /g')"
      [ "$count" -le 3 ] || msg="$msg (+$((count - 3)))"
    fi
    git -C "$dir" add -A
    # The push gate wants an issue or a reason: the message is the reason, and the trailer says
    # who committed it, unless the message names an issue or carries a trailer of its own
    trailer=()
    case "$msg" in *'#'[0-9]*|*'No-issue:'*) ;; *) trailer=(-m "No-issue: ${msg%%$'\n'*}, committed and pushed by ai-core push") ;; esac
    if ! git -C "$dir" commit -q -m "$msg" ${trailer[@]+"${trailer[@]}"}; then failed="$failed $name"; echo "$name: commit failed"; continue; fi
    echo "$name: committed $count file(s): $msg"
  fi
  # 2. push what is ahead of origin, after taking what colleagues pushed
  ahead="$(git -C "$dir" rev-list --count '@{upstream}..HEAD' 2>/dev/null || echo 1)"
  if [ "$ahead" -gt 0 ]; then
    git -C "$dir" pull --rebase --quiet 2>/dev/null || true
    if git -C "$dir" push --quiet -u origin HEAD; then
      echo "$name: pushed to $origin"; pushed=$((pushed + 1))
    else
      failed="$failed $name"; echo "$name: push failed; see above"
    fi
  else
    echo "$name: nothing to push"
  fi
done
[ "$seen" -gt 0 ] || { echo "push: no project harness clone under $FOLDER${ONLY:+ named $ONLY}"; exit 1; }
[ -z "$failed" ] || { echo "push: failed:$failed" >&2; exit 1; }

# 3. this checkout is current at once
if [ -d ".ai-core" ] && [ "$pushed" -gt 0 ]; then
  echo "--> Refreshing this checkout"
  if bash "$CORE/bin/init.sh" . --no-doctor > /dev/null 2>&1; then echo "--> This checkout is current"; else echo "note: init here reported a problem; run ai-core init to see it"; fi
fi
