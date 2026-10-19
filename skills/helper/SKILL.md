---
name: helper
description: Use for a bounded task inside any phase whose answer you can check cheaply - a pre-review of a diff before the deciding reviewer, facts collected across repositories, a log, a screenshot, a long span, drafted test cases. Hand it to the small model of your own tool, the helper row of .ai-core/models.tsv, so your own tokens go to judgment and decisions. It runs no UI test, no build and no deciding review.
---

# How to use the helper of your tool

The helper is the small model of the tool you run in: `.ai-core/models.tsv` names it in the row
`<your tool> helper *`. Each tool is its own ecosystem, so a Claude Code session asks Claude, a
Codex session asks Codex and an agy session asks agy, never another tool. Give the helper every
task whose result you can check cheaply, and keep your own tokens for judgment and decisions.

## Calling it

Run every call from a disposable directory, e.g. `mkdir -p <your scratch dir>/helper/<task> && cd`
there, because a helper can write files even where it was asked not to. For a code review, give it
a detached worktree: `git -C <repo> worktree add --detach <scratch>/helper/<name> <sha>`, name that
path in the task, and remove the worktree afterwards.

- claude, one call per task:

      claude -p "<task>" --model <model> --effort <effort> --permission-prompts none \
        --settings ~/.ai-core/claude-run-settings.json --strict-mcp-config --no-session-persistence --output-format text

  `--settings ~/.ai-core/claude-run-settings.json` carries the deny list of the template (key files
  and `.env` files unread, `git reset --hard` and `git clean` refused), which a call from a
  disposable directory would not otherwise have; `ai-core init` writes the file. The helper
  cannot read any `*.env` file, every `config.env` included, and its Grep tool leaves those files out
  without a word: when the question needs the content of such a file, hand it over in the task.
  `--permission-prompts none` denies whatever would ask a question, so the call never waits at a
  terminal; `--strict-mcp-config` keeps every MCP server of yours out of it, a logged-in browser
  among them. Name the files it reads by absolute path.

- codex, one call per task:

      codex exec -m <model> -c model_reasoning_effort=<effort> -s read-only --skip-git-repo-check \
        -C <the disposable directory> "<task>"

- agy, in one conversation per session (below):

      agy -p "<task>" --model <model> [--add-dir <dir>] --output-format text --conversation <id>

A helper run outside a checkout reads nothing of this harness: not the rules, not the maps
(`AGENTS.md`), not the skills, not the tracker. Everything the task depends on goes into the
prompt: the rules it must keep, the facts of the repository, the expected answer shape.

## agy: one conversation per session, kept for good

- A session keeps one agy conversation of its own, named after the session: the session `<name>`
  talks to `agy-<name>`, every time, across tasks and restarts, so the helper already knows the
  repositories and a call does not pay to teach it again.
- Record the conversation id in `~/.ai-core/agy-conversations.tsv`, one line per session:
  `agy-<session name>`, a tab, the id, under the helper's name, because an agy phase session
  records its own conversation under the bare name. Take the id from the first call's `--output-format json`
  output. Before a call, read your line; with no line, start the conversation and write the line.
- Never use `-c` / `--continue`: it takes the most recent conversation of anyone on this user
  account, which may be another session's.
- One call at a time per conversation; a second task waits for the first answer, or goes to a
  conversation of its own, named `agy-<name>-<task>` and recorded the same way.
- Hand the rules over in the first call of a conversation, and again after a rule changed.

## What to give it

- Pre-reviews of a diff before your deciding reviewer. Ask for file:line, the state in which the
  defect appears, and a planted case that would show it. Ask neutrally; never hint at the defect
  you suspect.
- Collecting facts across repositories, such as usages, which change is in which release, or what
  a log says.
- Reading a screenshot or a long span, and drafting test cases and checks.

## What it does not do

It runs no UI test and no live check: those are a phase of their own, on the ui-test model of the
package's class (the person-in-charge skill). It builds nothing, gives no deciding review and
decides nothing. Security, permissions, data protection, contracts and the release path it may
pre-read; your strongest reviewer or the product owner decides. Give it bounded tasks with a
clear answer shape, never long multi-step terminal work. A task that needs a bigger model is
yours.

## Always check its answer

A helper's claim is a lead, not a proof. Before it goes into an issue or a decision, open the
file:line it names, or repeat the one decisive check. When you quote it, say that the helper
reported it and what you verified yourself. A helper call is not a sub-agent: it needs no ask.

## Rules it inherits from you

- Never put a secret into a prompt, and never let one appear in its output.
- No writes to production data, and no real passwords in a browser.
- A helper does no push, release or tracker change. You do those yourself, under your project's
  rules.
- Your project's own rules apply to everything the helper does for you. Paste the relevant ones
  into the prompt.
