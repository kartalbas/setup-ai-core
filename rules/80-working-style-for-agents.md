## Working style for agents

- **Run the session start before any work, and after every compaction read every rules file whole
  again before the next step**, in every repository, with every tool, because a summary keeps the
  work and loses the rules; in Claude Code the session start names them after a compaction.
  [tool · discipline]
- **Read spans, not files, and gather them.** Locate code with a search and open only the span to
  edit, because a whole file spends the context the rest of the task needs; fetch every lookup a
  step needs in one answer, as parallel tool calls or one command, because every answer reads the
  whole context again. [discipline]
- **Work is tracked in the project's tracker, through the harness's commands, and the plan is the
  issues.** An issue exists before the work starts and is kept current; a plan lives nowhere else.
  It carries the full case, which is the context, the code facts as `file:line` and the acceptance
  criteria, under a title that names the action and its stake so it survives being read alone in a
  list. Independent pieces are split into their own issues before any detail is refined. An epic,
  an issue with sub-issues, carries no work of its own, which goes into a sub-issue, and is never
  moved by hand: it stands in `implementing` once one sub-issue has started, in `testing` once all
  stand in testing or done, and is done and closed once all are done; a sub-issue closed as not
  planned or as a duplicate does not count, and the issue commands move it with every sub-issue
  they move.
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
- **No assistant or vendor attribution** in a commit, as its author, its committer or a line of its
  message, or in a pull request, and every pushed commit carries as author and committer address the
  one the person pushing it set as their git identity, because the history names who answers for a
  change, and a tool cannot. [machine · review]
- **Never write a version, a price or an interface shape from memory.** Look it up at the source
  and state where it came from. [review]
- **Ask once per package before starting its sub-agents** (an issue alone is a package of one), naming for each what it is for, which
  question it answers, which model, which effort level and which context budget and why, and what
  the same work costs in tokens if the session does it itself; the ask ends with two options, a)
  start them as described, b) the session does it, and waits for the answer. A helper call on the
  cheapest model, for a check whose answer the session checks itself, is no sub-agent and needs no
  ask; so is a phase session a person in charge starts for a package on the rows of the project's
  model table (`.ai-core/models.tsv`), because the owner's start of the coordinator is the yes for
  them. A package is an area: one capability as the user meets it, across every repository it
  touches, with both sides of every contract an issue touches, each named in its plan by
  `file:line`. Its planner cuts it so that one build session finishes it alone, without a question
  back. Every issue of the area goes into it, and the owner's decisions are taken before the build
  starts. Packages that share a file or a contract run one after the other. The later one is built
  on what the earlier one landed. Only packages that share neither run at the same time. A package
  too large for one build's context budget is split into parts that run one after the other in the
  same way. A package has one worktree per repository, one commit per issue
  that names it, every issue's test case on the issue before the build ends, then one push gate run, one review of the whole package diff with its
  findings per issue, one integration and one release per repository with the additive side first,
  one UI test, and its issues close together. Every separate round pays the context, the install,
  the gate, the review and the CI run again, five to ten times over for five to ten issues, and
  slows the machine every session shares; so a finding in the files of a package that is not
  integrated yet joins that package, and a package cut by file splits a contract and releases its
  two sides apart. Every agent's name follows `<phase><n>-<model><version>-<effort>-<budget>k-<5 hex>`,
  `<phase>` the letter of its phase, so a reader sees its role in the name: `p` plan and plan
  check, `i` build, `r` review and re-check, `t` UI test and live check; `<n>` from a block of ten thousand that belongs to the coordinator starting it and stays its
  own across restarts (`10001` and on, `20001` and on), the next block above every number that
  runs or ran on the machine, so two coordinators never hand out the same number;
  the package it works on carries it in its `PHASE` line on the plan issue. Once approved, run independent agents in parallel, never for work that fits
  in one or two tool calls, give every call an explicit model and effort, and relay the
  conclusion, never the raw output. A delegated implementation gets a specification that names
  the files to touch, the interfaces, the acceptance criteria and the exact verification commands,
  and reports what changed, what it verified and what in the specification was wrong. A specialist
  is consulted with a briefing, never with a running conversation. When a result misses, fix the
  prompt, the scope or the missing context before changing model or effort. [discipline]
- **A review is independent, and it repairs what lies in the package, as a person reviewing does.** The
  reviewer gets the diff of the whole package and the stated intent of each of its issues, not the
  conversation; one handed a single issue of a running package asks for the package. Every
  finding it can repair inside the package's own files and contracts it repairs itself, in the
  package's branch or section, names as REPAIRED and lets land, so the card goes on to testing,
  because a NO pays a whole round; the gate's run on the repaired head and the test phase check
  that repair. Only a finding that needs a decision of the owner, or a change beyond the package's
  files and contracts, it writes down instead, and the package does not land. The reviewer's model and effort follow the class of the change, as the
  project's model table (`.ai-core/models.tsv`) names them for the tool the session runs in, and
  never the model that wrote the work. A sweep, a collection of facts, a draft of test cases or a
  pre-review whose answer the session can check cheaply goes to the helper of the same tool, the
  table's helper row; a UI test or a live check is a phase of its own, on the table's model for it.
  A table's `high-risk` rows name a model at least as strong as its `normal-hard` rows, because
  security, payments and contract work are never moved to a cheaper model to save money. The
  repair after a NO is re-checked by one reader against the named findings, reading only the
  repair, because a whole package read again for its repaired lines costs a full review.
  A helper never builds, never gives the deciding review and never decides; its answer is a lead the
  session checks before it uses it. No session moves a task to another model, effort or tool on its
  own because a quota ran out, because a fallback waters the result down from the bottom up: it
  waits. The owner may send a phase to another tool and model for a while; the session names that in
  its report. [review]
- **Never announce that the context is running out and never stop work because of it.** Report the
  work when it reaches a point, not because a budget did. A usage limit of an account is another
  matter, because every session using that account draws on it: at the limit the project sets,
  USAGE_STOP_AT in its config.env (92 % unless set), of any of its windows, the five hours, the week
  or one model's quota, every session using that limited account or model finishes the step in hand,
  commits and reports it, starts nothing new on that account or model and waits for the reset, and
  what is left stays for the coordination and the reviews. `ai-core usage` reads the
  windows. [review · tool]
