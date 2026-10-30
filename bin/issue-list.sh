#!/usr/bin/env bash
# List the issues of a repository, or search them.
#
#   issue-list.sh [OWNER/REPO | --owner ORG] [--state open|closed|all] [--search TEXT]
#
# Reads and prints; it changes nothing. One line each, separated by tabs: OWNER/REPO#NUMBER, the Status of the
# issue's first board card, its Priority and the title, with a dash where the issue has no card or the card has no
# value, in the order of repository and number. Without OWNER/REPO it reads the repository this checkout is of; with
# --owner ORG it reads every repository of that organisation or user. --state is open (the default), closed or all.
# --search TEXT keeps the issues whose title and body hold every word of TEXT, in any order, each word as typed.
# GitHub's search serves at most 1000 issues; a longer answer is refused and never listed as the whole.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/board.sh"

usage='usage: issue-list.sh [OWNER/REPO | --owner ORG] [--state open|closed|all] [--search TEXT]'

state=open
text=""
asked_text=0
owner=""
repo=""
while [ $# -gt 0 ]; do
  case "$1" in
    --state)  need_value "$1" "${2-}"; state="$2"; shift 2 ;;
    --search) need_value "$1" "${2-}"; text="$2"; asked_text=1; shift 2 ;;
    --owner)  need_value "$1" "${2-}"; owner="$2"; shift 2 ;;
    -*)       die "unknown argument '$1'" ;;
    *)        [ -z "$repo" ] || die "unexpected '$1'. $usage"; repo="$1"; shift ;;
  esac
done

case "$state" in open|closed|all) ;; *) die "--state must be open, closed or all, not '$state'" ;; esac
if [ "$asked_text" -eq 1 ] && [ -z "$(printf '%s' "$text" | tr -d '[:space:]')" ]; then die "--search needs the words to look for"; fi

if [ -n "$owner" ]; then
  [ -z "$repo" ] || die "--owner and OWNER/REPO exclude each other. $usage"
  case "$owner" in *[!A-Za-z0-9_.-]*) die "$owner is not the name of an organisation or a user" ;; esac
  scope="$owner"
else
  case "$repo" in
    '') scope="$(default_repo)" || exit 1 ;;
    */*/* | */ | /* | *[!A-Za-z0-9_./-]*) die "$repo is not OWNER/REPO" ;;
    */*) scope="$repo" ;;
    *)   die "$repo is not OWNER/REPO" ;;
  esac
fi

rows="$(issue_list "$scope" "$state" "$text")" || exit 1
[ -z "$rows" ] || printf '%s\n' "$rows" | jq -rs 'sort_by([.repo, .number])[]
  | "\(.repo)#\(.number)\t\(.status // "-")\t\(.priority // "-")\t\(.title)"'
