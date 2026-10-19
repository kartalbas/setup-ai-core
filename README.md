# setup-ai-core

**One harness for every AI coding agent, in every repository, on every machine.**

`setup-ai-core` gives a repository the same rules, the same session start and the same code
intelligence for Claude Code, OpenAI Codex, Google Antigravity, OpenCode, OpenHands, Cursor,
Windsurf, Aider and GitHub Copilot, on Linux; Windows runs it under WSL. A developer installs it once per
machine and runs one command per repository. Nothing of it is ever committed to the repository.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform: Linux](https://img.shields.io/badge/Platform-Linux-blue)](README.md)
[![check](https://github.com/kartalbas/setup-ai-core/actions/workflows/check.yml/badge.svg)](https://github.com/kartalbas/setup-ai-core/actions/workflows/check.yml)

This README is the only documentation. It describes two things and keeps them apart: **what
exists today** (you can run it) and **what is planned** (the concept, not yet built). Every
section says which one it is.

## Quick start

Once per machine, on Linux with Bash 3.2+. Windows runs the harness under WSL: open a WSL
distribution and do everything below inside it (section 5.9).

```bash
curl -sSL https://raw.githubusercontent.com/kartalbas/setup-ai-core/master/bin/install.sh | bash
```

Open a new terminal. `doctor` has run and named what is missing (git, `gh` with its login,
Node.js 20, jq); fix that and nothing else.

Per repository:

```
cd <repository>
ai-core init
ai-core session-start
```

Or a whole project folder, every repository in it and the folder itself (section 5.8), and then the
agent started in the folder:

```
ai-core init --all <project folder>
cd <project folder>
claude
```

**What `init` does, in this order.** `doctor` installs what is missing (git, `gh`, Node.js, jq,
with brew or apt) and the team modes into your agent tools. If the repository's origin is
`github.com/<org>/<prefix>-<name>`, the project harness `<org>/<prefix>-ai-core` is cloned beside
the repositories, into `<project folder>/<prefix>-ai-core`, or **created on GitHub, private, from
the skeleton** when it does not exist yet. The repository gets `.ai-core/` (rules, configuration, docs), the agent files (`AGENTS.md`,
`.claude/settings.json`, `opencode.json`, ...), the skills of the harness in `.claude/skills/`
and `.agents/skills/`, and the agents in `.claude/agents/`, all listed in `.git/info/exclude`.
**A block is written into `.gitignore`, committed and pushed by `init` itself** (a worktree keeps
it for its own commit). The run ends with a
report of every file it created, refreshed, kept or removed. **`ai-core init --dry-run` shows that
report and creates nothing**, on GitHub or on disk; run it first.

Update, on the machine:

```
ai-core update
```

moves setup-ai-core to its newest release (a tag `vX.Y.Z`, cut only when the checks are green) and pulls every project harness on this machine; `ai-core update --check` only asks.
Then, in a repository, `ai-core init` brings it to that state and reports what changed.
`ai-core session-start` says when a checkout is behind the harness or a release is available.
Nothing updates by itself.

---

`session-start` safely refreshes the checkout's local default branch before reporting its state.
A clean checkout on that branch uses a fast-forward merge; another branch or detached HEAD keeps
its selected commit, index and files while an unheld default ref advances. Dirty checkouts and
Git operations in progress are refused before fetching. Local-only commits, missing refs, fetch
failures and a default held by another worktree are named and skipped. Nothing is stashed or
forced, and startup diagnostics stay on stderr so `--json` remains valid.

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
| Rules for every project | yes: one file per section under `rules/`, assembled into one `rules.md` per checkout | same |
| Rules of one project (private harness) | yes: `github.com/<org>/<prefix>-ai-core`, found from the repository's origin, cloned beside the repositories (`<project folder>/<prefix>-ai-core`), created from a skeleton when missing; its `rules/` add or replace sections, its `skills/`, `docs/`, data files and `repos/<repo>/` are assembled into every checkout; a harness may extend another (section 4.5) | same |
| Skills and team modes | `rules/skills.md` says when to use them; `team-modes.tsv` says how each tool proves a mode is installed and how to install it; `doctor` installs the missing ones, `session-start` refuses a session without them; skill folders of the project harness are deployed into `.claude/skills/` and `.agents/skills/` of every checkout | same |
| Map of a repository (what the code does not say) | yes: `ai-core map` writes it from the code through the developer's agent CLI, five fixed sections, into `repos/<repo>/AGENTS.md` of the project harness; the generic one of `templates/` until then, both under the binding rules | also written by `init` where a repository has none |
| Claude Code hook, status line, permissions | yes: a `SessionStart` hook that runs the session start, and the status line that records the usage windows | same |
| Session start | yes: the team-modes gate, state, versions, rules present, the issue thread of a worktree, exit 1 when not installed | also re-assembles the checkout when a layer changed |
| Issues and the GitHub board | yes: one command per act over `gh`, from `issue-new` and `start-issue` to `board-sync`, `status` and `status-sync` (section 8); the conventions come from three data files a project fills | the data files come from the project harness |
| A coordinator that delegates to worker sessions | yes: the skill `person-in-charge` bundles the issues into packages and gives each to a worker session it starts, with the model, effort and context size the work needs (section 4.6) | same |
| The account's usage limit | yes: the status line records the usage windows, `ai-core usage` reads them against `USAGE_STOP_AT`, and every session stops at that limit | same |
| Prerequisite check and install | yes: `ai-core doctor` checks Git, gh and its login, Bash, Node.js 20+, jq, the team modes of the agent tools on the machine, and reports the agent CLIs; installs missing required tools with brew or apt-get; `init` runs it first and deploys nothing while a problem remains | tools a project harness declares |
| Agents that run in a sandbox (OpenHands, cloud agents) | a pointer file only; nothing of the harness reaches a sandbox | rules and skills published to the organisation's `.agents` repository; an optional bootstrap in the repository (section 4.11) |

Section 11 lists the implementation order.

---

## 3. Names

| Name | What it is | Where it comes from |
| :--- | :--- | :--- |
| `setup-ai-core` | this repository, public: the harness every project shares | fixed |
| `<prefix>-ai-core` | the private harness of one project, `github.com/<org>/<prefix>-ai-core` | `prefix` is the repository name up to the first `-`. `shop-web` and `shop-api` both belong to `shop-ai-core`. |
| `ai-core` | the command on the developer's machine | fixed; not a GitHub name |
| `.ai-core/` | the data of the harness inside a checkout: the assembled rules, the configuration, documents. No scripts; those run from the clone as `ai-core <command>`. | fixed |
| `~/setup-ai-core` | the clone of this repository on a developer's machine (or any clone named with `install --source`); its `bin/` is on the PATH and holds the `ai-core` command and every script. | the repository's name |
| `<project folder>/<prefix>-ai-core` | the clone of a project harness on a developer's machine, beside the repositories it serves and visible like them; `init` clones, pulls or creates it (a clone an earlier version kept under `~/.<prefix>-ai-core` is moved there), `update` pulls it | the harness's name |
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
├── bin/          the ai-core command and every script: install, doctor, init, session-start, and the
│                 board and issue commands (issue-new, start-issue, board-sync, status, ...)
├── lib/          the libraries of the commands (board, tracker, common, github/, layers, status), gitignore-block, binding-rules.md
├── rules/        one file per section (NN-slug.md) and skills.md, generic
├── skills/       the skills every checkout gets: person-in-charge, helper
├── skeleton/     what a new project harness starts from
├── templates/    the files a checkout gets, in the layout of the checkout, among them the data files
├── auto-mode.tsv the steps Claude Code's classifier allows in every project, written into the user settings
└── tests/        the check that proves the harness, and one test per board command

<org>/<prefix>-ai-core (project harness, private; skeleton/ of this repository is what it starts from)
├── ai-core.json  extends (another harness), setup-ai-core (the version it needs)
├── rules/        one file per section, NN-slug.md: the same name as a generic section replaces it, a new name adds one
├── skills/       one folder per skill, SKILL.md and its files
├── docs/         documents for agents: what the code cannot say
├── config.env, labels.tsv, assignees.tsv, team-modes.tsv, models.tsv   the project's settings and data
├── auto-mode.tsv the steps Claude Code's classifier allows in this project, written into the user settings
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
│   ├── config.env                       the agents served, the organisation: managed from the harness, else yours
│   ├── labels.tsv, assignees.tsv        the label taxonomy and who owns which repository's issues: the same
│   ├── team-modes.tsv                   the team modes per tool, with probe and install command: managed from the harness, else setup-ai-core's table
│   ├── models.tsv                       the model and effort of every package phase, by class: managed from the harness, else setup-ai-core's table
│   ├── docs/                            yours: documents for agents; docs/<harness>/ managed: the docs of each layer
│   ├── STAMP                            managed: the commit of setup-ai-core and of every layer this was assembled from
│   ├── DEPLOYED                         managed: what the layers put here; what a layer no longer provides is taken out at the next run
│   └── solution-path.template.md        yours: template of a solution path
├── .claude/skills/, .agents/skills/     managed: the skills of every layer, one folder each
├── .claude/agents/                      managed: the agents of every layer
├── AGENTS.md                            managed: the map from repos/<repo>/ of the harness, else the generic one of templates/, the binding rules on top
├── CLAUDE.local.md                      only where the repository has a CLAUDE.md of its own: imports AGENTS.md; created once
├── AGENTS.override.md                   managed, where Codex is served: what Claude Code loads here, each @ file written out, because Codex follows no @
├── .cursorrules, .windsurfrules         Cursor and Windsurf pointers
├── .github/copilot-instructions.md      Copilot pointer
├── .openhands/microagents/repo-rules.md OpenHands microagent
├── .claude/settings.json                Claude Code: the session-start hook, ai-core by its full path; the permission Bash(ai-core:*);
│                                        the status line ai-core statusline
└── opencode.json                        OpenCode: the rules as its instructions; created once
```

A project folder gets the same, except that its `AGENTS.md` is generated: the binding rules, each
file imported, then the list of the repositories in it, each with the path of its map, rewritten on
every `init` because the folder changes. An agent started in the folder has the rules from its
first prompt, and Claude Code loads a repository's map when it works there.

**Managed** files are replaced on every run of `init`. Do not edit them; edit the layer they come
from. Every other file is created once and never overwritten. All of it is registered in
`.git/info/exclude`.

### 4.3 Nothing is committed

`init` writes a block into the project's `.gitignore` (`lib/gitignore-block`): every file an agent
or the harness puts into a checkout, `/.ai-core/`, `/AGENTS.md`, `/.claude/`,
`/.agents/`, the pointer files. The block stands between two marker
lines and only the block is rewritten, in its place, on every run: every other line is the
project's and stays as it is, blank lines, the lines after the block and CRLF line ends too, and
a file without a block gets it at its end. A start line without its end line leaves the file
alone, because nothing tells the block from the lines after it; the report names it. A path the project already ignores is not written twice, and a project
that ignores them all gets no block, or loses the one it had where it stood. Only the main
checkout writes the block: `init` commits that `.gitignore` on its own (subject `the agent files
of this repository are ignored`, a `No-issue:` trailer naming `init`) and pushes it by ref to the
branch checked out, through the push gate where the repository carries one. A worktree keeps the
`.gitignore` its branch has and takes the block when it rebases. Before that commit the checkout is brought level with its origin:
fetched, and fast-forwarded where it is only behind, so a clone another machine already served
takes the block from there instead of committing it twice; a clone behind its origin with commits
or changes of its own gets no block, and the report says why. From then on no clone of the
repository commits an agent file, with or without the harness.

`init` also writes every path it deploys into `.git/info/exclude` of the clone, between two marker
lines, rewritten on every run, which covers the clone before that commit.
In a worktree, git resolves that file to the main checkout, so all worktrees share it, and it
keeps the deployed files out of `git status` in a worktree whose `.gitignore` has no block yet;
this step never touches the project's `.gitignore`. A file
the repository already tracks stays tracked: an exclude entry never affects a tracked file, and
`init` never overwrites a tracked file.

Because the harness is not in the repository, it does not travel with `git clone`. **Every clone
runs `init` once.** It is idempotent and takes seconds. A worktree runs it by itself: git runs
`.githooks/post-checkout` in the new tree after `git worktree add`, and that shim starts
`ai-core init` where `.ai-core/` is missing; `init` in a worktree first takes the checkout's own
`.ai-core/` data (its configuration, local rules and documents), then assembles the harness over
it as in the checkout.

A worktree that `start-issue` opens lives in `<project folder>/.worktrees/<repo>/`, where `..`
holds no other checkout. So `init` in such a worktree links every other checkout of the project
folder into `.worktrees/<repo>/`, as `../../<name>`, and a path such as
`../other-repo` finds from the worktree what it finds from the checkout. An entry that already
stands there is kept, a folder that is no repository gets no link, and `init --all` passes the links
by.

Five files are the repository's own and are committed, because they say what the repository
wants judged and how a worktree starts: `.githooks/pre-push`, the three-line shim that starts the
push gate, and `.githooks/post-checkout`, the shim that starts `init` in a new worktree (section 4.12);
`scripts/check.sh`, the repository's check;
`scripts/install.sh`, the install that check needs, which `integrate-issue --from-origin` runs in its
temporary worktree before the push;
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

1. The clone `<project folder>/<prefix>-ai-core` exists, beside the repositories: its origin is
   checked against the name and it is pulled (offline, it is used as it is). A clone an earlier
   version kept under `~/.<prefix>-ai-core` is moved there first. A clone with no commit of a
   repository with none, cloned by hand, is filled as in 2.
2. It exists on GitHub: cloned there, through `gh`. An empty repository, made by hand by whoever
   has the right to create it under that owner (the owner of a repository you only push to, say),
   is filled from `skeleton/` plus `config.env`, `labels.tsv` and `assignees.tsv` by the first `init` and pushed, said as
   `filled: <org>/<prefix>-ai-core, empty on GitHub, from the skeleton`.
3. It exists nowhere: created, private, from `skeleton/` of this repository plus the same three
   files, and pushed, through `gh repo create`. The first developer of a project gets the harness
   made for them; without the right to create it, `init` says so and the checkout gets the generic
   harness only.

The skeleton carries a `.gitattributes` (`* text=auto eol=lf`), so every checkout of a harness is
LF on every operating system: its `.githooks` shims run through bash, and a `.tsv` keeps its last
field. A clone made before the skeleton carried it gets the lines it lacks on its next
`init`, said as `note: <org>/<prefix>-ai-core: .gitattributes from the skeleton written into ...`;
the next `ai-core push` commits them.

A harness may extend another: `ai-core.json` `{"extends": "<org>/<name>-ai-core"}`, a company
harness under several projects for example. The chain is resolved base first, a circle or more
than eight layers is refused, and `"setup-ai-core": ">=1.1.0"` in `ai-core.json` stops `init` when
the clone of this repository is too old for the harness.

Then `init` assembles the checkout, later layer wins: the rules as above; `rules/skills.md` of the
last layer that has one; every `skills/<name>/`, setup-ai-core's own first, into
`.claude/skills/<name>/` and `.agents/skills/<name>/` (setup-ai-core brings `person-in-charge` and
`helper`, section 4.6); every `agents/<name>.md` into `.claude/agents/`; every `docs/` into
`.ai-core/docs/<harness>/`; `config.env`,
`labels.tsv`, `assignees.tsv`, `team-modes.tsv` and `models.tsv` into `.ai-core/`; and every file under
`repos/<repo>/` of the innermost harness over the checkout, in its own layout, so
`repos/shop-web/AGENTS.md` is the map of shop-web and `repos/shop-web/.ai-core/config.env` its
configuration. A file the repository tracks is never overwritten. `.ai-core/STAMP` records the
commit of setup-ai-core and of every layer the checkout was assembled from. `.ai-core/DEPLOYED`
records what the layers put into the checkout (skills, agents, docs, the files of `repos/<repo>/`);
what a layer no longer provides is taken out again at the next `init`, a file the repository
tracks excepted.

A project folder (section 5.8) gets the layers every repository under it shares: the company
harness when the repositories belong to different projects that extend it, the project harness when
they all belong to one. `init` on a checkout of a harness itself is refused; the harness is edited
like any repository and reaches every checkout at the next `init`, and `ai-core update` pulls every
harness clone of the project folder you stand in.

Changing what agents read is therefore: edit a file in the clone beside the repositories
(`<project folder>/<name>-ai-core`), then `ai-core push`, which commits what changed in every
harness clone of that folder with the message you give (or
the names of the files), pulls with rebase, pushes, and refreshes the checkout you stand in. The
harness clones carry the push gate too (section 4.12), so the message is the reason the gate wants:
unless it names an issue (`#<n>`) or carries a `No-issue:` trailer of its own, the commit gets
`No-issue: <message>, committed and pushed by ai-core push`.
Nothing is copied by hand, nothing is committed to a project repository, and a new developer runs
`install` and `init`.

### 4.6 Skills

A skill is a folder with a `SKILL.md` inside: instructions in prose, sometimes with scripts. A CLI
loads every skill it finds in its skill directories when it starts; there is no activation step.
Claude Code loads `.claude/skills/<name>/` in the repository and `~/.claude/skills/` on the
machine. Codex, Antigravity and OpenHands load `.agents/skills/<name>/` in the repository. OpenHands also
loads the skills of a repository named `.agents` under the GitHub organisation, for every
repository of that organisation, and `~/.agents/skills/` on a developer's machine.

**Today** `rules/skills.md` names three practices of the agent, which nothing installs or switches
on, and says when an agent uses the skill `archify`, the team mode; `.ai-core/team-modes.tsv`
says, per tool, how the harness sees that a mode is installed (a plugin the tool lists, a skill
folder, a file) and the command that installs it. The tool loads the skill when a task calls for it.
`ai-core team-modes-check` probes the tools on the machine and refuses when a mode is missing;
`session-start` and `start-issue` run it first, so no session starts without the modes;
`ai-core team-modes-install` runs the install column for every missing one, and `doctor` runs it
for the tools on the machine, so `install` and `init` leave the modes installed; a plugin loads when
the tool starts, so the tool is restarted once. Every install command installs a fixed version,
the one proven on a machine: a skill at a tag or commit through the tree URL of the skills CLI, a
Claude marketplace at a tag, a Codex marketplace and a Gemini extension with `--ref`; the header
of `team-modes.tsv` names what a tool does not hold (Codex installs a plugin's newest version
whatever the ref), and a newer version comes in by changing a row and verifying it again. The project's own skills are folders in the project
harness, `skills/<name>/SKILL.md`, and `init` copies them into `.claude/skills/` and
`.agents/skills/` of every checkout, where Claude Code, Codex, Antigravity and OpenHands find them
on start; no developer installs a skill by hand.

**The skills setup-ai-core brings.** Every checkout gets two:

- `person-in-charge` is the skill of the session the owner names coordinator of a project, in one
  tool: Claude Code, Codex or agy. Each tool is its own ecosystem; a `<tool>:<model>` row or the
  owner's temporary instruction starts a phase on that tool while the package keeps its
  coordinator's ecosystem and number block. The coordinator writes no code. It cuts the open issues
  into packages by area: one
  capability across every repository it touches, with both sides of each contract named by
  `file:line`, cut so that one build session finishes it alone; packages that share a file or a
  contract run one after the other. Every package is a section of one plan issue per board, titled "Plan:
  packages", with its ecosystem, class, repositories, contracts and issues.
  - Before the first plan, the coordinator clears what earlier sessions left in `implementing` and
    `testing` (`briefs/clearing.md`). A package then runs through its phases: plan, plan check,
    build and test, review, start check, land, release to the test stage, UI test, release to
    production and live check. The plan, the plan
    check, the build, the review and the UI test are fresh sessions, each ended with its phase and
    started with one brief from the skill's `briefs/` (its input, what to do, the exact shape of
    its output) on the commands of `references/<tool>.md`; the start check (`START_CHECK` of
    `config.env`), the landing and the release are the coordinator's own commands. No session is
    given a second phase, because the state lives in the tracker and on the branch.
  - The model and effort of each phase follow the package's class (`mechanical`, `normal-hard`,
    `high-risk`) and come from `.ai-core/models.tsv`, one block per tool; the plan runs on the
    `high-risk` or the `normal-hard` row, because the plan decides the class. The reviewer never runs on the
    model that built the package, by the table's rows. A session never moves a phase to another
    model or tool on its own because a quota ran out: its package waits; an owner's temporary
    selection is reported and expires on withdrawal or coordinator restart, without changing the
    template rows. The issues nobody planned belong to the first tool of
    `ECOSYSTEM_ORDER` in `.ai-core/config.env`; a later tool's coordinator plans what the owner
    hands it.
  - The cards move through `backlog`, `ready`, `planned`, `implementing`, `review`, `testing` and
    `done`; a question that is the owner's puts `needs:owner` on its issues.
  - At the usage limit every session using that limited account or model finishes its step, commits,
    reports and waits for the reset; the coordinator checks the selected tool with
    `ai-core usage --tool claude` or `ai-core usage --tool codex` before starting its phase.
    Asked for the state, the coordinator builds one page from `ai-core status`.
- `helper` hands a bounded task inside a phase, such as a pre-review of a diff, facts across
  repositories, a log or a screenshot, to the small model of the session's own tool, the `helper`
  row of `models.tsv`: `claude -p`, `codex exec` or `agy -p`. Its answer is a lead the session
  checks. It runs no UI test, no build and no deciding review.

### 4.7 Maps: what the code does not say

A search finds what is in the code: where a symbol is, who calls it, what a file exposes, how the
repository is laid out. A **map** says only what is not in the code, in
five fixed sections and at most 80 lines, because every session reads it:

1. **What it is** — three sentences: what it is for, who uses it, what it is not.
2. **Shape** — one line per top-level directory that matters, and the entry points.
3. **Build, check, run** — the exact commands, as the manifests and the CI define them.
4. **Where to add things** — a table: what is added, where it goes and where it is registered.
5. **Rules of this repository** — written by people, kept through every regeneration.

No directory trees and no symbol lists: a search finds those.

**`ai-core map`** (`bin/map.sh`) writes the map of the checkout it runs in: the
agent CLI named by `MAP_TOOL` in `.ai-core/config.env` (`claude`, `codex` or `agy`, each in its
non-interactive read-only mode; `MAP_MODEL` when not the CLI's default; `AI_CORE_MAP_TOOL` and
`AI_CORE_MAP_MODEL` in the environment name the CLI and the model of one machine, and the
project's model goes only with the project's CLI; a `claude` run gets the denials of
`~/.ai-core/claude-run-settings.json` through `--settings`, and `map` stops with exit 1 where
that file is missing, which `ai-core init` writes) reads the repository cheaply, its
manifests and the README, and
outputs the file in the fixed shape; `map` checks that shape (the title `# <repo> — the map`,
the five headings in order, at most 80 lines) and refuses anything else, keeping the output at
`.ai-core/map.rejected.md` for a look. With `agy`, `map` first asks `agy models` and stops with
agy's own words when agy cannot run in the session; over SSH agy keeps its sign-in in a file of
its own, not in the desktop's keychain, and the message says so. Section 5 comes back from the
map that exists. The file goes into the project harness as `repos/<repo>/AGENTS.md` with a first
line naming the commit it was generated from, the harness is committed and pushed (`push`), and
the checkout assembled again, so the map is in place at once. A map the code gives again word for
word is confirmed: only its first line moves to the current commit (`Map confirmed at <commit>`),
so the distance `session-start` counts begins there; at the commit it names already, nothing is
written (`Map unchanged`). In the checkout, `init` opens every map, a generated one or,
where the repository has none yet, the generic one of `templates/`, with the block
`## Binding rules` from `lib/binding-rules.md`, after the header line and the title: the rules, the
local rules and the skills file, each named after `@`, the documents of the project,
`ai-core --help` for the harness commands, and a line saying that an instruction file naming other
places for these, a machine-wide
`CLAUDE.md` among them, is out of date. Claude Code loads a file an
`AGENTS.md` names that way at launch, whole, so the rules are in the agent's context from its first
prompt; any other tool reads where they are. A checkout inside a project folder whose rules are the
folder's names them without the `@`, because the folder's `AGENTS.md` already loads them and Claude
Code loads every `AGENTS.md` above the directory it starts in; the local rules are imported once
they are more than the template. The map in the harness stays what the tool wrote. A repository
with a `CLAUDE.md` of its own makes Claude Code read that file instead of `AGENTS.md`, so `init`
writes a `CLAUDE.local.md` beside it that imports `AGENTS.md`; it is never committed, created once,
and a `CLAUDE.local.md` that is somebody's own is left alone with a note. `ai-core map --all <folder>` does it for every repository
under a folder with one push and `init --all`; `--no-push` writes into the clone and stops;
`--dry-run` prints the map. `session-start` prints `Map`: generated from which commit and how
many commits behind, or `Generic (run ai-core map)`. Until `map` has run, `AGENTS.md` is the
generic map of `templates/`, which says there is none yet, under the same block; an `AGENTS.md`
the repository tracks, or somebody's own, is kept. No `CLAUDE.md` is needed: Claude Code reads
`AGENTS.md` by itself, or through the `CLAUDE.local.md` above where the repository keeps one.

### 4.8 The session start

`ai-core session-start` is the first step of every session, run in the repository or in the
project folder. `AGENTS.md`, the OpenHands microagent and the rules say so; Claude Code runs it
through the `SessionStart` hook in the checkout's `.claude/settings.json` (deployed by `init`, or
merged into a `settings.json` the checkout had), every other agent runs it because the instruction
says so. It runs `team-modes-check` first and stops with its refusal when a mode is missing. Then it
prints:

```text
Branch           : master
Uncommitted files: 0
Harness version  : 1.2.0
Harness state    : ✓ Assembled from the current harness
Releases         : ✓ Current
Rules file       : ✓ Present (.ai-core/rules/rules.md)
Local rules      : ✓ Present (.ai-core/rules/rules.local.md)
Map              : ✓ Generated from 1a2b3c4, current
GitHub status    : ✓ Authenticated as @you
Ready for task execution.
```

In a project folder the branch line says `not-a-git-repo`.

A harness source is different from a product checkout. Its Git origin names `setup-ai-core`
or a repository ending in `-ai-core`; its source inputs must also be tracked and valid.
Run `session-start` directly there, without `init`. It validates the command's generic rule
source and the harness's local source chain, including compatible `ai-core.json` requirements,
rules, skills, and agents. A missing inherited source or invalid input refuses startup. It
neither downloads sources nor writes product assembly files. The source output names the rule
directories to read and says `Source inputs validated (no assembly)`; its map is `README.md`.
`start-issue` and the checkout hook preserve this source workflow in issue worktrees. `init`
refuses sources before copying any inherited product data.

In a worktree named `issue-N-<slug>`, the shape `start-issue` creates, it also prints the thread
of issue N, read through `issue-thread`, and whether the issue is assigned to you (`issue-mine`).
The issue is read in the repository `start-issue` recorded on the branch where the issue lives in
another one, and where it cannot be read, the last line says so instead of a plain "Ready".

With `--json` it prints the same as JSON: `repository`, `root`, `branch`, `uncommitted_files`, `harness_version`,
`harness_current`, `harness_stamp`, `release_state`, `release_lines`, `map_commit`, `map_behind`,
`rules_present`, `rules_path`, `local_rules_present`, `gh_authenticated`,
`gh_user`, `issue`, `assigned`, `thread`, `harness_source`, `source_ready`, `source_error`,
`rule_sources`. For a source, `harness_version` names the command source version,
`harness_current` is null, and `rules_present` and `rules_path` say whether an assembled rules
file lies on disk; a source's readiness does not depend on it.
The `rule_sources` directories are ordered base first. For a product, the source identity and
readiness are null and the source directories are empty. Exit status is 1 when required product
rules or valid source inputs are missing; `refused` is true for that refusal.
If `gh` is logged in, it makes one call to the GitHub API for the user name.

With one `--tool <name>` (`-Tool <name>`), the form the hooks use, the output is the agent's
context, and Claude Code passes a hook's output whole only up to a size: in a measured run of
Claude Code 2.1.282, 10 000 characters arrived whole and 15 000 arrived as a 2 KB preview, the
rest in a file the agent never opens. So the issue thread is cut after 3 000 characters and the
uncommitted files after 20 lines. The rules are not printed: Claude Code loads them through the
binding rules in `AGENTS.md`.

It compares `.ai-core/STAMP` with the setup-ai-core clone and the project harness clones beside the
repositories, and reports the checkout as assembled from the current harness or from an older one.
**Planned:** re-assembling the checkout when a layer changed, so a rule change in a layer reaches
every checkout at the next session without running `init` again.

### 4.9 What each agent reads

| Agent | Reads at start | Mechanically active |
| :--- | :--- | :--- |
| Claude Code | `AGENTS.md` of the directory it starts in and of every directory above it, with the files each imports after `@` (the rules, the local rules, the skills file), and a repository's `AGENTS.md` once it works there; where a `CLAUDE.md` exists, that file and the `CLAUDE.local.md` that imports `AGENTS.md`; `.claude/settings.json`, `.claude/skills/` | the `SessionStart` hook `ai-core session-start --tool claude`, which refuses a session without the team modes; the `PermissionRequest` hook `ai-core permission-request`, which denies a prompt nobody would answer in a background session; the status line `ai-core statusline`; permissions from the harness |
| OpenAI Codex | `AGENTS.override.md`, else `AGENTS.md`, from the repository root down to the working directory, concatenated, raw (no `@` import) and up to `project_doc_max_bytes`: `init` writes the override where Codex is served, with what Claude Code loads there written out (the project folder's `AGENTS.md`, this one, every file either names after `@`), and raises `project_doc_max_bytes` in Codex's user config to 262144 where it is lower; `~/.codex/AGENTS.md` for the user; `.agents/skills/` in the repository and `~/.agents/skills/`; MCP servers from `.codex/config.toml` in the repository (read once the project is trusted) and from `~/.codex/config.toml` | skills; MCP from `.codex/config.toml`, not from `.mcp.json` |
| OpenCode | the nearest `AGENTS.md`, without its `@` imports, and the files `opencode.json` names under `instructions`: the rules, the skills file and the local rules | nothing beyond its own defaults, which already refuse reading `.env` |
| Zed, Aider | `AGENTS.md` | nothing; text only |
| Google Antigravity (`agy`) | `AGENTS.md` (prepended to every prompt), `.agents/skills/` | skills; MCP only from `~/.gemini/config/mcp_config.json`, machine-wide: its documentation names `.agents/mcp_config.json` in the repository too, but `agy` does not load it (tested with `agy --print`, with a valid machine-wide file) |
| Cursor, Windsurf, Copilot | `.cursorrules`, `.windsurfrules`, `.github/copilot-instructions.md`, deployed only when `AGENTS` names them | nothing; a one-line pointer to `AGENTS.md` and the rules |
| OpenHands | `AGENTS.md`, `.agents/skills/`, the organisation's `.agents` repository, `.openhands/setup.sh`, `.openhands/hooks.json`; the microagent pointer the harness deploys today is the older convention | `setup.sh` runs at every start with the repository; hooks on `SessionStart`, `PreToolUse`, `PostToolUse`, `UserPromptSubmit`, `Stop`, `SessionEnd`; skills |

Except for Claude Code, everything is text that an agent reads and follows. That is how these
tools work; the harness gives them the text at the place they look.

### 4.10 Claude Code details

- Claude Code 2.1.277 or newer reads `AGENTS.md` by itself when the repository has no
  `CLAUDE.md`, and loads what it imports after `@`. Where the repository keeps a `CLAUDE.md` of its
  own, `init` writes an untracked `CLAUDE.local.md` with the line `@AGENTS.md`, so nothing is added
  by hand.
- **Checking a session.** Started in a project folder or a checkout, a session has the rules and
  the map without a word from you. To see it, send this as the first message:
  `Quote from your context only, without a tool and without reading a file: the first sentence
  under the heading "The code never lies to the person using it", and the start of the first rule
  of your project harness.` The answer is `This section outranks every other section.` and that
  rule. The transcript,
  `~/.claude/projects/<project>/<session>.jsonl`, shows what each `SessionStart` hook delivered; an
  output marked `Output too large` reached the agent only as a 2 KB preview.
- `.claude/settings.json` is created once with the `SessionStart` hook, the `PermissionRequest`
  hook `ai-core permission-request`, which answers a permission prompt in a background session
  (`CLAUDE_JOB_DIR` set) with a deny and a message that names the call and the ways that need no
  prompt, because nobody sits at that terminal and the prompt would wait for good, the status line
  `ai-core statusline`, which records the account's usage windows for `ai-core usage` (section 6),
  and the permission `Bash(ai-core:*)`, so an agent runs the harness commands without a prompt.
  The hooks and the status line name `ai-core` by its full path on this machine, so a Claude Code started from a terminal opened
  before the install still runs them; the file is the machine's and never committed. If your
  repository already has one, `init` keeps it, merges in the hook and the permission where they are
  missing, once, replaces an `ai-core` hook of an older form, and sets the status line to
  `ai-core statusline` in place of another one, because `ai-core usage` reads what it records. It also denies, and merges into an existing one
  the same way: reading or editing a checkout's `.env`, `.env.local`, `.env.*.local` and any `*.env`
  (except `config.env`, the harness's own file, which the entry `!config.env` carves out) and any
  `*.pem` and `*.key`, reading or editing `~/.netrc`, reading
  the machine's credentials (`~/.ssh`, `~/.aws`, `~/.git-credentials`, `~/.npmrc`, `~/.config/gh`,
  `~/.docker/config.json`, `~/.kube`), `git push --force`, `-f` and `--force-with-lease`, `git reset --hard`
  and every `git clean`. A Read or Edit denial holds Claude Code's file tools, the file commands it
  recognizes in Bash (`cat`, `head`, `tail`, `sed`, `tee`) and the targets of redirections; it does not
  hold a command that reads files without naming them, such as `grep -r pattern .`, or a script that opens
  files itself (Claude Code's permissions documentation, section "Read and Edit"). A Bash denial
  holds the command as written: `git -C . reset --hard` or `sh -c '...'` is not matched. A `claude -p` run from a throwaway folder reads
  no checkout's `settings.json`, so `init` also writes the same denials, with `**/` patterns anchored at the
  filesystem root (`//**/`) and without the `!config.env` entries, to `~/.ai-core/claude-run-settings.json`,
  which the skills pass with `--settings`. Claude Code applies allow rules from
  a committed or excluded project `settings.json` only after you accept its trust dialog for the
  folder.
- **Auto mode.** Claude Code's classifier reads `autoMode` only from the user settings,
  `${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json`, from managed settings and from `--settings`,
  never from a repository's `.claude/settings.json`. So `init` writes the entries of
  `auto-mode.tsv` there: setup-ai-core's own, which every project gets, and those of every layer of
  the checkout, each led by its layer's name, `[setup-ai-core] ...`. One line per entry: the list,
  `allow` or `environment`, a tab, the entry as prose the classifier reads. `init` replaces the
  entries of the layers it assembled, keeps your own and those of other layers, keeps
  `"$defaults"` and puts it first in a list it creates, and takes out an entry of yours whose text a
  layer now carries. Its report names every entry it added or removed; a line it cannot read stops
  it before it writes anything. Whoever can push to a layer can widen the classifier on every
  machine at the next `init`, so an entry is reviewed like a rule. A machine where Claude Code
  never ran has no settings folder, and `init` creates none.

### 4.11 Agents that run in a sandbox (OpenHands, cloud agents)

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

### 4.12 The push gate: `ai-core pre-push`

One gate judges every push of every repository, and it lives in setup-ai-core, not in the
repositories: each repository carries a three-line `.githooks/pre-push` that only starts
`ai-core pre-push` with git's own standard input, and `core.hooksPath` of the clone points at
`.githooks`. Beside it lies `.githooks/post-checkout`, the shim that gives a new worktree the
harness: git runs it in the new tree after `git worktree add`, and where `.ai-core/` is missing it
starts `ai-core init`; it exits 0 whatever happened, because a failing hook would fail the
checkout too, and what went wrong stands on stderr. `ai-core pre-push --install`
writes both shims into the current repository, and into each worktree of it the shims that
worktree's own commit lacks (a relative `core.hooksPath` is read from the tree git works in, and git
runs the files on disk), sets
`core.hooksPath`, and says what to commit; with `--all <folder>` it does so for every repository
under a folder, and it commits the shims on their own (a `No-issue:` trailer naming the command)
and pushes them by ref through the gate, after bringing the checkout level with its origin the
way `init` does before its `.gitignore` commit; where that push is refused, a commit the origin
moved past while the gate ran goes on top of it and is pushed once more, and any other refusal
undoes the commit and leaves the hooks as they were, so no commit of it stays ahead of the origin;
a worktree keeps what it gets for its own commit, and a shim that an earlier install rewrote in a
worktree whose commit carries it goes back to that commit, so `finish-issue` finds the worktree
clean; any other change there stays and is named. Git runs the shims through bash, and a shim checked out with CRLF fails on its first
line, so where no rule of the repository's `.gitattributes` makes them check out with LF the
install adds `.githooks/* text eol=lf` to that file and commits it with them. An unpushed commit ahead of origin that names no
issue and touches nothing but `.gitignore`, written by an `init` from before `init` committed the
block itself, gets the `No-issue:` trailer that says so, author and subject kept, so the push
goes through. `init` sets `core.hooksPath` in a clone that carries the shim, so a fresh clone is
armed by its first `init`.

The gate judges, in this order, stopping at the first refusal (`pre-push: REFUSED — ...`, exit 1):

1. **The pushed commit is the one checked out.** Work is pushed by ref, `git push origin
   HEAD:<branch>`; an annotated tag is resolved to the commit it names. Beside the default branch a
   ref may name another commit when origin already carries it, so the push sends nothing new: a
   release put on a stage by its deploy ref from a checkout that has moved on. A push to the default
   branch (`origin/HEAD`, else `master`) must be a fast-forward: one that would drop commits the
   remote has, a force push, is refused, whatever tool or person made it.
2. **Every pushed commit names its issue**, `#<n>` anywhere in the message, or is excused: the
   subject opens with `release:`; every file it touches is a `*.md` or a `LICENSE*` (an
   explanation needs no ticket); or it carries a trailer `No-issue: <who asked and why>`, read the
   way git reads a trailer, so an empty one and the two words inside a sentence do not count.
   The message of a merge is not judged, but a merge the remote does not have runs the checks on
   its tree like any new commit. So does every push that moves the default branch, also a branch
   pushed for review that lands as a fast-forward, whose commits origin carries already. A deletion runs nothing, and what is judged is exactly what the remote
   does not have yet: the local commit without the remote sha and without every ref of origin
   this clone knows, so a branch that merged the default branch is judged on its own commits, not
   on those the default branch published, and a tag introduces nothing.
3. **The team modes are installed** (`ai-core team-modes-check`, section 4.6).
4. **A pushed file that starts with `#!` carries the executable bit**, because it is run by its
   name and git skips a hook without it; the refusal names the `git update-index --chmod=+x` to run.
5. **Every subject is at most 72 characters, no message carries an assistant's or a vendor's
   attribution** (a `Co-Authored-By:` or `Generated with` line naming one), **and no author or
   committer is an assistant** (a vendor's address, an assistant's GitHub bot, or a name that is
   only an assistant's, the identity a cloud session commits under unless the person sets their
   own); a person as co-author, or one named Claude with an address of their own, passes. **Every
   pushed commit, a merge too, carries as author and committer the address `git config user.email`
   holds in the repository**, compared without regard to case: the refusal lists each commit as
   `<hash> author <address>, committer <address>` with the `--reset-author` rewrite, and a
   repository with no `user.email` is refused with the command that sets one. Only the commits the
   push adds are read, so a commit on a ref of origin this clone knows, another person's or a
   platform bot's, never refuses a push; one origin has and this clone has not fetched is read as
   new, and the refusal tells to `git fetch origin` first and to rewrite only your own commits.
   None of the four has an excuse.
6. **No added comment names an issue by its number**, `(#<n>)` or `<repo>#<n>`, judged on the
   comment part of the lines the push adds, Markdown, JSON and lock files left out; the issue is
   named in the commit message instead. A number in code that is no comment passes.
7. **A migration that exists is not changed or removed**: a `migrations/*.sql` the push modifies,
   renames or deletes is refused, a new one passes. A commit with a `Migration: <why>` trailer may
   change one that never reached a database.
8. **A default branch that goes live is landed with checks and a review**: where the repository's
   `.ai-core/config.env` says `DEFAULT_BRANCH_IS_LIVE="yes"`, a push to the default branch is refused
   without `scripts/check.sh`, and its last commit carries a `Reviewed-by: <reviewer>` trailer.
9. **The names of new directories are derived, not invented**, read from the families the trees
   already carry, with no list kept anywhere. A new `<a>` beside `<a>-<x>`, or the reverse, names
   one member of a family and leaves the other unnamed. A new `<owner>-<x>`, in a directory that
   mirrors the repositories of the project folder (two or more entries carry a repository's name),
   names a part of that repository, so `<x>` is one of its top-level directories; a repository's
   owner word is its name after the project prefix, and a word that is a top-level directory in
   two or more repositories is a word of structure and names no repository. A commit with a
   `Naming: <why>` trailer keeps the names it adds.
10. **`scripts/check.sh` is green**, run in the tree being pushed; a repository without one is told
   so and passes on. The check reads the working tree, so a tree that differs from the pushed commit,
   by an uncommitted change or a file neither tracked nor ignored, is refused with the files named.
11. **gitleaks over the commits the push carries**, in a repository that carries `.gitleaks.toml`;
   the commits are the only place a credential taken out again still stands. It runs
   `gitleaks git`, which came with gitleaks 8.19; without such a gitleaks the push is refused and
   `ai-core doctor` named, which installs it. `--install` writes nothing into such a repository
   until one is there, because the push of its own shims would be refused. A merge is read by
   what its author wrote beyond git's own merge, a conflict resolution among it, which needs git
   2.36; an older git is refused by name, because gitleaks would count git's error as no finding,
   and `ai-core doctor` names it too. A merge of three or more branches at once is refused: git
   shows no such diff for it. A finding names the commit, the file, the line and the rule, never
   the value or the commit message;
   a file that had a conflict is named `b/<path>` there, so a path allowlist or a rule path that
   starts with `^` does not match it: the allowlist then refuses more, the rule misses the file.

Run from a prompt or an agent's shell, with nothing on standard input, `ai-core pre-push` judges
the current branch against its upstream: what `git push` would send. `tests/pre-push.test.sh`
drives it with git's input by hand, against a scratch repository, stand-ins
for the check and for gitleaks, and a team-modes table of their own; the merge case runs the real
gitleaks, because only git's own output shows what a merge carries.

---

## 5. Install and use (today)

### 5.1 Prerequisites

| Need | For | Notes |
| :--- | :--- | :--- |
| Linux with Bash 3.2+ | every script | Windows runs the harness under WSL (section 5.9) |
| Git | `session-start`, worktrees, the exclude file | 2.36+ where `.gitleaks.toml` arms the push gate's scan |
| `curl` and `tar` | remote install with `init.sh` | |
| jq | every board and issue command reads GitHub's answers through it | `doctor` installs it |
| gitleaks 8.19+ | the credential scan of the push gate, in a repository that carries `.gitleaks.toml` | `doctor` wants it where a repository of the project folder carries that file, and installs it: brew, on Linux the GitHub release into `~/.local/bin` (apt's package is 8.16); `init` runs doctor in the folder it serves |
| Node.js 20+ with `npm` and `npx` | `ai-core status`, which counts with Node.js; the team modes installed through `npx` | `doctor` installs it |
| `gh`, logged in | with `FORGE=github`, the project harness is found, cloned and created through it, and `session-start` shows the GitHub user; with `TRACKER=github`, every board and issue command | `doctor` installs it; the login is yours |
| `curl` and an access token | with `FORGE=forgejo`, the repository calls (section 5.7); git itself signs in with the same token through `ai-core git-credential` | the token is read from `FORGEJO_TOKEN_COMMAND` at each call; `doctor` asks the instance whether it answers |

### 5.2 Once per machine: `install`

```bash
# Linux, or WSL on Windows
curl -sSL https://raw.githubusercontent.com/kartalbas/setup-ai-core/master/bin/install.sh | bash
```

`install` clones this repository to `~/setup-ai-core`, adds its `bin/` (where the `ai-core`
command lives) to the PATH (the shell profiles; open a new terminal afterwards) and runs `doctor`. Run it again to pull. If you
already have a clone, say so with `--source`: then nothing is cloned, that clone is the
installation, and its `bin/` goes on the PATH. Options:

| Option | Effect |
| :--- | :--- |
| `--source <clone>` | use this existing clone of the repository; nothing is cloned |
| `--dir <path>` | clone somewhere else than `~/setup-ai-core` |
| `--repo <url>` | clone from this URL or path instead of GitHub (a mirror, a fork) |
| `--no-path` | do not touch the PATH |
| `--no-doctor` | do not run `doctor` at the end |

`install` exits 1 when `doctor` finds problems; setup-ai-core is installed anyway, and the problems
are the next steps.

### 5.3 Per repository: `ai-core init`

```bash
cd ~/repos/myorg/myproject
ai-core init
```

`ai-core init` is `bin/init.sh` of the clone, run on the current directory. The
scripts can still be called by path (`bash ~/setup-ai-core/bin/init.sh .`). There is no way to
equip a checkout without the clone: the checkout gets no scripts of its own, so `ai-core` must be
on the machine that runs the agent.

### 5.4 Options of `init`

| Option | Effect |
| :--- | :--- |
| `ai-core init [TARGET_DIR]` | the repository to equip; default is the current directory |
| `--all <folder>` | run `init` in every git repository directly under the folder and in every worktree under its `.worktrees/`, then in the folder itself (section 5.8); `doctor` runs once; a failing repository is named in the summary and the exit code is 1 |
| `--no-doctor` | do not run `doctor` first (CI, or a machine you have checked yourself) |
| `--dry-run` | write nothing; print the report of what the run would create, refresh, keep and remove; `doctor` runs without installing; with `--all` every repository gets its dry run |
| `-h`, `--help` | usage |

An unknown option is an error.

### 5.5 What `init` does, in order

1. Runs `doctor`; while a problem remains, nothing is deployed and `init` exits 1 with the
   instruction.
2. Finds the project harness from `origin` and clones, pulls or creates it, with its `extends`
   chain (section 4.5). Creates `.ai-core/` with `rules/` and `docs/`, and removes a
   `.ai-core/bin/` an earlier version left there. In a worktree it first takes the checkout's
   `.ai-core/` data and links the other checkouts of the folder beside it (section 4.3).
3. Assembles the rules of every layer into `.ai-core/rules/rules.md`, copies `skills.md` and
   `VERSION`, the skills, docs and data files of every layer, the files under `repos/<repo>/`, and
   writes `STAMP`.
4. Copies every file of `templates/` that does not exist yet in the checkout; a file that exists
   is never overwritten. In a project folder `AGENTS.md` is generated instead and rewritten every
   time.
5. Writes the exclude block into `.git/info/exclude`, in the place of the one an earlier run
   wrote, and the block into `.gitignore` (section 4.3). Outside a git repository it says so and
   goes on.
6. Prints the report: what the run did to the checkout.

Every file `init` touches is written only when its content differs, and every file is recorded
under one of these words:

| word | meaning |
| :--- | :--- |
| `created` | did not exist; written |
| `refreshed` | a managed file (the assembled rules, `STAMP`, a skill, a data file, a map from `repos/<repo>/`, the exclude block) that differed from what the layers say; rewritten |
| `kept` | a file created once (`AGENTS.md`, `.claude/settings.json`, `config.env`, ...) that differs from its template, because it is yours; never overwritten |
| `removed` | what an earlier version left in the checkout (`.ai-core/bin/`, `.agents/mcp_config.json`), and what a layer no longer provides (recorded in `.ai-core/DEPLOYED`) |
| `tracked` | a file of `repos/<repo>/` the repository commits itself; not applied |
| `unchanged` | the count of files that were already what they should be |

The report closes with `.gitignore changed` when the block was written, committed and pushed
(or, in a worktree, left to its own commit), with `.gitignore: pulled N commit(s) from origin/<branch>
first; the block was there already` when the origin had it, with `.gitignore not written` and the
reason when the checkout is behind its origin with work of its own, with `.ai-core taken from the checkout <path>` when a
worktree started empty and got the checkout's `.ai-core/` data first, with `core.hooksPath set to .githooks` when the repository carries the push gate's shim and the
clone was not armed yet, with `credential.<FORGEJO_URL>.helper set` when the origin is on the Forgejo instance
and the clone did not sign in through `ai-core git-credential` yet, and with the harness version. A second run on an unchanged checkout reports
only the count of unchanged files.

`ai-core init --dry-run` prints the same report with `would change` and writes nothing, not
even the exclude file, and creates no project harness: one that does not exist yet is announced
as `would be created from the skeleton`.

### 5.6 First check

```bash
ai-core session-start
```

It must end with `Ready for task execution.` and `git status` must show nothing new.

### 5.7 `config.env`

`.ai-core/config.env` carries these keys. Values are case-insensitive; quotes and `# comments` are
allowed; any other value is an error.

| Key | Values | Meaning |
| :--- | :--- | :--- |
| `AGENTS` | names separated by spaces: `claude`, `codex`, `antigravity`, `openhands`, `gemini`, `cursor`, `windsurf`, `copilot`; default `claude codex antigravity openhands` | the agents this project serves. `init` deploys the file of each one named (`.cursorrules`, `.windsurfrules`, `.github/copilot-instructions.md`, `.openhands/microagents/repo-rules.md`) and no other. Empty: every pointer file. |
| `TRACKER` | `github` (default), `plane` | where the project's issues and board live: the folder of `lib/` whose `tracker.sh` every issue and board command calls. A value with no such folder stops the command and names the folders there are. The environment variable `TRACKER` overrides it. |
| `FORGE` | `github` (default), `forgejo` | where the project's code lives: the folder of `lib/` whose `forge.sh` creates and clones the harness repository, waits for the check of a release commit and names the signed-in user. A value with no such folder stops the command and names the folders there are. The environment variable `FORGE` overrides it. |
| `FORGEJO_URL` | the scheme and host of the instance, such as `https://forge.example.test` | with `FORGE=forgejo`: the instance the repository calls go to, and the host `origin` names. No default, and no path: a call that needs it stops and names it. A new project names its forge in the environment of its first `ai-core init`, which creates the harness repository on that instance; the harness's own `config.env`, which every checkout gets, carries the settings from then on. |
| `FORGEJO_TOKEN_COMMAND` | a command | with `FORGE=forgejo`: the command whose output is an access token of the instance. It runs when a call needs the token; the token stands in no argument, no environment and no file, and in no trace of `bash -x`, because curl gets it through its configuration on standard input and git gets it from `ai-core git-credential`. A token with a control character in it, a line break, a carriage return or a tab among them, is refused by the name of this setting before curl or git sees it. A clone that has no `.ai-core/config.env` of its own, such as the clone of a project harness, reads the settings of its project folder. |
| `PLANE_URL`, `PLANE_WORKSPACE`, `PLANE_PROJECT` | with `TRACKER=plane`: the address of the Plane instance, the slug of the workspace and the identifier of the project, the `ENG` of `ENG-142`. None has a default: a call that needs one stops and names it. A work item's `#n` is its number in that project, and one project holds the repositories of one line: a work item names its repository by the label `repo:<name>` (the name the origin spells), which `issue-new` puts on it and `labels-sync` makes once, and a `#n` whose label names another repository is refused. A work item with no such label belongs to no repository and is listed under none. Every Plane path is under `/api/v1`, the only prefix Plane CE 1.4.2 serves. |
| `PLANE_TOKEN_COMMAND` | a command | with `TRACKER=plane`: the command whose output is the API key. It runs when a call needs the key; the key stands in no argument, no environment and no file, because curl gets it through its configuration on standard input, and in no trace of `set -x` or `bash -x`. A key with a line break or another control character in it is refused by the name of the setting. Setting it to `cat <file>` of a file in your home with mode 0600 is the way `gh` keeps its token. |
| `GH_ORG` | a GitHub organisation or user | the owner the board commands act for when a command names no repository (`repo-boards`, `project-new`, `incident-count`, a bare board number). Unset: the owner of the repository the command runs in. The environment variable `GH_ORG` overrides both. |
| `MAP_TOOL` | `claude` (default), `codex`, `agy` | the agent CLI `ai-core map` writes the map with, in its non-interactive read-only mode; `AI_CORE_MAP_TOOL` in the environment names the CLI of one machine instead, for example `agy` where Claude's quota is spent |
| `MAP_MODEL` | a model id, or empty (default) | the model that CLI uses for the map; empty is the CLI's own default. It goes only with `MAP_TOOL`: `AI_CORE_MAP_MODEL` in the environment names the model of one machine, and a machine that names another CLI without it gets that CLI's default (`agy models` lists agy's, e.g. `claude-sonnet-5-5-high`) |
| `UPDATE_CHECK` | `session-start` (default), `never` | whether `session-start` asks `update --check` for a newer release; `AI_CORE_UPDATE_CHECK` in the environment overrides it. Nothing is updated by it |
| `USAGE_STOP_AT` | a percentage, `92` when unset | the usage limit: at it, in any window, every session finishes the step in hand, commits, reports and waits for the reset; `ai-core usage` exits 3 there |
| `LIVE_TAGS` | environments with the pattern of their release tags, the last stage first, separated by spaces, e.g. `prod=deploy/prod/* test=deploy/test/*`, or `landed` as the pattern for a repository with no release tag of its own, e.g. `prod=landed`; empty by default | where `ai-core status` reads a card's work as live: on an environment from the first of its tags that contains the newest commit on the default branch naming the issue, and on a `landed` environment from that commit's landing. Empty: the TESTING block says so and lists the landed cards without an environment |
| `ECOSYSTEM_ORDER` | tool names of `models.tsv`, `claude codex agy` when unset | the order the owner starts the coordinators in; a package stays in the ecosystem whose coordinator planned it |
| `START_CHECK` | a command, empty when unset | run by the person in charge on the bundle of a package's branches before it lands; empty means the project names none |
| `PROOF_HOURS` | hours, `24` when unset | how long a later environment of `LIVE_TAGS` may carry a card the first one does not before `ai-core status` marks its proof there overdue with 🔴 |
| `DEFAULT_BRANCH_IS_LIVE` | `yes`, or the folder names of the repositories whose default branch goes live; unset by default | a push to such a default branch needs `scripts/check.sh` and a `Reviewed-by:` trailer on its last commit (section 4.12) |

### 5.8 Many repositories

The unit of installation is one repository checkout. For a project with many repositories in one
folder, one command runs `init` in each git repository directly under it and in each worktree
`start-issue` put under its `.worktrees/`, skips the folders that are not repositories and the temporary
worktree of a landing (`integrate-<issue>.XXXXXX`, which `integrate-issue --from-origin` removes when it ends), names the
ones that failed, and then equips the folder itself:

```bash
ai-core init --all ~/repos/myorg
```

The folder is where many developers start their agent. It gets the same data as a repository,
an `AGENTS.md` that lists the repositories with the path of each map. Nothing there is under git, so nothing is excluded and nothing can be
committed. An agent started in the folder has the rules from its first prompt, because that
`AGENTS.md` imports them (section 4.7), and Claude Code loads a repository's own `AGENTS.md` as soon
as it works on files inside it, the way it loads nested `CLAUDE.md` files. Each repository still carries its own files, because a repository is also opened
alone: by OpenHands, by CI, by a colleague with another layout.

### 5.9 Windows

The harness is written for Bash 3.2+ and runs on Linux. Windows runs it under WSL: install a WSL
distribution, open it, and type everything of this README there, from the quick start on. A
repository the agent works on lives inside the distribution's file system, where `git` and the
`.sh` scripts behave as on Linux.

With Claude Code: run `claude` in the project folder or the repository, answer **yes** to trusting
the folder. Claude Code 2.1.277+
loads `AGENTS.md` by itself, and with it the rules; a repository with a `CLAUDE.md` of its own gets
a `CLAUDE.local.md` from `init` that imports `AGENTS.md`. With Antigravity: run `agy` in the repository and sign in; it loads `AGENTS.md` by itself.
A new clone or worktree runs `ai-core init` once.

### 5.10 Update and uninstall

**Update:** a release of setup-ai-core is a tag `vX.Y.Z` on the commit `VERSION` names, cut with
`ai-core release X.Y.Z` only when the checks were green for that commit; what is
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

**Uninstall:** delete what section 4.2 lists, and remove the block between
`# setup-ai-core start` and `# setup-ai-core end` from `.git/info/exclude`. On the machine: delete
`~/setup-ai-core`, the harness clones beside the repositories (`<project folder>/<prefix>-ai-core`)
and the PATH entry `install` added (the line marked `# setup-ai-core` in the shell profiles). `npx` keeps its cache.

---

## 6. The scripts (today)

All run as `ai-core <name>` from any directory inside the repository, or from the project folder,
and accept `-h` / `--help`. `ai-core <name>` runs `bin/<name>.sh` in Bash;
a new script in `bin/` is a command without any registration.

| Script | Usage | Exit codes |
| :--- | :--- | :--- |
| `session-start` | `ai-core session-start [--json]`; the JSON says `refused`, and a refusal carries the lines of the team modes; source checkouts validate source inputs without assembly | 0 ready; 1 a team mode, product rules, or valid source inputs missing |
| `solution-path` | `ai-core solution-path <issue> <file> [--check]` | section 7 |
| `rules-check` | `ai-core rules-check [file-or-directory]`; default `.ai-core/rules/rules.md`, or the `rules/` directory of setup-ai-core; a directory means its `NN-*.md` section files; a project harness (a directory with `rules/`, `skills/` or `agents/`) is checked whole: every skill has a front matter with its folder's name and a description, every agent a name and a description and no model below Sonnet, then its rule sections | 0 every rule tagged and nothing wrong in the harness; 1 otherwise |
| `init` | `ai-core init [dir] [--all <folder>] [--no-doctor] [--dry-run]` | 0 in place, or dry; 1 doctor failed, or a repository under `--all` failed |
| `map` | `ai-core map [dir] [--all <folder>] [--no-push] [--dry-run]` | 0 written (or unchanged, or dry); 1 no harness, `~/.ai-core/claude-run-settings.json` missing for a `claude` run, the agent CLI failed or wrote something that is not a map, or a repository under `--all` failed |
| `push` | `ai-core push [MESSAGE] [--harness <name>]`; runs `rules-check` on a clone with changes first and does not commit one it refuses | 0 every harness clone pushed or had nothing; 1 no clone, a clone `rules-check` refused, a commit or a push failed |
| `update` | `ai-core update [--check] [--main]` (section 5.10) | 0 done, or `--check`: everything current; 2 `--check`: a release or commits available; 1 an origin could not be reached |
| `release` | `ai-core release <version>` (in a clone of setup-ai-core, section 10) | 0 tagged and pushed; 1 refused, naming what is missing; 2 a wrong argument |
| `pre-push` | `ai-core pre-push [--install [--all <folder>]]` (section 4.12) | 0 nothing refused the push, or the shim written; 1 refused, or a repository under `--all` is none; 2 a wrong argument |
| `git-credential` | `ai-core git-credential get` (git runs it; `store` and `erase` do nothing): the credential helper `init` and the clone set for an origin on the `FORGEJO_URL` instance, as `credential.<FORGEJO_URL>.helper` in the clone's own `.git/config`, an empty entry and then `!ai-core git-credential`: the empty entry drops the helpers git takes from the system and the user's configuration, a `store` or a cache among them, which would keep the token and answer with it after the token command changed. It answers git's `get` with the username `ai-core` and the token that `FORGEJO_TOKEN_COMMAND` prints at that moment, and answers nothing for any other host or for http where `FORGEJO_URL` is https. An origin over ssh needs none of it | 0 answered or nothing to answer; 1 the token command failed or printed nothing; 2 a wrong argument |
| `usage` | `ai-core usage [--tool NAME] [--stop-at N]` | 0 every window below N; 3 a window at N or more; 2 nothing recorded yet, or a wrong argument. Prints the selected tool's last recorded usage windows (five hours, week); `--tool` overrides session detection, which defaults to Claude outside Codex, and exit 2 means unknown usage rather than a successful preflight. The selector accepts `claude` or `codex`. Each window has its reset time, against the limit N: `--stop-at`, else `USAGE_STOP_AT` of the project's `config.env`, else 92; a window whose reset has passed counts as reset. One model's own weekly quota is not among them |
| `watch` | `ai-core watch [--session NAME]... [--ref CLONE:REF]... [--file PATH]... [--still S] [--every S] [--heartbeat S]`, run in the background by a session that oversees others, so its end wakes that session | 0 one line names what happened: a named session has not been `busy` in `claude agents` for `--still` seconds (900), or left it; a ref moved, its clone fetched every `--every` seconds (60); an output file stopped growing for `--still` seconds without a parsed final `turn.completed` event; or the heartbeat (1800) passed, with every session/ref and every file’s path, bytes and minutes since growth. File inactivity is not proof of a hung process. Files must exist and be readable before watching; 1 a fetch, `claude agents` or a file read failed; 2 a wrong argument, nothing to watch, a ref that names nothing or an invalid file |
| `permission-request` | the `PermissionRequest` hook `init` writes into `.claude/settings.json` | in a background session (`CLAUDE_JOB_DIR` set), answers the permission prompt Claude Code is about to show with a deny and a message naming the call, so the session goes on instead of waiting for nobody; elsewhere it prints nothing and the prompt is shown |
| `statusline` | the status line command `init` writes into `.claude/settings.json` | records the usage windows Claude Code hands it in `~/.ai-core/usage.json` and, at most once a minute, a line of them in `~/.ai-core/usage.log`, then shows a short line of the model and the windows |
| the board and issue commands | `ai-core issue-new ...`, `ai-core start-issue N`, ... (section 8) | 0 done; 1 refused or gh refused; 2 a wrong argument |
| `doctor` | `ai-core doctor [--no-install]` | 0 every required tool present and the forge's login answering (gh logged in, or the Forgejo token accepted and `git ls-remote origin` answering; gh with its login and the `project` scope also where only `TRACKER` is `github`); 1 otherwise, each problem with its instruction |
| `install` | `bin/install.sh [--source <clone>] [--dir <path>] [--repo <url>] [--no-path] [--no-doctor]` | 0 installed and doctor OK; 1 when doctor found problems |
| `ai-core` | `ai-core <command>`: any script in `bin/` by name, plus `version`, `help` | the command's exit code; 1 for an unknown command |

`doctor` today checks Git, gh and its login, Bash, Node.js 20+
with `npx`, jq, the team modes, and reports whether `claude`, `agy` and `codex` are installed, with the install command
of each. It also names every `integrate-<issue>.XXXXXX` folder under the project folder's `.worktrees/<repository>/` whose landing no longer runs (no live process holds `ai-core-landing` in the clone's git directory for that issue), with the command that removes it; it removes nothing, and a leftover is not a problem that stops `init`. It takes out what a tool of an earlier layout left in the Claude Code configuration: a
session-start hook in `~/.claude/settings.json` that starts a script beside the repositories, and
a project memory folder `~/.claude/projects/<project>/memory` that is a link whose target is gone
(Claude Code makes a real folder at the next memory it writes); `--no-install` only reports them. Required tools it installs with `brew` or `apt-get`;
a login it cannot do for you.

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

The issue number comes first and is required: a solution path is written for an issue, and posting
it there is the normal end of the command; `--check` validates and posts nothing.

A section counts as filled when something other than whitespace follows its heading, a required
heading may stand only once: `tests/solution-path.test.sh` holds that with planted documents.

---

## 8. The board and the issues

The rules say the plan is the issues (the working style for agents in the rules), and these commands are what holds
that: one command per act on GitHub issues and a GitHub Projects board, driven from the terminal
through `gh`. Each is a `.sh` script, and `tests/` holds it to its answers against a stand-in `gh`, so nothing in the
tests reaches github.com. Nothing here holds state: every command reads the board through `gh`
and writes back to it, so the board is the truth and this is only a shorter way of reaching it.

**Which board.** No project number is written down anywhere. A command resolves the board it acts
on in this order: `--project N`, the environment variable `GH_PROJECT_NUMBER`,
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
| `team-modes.tsv` | tool, mode, probe, install, verified: how each tool proves a mode is installed and how it is installed (section 4.6). |

**The commands.** All run as `ai-core <name>` and take `--help`. A command that names
no repository acts on the one it runs in; `OWNER/REPO` before the issue number names another.

A call GitHub refuses with a rate limit is repeated by every command, because every `gh` call of the harness
goes through `lib/github/gh.sh` (the issue, board and landing commands, `release`, `doctor`, `init` and the push gate): the harness asks GitHub which limit it is, GraphQL `rateLimit` and
REST `rate_limit`, tells a spent budget (waits until its reset) from the limit for bursts (a minute,
doubled per try), repeats the call three times at most, and then fails with a message that names
the limit. A wait longer than 15 minutes fails at once. The wait notice goes to stderr, so a command
that parses what it captured keeps the two apart. `ai-core issue-comment` posts and resolves its
repository over REST. `AI_CORE_SLEEP` names the command that waits, `sleep` by default; the tests set it to a stand-in.

`issue-new`, `issue-comment` and `issue-edit` check supplied titles, label names and the final
composed body before any tracker write, including title-only edits. Unless the tracker confirms a
private GitHub repository, a literal email address is refused locally with the command and address
named. A failed or malformed visibility read uses
this public policy. Plane currently cannot establish private destination visibility, so the check
also applies to Plane text. `labels-sync`, `issue-label` and `repo-link` check label names and
descriptions before writing. `project-new`, `field-option-add` and `view-filter` check project
names, identifiers, label metadata, option names and descriptions, and view filters. Project
visibility is not established by either provider, so these project fields use the public policy
even when a repository is private. Each issue's title and body share one visibility decision.

Reserved domains (`invalid`, `example`, `test`, `localhost`, `example.com`, `example.net`,
`example.org` and their subdomains) and the exact GitHub domain `users.noreply.github.com` are
allowed, ignoring domain case. A local part containing `noreply` and an unverified Forgejo noreply
domain grant no exemption. The check reads the raw text as written. It refuses an address written
plainly, inside a code span or in a link. An address dressed so that the raw text differs from what a
reader sees may pass. Whether it passes depends on where the dressing stands in the address, so
nobody may rely on the check for a dressed address. Dressings are, for example, a Markdown escape
such as `\@`, a code span or emphasis in the address, HTML such as a comment or a tag in it, an
invisible format character (U+200B, U+00AD, U+2060), a lookalike of `@` or `.` (U+FF20, U+FE6B,
U+2024, U+FE52), or an address that overlaps an exempt or numeric match before it. Encoded addresses,
images and an address written as “name at domain” are not covered either. It refuses rather than
redacting and leaves the caller's file unchanged.

| Command | Does |
| :--- | :--- |
| `start-issue [OWNER/REPO] N` | opens the worktree for issue N under `../.worktrees/<repo>/issue-N-<slug>`, on a branch of that name cut from `origin/<default>`, only when the issue is assigned to you and the checkout is clean and current; moves the card to `implementing`; runs `init` there, which takes the checkout's `.ai-core/` data first; prints the thread. For an issue of another repository whose work lands here, `OWNER/REPO N` cuts the worktree here and records the issue's repository on the branch (`git config branch.<branch>.issueRepository`), where `session-start`, `integrate-issue` and `finish-issue` read it. One run, because any one of these done alone is often not done. |
| `integrate-issue [OWNER/REPO] N --reviewed-by R [--from-origin]` | in the worktree of issue N, after the reviewer's GO: merges its branch with `--no-ff` into the newest `origin/<default>`, under the issue's title with `(#N)`, or `(OWNER/REPO#N)` for an issue of another repository, given or recorded on the branch (or `Merge <branch> (...)`, then `Merge issue-N (...)`, where the title does not fit 72 characters) and a `Reviewed-by: R` trailer per `--reviewed-by`, pushes `HEAD:<default>` through the gate, checks the branch out again for `finish-issue`, and safely fast-forwards the main checkout’s default branch. A skipped refresh names the checkout and reason; the successful integration stays successful. The landings of one clone take turns: from the fetch to the end of the push it holds `ai-core-landing` in the clone's git directory, a landing that finds it held names the issue holding it and waits, and one whose holder no longer runs takes it over. Where GitHub refuses the read of the issue, a rate limit among the causes, it says "nothing landed" and names the cause. With `--from-origin` it runs in any directory of the clone and lands `origin/<branch>` instead, in a temporary worktree of `origin/<default>`, named `integrate-N.XXXXXX` in `.worktrees/<repository>/` beside the clone, where `start-issue` cuts its worktrees (so a project test that walks up to a sibling checkout finds it), that is removed afterwards, so the issue's worktree, its branch and its uncommitted changes stay as they were; it names the commit it merges, and a commit the branch holds only locally does not land. Where the merged tree tracks `scripts/install.sh`, it runs there after the merge and before the push, with its output shown, so the gate's check finds what it needs installed; a failing install says so, pushes nothing and leaves the issue's worktree as it was. Refuses without a reviewer, on a branch that is not issue N's, with changes in the tree, on a conflict and on a branch already integrated, each time with the branch checked out again and nothing pushed. The reviewer is a name given, not a review proven |
| `finish-issue [OWNER/REPO] N [--landed]` | after the push that lands the work; the issue, its card and its comment are in the repository given or recorded on the branch: removes the worktree and branch of issue N, only a worktree named for issue N (a package's worktree, named for its first issue, stays while a later issue's branch is checked out in it), only when it has no changes and the change of every commit is on `origin/<default>`, by ancestry or as an equal patch (`git cherry`, so a cherry-picked branch passes); `--landed` removes it anyway where commits landed in another shape, only for a closed issue, and names them; refuses, moving no card and telling the issue nothing, when no commit on `origin/<default>` names the issue; moves the card to `testing` where the board has that column, and in a repository on no board says there is no card; comments on the issue what landed; runs `status-sync` for its repository and the issue's. `--sweep [--dry-run]` removes every worktree of the repository whose work landed more than a day ago; `start-issue` and `init --all` run it |
| `issue-new` | creates an issue: `--title`, `--body-file`, labels, priority, the assignee from `assignees.tsv`, the card on the board, optionally a parent epic (`--parent OWNER/REPO#N`), which then follows its sub-issues as under `issue-status`. Refuses without `--asked-by LOGIN` and `--asked-in WHERE` and writes "Asked for by @login on DATE in WHERE." as the body's first line; a defect a session found in its own work (`type:bug`) takes `--found-in WHERE` instead and opens with "Found in WHERE on DATE, a defect filed without a yes.", because writing a found defect down is tracking, not new work. Reports a title over 70 characters, one with a backtick, or one that names an action and no stake. `--no-board` files it in a repository linked to no open board, a harness among them: no card, no status, no priority; refused where the repository is on a board, and together with `--project`, `--priority` or `--status`. |
| `issue-thread N [--json]` | the issue and every comment on it, for a person or as one JSON object |
| `issue-map [OWNER/REPO ...]` | one line per open issue (status, type, area, title, parent, `blocked by`, `blocks`, the files its body names as `path:line`), then the groups a parent or a `blocked by` joins and the files two issues share; read from the tracker each time |
| `issue-mine N` | whether the issue is assigned to the account `gh` is logged in as; `start-issue` and `session-start` ask it |
| `issue-comment N` | adds a comment, inline or `--body-file`, over REST so a GraphQL limit cannot lose it |
| `issue-edit N` | edits title and/or body; a body without the asked-for line keeps the one the issue has |
| `issue-close N...` | closes issues and moves their cards to `done`, as `completed` or `--reason not-planned`; the epic of a closed issue follows, as under `issue-status` |
| `issue-reopen N...` | reopens issues and returns their cards to `ready` |
| `issue-status N... STATUS` | moves cards between `backlog`, `ready`, `planned`, `implementing`, `review`, `testing`, `done`; in a repository on no board, with no board named, it says the status is not set and exits 0. The epic of a moved issue follows its sub-issues: `implementing` once one has started, `testing` once all stand in testing or done, closed and `done` once all are done; from `testing` it goes back to `implementing` once a sub-issue stands before testing again, and a closed epic stays closed |
| `issue-priority N... P` | `P0` blocker, `P1` high, `P2` normal, `P3` low, `P9` parked; on no board, as `issue-status` |
| `issue-label N --add/--remove` | labels checked against `labels.tsv`; a typo is refused, not minted |
| `issue-assign N` | adds, removes or replaces assignees; additive by default. On GitHub an assignee with an ASCII `@` other than `@me` and `@copilot` is refused as an email address; one with a lookalike of `@` (U+FF20, U+FE6B) is not |
| `issue-duplicate N OF M` | marks N the native duplicate of M, or removes it with `--undo` |
| `issue-transfer N OWNER/REPO` | moves an issue to another repository; the card stays where it is |
| `issue-block`, `issue-unblock` | records or clears a real `blocked by` dependency, across repositories |
| `subissue-add`, `subissue-remove` | attaches issues to an epic as sub-issues, or detaches them; the epic then follows its sub-issues as under `issue-status` |
| `board-sync` | puts every issue of every linked repository on the board and reports what is missing: labels, priorities, cards that were not on the board |
| `board-list` | the board: status, priority, repository, number, title; a repository of another organisation than the board's is written with its owner, `owner/name` |
| `status [--project N] [--tokens] [--issues]` | the state of the work, the same page every time and counted, with no model. Without options: the board counts and every agent process on the machine, with the runs each one started under it; a Claude session's name comes from `claude agents --json` where its command line names none, its model and effort from that name where it follows the worker naming rule, and its issue from the `issue-<n>-…` worktree it was started in, marked `at start`, because a worker given a later package keeps that folder; a stopped process is marked stopped and not counted as running; under REACH the command that reaches each agent. Where no agent runs, and with `--tokens`: the usage windows against the limit; the pace, the issues closed in the last 24 hours, with the average of 14 days beside it; how fast the project folder raises each window an hour, the rise the usage log of the status line measured times the folder's share of the fresh tokens of every session on the machine, and from the pace what that is per issue; the tokens every session of the project folder used in the last 24 hours, fresh and read from the cache apart, and per issue closed in that time; the context an answer read again in those hours, on average and the largest, which shows how late the sessions compact; the epics whose sub-issues are all closed; the open issues on the last column. An epic is an issue with sub-issues. `--issues` adds every open issue by epic. Without `--tokens` or `--issues` two blocks follow, both read from git at that moment: TESTING lists every card in testing with where its work is live, the newest commit on the default branch that names the issue and, per environment of `LIVE_TAGS`, the first release tag by date that contains it, or the commit's landing where the environment is `landed`, a tag's date being an annotated tag's own and a lightweight tag's commit's; the first environment is the last stage, and a card live on a later one only is due for its proof there, marked 🔴 once that environment has carried it longer than `PROOF_HOURS`; the clone of each repository with a card in testing, the folder of the project folder whose origin is that repository, is fetched once per call, for at most a minute. TREES lists the issue worktrees `finish-issue --sweep --dry-run` keeps whose last commit or uncommitted change is older than a day, each with the sweep's reason. Needs Node.js |
| `board-order` | stamps an order onto the board, read from standard input as `owner/repo#number` per line |
| `board-unarchive` | brings archived cards back into view |
| `status-sync [--dry-run] [OWNER/REPO ...]` | closes a card that `finish-issue` moved to `testing` once the first commit of its "Landed on" comment is carried by the newest release tag and the issue carries a proof record after that comment, a comment whose first line is `Proven on <environment>:`, written by the coordinator once a UI test session proved the released work; a released card without one is named `proof due` and stays; a card in testing whose landed commit is on origin's default branch and not in the newest release tag is named `not released`, with that tag, and stays; a repository whose origin was listed and has no tag of that pattern is named once, `no release`, with the pattern and the count of its cards in testing, because its cards can never close; a repository whose tags could not be read, or that has no clone, is named by its own line and not so; a card in a column before `testing` whose issue a commit on origin's default branch names is named `not finished`, with the `finish-issue` command to run, and stays, because that the work is complete is the session's statement; only the comments of the repository's owner, members and collaborators count. The release is the newest tag by date that origin has on the same commit and that matches the first environment of `LIVE_TAGS` in the clone's own `.ai-core/config.env`, or the newest such tag where it names none, read from the repository's clone in the checkout or the project folder after one fetch; where that first environment is `landed`, the landing on origin's default branch is the release and no tag is read; where origin cannot be listed, or has a tag of that pattern on another commit than the clone or one the clone lacks, no tag counts and the run says so, so a release tag is never moved, and where one was, `git fetch --tags --force` in the clone takes origin's; work that landed in another repository, `Landed on <branch> of <owner/repo>:`, is read in that repository's clone; a repository without a clone is named and its cards stay. With a repository named it reads only that repository's open issues, in one query of about 2 GraphQL points per 50 issues, and `start-issue` and `finish-issue` run it so for their own and for the issue's, where that is another; without one it reads the board once to learn its repositories; with no board named, the board is the checkout's, or, where the checkout is on none, the one the first repository named is linked to. It moves no card on a commit alone, because a commit that names an issue touches it without finishing it; an epic follows its sub-issues as under `issue-status`, so a sub-issue moved by hand on the board moves its epic too; forward only, except that step back of an epic |
| `epics-top`, `item-top`, `item-move` | epics to the top of the board; named cards to the top; a repository's cards from one board to another, keeping status and priority |
| `field-option-add` | adds one option to a single-select field, reading the field first so the others are not deleted; `--after NAME` puts it right after another option, the column order `finish-issue` moves a card by; `--replacing OLD` renames OLD in place, keeping its id, so every card that carried it keeps it |
| `view-filter`, `project-new`, `repo-link`, `repo-boards` | narrows a view to named repositories; creates a board by copying one whose title starts with `[TEMPLATE]`; links a repository to a board and gives it the taxonomy; every repository of the organisation and its board, exit 1 when one is on none or on two |
| `labels-sync` | applies `labels.tsv` to one repository, to named ones, or to every repository on a board |
| `incident-count` | the issues carrying each `incident:` label per ISO week |
| `team-modes-check`, `team-modes-install` | section 4.6 |
| `schema-check` | holds every GraphQL mutation in `bin/` and `lib/` against the schema github.com publishes; the one check that reaches the network, run by CI; where `TRACKER` is not `github` it says that the schema is GitHub's and exits 0 |

**The board commands on Plane** (`TRACKER=plane`). The columns of the board are the states of the project
`PLANE_PROJECT` names, and the priorities `P0` to `P3` are Plane's urgent, high, medium and low. `project-new
TITLE` makes that project, with the eight states `backlog`, `ready`, `planned`, `implementing`, `review`,
`testing`, `done` and Plane's own `Cancelled`, the labels of `labels.tsv` and `repo:<name>`; a board to copy
is refused, because Plane copies none. `board-list`, `status`, `status-sync`, `epics-top`, `item-top`,
`board-order`, `incident-count`, `labels-sync` and `repo-link` read and write the project's work items, a
work item that names no repository by a `repo:` label (or, carried from GitHub, by its `external_id`) under
`-`; `board-sync` says that every work item of a Plane project is on its board already and exits 0. Plane
1.4.2's API cannot serve `item-move`, `issue-transfer`, `view-filter`, `field-option-add`, `repo-boards`,
`board-unarchive`, `issue-unblock` and `issue-duplicate --undo`, so each is refused with a sentence that says
so and writes nothing. `issue-duplicate` relates the duplicate to the original, comments on it and moves it to `Cancelled`, as GitHub closes a duplicate. A listing reads the whole project, 100 work items to a page, and Plane's 60 requests
a minute are waited out; `status-sync` reads the comments and the state changes of the cards in `testing`
alone. A checkout acts on the work items of its own repository only: `board-order` and `epics-top` place those
alone, and a work item that carries the labels of two repositories belongs to none and is refused for a
write. `status-sync` moves the card of another repository of the project from the clone of that repository
in the project folder, and names a card whose repository has no clone there and leaves it; a `Proven on`
comment counts when its author is an active member of the project, whoever the key's own user is.
`issue-close --reason not-planned` puts the card in `Cancelled`, and `issue-status` writes the state it is
given, so it moves a work item out of `Cancelled` too. `incident-count` reads every project of the workspace
that is not archived, the repositories each one links by its `repo:` labels, and refuses to print a table
when one of them cannot be read.

**The hooks.** A repository that wants the gate before every push carries the three-line shim
`ai-core pre-push --install` writes into `.githooks/pre-push`, and beside it `.githooks/post-checkout`,
which starts `init` in a new worktree (section 4.12); the gate and `init` themselves never live in
a repository. Where the shim stands, `init` writes `.githooks/commit-msg` beside it, never committed:
it runs `ai-core pre-push --message`, so a subject over 72 characters, an assistant's attribution or
an assistant as author is refused while the commit is made, where the fault costs no rewrite.

---

## 9. Planned commands

Every command `ai-core --help` lists exists today (sections 6 and 8). Planned:

| Command | Does |
| :--- | :--- |
| `doctor` | also the tools a project harness declares in `ai-core.json` |
| `init` | additionally: generate the map when the repository has none |
| `session-start` | additionally: re-assemble the checkout when a layer moved past `.ai-core/STAMP` |
| `publish` | copy the assembled rules and the skills of the project harness into the organisation's `.agents` repository, so OpenHands loads them in every repository of the organisation (section 4.11) |

Prerequisites `doctor` will know, with an install per platform (`brew`, `apt`, or the
tool's official installer): Git, `gh` with its login (install yes, login is a
person's act), Node.js LTS, the agent CLIs listed in `ai-core.json`, and
the project tools listed there (`kubectl`, `helm`, ...). Everything GitHub-side goes through `gh`.
Nothing runs in a container.

---

## 10. Developing the harness

```bash
bash tests/check.sh               # every section at once
bash tests/check.sh 08-harness    # one section, by its file name
```

The check is `tests/sections/*.sh`, one file per group of sections that share their fixtures, each
sourcing `tests/lib.sh` (the root, `fail`, a throwaway directory of its own, the stand-in
`gh`). `tests/check.sh` starts them all at once, each in its own process, and prints the
report in file order with the time each section took; a red section prints its whole log. The
board suite (`tests/run-all.sh`) runs its tests eight at a time
(`CHECK_JOBS=<n>` for another number). Together the sections parse every script (`bash -n`), run `rules-check`
over `rules/`, run `doctor` against a fake old Node.js and a fake unauthenticated gh
and require the two problems, run the installer against a temporary home (an existing clone with `--source`, a clone with
`--repo`, a second run that pulls) and `init` through the `ai-core` command, bootstrap a temporary checkout
(data only, no scripts in the checkout), fail on any
warning or error in the output of `init`, prove the assembled `rules.md` has one section per source
file and passes `rules-check`, prove a second run creates
nothing, prove `git status` stays
empty in a fresh repository and in a worktree, run `init --all` over a folder
and prove the folder's generated `AGENTS.md` lists exactly its repositories, stand a fake `gh`
on the PATH and prove a project harness is created from the skeleton on the first `init`, cloned
on another machine, and that its rules, skills, docs, data files and `repos/<repo>/` are
assembled, base first along an `extends` chain, prove `push` commits
and pushes a harness clone's change to its origin and has nothing on a second run, require `session-start` to exit 1 where the harness is
absent, and run the board suite (`tests/run-all.sh`: one test per
command against a stand-in `gh`, the push gate's among them, and the tree must be as the
suite found it). It needs `bash`, `node`, `jq` and gitleaks 8.19+ and never touches the network. CI runs it on Ubuntu
for every push of a branch and every pull request, and then `schema-check`, which needs
github.com; a tag names a commit whose checks already ran, so pushing it starts no second run.

**A release** is one command, `ai-core release X.Y.Z`, run in the clone: it writes `VERSION` and
commits `release: X.Y.Z` when the file does not carry the version yet, pushes what is not pushed,
waits for the checks of exactly that commit (on GitHub the workflow run `check`; on Forgejo the combined state of the
commit's statuses, of every context, among them the `check` the pipeline posts; asked every 20 seconds, 30 minutes at most)
and, when they are green, tags that commit `vX.Y.Z`, not one made during the wait, and pushes
the tag. It refuses, naming what is missing,
when the tree is not clean, the branch is not the default one (`master`), origin has moved on, the tag exists, or the
run is red or does not finish; nothing is tagged red. `install` and `update` follow the newest
tag, so `master` can carry a mistake without it reaching anybody.

- **Add a file a checkout should get:** put it under `templates/` at the path it has in the
  checkout. `init` deploys it.
- **Add a script:** a `.sh` in `bin/` with a help screen; `ai-core <name>` runs it
  without any registration, and `ai-core --help`, where every `AGENTS.md` sends agents, lists it. A board
  command gets a test in `tests/` that drives it against a stand-in `gh`.
- **Change a rule:** edit its section file under `rules/`, keep the tag at the end of the rule,
  run `bash bin/rules-check.sh rules`. A rule may wrap over several lines; the tag ends the last
  one. A new section is a new `rules/NN-slug.md`; the number places it.
- **Release:** `ai-core release X.Y.Z`; `init` copies the version to `.ai-core/VERSION`.

Run the check before every commit.

---

## 11. Implementation order (planned)

Each step lands with its test in `tests/check.sh` and passes in CI before the next begins. Built
so far: the rules per section, `install`, `doctor`, `init --all`, the board and issue commands, the
project harness and its assembly, `session-start` with the `SessionStart` hook, the push gate,
releases by tag, `update`, `push`, and `map`. Open:

1. `session-start` re-assembles the checkout when a layer moved past `.ai-core/STAMP`.
2. `init` generates the map where a repository has none.
3. Sandboxed agents: `publish` into the organisation's `.agents` repository, and the OpenHands
   bootstrap files (`.openhands/setup.sh`, `.openhands/hooks.json`) as a template a project can
   choose to commit.
4. Removal of the per-checkout `rules.local.md`, `config.env` and `docs/README.md` templates
   (they come from `repos/<repo>/` then).

---

## 12. Troubleshooting

| Symptom | Cause and fix |
| :--- | :--- |
| `session-start` exits 1 with `Not ready: no rules file found` | the product checkout has no installed rules. Run `init`. In a harness source, run `session-start` directly and repair the source input it reports. |
| `kept .claude/settings.json` in the report | jq is missing, so `init` could not merge the hook, the status line, the permission and the denials into the settings.json your repository had; install jq and run `init` again. |
| `ai-core: command not found` from the session-start hook, or `ai-core on PATH  : ✗` in its output | Claude Code was started from a terminal opened before the install, whose PATH lacks `ai-core`. `init` writes the hook with the full path of `ai-core`, and `session-start` names that path for the agent's own shell; a terminal opened after the install has it on the PATH. |
| `ai-core: command not found` inside an agent | the clone's `bin/` is not on the PATH of that shell. Run `install` again, open a new terminal, or call the script by path. |
| Claude Code ignores `AGENTS.md` | a `CLAUDE.md` exists in the directory or above it. In a repository with its own `CLAUDE.md`, `init` writes a `CLAUDE.local.md` with `@AGENTS.md`; a `CLAUDE.md` above the repository gets that line by hand. |
| The agent does not know a rule, or quotes a stale one | the session started before `init` ran, or outside a project folder or checkout with the harness. Start it again there; the transcript under `~/.claude/projects/` shows what the start hooks delivered. |
| Claude Code prompts for `ai-core` commands although they are allowed | accept the trust dialog; project allow rules apply only after it |
| `git add AGENTS.md` says the path is ignored | `init` excluded it on purpose. `git add -f AGENTS.md` commits it anyway, or remove the entry from `.git/info/exclude`. |
| A fresh clone or worktree has no `.ai-core/` | the harness is not committed. Run `init` in a fresh clone once; a worktree gets it from the `post-checkout` hook where the repository carries it (`ai-core pre-push --install`), or from `ai-core start-issue`. |

---

## 13. Known limitations (today)

- Claude Code passes a hook's output whole only up to a size (10 000 characters arrived whole in a
  measured run, 15 000 did not); `session-start --tool` cuts the issue thread after 3 000
  characters and the uncommitted files after 20 lines, and nothing more. Codex, OpenCode and Antigravity
  do not import the files `AGENTS.md` names after `@`; they read where the rules are and open them.
- `rules-check` validates `rules.md` only, not `rules.local.md`.
- The board commands assume a GitHub Projects board with single-select fields `Status` (options
  `backlog`, `ready`, `planned`, `implementing`, `review`, `testing`, `done`) and `Priority` (`P0` to
  `P3`, `P9`); `project-new` copies such a board from one whose title starts with `[TEMPLATE]`.
  A board of the older layout is brought to it once, every card keeping its status:
  `field-option-add --project N --field Status --name ready --color <its colour> --replacing todo`,
  then `--name planned --after ready` and `--name review --after implementing`.
- `rules.local.md` belongs to one checkout and travels nowhere; what a project shares, rules,
  skills, documents, goes into its project harness.

---

## 14. Repository structure

```text
setup-ai-core/
├── VERSION                              setup-ai-core version, copied to .ai-core/VERSION
├── auto-mode.tsv                        the steps Claude Code's classifier allows in every project (section 4.10)
├── bin/
│   ├── install.sh                       once per machine: clone to ~/setup-ai-core, PATH, doctor
│   ├── doctor.sh                        prerequisites: check, install, or fail
│   ├── ai-core                          the command; runs any script here by name
│   ├── init.sh                          equips a checkout or a project folder with data
│   ├── session-start.sh                 the session start
│   ├── map.sh                           the map of a repository, written by the agent CLI into the harness
│   ├── git-credential.sh                git's credential helper for an origin on the Forgejo instance: the token of FORGEJO_TOKEN_COMMAND
│   ├── update.sh                        this machine to the newest release, the harness clones to their origins
│   ├── release.sh                       commits VERSION, pushes, waits for green checks, tags
│   ├── push.sh                          commits and pushes the harness clones of the project folder
│   ├── solution-path.sh                 8-section solution path validator
│   ├── rules-check.sh                   enforcement-tag validator
│   ├── team-modes-check / -install      the team modes of every tool on the machine
│   ├── status.sh                        the state of the work: board counts, agents, usage, tokens
│   ├── usage, statusline                the account's usage windows: recorded by the status line, read against the limit
│   ├── issue-*, start-issue, board-*,   the board and issue commands
│   │   finish-issue, status-sync, ...
│   ├── pre-push                         the push gate, and --install for the shim a repository carries
│   └── schema-check                     the check of the board commands themselves
├── lib/
│   ├── board.sh                         the library of the board commands
│   ├── tracker.sh                       reads TRACKER and sources lib/<TRACKER>/tracker.sh, the calls to the issue tracker
│   ├── common.sh                        what the libraries and providers share: die, data_dir, config_value, apart
│   ├── forge.sh                         reads FORGE and sources lib/<FORGE>/forge.sh, the calls to the code host
│   ├── github/                          the GitHub provider: gh.sh (gh with the rate limits met), tracker.sh, forge.sh
│   ├── plane/                           the Plane provider: api.sh (curl with the key, the rate limit met), tracker.sh
│   ├── forgejo/                         the Forgejo provider: forge.sh (curl with the token), and the line that lets git sign in
│   ├── layers.sh                        the project harness: from origin, beside the repositories, cloned, pulled, created, the extends chain
│   ├── gitignore-block                  the block init writes into a project's .gitignore
│   ├── binding-rules.md                 the binding rules init puts on top of every map and into a project folder's AGENTS.md
│   └── status.mjs, status-now.mjs       what status counts and prints, in Node.js
├── rules/
│   ├── NN-slug.md                       the generic rules, one file per section
│   └── skills.md                        when to use which skill
├── skills/                              person-in-charge, helper: deployed into every checkout
├── skeleton/                            what a new project harness starts from: ai-core.json, README, rules/, skills/, docs/, repos/
├── templates/                           mirror of the checkout; every file is created once
│   ├── AGENTS.md, .cursorrules, .windsurfrules
│   ├── .ai-core/                        config.env, labels.tsv, assignees.tsv, team-modes.tsv,
│   │                                    rules/rules.local.md, docs/README.md, solution-path.template.md
│   ├── .claude/                         settings.json: the session-start hook, the ai-core permissions, the denials
│   ├── .github/                         copilot-instructions.md
│   └── .openhands/                      microagents/repo-rules.md
├── tests/
│   ├── check.sh                         the check: every section at once, the report in order
│   ├── lib.sh                           what every section starts with: fail, a throwaway directory, the stand-ins
│   ├── sections/*.sh                    the sections, one file per group that shares fixtures
│   ├── run-all.sh                       the board suite, eight tests at a time
│   └── *.test.sh                        one test per board command
├── .githooks/                           pre-push and post-checkout: the shims this repository carries itself
├── .github/workflows/check.yml          runs the check on Ubuntu
├── LICENSE                              MIT
└── README.md
```

---

## 15. License

Created and maintained by [@kartalbas](https://github.com/kartalbas). Released under the
[MIT License](LICENSE).
