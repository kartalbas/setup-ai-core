# Brief: clear a board of what earlier sessions left

You are the coordinator, and this is your first work on a board whose `implementing` and `testing`
columns hold cards from before the packages: work nobody owns, in worktrees nobody reads. Nothing is
planned, and no mechanical package is built, until `implementing` holds only cards with `needs:owner`, because a package planned over half-done branches lands twice
or never. You write no code: every repair is a phase session with a brief. A card from before has no
package section: the issue's acceptance criteria and `file:line` facts stand in for it, its class is
`normal-hard` unless the issue names a secret, a payment, a contract outward or the push gate (outward means an interface somebody outside the project uses (a public API, a published package, a customer's data format), never a contract between the project's own repositories)
(`high-risk`), and the URL and the clicks of its proof come from its criteria. A card whose criteria
name no environment and no visible result cannot be proven by anyone: it gets `needs:owner` with the
question "where is this seen", and stays.

## Input

- `ai-core status --project <board>`: the TESTING block (where each card's work is live) and the
  TREES block (the worktrees that hold unlanded work or uncommitted changes).
- `ai-core board-list --project <board>`: every card in `implementing` and `testing`. On Forgejo, which has
  no board, read them with `ai-core status --label status/implementing` and `ai-core status --label status/testing`.
- Per card: the issue's last comments (`ai-core issue-thread <n>`), and for its worktree
  `git -C <worktree> status --porcelain` and `git -C <worktree> log origin/<default>..HEAD --oneline`.

## What to do, card by card

    testing
      🔴 proof due on production   → a UI test session (briefs/ui-test.md) on its promise; on PASS the
                                      `Proven on <environment>:` record; status-sync closes it
      🟢 proven on production      → its record is written: status-sync closes it
      🟡 🔴 live on the test stage  → a UI test session on the test stage; on PASS the release to
                                      production (the project's own release step), then as 🔴
      ⏸ waits for the release of <environment> → the release of that environment, then as 🔴
      ⏸ waits for a release of <repository> (every tag) → LIVE_TAGS is empty, so every tag counts: you cut
                                      the release the project's map names, once per card, then as 🔴
      ⏸ no commit names it          → it never landed: treat it as implementing
      ⏸ no checkout                 → the repository has no clone in the folder: needs:owner
      ⏸ no landing record           → the issue holds no `Landed on` record of a trusted author after its last
                                      reopening: ai-core finish-issue <n>, then as above
      ❓ unknown                    → a landing, a delivery or a fetch could not be read, and the line says which:
                                      mend what it names and read status again; a card never moves on a guess
    implementing
      landed on the default branch  → ai-core finish-issue <n> → testing, unless a UI test said
                                      FAIL after its `Landed on` record
      landed, a UI test said FAIL   → a build session (briefs/build.md) from the issue's criteria
                                      and the SEEN text as a new one, then review, land, as below
      branch pushed, not merged     → a review session (briefs/review.md) on that branch; GO →
                                      the skill's start check and land, with the LAND line; NO →
                                      a build session with the findings, as in a package; after the
                                      fourth NO, needs:owner
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

A card from before is its own area, named `clearing <repo>#<n>`, so its REVIEW, LAND and PHASE
lines are counted like a package's.

A round takes every card it can move, however many: the TESTING 🔴 first, then `implementing`, then
the rest of `testing`. Group the cards whose work shares a release: one release carries them all.
Group the cards due on the same environment the same way: one UI test session proves as many as
its 100k budget holds, at least two where two are due, because proofs that share a page, a login or a flow take nearly the
same steps, and every session pays its browser and its context once.

## Output, after every round, as a comment on the plan issue

    CLEARING round <k>: <n> cards left in implementing, <m> in testing
    - <repo>#<n>: <what was done: proven | released | landed | reviewed | built> (<session>)
    OPEN: <cards that need the owner, with the question>
    KEEPER: <repo> <file:line> <state of a defect outside the cards of the round>, one line each | none

When `implementing` holds only cards with `needs:owner`, say so in the last round's comment; from then on the plan phase
(`briefs/plan.md`) takes the cards in `ready`, and `testing` is read every round as the skill says.

A defect a round meets outside the card it clears is no issue of the round's: it is a `KEEPER:` line
of the round's comment, for the project's issue keeper, which files it into what exists.
