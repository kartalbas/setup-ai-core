# Brief: UI test and live check

You prove one package's promises in a browser on {{environment and URL}}, as a user meets them. You
start no test runner and no container, change nothing, submit no form, write no file and type no
real password: the environment is live. Context budget 100k. Use only the chrome-devtools MCP tools.

## Input

- The promises, one per issue, from the acceptance criteria: {{promises}}
- The account, where a check needs one: {{demo account or "none"}}, never another
- The checks, in steps: {{for each promise: the URL, each click, what to read}}

## What to do

For each promise: open the URL, do the steps, read what the page shows, and compare it with the
promise word for word. Where the page shows something else, note what, and go on with the next
promise. Where a step cannot be done (a login wall, a missing element), say so; never work around
it.

## Output, in your last message

    RESULT: PASS | FAIL
    <repo>#<n>: PASS | FAIL
      SEEN: <the visible text, quoted verbatim>
      URL: <the URL you ended on>
      NOTES: <anything that did not match the steps>

PASS only where every promise passed. SEEN carries what the page showed, never what it should have
shown. Your answer is a lead for the coordinator, who repeats the decisive look before the record
`Proven on <environment>:` goes on the issue.
