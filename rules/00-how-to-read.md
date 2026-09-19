# Engineering rules

These rules bind every AI coding agent and every person working in a repository that carries this
harness. They are generic: they name no product, no organisation, no repository and no tool of one
project. A project harness adds its own rules in its own layer; where two layers conflict, the more
specific layer wins, and the assembled rules file says which layer each section came from.

### How to read a rule

Every rule ends with its enforcement class in brackets. Two classes may share a rule.

| Tag | What holds the rule |
| :--- | :--- |
| `[machine]` | a lint, a test or a git hook refuses the change |
| `[tool]` | a script of this harness carries it out or checks it at the moment of the action |
| `[review]` | the reviewer's checklist asks for it |
| `[discipline]` | nothing but the reader |

A rule states a mechanism and a constraint, so it outlives the artifacts it applies to; an
explanation or an example under a rule may name a file, a command or a value. "Product owner" is a
role, whoever owns the product decisions for the work in front of you.
