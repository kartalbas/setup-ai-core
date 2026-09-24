#!/usr/bin/env bash
# The state machine behind status-sync.sh: which signal moves a card, and how far.
#
# The sweep itself is not driven here - the decision is, because that is where the rules live.
# The script stops before the sweep when it is SOURCED, so derive_target can be called directly
# and no board is reached at all.
#
#   bash test/status-sync.test.sh

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failed=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: [$2]"; echo "       actual:   [$3]"; failed=$((failed + 1)); fi
}

# Source the sweep for its functions only - the guard stops it running.
# shellcheck source=/dev/null
. "$ROOT/bin/status-sync.sh"

# derive_target <current> <on_master> <released> <is_epic>
echo 'a commit on master moves a card to testing'
check 'from todo'         'testing' "$(derive_target todo 1 0 0)"
check 'from backlog'      'testing' "$(derive_target backlog 1 0 0)"
check 'from implementing' 'testing' "$(derive_target implementing 1 0 0)"

echo 'a commit carried by the newest tag closes the issue'
check 'from todo'         'CLOSE' "$(derive_target todo 1 1 0)"
check 'from implementing' 'CLOSE' "$(derive_target implementing 1 1 0)"
check 'from testing'      'CLOSE' "$(derive_target testing 1 1 0)"

echo 'it never moves a card backward'
check 'testing stays testing'      '' "$(derive_target testing 1 0 0)"
check 'done stays done'            '' "$(derive_target done 1 1 0)"

# The card is put in implementing by start-issue, at the moment the worktree is opened. That
# column is a person's statement, so the sweep never writes it and never reads a worktree.
echo 'an open worktree is not a signal, so nothing moves without a commit on master'
check 'nothing at all'             '' "$(derive_target todo 0 0 0)"
check 'a tag without the commit'   '' "$(derive_target todo 0 1 0)"
check 'implementing stays where a person put it' '' "$(derive_target implementing 0 0 0)"

echo 'it never moves an epic, whatever the signal'
check 'epic with a released commit' '' "$(derive_target todo 1 1 1)"
check 'epic with a commit on master' '' "$(derive_target todo 1 0 1)"

echo 'the ranks are what forbid a backward move'
check 'backlog'      0 "$(status_rank backlog)"
check 'todo'         0 "$(status_rank todo)"
check 'implementing' 1 "$(status_rank implementing)"
check 'testing'      2 "$(status_rank testing)"
check 'done'         3 "$(status_rank done)"
check 'CLOSE is done' 3 "$(status_rank CLOSE)"

# --- the signal path, driven end to end against a stand-in gh -----------------
#
# The decision above is pure, and everything that FEEDS it is not. The timeline query that finds
# the newest commit naming an issue, the two `compare/<ref>...<sha>` reads that say whether a ref
# carries it, the board list and the memo are what a change breaks, and a suite that only calls
# derive_target cannot tell the two twins apart on any of them.
#
# NOTHING REACHES github.com. A stand-in `gh` on PATH answers the board, the signals of each
# issue, the default branch, the tag list and each compare, and writes down every call it was
# given, so the READS are held as well as the two lines the sweep prints.
#
# THE TWO PLANTED CARDS, one per signal:
#   #12 implementing, its commit behind master and not in the tag   -> would move to testing
#   #13 todo, its commit behind master and identical to the tag     -> would close, released
#   #14 todo, an epic with ONE sub-issue and no commit             -> named, not moved
#
# lib/board.sh, which the source above brought in, carries `set -e`. An assertion that counts
# zero matches exits non-zero, and under `set -e` that ends this test instead of failing it.
set +e

FAKE="$(mktemp -d)"
export GH_CACHE_DIRECTORY="$FAKE/cache"
PROJECT_NUMBER=999995
PROJECT_ID='PVT_kwstatussync'
trap 'rm -rf "$FAKE"' EXIT
mkdir -p "$GH_CACHE_DIRECTORY/$PROJECT_NUMBER"
printf '%s\n' "$PROJECT_ID" > "$GH_CACHE_DIRECTORY/$PROJECT_NUMBER/project-id"

printf '{"data":{"organization":{"projectV2":{"id":"%s"}}}}\n' "$PROJECT_ID" > "$FAKE/project-id.json"

card() {  # card <number> <title> <status>
  printf '{"fieldValues":{"nodes":[{"name":"%s","field":{"name":"Status"}}]},"content":{"number":%s,"title":"%s","state":"OPEN","repository":{"name":"example-repo"}}}' \
    "$3" "$1" "$2"
}
printf '{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[%s,%s,%s]}}}}\n' \
  "$(card 12 'A commit of its own is on master' implementing)" \
  "$(card 13 'A commit of its own is in the newest tag' todo)" \
  "$(card 14 'An epic with one child' todo)" > "$FAKE/board.json"

# One REFERENCED_EVENT, from a commit in the issue's own repository, after no reopening.
signals() {  # signals <sha>
  printf '{"data":{"repository":{"issue":{"state":"OPEN","subIssuesSummary":{"total":0},"reopened":{"nodes":[]},"timelineItems":{"nodes":[{"createdAt":"2026-09-01T10:00:00Z","isCrossRepository":false,"commit":{"oid":"%s","committedDate":"2026-09-01T10:00:00Z"}}]}}}}}\n' "$1"
}
signals sha12 > "$FAKE/signals-12.json"
signals sha13 > "$FAKE/signals-13.json"
printf '%s\n' '{"data":{"repository":{"issue":{"state":"OPEN","subIssuesSummary":{"total":1},"reopened":{"nodes":[]},"timelineItems":{"nodes":[]}}}}}' > "$FAKE/signals-14.json"
printf '{"default_branch":"master"}\n' > "$FAKE/repo.json"
printf '[{"name":"0.8.100"}]\n'        > "$FAKE/tags.json"
printf '{"status":"behind"}\n'         > "$FAKE/compare-master-sha12.json"
printf '{"status":"ahead"}\n'          > "$FAKE/compare-tag-sha12.json"
printf '{"status":"behind"}\n'         > "$FAKE/compare-master-sha13.json"
printf '{"status":"identical"}\n'      > "$FAKE/compare-tag-sha13.json"

# The stand-in RUNS the --jq program the caller gave, the way gh does. Answering the raw
# document instead would let a script that never reads its answer pass.
mkdir -p "$FAKE/bin"
cat > "$FAKE/bin/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$FAKE/calls.txt"
prog=""; prev=""
for a in "\$@"; do
  [ "\$prev" = "--jq" ] && prog="\$a"
  prev="\$a"
done
case "\$*" in
  *"projectV2(number:"*)             doc="$FAKE/project-id.json" ;;
  *"items(first:100, after:"*)       doc="$FAKE/board.json" ;;
  *"num=12"*)                        doc="$FAKE/signals-12.json" ;;
  *"num=13"*)                        doc="$FAKE/signals-13.json" ;;
  *"num=14"*)                        doc="$FAKE/signals-14.json" ;;
  *"compare/master...sha12"*)        doc="$FAKE/compare-master-sha12.json" ;;
  *"compare/0.8.100...sha12"*)       doc="$FAKE/compare-tag-sha12.json" ;;
  *"compare/master...sha13"*)        doc="$FAKE/compare-master-sha13.json" ;;
  *"compare/0.8.100...sha13"*)       doc="$FAKE/compare-tag-sha13.json" ;;
  *"/tags"*)                         doc="$FAKE/tags.json" ;;
  *"repos/example-org/example-repo"*) doc="$FAKE/repo.json" ;;
  *) echo "the stand-in gh has no answer for: \$*" >&2; exit 9 ;;
esac
# The jq BINARY writes CRLF on Windows where gh's own --jq writes LF, and stripping it is what
# makes the stand-in answer the way gh does.
if [ -n "\$prog" ]; then jq -r "\$prog" < "\$doc" | tr -d '\r'
else cat "\$doc"; fi
exit 0
EOF
chmod +x "$FAKE/bin/gh"
export PATH="$FAKE/bin:$PATH"

echo 'the sweep, driven against a stand-in gh: one card per signal'
run="$(bash "$ROOT/bin/status-sync.sh" --project "$PROJECT_NUMBER" --dry-run 2>&1)"
rc=$?
check 'exit 0' 0 "$rc"
check 'a commit on master would move the card to testing' \
  'would move   example-repo#12  (implementing -> testing)' \
  "$(grep '^would move' <<< "$run")"
check 'a commit the newest tag carries would close the issue' \
  'would close  example-repo#13  (todo -> done, released in 0.8.100)' \
  "$(grep '^would close' <<< "$run")"
check 'an epic with one sub-issue is named and not moved' \
  'one child    example-repo#14  (an epic with a single sub-issue is a plain issue, rules.md section 8)' \
  "$(grep '^one child' <<< "$run")"
check 'and the count says what it read' \
  "3 active cards scanned, 2 would move on board $PROJECT_NUMBER." \
  "$(printf '%s\n' "$run" | tail -1)"

echo 'the compare is asked once per question, with the ref as base and the commit as head'
check 'is the commit of #12 on master'      1 "$(grep -cF 'compare/master...sha12' "$FAKE/calls.txt")"
check 'is it in the newest tag'             1 "$(grep -cF 'compare/0.8.100...sha12' "$FAKE/calls.txt")"
check 'is the commit of #13 on master'      1 "$(grep -cF 'compare/master...sha13' "$FAKE/calls.txt")"
check 'is it in the newest tag'             1 "$(grep -cF 'compare/0.8.100...sha13' "$FAKE/calls.txt")"

# The memo exists so a board of two hundred cards in one repository does not ask for the same
# default branch two hundred times. Written inside a function that is only ever called as
# `$( … )`, it filled a subshell that ended a moment later and answered nothing.
echo 'the memo answers: one read per repository for the run, not one per card'
check 'the default branch, once for both cards' 1 \
  "$(grep -cF 'repos/example-org/example-repo --jq .default_branch' "$FAKE/calls.txt")"
check 'the tag list, once for both cards' 1 \
  "$(grep -cF 'repos/example-org/example-repo/tags' "$FAKE/calls.txt")"

echo
if [ "$failed" -gt 0 ]; then echo "$failed failed"; exit 1; fi
echo 'all passed'
