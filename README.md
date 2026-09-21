1 for an unknown command |# setup-ai-core

**One harness for every AI coding agent, in every repository, on every machine.**

`setup-ai-core` gives a repository the same rules, the same session start and the same code
intelligence for Claude Code, OpenAI Codex, Google Antigravity, OpenCode, OpenHands, Cursor,
Windsurf, Aider and GitHub Copilot, on Linux, macOS and Windows. A developer installs it once per
machine and runs one command per repository. Nothing of it is ever committed to the repository.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform: Linux | macOS | Windows](https://img.shields.io/badge/Platform-Linux%20%7C%20macOS%20%7C%20Windows-blue)](README.md)
[![check](https://github.com/kartalbas/setup-ai-core/actions/workflows/check.yml/badge.svg)](https://github.com/kartalbas/setup-ai-core/actions/workflows/check.yml)

This README is the only documentation. It describes two things and keeps them apart: **what
exists today** (you can run it) and **what is planned** (the concept, not yet built). Every
section says which one it is.

## Quick start

Once per machine. Windows, in PowerShell 7:

```powershell
irm https://raw.githubusercontent.com/kartalbas/setup-ai-core/main/bin/install.ps1 | iex
```

Linux and macOS:

```bash
curl -sSL https://raw.githubusercontent.com/kartalbas/setup-ai-core/main/bin/install.sh | bash
```

Open a new terminal. `doctor` has run and named what is missing (git, `gh` with its login,
Node.js 20, jq); fix that and nothing else.

Per repository:

```
cd <repository>
ai-core init
ai-core session-start
```

**What `init` does, in this order.** `doctor` installs what is missing (git, `gh`, Node.js, jq,
with winget, brew or apt) and the team modes into your agent tools. If the repository's origin is
`github.com/<org>/<prefix>-<name>`, the project harness `<org>/<prefix>-ai-core` is cloned to
`~/.<prefix>-ai-core`, or **created on GitHub, private, from the skeleton** when it does not exist
yet. The repository gets `.ai-core/` (rules, configuration, docs), the agent files (`AGENTS.md`,
`.claude/settings.json`, `.codex/config.toml`, ...), the skills of the harness in `.claude/skills/`
and `.agents/skills/`, and the agents in `.claude/agents/`, all listed in `.git/info/exclude`.
**A block is written into `.gitignore`, committed and pushed by `init` itself** (a worktree keeps
it for its own commit). Graft wires the agents (files
in the repository, and on the machine `~/.claude/settings.json`, `~/.codex/config.toml`,
`~/.gemini/config/mcp_config.json`) and builds the code graph in `graft/`. The run ends with a
report of every file it created, refreshed, kept or removed. **`ai-core init --dry-run` shows that
report and creates nothing**, on GitHub or on disk; run it first.

Update, on the machine:

```
ai-core update
```

moves setup-ai-core to its newest release (a tag `vX.Y.Z`, cut only when the checks are green on
both runners) and pulls every project harness on this machine; `ai-core update --check` only asks.
Then, in a repository, `ai-core init` brings it to that state and reports what changed.
`ai-core session-start` says when a checkout is behind the harness or a release is available.
Nothing updates by itself.

---

## 1. The problem and the idea

Every AI coding agent reads its instructions from a different file. Codex and OpenCode read
`AGENTS.md`. Cursor reads `.cursorrules`. OpenHands reads a microagent file. Claude Code reads
`AGENTS.md` or `CLAUDE.md`, plus `.claude/settings.json`. Copilot reads
`.github/copilot-instructions.md`. A team that uses several agents ends up with several copies of
the same rules in every repository, and the copies drift apart.

The idea of this harness:

1. **Rules and tools live in a few places, not in every repository.** This public
   repository, **setup-ai-core**, holds what is true for every project. A private **project harness** holds what is
   true for one project. Only the knowledge about one repository is specific to that repository.
2. **A checkout gets an assembled copy.** Agents can only read files inside the repository they
   are started in, so the harness copies the assembled result into `.ai-core/` of every checkout.
3. **Git never sees that copy.** The harness registers every file it deploys in the clone's own
   exclude file (`.git/info/exclude`). `git status` stays clean. The repository's history is never
   touched.
4. **Everything is automated.** Prerequisites are checked and installed. Skills are deployed, not
   installed by hand. Maps of repositories are generated. A rule change reaches every checkout at
   the next session.

```text
setup-ai-core (public)          rules for every project, scripts, templates
        +
<prefix>-ai-core (private harness)     rules, skills, docs and maps of one project
        +
the repository itself                  the code
        ↓  ai-core init assembles
<repo>/.ai-core/ and the pointer files   read by every agent, invisible to git
```

---

## 2. What exists today and what is planned

| Part | Today | Planned |
| :--- | :--- | :--- |
| Install the harness into a checkout with one command | yes: `ai-core init`, after a one-time `install` per machine; `ai-core init --all <folder>` for every repository under a folder | same |
| Nothing is committed to the repository | yes: a block in the project's `.gitignore` names every agent file, and `.git/info/exclude` carries the rest per clone | same |
| Rules for every project | yes: one file per section under `rules/`, 68 rules in 8 sections, assembled into one `rules.md` per checkout | same |
| Rules of one project (private harness) | yes: `github.com/<org>/<prefix>-ai-core`, found from the repository's origin, cloned to `~/.<prefix>-ai-core`, created from a skeleton when missing; its `rules/` add or replace sections, its `skills/`, `docs/`, data files and `repos/<repo>/` are assembled into every checkout; a harness may extend another (section 4.5) | same |
| Skills and team modes | `rules/skills.md` says when to use them; `team-modes.tsv` says how each tool proves a mode is installed and how to install it; `doctor` installs the missing ones, `session-start` refuses a session without them; skill folders of the project harness are deployed into `.claude/skills/` and `.agents/skills/` of every checkout | same |
| Map of a repository (what Graft cannot know) | `repos/<repo>/AGENTS.md` of the project harness, or a generic skeleton until one exists | generated by the developer's agent, four fixed sections |
| Code graph (Graft) | yes: built locally with Node.js, or `init` fails | same |
| Claude Code hooks, status line, permissions, MCP | yes | same, plus a `SessionStart` hook that runs the session start |
| Session start | yes: the team-modes gate, state, versions, rules present, the issue thread of a worktree, exit 1 when not installed | also re-assembles the checkout when a layer changed |
| Issues and the GitHub board | yes: 33 commands over `gh`, from `issue-new` and `start-issue` to `board-sync` and `status-sync` (section 8); the conventions come from three data files a project fills | the data files come from the project harness |
| Prerequisite check and install | yes: `ai-core doctor` checks Git, gh and its login, Bash, PowerShell 7, Node.js 20+, jq, the team modes of the agent tools on the machine, and reports the agent CLIs; installs missing required tools with winget, brew or apt-get; `init` runs it first and deploys nothing while a problem remains | tools a project harness declares |
| Both twins deploy the same files, proven by a test | yes: `tests/check.sh`, CI on Linux and Windows | same |
| Agents that run in a sandbox (OpenHands, cloud agents) | a pointer file only; nothing of the harness reaches a sandbox | rules and skills published to the organisation's `.agents` repository; an optional bootstrap in the repository (section 4.12) |

Section 11 lists the implementation order.

---

## 3. Names

| Name | What it is | Where it comes from |
| :--- | :--- | :--- |
| `setup-ai-core` | this repository, public: the harness every project shares | fixed |
| `<prefix>-ai-core` | the private harness of one project, `github.com/<org>/<prefix>-ai-core` | `prefix` is the repository name up to the first `-`. `shop-web` and `shop-api` both belong to `shop-ai-core`. |
| `ai-core` | the command on the developer's machine | fixed; not a GitHub name |
| `.ai-core/` | the data of the harness inside a checkout: the assembled rules, the configuration, documents. No scripts; those run from the clone as `ai-core <command>`. | fixed |
| `~/.setup-ai-core` | the clone of this repository on a developer's machine (or any clone named with `install --source`); its `bin/` is on the PATH and holds the `ai-core` command and every script. | the repository's name |
| `~/.<prefix>-ai-core` | the clone of a project harness on a developer's machine, next to the one above; `init` clones, pulls or creates it, `update` pulls it | the harness's name |
| the project folder | a folder that is no repository but holds repositories, `~/repos/myorg` for example. `init` equips it too, so an agent started there finds the rules and a list of the repositories. | your layout |

A project harness can extend another one. That is declared in the private harness, not in the
project repository:

```json
{ "extends": "<org>/<other>-ai-core", "setup-ai-core": ">=1.0" }
```

---

## 4. How it works

### 4.1 Layers: setup-ai-core, the project harness, the checkout

```text
setup-ai-core (public)
├── bin/          the ai-core command and every script: install, doctor, init, session-start, graft-setup, and the
│                 board and issue commands (issue-new, start-issue, board-sync, ...)
├── lib/          board.sh and Board.psm1, the library of the board commands; gitignore-block; entry-point.ps1
├── rules/        one file per section (NN-slug.md) and skills.md, generic
├── templates/    the files a checkout gets, in the layout of the checkout, among them the three data files
└── tests/        the check that proves the harness, and one test pair per board command

<org>/<prefix>-ai-core (project harness, private; skeleton/ of this repository is what it starts from)
├── ai-core.json  extends (another harness), setup-ai-core (the version it needs)
├── rules/        one file per section, NN-slug.md: the same name as a generic section replaces it, a new name adds one
├── skills/       one folder per skill, SKILL.md and its files
├── docs/         glossary, naming, architecture for agents
├── config.env, labels.tsv, assignees.tsv, team-modes.tsv   the project's settings and data
└── repos/<repo>/ the map (AGENTS.md) and other files of one repository, in the layout of the checkout

<repo> (project repository)
└── code only
```

Assembly order, later layer wins: setup-ai-core → project harness (base of the `extends` chain first)
→ `repos/<repo>/` of the innermost harness. Section 4.4 says how the harness is found and what
`init` assembles.

### 4.2 What a checkout gets (today)

Data only. The scripts stay in the clone and run as `ai-core <command>` from any directory; a
checkout never carries a copy.

```text
<repo>/
├── .ai-core/
│   ├── VERSION                          managed: version of setup-ai-core
│   ├── rules/rules.md, skills.md        managed: the rules
│   ├── rules/rules.local.md             yours: rules of this repository
│   ├── config.env                       the agents served, Graft on or off, the organisation: managed from the harness, else yours
│   ├── labels.tsv, assignees.tsv        the label taxonomy and who owns which repository's issues: the same
│   ├── team-modes.tsv                   the team modes per tool, with probe and install command: the same
│   ├── docs/                            yours: documents for agents; docs/<harness>/ managed: the docs of each layer
│   ├── STAMP                            managed: the commit of setup-ai-core and of every layer this was assembled from
│   └── solution-path.template.md        yours: template of a solution path
├── .claude/skills/, .agents/skills/     managed: the skills of every layer, one folder each
├── AGENTS.md                            managed from repos/<repo>/ of the harness, else created once from the template
├── .cursorrules, .windsurfrules         Cursor and Windsurf pointers
├── .github/copilot-instructions.md      Copilot pointer
├── .openhands/microagents/repo-rules.md OpenHands microagent
├── .claude/settings.json                Claude Code permissions: Bash(ai-core:*)
├── .codex/config.toml                   Codex: the Graft MCP server, read once the project is trusted
└── graft/                               the code graph, and what graft init wires: .mcp.json,
                                         .claude/helpers/, .claude/skills/graft/, GEMINI.md, ...
```

A project folder gets the same, except that its `AGENTS.md` is generated: the list of the
repositories in it, each with the path of its map, rewritten on every `init` because the folder
changes. Its Graft graph is a workspace over all of them (section 4.8).

**Managed** files are replaced on every run of `init`. Do not edit them; edit the layer they come
from. Every other file is created once and never overwritten. All of it is registered in
`.git/info/exclude`.

### 4.3 Nothing is committed

`init` writes a block into the project's `.gitignore` (`lib/gitignore-block`): every file an agent
or the harness puts into a checkout, `/.ai-core/`, `/graft/`, `/AGENTS.md`, `/.claude/`,
`/.mcp.json`, `/.agents/`, `/GEMINI.md`, the pointer files. The block stands between two marker
lines and is rewritten there on every run; the rest of the file is the project's, a path the
project already ignores is not written twice, and a project that ignores them all gets no block.
`init` commits that `.gitignore` on its own (subject `the agent files of this repository are
ignored`, a `No-issue:` trailer naming `init`) and pushes it by ref to the branch checked out,
through the push gate where the repository carries one; in a worktree it leaves the change for
that worktree's own commit. From then on no clone of the repository commits an agent file, with or
without the harness.

`init` also writes every path it deploys into `.git/info/exclude` of the clone, between two marker
lines, rewritten on every run, which covers the clone before that commit. `graft-setup` writes a second block there with what Graft writes:
`graft/` and the files `graft init` wires into the repository (`GEMINI.md`, `.gemini/settings.json`,
`.claude/skills/graft/SKILL.md`, ...). It compares `git status` before and after Graft, records
whatever a run added, and keeps what earlier runs recorded. In a worktree, git resolves that file to
the main checkout, so all worktrees share it. The project's `.gitignore` is never touched. A file
the repository already tracks stays tracked: an exclude entry never affects a tracked file, and
`init` never overwrites a tracked file. Graft does append to a tracked `AGENTS.md` or
`.github/copilot-instructions.md` when the repository commits one; that cannot be excluded, so
`graft-setup` prints a warning that names the file, and you keep or restore it.

Because the harness is not in the repository, it does not travel with `git clone` or
`git worktree add`. **Every clone and every worktree runs `init` once.** It is idempotent and takes
seconds.

Three files are the repository's own and are committed, because they say what the repository
wants judged: `.githooks/pre-push`, the three-line shim that starts the push gate (section 4.13);
`scripts/check.sh`, the repository's check, with `scripts/check.ps1` as its Windows entry point;
and `.gitleaks.toml`, which arms the credential scan. None of them is written by `init`.

### 4.4 Rules

setup-ai-core keeps its rules as one file per section under `rules/`: `00-how-to-read.md`,
`10-the-code-never-lies.md`, `20-clean-before-fast.md`, `30-done-means-proven.md`,
`40-architecture-configuration-secrets.md`, `50-naming.md`, `60-documentation-and-comments.md`,
`70-working-with-the-product-owner.md`, `80-working-style-for-agents.md` and
`90-the-harness-in-a-repository.md`: 68 rules. Two digits order the files and leave room between
them. They are generic: they name no product, no organisation, no repository and no tool of one
project. `init` assembles them into one `.ai-core/rules/rules.md` in the checkout, each section
headed by a comment that names its source file and the setup-ai-core version, so an agent reads one file
and a person sees where every rule came from.

Every rule ends with an **enforcement tag** that says what holds it:

| Tag | Held by |
| :--- | :--- |
| `[machine]` | a lint, a test or a git hook |
| `[tool]` | a script of this harness |
| `[review]` | the reviewer's checklist |
| `[discipline]` | nothing but the reader |

`rules-check` refuses a rules file in which a rule has no tag. A tag names the intended class; the
setup-ai-core ships tools for `[tool]` rules only.

**Layering.** A project harness keeps the same layout, `rules/NN-slug.md`. `init` merges the section
files of all layers by name: a file in a later layer with the same name replaces the setup-ai-core
section, a new name adds one at the place its number says, and the assembled file heads every
section with the layer and commit it came from, so a reader sees where a rule was made.

### 4.5 The project harness

Every repository of a project shares one private repository, `github.com/<org>/<prefix>-ai-core`,
where `org` and the repository name come from the checkout's `origin` and `prefix` is the name up
to its first dash: `shop-web` and `shop-api` both belong to `shop-ai-core`. Nothing is configured.
`init` finds it this way:

1. The clone `~/.<prefix>-ai-core` exists: its origin is checked against the name and it is pulled
   (offline, it is used as it is).
2. It exists on GitHub: cloned there, through `gh`.
3. It exists nowhere: created, private, from `skeleton/` of this repository plus the four data
   files, and pushed, through `gh repo create`. The first developer of a project gets the harness
   made for them; without the right to create it, `init` says so and the checkout gets the generic
   harness only.

A harness may extend another: `ai-core.json` `{"extends": "<org>/<name>-ai-core"}`, a company
harness under several projects for example. The chain is resolved base first, a circle or more
than eight layers is refused, and `"setup-ai-core": ">=1.1.0"` in `ai-core.json` stops `init` when
the clone of this repository is too old for the harness.

Then `init` assembles the checkout, later layer wins: the rules as above; `rules/skills.md` of the
last layer that has one; every `skills/<name>/` into `.claude/skills/<name>/` and
`.agents/skills/<name>/`; every `agents/<name>.md` into `.claude/agents/`; every `docs/` into
`.ai-core/docs/<harness>/`; `config.env`,
`labels.tsv`, `assignees.tsv` and `team-modes.tsv` into `.ai-core/`; and every file under
`repos/<repo>/` of the innermost harness over the checkout, in its own layout, so
`repos/shop-web/AGENTS.md` is the map of shop-web and `repos/shop-web/.ai-core/config.env` its
configuration. A file the repository tracks is never overwritten. `.ai-core/STAMP` records the
commit of setup-ai-core and of every layer the checkout was assembled from.

A project folder (section 5.8) gets the layers every repository under it shares: the company
harness when the repositories belong to different projects that extend it, the project harness when
they all belong to one. `init` on a checkout of a harness itself is refused; the harness is edited
like any repository and reaches every checkout at the next `init`, and `ai-core update` pulls every
harness clone on the machine.

Changing what agents read is therefore: edit a file under `~/.<name>-ai-core`, then `ai-core push`,
which commits what changed in every harness clone on the machine with the message you give (or
the names of the files), pulls with rebase, pushes, and refreshes the checkout you stand in.
Nothing is copied by hand, nothing is committed to a project repository, and a new developer runs
`install` and `init`.

### 4.6 Skills

A skill is a folder with a `SKILL.md` inside: instructions in prose, sometimes with scripts. A CLI
loads every skill it finds in its skill directories when it starts; there is no activation step.
Claude Code loads `.claude/skills/<name>/` in the repository and `~/.claude/skills/` on the
machine. Codex, Antigravity and OpenHands load `.agents/skills/<name>/` in the repository. OpenHands also
loads the skills of a repository named `.agents` under the GitHub organisation, for every
repository of that organisation, and `~/.agents/skills/` on a developer's machine.

**Today** `rules/skills.md` says when an agent uses the three team modes, `caveman`, `ponytail`
and `i-have-adhd`, and `.ai-core/team-modes.tsv` says, per tool, how the harness sees that a mode
is installed (a plugin the tool lists, a skill folder, a file) and the command that installs it.
`ai-core team-modes-check` probes the tools on the machine and refuses when a mode is missing;
`session-start` and `start-issue` run it first, so no session starts without the modes;
`ai-core team-modes-install` runs the install column for every missing one, and `doctor` runs it
for the tools on the machine, so `install` and `init` leave the modes installed; a plugin loads when
the tool starts, so the tool is restarted once. The project's own skills are folders in the project
harness, `skills/<name>/SKILL.md`, and `init` copies them into `.claude/skills/` and
`.agents/skills/` of every checkout, where Claude Code, Codex, Antigravity and OpenHands find them
on start; no developer installs a skill by hand.

### 4.7 Maps: what Graft cannot know

Graft knows what is in the code: where a symbol is, who calls it, what a file exposes, how the
repository is laid out. It is always current. A **map** says only what is not in the code, in
four sections:

1. **Purpose and boundaries** — what this repository is, what it is not, its role in the project.
2. **Commands** — build, test, the one verification command, release.
3. **Rules of this repository** — where to add what and nowhere else, what never to touch.
4. **Pointers** — use Graft instead of reading files; where the docs and the glossary are.

No directory trees and no symbol lists: Graft owns those.

**Today** `AGENTS.md` is a generic skeleton with the rules contract and the operations table.
**Planned:** `ai-core map` generates sections 1, 2 and 4 with the developer's agent CLI, running
non-interactively over the Graft index, the README, the build files and `git log`. Section 3 is
written by people and never touched by generation. The map lives in the project harness under
`repos/<repo>/AGENTS.md`, is committed and pushed there, and is generated at `init` when missing
and refreshed when older than a number of commits. A separate `CLAUDE.md` is not needed: Claude
Code reads `AGENTS.md`.

### 4.8 Graft: the code graph

`graft-setup` runs `npx -y @nanonets/graft init --agents ... --no-build` for the agents named
in `AGENTS` of `config.env` (`-y`, every agent Graft detects, when the list is empty), without
the interactive picker, and then `build` with the Node.js on the machine, which writes
`graft/index.md` and the graph. That is the
only way it runs. If `npx` is
missing or the build fails, the script exits 1 and says why, and `init` exits 1 with it. Nothing
is installed on the system and nothing runs in a container. A repository that does not want the
graph sets `GRAFT_EXECUTION_MODE="skip"` in `.ai-core/config.env`. Graft's output is kept and
shown whole only when it fails; what it wrote is reported afterwards as two lists, the files in
the repository and the files on the machine, with a line for the graph (section 5.5).
`ai-core graft --dry-run` (`-DryRun`) prints what `graft init` would write, in the repository
and on the machine, and builds nothing.

Agents use the graph in two ways: the Markdown index `graft/index.md`, and the MCP server in
`.mcp.json`, which Claude Code starts as `npx -y @nanonets/graft mcp`. That is a process over
stdin and stdout, started and stopped with the Claude Code session. No port, no service.

`graft/` is never committed: it changes with every commit, its cache differs per machine, and
`init` rebuilds it in a minute.

In a project folder Graft builds a **workspace**: it wires and builds every repository directly
under the folder and writes `graft/workspace.json` there, one graph over all of them. `graft ask`
and the MCP server started in that folder answer across repositories, each hit labelled with its
repository. That is what an agent started in the folder gets; an agent started in one repository
gets that repository's own graph.

`graft init` also writes outside the repository, once per machine: the Graft MCP server and hooks
for Codex (`~/.codex/config.toml`, `~/.codex/hooks.json`), Claude Code (`~/.claude.json`,
`~/.claude/settings.json`) and Antigravity (`~/.gemini/config/mcp_config.json`,
`~/.gemini/skills/graft/`). A config file it cannot parse, an empty one for example, is reported as
`skipped-unparseable` and left alone: put `{}` into it and run `ai-core graft` once. Graft sends
anonymous usage statistics unless `npx -y @nanonets/graft telemetry disable` was run on the machine
(or `DO_NOT_TRACK=1` is set).

### 4.9 The session start

`ai-core session-start` is the first step of every session, run in the repository or in the
project folder. `AGENTS.md`, the OpenHands microagent and the rules say so; Claude Code will run
it through a `SessionStart` hook (planned), every other agent runs it because the instruction says
so. It runs `team-modes-check` first and stops with its refusal when a mode is missing. Then it
prints:

```text
Branch           : main
Uncommitted files: 0
Harness version  : 1.2.0
Rules file       : ✓ Present (.ai-core/rules/rules.md)
Local rules      : ✓ Present (.ai-core/rules/rules.local.md)
Graft code graph : ✓ Indexed (graft/index.md)
GitHub status    : ✓ Authenticated as @you
Ready for task execution.
```

In a project folder the branch line says `not-a-git-repo` and the Graft line `✓ Workspace
(graft/workspace.json)`.

In a worktree named `issue-N-<slug>`, the shape `start-issue` creates, it also prints the thread
of issue N, read through `issue-thread`, and whether the issue is assigned to you (`issue-mine`).

With `--json` / `-Json` it prints the same as JSON, with the same keys and types on both
platforms: `repository`, `root`, `branch`, `uncommitted_files`, `harness_version`,
`rules_present`, `rules_path`, `local_rules_present`, `graft_indexed`, `gh_authenticated`,
`gh_user`, `issue`, `assigned`, `thread`. Exit status is 1 when no rules file is found, so an agent or a CI job can gate on it.
If `gh` is logged in, it makes one call to the GitHub API for the user name.

**Planned:** it compares `.ai-core/STAMP` with `~/.setup-ai-core` and the project harness clones and
re-assembles the checkout when a layer changed, so a rule change in a layer reaches every
checkout at the next session without running `init` again.

### 4.10 What each agent reads

| Agent | Reads at start | Mechanically active |
| :--- | :--- | :--- |
| Claude Code | `AGENTS.md`, `.claude/settings.json`, `.mcp.json`, `.claude/skills/` | permissions from the harness; hooks, status line, the Graft MCP server and the `graft` skill from `graft init` |
| OpenAI Codex | `AGENTS.md` from the repository root down to the working directory, concatenated; `~/.codex/AGENTS.md` for the user; `.agents/skills/` in the repository and `~/.agents/skills/`; MCP servers from `.codex/config.toml` in the repository (the harness deploys it with the Graft server; read once the project is trusted) and from `~/.codex/config.toml` | skills; MCP from `.codex/config.toml`, not from `.mcp.json`; hooks from `~/.codex/hooks.json`, which `graft init` writes |
| OpenCode, Zed, Aider | `AGENTS.md` | nothing; text only |
| Google Antigravity (`agy`) | `AGENTS.md` (prepended to every prompt), `.agents/skills/` | skills; MCP only from `~/.gemini/config/mcp_config.json`, machine-wide: its documentation names `.agents/mcp_config.json` in the repository too, but `agy` does not load it (tested with `agy --print`, with a valid machine-wide file), so `graft init` registers the server there and `doctor` repairs the file when it is empty |
| Cursor, Windsurf, Copilot | `.cursorrules`, `.windsurfrules`, `.github/copilot-instructions.md`, deployed only when `AGENTS` names them | nothing; a one-line pointer to `AGENTS.md` and the rules |
| OpenHands | `AGENTS.md`, `.agents/skills/`, the organisation's `.agents` repository, `.openhands/setup.sh`, `.openhands/hooks.json`; the microagent pointer the harness deploys today is the older convention | `setup.sh` runs at every start with the repository; hooks on `SessionStart`, `PreToolUse`, `PostToolUse`, `UserPromptSubmit`, `Stop`, `SessionEnd`; skills |

Except for Claude Code, everything is text that an agent reads and follows. That is how these
tools work; the harness gives them the text at the place they look.

### 4.11 Claude Code details

- Claude Code 2.1.277 or newer reads `AGENTS.md` by itself when the repository has no
  `CLAUDE.md`. If you keep a `CLAUDE.md`, add the line `@AGENTS.md` to it.
- `.claude/settings.json` is created once with one entry, `permissions.allow: ["Bash(ai-core:*)"]`,
  so an agent may run the harness commands without a prompt. If your repository already has one,
  `init` keeps it and reports it under `kept`; add that entry by hand. Claude Code applies allow rules from
  a committed or excluded project `settings.json` only after you accept its trust dialog for the
  folder.
- Everything else Claude Code needs for Graft is written by `graft init`, which `init` runs:
  `.mcp.json` with the Graft MCP server, the hook and status line blocks merged into
  `settings.json` (`PostToolUse`, `UserPromptSubmit`, `SessionStart`, `Stop`, each running
  `node .claude/helpers/graft-hooks.cjs`), the helpers under `.claude/helpers/`, and the
  `graft` skill under `.claude/skills/`. Graft merges into an existing `settings.json`; your
  entries stay. All of it is excluded from git by `graft-setup`. With
  `GRAFT_EXECUTION_MODE="skip"` none of it is written.

### 4.12 Agents that run in a sandbox (OpenHands, cloud agents)

OpenHands, and every agent that runs in the cloud, works on a **fresh clone in a sandbox**. Only
what is committed is there. The harness deploys its files into a checkout and hides them from git,
so none of them reach a sandbox. Two ways close that gap; they can be combined:

1. **Organisation-level, no file in the repository.** OpenHands loads the skills of the
   repository `github.com/<org>/.agents` for every repository of the organisation. The planned
   `ai-core publish` copies the assembled rules (as a skill that is always loaded) and every
   skill of the project harness into that repository. The rules and the skills then reach every
   OpenHands session of the organisation without any per-repository file. What this path cannot
   deliver is the map of one repository, because organisation skills do not know which repository
   they are loaded in.
2. **A bootstrap in the repository.** OpenHands runs `.openhands/setup.sh` every time it starts
   working with a repository, and `.openhands/hooks.json` gives it `SessionStart` and `Stop` hooks.
   A setup script of three lines that installs the harness and runs `init` puts the complete
   harness, map included, into the sandbox. These two files are committed; they are the only
   exception to "nothing is committed", they carry no content of the harness, and whether to use
   them is decided per project.

Today the harness deploys `.openhands/microagents/repo-rules.md`, the older OpenHands
convention. It is kept until the two paths above exist.

### 4.13 The push gate: `ai-core pre-push`

One gate judges every push of every repository, and it lives in setup-ai-core, not in the
repositories: each repository carries a three-line `.githooks/pre-push` that only starts
`ai-core pre-push` with git's own standard input, and `core.hooksPath` of the clone points at
`.githooks`. `ai-core pre-push --install` (`-Install`) writes that shim into the current
repository and into every worktree of it (a relative `core.hooksPath` is read from the tree being
pushed, and git runs the file on disk), sets `core.hooksPath`, and says what to commit; with
`--all <folder>` it does so for every repository under a folder, and it commits the shim on its
own (a `No-issue:` trailer naming the command) and pushes it by ref through the gate; a worktree
gets the file and keeps it for its own commit. An unpushed commit ahead of origin that names no
issue and touches nothing but `.gitignore`, written by an `init` from before `init` committed the
block itself, gets the `No-issue:` trailer that says so, author and subject kept, so the push
goes through. `init` sets `core.hooksPath` in a clone that carries the shim, so a fresh clone is
armed by its first `init`.

The gate judges, in this order, stopping at the first refusal (`pre-push: REFUSED — ...`, exit 1):

1. **The pushed commit is the one checked out.** Work is pushed by ref, `git push origin
   HEAD:<branch>`; an annotated tag is resolved to the commit it names.
2. **Every pushed commit names its issue**, `#<n>` anywhere in the message, or is excused: the
   subject opens with `release:`; every file it touches is a `*.md` or a `LICENSE*` (an
   explanation needs no ticket); or it carries a trailer `No-issue: <who asked and why>`, read the
   way git reads a trailer, so an empty one and the two words inside a sentence do not count.
   Merges are not judged, a deletion runs nothing, and what is judged is exactly what the remote
   does not have yet (`<remote sha>..<local sha>`; a ref the remote lacks is measured against every
   remote ref, so a tag introduces nothing).
3. **The team modes are installed** (`ai-core team-modes-check`, section 4.6).
4. **Every Windows entry point is the one text.** Where the checks are written in
   `scripts/check.sh`, a `check.ps1` or `build.ps1` anywhere in the tree must equal
   `lib/entry-point.ps1`: the file that starts the `.sh` of its own name and decides nothing. A
   copy that prints the verdict and exits 0 would tell the person the checks passed while nothing
   ran, and no other step can see that.
5. **`scripts/check.sh` is green**, run in the tree being pushed; a repository without one is told
   so and passes on.
6. **gitleaks over the commits the push carries**, in a repository that carries `.gitleaks.toml`;
   the commits are the only place a credential taken out again still stands.

Run from a prompt or an agent's shell, with nothing on standard input, `ai-core pre-push` judges
the current branch against its upstream: what `git push` would send. `tests/pre-push.test.sh`
and `.ps1` drive both twins with git's input by hand, against a scratch repository, stand-ins
for the check and for gitleaks, and a team-modes table of their own.

---

## 5. Install and use (today)

### 5.1 Prerequisites

| Need | For | Notes |
| :--- | :--- | :--- |
| Git | `session-start`, worktrees, the exclude file | On Windows also Git Bash, for the `.sh` twins and Claude Code's Bash tool |
| Bash 3.2+ or PowerShell 7 (`pwsh`) | the `.sh` and `.ps1` twins | `init.ps1` starts its child scripts with `pwsh`, so Windows PowerShell 5.1 alone is not enough |
| `curl` and `tar` | remote install with `init.sh` | `init.ps1` uses `Invoke-WebRequest` and `Expand-Archive`, part of PowerShell |
| jq | every board and issue command reads GitHub's answers through it | `doctor` installs it |
| Node.js 20+ with `npm` and `npx` | Graft, the Graft MCP server, the Claude Code hook helpers | no fallback: without Node.js, `init` fails; `skip` mode turns Graft off |
| `gh`, logged in | the project harness is found, cloned and created through it; every board and issue command; `session-start` shows the GitHub user | `doctor` installs it; the login is yours |

### 5.2 Once per machine: `install`

```bash
# Linux / macOS / Git Bash
curl -sSL https://raw.githubusercontent.com/kartalbas/setup-ai-core/main/bin/install.sh | bash
```

```powershell
# Windows, PowerShell 7
irm https://raw.githubusercontent.com/kartalbas/setup-ai-core/main/bin/install.ps1 | iex
```

`install` clones this repository to `~/.setup-ai-core`, adds its `bin/` (where the `ai-core`
command lives) to the PATH (the shell profiles on Linux and macOS, the user PATH on Windows; open a
new terminal afterwards) and runs `doctor`. Run it again to pull. If you already have a clone, say
so with `--source`: then nothing is cloned, that clone is the installation, and its `bin/` goes on
the PATH. Options:

| Bash | PowerShell | Effect |
| :--- | :--- | :--- |
| `--source <clone>` | `-Source <clone>` | use this existing clone of the repository; nothing is cloned |
| `--dir <path>` | `-Dir <path>` | clone somewhere else than `~/.setup-ai-core` |
| `--repo <url>` | `-Repo <url>` | clone from this URL or path instead of GitHub (a mirror, a fork) |
| `--no-path` | `-NoPath` | do not touch the PATH |
| `--no-doctor` | `-NoDoctor` | do not run `doctor` at the end |

`install` exits 1 when `doctor` finds problems; setup-ai-core is installed anyway, and the problems
are the next steps.

### 5.3 Per repository: `ai-core init`

```bash
cd ~/repos/myorg/myproject
ai-core init
```

`ai-core init` is `bin/init.sh` or `bin/init.ps1` of the clone, run on the current directory. The
scripts can still be called by path (`bash ~/.setup-ai-core/bin/init.sh .`). There is no way to
equip a checkout without the clone: the checkout gets no scripts of its own, so `ai-core` must be
on the machine that runs the agent.

### 5.4 Options of `init`

| Bash | PowerShell | Effect |
| :--- | :--- | :--- |
| `ai-core init [TARGET_DIR]` | `ai-core init [-TargetDir <path>]` | the repository to equip; default is the current directory |
| `--all <folder>` | `-All <folder>` | run `init` in every git repository directly under the folder, then in the folder itself (section 5.8); `doctor` runs once; a failing repository is named in the summary and the exit code is 1 |
| `--no-doctor` | `-NoDoctor` | do not run `doctor` first (CI, or a machine you have checked yourself) |
| `--dry-run` | `-DryRun` | write nothing; print the report of what the run would create, refresh, keep and remove, and what Graft would write in the repository and on the machine; `doctor` runs without installing; with `--all` every repository gets its dry run |
| `-h`, `--help` | `-Help` | usage |

An unknown option is an error.

### 5.5 What `init` does, in order

1. Runs `doctor`; while a problem remains, nothing is deployed and `init` exits 1 with the
   instruction.
2. Finds the project harness from `origin` and clones, pulls or creates it, with its `extends`
   chain (section 4.5). Creates `.ai-core/` with `rules/` and `docs/`, and removes a
   `.ai-core/bin/` an earlier version left there.
3. Assembles the rules of every layer into `.ai-core/rules/rules.md`, copies `skills.md` and
   `VERSION`, the skills, docs and data files of every layer, the files under `repos/<repo>/`, and
   writes `STAMP`.
4. Copies every file of `templates/` that does not exist yet in the checkout; a file that exists
   is never overwritten. In a project folder `AGENTS.md` is generated instead and rewritten every
   time.
5. Writes the exclude block into `.git/info/exclude`, in the place of the one an earlier run
   wrote, and the block into `.gitignore` (section 4.3). Outside a git repository it says so and
   goes on.
6. Runs `graft-setup`. If that fails, `init` prints why and exits 1; the other files are already
   in place.
7. Prints the report: what the run did to the checkout.

Every file `init` touches is written only when its content differs, and every file is recorded
under one of these words:

| word | meaning |
| :--- | :--- |
| `created` | did not exist; written |
| `refreshed` | a managed file (the assembled rules, `STAMP`, a skill, a data file, a map from `repos/<repo>/`, the exclude block) that differed from what the layers say; rewritten. A managed `AGENTS.md` keeps the block Graft appended to it, so Graft finds it unchanged |
| `kept` | a file created once (`AGENTS.md`, `.claude/settings.json`, `config.env`, ...) that differs from its template, yours or changed by Graft; never overwritten |
| `removed` | what an earlier version left in the checkout (`.ai-core/bin/`, `.agents/mcp_config.json`) |
| `tracked` | a file of `repos/<repo>/` the repository commits itself; not applied |
| `unchanged` | the count of files that were already what they should be |

The report closes with `.gitignore changed` when the block was written, committed and pushed
(or, in a worktree, left to its own commit), with `core.hooksPath set to .githooks` when the repository carries the push gate's shim and the
clone was not armed yet, and with the harness version. Above it, `graft-setup` reports its own writes in two lists, the
files in the repository and the files on the machine (under the home directory), each with
Graft's word for it (`created`, `updated`, `appended`, `wrote`), and one line for the graph.
Graft's full output is shown only when it fails. A second run on an unchanged checkout reports
only the count of unchanged files, on both twins the same lines.

`ai-core init --dry-run` prints the same report with `would change` and writes nothing, not
even the exclude file, and creates no project harness: one that does not exist yet is announced
as `would be created from the skeleton`; Graft's `--dry-run` lists what `graft init` would write in the
repository and on the machine, and the graph is not built.

### 5.6 First check

```bash
ai-core session-start
```

It must end with `Ready for task execution.` and `git status` must show nothing new.

### 5.7 `config.env`

`.ai-core/config.env` has two keys. Values are case-insensitive; quotes and `# comments` are
allowed; any other value is an error.

| Key | Values | Meaning |
| :--- | :--- | :--- |
| `AGENTS` | names separated by spaces: `claude`, `codex`, `antigravity`, `openhands`, `gemini`, `cursor`, `windsurf`, `copilot`; default `claude codex antigravity openhands` | the agents this project serves. `init` deploys the file of each one named (`.codex/config.toml`, `.cursorrules`, `.windsurfrules`, `.github/copilot-instructions.md`, `.openhands/microagents/repo-rules.md`) and no other, and `graft init` is wired into these and no other (`--agents`). Empty: every agent Graft detects on the machine, and every pointer file. Graft detects Gemini wherever `~/.gemini` exists, which Antigravity creates too, so an empty list wires `GEMINI.md` and `.gemini/` into every repository. |
| `GH_ORG` | a GitHub organisation or user | the owner the board commands act for when a command names no repository (`repo-boards`, `project-new`, `incident-count`, a bare board number). Unset: the owner of the repository the command runs in. The environment variable `GH_ORG` overrides both. |
| `GRAFT_EXECUTION_MODE` | `native` (default), `skip` | `native` builds the code graph with the local Node.js and fails when it cannot; `skip` does not build it in this repository |

### 5.8 Many repositories

The unit of installation is one repository checkout. For a project with many repositories in one
folder, one command runs `init` in each git repository directly under it, skips the folders that
are not repositories, names the ones that failed, and then equips the folder itself:

```powershell
ai-core init -All C:\repos\myorg
```

```bash
ai-core init --all ~/repos/myorg
```

The folder is where many developers start their agent. It gets the same data as a repository,
an `AGENTS.md` that lists the repositories with the path of each map, and a Graft workspace over
all of them (section 4.8). Nothing there is under git, so nothing is excluded and nothing can be
committed. An agent started in the folder reads that `AGENTS.md`, and Claude Code loads a
repository's own `AGENTS.md` as soon as it works on files inside it, the way it loads nested
`CLAUDE.md` files. Each repository still carries its own files, because a repository is also opened
alone: by OpenHands, by CI, by a colleague with another layout.

### 5.9 Windows before the quick start

Everything is typed into PowerShell 7 (`pwsh`), not the blue "Windows PowerShell". Before the
quick start, once per machine: `winget install Microsoft.PowerShell`, open "PowerShell 7"
(`$PSVersionTable.PSVersion` shows `7.x`), then `winget install Git.Git` and reopen the terminal.
`doctor`, run by `install`, installs Node.js, jq and gh and names the login it cannot do for you.
Then the quick start, which is the same on every system.

With Claude Code: run `claude` in the repository, answer **yes** to trusting the folder and
**approve** the `graft` MCP server (`/mcp` shows it connected); if the repository has a
`CLAUDE.md`, add the line `@AGENTS.md`, without one Claude Code 2.1.277+ reads `AGENTS.md` by
itself. With Antigravity: run `agy` in the repository and sign in; it loads `AGENTS.md` by itself
and reads its MCP servers from `~\.gemini\config\mcp_config.json`, where `graft init` registers
the Graft server (section 4.8). A new clone or worktree runs `ai-core init` once.

### 5.10 Update and uninstall

**Update:** a release of setup-ai-core is a tag `vX.Y.Z` on the commit `VERSION` names, cut with
`ai-core release X.Y.Z` only when the checks were green on both runners for that commit; what is
not tagged reaches nobody. `install` checks the newest release out, `ai-core update` moves a clean
clone to the newest one (a clone with uncommitted changes or commits not pushed is left alone and
named; `--main` follows the development branch, for whoever works on setup-ai-core) and pulls
every project harness clone on the machine; `ai-core update --check` fetches and reports only,
exit 0 when everything is current, 2 when something is available. The scripts are current in every
checkout at once because no checkout has a copy; `ai-core init` again in a clone or worktree
brings it to that state, managed files replaced, your files kept. `session-start` prints
`Harness state` (the checkout's `.ai-core/STAMP` against the clones: run `init` when it is
behind) and `Releases` (`update --check`, unless `UPDATE_CHECK="never"` in `config.env`).
Nothing updates by itself.

**Uninstall:** delete what section 4.2 lists, delete `graft/`, and remove the block between
`# setup-ai-core start` and `# setup-ai-core end`, and the one between `# setup-ai-core graft start`
and `# setup-ai-core graft end`, from `.git/info/exclude`. On the machine: delete
`~/.setup-ai-core` and the PATH entry `install` added (the line marked `# setup-ai-core` in the shell
profile; the entry in the user PATH on Windows). `npx` keeps its cache.

---

## 6. The scripts (today)

All run as `ai-core <name>` from any directory inside the repository, or from the project folder,
and accept `-h` / `--help` (`-Help` in PowerShell). `ai-core <name>` runs `bin/<name>.sh` in Bash
and `bin/<name>.ps1` in PowerShell; a new script in `bin/` is a command without any registration.

| Script | Usage | Exit codes |
| :--- | :--- | :--- |
| `session-start` | `ai-core session-start [--json]` / `[-Json]` | 0 ready; 1 no rules file |
| `solution-path` | `ai-core solution-path <file> [--check] [--issue N]` / `-File <file> [-Check]` | section 7 |
| `rules-check` | `ai-core rules-check [file-or-directory]` / `[-RulesFile <file-or-directory>]`; default `.ai-core/rules/rules.md`, or the `rules/` directory of setup-ai-core; a directory means its `NN-*.md` section files | 0 every rule tagged; 1 otherwise |
| `graft-setup` | `ai-core graft [dir] [--dry-run]` / `[-TargetDir <dir>] [-DryRun]` | 0 built, skipped or dry; 1 no Node.js, build failed, or bad `config.env`; 2 a wrong argument |
| `init` | `ai-core init [dir] [--all <folder>] [--no-doctor] [--dry-run]` / `[-TargetDir <dir>] [-All <folder>] [-NoDoctor] [-DryRun]` | 0 in place, or dry; 1 doctor failed, Graft failed, or a repository under `--all` failed |
| `push` | `ai-core push [MESSAGE] [--harness <name>]` / `[-Message <text>] [-Harness <name>]` | 0 every harness clone pushed or had nothing; 1 no clone, a commit or a push failed |
| `update` | `ai-core update [--check] [--main]` / `[-Check] [-Main]` (section 5.10) | 0 done, or `--check`: everything current; 2 `--check`: a release or commits available; 1 an origin could not be reached |
| `release` | `ai-core release <version>` (in a clone of setup-ai-core, section 10) | 0 tagged and pushed; 1 refused, naming what is missing; 2 a wrong argument |
| `pre-push` | `ai-core pre-push [--install [--all <folder>]]` / `[-Install [-All <folder>]]` (section 4.13) | 0 every check passed, or the shim written; 1 refused, or a repository under `--all` is none; 2 a wrong argument |
| the board and issue commands | `ai-core issue-new ...`, `ai-core start-issue N`, ... (section 8) | 0 done; 1 refused or gh refused; 2 a wrong argument |
| `doctor` | `ai-core doctor [--no-install]` / `ai-core doctor [-NoInstall]` | 0 every required tool present and gh logged in; 1 otherwise, each problem with its instruction |
| `install` | `bin/install.sh [--source <clone>] [--dir <path>] [--repo <url>] [--no-path] [--no-doctor]` / `bin/install.ps1 [-Source <clone>] [-Dir <path>] [-Repo <url>] [-NoPath] [-NoDoctor]` | 0 installed and doctor OK; 1 when doctor found problems |
| `ai-core` | `ai-core <command>`: any script in `bin/` by name, `graft` for `graft-setup`, plus `version`, `help` | the command's exit code; 1 for an unknown command |

`doctor` today checks Git, gh and its login, Bash, PowerShell 7 (required on Windows), Node.js 20+
with `npx`, jq, the team modes, repairs an empty Antigravity `mcp_config.json`, and reports whether `claude`, `agy` and `codex` are installed, with the install command
of each. Required tools it installs with `winget` (Windows), `brew` (macOS) or `apt-get` (Linux);
a login it cannot do for you. On Windows a tool installed a moment ago may need a new terminal.

---

## 7. The solution path

The rules require a solution path before any architectural change, multi-file refactoring or new
feature. Copy `.ai-core/solution-path.template.md`, fill the eight sections, validate:

1. `Where a person meets this`
2. `What they see today`
3. `What the system does behind it`
4. `The decision`
5. `Options`
6. `Recommendation`
7. `Code facts`
8. `Reuse manifest`

```bash
ai-core solution-path 42 docs/solution-42.md --check   # validate only
ai-core solution-path 42 docs/solution-42.md           # validate, then post it under issue 42 through issue-comment
```

```powershell
ai-core solution-path 42 docs/solution-42.md -Check
```

The issue number comes first and is required: a solution path is written for an issue, and posting
it there is the normal end of the command; `--check` / `-Check` validates and posts nothing.

A section counts as filled when something other than whitespace follows its heading, a required
heading may stand only once, and both twins answer identically: `tests/solution-path.test.sh` and
its PowerShell twin hold them to the same planted documents.

---

## 8. The board and the issues

The rules say the plan is the issues (the working style for agents in the rules), and these commands are what holds
that: one command per act on GitHub issues and a GitHub Projects board, driven from the terminal
through `gh`. Each exists as `.sh` and `.ps1`, takes the same arguments, prints the same lines,
and `tests/` holds the two to answering identically against a stand-in `gh`, so nothing in the
tests reaches github.com. Nothing here holds state: every command reads the board through `gh`
and writes back to it, so the board is the truth and this is only a shorter way of reaching it.

**Which board.** No project number is written down anywhere. A command resolves the board it acts
on in this order: `--project N` / `-Project N`, the environment variable `GH_PROJECT_NUMBER`,
then the single open project the repository is linked to. A repository linked to none, or to more
than one, stops the command with what to do; writing a card to the wrong board is silent
otherwise. A board is written `N` or `ORG/N`: a bare number is a board of the repository's
organisation (or `GH_ORG` when no repository is named), `ORG/N` names the organisation outright.
The board is addressed by name throughout, `Status`, `todo`, `P1`; the ids behind the names are
read from GitHub and cached under `.ai-core/.cache/`, one directory per board, so a rename on the
board surfaces as an error naming the options that exist.

**The data files**, in `.ai-core/` of the checkout, deployed once by `init` from `templates/` and
yours from then on (the project harness will carry them):

| File | What it holds |
| :--- | :--- |
| `labels.tsv` | the label taxonomy: group, name, colour, description. Every issue carries one `type:` and one `area:` label; `closes:` says what has to happen before a ticket may be closed; `incident:` names what went wrong with a ticket. The group is the prefix the name carries, and every reader refuses the file otherwise. `issue-label` refuses a name outside it, `labels-sync` creates them, `board-sync` reports the tickets missing one. The template carries the generic groups; the `area:` rows are the project's. |
| `assignees.tsv` | repository → login: who a new issue in that repository belongs to. A repository not listed falls back to `@me`. |
| `team-modes.tsv` | tool, mode, level, probe, install, verified: how each tool proves a mode is installed and how it is installed (section 4.6). |

**The commands.** All run as `ai-core <name>` and take `--help` (`-Help`). A command that names
no repository acts on the one it runs in; `OWNER/REPO` before the issue number names another.

| Command | Does |
| :--- | :--- |
| `start-issue N` | opens the worktree for issue N under `../.worktrees/<repo>/issue-N-<slug>`, on a branch of that name cut from `origin/<default>`, only when the issue is assigned to you and the checkout is clean and current; moves the card to `implementing`; copies the checkout's `.ai-core/` data into the worktree and runs `init` there; prints the thread. One run, because any one of these done alone is often not done. |
| `issue-new` | creates an issue: `--title`, `--body-file`, labels, priority, the assignee from `assignees.tsv`, the card on the board, optionally a parent epic (`--parent OWNER/REPO#N`). Refuses without `--asked-by LOGIN` and `--asked-in WHERE` and writes "Asked for by @login on DATE in WHERE." as the body's first line. Reports a title over 70 characters, one with a backtick, or one that names an action and no stake. |
| `issue-thread N [--json]` | the issue and every comment on it, for a person or as one JSON object |
| `issue-mine N` | whether the issue is assigned to the account `gh` is logged in as; `start-issue` and `session-start` ask it |
| `issue-comment N` | adds a comment, inline or `--body-file` |
| `issue-edit N` | edits title and/or body; a body without the asked-for line keeps the one the issue has |
| `issue-close N...` | closes issues and moves their cards to `done`, as `completed` or `--reason not-planned` |
| `issue-reopen N...` | reopens issues and returns their cards to `todo` |
| `issue-status N... STATUS` | moves cards between `backlog`, `todo`, `implementing`, `testing`, `done` |
| `issue-priority N... P` | `P0` blocker, `P1` high, `P2` normal, `P3` low, `P9` parked |
| `issue-label N --add/--remove` | labels checked against `labels.tsv`; a typo is refused, not minted |
| `issue-assign N` | adds, removes or replaces assignees; additive by default |
| `issue-duplicate N OF M` | marks N the native duplicate of M, or removes it with `--undo` |
| `issue-transfer N OWNER/REPO` | moves an issue to another repository; the card stays where it is |
| `issue-block`, `issue-unblock` | records or clears a real `blocked by` dependency, across repositories |
| `subissue-add`, `subissue-remove` | attaches issues to an epic as sub-issues, or detaches them |
| `board-sync` | puts every issue of every linked repository on the board and reports what is missing: labels, priorities, cards that were not on the board |
| `board-list` | the board: status, priority, repository, number, title |
| `board-order` | stamps an order onto the board, read from standard input as `owner/repo#number` per line |
| `board-unarchive` | brings archived cards back into view |
| `status-sync [--dry-run]` | moves each card to the state its git signals prove: a commit naming the issue on the default branch → `testing`, that commit carried by the newest tag → closed and `done`; forward only, never an epic |
| `epics-top`, `item-top`, `item-move` | epics to the top of the board; named cards to the top; a repository's cards from one board to another, keeping status and priority |
| `field-option-add` | adds one option to a single-select field, reading the field first so the others are not deleted |
| `view-filter`, `project-new`, `repo-link`, `repo-boards` | narrows a view to named repositories; creates a board by copying one whose title starts with `[TEMPLATE]`; links a repository to a board and gives it the taxonomy; every repository of the organisation and its board, exit 1 when one is on none or on two |
| `labels-sync` | applies `labels.tsv` to one repository, to named ones, or to every repository on a board |
| `incident-count` | the issues carrying each `incident:` label per ISO week |
| `team-modes-check`, `team-modes-install` | section 4.6 |
| `schema-check` | holds every GraphQL mutation in `bin/` and `lib/` against the schema github.com publishes; the one check that reaches the network, run by CI |
| `case-check` | refuses a spelling in `bin/` or `lib/` that accepts more than it says: a PowerShell comparison against a text literal must say whether it folds case (`-ceq`, `-clike`, `switch -CaseSensitive`, `[StringComparison]::Ordinal`), because every Bash twin compares bytes |

**The push hook.** A repository that wants the gate before every push carries the three-line
shim `ai-core pre-push --install` writes into `.githooks/pre-push` (section 4.13); the gate itself
never lives in a repository.

---

## 9. Planned commands

`install`, `doctor`, `update`, `version`, `init` with the project harness, and the `ai-core` command exist
(sections 4.5 and 6). Planned:

| Command | Does |
| :--- | :--- |
| `doctor` | also the agent CLIs and the tools a project harness declares in `ai-core.json`; `init` runs it first |
| `init` | additionally: generate the map when the repository has none |
| `session-start [--json]` | as today, plus: re-assemble the checkout when a layer moved past `.ai-core/STAMP`, print the map's headings, warn when a harness clone is behind its origin or the map is stale |
| `map [--check]` | generate or refresh the map of the current repository and push it to the project harness; `--check` only reports staleness |
| `publish` | copy the assembled rules and the skills of the project harness into the organisation's `.agents` repository, so OpenHands loads them in every repository of the organisation (section 4.12) |
| `graft`, `solution-path`, `rules-check`, the board and issue commands | as today |

Prerequisites `doctor` will know, with an install per platform (`winget`, `brew`, `apt`, or the
tool's official installer): Git and Git Bash, `gh` with its login (install yes, login is a
person's act), PowerShell 7 on Windows, Node.js LTS, the agent CLIs listed in `ai-core.json`, and
the project tools listed there (`kubectl`, `helm`, ...). Everything GitHub-side goes through `gh`.
Nothing runs in a container.

---

## 10. Developing the harness

```bash
bash tests/check.sh
```

The check parses every script (`bash -n`, the PowerShell parser), runs both `rules-check` twins
over `rules/`, runs both `doctor` twins against a fake old Node.js and a fake unauthenticated gh
and requires the same two problems, runs both installers against a temporary home (an existing clone with `--source`, a clone with
`--repo`, a second run that pulls) and `init` through both `ai-core` commands, bootstraps a temporary checkout with each installer in `skip` mode
(data only, no scripts in the checkout), fails on any
warning or error in either installer's output, diffs the two deployed file lists, proves the assembled `rules.md` has one section per source
file, is byte-identical on both twins and passes `rules-check`, proves a second run creates
nothing, compares `session-start`'s JSON between the twins, proves `git status` stays
empty in a fresh repository and in a worktree with both twins, runs `init --all` over a folder
and proves the folder's generated `AGENTS.md` lists exactly its repositories, stands a fake `gh`
on the PATH and proves a project harness is created from the skeleton on the first `init`, cloned
on another machine, and that its rules, skills, docs, data files and `repos/<repo>/` are
assembled identically by both twins, base first along an `extends` chain, and proves `push` commits
and pushes a harness clone's change to its origin and has nothing on a second run, proves a failing Graft build makes
`init` exit 1 with the files in place, runs a fake Graft that succeeds and proves `init` calls it
without the picker, excludes every file it wrote and names the committed file it changed, and requires `session-start` to exit 1 where the harness is
absent, runs the two board suites (`tests/run-all.sh`, `tests/run-all.ps1`: one test pair per
command against a stand-in `gh`, the push gate's pair among them, and the tree must be as the
suite found it) and both `case-check` twins. It needs `bash`, `pwsh`, `node` and `jq` and never touches the network. CI runs it on Ubuntu
and Windows for every push and pull request, and then `schema-check`, which needs github.com.

**A release** is `ai-core release X.Y.Z`, run in the clone: it refuses unless `VERSION` says X.Y.Z,
the tree is clean, `main` is pushed, and the workflow run for exactly that commit is completed and
green; then it tags `vX.Y.Z` and pushes the tag. `install` and `update` follow the newest tag, so
`main` can carry a mistake without it reaching anybody.

- **Add a file a checkout should get:** put it under `templates/` at the path it has in the
  checkout. Both installers deploy it.
- **Add a script:** both spellings in `bin/`, a help screen in each; `ai-core <name>` runs it
  without any registration. A row in `templates/AGENTS.md` when agents should call it. A board
  command gets a test pair in `tests/` that drives both twins against a stand-in `gh`, and its
  PowerShell comparisons say whether they fold case, or `case-check` is red.
- **Change a rule:** edit its section file under `rules/`, keep the tag at the end of the rule,
  run `bash bin/rules-check.sh rules`. A rule may wrap over several lines; the tag ends the last
  one. A new section is a new `rules/NN-slug.md`; the number places it.
- **Release:** bump `VERSION`; `init` copies it to `.ai-core/VERSION`.

Run the check before every commit.

---

## 11. Implementation order (planned)

Each step lands with its test in `tests/check.sh` and passes in CI before the next begins.

0. Rules as one file per section, assembled into one `rules.md` per checkout by both installers;
   `rules-check` over a directory. **Done.**
1. `doctor` and `install`, with the `ai-core` command. **Done.**
2. `ai-core init --all`, `doctor` run by `init`. **Done.**
2b. Scripts once per machine, checkouts data only, `init` for the project folder, the `.gitignore`
   block. **Done.**
2c. The board and issue commands, the team modes, `jq` in `doctor`. **Done.**
3. Project harness resolution from `origin`, the `extends` chain, clone and pull to
   `~/.<prefix>-ai-core`, `gh repo create` from the skeleton when missing. **Done.**
4. Assembly: merged rules, skills into both skill directories, docs, data files, `repos/<repo>/`,
   `STAMP`, the exclude block. **Done.**
5. `session-start` re-assembly on a changed stamp, and the Claude Code `SessionStart` hook.
6. `map`: the skeleton, the prompt, generation through the agent CLI, commit and push, staleness.
7. Sandboxed agents: `publish` into the organisation's `.agents` repository; the OpenHands
   bootstrap files (`.openhands/setup.sh`, `.openhands/hooks.json`) as a template a project can
   choose to commit; `.agents/skills/` deployed next to `.claude/skills/`.
8. Removal of the per-checkout `rules.local.md`, `config.env` and `docs/README.md` templates
   (they come from `repos/<repo>/` then), and a rewrite of this README from the result.

---

## 12. Troubleshooting

| Symptom | Cause and fix |
| :--- | :--- |
| `pwsh: command not found` / `'pwsh' is not recognized` | PowerShell 7 is not installed. Install it, or use the Bash twins from Git Bash. |
| `init` ends with `error: ... the Graft code graph is not` | Node.js with `npx` is missing, or Graft's native build failed. Install Node.js 20+ and run `ai-core graft` again, or set `GRAFT_EXECUTION_MODE="skip"`. The other files are in place. |
| `error: GRAFT_EXECUTION_MODE must be native or skip` | a typo in `config.env`; checked before anything runs |
| `session-start` exits 1 with `Not ready: no rules file found` | the harness is not installed here. Run `init`. |
| `kept .claude/settings.json` in the report | your repository already had one. Add `Bash(ai-core:*)` to its `permissions.allow` by hand, or delete the file and run `init` again. |
| `ai-core: command not found` inside an agent | the clone's `bin/` is not on the PATH of that shell. Run `install` again, open a new terminal, or call the script by path. |
| Claude Code ignores `AGENTS.md` | a `CLAUDE.md` exists in the directory or above it. Add `@AGENTS.md` to it. |
| Claude Code prompts for `ai-core` commands although they are allowed | accept the trust dialog; project allow rules apply only after it |
| Hooks appear to do nothing | expected in a repository without `graft/`. Run `ai-core graft` first. |
| `git add AGENTS.md` says the path is ignored | `init` excluded it on purpose. `git add -f AGENTS.md` commits it anyway, or remove the entry from `.git/info/exclude`. |
| A fresh clone or worktree has no `.ai-core/` | the harness is not committed. Run `init` there once. |

---

## 13. Known limitations (today)

- `@nanonets/graft` runs with `npx -y` and no version pin, in `graft-setup` and in the `.mcp.json` it writes,
  so the code Graft executes can change between sessions without a change in your repository.
- Remote installs track the `main` branch; there are no tagged releases yet.
- The `solution-path` twins differ as section 7 describes.
- `rules-check` validates `rules.md` only, not `rules.local.md`.
- The board commands assume a GitHub Projects board with single-select fields `Status` (options
  `backlog`, `todo`, `implementing`, `testing`, `done`) and `Priority` (`P0` to `P3`, `P9`);
  `project-new` copies such a board from one whose title starts with `[TEMPLATE]`.
- Project-level files such as `rules.local.md` do not travel with the repository; sharing them is
  a copy step of your own until the project harness exists.
- Skills are a per-machine step until the project harness exists.

---

## 14. Repository structure

```text
setup-ai-core/
├── VERSION                              setup-ai-core version, copied to .ai-core/VERSION
├── bin/
│   ├── install.sh / install.ps1         once per machine: clone to ~/.setup-ai-core, PATH, doctor
│   ├── doctor.sh / doctor.ps1           prerequisites: check, install, or fail
│   ├── ai-core, ai-core.ps1, ai-core.cmd the command; runs any script here by name
│   ├── init.sh / init.ps1               equips a checkout or a project folder with data
│   ├── session-start.sh / .ps1          the session start
│   ├── solution-path.sh / .ps1          8-section solution path validator
│   ├── rules-check.sh / .ps1            enforcement-tag validator
│   ├── graft-setup.sh / .ps1            Graft code graph, local Node.js or fail
│   ├── team-modes-check / -install      the team modes of every tool on the machine
│   ├── issue-*, start-issue, board-*,   the board and issue commands, one pair each
│   │   status-sync, labels-sync, ...
│   ├── pre-push                         the push gate, and --install for the shim a repository carries
│   └── schema-check, case-check         the checks of the board commands themselves
├── lib/
│   ├── board.sh / Board.psm1            the library of the board commands
│   ├── layers.sh / Layers.psm1          the project harness: from origin, cloned, pulled, created, the extends chain
│   ├── gitignore-block                  the block init writes into a project's .gitignore
│   └── entry-point.ps1                  the one text every scripts/check.ps1 and build.ps1 is a copy of
├── rules/
│   ├── NN-slug.md                       the generic rules, one file per section
│   └── skills.md                        when to use which skill
├── skeleton/                            what a new project harness starts from: ai-core.json, README, rules/, skills/, docs/, repos/
├── templates/                           mirror of the checkout; every file is created once
│   ├── AGENTS.md, .cursorrules, .windsurfrules
│   ├── .ai-core/                        config.env, labels.tsv, assignees.tsv, team-modes.tsv,
│   │                                    rules/rules.local.md, docs/README.md, solution-path.template.md
│   ├── .claude/                         settings.json: the ai-core permission
│   ├── .codex/                          config.toml: the Graft MCP server for Codex, per repository
│   ├── .github/                         copilot-instructions.md
│   └── .openhands/                      microagents/repo-rules.md
├── tests/
│   ├── check.sh                         the check
│   ├── run-all.sh / run-all.ps1         the board suites
│   └── *.test.sh / *.test.ps1           one test pair per board command
├── .github/workflows/check.yml          runs the check on Ubuntu and Windows
├── LICENSE                              MIT
└── README.md
```

---

## 15. License

Created and maintained by [@kartalbas](https://github.com/kartalbas). Released under the
[MIT License](LICENSE).
