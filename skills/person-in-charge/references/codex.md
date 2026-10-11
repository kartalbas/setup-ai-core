# Codex: the coordinator's commands

Read this only when your tool is Codex. The model and effort come from the `codex` rows of
`.ai-core/models.tsv`; the brief is the filled file from `briefs/`.

## Once per machine

`~/.codex/config.toml` needs `[sandbox_workspace_write] network_access = true`, because every phase
posts its report on the tracker and `workspace-write` cuts the network without it; check it before
the first session and ask the owner where it is missing.

## Start a phase session

In the background, its output in a file of your scratch directory, every worktree of the package
given, because `workspace-write` lets the session write only there:

    codex exec -m <model> -c model_reasoning_effort=<effort> -s workspace-write \
      -C <the package's first worktree> --add-dir <second worktree> [--add-dir ...] \
      --json "$(cat <brief file>)" > <output file>

The thread id stands in the first JSON line of the output. Record it at once in
`~/.ai-core/codex-sessions.tsv` as `<session name>`, a tab, the id, a tab, the output file, because
Codex names nothing itself and your scratch directory dies with you. A session's questions come in
its final message; the brief's `{{how to reach the coordinator}}` is "your final message". Whether
`workspace-write` lets the session push is not measured: a push it reports as refused is yours to
run from the worktree, through the push gate.

A UI test session needs the isolated browser in `~/.codex/config.toml`, once per machine:

    [mcp_servers.chrome-devtools]
    command = "npx"
    args = ["-y", "chrome-devtools-mcp@1.10.1", "--executablePath", "<path of Edge or Chrome>",
            "--headless", "--isolated", "--viewport", "1366x900"]

Run it from an empty throwaway directory with `-s read-only --skip-git-repo-check`.

## Reach, answer, continue, stop

- Answer a running session: `codex queue --thread <thread id> --message "<text>"`.
- Continue a finished one within its phase: `codex exec resume <thread id> "<text>"`.
- A session that finished is done; nothing is kept. Its report is on the issue, its last message in
  the output file of `codex-sessions.tsv`.
- Codex has no command the harness reads for its quota. A session refused for quota ends its phase;
  every phase of this ecosystem waits until a call is answered again.

## Wake yourself for the round

Codex has no timer of its own: the owner starts the coordinator as a loop, `while true; do codex
exec resume <your thread id> "the round"; sleep 600; done`, from the project folder. Your thread id
is the first JSON line of your own start; write it on the plan issue in your first comment.
