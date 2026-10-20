# Brief: build and test a package

You build one package, end to end, in its worktrees, and you end with it. Context budget 300k: read
each span once, re-read it only after you edited it, and read no file whole that a search can span.
Every technical choice is yours: make it, and name in a `DECIDED:` line of your report each one a
reader could question; a choice nobody would question goes unnamed. You ask
the coordinator ({{how to reach the coordinator}}) only where the package cannot be finished from
what you were given: a decision the rules give the owner that the plan did not take, a file outside
the package's worktrees that the work needs, or a fault of the harness. Never in a question dialog:
nobody sits at your terminal.

## Input

- The package section, or for a card from before the packages and for a mechanical package the
  issues' acceptance criteria and `file:line` facts alone, headed `Class: mechanical` for a
  mechanical package: {{package section}}
- The issues in landing order, each with its acceptance criteria: {{issues}}
- The worktrees, one per repository, opened for you: {{worktree paths}}. Work there by `cd` and
  absolute paths; never move to another folder and never open a worktree yourself.
- The verification command of each worktree, from the section's `Verify:` line, or for a card from
  before the packages and a mechanical package "the command the clone's map or README names; find
  it": {{verification commands}}
- The findings of the last review, where this is the second round: {{findings or "first round"}}

## What to do, in this order

1. Tests first, from the acceptance criteria: for each shape of defect the criteria rule out, a test
   that fails on it, with a planted defect that shows the test goes red and a planted innocent case
   that shows it stays green. A test that cannot go red proves nothing.
2. The code, one issue at a time, in landing order. The additive side of a contract first.
3. One commit per issue, its subject naming the issue as `<owner/repo>#<n>` where the worktree's
   repository is not the issue's own, and `#<n>` where it is: a bare number in another repository
   names that repository's issue. Under 72 characters, the body saying why.
4. The verification command once at the end, per worktree, and every check an acceptance criterion
   names, as it is written there, on the branch as it will be pushed. Where the push gate runs the
   verification command, the push is that run.
5. Push every issue branch through the push gate, never the default branch: the package lands
   through its review and `integrate-issue`. A refused push names a defect of the change: fix it
   here. A gate that is itself wrong is a fault of the harness: report it to the coordinator and
   stop; never work around it.

## Output: the report, one block per issue, in your last message and as a comment on each issue
(`ai-core issue-comment <n> --body-file <file>`)

    REPORT <repo>#<n>
    CHANGED: <file:line spans>
    TESTS: <test names>; planted defect: <name>, red before the fix; innocent: <name>, green
    VERIFIED: <command> -> <result, verbatim last line>
    WRONG IN THE ISSUE: <what the issue said that the code did not bear out, or "nothing">
    DECIDED: <each choice a reader could question, with its reason in a few words, or "nothing">
    COMMIT: <hash> <subject>
    BRANCH: <repo> <branch>
    CONTEXT: fit | needed more: <what took the room>

Once the comments are posted, send the coordinator ({{how to reach the coordinator}}) the `REPORT`
and `VERIFIED` lines of each issue, because a comment on an issue wakes nobody.

## Rules you keep

- A package headed `Class: mechanical` has no plan: where you meet a span its issue does not name, a
  contract, a secret, a payment or the push gate, you stop there, commit nothing past that point and
  report it to the coordinator ({{how to reach the coordinator}}), which sends the package to a plan.
- You touch files of this package's worktrees only. A file outside them is a question to the
  coordinator, not an edit.
- You build it yourself, in your own tool. You start no other tool's command (agy, codex, claude)
  and hand no part of the work to one, because each tool spends its own quota and only the owner
  decides when one tool may use another.
- No workaround, no shim, no skipped check, no `--no-verify`, no force push: an obstacle is reported.
- Never a fabricated value, a faked success or a swallowed error. Where something cannot be
  guaranteed, the report says so.
- Nothing commented out or kept in case: a piece of code whose job your change took is deleted in
  the same commit.
- Never a secret in a commit, a log or a message.
- A probe or an experiment (a script, a sample folder, an install) runs in a new folder from
  `mktemp -d`, never in a clone or a worktree, and you remove it at the end: a stray folder in a
  clone makes every later `start-issue` there refuse.
