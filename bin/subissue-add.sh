#!/usr/bin/env bash
# Attach an existing issue to an epic as a real GitHub sub-issue, which is what makes
# the epic's progress bar count. Issues that merely mention each other do not.
#
#   subissue-add.sh [OWNER/REPO] PARENT CHILD [CHILD ...]
#
# The repo may be left out inside a checkout.
#
# Parent and child are issues, and the link between them lives on the issues - so this
# touches no board and takes no project.
#
# A CHILD may name its own repo as OWNER/REPO#N. An epic and its work do not always live in
# one repo - a rebuild of one component is regularly blocked by a change in another - and an
# epic that cannot hold those children shows a progress bar that is wrong by design.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/board.sh"

[ $# -ge 2 ] || die "usage: subissue-add.sh [OWNER/REPO] PARENT CHILD [CHILD ...]"
reject_options "$@"

repo="$(resolve_repo "$1")"; case "$1" in */*) shift ;; esac
parent="$1"; shift
case "$parent" in ''|*[!0-9]*) die "the parent issue number must be numeric, not '$parent'" ;; esac

for child in "$@"; do
  case "$child" in
    */*#*) child_repo="${child%%#*}"; child_num="${child##*#}" ;;
    *)     child_repo="$repo";        child_num="$child" ;;
  esac
  case "$child_num" in ''|*[!0-9]*) die "the child issue number must be numeric, not '$child_num' - write a number, or OWNER/REPO#N" ;; esac
  # Resolved before the call, not inside it: a failed command substitution does not stop the command
  # it stands in, so an id that could not be read would be posted as an empty one.
  child_id="$(issue_db_id "$child_repo" "$child_num")" || exit 1
  gh api --method POST "repos/$repo/issues/$parent/sub_issues" -F sub_issue_id="$child_id" >/dev/null
  [ "$child_repo" = "$repo" ] && echo "#$child_num -> #$parent" || echo "$child_repo#$child_num -> #$parent"
done
