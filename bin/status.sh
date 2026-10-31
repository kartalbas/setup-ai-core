#!/usr/bin/env bash
# What runs now, or with --tokens (and where no agent runs) the pace and the forecast;
# lib/status-help.txt says what it prints.

set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/../lib/board.sh"
. "$here/../lib/live-release.sh"
. "$here/../lib/usage.sh"

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
stop="$(usage_stop_at)" || exit 1

work="$(mktemp -d)"; trap 'usage_release; rm -rf "$work"' EXIT
columns="$(fields_tsv)" || exit 1
awk -F'\t' 'tolower($1) == "status" { print $3 }' <<< "$columns" > "$work/columns"
card_rows > "$work/items" || exit 1

# WHAT THE TESTING BLOCK READS OF EACH CARD IN TESTING, one JSON object a line in $work/testing, for lib/status.mjs:
#   {repository, number, pattern, createdAt, context, reason, landing, landingClone, proofs}
# pattern is how a commit message names the issue (issue_mention_pattern), and createdAt is when the issue was
# made: a commit names the issue by its number only from then on (the time rule of issue_commits, which
# lib/status-live.mjs applies again). context says whether the issue was read of the tracker: "read", with landing the
# newest landing record the trusted comments of the issue still hold ({repository, commit, createdAt}, or null
# where there is none), landingClone the clone of its repository, empty where there is none, and proofs the
# trusted "Proven on" comments after that record, [{environment, createdAt}], the environment as
# proof_environment reads it, empty where the first line names none, and an empty list where there is no landing
# record; "failed", with the last line the tracker said, which names what it could not read. One read of the tracker
# per card, as the tracker answers it, at most; a read that fails is that card's line, never the end of the others.
write_testing_records() {
  local column clone repo number created pattern context thread landing reason landing_clone proofs
  column="$(awk 'tolower($0) == "testing" { print; exit }' "$work/columns")"
  : > "$work/testing"
  [ -n "$column" ] || return 0
  # A config.env of a clone that cannot be read stops the page here, before anything else reads it and says so again
  for clone in "$folder"/*/; do
    [ -e "${clone%/}/.git" ] || continue
    live_tags_declaration "${clone%/}" > /dev/null || exit 1
  done
  while IFS=$'\t' read -r repo number created; do
    [ -n "$number" ] || continue
    pattern="$(issue_mention_pattern "$repo" "$number" "$repo")"
    [ "$created" != - ] || created=""
    context="read"; landing=null; reason=""; landing_clone=""; proofs='[]'
    if thread="$( (issue_landing_context "$repo" "$number") 2> "$work/context-error")" \
      && landing="$(jq -c --argjson window "$LANDING_COMMENT_WINDOW" --arg issue "$repo" "$LANDING_RECORD_JQ"'
          (.reopenedAt // "") as $reopenedAt
          | [.comments | .[(0 - $window):] | .[] | trusted] | selected_landing($reopenedAt; $issue)' <<< "$thread" 2> "$work/context-error")" \
      && proofs="$(jq -c --argjson window "$LANDING_COMMENT_WINDOW" --argjson landing "$landing" "$LANDING_RECORD_JQ"'
          [.comments | .[(0 - $window):] | .[] | trusted | select($landing != null and (.body | startswith("Proven on ")) and later(.createdAt; $landing.createdAt))
            | {environment: ((.body | split("\n")[0] | proof_environment) // ""), createdAt: .createdAt}]' <<< "$thread" 2> "$work/context-error")"; then
      [ "$landing" = null ] || landing_clone="$(clone_of "$(jq -r '.repository' <<< "$landing")")"
    else
      reason="$(grep -v '^[[:space:]]*$' "$work/context-error" | tail -n1 | tr -s ' \t' ' ' || true)"
      context="failed"; landing=null; proofs='[]'
      reason="${reason:-the tracker gave no reason}"
    fi
    jq -nc --arg repository "$repo" --argjson number "$number" --arg pattern "$pattern" --arg createdAt "$created" \
      --arg context "$context" --arg reason "$reason" --argjson landing "$landing" --arg landingClone "$landing_clone" --argjson proofs "$proofs" \
      '{repository: $repository, number: $number, pattern: $pattern, createdAt: $createdAt, context: $context, reason: $reason, landing: $landing, landingClone: $landingClone, proofs: $proofs}' >> "$work/testing"
  done <<< "$(jq -r --arg column "$column" 'select(.open and (.repo // "") != "" and ((.status // "") | ascii_downcase) == ($column | ascii_downcase)) | "\(.repo)\t\(.number)\t\(.createdAt // "-")"' "$work/items" | sort -u)"
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
  # The issue each of those worktrees, and each worktree an agent session stands in, belongs to, by its name, each
  # asked in a fresh process inside the worktree, which reads the branch it has checked out. A line is
  # "<worktree path><TAB><number of its issue>", the number empty where its name names no issue.
  : > "$work/worktree-issues"
  { awk -F'\t' '{ print $2 }' "$work/trees" | sed -n 's/^worktree \(.*\): .*, stays$/\1/p'
    jq -r '.[]? | .cwd // empty' "$work/agents" 2> /dev/null | sed 's|/$||' | grep -E '/issue-[0-9]+(-[^/]*)?$' || true
  } | sort -u | while IFS= read -r tree; do
    [ -d "$tree" ] || continue
    info="$(cd "$tree" && bash -c '. "$1/lib/board.sh"; worktree_issue' _ "$here/.." 2> "$work/worktree-issue-error")" || info=""
    if [ -z "$info" ]; then
      echo "status: could not tell the issue of $tree: $(tr -s '\n' ' ' < "$work/worktree-issue-error")" >&2
      printf '%s\t\n' "$tree" >> "$work/worktree-issues"
    else
      printf '%s\t%s\n' "$tree" "$(jq -r '.named' <<< "$info")" >> "$work/worktree-issues"
    fi
  done
  processes=(--processes-file "$work/processes" --agents-file "$work/agents" --rollouts-file "$work/rollouts" --trees-file "$work/trees" --worktree-issues-file "$work/worktree-issues")
fi

# The comments of every plan issue of the board (a card whose title starts with "Plan: packages", open or closed),
# for the tally of review verdicts, one JSON object a line in $work/threads for lib/status.mjs:
#   {repository, number, comments: [{created_at, body}]}   or   {repository, number, failed: the last line the tracker said}
# A thread that cannot be read is that plan issue's line, never the end of the others.
write_review_threads() {
  local repo number thread line reason
  : > "$work/threads"
  while IFS=$'\t' read -r repo number; do
    [ -n "$number" ] || continue
    : > "$work/thread-error"
    if thread="$( (issue_thread "$repo" "$number") 2>> "$work/thread-error")" \
      && line="$(jq -c --arg repository "$repo" --argjson number "$number" '{repository: $repository, number: $number, comments: [.comments[] | {created_at, body}]}' <<< "$thread" 2>> "$work/thread-error")"; then
      printf '%s\n' "$line" >> "$work/threads"
    else
      reason="$(grep -v '^[[:space:]]*$' "$work/thread-error" | tail -n1 | tr -s ' \t' ' ' || true)"
      jq -nc --arg repository "$repo" --argjson number "$number" --arg failed "${reason:-the tracker gave no reason}" '{repository: $repository, number: $number, failed: $failed}' >> "$work/threads"
    fi
  done <<< "$(jq -r 'select((.title // "") | startswith("Plan: packages")) | select((.repo // "") != "") | "\(.repo)\t\(.number)"' "$work/items" | sort -u)"
}

# What the page reads beside the board: the windows of the tool this session runs on, as lib/usage.sh reads them (a
# tool with no reader, and a reading that failed, are in the snapshot, never Claude's figures in their place), and
# the review threads
tool="$(session_tool)"; [ -n "$tool" ] || tool=claude
page_files=()
write_page_files() {
  usage_snapshot "$tool" > "$work/usage.json" || exit 1
  write_review_threads
  page_files=(--usage-file "$work/usage.json" --threads-file "$work/threads")
}
[ -z "$tokens$issues" ] || write_page_files

# LIVE_TAGS and PROOF_HOURS are the project folder's, so a card reads the same from every checkout
run_status() {
  node "$here/../lib/status.mjs" --items-file "$work/items" --columns-file "$work/columns" \
    --board "$(project_org)/$(project_number)" --folder "$folder" --stop-at "$stop" --config-file "$folder/.ai-core/config.env" \
    ${processes[@]+"${processes[@]}"} ${testing_file[@]+"${testing_file[@]}"} ${page_files[@]+"${page_files[@]}"} $tokens $issues
}
rc=0; run_status || rc=$?
# 64: no agent runs, the page needs the windows, and they are read now, not on every call that shows the agents
if [ "$rc" -eq 64 ]; then write_page_files; rc=0; run_status || rc=$?; fi
exit "$rc"
