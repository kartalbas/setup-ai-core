#!/usr/bin/env bash
# Update this machine: setup-ai-core to its newest release, and every project harness clone
# (~/.<name>-ai-core) to its origin. Nothing updates by itself; this is the command that does.
#
#   update.sh [--check] [--main]
#
# A release is a tag vX.Y.Z of setup-ai-core, set when the checks are green on both runners
# (ai-core release). install checks out the newest one, and update moves to the newest one; a
# clone with uncommitted changes or commits not pushed is left alone and named. --main follows
# the development branch instead, which is what a clone of somebody working on setup-ai-core
# does. --check fetches and reports, and changes nothing: exit 0 when everything is current,
# 2 when a release or commits are available, 1 when an origin could not be reached.
set -uo pipefail

for arg in "$@"; do
  if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
    echo "Usage: update.sh [--check] [--main]"
    echo ""
    echo "Moves setup-ai-core to its newest release (a tag vX.Y.Z; a clone with uncommitted changes"
    echo "or commits not pushed is left alone and named) and pulls every project harness clone on"
    echo "this machine (~/.<name>-ai-core) from its origin. Nothing updates by itself."
    echo ""
    echo "Options:"
    echo "  --check       Fetch and report only: exit 0 when everything is current, 2 when a release or"
    echo "                commits are available, 1 when an origin could not be reached"
    echo "  --main        Follow the development branch of setup-ai-core instead of its releases"
    echo "  -h, --help    Show this help message"
    echo ""
    echo "Examples:"
    echo "  ai-core update"
    echo "  ai-core update --check"
    exit 0
  fi
done

CORE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK=0; MAIN=0
for arg in "$@"; do
  case "$arg" in
    --check) CHECK=1 ;;
    --main) MAIN=1 ;;
    *) echo "error: unknown option '$arg' (see --help)" >&2; exit 2 ;;
  esac
done

# A fetch that gives up on a dead line instead of hanging a session start
fetch() { git -C "$1" -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=5 fetch --quiet --tags origin 2>/dev/null; }
newest_release() { git -C "$1" tag --list 'v[0-9]*' --sort=-v:refname 2>/dev/null | head -n1; }
release_of() { git -C "$1" describe --tags --exact-match HEAD 2>/dev/null || true; }   # the tag HEAD stands on, or nothing
branch_of() { git -C "$1" symbolic-ref --short -q HEAD 2>/dev/null || true; }          # the branch, or nothing when detached
behind_by() { git -C "$1" rev-list --count "HEAD..origin/$2" 2>/dev/null || echo 0; }

status=0   # what --check answers
# --- setup-ai-core ------------------------------------------------------------------------------
branch="$(branch_of "$CORE")"; here="$(release_of "$CORE")"
if ! fetch "$CORE"; then
  echo "setup-ai-core: could not reach origin"; status=1
else
  newest="$(newest_release "$CORE")"
  if [ "$CHECK" -eq 1 ]; then
    if [ -n "$branch" ]; then
      n="$(behind_by "$CORE" "$branch")"
      if [ "$n" -gt 0 ]; then echo "setup-ai-core: follows $branch, behind by $n commit(s)"; status=2; else echo "setup-ai-core: follows $branch, current"; fi
      [ -n "$newest" ] && [ "$newest" != "$here" ] && echo "setup-ai-core: the newest release is $newest (ai-core update moves a clean clone there)"
    elif [ -z "$newest" ]; then
      echo "setup-ai-core: no release yet"
    elif [ "$newest" = "$here" ]; then
      echo "setup-ai-core: current ($here)"
    else
      echo "setup-ai-core: release $newest available (this machine: ${here:-no release})"; status=2
    fi
  else
    dirty="$(git -C "$CORE" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
    ahead=0; [ -n "$branch" ] && ahead="$(git -C "$CORE" rev-list --count "origin/$branch..HEAD" 2>/dev/null || echo 0)"
    if [ "$dirty" -gt 0 ] || [ "$ahead" -gt 0 ]; then
      echo "--> setup-ai-core at $CORE: left alone (${dirty} uncommitted change(s), ${ahead} commit(s) not pushed)"
    elif [ "$MAIN" -eq 1 ] || [ -z "$newest" ]; then
      [ -n "$branch" ] || { git -C "$CORE" checkout --quiet main 2>/dev/null || git -C "$CORE" checkout --quiet master 2>/dev/null; branch="$(branch_of "$CORE")"; }
      git -C "$CORE" pull --quiet --ff-only origin "$branch" && echo "--> setup-ai-core at $CORE: follows $branch$([ -z "$newest" ] && echo " (no release yet)"), pulled" || echo "--> setup-ai-core at $CORE: could not be pulled (see above)"
    elif [ -z "$branch" ] && [ "$newest" = "$here" ]; then
      echo "--> setup-ai-core at $CORE: current, release $here"
    else
      git -C "$CORE" checkout --quiet "$newest" && echo "--> setup-ai-core at $CORE: release $newest (was ${branch:-$here})" || echo "--> setup-ai-core at $CORE: could not move to $newest (see above)"
    fi
  fi
fi

# --- the project harness clones ------------------------------------------------------------
for d in "$HOME"/.*-ai-core; do
  [ -d "$d/.git" ] || continue
  name="$(basename "$d")"; name="${name#.}"
  [ "$name" != setup-ai-core ] || continue   # the clone itself, handled above
  if ! fetch "$d"; then echo "$name: could not reach origin"; status=1; continue; fi
  b="$(branch_of "$d")"; [ -n "$b" ] || b="$(git -C "$d" rev-parse --abbrev-ref origin/HEAD 2>/dev/null | sed 's|^origin/||')"
  if [ "$CHECK" -eq 1 ]; then
    n="$(behind_by "$d" "$b")"
    if [ "$n" -gt 0 ]; then echo "$name: behind by $n commit(s)"; status=2; else echo "$name: current"; fi
  else
    n="$(behind_by "$d" "$b")"
    if [ "$n" -eq 0 ]; then echo "--> $name at $d: current"
    elif git -C "$d" pull --quiet --ff-only origin "$b"; then echo "--> $name at $d: pulled $n commit(s)"
    else echo "--> $name at $d: could not be pulled (see above)"; fi
  fi
done

if [ "$CHECK" -eq 1 ]; then exit "$status"; fi
echo "--> The scripts are current everywhere; run ai-core init in a checkout to bring it to this state"
