#!/usr/bin/env bash
# What issue-transfer.sh sends, and what it deliberately does not touch.
#
# Run with a FAKE gh on PATH, so nothing is transferred and every call is recorded instead.
# What is pinned: the transfer is one call and the BOARD is not written at all - the target
# repository resolves to its own board, and which board the work belongs on after a transfer
# is a decision, not a consequence.
#
#   bash test/issue-transfer.test.sh

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fake="$(mktemp -d)"
trap 'rm -rf "$fake"' EXIT
log="$fake/calls.txt"

cat > "$fake/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
if [ "\$1" = "repo" ]; then echo 'example-org/example-repo'; exit 0; fi
echo 'https://github.com/example-org/other-repo/issues/7'
exit 0
EOF
chmod +x "$fake/gh"
export PATH="$fake:$PATH"

failed=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}

transfer="$root/bin/issue-transfer.sh"
repo='example-org/example-repo'
target='example-org/other-repo'

echo 'the whole call, and nothing else'
: > "$log"
out="$("$transfer" "$repo" 94 "$target" 2>&1)"; rc=$?
check 'exits zero'      0 "$rc"
check 'the call'        "issue transfer 94 $target --repo $repo" "$(cat "$log")"
check 'what gh printed' 'https://github.com/example-org/other-repo/issues/7' "$out"
check 'no board write'  no "$(grep -q 'graphql' "$log" && echo yes || echo no)"

echo 'the repo resolves from the checkout when left out'
: > "$log"
"$transfer" 94 "$target" >/dev/null 2>&1
check 'default repo' yes "$(grep -q -- "--repo $repo" "$log" && echo yes || echo no)"

echo 'a target not named OWNER/REPO stops before GitHub is reached'
: > "$log"
out="$("$transfer" "$repo" 94 other-repo 2>&1)"; rc=$?
check 'exits nonzero'  yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'says which'     yes "$(grep -q 'the target repository must be named OWNER/REPO' <<< "$out" && echo yes || echo no)"
check 'nothing sent'   0 "$(grep -c . "$log" || true)"

echo 'a number that is not one stops before GitHub is reached'
: > "$log"
out="$("$transfer" "$repo" ninety-four "$target" 2>&1)"; rc=$?
check 'exits nonzero' yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'nothing sent'  0 "$(grep -c . "$log" || true)"

echo 'a flag it does not take is refused'
out="$("$transfer" --project 6 94 "$target" 2>&1)"; rc=$?
check 'exits nonzero'  yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'names the word' yes "$(grep -q -- '--project' <<< "$out" && echo yes || echo no)"

echo 'a refused transfer stops the run rather than printing a url that is not one'
refusing="$fake/refusing"
mkdir -p "$refusing"
cat > "$refusing/gh" <<'NO'
#!/usr/bin/env bash
if [ "$1" = "repo" ]; then echo 'example-org/example-repo'; exit 0; fi
echo '{"message":"Must have admin rights"}'
echo 'gh: HTTP 403' >&2
exit 1
NO
chmod +x "$refusing/gh"
out="$(PATH="$refusing:$PATH" "$transfer" "$repo" 94 "$target" 2>&1)"; rc=$?
check 'exits nonzero'   yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'names the act'   yes "$(grep -q "cannot read the transfer of $repo#94 to $target" <<< "$out" && echo yes || echo no)"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
