#!/usr/bin/env bash
# Move each card to the state its git signals PROVE it has reached, so the board stops
# trailing reality because a person forgot to move a card.
#
#   status-sync.sh [--project N] [--dry-run] [OWNER/REPO ...]
#
# It reads only facts and moves FORWARD only. The signal:
#   - a card in testing whose landed commit the newest release tag carries, and whose issue carries
#     a proof record written after that landing                    -> closed + done
# The proof record is a comment whose first line is "Proven on <environment>:", written by the
# session that proved the released work; what it checked follows below that line, in the
# project's own form, and is not read here. Without it a released card stays in testing, because
# a release is not a proof.
# A card reaches testing through finish-issue, which runs after the push that lands the issue. A
# commit that names an issue says that it touches the issue, not that the issue is done: an issue
# whose work lands in several steps carries such commits long before it is.
#
# WHY THERE IS NO PULL-REQUEST SIGNAL. Work stays on master here: an issue is worked in a
# worktree on a temporary branch, and that branch is a place to commit, not a statement that
# anything is finished. An open worktree therefore proves nothing and is not read. What proves
# the work exists is the commit landing on master, which is what the push hook lets through, and
# what proves it shipped is a tag carrying that commit. A release here is a tag, because these
# repositories tag rather than cut a GitHub release; whether that tag actually deployed is the
# pipeline's to alarm on, not the board's.
#
# THE RELEASE IS READ FROM THE CLONE, after one fetch: the newest tag by date that matches the
# first environment of LIVE_TAGS in that clone's .ai-core/config.env ("prod=deploy/prod/* ..."
# gives deploy/prod/*), or the newest tag of all where LIVE_TAGS names none. GitHub lists tags by
# name, so its first tag is deploy/test/... beside deploy/prod/... and no release at all. A card
# whose work landed in another repository is read in that repository's clone. A repository with no
# clone here, in the checkout this runs in or beside it in the project folder, is named, and its
# cards stay.
#
# THE CARDS ARE READ PER REPOSITORY: its open issues and their cards on this board, in one paged
# query. start-issue and finish-issue run this for their own repository; read through the whole
# board, that cost about 200 points of the hourly GraphQL budget per call on a board of 1000 cards.
# Without a repository named, the board is read once to learn which repositories it holds.
#
# The card is put in `implementing` by start-issue, at the moment the worktree is opened, and in
# `testing` by finish-issue; both are a session's statement and this sweep writes neither. It
# never moves a card BACKWARD, so a state a person set by hand stands. An EPIC carries no work and has no signals of
# its own: it follows its sub-issues (epic_target in lib/board.sh), back from testing to
# implementing too, so a sub-issue moved by hand on the board moves its epic here too. Nothing is guessed: a card only moves on a signal.
#
# --dry-run prints what it would do and writes nothing. Default is to apply, because the whole
# point is that no person has to run it.
#
# It does not WRITE the board itself: it calls issue-status and issue-close, the movers that
# already handle every board a card is on. One writer, one set of rules.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/board.sh"

# --- the decision, kept pure so a test can drive it without a board ------------

# derive_target <current> <on_master 0|1> <released 0|1> <is_epic 0|1> <proven 0|1>
# Echoes CLOSE for a card finish-issue moved to testing whose commit the newest release tag
# carries and whose issue carries a proof record after its landing, and nothing for every other
# card; an epic follows its sub-issues instead.
derive_target() {
  local cur epic="$4"
  cur="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  [ "$epic" = 1 ] && return 0
  [ "$cur" = testing ] && [ "$2" = 1 ] && [ "$3" = 1 ] && [ "${5:-0}" = 1 ] && echo CLOSE
  return 0
}

# When sourced by a test, stop here: the functions are defined, the sweep does not run.
[ "${BASH_SOURCE[0]}" != "${0:-}" ] && return 0

# --- what is read, once per repository ----------------------------------------

# THE OPEN ISSUES OF ONE REPOSITORY THAT HAVE A CARD ON THIS BOARD, one line each:
#   <status>\t<number>\t<sub-issue total>\t<the commit finish-issue landed, or ->\t<proven 0|1>
#   \t<the repository it landed in where that is another one, or ->
#
# The commit is the first one finish-issue listed in its newest "Landed on <branch>:" comment,
# the record it writes when it moves the card to testing; "Landed on <branch> of <owner/repo>:"
# names the repository the work landed in. A comment counts only when it came after the issue was
# last reopened: a ticket reopened for rework still carries the record of the work that closed it
# the first time. A proof record counts only when it came after that landing. Only the comments of
# the repository's owner, members and collaborators count: on a public repository anybody can
# write "Landed on" and "Proven on".
cards_of_repo() {  # <owner/repo>
  local repo="$1" after="" page next
  while :; do
    page="$(gh_read "the open issues of $repo" api graphql -f o="${repo%%/*}" -f n="${repo#*/}" ${after:+-f after="$after"} -f query='
      query($o:String!, $n:String!, $after:String) { repository(owner:$o, name:$n) {
        issues(states:OPEN, first:50, after:$after) { pageInfo { hasNextPage endCursor } nodes {
          number subIssuesSummary { total }
          projectItems(first:20) { nodes { project { number owner { ... on Organization { login } ... on User { login } } }
            status: fieldValueByName(name:"Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } } } }
          reopened: timelineItems(last:1, itemTypes:[REOPENED_EVENT]) { nodes { ... on ReopenedEvent { createdAt } } }
          comments(last:50) { nodes { createdAt body authorAssociation } } } } } }')" || exit 1
    printf '%s' "$page" | jq -r --argjson board "$(project_number)" --arg org "$(project_org)" '
      .data.repository.issues.nodes[]
      | . as $i
      | ([$i.projectItems.nodes[] | select(.project.number == $board and (.project.owner.login | ascii_downcase) == ($org | ascii_downcase))
          | (.status.name // "")] | first) as $status
      | select($status != null and $status != "")
      | (($i.reopened.nodes[0].createdAt) // "") as $reopenedAt
      | [$i.comments.nodes[] | select(.authorAssociation == "OWNER" or .authorAssociation == "MEMBER" or .authorAssociation == "COLLABORATOR")] as $said
      | ([$said[] | select(.body | startswith("Landed on "))
          | select($reopenedAt == "" or (.createdAt > $reopenedAt))] | sort_by(.createdAt) | last) as $landed
      | (($landed.body // "") | split("\n") | map(select(test("^- [0-9a-f]{7,40} "))) | first
          | if . then (split(" ")[1]) else "-" end) as $sha
      | ((($landed.body // "") | (split("\n")[0] // "") | capture("^Landed on \\S+ of (?<r>[^\\s:]+/[^\\s:]+):") | .r) // "-") as $elsewhere
      | ([$said[] | select($landed != null and (.body | startswith("Proven on ")) and (.createdAt > $landed.createdAt))]
          | if length > 0 then 1 else 0 end) as $proven
      | "\($status)\t\($i.number)\t\($i.subIssuesSummary.total // 0)\t\($sha)\t\($proven)\t\($elsewhere)"' | tr -d '\r' || exit 1
    next="$(printf '%s' "$page" | jq -r '.data.repository.issues.pageInfo | if .hasNextPage then .endCursor else empty end')"
    [ -n "$next" ] || break
    after="$next"
  done
}

# THE CLONE OF <owner/repo> ON THIS MACHINE: the checkout this runs in when its origin is that
# repository, else a folder of the project folder whose origin is. Prints nothing where none is.
project_folder() {
  local common
  if common="$(git rev-parse --git-common-dir 2>/dev/null)"; then
    dirname "$(cd "$common/.." && git rev-parse --show-toplevel)"
  else pwd; fi
}
clone_of() {  # <owner/repo>
  local want dir url
  want="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  for dir in "$(git rev-parse --show-toplevel 2>/dev/null || true)" "$(project_folder)"/*/; do
    dir="${dir%/}"
    [ -n "$dir" ] || continue
    url="$(git -C "$dir" remote get-url origin 2>/dev/null | tr '[:upper:]' '[:lower:]')" || continue
    url="${url%.git}"
    case "$url" in *[:/]"$want") echo "$dir"; return 0 ;; esac
  done
  return 0
}

# THE TAGS OF THE RELEASE THAT CLOSES A CARD: the pattern of the first environment of LIVE_TAGS
# in a config.env, or every tag where it names none
release_tag_pattern() {  # <config.env>
  local line word
  line="$(grep -E '^[[:space:]]*LIVE_TAGS[[:space:]]*=' "$1" 2>/dev/null | tail -n1 || true)"
  line="${line#*=}"; line="${line%%#*}"; line="${line//[\"\']/}"
  for word in $line; do
    case "$word" in ?*=?*) echo "${word#*=}"; return 0 ;; esac
  done
  echo '*'
}

# THE RELEASE OF ONE REPOSITORY, read once per run and kept for the next card that asks: sets
# REL_CLONE (its clone, or empty), REL_REF (origin's default branch) and REL_TAG (the newest
# release tag by date, or empty), and says once what it could not read. Called in this shell, never
# as `$( )`, or what it keeps would end with the subshell.
#
# The pattern is LIVE_TAGS of the clone's own .ai-core/config.env: the project of that repository
# decides what its release is, never the folder this runs in. A tag counts only where origin has it
# on the same commit: a fetch never prunes and never moves a tag the clone holds, so a tag a
# refused push left in the clone, one deleted on origin or one origin moved would read as a
# release. Where origin cannot be listed, no tag counts. The fetch asks nobody for a password.
_RELEASES=''
release_of() {  # <owner/repo>
  local held said reason remote t want
  held="$(printf '%s' "$_RELEASES" | awk -F'\t' -v r="$1" 'tolower($1) == tolower(r) { print; exit }')"
  if [ -n "$held" ]; then
    IFS=$'\t' read -r _ REL_CLONE REL_REF REL_TAG <<< "$held"
    [ "$REL_CLONE" != - ] || REL_CLONE=""; [ "$REL_REF" != - ] || REL_REF=""; [ "$REL_TAG" != - ] || REL_TAG=""
    return 0
  fi
  REL_CLONE="$(clone_of "$1")"; REL_REF=""; REL_TAG=""
  if [ -z "$REL_CLONE" ]; then
    echo "no clone of $1 in $(project_folder), so no release of it is read and its cards in testing stay"
  else
    # Without -q, because a quiet fetch that refuses to move a tag gives no reason at all
    if ! said="$(GIT_TERMINAL_PROMPT=0 git -C "$REL_CLONE" fetch --tags origin 2>&1)"; then
      reason="$(printf '%s\n' "$said" | grep -m1 -E '^(error|fatal):|^ ! ' | tr -s ' ' | sed 's/^ //' || true)"
      echo "fetching origin of $1 in $REL_CLONE failed: ${reason:-git gave no reason}; the refs it had are read"
    fi
    REL_REF="origin/$(cd "$REL_CLONE" && origin_default_branch)" || REL_REF=""
    if remote="$(GIT_TERMINAL_PROMPT=0 git -C "$REL_CLONE" ls-remote --tags origin 2>/dev/null)"; then
      # <tag> <the commit it stands on>: an annotated tag's own line names the tag object, its ^{} line the commit
      remote="$(printf '%s\n' "$remote" | awk '$2 != "" { n = $2; sub("^refs/tags/", "", n)
        if (sub("\\^\\{\\}$", "", n)) c[n] = $1; else if (!(n in c)) c[n] = $1 } END { for (n in c) print n "\t" c[n] }')"
      while IFS= read -r t; do
        [ -n "$t" ] || continue
        want="$(awk -F'\t' -v t="$t" '$1 == t { print $2; exit }' <<< "$remote")"
        if [ -n "$want" ] && [ "$want" = "$(git -C "$REL_CLONE" rev-parse -q --verify "refs/tags/$t^{commit}" 2>/dev/null)" ]; then REL_TAG="$t"; break; fi
      done <<< "$(git -C "$REL_CLONE" tag --list "$(release_tag_pattern "$REL_CLONE/.ai-core/config.env")" --sort=-creatordate)"
    else
      echo "origin of $1 could not be listed from $REL_CLONE, so no tag of it counts as a release and its cards in testing stay"
    fi
  fi
  _RELEASES="${_RELEASES}$1"$'\t'"${REL_CLONE:--}"$'\t'"${REL_REF:--}"$'\t'"${REL_TAG:--}"$'\n'
}

# --- the sweep ----------------------------------------------------------------

project=""; dry=0; args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --project) need_value "$1" "${2-}"; project="$2"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    -*)        die "unknown argument '$1'" ;;
    *)         args+=("$1"); shift ;;
  esac
done
set -- ${args[@]+"${args[@]}"}

set_project "$project" >/dev/null
resolved="$(project_number)"
org="$(project_org)"

# The repositories: the ones named, else every one with an active card on the board, which is read
# whole for that. A refused read stops the run: a board that never answered is no empty board.
repos=()
if [ $# -gt 0 ]; then
  for want in "$@"; do case "$want" in */*) repos+=("$want") ;; *) repos+=("$org/$want") ;; esac; done
else
  cards="$("$ROOT/bin/board-list.sh" --project "$resolved")" || exit 1
  while read -r name; do
    [ -n "$name" ] || continue
    case "$name" in */*) repos+=("$name") ;; *) repos+=("$org/$name") ;; esac
  done <<< "$(awk '$1 != "done" && $4 ~ /^#[0-9]+$/ { print $3 }' <<< "$cards" | sort -u)"
fi

moved=0; scanned=0
for full in ${repos[@]+"${repos[@]}"}; do
  cards="$(cards_of_repo "$full")" || exit 1
  label="${full#"$org"/}"
  while IFS=$'\t' read -r st num subs sha proven elsewhere; do
    [ -n "$num" ] || continue
    [ "$(printf '%s' "$st" | tr '[:upper:]' '[:lower:]')" != done ] || continue
    scanned=$((scanned + 1))
    # An issue with sub-issues is an epic whatever their number, and follows them. One with a single
    # sub-issue is named: it is often an issue with work of its own and one dependency hung under
    # it, and closing it with that sub-issue would close the unfinished work.
    [ "$subs" = 1 ] && echo "one child    $label#$num  (its state follows its one sub-issue; work of its own belongs in a sub-issue of its own, or it is closed with that sub-issue)"
    if [ "$subs" -gt 0 ]; then
      target="$(epic_target_on_board "$full" "$num")" || exit 1
    else
      [ "$(printf '%s' "$st" | tr '[:upper:]' '[:lower:]')" = testing ] || continue
      # The release of the repository the work landed in, read once where a card in testing asks
      landed="$full"; [ "$elsewhere" = - ] || landed="$elsewhere"
      release_of "$landed"
      tag="$REL_TAG"; [ "$landed" = "$full" ] || tag="$landed $REL_TAG"
      on_master=0; rel=0
      if [ -n "$REL_REF" ] && [ "$sha" != - ] && commit="$(git -C "$REL_CLONE" rev-parse -q --verify "$sha^{commit}" 2>/dev/null)"; then
        git -C "$REL_CLONE" merge-base --is-ancestor "$commit" "$REL_REF" && on_master=1
        [ -n "$REL_TAG" ] && git -C "$REL_CLONE" merge-base --is-ancestor "$commit" "$REL_TAG" && rel=1
      fi
      target="$(derive_target "$st" "$on_master" "$rel" 0 "$proven")"
      [ -n "$target" ] || { [ "$rel" = 1 ] && echo "proof due    $label#$num  (released in $tag, no \"Proven on\" record after its landing)"; continue; }
    fi
    [ -n "$target" ] || continue

    if [ "$target" = "CLOSE" ]; then
      why="released in $tag and proven"; [ "$subs" -gt 0 ] && why="every sub-issue done"
      if [ "$dry" = 1 ]; then echo "would close  $label#$num  ($st -> done, $why)"
      else echo "close        $label#$num  ($st -> done, $why)"
        "$ROOT/bin/issue-close.sh" "$full" "$num" >/dev/null < /dev/null; fi
    else
      if [ "$dry" = 1 ]; then echo "would move   $label#$num  ($st -> $target)"
      else echo "move         $label#$num  ($st -> $target)"
        "$ROOT/bin/issue-status.sh" "$full" "$num" "$target" >/dev/null < /dev/null; fi
    fi
    moved=$((moved + 1))
  done <<< "$cards"
done

echo
echo "$scanned active cards scanned, $moved $([ "$dry" = 1 ] && echo would move || echo moved) on board $resolved."
