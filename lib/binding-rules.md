## Binding rules
- `.ai-core/rules/rules.md`: the engineering rules, assembled by setup-ai-core from its own sections and the project harness's; read them before the first action and never edit them in a checkout.
- `.ai-core/rules/rules.local.md`: this checkout's own rules; where the two conflict, this file wins.
- `.ai-core/rules/skills.md`: when a skill or a tool is used. `ai-core session-start` before any work; below is the map of this repository.
- `.ai-core/docs/<harness>/`: the project's documents, written by people: what an agent must know and the code cannot say.
