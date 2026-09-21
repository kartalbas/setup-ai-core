#!/usr/bin/env bash
# Which side of a `blocked by` dependency the endpoint addresses, and what each refusal says.
#
# issue-block.sh and issue-unblock.sh are one relationship written twice, so they are held here
# together: the endpoint's repository is the BLOCKED issue's and the id is the BLOCKER's database
# id. Written the other way round the dependency points backwards, and GitHub accepts it.
#
# Run with a FAKE gh on PATH, so nothing is recorded on any issue.
#
#   bash test/blocked-by.test.sh

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fake="$(mktemp -d)"
trap 'rm -rf "$fake"' EXIT
log="$fake/calls.txt"

cat > "$fake/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
case "\$*" in
  *"issues/311"*) echo '9311'; exit 0 ;;
  *"issues/359"*) echo '9359'; exit 0 ;;
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

block="$root/bin/issue-block.sh"
unblock="$root/bin/issue-unblock.sh"
blocked='example-org/example-repo'
by='example-org/other-repo'

echo 'the endpoint is the blocked issue, the id is the blocker'
: > "$log"
out="$("$block" "$blocked" 359 "$by" 311 2>&1)"; rc=$?
check 'exits zero'     0 "$rc"
check 'the line'       "$blocked#359 is blocked by $by#311" "$out"
check 'the endpoint'   yes "$(grep -q "repos/$blocked/issues/359/dependencies/blocked_by" "$log" && echo yes || echo no)"
check 'the id read'    yes "$(grep -q "api repos/$by/issues/311" "$log" && echo yes || echo no)"
check 'the id sent'    yes "$(grep -q -- '-F issue_id=9311' "$log" && echo yes || echo no)"

echo 'the mirror addresses the same side, with the id in the path'
: > "$log"
out="$("$unblock" "$blocked" 359 "$by" 311 2>&1)"; rc=$?
check 'exits zero'     0 "$rc"
check 'the line'       "$blocked#359 is no longer blocked by $by#311" "$out"
check 'the method'     yes "$(grep -q -- '--method DELETE' "$log" && echo yes || echo no)"
check 'the endpoint'   yes "$(grep -q "repos/$blocked/issues/359/dependencies/blocked_by/9311" "$log" && echo yes || echo no)"

echo 'a dependency that is already there says so and changes nothing'
existing="$fake/existing"
mkdir -p "$existing"
cat > "$existing/gh" <<'DUP'
#!/usr/bin/env bash
case "$*" in *"issues/311 "*|*"issues/311") echo '9311'; exit 0 ;; esac
echo 'gh: HTTP 422: Validation Failed' >&2
exit 1
DUP
chmod +x "$existing/gh"
out="$(PATH="$existing:$PATH" "$block" "$blocked" 359 "$by" 311 2>&1)"; rc=$?
check 'exits nonzero'  yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'says so'        yes "$(echo "$out" | grep -q "already blocked by $by#311 - nothing was changed" && echo yes || echo no)"

echo 'a dependency that is not there says so on the way out'
absent="$fake/absent"
mkdir -p "$absent"
cat > "$absent/gh" <<'GONE'
#!/usr/bin/env bash
case "$*" in *"issues/311 "*|*"issues/311") echo '9311'; exit 0 ;; esac
echo 'gh: HTTP 404: Not Found' >&2
exit 1
GONE
chmod +x "$absent/gh"
out="$(PATH="$absent:$PATH" "$unblock" "$blocked" 359 "$by" 311 2>&1)"; rc=$?
check 'exits nonzero'  yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'says so'        yes "$(echo "$out" | grep -q "is not blocked by $by#311 - nothing was changed" && echo yes || echo no)"

echo 'a repository not named OWNER/REPO stops before GitHub is reached'
for command in "$block" "$unblock"; do
  : > "$log"
  out="$("$command" example-repo 359 "$by" 311 2>&1)"; rc=$?
  check "$(basename "$command"): exits nonzero" yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
  check "$(basename "$command"): nothing sent"  0 "$(grep -c . "$log" || true)"
  : > "$log"
  out="$("$command" "$blocked" 359 other-repo 311 2>&1)"; rc=$?
  check "$(basename "$command"): the other side too" yes "$(echo "$out" | grep -q "the blocking issue's repository" && echo yes || echo no)"
  check "$(basename "$command"): still nothing sent" 0 "$(grep -c . "$log" || true)"
done

echo 'a number that is not one stops before GitHub is reached'
: > "$log"
out="$("$block" "$blocked" soon "$by" 311 2>&1)"; rc=$?
check 'exits nonzero' yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'nothing sent'  0 "$(grep -c . "$log" || true)"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
