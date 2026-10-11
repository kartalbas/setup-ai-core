# Brief: the coordinator's own restart, and the owner's page

A coordinator grows with every round: each `ai-core status` page and every report stays in its
context. When it holds more than its rounds need, or the owner restarts it, the next coordinator
starts fresh from this brief, because the state is in the tracker and nowhere else.

## Starting as coordinator

1. Read the skill `person-in-charge`, then `.ai-core/models.tsv` and `.ai-core/config.env`
   (`ECOSYSTEM_ORDER`, `USAGE_STOP_AT`, `LIVE_TAGS`).
2. Read the plan issue of each board, "Plan: packages": every section with its `Ecosystem:`,
   `Class:`, `Reviews:` and `Phase:` lines. Sections of another ecosystem are not yours.
3. Read `ai-core status` per board: which sessions run, which are blocked, what is in TESTING and
   TREES. A session the page does not show is off, whatever a `Phase:` line says; correct the line.
4. Do one round (the skill). Nothing is started before the round has read everything.

## Before you stop

Write into every package section the phase it stands in and the session that holds it, and the
`Reviews:` count. Post the open questions of the owner as a comment on the plan issue, each with its
issues and the label `needs:owner` on them. Then stop; the next coordinator reads it there.

## The owner's page, when the owner asks for the state

Run `ai-core status` once per board (in the project folder with `--project <board>`). Build the page
fresh from it and from the plan issue, as Markdown the terminal renders, never in a code block:

- the first line: what the owner must do now, or that nothing waits for them; then the usage line;
- the board line, as the command prints it, one per board;
- WHO WORKS ON WHAT: one row per package: class, phase, session and model, the sign of its state,
  the next step; below it the REACH commands in one code block, one per line, so the owner can copy
  them. A session the command does not show is off; one it marks stopped is suspended; minutes come
  from the command, never from memory;
- UP TO <the goal>: the open packages in landing order, each with phase and next step;
- NEXT TO DONE: the cards that close first, each with an approximate time.

No summary follows the page. Every question to the owner goes into the question dialog where the
tool has one, the recommended option first, with no option that needs typing.
