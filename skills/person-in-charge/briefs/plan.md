# Brief: plan a package

You plan one package of the project in `{{project folder}}`. You write no code and start no session:
your whole output is one package section, posted as one comment on the plan issue, and the plan check
reads it without you. Context budget 150k: read the issues, the spans their `file:line` facts name,
and nothing else.

## Why this phase exists

Last time packages were cut by file. An engine began to require a file per site that no content
repository shipped; each side released alone, and production failed twice for the same gap. A
package is an area: one capability as the user meets it, across every repository it touches, with
both sides of every contract.

## Input

- The area, as the coordinator names it: {{area}}
- The issues: {{issues, each with its acceptance criteria and file:line facts}}
- The clones of the project folder, by folder name: {{clone folder names}}
- The plan issue: {{plan issue reference}}
- What came back, where this plan is not the first: {{the plan check's GAPS, or the two reviews'
  FINDINGS, or "first plan"}}. A plan that comes back changes what the findings name; the rest stands.
- The classes: `mechanical` (a rename or a text, no contract touched), `high-risk` (security, payments,
  contracts outward, the push gate), `normal-hard` (everything else)

## What to do

1. Map each issue to the files it changes, from its `file:line` facts; an issue without them or
   without acceptance criteria stays out, and your output names it with what it lacks.
2. Derive the contract terms: every name one repository reads and another ships that an issue
   touches: a file name, a manifest field, a configuration key, an environment variable, a route, a
   message type. Take them from the facts' spans, not from memory.
3. `git -C <clone> fetch -q origin` for every clone, then `ai-core contract-scan <term>...` from the
   project folder: the scan reads what origin ships. Every clone that holds a side of a term joins the
   package. A hit that is no side (a README, a changelog, a fixture) is written down as innocent, with
   its `file:line`, so the plan check does not count it.
4. Order the issues: the additive side of a contract before the strict side; an issue that unblocks
   another first.
5. Judge the class from the terms and the issue text. Split the package where its build would not fit
   300k of context: about 8 issues or 400 changed lines.
6. Collect what the later phases need from the acceptance criteria: the verification command of each
   clone (its map, its `README` or its `scripts/`), the environment the criteria name with its URL, the
   demo account where a check needs one, and the clicks each promise takes.

## Output: the package section, nothing else

    ### Package: {{area}}
    Ecosystem: {{tool}}
    Class: mechanical | normal-hard | high-risk
    Repositories: <clone folder>,<clone folder>        (no space: this is --package's value)
    Contracts: <term> (<producer clone> -> <reader clone>), ...
    Innocent: <term> <clone> <file:line>, ...
    Issues: <repo>#<n> <title>, ... (in landing order)
    Verify: <clone>: <command>; ...
    Environment: <name> <URL>; demo account: <login or none>
    Checks: <repo>#<n>: <URL>, <click>, <what to read>; ...
    Reviews: 0
    Phase: plan - {{your session name}}
    Left out: <repo>#<n>: <what it lacks>

Post it with `ai-core issue-comment {{plan issue}} --body-file <file>`, one comment, so a second
planner's comment never overwrites yours. Then stop. Where the section replaces an earlier one of
the same area, say so in its first line: `Replaces the section of <date>`.

## Rules you keep

- A term you did not scan is not in the section. A side outside the package is a refusal of your
  own plan: widen the package or split along the contract, never ignore it.
- Never make a package a parent issue: an issue has one parent, and that is its epic.
- Names stay spelled as the code spells them.
