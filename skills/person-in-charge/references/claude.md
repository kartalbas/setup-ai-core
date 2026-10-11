# Claude Code: the coordinator's commands

Read this only when your tool is Claude Code. The model and effort come from the `claude` rows of
`.ai-core/models.tsv`; the brief is the filled file from `briefs/`.

## Start a phase session

From the folder the phase works in, with every other folder it needs added, because a session may
edit only inside the folders it was given: a build from the package's first worktree with the other
worktrees added; a plan, a plan check or a review from the first clone the area's issues name, with
the project folder added for the scan and the other clones for the diff.

    claude --bg --name <name> --model <model> --effort <effort> --permission-mode auto \
      --add-dir <folder> [--add-dir ...] "$(cat <brief file>)"

- `--bg` starts only where Claude Code trusts the git repository, and the trust of a folder does not
  cover the clones inside it. On "Workspace not trusted", collect every clone your packages need and
  ask the owner once to run `claude` in each; never start the session in another folder instead.
- No option stops a session at its context budget; the budget is the planner's cut and the name's
  promise, and a report that says it needed more is a GAP for the next plan.
- A UI test session gets the isolated browser and nothing else, as one `-p` run from an empty
  throwaway directory, its output into `~/.ai-core/sessions/<session name>.out`, because its last
  message is its report, `--no-session-persistence` keeps nothing, and you post the report on the
  issues:

      claude -p "$(cat <brief file>)" --model <model> --effort <effort> --permission-prompts none \
        --strict-mcp-config --no-session-persistence --output-format text \
        --mcp-config '{"mcpServers":{"chrome-devtools":{"command":"npx","args":["-y","chrome-devtools-mcp@1.10.1","--executablePath","<path of Edge or Chrome>","--headless","--isolated","--viewport","1366x900"]}}}' \
        --allowedTools mcp__chrome-devtools > ~/.ai-core/sessions/<session name>.out

`chrome-devtools-mcp@1.10.1` is a fixed version, never `@latest`; it drives Edge or Chrome headless
with a throwaway profile, so it never sees anyone's logged-in sessions.

## Reach, answer, continue, stop

- List the sessions: `claude agents --json` (name, id, sessionId, state) or `ListAgents`.
- Answer a session: `SendMessage` to its name. A session's questions reach you the same way; the
  brief's `{{how to reach the coordinator}}` is `SendMessage` to your own name, the `-n` name the
  owner started you with.
- A session that stopped before its phase was done continues with `claude --bg --resume <sessionId>`
  and no other option: Claude Code wakes it under the same id with its saved options. Where the id
  it prints is not the start of `<sessionId>`, Claude Code started a copy: stop the copy.
- Stop a session whose phase is done: `claude stop <id>`. Nothing of it is kept; its report is on
  the issue.

## Wake yourself for the round

`ScheduleWakeup` with 600 seconds and the prompt "the round", once at the end of every round; a
`SendMessage` from a session or a partner wakes you earlier.

## The usage limit

`ai-core usage` reads the five-hour and the weekly window with their reset times; exit 3 means one
stands at `USAGE_STOP_AT` or above. One model's own weekly quota is not among the windows: a
session's limit error for a model, or the owner naming its percentage, counts as that limit for that
model's phases.
