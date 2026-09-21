#!/usr/bin/env bash
# What field-option-add sends when it adds an option, and what it costs to send it wrong.
#
#   bash test/field-option-add.test.sh
#
# NOTHING REACHES github.com. A stand-in `gh` answers the field query, keeps the request
# body of the mutation, and answers that too. A cached project id is seeded for a board
# number no real project carries, so no board is ever resolved.
#
# THE CLASS THIS HOLDS CLOSED. The mutation
# updateProjectV2Field REPLACES a single-select field's whole option list. Every option in
# the list carries an OPTIONAL id: with it, GitHub updates the option that already exists;
# WITHOUT it, GitHub creates a new one and deletes the old. So a list of the same names,
# the same colours and the same descriptions, sent without ids, looks like a no-op and is
# not one - it swaps every option for a fresh one and CLEARS the field on every card that
# carried a value. Measured on 2026-08-26: adding P9 to the two boards this way emptied the
# Priority column of 18 cards. The answer said nothing, because the answer is the list of
# option NAMES, and the names were right.
#
# So the assertion is about the ID, not about the names: every option that already existed
# goes back with the id it already had, and the new one goes without.
#
# THE PLANTED DEFECT is the body without the ids - the same names, colours and descriptions,
# sent as a list GitHub reads as new options - asserted to be the thing this test catches.
#
# THE PLANTED INNOCENT CASE is an option the field already has: nothing is sent at all, so
# a run that sends a correct body is not the only way to pass.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAKE="$(mktemp -d)"
export GH_CACHE_DIRECTORY="$FAKE/cache"
PROJECT_NUMBER=999992
failed=0

cleanup() { rm -rf "$FAKE"; }
trap cleanup EXIT

check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}

mkdir -p "$GH_CACHE_DIRECTORY/$PROJECT_NUMBER"
printf 'PVT_kwboard%s\n' "$PROJECT_NUMBER" > "$GH_CACHE_DIRECTORY/$PROJECT_NUMBER/project-id"

# The board as the query answers it: one Priority field with four options, each with its
# own id, and one option carrying a description so the null-to-empty rule is exercised.
cat > "$FAKE/fields.json" <<'JSON'
{"data":{"node":{"fields":{"nodes":[
  {"id":"PVTSSF_status","name":"Status","options":[
    {"id":"OPT_todo","name":"todo","color":"BLUE","description":"want doing now"}]},
  {"id":"PVTSSF_priority","name":"Priority","options":[
    {"id":"OPT_p0","name":"P0","color":"GRAY","description":null},
    {"id":"OPT_p1","name":"P1","color":"GRAY","description":null},
    {"id":"OPT_p2","name":"P2","color":"GRAY","description":null},
    {"id":"OPT_p3","name":"P3","color":"GRAY","description":null}]}
]}}}}
JSON

cat > "$FAKE/mutation.json" <<'JSON'
{"data":{"updateProjectV2Field":{"projectV2Field":{"options":[
  {"id":"OPT_p0","name":"P0"},{"id":"OPT_p1","name":"P1"},{"id":"OPT_p2","name":"P2"},
  {"id":"OPT_p3","name":"P3"},{"id":"OPT_p9","name":"P9"}]}}}}
JSON

mkdir -p "$FAKE/bin"
# The stand-in keeps the request body of the mutation and RUNS the --jq program the caller
# gave, the way gh does. Answering the raw document instead would let a script that never
# reads its answer pass.
cat > "$FAKE/bin/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$FAKE/calls"
prog=""; prev=""
for a in "\$@"; do
  [ "\$prev" = "--input" ] && cp "\$a" "$FAKE/body.json"
  [ "\$prev" = "--jq" ] && prog="\$a"
  prev="\$a"
done
case "\$*" in
  *--input*) answer="\$(cat "$FAKE/mutation.json")" ;;
  *)         answer="\$(cat "$FAKE/fields.json")" ;;
esac
if [ -n "\$prog" ]; then printf '%s' "\$answer" | jq -r "\$prog"
else printf '%s' "\$answer"; fi
exit 0
EOF
chmod +x "$FAKE/bin/gh"
export PATH="$FAKE/bin:$PATH"

run() { # run <field-option-add.sh argument>...
  rm -f "$FAKE/calls" "$FAKE/body.json"
  bash "$ROOT/bin/field-option-add.sh" --project "$PROJECT_NUMBER" "$@" 2>&1
}

# The ids the body carries for the options that already existed, in order. This is the
# whole assertion: a body naming the four ids updates four options, a body naming none
# replaces them.
sent_ids() { jq -r '[.variables.opts[] | .id // "NONE"] | join(" ")' "$FAKE/body.json"; }

echo 'the option list the mutation is sent'

out="$(run --field Priority --name P9 --color GRAY)"
check 'the run reports the new list' \
      "board $PROJECT_NUMBER: field 'Priority' now has P0 P1 P2 P3 P9" "$out"
check 'every option that already existed keeps its id, and the new one has none' \
      'OPT_p0 OPT_p1 OPT_p2 OPT_p3 NONE' "$(sent_ids)"
check 'the names go with them, in order' 'P0 P1 P2 P3 P9' \
      "$(jq -r '[.variables.opts[].name] | join(" ")' "$FAKE/body.json")"
check 'a null description is sent as empty, never as null' 'yes' \
      "$(jq -r 'if [.variables.opts[].description] | any(. == null) then "no" else "yes" end' "$FAKE/body.json")"
check 'the field written to is the one that was asked for' 'PVTSSF_priority' \
      "$(jq -r '.variables.fid' "$FAKE/body.json")"

# THE PLANTED DEFECT: the body with the same names and colours and the ids dropped.
# Without it the assertion above passes equally well for a check that looks at nothing.
jq 'del(.variables.opts[].id)' "$FAKE/body.json" > "$FAKE/plant.json"
check 'the plant: a body without ids carries the same names' 'P0 P1 P2 P3 P9' \
      "$(jq -r '[.variables.opts[].name] | join(" ")' "$FAKE/plant.json")"
check 'the plant: and this test would have caught it' 'NONE NONE NONE NONE NONE' \
      "$(jq -r '[.variables.opts[] | .id // "NONE"] | join(" ")' "$FAKE/plant.json")"

echo
echo 'the board cache'

check 'the option set cached before the run is deleted' 'gone' \
      "$([ -f "$GH_CACHE_DIRECTORY/$PROJECT_NUMBER/fields.tsv" ] && echo 'still there' || echo gone)"

# THE INNOCENT CASE. An option the field already has: nothing is sent, so the run above is
# shown to have sent something because it had something to send.
echo
echo 'an option the field already has'

out="$(run --field Priority --name P2 --color GRAY)"
check 'is reported and nothing is sent' \
      "board $PROJECT_NUMBER: field 'Priority' already has 'P2' - nothing sent" "$out"
check 'and no mutation reached the board' 'no body' \
      "$([ -f "$FAKE/body.json" ] && echo 'a body was sent' || echo 'no body')"

echo
echo 'a field the board does not have'

out="$(run --field Priorität --name P9 --color GRAY)"
check 'stops, and names the fields there are' yes \
      "$(case "$out" in *"There is: Status Priority"*) echo yes ;; *) echo "no: $out" ;; esac)"
check 'and no mutation reached the board' 'no body' \
      "$([ -f "$FAKE/body.json" ] && echo 'a body was sent' || echo 'no body')"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo; echo 'all passed'
