#!/usr/bin/env bash
# The GitHub command line, as every GitHub provider of this harness calls it: gh with the rate
# limits met once (gh), gh with its refusals made visible (gh_read) and gh for a write (gh_write).
# lib/github/tracker.sh sources it, and lib/github/forge.sh will, because only this folder may call
# `command gh`. Source it, do not run it.

. "$(dirname "${BASH_SOURCE[0]}")/../common.sh"

# EVERY gh CALL OF THIS REPOSITORY MEETS GITHUB'S RATE LIMITS HERE, ONCE.
#
# A burst of calls from several sessions of one account is refused with "API rate limit already
# exceeded" while `gh api rate_limit` still shows thousands of points left for GraphQL: the REST
# view does not show the budget that GraphQL spends. So this function shadows `gh` in every script
# that sources lib/github/tracker.sh or lib/github/forge.sh, which is every script of this repository
# that calls gh, and a refusal, recognised on gh's STDERR alone because stdout may quote anything, is
# told apart by asking GitHub itself:
#   GraphQL `rateLimit` remaining 0, or REST `rate_limit` core remaining 0:
#                 the primary limit of that API: wait until its reset;
#   both above 0: the secondary limit, the one for bursts: a minute, doubled per try.
# The call is then repeated, GH_RATE_RETRIES times at most. A wait longer than GH_RATE_WAIT_MAX, or
# the last refusal, ends in a message that names the limit and leaves gh's answer and exit status
# to the caller, so gh_read and every bare call fail as they always did, with the limit named.
# The wait notice goes to stderr, which is why a caller that parses its capture uses `apart`.
#
# A call that reads its request from standard input (`--input -`) is not repeated: the first try
# consumed it. AI_CORE_SLEEP names the command that waits, `sleep` unless a test says otherwise.
GH_RATE_RETRIES=3
GH_RATE_WAIT_BASE=60
GH_RATE_WAIT_MAX=900

gh() {
  local rc try=0 out err
  case " $* " in *" --input - "*) command gh "$@"; return ;; esac
  while :; do
    rc=0; run_split command gh "$@" || rc=$?
    out="$split_out"; err="$split_err"
    if [ "$rc" -ne 0 ] && grep -qiE 'API rate limit (already )?exceeded|secondary rate limit' <<< "$err"; then
      if [ "$try" -lt "$GH_RATE_RETRIES" ]; then
        try=$((try + 1))
        gh_rate_wait "$try"
        if [ "$gh_rate_seconds" -le "$GH_RATE_WAIT_MAX" ]; then
          echo "waiting ${gh_rate_seconds}s for $gh_rate_limit (try $try of $GH_RATE_RETRIES)" >&2
          "${AI_CORE_SLEEP:-sleep}" "$gh_rate_seconds"
          continue
        fi
        err="$err"$'\n'"$gh_rate_limit refuses and does not lift within $GH_RATE_WAIT_MAX seconds"
      else
        err="$err"$'\n'"$gh_rate_limit still refuses after $try waits"
      fi
    fi
    [ -z "$out" ] || printf '%s\n' "$out"
    [ -z "$err" ] || printf '%s\n' "$err" >&2
    return "$rc"
  done
}

# Sets gh_rate_seconds and gh_rate_limit, a phrase that names the limit. Globals, because bash 3.2
# has no way to return two values.
gh_rate_wait() {  # gh_rate_wait <which try>
  local api remaining reset_epoch probe
  gh_rate_limit="GitHub's secondary rate limit"
  gh_rate_seconds=$(( GH_RATE_WAIT_BASE * (1 << ($1 - 1)) ))
  for api in GraphQL REST; do
    if [ "$api" = GraphQL ]; then
      probe="$(command gh api graphql -f query='{ rateLimit { remaining resetAt } }' 2>/dev/null \
        | jq -r '.data.rateLimit | "\(.remaining) \(.resetAt | fromdateiso8601)"' 2>/dev/null)" || probe=""
    else
      probe="$(command gh api rate_limit 2>/dev/null | jq -r '.resources.core | "\(.remaining) \(.reset)"' 2>/dev/null)" || probe=""
    fi
    remaining=""; reset_epoch=""
    read -r remaining reset_epoch <<< "$probe" || true
    if [ "$remaining" = 0 ] && [ -n "$reset_epoch" ]; then
      gh_rate_limit="GitHub's primary $api rate limit (spent until $(date -u -d "@$reset_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$reset_epoch"))"
      gh_rate_seconds=$(( reset_epoch - $(date +%s) + 1 ))
      [ "$gh_rate_seconds" -ge 1 ] || gh_rate_seconds=1
      return 0
    fi
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

# EVERYTHING THIS REPOSITORY WRITES THROUGH gh GOES THROUGH HERE, the counterpart of gh_read.
#
# A failed write leaves one of two facts, and gh_read's "cannot read" is wrong for both. A refusal by GitHub
# carries its status, 4xx, on stderr: nothing was changed. Any other failure, a lost connection, an answer that
# does not decode, a server error, a GraphQL answer that holds errors, may have come after GitHub stored the
# write, so the outcome is unknown and the message says that and never that nothing happened. 408 is a
# timeout and no refusal. The write is not repeated here; the rate limit wait of gh() repeats only a call that
# GitHub refused for its rate. The status, the stderr and the body gh answered are kept in the message.
#
# On success the answer is printed as gh_read prints it, the wait notices of gh() to stderr. Where the
# caller must stop, it writes `x="$(gh_write ...)" || exit 1`, or `gh_write ... || exit 1` where it needs no answer.
gh_write() {  # gh_write <what is written> <what became of it, a past participle> <gh argument>...
  local what="$1" participle="$2" rc=0 status
  shift 2
  run_split gh "$@" || rc=$?
  if [ "$rc" -eq 0 ]; then
    [ -z "$split_err" ] || printf '%s\n' "$split_err" >&2
    [ -z "$split_out" ] || printf '%s\n' "$split_out"
    return 0
  fi
  status="$(grep -oE 'HTTP [0-9]{3}' <<< "$split_err" | tail -n1 || true)"
  case "$status" in
    'HTTP 408') ;;
    'HTTP 4'??) die "$what was NOT $participle - GitHub refused it ($status); gh exited $rc${split_err:+ and said: $split_err}${split_out:+; GitHub answered: $split_out}" ;;
  esac
  die "it is not known whether $what was $participle - gh exited $rc${split_err:+ and said: $split_err}${split_out:+; GitHub answered: $split_out}; look at it before writing it again"
}

# gh_repo_visibility <owner/repo>: public or private. Only a successful boolean isPrivate establishes it;
# anything else fails and says why. The tracker and the forge both read the visibility of a repository
# here, so the two cannot disagree.
gh_repo_visibility() {
  local json visibility
  json="$(gh_read "the visibility of $1" repo view "$1" --json isPrivate)" || return 1
  visibility="$(printf '%s' "$json" | jq -er 'if (.isPrivate | type) == "boolean" then
    if .isPrivate then "private" else "public" end else error("isPrivate is not boolean") end' 2>/dev/null)" \
    || { echo "cannot establish the visibility of $1: isPrivate was not a boolean" >&2; return 1; }
  case "$visibility" in public|private) printf '%s\n' "$visibility" ;;
    *) echo "cannot establish the visibility of $1: expected one repository" >&2; return 1 ;;
  esac
}

# gh_doctor: the gh lines of `ai-core doctor`, through doctor's own report, problem and install_tool, which
# doctor.sh defines. The forge prints them where the forge is GitHub, and the tracker where only the
# tracker is: either one alone needs gh, its login and the project scope.
gh_doctor() {
  local gh_status
  if ! command -v gh >/dev/null 2>&1; then install_tool gh gh gh || true; fi
  if command -v gh >/dev/null 2>&1; then
    # the board commands write Projects v2, which a login with gh's default scopes cannot; a token
    # gh lists no scopes for (a fine-grained one, GH_TOKEN) is not judged
    if gh_status="$(gh auth status 2>&1)"; then
      if grep -q 'Token scopes:' <<< "$gh_status" && ! grep -q "'project'" <<< "$gh_status"; then
        report gh "no project scope" "the board commands read and write the project board; run: gh auth refresh -h github.com -s project"; problem
      else
        report gh present "$(gh --version 2>/dev/null | sed -n 1p), logged in"
      fi
    else
      report gh "not logged in" "run: gh auth login"; problem
    fi
  else
    report gh MISSING "install GitHub CLI from https://cli.github.com"; problem
  fi
}
