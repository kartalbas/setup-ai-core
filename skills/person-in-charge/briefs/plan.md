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
2. Find every contract an issue touches: every name one repository reads and another ships (a file
   name, a manifest field, a configuration key, an environment variable, a route, a message type),
   taken from the facts' spans, not from memory. Search every clone of the project folder and of
   each partner folder for it in what ships (`git -C <clone path> grep -n -I -F -e <name>
   origin/HEAD`; `-e` keeps a name that starts with a dash from being read as an option) and read
   the hits. A name with hundreds of hits is too common to mark a contract: search its longer,
   more specific spelling. A search finds only the words you give it, so a name built at run time or
   a shape without a fixed word is found by reading the code that reads or ships it. Every clone that holds
   a side joins the package, the side's `file:line` in `Contracts:`; a side in a partner folder is a
   `Partner:` line. A hit that is no side (a README, a changelog, a fixture) stays out.
3. Order the issues: the additive side of a contract before the strict side; an issue that unblocks
   another first. A package that shares a file or a contract with an open section waits until that
   section has landed: `After: <area>`. The open section was posted first, so it goes first.
4. Judge the class from the contracts and the issue text. Cut so that one build session finishes the
   package alone, without a question back: every issue that belongs to the area and its contracts
   goes into the one package, however many there are, because each further package reads the same
   code and contracts again and pays its whole context. Split only where the build would not fit its
   context budget (300k, 250k in Codex): one section per part, named `<area>: <part>`, in landing
   order, each later part naming the earlier one in its `After:` line, so it is built on what that
   part landed. Write in `Cut:` why you cut the way you did and where the risk lies.
5. Collect what the later phases need from the acceptance criteria: the verification command of each
   clone (its map, its `README` or its `scripts/`), the test and production environments the criteria
   name with their URLs, the demo account where a check needs one, and the clicks each promise takes.
6. Where an issue holds a decision of the owner's (a new dependency, a public interface, a deletion
   beyond the change's own leftovers, a rename of something that has a name or a new word a person
   meets, a cost of a multiple of the issue), write the solution path on
   that issue (`ai-core solution-path <n> <file>`) and name the issue under `Waits for the owner:`.

## Output: one package section per package, nothing else

    ### Package: {{area}}
    Ecosystem: {{tool}}
    Class: mechanical | normal-hard | high-risk
    Repositories: <clone folder>, <clone folder>
    Contracts: <name> (<producer clone> <file:line> -> <reader clone> <file:line>), ... | none
    Partner: <folder> <clone> <file:line> (producer | reader) | none
    After: <area> | none
    Cut: <why this cut, and where the risk lies>
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

- A contract side you did not open is not in the section. A side outside the package is a refusal
  of your own plan: widen the package or split it into parts that run one after the other, never
  ignore it.
- Never make a package a parent issue: an issue has one parent, and that is its epic.
- Names stay spelled as the code spells them.
