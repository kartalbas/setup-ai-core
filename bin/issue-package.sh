#!/usr/bin/env bash
# Put the label of a package on every issue of it, in every repository it spans, and take it off the issues that left.
#
#   issue-package.sh OWNER/REPO NUMBER --member OWNER/REPO#NUMBER... [--remove OWNER/REPO#NUMBER...]
#
# OWNER/REPO NUMBER is the first issue of the package, which stays its identity whoever joins or leaves. The label is
# package/<repo>#<number> of that issue, a label of each repository the members are in, and its description names the first
# issue as OWNER/REPO#NUMBER. --member names every issue of the package as it stands now, once each; --remove names the
# issues that were members before and no longer are. A repository that has a package/ label of that name which names
# another first issue, or none, is refused before anything is written.
#
# Every issue named is read first, and nothing is written before all of them and every label are read. The result is read
# back. When every member is closed as completed, the label is archived, so it stays on the issues and leaves the label
# picker; when one is open, closed as not planned or closed without a reason, the label is active again. The command never
# closes or proves an issue, and a package with no member is never archived. Where a step fails, the answer names what was
# confirmed; run the same command again, it reads the tracker and finishes what is missing. The tracker does not
# serialize two runs for one package: the coordinator runs one at a time. On Forgejo the same command is the one of
# lib/forgejo/tracker.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/board.sh"
. "$ROOT/lib/github/packages.sh"

usage='usage: issue-package.sh OWNER/REPO NUMBER --member OWNER/REPO#NUMBER... [--remove OWNER/REPO#NUMBER...]'
[ "$TRACKER" = github ] || die "issue-package supports GitHub and Forgejo, and TRACKER is '$TRACKER'"
[ $# -ge 1 ] || die "$usage"

repository_pattern='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
reference_pattern='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[1-9][0-9]*$'

members=()
removals=()
pos=()
while [ $# -gt 0 ]; do
  case "$1" in
    --member) need_value "$1" "${2-}"; members+=("$2"); shift 2 ;;
    --remove) need_value "$1" "${2-}"; removals+=("$2"); shift 2 ;;
    -*)       die "unknown argument '$1'" ;;
    *)        pos+=("$1"); shift ;;
  esac
done
[ ${#pos[@]} -eq 2 ] || die "$usage"
anchor_repository="${pos[0]}"
anchor_number="${pos[1]}"
[[ "$anchor_repository" =~ $repository_pattern ]] || die "'$anchor_repository' is not OWNER/REPO"
[[ "$anchor_number" =~ ^[1-9][0-9]*$ ]] || die "the issue number must be a positive number, not '$anchor_number'"
[ $(( ${#members[@]} + ${#removals[@]} )) -ge 1 ] || die "name the members of the package with --member, or the issues that left it with --remove: a package of nothing is a mistake"

lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
repository_of() { printf '%s' "${1%#*}"; }
number_of() { printf '%s' "${1##*#}"; }

member_keys=" "
for ref in ${members[@]+"${members[@]}"}; do
  [[ "$ref" =~ $reference_pattern ]] || die "'$ref' is not OWNER/REPO#NUMBER"
  case "$member_keys" in *" $(lc "$ref") "*) die "$ref is named twice with --member" ;; esac
  member_keys="$member_keys$(lc "$ref") "
done
removal_keys=" "
for ref in ${removals[@]+"${removals[@]}"}; do
  [[ "$ref" =~ $reference_pattern ]] || die "'$ref' is not OWNER/REPO#NUMBER"
  case "$removal_keys" in *" $(lc "$ref") "*) die "$ref is named twice with --remove" ;; esac
  case "$member_keys" in *" $(lc "$ref") "*) die "$ref is both a member and a departure" ;; esac
  removal_keys="$removal_keys$(lc "$ref") "
done

anchor="$anchor_repository#$anchor_number"
label_name="package/${anchor_repository#*/}#$anchor_number"
label_description="Package anchored at $anchor"
[ ${#label_description} -le 100 ] || die "the description of the label, '$label_description', is longer than the hundred characters GitHub takes"

create_error="$(mktemp)"
trap 'rm -f "$create_error"' EXIT
done_steps=()
note_done() { done_steps+=("$1"); }
# stop <what failed>: nothing was written yet, or what was confirmed before the failure
stop() {
  local joined="" item
  [ ${#done_steps[@]} -gt 0 ] || die "$*"
  for item in "${done_steps[@]}"; do joined="${joined:+$joined; }$item"; done
  echo "error: $*. Done before it failed: $joined. Run the same command again: it reads the tracker and finishes what is missing" >&2
  exit 1
}

# THE READS. Nothing is written before every issue and every label of the request has been read.
package_issue "$anchor_repository" "$anchor_number" >/dev/null || exit 1
member_json=()
for ref in ${members[@]+"${members[@]}"}; do
  fresh="$(package_issue "$(repository_of "$ref")" "$(number_of "$ref")")" || exit 1
  member_json+=("$fresh")
done
for ref in ${removals[@]+"${removals[@]}"}; do
  package_issue "$(repository_of "$ref")" "$(number_of "$ref")" >/dev/null || exit 1
done

# a scope is a repository: its members and its departures take their label from the repository's own list
scopes=()
while IFS= read -r repo; do
  [ -z "$repo" ] || scopes+=("$repo")
done <<< "$(for ref in ${members[@]+"${members[@]}"} ${removals[@]+"${removals[@]}"}; do repository_of "$ref"; echo; done | sort -f -u)"

# refuse_foreign_label <repository> <label JSON>
refuse_foreign_label() {
  local named
  named="$(printf '%s' "$2" | jq -r '.description // ""' | { grep -oE '[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+' || true; } | sort -fu)"
  [ "$(lc "$named")" != "$(lc "$anchor")" ] || return 0
  if [ -z "$named" ]; then named="names no anchor"; else named="names the anchor $(paste -sd' ' - <<< "$named" | sed 's/ / and /g')"; fi
  die "$1 has the label $label_name, which $named, and this package is anchored at $anchor: nothing was changed. Two packages cannot share a label name"
}

scope_labels=()
for repo in "${scopes[@]}"; do
  all="$(package_labels "$repo")" || exit 1
  label="$(package_label_in "$all" "$label_name")"
  if [ -n "$label" ]; then
    refuse_foreign_label "$repo" "$label"
    package_label_is_archived "$label" >/dev/null || die "GitHub did not say whether $label_name of $repo is archived"
  fi
  scope_labels+=("$label")
done

scope_index() {  # scope_index <repository>: the place of the repository in scopes
  local at=0 repo
  for repo in "${scopes[@]}"; do
    [ "$(lc "$repo")" != "$(lc "$1")" ] || { echo "$at"; return 0; }
    at=$((at + 1))
  done
  return 1
}

carries() {  # carries <label names, one per line> <name>
  grep -qixF -- "$2" <<< "$1"
}

others_of() {  # others_of <label names, one per line>: the package/ labels that are not this package's
  { printf '%s\n' "$1" | grep -i '^package/' | grep -vixF -- "$label_name"; } || true
}

# THE WRITES, one repository at a time.
for repo in "${scopes[@]}"; do
  at="$(scope_index "$repo")"
  label="${scope_labels[$at]}"
  scope_members=()
  lacking=no
  i=0
  for ref in ${members[@]+"${members[@]}"}; do
    if [ "$(lc "$(repository_of "$ref")")" = "$(lc "$repo")" ]; then
      scope_members+=("$ref")
      carries "$(package_issue_label_names "${member_json[$i]}")" "$label_name" || lacking=yes
    fi
    i=$((i + 1))
  done

  if [ ${#scope_members[@]} -gt 0 ]; then
    if [ -z "$label" ]; then
      if ! label="$(package_label_create "$repo" "$label_name" "$label_description" 2> "$create_error")"; then
        # another run may have made it between the read and this write: only a fresh read of the label decides
        all="$(package_labels "$repo")" || stop "creating $label_name in $repo failed and the label cannot be read"
        label="$(package_label_in "$all" "$label_name")"
        [ -n "$label" ] || stop "creating $label_name in $repo failed: $(cat "$create_error")"
        refuse_foreign_label "$repo" "$label"
      fi
      note_done "created $label_name in $repo"
      package_label_is_archived "$label" >/dev/null || stop "GitHub did not say whether $label_name of $repo is archived"
    fi
    if [ "$lacking" = yes ] && [ "$(package_label_is_archived "$label")" = true ]; then
      label="$(package_label_archive "$repo" "$label_name" false)" || stop "reactivating $label_name in $repo failed, and the label may be active"
      [ "$(package_label_is_archived "$label" || echo unknown)" = false ] || stop "GitHub did not make $label_name of $repo active"
      note_done "reactivated $label_name in $repo"
    fi
    scope_labels[$at]="$label"
  fi

  for ref in ${scope_members[@]+"${scope_members[@]}"}; do
    issue_repo="$(repository_of "$ref")"; issue_number="$(number_of "$ref")"
    fresh="$(package_issue "$issue_repo" "$issue_number")" || stop "reading $ref failed"
    names="$(package_issue_label_names "$fresh")"
    if ! carries "$names" "$label_name"; then
      package_issue_label_add "$issue_repo" "$issue_number" "$label_name" || stop "labeling $ref failed, and the write may have happened"
      note_done "labeled $ref"
    fi
    while IFS= read -r other; do
      [ -n "$other" ] || continue
      package_issue_label_remove "$issue_repo" "$issue_number" "$other" || stop "taking $other off $ref failed, and the write may have happened"
      note_done "took $other off $ref"
    done <<< "$(others_of "$names")"
  done

  for ref in ${removals[@]+"${removals[@]}"}; do
    [ "$(lc "$(repository_of "$ref")")" = "$(lc "$repo")" ] || continue
    issue_repo="$(repository_of "$ref")"; issue_number="$(number_of "$ref")"
    fresh="$(package_issue "$issue_repo" "$issue_number")" || stop "reading $ref failed"
    if carries "$(package_issue_label_names "$fresh")" "$label_name"; then
      package_issue_label_remove "$issue_repo" "$issue_number" "$label_name" || stop "taking $label_name off $ref failed, and the write may have happened"
      note_done "took $label_name off $ref"
    fi
  done
done

# THE READ-BACK of every member and every departure, and the label of every repository that has a member.
confirmed_json=()
for ref in ${members[@]+"${members[@]}"}; do
  fresh="$(package_issue "$(repository_of "$ref")" "$(number_of "$ref")")" || stop "reading $ref back failed"
  names="$(package_issue_label_names "$fresh")"
  [ "$(printf '%s\n' "$names" | grep -ci '^package/')" = 1 ] && carries "$names" "$label_name" \
    || stop "$ref carries $(printf '%s\n' "$names" | grep -i '^package/' | paste -sd, - || true) where only $label_name was expected"
  confirmed_json+=("$fresh")
done
for ref in ${removals[@]+"${removals[@]}"}; do
  fresh="$(package_issue "$(repository_of "$ref")" "$(number_of "$ref")")" || stop "reading $ref back failed"
  ! carries "$(package_issue_label_names "$fresh")" "$label_name" || stop "$ref still carries $label_name"
done
note_done "read back ${#members[@]} members and ${#removals[@]} departures"

complete_count=0
for fresh in ${confirmed_json[@]+"${confirmed_json[@]}"}; do
  ! package_issue_is_complete "$fresh" || complete_count=$((complete_count + 1))
done
complete=false
[ ${#members[@]} -gt 0 ] && [ "$complete_count" -eq ${#members[@]} ] && complete=true

report=()
for repo in "${scopes[@]}"; do
  at="$(scope_index "$repo")"
  has_member=no
  for ref in ${members[@]+"${members[@]}"}; do
    [ "$(lc "$(repository_of "$ref")")" != "$(lc "$repo")" ] || has_member=yes
  done
  [ "$has_member" = yes ] || continue
  all="$(package_labels "$repo")" || stop "reading the labels of $repo back failed"
  label="$(package_label_in "$all" "$label_name")"
  [ -n "$label" ] || stop "$repo has no label $label_name after it was written"
  if [ "$(package_label_is_archived "$label" || echo unknown)" = unknown ]; then stop "GitHub did not say whether $label_name of $repo is archived"; fi
  if [ "$(package_label_is_archived "$label")" != "$complete" ]; then
    label="$(package_label_archive "$repo" "$label_name" "$complete")" || stop "changing the archival of $label_name in $repo failed, and the write may have happened"
    [ "$(package_label_is_archived "$label" || echo unknown)" = "$complete" ] || stop "GitHub answered another archival of $label_name in $repo than the one asked, $complete"
    note_done "$([ "$complete" = true ] && echo archived || echo reactivated) $label_name in $repo"
    changed=yes
  fi
  report+=("$repo: $label_name is $([ "$complete" = true ] && echo archived || echo active)")
done

if [ "${changed:-no}" = yes ]; then
  for repo in "${scopes[@]}"; do
    for ref in ${members[@]+"${members[@]}"}; do
      [ "$(lc "$(repository_of "$ref")")" = "$(lc "$repo")" ] || continue
      carries "$(package_issue_label_names "$(package_issue "$repo" "$(number_of "$ref")")")" "$label_name" || stop "$ref lost $label_name"
    done
  done
fi

for ref in ${members[@]+"${members[@]}"}; do echo "$ref carries $label_name"; done
for ref in ${removals[@]+"${removals[@]}"}; do echo "$ref does not carry $label_name"; done
for line in ${report[@]+"${report[@]}"}; do echo "$line"; done
echo "$label_name: ${#members[@]} members confirmed, ${#removals[@]} departures confirmed, $complete_count of ${#members[@]} members complete"
