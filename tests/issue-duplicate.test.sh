#!/usr/bin/env bash
# Which of the two issues is marked as the duplicate of which.
#
# Run with a FAKE gh on PATH, so nothing is commented and every call is recorded instead. The
# direction is the whole point: GitHub's "Duplicate of #N" syntax is directional FROM the issue
# receiving the comment, so a reversed call marks the canonical issue as the duplicate and
# nothing in the answer says so.
#
#   bash test/issue-duplicate.test.sh

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fake="$(mktemp -d)"
trap 'rm -rf "$fake"' EXIT
log="$fake/calls.txt"

cat > "$fake/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
case "\$*" in
  *"issues/412"*) echo 'I_node412'; exit 0 ;;
  *"issues/421"*) echo 'I_node421'; exit 0 ;;
esac
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

dup="$root/bin/issue-duplicate.sh"
repo='example-org/example-repo'
other='example-org/other-repo'

echo 'the comment lands on the DUPLICATE and names the canonical issue'
: > "$log"
out="$("$dup" "$repo" 412 "$repo" 421 2>&1)"; rc=$?
check 'exits zero'   0 "$rc"
check 'the line'     "$repo#421 is marked as a duplicate of $repo#412" "$out"
check 'the endpoint' yes "$(grep -q "repos/$repo/issues/421/comments" "$log" && echo yes || echo no)"
check 'the body'     yes "$(grep -q -- 'body=Duplicate of #412' "$log" && echo yes || echo no)"

echo 'across repositories the reference carries the owner and the repository'
: > "$log"
out="$("$dup" "$other" 412 "$repo" 421 2>&1)"
check 'the line' "$repo#421 is marked as a duplicate of $other#412" "$out"
check 'the body' yes "$(grep -q -- "body=Duplicate of $other#412" "$log" && echo yes || echo no)"

echo '--undo takes the relation off through the mutation, not through a comment'
: > "$log"
out="$("$dup" --undo "$repo" 412 "$repo" 421 2>&1)"; rc=$?
check 'exits zero'    0 "$rc"
check 'the line'      "$repo#421 is no longer marked as a duplicate of $repo#412" "$out"
check 'the mutation'  yes "$(grep -q 'unmarkIssueAsDuplicate' "$log" && echo yes || echo no)"
check 'the two ids'   yes "$(grep -q -- '-f canonical=I_node412 -f duplicate=I_node421' "$log" && echo yes || echo no)"
check 'no comment'    no  "$(grep -q 'comments' "$log" && echo yes || echo no)"

echo 'a repository not named OWNER/REPO stops before GitHub is reached'
: > "$log"
out="$("$dup" example-repo 412 "$repo" 421 2>&1)"; rc=$?
check 'exits nonzero'  yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'names which'    yes "$(grep -q "the canonical issue's repository" <<< "$out" && echo yes || echo no)"
check 'nothing sent'   0 "$(grep -c . "$log" || true)"

: > "$log"
out="$("$dup" "$repo" 412 example-repo 421 2>&1)"; rc=$?
check 'the other side too' yes "$(grep -q "the duplicate issue's repository" <<< "$out" && echo yes || echo no)"
check 'nothing sent'       0 "$(grep -c . "$log" || true)"

echo 'a number that is not one stops before GitHub is reached'
: > "$log"
out="$("$dup" "$repo" many "$repo" 421 2>&1)"; rc=$?
check 'exits nonzero' yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'nothing sent'  0 "$(grep -c . "$log" || true)"

echo 'a call with the wrong number of arguments is refused'
out="$("$dup" "$repo" 412 "$repo" 2>&1)"; rc=$?
check 'exits nonzero' yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
