---
name: agy-helper
description: Use for every test, review and test check that a cheaper model can do and you can check cheaply - a live check after a release, a UI check in the browser, a pre-review of a diff before the deciding reviewer, drafting test cases, collecting facts across repositories. Hand it to Gemini through the agy CLI instead of doing it yourself, so the frontier models (Claude, codex) spend fewer tokens; keep your own tokens for judgment and decisions.
---

# How to use Gemini (agy) as your helper

Gemini runs on this machine through the CLI `agy`. Gemini 3.8 Flash has practically unlimited quota,
while Claude and codex tokens are scarce. Give Flash every task whose result you can check cheaply,
and keep your own tokens for judgment and decisions.

## Calling it

    agy -p "<task>" --model gemini-3.8-flash-high [--effort high] [--add-dir <dir>] [--output-format text|json]

- The model is gemini-3.8-flash-high, for every task; for deeper reading raise `--effort`, never
  the model. Gemini 3.1 Pro scores far below 3.8 Flash and is not used.
- Run it from a disposable directory, e.g. `mkdir -p <your scratch dir>/agy/<task> && cd` there.
  Even `--mode plan` is no guarantee that it writes nothing, so never run it inside a real checkout.
  For code reviews give it a detached worktree:
  `git -C <repo> worktree add --detach <scratch>/agy/<name> <sha>`, then `--add-dir` that path, and
  remove the worktree afterwards.
- agy reads nothing of this harness: not the rules, not the maps (AGENTS.md), not the skills, not
  the tracker. Everything the task depends on goes into the prompt: the rules it must keep, the
  facts of the repository, the expected answer shape.

## One agy conversation per session, kept for good

- A session keeps one agy conversation of its own, named after the session (the name other
  sessions message it by): the session `<name>` talks to `agy-<name>`, every time, across tasks
  and restarts. A session that works on the same repositories again and again thus has a helper
  that already knows them, and a call does not pay to teach it again.
- Record the conversation id in `~/.ai-core/agy-conversations.tsv`, one line per session:
  `<session name>`, a tab, the id. Take the id from the first call's `--output-format json`
  output (verify where it appears on that first call). Before a call, read your line; with no
  line, start the conversation and write the line.
- Continue it with `--conversation <id>`. Never use `-c` / `--continue`: it takes the most recent
  conversation of anyone on this user account, which may be another session's.
- One call at a time per conversation; a second task waits for the first answer, or goes to a
  conversation of its own, named `agy-<name>-<task>` and recorded the same way.
- Hand the rules over in the first call of a conversation, and again after a rule changed.

## Browser (live proofs, UI checks)

Check `agy mcp list`. If `chrome-devtools` is missing, add it, with the path of Edge or Chrome on
this machine (`/usr/bin/microsoft-edge-stable` on a Linux machine with Edge):

    agy mcp add chrome-devtools npx -- -y chrome-devtools-mcp@1.10.1 \
      --executablePath <path of Edge or Chrome> --headless --isolated --viewport 1366x900

This drives the browser headless with a throwaway profile per run, so it never sees anyone's
logged-in sessions.

Prompt shape: "Use only the chrome-devtools MCP tools. Open <URL>. <steps>. Expected: <result>.
Reply with what you saw, quote the visible text, and say PASS or FAIL. Change nothing, write no
files."

## What to give Flash

- Live checks after a release: one item, its exact check, PASS or FAIL with what it saw.
- Pre-reviews of a diff before your deciding reviewer. Ask for file:line, the state in which the
  defect appears, and a planted case that would show it. Ask neutrally; never hint at the defect
  you suspect.
- Collecting facts across repositories, such as usages, which change is in which release, or what
  a log says.
- Drafting test cases and checks.

## What Flash does not decide

Security, permissions, data protection, contracts and the release path. There Flash pre-reads, and
your strongest reviewer or the project owner decides. Flash is weak on long multi-step terminal
work, so give it bounded tasks with a clear answer shape.

## Always check its answer

A Flash claim is a lead, not a proof. Before it goes into an issue or a decision, open the
file:line it names, or repeat the one decisive check. When you quote it, say that Flash reported
it and what you verified yourself.

## Rules it inherits from you

- Never put a secret into a prompt, and never let one appear in its output.
- No writes to production data, and no real passwords in the browser.
- agy does no push, release or tracker change. You do those yourself, under your project's rules.
- Your project's own rules apply to everything agy does for you. Paste the relevant ones into the
  prompt.
