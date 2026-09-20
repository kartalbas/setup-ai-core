#!/usr/bin/env bash
# Read an issue and its whole comment thread.
#
#   issue-thread.sh [OWNER/REPO] NUMBER [--json]
#
# The repo may be left out inside a checkout. This reads and prints; it changes nothing
# on the issue and nothing on the board.
#
# Without --json it is laid out for a person: the title, the state, the labels, a blank
# line, the body, then every comment behind a line naming who wrote it and when. With
# --json it is one object on one line, for a script that has to work the thread out
# rather than read it.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/board.sh"

usage='usage: issue-thread.sh [OWNER/REPO] NUMBER [--json]'

as_json=0
numbers=()
while [ $# -gt 0 ]; do
  case "$1" in
    --json)    as_json=1; shift ;;
    -h|--help) echo "$usage"; exit 0 ;;
    -*)        die "unknown argument '$1'" ;;
    *)         numbers+=("$1"); shift ;;
  esac
done

[ ${#numbers[@]} -ge 1 ] || die "$usage"
repo="$(resolve_repo "${numbers[0]}")" || exit 1
case "${numbers[0]}" in */*) numbers=("${numbers[@]:1}") ;; esac
[ ${#numbers[@]} -ge 1 ] || die "$usage"
num="${numbers[0]}"
case "$num" in ''|*[!0-9]*) die "the issue number must be numeric, not '$num'" ;; esac

thread="$(issue_thread "$repo" "$num")" || exit 1

if [ "$as_json" -eq 1 ]; then
  printf '%s' "$thread" | jq -c .
  exit 0
fi

# An issue with no label prints a dash, the way board-list prints a missing field: an
# empty space after "labels:" reads as a line somebody forgot to finish.
printf '%s' "$thread" | jq -r '
  "#\(.number) \(.title)",
  "state: \(.state)",
  "labels: \(if (.labels | length) == 0 then "-" else (.labels | join(", ")) end)",
  "",
  .body,
  (.comments[] | "", "--- \(.author) \(.created_at)", .body)'
