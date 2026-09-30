#!/usr/bin/env bash
# Cut a release of setup-ai-core: the tag vX.Y.Z on the commit VERSION names, pushed to origin.
# For whoever maintains setup-ai-core, run in its clone. install and update follow the newest
# tag, so what is not tagged reaches nobody.
#
#   release.sh <version>
#
# One command does the whole release: VERSION gets the version when it does not carry it yet,
# committed on its own as `release: <version>`; whatever is not pushed goes to origin by ref;
# then the command waits for the check run of that commit (gh run list, every 20 seconds, 30
# minutes at most; AI_CORE_RELEASE_POLL and AI_CORE_RELEASE_WAIT, in seconds, for a suite) and
# tags it when the run is green. It refuses, naming what is missing, when the tree is not clean,
# the branch is not the default branch, origin has moved on, the tag exists, or the checks are
# red or do not finish. Nothing is tagged red.
set -uo pipefail

for arg in "$@"; do
  if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
    echo "Usage: release.sh <version>"
    echo ""
    echo "Releases <version> from this clone of setup-ai-core in one run: writes VERSION and commits"
    echo "'release: <version>' when VERSION does not carry it yet, pushes what is not pushed, waits for"
    echo "the check run of that commit and tags it v<version>, pushed, when the run is green."
    echo "Refuses, naming what is missing, when the tree is not clean, this is not the default branch,"
    echo "origin has moved on, the tag exists, or the checks are red or do not finish in 30 minutes."
    echo ""
    echo "Options:"
    echo "  -h, --help    Show this help message"
    echo ""
    echo "Examples:"
    echo "  ai-core release 1.2.0"
    exit 0
  fi
done

CORE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ $# -eq 1 ] || { echo "error: release takes one argument, the version (see --help)" >&2; exit 2; }
version="$1"
case "$version" in [0-9]*.[0-9]*.[0-9]*) ;; *) echo "error: '$version' is not a version of the form X.Y.Z" >&2; exit 2 ;; esac
tag="v$version"
refuse() { echo "release: REFUSED — $*" >&2; exit 1; }

[ -z "$(git -C "$CORE" status --porcelain)" ] || refuse "the tree is not clean; commit or stash first"
branch="$(git -C "$CORE" symbolic-ref --short -q HEAD)" || refuse "not on a branch; a release is cut on the default branch"
# the origin names its default branch; a clone's origin/HEAD can name one the origin renamed since
default="$(git -C "$CORE" ls-remote --symref origin HEAD 2>/dev/null | awk '$1 == "ref:" && $3 == "HEAD" { sub("^refs/heads/", "", $2); print $2 }')"; [ -n "$default" ] || default="$branch"
[ "$branch" = "$default" ] || refuse "on $branch, not on $default"
git -C "$CORE" fetch --quiet --tags origin || refuse "could not reach origin"
if git -C "$CORE" rev-parse -q --verify "refs/tags/$tag" >/dev/null 2>&1; then refuse "$tag exists already"; fi
if git -C "$CORE" rev-parse -q --verify "origin/$branch" >/dev/null 2>&1; then
  [ "$(git -C "$CORE" rev-list --count "HEAD..origin/$branch")" -eq 0 ] || refuse "origin/$branch has moved on; pull first"
fi

# 1. VERSION carries the version, committed on its own
have="$(tr -d '\r\n' < "$CORE/VERSION")"
if [ "$have" != "$version" ]; then
  printf '%s\n' "$version" > "$CORE/VERSION"
  git -C "$CORE" commit --quiet -m "release: $version" -- VERSION || refuse "could not commit VERSION"
  echo "release: VERSION $have -> $version, committed as 'release: $version'"
fi

# 2. The commit is on origin, with whatever was not pushed before it
sha="$(git -C "$CORE" rev-parse HEAD)"
if [ "$(git -C "$CORE" rev-parse -q --verify "origin/$branch" 2>/dev/null)" != "$sha" ]; then
  git -C "$CORE" push --quiet origin "HEAD:$branch" || refuse "could not push $branch (see above)"
  echo "release: ${sha:0:7} pushed to origin/$branch"
fi

# 3. The checks for exactly this commit, on every runner: one workflow run, completed and green,
#    waited for
#    A query that fails is no answer yet: gh or the network fails once while the checks run on,
#    so only the deadline ends the wait, and it names what gh said last.
poll="${AI_CORE_RELEASE_POLL:-20}"; limit="${AI_CORE_RELEASE_WAIT:-1800}"; deadline=$(( $(date +%s) + limit )); waiting=0
said="$(mktemp)"; trap 'rm -f "$said"' EXIT
while :; do
  if runs="$(gh run list --commit "$sha" --workflow check --json status,conclusion --limit 5 2>"$said")" && [ -n "$runs" ]; then
    failed_query=""
    if [ "$(printf '%s' "$runs" | jq 'length')" -gt 0 ] && printf '%s' "$runs" | jq -e 'all(.status == "completed")' >/dev/null; then break; fi
  else
    failed_query="$(tr -s '\r\n' '  ' < "$said")"; failed_query="${failed_query:-an empty answer}"
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    [ -z "$failed_query" ] || refuse "gh could not list the workflow runs of $sha until the deadline; it said last: ${failed_query% } (is gh logged in?)"
    refuse "the checks for $sha did not finish in $((limit / 60)) minute(s); run 'ai-core release $version' again when they have"
  fi
  [ "$waiting" -eq 1 ] || { echo "release: waiting for the checks of ${sha:0:7} (asked every ${poll}s, $((limit / 60)) minute(s) at most)"; waiting=1; }
  sleep "$poll"
done
printf '%s' "$runs" | jq -e 'any(.conclusion == "success")' >/dev/null || refuse "the checks for $sha are not green; nothing is released red"

# The tag goes on the commit whose checks were waited for, not on whatever HEAD is by now: a
# commit made during the wait was never checked
git -C "$CORE" tag -a "$tag" -m "release: $version" "$sha" || refuse "could not tag"
git -C "$CORE" push --quiet origin "refs/tags/$tag" || { git -C "$CORE" tag -d "$tag" >/dev/null 2>&1; refuse "could not push $tag; the tag is removed again"; }
echo "release: $tag on ${sha:0:7}, pushed; install and update follow it now"
