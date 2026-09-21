#!/usr/bin/env bash
# The order the cards end in, and the mutation that puts them there.
#
# The board keeps ONE order for all its items, and `updateProjectV2ItemPosition` with no afterId
# means the very top. So moving each named card to the top would hand back the names REVERSED -
# the one outcome nobody asking for an order wants. The first name goes to the top and every
# later one is placed under the card moved before it, which is what `afterId` is for.
#
# Run with a FAKE gh on PATH; the board answers are seeded, so nothing is looked up.
#
#   bash test/item-top.test.sh

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fake="$(mktemp -d)"
export GH_CACHE_DIRECTORY="$fake/cache"
PROJECT_NUMBER=999987
trap 'rm -rf "$fake"' EXIT
log="$fake/calls.txt"

cat > "$fake/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
case "\$*" in
  *"issues/373"*) echo 'I_node373'; exit 0 ;;
  *"issues/372"*) echo 'I_node372'; exit 0 ;;
  *projectItems*) exit 0 ;;
  *addProjectV2ItemById*)
    for a in "\$@"; do case "\$a" in cid=*) echo "PVTI_\${a#cid=I_node}"; exit 0 ;; esac; done
    echo 'PVTI_unknown'; exit 0 ;;
esac
if [ "\$1" = "repo" ]; then echo 'example-org/example-repo'; exit 0; fi
echo '{}'
exit 0
EOF
chmod +x "$fake/gh"
export PATH="$fake:$PATH"

mkdir -p "$GH_CACHE_DIRECTORY/$PROJECT_NUMBER"
printf 'PVT_kwtop%s\n' "$PROJECT_NUMBER" > "$GH_CACHE_DIRECTORY/$PROJECT_NUMBER/project-id"

failed=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}

top="$root/bin/item-top.sh"
repo='example-org/example-repo'

# The position calls in the order they were made, as "<item>[ <after item>]" per line.
#
# The recorded call runs over several physical lines - the mutation text carries newlines - and
# the flags all stand on the FIRST of them, so that is the line the two values are read from.
positions() {
  grep -- '-f iid=' "$log" | sed -e 's/.*-f iid=\([^ ]*\).*/\1/' > "$fake/iids"
  grep -- '-f iid=' "$log" | sed -e 's/.*-f after=\([^ ]*\).*/\1/' -e 't' -e 's/.*//' > "$fake/afters"
  paste -d' ' "$fake/iids" "$fake/afters" | sed 's/ $//'
}

echo 'the first card goes to the top, the second lands under it'
: > "$log"
out="$("$top" --project "$PROJECT_NUMBER" "$repo" 373 372 2>&1)"; rc=$?
check 'exits zero'      0 "$rc"
check 'both reported'   '#373 -> top
#372 -> top' "$out"
check 'two moves'       2 "$(grep -c 'updateProjectV2ItemPosition' "$log" || true)"
check 'the order'       'PVTI_373
PVTI_372 PVTI_373' "$(positions)"

echo 'one card alone goes to the top with no afterId at all'
: > "$log"
"$top" --project "$PROJECT_NUMBER" "$repo" 373 >/dev/null 2>&1
check 'one move'   1 "$(grep -c 'updateProjectV2ItemPosition' "$log" || true)"
check 'no afterId' 0 "$(grep -c -- '-f after=' "$log" || true)"

echo 'the board named on the command line is the board acted on'
check 'the project id sent' yes "$(grep -q "pid=PVT_kwtop$PROJECT_NUMBER" "$log" && echo yes || echo no)"

echo 'a number that is not one is refused before anything is sent'
: > "$log"
out="$("$top" --project "$PROJECT_NUMBER" "$repo" 373 later 2>&1)"; rc=$?
check 'exits nonzero' yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'nothing sent'  0 "$(grep -c 'updateProjectV2ItemPosition' "$log" || true)"

echo 'a flag without its value is named'
out="$("$top" --project 2>&1)"; rc=$?
check 'exits nonzero'  yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'names the flag' yes "$(echo "$out" | grep -q -- '--project needs a value' && echo yes || echo no)"

echo 'a misspelt flag is refused, never filed under the numbers'
out="$("$top" --projekt "$PROJECT_NUMBER" 373 2>&1)"; rc=$?
check 'exits nonzero'  yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'names the word' yes "$(echo "$out" | grep -q -- '--projekt' && echo yes || echo no)"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
