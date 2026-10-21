# Brief: check a plan

You check one package section somebody else planned. You did not write it, and that is the point: a
planner reads its own plan the way it meant it. Context budget 150k: the section, the issues it
names, the spans the facts and the contracts name.

## Input

- The plan issue, where your verdict goes: {{plan issue reference}}
- The package section: {{package section}}
- The issues it names, with their acceptance criteria: {{issues}}
- The clones of the project folder and of each partner folder, by path, fetched by the coordinator
  right before this check: {{clone paths}}
- For a re-check after a re-plan only: the reason for the re-plan (the GAPS of a plan-check NO, the
  findings of the review that sent the package back, the owner's amendment, or the build's context
  lines) and the changed parts of the re-plan, the before and after of each changed section or the
  diff of the plan comment: {{reason and changed parts, or "full check" for a first plan}}

## What to do

1. The contracts first. Open the `file:line` of every side in `Contracts:` and `Partner:` and
   confirm that it reads or ships the name. Then look for the sides the planner missed: search what
   ships for each name in every clone: first count (`git -C <clone path> grep -I -F -e <name>
   origin/HEAD | wc -l`), then list the hits (`git -C <clone path> grep -n -I -F -e <name>
   origin/HEAD`); `-e` keeps a name that starts with a dash from being read as an option. Read the
   code the issues change for a name built at run time or a shape without a fixed word, which no search finds. A side the
   section does not name is a gap, naming the clone and its `file:line`.
2. For every issue: can a build session start from its acceptance criteria and `file:line` facts,
   and finish the package, without asking? Does `Files:` hold every file the facts name? Name every
   placeholder, contradiction, open question and scope beyond the issues.
3. For every contract: is the additive side ordered before the strict side? Does a test need a
   second repository checked out beside the first, and does the section say so?
4. Is the class right? A touched contract outward (outward means an interface somebody outside the project uses (a public API, a published package, a customer's data format), never a contract between the project's own repositories), a secret, a payment or the push gate is
   `high-risk` whatever the text says.
5. Are `Verify:`, `Environment:` and `Checks:` filled from the criteria, so the build and the UI test
   can run from the section alone? Does `Environment:` hold the test and the production URL?
6. Would the build fit its context budget (300k, 250k in Codex)? Where not, say where to split. Do the
   parts of a split package run one after the other, each naming the earlier one in its `After:`
   line? Was an issue of this area and its contracts left out only to keep the package small? Name
   it.

## Probes

- A probe or an experiment (a script, a sample folder, an install) runs in a new folder from
  `mktemp -d`, never in a clone or a worktree, and you remove it at the end: a stray folder in a
  clone makes every later `start-issue` there refuse.

## Output

    PLAN CHECK <area>: GO | NO
    CONTRACTS: ok | <name> <clone> <file:line>, ... not in the section
    REPAIRED:
    - <repo>#<n>: <what was wrong, with file:line>; <how the section now says it>
    GAPS:
    - <repo>#<n>: <what is missing, with file:line where it applies>
    ORDER: ok | <issue> before <issue> because <contract>
    CLASS: ok | <class> because <reason>

A gap is only what stops a build session from starting or makes it build the wrong thing: a
missing criterion or `file:line`, a contradiction, a side of a contract outside the package, a
wrong order or class. Each gap names the issue of the package it belongs to, so that the re-plan
widens that issue. A gap never becomes an issue of its own. Wording and a better way that is not needed are no gaps. A gap you can close
from the code and the issues you close yourself, as a person reviewing does: post the whole section
again as `Replaces the section ... (comment <id>)`, list each repair under REPAIRED, and leave it
out of GAPS. Only a gap that needs the owner's decision, a new issue or a new cut of the package
stays under GAPS. GO only with an empty GAPS. Post it as a comment on the plan issue (`ai-core issue-comment`), send its first line to
the coordinator ({{how to reach the coordinator}}), because a comment on an issue wakes nobody, then
stop. A gap left under GAPS goes to the planner, in the next plan session, as its input; a CLASS line that raises the class sends the re-plan to that class's `re-plan` row.

## A re-check after a re-plan

Where the coordinator hands you the reason for a re-plan and the changed parts that answer it, you
re-check, with a 100k budget: read only the changed parts, each point of the reason against the part
that answers it, and the spans and contracts a changed part names. Say for every point, in your last
message, GO with the part that settles it or NO with what is still missing. A change that opens a
new gap is a NO. Your block holds under `GAPS` only the points that stay open and the new gaps, so
GO still means an empty `GAPS`. The rest of the section was read by the first plan check and stays
out.
