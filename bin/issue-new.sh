#!/usr/bin/env bash
# Create an issue and put it on the board in one step - labels, priority, status
# and, where it belongs to an epic, the parent link.
#
# Refuses literal email addresses in titles, labels and bodies for public or unknown visibility; reserved example domains
# and GitHub noreply addresses are allowed. Private GitHub repositories bypass the check. Plane
# cannot establish private visibility, so its text receives the public check.
# The check reads the raw text, and an address dressed by Markdown, HTML, invisible or lookalike characters may pass; the README names the cases.
#
#   issue-new --repo OWNER/REPO --title "Do the thing, or what it costs" --body-file PATH \
#             --label type:feature --label area:gate --priority P1 [--status ready] \
#             --asked-by LOGIN --asked-in WHERE | --found-in WHERE \
#             [--parent OWNER/REPO#N|REPO#N|N] [--project [ORG/]N | --no-board]
#
# --no-board files the issue in a repository that is linked to no open board, a harness or the
# tooling's own repository: labels, assignee and parent as always, no card, no status and no
# priority. It is refused where the repository IS linked to a board, and together with
# --project, --priority or --status, which all name the board or a field of it.
#
# THE TITLE CARRIES TWO HALVES: the ACTION, and the STAKE - what is wrong today, or what it
# costs if nobody does it - joined with ", so ", ", or " or a colon. "Add the board-sync
# command" names an artifact and fits twenty other tickets; "Put every new issue on its board,
# or nobody reading the board sees it" says what will be different (rules.md, the issue rules).
# A title outside that shape is REPORTED and the issue is created anyway: whether a title reads
# well is a judgment, and a script cannot make it.
#
# AFTER THE CREATE, A FAILURE STILL EXITS NON-ZERO, AND SAYS THAT THE ISSUE EXISTS. The board, the
# status, the priority and the parent are set after the issue is made; when one of them fails the
# last line names the issue, so a caller does not run the command again and make a duplicate.
#
# NO ISSUE WITHOUT A PERSON'S YES. --asked-by names the login of whoever said yes and --asked-in
# where they said it; the two are written into the first line of the body, so a ticket nobody
# asked for reads as one on the board. Refusing here is the tool's half of that rule; whether
# the name is true is the person's, and the name on the ticket is what makes a false one visible
# to them. A DEFECT A SESSION FOUND, or a sub-issue the issue keeper files under the owner's standing
# decision, takes --found-in instead, naming the session that found it: writing it down is tracking,
# not new work, and any type may take it.
#
# Prints the new issue number on stdout, so it can be captured and reused. When a parent
# is named, the issue the new one was attached to - repository, number and title - is
# reported on stderr, where a capture of the number does not swallow it.
#
# The parent may live in any repository: OWNER/REPO#N and REPO#N name one, and a bare
# number stays an issue of the repository the new issue is created in. It is resolved
# before the issue is created, so a parent that does not exist stops the run with
# nothing made.
#
# The rules require a label for the TYPE of work and one for the AREA it touches,
# plus a priority; this refuses to create an issue that is missing either, because
# an unlabelled ticket is invisible on a board grouped by anything but status.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/board.sh"

# The assignee is deliberately EMPTY here. It is resolved from the repo below, once
# the repo is known — defaulting to @me at parse time is what put every backend issue
# on whoever ran the command.
repo=""; title=""; body=""; priority=""; status="ready"; parent=""; project=""
labels=(); assignee=""; asked_by=""; asked_in=""; found_in=""; no_board=""; status_set=""

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)      need_value "$1" "${2-}"; repo="$2";      shift 2 ;;
    --title)     need_value "$1" "${2-}"; title="$2";     shift 2 ;;
    --body-file) need_value "$1" "${2-}"; body="$2";      shift 2 ;;
    --label)     need_value "$1" "${2-}"; labels+=("$2"); shift 2 ;;
    --priority)  need_value "$1" "${2-}"; priority="$2";  shift 2 ;;
    --status)    need_value "$1" "${2-}"; status="$2"; status_set=1; shift 2 ;;
    --parent)    need_value "$1" "${2-}"; parent="$2";    shift 2 ;;
    --assignee)  need_value "$1" "${2-}"; assignee="$2";  shift 2 ;;
    --project)   need_value "$1" "${2-}"; project="$2";   shift 2 ;;
    --asked-by)  need_value "$1" "${2-}"; asked_by="$2";  shift 2 ;;
    --asked-in)  need_value "$1" "${2-}"; asked_in="$2";  shift 2 ;;
    --found-in)  need_value "$1" "${2-}"; found_in="$2";  shift 2 ;;
    --no-board)  no_board=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$repo" ]     || repo="$(default_repo)"
# An explicit --assignee wins; otherwise the repo says who owns its issues.
[ -n "$assignee" ] || assignee="$(assignee_for "$repo")"
# Without the refusal where a board exists, --no-board is the quiet way to file a ticket that
# no board shows.
if [ -n "$no_board" ]; then
  [ -z "$project" ]    || die "--no-board and --project contradict each other: one says there is no board, the other names one"
  [ -z "$priority" ]   || die "--no-board and --priority contradict each other: the priority is a field of the board, and nothing would record it"
  [ -z "$status_set" ] || die "--no-board and --status contradict each other: the status is a field of the board, and nothing would record it"
  linked="$(repo_open_projects "$repo")" || exit 1
  [ -z "$linked" ]     || die "$repo is linked to an open project, so --no-board would keep this issue off a board that exists - drop the flag"
else
  set_project "$project" "$repo" >/dev/null
fi
[ -n "$title" ]    || die "--title is required"
[ -n "$body" ]     || die "--body-file is required"
[ -f "$body" ]     || die "no such body file: $body"
[ -r "$body" ]     || die "cannot read body file: $body"
[ -n "$no_board" ] || [ -n "$priority" ] || die "--priority is required (P0 blocker, P1 high, P2 normal, P3 low, P9 parked)"
[ "${#labels[@]}" -ge 2 ] || die "at least two labels are required: one for the type of work, one for the area"

# No issue without a person's yes (rules.md, the issue rules), except a defect found in the work.
if [ -n "$found_in" ]; then
  [ -z "$asked_by$asked_in" ] || die "--found-in and --asked-by/--asked-in contradict each other: one says a session found a defect, the other names who said yes - give one"
  asked="$FOUND_PREFIX$found_in on $(date +%Y-%m-%d)$FOUND_TAIL"
else
  [ -n "$asked_by" ] || die "--asked-by is required: the login of the person who said yes to this issue (a finding filed without a yes takes --found-in)"
  [ -n "$asked_in" ] || die "--asked-in is required: where they said it - the issue thread, the review, or the chat, with its date"
  case "$asked_by" in @*) asked_by="${asked_by#@}" ;; esac
  asked="$ASKED_PREFIX$asked_by on $(date +%Y-%m-%d) in $asked_in."
fi

# The body is written whole into a temporary file, and the ORIGINAL is left alone: a caller's
# file is theirs, and a command that edits its own input cannot be run twice.
sent="$(mktemp)" || die "issue-new: cannot create temporary body file"
created=""
finish() {
  local rc=$?
  rm -f "$sent"
  [ "$rc" -eq 0 ] || [ -z "$created" ] || echo "issue-new: issue $repo#$created exists; a step after the create failed, so do not run issue-new again for it" >&2
}
trap finish EXIT
trap 'exit 1' HUP INT TERM
{ printf '%s\n\n' "$asked"; cat "$body"; } > "$sent"

# Reported, not enforced. Every check above refuses; this one only names what a reader will
# struggle with, and the issue is created either way.
report_title "$title" "the issue is created anyway"

# The parent is resolved before anything is created: a reference that resolves nowhere
# stops the run with nothing made, instead of leaving a fresh issue attached to nothing.
parent_repo=""; parent_num=""; parent_id=""; parent_title=""
if [ -n "$parent" ]; then
  row="$(parent_issue "$parent" "$repo")" || exit 1
  IFS=$'\t' read -r parent_repo parent_num parent_id parent_title <<< "$row"
fi

# The status and the priority are resolved before anything is created: a board of an older
# layout has no `ready`, and an issue made first would stand half-made, on the board with no
# status and no priority. README names the field-option-add lines that bring a board to the layout.
if [ -z "$no_board" ]; then
  option_id Status "$status" >/dev/null
  option_id Priority "$priority" >/dev/null
fi

check_public_body issue-new "$repo" "$(printf '%s\n' "$title" "${labels[@]}")" "$sent"
num="$(issue_create "$repo" "$title" "$sent" "$assignee" "${labels[@]}")" || exit 1
created="$num"

if [ -n "$no_board" ]; then
  echo "#$num -> on no board: $repo is linked to none" >&2
else
  item="$(item_id "$repo" "$num")" || exit 1
  set_select "$item" Status   "$status"
  set_select "$item" Priority "$priority"
fi

if [ -n "$parent" ]; then
  subissue_attach_resolved "$parent_id" "$repo" "$num"
  echo "#$num -> sub-issue of $parent_repo#$parent_num  $parent_title" >&2
  update_epic "$parent_repo" "$parent_num" >&2 || exit 1
fi

echo "$num"
