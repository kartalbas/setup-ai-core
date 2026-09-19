# AGENTS.md — Repository Navigation & Operations

This map guides autonomous AI coding agents (Claude Code, OpenAI Codex, Google Antigravity, OpenCode, OpenHands, Cursor, Windsurf, Aider) operating in this repository.

---

## 1. Binding Rules (The Contract)

- **Core rules:** `.ai-core/rules/rules.md` — managed by setup-ai-core and overwritten on every update. Do not edit it here.
- **Project rules:** `.ai-core/rules/rules.local.md` — this project's own conventions and overrides. Never touched by updates. Where the two conflict, `rules.local.md` wins.
- **Skills behaviour:** `.ai-core/rules/skills.md`
- **Harness version:** `.ai-core/VERSION`

---

## 2. Universal Operations

The `ai-core` command is on the PATH and works the same in Bash and PowerShell; every command takes `--help`.

| Action | Command |
| :--- | :--- |
| **Session start (mandatory first step)** | `ai-core session-start` |
| **Validate a solution path** | `ai-core solution-path <path> --check` |
| **Check rule enforcement tags** | `ai-core rules-check` |
| **Rebuild the code graph** | `ai-core graft` |

The solution-path template is at `.ai-core/solution-path.template.md`.

---

## 3. Domain Knowledge & Context (Extension Point)

- **Code intelligence graph:** `graft/index.md` (if present)
- **Project documentation:** `.ai-core/docs/` — add links to this project's specifications and domain documents here.
