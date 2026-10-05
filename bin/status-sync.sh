#!/usr/bin/env bash
# Move each card to the state its git signals PROVE it has reached, so the board stops
# trailing reality because a person forgot to move a card.
#
#   status-sync.sh [--project N] [--dry-run] [OWNER/REPO ...]
#
# It reads only facts and moves FORWARD only. The signal:
#   - a card in testing whose commit is carried by the newest tag  -> closed + done
# A card reaches testing through finish-issue, which runs after the push that lands the issue. A
# commit that names an issue says that it touches the issue, not that the issue is done: an issue
# whose work lands in several steps carries such commits long before it is.
#
# WHY THERE IS NO PULL-REQUEST SIGNAL. Work stays on master here: an issue is worked in a
# worktree on a temporary branch, and that branch is a place to commit, not a statement that
# anything is finished. An open worktree therefore proves nothing and is not read. What proves
# the work exists is the commit landing on master, which is what the push hook lets through, and
# what proves it shipped is a tag carrying that commit. A release here is a tag, because these
# repositories tag rather than cut a GitHub release; whether that tag actually deployed is the
# pipeline's to alarm on, not the board's.
#
# The card is put in `implementing` by start-issue, at the moment the worktree is opened, and in
# `testing` by finish-issue; both are a session's statement and this sweep writes neither. It
# never moves a card BACKWARD, so a state a person set by hand stands. An EPIC carries no work and has no signals of
# its own: it follows its sub-issues (epic_target in lib/board.sh), so a sub-issue moved by hand
# on the board moves its epic here too. Nothing is guessed: a card only moves on a signal.
#
# --dry-run prints what it would do and writes nothing. Default is to apply, because the whole
# point is that no person has to run it.
#
# It does not WRITE the board itself: it calls issue-status and issue-close, the movers that
# already handle every board a card is on. One writer, one set of rules.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/board.sh"

# --- the decision, kept pure so a test can drive it without a board ------------

# derive_target <current> <on_master 0|1> <released 0|1> <is_epic 0|1>
# Echoes CLOSE for a card finish-issue moved to testing whose commit the newest tag carries, and
# nothing for every other card; an epic follows its sub-issues instead.
derive_target() {
  local cur epic="$4"
  cur="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  [ "$epic" = 1 ] && return 0
  [ "$cur" = testing ] && [ "$2" = 1 ] && [ "$3" = 1 ] && echo CLOSE
  return 0
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
#   <state>\t<sub-issue total>\t<the commit finish-issue landed, or ->
#
# The commit is the first one finish-issue listed in its "Landed on <branch>:" comment, the
# record it writes when it moves the card to testing. GitHub's REFERENCED_EVENT is not read: it is
# missing on issues whose commits are on master and in the newest tag.
signals_for() {  # <owner/repo> <number>
  local repo="$1" n="$2" o="${1%%/*}" name="${1#*/}" json
  json="$(gh_read "the signals of $repo#$n" api graphql -f o="$o" -f n="$name" -F num="$n" -f query='
    query($o:String!,$n:String!,$num:Int!){ repository(owner:$o,name:$n){ issue(number:$num){
      state subIssuesSummary{ total }
      reopened: timelineItems(last:1, itemTypes:[REOPENED_EVENT]){ nodes{ ... on ReopenedEvent{ createdAt } } }
      comments(last:50){ nodes{ createdAt body } } } } }')" || exit 1
  # A comment only counts if it came AFTER the issue was last reopened: a ticket reopened for
  # rework still carries the record of the work that closed it the first time.
  printf '%s' "$json" | jq -r '
    .data.repository.issue as $i
    | (($i.reopened.nodes[0].createdAt) // "") as $reopenedAt
    | ([ $i.comments.nodes[]
         | select(.body | startswith("Landed on "))
         | select($reopenedAt == "" or (.createdAt > $reopenedAt)) ] | sort_by(.createdAt) | last) as $landed
    | (($landed.body // "") | split("\n") | map(select(test("^- [0-9a-f]{7,40} "))) | first
       | if . then (split(" ")[1]) else "-" end) as $sha
    | "\($i.state)\t\($i.subIssuesSummary.total // 0)\t\($sha)"' | tr -d '\r'
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
  # An issue with sub-issues is an epic whatever their number, and follows them. One with a single
  # sub-issue is named: it is often an issue with work of its own and one dependency hung under
  # it, and closing it with that sub-issue would close the unfinished work.
  [ "$subs" = 1 ] && echo "one child    $repo#$num  (its state follows its one sub-issue; work of its own belongs in a sub-issue of its own, or it is closed with that sub-issue)"
  epic=$([ "$subs" -gt 0 ] && echo 1 || echo 0)
  branch="$(memo_get "branch:$full")" || { branch="$(default_branch "$full")"; memo_set "branch:$full" "$branch"; }
  on_master="$(contained_in "$full" "$branch" "$sha")"
  rel=0; tag=''
  if [ "$on_master" = "1" ]; then
    tag="$(memo_get "tag:$full")" || { tag="$(latest_tag "$full")"; memo_set "tag:$full" "${tag:--}"; }
    case "$tag" in '-') tag='' ;; esac
    rel="$(contained_in "$full" "$tag" "$sha")"
  fi
  if [ "$epic" = 1 ]; then target="$(epic_target_on_board "$full" "$num")" || exit 1; tag=''
  else target="$(derive_target "$st" "$on_master" "$rel" "$epic")"; fi
  [ -n "$target" ] || continue

  if [ "$target" = "CLOSE" ]; then
    why="released in $tag"; [ "$epic" = 1 ] && why="every sub-issue done"
    if [ "$dry" = 1 ]; then echo "would close  $repo#$num  ($st -> done, $why)"
    else echo "close        $repo#$num  ($st -> done, $why)"
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
