#!/usr/bin/env bash
# Mark or unmark one issue as the native GitHub duplicate of another.
#
#   issue-duplicate.sh [--undo] CANONICAL_REPO CANONICAL_NUMBER DUPLICATE_REPO DUPLICATE_NUMBER
#
# The direction is explicit because GitHub's "Duplicate of #N" comment syntax is
# directional from the issue receiving the comment and is easy to reverse.
# Refuses literal email addresses in the comment for public or unknown visibility; reserved example
# domains and GitHub noreply addresses are allowed. Private GitHub repositories bypass the check.
# Plane cannot establish private visibility, so its comments receive the public check.
# The check reads the raw text, and an address dressed by Markdown, HTML, invisible or lookalike characters is not refused; the README names the cases.

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
  duplicate_unmark "$canonical_repo" "$canonical_num" "$duplicate_repo" "$duplicate_num"
  verb="is no longer marked as a duplicate of"
else
  canonical_ref="$canonical_repo#$canonical_num"
  [ "$canonical_repo" != "$duplicate_repo" ] || canonical_ref="#$canonical_num"
  body="Duplicate of $canonical_ref"
  check_public_body issue-duplicate "$duplicate_repo" "$body" ""
  duplicate_mark "$canonical_repo" "$canonical_num" "$duplicate_repo" "$duplicate_num" "$body"
  verb="is marked as a duplicate of"
fi

echo "$duplicate_repo#$duplicate_num $verb $canonical_repo#$canonical_num"
