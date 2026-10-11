# Brief: the coordinator's own restart, and the owner's page

A coordinator grows with every round; the tool compacts it, and the owner may restart it. Either
way it reads its state again from this brief, because the state is in the tracker and nowhere else.

## Starting as coordinator

1. Read the skill `person-in-charge`, then `.ai-core/models.tsv` and `.ai-core/config.env`
   (`ECOSYSTEM_ORDER`, `START_CHECK`, `USAGE_STOP_AT`, `LIVE_TAGS`), and your start prompt: your
   partners, with their session names and folders, and the areas or issues the owner hands you.
2. Each board has one plan issue whose title starts with "Plan: packages". Where a board has none,
   create it: `ai-core issue-new --repo <the board's first repository> --title "Plan: packages, or
   no restart finds the state" --body-file <file> --label type:task --label area:<the harness's
   area label> --priority P2 --status backlog --asked-by <the owner's login> --asked-in "start
   prompt of <date>"`, its body one sentence: "The package sections and the phase log of this
   board; read newest first." It is no work to plan.
3. Read the plan issue of each board: every comment that is a package section, the newest of each
   area; the newest `PHASE <area>` line of each area, which holds the phase, the session, the plan
   and review counts and the next step; and every verdict (`PLAN CHECK <area>`, `REVIEW <area>`,
   `LAND <area>`, `CLEARING round`) after that line. Sections of another ecosystem are not yours.
4. Read `ai-core status` per board: which sessions run, which are blocked, what is in TESTING and
   TREES. A session the page does not show is off, whatever a PHASE line says; post a corrected
   line. Your session numbers count on from the highest `l<n>` on the plan issue, so no name of
   yours repeats a predecessor's. For Codex and agy, which the page shows without a name, a session
   runs while its output file `~/.ai-core/sessions/<session name>.out` has no final message; one
   that ended holds it there; a phase whose output file is missing is run again.
5. Where `implementing` holds cards no section names, run `briefs/clearing.md` first.
6. Do one round (the skill). Nothing is started before the round has read everything.

## Before you stop

Post one comment on each plan issue: every area with its PHASE line, and the open questions of the
owner, each with its issues and the label `needs:owner` on them. Then stop; the next coordinator
reads it there.

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
