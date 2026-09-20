#!/usr/bin/env bash
# Edit an existing issue's title and/or body.
#
#   issue-edit.sh [OWNER/REPO] NUMBER [--title "New title"] [--body-file PATH]
#
# The repo may be left out inside a checkout. At least one of title and body is required -
# a call that changes nothing is a mistake, and refusing it here is cheaper than a run
# against GitHub that also changes nothing. The body file must exist before GitHub is called.
# Only the fields the caller supplied are sent.
#
# A NEW TITLE IS READ THE WAY issue-new READS A FIRST ONE, and the report is a report: a title
# carries an ACTION and its STAKE - what is wrong today, or what it costs if nobody does it -
# joined with ", so ", ", or " or a colon (rules.md, the issue rules). "Add the board-sync
# command" names an artifact and fits twenty other tickets; "Put every new issue on its board,
# or nobody reading the board sees it" says what will be different. The edit is sent either way.
#
# THE ASKED-FOR LINE SURVIVES THE EDIT. It is kept, not asked for and not composed - see below.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/board.sh"

usage='usage: issue-edit.sh [OWNER/REPO] NUMBER [--title T] [--body-file PATH]'

title=""; body=""
numbers=()
while [ $# -gt 0 ]; do
  case "$1" in
    --title)     need_value "$1" "${2-}"; title="$2"; shift 2 ;;
    --body-file) need_value "$1" "${2-}"; body="$2";  shift 2 ;;
    --title=*|--body-file=*) die "$1 is not supported - separate the flag and its value" ;;
    -h|--help)   echo "$usage"; exit 0 ;;
    -*)          die "unknown argument '$1'" ;;
    *)           numbers+=("$1"); shift ;;
  esac
done
[ ${#numbers[@]} -ge 1 ] || die "$usage"

# Refuse a pointless or impossible edit BEFORE anything is resolved or sent.
[ -n "$title" ] || [ -n "$body" ] || die "name a --title or a --body-file - an edit that changes nothing is a mistake"
if [ -n "$body" ]; then
  [ -f "$body" ] || die "the body file does not exist: $body"
fi

repo="$(resolve_repo "${numbers[0]}")" || exit 1
case "${numbers[0]}" in */*) numbers=("${numbers[@]:1}") ;; esac
[ ${#numbers[@]} -ge 1 ] || die "$usage"
num="${numbers[0]}"
case "$num" in ''|*[!0-9]*) die "the issue number must be numeric, not '$num'" ;; esac

# Reported, not enforced.
[ -z "$title" ] || report_title "$title"

# THE FIRST LINE OF AN ISSUE BODY NAMES WHO ASKED FOR THE WORK, AND PATCH REPLACES THE WHOLE
# BODY. A file that does not carry that line therefore deletes it, with exit 0 and a verdict
# saying the edit went through, and nothing reports the loss.
#
# So the line is KEPT: where the new body does not open with one, the issue's current first line
# is read, and where THAT is an asked-for line it is put back on a temporary copy. The line that
# lands is the one the issue already carried. The alternative - refusing the body and telling the
# caller to carry the line - is an instruction to compose one from what the caller believes, and
# an invented line is indistinguishable on the board from a true one. Preserving beats refusing
# exactly because the rule says that line cannot be invented later.
#
# THE READ HAPPENS ONLY WHERE IT IS NEEDED. The body file's own first line is looked at first, so
# a body that already carries the line reaches GitHub once, as before. Measured on 2026-09-05:
# the PATCH takes about 650 ms and the read about 470 ms, so the second call is paid only by an
# edit that would otherwise have destroyed the line. When that read is refused the edit STOPS,
# because the alternative is sending a body known to be missing the line.
#
# WHERE THE ISSUE ITSELF CARRIES NO SUCH LINE - an older issue, or one opened on the web - there
# is nothing to keep. That is reported and the body is sent as given: a command reports what a
# ticket is missing and never fills it in.
#
# The caller's own file is left alone, the way issue-new leaves it: a command that edits its
# input cannot be run twice.
send="$body"
kept=""
if [ -n "$body" ] && ! head -n 1 "$body" | grep -q "^$ASKED_PREFIX"; then
  current="$(gh_read "the body of $repo#$num" api "repos/$repo/issues/$num" --jq '.body')" || exit 1
  # GitHub writes a body back with CRLF line endings, and the carriage return would travel into
  # the line being put back.
  first="$(printf '%s' "$current" | head -n 1)"
  first="${first%$'\r'}"
  case "$first" in
    "$ASKED_PREFIX"*)
      send="$(mktemp)"
      trap 'rm -f "$send"' EXIT
      { printf '%s\n\n' "$first"; cat "$body"; } > "$send"
      kept=", asked-for line kept" ;;
    *) echo "$repo#$num carries no asked-for line, so there is none to keep - an edit is not the place to invent one" >&2 ;;
  esac
fi

call=(api --method PATCH "repos/$repo/issues/$num")
[ -n "$title" ] && call+=(-f "title=$title")
[ -n "$body" ] && call+=(-F "body=@$send")
gh_read "the edit of $repo#$num" "${call[@]}" >/dev/null || exit 1

changed=""
[ -n "$title" ] && changed="title"
[ -n "$body" ] && changed="$changed${changed:+ and }body"
echo "#$num -> edited ($changed$kept)"
