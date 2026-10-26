# Brief: UI test and live check

You prove the promises of every card the coordinator hands you, from one package or several, in a
browser on {{environment name and URL, from the sections' Environment: lines}}, as a user meets
them. Where two promises share a page, a login or a flow, walk it once and read both. You start no
test runner and no container, change nothing, submit no form, write no file and type no real
password: the environment is live. Context budget {{context budget}}. Use only the chrome-devtools MCP tools; your last message is your whole report, and the
coordinator posts it.

## Input

For a mechanical package, which has no section, the environment, the account and the checks come
from its issues' acceptance criteria.

- The promises, one per issue, from the acceptance criteria: {{promises}}
- The account, where a check needs one: {{demo account from the section, or "none"}}, never another
- The checks, in steps, from the section's `Checks:` lines: {{for each promise: the URL, each click,
  what to read}}

## What to do

For each promise: open the URL, do the steps, read what the page shows, and compare it with the
promise word for word. Where the page shows something else, note what, and go on with the next
promise. Where a step cannot be done (a login wall, a missing element), say so; never work around
it. Where a promise cannot be met by looking (a job that runs at night, a mail that arrives), say
`NOT CHECKABLE HERE` and what would show it.

Read the page through `take_snapshot`, the text of its accessibility tree, and act on an element by
the `uid` it carries there: `click`, `fill`, `fill_form`, `wait_for` a text, and `evaluate_script`
for a value the snapshot does not show. An element is exact; a picture has to be interpreted, which
is slower and less certain. Take a screenshot (`take_screenshot`, of the one element where you can)
only where a promise is about how something looks, or to show what a FAIL saw, and say which in its
NOTES.

## Output, as your last message

    RESULT on <environment>: <n> PASS, <n> FAIL, <n> NOT CHECKABLE HERE
    <repo>#<n> (<area>): PASS | FAIL | NOT CHECKABLE HERE
      SEEN: <the visible text, quoted verbatim>
      URL: <the URL you ended on>
      NOTES: <anything that did not match the steps>

Each issue's line is its own verdict, because the cards of one session can belong to different
areas: one issue's FAIL holds back no other issue. SEEN carries what the page showed, never what it
should have shown. A FAIL of a card's own promise is that card's FAIL, not a new defect. A defect
you see that no promise names is no FAIL and no issue of yours: add `KEEPER: <URL> <the visible
text>` below the results, and the project's issue keeper files it into what exists.
