# Skills & Tooling Behavioral Guidelines

This document specifies when and how an agent should trigger and apply specific skills and tools in this harness.

The three modes of section 1 and 2, `i-have-adhd`, `caveman` and `ponytail`, are the team modes: `.ai-core/team-modes.tsv` says, per tool, how the harness sees that a mode is installed and how it is installed. `ai-core session-start` refuses a session while one is missing; `ai-core team-modes-install` installs them. Restart the tool afterwards: a plugin loads when the tool starts.

---

## 1. Output & Persona Skills

### `i-have-adhd` (Default Persona)
- **Trigger:** Active by default on every interaction.
- **Behavior:**
  - Never open with greetings, affirmations ("Certainly!", "I'd be happy to help"), or conclusion filler ("Hope this helps!").
  - Lead directly with the actionable result, bulleted plan, or diff.
  - Present multi-step procedures as concise numbered lists.
  - Remove all polite padding.

### `caveman` (Token Compressor)
- **Trigger:** When the prompt contains `/caveman`, "less tokens", "be brief", or during high-volume batch runs.
- **Behavior:**
  - Cuts grammatical fluff (articles, redundant verbs) while keeping 100% technical accuracy.
  - Retains code blocks, exact identifiers, file paths, and compiler error messages verbatim.
  - Shortens only what the agent writes in chat. Anything that lands in the record, an issue, a solution path, a commit message or a document, is written in full; and it never compresses what the agent reads: rules, skills, glossary and maps are read whole.

---

## 2. Architecture & Quality Skills

### `ponytail` (YAGNI & Minimal Complexity)
- **Trigger:** On every design decision, refactoring task, or library choice.
- **Behavior:**
  - Ask whether the task needs custom code at all.
  - Prefer standard library over external dependencies.
  - One line of idiomatic code before fifty lines of bespoke abstraction.
  - Reject premature optimization and speculative future-proofing.

### `archify` (Visual Architecture)
- **Trigger:** Whenever documenting system structure, writing major RFCs/PRDs, or preparing PR summaries for complex features.
- **Behavior:**
  - Produce interactive HTML/SVG architecture diagrams.
  - Map data flows, service boundaries, and state transitions visually.
  - Store diagrams under `docs/architecture/`.

---

## 3. Code Intelligence & Navigation

### `graft` (Code Graph & Span Targeting)
- **Trigger:** Whenever searching for definitions, callers, or understanding symbol dependencies.
- **Behavior:**
  - Query `graft ask "<query>"` or call MCP tools (`graft_find_code`, `graft_trace_calls`) instead of reading whole source files.
  - Open and edit ONLY the exact `file:line` span identified by the graph.
  - Keep the graph updated with `graft build` after major refactorings.
