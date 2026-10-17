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

# The tracker the project names (TRACKER in its config.env) brings in the functions that ask the
# issue tracker, gh_org and project_id among them, and common.sh: die, data_dir, data_file, apart.
. "$ROOT/lib/tracker.sh"

# THE DEFAULT BRANCH OF ORIGIN: asked of the remote, else origin/HEAD where it resolves. A clone's
# origin/HEAD is a copy that goes stale: it keeps the old branch after the default is renamed, or a
# branch somebody pointed it at, and trusting it sends every comparison to the wrong branch. Asking
# never prompts for credentials: a caller run from a terminal would wait on it without a word.
origin_default_branch() {
  local ref
  ref="$(GIT_TERMINAL_PROMPT=0 git ls-remote --symref origin HEAD 2>/dev/null | awk '$1 == "ref:" && $3 == "HEAD" { sub("^refs/heads/", "", $2); print $2 }')"
  if [ -z "$ref" ] && git rev-parse -q --verify refs/remotes/origin/HEAD >/dev/null 2>&1; then
    ref="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null)" && ref="${ref#refs/remotes/origin/}"
  fi
  [ -n "$ref" ] || die "cannot read the default branch from origin or from origin/HEAD - run 'git remote set-head origin -a', then run this again"
  echo "$ref"
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
# Quoting is gone by the time "$2" is read, so `--title -x` and `--title '-x marks the spot'`
# are the same two words here and no rule can tell them apart. Of the two ways to be wrong, this
# one refuses, because the other one is the defect above - a board number that is really the
# next flag, silently resolved from the current directory.
#
# WHAT IT COSTS, stated rather than hidden: a VALUE beginning with a dash cannot be passed to
# any bin/*.sh script - an issue title, a label, a view name. Nothing the scripts themselves
# take is lost, because every flag in bin/ is a long `--flag`.
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

# --- the label taxonomy -------------------------------------------------------

# The groups a row may stand in. The group is also the PREFIX the label carries, so
# a row in group `area` is named `area:something` - the two cannot be told apart and
# so cannot disagree.
LABEL_GROUPS='type area closes incident needs goal'

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
# it back afterwards - so two tests could not run at the same time without each reading
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

# An argument that carries a slash is a repo; anything else is an issue number and
# the repo comes from the current directory.
resolve_repo() { case "${1:-}" in */*) echo "$1" ;; *) default_repo ;; esac; }

# The repository the issue of an issue branch lives in, where that is not the checkout's own. An
# issue's work can have to land in a second repository; start-issue then records the issue's
# repository on the branch, and every command that reads the issue of a worktree reads it there,
# because the number alone names an unrelated issue, or none, in the checkout's own repository.
# Empty for a branch whose issue lives in its own repository.
branch_issue_repo() { [ -n "${1:-}" ] && git config --get "branch.$1.issueRepository" 2>/dev/null || true; }

# How a commit names issue <number> of <repo>: '#<number>' in the issue's own repository, and
# '<repo>#<number>' from another one, where '#<number>' links to an unrelated issue. GitHub reads
# a repository name in any case, so the comparison does too.
issue_ref() {  # issue_ref <repo or empty> <number>
  local lower='tr A-Z a-z'
  if [ -n "$1" ] && [ "$(printf '%s' "$1" | $lower)" != "$(default_repo 2>/dev/null | $lower)" ]; then echo "$1#$2"; else echo "#$2"; fi
}

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
# one invisible space would answer `one` or `@me` by chance. `IFS=$'	' read`
# is not used for the split, because a tab is IFS whitespace: it collapses a run of tabs and
# strips a leading one, so `x<TAB><TAB>one` would reach this as a valid two-column row.
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
  check_project_number "$n"
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
# Where the caller's organisation is not known, outside a checkout and without GH_ORG, the board's
# own organisation stands in for it: the command named it with its repository, and asking gh_org
# only printed an error and cached the board somewhere a checkout of that organisation does not.
cache_dir() {
  local caller
  caller="$(gh_org 2>/dev/null)" || caller="$(project_org)"
  if [ "$(project_org)" = "$caller" ]; then echo "$(cache_root)/$(project_number)"
  else echo "$(cache_root)/$(project_org)/$(project_number)"; fi
}

# make_cache_dir: the board's cache directory, made where git does not see it. A checkout init
# deployed names .ai-core/ in its exclude file; a harness clone gets no init, so without a line of
# its own the cache stands in its tree as an untracked change, and a gate that compares the tree
# with the commit refuses the next push from it.
make_cache_dir() {
  local dir root top exclude
  dir="$(cache_dir)"; root="$(cache_root)"
  mkdir -p "$dir" || return 1
  top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || return 0
  git -C "$top" check-ignore -q "$root" 2>/dev/null && return 0
  case "$root" in "$top"/*) ;; *) return 0 ;; esac
  exclude="$(git -C "$top" rev-parse --path-format=absolute --git-path info/exclude)" || return 0
  mkdir -p "$(dirname "$exclude")" || return 0
  # a last line without its newline would take this one onto itself and break both patterns
  [ ! -s "$exclude" ] || [ -z "$(tail -c1 "$exclude")" ] || echo >> "$exclude"
  printf '/%s/\n' "${root#"$top"/}" >> "$exclude"
}

# A field or option the cache does not know may have come to the board after the cache was written:
# the board is read once more before the name is refused.
fields_fresh() { rm -f "$(cache_dir)/fields.tsv" || return 1; fields_tsv; }

field_id() {  # field_id <field name>
  local want="$1" all id
  all="$(fields_tsv)" || exit 1
  id="$(printf '%s\n' "$all" | awk -F'\t' -v n="$want" '$1==n {print $2; exit}')"
  if [ -z "$id" ]; then
    all="$(fields_fresh)" || exit 1
    id="$(printf '%s\n' "$all" | awk -F'\t' -v n="$want" '$1==n {print $2; exit}')"
  fi
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
  if [ -z "$id" ]; then
    all="$(fields_fresh)" || exit 1
    id="$(printf '%s\n' "$all" | awk -F'\t' -v f="$fld" -v n="$want" 'tolower($1)==tolower(f) && tolower($3)==tolower(n) {print $4; exit}')"
  fi
  [ -n "$id" ] || die "field '$fld' has no option '$want'. It has: $(printf '%s\n' "$all" | awk -F'\t' -v f="$fld" 'tolower($1)==tolower(f) {print $3}' | paste -sd' ' -)"
  echo "$id"
}

# Clears every board's cache, not just the selected one - it is not called by any
# script and exists for the same reason README says to delete .cache/ by hand.
cache_clear() { rm -rf "$(cache_root)"; }

# A repository ON NO BOARD: no board is named, by --project or GH_PROJECT_NUMBER, and the
# repository is linked to no open one, as a harness or the tooling's own repository is. Its
# issues have no card, so a status, a priority or a testing column has nowhere to go.
on_no_board() {  # on_no_board <owner/repo> [named board] - true when the repository is on no board
  local named="${2:-${GH_PROJECT_NUMBER:-}}" linked
  [ -z "$named" ] || return 1
  linked="$(repo_open_projects "$1")" || exit 1
  [ -z "$linked" ]
}

# THE CARDS OF THE REPOSITORIES THAT A RELEASE HAS CARRIED AND A PROOF COVERS, closed as an issue
# starts or finishes: status-sync for the checkout's repository and the issue's, where that is
# another one, each in a run of its own that reads its issues in one query and its release from its
# clone, so a proven card in testing whose landed commit the newest release tag carries does not
# wait for a person. A run of its own, because each one is swept on its own board where none is
# named. A repository on no board has no card. A run goes in a subshell because the board readers
# exit on a failure; a failure is said and stops nothing.
sync_released_cards() {  # sync_released_cards <owner/repo>...
  local out r k named=()
  for r in "$@"; do
    for k in ${named[@]+"${named[@]}"}; do [ "$(printf '%s' "$k" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$r" | tr '[:upper:]' '[:lower:]')" ] || continue 2; done
    named+=("$r")
  done
  for r in ${named[@]+"${named[@]}"}; do
    out="$( (on_no_board "$r" && exit 0
             bash "$(dirname "${BASH_SOURCE[0]}")/../bin/status-sync.sh" "$r") 2>&1)" \
      || { echo "status-sync did NOT run for $r: $out" >&2; continue; }
    grep '^close ' <<< "$out" || true
  done
}

# --- issues -------------------------------------------------------------------

# HOW THE FIRST LINE OF EVERY ISSUE BODY OPENS. `issue-new` builds that line out of arguments it
# requires, and `issue-edit` recognizes it to keep it on a body that does not carry it. The two
# are the writer and the reader of one sentence, so the opening stands here once: a prefix
# changed in the writer alone would leave the reader keeping nothing and reporting nothing.
ASKED_PREFIX='Asked for by @'
# A defect a session found in its own work names where it was found instead: writing it down is
# tracking, not new work, so it waits for nobody's yes. Its line also ends the way issue-new
# writes it, because a body of prose may well open with "Found in".
FOUND_PREFIX='Found in '
FOUND_TAIL=', a defect filed without a yes.'
# is_origin_line LINE: whether LINE is the first line issue-new writes, asked for or found in
is_origin_line() { case "$1" in "$ASKED_PREFIX"*|"$FOUND_PREFIX"*"$FOUND_TAIL") return 0 ;; esac; return 1; }

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

# One single-select write, applied to EVERY board the issue is on, printing one line per board -
# a partial result must not read as a complete one. Each iteration selects its board first, so
# the per-board caches stay coherent.
#
# An issue on no card has TWO causes which must not be treated alike. A repository with a board
# and an issue that never got a card: add it. A repository on no board at all: there is nothing
# to add and nothing to set, and the issue tooling's own repository is deliberately one of those.
# Reading both as "card missing" made every close, reopen, status and priority on such an issue
# die after the issue itself had already been changed.
# option_on_every_board <owner/repo> <number> <field> <option>: dies where a board the issue is on,
# or the repository's board where it has no card yet, lacks the option; nothing is written. Called
# before an issue is changed, so a board of an older layout refuses before the issue stands
# half-made. The walk is for_each_board's, without the write.
option_on_every_board() {
  local repo="$1" n="$2" field="$3" option="$4" rows here bnum bitem
  rows="$(issue_board_items "$repo" "$n")" || exit 1
  if [ -z "$rows" ]; then
    here="$(repo_open_projects "$repo")" || exit 1
    [ -n "$here" ] || return 0
    set_project "" "$repo" >/dev/null
    option_id "$field" "$option" >/dev/null
    return 0
  fi
  while IFS=$'\t' read -r bnum bitem; do
    [ -n "$bnum" ] || continue
    set_project "$bnum" >/dev/null
    option_id "$field" "$option" >/dev/null
  done <<< "$rows"
}

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

# THE PROJECT FOLDER: the folder that holds the clone this runs in, its main checkout also from
# one of its worktrees, or the current directory outside a repository.
project_folder() {
  local common
  if common="$(git rev-parse --git-common-dir 2>/dev/null)"; then
    dirname "$(cd "$common/.." && git rev-parse --show-toplevel)"
  else pwd; fi
}

# THE WORKTREE CONTAINER: where the worktrees of this clone stand, <project folder>/.worktrees/<repository
# folder>, beside the main checkout and never inside it. The main checkout is found through
# --git-common-dir, so this answers the same from inside another worktree. start-issue cuts the worktree of
# an issue here and integrate-issue --from-origin its temporary one, so a project test that walks up to a
# sibling checkout finds the same neighbours in both.
worktree_container() {
  local common main
  common="$(git rev-parse --git-common-dir)" || return 1
  main="$(cd "$common/.." && git rev-parse --show-toplevel)" || return 1
  printf '%s/.worktrees/%s\n' "$(dirname "$main")" "${main##*/}"
}

# --- epics --------------------------------------------------------------------
#
# An epic, an issue with sub-issues, is never moved by hand: it follows its sub-issues. It stands in
# implementing once one has started (a sub-issue in review has started too), in testing once all
# stand in testing or done, and is closed once all are done. As nothing else moves it, it also takes
# the one step back its sub-issues make true again: from testing to implementing, once a sub-issue
# stands before testing.
# A closed epic stays closed.

status_rank() {  # status_rank <status> - backlog, ready and planned < implementing and review < testing < done
  case "$1" in
    implementing|review) echo 1 ;;
    testing) echo 2 ;;
    done|CLOSE|'not planned') echo 3 ;;
    *) echo 0 ;;
  esac
}

# epic_target <the epic's status> <a sub-issue's status>... - a closed sub-issue counts as done, one
# closed as not planned or as a duplicate ("not planned") not at all, so an epic whose sub-issues
# are all of that kind does not move. Echoes implementing, testing or CLOSE, or nothing where the
# epic stands there or further, except that an epic in testing goes back to implementing.
epic_target() {
  local cur="$1" s r low=3 high=0 t="" counted=0
  shift
  for s in "$@"; do
    [ "$s" = 'not planned' ] && continue
    counted=1
    r="$(status_rank "$s")"
    [ "$r" -lt "$low" ] && low="$r"
    [ "$r" -gt "$high" ] && high="$r"
  done
  [ "$counted" -eq 1 ] || return 0
  if [ "$low" -eq 3 ]; then t=CLOSE
  elif [ "$low" -eq 2 ]; then t=testing
  elif [ "$high" -ge 1 ]; then t=implementing
  fi
  [ -n "$t" ] || return 0
  if [ "$(status_rank "$t")" -gt "$(status_rank "$cur")" ] || [ "$cur $t" = 'testing implementing' ]; then echo "$t"; fi
  return 0
}

# update_epic <owner/repo> <number> - move an epic to where its sub-issues stand, through the same
# movers as every card, which move its own parent in turn; read on the board of the epic's
# repository where the caller selected none, or where the caller's board holds no card of the
# epic: moving it there would put a card of it on a board it was never on, and a board's
# "auto-add sub-issues" workflow then pulls all its sub-issues after it
update_epic() {
  local repo="$1" n="$2" target out bin items
  bin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
  (
    if [ -n "${PROJECT:-}" ]; then
      items="$(issue_board_items "$repo" "$n")" || exit 1
      cut -f1 <<< "$items" | grep -qxF "$(project_org)/$(project_number)" || { PROJECT=""; PROJECT_ORG=""; GH_PROJECT_NUMBER=""; }
    fi
    [ -n "${PROJECT:-}" ] || on_no_board "$repo" || set_project "" "$repo" >/dev/null || exit 1
    target="$(epic_target_on_board "$repo" "$n")" || exit 1
    case "$target" in
      '') exit 0 ;;
      CLOSE) out="$(bash "$bin/issue-close.sh" "$repo" "$n")" || exit 1
             echo "epic $repo#$n -> closed, every sub-issue done" ;;
      *)     out="$(bash "$bin/issue-status.sh" ${PROJECT:+--project "$(project_org)/$(project_number)"} "$repo" "$n" "$target")" || exit 1
             echo "epic $repo#$n -> $target, as its sub-issues stand" ;;
    esac
    grep '^epic ' <<< "$out" || true
  )
}

# update_parent_epic <owner/repo> <number> - after a card moved, its epic follows
update_parent_epic() {
  local parent
  parent="$(issue_parent "$1" "$2")" || return 1
  [ -n "$parent" ] || return 0
  update_epic "${parent% *}" "${parent#* }"
}
