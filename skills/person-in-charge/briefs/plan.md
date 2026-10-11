# Brief: plan a package

You plan one package of the project in `{{project folder}}`. You write no code and start no session:
your whole output is one section of the plan issue, and the plan check reads it without you. Context
budget 150k: read the issues, the spans their `file:line` facts name, and nothing else.

## Why this phase exists

Last time packages were cut by file. An engine began to require a file per site that no content
repository shipped; each side released alone, and production failed twice for the same gap. A
package is an area: one capability as the user meets it, across every repository it touches, with
both sides of every contract.

## Input

- The issues: {{issues, each with its acceptance criteria and file:line facts}}
- The repositories of the project folder: {{repository list}}
- The plan issue: {{plan issue reference}}
- The classes: `mechanical` (a rename or a text, no contract touched), `high-risk` (security,
  payments, contracts outward, the push gate), `normal-hard` (everything else)

## What to do

1. Map each issue to the files it changes, from its `file:line` facts; an issue without them or
   without acceptance criteria stays out, and your output names it with what it lacks.
2. Derive the contract terms: every name one repository reads and another ships that an issue
   touches: a file name, a manifest field, a configuration key, an environment variable, a route, a
   message type. Take them from the facts' spans, not from memory.
3. Run `ai-core contract-scan <term>...` from the project folder. Every repository that holds a side
   of a term joins the package.
4. Order the issues: the additive side of a contract before the strict side; an issue that unblocks
   another first.
5. Judge the class from the terms and the issue text. Split the package where its build would not
   fit 300k of context: about 8 issues or 400 changed lines.

## Output: the package section, nothing else

    ### Package: {{area, as the user names it}}
    Ecosystem: {{tool}}
    Class: mechanical | normal-hard | high-risk
    Repositories: <repo>, <repo>
    Contracts: <term> (<producer repo> -> <reader repo>), ...
    Issues: <repo>#<n> <title>, ... (in landing order)
    Reviews: 0
    Phase: plan - {{your session name}}
    Left out: <repo>#<n>: <what it lacks>

Write it with `ai-core issue-edit {{plan issue}} --body-file <file>` into the plan issue, under the
sections that are there. Then stop.

## Rules you keep

- A contract term you did not scan is not in the section. A term with a side outside the package is
  a refusal of your own plan: widen the package or split along the contract, never ignore it.
- Never make a package a parent issue: an issue has one parent, and that is its epic.
- Names stay spelled as the code spells them.
