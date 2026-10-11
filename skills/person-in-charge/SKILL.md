---
name: person-in-charge
description: Use when the owner names this session the person in charge (the coordinator) of a project in its tool, Claude Code, Codex or agy. Cuts the open issues into packages by area and contract, runs every package through its phases, each phase in a fresh session on the model and effort .ai-core/models.tsv names for the package's class and the tool, and lands the packages in plan order.
---

# Person in charge

You coordinate: you change no code and run no test yourself, a helper script included. Everything
beyond the coordination this skill names (the tracker, the messages, the plan, and starting,
stopping and landing the phase sessions) goes to a phase session. Your context holds the overview,
so read no source beyond the spans a search returns. The owner talks to you; the sessions report
to you.

## The principles

1. A package is an **area**: one capability as the user meets it, across every repository it
   touches, with its contracts.
2. A **contract scan** runs before the cut. A contract is what one repository reads and another
   ships: a file name, a manifest field, a configuration key, an environment variable, a route.
   Both sides of every contract an issue touches join the package; the additive side lands first,
   the strict side after it.
3. The model and effort follow the package's **class**, not a fixed phase: `.ai-core/models.tsv`
   names them. The strongest model runs only where the class needs it.
4. **One fresh session per package and phase**, ended with the phase. Nothing is compacted and
   continued: the state lives in the tracker and on the branch, and the next phase reads it there.
5. A package is **released as one**: the start check on the bundle that ships together, then the
   test stage, the UI test, production.
6. **No session stands idle and no package waits for a session you could start**: the phases of
   different packages run side by side. A phase never moves to another model, effort or tool
   because a quota ran out: its package waits.

## The ecosystems

Each tool is its own ecosystem with its own coordinator: `claude` (Claude Code), `codex` and
`agy`. You are the coordinator of the tool you run in. You start only that tool's sessions, read
only its rows of `.ai-core/models.tsv`, and never call another tool, as a helper neither. A
package stays in the ecosystem it started in, from its plan to its release.

- `ECOSYSTEM_ORDER` in `.ai-core/config.env` (`claude codex agy` when unset) says which ecosystem
  takes up a new package: the first one in the order whose coordinator runs and has quota. `ai-core status` lists every
  coordinator on the machine under AGENTS ON THIS MACHINE.
- A class without rows of your tool is not your work: such a package waits for the ecosystem that
  has them.
- The owner's yes, which the rules ask for before starting sub-agents, covers the phase sessions
  of its packages. Ask the owner only for what the rules name as the owner's decision, and for
  what only a person can do: a trust prompt, a question at a session's terminal, or a secret, an
  account or a device only the owner holds. Before you hand the owner a task, try it with the
  tools you and your sessions have; the task names what stopped you.

## 1. The classes, the packages and the plan

| Class | Mark (from the scan and the issue text) |
| :--- | :--- |
| `mechanical` | a rename or a text, no contract touched |
| `normal-hard` | everything above mechanical that is not high risk |
| `high-risk` | security, payments, contracts outward, the push gate |

1. Collect every open issue of the project (`ai-core board-list`, or `gh issue list` where a
   repository is on no board). Only an issue with acceptance criteria and `file:line` facts
   joins a package; another one stays in `backlog` with a comment that names what it lacks.
2. The plan phase cuts the packages (section 2): each issue mapped to its files and to the
   contracts it touches, the terms of each contract searched with `ai-core contract-scan TERM...`
   from the project folder, and every repository that holds a side of one joins the package.
   Split a package whose phases would not fit their budgets (section 3).
3. Every package stands in one plan issue per board, titled "Plan: packages", one section each:

       ### Package: <area>
       Ecosystem: <tool>
       Class: <class>
       Repositories: <repo>, <repo>
       Contracts: <term>, <term>
       Issues: <repo>#<number>, ... (in landing order)
       Phase: <phase> - <session name>

   Never make a package a parent issue: an issue has one parent, that parent belongs to its epic,
   and a package would take it away or stay empty. What is not in the plan issue, no fresh
   session knows.
4. A new issue joins an open package that owns its area and has not been released, or goes to
   the next plan phase.

## 2. The phases

| Phase | Done when | The card after it |
| :--- | :--- | :--- |
| plan | the package section stands in the plan issue | `ready` |
| plan check | `ai-core contract-scan --package <repos> <terms>` exits 0 and, outside `mechanical`, a fresh session on the plan-check model found no gap | `planned` |
| build and test | every issue has its commit and its tests, the issue branches are pushed through the push gate | `review` |
| review | a fresh session on the review model read the whole diff and approved it | `review` |
| start check | the project's start check booted the product on the bundle that ships together | `review` |
| land | `ai-core integrate-issue <first number> --reviewed-by <reviewer>` per repository, in plan order, then `ai-core finish-issue <number>` per issue | `testing` |
| UI test and live check | a fresh session on the ui-test model proved each issue's promise on the test stage, then on production | `done` |

- Move the cards with `ai-core issue-status <number>... <column>`; `start-issue` moves the first
  issue to `implementing` as it opens the worktree, and `finish-issue` moves each to `testing`.
- **Plan.** The planner gets the issues, the contract terms and the plan issue; it writes the
  package section and the order. The planner never checks its own plan.
- **Plan check.** The script first: a reader of a contract without its producer in the package is
  a refusal, and the plan goes back. Outside `mechanical`, a fresh session reads the plan against
  the issues' acceptance criteria and names placeholders, contradictions, scope and ambiguity.
- **Build and test.** One session per package, in its worktrees: `ai-core start-issue <first
  number>` in each repository of the package, with the package's first issue there. It writes the
  tests first, from the acceptance criteria, each with a planted defect and a planted innocent
  case, then the code; one commit per issue, naming it.
- **Review.** A fresh session, never on the model that built the package, gets the diff and the
  stated intent, not the conversation, and writes findings. A rejected review starts a fresh build
  session with the findings. After two rejected reviews the package goes back to the plan, not
  into a third build round.
- **Start check.** The project's own start check, as its map or its rules name it, run on the
  bundle that ships together. A project that names none has none: the land step says so in the
  package's record, because a check that does not exist has not passed.
- **Land** in plan order: the additive side of a contract before the strict side, one release per
  repository.
- **UI test and live check.** Section 4. A defect that reaches the test stage or production
  becomes a planted case of a check, in the package that fixes it.

## 3. Starting, continuing and stopping a phase session

Name every session `<issue numbers>-<model>-<effort>-<phase>-<5 hex>`, such as
`612-614-sonnet-5-5-xhigh-build-afb89`: the model as `models.tsv` spells it without a leading
`claude-`, and 5 hex digits that make the name unique. Write it into the package's `Phase:` line
(`ai-core issue-edit`). A session works in its package's worktree by path and never moves to
another folder. Its questions go to you, never into a question dialog, because nobody sits at its
terminal.

| Phase | Context budget |
| :--- | :--- |
| plan, plan check, review | 150k |
| build and test | 300k |
| UI test and live check | 100k |

The budget is what the planner cuts for; nothing measures a running session against it. A session
that has grown past it is not compacted: it finishes the step in hand, commits and reports, and
the planner splits what is left.

- **claude:** `claude --bg --name <name> --model <model> --effort <effort> --permission-mode auto
  "<the brief>"` from the package's worktree. `--bg` starts only where Claude Code trusts the git
  repository, and the trust of a folder does not cover the clones inside it: where it answers
  "Workspace not trusted", collect every clone your packages need and ask the owner once to run
  `claude` in each. List the sessions with `claude agents --json` or `ListAgents`, answer one with
  `SendMessage`, and stop it with `claude stop <id>` once its phase is done. A stopped session
  that must answer within its phase continues with `claude --bg --resume <sessionId>` and no other
  option; where the id it prints is not the start of `<sessionId>`, Claude Code started a copy:
  stop the copy.
- **codex:** `codex exec -m <model> -c model_reasoning_effort=<effort> -s workspace-write -C <the
  package's worktree> --json "<the brief>"`, in the background, its output in a file. Answer it
  with `codex queue --thread <session id> --message "<text>"`; a finished one continues with
  `codex exec resume <session id> "<text>"`. Whether `workspace-write` lets the session reach
  the network for its push is not measured: a push it reports as refused is yours to run.
- **agy:** `agy -p "<the brief>" --model <model> --output-format json` from the package's
  worktree, in the background, its output in a file. Continue it with
  `--conversation <id>`, the id from that first answer. Never use `-c` or `--continue`: it takes
  the most recent conversation of anyone on this user account.

**The brief** of every phase session holds:
- the package section of the plan issue, and the issues in order, each with its acceptance
  criteria;
- the file spans to read, read once, a span re-read only after editing it;
- the paths of the package's worktrees, and that the session works there by `cd` and absolute
  paths;
- that its questions go to you, and how: `SendMessage` (claude), its final message (codex, agy);
- the verification command, run once at the end; where the push gate runs `scripts/check.sh`, the
  push is that run, not a second one before it;
- a report: what changed, what was verified, what in the issues was wrong.

A session of agy or codex reads `AGENTS.md` and `.agents/skills/` of the checkout it runs in; one
that runs outside a checkout reads none of the harness, and its brief carries the rules it must
keep.

## 4. The UI test and the live check

They prove each issue in `testing` on the environment its acceptance criteria name, in a browser.
They start no test runner and no container on this machine. One fresh session per package, on the
ui-test model of the package's class, runs them; the helper of your ecosystem runs none.

**The browser, set up once per machine.** The server is `chrome-devtools-mcp@1.10.1`, a fixed
version, never `@latest`. It drives Edge or Chrome headless with a throwaway profile per run, so it
never sees anyone's logged-in sessions. Use the path of Edge or Chrome on this machine
(`/usr/bin/microsoft-edge-stable` on a Linux machine with Edge).

- claude: pass it per call, and allow only its tools:

      claude -p "<the brief>" --model <model> --effort <effort> --permission-prompts none \
        --strict-mcp-config --no-session-persistence --output-format text \
        --mcp-config '{"mcpServers":{"chrome-devtools":{"command":"npx","args":["-y","chrome-devtools-mcp@1.10.1","--executablePath","<path of Edge or Chrome>","--headless","--isolated","--viewport","1366x900"]}}}' \
        --allowedTools mcp__chrome-devtools

- codex: in `~/.codex/config.toml`

      [mcp_servers.chrome-devtools]
      command = "npx"
      args = ["-y", "chrome-devtools-mcp@1.10.1", "--executablePath", "<path of Edge or Chrome>",
              "--headless", "--isolated", "--viewport", "1366x900"]

- agy: check `agy mcp list`; if `chrome-devtools` is missing:

      agy mcp add chrome-devtools npx -- -y chrome-devtools-mcp@1.10.1 \
        --executablePath <path of Edge or Chrome> --headless --isolated --viewport 1366x900

Run it from an empty throwaway directory, because a session can write files there.

**The brief always holds:**
1. "Use only the chrome-devtools MCP tools."
2. The prohibitions: change nothing, submit no form, write no file, type no real password; log in
   only with a demo account the brief names.
3. The check in steps: the URL, each click, what to read.
4. The concrete expected result, taken from the issue's promise.
5. The answer shape:

       RESULT: PASS | FAIL
       SEEN: <the visible text, quoted verbatim>
       URL: <the URL it ended on>
       NOTES: <anything that did not match the steps>

**Then, on the issue:** check the answer against the issue's promise, repeating the one decisive
look where it leaves doubt. Write the `Proven on <environment>:` record on the issue only when
every check passed, with what the session reported and what you verified yourself; `status-sync`
closes the card at the release of the first environment of `LIVE_TAGS`. On FAIL or an unclear
answer, comment what was seen, and the card stays in `testing`.

## 5. The round

- Every 10 minutes, and wake yourself for it, read `ai-core status`: answer every session it marks
  `blocked` and every report still unanswered, end the sessions whose phase is done, and start
  every phase that is due, across all packages.
- A package waits only for its own previous phase, a decision of the owner's, or a quota. A
  question that is the owner's goes to the owner, and its issues get the label `needs:owner` until
  the answer comes (`ai-core issue-label <number>... --add needs:owner`); the card keeps its
  column.
- Read the TESTING block: prove each card that is live, the 🔴 ones first (section 4). A card that
  is not live waits for the release that carries it. Read the TREES block too: each worktree it
  lists holds work that has not landed or changes nobody committed; land them, or put the removal
  to the owner.

## 6. The usage limit

The account's limits are shared by every session; what is left at the end belongs to your
coordination and the reviews.

- claude: run `ai-core usage` before you start a phase and whenever a session reports. It reads
  the five-hour and the weekly window the status line records, with their reset times; exit 3
  means one stands at the project's limit or above (`USAGE_STOP_AT` in its config.env, 92 % unless
  set). One model's own weekly quota is not among the windows: when a session reports a limit
  error for a model, or the owner names its percentage, treat it as the same limit for that
  model's phases.
- codex and agy: neither has a command the harness reads for its quota. A session refused for
  quota stops its phase; every phase of that ecosystem waits until a call is answered again.
- At the limit, tell every session: finish the step in hand, commit and report it, then wait.
  Start nothing new. Wake yourself at the reset time, check again, and start the due phases once
  every window is below the limit.

## 7. The owner

When the owner asks for the state ("status"), run `ai-core status` once per board (in the project
folder `--project <board>`). It measures the board counts and every agent process on the machine,
with the runs each one started, and under REACH the command that reaches each agent. From that
output and what you know, build the page fresh each time as Markdown the terminal renders, never
in a code block, shaped as a report of state (the rules on working with the product owner):
- the first line: what the owner must do now, or that nothing waits for them; then the usage line;
- the board line, as the command prints it, one per board;
- WHO WORKS ON WHAT: a table, one row per package: its class, its phase, the session and its
  model, the sign of its state, and what comes next. Below the table, the commands that reach the
  sessions, copied from REACH, stand in one code block, one per line, so the owner can copy them.
  A session the command does not show is off and one it marks stopped is suspended, never
  running, and its minutes come from the command, never from memory;
- UP TO <the goal>: the open packages in landing order, each with its phase and next step;
- NEXT TO DONE: the cards that close first, each with an approximate time.
No summary follows the page. `--tokens` prints the usage, the pace and the cost when the owner
asks for them, `--tokens --issues` every open issue. Every question to the owner goes into the
question dialog, the recommended option first, with no option that needs typing.
