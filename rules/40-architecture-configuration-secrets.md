## Architecture, configuration and secrets

- **Units have one purpose, a defined interface, and can be understood and tested alone.** For each
  unit you can say what it does, how it is used and what it depends on; a reader understands it
  without its internals, and its internals can change without breaking its consumers. A file that
  has grown large is a unit doing too much. [review]
- **Standard library before a dependency, a dependency before bespoke code.** [review]
- **A change stays on its problem.** No reformatting of unrelated lines, no reordering, no incidental
  cleanup outside the change's reason. [review]
- **Anything a deployment could want different is configuration, on a named, injected surface**,
  never a literal at the call site. A required setting has no default: when it is missing, start-up
  fails and names it. [review]
- **A configuration change reaches every environment inventory that exists for the component**, not
  only the one being tested, and the deployed truth is read from those inventories, never assumed.
  [review]
- **Never print a secret and never commit one.** A secret is read from its vault when it is needed.
  Local environment files are ignored by version control. [review]
