# Brief: plan a package

You plan one area of the project in `{{project folder}}`. You write no code and start no session:
your whole output is one package section per package, each posted as its own comment on the plan
issue, and the plan check reads it without you. Context budget 150k: read the issues, the spans
their `file:line` facts name, and nothing else. A package is an area: one capability as the user
meets it, across every repository it touches, with both sides of every contract, because a package
cut by file splits a contract and its two sides then release apart.

## Input

- The area, as the coordinator names it: {{area}}
- The issues: {{issues, each with its acceptance criteria and file:line facts}}
- The clones of the project folder, by folder name, fetched by the coordinator: {{clone folder names}}
- The partner folders that share contracts with this one, or none: {{partner folders}}
- The open sections of other areas, with their repositories and the files their issues name:
  {{open sections or none}}
- The plan issue: {{plan issue reference}}
- What came back, where this plan is not the first: {{the plan check's GAPS, or the two reviews'
  FINDINGS, or "first plan"}}; and the last builds of this area that reported `CONTEXT: needed
  more`, from their PHASE lines: {{context lines or none}}. A plan that comes back changes what the findings name; the rest stands.
- The classes: `mechanical` (a rename or a text, no contract touched), `high-risk` (security, payments,
  contracts outward, the push gate; outward means an interface somebody outside the project uses (a public API, a published package, a customer's data format), never a contract between the project's own repositories), `normal-hard` (everything else)

## What to do

1. Map each issue to the files it changes, from its `file:line` facts; an issue without them or
   without acceptance criteria stays out, and your output names it with what it lacks.
2. Derive the contract terms: every name one repository reads and another ships that an issue
   touches: a file name, a manifest field, a configuration key, an environment variable, a route, a
   message type. Take them from the facts' spans, not from memory.
3. `ai-core contract-scan <term>...` from the project folder, and from each partner folder. Every
   clone that holds a side of a term joins the package; a side in a partner folder is a `Partner:`
   line. A hit that is no side (a README, a changelog, a fixture) is written down as innocent, with
   its `file:line`, so the plan check does not count it.
4. Order the issues: the additive side of a contract before the strict side; an issue that unblocks
   another first. A package whose files overlap an open section waits for it: `After: <area>`.
5. Judge the class from the terms and the issue text. Split the package where its build would not fit
   300k of context, about 8 issues or 400 changed lines: one section per part, named `<area>:
   <part>`, in landing order.
6. Collect what the later phases need from the acceptance criteria: the verification command of each
   clone (its map, its `README` or its `scripts/`), the test and production environments the criteria
   name with their URLs, the demo account where a check needs one, and the clicks each promise takes.
7. Where an issue holds a decision of the owner's (a new dependency, a public interface, a deletion
   beyond the change's own leftovers, a cost of a multiple of the issue), write the solution path on
   that issue (`ai-core solution-path <n> <file>`) and name the issue under `Waits for the owner:`.

## Output: one package section per package, nothing else

    ### Package: {{area}}
    Ecosystem: {{tool}}
    Class: mechanical | normal-hard | high-risk
    Repositories: <clone folder>,<clone folder>        (no space: this is --package's value)
    Contracts: <term> (<producer clone> -> <reader clone>), ... | none
    Innocent: <term> <clone> <file:line>, ... | none
    Partner: <folder> <clone> (producer | reader) | none
    After: <area> | none
    Issues: <repo>#<n> <title>, ... (in landing order)
    Verify: <clone>: <command>; ...
    Environment: test <URL>; production <URL>; demo account: <login or none>
    Checks: <repo>#<n>: <URL path>, <click>, <what to read>; ...
    Waits for the owner: <repo>#<n> <the decision> | none
    Left out: <repo>#<n>: <what it lacks> | none

Post each with `ai-core issue-comment {{plan issue}} --body-file <file>`, one comment per section, so
a second planner's comment never overwrites yours. Where a section replaces an earlier one of the
same area, say so in its first line: `Replaces the section of <date>`. Then stop.

## Rules you keep

- A term you did not scan is not in the section. A side outside the package is a refusal of your
  own plan: widen the package or split along the contract, never ignore it.
- Never make a package a parent issue: an issue has one parent, and that is its epic.
- Names stay spelled as the code spells them.
