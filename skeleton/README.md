# The project harness

This repository is the private harness of one project: everything its agents read that is not
code, kept in one place and deployed by `ai-core init` into every checkout of the project's
repositories, where none of it is ever committed. It was created from the skeleton of
[setup-ai-core](https://github.com/kartalbas/setup-ai-core), which carries the generic rules,
the scripts and the templates; this repository carries what is the project's own.

| What | Where | How it reaches a checkout |
| :--- | :--- | :--- |
| the project's rules | `rules/NN-slug.md`, one file per section | merged with the generic sections into `.ai-core/rules/rules.md`; a file with the same name as a generic section replaces it, a new name adds one |
| skills | `skills/<name>/SKILL.md` and its files | copied to `.claude/skills/<name>/` and `.agents/skills/<name>/` |
| documents for agents | `docs/` | copied to `.ai-core/docs/<this harness>/` |
| the map and other files of one repository | `repos/<repo>/`, in the layout of the checkout | copied over the checkout: `repos/<repo>/AGENTS.md` becomes its `AGENTS.md` |
| agent definitions for Claude Code | `agents/<name>.md` | copied to `.claude/agents/<name>.md` |
| the agents served, Graft, the organisation | `config.env` | `.ai-core/config.env` |
| the label taxonomy, who owns which repository's issues, the team modes | `labels.tsv`, `assignees.tsv`, `team-modes.tsv` | `.ai-core/` |
| the harness this one extends, the setup-ai-core version it needs | `ai-core.json` | resolved before assembly, base first |

Change a file here, commit and push: every developer gets it at the next `ai-core init`.
