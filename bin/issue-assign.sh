#!/usr/bin/env bash
# Add or remove an issue's assignees, without disturbing the ones already there.
#
#   issue-assign.sh [OWNER/REPO] NUMBER [NUMBER...] --add LOGIN [--add LOGIN...]
#   issue-assign.sh [OWNER/REPO] NUMBER [NUMBER...] --remove LOGIN
#   issue-assign.sh [OWNER/REPO] NUMBER [NUMBER...] --replace LOGIN [--replace LOGIN...]
#
# The repo may be left out inside a checkout.
#
# Assignment is ADDITIVE by default, because the common case is a second name rather
# than a replacement: the rules ask for the repository's responsible developer to be
# added alongside whoever is doing the work, so they are informed. Replacing on every
# call would quietly drop that person the next time somebody assigned a ticket.
#
# --replace states the whole set, and is the only way to remove somebody by assignment;
# --remove takes a name off and leaves the rest.
#
# Prints the assignees the issue carries AFTER the change, per issue, so a call is
# proven rather than assumed. The board is not touched: who owns a ticket is not a
# column.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/board.sh"

usage='usage: issue-assign.sh [OWNER/REPO] NUMBER [NUMBER...] --add|--remove|--replace LOGIN'

add=(); remove=(); replace=(); args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --add)     need_value "$1" "${2-}"; add+=("$2");     shift 2 ;;
    --remove)  need_value "$1" "${2-}"; remove+=("$2");  shift 2 ;;
    --replace) need_value "$1" "${2-}"; replace+=("$2"); shift 2 ;;
    -*)        die "unknown argument '$1'" ;;
    *)         args+=("$1"); shift ;;
  esac
done
set -- ${args[@]+"${args[@]}"}

# Refuse a call that changes nothing BEFORE the repository is resolved or GitHub is
# reached, so bad input costs nothing and cannot half-apply across several issues.
[ ${#add[@]} -gt 0 ] || [ ${#remove[@]} -gt 0 ] || [ ${#replace[@]} -gt 0 ] \
  || die "name --add, --remove or --replace - an assignment that changes nothing is a mistake"
if [ ${#replace[@]} -gt 0 ] && { [ ${#add[@]} -gt 0 ] || [ ${#remove[@]} -gt 0 ]; }; then
  die "--replace states the whole set, so it cannot be combined with --add or --remove"
fi

case "${1:-}" in */*) repo="$(resolve_repo "$1")" || exit 1; shift ;; *) repo="$(resolve_repo "")" || exit 1 ;; esac
[ $# -gt 0 ] || die "$usage"
for n in "$@"; do
  case "$n" in ''|*[!0-9]*) die "the issue number must be numeric, not '$n'" ;; esac
done

# One set as sorted lines, so two of them can be compared as text.
as_set() { printf '%s\n' "$@" | sed '/^$/d' | sort -u; }

for n in "$@"; do
  # The issue is established as an answer before its assignees are read out of it: a refused
  # query answers with an error body, and reading no login out of that is "assigned to nobody"
  # - which the next lines would then write back onto the issue.
  issue="$(gh_read "the issue $repo#$n" api "repos/$repo/issues/$n")" || exit 1
  current="$(printf '%s' "$issue" | jq -r '.assignees[]?.login')"

  if [ ${#replace[@]} -gt 0 ]; then
    wanted="$(as_set "${replace[@]}")"
  else
    wanted="$current"
    [ ${#add[@]} -eq 0 ] || wanted="$(printf '%s\n%s\n' "$wanted" "$(printf '%s\n' "${add[@]}")")"
    for r in ${remove[@]+"${remove[@]}"}; do
      wanted="$(printf '%s\n' "$wanted" | grep -vxF "$r" || true)"
    done
    wanted="$(printf '%s\n' "$wanted" | sed '/^$/d' | sort -u)"
  fi

  # Say so and move on rather than sending a write that changes nothing: a no-op PATCH
  # still writes an event onto the issue's timeline, which reads later as a decision
  # somebody took.
  if [ "$(printf '%s\n' "$current" | sed '/^$/d' | sort -u)" = "$wanted" ]; then
    echo "#$n -> unchanged ($(printf '%s\n' "$current" | sed '/^$/d' | paste -sd, - | sed -e 's/,/, /g' -e 's/^$/nobody/'))"
    continue
  fi

  printf '%s\n' "$wanted" | jq -R . | jq -sc '{assignees: [.[] | select(. != "")]}' \
    | gh api --method PATCH "repos/$repo/issues/$n" --input - >/dev/null \
    || die "could not set the assignees of $repo#$n"

  after="$(gh_read "the issue $repo#$n" api "repos/$repo/issues/$n")" || exit 1
  now="$(printf '%s' "$after" | jq -r '.assignees[]?.login')"
  echo "#$n -> $(printf '%s\n' "$now" | sed '/^$/d' | paste -sd, - | sed -e 's/,/, /g' -e 's/^$/nobody/')"
done
