#!/usr/bin/env bash
# What issue-edit.sh sends, and what it refuses before it sends anything.
#
# Run with a FAKE gh on PATH, so nothing is edited and every call is recorded instead. What is
# pinned: only the fields the caller named are sent, the body travels as a FILE reference so no
# shell reads its backticks and newlines on the way, and an edit that changes nothing or names a
# file that is not there stops before GitHub is reached.
#
# AND THE ASKED-FOR LINE SURVIVES THE EDIT, which is the reason the fake answers a READ as well
# as recording the write: the issue's own first line is what gets put back, so a test that could
# not answer that read could not tell keeping the line from composing one.
#
#   bash test/issue-edit.test.sh

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fake="$(mktemp -d)"
trap 'rm -rf "$fake"' EXIT
log="$fake/calls.txt"
# What the fake answers a read with, and where it keeps the body file it was handed - the tool
# deletes its temporary body the moment the call returns, so a copy is the only way to see it.
reply="$fake/reply.txt"; printf '{}\n' > "$reply"
sent="$fake/sent-body.md"

cat > "$fake/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
if [ "\$1" = "repo" ]; then echo 'example-org/example-repo'; exit 0; fi
case "\$*" in
  *--method\ PATCH*)
    for a in "\$@"; do case "\$a" in body=@*) cp "\${a#body=@}" "$sent" ;; esac; done
    echo '{}'; exit 0 ;;
esac
cat "$reply"
exit 0
EOF
chmod +x "$fake/gh"
export PATH="$fake:$PATH"

failed=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}

edit="$root/bin/issue-edit.sh"
repo='example-org/example-repo'
body="$fake/body.md"; printf 'A body with a `backtick` in it.\n' > "$body"

echo 'a title alone sends the title and nothing else'
: > "$log"
out="$("$edit" "$repo" 163 --title 'Read the board whole, or the count is a guess' 2>/dev/null)"
check 'what it says'   '#163 -> edited (title)' "$out"
check 'the method'     yes "$(grep -q "api --method PATCH repos/$repo/issues/163" "$log" && echo yes || echo no)"
check 'the title'      yes "$(grep -q -- '-f title=Read the board whole' "$log" && echo yes || echo no)"
check 'no body sent'   no  "$(grep -q -- '-F body=' "$log" && echo yes || echo no)"
check 'the issue is not read' no "$(grep -q -- '--jq .body' "$log" && echo yes || echo no)"

echo 'a body alone travels as a file reference'
: > "$log"
out="$("$edit" "$repo" 163 --body-file "$body" 2>/dev/null)"
check 'what it says'    '#163 -> edited (body)' "$out"
check 'the file'        yes "$(grep -q -- "-F body=@$body" "$log" && echo yes || echo no)"
check 'no title sent'   no  "$(grep -q -- '-f title=' "$log" && echo yes || echo no)"
check 'not its content' no  "$(grep -q 'backtick' "$log" && echo yes || echo no)"

echo 'both together are one call'
: > "$log"
out="$("$edit" "$repo" 163 --title t --body-file "$body" 2>/dev/null)"
check 'what it says'   '#163 -> edited (title and body)' "$out"
check 'one PATCH'      1 "$(grep -c 'api --method PATCH' "$log" || true)"

echo 'the repo resolves from the checkout when left out'
: > "$log"
"$edit" 163 --title t >/dev/null 2>&1
check 'default repo' yes "$(grep -q "repos/$repo/issues/163" "$log" && echo yes || echo no)"

# THE ASKED-FOR LINE. The three cases below are the whole guarantee: a body without it, a body
# with it, and an issue that never had one. The reply file is what the fake answers a read with,
# and it carries CRLF because that is what GitHub writes an issue body back with.
asked='Asked for by @kartalbas on 2026-09-04 in the chat session of 2026-09-04.'
plain="$fake/plain.md";    printf 'A rewritten body.\n' > "$plain"
carrying="$fake/carrying.md"; printf '%s\n\nA rewritten body.\n' "$asked" > "$carrying"

echo 'a body without the asked-for line keeps the line the issue carries'
: > "$log"; rm -f "$sent"
printf '%s\r\n\r\nthe old body\r\n' "$asked" > "$reply"
out="$("$edit" "$repo" 163 --body-file "$plain" 2>/dev/null)"
check 'what it says'      '#163 -> edited (body, asked-for line kept)' "$out"
check 'the issue is read' yes "$(grep -q -- "api repos/$repo/issues/163 --jq .body" "$log" && echo yes || echo no)"
check 'the line is back on top'  "$asked"           "$(head -1 "$sent")"
check 'the new body follows'     'A rewritten body.' "$(sed -n '3p' "$sent")"
check 'one copy of the line'     1 "$(grep -c 'Asked for by' "$sent" || true)"
check "the caller's file is left as it was" 'A rewritten body.' "$(cat "$plain")"
check 'the caller path is not the one sent' no "$(grep -q -- "-F body=@$plain" "$log" && echo yes || echo no)"

echo 'a body that already carries the line is sent untouched, and the issue is never read'
: > "$log"; rm -f "$sent"
out="$("$edit" "$repo" 163 --body-file "$carrying" 2>/dev/null)"
check 'what it says'          '#163 -> edited (body)' "$out"
check 'the issue is not read' no  "$(grep -q -- '--jq .body' "$log" && echo yes || echo no)"
check 'the file itself'       yes "$(grep -q -- "-F body=@$carrying" "$log" && echo yes || echo no)"
check 'no second copy of the line' 1 "$(grep -c 'Asked for by' "$sent" || true)"

echo 'an issue carrying no asked-for line is reported, and the body goes as given'
: > "$log"; rm -f "$sent"
printf 'An issue opened on the web.\n' > "$reply"
out="$("$edit" "$repo" 163 --body-file "$plain" 2>&1)"
check 'says there is none to keep' yes "$(echo "$out" | grep -q 'carries no asked-for line' && echo yes || echo no)"
check 'the edit still happened'    yes "$(echo "$out" | grep -q -- '#163 -> edited (body)' && echo yes || echo no)"
check 'the file itself'            yes "$(grep -q -- "-F body=@$plain" "$log" && echo yes || echo no)"
printf '{}\n' > "$reply"

echo 'an edit that changes nothing stops before GitHub is reached'
: > "$log"
out="$("$edit" "$repo" 163 2>&1)"; rc=$?
check 'exits nonzero'  yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'says what to name' yes "$(echo "$out" | grep -q 'an edit that changes nothing is a mistake' && echo yes || echo no)"
check 'nothing sent'   0 "$(grep -c . "$log" || true)"

echo 'a body file that is not there stops before GitHub is reached'
: > "$log"
out="$("$edit" "$repo" 163 --body-file "$fake/nope.md" 2>&1)"; rc=$?
check 'exits nonzero'     yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'the file is named' yes "$(echo "$out" | grep -q "does not exist: $fake/nope.md" && echo yes || echo no)"
check 'nothing sent'      0 "$(grep -c . "$log" || true)"

echo 'the glued form of a flag is refused rather than half-read'
out="$("$edit" "$repo" 163 --title=t 2>&1)"; rc=$?
check 'exits nonzero'  yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'says why'       yes "$(echo "$out" | grep -q 'separate the flag and its value' && echo yes || echo no)"

echo 'a misspelt flag is refused, never filed under the numbers'
out="$("$edit" "$repo" 163 --titel t 2>&1)"; rc=$?
check 'exits nonzero'  yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'names the word' yes "$(echo "$out" | grep -q -- '--titel' && echo yes || echo no)"

echo 'a refused PATCH stops the run rather than reporting an edit'
refusing="$fake/refusing"
mkdir -p "$refusing"
cat > "$refusing/gh" <<'NO'
#!/usr/bin/env bash
if [ "$1" = "repo" ]; then echo 'example-org/example-repo'; exit 0; fi
echo '{"message":"Validation Failed"}'
echo 'gh: HTTP 422' >&2
exit 1
NO
chmod +x "$refusing/gh"
out="$(PATH="$refusing:$PATH" "$edit" "$repo" 163 --title t 2>&1)"; rc=$?
check 'exits nonzero'      yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'no edited line'     no  "$(echo "$out" | grep -q '\-> edited' && echo yes || echo no)"

# The one failure mode keeping the line adds: the read before the write. It stops the edit,
# because the other way out is sending a body known to be missing the line.
echo 'a refused READ stops the edit rather than sending the body without the line'
out="$(PATH="$refusing:$PATH" "$edit" "$repo" 163 --body-file "$plain" 2>&1)"; rc=$?
check 'exits nonzero'      yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'names what it is'   yes "$(echo "$out" | grep -q "cannot read the body of $repo#163" && echo yes || echo no)"
check 'no edited line'     no  "$(echo "$out" | grep -q '\-> edited' && echo yes || echo no)"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
