#!/usr/bin/env bash
# The one start of a phase session for every tool, and the end of a print run: bin/start-phase.sh is the command,
# bin/watch.sh the reader of the end. Source it after lib/common.sh and lib/tool-order.sh; it runs nothing itself.
#
# A phase session leaves these files in ~/.ai-core/sessions/, all named after the session:
#   <name>.brief.md      the brief the session was given, with the frame this command adds
#   <name>.start.jsonl   the launch attempt, the native identity and, at the end, the end record
#   <name>.out, .err     the output of a print run
#   <name>.pid, .exit    the process of a print run and the status it ended with

START_PHASE_PHASES="plan re-plan plan-check build review ui-test keeper"
START_PHASE_BROWSER_SERVER="chrome-devtools-mcp@1.10.1"
START_PHASE_TMP_SENTENCE='Temporary files go under $TMPDIR (mktemp or $TMPDIR/<name>), never a literal /tmp path.'
START_PHASE_DELETE_SENTENCE='Delete nothing outside your own scratch folders: no prune and no clean of a shared cache or store.'
START_PHASE_PLAN_CHECK_SENTENCE='A plan check repairs what it can in the section itself (a citation, a fact, a point too large moved into its own part) and says GO with REPAIRED lines; it says NO only when the approach is wrong, because a NO pays a whole round.'

start_phase_error() { tool_order_error "$@"; }

start_phase_sessions() { printf '%s/sessions\n' "$TOOL_ORDER_HOME"; }

# The word of a model in a session name, <family><version><tier>: claude-sonnet-5-5 is sonnet5.5, gpt-6-astra is gpt6astra.
start_phase_model_word() {
  local base
  base="$(phase_model_base "$1")"; base="${base#claude-}"
  awk -F- '{
    if ($1 !~ /^[a-z]+$/) exit 1
    word = $1; version = ""; parts = 0; i = 2
    while (i <= NF && $i ~ /^[0-9]+$/) { version = version (parts ? "." : "") $i; parts++; i++ }
    if (parts < 1 || parts > 2) exit 1
    word = word version
    for (; i <= NF; i++) { if ($i !~ /^[a-z]+$/) exit 1; word = word $i }
    print word }' <<< "$base"
}

# The effort of a session name: the effort of the row, or, where the model name carries it (agy), its suffix.
start_phase_effort_word() {
  local effort="$1" model="$2"
  if [ "$effort" = - ]; then effort="$(sed -nE 's/^.*-(low|medium|high|xhigh|max)$/\1/p' <<< "$model")"; fi
  [[ "$effort" =~ ^[a-z]+$ ]] || return 1
  printf '%s\n' "$effort"
}

# start_phase_name <phase> <number> <model> <effort> <budget in thousands>
start_phase_name() {
  local model_word effort_word hex
  model_word="$(start_phase_model_word "$3")" || { start_phase_error "no session name can be made from the model $3"; return 2; }
  effort_word="$(start_phase_effort_word "$4" "$3")" || { start_phase_error "no session name can be made from the effort $4 of the model $3"; return 2; }
  hex="$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n' | cut -c1-5)"
  printf '%s%s-%s-%s-%sk-%s\n' "$1" "$2" "$model_word" "$effort_word" "$5" "$hex"
}

# start_phase_number_used <number>: a session of any phase carries the number already
start_phase_number_used() {
  local file
  for file in "$(start_phase_sessions)"/*; do
    case "${file##*/}" in plan-check"$1"-*|re-plan"$1"-*|ui-test"$1"-*|keeper"$1"-*|plan"$1"-*|build"$1"-*|review"$1"-*) return 0 ;; esac
  done
  return 1
}

# start_phase_measured <phase> <class>: "<seconds><TAB><name of the run>" of the newest end record of the phase and class
# in the start records of the machine, or nothing where no run ended.
start_phase_measured() {
  local file
  for file in "$(start_phase_sessions)"/*.start.jsonl; do
    [ -e "$file" ] || continue
    jq -r --arg phase "$1" --arg class "$2" --arg name "$(basename "$file" .start.jsonl)" \
      'select(type == "object" and .kind == "end" and .phase == $phase and .class == $class and (.ended | type == "number") and (.invoked | type == "number"))
       | "\(.ended)\t\((.ended - .invoked) | floor)\t\($name)"' "$file" 2>/dev/null
  done | sort -t "$(printf '\t')" -k1,1nr | awk -F'\t' 'NR == 1 { print $2 "\t" $3 }'
}

# start_phase_compose_brief <brief> <session name> <phase> <OWNER/REPO#N>: the brief the session reads, on stdout; the session name
# and the issue stand where the brief says {{session name}}, {{session issue repository}} and {{session issue number}}, the frame of
# the harness follows it, and a brief that still holds a placeholder is refused.
start_phase_compose_brief() {
  local text placeholder='\{\{[^}]+\}\}'
  text="$(sed -e "s|{{session name}}|$2|g" -e "s|{{session issue repository}}|${4%%#*}|g" -e "s|{{session issue number}}|${4##*#}|g" "$1")" || return 2
  if [[ "$text" =~ $placeholder ]]; then
    start_phase_error "the brief $1 still holds the placeholder ${BASH_REMATCH[0]}: fill every placeholder before the start"; return 2
  fi
  printf '%s\n\n## The frame of the harness\n\n- %s\n- %s\n' "$text" "$START_PHASE_TMP_SENTENCE" "$START_PHASE_DELETE_SENTENCE"
  if [ "$3" = plan-check ]; then printf -- '- %s\n' "$START_PHASE_PLAN_CHECK_SENTENCE"; fi
}

start_phase_does() { head -n 1 "$1" | sed -E 's/^#+[[:space:]]*//' | cut -c1-200; }

# --- the record --------------------------------------------------------------------------------------------------------

# start_phase_observe <kind> [native identity]: one bounded line of the start record, from the SP_ variables the command sets
start_phase_observe() {
  local line extra='{}'
  [ "$1" != attempt ] || extra="$SP_EXTRA"
  line="$(jq -acn --arg kind "$1" --arg id "${2:-}" --arg operation "$SP_OPERATION" --arg tool "$SP_TOOL" --arg model "$SP_MODEL" \
    --arg effort "$SP_EFFORT" --arg phase "$SP_PHASE" --arg class "$SP_CLASS" --arg writer "$SP_WRITER" --argjson invoked "$SP_INVOKED" \
    --argjson extra "$extra" '{version:1,kind:$kind,operation:$operation,tool:$tool,model:$model,effort:$effort,phase:$phase,class:$class,
      writer:$writer,invoked:$invoked,observed:now,nativeIdentity:$id} + $extra')" || return 2
  [ "${#line}" -lt 4095 ] && printf '%s\n' "$line" >> "$SP_RECORD" \
    || { start_phase_error "cannot append a bounded launch observation: $SP_RECORD"; return 2; }
}

# --- the tools ---------------------------------------------------------------------------------------------------------

start_phase_add_dirs() {  # start_phase_add_dirs: the --add-dir words of every root, one a line
  jq -r '.[] | "--add-dir\n" + .' <<< "$SP_ROOTS"
}

# start_phase_background <cwd> <key tool or empty> <command word>...: the command runs in the background with its output in
# $SP_OUT, its errors in $SP_ERR and its status in $SP_EXIT, and its process is written to $SP_PID. A key is read into the
# environment of that one command by an assignment in front of it: never exported, never in an argument. The run holds none
# of the caller's output, so a caller that reads the output of the start is not held until the run ends.
start_phase_background() {
  local cwd="$1" key="$2"; shift 2
  : > "$SP_OUT"; : > "$SP_ERR"; rm -f "$SP_EXIT"
  (
    set +x
    cd "$cwd" || exit 2
    rc=0
    if [ -n "$key" ]; then
      ANTHROPIC_API_KEY="$(cat "$(tool_order_secret_file "$key")")" "$@" < /dev/null > "$SP_OUT" 2> "$SP_ERR" || rc=$?
    else
      "$@" < /dev/null > "$SP_OUT" 2> "$SP_ERR" || rc=$?
    fi
    printf '%s\n' "$rc" > "$SP_EXIT"
  ) < /dev/null > /dev/null 2>> "$SP_ERR" &
  printf '%s\n' "$!" > "$SP_PID"
  disown
}

start_phase_browser() {
  local candidate
  for candidate in google-chrome google-chrome-stable chromium chromium-browser microsoft-edge microsoft-edge-stable; do
    command -v "$candidate" 2>/dev/null && return 0
  done
  for candidate in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"; do
    [ -x "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
  done
  start_phase_error 'a UI test needs Chrome or Edge, and none is on the PATH or in /Applications'; return 2
}

# Claude Code in the background: --bg returns at once, and the identity of the session is read from claude agents --json.
start_phase_claude_background() {
  local roots=() word window id n agents
  while IFS= read -r word; do roots+=("$word"); done < <(start_phase_add_dirs)
  window=$((SP_BUDGET_K * 1000 + 100000))
  if [ "$SP_OPERATION" = start ]; then
    claude "$SP_PROMPT" --bg --name "$SP_NAME" --model "$SP_MODEL" --effort "$SP_EFFORT" --permission-mode auto \
      --settings "{\"autoCompactWindow\":$window}" --strict-mcp-config --add-dir "$(dirname "$SP_BRIEF")" ${roots[@]+"${roots[@]}"} > /dev/null || return 2
  else
    agents="$(claude agents --json)" || { start_phase_error 'cannot read native Claude evidence'; return 2; }
    jq -e --arg id "$SP_NATIVE_ID" '[.[] | select(.sessionId == $id)] | length == 1 and all(((.status // "") != "busy") and ((.state // "") != "working"))' <<< "$agents" > /dev/null \
      || { start_phase_error "$SP_NAME is running, gone or listed twice: a resume needs one native session that is no longer running"; return 2; }
    claude "$SP_TEXT" --bg --resume "$SP_NATIVE_ID" --model "$SP_MODEL" --effort "$SP_EFFORT" --permission-mode auto \
      --strict-mcp-config ${roots[@]+"${roots[@]}"} > /dev/null || return 2
  fi
  id=''
  for ((n = 0; n < 600; n++)); do
    agents="$(claude agents --json)" || { start_phase_error 'cannot read native Claude evidence'; return 2; }
    id="$(jq -er --arg name "$SP_NAME" '[.[] | select(.name == $name)] | if length == 1 then .[0].sessionId // empty else empty end' <<< "$agents")" && break
    sleep 0.1
  done
  [ -n "$id" ] || { start_phase_error 'missing or ambiguous native Claude identity'; return 2; }
  [ "$SP_OPERATION" != resume ] || [ "$id" = "$SP_NATIVE_ID" ] || { start_phase_error "the resume created a copy of the session: stop that copy ($id) and report it"; return 2; }
  SP_NATIVE="$id"
}

# Claude Code in print mode: a UI test from an empty folder with the isolated browser only, any other phase of a key from the
# project; a key tool asks for JSON, because its report and its cost are read from the result object (the fields `result`,
# `total_cost_usd` and `session_id` of `claude -p --output-format json`, code.claude.com/docs/en/headless).
start_phase_claude_print() {
  local key="$1" format="$SP_OUTPUT" words=() word window settings browser mcp
  window=$((SP_BUDGET_K * 1000 + 100000))
  if [ "$SP_PHASE" = ui-test ]; then
    [ -f "$TOOL_ORDER_HOME/claude-run-settings.json" ] || { start_phase_error "$TOOL_ORDER_HOME/claude-run-settings.json is missing: ai-core init writes it"; return 2; }
    browser="$(start_phase_browser)" || return 2
    settings="$(jq -c --argjson window "$window" '. + {autoCompactWindow:$window}' "$TOOL_ORDER_HOME/claude-run-settings.json")" || return 2
    mcp="$(jq -cn --arg server "$START_PHASE_BROWSER_SERVER" --arg browser "$browser" '{mcpServers:{"chrome-devtools":{command:"npx",
      args:["-y",$server,"--executablePath",$browser,"--headless","--isolated","--viewport","1366x900"]}}}')"
    start_phase_background "$SP_CWD" "$key" claude -p "$(cat "$SP_BRIEF")" --model "$SP_MODEL" --effort "$SP_EFFORT" --permission-prompts none \
      --settings "$settings" --strict-mcp-config --no-session-persistence --output-format "$format" --mcp-config "$mcp" --allowedTools mcp__chrome-devtools
  else
    while IFS= read -r word; do words+=("$word"); done < <(start_phase_add_dirs)
    start_phase_background "$SP_CWD" "$key" claude -p "$SP_PROMPT" --model "$SP_MODEL" --effort "$SP_EFFORT" --permission-mode auto \
      --settings "{\"autoCompactWindow\":$window}" --strict-mcp-config --output-format json --add-dir "$(dirname "$SP_BRIEF")" ${words[@]+"${words[@]}"}
  fi
}

start_phase_codex() {
  local policy=(-p ai-core) added=() word id n alive profile review_policy resume_policy
  while IFS= read -r word; do added+=("$word"); done < <(start_phase_add_dirs)
  if [ "$SP_PHASE" = ui-test ]; then policy=(-s read-only -c 'approval_policy="never"'); fi
  if [ "$SP_OPERATION" = start ]; then
    start_phase_background "$SP_CWD" "" codex exec "${policy[@]}" -m "$SP_MODEL" -c "model_reasoning_effort=$SP_EFFORT" -C "$SP_CWD" --skip-git-repo-check \
      ${added[@]+"${added[@]}"} --json "$SP_PROMPT"
  else
    resume_policy=(-c 'sandbox_mode="workspace-write"' -c 'approval_policy="on-request"' -c 'approvals_reviewer="auto_review"' -c 'sandbox_workspace_write.network_access=false')
    if [ "$SP_PHASE" = ui-test ]; then
      resume_policy=(-c 'sandbox_mode="read-only"' -c 'approval_policy="never"')
    else
      profile="${CODEX_HOME:-$HOME/.codex}/ai-core.config.toml"
      review_policy="$(awk -v quote="$(printf "\047\047\047")" '$0 == "policy = " quote { on=1; next } on && $0 == quote { exit } on { print }' "$profile" 2>/dev/null)"
      [ -n "$review_policy" ] || { start_phase_error "missing review policy: $profile"; return 2; }
      resume_policy+=(-c "auto_review.policy=$(jq -cn --arg policy "$review_policy" '$policy')")
    fi
    start_phase_background "$SP_CWD" "" codex exec resume "$SP_NATIVE_ID" -m "$SP_MODEL" -c "model_reasoning_effort=$SP_EFFORT" --skip-git-repo-check \
      "${resume_policy[@]}" -c "sandbox_workspace_write.writable_roots=$SP_ROOTS" --json "$SP_TEXT"
  fi
  id=''
  for ((n = 0; n < 600; n++)); do
    alive=1; kill -0 "$(cat "$SP_PID")" 2>/dev/null || alive=0
    id="$(head -n 1 "$SP_OUT" | jq -r 'select(.type == "thread.started") | .thread_id // empty' 2>/dev/null)" || :
    [ -z "$id" ] || break
    if [ "$alive" = 0 ]; then start_phase_error "no native thread evidence; Codex exited $(cat "$SP_EXIT" 2>/dev/null || echo unknown): $(tail -n 1 "$SP_ERR")"; return 2; fi
    sleep 0.1
  done
  [ -n "$id" ] || { start_phase_error 'native thread evidence timed out; the attempt remains unknown'; return 2; }
  [ "$SP_OPERATION" != resume ] || [ "$id" = "$SP_NATIVE_ID" ] || { start_phase_error 'the resumed thread identity changed'; return 2; }
  if [ "$SP_OPERATION" = start ]; then printf '%s\t%s\n' "$SP_NAME" "$id" >> "$TOOL_ORDER_HOME/codex-sessions.tsv" || { start_phase_error 'cannot save the thread registry'; return 2; }; fi
  SP_NATIVE="$id"
}

# agy names its conversation in its answer, which exists once the run has ended: the identity is recorded then, by
# start_phase_end.
start_phase_agy() {
  local words=() word conversation=()
  while IFS= read -r word; do words+=("$word"); done < <(start_phase_add_dirs)
  [ "$SP_OPERATION" = start ] || conversation=(--conversation "$SP_NATIVE_ID")
  [ "$SP_PHASE" != ui-test ] || words=()
  start_phase_background "$SP_CWD" "" agy -p "${SP_TEXT:-$SP_PROMPT}" --model "$SP_MODEL" ${conversation[@]+"${conversation[@]}"} --mode accept-edits \
    ${words[@]+"${words[@]}"} --output-format json
}

# --- the end of a print run ------------------------------------------------------------------------------------------

# start_phase_report_text <name> <tool> <output format>: the report a print run gave, from its output file
start_phase_report_text() {
  local out; out="$(start_phase_sessions)/$1.out"
  case "$3" in
    text) cat "$out" ;;
    json) jq -r 'if type == "object" and (.result | type == "string") then .result else error("no result field") end' "$out" ;;
    jsonl) jq -rs '[.[] | select(.type == "item.completed" and .item.type == "agent_message") | .item.text] | if length > 0 then last else error("no agent_message") end' "$out" ;;
  esac
}

# start_phase_end <name> <report URL>: the end record of a session, whose report is on the issue. A background Claude session
# is stopped by its agent id; a print run ended with its process, and an agy run names its conversation only now.
start_phase_end() {
  local name="$1" url="$2" dir record attempt cost='null' id agent
  dir="$(start_phase_sessions)"; record="$dir/$name.start.jsonl"
  attempt="$(jq -c 'select(.kind == "attempt")' "$record" | tail -n 1)"
  if [ "$(jq -r '.tool' <<< "$attempt")" = agy ]; then
    id="$(jq -er '.conversation_id | select(type == "string" and length > 0)' "$dir/$name.out")" \
      || { start_phase_error "missing native conversation evidence in $dir/$name.out"; return 2; }
    if [ "$(jq -r '.operation' <<< "$attempt")" = start ]; then printf '%s\t%s\n' "$name" "$id" >> "$TOOL_ORDER_HOME/agy-conversations.tsv" || return 2; fi
    jq -c --arg id "$id" '{version:1,kind:"native",operation,tool,model,effort,phase,class,writer,invoked,observed:now,nativeIdentity:$id}' <<< "$attempt" >> "$record" || return 2
  fi
  if [ ! -f "$dir/$name.pid" ]; then
    id="$(jq -r 'select(.kind == "native") | .nativeIdentity' "$record" | tail -n 1)"
    agent="$(claude agents --json 2>/dev/null | jq -r --arg id "$id" '[.[] | select(.sessionId == $id)] | .[0].id // empty')"
    [ -z "$agent" ] || claude stop "$agent" > /dev/null || { start_phase_error "claude stop $agent failed"; return 2; }
  elif [ "$(jq -r '.output' <<< "$attempt")" = json ] && [ "$(jq -r '.tool' <<< "$attempt")" != agy ]; then
    cost="$(jq -c '.total_cost_usd | if type == "number" then . else null end' "$dir/$name.out" 2>/dev/null)" || cost=null
  fi
  jq -c --arg url "$url" --argjson cost "$cost" '{version:1,kind:"end",operation:.operation,tool,model,effort,phase,class,writer,invoked,ended:now,report:$url,costUsd:$cost}
    | .duration = (.ended - .invoked)' <<< "$attempt" >> "$record" || return 2
}
