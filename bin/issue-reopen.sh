#!/usr/bin/env bash
# Reopen issues and put every board card back in todo.
#
#   issue-reopen.sh [OWNER/REPO] NUMBER [NUMBER...]
#
# The repo may be left out inside a checkout. Every issue number is validated
# before repository resolution or any GitHub call, so invalid input changes nothing.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/board.sh"

usage='usage: issue-reopen.sh [OWNER/REPO] NUMBER [NUMBER...]'
[ $# -ge 1 ] || die "$usage"
reject_options "$@"

repo=""
numbers=("$@")
case "${numbers[0]}" in
  */*) repo="${numbers[0]}"; numbers=("${numbers[@]:1}") ;;
esac

[ ${#numbers[@]} -ge 1 ] || die "$usage"
for n in "${numbers[@]}"; do
  case "$n" in ''|*[!0-9]*) die "the issue number must be numeric, not '$n'" ;; esac
done

repo="$(resolve_repo "$repo")" || exit 1

for n in "${numbers[@]}"; do
  gh_read "the reopen of $repo#$n" api --method PATCH "repos/$repo/issues/$n" -f state=open >/dev/null || exit 1
  echo "#$n -> reopened"
  for_each_board "$repo" "$n" Status todo "todo"
done
