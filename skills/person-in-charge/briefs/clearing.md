# Brief: clear a board of what earlier sessions left

You are the coordinator, and this is your first work on a board whose `implementing` and `testing`
columns hold cards from before the packages: work nobody owns, in worktrees nobody reads. Nothing is
planned until `implementing` is empty, because a package planned over half-done branches lands twice
or never. You write no code: every repair is a phase session with a brief. A card from before has no
package section: the issue's acceptance criteria and `file:line` facts stand in for it, its class is
`normal-hard` unless the issue names a secret, a payment, a contract outward or the push gate
(`high-risk`), and the URL and the clicks of its proof come from its criteria. A card whose criteria
name no environment and no visible result cannot be proven by anyone: it gets `needs:owner` with the
question "where is this seen", and stays.

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
      branch with commits, unfinished → a build session (briefs/build.md) in that worktree, with the
                                      issue's criteria and its commits so far, finishes it; then
                                      review, land, as above. Started work is finished before new
                                      work starts
      worktree without a commit     → as unfinished, from the issue's criteria; where the issue has
                                      no criteria, `needs:owner` with the question what done is

An issue in `todo`, `ready` or `backlog` that a card in `implementing` or `testing` needs to be done
(named as its prerequisite, a sub-issue of the same epic, or the other side of the same contract) is
part of the clearing: it is built with that card, through the same review, before anything new
starts, because a card whose prerequisite waits in todo never reaches done.

Work in rounds of at most 10 cards, the TESTING 🔴 first, then `implementing`, then the rest of
`testing`. Group the cards whose work shares a release: one release carries them all.

## Output, after every round, as a comment on the plan issue

    CLEARING round <k>: <n> cards left in implementing, <m> in testing
    - <repo>#<n>: <what was done: proven | released | landed | reviewed | built> (<session>)
    OPEN: <cards that need the owner, with the question>

When `implementing` is empty, say so in the last round's comment; from then on the plan phase
(`briefs/plan.md`) takes the cards in `ready`, and `testing` is read every round as the skill says.
