#!/usr/bin/env bash
# What issue-map prints for a planted set of open issues: an epic with two sub-issues, a blocked
# pair, a chain of three whose smallest label sits at its far end, two issues that name the same
# file among a version, a host, a path off the repository and a file without an extension, issues
# whose labels or blockers GitHub gave only in part, and one issue with no relation, which stands
# alone. Then two repositories of one name under two owners, one with a cut file list; a parent of
# the same name under another owner; and a repository without a commit.
#
# Run with a FAKE gh on PATH. It answers the file list, and the issues one page at a time as GitHub
# does: the second page only where the call asks `--paginate` with a cursor, so a map that drops
# either reads half the issues and goes red.
#
#   bash tests/issue-map.test.sh

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fake="$(mktemp -d)"
trap 'rm -rf "$fake"' EXIT

none='"parent": null, "blockedBy": { "totalCount": 0, "nodes": [] }, "blocking": { "totalCount": 0, "nodes": [] }, "projectItems": { "nodes": [] }'
labels() { printf '"labels": { "totalCount": %s, "nodes": [%s] }' "$1" "${2:-}"; }
ref() { printf '{ "number": %s, "repository": { "nameWithOwner": "%s" } }' "$2" "$1"; }
links() { printf '"totalCount": %s, "nodes": [%s]' "$1" "${2:-}"; }
r=example-org/example-repo

cat > "$fake/tree.json" <<'JSON'
{ "truncated": false, "tree": [ { "path": "bin", "type": "tree" }, { "path": "bin/x.sh", "type": "blob" },
  { "path": "bin/ai-core", "type": "blob" }, { "path": "lib/y.sh", "type": "blob" }, { "path": "README.md", "type": "blob" } ] }
JSON
cat > "$fake/example.1.json" <<JSON
{ "data": { "repository": { "defaultBranchRef": { "name": "master" }, "issues": { "pageInfo": { "hasNextPage": true, "endCursor": "a" }, "nodes": [
  { "number": 1, "title": "Epic", "body": "Holds the two.", $(labels 1 '{ "name": "type:epic" }'),
    "parent": null, "blockedBy": { $(links 0) }, "blocking": { $(links 0) },
    "projectItems": { "nodes": [ { "fieldValueByName": { "name": "Implementing" } } ] } },
  { "number": 2, "title": "First part", "body": "", $(labels 2 '{ "name": "type:feature" }, { "name": "area:tooling" }'),
    "parent": $(ref $r 1), "blockedBy": { $(links 0) }, "blocking": { $(links 0) }, "projectItems": { "nodes": [] } },
  { "number": 3, "title": "Second part", "body": null, $(labels 0),
    "parent": $(ref $r 1), "blockedBy": { $(links 0) }, "blocking": { $(links 0) }, "projectItems": { "nodes": [] } },
  { "number": 4, "title": "Waits", "body": "", $(labels 0), "parent": null,
    "blockedBy": { $(links 2 "$(ref $r 5)") }, "blocking": { $(links 0) }, "projectItems": { "nodes": [] } }
] } } } }
JSON
cat > "$fake/example.2.json" <<JSON
{ "data": { "repository": { "defaultBranchRef": { "name": "master" }, "issues": { "pageInfo": { "hasNextPage": false, "endCursor": "b" }, "nodes": [
  { "number": 5, "title": "Unblocks", "body": "", $(labels 0), "parent": null,
    "blockedBy": { $(links 0) }, "blocking": { $(links 1 "$(ref $r 4)") }, "projectItems": { "nodes": [] } },
  { "number": 6, "title": "Reads the file", "body": "The reader at \`bin/x.sh:10\`, \`lib/y.sh:3-9\` and ./bin/ai-core:4.", $(labels 0), $none },
  { "number": 7, "title": "Writes the file", "body": "The writer at bin/x.sh:20. Released 1.5.79:2 on example.com:8080, see https://example.invalid:443/a and /home/u/bin/x.sh:1.", $(labels 0), $none },
  { "number": 8, "title": "Alone", "body": "No file:line here.", $(labels 3 '{ "name": "type:bug" }'), "parent": null,
    "blockedBy": { $(links 0) }, "blocking": { $(links 0) },
    "projectItems": { "nodes": [ { "fieldValueByName": { "name": "Todo" } } ] } },
  { "number": 97, "title": "Chain start", "body": "", $(labels 0), "parent": null,
    "blockedBy": { $(links 0) }, "blocking": { $(links 1 "$(ref $r 98)") }, "projectItems": { "nodes": [] } },
  { "number": 98, "title": "Chain middle", "body": "", $(labels 0), "parent": null,
    "blockedBy": { $(links 1 "$(ref $r 97)") }, "blocking": { $(links 1 "$(ref $r 100)") }, "projectItems": { "nodes": [] } },
  { "number": 100, "title": "Chain end", "body": "", $(labels 0), "parent": null,
    "blockedBy": { $(links 1 "$(ref $r 98)") }, "blocking": { $(links 0) }, "projectItems": { "nodes": [] } }
] } } } }
JSON
o=other-org/example-repo
cat > "$fake/other.1.json" <<JSON
{ "data": { "repository": { "defaultBranchRef": { "name": "master" }, "issues": { "pageInfo": { "hasNextPage": false, "endCursor": "c" }, "nodes": [
  { "number": 5, "title": "Other five", "body": "", $(labels 0), "parent": $(ref $o 9),
    "blockedBy": { $(links 0) }, "blocking": { $(links 0) }, "projectItems": { "nodes": [] } },
  { "number": 6, "title": "Other six", "body": "", $(labels 0), "parent": $(ref $r 1),
    "blockedBy": { $(links 0) }, "blocking": { $(links 0) }, "projectItems": { "nodes": [] } },
  { "number": 9, "title": "Other epic", "body": "", $(labels 0), $none }
] } } } }
JSON
sed 's/"truncated": false/"truncated": true/' "$fake/tree.json" > "$fake/other-tree.json"
# A repository without a commit: GitHub has no default branch for it and no file list
cat > "$fake/empty.1.json" <<JSON
{ "data": { "repository": { "defaultBranchRef": null, "issues": { "pageInfo": { "hasNextPage": false, "endCursor": "d" }, "nodes": [
  { "number": 1, "title": "Before the first commit", "body": "Write bin/x.sh:1.", $(labels 0), $none } ] } } } }
JSON
cat > "$fake/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"repos/example-org/example-repo/git/trees/"*) cat "$FAKE/tree.json" ;;
  *"repos/other-org/example-repo/git/trees/"*) cat "$FAKE/other-tree.json" ;;
  *graphql*"owner=example-org"*"name=empty-repo"*) cat "$FAKE/empty.1.json" ;;
  *graphql*"owner=example-org"*"name=example-repo"*)
    cat "$FAKE/example.1.json"
    case "$*" in *--paginate*'after:$endCursor'*) cat "$FAKE/example.2.json" ;; esac ;;
  *graphql*"owner=other-org"*"name=example-repo"*) cat "$FAKE/other.1.json" ;;
  *) echo "no such repository" >&2; exit 1 ;;
esac
EOF
chmod +x "$fake/gh"
export PATH="$fake:$PATH" FAKE="$fake"

failed=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}

echo 'the map of the planted set'
out="$(bash "$root/bin/issue-map.sh" example-org/example-repo 2>&1)"; rc=$?
check 'exit 0' 0 "$rc"
check 'the lines, the groups, the shared file and the cut list' "example-repo#1 Implementing epic - | Epic
example-repo#2 - feature tooling | First part | parent example-repo#1
example-repo#3 - - - | Second part | parent example-repo#1
example-repo#4 - - - | Waits | blocked by example-repo#5
example-repo#5 - - - | Unblocks | blocks example-repo#4
example-repo#6 - - - | Reads the file | files bin/ai-core,bin/x.sh,lib/y.sh
example-repo#7 - - - | Writes the file | files bin/x.sh
example-repo#8 Todo bug - | Alone
example-repo#97 - - - | Chain start | blocks example-repo#98
example-repo#98 - - - | Chain middle | blocked by example-repo#97 | blocks example-repo#100
example-repo#100 - - - | Chain end | blocked by example-repo#98
group: example-repo#1 example-repo#2 example-repo#3
group: example-repo#4 example-repo#5
group: example-repo#97 example-repo#98 example-repo#100
file example-repo bin/x.sh: example-repo#6 example-repo#7
cut: example-repo#4 blocked by shows 1 of 2
cut: example-repo#8 labels shows 1 of 3" "$out"

echo 'two repositories of one name'
out="$(bash "$root/bin/issue-map.sh" example-org/example-repo other-org/example-repo 2>&1)"; rc=$?
check 'exit 0' 0 "$rc"
check 'each group keeps to its owner' "group: example-org/example-repo#4 example-org/example-repo#5
group: other-org/example-repo#5 other-org/example-repo#9" "$(grep -E '^group: .*#(4|9)( |$)' <<< "$out")"

check 'a cut file list is named once' 'cut: files of other-org/example-repo: GitHub gave its file list only in part' "$(grep '^cut: files' <<< "$out")"

echo 'one repository whose issue names a parent of the same name under another owner'
out="$(bash "$root/bin/issue-map.sh" other-org/example-repo 2>&1)"
check 'the parent keeps its owner' 'other-org/example-repo#6 - - - | Other six | parent example-org/example-repo#1' "$(grep '#6 ' <<< "$out")"

echo 'a repository without a commit'
out="$(bash "$root/bin/issue-map.sh" example-org/empty-repo 2>&1)"; rc=$?
check 'exit 0' 0 "$rc"
check 'its issue, with no file' 'empty-repo#1 - - - | Before the first commit' "$out"

echo 'a repository gh cannot read'
out="$(bash "$root/bin/issue-map.sh" example-org/missing-repo 2>&1)"; rc=$?
check 'exit non-zero' 1 "$((rc != 0))"
check 'it names what it could not read' yes "$(grep -q 'cannot read the open issues of example-org/missing-repo' <<< "$out" && echo yes || echo no)"

echo 'a wrong argument'
out="$(bash "$root/bin/issue-map.sh" example-repo 2>&1)"; rc=$?
check 'no OWNER/REPO: exit non-zero' 1 "$((rc != 0))"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
