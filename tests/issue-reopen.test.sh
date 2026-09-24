#!/usr/bin/env bash
# What issue-reopen.sh sends, and where the card lands.
#
# Run with a FAKE gh on PATH, so nothing is reopened and every call is recorded instead. What is
# pinned: the state that reaches gh is `open`, the card goes back to `todo` on every board the
# issue is on, and a number that is not one stops the run before the FIRST issue is touched -
# a batch that half-applies is worse than one that does not run.
#
#   bash test/issue-reopen.test.sh

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fake="$(mktemp -d)"
export GH_CACHE_DIRECTORY="$fake/cache"
trap 'rm -rf "$fake"' EXIT
log="$fake/calls.txt"

cat > "$fake/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
case "\$*" in
  *projectItems*)         printf 'example-org/998\tPVTI_item\n'; exit 0 ;;
  *'projectV2(number'*)   echo 'PVT_kwreopen'; exit 0 ;;
  *'fields(first:50'*)    printf 'Status\tF1\ttodo\tT1\nStatus\tF1\tdone\tD1\n'; exit 0 ;;
esac
if [ "\$1" = "repo" ]; then echo 'example-org/example-repo'; exit 0; fi
echo '{}'
exit 0
EOF
chmod +x "$fake/gh"
export PATH="$fake:$PATH"

failed=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}

reopen="$root/bin/issue-reopen.sh"
repo='example-org/example-repo'

echo 'the state that reaches gh, and the column the card goes back to'
: > "$log"
out="$("$reopen" "$repo" 412 2>&1)"; rc=$?
check 'exits zero'     0 "$rc"
check 'the state'      yes "$(grep -q -- '-f state=open' "$log" && echo yes || echo no)"
check 'the issue'      yes "$(grep -q "api --method PATCH repos/$repo/issues/412" "$log" && echo yes || echo no)"
check 'the reopen line' '#412 -> reopened' "$(printf '%s\n' "$out" | sed -n '1p')"
check 'the board line'  '#412 -> todo (board example-org/998)' "$(printf '%s\n' "$out" | sed -n '2p')"
check 'the option sent' yes "$(grep -q 'oid=T1' "$log" && echo yes || echo no)"

echo 'a batch is one call per issue'
: > "$log"
out="$("$reopen" "$repo" 412 413 2>&1)"
check 'two PATCHes'    2 "$(grep -c 'api --method PATCH' "$log" || true)"
check 'both reported'  2 "$(grep -c -- '-> reopened' <<< "$out" || true)"

echo 'the repo resolves from the checkout when left out'
: > "$log"
"$reopen" 412 >/dev/null 2>&1
check 'default repo' yes "$(grep -q "repos/$repo/issues/412" "$log" && echo yes || echo no)"

# Every number is checked before the first one is sent: a batch that half-applies leaves the
# board and the issues disagreeing, and nothing on either side says which half ran.
echo 'a number that is not one stops before the first issue is touched'
: > "$log"
out="$("$reopen" "$repo" 412 not-a-number 2>&1)"; rc=$?
check 'exits nonzero'  yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'names the word' yes "$(echo "$out" | grep -q "not 'not-a-number'" && echo yes || echo no)"
check 'nothing sent'   0 "$(grep -c 'api --method PATCH' "$log" || true)"

echo 'a flag it does not take is refused'
out="$("$reopen" "$repo" --project 9 412 2>&1)"; rc=$?
check 'exits nonzero'  yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'names the word' yes "$(echo "$out" | grep -q -- '--project' && echo yes || echo no)"

echo 'a refused PATCH stops the run rather than reporting a reopen'
refusing="$fake/refusing"
mkdir -p "$refusing"
cat > "$refusing/gh" <<'NO'
#!/usr/bin/env bash
if [ "$1" = "repo" ]; then echo 'example-org/example-repo'; exit 0; fi
echo '{"message":"Not Found"}'
echo 'gh: HTTP 404' >&2
exit 1
NO
chmod +x "$refusing/gh"
out="$(PATH="$refusing:$PATH" "$reopen" "$repo" 412 2>&1)"; rc=$?
check 'exits nonzero'    yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'no reopened line' no  "$(echo "$out" | grep -q -- '-> reopened' && echo yes || echo no)"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
