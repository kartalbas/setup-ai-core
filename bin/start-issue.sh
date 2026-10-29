#!/usr/bin/env bash
# Open the worktree for one issue, move its card, and print what the issue asks for.
#
#   start-issue.sh [OWNER/REPO] NUMBER
#
# The three happen together on purpose. A worktree cut from a stale master carries work nobody
# asked for; a card left in the previous column tells everyone else the work has not started;
# and code written without reading the issue is a change measured against a memory of it. Any
# one of them done alone is often not done.
#
# THE WORK LANDS ON THE DEFAULT BRANCH of origin, with no pull request: after the reviewer's GO,
# `ai-core integrate-issue` merges the branch of the worktree and pushes the merge, and the hook
# decides whether it may go. What this creates
# is a WORKTREE - a second working directory of the same repository - so several issues can be
# open at once without one of them holding the checkout, and so a run of the checks in one is
# not disturbed by an edit in another. The worktree stands OUTSIDE the repository, under
# ../.worktrees/<repo>/, because a worktree committed into the tree it is a worktree of is a
# loop nobody unpicks. Its branch is temporary and carries the worktree's own name; it exists
# so the worktree has somewhere to commit, and it is deleted with the worktree.
#
# It is run from inside the repository the work belongs to. The default branch is READ from
# origin/HEAD and never assumed. Where the issue lives in another repository than the work, it is
# named as OWNER/REPO NUMBER: the worktree is cut here, and the issue's repository is recorded on
# its branch (git config branch.<branch>.issueRepository), where session-start, integrate-issue and
# finish-issue read it.
#
# AN ORIGIN WITH NO BRANCH AT ALL has no default branch to cut from, and the first branch pushed into an empty
# repository becomes its default branch, so the default branch is started before anything else reaches origin: one empty
# commit, "Start <owner>/<repo> (#<number>)", with the empty tree and no parent, so there is nothing to review, is pushed
# as the default branch, named by the HEAD of the checkout (no commit yet), under the mark of a landing, which the push
# gate takes for exactly this commit. The worktree is then cut from origin/<default> as always.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/board.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/layers.sh"
. "$ROOT/lib/landing-check.sh"

BIN="$ROOT/bin"
usage='usage: start-issue.sh [OWNER/REPO] NUMBER'

repo=""
case "$#:${1:-}" in
  2:*/*) repo="$1"; number="$2" ;;
  1:*)   number="$1" ;;
  *)     die "$usage" ;;
esac
case "$number" in ''|*[!0-9]*) die "the issue number must be numeric, not '$number' - $usage" ;; esac

git rev-parse --show-toplevel >/dev/null 2>&1 \
  || die 'not inside a git working copy - run this from the repository the work belongs to'

# No worktree without the team modes, for the same reason session-start refuses without
# them: the rules say no work starts, and a worktree is where work starts.
if ! modes="$(bash "$BIN/team-modes-check.sh" 2>&1)"; then
  printf '%s\n' "$modes" >&2
  die 'the team modes are missing - the lines above say which and how to install them'
fi

# Everything below is measured against what origin has right now, so the refs come first.
said="$(git fetch origin 2>&1)" \
  || die "could not reach origin: $said - fix the connection first, this worktree is cut from what origin has"

# An origin with no branch at all has nothing to cut from: its default branch is started below, with a start commit made
# here, which no ref holds until then. Its name is the one the HEAD of this clone names.
empty=""
if origin_is_empty; then
  empty=1
  default="$(unborn_default_branch)" || exit 1
  origin_tip="$(make_start_commit "$(issue_ref "$repo" "$number")")" || exit 1
else
  default="$(origin_default_branch)" || exit 1
  origin_tip="$(git rev-parse -q --verify "refs/remotes/origin/$default^{commit}")" \
    || die "origin has no branch $default to cut the worktree from"
fi

# The worktree is cut from origin, so the state of the checkout this runs in reaches it in no way.
# That checkout is somebody's working copy: it is measured here, read-only, and named after the
# worktree exists; it is never pulled, cleaned or switched.
changes="$(GIT_OPTIONAL_LOCKS=0 git status --porcelain --untracked-files=all)" \
  || die "cannot read the status of the checkout, so its state cannot be named - fix that first"
state=""
if source_head="$(git rev-parse -q --verify 'HEAD^{commit}')"; then
  counts="$(git rev-list --left-right --count "$source_head...$origin_tip")" \
    || die "cannot compare the checkout's HEAD with origin/$default"
  read -r ahead behind <<< "$counts"
  if [ "$behind" -gt 0 ] && [ "$ahead" -gt 0 ]; then
    state="is $behind commit(s) behind and $ahead commit(s) ahead of origin/$default"
  elif [ "$behind" -gt 0 ]; then
    state="is $behind commit(s) behind origin/$default"
  elif [ "$ahead" -gt 0 ]; then
    state="is $ahead commit(s) ahead of origin/$default"
  fi
else
  unborn_ref="$(git symbolic-ref -q HEAD)" && ! git rev-parse -q --verify "$unborn_ref" >/dev/null \
    || die "cannot read the checkout's HEAD, so its state cannot be named"
  state="has no commit yet"
fi
[ -z "$changes" ] || state="has changes${state:+, $state}"
if branch="$(git symbolic-ref -q --short HEAD)"; then
  position="branch $branch"
else
  position="detached HEAD at $(git rev-parse --short HEAD)"
fi

# No worktree without an issue: the title is what it is named after, and the thread is what the
# change will be measured against.
thread="$(apart "$BIN/issue-thread.sh" ${repo:+"$repo"} "$number" --json)" \
  || die "no worktree without an issue - the issue could not be read: $thread"
title="$(printf '%s' "$thread" | jq -r '.title // ""')"
[ -n "$(printf '%s' "$title" | tr -d '[:space:]')" ] \
  || die "issue $number has no title, so no worktree name can be built from it"

# Only an issue assigned to you is taken up (rules.md, the issue rules): the worktree is not cut
# for somebody else's issue, and not for one nobody has been given yet.
mine="$("$BIN/issue-mine.sh" ${repo:+"$repo"} "$number" 2>&1)" || die "$mine"

name="$(issue_branch_name "$number" "$title")"

# Where the worktrees stand: beside the CHECKOUT, never inside it, and grouped per repository so
# two repositories working the same issue number do not collide.
container="$(worktree_container)" || die "the folder for the worktrees could not be found"
path="$container/$name"

# A branch whose every commit is on the default branch has landed: finish-issue removed its
# worktree, or a cleanup kept only the branch, and the next step of the same issue starts afresh.
# A branch with work the default branch lacks, or a local one a worktree has checked out, where
# somebody may be about to commit, is somebody's work.
checked_out="$(git worktree list --porcelain 2>/dev/null | sed -n 's|^branch refs/heads/||p')"
# A branch named by the number is this issue's unless the repository recorded on it, or the checkout's own where
# it records none, is another one than the issue's.
owners="$(issue_branch_owners "$repo" "$name" "$number")" || exit 1
taken=""; clash=""
while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  # a ref the table does not list, such as a branch of another folder that merely contains the name, is this issue's as before
  foreign="$(awk -F'\t' -v b="${ref#origin/}" '$1 == b { print $2; exit }' <<< "$owners")"
  # A landed local branch of another issue under the new name stops the run too: git branch -f would move it
  # and keep its reflog, which still dates the branch to that issue.
  idle=""
  if git merge-base --is-ancestor "$ref" "$origin_tip"; then
    case "$ref" in origin/*) continue ;; esac
    if ! grep -qxF "$ref" <<< "$checked_out"; then
      [ -n "$foreign" ] && [ "$ref" = "$name" ] || continue
      idle=1
    fi
  fi
  if [ -z "$foreign" ]; then taken="$taken$ref"$'\n'
  elif [ "${ref#origin/}" = "$name" ]; then
    whose="$foreign"
    [ -z "$idle" ] || whose="$whose; it has landed and no worktree has it checked out: git branch -d $ref deletes it"
    clash="$clash$ref ($whose)"$'\n'
  fi
done <<< "$(git for-each-ref --format='%(refname:short)' refs/heads refs/remotes/origin 2>/dev/null \
  | grep -E "(^|/)issue-$number(-|$)" || true)"
[ -z "$taken" ] \
  || die "a branch for this issue exists already: $(printf '%s' "$taken" | paste -sd, - | sed 's/,/, /g') - use its worktree instead"
[ -z "$clash" ] \
  || die "the name $name is the name of a branch of another issue already: $(printf '%s' "$clash" | paste -sd, - | sed 's/,/, /g') - cutting the worktree would move that branch; finish its issue first"
[ ! -e "$path" ] || die "$path is already there - use it, or remove it with 'git worktree remove'"

# push_start_commit <commit> <branch>: from a temporary worktree at the commit, because the push gate reads the HEAD it
# runs in and this clone has none yet; with the hooks of this clone by their absolute path, because git looks for a relative
# core.hooksPath in the tree it pushes from, which holds no file
push_start_commit() {
  local tree said hooks status=0
  hooks="$(git rev-parse --path-format=absolute --git-path hooks)" || die "the hooks of this clone cannot be found, so no push gate would judge the start commit"
  mkdir -p "$container" && tree="$(mktemp -d "$container/start-$number.XXXXXX")" \
    || die "no folder for the temporary worktree beside the clone"
  git worktree add -q --detach "$tree" "$1" || { rm -rf "$tree"; die "the temporary worktree for the start commit could not be made (see above)"; }
  with_landing_mark "$tree" "$1" "refs/heads/$2" -- git -C "$tree" -c core.hooksPath="$hooks" push origin "$1:refs/heads/$2" >&2 || status=$?
  git worktree remove --force "$tree" >/dev/null 2>&1 || rm -rf "$tree"
  [ "$status" -eq 0 ] || die "origin did not take the start commit as $2 (see above): nothing was cut, and origin is as it was"
  said="$(git fetch origin 2>&1)" || die "the start commit is on origin as $2, but origin could not be fetched: $said"
  [ "$(git rev-parse -q --verify "refs/remotes/origin/$2^{commit}")" = "$1" ] \
    || die "origin/$2 is not the start commit $1 after the push: another session started it; run start-issue again"
}
if [ -n "$empty" ]; then
  push_start_commit "$origin_tip" "$default"
  echo "Started $default of the empty $(origin_repo) with the start commit $origin_tip."
fi

mkdir -p "$container"
# The worktree starts at the commit measured above, not at whatever origin/$default is by now: a
# fetch into this clone since then must not move it. The branch is made, set to push to and read origin/<its
# own name> (which a plain git push and pre-push in a terminal read: never the default branch, which only a
# landing updates; the remote branch exists after the first push) and, for an issue of another repository, marked with it BEFORE any
# worktree exists. A step that fails then leaves only a branch at a commit of origin that no worktree
# has checked out, and the next run takes it over: a landed local branch is an ancestor of that
# commit, so moving it loses nothing.
other_repo=""
[ "$(issue_ref "$repo" "$number")" = "#$number" ] || other_repo="$repo"
made="$(git branch -f --no-track "$name" "$origin_tip" 2>&1 \
  && git config "branch.$name.remote" origin 2>&1 \
  && git config "branch.$name.merge" "refs/heads/$name" 2>&1 \
  && { [ -z "$other_repo" ] || git config "branch.$name.issueRepository" "$other_repo" 2>&1; } \
  && git worktree add "$path" "$name" 2>&1)" \
  || if [ -e "$path" ]; then
       die "the worktree could not be created cleanly: $made - a worktree stands at $path on $name, at the commit read; use it, or remove it with 'git worktree remove' before running start-issue again"
     else
       die "the worktree could not be created: $made - no worktree stands at $path; run start-issue again once that is fixed"
     fi
echo "Worktree $path on $name, cut from origin/$default."
[ -z "$state" ] || echo "The checkout $(git rev-parse --show-toplevel) ($position) $state. The new worktree starts from origin/$default and does not see that; the checkout's branch, index, files and commits stay as they were."
[ -z "$other_repo" ] || echo "The issue lives in $other_repo: recorded on $name, where session-start, integrate-issue and finish-issue read it."

# The card and the worktree move together, and a card that did not move is said out loud rather
# than left for the next person to notice on the board.
if moved="$("$BIN/issue-status.sh" ${repo:+"$repo"} "$number" implementing 2>&1)"; then
  printf '%s\n' "$moved"
else
  echo "the card did NOT move: $moved - move it before you start" >&2
fi

# Worktrees whose work landed a day ago or more go as this one opens (finish-issue --sweep),
# so the disk does not fill with copies nobody works in any more
bash "$BIN/finish-issue.sh" --sweep 2>&1 | grep ': landed, removed$' || true
# and the cards of this repository and of the issue's whose work a release carries and a proof
# covers close (status-sync)
released_repo="$(resolve_repo "")" && sync_released_cards "$released_repo" ${repo:+"$repo"}

assemble_worktree "$path" "$ROOT" \
  || echo "the harness is NOT complete in the worktree: run 'ai-core init' there before you start" >&2
[ -f "$path/.githooks/pre-push" ] \
  || echo "this worktree carries no push gate (.githooks/pre-push), so the ai-core check before a push is not guaranteed: run 'ai-core pre-push --install' in $(git rev-parse --show-toplevel) first" >&2

"$BIN/issue-thread.sh" ${repo:+"$repo"} "$number" || true
