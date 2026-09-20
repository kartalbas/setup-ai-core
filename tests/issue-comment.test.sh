#!/usr/bin/env bash
# What issue-comment.sh sends GitHub, inline and from a file.
#
# Run with a FAKE gh on PATH, so nothing is commented and every call is recorded instead.
# The contract lives in the recorded call: an inline body travels as --body, a file
# travels as --body-file so no shell reads its backticks and newlines on the way, and a
# call naming both or neither stops before GitHub is reached.
#
#   bash test/issue-comment.test.sh

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fake="$(mktemp -d)"
trap 'rm -rf "$fake"' EXIT
log="$fake/calls.txt"

cat > "$fake/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
if [ "\$1" = "repo" ]; then echo 'example-org/example-repo'; exit 0; fi
echo 'https://github.com/example-org/example-repo/issues/94#issuecomment-1'
exit 0
EOF
chmod +x "$fake/gh"
export PATH="$fake:$PATH"

failed=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}

comment="$root/bin/issue-comment.sh"
repo='example-org/example-repo'
body_file="$fake/comment.md"
printf 'A body with a `backtick` in it.\n' > "$body_file"

echo 'an inline body still travels as --body'
: > "$log"
"$comment" "$repo" 94 'Comment here' >/dev/null 2>&1
check 'the whole call' "issue comment 94 --repo $repo --body Comment here" "$(cat "$log")"

echo 'a file travels as --body-file, never as its content'
: > "$log"
"$comment" "$repo" 94 --body-file "$body_file" >/dev/null 2>&1
check 'the flag'            yes "$(grep -q -- "--body-file $body_file" "$log" && echo yes || echo no)"
check 'the issue and repo'  yes "$(grep -q "issue comment 94 --repo $repo" "$log" && echo yes || echo no)"
check 'no inline body'      no  "$(grep -q -- '--body ' "$log" && echo yes || echo no)"

echo 'what gh prints is what the caller gets'
out="$("$comment" "$repo" 94 --body-file "$body_file" 2>/dev/null)"
check 'the comment url' 'https://github.com/example-org/example-repo/issues/94#issuecomment-1' "$out"

echo 'the repo resolves from the checkout when left out'
: > "$log"
"$comment" 94 --body-file "$body_file" >/dev/null 2>&1
check 'default repo' yes "$(grep -q -- "--repo $repo" "$log" && echo yes || echo no)"

: > "$log"
"$comment" 94 'Comment here' >/dev/null 2>&1
check 'default repo, inline' yes "$(grep -q -- "--repo $repo" "$log" && echo yes || echo no)"

echo 'an unusable call stops before GitHub is reached'
for name in 'no body at all' 'both a body and a file' 'a file that is not there'; do
  : > "$log"
  case "$name" in
    'no body at all')          "$comment" "$repo" 94 >/dev/null 2>&1 ;;
    'both a body and a file')  "$comment" "$repo" 94 'Comment here' --body-file "$body_file" >/dev/null 2>&1 ;;
    'a file that is not there') "$comment" "$repo" 94 --body-file "$fake/nope.md" >/dev/null 2>&1 ;;
  esac
  rc=$?
  check "$name: exits nonzero"   yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
  check "$name: nothing sent"    0   "$(grep -c . "$log" || true)"
done

out="$("$comment" "$repo" 94 --body-file "$fake/nope.md" 2>&1)"
check 'the missing file is named' yes "$(echo "$out" | grep -q 'does not exist' && echo yes || echo no)"

# --body-file with nothing after it would leave the path empty and let `shift 2` end the run
# with no word at all; need_value is what turns that into a sentence.
echo 'a flag without its value is named'
out="$("$comment" "$repo" 94 --body-file 2>&1)"; rc=$?
check 'exits nonzero'  yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'names the flag' yes "$(echo "$out" | grep -q -- '--body-file needs a value' && echo yes || echo no)"

echo 'a refused post stops the run rather than printing nothing and exiting zero'
refusing="$fake/refusing"
mkdir -p "$refusing"
cat > "$refusing/gh" <<'NO'
#!/usr/bin/env bash
if [ "$1" = "repo" ]; then echo 'example-org/example-repo'; exit 0; fi
echo '{"message":"Issue is locked"}'
echo 'gh: HTTP 403' >&2
exit 1
NO
chmod +x "$refusing/gh"
out="$(PATH="$refusing:$PATH" "$comment" "$repo" 94 --body-file "$body_file" 2>&1)"; rc=$?
check 'exits nonzero'    yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'and says on what' yes "$(echo "$out" | grep -q 'cannot read the comment posted on example-org/example-repo#94' && echo yes || echo no)"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
