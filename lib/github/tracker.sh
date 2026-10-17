#!/usr/bin/env bash
# The tracker of this harness on GitHub: issues, sub-issues, labels and the Projects v2 board, asked
# with gh. lib/tracker.sh sources it when TRACKER is github, which is the default. The functions
# stand under the names lib/board.sh and every command in bin/ call; a second tracker implements
# the same names in lib/<provider>/tracker.sh. Source it, do not run it.

. "$(dirname "${BASH_SOURCE[0]}")/gh.sh"

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
# dropped makes the thread look settled when it is not.
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
  printf '%s\n%s\n' "$issue" "$comments" | jq -s '.[0] as $issue | .[1] as $comments | {
    number:   $issue.number,
    title:    $issue.title,
    state:    $issue.state,
    labels:   [$issue.labels[].name],
    body:     ($issue.body // ""),
    comments: [$comments[] | { author: .user.login, created_at: .created_at, body: (.body // "") }]
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

# epic_target_on_board <owner/repo> <number> - the epic_target of an issue, read from its own card
# and its sub-issues' cards on the selected board, or on whichever board they are on when none is
# selected; an issue without sub-issues gets nothing. A sub-issue with no card on the selected board,
# often one of another repository on that repository's board, counts where its first card with a
# status stands, and at most as testing: an open issue is done for its epic only where the epic's
# own board says so, or the epic would close with that issue still open.
epic_target_on_board() {
  local repo="$1" n="$2" on="" rows cur="" first=1 st
  [ -z "${PROJECT:-}" ] || on="select(.project.number == $(project_number) and .project.owner.login == \"$(project_org)\") |"
  rows="$(gh_read "the sub-issues of $repo#$n" api graphql -f o="${repo%%/*}" -f r="${repo#*/}" -F n="$n" -f query='
    query($o:String!, $r:String!, $n:Int!) { repository(owner:$o, name:$r) { issue(number:$n) {
      state stateReason projectItems(first:20) { nodes { project { number owner { ... on Organization { login } ... on User { login } } }
        status: fieldValueByName(name:"Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } } } }
      subIssues(first:100) { nodes { state stateReason projectItems(first:20) { nodes {
        project { number owner { ... on Organization { login } ... on User { login } } }
        status: fieldValueByName(name:"Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } } } } } } } } }' \
    --jq "def card: [.projectItems.nodes[] | $on (.status.name // \"backlog\")] | first;
          def anycard: [.projectItems.nodes[] | .status.name | select(. != null)] | first
            | if . != null and ascii_downcase == \"done\" then \"testing\" else . end;
          def status(c): if .state == \"CLOSED\" then (if .stateReason == \"NOT_PLANNED\" or .stateReason == \"DUPLICATE\" then \"not planned\" else \"done\" end) else (c // \"backlog\") end;
          .data.repository.issue | status(card), (.subIssues.nodes[] | status(card // anycard))")" || return 1
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
