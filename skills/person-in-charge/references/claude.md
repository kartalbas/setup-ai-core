# Claude Code: the coordinator's commands

Read this only when your tool is Claude Code. The model and effort come from the `claude` rows of
`.ai-core/models.tsv`; the brief is the filled file from `briefs/`.

## Start a phase session

From the package's worktree (the first repository's, for a plan or a review any folder of the
project):

    claude --bg --name <name> --model <model> --effort <effort> --permission-mode auto "$(cat <brief file>)"

- `--bg` starts only where Claude Code trusts the git repository, and the trust of a folder does not
  cover the clones inside it. On "Workspace not trusted", collect every clone your packages need and
  ask the owner once to run `claude` in each; never start the session in another folder instead.
- A UI test session gets the isolated browser and nothing else, as one `-p` run from an empty
  throwaway directory:

      claude -p "$(cat <brief file>)" --model <model> --effort <effort> --permission-prompts none \
        --strict-mcp-config --no-session-persistence --output-format text \
        --mcp-config '{"mcpServers":{"chrome-devtools":{"command":"npx","args":["-y","chrome-devtools-mcp@1.10.1","--executablePath","<path of Edge or Chrome>","--headless","--isolated","--viewport","1366x900"]}}}' \
        --allowedTools mcp__chrome-devtools

`chrome-devtools-mcp@1.10.1` is a fixed version, never `@latest`; it drives Edge or Chrome headless
with a throwaway profile, so it never sees anyone's logged-in sessions.

## Reach, answer, continue, stop

- List the sessions: `claude agents --json` (name, id, sessionId, state) or `ListAgents`.
- Answer a session: `SendMessage` to its name. A session's questions reach you the same way; its
  brief says so.
- A session that stopped before its phase was done continues with `claude --bg --resume <sessionId>`
  and no other option: Claude Code wakes it under the same id with its saved options. Where the id
  it prints is not the start of `<sessionId>`, Claude Code started a copy: stop the copy.
- Stop a session whose phase is done: `claude stop <id>`. Nothing of it is kept; its report is on
  the issue.

## The usage limit

`ai-core usage` reads the five-hour and the weekly window with their reset times; exit 3 means one
stands at `USAGE_STOP_AT` or above. One model's own weekly quota is not among the windows: a
session's limit error for a model, or the owner naming its percentage, counts as that limit for that
model's phases.
