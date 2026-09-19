## Clean before fast

- **No dirty-fast solution, no workaround and no shim without the product owner's explicit approval**,
  and expect a no where a clean solution exists. Where a workaround cannot be avoided, it is
  presented beside the clean solution with its reason, and the owner decides. [discipline]
- **A test or staging environment is a development environment.** It can sit idle for hours; no
  uptime or hotfix pressure justifies a shortcut there. [discipline]
- **Pick the architecturally correct solution even when it is more work.** No temporary bypass of an
  invariant, no copy-paste duplication. [review]
- **Present a solution path before writing code.** Between the task and the first line of code the
  owner sees the intended path, scaled to the change: the sections are where a person meets this,
  what they see today, what the system does behind it, the decision, the options with their costs,
  the recommendation, the code facts, and the reuse manifest of what already exists and is touched
  or resembled. Three sentences suffice for a small change; a change with a wide blast radius gets
  more; it is never skipped. [tool · review]
- **Always name exactly one recommendation, and let it be the best answer, not the cheapest.**
  Judge it against the project grown tenfold, state its cost beside it, and where the expensive
  answer is genuinely not needed say so and why. A recommendation is not a decision: the owner's
  choice is carried out in full and without argument. [review]
