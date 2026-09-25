#!/usr/bin/env bash
# Set which labels an issue carries - put labels on, take labels off, or both at once.
#
#   issue-label.sh [OWNER/REPO] NUMBER [NUMBER...] [--add LABEL]... [--remove LABEL]...
#
# The repo may be left out inside a checkout. The numbers are positional and the labels
# are named, so a whole batch takes one call:
#   issue-label.sh 111 112 --add type:bug --add area:gate
#   issue-label.sh 72 --add area:installation --remove area:install
#
# WHY THIS EXISTS BESIDE issue-new. Every ticket carries at least one TYPE label and
# one AREA label, and issue-new sets them when a ticket is created. Nothing sets them
# on a ticket that already stands - so without this they are added by hand in one
# repository at a time, which is exactly what makes a board-wide filter lie.
#
# BOTH DIRECTIONS ARE NAMED, and neither of them is what a bare word means. Retiring a
# label is one act with two halves, so the two halves are spelled the same way; a set
# where one side carries the word and the other is silent cannot be searched for, and
# a reader who finds --remove and no --add concludes that adding is somebody else's job.
#
# A LABEL OUTSIDE THE TAXONOMY IS REFUSED ON --add AND ACCEPTED ON --remove. Creating
# one here would put a label in one repository and not in the others, and a filter
# across the board would then quietly miss the tickets in every repository that never
# got it. Adding a label means adding a line to labels.tsv and running labels-sync. A
# name being retired is out of labels.tsv by the time it comes off a ticket, so holding
# --remove to the taxonomy would refuse exactly the call it exists for.
#
# WHAT IS SENT IS WHAT THE ISSUE ACTUALLY CARRIES. The labels are read before the edit,
# a label already on the issue is not added again, and one that is not on it is not
# removed. Measured on 2026-08-26: `gh issue edit --remove-label x` exits 1 with
# "'x' not found" when the REPOSITORY has no label of that name, and exits 0 changing
# nothing when the repository has it but the issue does not. Reading first turns the
# first case - a misspelt name, or a second run after the label itself was deleted -
# into a reported line instead of a dead run.
#
# NO LABEL IS DELETED FROM A REPOSITORY HERE. Taking a label off one issue is undone by
# naming that issue again. Deleting the label takes it off every issue that carries it
# in one act, and the list of which issues those were goes with it, so nothing can say
# what to put back. labels-sync leaves an undeclared label alone for the same reason.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/board.sh"

[ $# -ge 1 ] || die "usage: issue-label.sh [OWNER/REPO] NUMBER [NUMBER...] [--add LABEL]... [--remove LABEL]..."

pos=()
add=()
remove=()
while [ $# -gt 0 ]; do
  case "$1" in
    --add)    need_value "$1" "${2-}"; add+=("$2");    shift 2 ;;
    --remove) need_value "$1" "${2-}"; remove+=("$2"); shift 2 ;;
    -*)       die "unknown argument '$1'" ;;
    *)        pos+=("$1"); shift ;;
  esac
done

# The repo is the one positional that carries a slash, and it stands first. Everything
# after it is an issue number: a word that is neither says the caller wrote a label where
# a number belongs, and a label filed under the numbers would be silently ignored.
repo="$(resolve_repo "${pos[0]-}")" || exit 1
case "${pos[0]-}" in */*) pos=("${pos[@]:1}") ;; esac

nums=()
for a in ${pos[@]+"${pos[@]}"}; do
  case "$a" in
    ''|*[!0-9]*) die "'$a' is not an issue number - a label is named with --add or --remove" ;;
    *)           nums+=("$a") ;;
  esac
done

[ ${#nums[@]} -ge 1 ] || die "no issue number given"
[ $(( ${#add[@]} + ${#remove[@]} )) -ge 1 ] || die "nothing to do - name a label to add or to remove"

# THE SAME NAME ON BOTH SIDES IS REFUSED RATHER THAN ORDERED. gh takes --add-label and
# --remove-label in one call and nothing here says which of the two wins, so the result
# is whatever the server does with it - and the board would then carry a label nobody
# can predict from the command that set it.
for a in ${add[@]+"${add[@]}"}; do
  for r in ${remove[@]+"${remove[@]}"}; do
    [ "$a" != "$r" ] || die "'$a' is named to add and to remove - it can only be one of the two"
  done
done

taxonomy="$(labels_tsv)" || exit 1
known="$(printf '%s\n' "$taxonomy" | cut -f2)"
for l in ${add[@]+"${add[@]}"}; do
  grep -qxF -- "$l" <<< "$known" ||
    die "\"$l\" is not in the taxonomy. Add it to labels.tsv and run labels-sync, so every repository has it."
done

# WHAT IS MISSING IS REPORTED, NEVER FILLED IN. A type or an area guessed here is a lie
# the board then tells everyone, so a ticket that ends up with only one of the two is
# named and left for a person to decide. Removal is what makes that case common, so the
# report is read from the labels the issue carries AFTER the edit and not from the
# arguments this run was given.
types="$(printf '%s\n' "$taxonomy" | awk -F'\t' '$1=="type" {print $2}')"
areas="$(printf '%s\n' "$taxonomy" | awk -F'\t' '$1=="area" {print $2}')"

# A label name may hold a space - GitHub's own defaults include "help wanted" - so the
# gh call is built as an argument array. Glued into one word-split string, such a name
# arrives as two arguments and gh removes a label that was never asked for.
labels_of() {  # labels_of <owner/repo> <number>
  gh_read "the labels of $1#$2" issue view "$2" --repo "$1" --json labels -q '.labels[].name'
}

joined() { local IFS=' '; printf '%s' "$*"; }

for n in "${nums[@]}"; do
  before="$(labels_of "$repo" "$n")" || exit 1

  will_add=(); already=()
  for l in ${add[@]+"${add[@]}"}; do
    if grep -qxF -- "$l" <<< "$before"; then already+=("$l"); else will_add+=("$l"); fi
  done
  will_remove=(); absent=()
  for l in ${remove[@]+"${remove[@]}"}; do
    if grep -qxF -- "$l" <<< "$before"; then will_remove+=("$l"); else absent+=("$l"); fi
  done

  edit=()
  for l in ${will_add[@]+"${will_add[@]}"};       do edit+=(--add-label "$l"); done
  for l in ${will_remove[@]+"${will_remove[@]}"}; do edit+=(--remove-label "$l"); done
  [ ${#edit[@]} -eq 0 ] || gh issue edit "$n" --repo "$repo" "${edit[@]}" >/dev/null

  on="$(labels_of "$repo" "$n")" || exit 1
  has_type=no; has_area=no
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    if grep -qxF -- "$l" <<< "$types"; then has_type=yes; fi
    if grep -qxF -- "$l" <<< "$areas"; then has_area=yes; fi
  done <<< "$on"

  changes=""
  for l in ${will_add[@]+"${will_add[@]}"};       do changes="$changes +$l"; done
  for l in ${will_remove[@]+"${will_remove[@]}"}; do changes="$changes -$l"; done
  [ -n "$changes" ] || changes=" unchanged"

  note=""
  [ ${#already[@]} -eq 0 ] || note="$note  already on it: $(joined "${already[@]}")"
  [ ${#absent[@]}  -eq 0 ] || note="$note  not on it: $(joined "${absent[@]}")"
  [ "$has_type" = no ] && note="$note  MISSING a type label"
  [ "$has_area" = no ] && note="$note  MISSING an area label"
  echo "#$n ->$changes$note"
done
