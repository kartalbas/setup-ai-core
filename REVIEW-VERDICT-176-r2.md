VERDICT setup-ai-core#176: GO
FINDINGS: 2, each as: <file>:<line> — <state in which it is wrong> — <severity: blocker | should | nit>
- bin/session-start.sh:121-123 — the "could not be written" path has no test, and none can run here (the sandbox runs as root, which ignores the mode bits); reasoned from the code: the braced write fails, the half-written `AGENTS.md.$$` is removed, the line names it, the exclude is left alone, session start goes on — nit
- bin/session-start.sh:126-132 — two session starts at the same moment still append `/AGENTS.md` twice (accepted in round 1 as a nit; unchanged) — nit
TESTS: `bash tests/sections/13-session-none.sh` at 937677f (a worktree of the commit): 15 sections green (rc 0). `bash tests/sections/11-all.sh` at 937677f: green; at e3dadf9, before the merge, also green here, so the red the branch showed on 1.5.60 did not reproduce in this environment and its cause stays unproven. Planted defects on a committed copy of the tree, each red at the intended assertion: tracked guard removed (red at "overwrote the source's committed AGENTS.md"); space escaping removed (red at "the space in a rule file's path is not escaped"); skills line removed (red at the new skills assertion); tracked naming removed (red at "does not say it left the committed AGENTS.md"); an innocent copy stays green. Not run: the full suite, the unwritable-checkout path, any Claude Code or Codex session against the file.

Round 1 findings:
1. Blocker, a tracked AGENTS.md overwritten and the exclude grown at every start — fixed, bin/session-start.sh:98: `git ls-files --error-unmatch AGENTS.md` returns before any write, nothing is excluded, the line at :298 says so; test plants a committed file and checks text, status and exclude.
2. Should, a space in the base path unescaped — fixed, :111 and :113: `${file// /\\ }` on every rule and skills path; test plants `rules/36 spaced.md` and checks the backslash.
3. Nit, "read as they are now" — fixed, :297: the line says what AGENTS.md names, nothing about what the tool read.
4. Nit, the unguarded write under `set -e` — fixed, :121-123: the write is a braced list with a fallback that names it; the unwritable state itself is untested (nit above).
5. Nit, duplicate exclude line from two concurrent starts — accepted, unchanged.
6. Nit, the skills line untested — fixed, tests/sections/13-session-none.sh:43.

The merge 937677f brings master in; `git diff origin/master...937677f` touches only bin/session-start.sh and tests/sections/13-session-none.sh, so nothing of master was resolved away. Commit e3dadf9: subject 63 characters, names #176, author a person, no attribution, no leftovers; the comments carry a reason.
