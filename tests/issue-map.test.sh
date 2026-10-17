#!/usr/bin/env bash
# What issue-map prints for a planted set of open issues: an epic with two sub-issues, a blocked
# pair, two issues that name the same file, and one issue with no relation, which stands alone.
#
# Run with a FAKE gh on PATH that answers the one GraphQL query with fixed pages, so nothing leaves
# the machine.
#
#   bash tests/issue-map.test.sh

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fake="$(mktemp -d)"
trap 'rm -rf "$fake"' EXIT

# Two pages, as `gh api graphql --paginate` prints them: one JSON document after the other
cat > "$fake/page.json" <<'JSON'
{ "data": { "repository": { "issues": { "pageInfo": { "hasNextPage": true, "endCursor": "a" }, "nodes": [
  { "number": 1, "title": "Epic", "body": "Holds the two.", "labels": { "nodes": [ { "name": "type:epic" } ] },
    "parent": null, "blockedBy": { "nodes": [] }, "blocking": { "nodes": [] },
    "projectItems": { "nodes": [ { "fieldValueByName": { "name": "Implementing" } } ] } },
  { "number": 2, "title": "First part", "body": "", "labels": { "nodes": [ { "name": "type:feature" }, { "name": "area:tooling" } ] },
    "parent": { "number": 1, "repository": { "name": "example-repo" } }, "blockedBy": { "nodes": [] }, "blocking": { "nodes": [] },
    "projectItems": { "nodes": [] } },
  { "number": 3, "title": "Second part", "body": null, "labels": { "nodes": [] },
    "parent": { "number": 1, "repository": { "name": "example-repo" } }, "blockedBy": { "nodes": [] }, "blocking": { "nodes": [] },
    "projectItems": { "nodes": [] } },
  { "number": 4, "title": "Waits", "body": "", "labels": { "nodes": [] }, "parent": null,
    "blockedBy": { "nodes": [ { "number": 5, "repository": { "name": "example-repo" } } ] }, "blocking": { "nodes": [] },
    "projectItems": { "nodes": [] } }
] } } } }
{ "data": { "repository": { "issues": { "pageInfo": { "hasNextPage": false, "endCursor": "b" }, "nodes": [
  { "number": 5, "title": "Unblocks", "body": "", "labels": { "nodes": [] }, "parent": null,
    "blockedBy": { "nodes": [] }, "blocking": { "nodes": [ { "number": 4, "repository": { "name": "example-repo" } } ] },
    "projectItems": { "nodes": [] } },
  { "number": 6, "title": "Reads the file", "body": "The reader at `bin/x.sh:10` and `lib/y.sh:3-9`.", "labels": { "nodes": [] }, "parent": null,
    "blockedBy": { "nodes": [] }, "blocking": { "nodes": [] }, "projectItems": { "nodes": [] } },
  { "number": 7, "title": "Writes the file", "body": "The writer at bin/x.sh:20; see https://example.invalid/a.", "labels": { "nodes": [] }, "parent": null,
    "blockedBy": { "nodes": [] }, "blocking": { "nodes": [] }, "projectItems": { "nodes": [] } },
  { "number": 8, "title": "Alone", "body": "No file:line here.", "labels": { "nodes": [ { "name": "type:bug" } ] }, "parent": null,
    "blockedBy": { "nodes": [] }, "blocking": { "nodes": [] },
    "projectItems": { "nodes": [ { "fieldValueByName": { "name": "Todo" } } ] } }
] } } } }
JSON
cat > "$fake/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"name=example-repo"*) cat "$fake/page.json" ;;
  *) echo "no such repository" >&2; exit 1 ;;
esac
EOF
chmod +x "$fake/gh"
export PATH="$fake:$PATH"

failed=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}

echo 'the map of the planted set'
out="$(bash "$root/bin/issue-map.sh" example-org/example-repo 2>&1)"; rc=$?
check 'exit 0' 0 "$rc"
check 'the lines, the group and the shared file' "example-repo#1 Implementing epic - | Epic
example-repo#2 - feature tooling | First part | parent example-repo#1
example-repo#3 - - - | Second part | parent example-repo#1
example-repo#4 - - - | Waits | blocked by example-repo#5
example-repo#5 - - - | Unblocks | blocks example-repo#4
example-repo#6 - - - | Reads the file | files bin/x.sh,lib/y.sh
example-repo#7 - - - | Writes the file | files bin/x.sh
example-repo#8 Todo bug - | Alone
group: example-repo#1 example-repo#2 example-repo#3
group: example-repo#4 example-repo#5
file bin/x.sh: example-repo#6 example-repo#7" "$out"
check 'the issue alone is in no group' '' "$(grep '^group:.*#8' <<< "$out")"

echo 'a repository gh cannot read'
out="$(bash "$root/bin/issue-map.sh" example-org/other-repo 2>&1)"; rc=$?
check 'exit non-zero' 1 "$((rc != 0))"
check 'it names what it could not read' yes "$(grep -q 'cannot read the open issues of example-org/other-repo' <<< "$out" && echo yes || echo no)"

echo 'a wrong argument'
out="$(bash "$root/bin/issue-map.sh" example-repo 2>&1)"; rc=$?
check 'no OWNER/REPO: exit non-zero' 1 "$((rc != 0))"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
