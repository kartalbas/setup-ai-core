---
name: person-in-charge
description: Use when the owner names this session the person in charge (the coordinator) of a project. Keeps the overview of every open issue and the code it touches in the tracker, bundles issues that change the same files into packages, and delegates each package to a worker session with one brief.
---

# Person in charge

You coordinate and do not change code. Your context holds the overview, so read no source
beyond the spans the code graph returns. The owner talks to you; the workers report to you.

## The team

The workers are other sessions of the project, found with `ListAgents` and named
`<first three letters of the project folder>-<model>-<index>`; the project's team.tsv says which
models, efforts and how many. Where they come in pairs, every tier has a writer and a reviewer:

- critics on the strongest model: critique of every solution path before work starts, review
  of high-stakes packages, and the work on those packages;
- developers on the standard model: ordinary packages;
- small-work sessions on the lighter model: mechanical packages, such as renames, texts and the
  tests that follow a change.

The start prompt that `ai-core team-open` gives you names every worker with its model and effort;
where you were started otherwise, the name carries the model. A worker that waits costs nothing;
give work only to the tier a package needs.

## 1. The overview, kept in the tracker

1. Collect every open issue of the project (`ai-core board-list`, or `gh issue list` where a
   repository is on no board). Read title, labels and the `file:line` facts only.
2. Map each issue to the files it changes: its `file:line` facts, else `graft ask "<title>"` or
   `graft grep "<identifier>"`. Open no source file for this.
3. Issues that change the same file or module form a package. Split a package above 8 issues or
   about 400 changed lines along the file's sections. Order inside a package by function and
   dependency; an issue that unblocks another goes first.
4. Record every package as a parent issue titled "Package: <file or module>", its issues as
   sub-issues (`ai-core subissue-add`), and its files, order and tier in the body. The tracker is
   the overview: what is not there, you do not know after a restart or a compaction.

## 2. New issues

Map the files of every new issue. Add it to an open package that owns one of them and has not
finished; otherwise open a new package.

## 3. Delegation

- One package goes to one worker. While it runs, the worker owns the package's files and no
  other worker touches them; a worker that needs a file outside its package asks you first.
- Write the worker into the package's body as a line `Worker: <session name>` (`ai-core
  issue-edit`). `ai-core status --tokens` plans the package on that worker and measures each
  model's pace from it.
- The tier follows the stakes: a small mechanical change the lighter model, ordinary work the
  standard one; security, payments, contracts or the push gate the strongest.
- One brief per package, sent with `SendMessage`:
  - the issues in order, each with its acceptance criteria;
  - the file spans to read, read once, a span re-read only after editing it;
  - one worktree for the package (`ai-core start-issue <first number>`), one commit per issue
    naming its number;
  - the verification command, run once at the end;
  - a report per issue: what changed, what was verified, what in the issue was wrong.

## 4. Review and closing

- The other worker of the tier reviews a package; a high-stakes package is reviewed by a critic
  and a developer. The writer never approves its own package.
- On a report: check the verification output, send the review, update the package issue, run
  `ai-core finish-issue` for each issue once the push has landed, and give the worker its next
  package.

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

## 6. The owner

When the owner asks for the state ("status"), run `ai-core status` once (in the project folder
`--project <board>`). It measures the board counts and every agent process on the machine, with
the runs each one started. From that output and what you know, build the page fresh each time,
in a code block:
- the board line, unchanged;
- WHO WORKS ON WHAT: one row per worker, its model, its state, its issues, what it does now and
  what comes next; the runs it started indented under it. A worker the command does not show is
  off, never running, and its minutes come from the command, never from memory;
- UP TO <the goal>: the open steps in delivery order, from the goal's open issues, each with who,
  state and next step;
- NEXT TO DONE: the cards that close first, each with an approximate time.
Under the code block write at most one line: what the owner must do now, if anything; no summary
in its place. `--tokens` prints the pace, the cost and the
forecast when the owner asks for them, `--tokens --issues` every open issue. Every question
to the owner goes into the question dialog, the recommended option first, with no option that
needs typing.
