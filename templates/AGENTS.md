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

| Action | Bash | PowerShell |
| :--- | :--- | :--- |
| **Session start (mandatory first step)** | `bash .ai-core/bin/session-start.sh` | `pwsh -File .ai-core/bin/session-start.ps1` |
| **Validate a solution path** | `bash .ai-core/bin/solution-path.sh <path> --check` | `pwsh -File .ai-core/bin/solution-path.ps1 -File <path> -Check` |
| **Check rule enforcement tags** | `bash .ai-core/bin/rules-check.sh` | `pwsh -File .ai-core/bin/rules-check.ps1` |

The solution-path template is at `.ai-core/solution-path.template.md`.

---

## 3. Domain Knowledge & Context (Extension Point)

- **Code intelligence graph:** `graft/INDEX.md` (if present)
- **Project documentation:** `.ai-core/docs/` — add links to this project's specifications and domain documents here.
