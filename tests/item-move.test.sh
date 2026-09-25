#!/usr/bin/env bash
# What item-move.sh does to a card, and in which order.
#
# A card is ADDED to the target board before it is removed from the source one. A card that
# failed to land on the target must still be on the source, or the work would be on no board at
# all - which is the one outcome worse than being on the wrong one.
#
# Run with a FAKE gh on PATH, so no card is moved anywhere.
#
#   bash test/item-move.test.sh

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fake="$(mktemp -d)"
export GH_CACHE_DIRECTORY="$fake/cache"
FROM=999985
TO=999984
trap 'rm -rf "$fake"' EXIT
log="$fake/calls.txt"

# One card on the source board: #42, status testing, priority P1. The target board's fields
# carry the same option names, so both values travel.
cat > "$fake/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" | tr '\n' ' ' >> "$log"; printf '\n' >> "$log"
line="\$*"
case "\$line" in
  *fieldValues*)
    cat <<'JSON'
{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},
 "nodes":[{"id":"PVTI_from42",
  "content":{"number":42,"repository":{"nameWithOwner":"example-org/example-repo"}},
  "fieldValues":{"nodes":[{"name":"testing","field":{"name":"Status"}},
                          {"name":"P1","field":{"name":"Priority"}}]}}]}}}}
JSON
    exit 0 ;;
  *"items(first:100"*)
    cat <<'JSON'
{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},
 "nodes":[{"id":"PVTI_from42",
  "content":{"number":42,"repository":{"nameWithOwner":"example-org/example-repo"}}}]}}}}
JSON
    exit 0 ;;
  *addProjectV2ItemById*) echo 'PVTI_to42'; exit 0 ;;
  *deleteProjectV2Item*)  echo '{}'; exit 0 ;;
  *projectItems*)         exit 0 ;;
  *"issues/42"*)          echo 'I_node42'; exit 0 ;;
esac
if [ "\$1" = "repo" ]; then echo 'example-org/example-repo'; exit 0; fi
echo '{}'
exit 0
EOF
chmod +x "$fake/gh"
export PATH="$fake:$PATH"

for n in "$FROM" "$TO"; do
  mkdir -p "$GH_CACHE_DIRECTORY/$n"
  printf 'PVT_kwmove%s\n' "$n" > "$GH_CACHE_DIRECTORY/$n/project-id"
  printf 'Status\tF1\ttesting\tS_%s\nPriority\tF2\tP1\tP_%s\n' "$n" "$n" > "$GH_CACHE_DIRECTORY/$n/fields.tsv"
done

failed=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}

move="$root/bin/item-move.sh"
repo='example-org/example-repo'

echo '--dry-run reports the card and writes nothing'
: > "$log"
out="$("$move" --repo "$repo" --from "$FROM" --to "$TO" --dry-run 2>&1)"; rc=$?
check 'exits zero'    0 "$rc"
check 'the count'     "1 card(s) from $repo on project $FROM" "$(printf '%s\n' "$out" | sed -n '1p')"
check 'the card'      yes "$(grep -q '#42.*status=testing.*priority=P1' <<< "$out" && echo yes || echo no)"
check 'and says so'   'dry run - nothing changed' "$(printf '%s\n' "$out" | tail -1)"
check 'nothing added' 0 "$(grep -c 'addProjectV2ItemById' "$log" || true)"
check 'nothing removed' 0 "$(grep -c 'deleteProjectV2Item' "$log" || true)"

echo 'the card is added to the target BEFORE it is taken off the source'
: > "$log"
out="$("$move" --repo "$repo" --from "$FROM" --to "$TO" 2>&1)"; rc=$?
check 'exits zero'   0 "$rc"
added="$(grep -n 'addProjectV2ItemById' "$log" | head -1 | cut -d: -f1)"
removed="$(grep -n 'deleteProjectV2Item' "$log" | head -1 | cut -d: -f1)"
check 'both happened' yes "$([ -n "$added" ] && [ -n "$removed" ] && echo yes || echo no)"
check 'add first'     yes "$([ "$added" -lt "$removed" ] && echo yes || echo no)"
check 'the last line' 'done - the issues themselves are untouched' "$(printf '%s\n' "$out" | tail -1)"

echo 'the two values are written on the TARGET board, resolved against its own options'
check 'the status'   yes "$(grep -q "oid=S_$TO" "$log" && echo yes || echo no)"
check 'the priority' yes "$(grep -q "oid=P_$TO" "$log" && echo yes || echo no)"

echo 'a value the target board has no option for is reported and left unset'
: > "$log"
printf 'Status\tF1\tbacklog\tS_other\n' > "$GH_CACHE_DIRECTORY/$TO/fields.tsv"
out="$("$move" --repo "$repo" --from "$FROM" --to "$TO" 2>&1)"
check 'the status is named'   yes "$(grep -q "Status 'testing' has no option on project $TO; left unset" <<< "$out" && echo yes || echo no)"
check 'the priority too'      yes "$(grep -q "Priority 'P1' has no option on project $TO; left unset" <<< "$out" && echo yes || echo no)"
check 'and the card still moved' yes "$(grep -q 'deleteProjectV2Item' "$log" && echo yes || echo no)"
printf 'Status\tF1\ttesting\tS_%s\nPriority\tF2\tP1\tP_%s\n' "$TO" "$TO" > "$GH_CACHE_DIRECTORY/$TO/fields.tsv"

echo 'the same board on both sides is refused'
: > "$log"
out="$("$move" --repo "$repo" --from "$FROM" --to "$FROM" 2>&1)"; rc=$?
check 'exits nonzero' yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'says why'      yes "$(grep -q 'are the same project' <<< "$out" && echo yes || echo no)"
check 'nothing sent'  0 "$(grep -c . "$log" || true)"

echo 'a repo not named OWNER/REPO is refused'
: > "$log"
out="$("$move" --repo example-repo --from "$FROM" --to "$TO" 2>&1)"; rc=$?
check 'exits nonzero' yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'nothing sent'  0 "$(grep -c . "$log" || true)"

echo 'a flag without its value is named'
out="$("$move" --repo "$repo" --from --to "$TO" 2>&1)"; rc=$?
check 'exits nonzero'  yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'names the flag' yes "$(grep -q -- '--from needs a value' <<< "$out" && echo yes || echo no)"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
