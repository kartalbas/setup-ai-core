## Done means a working, proven result

- **The goal is the working end-to-end result**, never a component that looks finished on its own.
  State what that result is before starting and measure done against it. [discipline]
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
  linters, the type check, the tests and the build, run by one entry point. A private repository
  runs all of it on the developer's machine before every push, its full test suites included and
  without building a container image for a test, because its code goes to no outside service; where
  the push gate runs that entry point, the push is that run, and nobody starts it a second time right
  before pushing. A
  public repository is tested by its CI, which an open-source project gets for free; running the
  entry point locally as well is always allowed. [review]
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
  tolerated; a warning that was there before becomes an issue. [review]
- **Report the result, not the intention.** A failed check is shown with its output, a skipped step
  is named with its reason, finished work is stated plainly. [review]
- **A pass from a gate is not a review.** Work that changes behaviour is read afterwards by a
  reviewer told to refute, who names the file, the line and the state in which a defect appears.
  Where the stakes are high, more than one reviewer reads it, on different models, because two
  readers with the same habits share a blind spot. After the reviewer's GO the work lands on the
  default branch as a merge commit that names the issue and carries a `Reviewed-by: <reviewer>`
  trailer, so the reviewed commits land as they were read, and the verdict is written on the
  issue. A refused landing goes to the owner: no other session pushes it, and nothing is reworded
  or forced past the refusal. [review]
- **Nothing is called done until the product owner has reviewed the finished work.** The checks
  decide what may leave the machine; the owner decides what counts as delivered. [review]
- **A machine is never repaired by hand while the repository does not yet carry the repair.** Reading
  state and reproducing a failure on a machine stays allowed; leaving it changed does not, because
  the hand that repairs destroys the state in which the fix could be proven. [discipline]
