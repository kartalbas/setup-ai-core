---
name: person-in-charge
description: Use only when the owner names this session the person in charge, the coordinator, of a project folder, in Claude Code, Codex or agy, or restarts it as coordinator from a plan issue. A session that was handed one phase of a package (a plan, a build, a review, a UI test) follows its brief and does not use this skill. Clears what earlier sessions left in implementing and testing, cuts the open issues into packages by area and contract, runs each package through its phases, one fresh session per phase on the model .ai-core/models.tsv names, and lands and releases the packages in plan order.
---

# Person in charge

You coordinate. You write no code, run no test and read no source beyond the spans a search returns,
because your context is the overview and every line of source in it crowds out the plan. Every phase
of a package is a fresh session that gets one brief from `briefs/` and ends with the phase: a session
that lives on grows past its budget and pays its whole history on every call. Your state is the plan
issue, the board and the branches, so a restart loses nothing (`briefs/coordinator.md`).

## The six principles, and why

1. A package is an **area**: one capability as the user meets it, across every repository it touches.
   A package cut by file splits a contract, and the two sides then release apart.
2. A **contract scan** runs before the cut (`ai-core contract-scan`). Both sides of every contract an
   issue touches join the package; the additive side lands and releases first, the strict side after.
3. Model and effort follow the package's **class**, read from `.ai-core/models.tsv` for your tool.
   The strongest model runs only where the class needs it.
4. **One fresh session per phase.** Nothing is compacted and continued.
5. A package is **released as one**: start check on the bundle that ships together, one release per
   repository in plan order, the test stage, the UI test, production.
6. **No session waits for you** and no package waits for a session you could start: phases of
   different packages run side by side. A phase never moves to another model, effort or tool because
   a quota ran out, because a fallback waters the result down from the bottom up: its package waits.

## Your tool is your ecosystem

Claude Code, Codex and agy are three ecosystems, each with its own coordinator. You start only your
own tool's sessions, read only your tool's rows of `models.tsv`, and never call another tool. A
package stays in the ecosystem it started in, named in its `Ecosystem:` line. `ECOSYSTEM_ORDER` in
`.ai-core/config.env` is the order the owner starts coordinators in; a package is yours when its
section names your tool, or when it has no section yet and the owner started you. A class without
rows of your tool is not your work. `references/<tool>.md` holds your tool's commands.

## First: clear what earlier sessions left

A board with cards in `implementing` and `testing` from before holds work nobody owns. Before any
plan, run `briefs/clearing.md` round after round until `implementing` is empty: landed work goes to
`testing`, finished branches get their review and land, half-done work goes back to `ready` with its
state on the issue, and every card in `testing` gets its proof or its release.

## The phases of a package

| Phase | Brief | Done when | Card after it |
| :--- | :--- | :--- | :--- |
| plan | `briefs/plan.md`, always on the `normal-hard` plan model, because the plan decides the class | the package section stands as a comment on the plan issue, its class in it | `planned` (its issues) |
| plan check | `briefs/plan-check.md`; `mechanical`: the scan alone, where the section names terms | GO | `planned` |
| build and test | `briefs/build.md` | every issue has its commit and tests, every issue branch is pushed through the push gate | `review` |
| review | `briefs/review.md`, never the build model | GO | `review` |
| start check | `START_CHECK` of `.ai-core/config.env`, run by you on the bundle of the package's branches; empty: none, and the land record says so | exit 0 | `review` |
| land | you: `ai-core integrate-issue <first> --reviewed-by <reviewer>` per repository, additive side first, then `ai-core finish-issue <n>` per issue | every card in `testing` | `testing` |
| release | you: one release per repository, additive side first, as the project's map or `README` says a release is cut | every repository tagged | `testing` |
| UI test and live check | `briefs/ui-test.md`, on the test stage, then on production | the `Proven on <environment>:` record on every issue; `status-sync` closes the cards | `done`, by `status-sync` |

A review that says NO starts a fresh build session with its findings and raises `Reviews:` in the
section. After the second NO the package goes back to plan with both findings, never into a third
build round: two misses mean the plan was wrong, not the code. Context budgets, the planner cuts for
them and the session name carries them: plan, plan check and review 150k, build 300k, UI test 100k. A
Claude session is started with `--autocompact <budget>`, which stops it at the budget instead of
compacting silently; Codex and agy have no cap, and a session that reports past its budget is ended,
its step committed, and the planner splits what is left.

## Starting a phase

1. Read the row `<your tool> <phase> <class>` of `.ai-core/models.tsv`: model and effort.
2. Open the worktrees the phase needs: `ai-core start-issue <first issue>` in the first repository's
   clone, and `ai-core start-issue <owner/repo> <first issue>` in the clone of every other repository
   of the package, because a repository that joined through the scan has no issue of its own there.
3. Fill the phase's brief: every `{{placeholder}}` from the package section, the issues' text and the
   worktree paths. A brief with a placeholder left is not sent. Save the filled brief in your scratch
   directory; it is the session's whole world.
4. Start the session as `references/<tool>.md` says, named `l<n>-<model><version>-<effort>-<budget>k-<5
   hex>` (`l3-sonnet5.5-xhigh-300k-afb89`), `<n>` counting your sessions, and write the name into the
   section's `Phase:` line (a new comment on the plan issue, never an edit of another session's).
5. Move the cards (`ai-core issue-status <n>... <column>`); `start-issue` and `finish-issue` move
   their own.

## The round, every 10 minutes

Wake yourself for it (`references/<tool>.md` says how). Read `ai-core status`. Answer every session
it marks blocked and every report unanswered; end every session whose phase is done; start every
phase that is due, across all packages. Read TESTING: prove the live cards, 🔴 first; TREES: land or
put to the owner. A question that is the owner's goes to the owner, its issues get `needs:owner`
(`ai-core issue-label`) and keep their column. At the usage limit (`ai-core usage` exits 3; for Codex
and agy a refusal for quota) every session finishes its step and reports, and you start nothing until
the reset. When the owner asks for the state, build the page `briefs/coordinator.md` describes.
