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
if [ "\$*" = "api repos/{owner}/{repo} --jq .full_name" ]; then echo 'example-org/example-repo'; exit 0; fi
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

echo 'the carry into Plane is gone: --to and --column are refused before any call or token command'
token_marker="$fake/token-ran"
export FORGEJO_TOKEN_COMMAND="touch $token_marker"
for retired in '--to plane' "$repo --to plane" "94 --to plane" "$repo 94 --to plane" '--column testing --to plane' "$repo --column testing --to plane" '--column testing' '--to'; do
  : > "$log"
  out="$("$transfer" $retired 2>&1)"; rc=$?
  check "$retired: exits nonzero"   yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
  check "$retired: names the word"  yes "$(grep -q "unknown argument '--\(to\|column\)'" <<< "$out" && echo yes || echo no)"
  check "$retired: nothing sent"    0 "$(grep -c . "$log" || true)"
  check "$retired: no token command" no "$([ -e "$token_marker" ] && echo yes || echo no)"
done
planted="$fake/planted"; mkdir -p "$planted"; cp -R "$root/bin" "$root/lib" "$root/templates" "$planted/"; cp "$root/VERSION" "$planted/"
sed -i.bak "s|^    -\*)       die \"unknown argument .*|    -*)       shift ;;|" "$planted/bin/issue-transfer.sh"
cmp -s "$root/bin/issue-transfer.sh" "$planted/bin/issue-transfer.sh" && { echo "  FAIL the planted copy equals the real script"; failed=$((failed + 1)); }
: > "$log"
"$planted/bin/issue-transfer.sh" --to "$repo" 94 "$target" >/dev/null 2>&1
check 'planted: a flag that is silently ignored still transfers, so the call count can go red' "issue transfer 94 $target --repo $repo" "$(cat "$log")"
: > "$log"
"$transfer" "$repo" 94 "$target" >/dev/null 2>&1
check 'innocent: the valid transfer makes its one call' "issue transfer 94 $target --repo $repo" "$(cat "$log")"
unset FORGEJO_TOKEN_COMMAND

echo 'two identical refused invocations at once refuse independently and leave no temporary artifact'
tmp="$fake/tmp"; mkdir -p "$tmp"; : > "$log"
for n in 1 2; do ( TMPDIR="$tmp" "$transfer" --to plane > "$fake/refused-$n.out" 2>&1; echo "$?" > "$fake/refused-$n.rc" ) & done
wait
check 'both exit nonzero'       "yes yes" "$([ "$(cat "$fake/refused-1.rc")" -ne 0 ] && echo yes || echo no) $([ "$(cat "$fake/refused-2.rc")" -ne 0 ] && echo yes || echo no)"
check 'both say the same'       yes "$(cmp -s "$fake/refused-1.out" "$fake/refused-2.out" && grep -q "unknown argument '--to'" "$fake/refused-1.out" && echo yes || echo no)"
check 'nothing sent'            0 "$(grep -c . "$log" || true)"
check 'no temporary artifact'   0 "$(ls -A "$tmp" | wc -l | tr -d ' ')"

echo 'a refused transfer stops the run rather than printing a url that is not one'
refusing="$fake/refusing"
mkdir -p "$refusing"
cat > "$refusing/gh" <<'NO'
#!/usr/bin/env bash
if [ "$*" = "api repos/{owner}/{repo} --jq .full_name" ]; then echo 'example-org/example-repo'; exit 0; fi
if [ "$1" = "repo" ]; then echo 'example-org/example-repo'; exit 0; fi
echo '{"message":"Must have admin rights"}'
echo 'gh: HTTP 403' >&2
exit 1
NO
chmod +x "$refusing/gh"
out="$(PATH="$refusing:$PATH" "$transfer" "$repo" 94 "$target" 2>&1)"; rc=$?
check 'exits nonzero'   yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'names the act, and that GitHub refused it' yes "$(grep -q "$repo#94 was NOT transferred to $target - GitHub refused it (HTTP 403)" <<< "$out" && echo yes || echo no)"
check 'with its words, and no read-back error' "yes no" "$(grep -q 'Must have admin rights' <<< "$out" && echo yes || echo no) $(grep -q 'cannot read' <<< "$out" && echo yes || echo no)"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
