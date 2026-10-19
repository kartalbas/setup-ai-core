## Documentation and comments

- **A document that states a fact about code is checked, generated, or gone.** Checked means
  something goes red when it and the code disagree; generated means derived from the code at build
  time; gone means deleted. There is no fourth state. [review]
- **The code tells what it does, not a comment.** Names, small units and plain structure carry the
  meaning. A comment stands only where the code cannot be made readable, and then in one short
  sentence: a mechanism the reader cannot see, a constraint not in the syntax, an obvious
  alternative that fails. Every other comment is deleted, because nothing checks it and the next
  change makes it wrong. History, tickets and decisions belong in commits and the tracker. [machine · review]
- **Everything on disk is simple US English**: one idea per sentence, no idiom carrying a fact. The
  conversation may run in any language; every name of a thing in the code stays spelled as the code
  spells it, in backticks. [review]
- **A rule carries its own substance.** It never points at another document for its content, because
  a pointer breaks in silence and then asserts something false. [review]
- **A repository that exists to be invoked carries its operating instructions in its readme**, because
  no other tracked file tells whoever opens it how to call it. [review]
