# Codex: the coordinator's commands

Read this only when your tool is Codex. The model and effort come from the `codex` rows of
`.ai-core/models.tsv`; the brief is the filled file from `briefs/`.

## Once per machine

`~/.codex/config.toml` needs `[sandbox_workspace_write] network_access = true`, because every phase
posts its report on the tracker and `workspace-write` cuts the network without it; check it before
the first session and ask the owner where it is missing. `mkdir -p ~/.ai-core/sessions`.

## The coordinator itself

A Codex coordinator is a loop of fresh runs, one per round, that the owner starts from the project
folder; every run reads the tracker as `briefs/coordinator.md` says, does one round and ends, so
nothing of it has to survive:

    while true; do
      codex exec -m <model> -c model_reasoning_effort=<effort> -s workspace-write \
        -C <project folder> --add-dir ~/.ai-core "$(cat .claude/skills/person-in-charge/briefs/coordinator.md)"
      sleep 600
    done

## Start a phase session

In the background, its output in `~/.ai-core/sessions/<session name>.out`, every folder of the
phase given, because `workspace-write` lets the session write only there (a build: the package's
worktrees; a plan, a plan check or a review: the first clone the area's issues name and the project
folder):

    codex exec -m <model> -c model_reasoning_effort=<effort> -s workspace-write \
      -C <first folder> --add-dir <folder> [--add-dir ...] \
      --json "$(cat <brief file>)" > ~/.ai-core/sessions/<session name>.out

The thread id stands in the first JSON line of the output. Record it at once in
`~/.ai-core/codex-sessions.tsv` as `<session name>`, a tab, the id, because Codex names nothing
itself. A session's questions come in its final message, the last line of its output file; the
brief's `{{how to reach the coordinator}}` is "your final message". Whether `workspace-write` lets
the session push is not measured: a push it reports as refused is yours to run from the worktree,
through the push gate.

A UI test session needs the isolated browser in `~/.codex/config.toml`, once per machine:

    [mcp_servers.chrome-devtools]
    command = "npx"
    args = ["-y", "chrome-devtools-mcp@1.10.1", "--executablePath", "<path of Edge or Chrome>",
            "--headless", "--isolated", "--viewport", "1366x900"]

Run it from an empty throwaway directory with `-s read-only --skip-git-repo-check`, its output into
the session's file, and post its report on the issues yourself.

## Reach, answer, continue, stop

- Answer a running session: `codex queue --thread <thread id> --message "<text>"`.
- Continue a finished one within its phase: `codex exec resume <thread id> "<text>"`; it keeps the
  folders of its start.
- A session that finished is done; nothing is kept. Its report is on the issue, its last message in
  its output file.
- Codex has no command the harness reads for its quota. A session refused for quota ends its phase;
  every phase of this ecosystem waits until a call is answered again.
