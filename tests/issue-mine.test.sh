#!/usr/bin/env bash
# What issue-mine.sh answers: yes for an issue assigned to the account gh is logged in as,
# REFUSED for one assigned to somebody else, REFUSED for one assigned to nobody.
#
# Run with a FAKE gh on PATH, so nothing leaves the machine.
#
#   bash test/issue-mine.test.sh

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fake="$(mktemp -d)"
trap 'rm -rf "$fake"' EXIT

cat > "$fake/gh" <<'GH'
#!/usr/bin/env bash
case "$*" in
  *"api user"*) echo '{"login":"tester"}' ;;
  *issues/163*) echo '{"number":163,"assignees":[{"login":"tester"},{"login":"anton"}]}' ;;
  *issues/164*) echo '{"number":164,"assignees":[{"login":"anton"},{"login":"kadir"}]}' ;;
  *issues/165*) echo '{"number":165,"assignees":[]}' ;;
  *)            echo 'example-org/example-repo' ;;
esac
exit 0
GH
chmod +x "$fake/gh"
export PATH="$fake:$PATH"

failed=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}
mine="$root/bin/issue-mine.sh"
repo='example-org/example-repo'

echo 'an issue assigned to the account is mine, among others or alone'
out="$("$mine" "$repo" 163 2>&1)"; rc=$?
check 'exits zero' 0 "$rc"
check 'it says so'  '#163 is assigned to @tester.' "$out"

echo "somebody else's issue is refused, and the line names them and me"
out="$("$mine" "$repo" 164 2>&1)"; rc=$?
check 'exits nonzero' 1 "$rc"
check 'the line' 'REFUSED: #164 is assigned to @anton, @kadir, not to @tester - ask them or the product owner to reassign it.' "$out"

echo "nobody's issue is refused too - the product owner assigns it first"
out="$("$mine" "$repo" 165 2>&1)"; rc=$?
check 'exits nonzero' 1 "$rc"
check 'the line' 'REFUSED: #165 is assigned to nobody - the product owner assigns it before it is taken up.' "$out"

echo 'the repo may be left out inside a checkout'
out="$("$mine" 163 2>&1)"; rc=$?
check 'exits zero' 0 "$rc"

# A refused read has an empty assignee list in it, and an empty list is the ONE answer that
# start-issue reads as "nobody has it" - which is a statement about the issue the issue never
# made. The read goes through gh_read, so a refusal stops the run instead.
echo 'a refused read is not an issue assigned to nobody'
refusing="$fake/refusing"
mkdir -p "$refusing"
cat > "$refusing/gh" <<'NO'
#!/usr/bin/env bash
case "$*" in
  *"api user"*) echo '{"login":"tester"}'; exit 0 ;;
  *issues/*)    echo '{"message":"Not Found"}'; echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
  *)            echo 'example-org/example-repo'; exit 0 ;;
esac
NO
chmod +x "$refusing/gh"
out="$(PATH="$refusing:$PATH" "$mine" "$repo" 404 2>&1)"; rc=$?
check 'exits nonzero'            yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'and does not say nobody'  no  "$(grep -q 'assigned to nobody' <<< "$out" && echo yes || echo no)"

echo 'a call with no number is refused'
out="$("$mine" 2>&1)"; rc=$?
check 'exits nonzero' yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
out="$("$mine" "$repo" not-a-number 2>&1)"; rc=$?
check 'a number that is not one is refused' yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
