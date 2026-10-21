#!/usr/bin/env bash
# The issue carry from GitHub into Plane, as bin/issue-transfer.sh runs it: the source is read whole and
# only read, the plan and every count come from lib/carry-plan.jq and are printed with the request bound before
# the first write, and the writes are dispatched to the clone that owns each destination. Source it, do not run it.

. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# carry_in_tracker <tracker> <function> [argument...]: a function of that tracker's provider, in a process of its own
carry_in_tracker() {
  TRACKER="$1" bash -c '. "$1/lib/board.sh"; shift; "$@"' _ "$HARNESS_ROOT" "${@:2}"
}

# carry_in_clone <clone> <function> [argument...]: a function of the Plane provider, in the clone that owns the destination
carry_in_clone() {
  (cd "$1" && TRACKER=plane bash -c '. "$1/lib/board.sh"; shift; "$@"' _ "$HARNESS_ROOT" "${@:2}")
}

# carry_destination_of <repo>: "<repo>\t<clone>\t<url|workspace|project>" where the clone of the repository sets a Plane
# destination, else a line starting with "!" that says what is missing. The settings are read in a fresh process.
carry_destination_of() {
  local clone settings url workspace project
  clone="$(clone_of "$1")"
  [ -n "$clone" ] || { printf '!no clone of %s in %s\n' "$1" "$(project_folder_of "$PWD")"; return 0; }
  settings="$(clone_settings "$clone")" || { printf '!cannot read the settings of %s\n' "$clone"; return 0; }
  IFS=$'\t' read -r _ url workspace project <<< "$settings"
  if [ -z "$url" ] || [ -z "$workspace" ] || [ -z "$project" ]; then
    printf '!%s sets no PLANE_URL, PLANE_WORKSPACE and PLANE_PROJECT\n' "$clone"; return 0
  fi
  printf '%s\t%s\t%s|%s|%s\n' "$1" "$clone" "${url%/}" "$workspace" "$project"
}

# carry_report <plan> <metadata pages> <missing labels>: every count of the plan, then the bound on the requests
carry_report() {
  jq -r --argjson m "$2" --argjson l "$3" '
    .report as $r
    | ($r.issues + $r.board_records) as $items
    | (3 * $items + ($r.comments_original + $r.comments_provenance) + 2 * $r.comment_pages + $m + $l + $r.parents_outside_distinct) as $bound
    | "issue carry: \($r.issues) issues of \($r.repositories_selected) repositories (open \($r.issues_open), closed as completed \($r.issues_done), closed as not planned or duplicate \($r.issues_cancelled)); skipped archived repositories: \(if ($r.repositories_skipped | length) == 0 then "none" else ($r.repositories_skipped | join(", ")) end)",
      "comments to carry: \($r.comments_original) original and \($r.comments_provenance) provenance, \($r.comments_original + $r.comments_provenance) in all, in \($r.comment_pages) pages of 100",
      "board memberships: \($r.memberships) on issues (\($r.archived_memberships) archived, on \($r.archived_issues) issues of \($r.issues)), \($r.boardless_issues) of \($r.issues) issues on no board",
      "parent links: \($r.parent_links) (\($r.parents_native) sub-issues, \($r.parents_reference) recorded relationships across destinations, \($r.parents_outside) outside the selection, \($r.parents_outside_distinct) distinct)",
      "boards: \($r.boards_source) on GitHub (\($r.boards_empty) empty, \($r.boards_closed) closed, \($r.boards_spanning) in several destinations), \($r.board_records) board records to create, \($r.board_memberships_total) cards in all",
      "cases: priority P9 on \($r.p9_issues) of \($r.issues) issues; an email address in \($r.address_issues) of \($r.issues) issues (\($r.address_titles) titles, \($r.address_bodies) bodies, \($r.address_comments) of \($r.comments_original) comments); differing active Status values on \($r.conflicting_status_issues) of \($r.issues) issues",
      "destinations: \($r.destinations | length) (\($r.destinations | join("; ")))",
      "Plane requests, at most: \($bound) = 3 x (\($r.issues) issues + \($r.board_records) board records) + \($r.comments_original + $r.comments_provenance) comments + 2 x \($r.comment_pages) comment pages + \($m) metadata pages + \($l) new labels + \($r.parents_outside_distinct) outside parents; at 60 a minute that is \(($bound + 59) / 60 | floor) minutes of API capacity, without retries and their waits"
  ' <<< "$1"
}

CARRY_WORK=""
# carry_run <repo or empty> <number or empty> <column or empty>: carries the selection and prints what it did; the status
# is non-zero when the source cannot be read whole or an issue is left incomplete
carry_run() {
  local repo="$1" number="$2" column="$3" owner source destinations plan line problems="" clone key m=0 l=0 pages missing
  local issues_complete=0 issues_new=0 issues_resumed=0 incomplete=0 boards_complete=0 boards_new=0 boards_incomplete=0 batch_clone="" batch="" label results numbers no_issues=""
  work="$(mktemp -d)"; CARRY_WORK="$work"; trap 'rm -rf "$CARRY_WORK"' EXIT
  export CARRY_RUN="$work/run"; mkdir -p "$CARRY_RUN"; : > "$CARRY_RUN/addresses.tsv"
  source="$work/source.jsonl"; : > "$source"; : > "$work/clones.tsv"

  if [ -z "$repo" ]; then
    owner="$(carry_in_tracker github gh_org)" || exit 1
    carry_in_tracker github github_carry_repositories "$owner" > "$work/repositories.jsonl" || exit 1
    cat "$work/repositories.jsonl" >> "$source"
    while IFS= read -r line; do
      [ "$(jq -r '.archived' <<< "$line")" = false ] || continue
      if [ "$(jq -r '.issues' <<< "$line")" = 0 ]; then no_issues="${no_issues:+$no_issues, }$(jq -r '.repo' <<< "$line")"; continue; fi
      line="$(carry_destination_of "$(jq -r '.repo' <<< "$line")")"
      case "$line" in '!'*) problems="$problems"$'\n'"  ${line#!}" ;; *) printf '%s\n' "$line" >> "$work/clones.tsv" ;; esac
    done < "$work/repositories.jsonl"
    [ -z "$problems" ] || die "the selection cannot be resolved, and nothing was written:$problems"
    while IFS=$'\t' read -r line _; do
      carry_in_tracker github github_carry_issues "$line" >> "$source" || exit 1
    done < "$work/clones.tsv"
    carry_in_tracker github github_carry_boards "$owner" >> "$source" || exit 1
    label=full
  else
    line="$(carry_destination_of "$repo")"
    case "$line" in '!'*) die "${line#!}" ;; esac
    printf '%s\n' "$line" > "$work/clones.tsv"
    if [ -n "$number" ]; then carry_in_tracker github github_carry_issues "$repo" "$number" >> "$source" || exit 1
    else
      numbers="$(carry_in_tracker github github_carry_column_numbers "$repo" "$column")" || exit 1
      for number in $numbers; do
        carry_in_tracker github github_carry_issues "$repo" "$number" >> "$source" || exit 1
      done
      jq -c 'select(.kind != "issue" or .state == "OPEN")' "$source" > "$work/open.jsonl" && mv "$work/open.jsonl" "$source"
    fi
    label=short
    if [ ! "$(jq -s 'map(select(.kind == "issue")) | length' "$source")" -gt 0 ]; then
      echo "nothing is left to carry: no issue of $repo is selected"; return 0
    fi
  fi

  destinations="$(jq -Rn '[inputs | split("\t") | {key: .[0], value: .[2]}] | from_entries' < "$work/clones.tsv")"
  plan="$(jq -n -f "$HARNESS_ROOT/lib/carry-plan.jq" --slurpfile source "$source" --argjson destinations "$destinations" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)")" || exit 1
  [ -n "$(jq -r '.report.issues_without_destination[]?' <<< "$plan")" ] && die "issues without a destination: $(jq -r '.report.issues_without_destination | join(", ")' <<< "$plan")"
  printf '%s\n' "$plan" > "$work/plan.json"

  # the destinations are read once each, before the report, because their pages and missing labels are part of the bound
  for key in $(jq -r '.report.destinations[]' <<< "$plan"); do
    clone="$(awk -F'\t' -v k="$key" '$3 == k { print $2; exit }' "$work/clones.tsv")"
    pages="$(carry_in_clone "$clone" plane_carry_metadata)" || exit 1
    m=$(( m + ${pages#metadata } ))
    missing="$(jq -c --arg k "$key" 'select(.dest == $k)' <<< "$(jq -c '.rows[]' <<< "$plan")" | carry_in_clone "$clone" plane_carry_missing_labels)" || exit 1
    l=$(( l + missing ))
  done
  carry_report "$plan" "$m" "$l"
  [ "$label" = full ] && echo "repositories with no issue, which need no destination: ${no_issues:-none}"

  results="$work/results.tsv"; : > "$results"
  flush_batch() {
    [ -z "$batch_clone" ] || printf '%s' "$batch" | carry_in_clone "$batch_clone" plane_carry_batch >> "$results" || exit 1
    batch=""
  }
  while IFS= read -r line; do
    clone="$(awk -F'\t' -v k="$(jq -r '.dest' <<< "$line")" -v r="$(jq -r '.repo // ""' <<< "$line")" '$3 == k && (r == "" || $1 == r) { print $2; exit }' "$work/clones.tsv")"
    if [ "$clone" != "$batch_clone" ]; then flush_batch; batch_clone="$clone"; fi
    batch="$batch$line"$'\n'
  done < <(jq -c '.rows[]' <<< "$plan")
  flush_batch

  while IFS=$'\t' read -r status ref ident address outcome; do
    case "$status" in
      OK) case "$ref" in
            */*"#"*)
              case "$outcome" in complete) issues_complete=$((issues_complete + 1)) ;; created) issues_new=$((issues_new + 1)) ;; resumed) issues_resumed=$((issues_resumed + 1)) ;; esac
              if [ "$label" = short ]; then echo "#${ref##*#} -> $ident"; else echo "$ref -> $ident"; fi ;;
            *)
              case "$outcome" in complete) boards_complete=$((boards_complete + 1)) ;; *) boards_new=$((boards_new + 1)) ;; esac
              echo "board $(jq -r --arg r "$ref" '.rows[] | select(.ref == $r) | .title' <<< "$plan" | head -n1) -> $ident" ;;
          esac ;;
      INCOMPLETE)
        case "$ref" in */*"#"*) incomplete=$((incomplete + 1)) ;; *) boards_incomplete=$((boards_incomplete + 1)) ;; esac
        echo "INCOMPLETE $ref: $ident" >&2 ;;
    esac
  done < "$results"
  echo "carried $((issues_complete + issues_new + issues_resumed)) of $(jq -r '.report.issues' <<< "$plan") issues: $issues_complete already complete, $issues_new newly created, $issues_resumed finished from an earlier run, $incomplete incomplete"
  if [ "$label" = full ]; then
    echo "board records: $((boards_complete + boards_new)) of $(jq -r '.report.board_records' <<< "$plan") ($boards_complete already there, $boards_new newly created, $boards_incomplete incomplete) for $(jq -r '.report.boards_source' <<< "$plan") boards"
  fi
  [ "$incomplete" = 0 ] && [ "$boards_incomplete" = 0 ]
}
