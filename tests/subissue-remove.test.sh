#!/usr/bin/env bash
# Which repository the detach is addressed to, and whose id is sent.
#
# The endpoint's repository is the PARENT's and the id is the CHILD's, so a child living in
# another repository is resolved THERE. Every repository numbers its own issues, and a number
# resolved in the wrong one is a real issue that the API accepts without a word.
#
# Run with a FAKE gh on PATH, so nothing is detached.
#
#   bash test/subissue-remove.test.sh

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fake="$(mktemp -d)"
trap 'rm -rf "$fake"' EXIT
log="$fake/calls.txt"

# Number 136 exists in BOTH repositories with different database ids, which is exactly the
# ambiguity under test - only the id says which one the call was pointed at.
cat > "$fake/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
case "\$*" in
  *"api repos/example-org/example-repo/issues/136 "*) echo '9001'; exit 0 ;;
  *"api repos/example-org/other-repo/issues/136 "*)   echo '9002'; exit 0 ;;
  *"api repos/example-org/example-repo/issues/149 "*) echo '9003'; exit 0 ;;
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

remove="$root/bin/subissue-remove.sh"
repo='example-org/example-repo'
other='example-org/other-repo'

echo 'a child of the same repository is resolved there'
: > "$log"
out="$("$remove" "$repo" 241 149 2>&1)"; rc=$?
check 'exits zero'    0 "$rc"
check 'the line'      '#149 detached from #241' "$out"
check 'the endpoint'  yes "$(grep -q -- "--method DELETE repos/$repo/issues/241/sub_issue" "$log" && echo yes || echo no)"
check 'the id sent'   yes "$(grep -q -- '-F sub_issue_id=9003' "$log" && echo yes || echo no)"

echo 'a child named OWNER/REPO#N is resolved in ITS repository, not in the parent one'
: > "$log"
out="$("$remove" "$repo" 241 "$other#136" 2>&1)"; rc=$?
check 'exits zero'      0 "$rc"
check 'the line'        "$other#136 detached from #241" "$out"
check 'the id was read there' yes "$(grep -q "api repos/$other/issues/136" "$log" && echo yes || echo no)"
check 'and not here'          no  "$(grep -q "api repos/$repo/issues/136" "$log" && echo yes || echo no)"
check 'the id sent'           yes "$(grep -q -- '-F sub_issue_id=9002' "$log" && echo yes || echo no)"
check 'the endpoint is still the parent' yes "$(grep -q -- "repos/$repo/issues/241/sub_issue" "$log" && echo yes || echo no)"

echo 'several children are several calls'
: > "$log"
out="$("$remove" "$repo" 241 149 "$other#136" 2>&1)"
check 'two DELETEs'   2 "$(grep -c -- '--method DELETE' "$log" || true)"
check 'both reported' 2 "$(printf '%s\n' "$out" | grep -c 'detached from #241' || true)"

echo 'the repo resolves from the checkout when left out'
: > "$log"
"$remove" 241 149 >/dev/null 2>&1
check 'default repo' yes "$(grep -q -- "repos/$repo/issues/241/sub_issue" "$log" && echo yes || echo no)"

echo 'a child that is not a number is refused before anything is sent'
: > "$log"
out="$("$remove" "$repo" 241 the-other-one 2>&1)"; rc=$?
check 'exits nonzero' yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'nothing sent'  0 "$(grep -c -- '--method DELETE' "$log" || true)"

echo 'a flag it does not take is refused'
out="$("$remove" --project 6 241 149 2>&1)"; rc=$?
check 'exits nonzero'  yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'names the word' yes "$(echo "$out" | grep -q -- '--project' && echo yes || echo no)"

echo 'a call with no child is refused'
out="$("$remove" "$repo" 241 2>&1)"; rc=$?
check 'exits nonzero' yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
