#!/usr/bin/env bash
# Move each card to the state its git signals PROVE it has reached, so the board stops
# trailing reality because a person forgot to move a card.
#
#   status-sync.sh [--project N] [--dry-run] [OWNER/REPO ...]
#
# It reads only facts and moves FORWARD only. The signals, in order:
#   - a commit naming the issue is on master        -> testing
#   - that commit is carried by the newest tag      -> closed + done
#
# WHY THERE IS NO PULL-REQUEST SIGNAL. Work stays on master here: an issue is worked in a
# worktree on a temporary branch, and that branch is a place to commit, not a statement that
# anything is finished. An open worktree therefore proves nothing and is not read. What proves
# the work exists is the commit landing on master, which is what the push hook lets through, and
# what proves it shipped is a tag carrying that commit. A release here is a tag, because these
# repositories tag rather than cut a GitHub release; whether that tag actually deployed is the
# pipeline's to alarm on, not the board's.
#
# The card is put in `implementing` by start-issue, at the moment the worktree is opened, so
# that column is a person's statement and this sweep never writes it. It never moves a card
# BACKWARD, so a state a person set by hand stands, and it never touches an EPIC - an epic
# carries no work and closes with its last sub-issue by a different rule. Nothing is guessed: a
# card only moves on a signal.
#
# --dry-run prints what it would do and writes nothing. Default is to apply, because the whole
# point is that no person has to run it.
#
# It does not WRITE the board itself: it calls issue-status and issue-close, the movers that
# already handle every board a card is on. One writer, one set of rules.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/board.sh"

# --- the decision, kept pure so a test can drive it without a board ------------

status_rank() {  # backlog/todo < implementing < testing < done
  case "$1" in
    implementing) echo 1 ;;
    testing) echo 2 ;;
    done|CLOSE) echo 3 ;;
    *) echo 0 ;;
  esac
}

# derive_target <current> <on_master 0|1> <released 0|1> <is_epic 0|1>
# Echoes the state to move TO - testing or CLOSE - or nothing when the card is already at or
# past what its signals prove, or is an epic.
derive_target() {
  local cur="$1" om="$2" rel="$3" epic="$4" t=""
  [ "$epic" = "1" ] && { echo ""; return; }
  if [ "$om" = "1" ] && [ "$rel" = "1" ]; then t="CLOSE"
  elif [ "$om" = "1" ]; then t="testing"
  else echo ""; return; fi
  [ "$(status_rank "$t")" -gt "$(status_rank "$cur")" ] || t=""
  echo "$t"
}

# When sourced by a test, stop here: the functions are defined, the sweep does not run.
[ "${BASH_SOURCE[0]}" != "${0:-}" ] && return 0

# --- reads about a repo, memoised for the run --------------------------------

# The memo is a string of "<key>\t<value>" lines and not an associative array: bash 3.2 has no
# associative arrays, and this half of the pair runs on macOS too.
#
# IT IS FILLED IN THE SWEEP LOOP AND NOT INSIDE THE TWO READERS BELOW. A reader is called as
# `$( … )`, which runs it in a subshell, and a variable set in a subshell is gone the moment it
# ends. Written there, the memo answered nothing and every card on a board re-read the same
# default branch and the same tag list.
_MEMO=''
memo_get() {  # memo_get <key> - prints the value, or nothing when the key is not held
  printf '%s\n' "$_MEMO" | awk -F'\t' -v k="$1" '$1 == k { print $2; found = 1; exit } END { exit (found ? 0 : 1) }'
}
memo_set() { _MEMO="${_MEMO}$1"$'\t'"$2"$'\n'; }

default_branch() {  # <owner/repo>
  gh_read "the default branch of $1" api "repos/$1" --jq '.default_branch' || exit 1
}
latest_tag() {  # <owner/repo> - newest tag, or empty when the repo has none
  gh_read "the tags of $1" api "repos/$1/tags" --jq '.[0].name // empty' || exit 1
}

# 1 when <sha> is contained in <ref>, else 0. `compare/REF...SHA` answers `behind` when the sha
# is an ancestor of the ref and `identical` when they are the same commit; both mean the ref
# carries it. One helper for two questions - is it on master, and is it in the newest tag -
# because a second implementation of "does this ref carry this commit" is a second answer.
contained_in() {  # contained_in <owner/repo> <ref> <sha>
  local repo="$1" ref="$2" sha="$3" st
  [ -n "$sha" ] && [ "$sha" != '-' ] || { echo 0; return; }
  [ -n "$ref" ] && [ "$ref" != '-' ] || { echo 0; return; }
  st="$(gh api "repos/$repo/compare/$ref...$sha" --jq '.status' 2>/dev/null)"
  case "$st" in behind|identical) echo 1 ;; *) echo 0 ;; esac
}

# Every signal about one issue, on one line:
#   <state>\t<sub-issue total>\t<newest referencing commit sha or ->
#
# A commit that names the issue leaves a REFERENCED_EVENT on it, whichever branch it was made
# on, so whether that commit is on master is a second question and is asked of the repository.
# Only commits in the issue's OWN repository count: a commit elsewhere naming #12 is about
# whatever #12 is there.
signals_for() {  # <owner/repo> <number>
  local repo="$1" n="$2" o="${1%%/*}" name="${1#*/}" json
  json="$(gh_read "the signals of $repo#$n" api graphql -f o="$o" -f n="$name" -F num="$n" -f query='
    query($o:String!,$n:String!,$num:Int!){ repository(owner:$o,name:$n){ issue(number:$num){
      state subIssuesSummary{ total }
      reopened: timelineItems(last:1, itemTypes:[REOPENED_EVENT]){ nodes{ ... on ReopenedEvent{ createdAt } } }
      timelineItems(last:60, itemTypes:[REFERENCED_EVENT]){ nodes{ ... on ReferencedEvent{
        createdAt isCrossRepository commit{ oid committedDate } } } } } } }')" || exit 1
  # A commit only counts if it landed AFTER the issue was last reopened: a ticket reopened for
  # rework still carries the reference of the commit that closed it the first time, and reading
  # that as work would push the rework to testing every half hour, forever.
  printf '%s' "$json" | jq -r '
    .data.repository.issue as $i
    | (($i.reopened.nodes[0].createdAt) // "") as $reopenedAt
    | ([ $i.timelineItems.nodes[]
         | select(.commit != null and .isCrossRepository == false)
         | select($reopenedAt == "" or (.createdAt > $reopenedAt)) ]) as $refs
    | ($i.state) as $state
    | ($i.subIssuesSummary.total // 0) as $subs
    | (($refs | sort_by(.commit.committedDate) | last | .commit.oid) // "-") as $sha
    | "\($state)\t\($subs)\t\($sha)"' | tr -d '\r'
}

# --- the sweep ----------------------------------------------------------------

project=""; dry=0; args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --project) need_value "$1" "${2-}"; project="$2"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    -*)        die "unknown argument '$1'" ;;
    *)         args+=("$1"); shift ;;
  esac
done
set -- ${args[@]+"${args[@]}"}

set_project "$project" >/dev/null
resolved="$(project_number)"

# The board is read whole first. A refused query reaching the loop would come out as a board
# with no cards, and the run would end with "0 active cards scanned" - which is an answer about
# the board, and the board never answered.
cards="$("$ROOT/bin/board-list.sh" --project "$resolved")" || exit 1

# Every active card on this board - status, repo, number. board-list is column-ordered status,
# priority, repo, number, title; a done card is a closed issue and is skipped.
moved=0; scanned=0
while read -r st prio repo num rest; do
  num="${num#\#}"                             # board-list prints the number as #NNN
  [ -n "$num" ] || continue
  case "$st" in done|"") continue ;; esac
  # Only repos on THIS board, and only the named ones when the caller named some.
  if [ $# -gt 0 ]; then
    keep=0; for want in "$@"; do [ "$repo" = "$want" ] || [ "$repo" = "${want#*/}" ] && keep=1; done
    [ "$keep" = 1 ] || continue
  fi
  # board-list prints the short repo name; the movers want owner/repo.
  case "$repo" in */*) full="$repo" ;; *) full="$(project_org)/$repo" ;; esac
  scanned=$((scanned + 1))

  signals="$(signals_for "$full" "$num")" || exit 1
  IFS=$'\t' read -r state subs sha <<< "$signals"
  [ "$state" = "OPEN" ] || continue          # a closed issue is already past every gate
  # An epic with ONE child is a plain issue (rules.md section 8); the sweep names it and, as
  # with every epic, moves nothing.
  [ "$subs" = 1 ] && echo "one child    $repo#$num  (an epic with a single sub-issue is a plain issue, rules.md section 8)"
  epic=$([ "$subs" -gt 0 ] && echo 1 || echo 0)
  branch="$(memo_get "branch:$full")" || { branch="$(default_branch "$full")"; memo_set "branch:$full" "$branch"; }
  on_master="$(contained_in "$full" "$branch" "$sha")"
  rel=0; tag=''
  if [ "$on_master" = "1" ]; then
    tag="$(memo_get "tag:$full")" || { tag="$(latest_tag "$full")"; memo_set "tag:$full" "${tag:--}"; }
    case "$tag" in '-') tag='' ;; esac
    rel="$(contained_in "$full" "$tag" "$sha")"
  fi
  target="$(derive_target "$st" "$on_master" "$rel" "$epic")"
  [ -n "$target" ] || continue

  if [ "$target" = "CLOSE" ]; then
    if [ "$dry" = 1 ]; then echo "would close  $repo#$num  ($st -> done, released in $tag)"
    else echo "close        $repo#$num  ($st -> done, released in $tag)"
      "$ROOT/bin/issue-close.sh" "$full" "$num" >/dev/null; fi
  else
    if [ "$dry" = 1 ]; then echo "would move   $repo#$num  ($st -> $target)"
    else echo "move         $repo#$num  ($st -> $target)"
      "$ROOT/bin/issue-status.sh" "$full" "$num" "$target" >/dev/null; fi
  fi
  moved=$((moved + 1))
done <<< "$cards"

echo
echo "$scanned active cards scanned, $moved $([ "$dry" = 1 ] && echo would move || echo moved) on board $resolved."
