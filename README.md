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

Or a whole project folder, every repository in it that carries the harness already and the folder itself
(section 5.8), and then the agent started in the folder:

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
A clean checkout on that branch uses a fast-forward merge, and runs the repository's
`scripts/install.sh` there afterwards where it has one, as `integrate-issue` does after a landing;
another branch or detached HEAD keeps
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
| Install the harness into a checkout with one command | yes: `ai-core init`, after a one-time `install` per machine; `ai-core init --all <folder>` for every repository under a folder that carries the harness | same |
| Nothing is committed to the repository | yes: a block in the project's `.gitignore` names every agent file, and `.git/info/exclude` carries the rest per clone | same |
| Rules for every project | yes: one file per section under `rules/`, assembled into one `rules.md` per checkout | same |
| Rules of one project (private harness) | yes: `github.com/<org>/<prefix>-ai-core`, found from the repository's origin, cloned beside the repositories (`<project folder>/<prefix>-ai-core`), created from a skeleton when missing; its `rules/` add or replace sections, its `skills/`, `docs/`, data files and `repos/<repo>/` are assembled into every checkout; a harness may extend another (section 4.5) | same |
| Skills and team modes | `rules/skills.md` says when to use them; `team-modes.tsv` says how each tool proves a mode is installed and how to install it; `doctor` installs the missing ones, `session-start` refuses a session without them; skill folders of the project harness are deployed into `.claude/skills/` and `.agents/skills/` of every checkout | same |
| Map of a repository (what the code does not say) | yes: `ai-core map` writes it from the code through the developer's agent CLI, five fixed sections, into `repos/<repo>/AGENTS.md` of the project harness; the generic one of `templates/` until then, both under the binding rules | also written by `init` where a repository has none |
| Claude Code hook, status line, permissions | yes: a `SessionStart` hook that runs the session start, and the status line that records the usage windows | same |
| Session start | yes: the team-modes gate, state, versions, rules present, the issue thread of a worktree, exit 1 when not installed | also re-assembles the checkout when a layer changed |
| Issues and the GitHub board | yes: one command per act over `gh`, from `issue-new` and `start-issue` to `board-sync`, `status` and `status-sync` (section 8); the conventions come from three data files a project fills | the data files come from the project harness |
| A coordinator that delegates to worker sessions | yes: the skill `person-in-charge` bundles the issues into packages and gives each to a worker session it starts, with the model, effort and context size the work needs (section 4.6) | same |
| The account's usage limit | yes: `ai-core usage` reports each tool's usage windows and their projections against `USAGE_STOP_AT`. Starts continue at full speed until a window stands at that limit. Every session then finishes its step, commits, reports and waits for the reset | same |
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
file imported, then the list of the repositories in it that carry the harness, each with the path of its map, rewritten on
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
`init` never overwrites a tracked file. That holds for the data files too (`config.env`, `labels.tsv`,
`assignees.tsv`, `team-modes.tsv`, `models.tsv`): the copy the repository commits wins over the copy of every
layer and over `repos/<repo>/`, and a tracked file changed or removed in the working tree stays so.

Because the harness is not in the repository, it does not travel with `git clone`. **Every clone
runs `init` once.** It is idempotent and takes seconds. A worktree runs it by itself: git runs
`.githooks/post-checkout` in the new tree after `git worktree add`, and that shim starts
`ai-core init` where `.ai-core/STAMP` is missing, also where a file the branch tracks under `.ai-core/` is there;
`init` in a worktree that has no `.ai-core/STAMP` yet first takes
the checkout's own `.ai-core/` data (its configuration, local rules and documents) file by file, leaving a file
that the worktree tracks as the branch has it, then assembles the harness over it as in the checkout.

A worktree that `start-issue` opens lives in `<project folder>/.worktrees/<repo>/`, where `..`
holds no other checkout. So `init` in such a worktree links every other checkout of the project
folder that carries the harness (a clone without it is never touched) into `.worktrees/<repo>/`, as `../../<name>`, and a path such as
`../other-repo` finds from the worktree what it finds from the checkout. An entry that already
stands there is kept, a folder that is no repository gets no link, a link `init` made to a checkout
that carries no harness goes, as `init` no longer follows it and the push gate would fetch into that clone
through it, and `init --all` passes the links by.

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
`90-the-harness-in-a-repository.md`: 67 rules. Two digits order the files and leave room between
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
`repos/shop-web/AGENTS.md` is the map of shop-web. `repos/shop-web/.ai-core/config.env` is the one
file laid over key by key: it holds only the keys shop-web changes, and `init` writes the `config.env` of
the layers with each of those keys taking the file's value (the last assignment of a key counts, and an
empty value stays empty), so every other key of the layers stays and a key a layer adds later reaches
shop-web at the next `init`. Every other file under `repos/<repo>/` replaces the whole file.
A file the repository tracks is never overwritten. `.ai-core/STAMP` records the
commit of setup-ai-core and of every layer the checkout was assembled from. `.ai-core/DEPLOYED`
records what the layers put into the checkout (skills, agents, docs, the files of `repos/<repo>/`);
what a layer no longer provides is taken out again at the next `init`, a file the repository
tracks excepted. A checkout whose `STAMP` names a layer, and whose `origin` is now on a host other than the
configured forge's, finds no harness, and so does a project folder whose `STAMP` names a layer and which holds a repository with such an origin, so `init` stops before it writes or removes anything and says which
settings to put in the environment for that one run (`FORGE`, `TRACKER` and, for Forgejo, `FORGEJO_URL`
and `FORGEJO_TOKEN_COMMAND`).

A project folder (section 5.8) gets the layers every repository under it that carries the harness shares: the company
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
  tool: Claude Code, Codex or agy. `ai-core tool-order codex,agy,claude` saves the machine-wide
  phase execution preference across restarts and init; `ai-core tool-order claude` returns to
  Claude alone, and `ai-core tool-order --clear` removes the saved order, so each session selects
  by its native tool and the routing rows of the model table again. A package keeps its coordinator's ecosystem and number block. The coordinator writes no code. It cuts the open issues
  into packages by area: one
  capability across every repository it touches, with both sides of each contract named by
  `file:line`, cut so that one build session finishes it alone; packages that share a file or a
  contract run one after the other. Every package is a section of one plan issue per board, titled "Plan:
  packages", with its ecosystem, class, repositories, contracts and issues.
  - Before any plan and any build of a mechanical package, the coordinator clears what earlier
    sessions left in `implementing` and `testing` (`briefs/clearing.md`). A package then runs through its phases: plan, plan check,
    build and test, review, start check, land, release to the test stage, UI test, release to
    production and live check. A `mechanical` package, which the coordinator decides from its
    issues, has no plan and no plan check and starts at its build. The plan, the plan
    check, the build, the review and the UI test are fresh sessions, each ended with its phase and
    started with one brief from the skill's `briefs/` (its input, what to do, the exact shape of
    its output) on the commands of `references/<tool>.md`; the start check (`START_CHECK` of
    `config.env`), the landing and the release are the coordinator's own commands. No session is
    given a second phase, because the state lives in the tracker and on the branch.
  - The model and effort of each phase follow the package's class (`mechanical`, `normal-hard`,
    `high-risk`) and come from `.ai-core/models.tsv`, one block per tool; the plan runs on the
    `high-risk` or the `normal-hard` row, because the plan decides between those two classes, and
    every plan session after the first plan, a re-plan, runs on the `re-plan` row. The reviewer never runs on the
    model that built the package. Before every start and resume, `ai-core phase-model PHASE CLASS`
    selects exactly `TOOL MODEL EFFORT`; plan-check and review require `--written-by MODEL` with
    the actual writer. A tool may hold several rows for one phase and class: they are tried in
    table order, a row whose destination has no quota left or whose model is the writer's is
    passed with its reason in the record, and the first eligible row is selected; the template
    names `codex:gpt-6-astra` first and `claude-fable-5-1` second for the plan and re-plan of
    `claude`, so plans run on Astra while Codex has quota and on Fable while it has none. Under a
    saved tool order, the first tool of the order with a row and quota runs, so an order that
    puts `claude` before `codex` runs plans on Fable even while Codex has quota. The `claude` review
    rows name `codex:gpt-6-astra`, then `claude-opus-5-5`, then `claude-fable-5-1`, so the work of
    every writer but Astra is reviewed on Astra while Codex has quota and on Opus while it has none;
    Astra's own work is reviewed on Opus, and the work of `claude-opus-5-5` on Fable while Codex has
    none. An order that puts `claude` before `codex` reviews on Opus, and the work of Opus on Fable,
    even while Codex has quota.
    While Claude has no quota and Codex has, the Astra route rows review the work of every Claude
    writer, `claude-sonnet-5-5` and `claude-fable-5-1` included, instead of waiting.
    Two rows equal in tool, phase, class, model and effort are refused as ambiguous. The plan's `Setup:` line, passed as `--setup-file PATH`, replaces the table
    row of a tool that has an entry for the phase, also where a row of another tool routes to it, only with a tuple the table allows, and sets the
    context budget of the phase within its ceiling. Every PHASE line includes the order and selected tuple. No saved order
    keeps native-tool selection and existing table routes, without inventing a set time.
    `ECOSYSTEM_ORDER` assigns coordinator ownership and number blocks, not phase preference.
    Phase names lead with `plan`, `re-plan`, `plan-check`, `build`, `review`, `ui-test` or `keeper`;
    status still reads old single-letter names. Re-checks keep their 100k budget and reading scope
    and take the selector's effort. A tool change starts a fresh session with the current brief,
    saved work and last report; no foreign conversation id is resumed.
  - A Claude phase session carries Claude Code's own system prompt and tools, the rules and maps that
    the folder's `AGENTS.md` names, the memory of the folder, the skills and the commands before its
    first word, and every answer pays that again. The start and the resume of
    `references/claude.md` add `--strict-mcp-config` and no `--mcp-config`, so none of the
    account's connectors loads: no brief sends a phase to a connector. The rules, the maps, the
    memory, the skills and the commands stay, because a session without the rules breaks them;
    `tests/phase-setup.test.sh` refuses a start or a resume that lacks the flag or carries any flag
    beyond the ones the reference names, such as `--safe-mode`, `--bare`, `--system-prompt` or
    `--disable-slash-commands`, which drop the rules or the skills, and a start that does not add
    the brief's folder. The UI test is the one run that starts a browser server, through its own
    `--mcp-config`.
  - One session per project files its issues, the issue keeper, the `keeper` row of `models.tsv`. A
    plan, a plan check, a build, a review or a UI test that finds a defect outside its work writes a
    `KEEPER:` line and files no issue. A review's finding outside its package goes to the owner
    first, who decides whether it becomes work, even when an existing issue could hold it.
    The coordinator hands the other lines of a round to one keeper
    (`briefs/keeper.md`), which reads the open issues and folds each finding into the issue it fits,
    or proposes a sub-issue of the epic it fits, and writes where and why. After a landing it
    rewrites the facts of every open issue whose named `file:line` spans the landing moved, and writes
    on the issue what it changed and why. A finding that fits nothing goes to the owner as a question,
    and a new issue or epic follows only his yes. A plan's `KEEPER: re-cut` moves only criteria
    the keeper verifies an existing issue already holds; a merge needs no new approval, and a
    split waits for the owner's yes for its new issue. Every new issue, including a sub-issue
    and a plan issue, waits for the owner's yes.
  - The cards move through `backlog`, `ready`, `planned`, `implementing`, `review`, `testing` and
    `done`; a question that is the owner's puts `needs:owner` on its issues.
  - At the usage limit every session using that limited account or model finishes its step, commits,
    reports and waits for the reset. The selector reads the quota before each start and resume.
    A changed order before launch requires a new selection. This is preflight and detection,
    not a quota reservation: another process may spend quota after the read, and the real tool's
    later quota refusal remains visible. `ai-core usage` counts native-confirmed starts since the
    order's set time, reports later-tool starts red using recorded quota reasons, and reports
    uncertain timing, identity or project proof as unknown. Launch examples retain attempts and
    native observations in `sessions/<session name>.start.jsonl`; artifacts alone prove no start.
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
under a folder that carries the harness, names every other one and touches it in no way, with one push and `init --all`; `--no-push` writes into the clone and stops;
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

`Local rules` names each `rules.local.md` that says more than the template: the project folder's
first, then the checkout's own. After a compaction, which the `SessionStart` hook's event reports,
the report lists every rules file to read again, these among them.

On Forgejo the sign-in line is `Forgejo status   : ✓ Authenticated on <host> as @you`, the host of `FORGEJO_URL`.

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
  (except `config.env`, the harness's own file, and the files named `*.example.env`, the convention for a tracked template (the carve-out goes by name, so such a file holding real values is readable too), which the entries
  `!config.env` and `!*.example.env` carve out) and any
  `*.pem` and `*.key`, reading or editing `~/.netrc`, reading
  the machine's credentials (`~/.ssh`, `~/.aws`, `~/.git-credentials`, `~/.npmrc`, `~/.config/gh`,
  `~/.docker/config.json`, `~/.kube`), `git push --force`, `-f` and `--force-with-lease`, `git reset --hard`
  and every `git clean`. A Read or Edit denial holds Claude Code's file tools, the file commands it
  recognizes in Bash (`cat`, `head`, `tail`, `sed`, `tee`) and the targets of redirections; it does not
  hold a command that reads files without naming them, such as `grep -r pattern .`, or a script that opens
  files itself (Claude Code's permissions documentation, section "Read and Edit"). A Bash denial
  holds the command as written: `git -C . reset --hard` or `sh -c '...'` is not matched. A `claude -p` run from a throwaway folder reads
  no checkout's `settings.json`, so `init` also writes the same denials, with `**/` patterns anchored at the
  filesystem root (`//**/`) and without the `!` entries, to `~/.ai-core/claude-run-settings.json`,
  which the skills pass with `--settings`. Claude Code reads a `!` pattern relative to the current folder,
  so it cannot carve out of a `//` rule (measured: a run refused `config.example.env` with both entries
  present): a `claude -p` run cannot read any `*.env` file, `config.env` and a template included, and a
  session hands it the content it needs. Claude Code applies allow rules from
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
harness: git runs it in the new tree after `git worktree add`, and where `.ai-core/STAMP` is missing it
starts `ai-core init`; it exits 0 whatever happened, because a failing hook would fail the
checkout too, and what went wrong stands on stderr. `ai-core pre-push --install`
writes both shims into the current repository, and into each worktree of it the shims that
worktree's own commit lacks (a relative `core.hooksPath` is read from the tree git works in, and git
runs the files on disk), sets
`core.hooksPath`, and says what to commit; with `--all <folder>` it does so for every repository
under a folder that carries the harness (a clone without it is named and left untouched), and it commits the shims on their own (a `No-issue:` trailer naming the command)
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
   remote has, a force push, is refused, whatever tool or person made it. **The default branch takes
   a harness landing or a direct push**: an update of it that carries no mark of a landing for
   exactly the commit it lands, this clone and this ref, and is no direct push (below), is refused as
   `master takes no plain push (<reason>)`, with
   `ai-core integrate-issue <number> --reviewed-by <reviewer>` named. The mark is a record
   (`lib/landing-check.sh`, `mark` and `unmark`) that a path of the harness writes right before its
   push, hands to that push's Git children alone in `AI_CORE_LANDING_MARK`, and removes on every way
   out: `integrate-issue` (its pushes to `ci/integrate-<branch>` and to the default branch), `release`
   (the commits it sends), `init` (its commit of the `.gitignore` block), `pre-push --install` (its
   commit of the shims), `start-issue` (the start commit of an empty origin, section 8, which the gate takes without a review) and `ai-core push` (the commit of a project harness). `init` and
   `pre-push --install` mark their push only where every commit it adds is one of theirs, with its
   `No-issue:` trailer and its files alone: a commit of somebody else beneath theirs makes it a plain
   push, which the gate refuses on the default branch. It is no override a
   person sets: it keeps a plain `git push` from reaching the default branch by habit, and proves no
   review. A push of another branch needs none.

   **A direct push** is a plain push to the default branch whose every new commit touches only files
   that the repository lists in `DIRECT_PUSH_FILES` of its own `.ai-core/config.env`: a release
   manifest that a release script commits and pushes, a data table, a change too small for a
   landing. Nothing is listed by default, so without the key every plain push is refused as before.
   The value is a list separated by white space of paths or shell patterns, matched against the
   whole path from the repository root, case counted: `*` stands for any characters, a slash
   included, `?` for one character, `[...]` for one of a set, and a pattern without them names
   exactly one file, so `VERSION` is no `sub/VERSION`, `version` or `VERSION.txt`, and `docs/*` is
   everything under `docs/`. A path that is absolute, or has an empty, `.` or `..` component, is
   refused by name. The gate reads the key again at every push, from the file of the checkout it
   runs in and from nothing else: an exported variable, the file of the project folder and the file
   of another worktree grant nothing, and a file it cannot read refuses the push and names the
   file. It reads each commit on its own, never the tip alone or the net change of the push: every
   commit that the default branch gains, a merge among them, a commit that another branch or tag
   of origin carries as well, and every commit that another ref of the same push adds. A merge is
   read against each of its parents, a rename as its old path and its new one. One commit that
   touches another file, one such commit beneath a valid one, and an unlisted change that a later
   commit reverts each leave the push a plain one, refused as before. So does a commit that changes
   `.ai-core/config.env` itself, whatever the list says, because the gate reads the list from that
   file as the push brings it: a repository that tracks the file changes it through a landing. A
   direct push meets every other check of the gate, on every commit that the default branch gains,
   as a landing does: the fast-forward and the checked-out commit above, the issue of
   each commit or its `No-issue:` reason (check 2), the team modes, `scripts/check.sh` run on the
   pushed tree, the secret scan, and, where the default branch goes live, `scripts/check.sh` and the
   `Reviewed-by:` trailer (check 8). The gate runs in the clone it is installed in: a temporary
   clone without the hook is judged by no gate, and this changes nothing there.
2. **Every pushed commit names its issue**, `#<n>` anywhere in the message, or is excused: the
   subject opens with `release:`; every file it touches is a `*.md` or a `LICENSE*` (an
   explanation needs no ticket); or it carries a trailer `No-issue: <who asked and why>`, read the
   way git reads a trailer, so an empty one and the two words inside a sentence do not count.
   The message of a merge is not judged, but a merge the remote does not have runs the checks on
   its tree like any new commit. So does every push that moves the default branch, also a branch
   pushed for review that lands as a fast-forward, whose commits origin carries already. A deletion runs nothing, and what is judged is exactly what the remote
   does not have yet: the local commit without the remote sha and without every ref of origin
   this clone knows, so a branch that merged the default branch is judged on its own commits, not
   on those the default branch published, and a tag introduces nothing. The one exception is a
   harness landing of the default branch, which judges every commit it adds to the default branch,
   those another ref of origin carries already among them, because a branch pushed by a session
   whose gate did not run reached origin unjudged. Every check below judges them, except the address
   of the person pushing (item 5).
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
   push adds to origin are read, by a harness landing too, so a commit on a ref of origin this clone
   knows, another person's or a platform bot's, never refuses a push; one origin has and this clone has not fetched is read as
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
   two or more repositories is a word of structure and names no repository. A `Naming: <why>`
   trailer on any commit of the push keeps the names the push adds, so a forgotten trailer is added
   by a later commit and no commit is rewritten.
10. **`scripts/check.sh` is green**, run in the tree being pushed; a repository without one is told
   so and passes on. The check reads the working tree, so a tree that differs from the pushed commit,
   by an uncommitted change or a file neither tracked nor ignored, is refused with the files named.
   The check starts when the 1-minute load average (`uptime`) is below `PRE_PUSH_LOAD_LIMIT`. At or
   above it the gate says once what it waits for, with the load and the limit, polls every five
   seconds at most, and after `PRE_PUSH_LOAD_WAIT_SECONDS` starts the check anyway and says that it
   started at or above the limit. The commit and the tree are judged again after a wait; a changed
   `HEAD` or a dirty tree is refused. An interrupted wait starts no check. The wait is one place: a
   private landing, a landing under `CI_GATE="none"`, a public landing and a release reach it through
   the generated hook, and the lock of a private landing stays held for it, at most the bound. A
   sample reserves no CPU and the load can rise again at once; the wait lowers the chance of a red run
   that has no defect, it guarantees nothing about the load during the check.
   The output of the check goes into the gate's log with the seconds since the check started on every line,
   and to the pusher as the check wrote it. When the check ends, red or green, the gate prints the five longest
   gaps of a second or more between two lines, longest first, each with the line that came before the gap, so
   that a slow step shows by name (`lib/gate-timing.sh`). The run record keeps the total seconds and the check's
   own last line, without the seconds.
   A check in a worktree reads its neighbours through `..`, where `ai-core init` linked the published
   copy of each, `.ai-core/neighbours/<neighbour>/origin-<branch>`. The gate takes only the neighbours that a
   tracked file of the repository names as a path beside the worktree: `../<neighbour>`, or `".."` with
   `"<neighbour>"` as the next argument of a path join, in either quote; a longer name such as
   `../<neighbour>-kit` does not count. A linked neighbour that no tracked file names this way is not asked,
   moved or locked, so no gate waits for it, and the gate prints it as not held. A path built from a variable
   is not seen: a check reaches a neighbour through a path written out, or the gate does not hold that
   neighbour. Right before the check starts the gate
   asks the origin of each neighbour it takes, in the order of the names, and brings the copy to the newest
   commit of the default branch, unless the copy holds a change in its tree or a commit its origin lacks:
   then it stays and the gate names it. The gate prints the commit each copy stands at, and holds a shared
   `flock` on the copy (`.copy.lock`) until the check ended, so no init and no other gate moves it under the
   check, while gates that read the same commit run together, and a copy that stands at the newest commit
   waits for no check, for the gate and for `ai-core init` alike. The gate's git and its check run without these lock
   descriptors, so a process they leave running, such as the detached maintenance of git after a fetch or
   a daemon of the check, holds no lock after the gate ends. A gate or init that must move a copy first takes
   the admission lock of the copy (`.admission.lock`, exclusive), which a gate holds shared only for the moment it
   takes the copy lock: a move that is pending keeps every gate that arrives later out, so it waits for the checks
   that were reading the copy when it asked, never for a succession of later ones. An init claims every copy it must
   move this way before it waits for any, so the gates that arrive meanwhile wait for it once. It then waits for
   those checks: at least `NEIGHBOUR_LOCK_WAIT_SECONDS`, and at least one and a half times the longest check
   in the run log of this machine (`ai-core pre-push --runs`) in the last 14 days, which counts for no less than 1320
   seconds, so 1980 seconds where no longer check is on record; with `0` it tries once. Admission and copy locks share that one
   wait, and neither another attempt nor another copy starts it again. The gate holds no copy while it waits for
   another: it gives up every copy it holds, waits for that one, moves it, and takes every copy again in the order of
   the names, reading each one's state again under its lock; the check starts once all are held together. A landing
   whose receipt does not show the check green holds no copy while the gate waits for a lower load, and takes them
   again after it. A check that runs longer than the wait, or hangs, keeps its copy: the refusal says so, and names
   the setting, the automatic wait and the history it came from. A fetch of the same neighbour that another gate or
   init runs is waited for `NEIGHBOUR_LOCK_WAIT_SECONDS` at most, while a fetch of its own takes as long as git takes;
   nothing here promises that a move or a new worktree is instant, only that it is not kept waiting by
   checks that start after it. An origin that cannot be asked, a copy that cannot
   be read, a default branch that origin renamed since the link was made, or a lock not free in time refuses the push
   and names the copy; nothing is certified against a copy that may be stale.
   A landing of a public repository pushes its merge commit through this gate twice, to
   `ci/integrate-<issue branch>` and then to the default branch. `ai-core integrate-issue` opens a receipt
   in a private folder (`lib/landing-check.sh`) and hands its path, in `AI_CORE_LANDING_RECEIPT`, to the Git
   children of those two pushes alone. The gate of the first push writes what its green check proved: the
   clone, the origin, the commit, its tree and the commit each neighbour copy stood at. The landing adds the
   `ci/` ref once that push went through and the CI of the same commit was read green. The gate of the final
   push then skips `scripts/check.sh`, and only that, where the receipt shows the very commit, tree, clone,
   origin and neighbour commits for the one push to the default branch; a second commit, a changed neighbour,
   a missing, invalid or incomplete receipt, a failed first push or a push outside a landing runs the check.
   The gate prints one line with the full commit and whether the check runs, and why or why not. The
   receipt is deleted on every way out the landing can trap, and a SIGKILL leaves only a folder of
   a few lines in the temporary folder of the machine.
   With `FORGE=forgejo`, the check gets the two `credential.<FORGEJO_URL>.helper` entries in git's
   environment configuration after the caller's entries, which stay. The second one runs
   `ai-core git-credential` with the checkout's `FORGEJO_URL` and `FORGEJO_TOKEN_COMMAND` set for
   that helper alone, so git started outside the checkout can sign in to that instance. The
   check's own environment gets neither setting, and only the command that prints the token is
   passed. A GitHub check gets nothing added.
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
the current branch against its upstream: what `git push` would send. Started by git, which gives it the
remote's name and URL, with no ref line, as when the remote branch moved since the push began and git
refused the ref itself, it judges nothing and exits 0, so git's own refusal stands alone. `tests/pre-push.test.sh`
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
| gitleaks 8.19+ | the credential scan of the push gate, in a repository that carries `.gitleaks.toml` | `doctor` wants it where a repository of the project folder that carries the harness, or the checkout doctor runs in, has that file, and installs it: brew, on Linux the GitHub release into `~/.local/bin` (apt's package is 8.16); `init` runs doctor in the folder it serves |
| Node.js 20+ with `npm` and `npx` | `ai-core status`, which counts with Node.js; the team modes installed through `npx` | `doctor` installs it |
| Node.js that runs `.mts` files without a flag (CI runs 24; measured on v24.21.0) | with `TRACKER=forgejo`, every issue command, which runs from `lib/forgejo/tracker` (section 8.1) | no npm package is loaded at runtime; `doctor` runs the tracker and asks, it compares no version number |
| `npm ci --prefix tests/typescript` | developing the Forgejo tracker: the strict type check of section 16 of the suite | development only: it installs the pinned `typescript` and `@types/node` of the Node line CI runs; the runtime never loads them, and a missing compiler turns the check red |
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
| `--all <folder>` | run `init` in the folder itself (section 5.8), then in every git repository directly under it that carries the harness (its `.ai-core/STAMP` exists; a harness clone `<name>-ai-core` counts as carrying it, and `init` is never run in it) and in every worktree under its `.worktrees/` whose checkout does; any other repository is named in a line `skipped: <name> carries no harness; ai-core init <path> installs it`, counted in the summary and touched in no way: no file, hook, exclude entry, git configuration, forge call, fetch or sweep of its worktrees; `doctor` runs once; a failing repository is named in the summary and the exit code is 1, a skipped one does not change it |
| `--no-doctor` | do not run `doctor` first (CI, or a machine you have checked yourself) |
| `--dry-run` | write nothing; print the report of what the run would create, refresh, keep and remove; `doctor` runs without installing; with `--all` every repository that carries the harness gets its dry run |
| `-h`, `--help` | usage |

Choose one `TARGET_DIR` or one `--all <folder>`. `--all` takes one folder and cannot be combined
with `TARGET_DIR`. An extra folder is named and refused with exit 1 before anything is written,
before `doctor` runs or a worktree is locked. Run `init` once per folder.
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
| `tracked` | a data file or a file of `repos/<repo>/` the repository commits itself; not applied, and its copy wins over the layers' copies |
| `unchanged` | the count of files that were already what they should be |

The report closes with `.gitignore changed` when the block was written, committed and pushed
(or, in a worktree, left to its own commit), with `.gitignore: pulled N commit(s) from origin/<branch>
first; the block was there already` when the origin had it, with `.gitignore not written` and the
reason when the checkout is behind its origin with work of its own, with `.ai-core taken from the checkout <path>` when a
worktree started empty and got the checkout's `.ai-core/` data first, with `core.hooksPath set to .githooks` when the repository carries the push gate's shim and the
clone was not armed yet, with `credential.<FORGEJO_URL>.helper set` when the origin is on the Forgejo instance
and the clone did not sign in through `ai-core git-credential` yet, with what the user's git configuration lacked of
`credential.<FORGEJO_URL>.helper` and `credential.<FORGEJO_URL>.aiCoreConfig` set there (the path of the main checkout's
`.ai-core/config.env`, so that git in a tool's own cache signs in too), and with the harness version. A second run on an unchanged checkout reports
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

`.ai-core/config.env` carries these keys. Quotes and `# comments` are allowed. The keys whose values are
a fixed set of words (`AGENTS`, `TRACKER`, `FORGE`, `UPDATE_CHECK` with its `AI_CORE_UPDATE_CHECK`, `CI_GATE`) are compared
without letter case, and a word outside the set is an error where the reader of the key checks it; `UPDATE_CHECK` is the
exception to that error, because every value but `never` asks. The other keys keep the bytes written: an address, a
command or an executable path (`FORGEJO_URL`, `FORGEJO_TOKEN_COMMAND`, `LIVE_RELEASE_COMMAND`,
`START_CHECK`), a name of an organisation, a model or a repository folder (`GH_ORG`,
`MAP_MODEL`, `DEFAULT_BRANCH_IS_LIVE`), and the tool names of `MAP_TOOL`,
`AI_CORE_MAP_TOOL` and `ECOSYSTEM_ORDER`, which are the exact lowercase names of the command line tools and of `models.tsv`.
The environments and patterns of `LIVE_TAGS` keep their bytes too, with `command` and `landed` as exact lowercase values,
and so do the paths and patterns of `DIRECT_PUSH_FILES`.
`DEFAULT_BRANCH_IS_LIVE` takes `yes` in lowercase or a folder name as written. The numbers (`USAGE_STOP_AT`,
`PRE_PUSH_LOAD_LIMIT`, `PRE_PUSH_LOAD_WAIT_SECONDS`, `NEIGHBOUR_LOCK_WAIT_SECONDS`, `PROOF_HOURS`) have no letter case.
A `config.env` that is not there, or a key it does not set, gives the default of the key. A `config.env` that is
there and cannot be read stops the command that reads it, with a nonzero status and the line `error: <file> exists
but cannot be read; fix its permissions, or remove it to take the defaults` on standard error; no command goes on
with a default in its place.

| Key | Values | Meaning |
| :--- | :--- | :--- |
| `AGENTS` | names separated by spaces: `claude`, `codex`, `antigravity`, `openhands`, `gemini`, `cursor`, `windsurf`, `copilot`; default `claude codex antigravity openhands` | the agents this project serves. `init` deploys the file of each one named (`.cursorrules`, `.windsurfrules`, `.github/copilot-instructions.md`, `.openhands/microagents/repo-rules.md`) and no other. Empty: every pointer file. |
| `TRACKER` | `github` (default), `forgejo` | where the project's issues live: the folder of `lib/` whose `tracker.sh` every issue and board command calls; `forgejo` is the exception, a tracker whose API carries no board and which has no Bash provider, whose issue commands run in Node from `lib/forgejo/tracker` (section 8.1). Any other value with no such folder stops the command and names the folders there are. The environment variable `TRACKER` overrides it. `TRACKER`, `FORGE`, `FORGEJO_URL` and `FORGEJO_TOKEN_COMMAND` are read from the main checkout's `.ai-core/config.env` (in the parent of the git common directory), never from a worktree's own copy, which `init` makes once and nothing refreshes: after the switch every worktree in flight reads the checkout's tracker, and the server the key goes to and the command that yields it come from that one file. A harness clone, the clone of a project harness layer, has no `.ai-core/config.env`, because `init` deploys into the repositories a layer serves and never into the layer: where it has none, it reads these four from the layer's own `config.env` at the root of the main checkout, for a worktree of it as for the clone itself, so the issues of a harness repository move and are read like any other. A product clone does not read a `config.env` at its root. When the main checkout has no `.ai-core/config.env`, or its `.ai-core/STAMP` names setup-ai-core alone, these four settings come from the main checkout's immediate parent if that folder is outside Git, has `.ai-core/config.env` whose `FORGEJO_URL` names the host of the main checkout's origin, and has a `STAMP` naming setup-ai-core followed by a project layer. A checkout whose own `STAMP` names a layer keeps its own config. Every other key stays the worktree's own. |
| `FORGE` | `github` (default), `forgejo` | where the project's code lives: the folder of `lib/` whose `forge.sh` creates and clones the harness repository, waits for the check of a release commit or of a reviewed tip, says whether a repository is public and names the signed-in user. A value with no such folder stops the command and names the folders there are. The environment variable `FORGE` overrides it. |
| `FORGEJO_URL` | the scheme and host of the instance, such as `https://forge.example.test` | with `FORGE=forgejo`: the instance the repository calls go to, and the host `origin` names. No default, and no credentials, path, query or fragment: a call that needs it stops and names it. A new project names its forge in the environment of its first `ai-core init`, which creates the harness repository on that instance; the harness's own `config.env`, which every checkout gets, carries the settings from then on. |
| `FORGEJO_TOKEN_COMMAND` | a command | with `FORGE=forgejo`: the command whose output is an access token of the instance. It runs when a call needs the token; the token stands in no argument, no environment and no file, and in no trace of `bash -x`, because curl gets it through its configuration on standard input and git gets it from `ai-core git-credential`. A token with a control character in it, a line break, a carriage return or a tab among them, is refused by the name of this setting before curl or git sees it. A clone that has no `.ai-core/config.env` of its own, such as the clone of a project harness, reads the settings of its project folder. |
| `GH_ORG` | a GitHub organisation or user | the owner the board commands act for when a command names no repository (`repo-boards`, `project-new`, `incident-count`, a bare board number). Unset: the owner of the repository the command runs in. The environment variable `GH_ORG` overrides both. |
| `MAP_TOOL` | `claude` (default), `codex`, `agy` | the agent CLI `ai-core map` writes the map with, in its non-interactive read-only mode; `AI_CORE_MAP_TOOL` in the environment names the CLI of one machine instead, for example `agy` where Claude's quota is spent |
| `MAP_MODEL` | a model id, or empty (default) | the model that CLI uses for the map; empty is the CLI's own default. It goes only with `MAP_TOOL`: `AI_CORE_MAP_MODEL` in the environment names the model of one machine, and a machine that names another CLI without it gets that CLI's default (`agy models` lists agy's, e.g. `claude-sonnet-5-5-high`) |
| `UPDATE_CHECK` | `session-start` (default), `never` | whether `session-start` asks `update --check` for a newer release; `AI_CORE_UPDATE_CHECK` in the environment overrides it. Nothing is updated by it |
| `USAGE_STOP_AT` | a percentage of a window used, `92` when unset | the usage limit, the same for every tool whatever share it shows: at it, in any window, every session finishes the step in hand, commits, reports and waits for the reset; `ai-core usage` exits 3 there; the hour a window reaches it at the measured burn is shown and stops no start |
| `LIVE_TAGS` | environments with the pattern of their release tags, the last stage first, separated by spaces, e.g. `prod=deploy/prod/* test=deploy/test/*`; `landed` as the pattern for a repository with no release tag of its own, e.g. `prod=landed`; `command` as the value for an environment whose delivery only a reader of the project can tell, e.g. `prod=command test=command`; empty by default | where `ai-core status` reads a card's work as live: on an environment from the first of its tags that contains the newest commit on the default branch naming the issue, on a `landed` environment from that commit's landing, and on a `command` environment from the delivery its reader answers (`LIVE_RELEASE_COMMAND`). The first environment is the one whose release makes a proof due: the TESTING block shows a card it carries as red, `proof due on <environment>`, until a trusted `Proven on <environment>:` comment follows the landing record, then as green, `proven on <environment>`, and a card no release of it carries yet as waiting, `waits for the release of <environment>`, with its tag pattern. Empty: every release tag of the card's repository is its release, as `status-sync` reads it, so a card is red from the first tag that contains its landing and waits, `waits for a release of <repository> (every tag)`, while none does. An environment name is spelled as written: `prod` and `Prod` are two environments. Both commands read the list of one clone where it names an environment, and the project folder's list, the `LIVE_TAGS` of the `.ai-core/config.env` in the project folder, where it names none, whichever checkout the command runs in; `status` takes the clone of the card's own repository and walks every environment of the list, `status-sync` takes the clone the work landed in and its first environment only, and reads every tag where neither list names one. `status` makes one exception: a card whose landing clone has an environment of its own list set to `command`: that card is read by that clone's whole list, tags and `landed` entries included, from the landing record of its issue, and the entries of the project folder's list are not mixed into it. A `command` in the project folder's list alone runs no reader of a clone that did not declare it: the cards it would decide are shown as unknown by `status`, and by `status-sync` as `unknown` and staying, with the missing declaration named. An exported `LIVE_TAGS` selects nothing of this |
| `LIVE_RELEASE_COMMAND` | one executable file, an absolute path or one relative to the clone; no default | the reader of the `command` environments of this clone's `LIVE_TAGS`, read from this clone's own `.ai-core/config.env` and from no exported variable. It is started in the clone, never through a shell, with two arguments, the full `OWNER/REPO` of the clone and the environment, and only reads. It prints one JSON object whose five fields are nonempty strings, `repository` and `environment` as they were given, `commit` the full object ID, in that repository, of the newest completed delivery of the environment, `releasedAt` when that delivery completed, UTC `YYYY-MM-DDTHH:MM:SSZ` and not in the future, and `source` the release or the successful run it inspected; or JSON `null` with exit 0 where there is no completed delivery. For a repository pinned by the release of another one it is the commit the newest completed release pins, read from that release's own contents; for a redeploy it is the commit the last successful run fetched, which a rollback changes, and a failed or pending attempt and the tip of the default branch are none. A missing or non-executable reader, a non-zero exit, no output, text that is no JSON, more than one value, another repository or environment, a time that is none, and a commit the clone, fetched, does not hold are errors, and nothing stands in for an error: no tag, no `landed`, no tip, no earlier answer. The harness checks the shape and the identity of the answer; whether the reader told the truth about a deployment outside the clones is the project's, and so is the deadline of every request it makes: the harness cannot know that an executable stops. Both commands start it once per repository and environment and run, and keep nothing of it for the next run. `status-sync` closes a card of a `command` environment when the landing commit is on the default branch and in the delivered commit, and a `Proven on <environment>:` comment of a trusted author came later than both the landing record and `releasedAt`: the environment is the first word of the first line after `Proven on `, up to a space, a tab or the colon, and equals the first environment of the list whatever the case of its letters; it may be followed by an annotation in parentheses before the colon, `Proven on prod (https://example.test):`. A proof before the delivery, at its second, of another environment or of a longer word proves nothing |
| `ECOSYSTEM_ORDER` | tool names of `models.tsv`, `claude codex agy` when unset | the order the owner starts the coordinators in; a package stays in the ecosystem whose coordinator planned it |
| `CI_GATE` | `public` (default), `none` | whether a public repository of the project lands only on green checks of its CI (`public`), or lands like a private one on its push gate, with nothing pushed to `ci/` and no CI read (`none`), for a project whose CI runs on its own machines; any other value refuses a landing. On Forgejo `integrate-issue` reads it the same way (section 8.1) |
| `INTEGRATE_MAX_ROUNDS` | a whole number from 1 to 999999999, `3` when unset | the most rounds `ai-core integrate-issue` makes, the first attempt counted: when the default branch moved while a round's gate ran, the next round fetches it again, merges onto its new tip and runs the whole gate on that merge; `1` is a single attempt that stops with nothing pushed and asks to run again. Read from the `config.env` of the checkout the command runs in before every round, so a change reaches a landing that runs and a value lowered below the rounds made ends it; never from the environment. An invalid value stops before the next merge or push and names the key. The Bash and the Forgejo command read it the same way |
| `PRE_PUSH_LOAD_LIMIT` | a number of 0 or more, `24` when unset | the 1-minute load average below which the push gate starts `scripts/check.sh`; at or above it the gate waits. An absolute load, not a share of the cores. `0` turns the wait off. Read from this file only, at every poll, so an edit takes effect during a wait |
| `PRE_PUSH_LOAD_WAIT_SECONDS` | a whole number of 0 or more, `300` when unset | the seconds the gate waits for the load to fall below the limit; then the check starts and the gate says it started above the limit. `0` starts it at once. With either setting at `0` the load is still measured once for the record of the run; a reading that fails is said and recorded as `-` and refuses nothing, while with both above `0` a load that cannot be read refuses the push. An invalid value refuses, naming the key |
| `NEIGHBOUR_LOCK_WAIT_SECONDS` | a whole number from 0 to 999999999, `600` when unset | the least seconds the push gate and `ai-core init` wait for the lock of a published neighbour copy. The gate holds only the neighbours the repository names (section 4.12); init prepares every linked neighbour: a copy that a check reads is not moved until the check ended, and a move that waits keeps later gates out, so it waits for the checks that were running, not for later ones; a copy that needs no move waits for nobody. The wait is the greater of this and one and a half times the longest check in the run log of this machine, read from the rows of the last 14 days only, so one outlier ages out by itself; it counts for no less than 1320 seconds, so `600` waits up to 1980 seconds while no check of the last 14 days took longer than 1320 seconds; `0` tries once and does not wait. The setting is read again at every poll, and the wait counts from its start. After the wait the gate refuses the push and init names the copy it could not move; a check that runs longer than the wait keeps its copy, and the refusal says so. An invalid value refuses, naming the key |
| `START_CHECK` | a command, empty when unset | run by the person in charge on the bundle of a package's branches before it lands; empty means the project names none |
| `PROOF_HOURS` | hours, `24` when unset | how long a later environment of `LIVE_TAGS` may carry a card the first one does not before `ai-core status` marks its proof there overdue with 🔴; `status` reads it from the project folder's `.ai-core/config.env`, whichever checkout it runs in |
| `DEFAULT_BRANCH_IS_LIVE` | `yes`, or the folder names of the repositories whose default branch goes live; unset by default | a push to such a default branch needs `scripts/check.sh` and a `Reviewed-by:` trailer on its last commit (section 4.12) |
| `DIRECT_PUSH_FILES` | paths or shell patterns separated by white space, relative to the repository root; empty by default | the files whose change may reach the default branch by a plain push: the push gate admits it, without a landing mark, where every new commit touches only files that match (section 4.12, the direct push). Read from the `.ai-core/config.env` of the checkout the push runs in, at every push, and from no exported variable. Empty or unset: every plain push to the default branch is refused. A path that is absolute or holds an empty, `.` or `..` component is refused by name |

### 5.8 Many repositories

The unit of installation is one repository checkout. For a project with many repositories in one
folder, one command runs `init` in the folder itself, then in each git repository directly under it that carries the harness (its `.ai-core/STAMP`
exists) and in each worktree `start-issue` put under the `.worktrees/` of such a checkout. It names each other
repository in a line that says `ai-core init <path>` installs the harness there, and touches it in no way: what you
clone for your own reading stays as it is until you say what to do with it. It also skips the folders that are not repositories and the temporary
worktree of a landing (`integrate-<issue>.XXXXXX`, which `integrate-issue --from-origin` removes when it ends), names the
ones that failed:

```bash
ai-core init --all ~/repos/myorg
```

The folder is where many developers start their agent. It gets the same data as a repository,
an `AGENTS.md` that lists the repositories that carry the harness with the path of each map. Nothing there is under git, so nothing is excluded and nothing can be
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
A new clone or worktree runs `ai-core init` once. For a Forgejo project, the main checkout must
be directly inside a project folder already assembled from the project harness, or that run must
set `FORGE`, `FORGEJO_URL` and `FORGEJO_TOKEN_COMMAND` in the environment (section 5.7). A fresh
checkout whose origin is on the host of the folder's `FORGEJO_URL` borrows the folder's tracker
settings to find the harness, copy its config, and set the sign-in line. The next `init` also
repairs a checkout whose `STAMP` names setup-ai-core alone.

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
a new script in `bin/` is a command without any registration. The one exception is the Forgejo tracker: with
`TRACKER=forgejo`, the issue commands of section 8.1 run in Node from `lib/forgejo/tracker/cli.mts`, and the
board commands are refused there. Every other command, with any tracker, is Bash.

| Script | Usage | Exit codes |
| :--- | :--- | :--- |
| `session-start` | `ai-core session-start [--json]`; the JSON says `refused`, and a refusal carries the lines of the team modes; source checkouts validate source inputs without assembly; in a worktree named `issue-<n>-…` it prints the thread of issue `<n>`, of the repository `start-issue` recorded on the branch; where that thread cannot be read, the run is ready WITHOUT the issue and says why | 0 ready; 1 a team mode, product rules, or valid source inputs missing |
| `solution-path` | `ai-core solution-path <issue> <file> [--check]` | section 7 |
| `rules-check` | `ai-core rules-check [file-or-directory]`; default `.ai-core/rules/rules.md`, or the `rules/` directory of setup-ai-core; a directory means its `NN-*.md` section files; a project harness (a directory with `rules/`, `skills/` or `agents/`) is checked whole: every skill has a front matter with its folder's name and a description, every agent a name and a description and no model below Sonnet, then its rule sections | 0 every rule tagged and nothing wrong in the harness; 1 otherwise |
| `init` | `ai-core init [TARGET_DIR \| --all <folder>] [--no-doctor] [--dry-run]`; the commit it makes of the `.gitignore` block is pushed to the checked-out branch with the mark of a harness landing, so the armed push gate lets it through | 0 in place, or dry; 1 invalid arguments, doctor failed, or a repository under `--all` failed |
| `map` | `ai-core map [dir] [--all <folder>] [--no-push] [--dry-run]` | 0 written (or unchanged, or dry); 1 no harness, `~/.ai-core/claude-run-settings.json` missing for a `claude` run, the agent CLI failed or wrote something that is not a map, or a repository under `--all` failed |
| `push` | `ai-core push [MESSAGE] [--harness <name>]`; runs `rules-check` on a clone with changes first and does not commit one it refuses; the first paragraph of MESSAGE, its lines joined by a space, is the subject of the commit and has at most 72 characters, or nothing is committed, and the message it writes itself names as many changed files as fit in 72; pushes with the mark of a harness landing, so a push gate armed in the clone lets it through; then refreshes the checkout it runs in with `init`, unless that is a harness repository, where `init` refuses | 0 every harness clone pushed or had nothing; 1 no clone, a clone `rules-check` refused, a commit or a push failed; 2 a wrong argument or a subject over 72 characters |
| `update` | `ai-core update [--check] [--main]` (section 5.10) | 0 done, or `--check`: everything current; 2 `--check`: a release or commits available; 1 an origin could not be reached |
| `release` | `ai-core release <version>` (in a clone of setup-ai-core, section 10); the commits it sends to the default branch carry the mark of a harness landing, so the armed push gate lets them through | 0 tagged and pushed; 1 refused, naming what is missing; 2 a wrong argument |
| `pre-push` | `ai-core pre-push [--install [--all <folder>]]` (section 4.12; it writes into a worktree only where its folder stands, so a worktree that `finish-issue` removed meanwhile stays gone, and pushes the commit of the shims with the mark of a harness landing); `ai-core pre-push --runs [--repo OWNER/REPO] [--since TIME]` lists the runs of the gate on this machine, newest first, each with its verdict (green, red, or no check), the seconds `scripts/check.sh` took (the wait for a lower load not counted), its last line and the 1-minute load when the check started (`-` for a run with no check, and for a run recorded before that column existed; a run that did not execute `scripts/check.sh` because the receipt of its landing showed it green is `no check` and its last line says so; a log may hold rows of both widths under its first header, and the listing shows the current header; the row an append has not ended is not listed; the longest of these checks of the last 14 days sets the wait for the copy of a neighbour, see `NEIGHBOUR_LOCK_WAIT_SECONDS`; a row with the verdict `landing lock` is no run of the gate: a landing writes it when it gives up the landing lock of its clone, with the seconds it held it, and one and a half times the longest of these holds of a repository is the deadline of the landings that wait for it where that is more than the bounds configured for a holder, see `integrate-issue`) | 0 nothing refused the push, the shim written, or the runs listed; 1 refused, a repository under `--all` is none, or the log cannot be read; 2 a wrong argument |
| `git-credential` | `ai-core git-credential get` (git runs it; `store` and `erase` do nothing): the credential helper `init` and the clone set for an origin on the `FORGEJO_URL` instance, as `credential.<FORGEJO_URL>.helper` in the clone's own `.git/config`, an empty entry and then `!ai-core git-credential`: the empty entry drops the helpers git takes from the system and the user's configuration, a `store` or a cache among them, which would keep the token and answer with it after the token command changed. With `FORGE=forgejo`, the push gate also passes these entries to `scripts/check.sh` in git's environment configuration after the caller's entries, the second one with the checkout's `FORGEJO_URL` and `FORGEJO_TOKEN_COMMAND` set for the helper alone, so git outside the checkout can sign in and the check's own environment gets neither setting. `init` sets the same two entries in the user's git configuration (`git config --global`) for the exact scheme, host and port of `FORGEJO_URL`, once (any helper value the file held for exactly that instance is replaced by the pair), with one `credential.<FORGEJO_URL>.aiCoreConfig` entry for each checkout: the path of the `.ai-core/config.env` of its main checkout, never a token and never a token command, under a lock so that two inits lose no entry and double none. A tool that runs git in a repository of its own, such as the cache of the git dependencies of `dart pub get`, then signs in with no variable set. The helper takes the settings of the checkout git runs in first where git was signed in there, by the pair in that checkout's own `.git/config` or by both settings in git's environment (ai-core's own git and the push gate), and the registered files everywhere else and for an instance those settings do not name: a `.ai-core/config.env` that stands in a plain folder, or that a clone nobody initialized tracks, never answers, and its token command never runs. It runs the token command of every registered file that names the instance as its `FORGEJO_URL`, answers where all give the same token, and refuses, naming the files and printing no token, where they differ, where a file cannot be read or where a command fails. A file that is gone, or that names another instance now, supplies nothing. The empty entry drops only the helpers git read before it, so a helper git reads after it stays in the chain and receives the token through `store`: one below init's entries in the same file, one in the configuration of the repository git runs in, such as a tool's cache, and one on git's command line or in its environment configuration. It answers git's `get` with the username `ai-core` and the token that `FORGEJO_TOKEN_COMMAND` prints at that moment, and answers nothing for any other host or for http where `FORGEJO_URL` is https. An origin over ssh needs none of it | 0 answered or nothing to answer; 1 the token command failed or printed nothing, or the registered files are ambiguous or cannot be read; 2 a wrong argument |
| `tool-order` | `ai-core tool-order [TOOL[,TOOL...] \| --clear]`; read or atomically replace the machine-wide preference under `${AI_CORE_HOME:-$HOME}/.ai-core/tool-order.json`, with its actual set time; validation checks project model rows and usage support, allowing exhausted tools; `--clear` appends an entry with no tools, which removes the saved order and keeps its history | 0 read or saved; 2 invalid order, unsupported usage, or state read/write failure; the previous preference survives a refused replacement |
| `phase-model` | `ai-core phase-model PHASE CLASS [--written-by MODEL]`; exactly `TOOL MODEL EFFORT` on stdout, first eligible execution tool in the saved order and, within a tool, the first eligible row in table order, exact class before `*`, two equal rows refused as ambiguous; review and plan-check require the actual writer; `--setup-file PATH` hands it the planner's `Setup:` object (JSON keyed `build`, `review`, `ui-test`, each per tool with `model`, `effort`, `estimate_tokens`, `budget_tokens`, `reason`), validated whole before any quota is read: a tool with an entry for the phase uses that tuple instead of its table row where the table names it for that phase (a `high-risk` package exactly the tool's `high-risk` row, a UI test the tool's UI-test row, a tool without a build row for the class none), `budget_tokens` is 1.5 times `estimate_tokens` rounded up and within the ceiling of the phase, and `--written-by` still skips a tool whose entry is the writer's model; every answer is saved in `phase-model.jsonl` with project, order snapshot and quota reasons | 0 selected and recorded; 2 refused, with each rejection on stderr; quota exit 3 is skipped, other failures stop the selection |
| `usage` | `ai-core usage [--tool NAME] [--model MODEL] [--stop-at N]` | 0 every window below N, whatever its projection, so work goes on up to N; 3 a window at N or more; 2 nothing recorded yet, a reading that cannot be used (a window without its numbers, agy missing, signed out or answering something unreadable, a model no group of agy holds, a usage history that cannot be written or read, or a history lock still held after 10 seconds), or a wrong argument. Without `--tool`, also reports the saved order, set time, per-tool start counts, matched/total examined observations, red starts, unknown evidence and artifacts proving no start; an audit failure is named and returns 2 only when the quota itself passed, preserving quota exit 3. Prints the selected tool's usage windows (five hours, week), each with its reset in its time zone and the time left, its burn per hour since its first reading, and what it stands at by its reset or the hour it reaches N. Every tool's windows, their forecast and N are shown as the share used, so the output says `limit 92 % used`. `ai-core status --tokens` reads the same windows through the same reader (`lib/usage.sh`), and shows them the same way. Claude's windows and burn are what the status line recorded (`~/.ai-core/usage.json`, `~/.ai-core/usage.log`), Codex's newest quota record by its timestamp, with burn from records of the last week; a record older than one hour is renewed first by one minimal `codex exec` call, read-only in a scratch folder, on the model of the `helper` row of Codex in the models table and for at most 120 seconds, which costs between 4,000 and 8,500 tokens as measured on 2026-10-28; readers that find the same old record share one call through the lock `~/.ai-core/codex-usage-refresh.lock`, and a failed call leaves the old record in use with one line that names why (`ai-core status --tokens` shows the line beside the Codex windows), kept with its time in `~/.ai-core/codex-usage-refresh.failed` so that no reader calls again within the hour after it; agy's are asked of `agy -p /usage` at that moment, one window for every bucket of every group, named by its group (`Claude and GPT models: five_hour`), and every reading is appended to a file of the day under `~/.ai-core/usage-agy/` that holds a week, from which the burn of a bucket of a group within one reset is measured. Appending, pruning and reading agy history share a bounded lock, acquired after the external quota call. `--model` for agy judges only the group whose description in agy's answer lists a family that the model's display name in `agy models` starts with, allowing numeric version words such as `3.8` in `Gemini 3.8 Flash`; a model no group or two groups hold exits 2. A window whose readings span less than 30 minutes says its burn is unmeasured, and a window of more than a day that reaches N before its reset gets a line to tell whoever holds the account; `--tool` overrides session detection, which defaults to Claude outside Codex, agy and Gemini and refuses Gemini, and exit 2 means unknown usage rather than a successful preflight. The selector accepts `claude`, `codex` or `agy`. Each window has its reset time, against the limit N: `--stop-at`, else `USAGE_STOP_AT` of the project's `config.env`, else 92; a window whose reset has passed counts as reset. One model's own weekly quota is not among Claude's windows |
| `watch` | `ai-core watch [--session NAME]... [--ref CLONE:REF]... [--file PATH]... [--still S] [--every S] [--heartbeat S]`, run in the background by a session that oversees others, so its end wakes that session | 0 one line names what happened: a named session has not been `busy` in `claude agents` for `--still` seconds (900), or left it; a named session compacts in a loop, read from its transcript (`<root>/*/<sessionId>.jsonl` of each of its entries in `claude agents --json`, the root `AI_CORE_TRANSCRIPTS` else `~/.claude/projects`), whatever its status: three `compact_boundary` lines of different uuids within the last 600 seconds, or Claude Code's own "Autocompact is thrashing" error message within them (the words inside an ordinary message count as nothing), the line naming the session, its id where one name stands on several entries, and the sign; a ref moved, its clone fetched every `--every` seconds (60); an output file stopped growing for `--still` seconds without a parsed final `turn.completed` event; or the heartbeat (1800) passed, with every session/ref and every file’s path, bytes and minutes since growth. File inactivity is not proof of a hung process. Files must exist and be readable before watching; 1 a fetch, `claude agents` or a file read failed, or the transcript of a named session is missing, unreadable, found twice, in another folder than its `cwd` names, holds a complete line that is no JSON or a compaction without its time or uuid, named in the line and never counted healthy. Only Claude Code sessions are covered: a Codex or agy session has no such transcript, and `--file` watches a Codex run; 2 a wrong argument, nothing to watch, a ref that names nothing or an invalid file |
| `permission-request` | the `PermissionRequest` hook `init` writes into `.claude/settings.json` | in a background session (`CLAUDE_JOB_DIR` set), answers the permission prompt Claude Code is about to show with a deny and a message naming the call, so the session goes on instead of waiting for nobody; elsewhere it prints nothing and the prompt is shown |
| `statusline` | the status line command `init` writes into `.claude/settings.json` | records the usage windows Claude Code hands it in `~/.ai-core/usage.json` and, at most once a minute, a line of them in `~/.ai-core/usage.log`, then shows a short line of the model and the windows |
| the board and issue commands | `ai-core issue-new ...`, `ai-core start-issue N`, ... (section 8) | 0 done; 1 refused or gh refused; 2 a wrong argument |
| `doctor` | `ai-core doctor [--no-install]` | 0 every required tool present and the forge's login answering (gh logged in, or the Forgejo token accepted and `git ls-remote origin` answering; gh with its login and the `project` scope also where only `TRACKER` is `github`); 1 otherwise, each problem with its instruction |
| `install` | `bin/install.sh [--source <clone>] [--dir <path>] [--repo <url>] [--no-path] [--no-doctor]` | 0 installed and doctor OK; 1 when doctor found problems |
| `ai-core` | `ai-core <command>`: any script in `bin/` by name, plus `version`, `help` | the command's exit code; 1 for an unknown command |

`doctor` today checks Git, gh and its login, Bash, Node.js 20+
with `npx`, jq, the team modes, and with `TRACKER=forgejo` the Forgejo tracker (it runs
`node lib/forgejo/tracker/cli.mts --version`, which a Node that cannot run `.mts` files fails, and then asks the
tracker, which tells "not configured", "not authorized" and "healthy" apart), and reports whether `claude`, `agy` and `codex` are installed, with the install command
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
this public policy. `labels-sync`, `issue-label` and `repo-link` check label names and
descriptions before writing. `project-new`, `field-option-add` and `view-filter` check project
names, identifiers, label metadata, option names and descriptions, and view filters. Project
visibility is not established by the GitHub provider, so these project fields use the public policy
even when a repository is private. Each issue's title and body share one visibility decision.

Reserved domains (`invalid`, `example`, `test`, `localhost`, `example.com`, `example.net`,
`example.org` and their subdomains) and the exact GitHub domain `users.noreply.github.com` are
allowed, ignoring domain case. A domain without a dot is no address and passes, as `sha256` does in an
image reference such as `name:1.2.3@sha256:<hex>`, and as `intranet` does in `user@intranet`. A domain
in square brackets is not tested for a dot. A local part containing `noreply` and an unverified
Forgejo noreply domain grant no exemption. The check reads the raw text as written. It refuses an address written
plainly, inside a code span or in a link. An address dressed so that the raw text differs from what a
reader sees may pass. Whether it passes depends on where the dressing stands in the address, so
nobody may rely on the check for a dressed address. Dressings are, for example, a Markdown escape
such as `\@`, a code span or emphasis in the address, HTML such as a comment or a tag in it, an
invisible format character (U+200B, U+00AD, U+2060), a lookalike of `@` or `.` (U+FF20, U+FE6B,
U+2024, U+FE52), or an address whose local part is the domain of an exempt, numeric or dotless match before it, such as a reserved-domain address or `a@b` directly followed by an at sign and a real domain, as in `a@b@company.ch`. Encoded addresses,
images, an address written as “name at domain”, and a domain that opens with a symbol or whose first
label holds one that IDNA2008 does not allow in a label, such as an emoji, are not covered either. It refuses rather than
redacting and leaves the caller's file unchanged.

| Command | Does |
| :--- | :--- |
| `issue-new` | creates an issue: `--title`, `--body-file`, labels, priority, the assignee from `assignees.tsv`, the card on the board, optionally a parent epic (`--parent OWNER/REPO#N`), which then follows its sub-issues as under `issue-status`. Refuses without `--asked-by LOGIN` and `--asked-in WHERE` and writes "Asked for by @login on DATE in WHERE." as the body's first line; the command also accepts `--found-in WHERE` instead, with any type, and opens with "Found in WHERE on DATE, a defect filed without a yes." for a `type:bug` issue and "Found in WHERE on DATE, a finding filed without a yes." for every other type, but no session may use that option: every new issue, a re-cut's share included, needs the owner's yes and the `--asked-by` and `--asked-in` record. Reports a title over 70 characters, one with a backtick, or one that names an action and no stake. `--no-board` files it in a repository linked to no open board, a harness among them: no card, no status, no priority; refused where the repository is on a board, and together with `--project`, `--priority` or `--status`. |
| `start-issue [OWNER/REPO] N` | opens the worktree for issue N under `../.worktrees/<repo>/issue-N-<slug>`, on a branch of that name cut from `origin/<default>` after a fetch, only when the issue is assigned to you; whatever state the checkout is in (behind origin, with changes, with commits of its own, on another branch or a detached `HEAD`, or without a commit yet), the worktree starts from origin, at the commit the run read and measured, and one line names that state when there is one to name (changes, a distance from `origin/<default>`, or no commit yet; a clean checkout level with origin gets none, on whatever branch or a detached `HEAD`), read without touching the checkout: its branch, index, files and commits stay as they were; a failed fetch, a missing `origin/<default>`, or a failed read of the checkout's status, `HEAD` or distance from origin refuses before anything is made; moves the card to `implementing`; runs `init` there, which takes the checkout's `.ai-core/` data first; prints the thread. For an issue of another repository whose work lands here, `OWNER/REPO N` cuts the worktree here and records the issue's repository on the branch (`git config branch.<branch>.issueRepository`), where `session-start`, `integrate-issue` and `finish-issue` read it. A branch `issue-<n>-…` is this issue's unless the repository recorded on it is another one: `start-issue <number>` cuts a branch of its own beside a branch of another issue that carries the same number, and refuses where its new name is already the branch of another issue, because cutting it would move that branch. For an issue of another repository, a branch `issue-<n>-…` without a recorded repository, local or only on origin, is a branch of this clone's own issue of that number and is no obstacle: only the branch named as this issue's branch, or one that records the issue's repository, is taken. The branch is set to push to and track `origin/<its own name>`, never `origin/<default>`: a plain `git push` from the worktree makes the issue's branch on origin (`git status` shows `origin/<branch>` once it exists), `ai-core pre-push` run from a terminal judges the branch against it, or against every ref of origin before the first push, and only a landing updates the default branch. One run, because any one of these done alone is often not done. |
| `integrate-issue [OWNER/REPO] N [N ...] --reviewed-by R [--from-origin] [--part]` | Given several numbers (the repository of the first issue, named or recorded on its branch, holds for all), it lands a package's issues in one push: the first issue's branch comes from the worktree, every other one as `--from-origin` reads it from `origin`, all merged in one temporary worktree, one merge commit per issue, in the order given, each with its own subject and the `Reviewed-by` lines; the lock, the fetch, the gate (a public repository: one push to `ci/integrate-<first branch>` and one wait for its checks) and the push happen once, a conflict of any issue lands none of them and names its branch, an issue named twice, without a branch on `origin`, or whose branch holds nothing that the issues before it do not, so that it would get no merge commit of its own, is refused before anything moves, and the `next:` lines name every issue. In the worktree of issue N, after the reviewer's GO: merges its branch with `--no-ff` into the newest `origin/<default>`, under the issue's title with `(#N)`, or `(OWNER/REPO#N)` for an issue of another repository, given or recorded on the branch (or `Merge <branch> (...)`, then `Merge issue-N (...)`, where the title does not fit 72 characters) and a `Reviewed-by: R` trailer per `--reviewed-by`, pushes `HEAD:<default>` through the gate, checks the branch out again for `finish-issue`, and safely fast-forwards the main checkout’s default branch. A skipped refresh names the checkout and reason; the successful integration stays successful. The landings of one clone take turns, for Forgejo and GitHub alike (`lib/landing-lock.sh`): a round takes `ai-core-landing` in the clone's git directory before its first fetch and holds it until its push ended or was refused, so no other landing of the clone moves the default branch while its gate runs. A landing that finds it held names the issue and the branch holding it and waits, one whose holder no longer runs takes it over, and the wait has a deadline for every holder, counted from the moment that holder took the lock (the lock names it with the holder's process, issue, branch and repository), so a landing that waits behind three holders in turn stops only when one of them has held the lock longer than the allowance. The waiting line names the holder, since when it holds the lock and when the deadline for that holder is. The allowance is one and a half times the longest time a landing of that repository held the lock in the last 14 days: every landing records how long it held the lock, in a row with the verdict `landing lock` in the log of `pre-push --runs`, when it gives the lock up. It is never less than the sum of the bounds a holder may spend under the lock, because a landing refused a second after its take records a short hold and a holder whose gate waits for the load holds the lock longer than one that did not; that sum is the allowance where it is more than the measured one and where no hold of the repository is recorded (no log, a log that cannot be read, no repository named by origin, no landing yet), and the waiting line then says that it is configured, not measured, why, and from which settings: one and a half times the longest check of the repository on record (1320 seconds where none is recorded), plus `PRE_PUSH_LOAD_WAIT_SECONDS`, plus, under `CI_GATE=public`, `AI_CORE_INTEGRATE_WAIT`; a private repository under `CI_GATE=public` carries the last term too, because the visibility is asked from the forge only after the lock is taken, and the time of `scripts/install.sh` has no bound of its own. At the deadline the landing stops with nothing pushed and names the holder, the time it took the lock and how long it has held it; a holder that gives the lock up, or whose process no longer runs, is replaced by the next one, which has its own count. Where GitHub refuses the read of the issue, a rate limit among the causes, it says "nothing landed" and names the cause. A public repository lands only on the green checks of the commit that lands: the forge says whether the repository of origin is public, and if it is, the merge commit is made in a temporary worktree of `origin/<default>` (the issue's worktree stays untouched, in both paths), pushed to `ci/integrate-<issue branch>` (a name only a landing uses, so a `ci/<issue branch>` a person pushed for the CI is never touched), and the command waits for the checks of exactly that commit (the workflow runs `check` and the commit statuses on GitHub, the combined commit status on Forgejo; every 20 seconds, 30 minutes at most, `AI_CORE_INTEGRATE_POLL` and `AI_CORE_INTEGRATE_WAIT` in seconds) under the landing lock, so that no other landing moves the default branch while the checks run and a slow CI holds up the landings of the clone behind it, which wait for it as long as the measured hold and half again, and at least the bounds configured for a holder. Green prints a line naming the commit and `ci/integrate-<issue branch>`. Red, checks that do not finish in time or cannot be read, and an issue branch tip that moved refuse with nothing pushed to the default branch. An `origin/<default>` that moved while they ran ends the round, and the next one is made on the new tip (see the rounds below). After a fetch the push sends exactly the merge commit that was checked. The push to `ci/integrate-<issue branch>` replaces what stands there, a left-over of an earlier landing of the issue or the branch of one that still runs, but only if it is still what was read just before the push (a lease), so a branch written in between is refused; the delete removes the branch only while it holds this landing's merge commit and names it in one line when it stays. The delete runs on every way out that can be trapped, a delete or a lookup that fails is named in one line and changes nothing, and a SIGKILL leaves the branch behind until the next landing of that issue replaces it. Without `--from-origin`, a public repository whose local branch tip is not the tip of `origin/<branch>` refuses at once, because a commit origin does not hold has no checks. A private repository rests on its push gate, which is its check: no CI is read and one line says so. A visibility the forge does not establish refuses, with the reason. With `--from-origin` it runs in any directory of the clone and lands `origin/<branch>` instead, in a temporary worktree of `origin/<default>`, named `integrate-N.XXXXXX` in `.worktrees/<repository>/` beside the clone, where `start-issue` cuts its worktrees (so a project test that walks up to a sibling checkout finds it), that is removed afterwards, so the issue's worktree, its branch and its uncommitted changes stay as they were; it names the commit it merges, and a commit the branch holds only locally does not land. Where the merged tree tracks `scripts/install.sh`, it runs there after the merge and before the push, with its output shown, so the gate's check finds what it needs installed; a failing install says so, pushes nothing and leaves the issue's worktree as it was. A branch `issue-<n>-…` of an issue of another repository is named and not taken, in the worktree and with `--from-origin` (which fetches first). Its `next: ai-core finish-issue` lines name each issue that a `(#N)` or `(OWNER/REPO#N)` of a merged commit names. Refuses without a reviewer, on a branch that is not issue N's, with changes in the tree, on a conflict and on a branch already integrated, each time with the branch checked out again and nothing pushed. A default branch that moves while a round runs ends that round with nothing pushed to it: the command fetches origin again, merges every branch onto the new tip, runs the whole gate on that merge and pushes it, by itself, in at most `INTEGRATE_MAX_ROUNDS` rounds, the first one counted (3 when unset; 1 is a single attempt; the setting is read from the `config.env` of the checkout again before every round, never from the environment, and a value that is no whole number from 1 to 999999999 stops the run before the next merge and names the key). Each round says its number, the limit, the base and its merge commit. A move is proven by the refusal of origin that git's own porcelain lines name, together with an `origin/<default>` that is not the base: a red gate beside a move stays a red gate. The branches must hold the commits round 1 read, else it stops. A conflict, an install that fails, red, unfinished or unreadable checks, a `ci/` branch somebody else wrote, an unreadable origin and every other refusal stop at once; the bound reached stops with the last cause and nothing pushed to the default branch (a public round may have pushed its merge commit to `ci/integrate-<issue branch>` and deletes it again where it still holds that commit); the other landing is never overwritten. A push that git reports as failed while origin holds the merge commit is reported as landed. In a public repository the check of the repository runs once for the commit that lands: the first push to `ci/integrate-<issue branch>` runs it and leaves a receipt, and the push to the default branch skips it only for that commit, with the CI of it green (section 4.12, gate step 10). With `--part`, a landing that has more to follow (a package lands an issue in parts) only changes the `next:` lines, which then say `finish-issue N --part`. The reviewer is a name given, not a review proven |
| `finish-issue [OWNER/REPO] N [--landed \| --part]` | after the push that lands the work (with `--part`, a part with more to follow: the worktree, the branch and the card stay, and the issue is told "Landed part on <default>:" with the commits, a record that status-sync does not read as a landing; the last part runs without it); the issue, its card and its comment are in the repository given or recorded on the branch: removes the worktree and branch of issue N, only a worktree named for issue N (a package's worktree, named for its first issue, stays while a later issue's branch is checked out in it), only when it has no changes and the change of every commit is on `origin/<default>`, by ancestry or as an equal patch (`git cherry`, so a cherry-picked branch passes, and a branch that took the default branch in after the landing, whose head lies wholly on `origin/<default>`, passes too); `--landed` removes it anyway where commits landed in another shape, and clears the issue's branches on `origin` the same way, deleting each one at the tip that was measured, so a commit pushed meanwhile keeps it, and printing the commits whose change `origin/<default>` lacks; it refuses on an open issue before it removes anything, and a branch that a worktree holds, a worktree with changes, a worktree that is locked and a history that git cannot read stay, whatever the flag says (without the flag a branch of `origin` with such commits stays, and the message names `--landed`); a deletion that is refused reads `origin` again and says whether the branch is gone already, its tip moved, or `origin` could not be read; with `--landed` on a closed issue that no commit on `origin/<default>` names, it clears the branches of `origin`, says the card and the issue were not updated, and, where it met no worktree and no branch of the issue, that it removed nothing, touches neither and exits 0; refuses, moving no card and telling the issue nothing, when no commit on `origin/<default>` names the issue, unless it removed a worktree and every worktree it removed was never committed in: that holds no work, so the run says the repository holds no work of the issue, moves no card, tells the issue nothing and exits 0; moves the card to `testing` where the board has that column, and in a repository on no board says there is no card; comments on the issue what landed, once: an issue that holds one record of the landing in this repository, written by the repository's owner, a member or a collaborator, that lists every commit of the run gets no copy, and a commit the record lacks gets the full record (an open issue's record must also follow its last reopening and stand among the last 50 comments, the ones `status-sync` reads; a closed issue's may be any age); comments that cannot be read leave the issue untold, and the run says so; runs `status-sync` for its repository and the issue's. It measures the worktree and the branches of the issue before any is removed, and leaves a branch that belongs to an issue of another repository, naming it. The local branch is deleted in one step, only while it still points at the tip that was measured (`git update-ref -d` with that tip), so a commit that arrives meanwhile keeps the branch, and its configuration section goes with it. A worktree that `ai-core init` is equipping is locked (`git worktree lock --reason "ai-core init"`, lifted when init ends, also after a failure or a TERM): `finish-issue` names that lock and the retry and removes nothing, and a lock that a kill -9 of init left stays until `git worktree unlock <path>` lifts it. `--sweep [--dry-run]` removes every worktree of the repository whose work landed more than a day ago, names a locked worktree as staying and goes on to the next; `init --all` runs it on every tracker and `start-issue` on GitHub, and it reads git alone, so on Forgejo `ai-core finish-issue --sweep` runs it too |
| `issue-thread N [--json]` | the issue and every comment on it, for a person or as one JSON object |
| `issue-map [OWNER/REPO ...]` | one line per open issue (status, type, area, title, parent, `blocked by`, `blocks`, the files its body names as `path:line`), then the groups a parent or a `blocked by` joins and the files two issues share; read from the tracker each time |
| `issue-mine N` | whether the issue is assigned to the account `gh` is logged in as; `start-issue` and `session-start` ask it |
| `issue-comment N` | adds a comment, inline or `--body-file`, over REST so a GraphQL limit cannot lose it; a refusal by GitHub (HTTP 403 on an issue with 2500 comments among them) says the comment was not posted and carries GitHub's words, a lost answer says it is not known whether it was posted, and the post is sent once either way |
| `issue-edit N` | edits title and/or body; a body without the asked-for line keeps the one the issue has |
| `issue-close N...` | closes issues and moves their cards to `done`, as `completed` or `--reason not-planned`; refuses an issue that has an open sub-issue, with either reason, naming the open sub-issues as `OWNER/REPO#N` and changing nothing for it, no close and no card (every page of its sub-issues is read, closed means the issue's own state and never the column of a card, and a read of them that fails refuses too); the epic of a closed issue follows, as under `issue-status` |
| `issue-reopen N...` | reopens issues and returns their cards to `ready` |
| `issue-status N... STATUS` | moves cards between `backlog`, `ready`, `planned`, `implementing`, `review`, `testing`, `done`; in a repository on no board, with no board named, it says the status is not set and exits 0. The epic of a moved issue follows its sub-issues alone, forward and back: closed and `done` once all that count are closed, `testing` once all stand in testing or done, `implementing` once one has started (a done one has), and otherwise where the least advanced of them stands, in the order `backlog`, `ready`, `planned`; a sub-issue closed as not planned or as a duplicate does not count, and an epic whose sub-issues are all of that kind does not move; a sub-issue that is still open counts at most as `testing`, even where its card stands in `done` or `not planned`, so its epic goes to `testing` and stays open; an epic that stands elsewhere, one in `done` or `implementing` after its sub-issues went back included, is moved there by the next `issue-status`, `issue-new --parent`, `subissue-add` or `subissue-remove` of one of its sub-issues, and a closed epic with an open sub-issue under it is reopened first |
| `issue-priority N... P` | `P0` blocker, `P1` high, `P2` normal, `P3` low, `P9` parked; on no board, as `issue-status`. Any other value is refused naming `P0`, `P1`, `P2`, `P3` and `P9`, before any write |
| `issue-label N --add/--remove` | labels checked against the `labels.tsv` of the project the issue's repository belongs to, never the caller's: the catalog its clone carries on this machine, else the one init would install, rebuilt read-only through the forge at one pinned commit per source repository (a tracked `.ai-core/labels.tsv`, else the innermost harness's `repos/<repo>/.ai-core/labels.tsv`, else the most derived layer's `labels.tsv`, else the base template); a source that cannot be read stops the call before any edit; a project harness the forge does not show is read as the base template, with a note that names it, because a forge answers a private repository the account cannot read as one that is not there; a typo is refused, not minted |
| `issue-package OWNER/REPO N --member OWNER/REPO#N... [--remove OWNER/REPO#N...]` | puts the label `package/<repo>#<number>` of the package's first issue (`OWNER/REPO N`) on every issue of the package, in every repository it spans, and takes it off the departures; `--member` is the whole package as it stands, `--remove` the issues that left it. The label is a repository label on GitHub, an exclusive organization label on Forgejo, and its description names the first issue as `OWNER/REPO#N`: a `package/` label of that name that names another first issue, or none, is refused before anything is written. Every issue and label is read before the first write and the result is read back; once every member is closed as completed the label is archived, so it stays on the issues and leaves the label picker, and a member that is open again makes it active again. A step that fails names what was confirmed, and the next run finishes it. It never closes or proves an issue, and the tracker does not serialize two runs for one package |
| `issue-assign N` | adds, removes or replaces assignees; additive by default. On GitHub an assignee with an ASCII `@` other than `@me` and `@copilot` is refused as an email address; one with a lookalike of `@` (U+FF20, U+FE6B) is not |
| `issue-duplicate N OF M` | marks N the native duplicate of M, or removes it with `--undo` |
| `issue-transfer N OWNER/REPO` | moves an issue to another repository; the card stays where it is |
| `issue-block`, `issue-unblock` | records or clears a real `blocked by` dependency, across repositories |
| `subissue-add`, `subissue-remove` | attaches issues to an epic as sub-issues, or detaches them; the epic then follows its sub-issues as under `issue-status` |
| `board-sync` | puts every issue of every linked repository on the board and reports what is missing: labels, priorities, cards that were not on the board |
| `board-list` | the board: status, priority, repository, number, title; a repository of another organisation than the board's is written with its owner, `owner/name` |
| `status [--project N] [--tokens] [--issues]` | the state of the work, the same page every time and counted, with no model. Without options: the board counts and every agent process on the machine, with the runs each one started under it; a Claude session's name comes from `claude agents --json` where its command line names none, its model and effort from that name where it follows the worker naming rule, and its issue from the `issue-<n>-…` worktree it was started in, marked `at start`, because a worker given a later package keeps that folder; a stopped process is marked stopped and not counted as running; under REACH the command that reaches each agent. Where no agent runs, and with `--tokens`: the usage windows of the tool whose shell runs it (Claude, Codex or agy, read and shown as `ai-core usage` reads and shows them, as the share used; Codex's and agy's named for the tool with the time the tool recorded them; a tool with no reader is named, never read as Claude) against the limit; the pace, the issues closed on the board in the last 24 hours, with the average of 14 days beside it; how fast the project folder raises each window an hour, the rise the usage log of the status line measured times the folder's share of the fresh tokens of every session on the machine, and from the pace what that is per issue; the tokens every session of the project folder (started in it or beneath it, never in a folder whose name only begins like it) used in the last 24 hours, fresh and read from the cache apart, and per issue closed in that time; the context an answer read again in those hours, on average and the largest, which shows how late the sessions compact; those three lines come from Claude Code's records alone, so in the shell of another tool each says `no source for <tool>`; the review verdicts of the last 14 days on the plan issues of the board (every card titled `Plan: packages…`, open or closed, every comment page), counted per builder model and effort as GO, NO and the GO that carried REPAIRED lines, from the `Reviewer: … Builder: …` line under the `REVIEW <area>: GO | NO` line of a verdict (a verdict without it is counted as unattributed; a NO that only asks for a full review, an exact repost and contradicting verdicts are named and not counted; comments in the RE-CHECK, PLAN CHECK or VERDICT: shapes and plan issues that could not be read are unmeasured, with their count, and make the tally incomplete); with `TRACKER=forgejo`, `ai-core status [OWNER/REPO...] --tokens` prints this page over the issues the `status/` labels name, the board named `OWNER/forgejo`, with no tally of reviews; the epics whose sub-issues are all closed; the open issues on the last column. An epic is an issue with sub-issues. `--issues` adds every open issue by epic. Without `--tokens` or `--issues` two blocks follow, both read from git at that moment: TESTING lists every card in testing with where its work is live, the newest commit on the default branch, naming the issue anywhere in its message, that names the issue (a commit names an issue by its number from the issue's creation on) and, per environment of `LIVE_TAGS`, the first release tag by date that contains it, or the commit's landing where the environment is `landed`, a tag's date being an annotated tag's own and a lightweight tag's commit's; a card whose landing clone declares an environment as `command` (`LIVE_RELEASE_COMMAND`) is read instead by the landing record its issue holds (the newest one of a trusted author after the last reopening within the last 50 comments) and the delivery the reader of that clone answers, shown with its `source` and `releasedAt`: status asks the tracker for the landing and the proof of every distinct card in testing, once each, which costs on GitHub the comment pages and one request for the last reopening; a card whose landing, delivery or fetch could not be read is shown as `unknown`, with its full repository and the reason, counts as such in the header, is never read from the commits instead, and makes the command exit 1 after the page; the live counts are per environment by its exact name and by whether it is the first of its list or a later one, `1 live on prod`, `1 live on prod only`; the first environment is the last stage, the one whose release makes a proof due: a card it carries is 🔴 `proof due on <environment> since <age>` with that release until the tracker holds a trusted `Proven on <environment>:` comment after the landing record, as `status-sync` and `issue-proof` count it, then 🟢 `proven on <environment>`; a card no release of it carries yet is ⏸ `waits for the release of <environment>` with its tag pattern; a card live on a later environment only is due for its proof there, marked 🔴 once that environment has carried it longer than `PROOF_HOURS`; where `LIVE_TAGS` is empty every release tag of the card's repository is its release; with `TRACKER=forgejo` the same block ends the page of `ai-core status [OWNER/REPO...]`, from the timelines of the open issues in testing; the clone of each repository with a card in testing, the folder of the project folder whose origin is that repository, is fetched once per call, for at most a minute. TREES lists the issue worktrees `finish-issue --sweep --dry-run` keeps whose last commit or uncommitted change is older than a day, each with the sweep's reason and named by the issue number of its checked-out branch, else of its directory. Needs Node.js |
| `board-order` | stamps an order onto the board, read from standard input as `owner/repo#number` per line |
| `board-unarchive` | brings archived cards back into view |
| `status-sync [--dry-run] [OWNER/REPO ...]` | closes a card that `finish-issue` moved to `testing` once the first commit of its "Landed on" comment is carried by the newest release tag and the issue carries a proof record after that comment, a comment whose first line is `Proven on <environment>:`, written by the coordinator once a UI test session proved the released work; a released card without one is named `proof due` and stays; a card in testing whose landed commit is on origin's default branch and not in the newest release tag is named `not released`, with that tag, and stays; a repository whose origin was listed and has no tag of that pattern is named once, `no release`, with the pattern and the count of its cards in testing, because its cards can never close; a repository whose tags could not be read, or that has no clone, is named by its own line and not so; a card in a column before `testing` whose issue a commit on origin's default branch names, is named `not finished`, with the `finish-issue` command to run, and stays, because that the work is complete is the session's statement; only the comments of the repository's owner, members and collaborators count; The release is the newest tag by date that origin has on the same commit and that matches the first environment of the `LIVE_TAGS` that applies to the clone (its own `.ai-core/config.env`, else the project folder's list), or the newest such tag where neither names an environment, read from the repository's clone in the checkout or the project folder after one fetch; where that first environment is `landed`, the landing on origin's default branch is the release and no tag is read; where it is `command`, the release is the delivery the reader of that clone answers (`LIVE_RELEASE_COMMAND`), the landing must be on the default branch and in the delivered commit, and the proof must follow both the landing record and the delivery, a card the delivery does not carry being named `not released` with its `source`, one a delivery carries without that proof `proof due`, and one whose fetch or reader failed `unknown`, which stays; where origin cannot be listed, or has a tag of that pattern on another commit than the clone or one the clone lacks, no tag counts and the run says so, so a release tag is never moved, and where one was, `git fetch --tags --force` in the clone takes origin's; work that landed in another repository, `Landed on <branch> of <owner/repo>:`, is read in that repository's clone; a repository without a clone is named and its cards stay. With a repository named it reads only that repository's open issues, in one query of about 2 GraphQL points per 50 issues, and `start-issue` and `finish-issue` run it so for their own and for the issue's, where that is another; without one it reads the board once to learn its repositories; with no board named, the board is the checkout's, or, where the checkout is on none, the one the first repository named is linked to. It moves no card on a commit alone, because a commit that names an issue touches it without finishing it; it moves a card forward only, and an epic forward and back, following its sub-issues as under `issue-status`, so a sub-issue moved by hand on the board moves its epic too, except an epic whose card stands in `done`, which it does not read |
| `epics-top`, `item-top`, `item-move` | epics to the top of the board; named cards to the top; a repository's cards from one board to another, keeping status and priority |
| `field-option-add` | adds one option to a single-select field, reading the field first so the others are not deleted; `--after NAME` puts it right after another option, the column order `finish-issue` moves a card by; `--replacing OLD` renames OLD in place, keeping its id, so every card that carried it keeps it |
| `view-filter`, `project-new`, `repo-link`, `repo-boards` | narrows a view to named repositories; creates a board by copying one whose title starts with `[TEMPLATE]`; links a repository to a board and gives it the taxonomy; every repository of the organisation and its board, exit 1 when one is on none or on two |
| `labels-sync` | applies `labels.tsv` to one repository, to named ones, or to every repository on a board; `--all` names an archived repository, which is read-only, and skips it |
| `incident-count` | the issues carrying each `incident:` label per ISO week |
| `team-modes-check`, `team-modes-install` | section 4.6 |
| `schema-check` | holds every GraphQL mutation in `bin/` and `lib/` against the schema github.com publishes; the one check that reaches the network, run by CI; where `TRACKER` is not `github` it says that the schema is GitHub's and exits 0 |

**The hooks.** A repository that wants the gate before every push carries the three-line shim
`ai-core pre-push --install` writes into `.githooks/pre-push`, and beside it `.githooks/post-checkout`,
which starts `init` in a new worktree (section 4.12); the gate and `init` themselves never live in
a repository. Where the shim stands, `init` writes `.githooks/commit-msg` beside it, never committed:
it runs `ai-core pre-push --message`, so a subject over 72 characters, an assistant's attribution,
a closing keyword before an issue reference (`Fixes #12`, which closes the issue on the forge before
any release) or an assistant as author is refused while the commit is made, where the fault costs no
rewrite. A harness source, which `init` never assembles, gets the same hook from
`ai-core pre-push --install` in its checkout and its worktrees, and from `start-issue` in a new worktree.
When the worktree it opens holds no `.githooks/pre-push` file, `start-issue` warns that the ai-core
check before a push is not guaranteed and names the checkout to run `ai-core pre-push --install` in.
This includes a new repository's first worktree and, on Forgejo, a resumed worktree.

**The first commit of a new repository.** An origin with no branch at all has no default branch to cut
a worktree from, and the first branch pushed into an empty repository becomes its default branch on
GitHub and on Forgejo. So `start-issue`, in a clone of such an origin, first starts the default branch:
it makes one commit with the empty tree and no parent, `Start <owner>/<repo> (#<number>)`, so there is
nothing to review, and pushes it as the default branch under the mark of a landing. The branch is named
by the clone's own `HEAD`, which has no commit yet (`git symbolic-ref HEAD`), and the push runs the
clone's hooks by their absolute path, because the temporary worktree it is made from holds no file. In
an empty origin the push gate takes the branch a push creates for the default branch, whatever its
name: it takes exactly the push of the start commit, without the review and the live checks that a
landing of a branch that goes live needs, and refuses a plain push, the same commit without the mark,
and a first push that creates more than one branch. The worktree is then cut from `origin/<default>`
as always, and `integrate-issue` lands the reviewed branch on it like any other; its refresh then
takes the default branch into the clone, whose `HEAD` named it before it had a commit. A clone whose
`HEAD` branch has commits is refused: `start-issue` runs in a fresh clone of the empty repository,
and those commits land later through an issue.

### 8.1 The Forgejo tracker

With `TRACKER=forgejo` the issue commands run in `lib/forgejo/tracker/cli.mts`, TypeScript that Node runs as it is
(no build step, no package at runtime), and `ai-core` hands it `FORGEJO_URL` (a scheme and a host), the command in
`FORGEJO_TOKEN_COMMAND`, which prints the token when the first request needs it, the paths of the label
catalog and of the assignee map, and `CI_GATE` and `LIVE_TAGS` as the other commands read them. It carries no board, because Forgejo's API cannot create or move the cards of a project, and Forgejo has no epics. Every request has 15 seconds to connect and 120 seconds in all, and a
failure says which of these it is: the token refused (401), a permission missing (403), nothing there (404), no
answer, or an answer that breaks the contract of the API (a status other than the documented one, text that is
not JSON, a field the client needs missing). A list is read to its last page or refused; a page whose body is `null`, which is how Forgejo answers a page of an issue's timeline past its end, is an empty page. A comment or a change
whose answer was lost is reported as uncertain and is never sent again by the command itself.

| Treatment | Commands |
| :--- | :--- |
| Run in Node | `issue-new`, `issue-comment`, `issue-close`, `issue-reopen`, `issue-edit`, `issue-label`, `issue-package`, `issue-priority`, `issue-status`, `issue-assign`, `issue-block`, `issue-unblock`, `issue-thread`, `issue-mine`, `issue-list`, `start-issue`, `integrate-issue`, `finish-issue`, `issue-release`, `issue-proof`, `status`, `labels-sync` |
| Refused with exit 2 and one line | `board-list`, `board-order`, `board-sync`, `board-unarchive`, `field-option-add`, `item-move`, `item-top`, `project-new`, `repo-boards`, `repo-link`, `view-filter`, `epics-top`, `subissue-add`, `subissue-remove`, `status-sync`, `issue-transfer`, `issue-duplicate`, `issue-map`, `incident-count` |

| Tracker | How the commands of section 8 run |
| :--- | :--- |
| GitHub | each command is the Bash script `bin/<name>.sh`; the board and the epics are theirs |
| Forgejo | the commands of the first row above run in Node; the commands of the second row are refused; every other command of `ai-core` is the Bash script it is for any tracker, and the entries that used to load the board code (`session-start`, `solution-path`, `team-modes-check`, `team-modes-install`, `init --all`, `doctor`) do not load it with `TRACKER=forgejo` |

The exit codes are 0 for success, 1 for a precondition that refuses (an issue is closed as completed by
`issue-proof`, not by `issue-close`; a literal email address in text for a public repository), 2 for invalid input
or settings, 3 for a failure of Forgejo or of Git, and 4 for an action that partly completed, which names what was
done. `issue-close --reason completed` is refused until `issue-proof` records the proof of a delivery.

**Labels.** The state of an issue is a label of the `status/` family (`backlog`, `ready`, `planned`, `implementing`,
`review`, `testing`, `done`, `not-planned`) and its priority one of `priority/` (`p0`, `p1`, `p2`, `p3`, `p9`). The
families `status/`, `priority/`, `type/`, `goal/`, `test/` and `package/` are exclusive: an issue carries one label of each;
`area/` is not. A `package/` label is made by `issue-package` for each package and is no row of `labels.tsv`: `labels-sync`
leaves it alone, archived or not. Every other label keeps its name (`needs:owner`, `closes:*`, `incident:*`). A label of `labels.tsv`
written `type:bug` there is `type/bug` on Forgejo, and the commands read either spelling. `labels-sync --org ORG`
creates and updates the labels of an organization from `labels.tsv` and from these two families, deletes none, and
writes nothing when the organization already matches. A label change adds with one request and removes with
another and never replaces the whole set, because Forgejo then drops every second label of an exclusive family.

**Dependencies.** `issue-block BLOCKED_REPO N BY_REPO M` writes Forgejo's own relation, the blocked issue first.

**The lifecycle** is written into the issue at the moment each fact happens; a card's state is never rebuilt from
commit messages or release history. Each record is a comment whose first line names it:

| Command | What it does | Record |
| :--- | :--- | :--- |
| `start-issue [OWNER/REPO] N` | cuts `.worktrees/<repository>/issue-N-<slug>` from the fetched default branch of origin, for an issue that is open, assigned to the signed-in account and in `ready`, `planned`, `implementing` or `review`, after the team modes check, which refuses it while a mode is missing; an origin branch of the issue whose tip the default branch contains does not refuse it, as on GitHub, and one that has not landed, under the exact name the worktree takes, is opened as the worktree at its tip; any other branch of the issue refuses it, except for an issue of another repository, where a local branch counts only if its record names that repository or it is named as the issue's branch, and a branch of origin only if it is named so; runs `init` in the new worktree, as on GitHub (a harness source needs none); sets the branch to push to and track `origin/<its own name>` (`branch.<branch>.remote` and `.merge`), never the default branch, as on GitHub; sets `status/implementing` | `Started on <branch>:` with the base commit |
| `integrate-issue [OWNER/REPO] N [N ...] --reviewed-by NAME --reviewed-head SHA [--reviewed-head SHA ...] [--also OWNER/REPO#N ...] [--part]` | in the worktree of the issue: refuses a worktree with changes, a head that is not `--reviewed-head`, an issue that is closed or not assigned to the signed-in account, and an ignored file of that worktree that `origin/<default>` tracks, which the landing would overwrite; merges the reviewed commits into the default branch with a merge commit that names the issue and a `Reviewed-by` line per reviewer, and pushes it through the push gate, in the worktree of the issue where the push gate is the check (detached on `origin/<default>`, so the gate finds the tools installed there, and on its branch again whether the push landed or was refused) and in a temporary worktree where the checks of Forgejo are read, where `scripts/install.sh` of the merged tree runs first when it has one, its lines shown, and a failing install refuses the landing with nothing pushed; there the push gate runs `scripts/check.sh` once for the commit that lands, as `integrate-issue.sh` does: the receipt of `lib/landing-check.sh` reaches the two pushes alone; the lines of git and of the push gate show while the push runs, a default branch that moves while a round runs ends that round, and the command makes the next round by itself on the new tip with the whole gate, at most `INTEGRATE_MAX_ROUNDS` rounds as the Bash command does (the setting is read through the Bash harness, `lib/landing-check.sh rounds`, before every round); a move is proven by the refusal of origin that git names together with a different tip, so a red gate beside a move stays a red gate, one that git reports as failed while origin holds the merge commit is reported as landed, and a worktree with changes is refused with at most twenty of the changes named, and their count where there are more; fast-forwards the default branch of the main checkout where it is only behind, and names a checkout it cannot refresh while the landing stands; sets `status/testing` on every issue it lands. It finds no issue from the history of Git. Run again after `finish-issue` removed the worktree, in the main checkout (`OWNER/REPO N` where the issue lives in another repository), it merges and pushes nothing and writes the missing records for a reviewed head that is on `origin/<default>` in a commit whose subject ends with the name of the issue in parentheses, as this command writes it; any other landed head it refuses, writing nothing, and says that the rerun goes in the worktree of the issue. Given several numbers it lands a package's issues in one push, one `--reviewed-head` per number in the same order: the first issue's branch is the worktree's, every other one the one branch `issue-N-*` of the issue that origin holds (for an issue of another repository, the one named as the issue's branch or recorded for its repository), whose tip must be its reviewed head; each is merged in the same tree with a merge commit of its own, the gate and the checks run once, a conflict of any issue lands none, and each issue gets its own record (`--also` issues get the first issue's). `--part` names a landing with more to follow: the issues keep the status they have, the record says `Landed part on <branch>:` with the same lines, which is the landing of that repository for its release and its delivery and never the landing of the whole issue, no `finish-issue` step is printed, and the worktree stays for the next part; a package that lands one issue in several repositories lands each one but the last with `--part`; the last part runs without `--part` and moves the issues to `status/testing` as every landing does. An issue named twice is refused, and so is one whose branch holds nothing that the issues before it do not, which would get no merge commit of its own. A re-run in which only some of the reviewed heads are on `origin/<default>` is refused, naming each issue, and nothing is merged. The re-run sets `status/testing` only on an issue whose record it writes in that run, and the output says which issues keep their status because their record was there already. | `Landed on <branch>:` (`... of OWNER/REPO:` where the issue lives in another repository) with the reviewed head, the landed commit and the reviewers |
| `finish-issue [OWNER/REPO] N` | removes the worktree of that one issue and its branch, at the head that landed whatever its upstream holds, when the worktree has no changes, its head is on the default branch and the issue carries the `Landed on` record of that head, or of a reviewed head the worktree holds when it took the default branch in after the landing, from an account that may write; a `Landed part on` record of that head counts once a `Landed on` record of the issue follows it, from any repository, and while none follows the worktree stays for the next part and the refusal says so; where the record is missing it removes nothing, exits 1 and names the `integrate-issue` command that writes it; a worktree of the issue that stands detached, as a killed landing leaves it, is named with the `git switch <branch>` to run in it first, and nothing is removed; a worktree that is locked, as `ai-core init` locks the one it equips, is named with its lock and the retry, and nothing is removed; the local branch is deleted in one step, only while it still points at the head that landed, so a commit that arrives meanwhile keeps it; then deletes the issue's branches on origin that a `Started on` record of it names, that no worktree has checked out and whose tip the default branch of origin holds, each at the tip it read, and names each that stays; where no worktree of the issue stands it does only that, and exits 1 when it deletes nothing; writes nothing to the tracker and looks at no other worktree | none |
| `issue-release --repo OWNER/REPO --tag TAG N...` | checks that the tag exists and that every issue carries a `Landed on` or `Landed part on` record of that repository since its last reopening for new work, and otherwise writes nothing and names each issue without one; makes or reuses the milestone named TAG in that repository and sets it on each issue of it; an issue of another repository (`OWNER/REPO#N`) gets a comment instead, because a milestone belongs to one repository; only a release record after that repository's newest landing or part counts on a rerun. It publishes nothing | the milestone, or `Released in OWNER/REPO TAG:` |
| `issue-proof [OWNER/REPO] N --environment ENV --body-file PATH` | refuses at once, before any write, an ENV that no `LIVE_TAGS` of a landed repository names (a repository with no `LIVE_TAGS` names none, and the check needs at least one that does), and lists the names there, each with its repository; refuses unless the issue's newest landing record is `Landed on`, after any `Landed part on` records of the package (an issue that holds no `Landed on` or `Landed part on` record at all, and whose number no commit on the default branch of origin of the clone is the work of (a commit whose subject names it, or whose subject names no issue and whose body names it), was delivered without a code change: it needs none, and the output says that no landing exists; such a commit is work that landed without its record, and is refused until `integrate-issue` writes it, here and in `issue-close --reason completed`) and, for every repository a landing or a part names, a release that came after its newest record, or `LIVE_TAGS` names ENV with the pattern `landed`, or with `command` and the newest completed delivery its reader answers (`LIVE_RELEASE_COMMAND`) holds the newest landed commit and completed after the landing was recorded, or the repository is a harness layer, which init deploys from its default branch; the clone of a repository the landing names is the folder of the project folder with its name, else the one checkout of it in a folder beside the project folder, as the project folder of another organization, where its origin decides and two such checkouts refuse the proof; no delivery, a reader's error, a delivery without the landing or one that is not later than the landing is named as the reason; then writes the proof, sets `status/done` and closes the issue as completed | `Proven on ENV:` with the evidence |

`CI_GATE=public` (the default) makes `integrate-issue` push the merge commit of a public repository to
`ci/integrate-<branch>`, wait for the combined commit status of Forgejo (`AI_CORE_INTEGRATE_POLL` seconds apart,
`AI_CORE_INTEGRATE_WAIT` seconds at most, 20 and 1800 unless set) and land exactly that commit when it is green; a
private repository, and `CI_GATE=none`, land on the push gate alone. A record counts only when its author may write
to the repository and it follows the last reopening of the issue for new work, read from the timeline of the issue;
a reopening whose first `status/` label added by such an account is `status/testing` starts no new work, so the
landings and releases before it still count, and a proof counts only after the last reopening of any kind; the
permission of another account is readable only for an administrator of the repository, so the token of these
commands must belong to one. When the work landed and a record could not be written, `integrate-issue` exits 4 and
names what is done; run again, in the worktree of the issue or, once `finish-issue` removed it, in the main checkout, it sees that the reviewed head is on the default branch, merges and pushes nothing
and writes only the records that are missing. `issue-close --reason completed` closes only an issue that records a
proof after its newest landing and its last reopening.

**`status`** lists the issues the tracker records, every page of them, per owner, for the repositories named or for
the clones beside the current checkout. It reports what the tracker records, not an observed deployment.

### 8.2 List and search the issues of a repository: `issue-list`

`ai-core issue-list [OWNER/REPO | --owner ORG] [--state open|closed|all] [--search TEXT]` lists issues and changes
nothing. It has the same name and prints the same lines with `TRACKER=github` and with `TRACKER=forgejo`, so a session
that must file a finding into what exists reads one output on either. Each issue is one line of five tab-separated
fields: `OWNER/REPO#NUMBER`, `open` or `closed`, the status, the priority and the title, with a dash where the issue
has no status or no priority, in the order of repository and number; the second field tells a closed issue from an
open one where `--state all` lists them together. Nothing printed, with exit status 0, means that no issue matched.

```text
example-org/shop#9     closed    done            P2    Gate waits for a copy of the checkout
example-org/shop#12    open      implementing    P1    Carry the value through every renderer
example-org/shop#14    open      ready           -     Rename the colour palette
```

| Option | What it does |
| :--- | :--- |
| `OWNER/REPO` | the repository to read; without it, the repository of this checkout: the one `gh` names for the directory, or the one the `origin` remote names |
| `--owner ORG` | every repository of that organisation or user; given with `OWNER/REPO` it is refused |
| `--state` | `open` (the default), `closed` or `all` |
| `--search TEXT` | the issues whose title and body, read together, hold every word of `TEXT`, in any order; each word is sent to the tracker's search in quotes, so a word such as `is:closed` is searched as text and never read as one of its operators |

The status and the priority are what the tracker keeps. On GitHub they are the Status and the Priority of the issue's
first board card, spelled as the board spells them. On Forgejo they are the `status/` and `priority/` labels, and
`priority/p1` is printed as `P1`. GitHub's search serves at most 1000 issues, so an answer that names more than it
serves is refused with both counts and never printed as the whole; narrow it with `--state` or `--search`. Forgejo's
search reads the comments of an issue too, and its database indexer searches only the last word (`db.go` and
`bleve.go` of `modules/indexer/issues`, read at v17.0.1), so every page of its answer is read, or the command fails,
and then read again for every word in the title and the body, so that both trackers list the same kind of match.

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
and prove the folder's generated `AGENTS.md` lists exactly its repositories that carry the harness, stand a fake `gh`
on the PATH and prove a project harness is created from the skeleton on the first `init`, cloned
on another machine, and that its rules, skills, docs, data files and `repos/<repo>/` are
assembled, base first along an `extends` chain, prove `push` commits
and pushes a harness clone's change to its origin and has nothing on a second run, require `session-start` to exit 1 where the harness is
absent, and run the board suite (`tests/run-all.sh`: one test per
command against a stand-in `gh`, the push gate's among them, and the tree must be as the
suite found it) and the Forgejo tracker (section 16: the strict type check of `lib/forgejo/tracker` with the
development-only compiler under `tests/typescript`, every test of it against a fake Forgejo on `127.0.0.1`, and the shared
entries run with `TRACKER=forgejo` against a copy of the harness whose board code fails the run when it is loaded; a missing
compiler or a red check makes the section red, it is never skipped). It needs `bash`, `node`, `jq`, gitleaks 8.19+ and, for the
type check, `npm ci --prefix tests/typescript`, and never touches the network. CI sets up the Node line of the tracker, installs the
compiler and runs it on Ubuntu for every push of a branch and every pull request, and then `schema-check`, which needs
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
- **Change the Forgejo tracker** (`lib/forgejo/tracker/`, TypeScript that Node runs as it is): it needs a Node.js that
  runs `.mts` files without a flag (measured on v24.21.0), and, to type-check, the development-only
  compiler under `tests/typescript`, which the runtime never loads: `npm ci --prefix tests/typescript` installs the
  two pinned packages, `typescript` and `@types/node`. `bash tests/check.sh 16-forgejo` runs the strict type check
  and every test of the tree against a fake Forgejo on `127.0.0.1`; a missing compiler turns the section red. The
  paths and definitions of the API that the client uses are in `lib/forgejo/tracker/api/schema.json`, which the
  fake answers from. Extract it again, after adding a path to `used`, from the swagger of a Forgejo instance (the
  address in `FORGEJO_URL`, read without a token):

```bash
curl -fsS "$FORGEJO_URL/swagger.v1.json" | node -e '
const fs = require("fs");
const swagger = JSON.parse(fs.readFileSync(0, "utf8"));
const used = {
  "/user": ["get"],
  "/repos/{owner}/{repo}": ["get"],
  "/repos/{owner}/{repo}/issues": ["post"],
  "/repos/{owner}/{repo}/issues/{index}": ["get", "patch"],
  "/repos/{owner}/{repo}/issues/{index}/comments": ["get", "post"],
  "/repos/{owner}/{repo}/assignees": ["get"],
  "/repos/{owner}/{repo}/issues/{index}/dependencies": ["get", "post", "delete"],
  "/repos/{owner}/{repo}/issues/{index}/labels": ["post"],
  "/repos/{owner}/{repo}/issues/{index}/labels/{identifier}": ["delete"],
  "/repos/{owner}/{repo}/labels": ["get"],
  "/orgs/{org}/labels": ["get", "post"],
  "/orgs/{org}/labels/{id}": ["patch"],
  "/repos/issues/search": ["get"],
  "/repos/{owner}/{repo}/tags/{tag}": ["get"],
  "/repos/{owner}/{repo}/milestones": ["get", "post"],
  "/repos/{owner}/{repo}/issues/{index}/timeline": ["get"],
  "/repos/{owner}/{repo}/collaborators/{collaborator}/permission": ["get"],
  "/repos/{owner}/{repo}/commits/{ref}/status": ["get"],
};
const paths = {}, definitions = {}, responses = {};
const collect = (node) => {
  if (Array.isArray(node)) return node.forEach(collect);
  if (node === null || typeof node !== "object") return;
  for (const [key, value] of Object.entries(node)) {
    if (key !== "$ref") { collect(value); continue; }
    const name = value.split("/").pop();
    if (value.startsWith("#/responses/") && !responses[name]) { responses[name] = swagger.responses[name]; collect(responses[name]); }
    if (value.startsWith("#/definitions/") && !definitions[name]) { definitions[name] = swagger.definitions[name]; collect(definitions[name]); }
  }
};
for (const [path, methods] of Object.entries(used)) {
  paths[path] = {};
  for (const method of methods) {
    if (!swagger.paths[path]?.[method]) throw new Error(`the swagger has no ${method} ${path}`);
    paths[path][method] = swagger.paths[path][method];
  }
}
collect(paths);
const schema = { swagger: swagger.swagger, info: { title: swagger.info.title, version: swagger.info.version }, basePath: swagger.basePath, paths, definitions, responses };
fs.writeFileSync("lib/forgejo/tracker/api/schema.json", JSON.stringify(schema, null, 1) + "\n");
'
```

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
| A fresh clone or worktree has no `.ai-core/` | the harness is not committed. Run `init` in a fresh clone once. For Forgejo, keep the main checkout directly inside a project folder already assembled from the project harness, or set the forge settings in the environment for that run (section 5.7). A checkout with only setup-ai-core in its `STAMP` is repaired by the next `init` in that folder. A worktree gets the harness from the `post-checkout` hook where the repository carries it (`ai-core pre-push --install`), or from `ai-core start-issue`. |

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
│   ├── forgejo/                         the Forgejo provider: forge.sh (curl with the token), and the line that lets git sign in
│   ├── layers.sh                        the project harness: from origin, beside the repositories, cloned, pulled, created, the extends chain
│   ├── live-release.sh                  the reader of a `command` environment of LIVE_TAGS: its start, the checks of its answer
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
