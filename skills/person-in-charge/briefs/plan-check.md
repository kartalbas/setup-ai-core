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
- The open sections of the areas whose first section stands earlier on the plan issue than this
  area's first section, with their repositories and the files their issues name: {{earlier open
  sections or none}}

## What to do

1. The contracts first. Open the `file:line` of every side in `Contracts:` and `Partner:` and
   confirm that it reads or ships the name. Then look for the sides the planner missed: search what
   ships for each name in every clone: first count (`git -C <clone path> grep -c -I -F -e <name>
   origin/HEAD`), then list the hits with `-n` in place of `-c`; `-e` keeps a name that starts with a
   dash from being read as an option. Read the code the issues change for a name built at run time
   or a shape without a fixed word, which no search finds. A side the section does not name is a gap, naming the clone and its `file:line`.
2. For every issue: can a build session start from its acceptance criteria and `file:line` facts,
   and finish the package, without asking? Name every placeholder, contradiction, open question and
   scope beyond the issues.
3. For every contract: is the additive side ordered before the strict side? Does a test need a
   second repository checked out beside the first, and does the section say so? Does the package
   share a file or a contract with an earlier area's open section that its `After:` line does not
   name? Does its `After:` name an area whose first section stands later? Areas take turns in the
   order of their first section on the plan issue, also after a replan.
4. Is the class right? A touched contract outward (outward means an interface somebody outside the project uses (a public API, a published package, a customer's data format), never a contract between the project's own repositories), a secret, a payment or the push gate is
   `high-risk` whatever the text says. A `mechanical` section that names a contract is not mechanical.
   Open the spans the issues name: a package called mechanical that changes a value anything reads
   is not mechanical.
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
    GAPS:
    - <repo>#<n>: <what is missing, with file:line where it applies>
    ORDER: ok | <issue> before <issue> because <contract>
    CLASS: ok | <class> because <reason>

A gap is only what stops a build session from starting or makes it build the wrong thing: a
missing criterion or `file:line`, a contradiction, a side of a contract outside the package, a
wrong order or class. Wording and a better way that is not needed are no gaps. GO only with an
empty GAPS. Post it as a comment on the plan issue (`ai-core issue-comment`), then
stop. You change nothing in the section: the planner does, in the next plan session, with your GAPS
as its input; a CLASS line that raises the class sends the plan to that class's plan row.
