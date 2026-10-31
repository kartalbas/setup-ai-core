# agy: the coordinator's commands

Read this when agy is the execution tool from `ai-core phase-model`, for any coordinator.
Use exactly the selected model; agy's model names carry effort, so there is no `--effort`.
The brief is the filled file from `briefs/`.

## Measured

On 2026-10-16 a print run of agy with `--model claude-sonnet-5-5-high --mode accept-edits --output-format
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
used, against `USAGE_STOP_AT` as percent used, and judges only the selected model's group.
Exit 3 skips that tool; a failed reading refuses the whole selection. A projection to the limit
is shown and stops no start. On refusal, do not start or fall back to another tool. The windows
are agy's answer of that moment.

`ai-core start-phase` starts it, from the project folder, with `--add-dir <folder>` for every other folder
the brief lets it write in (`SKILL.md`, "Starting a phase"); a UI test it runs in an empty throwaway
directory, with no folder added.

The output file, `~/.ai-core/sessions/<session name>.out`, holds the conversation id only once the run
has ended. `ai-core watch --session <session name>` follows the run by its process; once it ended, that
watch reads the id, records it in `~/.ai-core/agy-conversations.tsv` as `<session name>`, a tab, the id,
because agy names nothing itself, and posts the last message on the issue under the first line
`Reported by <session name>:`. A helper of that session writes its own line as `agy-<session name>`,
so the two never share one. A session's questions come in its final message, the last line of its output
file; the brief's `{{how to reach the coordinator}}` is "your final message".

A UI test session needs the isolated browser, once per machine; check `agy mcp list`, and where
`chrome-devtools` is missing:

    agy mcp add chrome-devtools npx -- -y chrome-devtools-mcp@1.10.1 \
      --executablePath <path of Edge or Chrome> --headless --isolated --viewport 1366x900

agy can write files even with `--mode plan`, so a UI test never runs in a folder that holds anything.

## Reach, answer, continue, stop

- Continue a finished session within its phase with `ai-core start-phase --resume <session name> "<text>"`.
  It selects again, passes the recorded conversation with `--conversation` and the selected model, and refuses
  where the tuple changed. Never `-c` or `--continue`: those use the account's most recent conversation.
- One call at a time per conversation; a second task waits for the first answer.
- A finished session is done; nothing is kept. Its report is on the issue, its last message in its
  output file.
- A native quota refusal remains visible. Ask `phase-model` again before another start or resume;
  use only its successful tuple, with no local fallback.
