# Brief: clear a board of what earlier sessions left

You are the coordinator, and this is your first work on a board whose `implementing` and `testing`
columns hold cards from before the packages: work nobody owns, in worktrees nobody reads. Nothing is
planned until `implementing` is empty, because a package planned over half-done branches lands twice
or never. You write no code: every repair is a phase session with a brief.

## Input

- `ai-core status --project <board>`: the TESTING block (where each card's work is live) and the
  TREES block (the worktrees that hold unlanded work or uncommitted changes).
- `ai-core board-list --project <board>`: every card in `implementing` and `testing`.
- Per card: the issue's last comments (`ai-core issue-thread <n>`), and for its worktree
  `git -C <worktree> status --porcelain` and `git -C <worktree> log origin/<default>..HEAD --oneline`.

## What to do, card by card

    testing
      🟢 live on production         → a UI test session (briefs/ui-test.md) on its promise; on PASS the
                                      `Proven on <environment>:` record; status-sync closes it
      🟡 🔴 live on the test stage  → the release to production (the project's own release step),
                                      then as 🟢
      ⏸ no landing commit           → it never landed: treat it as implementing
    implementing
      landed on the default branch  → ai-core finish-issue <n> → testing
      branch pushed, not merged     → a review session (briefs/review.md) on that branch; GO →
                                      ai-core integrate-issue <n> --reviewed-by <reviewer>, finish-issue
      branch with commits, unfinished → the state as a comment on the issue ("Stand: <what is done,
                                      what is not, the branch>"), the card to ready, the worktree
                                      kept until a package takes the issue up
      worktree without a commit     → the card to ready; finish-issue --sweep removes the worktree
                                      once it has rested a day

Work in rounds of at most 10 cards, the TESTING 🔴 first, then `implementing`, then the rest of
`testing`. Group the cards whose work shares a release: one release carries them all.

## Output, after every round, as a comment on the plan issue

    CLEARING round <k>: <n> cards left in implementing, <m> in testing
    - <repo>#<n>: <what was done: proven | released | landed | reviewed | back to ready> (<session>)
    OPEN: <cards that need the owner, with the question>

When `implementing` is empty, say so in the last round's comment; from then on the plan phase
(`briefs/plan.md`) takes the cards in `ready`, and `testing` is read every round as the skill says.
