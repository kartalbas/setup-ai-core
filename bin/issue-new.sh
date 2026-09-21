#!/usr/bin/env bash
# Create an issue and put it on the board in one step - labels, priority, status
# and, where it belongs to an epic, the parent link.
#
#   issue-new --repo OWNER/REPO --title "Do the thing, or what it costs" --body-file PATH \
#             --label type:feature --label area:gate --priority P1 [--status todo] \
#             --asked-by LOGIN --asked-in WHERE \
#             [--parent OWNER/REPO#N|REPO#N|N] [--project [ORG/]N]
#
# THE TITLE CARRIES TWO HALVES: the ACTION, and the STAKE - what is wrong today, or what it
# costs if nobody does it - joined with ", so ", ", or " or a colon. "Add the board-sync
# command" names an artifact and fits twenty other tickets; "Put every new issue on its board,
# or nobody reading the board sees it" says what will be different (rules.md, the issue rules).
# A title outside that shape is REPORTED and the issue is created anyway: whether a title reads
# well is a judgment, and a script cannot make it.
#
# NO ISSUE WITHOUT A PERSON'S YES. --asked-by names the login of whoever said yes and --asked-in
# where they said it; the two are written into the first line of the body, so a ticket nobody
# asked for reads as one on the board. Refusing here is the tool's half of that rule; whether
# the name is true is the person's, and the name on the ticket is what makes a false one visible
# to them.
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
repo=""; title=""; body=""; priority=""; status="todo"; parent=""; project=""
labels=(); assignee=""; asked_by=""; asked_in=""

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)      need_value "$1" "${2-}"; repo="$2";      shift 2 ;;
    --title)     need_value "$1" "${2-}"; title="$2";     shift 2 ;;
    --body-file) need_value "$1" "${2-}"; body="$2";      shift 2 ;;
    --label)     need_value "$1" "${2-}"; labels+=("$2"); shift 2 ;;
    --priority)  need_value "$1" "${2-}"; priority="$2";  shift 2 ;;
    --status)    need_value "$1" "${2-}"; status="$2";    shift 2 ;;
    --parent)    need_value "$1" "${2-}"; parent="$2";    shift 2 ;;
    --assignee)  need_value "$1" "${2-}"; assignee="$2";  shift 2 ;;
    --project)   need_value "$1" "${2-}"; project="$2";   shift 2 ;;
    --asked-by)  need_value "$1" "${2-}"; asked_by="$2";  shift 2 ;;
    --asked-in)  need_value "$1" "${2-}"; asked_in="$2";  shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$repo" ]     || repo="$(default_repo)"
# An explicit --assignee wins; otherwise the repo says who owns its issues.
[ -n "$assignee" ] || assignee="$(assignee_for "$repo")"
set_project "$project" "$repo" >/dev/null
[ -n "$title" ]    || die "--title is required"
[ -n "$body" ]     || die "--body-file is required"
[ -f "$body" ]     || die "no such body file: $body"
[ -n "$priority" ] || die "--priority is required (P0 blocker, P1 high, P2 normal, P3 low, P9 parked)"
[ "${#labels[@]}" -ge 2 ] || die "at least two labels are required: one for the type of work, one for the area"

# No issue without a person's yes (rules.md, the issue rules).
[ -n "$asked_by" ] || die "--asked-by is required: the login of the person who said yes to this issue"
[ -n "$asked_in" ] || die "--asked-in is required: where they said it - the issue thread, the review, or the chat, with its date"
case "$asked_by" in @*) asked_by="${asked_by#@}" ;; esac

# The body is written whole into a temporary file, and the ORIGINAL is left alone: a caller's
# file is theirs, and a command that edits its own input cannot be run twice.
asked="$ASKED_PREFIX$asked_by on $(date +%Y-%m-%d) in $asked_in."
sent="$(mktemp)"
trap 'rm -f "$sent"' EXIT
{ printf '%s\n\n' "$asked"; cat "$body"; } > "$sent"

# Reported, not enforced. Every check above refuses; this one only names what a reader will
# struggle with, and the issue is created either way.
report_title "$title"

# The parent is resolved before anything is created: a reference that resolves nowhere
# stops the run with nothing made, instead of leaving a fresh issue attached to nothing.
parent_repo=""; parent_num=""; parent_id=""; parent_title=""
if [ -n "$parent" ]; then
  row="$(parent_issue "$parent" "$repo")" || exit 1
  IFS=$'\t' read -r parent_repo parent_num parent_id parent_title <<< "$row"
fi

args=(--repo "$repo" --title "$title" --body-file "$sent" --assignee "$assignee")
for l in "${labels[@]}"; do args+=(--label "$l"); done

url="$(gh_read "the new issue in $repo" issue create "${args[@]}")" || exit 1
num="${url##*/}"

item="$(item_id "$repo" "$num")" || exit 1
set_select "$item" Status   "$status"
set_select "$item" Priority "$priority"

# The child id is resolved before the call, not inside it: a failed command substitution
# does not stop the command it stands in, so an id that could not be read would be sent as
# an empty one. The attach goes through the addSubIssue mutation, which takes node ids and
# is not bound to one repository the way the REST sub_issues endpoint is - posting a number
# there reads it in ONE repository, and a parent meant for another silently becomes
# whatever issue carries that number here.
if [ -n "$parent" ]; then
  child="$(issue_node_id "$repo" "$num")" || exit 1
  gh api graphql -f parent="$parent_id" -f child="$child" -f query='
    mutation($parent:ID!, $child:ID!) {
      addSubIssue(input:{issueId:$parent, subIssueId:$child}) { issue { number } } }' >/dev/null
  echo "#$num -> sub-issue of $parent_repo#$parent_num  $parent_title" >&2
fi

echo "$num"
