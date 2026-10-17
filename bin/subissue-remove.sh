#!/usr/bin/env bash
# Detach a sub-issue from its epic, leaving both issues standing.
#
#   subissue-remove.sh [OWNER/REPO] PARENT CHILD [CHILD ...]
#
# The repo may be left out inside a checkout. A CHILD may name its own repo as
# OWNER/REPO#N, exactly as subissue-add.sh takes it.
#
# The counterpart to subissue-add.sh, and needed for the same reason it is: a child
# has exactly ONE parent, so moving work under the epic it really belongs to is a
# detach followed by an attach. Without this the only way to correct a wrong parent
# is to close the issue and file it again, which throws away its comments and its
# history - the part of an issue that is hardest to reproduce.
#
# The link lives on the issues, so this takes no project. The epic then follows the sub-issues it
# still has on its own board, as under issue-status.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/board.sh"

[ $# -ge 2 ] || die "usage: subissue-remove.sh [OWNER/REPO] PARENT CHILD [CHILD ...]"
reject_options "$@"

repo="$(resolve_repo "$1")" || exit 1
case "$1" in */*) shift ;; esac
[ $# -ge 2 ] || die "usage: subissue-remove.sh [OWNER/REPO] PARENT CHILD [CHILD ...]"
parent="$1"; shift
case "$parent" in ''|*[!0-9]*) die "the parent issue number must be numeric, not '$parent'" ;; esac

for child in "$@"; do
  case "$child" in
    */*#*) child_repo="${child%%#*}"; child_num="${child##*#}" ;;
    *)     child_repo="$repo";        child_num="$child" ;;
  esac
  case "$child_num" in ''|*[!0-9]*) die "the child issue number must be numeric, not '$child_num' - write a number, or OWNER/REPO#N" ;; esac
  subissue_detach "$repo" "$parent" "$child_repo" "$child_num"
  [ "$child_repo" = "$repo" ] && echo "#$child_num detached from #$parent" || echo "$child_repo#$child_num detached from #$parent"
done
update_epic "$repo" "$parent" || exit 1
