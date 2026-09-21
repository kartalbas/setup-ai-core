#!/usr/bin/env bash
# Add one option to a single-select field of a board - a status column, a priority.
#
#   field-option-add.sh --field Priority --name P9 --color GRAY
#   field-option-add.sh --project 6 --field Priority --name P9 --color GRAY \
#                       --description "Parked: kept rather than closed"
#
# Running it twice changes nothing the second time: an option the field already has is
# reported and nothing is sent.
#
# WHY THIS IS A SCRIPT AND NOT A LINE SOMEBODY TYPES ONCE. The mutation behind it,
# updateProjectV2Field, does not ADD an option - it REPLACES the whole list with what it
# is given. An option left out of that list is DELETED, and with it the value goes off
# every card that carried it. So the field is read first and its current options are sent
# back beside the new one, and that read-then-write is the part nobody should retype from
# memory at midnight.
#
# AN EXISTING OPTION IS SENT BACK WITH ITS id, AND THAT IS THE WHOLE OF IT. The input type
# carries an OPTIONAL id: with it, GitHub updates the option that already exists; without
# it, GitHub creates a NEW one - so a list of the same names, the same colours and the same
# descriptions, sent without ids, replaces every option with a fresh one and CLEARS the
# field on every card that carried a value. Measured on 2026-08-26: adding P9 to both
# boards this way emptied the Priority column of 18 cards, and nothing in the answer said
# so - the mutation reported the five option names it was asked for.
#
# WHAT IT CANNOT GUARANTEE: the read and the write are two
# calls and GitHub offers no way to make them one. An option somebody else adds between
# them is not in the list this run sends, so it is deleted. The window is one round trip
# and there is no way to close it from here.
#
# The colour is one of GitHub's own option colours: GRAY BLUE GREEN YELLOW ORANGE RED
# PINK PURPLE. It is required - a colour defaulted here would make every option added by
# this script look alike whether or not that was meant.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/board.sh"

project=""; field=""; name=""; color=""; description=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project)     need_value "$1" "${2-}"; project="$2";     shift 2 ;;
    --field)       need_value "$1" "${2-}"; field="$2";       shift 2 ;;
    --name)        need_value "$1" "${2-}"; name="$2";        shift 2 ;;
    --color)       need_value "$1" "${2-}"; color="$2";       shift 2 ;;
    --description) need_value "$1" "${2-}"; description="$2"; shift 2 ;;
    *) die "unknown argument '$1'" ;;
  esac
done

[ -n "$field" ] || die "--field is required"
[ -n "$name" ]  || die "--name is required"
# The set is GitHub's own, and it is checked here so both twins answer the same way: the
# PowerShell binder refuses a name outside it before the first call, and without this the
# Bash twin would carry it as far as the mutation and answer with the API's wording.
#
# The set is a VARIABLE and not a literal in the `case` subject. A constant subject is how a
# swapped-over `case` looks, so shellcheck reports one - and a warning left standing is what
# teaches everyone to read past the next one.
COLORS='GRAY BLUE GREEN YELLOW ORANGE RED PINK PURPLE'
[ -n "$color" ] || die "--color is required ($COLORS)"
case " $COLORS " in
  *" $color "*) ;;
  *) die "'$color' is not an option colour. There is: $COLORS" ;;
esac

set_project "$project" >/dev/null

# Read whole, then decided on. gh's own --jq is not used here because the SAME answer is
# read twice below - once for the field id and once for the options it already carries.
fields="$(gh_read "the fields of board $(project_number)" api graphql -f pid="$(project_id)" -f query='
  query($pid:ID!) { node(id:$pid) { ... on ProjectV2 {
    fields(first:50) { nodes { ... on ProjectV2SingleSelectField {
      id name options { id name color description } } } } } } }')" || exit 1

fid="$(printf '%s' "$fields" | jq -r --arg f "$field" \
  '[.data.node.fields.nodes[] | select(.name == $f)] | first | .id // empty' | tr -d '\r')"
[ -n "$fid" ] || die "no single-select field named '$field' on board $(project_number). There is: $(printf '%s' "$fields" | jq -r '.data.node.fields.nodes[] | select(.name != null) | .name' | tr -d '\r' | paste -sd' ' -)"

have="$(printf '%s' "$fields" | jq -r --arg f "$field" \
  '.data.node.fields.nodes[] | select(.name == $f) | .options[].name' | tr -d '\r')"
if printf '%s\n' "$have" | grep -qxF -- "$name"; then
  echo "board $(project_number): field '$field' already has '$name' - nothing sent"
  exit 0
fi

# THE REQUEST BODY IS BUILT BY jq, NOT BY GLUING STRINGS. A description holding a double
# quote or a backslash written into the text of a JSON document is not data any more, and
# the option list carries descriptions somebody typed on a web page.
#
# `description` comes back null for an option that has none, and the input type takes a
# String and not a null, so an absent one is sent as empty.
#
# The new option carries NO id, which is what tells GitHub to create it.
body="$(mktemp)"
trap 'rm -f "$body"' EXIT
printf '%s' "$fields" | jq \
  --arg f "$field" --arg n "$name" --arg c "$color" --arg d "$description" \
  --arg q 'mutation($fid:ID!, $opts:[ProjectV2SingleSelectFieldOptionInput!]!) {
             updateProjectV2Field(input:{fieldId:$fid, singleSelectOptions:$opts}) {
               projectV2Field { ... on ProjectV2SingleSelectField { options { id name } } } } }' '
  .data.node.fields.nodes[] | select(.name == $f)
  | { query: $q,
      variables: {
        fid: .id,
        opts: ((.options | map({ id, name, color, description: (.description // "") }))
               + [{ name: $n, color: $c, description: $d }]) } }' > "$body"

after="$(gh_read "the options of '$field' on board $(project_number)" api graphql --input "$body" \
  --jq '.data.updateProjectV2Field.projectV2Field.options[].name')" || exit 1

# The board's field cache holds the option set as it was BEFORE this run. Left standing,
# every later script resolves names against a list that no longer matches the board, and
# the name just added is the one it cannot find.
rm -f "$(cache_dir)/fields.tsv"

echo "board $(project_number): field '$field' now has $(printf '%s\n' "$after" | tr -d '\r' | paste -sd' ' -)"
