#!/usr/bin/env bash
# Add a comment to an issue.
#
#   issue-comment.sh [OWNER/REPO] NUMBER BODY
#   issue-comment.sh [OWNER/REPO] NUMBER --body-file PATH
#
# The repo may be left out inside a checkout. The body comes inline or from a file, and
# exactly one of the two. A long comment belongs in a file. Its backticks, quotes and
# newlines then reach GitHub as they were written, because no shell reads them on the
# way. The file must exist before GitHub is called. What gh prints - the comment URL -
# is passed straight through.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/board.sh"

usage='usage: issue-comment.sh [OWNER/REPO] NUMBER (BODY | --body-file PATH)'

body_file=""
numbers=()
while [ $# -gt 0 ]; do
  case "$1" in
    --body-file)   need_value "$1" "${2-}"; body_file="$2"; shift 2 ;;
    --body-file=*) die "$1 is not supported - separate the flag and its value" ;;
    -h|--help)     echo "$usage"; exit 0 ;;
    -*)            die "unknown argument '$1'" ;;
    *)             numbers+=("$1"); shift ;;
  esac
done

[ ${#numbers[@]} -ge 1 ] || die "$usage"
repo="$(resolve_repo "${numbers[0]}")" || exit 1
case "${numbers[0]}" in */*) numbers=("${numbers[@]:1}") ;; esac
[ ${#numbers[@]} -ge 1 ] || die "$usage"
number="${numbers[0]}"
body="${numbers[1]:-}"
case "$number" in ''|*[!0-9]*) die "the issue number must be numeric, not '$number'" ;; esac

# Refuse an empty or a double-sourced comment BEFORE anything is resolved or sent.
[ -n "$body" ] || [ -n "$body_file" ] || die "name a body or a --body-file - a comment with no text is a mistake"
[ -z "$body" ] || [ -z "$body_file" ] || die "name a body or a --body-file, not both - which one is the comment is not for a script to guess"

if [ -n "$body_file" ]; then
  [ -f "$body_file" ] || die "the body file does not exist: $body_file"
  gh_read "the comment posted on $repo#$number" issue comment "$number" --repo "$repo" --body-file "$body_file"
else
  gh_read "the comment posted on $repo#$number" issue comment "$number" --repo "$repo" --body "$body"
fi
