# Claude Code: the coordinator's commands

Read this for a Claude tuple from `ai-core phase-model`, from any coordinator. The selected tool,
model and effort govern every start and resume; a Claude coordinator reads `references/codex.md`
or `references/agy.md` when the selection names that tool. The brief is the filled file from `briefs/`.

## Start a phase session

`ai-core start-phase` starts it (`SKILL.md`, "Starting a phase"), from the folder the phase works in, because a session
may edit only inside the folders it was given: a build from the package's first worktree with `--add-dir` for each other
worktree; a plan, a plan check or a review from the first clone the area's issues name, with `--add-dir` for the project
folder and each partner folder, so it can read every clone. The command adds the folder it runs in, `~/.ai-core` and the folder of the brief itself,
and a resume adds the same folders again from the start record.

- `--bg` starts only where Claude Code trusts the git repository, and the trust of a folder does not
  cover the clones inside it. On "Workspace not trusted", collect every clone your packages need and
  ask the owner once to run `claude` in each; never start the session in another folder instead.
- The command sets the session's compact window to its budget plus 100000 tokens: `400000` for a `300k` name, `200000`
  for a `100k` name. A session carries its base context before its first word (the system prompt,
  the rules, the skills and the maps, about 66k in a project folder whose rules load at start,
  measured on 2026-10-26), and the budget is the room for the phase's own work above it. A window of the budget alone leaves a
  100k session about 30k: every compaction frees almost nothing, and Claude Code stops it with
  "Autocompact is thrashing". Claude Code compacts the conversation as it nears the window instead
  of near the model's full window, so the phase's answers stay near its base and budget instead of
  growing toward the full window. A report that says it needed more is a GAP for the next plan.
- A phase session starts with `--strict-mcp-config` and no `--mcp-config`, so none of the account's
  connectors loads and every answer stops paying for their tool names; no brief sends a phase to a
  connector. The rules, the maps, the memory, the skills and the commands stay loaded, so the start
  and the resume carry no flag beyond the ones the command sets: one such as `--safe-mode` or `--bare` skips
  the folder's instruction files or turns off the skills and commands, and a session that cannot
  read the rules breaks them. The UI test below is the one run that starts a browser server.
- Right after the start, subscribe to the session's end: `SendMessage` to `<name>` with no message
  and `notify_when_idle: true`. One notice arrives when it next goes idle or exits, so a phase that
  stops on a question wakes you at once instead of at your next round. The subscription
  holds for one notice: subscribe again after you answered a question.
- You run with a 300k window yourself: the owner starts you with
  `--settings '{"autoCompactWindow":300000}'`. A coordinator started without it compacts only near
  its model's full window, and every round re-reads all of it; ask the owner for a restart with it.
- A UI test session gets the isolated browser and nothing else, as one print run from an empty
  throwaway directory that the command makes, because its last message is its report and nothing of the
  session is kept. `~/.ai-core/claude-run-settings.json` is the file `ai-core init` writes: the deny list of
  the template, which a print run from a throwaway folder would not otherwise carry. Its end is the end of its
  process, and `ai-core watch --session <name>` then posts the report on the issue.

`chrome-devtools-mcp@1.10.1` is a fixed version, never `@latest`; it drives Edge or Chrome headless
with a throwaway profile, so it never sees anyone's logged-in sessions.

## Reach, answer, continue, stop

- List the sessions: `claude agents --json` (name, id, sessionId, state) or `ListAgents`.
- Answer a session: `SendMessage` to its name. A session's questions reach you the same way; the
  brief's `{{how to reach the coordinator}}` is `SendMessage` to your own name, the `-n` name the
  owner started you with.
- A session that stopped before its phase was done continues with `ai-core start-phase --resume <session name> "<text>"`.
  It asks `phase-model` again, passes the selected `--model` and `--effort`, and checks in `claude agents --json` that the
  recorded `sessionId` is not running. It refuses where the selector's tuple changed; then start a fresh session with
  `ai-core start-phase`, the current brief, the saved work and the last report. Never resume a running
  conversation, silently reuse saved model and effort, or send a Claude id to another tool.
- A session whose phase is done is stopped by `ai-core watch --session <name>` once its report is on the issue (`claude stop`
  by the id of its record). Its conversation is kept but never resumed.

## Wake yourself for the round

`ScheduleWakeup` with 600 seconds and the prompt "the round", once at the end of every round; a
`SendMessage` from a session or a partner, an idle notice and the end of a background run wake you
earlier. The round is the net under them: it finds what none of them reported.

A worker that compacts in a loop is busy the whole time, so no idle notice comes. Keep one
`ai-core watch --session <worker name> --still 3600` running in the background (Bash with
`run_in_background`) for every Claude worker of your own number block that runs, one command with
a `--session` for each. It reads the transcripts and its end wakes you with one line when a worker
shows three compactions within 600 seconds or Claude Code's "Autocompact is thrashing" message,
when its deadline has passed, when its report is on the issue (the watch then stops the session),
and with exit 1 when a worker's transcript cannot be found or read. Start it again after each wake and
after each start or end of a worker. It covers Claude sessions only; Codex output files go to
`--file` (`references/codex.md`).

## The usage limit

`ai-core usage --tool claude` reads Claude's last recorded five-hour and weekly windows, shown as
percent used, with their reset times, even when the calling shell carries another tool's variables;
exit 3 means one stands at `USAGE_STOP_AT` or above; the hour a window reaches it, at the burn
measured from `~/.ai-core/usage.log`, is shown and stops no start. One model's own weekly quota is not among the windows: a
session's limit error for a model, or the owner naming its percentage, counts as that limit for that
model's phases.
