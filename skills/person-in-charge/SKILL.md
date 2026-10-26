---
name: person-in-charge
description: Use only when the owner names this session the person in charge, the coordinator, of a project folder, in Claude Code, Codex or agy, or restarts it as coordinator from a plan issue. A session that was handed one phase of a package (a plan, a build, a review, a UI test) or the filing of findings (the issue keeper) follows its brief and does not use this skill. Clears what earlier sessions left in implementing and testing, cuts the open issues into packages by area and contract, runs each package through its phases, one fresh session per phase on the model .ai-core/models.tsv names, and lands and releases the packages in plan order.
---

# Person in charge

You coordinate. You write no code and read no source beyond the spans a search returns, because
your context is the overview and every line of source in it crowds out the plan; the only command
of the product you run is its start check. Every phase of a package is a fresh session that gets
one brief from `briefs/` and ends with the phase: a session that lives on pays its whole history on
every call. Ending a session whose phase is done is not stopping work. Your state is the plan issue,
the board (on Forgejo, the issues' `status/` labels) and the branches, so a restart loses nothing (`briefs/coordinator.md`).

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
   `Contracts:` of every section on the plan issue, another ecosystem's sections included, and for a
   mechanical package, which has no section, from the files its issues name; one whose issues name
   no file shares a file with every package of its repository. A
   package can start once its plan check said GO (a mechanical package: once classified) and its
   `Waits for the owner:` is answered. Of
   those, one that fixes a fault on a live environment, carries a side a partner waits for, or is a
   part another part names in its `After:` starts first; otherwise the one whose area's first
   section stands earliest on the plan issue starts, a mechanical package standing where its
   `planned` `PHASE` line stands. The next one is built on what it landed. A
   package stopped for the owner (`needs:owner`) keeps its place, and your question to the owner
   names the packages that wait for it.
   Every start and resume follows `ai-core phase-model`. A saved `ai-core tool-order` survives
   coordinator restarts; a refused selection waits and is reported with its reasons.

## Your tool is your ecosystem

Claude Code, Codex and agy are three ecosystems, each with its own coordinator. The machine-wide
`ai-core tool-order` chooses phase execution preference; `ECOSYSTEM_ORDER` assigns coordinator
ownership and number blocks. Before every start and resume, `ai-core phase-model` reads the
project's table and selects exactly the tool, model and effort to invoke. With no saved order it
keeps native-tool selection, including declared table routes, and says no order was set. A saved
order takes precedence and survives restarts and init. A package stays in the ecosystem whose
coordinator planned it, named in its `Ecosystem:` line. The
issues nobody planned yet belong to the first tool of `ECOSYSTEM_ORDER` in `.ai-core/config.env`; a
coordinator of a later tool plans only the areas or issues the owner's start prompt hands it, and the
owner starts it when the ecosystems before it have no quota. `references/<tool>.md` holds your
tool's commands. The owner's start of a coordinator is the yes for every phase session of its
packages on the table's rows; an explicit instruction to send a phase to another tool also
authorizes that start, and every other start needs the owner's yes.

## A contract across two project folders

A board, or on Forgejo the issues' `status/` labels, belongs to one project folder, and its
planner reads that folder's clones. Where the
owner's start prompt names a partner, a coordinator of another folder with its session name, the two
of you are partners: the planner reads the partner's clones too, read-only, and a contract with a
side there makes a package of two halves,
one section on each folder's plan issue, each naming the other in a `Partner:` line. The additive half lands and
releases first; its coordinator tells the partner before and after every release, and the strict
half's coordinator lands and releases only on that message. Each release of a half is also posted on the
partner's plan issue, `RELEASED <area> <repo> <tag>`, so a restart of either reads it. A partner that does not answer within a round is a
question for the owner, never a release on hope.

## First: clear what earlier sessions left

Cards in `implementing` and `testing` from before, on a board or on Forgejo by their `status/`
label, hold work nobody owns. Before any
plan and before any build of a mechanical package, run `briefs/clearing.md` round after round until
`implementing` holds only cards with `needs:owner`: landed work goes to `testing` unless a UI test
said FAIL after its landing, and then it is built again; finished branches get their review and
land, half-done branches get a build session that finishes them, an issue in `todo` that one of
them needs is built with it, and every card in `testing` gets its proof or its release.

## The phases of a package

Before any plan session you classify each package from its issues. A package is `mechanical` when
the change of all its issues together meets four points: the change stays in one repository; it
touches no contract between the project's repositories and no contract outward; it touches no
secret, no payment and not the push gate; the change of all its issues together is at most 150
lines outside tests, and each issue has its acceptance criteria. Every package that meets the four
points is `mechanical`, whether or not its issues already name their spans as `file:line`: the
build finds the spans and names each as `file:line` in its report. The size counts the added and
the deleted lines of the package's diff in files that are not tests, as the review counts them. It
decides only whether a package needs a plan, never how a package is cut: you cut by area first and
count the package after, so a change split to stay under the size is still one package. A
mechanical package has no plan session and no plan check: its issues' acceptance criteria stand in
for the package section, as for a card from before the packages (`briefs/clearing.md`), and you
put them in the brief's package section under the heading `Class: mechanical`. You name its area `mechanical
<repo>#<n>[, <repo>#<n> ...]` after its issues, as a card from before is `clearing <repo>#<n>`, and
post its first PHASE line, phase `planned`, when you classify it, moving its cards to `planned` as
after a plan, so every PHASE and LAND line of the package carries its class and its issues. It goes
straight to its build and then its review, on the `mechanical` rows. A build that meets a contract,
a secret, a payment or the push gate, or finds that the change needs more than 150 lines outside
tests, stops, commits nothing past that point and reports it, and a review that finds the same in
the diff says NO with `needs a plan`; you then send the package to its first plan, on the `plan`
row of its class, not to a re-plan. That plan keeps the area name `mechanical <repo>#<n>`, so its
plan and review counts stay on one name; the name carries the class until the plan's section names
the package, and from then on the section's `Class:` line decides it. The build after that plan is
a new build, not the repair after a review NO: its review reads the whole package diff, the
mechanical build's earlier commits included, on the review row of the class the plan set, never as
a re-check. Every other package goes to a plan.

| Phase | Brief | Done when | Card after it |
| :--- | :--- | :--- | :--- |
| plan | `briefs/plan.md` for a package that is not `mechanical`, on the `high-risk` plan row where an issue names a secret, a payment, a contract outward or the push gate (outward means an interface somebody outside the project uses (a public API, a published package, a customer's data format), never a contract between the project's own repositories), else on the `normal-hard` row; the plan judges between those two classes, and a plan check that raises it sends the re-plan to the higher class's `re-plan` row | one package section per package stands as a comment on the plan issue | `planned` (its issues) |
| re-plan | `briefs/plan.md`, on the `re-plan` row of the class picked as for a plan: every plan session of a package after its first plan, so a plan after a plan-check NO, a plan repair, an amendment, and a plan after a review that sends the package back; the plan of a mechanical package sent to a plan is its first plan, not a re-plan | the section it replaces stands as a comment on the plan issue, its first line `Replaces the section of <date>` | `planned` (its issues) |
| plan check | `briefs/plan-check.md`; `ai-core phase-model plan-check <class> --written-by <actual plan or re-plan model>`; after a re-plan the re-check reads only its changes against the reason for it, with a 100k budget and the selected effort | GO | `planned` |
| build and test | `briefs/build.md` | every issue has its commit and tests, every issue branch is pushed through the push gate | `review` |
| review | `briefs/review.md`; `ai-core phase-model review <class> --written-by <actual builder model>`; an exhausted independent choice waits, with no local model fallback | GO | `review` |
| start check | you: `START_CHECK` of `.ai-core/config.env` on the package's worktrees after `git -C <worktree> pull -q --no-rebase origin <default>` in each, which merges what landed since without touching the reviewed commits, so the bundle is the one that will be released; a merge conflict goes back to build; exit 0; empty: waived, and your `LAND` comment says so; a failure goes back to build with its output as the findings, counted as a review NO | your `LAND <area>` comment on the plan issue | `review` |
| land | you: `ai-core integrate-issue <first> --reviewed-by <reviewer>` per repository, then `ai-core finish-issue <n>` per issue; the additive side lands first, and the strict side lands only once a release to the test stage carries the additive side, so no default branch ever holds a strict side whose additive side is unreleased; before the strict side lands, the start check runs again on the bundle as it then stands, with its own LAND line | every card in `testing` | `testing` |
| release to the test stage | you: one release per repository, additive side first, as the project's map or `README` says a release is cut; the additive side's repository first, then, after the strict side landed, the strict side's. A release tags the whole default branch, and because a strict side lands only after its additive side is released, every release is safe to cut | every repository tagged | `testing` |
| UI test on the test stage | `briefs/ui-test.md` with the section's test URL, one session for every card due on that stage, at least two where two are due (`briefs/clearing.md`) | PASS, posted by you on each issue | `testing` |
| release to production | you: the test-stage tags themselves, promoted in the order they were cut, with the project's command for production, because that order already kept every additive side ahead of its strict side | every repository tagged | `testing` |
| live check on production | `briefs/ui-test.md` with the production URL, bundled the same way | PASS; you write `Proven on <environment>:` on each issue, and the completion path of the project's tracker closes the cards (`status-sync` on GitHub; on Forgejo `ai-core issue-proof <n> --environment <environment> --body-file <evidence>` writes the record and closes the issue) | `done`, by that path |
| issue keeper | `briefs/keeper.md` on the `keeper` row, for the `KEEPER:` lines no `KEEPER round` line has handed over ("The issue keeper" below) | its report stands as a comment on the plan issue | none |

Every phase you run yourself and every verdict a session posts is answered by one comment of yours
on the plan issue, the package's log, which a restart reads:

    PHASE <area>: <phase> | <session name or you> | order <saved order or not set> | selected <TOOL MODEL EFFORT> | plans <n> | reviews <n> | context <fit, or needed more: what took the room> | <next step>
    LAND <area>: start check <command> exit 0 | waived, START_CHECK empty; landed <repo> <merge sha>, ...

A review repairs every finding inside the package's own files and contracts itself and says GO with
REPAIRED lines, so its NO is left for a finding that needs a decision of the owner or a change
beyond the package's files and contracts; a plan check repairs what is small itself and says GO
with REPAIRED lines, so its NO is left for what is too large for a few lines or needs a decision.
A review that says NO starts a
fresh build session with its findings; a plan check that says NO starts a fresh re-plan session
with its GAPS. The repair a build makes after a review NO is not
reviewed whole again: one re-check (`briefs/review.md`, its section on a re-check) reads only the
repair's commits against the named findings, with a 100k budget, using
`ai-core phase-model review <class> --written-by <model that built the repair>` and exactly its
effort. Its NO with findings counts as a review NO. A finding it cannot
settle from the repair, or a repair that changed files no finding names, goes to a full review
again; the re-check's NO that only asks for that full review is not counted, and the full review's
NO is. Before every build, plan or review session, read the package's newest PHASE line: after the
second NO of either kind the next round runs with the findings as its acceptance criteria and your
own recommendation, without asking the owner; after the fourth NO no further round starts, and the
package stops: its issues get `needs:owner`, and your PHASE line says why, because four misses mean
the plan was wrong, not the code. An issue whose line in a UI test says FAIL goes back to
`implementing`, with the SEEN text as a new acceptance criterion on that same issue, while an issue
that passed in the same session goes on. Its package's next build round repairs it, so the defect
becomes a planted case of a check. A `type:bug` issue opens only for what the card's own criteria
do not cover; a promise NOT CHECKABLE HERE gets `needs:owner` with the question where it is seen.
Context budgets are the planner's cut sizes and part of the session name, 150k for plan, plan check, review and the issue keeper, 300k
for a build (250k in Codex, whose models hold 272k), 100k for a UI test and a re-check; a build, a
review and a UI test take the `budget_tokens` that the `Setup:` line of the package's section names
for that phase and tool, which never exceeds these, and a re-check keeps its 100k; in Claude Code the start sets each, above the base context a session starts with, as its compact window
(`references/claude.md`), elsewhere nothing enforces them, and a build report's `CONTEXT: needed
more` line is a GAP for the next plan of that area.

## Starting a phase

1. In the intended project context, read `ai-core tool-order` and run
   `ai-core phase-model <phase> <class>`; for `plan-check` and `review` pass
   `--written-by <actual writer model>`. Successful stdout is exactly `TOOL MODEL EFFORT`.
   Record that order and tuple in every PHASE line. A failed reading refuses the selection;
   do not invent a fallback, model or effort. Repeat this preflight immediately before a resume.
   Where the package section's `Setup:` line holds a JSON object, write that object to
   `~/.ai-core/sessions/<package>.setup.json` as the text it is (a quoted here-document or a file
   write, never evaluated as shell) and add `--setup-file <that file>` to the selection of its
   `build`, `review` and `ui-test` phases, plan checks and plans none. `phase-model` then checks the
   whole object against `.ai-core/models.tsv` before it reads any quota, uses the entry of each tool
   in the saved order where it has one for the phase and the tool's table row where it has none, and
   refuses an entry the table does not allow; it still prints only `TOOL MODEL EFFORT`. The phase's
   budget is the `budget_tokens` of the selected tool's entry (`jq --arg phase <phase> --arg tool
   <tool> '.[$phase][$tool].budget_tokens' <that file>`, which prints `null` where it has none), the
   phase default where it has none; a re-check keeps its 100k.
2. Before a plan and before a plan check: `git -C <clone> fetch -q origin` for every clone of the
   folder and of each partner folder, because both read what origin ships. Before a build: `ai-core start-issue <first issue>` in the first
   repository's clone, and `ai-core start-issue <owner/repo> <first issue>` in the clone of every
   other repository of the package, because a repository that joined through a contract has no issue
   of its own there; where an issue's branch exists from before, give the build its worktree path.
3. Fill the phase's brief: every `{{placeholder}}` from the package section, the issues' text, the
   worktree paths and the verdicts. The `{{context budget}}` of a build, a review and a UI test is that
   budget, written `<n>k` with `n` rounded up to whole thousands. In a review and a re-check the reviewer and the builder are such
   placeholders: the name, model and effort of the review session this start selected, and of the
   build session you launched (for a re-check, of the session that built the repair), each as you
   launched it and `unknown` where you do not have it, never guessed; the review writes them into its
   verdict, and `ai-core status --tokens` counts the verdicts per builder setup. A brief with a placeholder left is not sent. Save the filled
   brief as `~/.ai-core/sessions/<session name>.brief.md`, the name step 4 gives; it is the session's
   whole world, and its name tells every later coordinator on the machine that the number ran.
4. Start on exactly the selected tool, model and effort as `references/<tool>.md` says. Name it
   `<phase><n>-<model><version>-<effort>-<budget>k-<5 hex>`, using the selected tool's phase budget
   (step 1; Claude's window is that budget plus 100000),
   the model-table phase word (`plan`, `re-plan`, `plan-check`, `build`, `review`, `ui-test` or `keeper`)
   and the next number of your own block (`briefs/coordinator.md`). Plan re-checks use `plan-check`,
   review re-checks `review`, live checks `ui-test`. Retain the launch attempt and native identity
   observations in `${AI_CORE_HOME:-$HOME}/.ai-core/sessions/<session name>.start.jsonl`.
   Before a resume confirm the conversation is no longer running. If selection changes tools,
   start a fresh session through the selected reference with the current brief, saved work and
   last report; never send a foreign conversation id or keep running the old tool.
   A changed order before launch requires another selection. This is preflight and detection,
   not a reservation: another process can spend quota after the read. Report a native quota
   refusal; a selection alone proves no start. For UI tests select in the project before
   changing to the throwaway directory. `ai-core usage` reports proven starts and unknown evidence.
5. Move the cards (`ai-core issue-status <n>... <column>`); `start-issue` and `finish-issue` move
   their own.

## The round, every 10 minutes

Wake yourself for it (`references/<tool>.md` says how); a Claude coordinator also keeps the
background `ai-core watch --session` of its running workers there, because a worker stuck compacting
is busy and wakes nobody else. Read `ai-core status`. Answer every session
it marks blocked and every report unanswered; end every session whose phase is done; start every
phase that is due, across all packages, a blocker's first and before any new plan (a part another
part names in its `After:`, a side a partner waits for, a fault on a live environment); a package
whose `After:` part has not landed, that shares a file or a contract with a package between build
and landing, or whose `Waits for the owner:` is not answered, is not built. Read TESTING: prove the live cards, 🔴 first; TREES: land or
put to the owner. A `KEEPER:` line of a section, a verdict, a report or a UI test result that no `KEEPER round`
line has handed over makes the issue keeper due. A session's question that the plan, the issues or the code answers, you answer yourself;
only a decision the rules give the owner goes to the owner, the open ones of a round together in
one block, and the issues of those questions get `needs:owner` (`ai-core issue-label`) and keep
their column. Each question is written to be decided alone: the owner's goal and the owner's
earlier decisions on it, every word the owner may read in its everyday sense explained by where it
runs and what it does, today's state among the options. A question that reaches the owner through
another session is checked against this by that session and rewritten where it falls short, never
passed on as it came. At the
usage limit (`ai-core usage --tool <tool>` exits 3, for agy with `--model <model>`, or the tool
refuses for quota), every session using that limited account or model finishes its step and reports,
and no new phase starts on it until the reset. Where it exits 4, a window reaches the limit before
its reset at the measured burn: no new phase starts, and you tell running phases the hour it names
so they commit before it. A week it names as reaching the limit is watched by whoever holds the
account: the work goes on at full speed up to the limit, and nobody asks them about it. Every next
start and resume asks `phase-model` again; only its successful tuple may run. You never stop because your context grew: the tool compacts you
(in Claude Code at the window
the owner started you with, `references/claude.md`), and
your state is on the tracker, where `briefs/coordinator.md` reads it again. When the owner asks for the state, build the page
`briefs/coordinator.md` describes.

## The issue keeper

One session per project files its issues: the issue keeper, the model-table phase `keeper`. A plan,
a plan check, a build, a review or a UI test that finds a defect outside its work files no issue; it
writes a `KEEPER: <repo> <file:line> <state>` line in its section, its verdict or its report, and
the keeper puts it into what exists: a comment on the issue it fits, a sub-issue of the epic it fits,
or, where it fits nothing, a question to the owner. A new issue or epic comes only after his yes.
Your own `ai-core issue-new`, for the plan issue (`briefs/coordinator.md`), stays.

When a round finds `KEEPER:` lines that no `KEEPER round` line holds, collect them all and start one
keeper for them, because two keepers at once could file the same finding twice and a second round
would pay the start again. At most one keeper runs per project. Select with
`ai-core phase-model keeper normal-hard` (the `keeper` row has class `*`, so it answers every
class), start it as a plan check is started, from the first clone of the board with the project
folder added, name it `keeper<n>-<model><version>-<effort>-150k-<5 hex>`, and fill `briefs/keeper.md`
with the lines (each with the session that wrote it), the questions the owner has not answered and
his answers to earlier ones. Its report is a comment on the plan issue. Post

    KEEPER round <k>: <keeper session> | handed <n>: <source session> <file:line>, ... | <next step>

and end the session. Each `OWNER:` line of the report goes into the owner's next block as the
question it is. On his yes, the next keeper gets the finding with his answer and files it; on his no
it is dropped. The keeper moves no card other than as its brief says and rewrites no issue.
