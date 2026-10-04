## Clean before fast

- **No dirty-fast solution, no workaround and no shim without the product owner's explicit approval**,
  and expect a no where a clean solution exists. Where a workaround cannot be avoided, it is
  presented beside the clean solution with its reason, and the owner decides. An obstacle is never
  cleared by a shortcut that is hard to undo: no skipped check (`--no-verify`), no force push or hard
  reset on a branch others hold, no deletion of files that may be somebody's work in progress,
  because other sessions work in the same checkouts and repositories. [discipline]
- **A test or staging environment is a development environment.** It can sit idle for hours; no
  uptime or hotfix pressure justifies a shortcut there. [discipline]
- **Pick the architecturally correct solution even when it is more work.** Correct is the simplest
  solution that keeps the invariants; more work is accepted for correctness, never for generality
  nobody needs yet. No temporary bypass of an invariant, no copy-paste duplication. [review]
- **Present a solution path before writing code.** Between the task and the first line of code the
  owner sees the intended path, scaled to the change: the sections are where a person meets this,
  what they see today, what the system does behind it, the decision with its options, their costs
  and the recommendation where a decision is the owner's, the code facts, and the reuse manifest of
  what already exists and is touched or resembled. Three sentences suffice for a small change; a
  change with a wide blast radius gets more; it is never skipped. A path that holds no decision of
  the owner's is followed at once; one that holds a decision waits for it. [tool · review]
- **Always name exactly one recommendation, and let it be the correct answer, not the cheapest.**
  Judge it against the project as it is and as its issues plan it, not a size nobody asked for;
  state its cost beside it, as the agents' effort it is: the issues it takes times the time an
  issue takes at the measured pace (`ai-core status --tokens`), and the tokens, never a person's hours, days
  or weeks; where the expensive answer is genuinely not needed say so and why. A recommendation is
  not a decision: the owner's choice is carried out in full and without argument. [review]
