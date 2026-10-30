#!/usr/bin/env bash
# issue-list on GitHub: the issues of a repository or of an owner, filtered by state and by the words of a search, one line each.
#
#   bash tests/issue-list.test.sh
#
# NOTHING REACHES github.com. tests/gh-search-fake.mjs stands in for gh and answers the search of GitHub's GraphQL API over six
# planted issues: in the repository of the checkout a matching open issue, a matching closed issue, an innocent one and one that
# matches only in its body, and in other repositories one that matches in the same owner and one that matches in another owner.
#
# THE PLANTED DEFECTS, each replayed so it is shown RED: a search that forgets the state, one that forgets the words, one that
# sends the words unquoted so a qualifier among them is read as one. THE INNOCENT CASES stay green beside them: the issue that
# matches in its body only, the issue with no card and the one whose card has no Priority.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" AI_CORE_HOME="$WORK/core" GH_CACHE_DIRECTORY="$WORK/cache" AI_CORE_UPDATE_CHECK=never TRACKER=github
export GH_SEARCH_STATE="$WORK/state"
mkdir -p "$HOME" "$AI_CORE_HOME" "$GH_SEARCH_STATE" "$WORK/bin" "$WORK/project"
git init -q "$WORK/project"
printf '#!/bin/sh\nexec node "%s/tests/gh-search-fake.mjs" "$@"\n' "$ROOT" > "$WORK/bin/gh"
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"
T=$'\t'
failed=0

check() {  # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: [$2]"; echo "       actual:   [$3]"; failed=$((failed + 1)); fi
}
joined() { local IFS=$'\n'; echo "$*"; }

cat > "$GH_SEARCH_STATE/issues.json" <<'JSON'
{ "repository": "example-org/example-repo",
  "issues": [
    { "repo": "example-org/example-repo", "number": 1, "state": "open", "title": "Gate waits for a stale neighbour", "body": "",
      "cards": [ { "status": "implementing", "priority": "P1" } ] },
    { "repo": "example-org/example-repo", "number": 2, "state": "closed", "title": "Gate waits for a copy of the checkout", "body": "",
      "cards": [ { "status": "done", "priority": "P2" } ] },
    { "repo": "example-org/example-repo", "number": 3, "state": "open", "title": "Rename the colour palette", "body": "Nothing that concerns the checks.",
      "cards": [ { "status": "ready", "priority": null } ] },
    { "repo": "example-org/example-repo", "number": 4, "state": "open", "title": "Nothing about it in the title", "body": "The GATE also waits here.",
      "cards": [] },
    { "repo": "example-org/other-repo", "number": 1, "state": "open", "title": "Gate flakes in the other repository", "body": "",
      "cards": [ { "status": "planned", "priority": "P3" } ] },
    { "repo": "other-org/foreign", "number": 1, "state": "open", "title": "Gate of another owner", "body": "",
      "cards": [ { "status": "ready", "priority": null } ] }
  ] }
JSON
FIRST="example-org/example-repo#1${T}implementing${T}P1${T}Gate waits for a stale neighbour"
SECOND="example-org/example-repo#2${T}done${T}P2${T}Gate waits for a copy of the checkout"
THIRD="example-org/example-repo#3${T}ready${T}-${T}Rename the colour palette"
FOURTH="example-org/example-repo#4${T}-${T}-${T}Nothing about it in the title"
OTHER="example-org/other-repo#1${T}planned${T}P3${T}Gate flakes in the other repository"
FOREIGN="other-org/foreign#1${T}ready${T}-${T}Gate of another owner"

list() {  # list <argument>...: what the command prints in $out, its status in $rc, what it said in $err
  out="$(cd "$WORK/project" && bash "${ROOT_UNDER_TEST:-$ROOT}/bin/issue-list.sh" "$@" 2> "$WORK/err")"; rc=$?
  err="$(cat "$WORK/err")"
}
last_search() { tail -n 1 "$GH_SEARCH_STATE/searches.log"; }

echo 'the repository of the checkout, open issues, when nothing narrows the list'
list
check 'exit status' 0 "$rc"
check 'the open issues of that repository, by number, one line each' "$(joined "$FIRST" "$THIRD" "$FOURTH")" "$out"
check 'asked as one search' 'repo:example-org/example-repo is:issue is:open' "$(last_search)"

echo 'the filters, against a matching open issue, a matching closed one and an innocent one'
list --search gate
check '--search keeps the open matches, found in the title and in the body only' "$(joined "$FIRST" "$FOURTH")" "$out"
check 'the search says the repository, the state, title and body, and the quoted word' 'repo:example-org/example-repo is:issue is:open in:title,body "gate"' "$(last_search)"
list --state closed --search gate
check '--state closed lists the matching closed issue and no open one' "$SECOND" "$out"
list --state all --search gate
check '--state all lists the matching open and closed issues, and not the innocent one' "$(joined "$FIRST" "$SECOND" "$FOURTH")" "$out"
check 'it asks for no state' 'repo:example-org/example-repo is:issue in:title,body "gate"' "$(last_search)"
list --state all
check '--state all without a search lists the innocent one too' "$(joined "$FIRST" "$SECOND" "$THIRD" "$FOURTH")" "$out"
list --search palette
check 'an open issue is found by a word of its title alone' "$THIRD" "$out"
list --search gate --state closed
check 'the options may come in any order' "$SECOND" "$out"
list --search 'gate stale'
check 'every word is wanted' "$FIRST" "$out"
list --search 'stale   gate'
check 'in any order, and the spaces between words do not matter' "$FIRST" "$out"
list --search 'gate nonexistent'
check 'a word that no issue holds leaves nothing, with exit status 0' "0/" "$rc/$out"

echo 'the repository named, or every repository of an owner'
list example-org/other-repo --search gate
check 'a named repository is read instead of the checkout, and no other of the owner' "$OTHER" "$out"
list --owner example-org --search gate
check '--owner lists every repository of the owner, by repository and number, and no other owner' "$(joined "$FIRST" "$FOURTH" "$OTHER")" "$out"
check 'asked as the search of the owner' 'org:example-org is:issue is:open in:title,body "gate"' "$(last_search)"
list --owner other-org --search gate
check 'another owner is read for itself' "$FOREIGN" "$out"
GH_SEARCH_PAGE_SIZE=2 list --owner example-org --state all
check 'an answer of several pages is read to its end' "$(joined "$FIRST" "$SECOND" "$THIRD" "$FOURTH" "$OTHER")" "$out"

echo 'what the words of the search cannot do'
list --search 'is:closed'
check 'a qualifier among the words is searched as text and never applied' "0/" "$rc/$out"
check 'it reached the search quoted' 'repo:example-org/example-repo is:issue is:open in:title,body "is:closed"' "$(last_search)"
list --search 'say "hi" \'
check 'a quote and a backslash are escaped inside the quotes' 'repo:example-org/example-repo is:issue is:open in:title,body "say" "\"hi\"" "\\"' "$(last_search)"

echo 'a search that serves fewer issues than it found is refused, and one that GitHub refuses stops the run'
GH_SEARCH_SERVE_AT_MOST=2 list --owner example-org --state all
check 'exits nonzero' 1 "$rc"
check 'and lists nothing' '' "$out"
check 'and says how many it found and how many it served' yes "$(grep -q 'found 5 issues' <<< "$err" && grep -q 'served 2 of them' <<< "$err" && echo yes || echo no)"
cp "$GH_SEARCH_STATE/issues.json" "$WORK/issues.json"
sed 's/"issues":/"refuse": true, "issues":/' "$WORK/issues.json" > "$GH_SEARCH_STATE/issues.json"
list
check 'a refused read exits nonzero' 1 "$rc"
check 'and prints no line' '' "$out"
check 'and says what could not be read' yes "$(grep -q 'cannot read the issues found by' <<< "$err" && echo yes || echo no)"
cp "$WORK/issues.json" "$GH_SEARCH_STATE/issues.json"

echo 'a call that is wrong is refused before GitHub is asked anything'
: > "$GH_SEARCH_STATE/calls.log"
refused() {  # refused <what is wrong> <argument>...
  local what="$1"; shift
  list "$@"
  check "refused: $what" nonzero "$([ "$rc" -ne 0 ] && echo nonzero || echo "status $rc")"
}
refused 'a state that is none' --state maybe
refused 'a search of blanks' --search '   '
refused 'an owner and a repository' --owner example-org example-org/example-repo
refused 'an owner that is no name' --owner 'bad/name'
refused 'an owner without its value' --owner
refused 'a state without its value' --state
refused 'an option that does not exist' --label x
refused 'a word that is no repository' not-a-repository
refused 'a repository of three parts' a/b/c
refused 'a repository with a space' 'a/b c'
refused 'a repository without its owner' /b
refused 'two repositories' one/two three/four
check 'none of them reached GitHub' 0 "$(wc -c < "$GH_SEARCH_STATE/calls.log" | tr -d ' ')"

echo 'it only reads, and prints no token'
: > "$GH_SEARCH_STATE/calls.log"
GH_TOKEN=ghp_plantedtokenvalue0123456789 list --state all --owner example-org
check 'no token in what it printed or said' 0 "$(printf '%s\n%s\n' "$out" "$err" | grep -c ghp_plantedtokenvalue)"
check 'every call is a read: a search and nothing that writes' 0 "$(grep -cE 'mutation|--method|-X |--input' "$GH_SEARCH_STATE/calls.log")"

echo 'the command is listed by ai-core and answers --help'
help="$(cd "$WORK/project" && bash "$ROOT/bin/ai-core" issue-list --help)"
check 'its help names the usage' yes "$(grep -qF 'issue-list.sh [OWNER/REPO | --owner ORG] [--state open|closed|all] [--search TEXT]' <<< "$help" && echo yes || echo no)"
listing="$(bash "$ROOT/bin/ai-core" --help)"
check 'ai-core lists it' yes "$(grep -q '^  issue-list$' <<< "$listing" && echo yes || echo no)"

echo 'planted defects, each shown red against the question it must answer'
plant() {  # plant <name> <file of the harness> <the text to replace> <its replacement>: a copy of the harness with one defect
  local copy="$WORK/plant-$1"
  mkdir -p "$copy"
  tar -C "$ROOT" --exclude=node_modules --exclude=.git -cf - bin lib templates rules VERSION | tar -C "$copy" -xf -
  node -e '
    const fs = require("fs");
    const [file, from, to] = process.argv.slice(1);
    const text = fs.readFileSync(file, "utf8");
    if (!text.includes(from)) process.exit(1);
    fs.writeFileSync(file, text.replace(from, () => to));' "$copy/$2" "$3" "$4" || { echo "  FAIL the plant '$1' did not take"; failed=$((failed + 1)); }
}
differs() {  # differs <plant> <what the real command printed> <argument>...
  local name="$1" real="$2"; shift 2
  ROOT_UNDER_TEST="$WORK/plant-$name" list "$@"
  if [ "$out" != "$real" ]; then echo "  ok   the plant '$name' prints something else, so the check would be red"
  else echo "  FAIL the plant '$name' prints what the real command prints"; failed=$((failed + 1)); fi
}
list --search gate; real_open="$out"
list --search 'is:closed'; real_operator="$out"
plant state lib/github/tracker.sh '  [ "$state" = all ] || query="$query is:$state"' ''
differs state "$real_open" --search gate
plant words lib/github/tracker.sh '[ -z "$text" ] || query="$query in:title,body $(search_terms_of "$text")" || exit 1' ':'
differs words "$real_open" --search gate
plant quotes lib/github/tracker.sh 'in:title,body $(search_terms_of "$text")' 'in:title,body $text'
differs quotes "$real_operator" --search 'is:closed'

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
