## Documentation and comments

- **A document that states a fact about code is checked, generated, or gone.** Checked means
  something goes red when it and the code disagree; generated means derived from the code at build
  time; gone means deleted. There is no fourth state. [review]
- **Say why, not what.** The what is the code and a second copy drifts; the why stands nowhere else.
  [review]
- **A comment carries only what a reader of that line today can use**: a mechanism they cannot see,
  a constraint not in the syntax, a consequence elsewhere, an obvious alternative that fails.
  History, tickets, phases and decision records belong in commit messages and the tracker, not in
  the code. [review]
- **Everything on disk is simple US English**: one idea per sentence, no idiom carrying a fact. The
  conversation may run in any language; every name of a thing in the code stays spelled as the code
  spells it, in backticks. [review]
- **A rule carries its own substance.** It never points at another document for its content, because
  a pointer breaks in silence and then asserts something false. [review]
- **A repository that exists to be invoked carries its operating instructions in its readme**, because
  no other tracked file tells whoever opens it how to call it. [review]
