#!/usr/bin/env bash
# What issue-assign.sh writes back as the assignee set.
#
# Run with a FAKE gh on PATH, so nothing is assigned and the body of every PATCH is recorded
# instead. What is pinned: --add keeps whoever is already there, --remove takes one name off and
# leaves the rest, --replace states the whole set, and a call that would change nothing sends no
# PATCH at all - a no-op PATCH still writes an event onto the timeline, which reads later as a
# decision somebody took.
#
#   bash test/issue-assign.test.sh

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fake="$(mktemp -d)"
trap 'rm -rf "$fake"' EXIT
log="$fake/calls.txt"
body="$fake/body.json"

# The issue carries two assignees. On a PATCH the stand-in keeps the body it was handed on
# stdin, because that body is the whole contract.
cat > "$fake/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
case "\$*" in
  *"--method PATCH"*) cat > "$body"; echo '{}'; exit 0 ;;
esac
if [ "\$1" = "repo" ]; then echo 'example-org/example-repo'; exit 0; fi
echo '{"number":575,"assignees":[{"login":"kartalbas"},{"login":"anton"}]}'
exit 0
EOF
chmod +x "$fake/gh"
export PATH="$fake:$PATH"

failed=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}

assign="$root/bin/issue-assign.sh"
repo='example-org/example-repo'

# The set that reached GitHub, sorted, so the comparison is about membership and not order.
sent() { jq -r '.assignees | sort | join(",")' "$body" 2>/dev/null; }

echo '--add keeps whoever is already there'
: > "$log"; rm -f "$body"
"$assign" "$repo" 575 --add kadir >/dev/null 2>&1
check 'the whole set'  'anton,kadir,kartalbas' "$(sent)"
check 'one PATCH'      1 "$(grep -c -- '--method PATCH' "$log" || true)"

echo '--remove takes one name off and leaves the rest'
: > "$log"; rm -f "$body"
"$assign" "$repo" 575 --remove anton >/dev/null 2>&1
check 'the whole set' 'kartalbas' "$(sent)"

echo '--replace states the whole set'
: > "$log"; rm -f "$body"
"$assign" "$repo" 575 --replace kadir >/dev/null 2>&1
check 'the whole set' 'kadir' "$(sent)"

echo 'a call that changes nothing sends no PATCH'
: > "$log"; rm -f "$body"
out="$("$assign" "$repo" 575 --add kartalbas 2>&1)"
check 'no PATCH'      0 "$(grep -c -- '--method PATCH' "$log" || true)"
check 'and says so'   '#575 -> unchanged (kartalbas, anton)' "$out"

echo 'the repo resolves from the checkout when left out'
: > "$log"; rm -f "$body"
"$assign" 575 --add kadir >/dev/null 2>&1
check 'default repo' yes "$(grep -q "repos/$repo/issues/575" "$log" && echo yes || echo no)"

echo 'a batch is one read and one write per issue'
: > "$log"; rm -f "$body"
out="$("$assign" "$repo" 575 576 --add kadir 2>&1)"
check 'two PATCHes'   2 "$(grep -c -- '--method PATCH' "$log" || true)"
check 'both reported' 2 "$(printf '%s\n' "$out" | grep -c '^#' || true)"

echo 'a call that names no direction stops before GitHub is reached'
: > "$log"
out="$("$assign" "$repo" 575 2>&1)"; rc=$?
check 'exits nonzero' yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'says what to name' yes "$(echo "$out" | grep -q 'name --add, --remove or --replace' && echo yes || echo no)"
check 'nothing sent'  0 "$(grep -c . "$log" || true)"

echo '--replace cannot be combined with the additive flags'
: > "$log"
out="$("$assign" "$repo" 575 --replace kadir --add anton 2>&1)"; rc=$?
check 'exits nonzero' yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'says why'      yes "$(echo "$out" | grep -q 'states the whole set' && echo yes || echo no)"
check 'nothing sent'  0 "$(grep -c . "$log" || true)"

echo 'a flag without its value is named'
out="$("$assign" "$repo" 575 --add 2>&1)"; rc=$?
check 'exits nonzero'  yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'names the flag' yes "$(echo "$out" | grep -q -- '--add needs a value' && echo yes || echo no)"

echo 'a number that is not one is refused before the first issue is touched'
: > "$log"
out="$("$assign" "$repo" 575 nobody --add kadir 2>&1)"; rc=$?
check 'exits nonzero' yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'nothing sent'  0 "$(grep -c -- '--method PATCH' "$log" || true)"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
