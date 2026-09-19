## Done means a working, proven result

- **The goal is the working end-to-end result**, never a component that looks finished on its own.
  State what that result is before starting and measure done against it. [discipline]
- **Never break an existing feature or user experience.** Contracts we own may change on both sides
  at once; a regression may not. [review]
- **No leftovers.** The moment a change takes a piece of code's job away, that code is deleted in the
  same change: nothing commented out, parked behind a flag, or kept in case. Before calling a change
  done, verify that nothing uncalled, unread, unreferenced or tested-for-a-removed-thing remains.
  [review]
- **Build nothing that was not asked for.** No speculative feature, no abstraction for an unstated
  requirement, no handling for a state that cannot occur, no compatibility shim where the code can
  simply change. Validate at system boundaries, which are user input, external services and data
  from outside, and trust internal code. [review]
- **Never lie in code.** No fabricated value, no faked success, no invented default standing in for
  a real one, no swallowed error. An error is caught only to make it visible. [review]
- **Every repository has a fixed set of checks that is green before work is called done**: the
  linters, the type check, the tests and the build, run by one entry point on the developer's
  machine before anything is pushed. A remote run is a second pair of eyes, never the deciding one.
  [review]
- **A green run proves what it covers and nothing more.** A check says how much it covered, and it
  carries a planted defect of each shape it must catch plus a planted innocent case, so it can be
  shown to go red and a clean answer means somebody was looking. [review]
- **A bug fix includes the test that reproduces the bug** and fails before the fix. [review]
- **Warnings are near-errors** and are cleared, not tolerated. [review]
- **Report the result, not the intention.** A failed check is shown with its output, a skipped step
  is named with its reason, finished work is stated plainly. [review]
- **A pass from a gate is not a review.** Work that changes behaviour is read afterwards by a
  reviewer told to refute, who names the file, the line and the state in which a defect appears.
  Where the stakes are high, more than one reviewer reads it, on different models, because two
  readers with the same habits share a blind spot. [review]
- **Nothing is called done until the product owner has reviewed the finished work.** The checks
  decide what may leave the machine; the owner decides what counts as delivered. [review]
- **A machine is never repaired by hand while the repository does not yet carry the repair.** Reading
  state and reproducing a failure on a machine stays allowed; leaving it changed does not, because
  the hand that repairs destroys the state in which the fix could be proven. [discipline]
