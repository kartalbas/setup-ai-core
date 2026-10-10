---
name: agy-helper
description: Use for every test, review and test check that a cheaper model can do and you can check cheaply - a live check after a release, a UI check in the browser, a pre-review of a diff before the deciding reviewer, drafting test cases, collecting facts across repositories. Hand it to Gemini through the agy CLI instead of doing it yourself, and to Claude Haiku 5.5 where agy has no quota left, so the frontier models (Claude, codex) spend fewer tokens; keep your own tokens for judgment and decisions.
---

# How to use Gemini (agy) as your helper

Gemini runs on this machine through the CLI `agy`. Gemini 3.8 Flash runs on agy's own weekly
quota, apart from the Claude and codex limits, which are scarcer. Give Flash every task whose
result you can check cheaply, and keep your own tokens for judgment and decisions. Where agy has no
quota left, the same tasks go to Claude Haiku 5.5 (see below).

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

## Live check after a release

A live check proves an issue in `testing` against the deployed environment, in a browser. It
starts no test runner and no container on this machine.

**Set up the browser once per machine.** The server is `chrome-devtools-mcp@1.10.1`, a fixed
version, never `@latest`. It drives Edge or Chrome headless with a throwaway profile per run, so
it never sees anyone's logged-in sessions; no browser extension is needed. Use the path of Edge
or Chrome on this machine (`/usr/bin/microsoft-edge-stable` on a Linux machine with Edge).

- agy: check `agy mcp list`; if `chrome-devtools` is missing:

      agy mcp add chrome-devtools npx -- -y chrome-devtools-mcp@1.10.1 \
        --executablePath <path of Edge or Chrome> --headless --isolated --viewport 1366x900

- codex, where a check runs there instead: in `~/.codex/config.toml`

      [mcp_servers.chrome-devtools]
      command = "npx"
      args = ["-y", "chrome-devtools-mcp@1.10.1", "--executablePath", "<path of Edge or Chrome>",
              "--headless", "--isolated", "--viewport", "1366x900"]

**Call it** from an empty throwaway directory, because agy can write files even with
`--mode plan`, in the session's own conversation (see above):

    agy -p "<prompt>" --model gemini-3.8-flash-high --conversation <id> --output-format text

**The prompt always holds:**
1. "Use only the chrome-devtools MCP tools."
2. The prohibitions: change nothing, submit no form, write no file, type no real password; log in
   only with a demo account the prompt names.
3. The check in steps: the URL, each click, what to read.
4. The concrete expected result, taken from the issue's promise.
5. The answer shape:

       RESULT: PASS | FAIL
       SEEN: <the visible text, quoted verbatim>
       URL: <the URL it ended on>
       NOTES: <anything that did not match the steps>

**Then, on the issue:** the result is a lead, not the proof. Check it against the issue's promise,
repeating the one decisive look where the answer leaves doubt. Comment on the issue with what
Flash reported and what you verified yourself ("Flash reported … / verified …"), and only then
close it with `ai-core issue-close`. On FAIL or an unclear answer, comment what was seen, and the
card stays in `testing`.

## What to give Flash

- Live checks after a release, as described above: one item per call, its exact check.
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

## When agy has no quota left: Claude Haiku 5.5

agy's quota is weekly. When agy refuses a call for quota, the same tasks go to Claude Haiku 5.5
(`claude-haiku-5-5`), Anthropic's smallest model at about a twentieth of Sonnet's price, on the
Claude account. Call it from the same kind of throwaway directory, one call per task:

    claude -p "<task>" --model claude-haiku-5-5 --effort medium --permission-prompts none \
      --strict-mcp-config --no-session-persistence --output-format text

- `--permission-prompts none` denies whatever would ask a question, so the call never waits at a
  terminal; `--strict-mcp-config` keeps every MCP server of yours out of it, a logged-in browser
  among them. Name the files it reads by absolute path.
- For a live check in the browser, give it the isolated browser of the setup above and allow only
  its tools:

      --mcp-config '{"mcpServers":{"chrome-devtools":{"command":"npx","args":["-y","chrome-devtools-mcp@1.10.1","--executablePath","<path of Edge or Chrome>","--headless","--isolated","--viewport","1366x900"]}}}' \
      --allowedTools mcp__chrome-devtools

- Give it what you would give Flash, in the same prompt shape, and check its answer the same way.
  It never builds, never gives the deciding review and never decides. For deeper reading raise
  `--effort`; a task that needs a bigger model is yours.
- It is a helper call, not a sub-agent: it needs no ask.

## A worker on agy's Claude models

agy also offers Claude models on its own quota (`agy models`: `claude-opus-5-5-high`,
`claude-sonnet-5-5-high` and their lower efforts). A coordinator may staff a worker tier with them
(the person-in-charge skill). What agy lists is a label, and that the label is the model it
serves is not proven. Such a worker is no helper: it runs in its package's worktree, not in
a throwaway directory, and pushes its issue branch through the push gate. Everything else on this
page is about helper calls.

## Rules it inherits from you

- Never put a secret into a prompt, and never let one appear in its output.
- No writes to production data, and no real passwords in the browser.
- A helper does no push, release or tracker change. You do those yourself, under your project's
  rules.
- Your project's own rules apply to everything agy does for you. Paste the relevant ones into the
  prompt.
