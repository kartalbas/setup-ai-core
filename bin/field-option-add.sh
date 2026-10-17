#!/usr/bin/env bash
# Add one option to a single-select field of a board - a status column, a priority.
#
#   field-option-add.sh --field Priority --name P9 --color GRAY
#   field-option-add.sh --project 6 --field Priority --name P9 --color GRAY \
#                       --description "Parked: kept rather than closed"
#   field-option-add.sh --field Status --name review --color PURPLE --after implementing
#   field-option-add.sh --field Status --name ready --color BLUE --replacing todo
#
# The new option goes last, or right after the option --after names. The order is the order of
# the columns, and finish-issue moves a card by it. --replacing gives an existing option the new
# name, colour and description and keeps its id, so every card that carried the old option
# carries the new one; nothing is created.
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

project=""; field=""; name=""; color=""; description=""; after=""; replacing=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project)     need_value "$1" "${2-}"; project="$2";     shift 2 ;;
    --field)       need_value "$1" "${2-}"; field="$2";       shift 2 ;;
    --name)        need_value "$1" "${2-}"; name="$2";        shift 2 ;;
    --color)       need_value "$1" "${2-}"; color="$2";       shift 2 ;;
    --description) need_value "$1" "${2-}"; description="$2"; shift 2 ;;
    --after)       need_value "$1" "${2-}"; after="$2";       shift 2 ;;
    --replacing)   need_value "$1" "${2-}"; replacing="$2";   shift 2 ;;
    *) die "unknown argument '$1'" ;;
  esac
done

[ -n "$field" ] || die "--field is required"
[ -n "$name" ]  || die "--name is required"
[ -z "$after" ] || [ -z "$replacing" ] || die "--after and --replacing exclude each other: a replaced option keeps its place"
# The set is GitHub's own, and it is checked here so a name outside it is refused before the
# first call, not carried as far as the mutation and answered with the API's wording.
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
fields="$(board_fields_json)" || exit 1

fid="$(printf '%s' "$fields" | jq -r --arg f "$field" \
  '[.data.node.fields.nodes[] | select(.name == $f)] | first | .id // empty')"
[ -n "$fid" ] || die "no single-select field named '$field' on board $(project_number). There is: $(printf '%s' "$fields" | jq -r '.data.node.fields.nodes[] | select(.name != null) | .name' | paste -sd' ' -)"

have="$(printf '%s' "$fields" | jq -r --arg f "$field" \
  '.data.node.fields.nodes[] | select(.name == $f) | .options[].name')"
if grep -qxF -- "$name" <<< "$have"; then
  [ -z "$replacing" ] || die "field '$field' on board $(project_number) has both '$name' and '$replacing': nothing is replaced, because two options cannot become one; move the cards of '$replacing' by hand and delete it on the board"
  echo "board $(project_number): field '$field' already has '$name' - nothing sent"
  exit 0
fi
for o in "$after" "$replacing"; do
  [ -z "$o" ] || grep -qxF -- "$o" <<< "$have" \
    || die "field '$field' on board $(project_number) has no option '$o'. There is: $(paste -sd' ' - <<< "$have")"
done

# THE REQUEST BODY IS BUILT BY jq, NOT BY GLUING STRINGS. A description holding a double
# quote or a backslash written into the text of a JSON document is not data any more, and
# the option list carries descriptions somebody typed on a web page.
#
# `description` comes back null for an option that has none, and the input type takes a
# String and not a null, so an absent one is sent as empty.
#
# The new option carries NO id, which is what tells GitHub to create it; a replaced one keeps
# its own.
body="$(mktemp)"
trap 'rm -f "$body"' EXIT
printf '%s' "$fields" | jq \
  --arg f "$field" --arg n "$name" --arg c "$color" --arg d "$description" --arg a "$after" --arg r "$replacing" \
  --arg q 'mutation($fid:ID!, $opts:[ProjectV2SingleSelectFieldOptionInput!]!) {
             updateProjectV2Field(input:{fieldId:$fid, singleSelectOptions:$opts}) {
               projectV2Field { ... on ProjectV2SingleSelectField { options { id name } } } } }' '
  .data.node.fields.nodes[] | select(.name == $f)
  | { query: $q,
      variables: {
        fid: .id,
        opts: ((.options | map({ id, name, color, description: (.description // "") })) as $o
               | { name: $n, color: $c, description: $d } as $new
               | if $r != "" then $o | map(if .name == $r then . + $new else . end)
                 elif $a != "" then ($o | map(.name) | index($a)) as $i | $o[:$i + 1] + [$new] + $o[$i + 1:]
                 else $o + [$new] end) } }' > "$body"

after="$(field_options_replace "$field" "$body")" || exit 1

# The board's field cache holds the option set as it was BEFORE this run. Left standing,
# every later script resolves names against a list that no longer matches the board, and
# the name just added is the one it cannot find.
rm -f "$(cache_dir)/fields.tsv"

echo "board $(project_number): field '$field' now has $(printf '%s\n' "$after" | paste -sd' ' -)"
