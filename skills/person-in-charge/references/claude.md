# Claude Code: the coordinator's commands

Read this only when your tool is Claude Code. The model and effort come from the `claude` rows of
`.ai-core/models.tsv`; the brief is the filled file from `briefs/`. A phase assigned to another tool
by a `<tool>:<model>` row or the owner's instruction is started through `references/<tool>.md`; a
Claude coordinator therefore reads `references/codex.md` for a phase it sends to Codex.

## Start a phase session

From the folder the phase works in, with every other folder it needs added, because a session may
edit only inside the folders it was given: a build from the package's first worktree with the other
worktrees added; a plan, a plan check or a review from the first clone the area's issues name, with
the project folder and each partner folder added, so it can read every clone.

    claude "Read <brief file> and do the phase it describes." --bg --name <name> --model <model> \
      --effort <effort> --permission-mode auto --settings '{"autoCompactWindow":<window>}' \
      --add-dir <folder of the brief file> --add-dir <folder> ...

- The prompt comes first, because `--add-dir` takes a list and would read a prompt after it as one
  more folder: the session would start with no input and stand idle. The prompt is one sentence that
  names the brief file, and the brief's folder is one of the added folders, so the session reads it.
- `--bg` starts only where Claude Code trusts the git repository, and the trust of a folder does not
  cover the clones inside it. On "Workspace not trusted", collect every clone your packages need and
  ask the owner once to run `claude` in each; never start the session in another folder instead.
- `<window>` is the session's budget plus 100000, in tokens: `400000` for a `300k` name, `200000`
  for a `100k` name. A session carries its base context before its first word (the system prompt,
  the rules, the skills and the maps, about 70k in a project folder whose rules load at start), and
  the budget is the room for the phase's own work above it. A window of the budget alone leaves a
  100k session about 30k: every compaction frees almost nothing, and Claude Code stops it with
  "Autocompact is thrashing". Claude Code compacts the conversation as it nears the window instead
  of near the model's full window, so the phase's answers stay near its base and budget instead of
  growing toward the full window. A report that says it needed more is a GAP for the next plan.
- Right after the start, subscribe to the session's end: `SendMessage` to `<name>` with no message
  and `notify_when_idle: true`. One notice arrives when it next goes idle or exits, so a phase that
  ends, or stops on a question, wakes you at once instead of at your next round. The subscription
  holds for one notice: subscribe again after you answered a question.
- You run with a 400k window yourself: the owner starts you with
  `--settings '{"autoCompactWindow":400000}'`. A coordinator started without it compacts only near
  its model's full window, and every round re-reads all of it; ask the owner for a restart with it.
- A UI test session gets the isolated browser and nothing else, as one `-p` run from an empty
  throwaway directory, its output into `~/.ai-core/sessions/<session name>.out`, because its last
  message is its report, `--no-session-persistence` keeps nothing, and you post the report on the
  issues. `~/.ai-core/claude-run-settings.json` is the file `ai-core init` writes: the deny list of
  the template, which a `-p` run from a throwaway folder would not otherwise carry:

      claude -p "$(cat <brief file>)" --model <model> --effort <effort> --permission-prompts none \
        --settings "$(jq -c '. + {autoCompactWindow:200000}' ~/.ai-core/claude-run-settings.json)" --strict-mcp-config --no-session-persistence \
        --output-format text \
        --mcp-config '{"mcpServers":{"chrome-devtools":{"command":"npx","args":["-y","chrome-devtools-mcp@1.10.1","--executablePath","<path of Edge or Chrome>","--headless","--isolated","--viewport","1366x900"]}}}' \
        --allowedTools mcp__chrome-devtools > ~/.ai-core/sessions/<session name>.out

  Start it with the Bash tool's `run_in_background`, so its end wakes you.

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
- Stop a session whose phase is done: `claude stop <id>`. Its conversation is kept but never
  resumed; its report is on the issue.

## Wake yourself for the round

`ScheduleWakeup` with 600 seconds and the prompt "the round", once at the end of every round; a
`SendMessage` from a session or a partner, an idle notice and the end of a background run wake you
earlier. The round is the net under them: it finds what none of them reported.

## The usage limit

`ai-core usage --tool claude` reads Claude's last recorded five-hour and weekly windows with their
reset times, even when the calling shell carries another tool's variables; exit 3 means one stands
at `USAGE_STOP_AT` or above, and exit 4 that the five-hour window reaches it before its reset at the
burn measured from `~/.ai-core/usage.log`. One model's own weekly quota is not among the windows: a
session's limit error for a model, or the owner naming its percentage, counts as that limit for that
model's phases.
