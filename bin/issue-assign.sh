#!/usr/bin/env bash
# Add or remove an issue's assignees, without disturbing the ones already there.
#
#   issue-assign.sh [OWNER/REPO] NUMBER [NUMBER...] --add LOGIN [--add LOGIN...]
#   issue-assign.sh [OWNER/REPO] NUMBER [NUMBER...] --remove LOGIN
#   issue-assign.sh [OWNER/REPO] NUMBER [NUMBER...] --replace LOGIN [--replace LOGIN...]
#
# The repo may be left out inside a checkout.
#
# LOGIN is the name the tracker knows a person by: on GitHub the login, on Plane the email of a
# member of the workspace, which Plane matches without case, or @me for the key's own user. Plane
# does not match a display name. A name the tracker does not know stops the command before
# anything is written.
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
  # The assignees are established as an answer before they are compared: a refused query reads as
  # "assigned to nobody" - which the next lines would then write back onto the issue.
  current="$(issue_assignees "$repo" "$n")" || exit 1

  if [ ${#replace[@]} -gt 0 ]; then
    wanted="$(as_set "${replace[@]}")"
  else
    wanted="$current"
    [ ${#add[@]} -eq 0 ] || wanted="$(printf '%s\n%s\n' "$wanted" "$(printf '%s\n' "${add[@]}")")"
    for r in ${remove[@]+"${remove[@]}"}; do
      wanted="$(grep -vxF "$r" <<< "$wanted" || true)"
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

  issue_assignees_set "$repo" "$n" "$wanted"

  now="$(issue_assignees "$repo" "$n")" || exit 1
  echo "#$n -> $(printf '%s\n' "$now" | sed '/^$/d' | paste -sd, - | sed -e 's/,/, /g' -e 's/^$/nobody/')"
done
