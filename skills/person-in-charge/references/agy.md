# agy: the coordinator's commands

Read this only when your tool is agy. The model comes from the `agy` rows of `.ai-core/models.tsv`;
agy's model names carry the effort. The brief is the filled file from `briefs/`.

## Start a phase session

From the package's first worktree, in the background, its output in a file of your scratch
directory, every other worktree of the package named in the brief's worktree lines, because agy
takes no second folder:

    agy -p "$(cat <brief file>)" --model <model> --mode accept-edits --output-format json > <output file>

The conversation id stands in that first answer. Record it in `~/.ai-core/agy-conversations.tsv` as
`<session name>`, a tab, the id, because agy names nothing itself; a helper of that session writes
its own line as `agy-<session name>`, so the two never share one. A session's questions come in its
final message; the brief's `{{how to reach the coordinator}}` is "your final message".

A UI test session needs the isolated browser, once per machine; check `agy mcp list`, and where
`chrome-devtools` is missing:

    agy mcp add chrome-devtools npx -- -y chrome-devtools-mcp@1.10.1 \
      --executablePath <path of Edge or Chrome> --headless --isolated --viewport 1366x900

Run it from an empty throwaway directory, because agy can write files even with `--mode plan`.

## Reach, answer, continue, stop

- Continue a session within its phase: the same command with `--conversation <id>`. Never `-c` or
  `--continue`: it takes the most recent conversation of anyone on this user account.
- One call at a time per conversation; a second task waits for the first answer.
- A finished session is done; nothing is kept. Its report is on the issue, its last message in the
  output file.
- agy has no command the harness reads for its quota. A session refused for quota ends its phase;
  every phase of this ecosystem waits until a call is answered again.

## Wake yourself for the round

agy has no timer of its own: the owner starts the coordinator as a loop, `while true; do agy -p "the
round" --conversation <your id> --model <model>; sleep 600; done`, from the project folder. Your
conversation id is in your first answer; write it on the plan issue in your first comment.
