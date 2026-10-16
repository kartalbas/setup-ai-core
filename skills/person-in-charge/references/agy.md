# agy: the coordinator's commands

Read this when your tool is agy, or when a row of your tool reads `agy:<model>`. The model comes
from the `agy` rows of `.ai-core/models.tsv`, or after `agy:` in your own row; agy's model names
carry the effort, so no `--effort` is given. The brief is the filled file from `briefs/`.

## Measured

On 2026-10-16 `agy -p "<prompt>" --model claude-sonnet-5-5-high --mode accept-edits --output-format
json` ran shell commands with nobody to answer a prompt, wrote a file in its folder, and its JSON
output carried `conversation_id`, `status` and `usage`.

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

From the folder the phase works in, every other folder it needs added, in the background, its
output in `~/.ai-core/sessions/<session name>.out`:

    agy -p "$(cat <brief file>)" --model <model> --mode accept-edits --add-dir <folder> [--add-dir ...] \
      --output-format json > ~/.ai-core/sessions/<session name>.out

The conversation id stands in that first answer. Record it in `~/.ai-core/agy-conversations.tsv` as
`<session name>`, a tab, the id, because agy names nothing itself; a helper of that session writes
its own line as `agy-<session name>`, so the two never share one. A session's questions come in its
final message, the last line of its output file; the brief's `{{how to reach the coordinator}}` is
"your final message".

A UI test session needs the isolated browser, once per machine; check `agy mcp list`, and where
`chrome-devtools` is missing:

    agy mcp add chrome-devtools npx -- -y chrome-devtools-mcp@1.10.1 \
      --executablePath <path of Edge or Chrome> --headless --isolated --viewport 1366x900

Run it from an empty throwaway directory, because agy can write files even with `--mode plan`, its
output into the session's file, and post its report on the issues yourself.

## Reach, answer, continue, stop

- Continue a session within its phase: the same command with `--conversation <id>`. Never `-c` or
  `--continue`: it takes the most recent conversation of anyone on this user account.
- One call at a time per conversation; a second task waits for the first answer.
- A finished session is done; nothing is kept. Its report is on the issue, its last message in its
  output file.
- agy has no command the harness reads for its quota. A session refused for quota ends its phase;
  every phase of this ecosystem waits until a call is answered again.
