#!/usr/bin/env bash
# Cut a release of setup-ai-core: the tag vX.Y.Z on the commit checked out, pushed to origin.
# For whoever maintains setup-ai-core, run in its clone. install and update follow the newest
# tag, so what is not tagged reaches nobody.
#
#   release.sh <version>
#
# A release is cut only when VERSION carries the version, the tree is clean, the commit is on
# the default branch and pushed, and the checks were green on both runners for exactly this
# commit (gh run list). Whatever is missing is named, and nothing is tagged.
set -uo pipefail

for arg in "$@"; do
  if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
    echo "Usage: release.sh <version>"
    echo ""
    echo "Tags the commit checked out in this clone of setup-ai-core as v<version> and pushes the tag."
    echo "Refuses, naming what is missing, unless VERSION carries <version>, the tree is clean, the commit"
    echo "is on the default branch and pushed, and the checks were green on both runners for this commit."
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

have="$(tr -d '\r\n' < "$CORE/VERSION")"
[ "$have" = "$version" ] || refuse "VERSION carries $have, not $version; a release carries the version the file says"
[ -z "$(git -C "$CORE" status --porcelain)" ] || refuse "the tree is not clean; commit or stash first"
branch="$(git -C "$CORE" symbolic-ref --short -q HEAD)" || refuse "not on a branch; a release is cut on the default branch"
default="$(git -C "$CORE" rev-parse --abbrev-ref origin/HEAD 2>/dev/null | sed 's|^origin/||')"; [ -n "$default" ] || default="$branch"
[ "$branch" = "$default" ] || refuse "on $branch, not on $default"
git -C "$CORE" fetch --quiet --tags origin || refuse "could not reach origin"
sha="$(git -C "$CORE" rev-parse HEAD)"
[ "$(git -C "$CORE" rev-parse "origin/$branch")" = "$sha" ] || refuse "$branch is not pushed, or origin/$branch has moved on; push or pull first"
if git -C "$CORE" rev-parse -q --verify "refs/tags/$tag" >/dev/null 2>&1; then refuse "$tag exists already"; fi

# The checks for exactly this commit, on every runner: one workflow run, completed and green
runs="$(gh run list --commit "$sha" --workflow check --json status,conclusion --limit 5 2>/dev/null)" || refuse "gh could not list the workflow runs of $sha (is gh logged in?)"
[ "$(printf '%s' "$runs" | jq 'length')" -gt 0 ] || refuse "no workflow run for $sha yet; push, let the checks run, then release"
printf '%s' "$runs" | jq -e 'all(.status == "completed")' >/dev/null || refuse "the checks for $sha are still running"
printf '%s' "$runs" | jq -e 'any(.conclusion == "success")' >/dev/null || refuse "the checks for $sha are not green; nothing is released red"

git -C "$CORE" tag -a "$tag" -m "release: $version" || refuse "could not tag"
git -C "$CORE" push --quiet origin "refs/tags/$tag" || { git -C "$CORE" tag -d "$tag" >/dev/null 2>&1; refuse "could not push $tag; the tag is removed again"; }
echo "release: $tag on ${sha:0:7}, pushed; install and update follow it now"
