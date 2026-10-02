## Working style for agents

- **Run the session start before any work**, in every repository, with every tool. [tool]
- **Read spans, not files.** Locate code through the code graph and open only the span to edit,
  because a whole file spends the context the rest of the task needs. [discipline]
- **Work is tracked in the project's tracker, through the harness's commands, and the plan is the
  issues.** An issue exists before the work starts and is kept current; a plan lives nowhere else.
  It carries the full case, which is the context, the code facts as `file:line` and the acceptance
  criteria, under a title that names the action and its stake so it survives being read alone in a
  list. Independent pieces are split into their own issues before any detail is refined.
  Everything that carries the work, a branch, a worktree or an agent, is named after its issue, and
  a commit that touches an issue names it; the push that lands an issue is followed by `ai-core
  finish-issue <number>`, which removes its worktree and moves its card on. Before handing over an
  issue or a document, check it for placeholders, contradictions, scope and ambiguity. Issues and
  the board change through the harness's issue and board commands (`ai-core --help`), so they are
  used, proven, and extended or fixed where they fall short; `gh` serves everything they do not
  cover. [tool · discipline]
- **Never stage blindly.** Read the working-tree status and add the paths you changed. A commit
  subject is one sentence of at most 72 characters that describes the change, because the log, the
  tracker and every list view cut a longer subject and the rest is lost where it is read; the body
  says why. Commit and push as often as the work needs; the owner reviews the finished work, not
  each commit. [machine · review]
- **No assistant or vendor attribution** in a commit message or a pull request, because the history
  names who answers for a change, and a tool cannot. [machine · review]
- **Never write a version, a price or an interface shape from memory.** Look it up at the source
  and state where it came from. [review]
- **Ask once per issue before starting its sub-agents**, naming for each what it is for, which
  question it answers, which model and which effort level and why, and what the same work costs in
  tokens if the session does it itself; the ask ends with two options, a) start them as described,
  b) the session does it, and waits for the answer. Issues that touch the same files go to one agent
  together, because it reads the code once and every round of a second agent pays the whole context
  again; issues that share nothing stay apart. Every agent's name opens with the numbers of its
  issues and the model it runs on. Once approved, run independent agents in parallel,
  never for work that fits in one or two tool calls, give every call an explicit model and effort,
  and relay the conclusion, never the raw output. A delegated implementation gets a specification
  that names the files to touch, the interfaces, the acceptance criteria and the exact verification
  commands, and reports what changed, what it verified and what in the specification was wrong. A
  specialist is consulted with a briefing, never with a running conversation. When a result misses,
  fix the prompt, the scope or the missing context before changing model or effort. [discipline]
- **A review is independent and read-only.** The reviewer gets the diff and the stated intent, not
  the conversation, and writes findings instead of pushing into the tree under review. Deciding
  whether a finding is real is a separate step from repairing it, and whoever wrote a fix does not
  approve it. The reviewer's model follows the stakes of the change, not the model of the session: a
  small mechanical change takes the lighter model the harness allows, ordinary work the standard
  one, and security, payments, contracts or the push gate the strongest, read a second time by
  another model. Never downgrade a model to save money on security, payments or contract work.
  [review]
- **Never announce that the context is running out and never stop work because of it.** Report the
  work when it reaches a point, not because a budget did. A usage limit of the account is another
  matter, because every session draws on it: at the limit the project sets, USAGE_STOP_AT in its
  config.env (92 % unless set), of any of its windows, the five hours, the week or one model's quota,
  every session finishes the step in hand, commits and reports it, starts nothing new and waits for
  the reset, and what is left stays for the coordination and the reviews. `ai-core usage` reads the
  windows. [review · tool]
