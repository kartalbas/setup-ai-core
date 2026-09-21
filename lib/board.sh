#!/usr/bin/env bash
# Shared helpers for every script in bin/. Source it, do not run it.
#
# The board is addressed by NAME throughout - "Status", "Todo", "P1". The ids
# behind those names are looked up from GitHub and cached; a name that no longer
# exists stops the script with the list of names that do, because writing a stale
# id succeeds silently and puts the card in the wrong column.
#
# Neither a project nor a repo is baked in. The repo comes from the caller or from
# the directory the caller stands in; the project is whichever project that repo is
# linked to. A repo linked to no project, or to more than one, stops the script
# rather than guessing - a guess here writes a card onto the wrong board.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { echo "error: $*" >&2; exit 1; }

# --- where the data lives -----------------------------------------------------

# THE DATA FILES ARE THE PROJECT'S, NOT THE HARNESS'S: labels.tsv, assignees.tsv, team-modes.tsv.
# A checkout carries them in .ai-core/, put there by init; the clone's templates hold the
# defaults a project starts from. Every reader asks here, so the two twins and every command
# read the same file: the one of the repository the caller stands in, or of the project folder.
data_dir() {
  local top
  top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$top" ] || top="$PWD"
  echo "$top/.ai-core"
}
data_file() {  # data_file <name>
  local f
  f="$(data_dir)/$1"
  if [ -f "$f" ]; then echo "$f"; else echo "$ROOT/templates/.ai-core/$1"; fi
}

# THE ORGANISATION, for a command that names no repository: GH_ORG in the environment, then
# GH_ORG= in the checkout's .ai-core/config.env (the project's setting, put there by init), then
# the owner of the repository the caller stands in. The harness itself names none: it serves many.
gh_org() {
  local line repo
  if [ -n "${GH_ORG:-}" ]; then echo "$GH_ORG"; return 0; fi
  # Resolved once per process: the answer is exported so no later call asks gh again
  if [ -f "$(data_dir)/config.env" ]; then
    line="$(grep -E '^[[:space:]]*GH_ORG[[:space:]]*=' "$(data_dir)/config.env" | tail -n1 || true)"
    line="${line#*=}"; line="${line%%#*}"; line=${line//[[:space:]\"\']/}
    if [ -n "$line" ]; then export GH_ORG="$line"; echo "$line"; return 0; fi
  fi
  repo="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)" \
    || die "no organisation: set GH_ORG in .ai-core/config.env or the environment, or run this inside a repository of it"
  export GH_ORG="${repo%%/*}"
  echo "$GH_ORG"
}

# A FLAG WITHOUT ITS VALUE, WHICH BASH DOES NOT NOTICE ON ITS OWN.
#
# Every parser in bin/ matches option names by hand, so nothing checks that the word after a
# flag is a value: `--project --dry-run` takes the next FLAG as the board number, and
# `--project` written last leaves the variable empty and lets `shift 2` end the run with exit 1
# and no word at all. Both read downstream as "no board was named", and a board that was not
# named is resolved from the current directory - which is a real board, so nothing afterwards
# can tell.
#
# THIS IS STRICTER THAN THE POWERSHELL TWIN, AND IT HAS TO BE. PowerShell's binder refuses the
# two cases above on its own, and it also accepts a QUOTED value that begins with a dash - the
# parser still knows which words were quoted when it decides what is a parameter name and what
# is an argument. Measured on pwsh 7.6.5:
#
#   board-list.ps1 -Project              ->  Missing an argument for parameter 'Project'.
#   board-list.ps1 -Project -Status Todo ->  Missing an argument for parameter 'Project'.
#   issue-new.ps1  -Title '-x marks the spot'  ->  bound, Title=[-x marks the spot]
#
# Bash has no such knowledge: quoting is gone by the time "$2" is read, so `--title -x` and
# `--title '-x marks the spot'` are the same two words here and no rule can tell them apart.
# Of the two ways to be wrong, this one refuses, because the other one is the defect above -
# a board number that is really the next flag, silently resolved from the current directory.
#
# WHAT IT COSTS, stated rather than hidden: a VALUE beginning with a dash cannot be passed to
# any bin/*.sh script - an issue title, a label, a view name. Nothing the scripts themselves
# take is lost, because every flag in bin/ is a long `--flag`. The twins therefore answer
# differently for exactly that input, and the bash side is the one that refuses.
need_value() {  # need_value <flag> <the argument after it>
  case "${2-}" in
    '' | -*) die "$1 needs a value" ;;
  esac
}

# AN ARGUMENT BEGINNING WITH A DASH IS EITHER A FLAG THE SCRIPT TOOK, OR AN ERROR.
#
# A parser that files everything it did not match under positional arguments turns a misspelt
# `--project` into a status name, a repo, an issue number, a label or a board title, and the
# flag's value into the argument after it. The run then does something real with both: the
# board comes from the current directory and the card lands on it.
#
# For scripts that take no flags at all, this is the whole check.
reject_options() {  # reject_options "$@"
  local a
  for a in "$@"; do
    case "$a" in -*) die "unknown argument '$a'" ;; esac
  done
}

# EVERYTHING THIS REPOSITORY ASKS gh GOES THROUGH HERE.
#
# A refused query is not an empty result. When the server refuses, gh writes the whole error body
# to STDOUT - where the rows would be - puts a one-line complaint on stderr, and exits non-zero. It
# does that even when --jq was given, because the jq program never runs at all. So a caller that
# reads stdout and counts lines reads the complaint as data: a board with one row that is not a
# card, a repo linked to no project, an archived card that is not there.
#
# The exit status is the one signal that tells an answer from a refusal, and it is the same signal
# whatever shape the rows have - so it is checked HERE, once, and the output is handed on only when
# gh said it answered. What gh wrote to STDERR is left where it is: that is the sentence naming
# which query was refused, and a redirect silencing it leaves nothing on the screen but a run that
# stopped.
#
# A caller that must stop rather than continue with nothing writes `x="$(gh_read ...)" || exit 1`.
# `die` inside `$( )` exits the substitution and nothing else, which is the same trap set_select
# names below.
#
# WHAT THIS CANNOT SAY is whether the answer is the one that was asked for: a query gh accepts
# answers `{}` with exit 0 when the id it was given belongs to something else. That is a question
# about the VALUE, and it is asked where the value is used - see project_id.
gh_read() {  # gh_read <what was asked for> <gh argument>...
  local what="$1"; shift
  local out rc=0
  out="$(gh "$@")" || rc=$?
  [ "$rc" -eq 0 ] || die "cannot read $what - gh exited $rc${out:+, and answered: $out}"
  [ -n "$out" ] || return 0
  printf '%s\n' "$out"
}

# --- the label taxonomy -------------------------------------------------------

# The groups a row may stand in. The group is also the PREFIX the label carries, so
# a row in group `area` is named `area:something` - the two cannot be told apart and
# so cannot disagree.
LABEL_GROUPS='type area closes incident'

# EVERY READER OF labels.tsv COMES THROUGH HERE, and the file is held against its
# shape before a single name leaves this function.
#
# The file is read by labels-sync to create the labels, by board-sync to decide which
# ticket is missing one, and by issue-label to refuse a name outside the taxonomy.
# Three readers parsing it three ways, none of them looking at what it found, is what
# this closes: a row whose group is misspelt is simply not seen by board-sync's group
# filter, so every ticket in the organisation is reported as missing a label that is
# on it, and the run stays green because finding nothing is what green looks like.
# A row named `area:gate` filed under group `type` is the same defect one step worse -
# it is counted as the family it is not.
#
# So a row that cannot be read the way board-sync reads it stops the run and names the
# line. `die` inside `$( )` exits the substitution and nothing else, so a caller writes
# `x="$(labels_tsv)" || exit 1`.
#
# THE FILE IS AN ARGUMENT, defaulting to the repository's own. A reader that could only
# ever read one path would force the test to plant its shapes into the tracked file and put
# it back afterwards - so the two twins could not run at the same time without each reading
# the other's plant, and a killed run would leave the taxonomy damaged in the working tree.
#
# Prints: <group>\t<name>\t<colour>\t<description>
labels_tsv() {  # labels_tsv [file]
  local file="${1:-$(data_file labels.tsv)}" line no=0 group name color desc extra seen=""
  [ -f "$file" ] || die "missing label taxonomy: $file"

  while IFS= read -r line || [ -n "$line" ]; do
    no=$((no + 1))
    case "$line" in ''|'#'*) continue ;; esac
    IFS=$'\t' read -r group name color desc extra <<< "$line"

    case " $LABEL_GROUPS " in
      *" $group "*) ;;
      *) die "$file:$no is in group '$group', and there is only $LABEL_GROUPS" ;;
    esac
    case "$name" in
      "$group:"?*) ;;
      *) die "$file:$no is in group '$group' but is named '$name' - a row's name carries its own group as its prefix" ;;
    esac
    case "$color" in
      [0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]) ;;
      *) die "$file:$no has '$color' where a six-digit hex colour belongs" ;;
    esac
    [ -n "$desc" ] || die "$file:$no has no description, and every label on the board carries one"
    [ -z "${extra:-}" ] || die "$file:$no has more than four columns: $line"

    case " $seen " in
      *" $name "*) die "$file:$no declares '$name' a second time" ;;
    esac
    seen="$seen $name"

    printf '%s\t%s\t%s\t%s\n' "$group" "$name" "$color" "$desc"
  done < "$file"
}

# The names of one group, in the order the file declares them.
label_names_in_group() {  # label_names_in_group <group> [file]
  local all
  all="$(labels_tsv "${2:-}")" || exit 1
  printf '%s\n' "$all" | awk -F'\t' -v g="$1" '$1==g {print $2}'
}

# --- repositories -------------------------------------------------------------

# Which repo to act on. A colleague standing in their own checkout does not have to
# type it; anyone driving another repo from elsewhere passes it explicitly.
#
# The ONE gh call that does not go through gh_read, and it still checks the same signal. What it
# would gain there is gh's answer in the message, and there is none to gain: this call answers with
# a name or with nothing. What a person needs here is what to type instead, so that is what it
# says, and gh's own line on stderr says whether standing outside a checkout was the reason.
default_repo() {
  gh repo view --json nameWithOwner --jq '.nameWithOwner' \
    || die "not inside a GitHub repo - pass the repo as OWNER/REPO"
}

# An argument that carries a slash is a repo; anything else is an issue number and
# the repo comes from the current directory.
resolve_repo() { case "${1:-}" in */*) echo "$1" ;; *) default_repo ;; esac; }

# Who a new issue in this repo belongs to.
#
# An issue lands on whoever OWNS the repository, not on whoever typed the command,
# and the mapping is a file both shells read so the two cannot drift. A repo nobody
# listed falls back to @me — a new repo should assign to the person setting it up
# rather than refuse, and adding a line is how that stops.
#
# It is called AFTER the repo is known. Resolving a default before that is what
# produced the wrong assignee in the first place.
#
# THE FILE IS AN ARGUMENT, defaulting to the repository's own, for the reason written above
# labels_tsv: a reader that could only ever read one path would force the test to plant into the
# tracked file and put it back afterwards, so two suites running at once would each restore what
# the other planted and the tracked map would hold a test's plant.
#
# A COLUMN IS THE BYTES BETWEEN THE TABS, and the file's own header says so. A row carries
# exactly one tab and neither column may begin or end with a space, so `example-org/x <TAB>one`
# is refused by name rather than answered. Trimming it here instead would have this reader
# repair a file, and dropping the row silently would hand the issue to @me with nobody told;
# one invisible space would answer `one` on the PowerShell side and `@me` here. `IFS=$'	' read`
# is not used for the split, because a tab is IFS whitespace: it collapses a run of tabs and
# strips a leading one, so `x<TAB><TAB>one` would reach this as a valid two-column row while
# the PowerShell reader saw three columns and refused.
assignee_for() {  # assignee_for <repo> [file]
  local repo="$1" file="${2:-$(data_file assignees.tsv)}" found="" line no=0 r l tab
  tab=$'\t'
  [ -f "$file" ] || die "missing assignee map: $file"

  while IFS= read -r line || [ -n "$line" ]; do
    no=$((no + 1))
    case "$line" in ''|'#'*) continue ;; esac
    # Exactly two tab-separated columns. A third means somebody wrote something the
    # next reader would take for data.
    case "$line" in
      *"$tab"*"$tab"*) die "$file:$no is not 'repo<TAB>login': $line" ;;
      *"$tab"*) ;;
      *) die "$file:$no is not 'repo<TAB>login': $line" ;;
    esac
    r="${line%%"$tab"*}"
    l="${line#*"$tab"}"
    [ -n "$r" ] && [ -n "$l" ] || die "$file:$no is not 'repo<TAB>login': $line"
    case "$r$tab$l" in
      ' '*|*' '|*" $tab"*|*"$tab "*)
        die "$file:$no has a space at the edge of a column, and the format allows none: '$r' '$l'" ;;
    esac
    if [ "$r" = "$repo" ]; then
      [ -z "$found" ] || die "$file lists $repo twice - which one is right is not for a script to guess"
      found="$l"
    fi
  done < "$file"

  echo "${found:-@me}"
}

# --- the project --------------------------------------------------------------

# Set once per process by every bin script, so the whole run acts on one board.
PROJECT=""
PROJECT_ORG=""

# set_project [board] [repo]
#
# A BOARD IS WRITTEN N OR ORG/N. A bare number is a board of the organisation the named
# repository belongs to, or of GH_ORG when the command names no repository; ORG/N names the
# organisation outright, which is what a card moving from one organisation's board to
# another's needs. Two organisations keep boards here - example-org and other-org - and a
# number alone says nothing about which; resolving every number under GH_ORG put the
# customer's cards on the wrong board (example-tools#25).
#
# Resolution order: what the caller asked for, then the environment, then the
# single project the repo is linked to. Nothing is defaulted beyond that.
#
# EVERY BOARD NUMBER ARRIVES HERE, from a --project flag, from GH_PROJECT_NUMBER or from the
# repo's own link, so this is where one is judged and there is no second copy of the rule in
# the commands that pass one in. A number is digits and nothing else: `--project 12.6`
# used to travel into `-F num=12.6` against an `Int!` variable and stop later with a complaint
# about a project id, which names neither the flag nor what was typed.
set_project() {
  local n="${1:-}" repo="${2:-}" org=""
  [ -n "$n" ] || n="${GH_PROJECT_NUMBER:-}"
  case "$n" in
    */*) org="${n%%/*}"; n="${n#*/}"
         [ -n "$org" ] && [ -n "$n" ] || die "a board is written N or ORG/N, not '${1:-$GH_PROJECT_NUMBER}'" ;;
  esac
  if [ -z "$n" ]; then
    [ -n "$repo" ] || repo="$(default_repo)" || exit 1
    n="$(resolve_project_for_repo "$repo")" || exit 1
  fi
  case "$n" in ''|*[!0-9]*) die "the board number must be numeric, not '$n'" ;; esac
  if [ -z "$org" ]; then
    if [ -n "$repo" ]; then org="${repo%%/*}"; else org="$(gh_org)" || exit 1; fi
  fi
  PROJECT="$n"
  PROJECT_ORG="$org"
  echo "$PROJECT"
}

project_number() {
  [ -n "$PROJECT" ] || die "no project selected - call set_project first"
  echo "$PROJECT"
}

# The organisation the selected board lives under - see set_project for how it is chosen.
project_org() {
  [ -n "$PROJECT_ORG" ] || die "no project selected - call set_project first"
  echo "$PROJECT_ORG"
}

# A board whose title starts with this is a shape to copy, never a board work is
# tracked on. It stays unlinked from every repo, and is skipped below in case
# somebody links it.
TEMPLATE_MARK='[TEMPLATE]'

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

  [ -s "$f" ] || { mkdir -p "$(cache_dir)"; printf '%s\n' "$id" > "$f"; }
  printf '%s\n' "$id"
}

# One cache directory per board. Sharing one would hand a board the other's field
# and option ids, and the API accepts a foreign id without complaining.
#
# WHERE THE CACHE STANDS IS AN ENVIRONMENT VARIABLE, defaulting to the checkout's own
# .cache. A test runs a command that caches, so a cache fixed under the checkout is a
# directory two runs of the same command share, and the loser reads a board id that is
# not its own. Every test points this at its own temporary directory, which is why no
# test writes inside the tree it is testing.
cache_root() { echo "${GH_CACHE_DIRECTORY:-$(data_dir)/.cache}"; }
# A board of the organisation (gh_org) caches under its number; a board of another organisation
# under that organisation's name and its number, so board 1 of one never answers for board 1 of
# the other.
cache_dir() {
  if [ "$(project_org)" = "$(gh_org)" ]; then echo "$(cache_root)/$(project_number)"
  else echo "$(cache_root)/$(project_org)/$(project_number)"; fi
}

# Every single-select field with all of its options, one per line:
#   <field name>\t<field id>\t<option name>\t<option id>
fields_tsv() {
  local f rows row
  f="$(cache_dir)/fields.tsv"
  [ -s "$f" ] || {
    # Read whole, then written. Redirecting gh straight into the cache stores whatever it wrote
    # under the name of an answer, and every later run finds a non-empty file and never asks again.
    rows="$(gh_read "the fields of board $(project_number)" api graphql -f pid="$(project_id)" -f query='
      query($pid:ID!) { node(id:$pid) { ... on ProjectV2 {
        fields(first:50) { nodes { ... on ProjectV2SingleSelectField {
          id name options { id name } } } } } } }' \
      --jq '.data.node.fields.nodes[] | select(.name != null) | .name as $n | .id as $f
            | .options[] | "\($n)\t\($f)\t\(.name)\t\(.id)"')" || return 1
    mkdir -p "$(cache_dir)"
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

field_id() {  # field_id <field name>
  local want="$1" all id
  all="$(fields_tsv)" || exit 1
  id="$(printf '%s\n' "$all" | awk -F'\t' -v n="$want" '$1==n {print $2; exit}')"
  [ -n "$id" ] || die "no single-select field named '$want' on the board. There is: $(printf '%s\n' "$all" | cut -f1 | sort -u | paste -sd' ' -)"
  echo "$id"
}

# THE OPTION NAME IS MATCHED WITHOUT CASE, and the board's own spelling is the one that counts.
#
# A board names its options however whoever made it typed them — `todo` on this one, `Todo` on the
# next — and nobody typing a command remembers which. Refusing `Todo` because the board says `todo`
# teaches a person nothing about their board and everything about this script. It is also how
# issue-new came to carry a default status that could never resolve on this board at all.
#
# WHAT IS NOT RELAXED is whether the option exists. A name matching nothing still dies, naming every
# option there is, because an option guessed at is a card in the wrong column and nobody told.
option_id() {  # option_id <field name> <option name>
  local fld="$1" want="$2" all id
  all="$(fields_tsv)" || exit 1
  id="$(printf '%s\n' "$all" | awk -F'\t' -v f="$fld" -v n="$want" 'tolower($1)==tolower(f) && tolower($3)==tolower(n) {print $4; exit}')"
  [ -n "$id" ] || die "field '$fld' has no option '$want'. It has: $(printf '%s\n' "$all" | awk -F'\t' -v f="$fld" 'tolower($1)==tolower(f) {print $3}' | paste -sd' ' -)"
  echo "$id"
}

# Clears every board's cache, not just the selected one - it is not called by any
# script and exists for the same reason README says to delete .cache/ by hand.
cache_clear() { rm -rf "$(cache_root)"; }

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

# --- issues -------------------------------------------------------------------

# HOW THE FIRST LINE OF EVERY ISSUE BODY OPENS. `issue-new` builds that line out of arguments it
# requires, and `issue-edit` recognizes it to keep it on a body that does not carry it. The two
# are the writer and the reader of one sentence, so the opening stands here once: a prefix
# changed in the writer alone would leave the reader keeping nothing and reporting nothing.
ASKED_PREFIX='Asked for by @'

# WHAT IS WRONG WITH A TITLE. Every check here REPORTS on stderr, and the call still goes
# through. Whether a title reads well is a judgment, and a script cannot make it; a refusal
# here would stop a real ticket over wording the writer may have chosen on purpose.
#
# THE LENGTH IS COUNTED IN CHARACTERS, and not by `wc -m`, which counts bytes wherever the
# locale is not a UTF-8 one and has no portable UTF-8 locale name across Linux and macOS.
# Every continuation byte of a UTF-8 sequence lies between 0x80 and 0xBF, so deleting those
# and counting what is left counts code points, in any locale. Without it an em dash counts
# as three and a title of exactly seventy is reported as too long by this half of the pair
# and by nothing else.
#
# THE THIRD REPORT IS ABOUT THE STAKE. A title carries an action and what it costs, joined
# with ", so ", ", or " or a colon (rules.md, the issue rules). The shape reported here is
# narrow on purpose: it opens with one of six verbs that name an artifact and carries none of
# the three joins, which is the exact shape of "Add the board-sync command" - a title that
# fits twenty other tickets. A title outside that shape is not judged at all.
report_title() {  # report_title <title>
  local title="$1" n
  n="$(printf '%s' "$title" | LC_ALL=C tr -d '\200-\277' | wc -c | tr -d ' ')"
  [ "$n" -le 70 ] \
    || echo "title is $n characters, over 70 - a title is one sentence a stranger understands; the reason and the code go into the body" >&2
  case "$title" in
    *'`'*) echo "title contains a backtick - no code name in a title" >&2 ;;
  esac
  case "$title" in
    Add\ *|Create\ *|Write\ *|Implement\ *|Introduce\ *|Define\ *)
      case "$title" in
        *", so "*|*", or "*|*:*) ;;
        *) echo "title names an action and no stake - write what is wrong today or what it costs, joined with \", so \", \", or \" or a colon" >&2 ;;
      esac ;;
  esac
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
# board - which is exactly the card a command like issue-close has to reach (example-tools#26).
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

# One single-select write, applied to EVERY board the issue is on, printing one line per board -
# a partial result must not read as a complete one. Each iteration selects its board first, so
# the per-board caches stay coherent.
#
# An issue on no card has TWO causes which must not be treated alike. A repository with a board
# and an issue that never got a card: add it. A repository on no board at all: there is nothing
# to add and nothing to set, and the issue tooling's own repository is deliberately one of those.
# Reading both as "card missing" made every close, reopen, status and priority on such an issue
# die after the issue itself had already been changed.
for_each_board() {  # for_each_board <owner/repo> <number> <field> <option> <printed>
  local repo="$1" n="$2" field="$3" option="$4" printed="$5" rows here item bnum bitem
  rows="$(issue_board_items "$repo" "$n")" || exit 1
  if [ -z "$rows" ]; then
    here="$(repo_open_projects "$repo")" || exit 1
    if [ -z "$here" ]; then
      echo "#$n -> $printed (issue only; $repo is on no board)"
      return 0
    fi
    set_project "" "$repo" >/dev/null
    item="$(item_id "$repo" "$n")" || exit 1
    set_select "$item" "$field" "$option"
    echo "#$n -> $printed (board $(project_org)/$(project_number), card added)"
    return 0
  fi
  while IFS=$'\t' read -r bnum bitem; do
    [ -n "$bnum" ] || continue
    set_project "$bnum" >/dev/null
    set_select "$bitem" "$field" "$option"
    echo "#$n -> $printed (board $bnum)"
  done <<< "$rows"
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
    # The carriage return is stripped HERE and not by each caller. This is the one place the jq
    # BINARY is run rather than gh's own --jq, and on Windows that binary writes CRLF - so an
    # unstripped number arrives as `19\r`, matches no issue, and is reported as "not on the
    # board" — a wrong answer that reads like a real one.
    printf '%s' "$page" | jq -r '.data.node.items.nodes[]
      | select(.content.number != null)
      | "\(.id)\t\(.content.repository.nameWithOwner)\t\(.content.number)"' | tr -d '\r'
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
