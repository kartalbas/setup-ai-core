#!/usr/bin/env bash
# The tracker of this harness on Plane: work items, their states, priorities, labels, parents and
# relations, asked with curl. lib/tracker.sh sources it when TRACKER is plane. The functions stand under
# the names lib/board.sh and every command in bin/ call, with the arguments and the rows of
# lib/github/tracker.sh; a call Plane's API cannot serve is refused with its own sentence. Source it, do
# not run it.
#
# THE MAPPING, decided on #184: an issue is a work item, `#n` is its sequence_id in the project, an epic is
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

# plane_origin: "owner/repo" of the origin of the checkout the caller stands in, whatever the host and the
# way it is spelled (https, scp-like or ssh://), nothing where there is none
plane_origin() {
  local url
  url="$(git remote get-url origin 2>/dev/null)" || return 1
  url="${url%/}"; url="${url%.git}"
  url="$(printf '%s' "$url" | sed -n 's|^.*[:/]\([^:/][^:/]*/[^:/][^:/]*\)$|\1|p')"
  [ -n "$url" ] || return 1
  printf '%s\n' "$url"
}

# The organisation a command acts for: GH_ORG, then the owner of the checkout's origin.
gh_org() {
  local org repo
  org="$(config_value GH_ORG "")"
  if [ -n "$org" ]; then export GH_ORG="$org"; echo "$org"; return 0; fi
  repo="$(plane_origin)" \
    || die "no organisation: set GH_ORG in .ai-core/config.env or the environment, or run this inside a repository of it"
  export GH_ORG="${repo%%/*}"
  echo "$GH_ORG"
}

default_repo() {
  plane_origin || die "cannot tell which repository this is - pass the repo as OWNER/REPO"
}

# ONE CHECKOUT, ONE REPOSITORY: a call that names another repository is refused, because the project the
# checkout's PLANE_PROJECT names holds work items of every repository of one line, told apart by their
# repo: label (#242), and acting on another repository's items from here would be a guess.
plane_check_repo() {  # plane_check_repo <owner/repo>
  local here
  here="$(default_repo)" || exit 1
  [ "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$here" | tr '[:upper:]' '[:lower:]')" ] \
    || die "no Plane project is configured here for $1"
}

# A project is written by its identifier, the letters and digits before the dash of ENG-142
check_project_number() {  # check_project_number <project identifier>
  case "$1" in ''|*[!A-Za-z0-9_]*) die "the Plane project must be written by its identifier, not '$1'" ;; esac
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

# plane_project_uuid: the uuid of the project PLANE_PROJECT names, kept beside the other caches. The id of a
# project does not change, so the file is the answer until somebody deletes it.
plane_project_uuid() {
  local ident f rows id
  ident="$(plane_setting PLANE_PROJECT)"
  f="$(cache_root)/plane/$(plane_setting PLANE_WORKSPACE)-$ident.id"
  if [ -s "$f" ]; then id="$(cat "$f")"
  else
    rows="$(plane_pages "the projects of $(plane_setting PLANE_WORKSPACE)" "$(plane_path projects/)")" || exit 1
    id="$(printf '%s\n' "$rows" | jq -r --arg i "$ident" 'select(.identifier == $i) | .id' | head -n1)"
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

# Priorities: the harness says P0 to P3, a person reads High in Plane
plane_priority() {  # plane_priority <P0..P3 | urgent..none>: Plane's word
  case "$1" in
    P0|urgent) echo urgent ;; P1|high) echo high ;; P2|medium) echo medium ;; P3|low) echo low ;;
    *) die "Plane has no priority '$1'. It has: P0 P1 P2 P3" ;;
  esac
}

# plane_item <owner/repo> <number>: the work item <IDENT>-<number> as JSON, its state, labels and parent
# expanded
plane_item() {
  local repo="$1" n="$2" item
  case "$n" in ''|*[!0-9]*) die "the issue number must be numeric, not '$n'" ;; esac
  item="$(plane_api "the work item $(plane_setting PLANE_PROJECT)-$n" GET "$(plane_path "issues/$(plane_setting PLANE_PROJECT)-$n/")?expand=state,labels,parent")" || exit 1
  printf '%s\n' "$item"
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
    group:*) id="$(printf '%s\n' "$rows" | jq -r --arg g "${1#group:}" 'select(.group == $g) | .id' | head -n1)" ;;
    *)       id="$(printf '%s\n' "$rows" | jq -r --arg n "$1" 'select((.name | ascii_downcase) == ($n | ascii_downcase)) | .id' | head -n1)" ;;
  esac
  [ -n "$id" ] || die "the Plane project $(plane_setting PLANE_PROJECT) has no state '${1#group:}'. It has: $(printf '%s\n' "$rows" | jq -r '.name' | paste -sd' ' -)"
  printf '%s\n' "$id"
}

# issue_create <owner/repo> <title> <body file> <assignee> [label...]: prints the number of the new work item
issue_create() {
  local repo="$1" title="$2" body="$3" assignee="$4" ids aid request created
  shift 4
  plane_check_repo "$repo"
  ids="$(plane_label_ids "$@")" || exit 1
  aid="$(plane_user_id "$assignee")" || exit 1
  request="$(jq -n --arg name "$title" --arg html "$(plane_html_of "" "$body")" --argjson labels "$ids" --arg a "$aid" \
    '{name: $name, description_html: $html, labels: $labels, assignees: [$a], external_source: "ai-core"}')"
  created="$(plane_api "the issue created in $repo, which was NOT created" POST "$(plane_path "projects/$(plane_project_uuid)/issues/")" "$request")" || exit 1
  printf '%s' "$created" | jq -r '.sequence_id'
}

# plane_label_ids <name>...: a JSON array of the uuids of these labels of the project; a name the project
# lacks stops the create and says how to make it, the way a missing label does on GitHub
plane_label_ids() {
  local rows name ids="[]" id
  rows="$(plane_pages "the labels of $(plane_setting PLANE_PROJECT)" "$(plane_path "projects/$(plane_project_uuid)/labels/")")" || exit 1
  for name in "$@"; do
    id="$(printf '%s\n' "$rows" | jq -r --arg n "$name" 'select(.name == $n) | .id' | head -n1)"
    [ -n "$id" ] || die "the issue was NOT created - the Plane project has no label '$name'. Run: ai-core labels-sync"
    ids="$(jq -c --arg i "$id" '. + [$i]' <<< "$ids")"
  done
  printf '%s\n' "$ids"
}

# issue_edit <owner/repo> <number> <title or empty> <body file or empty>
issue_edit() {
  local request
  request="$(jq -n --arg t "$3" --arg h "$([ -z "$4" ] || plane_html_of "" "$4")" \
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
  local target="done"
  [ "$3" != not-planned ] || target="group:cancelled"
  plane_patch "the close of $1#$2" "$1" "$2" "$(jq -nc --arg s "$(plane_state_id "$target")" '{state: $s}')"
}

issue_reopen() {  # issue_reopen <owner/repo> <number>: the state `ready`
  plane_patch "the reopen of $1#$2" "$1" "$2" "$(jq -nc --arg s "$(plane_state_id ready)" '{state: $s}')"
}

# issue_comment_post <owner/repo> <number> <text> <text file>: prints the address of the work item, because
# Plane's API answers no address for a comment
issue_comment_post() {
  local item
  item="$(plane_item "$1" "$2")" || exit 1
  plane_api "the comment posted on $1#$2" POST "$(plane_path "$(plane_issue_path "$item")comments/")" \
    "$(jq -nc --arg h "$(plane_html_of "$3" "$4")" '{comment_html: $h}')" >/dev/null || exit 1
  printf '%s/%s/browse/%s-%s/\n' "$(plane_setting PLANE_URL | sed 's|/*$||')" "$(plane_setting PLANE_WORKSPACE)" "$(plane_setting PLANE_PROJECT)" "$2"
}

# issue_thread <owner/repo> <number>: the work item and its whole comment thread as one JSON object:
#   {number,title,state,labels,body,comments:[{author,created_at,body}]}
issue_thread() {
  local item comments
  item="$(plane_item "$1" "$2")" || exit 1
  comments="$(plane_pages "the comments of $1#$2" "$(plane_path "$(plane_issue_path "$item")comments/")?expand=actor")" || exit 1
  printf '%s\n%s\n' "$item" "$comments" | jq -s "$PLANE_TEXT"'
    .[0] as $i | .[1:] as $c | {
      number: $i.sequence_id, title: $i.name,
      state: (if ($i.state.group | IN("completed", "cancelled")) then "closed" else "open" end),
      labels: [$i.labels[].name], body: (($i.description_html // "") | text),
      comments: ($c | sort_by(.created_at) | map({author: (.actor.display_name // .actor.email // ""),
                       created_at: .created_at, body: ((.comment_html // "") | text)})) }'
}

# A work item has one identity here, its uuid
issue_node_id() { plane_item "$1" "$2" | jq -r '.id'; }
issue_db_id() { issue_node_id "$@"; }

issue_title() {  # issue_title <owner/repo> <number>
  plane_item "$1" "$2" | jq -r '.name'
}

# --- labels -------------------------------------------------------------------------

issue_labels() {  # issue_labels <owner/repo> <number>: the names, one per line
  plane_item "$1" "$2" | jq -r '.labels[].name'
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
    id="$(printf '%s\n' "$rows" | jq -r --arg n "${l#?}" 'select(.name == $n) | .id' | head -n1)"
    case "$l" in
      +*) [ -n "$id" ] || die "the Plane project has no label '${l#+}'. Run: ai-core labels-sync"
          set="$(jq -c --arg i "$id" '. + [$i] | unique' <<< "$set")" ;;
      -*) set="$(jq -c --arg i "$id" '. - [$i]' <<< "$set")" ;;
    esac
  done
  plane_patch "the labels of $repo#$n" "$repo" "$n" "$(jq -nc --argjson l "$set" '{labels: $l}')"
}

# labels_create <owner/repo> <name> <colour> <description>: made once, left as it is when it stands
labels_create() {
  local rows
  plane_check_repo "$1"
  rows="$(plane_pages "the labels of $(plane_setting PLANE_PROJECT)" "$(plane_path "projects/$(plane_project_uuid)/labels/")")" || exit 1
  printf '%s\n' "$rows" | jq -e --arg n "$2" 'select(.name == $n)' >/dev/null && return 0
  plane_api "the label $2" POST "$(plane_path "projects/$(plane_project_uuid)/labels/")" \
    "$(jq -nc --arg n "$2" --arg c "#$3" --arg d "$4" '{name: $n, color: $c, description: $d}')" >/dev/null || exit 1
}

# labels_list <owner/repo>: the names of the labels the project carries, one per line
labels_list() {
  plane_check_repo "$1"
  plane_pages "the labels of $(plane_setting PLANE_PROJECT)" "$(plane_path "projects/$(plane_project_uuid)/labels/")" | jq -r '.name'
}

# --- assignees ------------------------------------------------------------------------

issue_assignees() {  # issue_assignees <owner/repo> <number>: the emails assigned, one per line
  local item
  item="$(plane_item "$1" "$2")" || exit 1
  plane_api "the assignees of $1#$2" GET "$(plane_path "$(plane_issue_path "$item")")?expand=assignees" | jq -r '.assignees[]?.email'
}

# issue_assignees_set <owner/repo> <number> <emails, one per line>: the assignees become exactly these
issue_assignees_set() {
  local ids="[]" who
  while IFS= read -r who; do
    [ -n "$who" ] || continue
    ids="$(jq -c --arg i "$(plane_user_id "$who")" '. + [$i]' <<< "$ids")" || exit 1
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
  local child
  child="$(plane_item "$3" "$4")" || exit 1
  [ "$(printf '%s' "$child" | jq -r '.parent.sequence_id // ""')" = "$2" ] \
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

# duplicate_mark <canonical owner/repo> <number> <duplicate owner/repo> <number>: the relation duplicate, and
# the comment GitHub gets, so a person reading the thread sees it
duplicate_mark() {
  local canonical duplicate ref="$1#$2"
  canonical="$(plane_item "$1" "$2")" || exit 1
  duplicate="$(plane_item "$3" "$4")" || exit 1
  [ "$1" != "$3" ] || ref="#$2"
  plane_api "the duplicate mark on $3#$4" POST "$(plane_path "$(plane_relations_path "$duplicate")")" \
    "$(jq -nc --arg i "$(printf '%s' "$canonical" | jq -r '.id')" '{relation_type: "duplicate", issues: [$i]}')" >/dev/null || exit 1
  plane_api "the duplicate mark on $3#$4" POST "$(plane_path "$(plane_issue_path "$duplicate")comments/")" \
    "$(jq -nc --arg h "$(plane_html_of "Duplicate of $ref" "")" '{comment_html: $h}')" >/dev/null || exit 1
}

# --- the board: one work item ---------------------------------------------------------------

# fields_tsv: every field with all its options, one per line, the shape of GitHub's:
#   <field name>\t<field id>\t<option name>\t<option id>\t<state group>
# Status is the project's states, Priority the words P0 to P3 over Plane's four. The fifth column is read
# by this provider alone. The cache lives an hour, as on GitHub.
fields_tsv() {
  local f rows row
  f="$(cache_dir)/fields.tsv"
  [ -s "$f" ] && [ -z "$(find "$f" -mmin +60)" ] || {
    rows="$(plane_states)" || return 1
    rows="$(printf '%s\n' "$rows" | jq -r '"Status\tstatus\t\(.name)\t\(.id)\t\(.group)"')"
    rows="$rows"$'\n'"$(printf 'Priority\tpriority\tP0\turgent\t\nPriority\tpriority\tP1\thigh\t\nPriority\tpriority\tP2\tmedium\t\nPriority\tpriority\tP3\tlow\t')"
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

# set_select <uuid> <field name> <option name>: a state or a priority, matched without case. A work item
# closed as not planned keeps its Cancelled when the closing column done is set after it: the close was one
# write already, and done would turn the reason into a completion.
set_select() {
  local fid oid group item
  fid="$(field_id "$2")" || exit 1
  oid="$(option_id "$2" "$3")" || exit 1
  case "$fid" in
    status)
      group="$(fields_tsv | awk -F'\t' -v o="$oid" '$4 == o { print $5; exit }')"
      if [ "$group" = completed ]; then
        item="$(plane_api "the work item $1" GET "$(plane_path "projects/$(plane_project_uuid)/issues/$1/")?expand=state")" || exit 1
        if [ "$(printf '%s' "$item" | jq -r '.state.group')" = cancelled ]; then
          printf '%s' "$item" | jq -r '"#\(.sequence_id) stays \(.state.name): it was closed as not planned, and reopening it comes first"' >&2
          return 0
        fi
      fi
      plane_api "the state of $1" PATCH "$(plane_path "projects/$(plane_project_uuid)/issues/$1/")" "$(jq -nc --arg s "$oid" '{state: $s}')" >/dev/null || exit 1 ;;
    priority)
      plane_api "the priority of $1" PATCH "$(plane_path "projects/$(plane_project_uuid)/issues/$1/")" "$(jq -nc --arg p "$oid" '{priority: $p}')" >/dev/null || exit 1 ;;
  esac
}

# epic_target_on_board <owner/repo> <number> - the epic_target of a work item, from its own state and the
# states of its children: a state of the completed group counts as done, one of the cancelled group as not
# planned, any other by its name. A work item without children gets nothing.
epic_target_on_board() {
  local item children rows cur st first=1
  item="$(plane_item "$1" "$2")" || exit 1
  children="$(plane_pages "the work items of $(plane_setting PLANE_PROJECT)" "$(plane_path "projects/$(plane_project_uuid)/issues/")?expand=state&fields=id,parent,state")" || exit 1
  rows="$(printf '%s\n%s\n' "$item" "$children" | jq -rs '
    def status: if .state.group == "completed" then "done" elif .state.group == "cancelled" then "not planned" else (.state.name | ascii_downcase) end;
    .[0] as $i | ([.[1:][] | select(.parent == $i.id)]) as $kids
    | if ($kids | length) == 0 then empty else ($i | status), ($kids[] | status) end')"
  [ -n "$rows" ] || return 0
  set --
  while IFS= read -r st; do
    if [ "$first" = 1 ]; then cur="$st"; first=0; else set -- "$@" "$st"; fi
  done <<< "$rows"
  epic_target "$cur" "$@"
}

# --- what only the whole board can serve; built with the board commands (#229) -----------------

plane_later() { die "$1 is not served on Plane yet"; }
project_repos() { plane_later project_repos; }
archived_item_id() { plane_later archived_item_id; }
item_top() { plane_later item_top; }
board_items() { plane_later board_items; }
remove_board_item() { plane_later remove_board_item; }
issue_transfer() { plane_later issue_transfer; }
issue_unblock() { plane_later issue_unblock; }
duplicate_unmark() { plane_later duplicate_unmark; }
issue_rows() { plane_later issue_rows; }
issues_created_since() { plane_later issues_created_since; }
projects_of_org() { plane_later projects_of_org; }
item_unarchive() { plane_later item_unarchive; }
issue_numbers_closed() { plane_later issue_numbers_closed; }
issue_summaries() { plane_later issue_summaries; }
board_card_lines() { plane_later board_card_lines; }
board_cards_of_repo() { plane_later board_cards_of_repo; }
card_rows() { plane_later card_rows; }
open_issue_page() { plane_later open_issue_page; }
board_fields_json() { plane_later board_fields_json; }
field_options_replace() { plane_later field_options_replace; }
project_create() { plane_later project_create; }
repo_boards_rows() { plane_later repo_boards_rows; }
repo_link() { plane_later repo_link; }
board_views() { plane_later board_views; }
view_filter_set() { plane_later view_filter_set; }
