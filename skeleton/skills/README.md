One folder per skill, `skills/<name>/SKILL.md` with the files it needs. `ai-core init` copies each
folder to `.claude/skills/<name>/` and `.agents/skills/<name>/` of every checkout, where Claude
Code, Codex, Antigravity and OpenHands find it on start. A community skill is vendored here, not
installed per machine.
