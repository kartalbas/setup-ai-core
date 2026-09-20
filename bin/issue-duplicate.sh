#!/usr/bin/env bash
# Mark or unmark one issue as the native GitHub duplicate of another.
#
#   issue-duplicate.sh [--undo] CANONICAL_REPO CANONICAL_NUMBER DUPLICATE_REPO DUPLICATE_NUMBER
#
# The direction is explicit because GitHub's "Duplicate of #N" comment syntax is
# directional from the issue receiving the comment and is easy to reverse.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/board.sh"

usage='usage: issue-duplicate.sh [--undo] CANONICAL_REPO CANONICAL_NUMBER DUPLICATE_REPO DUPLICATE_NUMBER'

undo=""
if [ "${1:-}" = "--undo" ]; then undo=1; shift; fi
reject_options "$@"
[ $# -eq 4 ] || die "$usage"

canonical_repo="$1"; canonical_num="$2"; duplicate_repo="$3"; duplicate_num="$4"
[[ "$canonical_repo" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || die "the canonical issue's repository must be named OWNER/REPO"
[[ "$duplicate_repo" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || die "the duplicate issue's repository must be named OWNER/REPO"
case "$canonical_num" in ''|*[!0-9]*) die "the canonical issue number must be numeric, not '$canonical_num'" ;; esac
case "$duplicate_num" in ''|*[!0-9]*) die "the duplicate issue number must be numeric, not '$duplicate_num'" ;; esac

if [ -n "$undo" ]; then
  # Both ids are resolved before the mutation, not inside it: a failed command substitution does
  # not stop the command it stands in, so an id that could not be read would be sent as empty.
  canonical_id="$(issue_node_id "$canonical_repo" "$canonical_num")" || exit 1
  duplicate_id="$(issue_node_id "$duplicate_repo" "$duplicate_num")" || exit 1
  mutation='mutation($canonical:ID!,$duplicate:ID!){unmarkIssueAsDuplicate(input:{canonicalId:$canonical,duplicateId:$duplicate}){duplicate{... on Issue{number}}}}'
  gh_read "the duplicate mark taken off $duplicate_repo#$duplicate_num" api graphql \
    -f canonical="$canonical_id" -f duplicate="$duplicate_id" -f query="$mutation" >/dev/null || exit 1
  verb="is no longer marked as a duplicate of"
else
  canonical_ref="$canonical_repo#$canonical_num"
  [ "$canonical_repo" = "$duplicate_repo" ] && canonical_ref="#$canonical_num"
  gh_read "the duplicate mark on $duplicate_repo#$duplicate_num" api --method POST \
    "repos/$duplicate_repo/issues/$duplicate_num/comments" -f "body=Duplicate of $canonical_ref" >/dev/null || exit 1
  verb="is marked as a duplicate of"
fi

echo "$duplicate_repo#$duplicate_num $verb $canonical_repo#$canonical_num"
