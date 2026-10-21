#!/usr/bin/env bash
# What runs now, or with --tokens (and where no agent runs) the pace and the forecast;
# lib/status-help.txt says what it prints.

set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/../lib/board.sh"
. "$here/../lib/live-release.sh"

usage="usage: status.sh [--project N] [--tokens] [--issues]"
project=""; issues=""; tokens=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) echo "$usage"; cat "$here/../lib/status-help.txt"; exit 0 ;;
    --project) need_value "$1" "${2-}"; project="$2"; shift 2 ;;
    --tokens) tokens=--tokens; shift ;;
    --issues) issues=--issues; shift ;;
    *) die "unknown argument '$1' - $usage" ;;
  esac
done
command -v node >/dev/null 2>&1 || die "status counts with node, and node is not on the PATH"
# Outside a repository there is none to find the board from, and the board is named instead
[ -n "$project" ] || [ -n "${GH_PROJECT_NUMBER:-}" ] || git rev-parse --git-dir >/dev/null 2>&1 \
  || die "outside a repository, name the board - status --project N"
set_project "$project" "" >/dev/null || exit 1

# The project folder: the one the repositories and their .worktrees stand in, found from a worktree
# too; outside a repository, the folder you stand in
if common="$(git rev-parse --git-common-dir 2>/dev/null)"; then
  folder="$(dirname "$(cd "$common/.." && git rev-parse --show-toplevel)")"
else
  folder="$(pwd)"
fi
# The limit as usage.sh reads it: USAGE_STOP_AT of the project's config.env, else 92
config="$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.ai-core/config.env"
stop="$(grep -E '^[[:space:]]*USAGE_STOP_AT[[:space:]]*=' "$config" 2>/dev/null | tail -n1 || true)"
stop="${stop#*=}"; stop="${stop%%#*}"; stop="${stop//[[:space:]\"\']/}"; stop="${stop:-92}"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
columns="$(fields_tsv)" || exit 1
awk -F'\t' 'tolower($1) == "status" { print $3 }' <<< "$columns" > "$work/columns"
card_rows > "$work/items" || exit 1

# WHAT THE TESTING BLOCK READS OF EACH CARD IN TESTING, one JSON object a line in $work/testing, for lib/status.mjs:
#   {repository, number, pattern, context, reason, landing, landingClone}
# pattern is how a commit message names the issue (issue_mention_pattern). context says whether the landing
# of the issue was asked of the tracker: "none" where no clone of the project folder declares an environment
# of LIVE_TAGS as `command`, so that no card pays for a read it does not need; "read", with landing the
# newest landing record the trusted comments of the issue still hold ({repository, commit, createdAt}, or null
# where there is none) and landingClone the clone of its repository, empty where there is none; "failed", with
# the last line the tracker said, which names what it could not read. One read of the tracker per card, as the tracker answers it, at most; a read that
# fails is that card's line, never the end of the others.
write_testing_records() {
  local column clone declared="" repo number pattern context thread landing reason landing_clone
  column="$(awk 'tolower($0) == "testing" { print; exit }' "$work/columns")"
  : > "$work/testing"
  [ -n "$column" ] || return 0
  for clone in "$folder"/*/; do
    clone="${clone%/}"
    [ -e "$clone/.git" ] || continue
    if live_tags_names_command "$(live_tags_declaration "$clone")"; then declared=1; break; fi
  done
  while IFS=$'\t' read -r repo number; do
    [ -n "$number" ] || continue
    pattern="$(issue_mention_pattern "$repo" "$number" "$repo")"
    context=none; landing=null; reason=""; landing_clone=""
    if [ -n "$declared" ]; then
      if thread="$( (issue_landing_context "$repo" "$number") 2> "$work/context-error")" \
        && landing="$(jq -c --argjson window "$LANDING_COMMENT_WINDOW" --arg issue "$repo" "$LANDING_RECORD_JQ"'
            (.reopenedAt // "") as $reopenedAt
            | [.comments | .[(0 - $window):] | .[] | trusted] | selected_landing($reopenedAt; $issue)' <<< "$thread" 2> "$work/context-error")"; then
        context="read"
        [ "$landing" = null ] || landing_clone="$(clone_of "$(jq -r '.repository' <<< "$landing")")"
      else
        reason="$(grep -v '^[[:space:]]*$' "$work/context-error" | tail -n1 | tr -s ' \t' ' ' || true)"
        context="failed"; landing=null
        reason="${reason:-the tracker gave no reason}"
      fi
    fi
    jq -nc --arg repository "$repo" --argjson number "$number" --arg pattern "$pattern" --arg context "$context" \
      --arg reason "$reason" --argjson landing "$landing" --arg landingClone "$landing_clone" \
      '{repository: $repository, number: $number, pattern: $pattern, context: $context, reason: $reason, landing: $landing, landingClone: $landingClone}' >> "$work/testing"
  done <<< "$(jq -r --arg column "$column" 'select(.open and (.repo // "") != "" and ((.status // "") | ascii_downcase) == ($column | ascii_downcase)) | "\(.repo)\t\(.number)"' "$work/items" | sort -u)"
}
testing_file=()
if [ -z "$tokens$issues" ]; then
  write_testing_records || exit 1
  testing_file=(--testing-file "$work/testing")
fi

# Every process: its id, its parent, how long it runs ([[dd-]hh:]mm:ss), its state as ps writes it
# and its command line, a tab between; AI_CORE_PROCESSES names a file that stands in for it. Only the default view reads it.
processes=()
if [ -z "$tokens$issues" ]; then
  if [ -n "${AI_CORE_PROCESSES:-}" ]; then
    cp "$AI_CORE_PROCESSES" "$work/processes"
  else
    ps -A -o pid=,ppid=,etime=,stat=,command= | awk '{ line = $0; sub(/^ *[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +/, "", line); print $1 "\t" $2 "\t" $3 "\t" $4 "\t" line }' > "$work/processes"
  fi
  # How to reach each agent: Claude Code's list of its sessions, and where /proc shows them the codex
  # rollout files the processes hold open, "/proc/<pid>/fd<tab><path>"; AI_CORE_AGENTS and
  # AI_CORE_ROLLOUTS name files that stand in for them. A failed list reaches the page as its text.
  if [ -n "${AI_CORE_AGENTS:-}" ]; then
    cp "$AI_CORE_AGENTS" "$work/agents"
  elif command -v claude > /dev/null 2>&1; then
    claude agents --json > "$work/agents" 2> /dev/null || echo 'claude agents --json failed' > "$work/agents"
  else
    : > "$work/agents"
  fi
  if [ -n "${AI_CORE_ROLLOUTS:-}" ]; then
    cp "$AI_CORE_ROLLOUTS" "$work/rollouts"
  elif [ -d /proc ]; then
    # find exits 1 on the processes it may not read, other users' or ended ones; what it read stands
    find /proc -mindepth 3 -maxdepth 3 -path '/proc/*/fd/*' \( -lname '*/rollout-*.jsonl' -o -lname '*/.ai-core/sessions/*.out' \) -printf '%h\t%l\n' > "$work/rollouts" 2> /dev/null || :
  else
    : > "$work/rollouts"
  fi
  # The worktrees the sweep keeps: its dry run in every repository of the folder that has a
  # worktree, each line led by the repository; a sweep that cannot run says so in one line
  : > "$work/trees"
  for repo in "$folder"/*/; do
    repo="${repo%/}"
    [ -e "$repo/.git" ] && [ "$(git -C "$repo" worktree list --porcelain 2>/dev/null | grep '^worktree ' | grep -v -c -E '/\.ai-core/neighbours/|/\.worktrees/[^/]*/origin-')" -gt 1 ] || continue
    if said="$(cd "$repo" && bash "$here/finish-issue.sh" --sweep --dry-run 2>&1)"; then
      while IFS= read -r line; do printf '%s\t%s\n' "${repo##*/}" "$line"; done <<< "$said" >> "$work/trees"
    else
      # The refusal on one line, from its "error: " on where it has one, where git's own lines follow it
      said="$(printf '%s\n' "$said" | tr '\n' ' ' | tr -s ' ' | sed 's/^ *//; s/ *$//')"
      case "$said" in *'error: '*) said="${said#*error: }" ;; esac
      printf '%s\terror: %s\n' "${repo##*/}" "$said" >> "$work/trees"
    fi
  done
  processes=(--processes-file "$work/processes" --agents-file "$work/agents" --rollouts-file "$work/rollouts" --trees-file "$work/trees")
fi

node "$here/../lib/status.mjs" --items-file "$work/items" --columns-file "$work/columns" \
  --board "$(project_org)/$(project_number)" --folder "$folder" --stop-at "$stop" --config-file "$config" \
  ${processes[@]+"${processes[@]}"} ${testing_file[@]+"${testing_file[@]}"} $tokens $issues
