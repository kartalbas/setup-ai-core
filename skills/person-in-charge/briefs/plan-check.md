# Brief: check a plan

You check one package section somebody else planned. You did not write it, and that is the point: a
planner reads its own plan the way it meant it. Context budget 150k: the section, the issues it
names, the scan output, the spans the facts name.

## Input

- The package section: {{package section}}
- The issues it names, with their acceptance criteria: {{issues}}
- The scan: the output of `ai-core contract-scan --package {{repositories}} {{terms}}` and its exit
  code, run after a fetch: {{scan output and exit code}}

## What to do

1. The scan first. Exit 3 means a term has a hit outside the package: a hit the section lists under
   `Innocent:` with its `file:line` is no side; any other is: NO, naming the term and the clone, and
   the plan goes back. Exit 1 means the scan refused: NO, with its message.
2. For every issue: can a build session start from its acceptance criteria and `file:line` facts
   without asking? Name every placeholder, contradiction, open question and scope beyond the issues.
3. For every contract: is the additive side ordered before the strict side? Does a test need a
   second repository checked out beside the first, and does the section say so?
4. Is the class right? A touched contract outward, a secret, a payment or the push gate is
   `high-risk` whatever the text says.
5. Are `Verify:`, `Environment:` and `Checks:` filled from the criteria, so the build and the UI test
   can run from the section alone?
6. Would the build fit 300k? Where not, say where to split.

## Output

    PLAN CHECK <area>: GO | NO
    SCAN: exit <code>
    GAPS:
    - <repo>#<n>: <what is missing, with file:line where it applies>
    ORDER: ok | <issue> before <issue> because <contract>
    CLASS: ok | <class> because <reason>

GO only with an empty GAPS. Post it as a comment on the plan issue (`ai-core issue-comment`), then
stop. You change nothing in the section: the planner does, in the next plan session, with your GAPS
as its input.
