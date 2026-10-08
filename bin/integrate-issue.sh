#!/usr/bin/env bash
# Integrate the reviewed branch of one issue into the default branch: a merge commit that names the
# issue and its reviewer, pushed through the gate.
#
#   integrate-issue.sh NUMBER --reviewed-by REVIEWER
#
# Between start-issue and finish-issue. Run it in the worktree of the issue, on its branch, once the
# reviewer gave the GO. It fetches origin, puts the worktree on the newest origin/<default>, merges
# the branch with --no-ff under the issue's title and a 'Reviewed-by: REVIEWER' trailer, pushes
# HEAD:<default> through the gate, and checks the branch out again for finish-issue.
#
# A MERGE COMMIT, NOT A REBASE: the reviewed commits land as they were read, with the shas the
# reviewer saw, and the one new commit carries the issue and the reviewer.
#
# THE REVIEWER IS A NAME GIVEN, NOT A REVIEW PROVEN. Without --reviewed-by this refuses; with it, the
# name goes into the history, where it can be traced, and nothing here can tell whether the review
# took place.
#
# NOTHING IS LEFT HALF DONE. A conflict aborts the merge, a branch already in the default branch has
# nothing to integrate, and a push the gate refuses reaches nothing; each time the branch is checked
# out again and the cause is named.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/board.sh"

BIN="$ROOT/bin"
usage='usage: integrate-issue.sh NUMBER --reviewed-by REVIEWER'

number=""; reviewer=""
while [ $# -gt 0 ]; do
  case "$1" in
    --reviewed-by)   [ $# -ge 2 ] || die "--reviewed-by takes the reviewer's name - $usage"; reviewer="$2"; shift ;;
    --reviewed-by=*) reviewer="${1#--reviewed-by=}" ;;
    -*)              die "unknown argument '$1' - $usage" ;;
    *)               [ -z "$number" ] || die "$usage"; number="$1" ;;
  esac
  shift
done
case "$number" in ''|*[!0-9]*) die "the issue number must be numeric, not '$number' - $usage" ;; esac
[ -n "${reviewer//[[:space:]]/}" ] || die "who reviewed the work? --reviewed-by names the reviewer whose GO this integrates - $usage"
case "$reviewer" in *$'\n'*) die "--reviewed-by takes one line" ;; esac

git rev-parse --show-toplevel >/dev/null 2>&1 \
  || die "not inside a git working copy - run this in the worktree of issue $number"
branch="$(git symbolic-ref --short -q HEAD)" || branch=""
case "$branch" in
  "issue-$number"|"issue-$number-"*) ;;
  *) die "this runs in the worktree of issue $number, on its branch issue-$number-*; here ${branch:-no branch} is checked out" ;;
esac
[ -z "$(git status --porcelain)" ] \
  || die "the worktree has changes - commit them for the review, or put them aside, then run this again"

title="$("$BIN/issue-thread.sh" "$number" --json 2>&1)" || die "the issue could not be read: $title"
title="$(printf '%s' "$title" | jq -r '.title // ""')"
subject="$title (#$number)"
[ -n "$title" ] && [ "${#subject}" -le 72 ] || subject="Merge $branch (#$number)"

said="$(git fetch origin 2>&1)" || die "could not reach origin: $said"
default="$(origin_default_branch)" || exit 1

# back_to_branch <reason>: the worktree goes back to the branch it was on, and the run stops
back_to_branch() {
  git switch -q "$branch" 2>/dev/null || echo "error: the branch $branch could not be checked out again - run git switch $branch" >&2
  die "$1"
}

[ -n "$(git rev-list -n1 "$branch" --not "origin/$default")" ] \
  || die "nothing to integrate: $branch is in origin/$default already"
git switch -q --detach "origin/$default" || die "the worktree could not be put on origin/$default (see above)"
if ! git merge -q --no-ff --no-edit "$branch" -m "$subject" -m "Reviewed-by: $reviewer"; then
  git merge --abort 2>/dev/null
  back_to_branch "$branch does not merge cleanly into origin/$default - bring origin/$default into the branch, get the review of the result, then run this again"
fi
merged="$(git rev-parse --short HEAD)"
git push origin "HEAD:$default" \
  || back_to_branch "the push was refused (see above) - nothing reached origin, and $branch is checked out again"
git switch -q "$branch" || die "$merged is on origin/$default, but $branch could not be checked out again - run git switch $branch before finish-issue"
echo "integrated: $merged on origin/$default, $subject, Reviewed-by: $reviewer"
echo "next: ai-core finish-issue $number"
