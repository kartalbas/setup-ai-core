#!/usr/bin/env bash
# What runs now, or with --tokens (and where no agent runs) the pace and the forecast;
# lib/status-help.txt says what it prints.

set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/../lib/board.sh"

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
stop="$(grep -E '^[[:space:]]*USAGE_STOP_AT[[:space:]]*=' "$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.ai-core/config.env" 2>/dev/null | tail -n1 || true)"
stop="${stop#*=}"; stop="${stop%%#*}"; stop="${stop//[[:space:]\"\']/}"; stop="${stop:-92}"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
columns="$(fields_tsv)" || exit 1
awk -F'\t' 'tolower($1) == "status" { print $3 }' <<< "$columns" > "$work/columns"
# One card a line, then the cursor of the next page where there is one
cards='(.data.node.items.nodes[] | tojson), (.data.node.items.pageInfo | select(.hasNextPage) | "after \(.endCursor)")'
: > "$work/items"; after=""
while :; do
  out="$(gh_read "the cards of board $(project_number)" api graphql -f pid="$(project_id)" ${after:+-f after="$after"} -f query='
    query($pid:ID!, $after:String) { node(id:$pid) { ... on ProjectV2 {
      items(first:100, after:$after) { pageInfo { hasNextPage endCursor } nodes {
        status: fieldValueByName(name:"Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } }
        priority: fieldValueByName(name:"Priority") { ... on ProjectV2ItemFieldSingleSelectValue { name } }
        content { ... on Issue { number title state closedAt body repository { nameWithOwner }
          parent { number repository { nameWithOwner } } subIssuesSummary { total } } } } } } } }' --jq "$cards")" || exit 1
  grep '^{' <<< "$out" >> "$work/items"
  after="$(sed -n 's/^after //p' <<< "$out")"
  [ -n "$after" ] || break
done

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
    find /proc -mindepth 3 -maxdepth 3 -path '/proc/*/fd/*' -lname '*/rollout-*.jsonl' -printf '%h\t%l\n' > "$work/rollouts" 2> /dev/null || :
  else
    : > "$work/rollouts"
  fi
  processes=(--processes-file "$work/processes" --agents-file "$work/agents" --rollouts-file "$work/rollouts")
fi

node "$here/../lib/status.mjs" --items-file "$work/items" --columns-file "$work/columns" \
  --board "$(project_org)/$(project_number)" --folder "$folder" --stop-at "$stop" \
  ${processes[@]+"${processes[@]}"} $tokens $issues
