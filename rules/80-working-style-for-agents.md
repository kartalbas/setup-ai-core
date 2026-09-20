## Working style for agents

- **Run the session start before any work**, in every repository, with every tool. [tool]
- **Read spans, not files.** Locate code through the code graph and open only the span to edit.
  [discipline]
- **Work is tracked in the project's tracker, and the plan is the issues.** An issue exists before
  the work starts and is kept current; a plan lives nowhere else. It carries the full case, which is
  the context, the code facts as `file:line` and the acceptance criteria, under a title that names
  the action and its stake so it survives being read alone in a list. Independent pieces are split
  into their own issues before any detail is refined. Everything that carries the work, a branch, a
  worktree or an agent, is named after its issue, and a commit that touches an issue names it.
  Before handing over an issue or a document, check it for placeholders, contradictions, scope and
  ambiguity. [tool · discipline]
- **Never stage blindly.** Read the working-tree status and add the paths you changed. A commit
  subject is one sentence of at most 72 characters that describes the change; the body says why.
  Commit and push as often as the work needs; the owner reviews the finished work, not each commit.
  [review]
- **No assistant or vendor attribution** in a commit message or a pull request. [review]
- **Never write a version, a price or an interface shape from memory.** Look it up at the source
  and state where it came from. [review]
- **Ask before starting any sub-agent**, naming for each what it is for, which question it answers,
  which model and which effort level and why. Once approved, run independent agents in parallel,
  never for work that fits in one or two tool calls, give every call an explicit model and effort,
  and relay the conclusion, never the raw output. A delegated implementation gets a specification
  that names the files to touch, the interfaces, the acceptance criteria and the exact verification
  commands, and reports what changed, what it verified and what in the specification was wrong. A
  specialist is consulted with a briefing, never with a running conversation. When a result misses,
  fix the prompt, the scope or the missing context before changing model or effort. [discipline]
- **A review is independent and read-only.** The reviewer gets the diff and the stated intent, not
  the conversation, and writes findings instead of pushing into the tree under review. Deciding
  whether a finding is real is a separate step from repairing it, and whoever wrote a fix does not
  approve it. Never downgrade a model to save money on security, payments or contract work. [review]
- **Never announce that the context is running out and never stop work because of it.** Report the
  work when it reaches a point, not because a budget did. [review]
