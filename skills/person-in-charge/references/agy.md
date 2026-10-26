# agy: the coordinator's commands

Read this when agy is the execution tool from `ai-core phase-model`, for any coordinator.
Use exactly the selected model; agy's model names carry effort, so there is no `--effort`.
The brief is the filled file from `briefs/`.

## Measured

On 2026-10-16 `agy -p "<prompt>" --model claude-sonnet-5-5-high --mode accept-edits --output-format
json` ran shell commands with nobody to answer a prompt, and its JSON output carried
`conversation_id`. In a session name, the effort is the suffix of the model's name:
`build10003-sonnet5.5-high-300k-afb89` for `claude-sonnet-5-5-high`.

## The coordinator itself

An agy coordinator is a loop of fresh runs, one per round, that the owner starts from the project
folder; every run reads the tracker as `briefs/coordinator.md` says, does one round and ends, so
nothing of it has to survive (`mkdir -p ~/.ai-core/sessions` once):

    while true; do
      agy -p "$(cat .claude/skills/person-in-charge/briefs/coordinator.md)" --model <model> \
        --mode accept-edits --add-dir ~/.ai-core
      sleep 600
    done

## Start a phase session

`phase-model` calls `ai-core usage --tool agy --model MODEL`. The reading shows it as percent
left, against `USAGE_STOP_AT` as percent used, and judges only the selected model's group.
Exit 3 or 4 skips that tool; a failed reading refuses the whole selection. On refusal,
do not start or fall back to another tool. The windows are agy's answer of that moment.

Set `PROJECT`, `PHASE`, `CLASS`, `SESSION` and `BRIEF` to the intended project, model-table
phase word, class, phase session name and filled brief file. Set `WRITER` to the actual writer
for plan-check or review. `SETUP_FILE` is the package's setup file (`SKILL.md`, "Starting a phase"), or empty.
`EXTRA_ROOTS` is the JSON array of every other absolute folder the
phase needs; a UI test gets no folder and runs in the empty `UI_TEST_DIR`. `OPERATION` is
`start` or `resume`; for a resume set `NATIVE_ID` and `TEXT`, after status proves that
conversation is no longer running. The name and original start
stay the same within a phase. Select in the project before entering a UI-test throwaway directory.
A changed tool uses the selected reference for a fresh session with the current brief, saved work
and last report, without the foreign id. A changed order before launch requires a new selection.
This is preflight and detection, not a quota reservation; report the real CLI's later quota refusal.

```bash
set -euo pipefail
cd "$PROJECT"
args=("$PHASE" "$CLASS")
[ -z "${WRITER:-}" ] || args+=(--written-by "$WRITER")
[ -z "${SETUP_FILE:-}" ] || args+=(--setup-file "$SETUP_FILE")
selection="$(ai-core phase-model "${args[@]}")" || exit 2
read -r tool model effort <<< "$selection"
[ "$tool" = agy ] || { printf 'Continue fresh through references/%s.md with the current brief, saved work and last report; no foreign id.\n' "$tool" >&2; exit 2; }
state="${AI_CORE_HOME:-$HOME}/.ai-core"
mkdir -p "$state/sessions"
record="$state/sessions/$SESSION.start.jsonl"
operation="${OPERATION:-start}"
case "$operation" in start|resume) ;; *) echo 'invalid OPERATION' >&2; exit 2 ;; esac
invoked="$(jq -n now)"
observe() {
  line="$(jq -acn --arg kind "$1" --arg id "${2:-}" --arg operation "$operation" --arg tool "$tool" \
    --arg model "$model" --arg effort "$effort" --arg phase "$PHASE" --arg class "$CLASS" --arg writer "${WRITER:-}" \
    --argjson invoked "$invoked" '{version:1,kind:$kind,operation:$operation,tool:$tool,model:$model,effort:$effort,
      phase:$phase,class:$class,writer:$writer,invoked:$invoked,observed:now,nativeIdentity:$id}')" || return 2
  [ "${#line}" -lt 4095 ] && printf '%s\n' "$line" >> "$record" \
    || { echo "cannot append bounded launch observation: $record" >&2; return 2; }
}
out="$state/sessions/$SESSION.out"
conversation=()
if [ "$operation" = resume ]; then
  : "${NATIVE_ID:?set the explicit conversation id}" "${TEXT:?set the continuation}"
  conversation=(--conversation "$NATIVE_ID")
  out="$state/sessions/$SESSION.resume.$invoked.out"
  prompt="$TEXT"
else
  [ ! -e "$out" ] || { echo "output already exists: $out" >&2; exit 2; }
  prompt="$(cat "$BRIEF")"
fi
launch_cwd="$PROJECT"
added=()
if [ "$PHASE" = ui-test ]; then
  launch_cwd="${UI_TEST_DIR:?set the empty throwaway UI_TEST_DIR}"
else
  roots="$(jq -cn --arg project "$PROJECT" --arg state "$state" --argjson extra "${EXTRA_ROOTS:-[]}" '[$project,$state] + $extra')"
  while IFS= read -r root; do added+=(--add-dir "$root"); done < <(jq -r '.[]' <<< "$roots")
fi
observe attempt
(cd "$launch_cwd" && agy -p "$prompt" --model "$model" ${conversation[@]+"${conversation[@]}"} \
  --mode accept-edits ${added[@]+"${added[@]}"} --output-format json < /dev/null > "$out")
id="$(jq -er '.conversation_id | select(type == "string" and length > 0)' "$out")" \
  || { echo 'missing native conversation evidence' >&2; exit 2; }
[ "$operation" != resume ] || [ "$id" = "$NATIVE_ID" ] || { echo 'resumed conversation identity changed' >&2; exit 2; }
if [ "$operation" = start ]; then printf '%s\t%s\n' "$SESSION" "$id" >> "$state/agy-conversations.tsv" || { echo 'cannot save conversation registry' >&2; exit 2; }; fi
observe native "$id"
```

The output file holds the conversation id only once the run has ended: read it from there then, and
record it in `~/.ai-core/agy-conversations.tsv` as `<session name>`, a tab, the id, because agy
names nothing itself; a helper of that session writes its own line as `agy-<session name>`, so the
two never share one. A session's questions come in its final message, the last line of its output
file; the brief's `{{how to reach the coordinator}}` is "your final message".

A UI test session needs the isolated browser, once per machine; check `agy mcp list`, and where
`chrome-devtools` is missing:

    agy mcp add chrome-devtools npx -- -y chrome-devtools-mcp@1.10.1 \
      --executablePath <path of Edge or Chrome> --headless --isolated --viewport 1366x900

Run it from an empty throwaway directory, because agy can write files even with `--mode plan`, its
output into the session's file, and post its report on the issues yourself.

## Reach, answer, continue, stop

- Continue a finished session within its phase with the example's `OPERATION=resume` and its
  explicit `NATIVE_ID`. It selects again and passes `--conversation` and the new model. Never
  `-c` or `--continue`: those use the account's most recent conversation.
- One call at a time per conversation; a second task waits for the first answer.
- A finished session is done; nothing is kept. Its report is on the issue, its last message in its
  output file.
- A native quota refusal remains visible. Ask `phase-model` again before another start or resume;
  use only its successful tuple, with no local fallback.
