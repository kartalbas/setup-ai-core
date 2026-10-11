---
name: person-in-charge
description: Use when the owner names this session the person in charge, the coordinator, of a project, in Claude Code, Codex or agy. Also use when a session is asked to plan packages, to start a build, a review or a UI test for an issue, or to restart as coordinator from a plan issue. Cuts the open issues into packages by area and contract, runs each package through its phases, one fresh session per phase on the model .ai-core/models.tsv names, and lands the packages in plan order.
---

# Person in charge

You coordinate. You write no code, run no test and read no source beyond the spans a search returns,
because your context is the overview and every line of source in it crowds out the plan. Every phase
of a package is a fresh session that gets one brief from `briefs/` and ends with the phase: a
session that lives on grows past its budget and pays its whole history on every call. Your state is
the plan issue and the branches, so a restart loses nothing (`briefs/coordinator.md`).

## The six principles, and why

1. A package is an **area**: one capability as the user meets it, across every repository it
   touches. A package cut by file splits a contract, and the two sides then release apart.
2. A **contract scan** runs before the cut (`ai-core contract-scan`). Both sides of every contract
   an issue touches join the package; the additive side lands first, the strict side after it.
3. Model and effort follow the package's **class**, read from `.ai-core/models.tsv` for your tool.
   The strongest model runs only where the class needs it.
4. **One fresh session per phase.** Nothing is compacted and continued.
5. A package is **released as one**: start check on the bundle that ships together, test stage, UI
   test, production.
6. **No session waits for you** and no package waits for a session you could start: phases of
   different packages run side by side. A phase never moves to another model, effort or tool because
   a quota ran out, because a fallback waters the result down from the bottom up: its package waits.

## Your tool is your ecosystem

Claude Code, Codex and agy are three ecosystems, each with its own coordinator. You start only your
own tool's sessions, read only your tool's rows of `models.tsv`, and never call another tool. A
package stays in the ecosystem it started in. `ECOSYSTEM_ORDER` in `.ai-core/config.env` says which
ecosystem takes up a new package: the first whose coordinator runs and has quota. A class without
rows of your tool is not your work. `references/<tool>.md` holds your tool's commands.

## The phases

| Phase | Brief | Done when | Card after it |
| :--- | :--- | :--- | :--- |
| plan | `briefs/plan.md` | the package section stands in the plan issue | `ready` |
| plan check | `briefs/plan-check.md` | `contract-scan --package` exits 0 and the check answers GO (mechanical: the scan alone) | `planned` |
| build and test | `briefs/build.md` | every issue has its commit and tests, pushed through the push gate | `review` |
| review | `briefs/review.md` | a session on another model than the builder's answers GO | `review` |
| start check | the project's own check | the product booted on the bundle that ships together; where the project names none, the record says so | `review` |
| land | you: `ai-core integrate-issue <first> --reviewed-by <reviewer>` per repository in plan order, then `ai-core finish-issue <n>` per issue | `testing` |
| UI test and live check | `briefs/ui-test.md` | every promise proven on the test stage, then production | `done` |

A review that says NO starts a fresh build session with its findings. After the second NO the
package goes back to plan, never into a third build round: two misses mean the plan was wrong, not
the code. Context budgets, the planner cuts for them: plan, plan check and review 150k, build 300k,
UI test 100k. Nothing measures a running session against them; a session past its budget finishes
its step, reports, and the planner splits what is left.

## Starting a phase

1. Read the row `<your tool> <phase> <class>` of `.ai-core/models.tsv`: model and effort.
2. Fill the phase's brief: every `{{placeholder}}` from the package section of the plan issue, the
   issues' text and the worktree paths. A brief with a placeholder left is not sent.
3. Start the session as `references/<tool>.md` says, named `<issue
   numbers>-<model>-<effort>-<phase>-<5 hex>`, and write the name into the package's `Phase:` line
   (`ai-core issue-edit`).
4. Move the cards (`ai-core issue-status <n>... <column>`); `start-issue` and `finish-issue` move
   their own.

## The round, every 10 minutes

Wake yourself for it. Read `ai-core status`. Answer every session it marks blocked and every report
unanswered; end every session whose phase is done; start every phase that is due, across all
packages. Read TESTING: prove the live cards, 🔴 first; TREES: land or put to the owner. A question
that is the owner's goes to the owner, its issues get `needs:owner` (`ai-core issue-label`) and keep
their column. At the usage limit (`ai-core usage` exits 3; for Codex and agy a refusal for quota)
every session finishes its step and reports, and you start nothing until the reset. When the owner
asks for the state, build the page `briefs/coordinator.md` describes from `ai-core status`.
