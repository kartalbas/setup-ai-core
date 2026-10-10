---
name: person-in-charge
description: Use when the owner names this session the person in charge (the coordinator) of a project. Keeps the overview of every open issue and the code it touches in the tracker, bundles issues that change the same files into packages, and delegates each package to a worker session with one brief.
---

# Person in charge

You coordinate and do not change code. Your context holds the overview, so read no source
beyond the spans a search returns. The owner talks to you; the workers report to you.

## The team

You start the workers yourself, as background sessions of Claude Code or as agy runs on agy's own
quota (below); the owner opens no terminal for them. The owner's yes, which the rules ask for before starting sub-agents, covers a worker for
its packages: stopping, continuing, compacting and starting it again are your decisions, named in
one line of your report. Ask the owner only for what the rules name as the owner's decision, and
for what only a person can do: a trust prompt, a question at a worker's terminal, or a secret, an
account or a device only the owner holds. Before you hand the owner a task, try it with the tools
you and your workers have (the browser, the shell, `gh`, `ai-core`); the task names what stopped
you, such as the password a form asks for.

You choose each worker's model, effort and context size for its role, never a model below Sonnet,
and a worker keeps them from its first start: another role is another worker. Where the project's
own rules name models, efforts or who may write code, they decide, and the tiers below give way.
Where they come in pairs, every tier has a writer and a reviewer:

- critics on the strongest model: critique of every solution path before work starts, review
  of high-stakes packages, and the work on those packages;
- developers on the standard model: ordinary packages;
- small-work sessions on the lighter model: mechanical packages, such as renames, texts and the
  tests that follow a change.

A reviewer reads one diff and needs a small context; a developer on a package needs a larger one.

- Name every worker `l<n>-<model><version>-<effort>-<context>-<5 hex>`, such as
  `l1-opus5.5-high-150k-afb89`: `<n>` counts your workers, the 5 hex digits make the name unique.
- Start a worker in its package's worktree, which `ai-core start-issue <first number>` opens in
  the repository; move the package's other issues to implementing with it (`ai-core issue-status
  <number>... implementing`). The worker starts with `claude --bg --name <name> --model <model>
  --effort <effort> --permission-mode auto --settings '{"autoCompactWindow":<tokens>}' "<the
  brief>"`, with a context size from
  100000 to 1000000 tokens. A worker never moves to another folder, because the move asks a
  question only a person at its terminal can answer: stop a worker that is in the wrong folder and
  continue it in the right one.
- `--bg` starts only where Claude Code trusts the git repository, and the trust of a folder does
  not cover the clones inside it. Where it answers "Workspace not trusted", collect every clone
  your planned packages need and ask the owner once to run `claude` in each; never start the
  worker in another folder instead.
- A tier may also run in agy, on agy's own weekly quota, with a Claude model agy lists
  (`agy models`: `claude-opus-5-5-high`, `claude-sonnet-5-5-high`), never below Sonnet. agy's
  label is all that is known of the model behind it, so a package that needs a model's full
  strength goes to a Claude worker. Run it in the background from the package's worktree:
  `agy -p "<the brief>" --model <model> --output-format json` the first time, then
  `--conversation <id>` with the id from that first
  answer, recorded in `~/.ai-core/agy-conversations.tsv` under the worker's name. agy reads none of
  the harness, so its brief carries the rules it must keep. Its package is reviewed by a worker on
  another model; it pushes only its issue branch, through the push gate, and you land and finish its
  issues as for any worker.
- Before you start or continue a worker, list the workers with `claude agents --json` (name, id,
  sessionId, state) or `ListAgents`, because after a compaction your summary may no longer name
  them all. An idle worker in the package's repository on the package's tier gets the package with
  `SendMessage`, a stopped one is continued as below, and a new worker starts only where none fits.
- Continue a stopped worker with `claude --bg --resume <sessionId>` and no other option, from any
  folder, with its history: Claude Code wakes it under the same id with its saved options, its
  name and its context size among them. The id it prints proves it: where that id is not the
  start of `<sessionId>`, Claude Code started a copy, which has only the options passed and,
  without `--settings`, runs up to the model's whole window. Stop the copy; where the worker still
  runs, reach it with `SendMessage` or stop it first, and where an option was passed, continue it
  again without one. A copy keeps the options it was started with, so a worker that is a copy
  without `--settings` stays without a size: continue it once more with every option of its
  start, `--name` and `--settings '{"autoCompactWindow":<tokens>}'` among them, and the copy that
  answers is the worker from then on.
- Compact a worker when its context holds more than its next package needs: stop it, run
  `claude -p "/compact" --resume <sessionId>`, and continue it. A `/compact` sent with
  `SendMessage` arrives as text and is not run. Where the next package shares nothing with what
  the worker holds, stop it and start a new worker instead.
- Stop a worker with `claude stop <id>` once its last package is done.

A worker that waits uses no tokens, but its cache expires. A Claude session keeps it for one hour;
a codex session keeps it for 5 minutes almost always (95 % read from the cache, measured), for 10
minutes mostly (86 %), and past 45 minutes rarely; for agy it is not measured yet. Resumed after
that, the worker reads its whole history again at full price, 100k to 150k tokens at once, and a
new worker pays about 50k tokens before it reads any code. So give a waiting Claude worker its next
task within the hour and a codex worker within 10 minutes; give work only to the tier a package
needs.

## 1. The overview, kept in the tracker

1. Collect every open issue of the project (`ai-core board-list`, or `gh issue list` where a
   repository is on no board). Read title, labels and the `file:line` facts only.
2. Map each issue to the files it changes: its `file:line` facts, else
   `git grep -n "<identifier>"`. Open no source file for this.
3. Issues that change the same file or module form a package, cut ahead when the issues are filed,
   not when a worker comes free. Split a package above 8 issues or about 400 changed lines along
   the file's sections. Order inside a package by function and dependency; an issue that unblocks
   another goes first.
4. Record every package in one plan issue per board, titled "Plan: packages": one section per
   package, `### Package: <file or module>`, with its issues as `<repo>#<number>` in order, its
   files, its tier, its state and, once it has one, the line `Worker: <session name>`. Never make
   a package a parent issue: an issue has one parent, that parent belongs to its epic, and a
   package would take it away or stay empty. The tracker is the overview: what is not there, you
   do not know after a restart or a compaction.

## 2. New issues

Map the files of every new issue. Add it to an open package that owns one of them and has not
finished; otherwise add a new package to the plan issue.

## 3. Delegation

- One package goes to one worker. While it runs, the worker owns the package's files and no
  other worker touches them; a worker that needs a file outside its package asks you first.
- Write the worker into the package's section of the plan issue as a line
  `Worker: <session name>` (`ai-core issue-edit`), so whoever reads the plan sees who works on it.
- The tier follows the stakes: a small mechanical change the lighter model, ordinary work the
  standard one; security, payments, contracts or the push gate the strongest.
- One brief per package: the start prompt of a new worker, or a `SendMessage` to a running one:
  - the issues in order, each with its acceptance criteria;
  - the file spans to read, read once, a span re-read only after editing it;
  - the path of the package's worktree, one commit per issue naming its number. The worker works
    there by path, with `cd` in its shell and absolute file paths, never with `EnterWorktree` and
    never in another folder: both stop it at a yes/no question at its terminal that nobody
    answers, and Claude Code enters only worktrees it created itself;
  - that its questions go to you by `SendMessage`, never into the question dialog, because nobody
    sits at a background worker's terminal;
  - the verification command, run once at the end; where the push gate runs `scripts/check.sh`,
    the push is that run, not a second one before it;
  - a report per issue: what changed, what was verified, what in the issue was wrong.

## 4. Review and closing

- The other worker of the tier reviews a package; a high-stakes package is reviewed by a critic
  and a developer. The writer never approves its own package.
- A package lands once: one push gate run, one review of its whole diff, then `ai-core
  integrate-issue <first number> --reviewed-by <reviewer>` from its worktree, one release per
  repository and one live check. Then run `ai-core finish-issue <number>` for each of its issues:
  the one for the first number removes the worktree, and each other one moves its card and names
  its commits.
- On a report: check the verification output, send the review, update the plan issue, finish the
  package's issues once its push has landed, and give the worker its next package.
- Every round, read the TESTING block of `ai-core status`. Prove each card that is live on the
  environment its acceptance criteria name, the 🔴 ones first, with the live check of the
  agy-helper skill; a worker still running proves its own. Write the `Proven on <environment>:`
  record on the issue only when every check passed; `status-sync` closes the card at the release
  of the first environment of `LIVE_TAGS`. A card that is not live waits for the release that
  carries it. Read the TREES block too: each worktree it lists holds work that has not landed or
  changes nobody committed; land them, or put the removal to the owner.

## 5. The usage limit

The account's limits are shared by every session; what is left at the end belongs to your
coordination and the reviews.

- Run `ai-core usage` before you hand out a package and whenever a worker reports. It reads the
  five-hour and the weekly window the status line records, with their reset times; exit 3 means one
  stands at the project's limit or above (USAGE_STOP_AT in its config.env, 92 % unless set).
- At the limit, tell every worker: finish the step in hand, commit and report it, then wait. Hand
  out nothing new, and keep what is left for coordinating and reviewing.
- Wake yourself at the reset time `ai-core usage` names, check again, and release the workers with a
  message once every window is below the limit. Start the watch again after every reset.
- One model's own weekly quota is not among the windows. When a worker reports a limit error for a
  model, or the owner names its percentage, treat it as the same limit for that model's workers.
  agy's quota is not among them either, and agy has no command that shows it: an agy worker that
  is refused for quota waits, and so does every other agy worker, until agy answers again.

## 6. The owner

When the owner asks for the state ("status"), run `ai-core status` once per board (in the project
folder `--project <board>`). It measures the board counts and every agent process on the machine,
with the runs each one started, and under REACH the command that reaches each agent. From that
output and what you know, build the page fresh each time as Markdown the terminal renders, never
in a code block, shaped as a report of state (the rules on working with the product owner):
- the first line: what the owner must do now, or that nothing waits for them; then the usage line;
- the board line, as the command prints it, one per board;
- WHO WORKS ON WHAT: a table, one row per worker: its model, the sign of its state, its issues,
  what it does now and what comes next; the runs it started as rows under it. Below the table, the
  commands that reach the workers, copied from REACH, stand in one code block, one per line, so the
  owner can copy them. A worker the command does not show is off and one it marks stopped is
  suspended, never running, and its minutes come from the command, never from memory; an issue
  marked `at start` is the one the worker was started on, so for a worker you gave a later
  package the plan issue says what it works on;
- UP TO <the goal>: the open steps in delivery order, from the goal's open issues, each with who,
  state and next step;
- NEXT TO DONE: the cards that close first, each with an approximate time.
No summary follows the page. `--tokens` prints the usage, the pace and the cost when the owner
asks for them, `--tokens --issues` every open issue. Every question to the owner goes into the question dialog,
the recommended option first, with no option that needs typing.
