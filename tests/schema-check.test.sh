#!/usr/bin/env bash
# Does the schema check see a field the payload does not have, and does it leave a correct one alone?
#
#   bash test/schema-check.test.sh
#
# THE CLASS THIS HOLDS CLOSED. github.com validates a mutation document before it executes it, so a
# field that is not on the payload refuses the whole mutation and nothing happens on the board. No
# test in this repository could see that: every one of them runs against a fake gh that answers
# whatever it is told. `updateProjectV2ItemPosition(...) { projectV2Item { id } }` therefore stood
# in lib/board.sh and lib/Board.psm1 under two green tests, and item-top moved no card.
#
# WHAT IS FAKED HERE, AND WHAT IS NOT. The interface is faked: gh answers a small hand-written
# introspection payload naming two mutations, so this test reaches nothing, exactly like every
# other one. What is NOT faked is the reading - the check walks a real directory of real files and
# the refusals below are the ones it printed. Proving that the payload it reads is the real one is
# the command's own job when scripts/check.sh runs it, and it is not a test's job at all.
#
# THE PLANTED DEFECT AND THE PLANTED INNOCENT. The tree starts with two mutations the interface
# has, and the run must be GREEN over them - without that, a refusal below could be the check
# refusing everything. Then a file asking for a field the payload does not carry is planted, and
# then a file naming a mutation the interface does not have, and each must be named with its line.
# Taking both away must make the run green again.

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fake="$(mktemp -d)"
trap 'rm -rf "$fake"' EXIT
log="$fake/calls.txt"

failed=0
check() {  # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}

# The stand-in interface. Two mutations, each with the fields its payload really carries, which is
# all the check asks for. `$fake/refuse` turns it into a server that says no.
cat > "$fake/schema.json" <<'JSON'
{"data":{"__type":{"fields":[
  {"name":"updateProjectV2ItemPosition","type":{"name":"UpdateProjectV2ItemPositionPayload",
    "fields":[{"name":"clientMutationId"},{"name":"items"}]}},
  {"name":"addProjectV2ItemById","type":{"name":"AddProjectV2ItemByIdPayload",
    "fields":[{"name":"clientMutationId"},{"name":"item"}]}}
]}}}
JSON

cat > "$fake/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
if [ -f "$fake/refuse" ]; then
  echo '{"errors":[{"message":"Bad credentials"}]}'
  exit 1
fi
cat "$fake/schema.json"
EOF
chmod +x "$fake/gh"
export PATH="$fake:$PATH"

# The tree the check is pointed at. Its two files are the innocent case, and both are written the
# way this repository writes a mutation: over several physical lines, inside a quoted argument.
tree="$fake/tree"
mkdir -p "$tree/bin" "$tree/lib"

cat > "$tree/bin/board-sync.sh" <<'SH'
#!/usr/bin/env bash
add_card() {
  gh api graphql -f query='
    mutation($pid:ID!, $cid:ID!) {
      addProjectV2ItemById(input:{projectId:$pid, contentId:$cid}) { item { id } } }'
}
SH

cat > "$tree/lib/board.sh" <<'SH'
#!/usr/bin/env bash
item_top() {
  gh api graphql -f query='
    mutation($pid:ID!, $iid:ID!) {
      updateProjectV2ItemPosition(input:{projectId:$pid, itemId:$iid}) { items { totalCount } } }'
}
SH

command="$root/bin/schema-check.sh"
out=''
run() {  # run <argument>...
  : > "$log"
  out="$("$command" "$@" 2>&1)"
  return $?
}
line() {  # line <a word the line carries>
  printf '%s\n' "$out" | grep -F -- "$1" | head -1
}

echo 'the innocent tree is green, and the count says how much was read'
run "$tree"; rc=$?
check 'exits zero' 0 "$rc"
check 'the count'  'schema-check: 2 mutation selection(s) in 2 file(s), every one on the payload the interface publishes.' \
      "$(printf '%s\n' "$out" | tail -1)"
check 'one call to the interface, not one per file' 1 "$(wc -l < "$log" | tr -d ' ')"

echo 'a field the payload does not carry is refused, with the file and the line'
cat > "$tree/bin/plant.sh" <<'SH'
#!/usr/bin/env bash
gh api graphql -f query='
  mutation($pid:ID!, $iid:ID!) {
    updateProjectV2ItemPosition(input:{projectId:$pid, itemId:$iid}) { projectV2Item { id } } }'
SH
run "$tree"; rc=$?
check 'exits nonzero' yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'names the file, the line, the mutation and the field' \
      'bin/plant.sh:4 asks `updateProjectV2ItemPosition` for `projectV2Item`, and UpdateProjectV2ItemPositionPayload has: clientMutationId,items' \
      "$(line 'plant.sh')"
check 'the count' 'schema-check: 3 mutation selection(s) in 3 file(s), 1 refused.' \
      "$(printf '%s\n' "$out" | tail -1)"
check 'the two correct ones are not named' '' "$(line 'board-sync.sh')$(line 'lib/board.sh')"

echo 'a mutation the interface does not have is refused too'
cat > "$tree/bin/unknown.sh" <<'SH'
#!/usr/bin/env bash
gh api graphql -f query='
  mutation($pid:ID!) {
    updateProjectV2ItemPositions(input:{projectId:$pid}) { items { totalCount } } }'
SH
run "$tree"; rc=$?
check 'exits nonzero' yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'names the mutation' \
      'bin/unknown.sh:4 names `updateProjectV2ItemPositions`, and the interface has no mutation of that name' \
      "$(line 'unknown.sh')"
check 'the count, and the unknown one is not counted as a selection' \
      'schema-check: 3 mutation selection(s) in 4 file(s), 2 refused.' \
      "$(printf '%s\n' "$out" | tail -1)"

echo 'with both plants taken away the run is green again, so the refusals were the plants'
rm -f "$tree/bin/plant.sh" "$tree/bin/unknown.sh"
run "$tree"; rc=$?
check 'exits zero' 0 "$rc"
check 'the count'  'schema-check: 2 mutation selection(s) in 2 file(s), every one on the payload the interface publishes.' \
      "$(printf '%s\n' "$out" | tail -1)"

echo 'an interface that refuses makes the run RED, never green and never skipped'
: > "$fake/refuse"
run "$tree"; rc=$?
rm -f "$fake/refuse"
check 'exits nonzero'  yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'says nothing was checked' \
      'schema-check: FAIL - the interface could not be read, so no mutation was checked' \
      "$(line 'no mutation was checked')"
check 'and never prints a green verdict' '' "$(line 'every one on the payload')"

echo 'a comment naming a mutation is not code'
cat > "$tree/bin/comment.sh" <<'SH'
#!/usr/bin/env bash
# updateProjectV2ItemPosition(input:{projectId:$pid}) { projectV2Item { id } } is the defect
SH
cat > "$tree/bin/help.ps1" <<'PS'
<#
.NOTES
updateProjectV2ItemPosition(input:{projectId:$pid}) { projectV2Item { id } } is the defect
#>
Write-Host 'nothing is sent here'
PS
run "$tree"; rc=$?
check 'exits zero' 0 "$rc"
check 'neither the shell comment nor the help block was counted' \
      'schema-check: 2 mutation selection(s) in 4 file(s), every one on the payload the interface publishes.' \
      "$(printf '%s\n' "$out" | tail -1)"
rm -f "$tree/bin/comment.sh" "$tree/bin/help.ps1"

echo 'a misspelt flag is refused, never read as a directory'
run --dirctory "$tree"; rc=$?
check 'exits two'      2 "$rc"
check 'names the word' yes "$(case "$out" in *--dirctory*) echo yes ;; *) echo "no: $out" ;; esac)"

echo 'a directory that is not there is named'
run "$fake/nowhere"; rc=$?
check 'exits two'      2 "$rc"
check 'names the path' yes "$(case "$out" in *"$fake/nowhere"*) echo yes ;; *) echo "no: $out" ;; esac)"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
