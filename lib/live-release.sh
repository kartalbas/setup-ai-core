#!/usr/bin/env bash
# THE DELIVERY OF AN ENVIRONMENT THAT A PROJECT'S OWN READER ANSWERS, for the two commands that ask
# whether work is live: status-sync sources this file, and status runs it as
#
#   live-release.sh read <landing clone> <owner/repo> <environment>
#
# An environment of LIVE_TAGS whose value is `command` is delivered by something the harness cannot
# read for itself: the release of another repository that pins this one, or the redeploy of a
# service. The project says how to read it in LIVE_RELEASE_COMMAND of the landing clone's own
# .ai-core/config.env: one executable file, an absolute path or one relative to that clone, that is
# started in the clone with two arguments, the full owner/repo and the environment, never through a
# shell. It only reads, and it prints one JSON object whose five fields are all nonempty strings:
#   repository   the requested one, as it was asked
#   environment  the requested one, as it was asked
#   commit       the full object ID, in that repository, of the commit the newest completed delivery holds
#   releasedAt   when that delivery completed, UTC, YYYY-MM-DDTHH:MM:SSZ, a time of the calendar, not in the future
#   source       the carrying release or the successful run the reader inspected
# or JSON null, with exit 0, where its read found no completed delivery. Everything else is an error
# and no answer: a missing or non-executable reader, a non-zero exit, no output, text that is no JSON,
# more than one value, another repository or environment, a field of another type, a time that is
# none, and a commit the clone does not hold. Nothing stands in for an error: not a tag, not the tip
# of the default branch, not an earlier answer. Standard error stays apart from the JSON, and the
# reader owns the deadline of every request it makes: this file cannot know that an executable
# stops.
#
# The harness checks the shape and the identity of the answer; whether the reader told the truth
# about a deployment outside the clones is the project's.
#
# Sourced, it needs lib/common.sh already sourced by the caller, which sources lib/board.sh; run, it sources
# lib/common.sh itself.

# live_tags_declaration <clone>: LIVE_TAGS as the clone's own config.env sets it; the environment does not
live_tags_declaration() { (cd "$1" && config_file_value LIVE_TAGS ""); }

# live_tags_names_command <the value of LIVE_TAGS>: whether one of its <environment>=<value> entries has the value `command`
live_tags_names_command() {
  local words word
  read -r -a words <<< "$1"
  for word in ${words[@]+"${words[@]}"}; do
    case "$word" in ?*=command) return 0 ;; esac
  done
  return 1
}

# live_release_run <directory> <command>...: the command in the directory, with no standard input, because the
# caller may be reading its cards from it
live_release_run() { (cd "$1" && shift && "$@" < /dev/null); }

# live_release_read <clone> <owner/repo> <environment>: sets LIVE_RELEASE_ANSWER to {"delivered": null} or
# {"delivered": {repository, environment, commit, releasedAt, source}} and returns 0, or sets LIVE_RELEASE_ERROR
# to the reason in one line and returns 1. Called in this shell, never as `$( )`, or what it sets ends with the
# subshell.
live_release_read() {
  local clone="$1" repo="$2" environment="$3" path reader rc=0 count first fault now resolved
  LIVE_RELEASE_ANSWER=""; LIVE_RELEASE_ERROR=""
  path="$(cd "$clone" && config_file_value LIVE_RELEASE_COMMAND "")" \
    || { LIVE_RELEASE_ERROR="the settings of $clone cannot be read, so LIVE_RELEASE_COMMAND is not known"; return 1; }
  if [ -z "$path" ]; then
    LIVE_RELEASE_ERROR="LIVE_RELEASE_COMMAND is not set in $clone/.ai-core/config.env, and its LIVE_TAGS says $environment=command"
    return 1
  fi
  case "$path" in /*) reader="$path" ;; *) reader="$clone/$path" ;; esac
  if [ ! -f "$reader" ] || [ ! -x "$reader" ]; then
    LIVE_RELEASE_ERROR="the reader $reader that LIVE_RELEASE_COMMAND names in $clone/.ai-core/config.env is not an executable file"
    return 1
  fi
  run_split live_release_run "$clone" "$reader" "$repo" "$environment" || rc=$?
  if [ "$rc" -ne 0 ]; then
    first="$(grep -m1 -v '^[[:space:]]*$' <<< "$split_err" || true)"
    LIVE_RELEASE_ERROR="the reader $reader exited $rc for $repo $environment: ${first:-it said nothing}"
    return 1
  fi
  if ! count="$(printf '%s' "$split_out" | jq -s 'length' 2>/dev/null)"; then
    LIVE_RELEASE_ERROR="the reader $reader printed text that is no JSON for $repo $environment"
    return 1
  fi
  case "$count" in
    0) LIVE_RELEASE_ERROR="the reader $reader printed nothing for $repo $environment"; return 1 ;;
    1) ;;
    *) LIVE_RELEASE_ERROR="the reader $reader printed $count JSON values for $repo $environment, and one is the answer"; return 1 ;;
  esac
  if printf '%s' "$split_out" | jq -e '. == null' >/dev/null 2>&1; then
    LIVE_RELEASE_ANSWER='{"delivered":null}'
    return 0
  fi
  now="${AI_CORE_NOW:-$(date +%s)}"
  fault="$(printf '%s' "$split_out" | jq -r --arg repo "$repo" --arg environment "$environment" --argjson now "$now" '
    . as $answer
    | if type != "object" then "its answer is no JSON object"
      else (["repository", "environment", "commit", "releasedAt", "source"] | map(select(($answer[.] | type) != "string" or $answer[.] == "")) | first) as $missing
        | if $missing then "its field \($missing) is no nonempty string"
          elif .repository != $repo then "it answered for the repository \(.repository), not \($repo)"
          elif .environment != $environment then "it answered for the environment \(.environment), not \($environment)"
          elif (.commit | test("^([0-9a-f]{40}|[0-9a-f]{64})$") | not) then "its commit \(.commit) is no full object ID"
          elif (.releasedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") | not) then "its releasedAt \(.releasedAt) is not YYYY-MM-DDTHH:MM:SSZ"
          elif ((.releasedAt | try (fromdateiso8601 | todate) catch "") != .releasedAt) then "its releasedAt \(.releasedAt) is no time of the calendar"
          elif (.releasedAt | fromdateiso8601) > $now then "its releasedAt \(.releasedAt) is in the future"
          else empty end
      end' 2>/dev/null)" || fault="its answer could not be checked"
  if [ -n "$fault" ]; then
    LIVE_RELEASE_ERROR="the reader $reader answered for $repo $environment, and $fault"
    return 1
  fi
  resolved="$(git -C "$clone" rev-parse -q --verify "$(printf '%s' "$split_out" | jq -r '.commit')^{commit}" 2>/dev/null)" || resolved=""
  if [ "$resolved" != "$(printf '%s' "$split_out" | jq -r '.commit')" ]; then
    LIVE_RELEASE_ERROR="the reader $reader answered for $repo $environment with the commit $(printf '%s' "$split_out" | jq -r '.commit'), and the clone $clone, fetched, has no such commit"
    return 1
  fi
  LIVE_RELEASE_ANSWER="$(printf '%s' "$split_out" | jq -c '{delivered: {repository, environment, commit, releasedAt, source}}')"
}

if [ "${BASH_SOURCE[0]}" = "${0:-}" ]; then
  set -uo pipefail
  . "$(dirname "${BASH_SOURCE[0]}")/common.sh"
  case "${1:-}" in
    read)
      [ $# -eq 4 ] || { echo "usage: live-release.sh read <landing clone> <owner/repo> <environment>" >&2; exit 2; }
      if live_release_read "$2" "$3" "$4"; then printf '%s\n' "$LIVE_RELEASE_ANSWER"; else printf '%s\n' "$LIVE_RELEASE_ERROR" >&2; exit 1; fi ;;
    *) echo "usage: live-release.sh read <landing clone> <owner/repo> <environment>" >&2; exit 2 ;;
  esac
fi
