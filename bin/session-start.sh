#!/usr/bin/env bash
# The session start: what an agent reads before its first action, in a repository or in a
# project folder. It refuses when a team mode is missing, prints the state of the checkout and,
# in a worktree of an issue, that issue's thread.
#
#   session-start.sh [--json] [--tool NAME ...]
#
set -euo pipefail

for arg in "$@"; do
  if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
  echo "Usage: session-start.sh [--json] [--tool NAME ...]"
  echo ""
  echo "The first step of every session. It runs team-modes-check and refuses when a mode is"
  echo "missing; it prints the branch, the uncommitted files, the harness version, the rules and"
  echo "the gh login; in a worktree named issue-N-... it prints the thread of issue N and whether it"
  echo "is assigned to you."
  echo ""
  echo "Options:"
  echo "  -h, --help    Show this help message"
  echo "  --json        Print the same facts as JSON, a refusal too: refused, and the lines of the"
  echo "                team modes"
  echo "  --tool NAME   Check the team modes of this tool only (repeatable); with one tool, the"
  echo "                form the hooks use, the issue thread is cut to fit a hook's output"
  echo ""
  echo "Harness sources use their tracked source inputs and rules, without product assembly."
  echo "Exit status is 1 when a team mode, product rules, or valid source inputs are missing."
  echo ""
  echo "Examples:"
  echo "  ai-core session-start"
  echo "  ai-core session-start --json"
  exit 0
  fi
done

CORE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
as_json=0; tool_args=(); TOOL_N=0
while [ $# -gt 0 ]; do
  case "$1" in
    --json|-Json) as_json=1; shift ;;
    --tool) [ $# -ge 2 ] || { echo "error: --tool needs a value" >&2; exit 2; }; tool_args+=(--tool "$2"); TOOL_N=$((TOOL_N + 1)); shift 2 ;;
    *) echo "error: unknown argument '$1' (see --help)" >&2; exit 2 ;;
  esac
done

# Claude Code starts the hook with the event on standard input, whose "source" is "compact" after a
# compaction (code.claude.com/docs/en/hooks, SessionStart). A summary keeps the work and loses the
# rules, so then the report names every rules file to read again, and bin/pre-tool-use.sh refuses the
# session's calls until it has read them (lib/rules-read.sh). A start that is no compaction clears that
# duty. A terminal passes no event.
AFTER_COMPACTION=0; SESSION_ID=""; SESSION_SOURCE=""
if [ "$TOOL_N" -eq 1 ] && [ ! -t 0 ]; then
  HOOK_INPUT=""; IFS= read -r -t 1 -d '' HOOK_INPUT || true
  SESSION_SOURCE="$(printf '%s' "$HOOK_INPUT" | jq -r '.source? // empty' 2>/dev/null)"
  SESSION_ID="$(printf '%s' "$HOOK_INPUT" | jq -r '.session_id? // empty' 2>/dev/null)"
  [ "$SESSION_SOURCE" != compact ] || AFTER_COMPACTION=1
fi

# 1. The gate: no session without the team modes. team-modes-check prints its own lines and the
#    refusal; nothing else is printed before it. With --json the refusal is JSON too.
if ! modes="$(bash "$CORE/bin/team-modes-check.sh" ${tool_args[@]+"${tool_args[@]}"} 2>&1)"; then
  if [ "$as_json" -eq 1 ]; then
    jq -n --arg lines "$modes" '{refused: true, team_modes: ($lines | split("\n") | map(select(length > 0)))}'
  else
    printf '%s\n' "$modes"
  fi
  exit 1
fi

. "$CORE/lib/layers.sh"
. "$CORE/lib/worktrees.sh"
. "$CORE/lib/rules-read.sh"
if git rev-parse --show-toplevel >/dev/null 2>&1; then
  fast_forward_default_branch "$PWD" || true
fi

# 2. The checkout
ROOT="$(pwd)"
REPO_NAME="$(basename "$ROOT")"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "not-a-git-repo")"
DIRTY_COUNT="$({ git status --porcelain 2>/dev/null || true; } | wc -l | tr -d ' ')"

RULES_PATH=""
if [ -f ".ai-core/rules/rules.md" ]; then
  RULES_PATH=".ai-core/rules/rules.md"
elif [ -f "rules/rules.md" ]; then
  RULES_PATH="rules/rules.md"
fi
RULES_OK=0
[ -n "$RULES_PATH" ] && RULES_OK=1
HARNESS_VERSION=""
[ -f ".ai-core/VERSION" ] && HARNESS_VERSION="$(tr -d '\r\n' < .ai-core/VERSION)"
# The map: an AGENTS.md written by ai-core map names in its first line the commit it came
# from; the distance to HEAD says whether it is current
MAP_COMMIT=""; MAP_BEHIND=""
if [ "$BRANCH" != not-a-git-repo ] && [ -f AGENTS.md ]; then
  MAP_COMMIT="$(head -n1 AGENTS.md | tr -d '\r' | sed -n 's/.*ai-core map: generated [0-9-]* from \([0-9a-f]*\).*/\1/p')"
  [ -z "$MAP_COMMIT" ] || MAP_BEHIND="$(git rev-list --count "$MAP_COMMIT..HEAD" 2>/dev/null || true)"
fi

# The harness this checkout was assembled from (.ai-core/STAMP, one line per layer: name and
# commit) against the clones beside the repositories; and the releases, asked from the origins by
# update --check, unless UPDATE_CHECK is "never" (config.env, or AI_CORE_UPDATE_CHECK in the
# environment). Nothing is updated here; the lines say what to run.
FOLDER="$(project_folder_of "$ROOT")"
# The local rules bind from the project folder and from the checkout, the folder's first; a file
# that is still the template holds none
LOCAL_RULES_PATHS=""
[ "$FOLDER" = "$ROOT" ] || ! holds_local_rules "$FOLDER/.ai-core/rules/rules.local.md" || LOCAL_RULES_PATHS="$FOLDER/.ai-core/rules/rules.local.md"$'\n'
! holds_local_rules .ai-core/rules/rules.local.md || LOCAL_RULES_PATHS="$LOCAL_RULES_PATHS.ai-core/rules/rules.local.md"$'\n'
LOCAL_RULES_OK=0
[ -z "$LOCAL_RULES_PATHS" ] || LOCAL_RULES_OK=1
HARNESS_SOURCE="$(harness_source_of "$ROOT" || true)"
SOURCE_READY=null; SOURCE_ERROR=""; RULE_SOURCES='[]'; READY="$RULES_OK"; SOURCE_RULE_FILES=0; SOURCE_AGENTS=""; SOURCE_RULE_PATHS=""; SOURCE_HOOKS=""
# A harness source is never assembled, and the tool loads AGENTS.md: so in a source that file names
# the rule files where they are written, base layer first, and the tool reads each as it is now. A
# copy would age with the next change of a rule. This file is the one session start writes there,
# only when its text changes, and the clone's exclude file keeps it out of every commit.
write_source_agents() {  # write_source_agents <checkout> <rule directories, one per line>
  local dir file text skills="" exclude
  # A worktree removed under a running session, or the leftover of one, is no place to write
  if [ ! -d "$1" ] || worktree_orphan "$1"; then SOURCE_AGENTS=gone; return 0; fi
  # A source that commits its own AGENTS.md keeps it: that file is somebody's work
  if git -C "$1" ls-files --error-unmatch AGENTS.md >/dev/null 2>&1; then SOURCE_AGENTS=tracked; return 0; fi
  # an import ends at a space, so a space in a path is escaped
  text="<!-- ai-core session-start: written in a harness source at every session start; it names the rule files, it holds none -->
# $HARNESS_SOURCE: a harness source

## Binding rules
- The engineering rules, read where they are written, base layer first; never edited here:"
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    for file in "$dir"/[0-9]*.md; do
      [ -f "$file" ] || continue
      file="${file#"$1"/}"
      text="$text
  - @${file// /\\ }"; SOURCE_RULE_FILES=$((SOURCE_RULE_FILES + 1)); SOURCE_RULE_PATHS="$SOURCE_RULE_PATHS$file"$'\n'
    done
    [ ! -f "$dir/skills.md" ] || { file="${dir#"$1"/}/skills.md"; skills="$skills @${file// /\\ }"; SOURCE_RULE_PATHS="$SOURCE_RULE_PATHS$file"$'\n'; }
  done <<< "$2"
  [ -z "$skills" ] || text="$text
- When a skill or a tool is used:$skills"
  text="$text
- \`ai-core --help\`: every command of the harness, each with its own \`--help\`.
- Where another instruction file, a machine-wide CLAUDE.md among them, names other places for these rules, it is out of date: these files win.
- \`ai-core session-start\` before any work; the README is where to start."
  if [ "$(cat "$1/AGENTS.md" 2>/dev/null)" != "$text" ]; then
    { printf '%s\n' "$text" > "$1/AGENTS.md.$$" && mv "$1/AGENTS.md.$$" "$1/AGENTS.md"; } 2>/dev/null \
      || { rm -f "$1/AGENTS.md.$$"; SOURCE_AGENTS=unwritten; return 0; }
  fi
  SOURCE_AGENTS=written
  git -C "$1" check-ignore -q AGENTS.md 2>/dev/null && return 0
  exclude="$(git -C "$1" rev-parse --git-path info/exclude 2>/dev/null)" || return 0
  case "$exclude" in /*) ;; *) exclude="$1/$exclude" ;; esac
  mkdir -p "$(dirname "$exclude")" || return 0
  # appended after a last line that lacks its newline, the entry would join that line
  [ ! -s "$exclude" ] || [ -z "$(tail -c1 "$exclude")" ] || echo >> "$exclude"
  echo "/AGENTS.md" >> "$exclude"
}
if [ -n "$HARNESS_SOURCE" ]; then
  HARNESS_VERSION="$(tr -d '\r\n' 2>/dev/null < "$CORE/VERSION" || true)"
  SOURCE_READY=false; READY=0
  if source_dirs="$(source_rule_dirs "$ROOT" "$CORE" 2>&1)"; then
    SOURCE_READY=true; READY=1
    RULE_SOURCES="$(printf '%s\n' "$source_dirs" | jq -R -s 'split("\n") | map(select(length > 0))')"
    write_source_agents "$ROOT" "$source_dirs"
  else
    SOURCE_ERROR="$source_dirs"
  fi
  SOURCE_HOOKS=gone
  if [ -d "$ROOT" ] && ! worktree_orphan "$ROOT"; then
    SOURCE_HOOKS="$(arm_claude_hooks "$ROOT" "$CORE" 2>/dev/null)" || SOURCE_HOOKS=unwritten
  fi
fi
HARNESS_CURRENT=true; HARNESS_STAMP=""
if [ -f ".ai-core/STAMP" ]; then
  HARNESS_STAMP="$( { tr -d '\r' < .ai-core/STAMP | grep -v '^$' || true; } | tr '\n' ';' | sed 's/;$//')"
  while read -r lname lcommit; do
    [ -n "$lname" ] || continue
    if [ "$lname" = setup-ai-core ]; then ldir="$CORE"; else ldir="$FOLDER/$lname"; fi
    [ -d "$ldir" ] || continue
    [ "$(git -C "$ldir" rev-parse --short HEAD 2>/dev/null)" = "$lcommit" ] || HARNESS_CURRENT=false
  done < <(tr -d '\r' < .ai-core/STAMP)
else
  HARNESS_CURRENT=false
fi
UPDATE_CHECK="${AI_CORE_UPDATE_CHECK:-}"
[ -n "$UPDATE_CHECK" ] || UPDATE_CHECK="$(config_value_in_file .ai-core/config.env UPDATE_CHECK "")" || exit 1
UPDATE_CHECK="$(printf '%s' "$UPDATE_CHECK" | tr '[:upper:]' '[:lower:]')"
RELEASE_LINES=""; RELEASE_STATE="skipped"   # current | available | unreachable | skipped
if [ "$UPDATE_CHECK" != never ]; then
  rc=0; RELEASE_LINES="$(bash "$CORE/bin/update.sh" --check 2>/dev/null)" || rc=$?
  case $rc in 0) RELEASE_STATE=current ;; 2) RELEASE_STATE=available ;; *) RELEASE_STATE=unreachable ;; esac
fi

GH_LOGGED_IN=0
GH_USER=""
if GH_USER="$(signed_in_user)"; then GH_LOGGED_IN=1; else GH_USER=""; fi

# The thread and the assignment of an issue come from the tracker of the project. The Forgejo tracker runs in Node
# through ai-core and loads no board code; the others run their Bash scripts, as before.
read_issue_thread() {  # read_issue_thread <repository or empty> <number>
  if tracker_is_forgejo; then apart bash "$CORE/bin/ai-core" issue-thread ${1:+"$1"} "$2" --json
  else ( . "$CORE/lib/board.sh"; apart bash "$CORE/bin/issue-thread.sh" ${1:+"$1"} "$2" --json ); fi
}
read_issue_mine() {  # read_issue_mine <repository or empty> <number>
  if tracker_is_forgejo; then bash "$CORE/bin/ai-core" issue-mine ${1:+"$1"} "$2" 2>&1
  else bash "$CORE/bin/issue-mine.sh" ${1:+"$1"} "$2" 2>&1; fi
}
# What the worktree stands for on Forgejo, as worktree_issue of lib/board.sh answers it: a branch or a directory
# named issue-N-... carries issue N, of the repository start-issue recorded on the branch.
forgejo_worktree_issue() {
  local branch named="" repository="" tail
  branch="$(git symbolic-ref --short -q HEAD || true)"
  tail="${branch##*/}"
  case "$tail" in issue-[0-9]*) named="${tail#issue-}"; named="${named%%-*}"; repository="$(git config --get "branch.$branch.issueRepository" 2>/dev/null || true)" ;; esac
  if [ -z "$named" ]; then tail="$(git rev-parse --show-toplevel)"; tail="${tail##*/}"; case "$tail" in issue-[0-9]*) named="${tail#issue-}"; named="${named%%-*}" ;; esac; fi
  case "$named" in *[!0-9]*) named="" ;; esac
  jq -nc --arg named "$named" --arg repository "$repository" '{named: $named, repository: $repository}'
}

# 3. The issue of this worktree: a branch or a directory named issue-N-<slug> carries issue N, of
#    the repository start-issue recorded on the branch where the issue lives in another one.
#    Its thread is read through issue-thread, and issue-mine says whether it is assigned to you.
THREAD=""; THREAD_JSON="null"; ASSIGNED=false; MINE=""; ISSUE_REPO=""; ISSUE_UNREAD=""
# board.sh, and so the tracker, is loaded only for a worktree or branch named like an issue's
case "${BRANCH##*/}:${ROOT##*/}" in
  issue-[0-9]*|*:issue-[0-9]*)
    if tracker_is_forgejo; then WORKTREE_ISSUE="$(forgejo_worktree_issue)"
    else WORKTREE_ISSUE="$(. "$CORE/lib/board.sh"; worktree_issue)"; fi ;;
  *) WORKTREE_ISSUE='{"named":"","repository":""}' ;;
esac
ISSUE="$(jq -r '.named' <<< "$WORKTREE_ISSUE")"
if [ -n "$ISSUE" ]; then
  ISSUE_REPO="$(jq -r '.repository' <<< "$WORKTREE_ISSUE")"
  if THREAD_JSON="$(read_issue_thread "$ISSUE_REPO" "$ISSUE")"; then
    THREAD="$(printf '%s' "$THREAD_JSON" | jq -r '
      "#\(.number) \(.title)",
      "state: \(.state)",
      "labels: \(if (.labels | length) == 0 then "-" else (.labels | join(", ")) end)",
      "",
      .body,
      (.comments[] | "", "--- \(.author) \(.created_at)", .body)')"
  else
    ISSUE_UNREAD="$(grep -m1 . <<< "$THREAD_JSON" || true)"
    THREAD="The thread of ${ISSUE_REPO}#$ISSUE could not be read: $THREAD_JSON"; THREAD_JSON="null"
  fi
  if MINE="$(read_issue_mine "$ISSUE_REPO" "$ISSUE")"; then ASSIGNED=true; fi
fi

# 4. The hook's output is the agent's context, but Claude Code passes a hook's output whole only
#    up to a size: in a measured run of Claude Code 2.1.282, 10 000 characters arrived whole and
#    15 000 arrived as a 2 KB preview, the rest in a file the agent never opens. So for one --tool,
#    the form the hooks use, the text output cuts the issue thread and the list of uncommitted files.
if [ "$TOOL_N" -eq 1 ] && [ "$as_json" -eq 0 ] && [ "${#THREAD}" -gt 3000 ]; then
  THREAD="${THREAD:0:3000}"$'\n'"[the thread goes on: ai-core issue-thread $ISSUE]"
fi

bool() { [ "$1" -eq 1 ] && echo true || echo false; }

if [ "$as_json" -eq 1 ]; then
  printf '%s' "$THREAD_JSON" | jq -n \
    --arg repository "$REPO_NAME" --arg root "$ROOT" --arg branch "$BRANCH" \
    --argjson uncommitted_files "$DIRTY_COUNT" --arg harness_version "$HARNESS_VERSION" \
    --argjson rules_present "$(bool $RULES_OK)" --arg rules_path "$RULES_PATH" \
    --argjson local_rules_present "$(bool $LOCAL_RULES_OK)" \
    --argjson gh_authenticated "$(bool $GH_LOGGED_IN)" --arg gh_user "$GH_USER" \
    --arg map_commit "$MAP_COMMIT" --arg map_behind "$MAP_BEHIND" \
    --argjson harness_current "$HARNESS_CURRENT" --arg harness_stamp "$HARNESS_STAMP" \
    --arg harness_source "$HARNESS_SOURCE" --argjson source_ready "$SOURCE_READY" \
    --arg source_error "$SOURCE_ERROR" --argjson rule_sources "$RULE_SOURCES" --argjson ready "$(bool "$READY")" \
    --arg release_state "$RELEASE_STATE" --arg release_lines "$RELEASE_LINES" \
    --arg issue "$ISSUE" --arg issue_repository "$ISSUE_REPO" --argjson assigned "$ASSIGNED" \
    '{ refused: ($ready | not), repository: $repository, root: $root, branch: $branch, uncommitted_files: $uncommitted_files,
       harness_version: $harness_version, harness_current: (if $harness_source == "" then $harness_current else null end), harness_stamp: $harness_stamp,
       harness_source: (if $harness_source == "" then null else $harness_source end), source_ready: $source_ready,
       source_error: $source_error, rule_sources: $rule_sources,
       release_state: $release_state, release_lines: $release_lines,
       rules_present: $rules_present, rules_path: $rules_path,
       local_rules_present: $local_rules_present,
       gh_authenticated: $gh_authenticated, gh_user: $gh_user,
       map_commit: $map_commit, map_behind: (if $map_behind == "" then null else ($map_behind | tonumber) end),
       issue: (if $issue == "" then null else ($issue | tonumber) end),
       issue_repository: (if $issue_repository == "" then null else $issue_repository end),
       assigned: $assigned, thread: input }'
  exit $((1 - READY))
fi

echo "=================================================="
echo "AI Agent Session Start: $REPO_NAME"
echo "=================================================="
echo "Branch           : $BRANCH"
echo "Uncommitted files: $DIRTY_COUNT"
if [ -n "$HARNESS_SOURCE" ]; then
  echo "Harness version  : $HARNESS_VERSION (command source)"
  echo "Harness source   : $HARNESS_SOURCE"
  echo "Harness state    : $([ "$READY" -eq 1 ] && echo "✓ Source inputs validated (no assembly)" || echo "✗ Invalid source inputs (no assembly)")"
else
  echo "Harness version  : $([ -n "$HARNESS_VERSION" ] && echo "$HARNESS_VERSION" || echo "✗ Missing (.ai-core/VERSION)")"
  echo "Harness state    : $([ "$HARNESS_CURRENT" = true ] && echo "✓ Assembled from the current harness" || echo "✗ Assembled from an older harness (run ai-core init)")"
fi
# A Claude Code started from a terminal opened before the install runs this through the full path in
# its hook, while its own shell does not find ai-core: say how to call it there
if ! command -v ai-core >/dev/null 2>&1; then
  AI_CORE_CMD="$CORE/bin/ai-core"
  echo "ai-core on PATH  : ✗ not in this session; call it as \"$AI_CORE_CMD\", or start the agent from a terminal opened after the install"
fi
case "$RELEASE_STATE" in
  current)     echo "Releases         : ✓ Current" ;;
  available)   echo "Releases         : ! Available (run ai-core update)"; printf '%s\n' "$RELEASE_LINES" | sed 's/^/                   /' ;;
  unreachable) echo "Releases         : – Could not reach an origin"; printf '%s\n' "$RELEASE_LINES" | sed 's/^/                   /' ;;
  skipped)     echo "Releases         : – Not checked (UPDATE_CHECK=never)" ;;
esac
if [ -n "$HARNESS_SOURCE" ]; then
  echo "Rule sources     : $(printf '%s' "$RULE_SOURCES" | jq -r 'join("; ")')"
  case "$SOURCE_AGENTS" in
    written) echo "Rule files       : AGENTS.md names the $SOURCE_RULE_FILES rule files of these sources where they are written" ;;
    tracked) echo "Rule files       : – AGENTS.md is committed here, so session start leaves it as it is" ;;
    unwritten) echo "Rule files       : ✗ AGENTS.md could not be written here, so no rule file of these sources is named to the tool" ;;
    gone) echo "Rule files       : ✗ AGENTS.md was not written: $ROOT is removed or is no worktree, so nothing is written there" ;;
  esac
  case "$SOURCE_HOOKS" in
    written) echo "Claude hooks     : .claude/settings.json now holds every hook of the harness; Claude Code reads them at its next start" ;;
    unchanged) echo "Claude hooks     : ✓ .claude/settings.json holds every hook of the harness" ;;
    tracked) echo "Claude hooks     : – .claude/settings.json is committed here, so session start leaves it as it is" ;;
    unwritten) echo "Claude hooks     : ✗ .claude/settings.json could not be written, so a Claude Code session here runs without the hooks of the harness" ;;
  esac
else
  echo "Rules file       : $([ $RULES_OK -eq 1 ] && echo "✓ Present ($RULES_PATH)" || echo "✗ Missing")"
fi
if [ "$LOCAL_RULES_OK" -eq 1 ]; then echo "Local rules      : ✓ Present ($(printf '%s' "$LOCAL_RULES_PATHS" | paste -sd ';' - | sed 's/;/; /g'))"
elif [ -f .ai-core/rules/rules.local.md ]; then echo "Local rules      : – None (.ai-core/rules/rules.local.md is still the template)"
else echo "Local rules      : – None"; fi
if [ -n "$HARNESS_SOURCE" ]; then echo "Map              : – Harness source: read README.md"
elif [ "$BRANCH" = not-a-git-repo ]; then echo "Map              : – A project folder: AGENTS.md lists its repositories"
elif [ -z "$MAP_COMMIT" ]; then echo "Map              : – Generic (run ai-core map)"
elif [ -z "$MAP_BEHIND" ]; then echo "Map              : ? Generated from $MAP_COMMIT, a commit this clone does not have"
elif [ "$MAP_BEHIND" -eq 0 ]; then echo "Map              : ✓ Generated from $MAP_COMMIT, current"
else echo "Map              : ! Generated from $MAP_COMMIT, $MAP_BEHIND commit(s) behind (run ai-core map)"; fi
if [ "$FORGE" = forgejo ]; then
  FORGE_HOST="$(forge_host 2>/dev/null)" || FORGE_HOST=""
  if [ "$GH_LOGGED_IN" -eq 1 ]; then echo "Forgejo status   : ✓ Authenticated on $FORGE_HOST as @$GH_USER"
  else echo "Forgejo status   : ✗ ${FORGE_HOST:+$FORGE_HOST: }$(not_signed_in_words)"; fi
elif [ "$GH_LOGGED_IN" -eq 1 ]; then
  echo "GitHub status    : ✓ Authenticated as @$GH_USER"
else
  echo "GitHub status    : ✗ Not logged in / gh missing"
fi
echo "=================================================="

if [ "$DIRTY_COUNT" -gt 0 ]; then
  echo "warning: Working directory has $DIRTY_COUNT uncommitted changes:"
  if [ "$TOOL_N" -eq 1 ] && [ "$as_json" -eq 0 ]; then
    git status --short | sed -n 1,20p || true
    [ "$DIRTY_COUNT" -le 20 ] || echo "... and $((DIRTY_COUNT - 20)) more (git status)"
  else
    git status --short
  fi
fi

if [ -n "$ISSUE" ]; then
  echo ""
  echo "This worktree carries issue ${ISSUE_REPO}#$ISSUE. ${MINE}"
  echo ""
  printf '%s\n' "$THREAD"
  echo ""
fi

if [ "$READY" -eq 0 ]; then
  if [ -n "$HARNESS_SOURCE" ]; then printf 'Not ready: source inputs failed validation.\n%s\n' "$SOURCE_ERROR" >&2
  else echo "Not ready: no rules file found. Run ai-core init in this repository." >&2; fi
  exit 1
fi
if [ "$AFTER_COMPACTION" -eq 1 ]; then
  RULES_TO_READ="$(rules_files_to_read "$ROOT" "$SOURCE_RULE_PATHS" "$RULES_PATH" "$LOCAL_RULES_PATHS")"
  echo "After compaction: read every rules file whole again now, before the next step:"
  printf '%s\n' "$RULES_TO_READ" | sed 's/^/  /'
  if rules_unread_record "$SESSION_ID" "$RULES_TO_READ"; then
    echo "Until then every call but the read of one of these files is refused."
  else
    echo "No session id came with the event, so no call is refused until the files are read: this read rests on you."
  fi
elif [ -n "$SESSION_SOURCE" ]; then
  rules_unread_clear "$SESSION_ID"
fi
# A start without the issue it was opened for is not the start it looks like, so the last line says so
if [ -n "$ISSUE_UNREAD" ]; then
  echo "Ready for task execution, but WITHOUT the issue: ${ISSUE_REPO}#$ISSUE could not be read ($ISSUE_UNREAD). Read it with ai-core issue-thread ${ISSUE_REPO:+$ISSUE_REPO }$ISSUE before you start."
else
  echo "Ready for task execution."
fi
