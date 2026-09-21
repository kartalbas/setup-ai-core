#!/usr/bin/env bash
# Is this issue assigned to the account this session runs as?
#
#   issue-mine.sh [OWNER/REPO] NUMBER
#
# Exit 0 and one line when the account (gh's login) is among the issue's assignees. Exit 1 with
# a REFUSED line otherwise - an issue assigned to nobody as much as one assigned to somebody
# else. This is the one check behind start-issue and session-start: only an issue assigned to
# you is taken up (rules.md, the issue rules).

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/board.sh"

usage='usage: issue-mine.sh [OWNER/REPO] NUMBER'
[ $# -ge 1 ] || die "$usage"
reject_options "$@"
repo="$(resolve_repo "$1")" || exit 1
case "$1" in */*) shift ;; esac
[ $# -ge 1 ] || die "$usage"
num="$1"
case "$num" in ''|*[!0-9]*) die "the issue number must be numeric, not '$num'" ;; esac

# Both reads are established as answers before they are compared. A refused query writes its
# error body to stdout, so a login read straight through a pipe would be the refusal text, and
# an assignee list read the same way would be empty - which reads as "assigned to nobody", a
# statement about the issue that the issue never made.
who="$(gh_read "who gh is logged in as" api user)" || exit 1
login="$(printf '%s' "$who" | jq -r '.login // ""')"
[ -n "$login" ] || die "cannot read who gh is logged in as - run 'gh auth status'"

issue="$(gh_read "the issue $repo#$num" api "repos/$repo/issues/$num")" || exit 1
assignees="$(printf '%s' "$issue" | jq -r '[.assignees[]?.login] | join(" ")')"

for a in $assignees; do
  [ "$a" = "$login" ] && { echo "#$num is assigned to @$login."; exit 0; }
done
if [ -z "$assignees" ]; then
  echo "REFUSED: #$num is assigned to nobody - the product owner assigns it before it is taken up."
else
  echo "REFUSED: #$num is assigned to $(printf '@%s, ' $assignees | sed 's/, $//'), not to @$login - ask them or the product owner to reassign it."
fi
exit 1
