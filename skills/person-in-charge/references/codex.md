# Codex: the coordinator's commands

Read this only when your tool is Codex. The model and effort come from the `codex` rows of
`.ai-core/models.tsv`; the brief is the filled file from `briefs/`.

## Start a phase session

In the background, its output in a file of your scratch directory:

    codex exec -m <model> -c model_reasoning_effort=<effort> -s workspace-write \
      -C <the package's worktree> --json "$(cat <brief file>)" > <output file>

A session's questions come in its final message; its brief says so. Whether `workspace-write` lets
the session push is not measured: a push it reports as refused is yours to run from the worktree,
through the push gate.

A UI test session needs the isolated browser in `~/.codex/config.toml`, once per machine:

    [mcp_servers.chrome-devtools]
    command = "npx"
    args = ["-y", "chrome-devtools-mcp@1.10.1", "--executablePath", "<path of Edge or Chrome>",
            "--headless", "--isolated", "--viewport", "1366x900"]

Run it from an empty throwaway directory with `-s read-only --skip-git-repo-check`.

## Reach, answer, continue, stop

- Answer a running session: `codex queue --thread <session id> --message "<text>"`.
- Continue a finished one within its phase: `codex exec resume <session id> "<text>"`.
- A session that finished is done; nothing is kept. Its report is on the issue.
- Codex has no command the harness reads for its quota. A session refused for quota ends its phase;
  every phase of this ecosystem waits until a call is answered again.
