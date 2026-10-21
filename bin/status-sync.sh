#!/usr/bin/env bash
# Move each card to the state its git signals PROVE it has reached, so the board stops
# trailing reality because a person forgot to move a card.
#
#   status-sync.sh [--project N] [--dry-run] [OWNER/REPO ...]
#
# It reads only facts and moves FORWARD only. The signal:
#   - a card in testing whose landed commit the newest release tag carries, and whose issue carries
#     a proof record written after that landing                    -> closed + done
#   - a card in a column before testing whose issue a commit on origin's default branch names -> named
#     "not finished", the card stays: finish-issue, run after the push that lands the issue, moves it
#   - a card in testing whose landed commit the newest release tag does not carry     -> named
#     "not released", with the tag; where origin has no tag of the first environment of LIVE_TAGS
#     at all, the repository is named once, "no release", with the count of its cards in testing
#   - a card in testing whose landed commit the delivery of a `command` environment (LIVE_RELEASE_COMMAND,
#     lib/live-release.sh) holds, and whose issue carries a proof of that environment written after both
#     the landing and the delivery                                  -> closed + done; a delivery that does
#     not hold it is "not released", with its source; a read that failed is "unknown" and the card stays
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
# gives deploy/prod/*), else in the .ai-core/config.env of the checkout this runs in, as `status`
# reads a card, or the newest tag of all where neither names an environment; where that
# environment says `command` ("prod=command"), the delivery its reader answers and no tag, and a
# `command` of the checkout's list is no reader of a clone that declares none: its cards are
# unknown. GitHub lists tags by name, so its first tag is deploy/test/... beside deploy/prod/...
# and no release at all. A card whose work landed in another repository is read in that
# repository's clone. A repository with no clone here, in the checkout this runs in or beside it
# in the project folder, is named, and its cards stay. A repository whose work is live once it lands, documentation read where it lands, a
# template whose copies are released or a deployment that a run applies, has no release tag of its
# own: its first environment of LIVE_TAGS says `landed` ("prod=landed"), and its landing on origin's
# default branch is its release.
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
# already handle every board a card is on. One writer, one set of rules. Where a tracker lets a checkout
# act for its own repository only (writes_run_in_repo_clone), the movers run in the clone of the card's
# repository, and a card whose repository has no clone here is named and stays.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/board.sh"
. "$ROOT/lib/live-release.sh"

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
#   \t<the instant of that record, or ->\t<the proofs, "<instant>=<environment>" separated by a space, or ->
#
# The commit is the first one finish-issue listed in its newest "Landed on <branch>:" comment,
# the record it writes when it moves the card to testing; a report that starts with the same words
# but lists no commit is not that record; "Landed on <branch> of <owner/repo>:"
# names the repository the work landed in. Which comments are records is decided in lib/board.sh
# (LANDING_RECORD_JQ), as finish-issue decides whether the issue holds one. A proof record counts
# only when it came after that landing, written by an author who counts as there. An instant is
# the seconds since 1970 and nine digits of fraction, so that two compare as the times they are
# whatever fraction a tracker writes; a proof is listed with the environment its first line names,
# for a release read by a command (lib/live-release.sh), which compares it with the delivery.
cards_of_repo() {  # <owner/repo>
  local repo="$1" after="" page next
  while :; do
    page="$(open_issue_page "$repo" "$after")" || exit 1
    printf '%s' "$page" | jq -r --argjson board "$(project_number_json)" --arg org "$(project_org)" --arg repo "$repo" "$LANDING_RECORD_JQ"'
      .data.repository.issues.nodes[]
      | . as $i
      | ([$i.projectItems.nodes[] | select(.project.number == $board and (.project.owner.login | ascii_downcase) == ($org | ascii_downcase))
          | (.status.name // "")] | first) as $status
      | select($status != null and $status != "")
      | (($i.reopened.nodes[0].createdAt) // "") as $reopenedAt
      | [$i.comments.nodes[] | trusted] as $said
      | ($said | selected_landing($reopenedAt; $repo)) as $landing
      | ($landing.commit // "-") as $sha
      | (if $landing == null or ($landing.repository | ascii_downcase) == ($repo | ascii_downcase) then "-" else $landing.repository end) as $elsewhere
      | ([$said[] | select($landing != null and (.body | startswith("Proven on ")) and (.createdAt > $landing.createdAt))]
          | if length > 0 then 1 else 0 end) as $proven
      | (first($landing.createdAt // empty | instant) // "-") as $landedAt
      | ([$said[] | (.createdAt | instant) as $at | (.body | split("\n")[0] | proof_environment) as $token | "\($at)=\($token)"]
          | if length > 0 then join(" ") else "-" end) as $proofs
      | "\($status)\t\($i.number)\t\($i.subIssuesSummary.total // 0)\t\($sha)\t\($proven)\t\($elsewhere)\t\($landedAt)\t\($proofs)"' || exit 1
    next="$(printf '%s' "$page" | jq -r '.data.repository.issues.pageInfo | if .hasNextPage then .endCursor else empty end')"
    [ -n "$next" ] || break
    after="$next"
  done
}

# THE FIRST ENVIRONMENT of the LIVE_TAGS of a config.env, as <environment>=<pattern>; nothing where it names none
first_environment() {  # <config.env>
  local line word
  line="$(grep -E '^[[:space:]]*LIVE_TAGS[[:space:]]*=' "$1" 2>/dev/null | tail -n1 || true)"
  line="${line#*=}"; line="${line%%#*}"; line="${line//[\"\']/}"
  for word in $line; do
    case "$word" in ?*=?*) echo "$word"; return 0 ;; esac
  done
  return 0
}

# THE RELEASE OF ONE REPOSITORY, read once per run and kept for the next card that asks: sets
# REL_CLONE (its clone, or empty), REL_REF (origin's default branch), REL_TAG (the newest
# release tag by date, or empty), REL_LANDED (1 where LIVE_TAGS says `landed`, so the landing is
# the release and no tag is read), REL_NOTAG (1 only where origin was listed and none of its tags
# matches the pattern: an empty REL_TAG is also a repository with no clone, one whose tag stands
# on another commit and one whose origin could not be listed, and none of those is a repository
# that makes no release), REL_ENV (the environment the pattern belongs to, empty where LIVE_TAGS
# names none) and REL_PATTERN, and says once what it could not read. Where LIVE_TAGS says `command`,
# REL_COMMAND is 1 and no tag is read: the release is what the project's reader answers, which
# delivery_of asks for a card in testing, and REL_ERROR is set here where the fetch failed or where
# the `command` is the checkout's list and the clone declares none. Called in this shell, never as
# `$( )`, or what it keeps would end with the subshell.
#
# The pattern is the first environment of LIVE_TAGS of the clone's own .ai-core/config.env: the
# project of that repository decides what its release is. A clone that names none is read by the
# list of the checkout this runs in, as `status` reads it, and by every tag where that names none
# either. A tag counts only where origin has it on the same commit: a fetch never prunes and
# never moves a tag the clone holds, so a tag a refused push left in the clone, one deleted on
# origin or one origin moved would read as a release. Where a tag of the pattern stands on origin
# on another commit than in the clone, or not in the clone at all, which one is the newest is not
# known, and where origin cannot be listed, nothing is: then no tag counts. The fetch asks nobody
# for a password. A reader's answer is no release either where that fetch failed: its commit
# would be read from the refs the clone had.
_RELEASES=''
release_of() {  # <owner/repo>
  local held said reason remote word pattern t want caller_config odd="" fetch_failed="" from_caller=""
  held="$(printf '%s' "$_RELEASES" | awk -F'\t' -v r="$1" 'tolower($1) == tolower(r) { print; exit }')"
  if [ -n "$held" ]; then
    IFS=$'\t' read -r _ REL_CLONE REL_REF REL_TAG REL_LANDED REL_NOTAG REL_ENV REL_PATTERN REL_COMMAND REL_ERROR <<< "$held"
    [ "$REL_CLONE" != - ] || REL_CLONE=""; [ "$REL_REF" != - ] || REL_REF=""; [ "$REL_TAG" != - ] || REL_TAG=""
    [ "$REL_ENV" != - ] || REL_ENV=""; [ "$REL_ERROR" != - ] || REL_ERROR=""
    return 0
  fi
  REL_CLONE="$(clone_of "$1")"; REL_REF=""; REL_TAG=""; REL_LANDED=0; REL_NOTAG=0; REL_ENV=""; REL_PATTERN=""
  REL_COMMAND=0; REL_ERROR=""
  if [ -z "$REL_CLONE" ]; then
    echo "no clone of $1 in $(project_folder), so no release of it is read and its cards in testing stay"
  else
    # Without -q, because a quiet fetch that refuses to move a tag gives no reason at all
    if ! said="$(GIT_TERMINAL_PROMPT=0 git -C "$REL_CLONE" fetch --tags origin 2>&1)"; then
      reason="$(printf '%s\n' "$said" | grep -m1 -E '^(error|fatal):|^ ! ' | tr -s ' ' | sed 's/^ //' || true)"
      fetch_failed="fetching origin of $1 in $REL_CLONE failed: ${reason:-git gave no reason}"
      echo "$fetch_failed; the refs it had are read"
    fi
    REL_REF="origin/$(cd "$REL_CLONE" && origin_default_branch)" || REL_REF=""
    caller_config="$(data_dir)/config.env"
    word="$(first_environment "$REL_CLONE/.ai-core/config.env")"
    [ -n "$word" ] || { word="$(first_environment "$caller_config")"; from_caller=1; }
    case "$word" in *=*) REL_ENV="${word%%=*}"; pattern="${word#*=}" ;; *) pattern='*' ;; esac
    REL_PATTERN="$pattern"
    if [ "$pattern" = landed ]; then
      REL_LANDED=1
    elif [ "$pattern" = command ]; then
      REL_COMMAND=1
      [ -z "$fetch_failed" ] || REL_ERROR="$fetch_failed, so the delivery of $REL_ENV is not read"
      [ -z "$from_caller" ] || REL_ERROR="LIVE_TAGS of $caller_config says $REL_ENV=command, and the clone of $1 declares no command: only a clone that does can have its reader run, so $REL_ENV is not read"
    elif remote="$(GIT_TERMINAL_PROMPT=0 git -C "$REL_CLONE" ls-remote --tags origin 2>/dev/null)"; then
      # <tag> <the commit it stands on>: an annotated tag's own line names the tag object, its ^{} line the commit
      remote="$(printf '%s\n' "$remote" | awk '$2 != "" { n = $2; sub("^refs/tags/", "", n)
        if (sub("\\^\\{\\}$", "", n)) c[n] = $1; else if (!(n in c)) c[n] = $1 } END { for (n in c) print n "\t" c[n] }' | LC_ALL=C sort)"
      while IFS=$'\t' read -r t want; do
        # the pattern is a glob here as it is to git tag --list
        # shellcheck disable=SC2254
        case "$t" in $pattern) ;; *) continue ;; esac
        [ "$want" = "$(git -C "$REL_CLONE" rev-parse -q --verify "refs/tags/$t^{commit}" 2>/dev/null)" ] || { odd="$t"; break; }
      done <<< "$remote"
      if [ -n "$odd" ]; then
        echo "origin of $1 has $odd on a commit its clone in $REL_CLONE does not have it on, so no tag of it counts as a release and its cards in testing stay"
      else
        while IFS= read -r t; do
          [ -n "$t" ] || continue
          if awk -F'\t' -v t="$t" '$1 == t { f = 1 } END { exit !f }' <<< "$remote"; then REL_TAG="$t"; break; fi
        done <<< "$(git -C "$REL_CLONE" tag --list "$pattern" --sort=-creatordate)"
        [ -n "$REL_TAG" ] || REL_NOTAG=1
      fi
    else
      echo "origin of $1 could not be listed from $REL_CLONE, so no tag of it counts as a release and its cards in testing stay"
    fi
  fi
  _RELEASES="${_RELEASES}$1"$'\t'"${REL_CLONE:--}"$'\t'"${REL_REF:--}"$'\t'"${REL_TAG:--}"$'\t'"$REL_LANDED"$'\t'"$REL_NOTAG"$'\t'"${REL_ENV:--}"$'\t'"${REL_PATTERN:--}"$'\t'"$REL_COMMAND"$'\t'"${REL_ERROR:--}"$'\n'
}

# THE DELIVERY OF A COMMAND ENVIRONMENT, read once per run for the repository release_of was called for, and
# kept for the next card that asks: sets REL_DELIVERED (the commit of the newest completed delivery of REL_ENV),
# REL_AT (its time), REL_INSTANT (that time as cards_of_repo writes an instant), REL_SOURCE (what the reader
# inspected), all empty where its read found no completed delivery, and REL_ERROR, why no delivery could be
# read, which release_of may have set already. Called in this shell, never as `$( )`.
_DELIVERIES=''
delivery_of() {  # <owner/repo>
  local held
  REL_DELIVERED=""; REL_AT=""; REL_INSTANT=""; REL_SOURCE=""
  [ -z "$REL_ERROR" ] || return 0
  held="$(printf '%s' "$_DELIVERIES" | awk -F'\t' -v r="$1" 'tolower($1) == tolower(r) { print; exit }')"
  if [ -n "$held" ]; then
    IFS=$'\t' read -r _ REL_DELIVERED REL_AT REL_INSTANT REL_SOURCE REL_ERROR <<< "$held"
    [ "$REL_DELIVERED" != - ] || REL_DELIVERED=""; [ "$REL_AT" != - ] || REL_AT=""; [ "$REL_INSTANT" != - ] || REL_INSTANT=""
    [ "$REL_SOURCE" != - ] || REL_SOURCE=""; [ "$REL_ERROR" != - ] || REL_ERROR=""
    return 0
  fi
  if live_release_read "$REL_CLONE" "$1" "$REL_ENV"; then
    REL_DELIVERED="$(jq -r '.delivered.commit // empty' <<< "$LIVE_RELEASE_ANSWER")"
    REL_AT="$(jq -r '.delivered.releasedAt // empty' <<< "$LIVE_RELEASE_ANSWER")"
    REL_SOURCE="$(jq -j '.delivered.source // empty' <<< "$LIVE_RELEASE_ANSWER" | tr '\t\n' '  ')"
    [ -z "$REL_AT" ] || REL_INSTANT="$(jq -rn --arg t "$REL_AT" '($t | fromdateiso8601 | tostring) + ".000000000"')"
  else
    REL_ERROR="$(printf '%s' "$LIVE_RELEASE_ERROR" | tr '\t\n' '  ')"
  fi
  _DELIVERIES="${_DELIVERIES}$1"$'\t'"${REL_DELIVERED:--}"$'\t'"${REL_AT:--}"$'\t'"${REL_INSTANT:--}"$'\t'"${REL_SOURCE:--}"$'\t'"${REL_ERROR:--}"$'\n'
}

# instant_after <instant> <instant>: whether the first is later than the second, as cards_of_repo writes them, <seconds>.<nine digits>
instant_after() {
  local first="${1%%.*}" first_fraction="${1#*.}" second="${2%%.*}" second_fraction="${2#*.}"
  [ "$first" -gt "$second" ] || { [ "$first" -eq "$second" ] && [ "$((10#$first_fraction))" -gt "$((10#$second_fraction))" ]; }
}

# proof_after_delivery <proofs of cards_of_repo> <environment> <the instant of the landing record> <the instant of the delivery>:
# whether one proof names the environment, whatever the case of its letters, and stands later than both
proof_after_delivery() {
  local proof at word="" environment
  environment="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
  for proof in $1; do
    at="${proof%%=*}"
    word="$(printf '%s' "${proof#*=}" | tr '[:upper:]' '[:lower:]')"
    [ "$word" = "$environment" ] && instant_after "$at" "$3" && instant_after "$at" "$4" && return 0
  done
  return 1
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

# Without a board named, the board is the checkout's. Where the checkout is no repository or is on
# no board, it is the one the first repository named is linked to, so an issue whose repository
# has a board is swept there from a checkout that has none.
first=""
if [ -z "$project" ] && [ -z "${GH_PROJECT_NUMBER:-}" ]; then
  case "${1:-}" in */*)
    here="$( (default_repo) 2>/dev/null)" || here=""
    if [ -z "$here" ] || on_no_board "$here"; then first="$1"; fi ;;
  esac
fi
set_project "$project" "$first" >/dev/null
resolved="$(project_number)"
org="$(project_org)"

# The repositories: the ones named, else every one with an active card on the board, which is read
# whole for that. A refused read stops the run: a board that never answered is no empty board.
repos=()
if [ $# -gt 0 ]; then
  for want in "$@"; do case "$want" in */*) repos+=("$want") ;; *) repos+=("$org/$want") ;; esac; done
else
  cards="$("$ROOT/bin/board-list.sh" --project "$resolved")" || exit 1
  # A card that names no repository ("-") has no clone to read and is left out
  while read -r name; do
    [ -n "$name" ] || continue
    case "$name" in */*) repos+=("$name") ;; *) repos+=("$org/$name") ;; esac
  done <<< "$(awk '$1 != "done" && $3 != "-" && $4 ~ /^#[0-9]+$/ { print $3 }' <<< "$cards" | sort -u)"
fi

moved=0; scanned=0; unreleased=""
for full in ${repos[@]+"${repos[@]}"}; do
  cards="$(cards_of_repo "$full")" || exit 1
  label="${full#"$org"/}"
  while IFS=$'\t' read -r st num subs sha proven elsewhere landedat proofs; do
    [ -n "$num" ] || continue
    [ "$(printf '%s' "$st" | tr '[:upper:]' '[:lower:]')" != 'done' ] || continue
    scanned=$((scanned + 1))
    # An issue with sub-issues is an epic whatever their number, and follows them. One with a single
    # sub-issue is named: it is often an issue with work of its own and one dependency hung under
    # it, and closing it with that sub-issue would close the unfinished work.
    [ "$subs" = 1 ] && echo "one child    $label#$num  (its state follows its one sub-issue; work of its own belongs in a sub-issue of its own, or it is closed with that sub-issue)"
    if [ "$subs" -gt 0 ]; then
      target="$(epic_target_on_board "$full" "$num")" || exit 1
    else
      # A card before testing whose issue a commit on the default branch names: the work may have
      # landed with nobody running finish-issue, and this sweep reads testing alone. Named, never
      # moved, because that the work is complete is the session's statement, which finish-issue records.
      if [ "$(status_rank "$(printf '%s' "$st" | tr '[:upper:]' '[:lower:]')")" -lt 2 ]; then
        release_of "$full"
        named=""
        [ -z "$REL_REF" ] || named="$(git -C "$REL_CLONE" log "$REL_REF" -E -i --grep="$(issue_mention_pattern "$full" "$num" "$full")" --format=%h -n 1)" || named=""
        [ -z "$named" ] || echo "not finished $label#$num  (in $st, but $REL_REF has $named naming it: run ai-core finish-issue $full $num)"
        continue
      fi
      [ "$(printf '%s' "$st" | tr '[:upper:]' '[:lower:]')" = testing ] || continue
      # Without a landing record nothing here can tell where its work is, and the card never moves
      # on: named, so it does not wait unseen
      if [ "$sha" = - ]; then
        echo "no landing   $label#$num  (in testing, but no \"Landed on\" record names its work: where it landed, run ai-core finish-issue $full $num)"
        continue
      fi
      # The release of the repository the work landed in, read once where a card in testing asks
      landed="$full"; [ "$elsewhere" = - ] || landed="$elsewhere"
      release_of "$landed"
      tag="$REL_TAG"; [ "$REL_LANDED" = 0 ] || tag="its landing on $REL_REF"; [ "$landed" = "$full" ] || tag="$landed $tag"
      [ "$REL_COMMAND" = 0 ] || delivery_of "$landed"
      # What a reader cannot answer, or an answer that cannot be compared, is no release and no proof either way
      if [ "$REL_COMMAND" = 1 ] && [ -n "$REL_ERROR" ]; then
        echo "unknown      $label#$num  ($REL_ERROR; the card stays)"
        continue
      fi
      if [ "$REL_COMMAND" = 1 ] && [ "$landedat" = - ]; then
        echo "unknown      $label#$num  (the time of its \"Landed on\" record cannot be read, so no proof is compared with it; the card stays)"
        continue
      fi
      on_master=0; rel=0
      if [ -n "$REL_REF" ] && [ "$sha" != - ] && commit="$(git -C "$REL_CLONE" rev-parse -q --verify "$sha^{commit}" 2>/dev/null)"; then
        git -C "$REL_CLONE" merge-base --is-ancestor "$commit" "$REL_REF" && on_master=1
        [ -n "$REL_TAG" ] && git -C "$REL_CLONE" merge-base --is-ancestor "$commit" "$REL_TAG" && rel=1
        [ "$REL_LANDED" = 0 ] || rel="$on_master"
        if [ "$REL_COMMAND" = 1 ]; then
          # Delivered is what the reader's commit holds, and the landing must be on the default branch as well
          rel=0; proven=0
          [ "$on_master" = 1 ] && [ -n "$REL_DELIVERED" ] && git -C "$REL_CLONE" merge-base --is-ancestor "$commit" "$REL_DELIVERED" && rel=1
          [ "$rel" = 1 ] && proof_after_delivery "$proofs" "$REL_ENV" "$landedat" "$REL_INSTANT" && proven=1
          tag="$REL_ENV delivery $REL_SOURCE at $REL_AT"; [ "$landed" = "$full" ] || tag="$landed $tag"
        fi
      fi
      target="$(derive_target "$st" "$on_master" "$rel" 0 "$proven")"
      if [ -z "$target" ]; then
        if [ "$rel" = 1 ]; then
          if [ "$REL_COMMAND" = 1 ]; then
            echo "proof due    $label#$num  (released in $tag, no \"Proven on $REL_ENV\" record after both its landing and that delivery)"
          else
            echo "proof due    $label#$num  (released in $tag, no \"Proven on\" record after its landing)"
          fi
        elif [ "$on_master" = 1 ] && [ "$REL_COMMAND" = 1 ]; then
          where=""; [ "$landed" = "$full" ] || where=" of $landed"
          if [ -n "$REL_DELIVERED" ]; then
            echo "not released $label#$num  (landed in $sha; the newest $REL_ENV delivery$where, $REL_SOURCE at $REL_AT, does not carry it)"
          else
            echo "not released $label#$num  (landed in $sha; no completed $REL_ENV delivery$where is recorded)"
          fi
        elif [ "$on_master" = 1 ] && [ -n "$REL_TAG" ]; then
          where=""; [ "$landed" = "$full" ] || where=" of $landed"
          echo "not released $label#$num  (landed in $sha; the newest ${REL_ENV:+$REL_ENV }release $REL_TAG$where does not carry it)"
        elif [ "$on_master" = 1 ] && [ "$REL_NOTAG" = 1 ]; then
          # The cause is the repository's, so it is named once for all its cards, after the sweep
          unreleased="$(awk -F'\t' -v r="$landed" 'BEGIN { OFS = "\t" } $1 == "" { next } tolower($1) == tolower(r) { $2++; f = 1 } { print } END { if (!f) print r, 1 }' <<< "$unreleased")"
        elif [ -z "$REL_CLONE" ]; then
          echo "unknown      $label#$num  (no clone of $landed in $(project_folder), so its release is not read; the card stays)"
        elif [ -z "$REL_REF" ]; then
          echo "unknown      $label#$num  (the default branch of origin of $landed could not be read, so its release is not read; the card stays)"
        elif [ "$on_master" = 0 ]; then
          echo "no landing   $label#$num  (in testing, but its \"Landed on\" record names $sha, which $REL_REF of $landed does not hold: where it landed, run ai-core finish-issue $full $num)"
        else
          echo "unknown      $label#$num  (the release of $landed could not be read, as said where it was first asked for; the card stays)"
        fi
        continue
      fi
    fi
    [ -n "$target" ] || continue

    # Where the tracker has the clone of a card's repository write it, the movers run there
    mover_dir="."
    if writes_run_in_repo_clone "$full"; then
      mover_dir="$(clone_of "$full")"
      if [ -z "$mover_dir" ]; then
        echo "no clone     $label#$num  (no clone of $full in $(project_folder), and only its clone writes its cards, so the card stays)"
        continue
      fi
      # A fresh shell reads the clone as the mover will, without this shell's loaded provider variables.
      different="$(clone_setting_difference "$mover_dir" "$TRACKER" "$(config_value PLANE_URL "")" "$(config_value PLANE_WORKSPACE "")" "$resolved")" || exit 1
      if [ -n "$different" ]; then
        echo "other board  $label#$num  ($mover_dir has a different $different, so the card stays)"
        continue
      fi
    fi

    if [ "$target" = "CLOSE" ]; then
      # An epic names no release, and no card in testing may have been read before it
      if [ "$subs" -gt 0 ]; then why="every sub-issue done"; else why="released in $tag and proven"; fi
      if [ "$dry" = 1 ]; then echo "would close  $label#$num  ($st -> done, $why)"
      else echo "close        $label#$num  ($st -> done, $why)"
        (cd "$mover_dir" && "$ROOT/bin/issue-close.sh" "$full" "$num") >/dev/null < /dev/null; fi
    else
      if [ "$dry" = 1 ]; then echo "would move   $label#$num  ($st -> $target)"
      else echo "move         $label#$num  ($st -> $target)"
        (cd "$mover_dir" && "$ROOT/bin/issue-status.sh" "$full" "$num" "$target") >/dev/null < /dev/null; fi
    fi
    moved=$((moved + 1))
  done <<< "$cards"
done

# A repository whose origin was listed and has no tag of its release pattern: its cards in testing
# can never close, which no single card says
while IFS=$'\t' read -r unreleased_repo count; do
  [ -n "$unreleased_repo" ] || continue
  release_of "$unreleased_repo"
  if [ -n "$REL_ENV" ]; then what="$REL_ENV=$REL_PATTERN of LIVE_TAGS"; else what="$REL_PATTERN (LIVE_TAGS names no environment)"; fi
  echo "no release   ${unreleased_repo#"$org"/}  (no tag of ${unreleased_repo#"$org"/} matches $what; $count card$([ "$count" = 1 ] || echo s) in testing wait)"
done <<< "$unreleased"

echo
echo "$scanned active cards scanned, $moved $([ "$dry" = 1 ] && echo would move || echo moved) on board $resolved."
