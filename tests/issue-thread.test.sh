#!/usr/bin/env bash
# What issue-thread.sh reads and how it lays the thread out.
#
# Run with a FAKE gh on PATH, so the issue and its comments are fixed text and nothing
# leaves the machine. Two things are pinned: the JSON shape a script reads, and the
# layout a person reads - the comments in the order they were written, each behind a
# line naming its author and its time.
#
#   bash test/issue-thread.test.sh

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fake="$(mktemp -d)"
trap 'rm -rf "$fake"' EXIT
log="$fake/calls.txt"

cat > "$fake/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$log"
case "\$*" in
  *comments*) cat <<'JSON'
[ { "user": { "login": "kadir" }, "created_at": "2026-08-20T09:00:00Z", "body": "First read." },
  { "user": { "login": "anton" }, "created_at": "2026-08-21T11:30:00Z", "body": "Second read." } ]
JSON
    exit 0 ;;
  *"repos/example-org/example-repo/issues/"*) cat <<'JSON'
{ "number": 163, "title": "Carry the value through every renderer", "state": "open",
  "labels": [ { "name": "type:bug" }, { "name": "area:tooling" } ],
  "body": "The reader drops the value." }
JSON
    exit 0 ;;
  *) printf 'example-org/example-repo\n'; exit 0 ;;
esac
EOF
chmod +x "$fake/gh"
export PATH="$fake:$PATH"

failed=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}

thread="$root/bin/issue-thread.sh"
repo='example-org/example-repo'

echo 'both reads reach GitHub, and neither writes'
: > "$log"
"$thread" "$repo" 163 >/dev/null 2>&1
check 'the issue is read'     1 "$(grep -c 'api repos/example-org/example-repo/issues/163$' "$log" || true)"
check 'the comments are read' 1 "$(grep -c -- '--paginate repos/example-org/example-repo/issues/163/comments' "$log" || true)"
check 'nothing was written'   0 "$(grep -cE 'method (POST|PATCH|PUT|DELETE)|mutation' "$log" || true)"

echo 'the json is one object a script can read'
json="$("$thread" "$repo" 163 --json)"
check 'one line'      1 "$(printf '%s\n' "$json" | grep -c . || true)"
check 'number'      163 "$(printf '%s' "$json" | jq -r '.number')"
check 'title'         'Carry the value through every renderer' "$(printf '%s' "$json" | jq -r '.title')"
check 'state'         open "$(printf '%s' "$json" | jq -r '.state')"
check 'labels'        'type:bug area:tooling' "$(printf '%s' "$json" | jq -r '.labels | join(" ")')"
check 'body'          'The reader drops the value.' "$(printf '%s' "$json" | jq -r '.body')"
check 'two comments'  2 "$(printf '%s' "$json" | jq -r '.comments | length')"
check 'first author'  kadir "$(printf '%s' "$json" | jq -r '.comments[0].author')"
check 'first time'    '2026-08-20T09:00:00Z' "$(printf '%s' "$json" | jq -r '.comments[0].created_at')"
check 'second body'   'Second read.' "$(printf '%s' "$json" | jq -r '.comments[1].body')"

# The carriage returns come out before the comparison. jq ends every line with CRLF on
# Windows and with LF everywhere else, so the layout is the same on both and only the
# line terminator is not - comparing the bytes would fail on one platform or the other.
echo 'the plain layout is what a person reads'
out="$("$thread" "$repo" 163 | tr -d '\r')"
expected="$(cat <<'TEXT'
#163 Carry the value through every renderer
state: open
labels: type:bug, area:tooling

The reader drops the value.

--- kadir 2026-08-20T09:00:00Z
First read.

--- anton 2026-08-21T11:30:00Z
Second read.
TEXT
)"
check 'every line, in order' "$expected" "$out"

echo 'the repo resolves from the checkout when left out'
: > "$log"
"$thread" 163 --json >/dev/null 2>&1
check 'default repo' yes "$(grep -q "repos/$repo/issues/163" "$log" && echo yes || echo no)"

# An issue with nothing on it is the case the twins drifted on: an empty label list read
# back as one label that is nothing, so the dash never printed and the JSON carried a null.
echo 'an issue with no label and no comment says so'
bare="$fake/bare"
mkdir -p "$bare"
cat > "$bare/gh" <<'BARE'
#!/usr/bin/env bash
case "$*" in
  *comments*) echo '[]'; exit 0 ;;
  *issues/*)  echo '{"number":7,"title":"Bare","state":"closed","labels":[],"body":null}'; exit 0 ;;
  *) printf 'example-org/example-repo\n'; exit 0 ;;
esac
BARE
chmod +x "$bare/gh"
check 'labels read as a dash' 'labels: -' \
  "$(PATH="$bare:$PATH" "$thread" "$repo" 7 | tr -d '\r' | sed -n '3p')"
check 'the json carries an empty list' \
  '{"number":7,"title":"Bare","state":"closed","labels":[],"body":"","comments":[]}' \
  "$(PATH="$bare:$PATH" "$thread" "$repo" 7 --json | tr -d '\r')"

# A real thread on an epic runs to tens of kilobytes. Handed to jq as an argument it dies with
# "Argument list too long" - on exactly the issues worth reading - so it travels through a pipe.
echo 'a comment larger than one command-line argument is read whole'
big="$fake/big"
mkdir -p "$big"
long="$(head -c 50000 /dev/zero | tr '\0' 'y')"
printf '[{"user":{"login":"kadir"},"created_at":"2026-08-20T09:00:00Z","body":"%s"}]\n' "$long" \
  > "$fake/big-comments.json"
cat > "$big/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *comments*) cat "$fake/big-comments.json"; exit 0 ;;
  *issues/*)  echo '{"number":8,"title":"Long","state":"open","labels":[],"body":"short"}'; exit 0 ;;
  *) printf 'example-org/example-repo\n'; exit 0 ;;
esac
EOF
chmod +x "$big/gh"
check 'the whole body came through' 50000 \
  "$(PATH="$big:$PATH" "$thread" "$repo" 8 --json | jq -r '.comments[0].body | length')"

# The team's texts use the em dash everywhere. Both twins print UTF-8, so the same thread reads
# the same from either of them.
echo 'an em dash comes out as an em dash'
dashed="$fake/dashed"
mkdir -p "$dashed"
cat > "$dashed/gh" <<'DASH'
#!/usr/bin/env bash
case "$*" in
  *comments*) echo '[{"user":{"login":"kadir"},"created_at":"2026-08-20T09:00:00Z","body":"one — two"}]'; exit 0 ;;
  *issues/*)  echo '{"number":9,"title":"Dashed","state":"open","labels":[],"body":"a — b"}'; exit 0 ;;
  *) printf 'example-org/example-repo\n'; exit 0 ;;
esac
DASH
chmod +x "$dashed/gh"
check 'in the body'    'a — b'     "$(PATH="$dashed:$PATH" "$thread" "$repo" 9 | tr -d '\r' | sed -n '5p')"
check 'in a comment'   'one — two' "$(PATH="$dashed:$PATH" "$thread" "$repo" 9 | tr -d '\r' | sed -n '8p')"

# A refused read is not an empty issue. gh writes its error body to stdout, which jq would
# take for the issue, so the read goes through gh_read and the run stops.
echo 'a refused read stops the run rather than printing an empty issue'
refusing="$fake/refusing"
mkdir -p "$refusing"
cat > "$refusing/gh" <<'NO'
#!/usr/bin/env bash
case "$*" in
  *issues/*) echo '{"message":"Not Found"}'; echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
  *) printf 'example-org/example-repo\n'; exit 0 ;;
esac
NO
chmod +x "$refusing/gh"
out="$(PATH="$refusing:$PATH" "$thread" "$repo" 404 2>&1)" && rc=0 || rc=$?
check 'exits nonzero' yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'and says what could not be read' yes \
  "$(printf '%s\n' "$out" | grep -q 'cannot read the issue example-org/example-repo#404' && echo yes || echo no)"

echo 'a call with no number is refused'
out="$("$thread" 2>&1)" && rc=0 || rc=$?
check 'exits nonzero' yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
out="$("$thread" "$repo" not-a-number 2>&1)" && rc=0 || rc=$?
check 'a number that is not one is refused' yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
