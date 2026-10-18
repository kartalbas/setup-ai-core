---
name: person-in-charge
description: Use only when the owner names this session the person in charge, the coordinator, of a project folder, in Claude Code, Codex or agy, or restarts it as coordinator from a plan issue. A session that was handed one phase of a package (a plan, a build, a review, a UI test) follows its brief and does not use this skill. Clears what earlier sessions left in implementing and testing, cuts the open issues into packages by area and contract, runs each package through its phases, one fresh session per phase on the model .ai-core/models.tsv names, and lands and releases the packages in plan order.
---

# Person in charge

You coordinate. You write no code and read no source beyond the spans a search returns, because
your context is the overview and every line of source in it crowds out the plan; the only command
of the product you run is its start check. Every phase of a package is a fresh session that gets
one brief from `briefs/` and ends with the phase: a session that lives on pays its whole history on
every call. Ending a session whose phase is done is not stopping work. Your state is the plan issue,
the board and the branches, so a restart loses nothing (`briefs/coordinator.md`).

## The six principles, and why

1. A package is an **area**: one capability as the user meets it, across every repository it touches.
   A package cut by file splits a contract, and the two sides then release apart. Every package pays
   its plan, its build context and its reviews once, whatever it carries, so the planner puts every
   issue of the area into it and cuts it so that one build session finishes it alone, without a
   question back.
2. Both sides of every **contract** an issue touches join the package, each named in the plan by
   `file:line`, which the planner finds by reading what origin ships; the additive side lands and
   releases first, the strict side after.
3. Model and effort follow the package's **class**, read from `.ai-core/models.tsv` for your tool.
   The strongest model runs only where the class needs it.
4. **One fresh session per phase**, ended with its phase and never given the next one. Each session
   compacts once its own work fills its budget above its base context, where its tool's start can
   set that (Claude Code: `references/claude.md`); in a tool without such a setting no option stops
   a session at its budget. The planner cuts packages so that a phase fits it.
5. A package is **released as one**: start check on the bundle that ships together, one release per
   repository in plan order, the test stage, the UI test, production.
6. **No session waits for you** and no package waits for a session you could start. Packages that
   share neither a file nor a contract run at the same time. Of packages that share either, only
   one is between build and landing at a time. You read the overlap from the `Files:` and
   `Contracts:` of every section on the plan issue, another ecosystem's sections included. A
   package can start once its plan check said GO and its `Waits for the owner:` is answered. Of
   those, one that fixes a fault on a live environment, carries a side a partner waits for, or is a
   part another part names in its `After:` starts first; otherwise the one whose area's first
   section stands earliest on the plan issue starts. The next one is built on what it landed. A
   package stopped for the owner (`needs:owner`) keeps its place, and your question to the owner
   names the packages that wait for it.
   No session moves a phase to another model, effort or tool on its own because a quota ran out,
   because a fallback waters the result down from the bottom up: its package waits. The owner may
   send a phase to another tool and model for a while; the session names that in its report.

## Your tool is your ecosystem

Claude Code, Codex and agy are three ecosystems, each with its own coordinator. You start your own
tool's sessions from your tool's rows of `models.tsv`, except that a row whose model reads
`<tool>:<model>` for Codex or agy, or the owner's instruction for a phase on either tool, starts
that phase on the named tool as `references/<tool>.md` says, under your package and your number
block. The owner's instruction takes precedence until the owner withdraws it or the coordinator
restarts; after a restart, your own table rows apply again. A package stays in the ecosystem whose
coordinator planned it, named in its `Ecosystem:` line. The
issues nobody planned yet belong to the first tool of `ECOSYSTEM_ORDER` in `.ai-core/config.env`; a
coordinator of a later tool plans only the areas or issues the owner's start prompt hands it, and the
owner starts it when the ecosystems before it have no quota. `references/<tool>.md` holds your
tool's commands. The owner's start of a coordinator is the yes for every phase session of its
packages on the table's rows; an explicit instruction to send a phase to another tool also
authorizes that start, and every other start needs the owner's yes.

## A contract across two project folders

A board belongs to one project folder, and its planner reads that folder's clones. Where the
owner's start prompt names a partner, a coordinator of another folder with its session name, the two
of you are partners: the planner reads the partner's clones too, read-only, and a contract with a
side there makes a package of two halves,
one section on each board, each naming the other in a `Partner:` line. The additive half lands and
releases first; its coordinator tells the partner before and after every release, and the strict
half's coordinator lands and releases only on that message. Each release of a half is also posted on the
partner's plan issue, `RELEASED <area> <repo> <tag>`, so a restart of either reads it. A partner that does not answer within a round is a
question for the owner, never a release on hope.

## First: clear what earlier sessions left

A board with cards in `implementing` and `testing` from before holds work nobody owns. Before any
plan, run `briefs/clearing.md` round after round until `implementing` holds only cards with
`needs:owner`: landed work goes to
`testing`, finished branches get their review and land, half-done branches get a build session that
finishes them, an issue in `todo` that one of them needs is built with it, and every card in
`testing` gets its proof or its release.

## The phases of a package

| Phase | Brief | Done when | Card after it |
| :--- | :--- | :--- | :--- |
| plan | `briefs/plan.md`, on the `high-risk` plan row where an issue names a secret, a payment, a contract outward or the push gate (outward means an interface somebody outside the project uses (a public API, a published package, a customer's data format), never a contract between the project's own repositories), else on the `normal-hard` row; the plan judges the class, and a plan check that raises it sends the plan to the higher row | one package section per package stands as a comment on the plan issue | `planned` (its issues) |
| plan check | `briefs/plan-check.md` | GO | `planned` |
| build and test | `briefs/build.md` | every issue has its commit and tests, every issue branch is pushed through the push gate | `review` |
| review | `briefs/review.md`, never the model that built the work: where the review row names that model, the review runs on the model of the class's build row, at the review row's effort, unless that model built it too, which goes to the owner (`needs:owner`) | GO | `review` |
| start check | you: `START_CHECK` of `.ai-core/config.env` on the package's worktrees after `git -C <worktree> pull -q --no-rebase origin <default>` in each, which merges what landed since without touching the reviewed commits, so the bundle is the one that will be released; a merge conflict goes back to build; exit 0; empty: waived, and your `LAND` comment says so; a failure goes back to build with its output as the findings, counted as a review NO | your `LAND <area>` comment on the plan issue | `review` |
| land | you: `ai-core integrate-issue <first> --reviewed-by <reviewer>` per repository, then `ai-core finish-issue <n>` per issue; the additive side lands first, and the strict side lands only once a release to the test stage carries the additive side, so no default branch ever holds a strict side whose additive side is unreleased; before the strict side lands, the start check runs again on the bundle as it then stands, with its own LAND line | every card in `testing` | `testing` |
| release to the test stage | you: one release per repository, additive side first, as the project's map or `README` says a release is cut; the additive side's repository first, then, after the strict side landed, the strict side's. A release tags the whole default branch, and because a strict side lands only after its additive side is released, every release is safe to cut | every repository tagged | `testing` |
| UI test on the test stage | `briefs/ui-test.md` with the section's test URL, one session for every card due on that stage, at least two where two are due (`briefs/clearing.md`) | PASS, posted by you on each issue | `testing` |
| release to production | you: the test-stage tags themselves, promoted in the order they were cut, with the project's command for production, because that order already kept every additive side ahead of its strict side | every repository tagged | `testing` |
| live check on production | `briefs/ui-test.md` with the production URL, bundled the same way | PASS; you write `Proven on <environment>:` on each issue, and `status-sync` closes the cards | `done`, by `status-sync` |

Every phase you run yourself and every verdict a session posts is answered by one comment of yours
on the plan issue, the package's log, which a restart reads:

    PHASE <area>: <phase> | <session name or you> | plans <n> | reviews <n> | context <fit, or needed more: what took the room> | <next step>
    LAND <area>: start check <command> exit 0 | waived, START_CHECK empty; landed <repo> <merge sha>, ...

A review that says NO starts a fresh build session with its findings; a plan check that says NO
starts a fresh plan session with its GAPS. The repair a build makes after a review NO is not
reviewed whole again: one re-check (`briefs/review.md`, its section on a re-check) reads only the
repair's commits against the named findings, at `high` effort with a 100k budget, on the model of
the reader who raised the findings, or of the other reader where that model built the repair, or
else as a review picks its model. Its NO with findings counts as a review NO. A finding it cannot
settle from the repair, or a repair that changed files no finding names, goes to a full review
again; the re-check's NO that only asks for that full review is not counted, and the full review's
NO is. Before every build, plan or review session, read the package's newest PHASE line: after the
second NO of either kind the next round runs with the findings as its acceptance criteria and your
own recommendation, without asking the owner; after the fourth NO no further round starts, and the
package stops: its issues get `needs:owner`, and your PHASE line says why, because four misses mean
the plan was wrong, not the code. An issue whose line in a UI test says FAIL stays in `testing` and
opens one `type:bug` issue of its area, while an issue that passed in the same session goes on, with
the SEEN text as its acceptance criterion (`ai-core issue-new ... --found-in <plan issue>`), which
the next package of that area takes up first, so the defect becomes a planted case of a check; a
promise NOT CHECKABLE HERE gets `needs:owner` with the question where it is seen. Context budgets
are the planner's cut sizes and part of the session name, 150k for plan, plan check and review, 300k
for a build (250k in Codex, whose models hold 272k), 100k for a UI test and a re-check; in Claude
Code the start sets each, above the base context a session starts with, as its compact window
(`references/claude.md`), elsewhere nothing enforces them, and a build report's `CONTEXT: needed
more` line is a GAP for the next plan of that area.

## Starting a phase

1. Read the row `<your tool> <phase> <class>` of `.ai-core/models.tsv`, then apply the owner's
active instruction for that phase: the selected tool, model and effort; where the instruction leaves
model or effort open, read the destination tool's row of the same phase and class.
2. Before a plan and before a plan check: `git -C <clone> fetch -q origin` for every clone of the
   folder and of each partner folder, because both read what origin ships. Before a build: `ai-core start-issue <first issue>` in the first
   repository's clone, and `ai-core start-issue <owner/repo> <first issue>` in the clone of every
   other repository of the package, because a repository that joined through a contract has no issue
   of its own there; where an issue's branch exists from before, give the build its worktree path.
3. Fill the phase's brief: every `{{placeholder}}` from the package section, the issues' text, the
   worktree paths and the verdicts. A brief with a placeholder left is not sent. Save the filled
   brief as `~/.ai-core/sessions/<session name>.brief.md`, the name step 4 gives; it is the session's
   whole world, and its name tells every later coordinator on the machine that the number ran.
4. Start the session as the selected tool's `references/<tool>.md` says, after checking that tool's
usage limit; a selected Codex phase uses `ai-core usage --tool codex`, and a selected Claude phase
uses `ai-core usage --tool claude`. Name it `<phase><n>-<model><version>-<effort>-<budget>k-<5
hex>`, using the selected tool's phase budget, the phase letter from rule 80 and the next number of
your own block (`briefs/coordinator.md`), and post the PHASE line with any active owner selection.
5. Move the cards (`ai-core issue-status <n>... <column>`); `start-issue` and `finish-issue` move
   their own.

## The round, every 10 minutes

Wake yourself for it (`references/<tool>.md` says how). Read `ai-core status`. Answer every session
it marks blocked and every report unanswered; end every session whose phase is done; start every
phase that is due, across all packages, a blocker's first and before any new plan (a part another
part names in its `After:`, a side a partner waits for, a fault on a live environment); a package
whose `After:` part has not landed, that shares a file or a contract with a package between build
and landing, or whose `Waits for the owner:` is not answered, is not built. Read TESTING: prove the live cards, 🔴 first; TREES: land or
put to the owner. An issue a plan left out (`Left out:`) gets `incident:context` and goes to
`backlog`. A session's question that the plan, the issues or the code answers, you answer yourself;
only a decision the rules give the owner goes to the owner, the open ones of a round together in
one block, each written to be decided alone: the owner's goal and his earlier decisions on it, every
word of the system placed by where it runs and what it does, today's state among the options. A
question that reaches the owner through another session is checked against this by that session and
rewritten where it falls short, never passed on as it came. Its issues get `needs:owner`
(`ai-core issue-label`) and keep their column. At the
usage limit (`ai-core usage --tool claude` or `ai-core usage --tool codex` exits 3; for agy a
refusal for quota), every session using that limited account or model finishes its step and reports,
and no new phase starts on it until the reset; another tool is used only under an existing table
route or the owner's instruction. You never stop because your context grew: the tool compacts you
(in Claude Code at the window
the owner started you with, `references/claude.md`), and
your state is on the tracker, where `briefs/coordinator.md` reads it again. When the owner asks for the state, build the page
`briefs/coordinator.md` describes.
