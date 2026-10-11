# Codex: the coordinator's commands

Read this only when your tool is Codex. The model and effort come from the `codex` rows of
`.ai-core/models.tsv`; the brief is the filled file from `briefs/`.

## Every session starts in the project folder

Under `workspace-write` Codex keeps the top-level `.git`, `.agents` and `.codex` of its workspace
read-only, and a worktree's git directory with them. A session started in a worktree therefore
cannot commit; one started in the project folder commits in every clone and worktree under it, and
can add and remove worktrees. Codex also reads `AGENTS.override.md` only from its working directory
up to the git root, and the project folder's carries the rules, the local rules and the skills file.
So every coordinator round and every phase but the UI test starts with `-C <project folder>` and,
because the folder is no git repository, `--skip-git-repo-check`; the brief names the
worktree, and the session reads that repository's `AGENTS.md` there before it works in it.
`~/.ai-core` is writable only with `--add-dir ~/.ai-core`.

## Once per machine

Every session starts with the profile `ai-core` (`-p ai-core`), which `ai-core init` writes into
`~/.codex/ai-core.config.toml`: `workspace-write` with the network closed, and every approval
request, each network call among them, decided by Codex's reviewing subagent against the auto-mode
entries of the harness and the project, the ones Claude Code's classifier reads. A push, a call to
the tracker and an ssh read on a stage therefore each wait for that review; a refusal is the
review's answer, never a reason to start a session without the profile. `mkdir -p ~/.ai-core/sessions`.

Before your first round, check that Codex sees the rules: `codex debug prompt-input hi`, run in
the project folder, prints the prompt the model would get, without a call to it. It holds the heading
`## The code never lies to the person using it` and the project folder's local rules; where it does
not, `ai-core init` has not run here since the harness writes `AGENTS.override.md`, and you start
nothing and tell the owner.

## The coordinator itself

A Codex coordinator is a loop of fresh runs, one per round, that the owner starts from the project
folder; every run reads the tracker as `briefs/coordinator.md` says, does one round and ends, so
nothing of it has to survive:

    while true; do
      codex exec -p ai-core -m <model> -c model_reasoning_effort=<effort> \
        -C <project folder> --skip-git-repo-check --add-dir ~/.ai-core "$(cat .claude/skills/person-in-charge/briefs/coordinator.md)"
      sleep 600
    done

## Start a phase session

In the background, its output in `~/.ai-core/sessions/<session name>.out`, the brief naming the
package's worktrees or clones:

    codex exec -p ai-core -m <model> -c model_reasoning_effort=<effort> \
      -C <project folder> --skip-git-repo-check --add-dir ~/.ai-core \
      --json "$(cat <brief file>)" > ~/.ai-core/sessions/<session name>.out

The thread id stands in the first JSON line of the output. Record it at once in
`~/.ai-core/codex-sessions.tsv` as `<session name>`, a tab, the id, because Codex names nothing
itself. A session's questions come in its final message, the last line of its output file; the
brief's `{{how to reach the coordinator}}` is "your final message". A push is a network call and
goes through the reviewer like every other; one it refuses is a question for the owner.

A UI test session needs the isolated browser in `~/.codex/config.toml`, once per machine:

    [mcp_servers.chrome-devtools]
    command = "npx"
    args = ["-y", "chrome-devtools-mcp@1.10.1", "--executablePath", "<path of Edge or Chrome>",
            "--headless", "--isolated", "--viewport", "1366x900"]

Run it from an empty throwaway directory with `-s read-only --skip-git-repo-check`, its output into
the session's file, and post its report on the issues yourself.

## Ask the owner

Codex has no question dialog, and the owner does not read a round's output. A question for the
owner is a comment on the plan issue (`ai-core issue-comment`): the question in one sentence, the
lettered options with the recommended one first and marked, and the label `needs:owner` on the
issues it holds. The owner answers there; your next round reads the answer.

## Reach, answer, continue, stop

- Answer a running session: `codex queue --thread <thread id> --message "<text>"`.
- Continue a finished one within its phase: `codex exec resume <thread id> "<text>"`; it keeps the
  folders of its start.
- A session that finished is done; nothing is kept. Its report is on the issue, its last message in
  its output file.
- Codex has no command the harness reads for its quota. A session refused for quota ends its phase;
  every phase of this ecosystem waits until a call is answered again.
