#!/usr/bin/env bash
# Put every issue of every linked repo on the one board, and report what that changed.
#
#   board-sync.sh                  every repo linked to the project
#   board-sync.sh OWNER/REPO ...   named repos only
#   board-sync.sh --project 5      pick the project rather than resolving it from the repo
#
# Adding an item twice is harmless, so this can be run as often as you like - it is the
# sweep that catches an issue somebody created straight on github.com, which otherwise
# exists but is invisible on the board.
#
# It never sets a value itself. What is missing is reported, because a status or a
# priority guessed by a script is a lie the board then tells everyone.
#
# GitHub does set one, though: the project's built-in workflow stamps a Status on every
# item AS IT IS ADDED - typically Todo for an open issue and Done for a closed one. That
# is why the newly added items are listed separately below. They have a status nobody
# chose, and a sweep that did not say so would quietly fill the Todo column with old
# work the next morning.
#
# AN OPEN TICKET MISSING A LABEL AND A CLOSED ONE ARE NOT THE SAME REPORT, and one number
# over both hides the first. Measured over all eleven repositories on 2026-08-26: 20 issues are
# open and 5 of them are missing a type or an area; 430 are closed and 104 of them are.
# Read as one figure of 109 that is a backlog nobody will ever work off, and the five
# that can be fixed this afternoon disappear into it. So the open ones are listed one by
# one, because somebody is going to pick each of them up and label it as they do, and the
# closed ones are counted, because a label put on a finished ticket by somebody who did
# not write it is a guess - and this tool reports rather than guesses.
#
# THE PRIORITY REPORT SPLITS THE SAME WAY, and the split has to be made here rather than
# left to the reader. Measured with board-list across both boards on 2026-08-26: five cards
# carry no priority and every one of them is CLOSED. Printed as the single figure "5" that
# reads as five tickets waiting to be prioritised; split, it is five finished tickets nobody
# should guess a value for and not one open ticket anybody can act on.
#
# EVERY COUNT HERE STANDS BESIDE WHAT IT WAS COUNTED OUT OF. "5 missing" cannot be told
# apart from a board of six cards or a board of six hundred, and it cannot be told apart
# from a run that read nothing - which is what a refused query looks like from outside.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/board.sh"

project=""
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --project) need_value "$1" "${2-}"; project="$2"; shift 2 ;;
    -*)        die "unknown argument '$1'" ;;
    *)         args+=("$1"); shift ;;
  esac
done
set -- "${args[@]}"

# Called directly and NOT in a command substitution. `set_project` writes the number into PROJECT,
# and a substitution runs it in a subshell — the number would come back on stdout while every later
# `project_number` in this process still found PROJECT empty and died.
set_project "$project" >/dev/null
resolved="$(project_number)"

# The list is read into a variable BEFORE it is split into lines. A process substitution reports
# nothing about how the command inside it ended, so a refused query arrives here as a repo list of
# length zero and the sweep below runs to the end and reports that nothing was missing.
if [ $# -eq 0 ]; then
  linked="$(project_repos)" || exit 1
  repos=()
  while IFS= read -r repo || [ -n "$repo" ]; do
    [ -n "$repo" ] && repos+=("$repo")
  done <<< "$linked"
else
  repos=("$@")
fi

types="$(label_names_in_group type)" || exit 1
areas="$(label_names_in_group area)" || exit 1

before="$(mktemp)"; after="$(mktemp)"
trap 'rm -f "$before" "$after"' EXIT

# board-list.sh runs as its own process and resolves its own project from scratch -
# pass the number down explicitly rather than letting it re-resolve and risk landing
# on a different project than the one being synced.
"$ROOT/bin/board-list.sh" --project "$resolved" > "$before"

open_issues=0
closed_issues=0
open_gaps=0
closed_gaps=0
for repo in "${repos[@]}"; do
  echo "$repo"
  # Same reason as the repo list above: the issues are read whole, so a refused query stops the
  # sweep instead of reading as a repo that has no issues.
  #
  # The title stands LAST because it is the one field a person types: a tab inside it would take
  # the column after it, and there is none after the last.
  issues="$(gh_read "the issues of $repo" issue list --repo "$repo" --state all --limit 500 \
             --json number,state,title,labels \
             --jq '.[] | "\(.number)\t\(.state)\t\([.labels[].name] | join(","))\t\(.title)"')" || exit 1
  while IFS=$'\t' read -r num state labels title; do
    [ -n "$num" ] || continue
    item_id "$repo" "$num" >/dev/null

    if [ "$state" = OPEN ]; then open_issues=$((open_issues + 1)); else closed_issues=$((closed_issues + 1)); fi

    missing=""
    grep -qxF -f <(echo "$types") <<< "${labels//,/$'\n'}" || missing="type"
    grep -qxF -f <(echo "$areas") <<< "${labels//,/$'\n'}" || missing="$missing area"
    [ -n "$missing" ] || continue
    if [ "$state" = OPEN ]; then
      printf '  #%-4s missing label: %-12s %s\n' "$num" "$missing" "$title"
      open_gaps=$((open_gaps + 1))
    else
      closed_gaps=$((closed_gaps + 1))
    fi
  done <<< "$issues"
done

# READ ONCE, AND EVERY FIGURE BELOW COMES OUT OF THESE LINES. A colleague can move a card while
# the sweep runs, so a second read for the priority report would answer about a board the added
# items above were never counted against, with nothing on the screen saying so.
"$ROOT/bin/board-list.sh" --project "$resolved" > "$after"

# board-list renders one card per line as "<status> <priority> <repo> #<number> <title>", and a
# closed one ends in "[closed]". That is the whole shape the counts below read.
cards="$(awk                                                        'END { print NR    }' "$after")"
open_cards="$(awk       '$0 !~ /\[closed\]$/              { n++ }   END { print n + 0 }' "$after")"
closed_cards="$(awk     '$0 ~  /\[closed\]$/              { n++ }   END { print n + 0 }' "$after")"
open_no_prio="$(awk     '$2 == "-" && $0 !~ /\[closed\]$/'                               "$after")"
open_no_prio_n="$(awk   '$2 == "-" && $0 !~ /\[closed\]$/ { n++ }   END { print n + 0 }' "$after")"
closed_no_prio_n="$(awk '$2 == "-" && $0 ~  /\[closed\]$/ { n++ }   END { print n + 0 }' "$after")"

echo
echo "$open_gaps of $open_issues OPEN issues are missing a type or an area label, listed above"
echo "$closed_gaps of $closed_issues closed issues are missing one too, and are not listed -"
echo "  labelling somebody else's finished ticket is a guess, and nothing on the board filters on it"

# A card is matched on its repo and its number, never on its whole line. The status and the
# priority columns can differ between the two reads - GitHub stamps a status onto an item as it
# is added, and a colleague can move a card while the sweep runs - so a whole-line comparison
# would report a card that was on the board all along as one that had just arrived.
added="$(awk 'NR == FNR { was[$3 " " $4] = 1; next } !was[$3 " " $4]' "$before" "$after")"
added_count="$(printf '%s' "$added" | awk 'END { print NR }')"
if [ "$added_count" -gt 0 ]; then
  echo
  echo "$added_count of the $cards cards on the board were NOT on it before this run."
  echo "GitHub stamped each one with a status as it was added - it is the first word of every"
  echo "line below. Move whatever does not belong there:"
  printf '%s\n' "$added" | sed 's/^/  /'
fi

echo
if [ "$open_no_prio_n" -gt 0 ]; then
  echo "OPEN cards on the board that carry no priority:"
  printf '%s\n' "$open_no_prio" | sed 's/^/  /'
  echo "$open_no_prio_n of $open_cards OPEN cards carry no priority, listed above"
else
  echo "$open_no_prio_n of $open_cards OPEN cards carry no priority"
fi
echo "$closed_no_prio_n of $closed_cards closed cards carry none either, and are not listed -"
echo "  a priority put on a finished ticket by somebody who did not work it is a guess"
