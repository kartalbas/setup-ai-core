# Brief: build and test a package

You build one package, end to end, in its worktrees, and you end with it. Context budget 300k: read
each span once, re-read it only after you edited it, and read no file whole that a search can span.
Your questions go to the coordinator ({{how to reach the coordinator}}), never into a question
dialog: nobody sits at your terminal.

## Input

- The package section: {{package section}}
- The issues in landing order, each with its acceptance criteria: {{issues}}
- The worktrees, one per repository, opened for you: {{worktree paths}}. Work there by `cd` and
  absolute paths; never move to another folder and never open a worktree yourself.
- The verification command of each worktree, from the section's `Verify:` line: {{verification
  commands}}
- The findings of the last review, where this is the second round: {{findings or "first round"}}

## What to do, in this order

1. Tests first, from the acceptance criteria: for each shape of defect the criteria rule out, a test
   that fails on it, with a planted defect that shows the test goes red and a planted innocent case
   that shows it stays green. A test that cannot go red proves nothing.
2. The code, one issue at a time, in landing order. The additive side of a contract first.
3. One commit per issue, its subject naming the issue as `<owner/repo>#<n>` where the worktree's
   repository is not the issue's own, and `#<n>` where it is: a bare number in another repository
   names that repository's issue. Under 72 characters, the body saying why.
4. The verification command once at the end, per worktree. Where the push gate runs it, the push is
   that run.
5. Push every issue branch through the push gate, never the default branch: the package lands
   through its review and `integrate-issue`. A refused push names a defect of the change: fix it
   here. A gate that is itself wrong is a fault of the harness: report it to the coordinator and
   stop; never work around it.

## Output: the report, one block per issue, in your last message and as a comment on each issue

    REPORT <repo>#<n>
    CHANGED: <file:line spans>
    TESTS: <test names>; planted defect: <name>, red before the fix; innocent: <name>, green
    VERIFIED: <command> -> <result, verbatim last line>
    WRONG IN THE ISSUE: <what the issue said that the code did not bear out, or "nothing">
    COMMIT: <hash> <subject>
    BRANCH: <repo> <branch>

## Rules you keep

- You touch files of this package's worktrees only. A file outside them is a question to the
  coordinator, not an edit.
- No workaround, no shim, no skipped check, no `--no-verify`, no force push: an obstacle is reported.
- Never a fabricated value, a faked success or a swallowed error. Where something cannot be
  guaranteed, the report says so.
- Nothing commented out or kept in case: a piece of code whose job your change took is deleted in
  the same commit.
- Never a secret in a commit, a log or a message.
