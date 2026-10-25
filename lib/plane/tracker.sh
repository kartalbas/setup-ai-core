#!/usr/bin/env bash
# The tracker of this harness on Plane: work items, their states, priorities, labels, parents and
# relations, asked with curl. lib/tracker.sh sources it when TRACKER is plane. The functions stand under
# the names lib/board.sh and every command in bin/ call, with the arguments and the rows of
# lib/github/tracker.sh; a call Plane's API cannot serve is refused with its own sentence. Source it, do
# not run it.
#
# THE MAPPING: an issue is a work item, `#n` is its sequence_id in the project, an epic is
# a work item with children (parent), a board column is a state of the project with the column's name, and
# the priorities P0 to P3 are Plane's urgent, high, medium and low. A body and a comment are the Markdown
# escaped inside one <pre>, which the read side strips again. Settings: PLANE_URL, PLANE_WORKSPACE,
# PLANE_PROJECT (the identifier, the ENG of ENG-142) and PLANE_TOKEN_COMMAND.
#
# PLANE 1.4.2 TAKES THE IDS OF THINGS, NOT THEIR NAMES: `state`, `parent`, `labels` and `assignees` of a work
# item are uuids (apps/api/plane/api/serializers/issue.py at v1.4.2), so a name is resolved to its id before
# the write.

. "$(dirname "${BASH_SOURCE[0]}")/api.sh"

# --- the repository, the project, the user --------------------------------------

tracker_name() { echo Plane; }

repo_visibility() {
  echo "Plane cannot establish private destination visibility for $1; the public body check applies" >&2
  return 1
}

# The organisation a command acts for: GH_ORG, then the owner of the checkout's origin.
gh_org() {
  local org repo
  org="$(config_value GH_ORG "")"
  if [ -n "$org" ]; then export GH_ORG="$org"; echo "$org"; return 0; fi
  repo="$(origin_repo)" \
    || die "no organisation: set GH_ORG in .ai-core/config.env or the environment, or run this inside a repository of it"
  export GH_ORG="${repo%%/*}"
  echo "$GH_ORG"
}

default_repo() {
  origin_repo || die "cannot tell which repository this is - pass the repo as OWNER/REPO"
}

# plane_is_here <owner/repo>: whether it is the repository of this checkout
plane_is_here() {
  local here
  here="$(default_repo)" || exit 1
  [ "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$here" | tr '[:upper:]' '[:lower:]')" ]
}

# ONE CHECKOUT, ONE REPOSITORY: the project the checkout's PLANE_PROJECT names holds the work items of every
# repository of one line, told apart by their repo: label (plane_item), and acting on another repository's
# items from here would be a guess, so a call that names another repository is refused.
plane_check_repo() {  # plane_check_repo <owner/repo>
  plane_is_here "$1" || die "no Plane project is configured here for $1"
}

# writes_run_in_repo_clone <owner/repo>: whether a write to a work item of that repository has to run in the
# clone of that repository, which is so for every repository but this checkout's (status-sync moves the cards
# of each repository of the project from the clone that acts for it)
writes_run_in_repo_clone() { ! plane_is_here "$1"; }

# plane_repo_label: the label that says a work item belongs to the checkout's repository, repo:<name> with
# the name as the origin spells it
plane_repo_label() {
  local here
  here="$(default_repo)" || exit 1
  printf 'repo:%s\n' "${here#*/}"
}

# plane_owner: the owner of the checkout's origin, the owner every repo: label of the project is read under
plane_owner() {
  local here
  here="$(default_repo)" || exit 1
  printf '%s\n' "${here%%/*}"
}

# plane_check_owner <owner/repo>: a read over the work items of one repository of the project; the project
# holds the repositories of the origin's owner, and no other owner's repository is in it
plane_check_owner() {
  [ "$(printf '%s' "${1%%/*}" | tr '[:upper:]' '[:lower:]')" = "$(plane_owner | tr '[:upper:]' '[:lower:]')" ] \
    || die "no Plane project is configured here for $1"
}

# The repository of a work item whose labels are expanded: the owner of the checkout's origin and the name
# its repo: label carries; failing that the repository a carried item names in its external_id
# (<owner/repo>#<n> from GitHub); otherwise null. carried_from is that external_id of a carried item, else null. An item without either belongs to no repository, and is
# never listed under the checkout's. An item that carries two repo: labels names no one repository: it is
# listed under none, and plane_check_item refuses to act on it.
PLANE_REPO='def carried_from: if .external_source == "github" and ((.external_id // "") | test("^[^/#]+/[^/#]+#[0-9]+$")) then .external_id else null end;
  def repo($owner):
  [.labels[]? | .name | select(startswith("repo:")) | .[5:]] as $l
  | if ($l | length) > 1 then null
    elif ($l | length) == 1 then "\($owner)/\($l[0])"
    elif carried_from then carried_from | sub("#[0-9]+$"; "")
    else null end;
  def same($a; $b): ($a // "" | ascii_downcase) == ($b | ascii_downcase);'

# A project is written by its identifier, the letters and digits before the dash of ENG-142, and a checkout
# serves the one PLANE_PROJECT names: every call after set_project reads that project, so another identifier
# would be answered with this project's work items under its name.
check_project_number() {  # check_project_number <project identifier>
  case "$1" in ''|*[!A-Za-z0-9_]*) die "the Plane project must be written by its identifier, not '$1'" ;; esac
  [ "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" = "$(plane_setting PLANE_PROJECT | tr '[:upper:]' '[:lower:]')" ] \
    || die "this checkout is set up for the Plane project $(plane_setting PLANE_PROJECT), not $1: PLANE_PROJECT in .ai-core/config.env names the one it serves"
}

resolve_project_for_repo() {  # resolve_project_for_repo <owner/repo>
  plane_check_repo "$1"
  plane_setting PLANE_PROJECT
}

# Plane copies no template project: project-new creates the project with its states and labels
template_project_number() { :; }

repo_open_projects() {  # repo_open_projects <owner/repo>
  plane_check_repo "$1"
  printf '%s\t%s\n' "$(plane_setting PLANE_PROJECT)" "$(plane_setting PLANE_PROJECT)"
}

# board_cache_name: where the cache of this project stands under the cache root (lib/board.sh cache_dir). The
# same identifier in another workspace, or on another instance, is another project with other ids, and
# a cache that does not say so answers for it with the ids of the first.
board_cache_name() { plane_cache_name "$(plane_setting PLANE_PROJECT)"; }

plane_cache_name() {  # plane_cache_name <project identifier>
  printf 'plane/%s/%s/%s\n' \
    "$(plane_setting PLANE_URL | jq -Rr @uri)" \
    "$(plane_setting PLANE_WORKSPACE | sed 's|[^A-Za-z0-9._-]|_|g')" "$(printf '%s' "$1" | sed 's|[^A-Za-z0-9._-]|_|g')"
}

# plane_project_cache_dir <project identifier>: where this checkout caches what it read of the project
plane_project_cache_dir() { printf '%s/%s\n' "$(cache_root)" "$(plane_cache_name "$1")"; }

# plane_project_uuid [project identifier]: the uuid of the project, PLANE_PROJECT when none is named, kept
# beside the other caches of the project. The id of a project does not change, so the file is the answer until
# somebody deletes it; project_create writes it for a project it made.
plane_project_uuid() {
  local ident f rows id
  ident="${1:-$(plane_setting PLANE_PROJECT)}"
  f="$(plane_project_cache_dir "$ident")/project-id"
  if [ -s "$f" ]; then id="$(cat "$f")"
  else
    rows="$(plane_pages "the projects of $(plane_setting PLANE_WORKSPACE)" "$(plane_path projects/)")" || exit 1
    id="$(jq -r --arg i "$ident" 'select(.identifier == $i) | .id' <<< "$rows" | sed -n 1p)"
    [ -n "$id" ] || die "Plane has no project with the identifier $ident in the workspace $(plane_setting PLANE_WORKSPACE)"
  fi
  # the one shape an id has, wherever it came from: a file written by hand is not trusted
  case "$id" in
    ????????-????-????-????-????????????) ;;
    *) die "$f does not hold a project id - delete it and run again. It holds: $id" ;;
  esac
  [ -s "$f" ] || { mkdir -p "$(dirname "$f")"; printf '%s\n' "$id" > "$f"; }
  printf '%s\n' "$id"
}

project_id() { plane_project_uuid; }

# plane_user_id <email | @me>: the uuid of a member of the workspace
plane_user_id() {
  local who="$1" answer id
  if [ "$who" = @me ]; then
    answer="$(plane_api "who the Plane key belongs to" GET /api/v1/users/me/)" || exit 1
    id="$(printf '%s' "$answer" | jq -r '.id // empty')"
  else
    answer="$(plane_api "the members of $(plane_setting PLANE_WORKSPACE)" GET "$(plane_path members/)")" || exit 1
    id="$(printf '%s' "$answer" | jq -r --arg e "$who" '[.[] | select((.email | ascii_downcase) == ($e | ascii_downcase)) | .id][0] // empty')"
  fi
  [ -n "$id" ] || die "Plane has no member $who in the workspace $(plane_setting PLANE_WORKSPACE)"
  printf '%s\n' "$id"
}

# plane_check_assignable <user id> <member rows> <who, as the refusal names it>: dies unless that user is an active member of the
# project with a role of 15 or more, the only kind of user Plane keeps as an assignee: it drops every other without a word
# (validate() of apps/api/plane/api/serializers/issue.py at v1.4.2), and a project's default assignee takes the place of an empty list
plane_check_assignable() {
  printf '%s\n' "$2" | jq -e --arg i "$1" 'select(.id == $i and .is_active == true and .role >= 15)' > /dev/null \
    || die "$3 is not an active member of the project $(plane_setting PLANE_PROJECT) with a role of 15 or more, and Plane keeps no assignee who is not one: nothing was written"
}

# plane_assignee_id <email | @me> <member rows>: the uuid of that user, checked to be one Plane keeps as an assignee; the rows are
# those of plane_member_rows, read once by the caller for all its assignees
plane_assignee_id() {
  local id
  id="$(plane_user_id "$1")" || exit 1
  plane_check_assignable "$id" "$2" "the assignee $1"
  printf '%s\n' "$id"
}

# tracker_login: the email the key's user is known by, which is what a Plane assignee is written as
tracker_login() {
  local who email
  who="$(plane_api "who the Plane key belongs to" GET /api/v1/users/me/)" || exit 1
  email="$(printf '%s' "$who" | jq -r '.email // ""')"
  [ -n "$email" ] || die "cannot read who the Plane key belongs to - the answer has no email"
  echo "$email"
}

# The doctor line: the tracker, where it answers, and whether the key does. Never the key.
tracker_doctor() {
  local url
  url="$(config_value PLANE_URL "")"
  if [ -z "$url" ] || [ -z "$(config_value PLANE_WORKSPACE "")" ] || [ -z "$(config_value PLANE_PROJECT "")" ] \
     || [ -z "$(config_value PLANE_TOKEN_COMMAND "")" ]; then
    echo "  tracker: plane"
    report tracker "not configured" "set PLANE_URL, PLANE_WORKSPACE, PLANE_PROJECT and PLANE_TOKEN_COMMAND in .ai-core/config.env"; problem
    return 0
  fi
  plane_call GET "$(plane_path projects/)"
  case "$plane_status" in
    2??) echo "  tracker: plane ($url, the key answers)" ;;
    000) echo "  tracker: plane"; report tracker "not reachable" "$url did not answer"; problem ;;
    *)   echo "  tracker: plane"; report tracker "refused" "the Plane API answered $plane_status at $url"; problem ;;
  esac
}

# --- the text of a body and a comment ---------------------------------------------

# A body is stored as description_html, the Markdown escaped inside one <pre>: Plane stores HTML, and the
# harness reads Markdown (the file:line of issue-map, the thread of issue-thread) back out of it exactly.
# What this cannot guarantee: a body that opens with a line break loses it, because HTML drops the first
# line break after <pre>.
PLANE_TEXT='def text:
  if startswith("<pre>") and endswith("</pre>") then .[5:-6]
  else gsub("</p>"; "\n") | gsub("<[^>]*>"; "") end
  | gsub("&lt;"; "<") | gsub("&gt;"; ">") | gsub("&amp;"; "&");'
PLANE_HTML='def html: "<pre>" + (gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;")) + "</pre>";'

# The html a write sends for a body that is in a file or in a text
plane_html_of() {  # plane_html_of <text> <file or empty>
  { if [ -n "$2" ]; then cat "$2"; else printf '%s' "$1"; fi; } | jq -Rrs "$PLANE_HTML"' html'
}

# --- the work item ------------------------------------------------------------------

# plane_fetch <number>: the work item <IDENT>-<number> as JSON, its state, labels and parent expanded
plane_fetch() {
  case "$1" in ''|*[!0-9]*) die "the issue number must be numeric, not '$1'" ;; esac
  plane_api "the work item $(plane_setting PLANE_PROJECT)-$1" GET "$(plane_path "issues/$(plane_setting PLANE_PROJECT)-$1/")?expand=state,labels,parent"
}

# plane_check_item <work item json> <owner/repo> <number>: refused, naming the repository, where the work item
# belongs to another repository than <owner/repo>, or carries two repo: labels and so belongs to none. The
# number counts per project, and a number given for one repository can be another's.
plane_check_item() {
  local verdict
  verdict="$(printf '%s' "$1" | jq -r --arg me "repo:${2#*/}" '
    [.labels[].name | select(startswith("repo:"))] as $r
    | if ($r | length) > 1 then "many \($r | join(" "))"
      elif ($r | length) == 1 and ($r[0] | ascii_downcase) != ($me | ascii_downcase) then "other \($r[0][5:])"
      else empty end')"
  case "$verdict" in
    '') ;;
    other\ *) if plane_is_here "$2"; then die "#$3 belongs to ${verdict#other }, not this checkout - nothing was changed"; fi
              die "#$3 belongs to ${verdict#other }, not $2 - nothing was changed" ;;
    *) die "#$3 carries more than one repository label (${verdict#many }), so it belongs to no one repository - nothing was changed" ;;
  esac
}

# plane_item_read <owner/repo> <number>: the work item, for a call that only reads: any repository of the
# owner the project holds, as long as the number is that repository's
plane_item_read() {
  local item
  plane_check_owner "$1"
  item="$(plane_fetch "$2")" || exit 1
  plane_check_item "$item" "$1" "$2"
  printf '%s\n' "$item"
}

# plane_item <owner/repo> <number>: the work item, for a call that acts on it: this checkout's repository
# only, and one whose repo: label names another is refused before anything is written
plane_item() {
  plane_check_repo "$1"
  plane_item_read "$1" "$2"
}

# plane_issue_path <work item json>: the path of the work item to read and write by its uuid
plane_issue_path() { printf '%s' "$1" | jq -r '"projects/\(.project)/issues/\(.id)/"'; }

# plane_relations_path <work item json>: Plane 1.4 serves the relations only under work-items/
plane_relations_path() { printf '%s' "$1" | jq -r '"projects/\(.project)/work-items/\(.id)/relations/"'; }

# plane_patch <what> <owner/repo> <number> <json>: a partial update of the work item
plane_patch() {
  local item
  item="$(plane_item "$2" "$3")" || exit 1
  plane_api "$1" PATCH "$(plane_path "$(plane_issue_path "$item")")" "$4" >/dev/null || exit 1
}

# plane_states: the states of the project, one JSON object per line, without the triage state
plane_states() {
  local rows
  rows="$(plane_pages "the states of $(plane_setting PLANE_PROJECT)" "$(plane_path "projects/$(plane_project_uuid)/states/")")" || exit 1
  printf '%s\n' "$rows" | jq -c 'select(.group != "triage")'
}

# plane_state_id <name | group:<group>>: the uuid of the state of that name, matched without case, or of the
# first state of that group; refused, with the states there are, where none matches
plane_state_id() {
  local rows id
  rows="$(plane_states)" || exit 1
  case "$1" in
    group:*) id="$(jq -r --arg g "${1#group:}" 'select(.group == $g) | .id' <<< "$rows" | sed -n 1p)" ;;
    *)       id="$(jq -r --arg n "$1" 'select((.name | ascii_downcase) == ($n | ascii_downcase)) | .id' <<< "$rows" | sed -n 1p)" ;;
  esac
  [ -n "$id" ] || die "the Plane project $(plane_setting PLANE_PROJECT) has no state '${1#group:}'. It has: $(printf '%s\n' "$rows" | jq -r '.name' | paste -sd' ' -)"
  printf '%s\n' "$id"
}

# issue_create <owner/repo> <title> <body file> <assignee> [label...]: prints the number of the new work item,
# with the label of the checkout's repository on it. Plane drops a label id of another project without a word,
# so the item is read back and refused by name where the label is not there; the assignee is checked before the write.
issue_create() {
  local repo="$1" title="$2" body="$3" assignee="$4" label ids members aid html request created id n back project
  shift 4
  plane_check_repo "$repo"
  label="$(plane_repo_label)"
  ids="$(plane_label_ids "$@" "$label")" || exit 1
  members="$(plane_member_rows)" || exit 1
  aid="$(plane_assignee_id "$assignee" "$members")" || exit 1
  html="$(plane_html_of "" "$body")" || exit 1
  request="$(jq -n --arg name "$title" --arg html "$html" --argjson labels "$ids" --arg a "$aid" \
    '{name: $name, description_html: $html, labels: $labels, assignees: [$a], external_source: "ai-core"}')"
  project="$(plane_project_uuid)" || exit 1
  created="$(plane_api "the issue created in $repo, which was NOT created" POST "$(plane_path "projects/$project/issues/")" "$request")" || exit 1
  id="$(printf '%s' "$created" | jq -r '.id')"; n="$(printf '%s' "$created" | jq -r '.sequence_id')"
  back="$(plane_api "the work item $(plane_setting PLANE_PROJECT)-$n just created" GET "$(plane_path "projects/$(plane_project_uuid)/issues/$id/")?expand=labels")" \
    || die "#$n exists in $repo after the create; the read-back above failed, so do not create it again"
  printf '%s' "$back" | jq -e --arg l "$label" 'any(.labels[]; .name == $l)' >/dev/null \
    || die "Plane dropped the label $label of #$n: the label id belongs to another project - #$n exists without it"
  printf '%s\n' "$n"
}

# plane_find_carried <external_id>: the work item carried from GitHub under that external_id, as JSON, or nothing.
# Plane 1.4.2 serves this one query on the list: GET .../issues/?external_id=&external_source=github answers the
# one object (apps/api/plane/api/views/issue.py at v1.4.2), archived items included. A 404 is read as "none".
plane_find_carried() {
  plane_call GET "$(plane_path "projects/$(plane_project_uuid)/issues/")?external_source=github&external_id=$(jq -rn --arg e "$1" '$e | @uri')"
  case "$plane_status" in
    2??) printf '%s' "$plane_body" | jq -e --arg e "$1" 'type == "object" and .external_id == $e and .external_source == "github" and (.sequence_id | type == "number")' >/dev/null 2>&1 \
           || die "the Plane API answered $plane_status for the work item carried from $1, and the answer is not that work item: $(printf '%s' "$plane_body" | tr -s '\r\n' '  ' | cut -c1-300)"
         printf '%s\n' "$plane_body" ;;
    404) ;;
    000) die "cannot read the work item carried from $1 - the Plane API did not answer: $plane_body" ;;
    *)   die "cannot read the work item carried from $1 - the Plane API answered $plane_status${plane_body:+: $(printf '%s' "$plane_body" | tr -s '\r\n' '  ' | cut -c1-300)}" ;;
  esac
}

# --- the issue carry: a work item for every row of lib/carry-plan.jq ---------------------------
# Run in the clone that owns the destination, with TRACKER=plane and CARRY_RUN naming the directory of this run.
# A destination is read ONCE per run: its project, states and labels stand in files of CARRY_RUN, scoped by the full
# URL, workspace and project; so do the work items carried so far (ref, uuid, number), which a sub-issue of the same
# destination reads without a request. WHAT A PERSON CHANGED IN PLANE IS NEVER WRITTEN BACK: a work item found by
# its external id is not patched, not its state, parent, archive date, assignee, title, body, labels or priority, and a comment
# found by its external id is not edited. State, parent, archive date and assignee are set in the one create request.

carry_dir() {
  local d
  d="${CARRY_RUN:?CARRY_RUN names the directory of this run}/$(printf '%s|%s|%s' "$(plane_setting PLANE_URL)" "$(plane_setting PLANE_WORKSPACE)" "$(plane_setting PLANE_PROJECT)" | cksum | cut -d' ' -f1)"
  mkdir -p "$d"
  printf '%s\n' "$d"
}

# plane_carry_metadata: reads the project, its states and its labels once for this destination and prints
# the number of pages that took: "metadata <n>"
plane_carry_metadata() {
  local dir pages=0 ident project
  dir="$(carry_dir)"
  if [ ! -s "$dir/states.jsonl" ]; then
    ident="$(plane_setting PLANE_PROJECT)"
    [ -s "$(plane_project_cache_dir "$ident")/project-id" ] || pages=1
    project="$(plane_project_uuid)" || exit 1
    plane_states > "$dir/states.jsonl" || exit 1
    plane_pages "the labels of $ident" "$(plane_path "projects/$project/labels/")" > "$dir/labels.jsonl" || exit 1
    pages=$(( pages + $(wc -l < "$dir/states.jsonl") / 100 + 1 + $(wc -l < "$dir/labels.jsonl") / 100 + 1 ))
    : >> "$dir/carried.tsv"
  fi
  echo "metadata $pages"
}

# plane_carry_missing_labels: the rows of the plan for this destination on standard input; prints how many of their
# labels the project lacks
plane_carry_missing_labels() {
  jq -s --slurpfile have "$(carry_dir)/labels.jsonl" '[.[].labels[]] | unique | map(select(. as $n | $have | map(.name) | index($n) | not)) | length'
}

# plane_carry_key_user: reads once for this destination who the Plane key's user is and that it can be an assignee; stores its id
# for plane_carry_row and prints "key-user <requests>", the most requests it made
plane_carry_key_user() {
  local id rows
  id="$(plane_user_id @me)" || exit 1
  rows="$(plane_member_rows)" || exit 1
  plane_check_assignable "$id" "$rows" "the Plane key's user"
  printf '%s\n' "$id" > "$(carry_dir)/key-user"
  echo "key-user $(( 1 + $(printf '%s\n' "$rows" | wc -l) / 100 + 1 ))"
}

# carry_state_id <mode> <name>: the state a work item is created in. A named state must belong to an open group; the
# default is the project's own default state, which must belong to one too; done is the state done of the completed
# group, and a cancelled issue stands in the first state of the cancelled group
carry_state_id() {
  local dir id
  dir="$(carry_dir)"
  case "$1" in
    status)    id="$(jq -r --arg n "$2" 'select((.name | ascii_downcase) == ($n | ascii_downcase) and (.group | IN("backlog", "unstarted", "started"))) | .id' "$dir/states.jsonl" | sed -n 1p)" ;;
    done)      id="$(jq -r 'select(.group == "completed") | [(.name | ascii_downcase) == "done", .id] | @tsv' "$dir/states.jsonl" | sort -r | sed -n 1p | cut -f2)" ;;
    cancelled) id="$(jq -r 'select(.group == "cancelled") | .id' "$dir/states.jsonl" | sed -n 1p)" ;;
  esac
  if [ -z "${id:-}" ] && { [ "$1" = status ] || [ "$1" = default ]; }; then
    id="$(jq -r 'select(.default == true and (.group | IN("backlog", "unstarted", "started"))) | .id' "$dir/states.jsonl" | sed -n 1p)"
    [ -n "$id" ] || die "the Plane project $(plane_setting PLANE_PROJECT) has no default state in an open group, and the work item cannot be given an open state without a guess"
  fi
  [ -n "${id:-}" ] || die "the Plane project $(plane_setting PLANE_PROJECT) has no state for '$1' in the group the source close reason names"
  printf '%s\n' "$id"
}

# carry_label_id <name>: the uuid of that label, made first where the project lacks it, with the colour and the
# description of labels.tsv; a 409 means the cache is behind, and the labels are read again once
carry_label_id() {
  local dir id rows colour desc
  dir="$(carry_dir)"
  id="$(jq -r --arg n "$1" 'select(.name == $n) | .id' "$dir/labels.jsonl" | sed -n 1p)"
  if [ -z "$id" ]; then
    rows="$(labels_tsv)" || exit 1
    colour="$(awk -F'\t' -v n="$1" '$2 == n { print $3; exit }' <<< "$rows")"
    desc="$(awk -F'\t' -v n="$1" '$2 == n { print $4; exit }' <<< "$rows")"
    plane_call POST "$(plane_path "projects/$(plane_project_uuid)/labels/")" "$(jq -nc --arg n "$1" --arg c "#${colour:-6B7280}" --arg d "${desc:-Carried from GitHub}" '{name: $n, color: $c, description: $d}')"
    case "$plane_status" in
      2??) printf '%s\n' "$plane_body" | jq -c '.' >> "$dir/labels.jsonl"; id="$(printf '%s' "$plane_body" | jq -r '.id')" ;;
      409) plane_pages "the labels of $(plane_setting PLANE_PROJECT)" "$(plane_path "projects/$(plane_project_uuid)/labels/")" > "$dir/labels.jsonl" || exit 1
           id="$(jq -r --arg n "$1" 'select(.name == $n) | .id' "$dir/labels.jsonl" | sed -n 1p)" ;;
      *)   die "cannot write the label $1 - the Plane API answered $plane_status${plane_body:+: $(printf '%s' "$plane_body" | tr -s '\r\n' '  ' | cut -c1-300)}" ;;
    esac
  fi
  [ -n "$id" ] || die "the label $1 is not in the Plane project after it was made"
  printf '%s\n' "$id"
}

# carry_known <ref>: the uuid of the work item carried from that ref in this run, "-" where this destination has none
carry_known() { awk -F'\t' -v r="$1" '$1 == r { print $2; exit }' "$(carry_dir)/carried.tsv"; }

# carry_remember <ref> <work item json | none>: the work item is known to this destination (ref, uuid, number) and, for every
# destination of the run, by its address in the browser
carry_remember() {
  local id seq
  if [ "$2" = none ]; then printf '%s\t-\t-\n' "$1" >> "$(carry_dir)/carried.tsv"; return; fi
  IFS=$'\t' read -r id seq <<< "$(jq -r '[.id, .sequence_id] | @tsv' <<< "$2")"
  printf '%s\t%s\t%s\n' "$1" "$id" "$seq" >> "$(carry_dir)/carried.tsv"
  printf '%s\t%s\n' "$1" "$(plane_item_url "$seq")" >> "$CARRY_RUN/addresses.tsv"
}

# carry_address <ref>: the address in the browser of the work item carried from that ref in any destination of this run, or nothing
carry_address() { awk -F'\t' -v r="$1" '$1 == r { print $2; exit }' "$CARRY_RUN/addresses.tsv"; }

# carry_missing <pending comments> <external ids already in Plane>: the pending comments whose external id is not there yet.
# Both reach jq on standard input: a thread can outgrow the 128 KiB Linux allows one argument.
carry_missing() { { printf '%s\n' "$1"; printf '%s\n' "$2"; } | jq -nc 'input as $pending | input as $have | $pending | map(select(.external_id as $e | $have | index($e) | not))'; }

# carry_comment_request: the comment to carry (external_id, created_at, text) on standard input; the body of the POST that writes it,
# the text escaped as in a work item. The text can be 65,536 characters of "<", which escape to 262,144.
carry_comment_request() { jq -c "$PLANE_HTML"' {comment_html: (.text | html), external_source: "github", external_id, created_at}'; }

# carry_comments <comments path> : every comment of the work item by its uuid, archived or not
carry_comments() { plane_pages "the comments of $1" "$(plane_path "$2")"; }

# plane_carry_row: one row of the plan on standard input, carried: the work item created with its state, parent,
# archive date, assignee and labels in the one request, then every missing comment and the provenance comment by external id.
# Prints "<ref>\t<IDENT-n>\t<address>\t<complete | created | resumed>"; dies naming the reason where it is incomplete.
plane_carry_row() {
  local row ref kind found project id seq request state parent_ref parent_id mode ids name pending have missing path comment posts=0 notes="" outcome verify=1
  local preexisting=1 provenance_end="" parent_link moved_to assignee=""
  row="$(cat)"
  ref="$(jq -r '.ref' <<< "$row")"; kind="$(jq -r '.kind' <<< "$row")"
  [ "$kind" != issue ] || plane_check_repo "$(jq -r '.repo' <<< "$row")"
  project="$(plane_project_uuid)" || exit 1
  mode="$(jq -r '.parent.mode // ""' <<< "$row")"; parent_ref="$(jq -r '.parent.ref // ""' <<< "$row")"; parent_id=""
  if [ "$mode" = reference ]; then
    parent_link="$(carry_address "$parent_ref")"
    [ -n "$parent_link" ] || die "$ref is a sub-issue of $parent_ref, which stands in another destination and is not carried into Plane yet - the provenance of the sub-issue names the Plane link of its parent, so the sub-issue waits for the parent. Nothing was written for it"
    provenance_end="$provenance_end"$'\n'"Plane parent link: $parent_link"
  fi
  found="$(plane_find_carried "$ref")" || exit 1
  outcome=complete
  if [ -z "$found" ]; then
    outcome=created; preexisting=0
    case "$mode" in
      selected) parent_id="$(carry_known "$parent_ref")"
                [ -n "$parent_id" ] && [ "$parent_id" != - ] || die "$ref is a sub-issue of $parent_ref, which is not carried into Plane in this destination - the sub-issue waits for the parent. Nothing was written for it" ;;
      outside)  parent_id="$(carry_known "$parent_ref")"
                if [ -z "$parent_id" ]; then
                  found="$(plane_find_carried "$parent_ref")" || exit 1
                  if [ -n "$found" ]; then carry_remember "$parent_ref" "$found"; else carry_remember "$parent_ref" none; fi
                  parent_id="$(carry_known "$parent_ref")"
                fi
                [ "$parent_id" != - ] || parent_id="" ;;
    esac
    state="$(carry_state_id "$(jq -r '.state.mode' <<< "$row")" "$(jq -r '.state.name // ""' <<< "$row")")" || exit 1
    ids="[]"
    while IFS= read -r name; do
      ids="$(jq -c --arg i "$(carry_label_id "$name")" '. + [$i]' <<< "$ids")"
    done < <(jq -r '.labels[]' <<< "$row")
    if [ "$(jq -r '.assigned_to_key_user' <<< "$row")" = true ]; then assignee="$(cat "$(carry_dir)/key-user")" || exit 1; fi
    request="$(jq -c --arg state "$state" --arg parent "$parent_id" --arg assignee "$assignee" --argjson labels "$ids" --arg today "$(date -u +%F)" "$PLANE_HTML"'
      {name: .title, description_html: (.body | html), labels: $labels, external_source: "github", external_id: .ref, priority: .priority, state: $state}
      + (if $parent != "" then {parent: $parent} else {} end) + (if $assignee != "" then {assignees: [$assignee]} else {} end) + (if .archived then {archived_at: $today} else {} end)' <<< "$row")"
    plane_call POST "$(plane_path "projects/$project/issues/")" "$request"
    case "$plane_status" in
      2??) ;;
      000) notes="the answer to the create did not arrive" ;;
      409) notes="Plane answered 409 to the create"; outcome=resumed; verify=0; preexisting=1 ;;
      *)   die "the work item carried from $ref was NOT created - the Plane API answered $plane_status${plane_body:+: $(printf '%s' "$plane_body" | tr -s '\r\n' '  ' | cut -c1-300)}" ;;
    esac
    found="$(plane_find_carried "$ref")" || exit 1
    [ -n "$found" ] || die "the work item carried from $ref was not found by its external_id after the create (${notes:-Plane answered $plane_status}): nothing is known to exist. Run the same command again"
    [ "$verify" = 0 ] || jq -e --arg s "$state" --arg p "$parent_id" --arg u "$assignee" --argjson a "$(jq '.archived' <<< "$row")" \
      '.state == $s and ((.parent // "") == $p) and ((.archived_at != null) == $a) and ($u == "" or ((.assignees // []) | index($u) != null))' <<< "$found" >/dev/null \
      || die "the work item carried from $ref was stored with another state, parent, archive date or assignee than it was given: $(jq -c '{state, parent, archived_at, assignees}' <<< "$found")"
  fi
  id="$(jq -r '.id' <<< "$found")"; seq="$(jq -r '.sequence_id' <<< "$found")"
  carry_remember "$ref" "$found"
  moved_to="$(jq -r '.moved_to // ""' <<< "$row")"
  if [ "$preexisting" = 1 ] && [ -n "$moved_to" ] && [ "$moved_to" = "$(plane_item_url "$seq")" ]; then
    provenance_end="$provenance_end"$'\n'"Earlier carry: the work item $moved_to stood in Plane before this carry, the issue holds the comment \"Moved to $moved_to\", and its NOT_PLANNED close came after that comment with no reopening since, so this close may be the close of an earlier carry; its cause is not established."
  fi
  if [ "$kind" = issue ]; then
    path="projects/$project/issues/$id/comments/"
    pending="$(jq -c --arg end "$provenance_end" '[.comments[], .provenance] | map({external_id, created_at, text}) | .[-1].text += $end' <<< "$row")"
    have="[]"
    if [ "$outcome" != created ]; then
      have="$(carry_comments "$ref" "$path" | jq -sc 'map(select(.external_source == "github") | .external_id)')" || exit 1
    fi
    missing="$(carry_missing "$pending" "$have")"
    while IFS= read -r comment; do
      [ -n "$comment" ] || continue
      plane_call POST "$(plane_path "$path")" "$(carry_comment_request <<< "$comment")"
      posts=$((posts + 1))
      case "$plane_status" in
        2??) ;;
        000) notes="$notes; the answer to the comment $(jq -r '.external_id' <<< "$comment") did not arrive" ;;
        409) notes="$notes; the comment identity $(jq -r '.external_id' <<< "$comment") stands on another work item of the project" ;;
        *)   notes="$notes; the comment $(jq -r '.external_id' <<< "$comment") was refused with $plane_status" ;;
      esac
    done < <(jq -c '.[]' <<< "$missing")
    if [ "$posts" -gt 0 ]; then
      have="$(carry_comments "$ref" "$path" | jq -sc 'map(select(.external_source == "github") | .external_id)')" || exit 1
      missing="$(carry_missing "$pending" "$have" | jq -c 'map(.external_id)')"
      [ "$missing" = "[]" ] || die "the work item $ref is incomplete: $(jq -r 'length' <<< "$missing") of its comments or its provenance are not in Plane${notes:+ ($notes)}. Run the same command again: it finishes what is missing"
      [ "$outcome" != complete ] || outcome=resumed
    fi
  fi
  printf '%s\t%s-%s\t%s\t%s\n' "$ref" "$(plane_setting PLANE_PROJECT)" "$seq" "$(plane_item_url "$seq")" "$outcome"
}

# plane_carry_batch: rows of the plan on standard input, each carried alone; prints "OK\t<row result>" or
# "INCOMPLETE\t<ref>\t<reason>" for each, and goes on after an incomplete one
plane_carry_batch() {
  local row ref err
  err="$(carry_dir)/error"
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    ref="$(jq -r '.ref' <<< "$row")"
    if out="$( (plane_carry_row <<< "$row") 2>"$err")"; then printf 'OK\t%s\n' "$out"
    else printf 'INCOMPLETE\t%s\t%s\n' "$ref" "$(sed 's/^error: //' "$err" | tr -s '\r\n' '  ' | cut -c1-400)"; fi
    grep -v '^error:' "$err" >&2 || true
  done
}

# plane_label_ids <name>...: a JSON array of the uuids of these labels of the project; a name the project
# lacks stops the create and says how to make it, the way a missing label does on GitHub
plane_label_ids() {
  local rows name ids="[]" id
  rows="$(plane_pages "the labels of $(plane_setting PLANE_PROJECT)" "$(plane_path "projects/$(plane_project_uuid)/labels/")")" || exit 1
  for name in "$@"; do
    id="$(jq -r --arg n "$name" 'select(.name == $n) | .id' <<< "$rows" | sed -n 1p)"
    [ -n "$id" ] || die "the issue was NOT created - the Plane project has no label '$name'. Run: ai-core labels-sync"
    ids="$(jq -c --arg i "$id" '. + [$i]' <<< "$ids")"
  done
  printf '%s\n' "$ids"
}

# issue_edit <owner/repo> <number> <title or empty> <body file or empty>
issue_edit() {
  local request html=""
  [ -z "$4" ] || html="$(plane_html_of "" "$4")" || exit 1
  request="$(jq -n --arg t "$3" --arg h "$html" \
    '{} + (if $t != "" then {name: $t} else {} end) + (if $h != "" then {description_html: $h} else {} end)')"
  plane_patch "the edit of $1#$2" "$1" "$2" "$request"
}

# issue_body <owner/repo> <number>: the Markdown of the body
issue_body() {
  plane_item "$1" "$2" | jq -r "$PLANE_TEXT"' .description_html // "" | text'
}

# issue_close <owner/repo> <number> <completed | not-planned>: ONE WRITE, where GitHub needs two. completed
# is the state `done`; not-planned is the state of the cancelled group, Plane's own Cancelled.
issue_close() {
  local target="done" state
  [ "$3" != not-planned ] || target="group:cancelled"
  state="$(plane_state_id "$target")" || exit 1
  plane_patch "the close of $1#$2" "$1" "$2" "$(jq -nc --arg s "$state" '{state: $s}')"
}

issue_reopen() {  # issue_reopen <owner/repo> <number>: the state `ready`
  local state
  state="$(plane_state_id ready)" || exit 1
  plane_patch "the reopen of $1#$2" "$1" "$2" "$(jq -nc --arg s "$state" '{state: $s}')"
}

# issue_comment_post <owner/repo> <number> <text> <text file>: prints the address of the work item, because
# Plane's API answers no address for a comment
issue_comment_post() {
  local item html
  item="$(plane_item "$1" "$2")" || exit 1
  html="$(plane_html_of "$3" "$4")" || exit 1
  plane_api "the comment posted on $1#$2" POST "$(plane_path "$(plane_issue_path "$item")comments/")" \
    "$(jq -nc --arg h "$html" '{comment_html: $h}')" >/dev/null || exit 1
  plane_item_url "$2"
}

# plane_item_url <number>: the address of the work item <IDENT>-<number> in the browser
plane_item_url() {
  printf '%s/%s/browse/%s-%s/\n' "$(plane_setting PLANE_URL | sed 's|/*$||')" "$(plane_setting PLANE_WORKSPACE)" "$(plane_setting PLANE_PROJECT)" "$1"
}

# issue_thread <owner/repo> <number>: the work item and its whole comment thread as one JSON object:
#   {number,title,state,labels,body,carriedFrom,createdAt,comments:[{author,created_at,body}]}
# carriedFrom is the GitHub reference a carried work item came from, else null; createdAt is the work item's
issue_thread() {
  local item comments
  item="$(plane_item "$1" "$2")" || exit 1
  comments="$(plane_pages "the comments of $1#$2" "$(plane_path "$(plane_issue_path "$item")comments/")?expand=actor")" || exit 1
  printf '%s\n%s\n' "$item" "$comments" | jq -s "$INSTANT_JQ""$PLANE_REPO""$PLANE_TEXT"'
    .[0] as $i | .[1:] as $c | {
      number: $i.sequence_id, title: $i.name, carriedFrom: ($i | carried_from), createdAt: $i.created_at,
      state: (if ($i.state.group | IN("completed", "cancelled")) then "closed" else "open" end),
      labels: [$i.labels[].name | select(startswith("repo:") | not)], body: (($i.description_html // "") | text),
      comments: ($c | sort_by(.created_at | instant_key) | map({author: (.actor.display_name // .actor.email // ""),
                       created_at: .created_at, body: ((.comment_html // "") | text)})) }'
}

# referenced_issue <owner/repo or empty> <number> <time or empty>: the work item that a reference to <number> of the repository
# (the checkout's own where none is given),
# made at <time> (whole seconds since 1970), names. The reference is a branch or a directory named
# issue-<number>-..., or a commit's (#<number>). After a carry from GitHub a number is both a GitHub number of the
# repository and the number of a work item of the project, and the time tells which was meant. The own item is the
# work item <number> where it exists and belongs to the repository (no label of another one), and the carried item
# is the one carried from <owner/repo>#<number>; carried under that same number, it is the own item, and the answer
# whatever the time. Prints the number of the work item, or a tab and the reason where the reference names none:
#   the own item, where it was made at or before the time;
#   after the time: the carried item, or none, the reference names a GitHub issue nothing was carried from;
#   no time: the own item where nothing was carried from the reference, none where both exist;
#   no own item: the carried item, else <number> itself, which the reader of it then answers for.
# A repository of another owner is not in the project: its reference stays <number>.
referenced_issue() {
  local repo="${1:-$(default_repo)}" number="$2" at="${3:-}" own="" own_at="" carried="" c=""
  if [ "$(printf '%s' "${repo%%/*}" | tr '[:upper:]' '[:lower:]')" != "$(plane_owner | tr '[:upper:]' '[:lower:]')" ]; then
    printf '%s\n' "$number"; return 0
  fi
  plane_call GET "$(plane_path "issues/$(plane_setting PLANE_PROJECT)-$number/")?expand=labels"
  case "$plane_status" in
    2??) printf '%s' "$plane_body" | jq -e 'type == "object" and (.created_at | type == "string")' >/dev/null 2>&1 \
           || die "the Plane API answered $plane_status for the work item $(plane_setting PLANE_PROJECT)-$number, and the answer is not that work item: $(printf '%s' "$plane_body" | tr -s '\r\n' '  ' | cut -c1-300)"
         if printf '%s' "$plane_body" | jq -e --arg l "repo:${repo#*/}" '
              [.labels[]?.name | select(startswith("repo:"))] as $r
              | ($r | length) == 0 or (($r | length) == 1 and (($r[0] | ascii_downcase) == ($l | ascii_downcase)))' >/dev/null; then
           own="$number"; own_at="$(instant_seconds "$(printf '%s' "$plane_body" | jq -r '.created_at')")" || exit 1
         fi ;;
    404) ;;
    000) die "cannot read the work item $(plane_setting PLANE_PROJECT)-$number - the Plane API did not answer: $plane_body" ;;
    *)   die "cannot read the work item $(plane_setting PLANE_PROJECT)-$number - the Plane API answered $plane_status${plane_body:+: $(printf '%s' "$plane_body" | tr -s '\r\n' '  ' | cut -c1-300)}" ;;
  esac
  if [ -n "$own" ] && [ -n "$at" ] && [ "$at" -ge "$own_at" ]; then printf '%s\n' "$own"; return 0; fi
  carried="$(plane_find_carried "$repo#$number")" || exit 1
  [ -z "$carried" ] || c="$(printf '%s' "$carried" | jq -r '.sequence_id')"
  if [ "$c" = "$number" ]; then printf '%s\n' "$number"; return 0; fi
  if [ -z "$own" ]; then printf '%s\n' "${c:-$number}"
  elif [ -n "$at" ]; then
    if [ -n "$c" ]; then printf '%s\n' "$c"
    else printf '\tnames GitHub %s#%s, which no work item was carried from\n' "$repo" "$number"; fi
  elif [ -n "$c" ]; then
    printf '\tnames both #%s and #%s, which was carried from %s#%s, and when it was made cannot be read\n' "$number" "$c" "$repo" "$number"
  else printf '%s\n' "$own"; fi
}

# A work item has one identity here, its uuid
issue_node_id() { plane_item "$1" "$2" | jq -r '.id'; }
issue_db_id() { issue_node_id "$@"; }

issue_title() {  # issue_title <owner/repo> <number>
  plane_item "$1" "$2" | jq -r '.name'
}

# --- labels -------------------------------------------------------------------------

issue_labels() {  # issue_labels <owner/repo> <number>: the names, one per line
  plane_item "$1" "$2" | jq -r '.labels[].name | select(startswith("repo:") | not)'
}

# issue_labels_set <owner/repo> <number> <+name | -name>...: Plane replaces the labels of a work item by the
# list it is given, so the list is the work item's own, with these added and removed
issue_labels_set() {
  local repo="$1" n="$2" item rows set l id
  shift 2
  plane_check_repo "$repo"
  item="$(plane_item "$repo" "$n")" || exit 1
  rows="$(plane_pages "the labels of $(plane_setting PLANE_PROJECT)" "$(plane_path "projects/$(plane_project_uuid)/labels/")")" || exit 1
  set="$(printf '%s' "$item" | jq -c '[.labels[].id]')"
  for l in "$@"; do
    id="$(jq -r --arg n "${l#?}" 'select(.name == $n) | .id' <<< "$rows" | sed -n 1p)"
    case "$l" in
      +*) [ -n "$id" ] || die "the Plane project has no label '${l#+}'. Run: ai-core labels-sync"
          set="$(jq -c --arg i "$id" '. + [$i] | unique' <<< "$set")" ;;
      -*) set="$(jq -c --arg i "$id" '. - [$i]' <<< "$set")" ;;
    esac
  done
  plane_patch "the labels of $repo#$n" "$repo" "$n" "$(jq -nc --argjson l "$set" '{labels: $l}')"
}

# plane_label_ensure <labels json lines> <name> <colour> <description>: made once, left as it is when it stands.
# A write Plane refuses may be the answer to another command having made the label first, so a refusal is
# followed by a fresh listing, and the command goes on only when that shows the exact name.
plane_label_ensure() {
  local project rows
  printf '%s\n' "$1" | jq -e --arg n "$2" 'select(.name == $n)' >/dev/null && return 0
  project="$(plane_project_uuid)" || exit 1
  plane_call POST "$(plane_path "projects/$project/labels/")" \
    "$(jq -nc --arg n "$2" --arg c "#$3" --arg d "$4" '{name: $n, color: $c, description: $d}')"
  case "$plane_status" in 2??) return 0 ;; esac
  rows="$(plane_pages "the labels of $(plane_setting PLANE_PROJECT)" "$(plane_path "projects/$project/labels/")")" || exit 1
  printf '%s\n' "$rows" | jq -e --arg n "$2" 'select(.name == $n)' >/dev/null && return 0
  die "cannot write the label $2 - the Plane API answered ${plane_status}${plane_body:+: $(printf '%s' "$plane_body" | tr -s '\r\n' '  ' | cut -c1-300)} and a fresh listing does not show it"
}

# labels_create <owner/repo> <name> <colour> <description>: made once, left as it is when it stands, and so
# is the repo: label of the checkout's repository, which every work item it creates carries
labels_create() {
  local rows own
  plane_check_repo "$1"
  own="$(plane_repo_label)"
  rows="$(plane_pages "the labels of $(plane_setting PLANE_PROJECT)" "$(plane_path "projects/$(plane_project_uuid)/labels/")")" || exit 1
  plane_label_ensure "$rows" "$own" 6B7280 "Work of the repository ${own#repo:}"
  [ "$2" = "$own" ] || plane_label_ensure "$rows" "$2" "$3" "$4"
}

# labels_list <owner/repo>: the names of the labels the project carries, one per line
labels_list() {
  plane_check_repo "$1"
  plane_pages "the labels of $(plane_setting PLANE_PROJECT)" "$(plane_path "projects/$(plane_project_uuid)/labels/")" | jq -r '.name | select(startswith("repo:") | not)'
}

# --- assignees ------------------------------------------------------------------------

issue_assignees() {  # issue_assignees <owner/repo> <number>: the emails assigned, one per line
  local item
  item="$(plane_item "$1" "$2")" || exit 1
  plane_api "the assignees of $1#$2" GET "$(plane_path "$(plane_issue_path "$item")")?expand=assignees" | jq -r '.assignees[]?.email'
}

# issue_assignees_set <owner/repo> <number> <emails, one per line>: the assignees become exactly these, each checked before the write
issue_assignees_set() {
  local ids="[]" who id members=""
  while IFS= read -r who; do
    [ -n "$who" ] || continue
    [ -n "$members" ] || members="$(plane_member_rows)" || exit 1
    id="$(plane_assignee_id "$who" "$members")" || exit 1
    ids="$(jq -c --arg i "$id" '. + [$i]' <<< "$ids")" || exit 1
  done <<< "$3"
  plane_patch "the assignees of $1#$2" "$1" "$2" "$(jq -nc --argjson a "$ids" '{assignees: $a}')"
}

# --- parents and relations ---------------------------------------------------------------

# parent_issue <reference> <owner/repo it is read against>: OWNER/REPO#N, REPO#N or a number, resolved
# before anything is created. Prints <owner/repo>\t<number>\t<uuid>\t<title>.
parent_issue() {
  local ref="$1" repo="$2" prepo num item
  case "$ref" in
    *'#'*)
      prepo="${ref%%#*}"; num="${ref#*#}"
      case "$prepo" in
        */*) ;;
        '')  die "'$ref' is not an issue reference - write OWNER/REPO#N, REPO#N, or an issue number" ;;
        *)   prepo="${repo%%/*}/$prepo" ;;
      esac ;;
    *) prepo="$repo"; num="$ref" ;;
  esac
  case "$num" in
    ''|*[!0-9]*) die "'$ref' is not an issue reference - write OWNER/REPO#N, REPO#N, or an issue number" ;;
  esac
  item="$(plane_item "$prepo" "$num")" || exit 1
  printf '%s\t%s\t%s\t%s\n' "$prepo" "$num" "$(printf '%s' "$item" | jq -r '.id')" "$(printf '%s' "$item" | jq -r '.name')"
}

# subissue_attach_resolved <parent uuid> <owner/repo> <number>: the child is that work item
subissue_attach_resolved() {
  plane_patch "the parent of $2#$3" "$2" "$3" "$(jq -nc --arg p "$1" '{parent: $p}')"
}

subissue_attach() {  # subissue_attach <owner/repo> <parent number> <child owner/repo> <child number>
  subissue_attach_resolved "$(issue_node_id "$1" "$2")" "$3" "$4"
}

subissue_detach() {  # subissue_detach <owner/repo> <parent number> <child owner/repo> <child number>
  local parent child
  parent="$(plane_item "$1" "$2")" || exit 1
  child="$(plane_item "$3" "$4")" || exit 1
  [ "$(printf '%s' "$child" | jq -r '.parent.id // ""')" = "$(printf '%s' "$parent" | jq -r '.id')" ] \
    || die "$3#$4 is not a sub-issue of $1#$2 - nothing was changed"
  plane_patch "the detach of $3#$4 from $1#$2" "$3" "$4" '{"parent": null}'
}

# issue_parent <owner/repo> <number>: the parent as "owner/repo number", or nothing
issue_parent() {
  local item parent
  item="$(plane_item "$1" "$2")" || exit 1
  parent="$(printf '%s' "$item" | jq -r '.parent.sequence_id // empty')"
  [ -n "$parent" ] || return 0
  printf '%s %s\n' "$1" "$parent"
}

# issue_block <blocked owner/repo> <blocked number> <by owner/repo> <by number>: the relation blocked_by of
# the blocked work item. Plane takes a repeated relation without a word, so it is read first and refused
# the way GitHub refuses it.
issue_block() {
  local blocked by held
  blocked="$(plane_item "$1" "$2")" || exit 1
  by="$(plane_item "$3" "$4")" || exit 1
  held="$(plane_api "the relations of $1#$2" GET "$(plane_path "$(plane_relations_path "$blocked")")")" || exit 1
  printf '%s' "$held" | jq -e --arg i "$(printf '%s' "$by" | jq -r '.id')" 'any(.blocked_by[]; .issue_id == $i)' >/dev/null \
    && die "$1#$2 is already blocked by $3#$4 - nothing was changed"
  plane_api "the block of $1#$2 by $3#$4" POST "$(plane_path "$(plane_relations_path "$blocked")")" \
    "$(jq -nc --arg i "$(printf '%s' "$by" | jq -r '.id')" '{relation_type: "blocked_by", issues: [$i]}')" >/dev/null || exit 1
}

# duplicate_mark <canonical owner/repo> <number> <duplicate owner/repo> <number> <comment>: the relation duplicate, the
# comment GitHub gets, so a person reading the thread sees it, and the duplicate in Plane's own Cancelled,
# because GitHub closes a duplicate and an open one would still hold its epic open. The state is resolved
# before the first write, so a project without one changes nothing.
duplicate_mark() {
  local canonical duplicate cancelled html
  canonical="$(plane_item "$1" "$2")" || exit 1
  duplicate="$(plane_item "$3" "$4")" || exit 1
  cancelled="$(plane_state_id group:cancelled)" || exit 1
  plane_api "the duplicate mark on $3#$4" POST "$(plane_path "$(plane_relations_path "$duplicate")")" \
    "$(jq -nc --arg i "$(printf '%s' "$canonical" | jq -r '.id')" '{relation_type: "duplicate", issues: [$i]}')" >/dev/null || exit 1
  html="$(plane_html_of "$5" "")" || exit 1
  plane_api "the duplicate mark on $3#$4" POST "$(plane_path "$(plane_issue_path "$duplicate")comments/")" \
    "$(jq -nc --arg h "$html" '{comment_html: $h}')" >/dev/null || exit 1
  plane_api "the cancel of the duplicate $3#$4" PATCH "$(plane_path "$(plane_issue_path "$duplicate")")" \
    "$(jq -nc --arg s "$cancelled" '{state: $s}')" >/dev/null || exit 1
}

# --- the board: one work item ---------------------------------------------------------------

# fields_tsv: every field with all its options, one per line, the shape of GitHub's:
#   <field name>\t<field id>\t<option name>\t<option id>\t<state group>
# Status is the project's states in the order of their sequence, with the cancelled and then the completed
# ones last, because lib/status.mjs reads the last column as the finished one; Priority the words P0 to P3
# over Plane's four, and P9, parked, over none with the label P9. The fifth column is read by this provider alone. The cache lives an hour, as on GitHub.
fields_tsv() {
  local f rows row
  f="$(cache_dir)/fields.tsv"
  [ -s "$f" ] && [ -z "$(find "$f" -mmin +60)" ] || {
    rows="$(plane_states)" || return 1
    rows="$(printf '%s\n' "$rows" | jq -rs 'sort_by([(if .group == "completed" then 2 elif .group == "cancelled" then 1 else 0 end), .sequence])[]
      | "Status\tstatus\t\(.name)\t\(.id)\t\(.group)"')"
    rows="$rows"$'\n'"$(printf 'Priority\tpriority\tP0\turgent\t\nPriority\tpriority\tP1\thigh\t\nPriority\tpriority\tP2\tmedium\t\nPriority\tpriority\tP3\tlow\t\nPriority\tpriority\tP9\tnone\t')"
    make_cache_dir
    printf '%s\n' "$rows" > "$f"
  }
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    case "$row" in
      *"	"*"	"*"	"*) ;;
      *) die "$f does not hold field rows - delete $(cache_dir) and run again. It holds: $row" ;;
    esac
  done < "$f"
  cat "$f"
}

# item_id <owner/repo> <number>: the uuid of the work item. It is on the board already.
item_id() { issue_node_id "$1" "$2"; }

# issue_board_items <owner/repo> <number>: the one board the work item is on, "<owner>/<project>\t<uuid>"
issue_board_items() {
  local id
  id="$(issue_node_id "$1" "$2")" || exit 1
  printf '%s/%s\t%s\n' "${1%%/*}" "$(plane_setting PLANE_PROJECT)" "$id"
}

# set_select <uuid> <field name> <option name>: a state or a priority, matched without case. The state asked for
# is written, whatever the work item stands in now: a command that moves a card out of Cancelled moves it.
set_select() {
  local fid oid project
  fid="$(field_id "$2")" || exit 1
  oid="$(option_id "$2" "$3")" || exit 1
  project="$(plane_project_uuid)" || exit 1
  case "$fid" in
    status)
      plane_api "the state of $1" PATCH "$(plane_path "projects/$project/issues/$1/")" "$(jq -nc --arg s "$oid" '{state: $s}')" >/dev/null || exit 1 ;;
    priority) plane_set_priority "$1" "$oid" ;;
  esac
}

# plane_set_priority <work item uuid> <native priority>: the native priority is what the option the person named
# resolved to, so the spelling typed, P9 or p9, decides nothing here. P9 is the label P9 and the native priority
# none, P0 to P3 a native priority without that label, so a work item never reads as two. The labels of a work
# item are replaced by the list a write gives, so the one PATCH carries the priority and the whole label list,
# and the work item is read back before the command says it is done. A PATCH and a readback show what the work
# item held then; they do not stop another client writing its labels at the same moment.
plane_set_priority() {
  local project item_path item rows p9 labels read_back
  project="$(plane_project_uuid)" || exit 1
  item_path="$(plane_path "projects/$project/issues/$1/")"
  item="$(plane_api "the labels of the work item $1" GET "${item_path}?expand=labels")" || exit 1
  if [ "$2" = none ]; then
    rows="$(plane_pages "the labels of $(plane_setting PLANE_PROJECT)" "$(plane_path "projects/$project/labels/")")" || exit 1
    plane_label_ensure "$rows" P9 6B7280 "Parked: the work waits, and Plane has no priority for that"
    rows="$(plane_pages "the labels of $(plane_setting PLANE_PROJECT)" "$(plane_path "projects/$project/labels/")")" || exit 1
    p9="$(jq -r 'select(.name == "P9") | .id' <<< "$rows" | sed -n 1p)"
    [ -n "$p9" ] || die "the Plane project has no label P9 after it was made"
    labels="$(printf '%s' "$item" | jq -c --arg p "$p9" '[.labels[].id, $p] | unique')"
  else
    labels="$(printf '%s' "$item" | jq -c '[.labels[] | select(.name != "P9") | .id] | unique')"
  fi
  plane_api "the priority of $1" PATCH "$item_path" "$(jq -nc --arg p "$2" --argjson l "$labels" '{priority: $p, labels: $l}')" >/dev/null || exit 1
  read_back="$(plane_api "the priority of $1 after the write" GET "${item_path}?expand=labels")" || exit 1
  printf '%s' "$read_back" | jq -e --arg p "$2" --argjson l "$labels" '
    .priority == $p and ([.labels[].id] | sort) == ($l | sort) and ([.labels[] | select(.name == "P9")] | length) == (if $p == "none" then 1 else 0 end)' >/dev/null \
    || die "the priority of $1 was NOT confirmed: Plane answered the write, and the work item reads priority $(printf '%s' "$read_back" | jq -r '.priority') with the labels $(printf '%s' "$read_back" | jq -r '[.labels[].name] | join(", ")')"
}

# closing_column <completed | not-planned>: the Status a closed issue's card is put in. An issue closed as
# not planned stands in Plane's own Cancelled, which issue_close wrote already, so the column asked for
# afterwards is that one and the reason is not turned into a completion.
closing_column() {
  local name
  case "$1" in
    not-planned)
      name="$(plane_states | jq -r 'select(.group == "cancelled") | .name' | sed -n 1p)"
      [ -n "$name" ] || die "the Plane project $(plane_setting PLANE_PROJECT) has no state of the cancelled group"
      echo "$name" ;;
    *) echo done ;;
  esac
}

# epic_target_on_board <owner/repo> <number> - the epic_target of a work item, from its own state and the
# states of its children: a state of the completed group counts as done, one of the cancelled group as not
# planned, any other by its name, except that a child still open counts at most as testing, whatever the
# state is called, one called done or not planned included, or the epic would close with that work item
# still open. Every child is read, page after page. A work item without children gets nothing. A read, so
# any repository of the project: the sweep of status-sync asks it for the epics of each.
epic_target_on_board() {
  local item children rows cur st first=1
  item="$(plane_item_read "$1" "$2")" || exit 1
  children="$(plane_pages "the work items of $(plane_setting PLANE_PROJECT)" "$(plane_path "projects/$(plane_project_uuid)/issues/")?expand=state&fields=id,parent,state")" || exit 1
  rows="$(printf '%s\n%s\n' "$item" "$children" | jq -rs '
    def status: if .state.group == "completed" then "done" elif .state.group == "cancelled" then "not planned" else (.state.name | ascii_downcase) end;
    def childstatus: if .state.group | IN("completed", "cancelled") then status else status | if IN("done", "not planned") then "testing" else . end end;
    .[0] as $i | ([.[1:][] | select(.parent == $i.id)]) as $kids
    | if ($kids | length) == 0 then empty else ($i | if .state.group | IN("completed", "cancelled") then "closed" else status end), ($kids[] | childstatus) end')"
  [ -n "$rows" ] || return 0
  set --
  while IFS= read -r st; do
    if [ "$first" = 1 ]; then cur="$st"; first=0; else set -- "$@" "$st"; fi
  done <<< "$rows"
  epic_target "$cur" "$@"
}

# open_subissues <owner/repo> <number>: the children of a work item that are not closed, one "<owner/repo>#<number>"
# a line, none where it has none. Closed is the completed and cancelled groups of the state, never its name. A
# child that names no repository is written as Plane writes it, <project>-<number>.
open_subissues() {
  local item
  item="$(plane_item_read "$1" "$2")" || exit 1
  plane_all_items | jq -rs --arg o "$(plane_owner)" --arg id "$(printf '%s' "$item" | jq -r '.id')" --arg project "$(plane_setting PLANE_PROJECT)" "$PLANE_REPO""$PLANE_ROW"'
    .[] | select(.parent.id == $id and (closed | not)) | "\(repo($o) // $project)\(if repo($o) then "#" else "-" end)\(.sequence_id)"'
}

# --- the rows over the project ---------------------------------------------------------------

# plane_all_items [project identifier]: every work item of the project, PLANE_PROJECT when none is named,
# that is not archived, open or closed, one JSON object per line, with state, labels and parent expanded.
# Plane 1.4 has no filter on the list, so the reader filters; the one query it serves is a work item by its
# external_source and external_id (plane_find_carried).
plane_all_items() {
  local ident="${1:-$(plane_setting PLANE_PROJECT)}"
  plane_pages "the work items of $ident" "$(plane_path "projects/$(plane_project_uuid "$ident")/issues/")?expand=state,labels,parent"
}

# issue_rows <owner/repo>: the open issues of the repository, the issue row of lib/tracker.sh, from the work
# items whose repo: label names it. A work item without that label belongs to nobody and is not listed.
# The relations are read one work item at a time, because Plane's list answers none: a repository of 100
# open items costs 100 reads beside the listing, and a rate limit that runs out waits as every call does.
# A relation to a work item of another project, or to one without a repo: label, has no name to give, and is
# reported in cut instead.
issue_rows() {
  local repo="$1" all ids id held rels=""
  plane_check_owner "$repo"
  all="$(plane_all_items)" || exit 1
  ids="$(printf '%s\n' "$all" | jq -r --arg o "${repo%%/*}" --arg r "$repo" "$PLANE_REPO"'
    select(same(repo($o); $r) and (.state.group | IN("completed", "cancelled") | not)) | .id')"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    held="$(plane_api "the relations of a work item of $repo" GET "$(plane_path "projects/$(plane_project_uuid)/work-items/$id/relations/")")" || exit 1
    rels="$rels$(printf '%s' "$held" | jq -c --arg i "$id" '{id: $i, blockedBy: [.blocked_by[].issue_id], blocking: [.blocking[].issue_id]}')"$'\n'
  done <<< "$ids"
  printf '%s\n' "$all" | jq -cs --arg o "${repo%%/*}" --arg r "$repo" --argjson rels "$(printf '%s' "$rels" | jq -cs '.')" "$PLANE_REPO""$PLANE_TEXT"'
    (map({key: .id, value: .}) | from_entries) as $byid
    | def ref($uuid): ($byid[$uuid] // null) as $w | if $w and ($w | repo($o)) then "\($w | repo($o))#\($w.sequence_id)" else null end;
      def cut($what; $uuids): ([$uuids[] | select(ref(.) == null)] | length) as $n
        | if $n > 0 then ["\($what) names \($n) work item(s) of another project or without a repo: label"] else [] end;
    .[] | select(same(repo($o); $r) and (.state.group | IN("completed", "cancelled") | not))
    | . as $w | ($rels | map(select(.id == $w.id))[0] // {blockedBy: [], blocking: []}) as $x
    | { repo: repo($o), number: .sequence_id, title: .name, body: ((.description_html // "") | text), open: true,
        labels: [.labels[].name | select(startswith("repo:") | not)], status: .state.name,
        parent: (if .parent.id then ref(.parent.id) else null end),
        blockedBy: [$x.blockedBy[] | ref(.) | select(. != null)], blocking: [$x.blocking[] | ref(.) | select(. != null)],
        cut: ((if .parent.id and ref(.parent.id) == null then ["parent names a work item of another project or without a repo: label"] else [] end)
              + cut("blocked by"; $x.blockedBy) + cut("blocks"; $x.blocking)) }'
}

# --- the cards of the project --------------------------------------------------------------

# The columns of a card row (lib/tracker.sh). A closed work item is one in a state of the completed or the
# cancelled group; Plane's four priorities stand for P0 to P3, and none for no priority. The label P9 says parked,
# which Plane has no priority for (an issue carry sets it), and it outranks the native priority.
PLANE_ROW='def closed: .state.group | IN("completed", "cancelled");
  def prio: if any(.labels[]?; .name == "P9") then "P9" else ({urgent: "P0", high: "P1", medium: "P2", low: "P3"})[.priority // "none"] end;
  def ref($byid; $o): ($byid[.id] // null) as $w | if $w and ($w | repo($o)) then "\($w | repo($o))#\($w.sequence_id)" else null end;'

# card_rows: every work item of the project, one JSON object per line, the card row of lib/tracker.sh. A work
# item without a repository is a row with repo null: it is on the board, and under no repository.
card_rows() {
  plane_all_items | jq -cs --arg o "$(plane_owner)" "$PLANE_REPO""$PLANE_ROW"'
    (map({key: .id, value: .}) | from_entries) as $byid
    | (map(select(.parent.id) | .parent.id) | group_by(.) | map({key: .[0], value: length}) | from_entries) as $subs
    | .[] | {repo: repo($o), number: .sequence_id, title: .name, open: (closed | not),
             closedAt: (if closed then (.completed_at // .updated_at) else null end),
             createdAt: .created_at, carriedFrom: carried_from,
             status: .state.name, priority: prio,
             parent: (if .parent.id then (.parent | ref($byid; $o)) else null end),
             subs: ($subs[.id] // 0)}'
}

# board_card_lines <organisation, lower case>: "<status>\t<priority>\t<repo>\t<number>\t<title>\t<closed or empty>"
# for every work item; the repository is its bare name under that organisation, its full name under another,
# and "-" for a work item that names none
board_card_lines() {
  plane_all_items | jq -r --arg o "$(plane_owner)" --arg org "$1" "$PLANE_REPO""$PLANE_ROW"'
    repo($o) as $r
    | [.state.name, (prio // "-"),
       (if $r == null then "-" elif ($r | split("/")[0] | ascii_downcase) == $org then ($r | split("/")[1]) else $r end),
       .sequence_id, (.name | gsub("[\t\n]"; " ")), (if closed then "closed" else "" end)] | map(tostring) | join("\t")'
}

# board_items: "<work item uuid>\t<owner/repo>\t<number>" for every work item of this checkout's repository, the
# only ones it may write. board-order and epics-top place what this lists, so a work item of another
# repository is not on the board they see.
board_items() {
  plane_all_items | jq -r --arg o "$(plane_owner)" --arg r "$(default_repo)" "$PLANE_REPO"'repo($o) as $x | select($x != null and same($x; $r)) | "\(.id)\t\($x)\t\(.sequence_id)"'
}

# item_top <work item uuid> [after work item uuid]: the work item goes to the top of the project's order, or
# directly under the other one. Plane orders by sort_order, the smallest first, and a number between two
# neighbours is a float's half. About fifty placements under one work item exhaust a float's halves,
# and then two work items share an order; rewriting the whole order would lift that ceiling.
item_top() {
  local orders target project
  project="$(plane_project_uuid)" || exit 1
  orders="$(plane_pages "the order of the work items of $(plane_setting PLANE_PROJECT)" "$(plane_path "projects/$project/issues/")?fields=id,sort_order")" || exit 1
  target="$(printf '%s\n' "$orders" | jq -rs --arg a "${2:-}" '
    if $a == "" then (map(.sort_order) | min // 0) - 10000
    else (map(select(.id == $a))[0].sort_order) as $x
      | if $x == null then empty
        else ([.[].sort_order | select(. > $x)] | min) as $next | if $next == null then $x + 10000 else ($x + $next) / 2 end end
    end')"
  [ -n "$target" ] || die "the work item to place it under is not in the project $(plane_setting PLANE_PROJECT)"
  plane_api "the order of the work item $1" PATCH "$(plane_path "projects/$project/issues/$1/")" \
    "$(jq -nc --argjson s "$target" '{sort_order: $s}')" >/dev/null || exit 1
}

# board_repos <project identifier>: the repositories of that project, the ones a repo: label names, under the
# owner of the origin. incident-count reads every open project of the workspace, so this reads a project
# that is not the one PLANE_PROJECT names.
board_repos() {
  plane_pages "the labels of $1" "$(plane_path "projects/$(plane_project_uuid "$1")/labels/")" \
    | jq -r --arg o "$(plane_owner)" 'select(.name | startswith("repo:")) | "\($o)/\(.name[5:])"'
}

# project_repos: the repositories of the project this checkout serves
project_repos() { board_repos "$(plane_setting PLANE_PROJECT)"; }

# plane_open_projects: the projects of the workspace that are not archived, one JSON object per line. The list
# of Plane 1.4 answers the archived projects too, each with an archived_at.
plane_open_projects() {
  plane_pages "the projects of $(plane_setting PLANE_WORKSPACE)" "$(plane_path projects/)" | jq -c 'select(.archived_at == null)'
}

# projects_of_org <organisation>: "<identifier>\t<name>" of every open project of the workspace this checkout
# names; the workspace stands for the organisation, so the argument is not read.
projects_of_org() {
  local rows
  rows="$(plane_open_projects)" || exit 1
  printf '%s\n' "$rows" | jq -r '"\(.identifier)\t\(.name)"'
}

# issues_created_since <owner/repo> <YYYY-MM-DD> <limit>: the newest <limit> work items of the repository
# created on that day or later, as a JSON array of {createdAt, labels: [name]}, over every open project of
# the workspace: a repository that is linked in two projects is counted in both. Plane 1.4 filters the list by
# nothing, so the whole list is read and cut here.
issues_created_since() {
  local projects ident rows="" items
  plane_check_owner "$1"
  projects="$(projects_of_org "$(plane_owner)")" || exit 1
  while IFS=$'\t' read -r ident _; do
    [ -n "$ident" ] || continue
    items="$(plane_all_items "$ident")" || exit 1
    rows="$rows$items"$'\n'
  done <<< "$projects"
  printf '%s' "$rows" | jq -cs --arg o "$(plane_owner)" --arg r "$1" --arg d "$2" --argjson n "$3" "$INSTANT_JQ""$PLANE_REPO"'
    [.[] | select(same(repo($o); $r) and (.created_at | instant_key) >= ($d + "T00:00:00Z" | instant_key))] | sort_by(.created_at | instant_key) | reverse | .[:$n]
    | map({createdAt: .created_at, labels: [.labels[].name | select(startswith("repo:") | not)]})'
}

# issue_numbers_closed <owner/repo>: the numbers of the newest 200 closed work items of the repository
issue_numbers_closed() {
  plane_check_owner "$1"
  plane_all_items | jq -rs --arg o "$(plane_owner)" --arg r "$1" "$INSTANT_JQ""$PLANE_REPO""$PLANE_ROW"'
    [.[] | select(same(repo($o); $r) and closed)] | sort_by((.completed_at // .updated_at) | instant_key) | reverse | .[:200][] | .sequence_id'
}

# issue_summaries <owner/repo>: the newest 500 work items of the repository, open or closed, one
# "<number>\t<OPEN|CLOSED>\t<labels, comma between>\t<title>" per line, the title last
issue_summaries() {
  plane_check_owner "$1"
  plane_all_items | jq -rs --arg o "$(plane_owner)" --arg r "$1" "$INSTANT_JQ""$PLANE_REPO""$PLANE_ROW"'
    [.[] | select(same(repo($o); $r))] | sort_by(.created_at | instant_key) | reverse | .[:500][]
    | "\(.sequence_id)\t\(if closed then "CLOSED" else "OPEN" end)\t\([.labels[].name | select(startswith("repo:") | not)] | join(","))\t\(.name | gsub("[\t\n]"; " "))"'
}

# plane_closed_state_ids: the ids of the states of the completed and cancelled groups, the closed states, as a JSON array
plane_closed_state_ids() {
  local states
  states="$(plane_states)" || exit 1
  printf '%s\n' "$states" | jq -cs '[.[] | select(.group | IN("completed", "cancelled")) | .id]'
}

# plane_member_rows: the members of the project, active or not, one JSON object each
plane_member_rows() {
  plane_pages "the members of $(plane_setting PLANE_PROJECT)" "$(plane_path "projects/$(plane_project_uuid)/project-members-lite/")"
}

# plane_active_member_ids: the ids of the active members of the project, as a JSON array
plane_active_member_ids() {
  local rows
  rows="$(plane_member_rows)" || exit 1
  printf '%s\n' "$rows" | jq -cs '[.[] | select(.is_active == true) | .id]'
}

# plane_landing_context <work item id> <what it is, for a refusal> <closed state ids> <active member ids>: the
# landing context of lib/tracker.sh (issue_landing_context) of a work item, read from its comments and its
# state changes: {reopenedAt, comments:[{createdAt, body, authorAssociation}]}. A comment is a MEMBER's
# where its author is an active member of the project: the is_member of a comment says whether the key's
# own user is a member (Plane CE 1.4.2, apps/api/plane/api/views/issue.py, member_id=self.request.user.id),
# so it says nothing of the author. The reopening is the last change of the state from a closed to an open one.
#
# A CARRIED COMMENT is one with external_source github and an external_id, the mark the carry posts
# (carry_comment_request); every other comment is a Plane comment, judged as above whatever its text says. The
# carry writes each GitHub comment under the header lib/carry-plan.jq makes, "Comment N of T by @login
# (ASSOCIATION) on <time>", the address and an empty line. A carried comment is read from that header: its time
# is the header's, never its created_at, which Plane may set to the time of the carry; its body follows the
# header; its association is GitHub's word in the header, and only where its actor is an active member
# of the project, NONE otherwise and where the header has no word (carried before the header held it). The
# provenance comment of a carry is no comment of a person: it is left out, and the reopening on GitHub it
# names ("Last reopened on GitHub at <time>.") counts beside Plane's own, the later of the two.
plane_landing_context() {
  local id="$1" what="$2" closed="$3" members="$4" comments acts
  comments="$(plane_pages "the comments of $what" "$(plane_path "projects/$(plane_project_uuid)/issues/$id/comments/")")" || exit 1
  acts="$(plane_pages "the state changes of $what" "$(plane_path "projects/$(plane_project_uuid)/issues/$id/activities/")")" || exit 1
  jq -cn --arg what "$what" --argjson closed "$closed" --argjson members "$members" --argjson c "$(printf '%s' "$comments" | jq -cs '.')" --argjson a "$(printf '%s' "$acts" | jq -cs '.')" "$INSTANT_JQ""$PLANE_TEXT"'
    def member: (.actor | if type == "object" then .id else . end) as $a | $members | index($a) != null;
    def carried: .external_source == "github" and ((.external_id // "") != "");
    def provenance: carried and (.text | startswith("Carried from GitHub "));
    def unwrapped: (.text | split("\n")) as $l
      | (($l[0] | capture("^Comment [0-9]+ of [0-9]+ by (?:@[^ ]+|an unavailable author)(?: \\((?<word>[A-Z_]+)\\))? on (?<at>[^ ]+)$"))
         // error("the header of a carried comment of \($what) cannot be read: \($l[0])")) as $h
      | {createdAt: $h.at, body: ($l[3:] | join("\n")), authorAssociation: (if member then ($h.word // "NONE") else "NONE" end)};
    ($c | map(. + {text: ((.comment_html // "") | text)})) as $all
    | {comments: ($all | map(select(provenance | not)
                | if carried then unwrapped else {createdAt: .created_at, body: .text, authorAssociation: (if member then "MEMBER" else "NONE" end)} end)
                | sort_by(.createdAt | instant_key)),
       reopenedAt: ([([$a[] | select(.field == "state" and (.old_identifier | IN($closed[])) and ((.new_identifier | IN($closed[])) | not))]
                      | sort_by(.created_at | instant_key) | last | .created_at),
                     ($all[] | select(provenance) | .text | split("\n")[] | capture("^Last reopened on GitHub at (?<t>[^ ]+)\\.$") | .t)]
                    | map(select(. != null)) | max_by(instant_key))}'
}

# issue_landing_context <owner/repo> <number>: the landing context of lib/tracker.sh of a work item, every comment
# of it
issue_landing_context() {
  local item closed members
  item="$(plane_item_read "$1" "$2")" || exit 1
  closed="$(plane_closed_state_ids)" || exit 1
  members="$(plane_active_member_ids)" || exit 1
  plane_landing_context "$(printf '%s' "$item" | jq -r '.id')" "$1#$2" "$closed" "$members"
}

# open_issue_page <owner/repo> [cursor]: the open work items of the repository, as the page GitHub answers to
# status-sync (lib/github/tracker.sh): the number, the sub-issue total, the one board it is on with its Status,
# the time of the last reopening and the last LANDING_COMMENT_WINDOW comments. status-sync reads the comments
# of a card in testing alone, so those, and the state changes behind a reopening, are read for the work items
# in testing alone: a page costs two reads beside the listing for each of them. The whole repository is one
# page. The members are read once, and plane_landing_context judges each comment's author by them.
open_issue_page() {
  local repo="$1" all closed ids id record members="[]" extra=""
  plane_check_owner "$repo"
  all="$(plane_all_items)" || exit 1
  closed="$(plane_closed_state_ids)" || exit 1
  ids="$(printf '%s\n' "$all" | jq -r --arg o "$(plane_owner)" --arg r "$repo" "$PLANE_REPO""$PLANE_ROW"'
    select(same(repo($o); $r) and (closed | not) and (.state.name | ascii_downcase) == "testing") | .id')"
  if [ -n "$ids" ]; then members="$(plane_active_member_ids)" || exit 1; fi
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    record="$(plane_landing_context "$id" "a work item of $repo" "$closed" "$members")" || exit 1
    extra="$extra$(jq -c --arg i "$id" --argjson k "$LANDING_COMMENT_WINDOW" '{id: $i, comments: (.comments | .[(0 - $k):]), reopenedAt}' <<< "$record")"$'\n'
  done <<< "$ids"
  printf '%s\n' "$all" | jq -cs --arg o "$(plane_owner)" --arg r "$repo" --argjson board "$(project_number_json)" --arg org "$(project_org)" \
    --argjson extra "$(printf '%s' "$extra" | jq -cs '.')" "$PLANE_REPO""$PLANE_ROW"'
    (map(select(.parent.id) | .parent.id) | group_by(.) | map({key: .[0], value: length}) | from_entries) as $subs
    | {data: {repository: {issues: {pageInfo: {hasNextPage: false, endCursor: null},
        nodes: [.[] | select(same(repo($o); $r) and (closed | not)) | . as $w
          | ($extra | map(select(.id == $w.id))[0] // {comments: [], reopenedAt: null}) as $x
          | {number: .sequence_id, createdAt: .created_at, carriedFrom: carried_from, subIssuesSummary: {total: ($subs[.id] // 0)},
             projectItems: {nodes: [{project: {number: $board, owner: {login: $org}}, status: {name: .state.name}}]},
             reopened: {nodes: (if $x.reopenedAt then [{createdAt: $x.reopenedAt}] else [] end)},
             comments: {nodes: $x.comments}}]}}}}'
}

# repo_link <owner/repo>: a repository belongs to the project by its repo: label, made once; prints its name
repo_link() {
  local rows own
  plane_check_repo "$1"
  own="$(plane_repo_label)"
  rows="$(plane_pages "the labels of $(plane_setting PLANE_PROJECT)" "$(plane_path "projects/$(plane_project_uuid)/labels/")")" || exit 1
  plane_label_ensure "$rows" "$own" 6B7280 "Work of the repository ${own#repo:}"
  printf '%s\n' "$1"
}

# --- the project and the columns -------------------------------------------------------------

# The states of a project the harness reads, in the order of its columns: "<name>\t<group>\t<colour>\t<the name
# Plane gives it when it makes the project>". Plane makes Backlog, Todo, In Progress, Done and Cancelled with
# every project (plane/db/models/state.py DEFAULT_STATES at v1.4.2): four are renamed, three are made, and
# Cancelled stays.
PLANE_STATES='backlog	backlog	#60646C	Backlog
ready	unstarted	#3B82F6	Todo
planned	unstarted	#8B5CF6	
implementing	started	#F59E0B	In Progress
review	started	#EC4899	
testing	started	#06B6D4	
done	completed	#46A758	Done
Cancelled	cancelled	#9AA4BC	Cancelled'

# project_create <organisation> <board to copy> <title>: makes the project PLANE_PROJECT names, with the eight
# states and the labels of labels.tsv, and prints "<identifier>\t<address>". Plane copies no project, so a
# board to copy is refused.
project_create() {
  local ident made pid states made_state n=0 name group colour was id description taxonomy repo
  [ -z "$2" ] || die "Plane copies no project: project-new takes the title alone, and PLANE_PROJECT names the identifier of the new project"
  ident="$(plane_setting PLANE_PROJECT)"
  repo="$(default_repo)" || exit 1
  taxonomy="$(labels_tsv)" || exit 1
  check_public_body project-new "$ident" "$ident"$'\n'"$repo"$'\n'"$taxonomy" "" project
  states="$(plane_pages "the projects of $(plane_setting PLANE_WORKSPACE)" "$(plane_path projects/)")" || exit 1
  ! printf '%s\n' "$states" | jq -e --arg i "$ident" 'select(.identifier == $i)' >/dev/null \
    || die "the Plane project $ident exists already - set PLANE_PROJECT to the identifier of the project to make"
  made="$(plane_api "the project $ident, which was NOT made" POST "$(plane_path projects/)" \
    "$(jq -nc --arg n "$3" --arg i "$ident" '{name: $n, identifier: $i}')")" || exit 1
  pid="$(printf '%s' "$made" | jq -r '.id')"
  # what this checkout cached for the identifier belonged to a project that is gone
  rm -rf "$(plane_project_cache_dir "$ident")"; mkdir -p "$(plane_project_cache_dir "$ident")"
  printf '%s\n' "$pid" > "$(plane_project_cache_dir "$ident")/project-id"
  states="$(plane_pages "the states of $ident" "$(plane_path "projects/$pid/states/")")" || exit 1
  while IFS=$'\t' read -r name group colour was; do
    n=$((n + 1))
    id="$(jq -r --arg n "$name" --arg was "$was" 'select(.name == $n or .name == $was) | .id' <<< "$states" | sed -n 1p)"
    if [ -z "$id" ]; then
      made_state="$(plane_api "the state $name of $ident" POST "$(plane_path "projects/$pid/states/")" \
        "$(jq -nc --arg n "$name" --arg g "$group" --arg c "$colour" '{name: $n, group: $g, color: $c}')")" || exit 1
      id="$(printf '%s' "$made_state" | jq -r '.id')"
    fi
    # Plane puts a new state after the last whatever sequence it is asked for, so the order is written once
    # every state stands
    plane_api "the state $name of $ident" PATCH "$(plane_path "projects/$pid/states/$id/")" \
      "$(jq -nc --arg n "$name" --arg c "$colour" --argjson s "$((n * 10000))" '{name: $n, color: $c, sequence: $s}')" >/dev/null || exit 1
  done <<< "$PLANE_STATES"
  while IFS=$'\t' read -r group name colour description; do
    [ -n "$name" ] || continue
    labels_create "$repo" "$name" "$colour" "$description"
  done <<< "$taxonomy"
  printf '%s\t%s/%s/projects/%s/issues/\n' "$ident" "$(plane_setting PLANE_URL | sed 's|/*$||')" "$(plane_setting PLANE_WORKSPACE)" "$pid"
}

# --- what Plane's API cannot serve, each refused with its own sentence ------------------------

archived_item_id() { die "board-unarchive is not served on Plane: its API (1.4.2) can neither list nor restore an archived work item, so restore it in Plane itself"; }
item_unarchive() { archived_item_id; }
issue_unblock() { die "issue-unblock is not served on Plane: its API (1.4.2) has no call that removes a relation, so remove it in Plane itself"; }
duplicate_unmark() { die "the removal of a duplicate mark is not served on Plane: its API (1.4.2) has no call that removes a relation, so remove it in Plane itself"; }
issue_transfer() { die "issue-transfer is not served on Plane: a work item stands in one project, and Plane's API has no call that moves it to another"; }
board_cards_of_repo() { die "item-move is not served on Plane: a work item stands in one project, and Plane's API has no call that moves it to another"; }
remove_board_item() { board_cards_of_repo; }
board_views() { die "view-filter is not served on Plane: its API has no project views"; }
view_filter_set() { board_views; }
board_fields_json() { die "field-option-add is not served on Plane: its API has no custom fields on a board, and the Status column is the states of the project"; }
field_options_replace() { board_fields_json; }
repo_boards_rows() { die "repo-boards is not served on Plane: a repository is not linked to a project there, it names its work items by the label repo:<name>"; }
