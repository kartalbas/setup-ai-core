## Done means a working, proven result

- **The goal is the working end-to-end result**, never a component that looks finished on its own.
  State what that result is before starting and measure done against it. Before work lands, the
  product starts on the bundle that ships together, every repository at the version that will be
  released, by the project's start check (`START_CHECK` in `.ai-core/config.env`), because a part
  that passes alone can fail at the first start beside the others; a project without one lands with
  the check waived, and the land record says so. [discipline · review]
- **Never break an existing feature or user experience.** Contracts we own may change on both sides
  at once; a regression may not. [review]
- **No leftovers.** The moment a change takes a piece of code's job away, that code is deleted in the
  same change: nothing commented out, parked behind a flag, or kept in case. Before calling a change
  done, verify that nothing uncalled, unread, unreferenced or tested-for-a-removed-thing remains.
  [review]
- **Build nothing that was not asked for**, because every line nobody asked for is still read,
  tested and kept alive. No speculative feature, no abstraction for an unstated requirement, no
  handling for a state that cannot occur, no compatibility shim where the code can simply change.
  Validate at system boundaries, which are user input, external services and data
  from outside, and trust internal code. [review]
- **Never lie in code.** No fabricated value, no faked success, no invented default standing in for
  a real one, no swallowed error. An error is caught only to make it visible. [review]
- **Every repository has a fixed set of checks that is green before work is called done**: the
  linters, the type check, the unit tests and the build, run by one entry point. A private
  repository, and a public one whose CI would run on the project's own machines, runs all of it on
  the developer's machine before every push, without building a container image for a test there,
  because its code goes to no outside service; where the push gate runs that entry point, the push
  is that run, and nobody starts it a second time right before pushing. A public repository whose
  CI an outside service runs for free is tested by that CI; running the entry point locally as well
  is always allowed. The integration tests are not in that set: they run in ordered groups by a
  plan, each group on the machine it names, in parallel or one after the other inside it, once or
  twice a day, and their results are read then. [review]
- **A green run proves what it covers and nothing more.** A check says how much it covered, and it
  carries a planted defect of each shape it must catch plus a planted innocent case, so it can be
  shown to go red and a clean answer means somebody was looking. A test turns green through the code
  it tests, never through a special case for its input. An expectation changes only when the
  behaviour it asserts was meant to change or the test was wrong, and the report says which; a test
  that is wrong is reported, never worked around. [review]
- **A bug fix includes the test that reproduces the bug** and fails before the fix. [review]
- **A claim is tested against the latest state, never a stale copy.** Before a defect is reproduced,
  an issue is audited against the code or a fix is called done, the working copy is pulled and the
  live surface the claim is about, the tracker, the deployed environment or the running service, is
  read again at that moment. Nothing is claimed about code that was not read: a file the owner names
  is opened, at least the span the answer rests on, before anything is said about it. [discipline]
- **Warnings are near-errors.** A warning the change raises is cleared in the change, never
  tolerated; a warning that was there before is a defect found in the work. [review]
- **Report the result, not the intention.** A failed check is shown with its output, a skipped step
  is named with its reason, finished work is stated plainly. [review]
- **A pass from a gate is not a review.** Work that changes behaviour is read, before it is
  integrated, by a reviewer told to refute, who names the file, the line and the state in which a
  defect appears; a small change that a person sees and that changes no code path or interface is
  reviewed instead by the owner's choice of its picture. A low-risk change gets no reviewer and no
  second reader, as a change of text gets no issue: a value, a configuration line, a text, a
  comment, a line of a test list, or a few lines that change no code path or interface and touch no
  secret, payment, migration or contract. It lands on the go of whoever decided it, and
  `--reviewed-by` names that go. The reviewer never runs on the model that
  wrote the work, because two readers with the same habits share a blind spot. After the reviewer's
  GO,
  `ai-core integrate-issue <number> --reviewed-by <reviewer>` integrates the work into the default
  branch as a merge commit that names the issue and carries a `Reviewed-by: <reviewer>` trailer,
  so the reviewed commits land as they were read; the verdict is written on the issue. An
  integration refused for a defect of the package's change goes back to review for a repair and
  an independent re-check before another integration attempt. Every other refusal goes to the
  owner: no other session pushes it, and nothing is reworded or forced past the refusal. [tool · review]
- **Nothing is called done until the product owner has reviewed the finished work.** The checks
  decide what may leave the machine; the owner decides what counts as delivered. A card in testing
  is due for its proof once a release carries its work to the environment its acceptance criteria
  name: a UI test session proves it there, on the model the project's table names for that phase,
  together with every other card due on that environment, at least two where two are due, because
  cards whose proofs share a page, a login or a flow pass with nearly the same steps; and the
  coordinator, in its next round, writes the proof on the issue, in a comment whose first line is
  `Proven on <environment>:`; on GitHub `ai-core status-sync` closes the card when that record follows its
  landing and the release of the first environment of `LIVE_TAGS` carries its work; on Forgejo
  `ai-core issue-proof` writes the record and closes the issue under the same conditions. A small
  change that the owner chose by its picture is proven instead by the picture that the session
  that made it takes there, written as that record. A test, on
  any environment, reaches no real person. Every mail or message that a test sends, or makes the
  product send, goes to the project's one test mailbox. Its address is one setting of the tests,
  never a literal in a test case. Each test case adds its own name to the local part of that
  address, so every mail names the test case that sent it. [tool · review]
- **A machine is never repaired by hand while the repository does not yet carry the repair.** Reading
  state and reproducing a failure on a machine stays allowed; leaving it changed does not, because
  the hand that repairs destroys the state in which the fix could be proven. [discipline]
