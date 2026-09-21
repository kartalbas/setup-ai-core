#!/usr/bin/env bash
# Open the worktree for one issue, move its card, and print what the issue asks for.
#
#   start-issue.sh NUMBER
#
# The three happen together on purpose. A worktree cut from a stale master carries work nobody
# asked for; a card left in the previous column tells everyone else the work has not started;
# and code written without reading the issue is a change measured against a memory of it. Any
# one of them done alone is often not done.
#
# WORK STAYS ON master. There is no feature branch and no pull request: the change is pushed
# with `git push origin HEAD:master` and the hook decides whether it may go. What this creates
# is a WORKTREE - a second working directory of the same repository - so several issues can be
# open at once without one of them holding the checkout, and so a run of the checks in one is
# not disturbed by an edit in another. The worktree stands OUTSIDE the repository, under
# ../.worktrees/<repo>/, because a worktree committed into the tree it is a worktree of is a
# loop nobody unpicks. Its branch is temporary and carries the worktree's own name; it exists
# so the worktree has somewhere to commit, and it is deleted with the worktree.
#
# It is run from inside the repository the work belongs to. The default branch is READ from
# origin/HEAD and never assumed.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/board.sh"

BIN="$ROOT/bin"
usage='usage: start-issue.sh NUMBER'

[ $# -eq 1 ] || die "$usage"
number="$1"
case "$number" in ''|*[!0-9]*) die "the issue number must be numeric, not '$number' - $usage" ;; esac

git rev-parse --show-toplevel >/dev/null 2>&1 \
  || die 'not inside a git working copy - run this from the repository the work belongs to'

# No worktree without the three team modes, for the same reason session-start refuses without
# them: the rules say no work starts, and a worktree is where work starts.
if ! modes="$(bash "$BIN/team-modes-check.sh" 2>&1)"; then
  printf '%s\n' "$modes" >&2
  die 'the team modes are missing - the lines above say which and how to install them'
fi

# Everything below is measured against what origin has right now, so the refs come first.
said="$(git fetch origin 2>&1)" \
  || die "could not reach origin: $said - fix the connection first, this worktree is cut from what origin has"

[ -z "$(git status --porcelain)" ] \
  || die 'the working copy has changes - commit or put them aside before opening a worktree'

head_ref="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null || true)"
[ -n "$head_ref" ] \
  || die "cannot read the default branch from origin/HEAD - run 'git remote set-head origin -a', then run this again"
default="${head_ref##refs/remotes/origin/}"

behind="$(git rev-list --count "$default..origin/$default" 2>/dev/null || true)"
[ -n "$behind" ] || die "cannot compare $default with origin/$default - is the remote branch there?"
[ "$behind" -eq 0 ] || die "$default is $behind commit(s) behind origin/$default - pull, then run this again"

# No worktree without an issue: the title is what it is named after, and the thread is what the
# change will be measured against.
thread="$("$BIN/issue-thread.sh" "$number" --json 2>&1)" \
  || die "no worktree without an issue - the issue could not be read: $thread"
title="$(printf '%s' "$thread" | jq -r '.title // ""')"
[ -n "$(printf '%s' "$title" | tr -d '[:space:]')" ] \
  || die "issue $number has no title, so no worktree name can be built from it"

# Only an issue assigned to you is taken up (rules.md, the issue rules): the worktree is not cut
# for somebody else's issue, and not for one nobody has been given yet.
mine="$("$BIN/issue-mine.sh" "$number" 2>&1)" || die "$mine"

# The readable half of the name. Everything that is not a letter or a digit becomes a hyphen,
# runs of hyphens collapse, and the result is cut to forty characters - the name is read in a
# directory listing beside a dozen others, and a whole title carried into it makes that listing
# unreadable.
slug="$(printf '%s' "$title" \
  | tr '[:upper:]' '[:lower:]' \
  | sed -e 's/[^a-z0-9][^a-z0-9]*/-/g' -e 's/^-*//' -e 's/-*$//' \
  | cut -c1-40 | sed -e 's/-*$//')"
name="issue-$number-$slug"

# Where the worktrees stand: beside the CHECKOUT, never inside it, and grouped per repository so
# two repositories working the same issue number do not collide. The main checkout is found
# through --git-common-dir, so this answers the same from inside another worktree.
common="$(git rev-parse --git-common-dir)"
# git's own spelling of that directory, not the shell's. On Windows the two differ - git says
# C:/Users/... where Git Bash says /c/Users/... - and the worktree path is printed for a person
# to open and handed to git in the same breath.
main="$(cd "$common/.." && git rev-parse --show-toplevel)"
repo_folder="${main##*/}"
container="$(dirname "$main")/.worktrees/$repo_folder"
path="$container/$name"

taken="$(git for-each-ref --format='%(refname:short)' refs/heads refs/remotes/origin 2>/dev/null \
  | grep -E "(^|/)issue-$number(-|$)" || true)"
[ -z "$taken" ] \
  || die "a branch for this issue exists already: $(printf '%s' "$taken" | paste -sd', ' -) - use its worktree instead"
[ ! -e "$path" ] || die "$path is already there - use it, or remove it with 'git worktree remove'"

mkdir -p "$container"
made="$(git worktree add -b "$name" "$path" "origin/$default" 2>&1)" \
  || die "the worktree could not be created: $made"
echo "Worktree $path on $name, cut from origin/$default."

# The card and the worktree move together, and a card that did not move is said out loud rather
# than left for the next person to notice on the board.
if moved="$("$BIN/issue-status.sh" "$number" implementing 2>&1)"; then
  printf '%s\n' "$moved"
else
  echo "the card did NOT move: $moved - move it before you start" >&2
fi

# The harness is not in the repository, so the new worktree gets it here: init takes the main
# checkout's own .ai-core data (its config, its local rules, its documents) first, assembles the
# rules and builds the graph. A worktree that starts without them starts without the rules.
bash "$ROOT/bin/init.sh" "$path" --no-doctor \
  || echo "the harness is NOT complete in the worktree: run 'ai-core init' there before you start" >&2

"$BIN/issue-thread.sh" "$number" || true
