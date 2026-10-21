#!/usr/bin/env bash
# The tracker of this harness on GitHub: issues, sub-issues, labels and the Projects v2 board, asked
# with gh. lib/tracker.sh sources it when TRACKER is github, which is the default. The functions
# stand under the names lib/board.sh and every command in bin/ call; a second tracker implements
# the same names in lib/<provider>/tracker.sh. Source it, do not run it.

. "$(dirname "${BASH_SOURCE[0]}")/gh.sh"

# tracker_name: the tracker as a message names it
tracker_name() { echo GitHub; }

repo_visibility() {
  gh_repo_visibility "$1"
}

# THE ORGANISATION, for a command that names no repository: GH_ORG in the environment, then
# GH_ORG= in the checkout's .ai-core/config.env (the project's setting, put there by init), then
# the owner of the repository the caller stands in. The harness itself names none: it serves many.
gh_org() {
  local org repo
  org="$(config_value GH_ORG "")"
  # Resolved once per process: the answer is exported so no later call asks gh again
  if [ -n "$org" ]; then export GH_ORG="$org"; echo "$org"; return 0; fi
  repo="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)" \
    || die "no organisation: set GH_ORG in .ai-core/config.env or the environment, or run this inside a repository of it"
  export GH_ORG="${repo%%/*}"
  echo "$GH_ORG"
}

# Which repo to act on. A colleague standing in their own checkout does not have to
# type it; anyone driving another repo from elsewhere passes it explicitly.
#
# The ONE gh call that does not go through gh_read, and it still checks the same signal. What a
# person needs on a failure is what to type instead, so that is what it says, with gh's own words
# behind it.
#
# THE REPOSITORY IS READ OVER REST, through gh's {owner}/{repo} placeholders, not with `gh repo
# view`: that is GraphQL, and a command that only names its repository must not depend on the limit
# GraphQL is under. `gh api --help` of the installed gh says the placeholders take their values
# from the repository of the current directory; `.full_name` is the name GitHub knows it by.
default_repo() {
  local name
  name="$(apart gh api 'repos/{owner}/{repo}' --jq .full_name)" \
    || die "cannot tell which GitHub repo this is - pass the repo as OWNER/REPO: $name"
  echo "$name"
}

# A repo keeps its old boards after they are closed, so the live board is the one
# open project it is linked to. Counting the closed ones would make every long-lived
# repo ambiguous and force an explicit number on every call.
resolve_project_for_repo() {  # resolve_project_for_repo <owner/repo>
  local repo="$1" owner name rows
  owner="${repo%%/*}"; name="${repo#*/}"
  rows="$(gh_read "the projects of $repo" api graphql -f o="$owner" -f n="$name" -f query='
    query($o:String!,$n:String!) { repository(owner:$o, name:$n) {
      projectsV2(first:50) { nodes { number title closed } } } }' \
    --jq '.data.repository.projectsV2.nodes[] | select(.closed == false) | "\(.number)\t\(.title)"')" || exit 1
  # The template board is dropped AFTER the answer is established, so an empty list here means
  # the repo has no board of its own and never that the query was refused.
  rows="$(printf '%s\n' "$rows" | grep -Fv "	$TEMPLATE_MARK" || true)"

  case "$(printf '%s\n' "$rows" | grep -c .)" in
    0) die "$repo is not linked to an open project - run repo-link, or pass --project <number>" ;;
    1) printf '%s\n' "$rows" | cut -f1 ;;
    *) die "$repo is linked to more than one open project ($(printf '%s\n' "$rows" | awk -F'\t' '{ printf "%s%s %s", (NR>1 ? ", " : ""), $1, $2 }')) - pass --project <number>" ;;
  esac
}

# The one open board carrying the template mark. Found by title so replacing the
# template does not mean editing a number into a script.
template_project_number() {
  local rows org
  org="$(gh_org)" || exit 1
  rows="$(gh_read "the projects of $org" api graphql -f o="$org" -f query='
    query($o:String!) { organization(login:$o) {
      projectsV2(first:100) { nodes { number title closed } } } }' \
    --jq '.data.organization.projectsV2.nodes[] | select(.closed == false) | "\(.number)\t\(.title)"')" || exit 1
  rows="$(printf '%s\n' "$rows" | grep -F "	$TEMPLATE_MARK" || true)"

  case "$(printf '%s\n' "$rows" | grep -c .)" in
    0) die "no open project whose title starts with '$TEMPLATE_MARK' in $org - pass --like to name a board to copy" ;;
    1) printf '%s\n' "$rows" | cut -f1 ;;
    *) die "more than one open template board in $org: $(printf '%s\n' "$rows" | cut -f1 | paste -sd' ' -)" ;;
  esac
}

# board_cache_name: the directory of the board under the cache root, its number
board_cache_name() { project_number; }

project_id() {
  local f id from
  f="$(cache_dir)/project-id"
  if [ -s "$f" ]; then
    id="$(cat "$f")"; from="the id cached in $f"
  else
    id="$(gh_read "the id of project $(project_number) in $(project_org)" api graphql \
      -f org="$(project_org)" -F num="$(project_number)" -f query='
      query($org:String!, $num:Int!) {
        organization(login:$org) { projectV2(number:$num) { id } } }' \
      --jq '.data.organization.projectV2.id')" || exit 1
    from="the answer for project $(project_number) of $(project_org)"
  fi

  # WHETHER gh ANSWERED IS NOT WHETHER IT ANSWERED THIS. A query naming an id that belongs to
  # something other than a board is ACCEPTED: it comes back as `{}` with exit 0, which no status
  # check can tell from a real answer. So the value itself is held against the one shape a project
  # id has, wherever it came from.
  #
  # It is checked BEFORE the cache is written, because a file written here is the answer for every
  # later run - nothing asks again once it is not empty - and AFTER the cache is read, because the
  # file can be older than this check, or written by hand.
  case "$id" in
    PVT_*) ;;
    *) die "$from is not a project id: $id" ;;
  esac

  [ -s "$f" ] || { make_cache_dir; printf '%s\n' "$id" > "$f"; }
  printf '%s\n' "$id"
}

# Every single-select field with all of its options, one per line:
#   <field name>\t<field id>\t<option name>\t<option id>
# The cache lives an hour: a board gains columns, and the page and the commands read them within
# the hour; a name the cache does not know reads the board at once (fields_fresh).
fields_tsv() {
  local f rows row
  f="$(cache_dir)/fields.tsv"
  [ -s "$f" ] && [ -z "$(find "$f" -mmin +60)" ] || {
    # Read whole, then written. Redirecting gh straight into the cache stores whatever it wrote
    # under the name of an answer, and every later run finds a non-empty file and never asks again.
    rows="$(gh_read "the fields of board $(project_number)" api graphql -f pid="$(project_id)" -f query='
      query($pid:ID!) { node(id:$pid) { ... on ProjectV2 {
        fields(first:50) { nodes { ... on ProjectV2SingleSelectField {
          id name options { id name } } } } } } }' \
      --jq '.data.node.fields.nodes[] | select(.name != null) | .name as $n | .id as $f
            | .options[] | "\($n)\t\($f)\t\(.name)\t\(.id)"')" || return 1
    make_cache_dir
    printf '%s\n' "$rows" > "$f"
  }
  # And what the cache holds is held against the shape of a row, not trusted. The guard above
  # covers what THIS run writes; the file it reads can be older than the guard, or written by
  # hand. Without this a lookup reports a board that has no fields, which is a statement about the
  # board, and on this path the board was never asked.
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    case "$row" in
      *"	"*"	"*"	"*) ;;
      *) die "$f does not hold field rows - delete $(cache_dir) and run again. It holds: $row" ;;
    esac
  done < "$f"
  cat "$f"
}

# Every repo linked to the selected project.
project_repos() {
  gh_read "the repos linked to board $(project_number)" api graphql -f pid="$(project_id)" -f query='
    query($pid:ID!) { node(id:$pid) { ... on ProjectV2 {
      repositories(first:100) { nodes { nameWithOwner } } } } }' \
    --jq '.data.node.repositories.nodes[].nameWithOwner'
}

# board_repos <board>: every repo linked to that board, the board selected first
board_repos() {
  set_project "$1" >/dev/null
  project_repos
}

# The open boards a repo is linked to, one "<number>\t<title>" per line, EMPTY where it is
# linked to none. It answers the question rather than deciding what to do about the answer,
# because two callers want opposite things from "none": naming a board has to fail, and
# setting a field on a card that cannot exist has to succeed quietly.
repo_open_projects() {  # repo_open_projects <owner/repo>
  local repo="$1" owner name rows
  owner="${repo%%/*}"; name="${repo#*/}"
  rows="$(gh_read "the projects of $repo" api graphql -f o="$owner" -f n="$name" -f query='
    query($o:String!,$n:String!) { repository(owner:$o, name:$n) {
      projectsV2(first:50) { nodes { number title closed } } } }' \
    --jq '.data.repository.projectsV2.nodes[] | select(.closed == false) | "\(.number)\t\(.title)"')" || exit 1
  printf '%s\n' "$rows" | grep -Fv "	$TEMPLATE_MARK" || true
}

# An issue and its whole comment thread, as one JSON object:
#   {number,title,state,labels,body,comments:[{author,created_at,body}]}
#
# The comments are paged. A thread on an epic often runs past one page, and a page that is
# dropped makes the thread look settled when it is not: gh prints one JSON array per page, and every
# page is read.
#
# Both documents reach jq through a PIPE and never as an argument. A busy thread is larger
# than one command-line argument may be - the operating system refuses with "Argument list
# too long" - so passing them in would fail on exactly the issues worth reading.
#
# EACH READ IS ESTABLISHED AS AN ANSWER FIRST. A refused query writes its error body to
# stdout, which jq would read as the issue, so the two reads go through gh_read into
# variables and only then into the program.
issue_thread() {  # issue_thread <owner/repo> <number>
  local issue comments
  issue="$(gh_read "the issue $1#$2" api "repos/$1/issues/$2")" || exit 1
  comments="$(gh_read "the comments of $1#$2" api --paginate "repos/$1/issues/$2/comments")" || exit 1
  printf '%s\n%s\n' "$issue" "$comments" | jq -s '.[0] as $issue | (.[1:] | add // []) as $comments | {
    number:   $issue.number,
    title:    $issue.title,
    state:    $issue.state,
    labels:   [$issue.labels[].name],
    body:     ($issue.body // ""),
    comments: [$comments[] | { author: .user.login, created_at: .created_at, body: (.body // "") }]
  }'
}

# issue_landing_context <owner/repo> <number>: what decides whether the issue holds a record of a landing
# (landing_recorded in lib/board.sh), as one JSON object:
#   {reopenedAt, comments:[{createdAt, body, authorAssociation}]}
# every comment of the thread in the order it was written, each with the association of its author with
# the repository as the tracker names it, and the time of the last reopening, or null. The thread of
# issue_thread has neither the association nor the reopening.
issue_landing_context() {
  local comments reopened
  comments="$(gh_read "the comments of $1#$2" api --paginate "repos/$1/issues/$2/comments")" || exit 1
  reopened="$(gh_read "the last reopening of $1#$2" api graphql -f o="${1%%/*}" -f n="${1#*/}" -F i="$2" -f query='
    query($o:String!, $n:String!, $i:Int!) { repository(owner:$o, name:$n) { issue(number:$i) {
      reopened: timelineItems(last:1, itemTypes:[REOPENED_EVENT]) { nodes { ... on ReopenedEvent { createdAt } } } } } }' \
    --jq '.data.repository.issue.reopened.nodes[0].createdAt')" || exit 1
  printf '%s\n' "$comments" | jq -s --arg reopened "$reopened" '{
    reopenedAt: (if $reopened == "" or $reopened == "null" then null else $reopened end),
    comments:   [(add // [])[] | { createdAt: .created_at, body: (.body // ""), authorAssociation: .author_association }]
  }'
}

# GitHub gives an issue two identities: a node id for GraphQL and a numeric
# database id for the REST sub-issue endpoint. Both are needed.
issue_node_id() {  # issue_node_id <owner/repo> <number>
  gh_read "the node id of $1#$2" api "repos/$1/issues/$2" --jq '.node_id'
}

issue_db_id() {    # issue_db_id <owner/repo> <number>
  gh_read "the database id of $1#$2" api "repos/$1/issues/$2" --jq '.id'
}

# A parent reference from the command line: OWNER/REPO#N, REPO#N, or a bare number. The
# owner defaults to the owner of the repository being acted on, and a bare number stays
# an issue of that repository itself.
#
# THE REFERENCE IS RESOLVED, NOT TRUSTED. Every repository numbers its own issues, so a
# number meant for one repository resolves in any other, to whatever issue happens to
# carry it there - and the sub-issue API accepts that issue without a word. Asking for
# the issue first turns a reference that resolves nowhere into a refusal that names what
# was asked for, and hands back the title so the caller can show which issue it found.
#
# Prints: <owner/repo>\t<number>\t<node id>\t<title>
parent_issue() {  # parent_issue <reference> <owner/repo it is read against>
  local ref="$1" repo="$2" prepo num row
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
  row="$(gh_read "the parent issue $prepo#$num" api graphql \
    -f o="${prepo%%/*}" -f n="${prepo#*/}" -F num="$num" -f query='
    query($o:String!, $n:String!, $num:Int!) { repository(owner:$o, name:$n) {
      issue(number:$num) { id title } } }' \
    --jq '.data.repository.issue | "\(.id)\t\(.title)"')" || exit 1
  printf '%s\t%s\t%s\n' "$prepo" "$num" "$row"
}

# The board item for an issue, adding it to the board if it is not on it yet.
# Adding twice is harmless - GitHub returns the existing item.
#
# ARCHIVED STAYS ARCHIVED. Archiving is the owner's decision and nothing else's, and the mutation
# below does not merely return an existing item - it takes it back OUT of the archive. So a card
# somebody deliberately put away is on the board again after the next sweep, with nobody having
# asked for it.
#
# It cannot be caught by looking at the board: a project's item list leaves archived items out, so
# the sweep sees no card, concludes one is missing, and adds it. The question has to be asked from
# the ISSUE, which is the one side that can be told to include them.
#
# THE QUESTION IS ASKED BEFORE THE MUTATION, AND A REFUSED ONE STOPS THE SCRIPT. A refusal that
# left an empty value behind would read as "this issue has no archived card", and the next line
# takes a card out of the archive - so the one answer that must never be guessed is the one that
# is guessed by default.
item_id() {  # item_id <owner/repo> <number>
  local existing cid
  existing="$(archived_item_id "$1" "$2")" || exit 1
  if [ -n "$existing" ]; then
    echo "$existing"
    return 0
  fi
  cid="$(issue_node_id "$1" "$2")" || exit 1
  gh_read "the board item added for $1#$2" api graphql -f pid="$(project_id)" -f cid="$cid" -f query='
    mutation($pid:ID!, $cid:ID!) {
      addProjectV2ItemById(input:{projectId:$pid, contentId:$cid}) { item { id } } }' \
    --jq '.data.addProjectV2ItemById.item.id'
}

# The id of this issue's ARCHIVED item on this board, or nothing when it has none.
#
# THE BOARD IS PICKED OUT HERE AND NOT INSIDE THE jq PROGRAM. jq asks which items are archived;
# which of them are on THIS board is decided afterwards, against a value that stays a value.
# Writing the id into the program text instead makes the program depend on what the id contains,
# and jq reads a double quote or a backslash in it as program, not as data.
archived_item_id() {  # archived_item_id <owner/repo> <number>
  local owner="${1%%/*}" name="${1#*/}" project_id rows found item
  # The board this run is about, resolved before the rows are matched against it. An empty value
  # here matches no row, which reads as "nothing of this issue is archived" - the one answer that
  # puts a card back on the board.
  project_id="$(project_id)" || exit 1
  rows="$(gh_read "the project items of $1#$2" api graphql -f o="$owner" -f n="$name" -F num="$2" -f query='
    query($o:String!, $n:String!, $num:Int!) { repository(owner:$o, name:$n) {
      issue(number:$num) { projectItems(first:20, includeArchived:true) {
        nodes { id isArchived project { id } } } } } }' \
    --jq '.data.repository.issue.projectItems.nodes[]
            | select(.isArchived) | "\(.project.id)\t\(.id)"')" || exit 1
  printf '%s\n' "$rows" \
  | while IFS=$'\t' read -r found item; do
      [ "$found" = "$project_id" ] || continue
      printf '%s\n' "$item"
      break
    done
}

# Every open board this issue has a card on, one line per board:
#   <project number>\t<item id>
#
# The issue's own projectItems is the authoritative list. A REPO resolves to one board, but an
# ISSUE can be on several - a cross-repository epic pulls its child onto its own board - and a
# card that is stale on the second board makes that board lie to whoever filters it.
# Every open board an issue has a card on, one `OWNER/N<tab><item id>` per line. THE BOARD IS
# NAMED WITH ITS OWNER, because a number alone is resolved under the organisation of the
# repository the command names (set_project), and a card can stand on another organisation's
# board - which is exactly the card a command like issue-close has to reach.
issue_board_items() {  # issue_board_items <owner/repo> <number>
  local owner="${1%%/*}" name="${1#*/}"
  gh_read "the project items of $1#$2" api graphql -f o="$owner" -f n="$name" -F num="$2" -f query='
    query($o:String!, $n:String!, $num:Int!) { repository(owner:$o, name:$n) {
      issue(number:$num) { projectItems(first:20) {
        nodes { id project { number closed owner { ... on Organization { login } ... on User { login } } } } } } } }' \
    --jq '.data.repository.issue.projectItems.nodes[]
          | select(.project.closed == false)
          | "\(.project.owner.login)/\(.project.number)\t\(.id)"'
}

# Put one card at the top of the board, or directly under another one.
#
# The second argument is what makes a NAMED ORDER possible: moving each card to the top would
# reverse the names into a stack, so the caller hands the card moved before this one and this
# lands right beneath it. With no second argument the card goes above everything, which is what
# the FIRST name in a list wants. An empty string is treated as no argument at all, since an
# omitted GraphQL variable is the absence of a value and not one that is empty.
item_top() {  # item_top <item id> [after item id]
  local iid="$1" after="${2:-}" call
  call=(api graphql -f "pid=$(project_id)" -f "iid=$iid")
  [ -n "$after" ] && call+=(-f "after=$after")
  gh "${call[@]}" -f query='
    mutation($pid:ID!, $iid:ID!, $after:ID) {
      updateProjectV2ItemPosition(input:{
        projectId:$pid, itemId:$iid, afterId:$after}) { items { totalCount } } }' >/dev/null
}

# Every card on this board, paged, one per line:
#   <item id>\t<owner/repo>\t<issue number>
# A board outgrows one page of 100 quickly, and a single unpaged query silently
# reports the rest as absent.
board_items() {
  local after="" page
  while :; do
    if [ -n "$after" ]; then
      page="$(gh_read "the cards of board $(project_number) after $after" api graphql -f pid="$(project_id)" -f after="$after" -f query='
        query($pid:ID!, $after:String) { node(id:$pid) { ... on ProjectV2 {
          items(first:100, after:$after) { pageInfo { hasNextPage endCursor }
            nodes { id content { ... on Issue { number repository { nameWithOwner } } } } } } } }')" || exit 1
    else
      page="$(gh_read "the cards of board $(project_number)" api graphql -f pid="$(project_id)" -f query='
        query($pid:ID!) { node(id:$pid) { ... on ProjectV2 {
          items(first:100) { pageInfo { hasNextPage endCursor }
            nodes { id content { ... on Issue { number repository { nameWithOwner } } } } } } } }')" || exit 1
    fi
    printf '%s' "$page" | jq -r '.data.node.items.nodes[]
      | select(.content.number != null)
      | "\(.id)\t\(.content.repository.nameWithOwner)\t\(.content.number)"'
    [ "$(printf '%s' "$page" | jq -r '.data.node.items.pageInfo.hasNextPage')" = 'true' ] || break
    after="$(printf '%s' "$page" | jq -r '.data.node.items.pageInfo.endCursor')"
  done
}

# Takes a card off this board. The issue itself is untouched. Prints nothing and
# returns non-zero when the issue was not on the board.
remove_board_item() {  # remove_board_item <owner/repo> <number>
  local rows item
  # The board is read whole first: a refusal reaching the match below would come out as "the issue
  # was not on the board", which is an answer about the board and the board did not answer.
  rows="$(board_items)" || exit 1
  item="$(printf '%s\n' "$rows" | awk -F'\t' -v r="$1" -v n="$2" '$2==r && $3==n {print $1; exit}')"
  [ -n "$item" ] || return 1
  gh api graphql -f pid="$(project_id)" -f iid="$item" -f query='
    mutation($pid:ID!, $iid:ID!) {
      deleteProjectV2Item(input:{projectId:$pid, itemId:$iid}) { deletedItemId } }' >/dev/null
}

# THE TWO LOOKUPS ARE RESOLVED BEFORE THE MUTATION, and a failed one STOPS THE SCRIPT.
#
# `die` inside `$( )` exits the substitution and nothing else. Written as arguments to the call
# below, a field or an option that could not be resolved printed its refusal, left an EMPTY value
# behind, and the mutation went ahead with it — so a person read the tool's own error, then a
# second one from gh about an id that belongs to no field, and the script exited 0. A caller reading
# that status was told the card had moved.
#
# `local x; x="$(...)" || exit 1` is what makes the substitution's failure the script's failure. It
# is the same trap board-sync names about set_project, in the other direction.
set_select() {  # set_select <item id> <field name> <option name>
  local fid oid
  fid="$(field_id "$2")" || exit 1
  oid="$(option_id "$2" "$3")" || exit 1
  gh api graphql -f pid="$(project_id)" -f iid="$1" \
    -f fid="$fid" -f oid="$oid" -f query='
    mutation($pid:ID!, $iid:ID!, $fid:ID!, $oid:String!) {
      updateProjectV2ItemFieldValue(input:{
        projectId:$pid, itemId:$iid, fieldId:$fid,
        value:{singleSelectOptionId:$oid}}) { projectV2Item { id } } }' >/dev/null
}

# github_subissues <owner/repo> <number> <fields of the issue> <fields of a sub-issue> <jq program>: the jq
# program run over the issue and over every page of its sub-issues, its lines printed in page order. The
# program reads .data.repository.issue and may ask onfirstpage, true on the first page alone, for what is
# said once. A page is read until the tracker says there is no further one; a read that fails ends the whole
# read, so no part of the sub-issues is ever taken for all of them.
github_subissues() {
  local after="" first=true out
  while :; do
    out="$(gh_read "the sub-issues of $1#$2" api graphql -f o="${1%%/*}" -f r="${1#*/}" -F n="$2" ${after:+-f after="$after"} -f query='
      query($o:String!, $r:String!, $n:Int!, $after:String) { repository(owner:$o, name:$r) { issue(number:$n) {
        '"$3"'
        subIssues(first:100, after:$after) { pageInfo { hasNextPage endCursor } nodes { '"$4"' } } } } }' \
      --jq "def onfirstpage: $first; ($5), (.data.repository.issue.subIssues.pageInfo | select(.hasNextPage) | \"after \(.endCursor)\")")" || return 1
    after="$(sed -n 's/^after //p' <<< "$out")"
    grep -v '^after ' <<< "$out" || true
    [ -n "$after" ] || break
    first=false
  done
}

# open_subissues <owner/repo> <number>: the sub-issues of an issue that are not closed, one "<owner/repo>#<number>"
# a line, none where it has none. Whether one is closed is the issue's own state, never the column of a card.
open_subissues() {
  github_subissues "$1" "$2" '' 'number state repository { nameWithOwner }' \
    '.data.repository.issue.subIssues.nodes[] | select(.state != "CLOSED") | "\(.repository.nameWithOwner)#\(.number)"' || exit 1
}

# epic_target_on_board <owner/repo> <number> - the epic_target of an issue, read from its own card
# and its sub-issues' cards on the selected board, or on whichever board they are on when none is
# selected; an issue without sub-issues gets nothing. A sub-issue counts as done or as not planned only
# when it is closed: an open one counts at most as testing, whatever column its card stands in, a column
# called done or not planned included, or the epic would close with that issue still open. One with no
# card on the selected board, often one of another repository on that repository's board, counts where
# its first card with a status stands.
epic_target_on_board() {
  local repo="$1" n="$2" on="" rows cur="" first=1 st
  [ -z "${PROJECT:-}" ] || on="select(.project.number == $(project_number) and .project.owner.login == \"$(project_org)\") |"
  local fields='state stateReason projectItems(first:20) { nodes { project { number owner { ... on Organization { login } ... on User { login } } }
        status: fieldValueByName(name:"Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } } } }'
  rows="$(github_subissues "$repo" "$n" "$fields" "$fields" "
    def card: [.projectItems.nodes[] | $on (.status.name // \"backlog\")] | first;
    def anycard: [.projectItems.nodes[] | .status.name | select(. != null)] | first;
    def closed: if .stateReason == \"NOT_PLANNED\" or .stateReason == \"DUPLICATE\" then \"not planned\" else \"done\" end;
    def unclosed(c): (c // \"backlog\") | if (ascii_downcase | IN(\"done\", \"not planned\")) then \"testing\" else . end;
    (.data.repository.issue | if onfirstpage then (if .state == \"CLOSED\" then closed else (card // \"backlog\") end) else empty end),
    (.data.repository.issue.subIssues.nodes[] | if .state == \"CLOSED\" then closed else unclosed(card // anycard) end)")" || return 1
  set --
  while IFS= read -r st; do
    st="$(printf '%s' "$st" | tr -d '\r' | tr '[:upper:]' '[:lower:]')"
    if [ "$first" = 1 ]; then cur="$st"; first=0; else set -- "$@" "$st"; fi
  done <<< "$rows"
  epic_target "$cur" "$@"
}

# The board number as this tracker writes it: digits and nothing else. set_project judges every
# number that reaches it here, and a tracker that names a board otherwise says so in its own copy.
check_project_number() {  # check_project_number <board number>
  case "$1" in ''|*[!0-9]*) die "the board number must be numeric, not '$1'" ;; esac
}

# The parent of an issue, "owner/repo number", or nothing for an issue without one.
issue_parent() {  # issue_parent <owner/repo> <number>
  gh_read "the parent of $1#$2" api graphql -f o="${1%%/*}" -f r="${1#*/}" -F n="$2" -f query='
    query($o:String!, $r:String!, $n:Int!) { repository(owner:$o, name:$r) { issue(number:$n) {
      parent { number repository { nameWithOwner } } } } }' \
    --jq '.data.repository.issue.parent | select(. != null) | "\(.repository.nameWithOwner) \(.number)"'
}

# --- the issue commands -------------------------------------------------------
#
# One function for each call an issue command makes. The command keeps its arguments, its output and
# its exit codes; what is GitHub's here is the endpoint, the mutation and the words of its refusals.

# Email-to-member resolution belongs to Plane; GitHub takes logins or gh's special tokens.
check_github_assignees() {  # check_github_assignees <command> <comma- or newline-separated assignees>
  local command="$1" assignee
  while IFS= read -r assignee; do
    case "$assignee" in
      @me|@copilot) ;;
      *@*) die "$command: GitHub assignees must be logins, not email addresses: $assignee" ;;
    esac
  done < <(printf '%s\n' "$2" | tr ',' '\n')
}

# issue_create <owner/repo> <title> <body file> <assignee> [label...]: prints the number of the new issue.
# A create that fails is no read problem: gh names why on stderr, most often a label of labels.tsv
# that labels-sync has not yet made in this repository, and nothing was created.
issue_create() {
  local repo="$1" title="$2" body="$3" assignee="$4" args l rc=0 url
  check_github_assignees issue-new "$assignee"
  shift 4
  args=(--repo "$repo" --title "$title" --body-file "$body" --assignee "$assignee")
  for l in "$@"; do args+=(--label "$l"); done
  url="$(gh issue create "${args[@]}")" || rc=$?
  [ "$rc" -eq 0 ] || die "the issue was NOT created in $repo - gh exited $rc, for the reason it wrote above. Where that is a label the repository does not have, run: ai-core labels-sync $repo"
  echo "${url##*/}"
}

# The sub-issue link made with the addSubIssue mutation, which takes node ids and is not bound to one
# repository the way the REST sub_issues endpoint is - posting a number there reads it in ONE
# repository, and a parent meant for another silently becomes whatever issue carries that number here.
# subissue_attach_resolved <parent node id> <owner/repo> <number>: the child is the issue <number>
# of <owner/repo>; the parent was resolved before anything was created (parent_issue), so a reference
# that resolves nowhere stopped the run with nothing made.
subissue_attach_resolved() {
  local child
  child="$(issue_node_id "$2" "$3")" || exit 1
  gh api graphql -f parent="$1" -f child="$child" -f query='
    mutation($parent:ID!, $child:ID!) {
      addSubIssue(input:{issueId:$parent, subIssueId:$child}) { issue { number } } }' >/dev/null
}

# subissue_attach <owner/repo> <parent number> <child owner/repo> <child number>
subissue_attach() {
  local child_id
  # Resolved before the call, not inside it: a failed command substitution does not stop the command
  # it stands in, so an id that could not be read would be posted as an empty one.
  child_id="$(issue_db_id "$3" "$4")" || exit 1
  gh api --method POST "repos/$1/issues/$2/sub_issues" -F sub_issue_id="$child_id" >/dev/null
}

# subissue_detach <owner/repo> <parent number> <child owner/repo> <child number>
subissue_detach() {
  local child_id
  child_id="$(issue_db_id "$3" "$4")" || exit 1
  gh_read "the detach of $3#$4 from $1#$2" api --method DELETE \
    "repos/$1/issues/$2/sub_issue" -F sub_issue_id="$child_id" >/dev/null || exit 1
}

# issue_assignees <owner/repo> <number>: the logins assigned, one per line.
# The issue is established as an answer before its assignees are read out of it: a refused query
# answers with an error body, and reading no login out of that is "assigned to nobody".
issue_assignees() {
  local issue
  issue="$(gh_read "the issue $1#$2" api "repos/$1/issues/$2")" || exit 1
  printf '%s' "$issue" | jq -r '.assignees[]?.login'
}

# issue_assignees_set <owner/repo> <number> <logins, one per line>: the assignees become exactly these.
issue_assignees_set() {
  check_github_assignees issue-assign "$3"
  printf '%s\n' "$3" | jq -R . | jq -sc '{assignees: [.[] | select(. != "")]}' \
    | gh api --method PATCH "repos/$1/issues/$2" --input - >/dev/null \
    || die "could not set the assignees of $1#$2"
}

# THE ENDPOINT'S REPO IS THE BLOCKED ISSUE'S and the id is the BLOCKER's database id - resolved
# BEFORE the call, so an id that could not be read stops the run instead of being posted as an empty
# one, and in the shape the DELETE takes, so the two cannot come to disagree about which side of the
# relationship is addressed.
# issue_block <blocked owner/repo> <blocked number> <by owner/repo> <by number>
issue_block() {
  local by_id answer
  by_id="$(issue_db_id "$3" "$4")" || exit 1
  if ! answer="$(gh api --method POST "repos/$1/issues/$2/dependencies/blocked_by" \
        -F issue_id="$by_id" 2>&1)"; then
    case "$answer" in
      *422*) die "$1#$2 is already blocked by $3#$4 - nothing was changed" ;;
      *404*) die "an issue was not found - check OWNER/REPO and the numbers on both sides" ;;
      *)     die "$answer" ;;
    esac
  fi
}

issue_unblock() {  # issue_unblock <blocked owner/repo> <blocked number> <by owner/repo> <by number>
  local by_id answer
  by_id="$(issue_db_id "$3" "$4")" || exit 1
  if ! answer="$(gh api --method DELETE "repos/$1/issues/$2/dependencies/blocked_by/$by_id" 2>&1)"; then
    case "$answer" in
      *404*) die "$1#$2 is not blocked by $3#$4 - nothing was changed" ;;
      *)     die "$answer" ;;
    esac
  fi
}

# issue_labels <owner/repo> <number>: the names of the labels on the issue, one per line.
issue_labels() {
  gh_read "the labels of $1#$2" issue view "$2" --repo "$1" --json labels -q '.labels[].name'
}

# issue_labels_set <owner/repo> <number> <+name | -name>...: +name puts a label on, -name takes it off.
# A label name may hold a space - GitHub's own defaults include "help wanted" - so the gh call is
# built as an argument array: glued into one word-split string, such a name arrives as two
# arguments and gh removes a label that was never asked for.
issue_labels_set() {
  local repo="$1" n="$2" l edit=()
  shift 2
  for l in "$@"; do
    case "$l" in
      +*) edit+=(--add-label "${l#+}") ;;
      -*) edit+=(--remove-label "${l#-}") ;;
    esac
  done
  [ ${#edit[@]} -eq 0 ] || gh issue edit "$n" --repo "$repo" "${edit[@]}" >/dev/null
}

labels_create() {  # labels_create <owner/repo> <name> <colour> <description>
  gh label create "$2" --repo "$1" --color "$3" --description "$4" --force >/dev/null
}

# labels_list <owner/repo>: the names of the labels the repository carries, one per line.
labels_list() {
  gh_read "the labels of $1" label list --repo "$1" --limit 200 --json name --jq '.[].name'
}

# tracker_doctor: the lines `ai-core doctor` prints for the tracker. Where the forge is GitHub too, its doctor
# checks gh with the same lines; where the forge is elsewhere, nothing else would, and the board commands
# still need gh, its login and the project scope.
tracker_doctor() {
  echo "  tracker: github"
  [ "$(config_value FORGE github | tr '[:upper:]' '[:lower:]')" = github ] || gh_doctor
}

# closing_column <completed | not-planned>: the Status a closed issue's card is put in; the board has one
# column for both reasons
closing_column() { echo done; }

# writes_run_in_repo_clone <owner/repo>: never on GitHub, where a command acts for any repository it is given
writes_run_in_repo_clone() { return 1; }

# tracker_login: the login the tracker knows the caller by. The answer is established as one before
# the login is read out of it: a refused query writes its error body to stdout, so a login read
# straight through a pipe would be the refusal text.
tracker_login() {
  local who login
  who="$(gh_read "who gh is logged in as" api user)" || exit 1
  login="$(printf '%s' "$who" | jq -r '.login // ""')"
  [ -n "$login" ] || die "cannot read who gh is logged in as - run 'gh auth status'"
  echo "$login"
}

# issue_close <owner/repo> <number> <completed | not-planned>
issue_close() {
  local state_reason="completed"
  [ "$3" != not-planned ] || state_reason="not_planned"
  gh_read "the close of $1#$2" api --method PATCH "repos/$1/issues/$2" \
    -f state=closed -f state_reason="$state_reason" >/dev/null || exit 1
}

issue_reopen() {  # issue_reopen <owner/repo> <number>
  gh_read "the reopen of $1#$2" api --method PATCH "repos/$1/issues/$2" -f state=open >/dev/null || exit 1
}

# issue_comment_post <owner/repo> <number> <text> <text file>: prints the comment's URL. One of the
# two texts is empty. Over REST, not `gh issue comment`: that call is GraphQL, and a refusal of GraphQL
# by a rate limit must not lose the comment. -F reads the file named after @ as it is; -f sends the
# inline text as it is.
issue_comment_post() {
  local field
  if [ -n "$4" ]; then field=(-F "body=@$4"); else field=(-f "body=$3"); fi
  gh_read "the comment posted on $1#$2" api "repos/$1/issues/$2/comments" "${field[@]}" --jq .html_url
}

# duplicate_mark <canonical owner/repo> <number> <duplicate owner/repo> <number> <comment>: the duplicate gets a
# comment that names the canonical issue.
duplicate_mark() {
  gh_read "the duplicate mark on $3#$4" api --method POST \
    "repos/$3/issues/$4/comments" -f "body=$5" >/dev/null || exit 1
}

duplicate_unmark() {  # duplicate_unmark <canonical owner/repo> <number> <duplicate owner/repo> <number>
  local canonical_id duplicate_id mutation
  # Both ids are resolved before the mutation, not inside it: a failed command substitution does
  # not stop the command it stands in, so an id that could not be read would be sent as empty.
  canonical_id="$(issue_node_id "$1" "$2")" || exit 1
  duplicate_id="$(issue_node_id "$3" "$4")" || exit 1
  mutation='mutation($canonical:ID!,$duplicate:ID!){unmarkIssueAsDuplicate(input:{canonicalId:$canonical,duplicateId:$duplicate}){duplicate{... on Issue{number}}}}'
  gh_read "the duplicate mark taken off $3#$4" api graphql \
    -f canonical="$canonical_id" -f duplicate="$duplicate_id" -f query="$mutation" >/dev/null || exit 1
}

# issue_body <owner/repo> <number>: the body of the issue, as the tracker stores it.
issue_body() {
  gh_read "the body of $1#$2" api "repos/$1/issues/$2" --jq '.body'
}

# issue_edit <owner/repo> <number> <title or empty> <body file or empty>
issue_edit() {
  local call=(api --method PATCH "repos/$1/issues/$2")
  [ -n "$3" ] && call+=(-f "title=$3")
  [ -n "$4" ] && call+=(-F "body=@$4")
  gh_read "the edit of $1#$2" "${call[@]}" >/dev/null || exit 1
}

issue_transfer() {  # issue_transfer <owner/repo> <number> <target owner/repo>: prints the new issue's URL
  gh_read "the transfer of $1#$2 to $3" issue transfer "$2" "$3" --repo "$1"
}

# issue_rows <owner/repo>: the open issues of the repository, one JSON object per line, the issue row
# of lib/tracker.sh:
#   {repo, number, title, body, open, labels: [name], status, parent, blockedBy, blocking, cut}
# parent, blockedBy and blocking name issues as "owner/repo#number"; status is the name of the issue's
# first card's Status, or null; cut lists what the tracker gave in part ("labels shows 50 of 63"). The
# priority, the closing time and the sub-issue count of the card row belong to card_rows.
issue_rows() {
  local repo="$1" page
  page="$(gh_read "the open issues of $repo" api graphql --paginate -F owner="${repo%%/*}" -F name="${repo#*/}" -f query='
    query($owner:String!, $name:String!, $endCursor:String) { repository(owner:$owner, name:$name) {
      issues(states:OPEN, first:50, after:$endCursor) { pageInfo { hasNextPage endCursor } nodes {
        number title body
        labels(first:50) { totalCount nodes { name } }
        parent { number repository { nameWithOwner } }
        blockedBy(first:50) { totalCount nodes { number repository { nameWithOwner } } }
        blocking(first:50) { totalCount nodes { number repository { nameWithOwner } } }
        projectItems(first:5) { nodes { fieldValueByName(name:"Status") {
          ... on ProjectV2ItemFieldSingleSelectValue { name } } } } } } } }')" || exit 1
  jq -c --arg repo "$repo" '
    .data.repository.issues.nodes[]
    | def ref: "\(.repository.nameWithOwner)#\(.number)";
      def cut($what; $list): if $list.totalCount > ($list.nodes | length)
        then ["\($what) shows \($list.nodes | length) of \($list.totalCount)"] else [] end;
      { repo: $repo, number, title, body: (.body // ""), open: true,
        labels: [.labels.nodes[].name],
        status: ([.projectItems.nodes[].fieldValueByName.name // empty][0]),
        parent: (if .parent then (.parent | ref) else null end),
        blockedBy: [.blockedBy.nodes[] | ref], blocking: [.blocking.nodes[] | ref],
        cut: (cut("labels"; .labels) + cut("blocked by"; .blockedBy) + cut("blocks"; .blocking)) }' <<< "$page"
}

# issues_created_since <owner/repo> <YYYY-MM-DD> <limit>: the newest <limit> issues of the repository
# created on that day or later, open or closed, as a JSON array of {createdAt, labels: [name]}.
issues_created_since() {
  local found
  found="$(gh_read "the issues of $1" issue list --repo "$1" --state all --limit "$3" \
           --search "created:>=$2" --json createdAt,labels)" || exit 1
  printf '%s' "$found" | jq -c '[.[] | {createdAt, labels: [.labels[].name]}]'
}

# projects_of_org <organisation>: the open boards of the organisation, one "<number>\t<title>" per line.
projects_of_org() {
  gh_read "the projects of $1" api graphql -f o="$1" -f query='
    query($o:String!) { organization(login:$o) {
      projectsV2(first:100) { nodes { number title closed } } } }' \
    --jq '.data.organization.projectsV2.nodes[] | select(.closed == false) | "\(.number)\t\(.title)"'
}

# --- the board commands -------------------------------------------------------

# item_unarchive <item id>: the card comes back onto the selected board.
item_unarchive() {
  gh api graphql -f pid="$(project_id)" -f iid="$1" -f query='
    mutation($pid:ID!, $iid:ID!) {
      unarchiveProjectV2Item(input:{projectId:$pid, itemId:$iid}) { item { id } } }' \
    --jq '.data.unarchiveProjectV2Item.item.id' >/dev/null
}

# issue_numbers_closed <owner/repo>: the numbers of the newest 200 closed issues, one per line.
issue_numbers_closed() {
  gh_read "the closed issues of $1" issue list --repo "$1" --state closed --limit 200 \
    --json number --jq '.[].number'
}

# issue_summaries <owner/repo>: the newest 500 issues, open or closed, one
# "<number>\t<OPEN|CLOSED>\t<labels, comma between>\t<title>" per line. The title stands last because
# it is the one field a person types.
issue_summaries() {
  gh_read "the issues of $1" issue list --repo "$1" --state all --limit 500 \
    --json number,state,title,labels \
    --jq '.[] | "\(.number)\t\(.state)\t\([.labels[].name] | join(","))\t\(.title)"'
}

issue_title() {  # issue_title <owner/repo> <number>
  gh_read "the title of $1#$2" issue view "$2" --repo "$1" --json title --jq '.title'
}

# board_card_lines <organisation, lower case>: every card of the selected board that is an issue, one
# "<status>\t<priority>\t<repository>\t<number>\t<title>\t<closed or empty>" per line. The repository
# is written without its owner when the owner is the organisation.
board_card_lines() {
  gh_read "the cards of board $(project_number)" api graphql --paginate -f pid="$(project_id)" -f query='
    query($pid:ID!, $endCursor:String) { node(id:$pid) { ... on ProjectV2 {
      items(first:100, after:$endCursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          fieldValues(first:20) { nodes { ... on ProjectV2ItemFieldSingleSelectValue {
            name field { ... on ProjectV2SingleSelectField { name } } } } }
          content { ... on Issue { number title state repository { name nameWithOwner } } }
        } } } } }' \
    --jq '.data.node.items.nodes[] | select(.content.number != null)
          | { n: .content.number, t: .content.title, closed: (.content.state == "CLOSED"),
              r: (.content.repository | if (.nameWithOwner | ascii_downcase) == ("'"$1"'/" + (.name | ascii_downcase)) then .name else .nameWithOwner end),
              s: ([.fieldValues.nodes[] | select(.field.name == "Status")   | .name] | first // "-"),
              p: ([.fieldValues.nodes[] | select(.field.name == "Priority") | .name] | first // "-") }
          | "\(.s)\t\(.p)\t\(.r)\t\(.n)\t\(.t)\t\(if .closed then "closed" else "" end)"'
}

# board_cards_of_repo <owner/repo>: every card of this repository on the selected board with the two
# values worth carrying, one "<number>\t<status>\t<priority>" per line. One page of 100 does not
# cover a board that has run for a while, so this pages.
board_cards_of_repo() {
  local after="" page
  while :; do
    if [ -n "$after" ]; then
      page="$(gh_read "the cards of board $(project_number) after $after" api graphql -f pid="$(project_id)" -f after="$after" -f query='
        query($pid:ID!, $after:String) { node(id:$pid) { ... on ProjectV2 {
          items(first:100, after:$after) { pageInfo { hasNextPage endCursor }
            nodes { id
              content { ... on Issue { number repository { nameWithOwner } } }
              fieldValues(first:20) { nodes { ... on ProjectV2ItemFieldSingleSelectValue {
                name field { ... on ProjectV2SingleSelectField { name } } } } } } } } } }')" || exit 1
    else
      page="$(gh_read "the cards of board $(project_number)" api graphql -f pid="$(project_id)" -f query='
        query($pid:ID!) { node(id:$pid) { ... on ProjectV2 {
          items(first:100) { pageInfo { hasNextPage endCursor }
            nodes { id
              content { ... on Issue { number repository { nameWithOwner } } }
              fieldValues(first:20) { nodes { ... on ProjectV2ItemFieldSingleSelectValue {
                name field { ... on ProjectV2SingleSelectField { name } } } } } } } } } }')" || exit 1
    fi
    printf '%s' "$page" | jq -r --arg r "$1" '
      .data.node.items.nodes[]
      | select(.content.number != null and .content.repository.nameWithOwner == $r)
      | . as $i
      | ($i.fieldValues.nodes | map(select(.field.name == "Status"))   | .[0].name // "") as $s
      | ($i.fieldValues.nodes | map(select(.field.name == "Priority")) | .[0].name // "") as $p
      | "\($i.content.number)\t\($s)\t\($p)"'
    [ "$(printf '%s' "$page" | jq -r '.data.node.items.pageInfo.hasNextPage')" = 'true' ] || break
    after="$(printf '%s' "$page" | jq -r '.data.node.items.pageInfo.endCursor')"
  done
}

# --- the whole source of an issue carry -----------------------------------------------------
# Everything the carry reads from GitHub, and only reads: the repositories of the owner, the issues of a
# repository with their comments, labels, parent and every board membership (archived ones too), and the boards
# of the owner with their linked repositories and items (archived ones too). A page, a nested overflow and an
# error answer are checked here: an incomplete read dies naming what it was reading, and is never an empty one.

# carry_pages <what> <jq path to the connection> <query> [gh argument...]: the nodes of a connection, one JSON
# object per line, every page read. CARRY_AFTER names the cursor to start after.
carry_pages() {
  local what="$1" path="$2" query="$3" page conn cursor="${CARRY_AFTER:-}" seen=" "
  shift 3
  while :; do
    if [ -n "$cursor" ]; then page="$(gh_read "$what" api graphql -f query="$query" "$@" -f c="$cursor")" || exit 1
    else page="$(gh_read "$what" api graphql -f query="$query" "$@")" || exit 1; fi
    conn="$(jq -c "if ((.errors // []) | length) > 0 then error(\"errors\") else $path end" <<< "$page" 2>/dev/null)" \
      || die "cannot read $what - GitHub answered with errors or not with JSON: $(printf '%s' "$page" | tr -s '\r\n' '  ' | cut -c1-300)"
    [ "$conn" != null ] && jq -e '(.nodes | type) == "array"' <<< "$conn" >/dev/null 2>&1 \
      || die "cannot read $what - GitHub answered without the connection"
    jq -c '.nodes[]' <<< "$conn"
    [ "$(jq -r '.pageInfo.hasNextPage' <<< "$conn")" = true ] || break
    cursor="$(jq -r '.pageInfo.endCursor // empty' <<< "$conn")"
    [ -n "$cursor" ] || die "cannot read $what - GitHub announced a next page and gave no cursor for it"
    case "$seen" in *" $cursor "*) die "cannot read $what - GitHub answered the page cursor $cursor again, so the listing does not advance" ;; esac
    seen="$seen$cursor "
  done
}

# carry_overflow <what> <node id> <GraphQL type> <connection> <extra arguments> <selection> <cursor>: the nodes of a
# connection of one node after the first page, which the issue or board query read with its parent
carry_overflow() {
  CARRY_AFTER="$7" carry_pages "$1" ".data.node.$4" \
    'query($id:ID!,$c:String){ node(id:$id){ ... on '"$3"' { '"$4"'(first:100, after:$c'"$5"') { nodes{ '"$6"' } pageInfo{ hasNextPage endCursor } } } } }' -f id="$2"
}

# carry_append <row> <field> <values>: the row with these JSON values, one per line, added to the end of its field. The row and the
# values reach jq on standard input, never as an argument: Linux refuses one argument over 128 KiB, and a thread or a board outgrows it.
carry_append() { { printf '%s\n' "$1"; printf '%s\n' "$3"; } | jq -nc --arg k "$2" 'input as $row | [inputs] as $e | $row | .[$k] += $e'; }

CARRY_FIELD_VALUES='fieldValues(first:20){ nodes{ ... on ProjectV2ItemFieldSingleSelectValue{ name field{ ... on ProjectV2SingleSelectField{ name } } } } }'
CARRY_COMMENT='id url createdAt body author{ login }'
CARRY_MEMBERSHIP='id isArchived project{ id } '"$CARRY_FIELD_VALUES"
# the close and reopen events of an issue, which tell a close a person made after the old carry's from the old carry's own
CARRY_TIMELINE='__typename ... on ClosedEvent{ createdAt } ... on ReopenedEvent{ createdAt }'
CARRY_TIMELINE_TYPES='itemTypes: [CLOSED_EVENT, REOPENED_EVENT]'
CARRY_TIMELINE_EVENT='select(.__typename == "ClosedEvent" or .__typename == "ReopenedEvent") | {kind: (if .__typename == "ClosedEvent" then "closed" else "reopened" end), at: .createdAt}'
# stateReason(enableDuplicate: true) is the only spelling that tells DUPLICATE from NOT_PLANNED, and
# projectItems(includeArchived: true) the only one that shows an archived card
CARRY_ISSUE='id number title body state stateReason(enableDuplicate: true) url
  labels(first:100){ nodes{ name } pageInfo{ hasNextPage endCursor } }
  comments(first:100){ nodes{ '"$CARRY_COMMENT"' } pageInfo{ hasNextPage endCursor } }
  parent{ id number url repository{ nameWithOwner } }
  projectItems(first:50, includeArchived: true){ nodes{ '"$CARRY_MEMBERSHIP"' } pageInfo{ hasNextPage endCursor } }
  timelineItems(first:100, '"$CARRY_TIMELINE_TYPES"'){ nodes{ '"$CARRY_TIMELINE"' } pageInfo{ hasNextPage endCursor } }'
CARRY_STATUS='(first(.fieldValues.nodes[]? | select(.field.name == "Status") | .name) // null)'
CARRY_PRIORITY='(first(.fieldValues.nodes[]? | select(.field.name == "Priority") | .name) // null)'
CARRY_ISSUE_ROW='{kind: "issue", repo: $repo, number, id, url, title, body, state, reason: .stateReason, labels: [.labels.nodes[].name],
  comments: [.comments.nodes[] | {id, url, createdAt, body, author: (.author.login // null)}],
  parent: (if .parent == null then null else {id: .parent.id, repo: .parent.repository.nameWithOwner, number: .parent.number, url: .parent.url} end),
  memberships: [.projectItems.nodes[] | {item: .id, board: .project.id, archived: .isArchived, status: '"$CARRY_STATUS"', priority: '"$CARRY_PRIORITY"'}],
  timeline: [.timelineItems.nodes[] | '"$CARRY_TIMELINE_EVENT"'],
  more: {labels: (if .labels.pageInfo.hasNextPage then .labels.pageInfo.endCursor else null end),
         comments: (if .comments.pageInfo.hasNextPage then .comments.pageInfo.endCursor else null end),
         memberships: (if .projectItems.pageInfo.hasNextPage then .projectItems.pageInfo.endCursor else null end),
         timeline: (if .timelineItems.pageInfo.hasNextPage then .timelineItems.pageInfo.endCursor else null end)}}'

# github_carry_repositories <owner>: {kind: "repository", repo, archived, issues} for every repository of the organisation,
# issues being how many issues it holds, open and closed, and 0 where it has issues disabled: such a repository has nothing to
# carry, and needs no destination
github_carry_repositories() {
  carry_pages "the repositories of $1" .data.organization.repositories \
    'query($o:String!,$c:String){ organization(login:$o){ repositories(first:100, after:$c){ nodes{ nameWithOwner isArchived hasIssuesEnabled issues{ totalCount } } pageInfo{ hasNextPage endCursor } } } }' -f o="$1" \
    | jq -c '{kind: "repository", repo: .nameWithOwner, archived: .isArchived, issues: (if .hasIssuesEnabled then .issues.totalCount else 0 end)}'
}

# github_carry_issues <owner/repo> [number]: the issues of the repository (or the one), one row each:
#   {kind, repo, number, id, url, title, body, state, reason, labels: [name], comments: [{id, url, createdAt, body, author}],
#    parent: {id, repo, number, url} | null, memberships: [{item, board, archived, status, priority}],
#    timeline: [{kind: "closed" | "reopened", at}]}
# in the order they were opened, with every nested connection read to its end.
github_carry_issues() {
  local repo="$1" nodes row kind cursor extra what
  if [ -n "${2:-}" ]; then
    nodes="$(gh_read "the issue $repo#$2" api graphql -f o="${repo%%/*}" -f n="${repo#*/}" -F i="$2" -f query='query($o:String!,$n:String!,$i:Int!){ repository(owner:$o,name:$n){ issue(number:$i){ '"$CARRY_ISSUE"' } } }')" || exit 1
    nodes="$(jq -c 'if ((.errors // []) | length) > 0 or .data.repository.issue == null then error("no issue") else .data.repository.issue end' <<< "$nodes" 2>/dev/null)" \
      || die "cannot read the issue $repo#$2 - GitHub answered with errors or without it"
  else
    nodes="$(carry_pages "the issues of $repo" .data.repository.issues \
      'query($o:String!,$n:String!,$c:String){ repository(owner:$o,name:$n){ issues(first:50, after:$c, orderBy:{field:CREATED_AT, direction:ASC}){ nodes{ '"$CARRY_ISSUE"' } pageInfo{ hasNextPage endCursor } } } }' \
      -f o="${repo%%/*}" -f n="${repo#*/}")" || exit 1
  fi
  printf '%s\n' "$nodes" | jq -r --arg repo "$repo" "$CARRY_ISSUE_ROW"' | ([.more.labels, .more.comments, .more.memberships, .more.timeline] | map(. // "") | join(",")) + "\t" + (del(.more) | tojson)' | while IFS=$'\t' read -r more row; do
    if [ "$more" != ",,," ]; then
      for kind in labels comments memberships timeline; do
        cursor="$(printf '%s' "$more" | cut -d, -f"$(case "$kind" in labels) echo 1 ;; comments) echo 2 ;; memberships) echo 3 ;; *) echo 4 ;; esac)")"
        [ -n "$cursor" ] || continue
        what="of the issue $repo#$(jq -r .number <<< "$row")"
        case "$kind" in
          labels)      extra="$(carry_overflow "the labels $what" "$(jq -r .id <<< "$row")" Issue labels "" 'name' "$cursor" | jq -c '.name')" ;;
          comments)    extra="$(carry_overflow "the comments $what" "$(jq -r .id <<< "$row")" Issue comments "" "$CARRY_COMMENT" "$cursor" | jq -c '{id, url, createdAt, body, author: (.author.login // null)}')" ;;
          memberships) extra="$(carry_overflow "the board memberships $what" "$(jq -r .id <<< "$row")" Issue projectItems ", includeArchived: true" "$CARRY_MEMBERSHIP" "$cursor" | jq -c '{item: .id, board: .project.id, archived: .isArchived, status: '"$CARRY_STATUS"', priority: '"$CARRY_PRIORITY"'}')" ;;
          timeline)    extra="$(carry_overflow "the close and reopen events $what" "$(jq -r .id <<< "$row")" Issue timelineItems ", $CARRY_TIMELINE_TYPES" "$CARRY_TIMELINE" "$cursor" | jq -c "$CARRY_TIMELINE_EVENT")" ;;
        esac
        row="$(carry_append "$row" "$kind" "$extra")"
      done
    fi
    printf '%s\n' "$row"
  done
}

# github_carry_column_numbers <owner/repo> <column>: the numbers of the issues whose card stands in that column of the
# repository's board, one per line (the open ones are chosen by the caller, after it has read them)
github_carry_column_numbers() {
  local cards list
  set_project "" "$1" >/dev/null || exit 1
  cards="$(board_cards_of_repo "$1")" || exit 1
  list="$(printf '%s\n' "$cards" | awk -F'\t' -v c="$2" 'tolower($2) == tolower(c) { print $1 }')"
  [ -n "$list" ] || die "no card of $1 stands in the column '$2'"
  printf '%s\n' "$list"
}

# github_carry_boards <owner>: every board of the organisation, closed and empty ones too, one row each:
#   {kind: "board", id, number, title, url, closed, readme, repositories: [{repo, archived}],
#    items: [{item, issue, repo, number, archived, status, priority}]}
# items are the cards of the board, archived ones included (archivedStates asks for both); issue is null for a card
# that is a draft or another repository's pull request.
github_carry_boards() {
  local nodes row id n extra
  local item='id isArchived content{ ... on Issue{ id number repository{ nameWithOwner } } } '"$CARRY_FIELD_VALUES"
  local archived='archivedStates:[ARCHIVED, NOT_ARCHIVED]'
  local item_row='{item: .id, issue: .content.id, repo: .content.repository.nameWithOwner, number: .content.number, archived: .isArchived, status: '"$CARRY_STATUS"', priority: '"$CARRY_PRIORITY"'}'
  carry_pages "the boards of $1" .data.organization.projectsV2 \
    'query($o:String!,$c:String){ organization(login:$o){ projectsV2(first:20, after:$c){ nodes{ id number title url closed readme
        repositories(first:100){ nodes{ nameWithOwner isArchived } pageInfo{ hasNextPage endCursor } }
        items(first:100, '"$archived"'){ nodes{ '"$item"' } pageInfo{ hasNextPage endCursor } } }
      pageInfo{ hasNextPage endCursor } } } }' -f o="$1" \
    | jq -c '{kind: "board", id, number, title, url, closed, readme: (.readme // ""),
              repositories: [.repositories.nodes[] | {repo: .nameWithOwner, archived: .isArchived}],
              items: [.items.nodes[] | '"$item_row"'],
              more: {repositories: (if .repositories.pageInfo.hasNextPage then .repositories.pageInfo.endCursor else null end),
                     items: (if .items.pageInfo.hasNextPage then .items.pageInfo.endCursor else null end)}}' \
    | while IFS= read -r row; do
        id="$(jq -r .id <<< "$row")"; n="$(jq -r .number <<< "$row")"
        extra="$(jq -r '.more.repositories // empty' <<< "$row")"
        if [ -n "$extra" ]; then
          nodes="$(carry_overflow "the linked repositories of the board $n" "$id" ProjectV2 repositories "" 'nameWithOwner isArchived' "$extra" | jq -c '{repo: .nameWithOwner, archived: .isArchived}')"
          row="$(carry_append "$row" repositories "$nodes")"
        fi
        extra="$(jq -r '.more.items // empty' <<< "$row")"
        if [ -n "$extra" ]; then
          nodes="$(carry_overflow "the cards of the board $n" "$id" ProjectV2 items ", $archived" "$item" "$extra" | jq -c "$item_row")"
          row="$(carry_append "$row" items "$nodes")"
        fi
        jq -c 'del(.more)' <<< "$row"
      done
}

# card_rows: every card of the selected board that is an issue, one JSON object per line, the card row
# of lib/tracker.sh:
#   {repo, number, title, open, closedAt, status, priority, parent, subs}
# repo and parent are "owner/repo" and "owner/repo#number"; closedAt is an ISO 8601 time or null;
# status and priority are the names of the card's Status and Priority, or null; subs counts sub-issues.
card_rows() {
  local after="" out cards
  cards='(.data.node.items.nodes[] | tojson), (.data.node.items.pageInfo | select(.hasNextPage) | "after \(.endCursor)")'
  while :; do
    out="$(gh_read "the cards of board $(project_number)" api graphql -f pid="$(project_id)" ${after:+-f after="$after"} -f query='
      query($pid:ID!, $after:String) { node(id:$pid) { ... on ProjectV2 {
        items(first:100, after:$after) { pageInfo { hasNextPage endCursor } nodes {
          status: fieldValueByName(name:"Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } }
          priority: fieldValueByName(name:"Priority") { ... on ProjectV2ItemFieldSingleSelectValue { name } }
          content { ... on Issue { number title state closedAt repository { nameWithOwner }
            parent { number repository { nameWithOwner } } subIssuesSummary { total } } } } } } } }' --jq "$cards")" || exit 1
    grep '^{' <<< "$out" | jq -c 'select(.content.number != null) | .content as $c
      | { repo: $c.repository.nameWithOwner, number: $c.number, title: $c.title, open: ($c.state == "OPEN"),
          closedAt: $c.closedAt, status: .status.name, priority: .priority.name,
          parent: (if $c.parent then "\($c.parent.repository.nameWithOwner)#\($c.parent.number)" else null end),
          subs: ($c.subIssuesSummary.total // 0) }'
    after="$(sed -n 's/^after //p' <<< "$out")"
    [ -n "$after" ] || break
  done
}

# open_issue_page <owner/repo> [cursor]: one page of the open issues of the repository with their cards
# (board number, owner and Status), the time of the last reopening and the last LANDING_COMMENT_WINDOW
# comments, as the tracker answers it; status-sync reads it and pages with the cursor.
open_issue_page() {
  gh_read "the open issues of $1" api graphql -f o="${1%%/*}" -f n="${1#*/}" ${2:+-f after="$2"} -f query='
    query($o:String!, $n:String!, $k:Int!, $after:String) { repository(owner:$o, name:$n) {
      issues(states:OPEN, first:50, after:$after) { pageInfo { hasNextPage endCursor } nodes {
        number subIssuesSummary { total }
        projectItems(first:20) { nodes { project { number owner { ... on Organization { login } ... on User { login } } }
          status: fieldValueByName(name:"Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } } } }
        reopened: timelineItems(last:1, itemTypes:[REOPENED_EVENT]) { nodes { ... on ReopenedEvent { createdAt } } }
        comments(last:$k) { nodes { createdAt body authorAssociation } } } } } }' -F k="$LANDING_COMMENT_WINDOW"
}

# board_fields_json: the single-select fields of the selected board with their options, as the tracker
# answers it, for field-option-add to decide on.
board_fields_json() {
  gh_read "the fields of board $(project_number)" api graphql -f pid="$(project_id)" -f query='
    query($pid:ID!) { node(id:$pid) { ... on ProjectV2 {
      fields(first:50) { nodes { ... on ProjectV2SingleSelectField {
        id name options { id name color description } } } } } } }'
}

# field_options_replace <field> <request body file>: sends the request body that carries the field's
# whole new option list, and prints the option names that stand afterwards, one per line.
field_options_replace() {
  gh_read "the options of '$1' on board $(project_number)" api graphql --input "$2" \
    --jq '.data.updateProjectV2Field.projectV2Field.options[].name'
}

# project_create <organisation> <number of the board to copy> <title>: prints "<number>\t<url>" of the
# new board.
project_create() {
  local org src
  check_project_number "$2"
  org="$(gh_read "the id of $1" api graphql -f o="$1" -f query='
    query($o:String!){ organization(login:$o){ id } }' \
    --jq '.data.organization.id')" || exit 1
  src="$(gh_read "the id of project $2 in $1" api graphql -f o="$1" -F n="$2" -f query='
    query($o:String!,$n:Int!){ organization(login:$o){ projectV2(number:$n){ id } } }' \
    --jq '.data.organization.projectV2.id')" || exit 1
  [ -n "$src" ] || die "no project $2 in $1 to copy from"
  gh_read "the board copied from project $2" api graphql -f pid="$src" -f oid="$org" -f t="$3" -f query='
    mutation($pid:ID!,$oid:ID!,$t:String!){
      copyProjectV2(input:{projectId:$pid, ownerId:$oid, title:$t, includeDraftIssues:false}){
        projectV2 { number url } } }' \
    --jq '.data.copyProjectV2.projectV2 | "\(.number)\t\(.url)"'
}

# ONE ROW PER REPOSITORY, AND ONE MORE PER BOARD IT IS LINKED TO. Packing the boards into the
# repository's own row would mean filtering rows by their board title in the caller, and a repository
# whose only link is to the template board would then vanish from the report entirely - which is the
# one answer repo-boards exists to never give.
# repo_boards_rows <organisation>: every repository of the organisation, paged, as one
# "R\t<owner/repo>\t<archived true|false>" line and one "B\t<owner/repo>\t<number>\t<title>" line for
# each open board it is linked to.
repo_boards_rows() {
  local org="$1" after="" page
  while :; do
    if [ -n "$after" ]; then
      page="$(gh_read "the repositories of $org after $after" api graphql -f o="$org" -f after="$after" -f query='
        query($o:String!, $after:String) { organization(login:$o) {
          repositories(first:100, after:$after) { pageInfo { hasNextPage endCursor }
            nodes { nameWithOwner isArchived
              projectsV2(first:50) { nodes { number title closed } } } } } }')" || exit 1
    else
      page="$(gh_read "the repositories of $org" api graphql -f o="$org" -f query='
        query($o:String!) { organization(login:$o) {
          repositories(first:100) { pageInfo { hasNextPage endCursor }
            nodes { nameWithOwner isArchived
              projectsV2(first:50) { nodes { number title closed } } } } } }')" || exit 1
    fi
    printf '%s' "$page" | jq -r '.data.organization.repositories.nodes[] | . as $r
      | "R\t\($r.nameWithOwner)\t\($r.isArchived)",
        ($r.projectsV2.nodes[] | select(.closed == false)
         | "B\t\($r.nameWithOwner)\t\(.number)\t\(.title)")'
    [ "$(printf '%s' "$page" | jq -r '.data.organization.repositories.pageInfo.hasNextPage')" = 'true' ] || break
    after="$(printf '%s' "$page" | jq -r '.data.organization.repositories.pageInfo.endCursor')"
  done
}

# repo_link <owner/repo>: links the repository to the selected board and prints its name as the
# tracker answers it. What the mutation answered is printed as the confirmation, so it is established
# as an answer first: piped straight into sed, a refusal prints as `linked: {"data":null,...}`.
repo_link() {
  local rid
  rid="$(gh_read "the node id of $1" api "repos/$1" --jq '.node_id')" || exit 1
  gh_read "the link between $1 and board $(project_number)" api graphql \
    -f pid="$(project_id)" -f rid="$rid" -f query='
    mutation($pid:ID!, $rid:ID!) {
      linkProjectV2ToRepository(input:{projectId:$pid, repositoryId:$rid}) {
        repository { nameWithOwner } } }' \
    --jq '.data.linkProjectV2ToRepository.repository.nameWithOwner'
}

# board_views <board as the caller named it>: the views of the selected board, one "<name>\t<id>" per line.
board_views() {
  gh_read "the views of board $1" api graphql -f pid="$(project_id)" -f query='
    query($pid:ID!){ node(id:$pid){ ... on ProjectV2 { views(first:20){ nodes { id name filter } } } } }' \
    --jq '.data.node.views.nodes[] | "\(.name)\t\(.id)"'
}

# view_filter_set <view id> <filter>: prints "<view>: <filter>" as the tracker answers it, "shows
# everything" for an empty filter. What the mutation answered is the line this prints, so it is
# established as an answer first rather than written to the screen as the result of a filter that
# was never set.
view_filter_set() {
  gh_read "the filter set on view '$1'" api graphql -f vid="$1" -f f="$2" -f query='
    mutation($vid:ID!,$f:String!){ updateProjectV2View(input:{viewId:$vid, filter:$f}){ projectV2View { name filter } } }' \
    --jq '.data.updateProjectV2View.projectV2View | "\(.name): \(if .filter == "" then "shows everything" else .filter end)"'
}

# mutation_schema: GitHub's GraphQL interface, the Mutation type with its fields and their payloads,
# for schema-check. Exit 2 where gh is missing, the exit status of the read otherwise; gh writes its
# error body to STDOUT where the answer would be, so a caller judges by the status. stderr is not
# captured: the rate-limit wait of gh writes "waiting Ns ..." there, and it would stand in front of
# the JSON.
mutation_schema() {
  command -v gh >/dev/null 2>&1 || { echo "error: gh is not on PATH, and the schema is read through it" >&2; return 2; }
  gh api graphql -f query='{ __type(name:"Mutation") { fields { name type { name fields { name } } } } }'
}
