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

# derive_target <current> <on_master> <released> <is_epic> <proven>
echo 'a commit on master alone moves nothing: it touches the issue, it does not finish it'
check 'from todo'         '' "$(derive_target todo 1 0 0)"
check 'from backlog'      '' "$(derive_target backlog 1 0 0)"
check 'from implementing' '' "$(derive_target implementing 1 0 0)"

echo 'a released and proven commit closes only a card finish-issue moved to testing'
check 'from testing'      'CLOSE' "$(derive_target testing 1 1 0 1)"
check 'the board spells it Testing' 'CLOSE' "$(derive_target Testing 1 1 0 1)"
check 'not from todo'     '' "$(derive_target todo 1 1 0 1)"
check 'not from implementing, whose work may land in more steps' '' "$(derive_target implementing 1 1 0 1)"

echo 'a release is not a proof'
check 'released, no proof record'  '' "$(derive_target testing 1 1 0 0)"
check 'proven, not released'       '' "$(derive_target testing 1 0 0 1)"

echo 'it never moves a card backward'
check 'testing stays testing'      '' "$(derive_target testing 1 0 0)"
check 'done stays done'            '' "$(derive_target done 1 1 0 1)"

# The card is put in implementing by start-issue, at the moment the worktree is opened. That
# column is a person's statement, so the sweep never writes it and never reads a worktree.
echo 'an open worktree is not a signal, so nothing moves without a commit on master'
check 'nothing at all'             '' "$(derive_target todo 0 0 0)"
check 'a tag without the commit'   '' "$(derive_target todo 0 1 0)"
check 'implementing stays where a person put it' '' "$(derive_target implementing 0 0 0)"

echo 'no commit moves an epic, whatever the signal: an epic follows its sub-issues'
check 'epic with a released commit' '' "$(derive_target todo 1 1 1 1)"
check 'epic with a commit on master' '' "$(derive_target todo 1 0 1)"

echo 'the ranks are what forbid a backward move'
check 'backlog'      0 "$(status_rank backlog)"
check 'todo'         0 "$(status_rank todo)"
check 'implementing' 1 "$(status_rank implementing)"
check 'testing'      2 "$(status_rank testing)"
check 'done'         3 "$(status_rank done)"
check 'CLOSE is done' 3 "$(status_rank CLOSE)"

# --- the signal path, driven end to end against a stand-in gh and a real clone ----
#
# The decision above is pure, and everything that FEEDS it is not: the one query per repository
# that reads its open issues with their cards and comments, the clone the release is read from,
# and the board that is read only when no repository is named. A suite that only calls
# derive_target cannot tell the two twins apart on any of them.
#
# NOTHING REACHES github.com. A stand-in `gh` on PATH answers the board and the issues of each
# repository and writes down every call. The clone is a real git repository whose origin is a
# bare one named .../example-org/example-repo.git, with these commits and tags, oldest first:
#   abc13 deploy/prod/1 (LIVE_TAGS' first environment) ... abc18 deploy/prod/2 and 0.1-newest,
#         the newest tag by date and the last of all by name
#   abc19 deploy/test/9, the newest by date but for 0.1-newest
#   abc20 on master, in no tag
#
# THE PLANTED CARDS, one per case:
#   #12 implementing, its commit on master                          -> stays
#   #13 testing, in deploy/prod/1, a "Proven on" record after it    -> would close
#   #14 todo, an epic with ONE sub-issue                            -> named, follows it
#   #15 todo, a repository of another organisation                  -> read under its owner
#   #16 testing, reopened after its work landed                     -> stays
#   #17 testing, moved by hand: no "Landed on" record               -> stays
#   #18 testing, in deploy/prod/2, no proof record                  -> proof due, stays
#   #19 testing, in deploy/test/9 only, proven                      -> stays: no production release
#   #20 testing, on master in no tag, proven, on the second page    -> stays
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

# The clone and its origin. Commit and tag dates are set, so "newest by date" is not left to the
# speed of the machine.
gitc() { git -C "$1" -c user.name=check -c user.email=check@localhost "${@:2}"; }
commit_at() {  # commit_at <dir> <unix time> <subject>
  echo "$3" > "$1/$2.txt"; git -C "$1" add -A
  GIT_AUTHOR_DATE="@$2 +0000" GIT_COMMITTER_DATE="@$2 +0000" gitc "$1" commit -q -m "$3"
  git -C "$1" rev-parse HEAD
}
tag_at() { GIT_COMMITTER_DATE="@$3 +0000" gitc "$1" tag -a -m "$2" "$2"; }  # tag_at <dir> <tag> <unix time>
origin="$FAKE/remote/example-org/example-repo.git"; seed="$FAKE/seed"; clone="$FAKE/folder/example-repo"
git init -q --bare "$origin"; git init -q "$seed"; git -C "$seed" checkout -q -b master
c12="$(commit_at "$seed" 1700000012 'Work of #12')"
c13="$(commit_at "$seed" 1700000013 'Land #13')"; tag_at "$seed" deploy/prod/1 1700000013
c16="$(commit_at "$seed" 1700000016 'Land #16')"
c18="$(commit_at "$seed" 1700000018 'Land #18')"; tag_at "$seed" deploy/prod/2 1700000018; tag_at "$seed" 0.1-newest 1700000099
c19="$(commit_at "$seed" 1700000019 'Land #19')"; tag_at "$seed" deploy/test/9 1700000019
c20="$(commit_at "$seed" 1700000020 'Land #20')"
git -C "$seed" push -q "$origin" master --tags
git -C "$origin" symbolic-ref HEAD refs/heads/master
mkdir -p "$FAKE/folder"; git clone -q "$origin" "$clone"
# The tags reach the clone through the fetch status-sync makes, not through the clone
git -C "$clone" tag -l | xargs -r git -C "$clone" tag -d >/dev/null
mkdir -p "$clone/.ai-core"; printf 'LIVE_TAGS="prod=deploy/prod/* test=deploy/test/*"\n' > "$clone/.ai-core/config.env"

card() {  # card <number> <title> <status> [owner]: a card as board-list reads it
  printf '{"fieldValues":{"nodes":[{"name":"%s","field":{"name":"Status"}}]},"content":{"number":%s,"title":"%s","state":"OPEN","repository":{"name":"example-repo","nameWithOwner":"%s/example-repo"}}}' \
    "$3" "$1" "$2" "${4:-example-org}"
}
printf '{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[%s,%s]}}}}\n' \
  "$(card 12 'A commit of its own is on master' implementing)" \
  "$(card 15 'An issue of another organisation on this board' todo other-org)" > "$FAKE/board.json"

# An open issue as the query of one repository reads it: its card on this board and on another
landed() { printf '{"createdAt":"%s","body":"Landed on master:\\n\\n- %s Its subject\\n- 1111111 an older commit"}' "$1" "$(printf '%s' "$2" | cut -c1-7)"; }
proven() { printf '{"createdAt":"%s","body":"Proven on prod:\\n\\n- TC-1 PASS"}' "$1"; }
# The card of board 5 and the one of a board numbered like this one under another owner are not
# this board's
issue() {  # issue <number> <status> <sub-issues> <comments> [reopened at]
  printf '{"number":%s,"subIssuesSummary":{"total":%s},"projectItems":{"nodes":[{"project":{"number":5,"owner":{"login":"example-org"}},"status":{"name":"done"}},{"project":{"number":%s,"owner":{"login":"other-org"}},"status":{"name":"done"}},{"project":{"number":%s,"owner":{"login":"example-org"}},"status":{"name":"%s"}}]},"reopened":{"nodes":[%s]},"comments":{"nodes":[%s]}}' \
    "$1" "$3" "$PROJECT_NUMBER" "$PROJECT_NUMBER" "$2" "${5:+{\"createdAt\":\"$5\"\}}" "$4"
}
page() { printf '{"data":{"repository":{"issues":{"pageInfo":{"hasNextPage":%s,"endCursor":%s},"nodes":[%s]}}}}\n' "$1" "$2" "$3"; }
page true '"c1"' "$(issue 12 implementing 0 "$(landed 2026-09-01T10:00:00Z "$c12")"),$(issue 13 testing 0 "$(landed 2026-08-01T10:00:00Z 0000000),$(landed 2026-09-01T10:00:00Z "$c13"),$(proven 2026-09-02T10:00:00Z),{\"createdAt\":\"2026-09-03T10:00:00Z\",\"body\":\"Looks good, see 2222222\"}"),$(issue 14 todo 1 ''),$(issue 16 testing 0 "$(landed 2026-09-01T10:00:00Z "$c16"),$(proven 2026-09-02T10:00:00Z)" 2026-09-05T10:00:00Z),$(issue 17 testing 0 '{"createdAt":"2026-09-01T10:00:00Z","body":"Done in\n- abc1717 by hand"}')" > "$FAKE/issues-1.json"
page false null "$(issue 18 testing 0 "$(proven 2026-08-30T10:00:00Z),$(landed 2026-09-01T10:00:00Z "$c18")"),$(issue 19 testing 0 "$(landed 2026-09-01T10:00:00Z "$c19"),$(proven 2026-09-02T10:00:00Z)"),$(issue 20 testing 0 "$(landed 2026-09-01T10:00:00Z "$c20"),$(proven 2026-09-02T10:00:00Z)"),$(issue 21 '' 0 '')" > "$FAKE/issues-2.json"
page false null "$(issue 15 todo 0 '')" > "$FAKE/issues-other.json"
# #14's one sub-issue was moved to testing by hand on the board; the epic itself stands in todo
printf '%s\n' '{"data":{"repository":{"issue":{"state":"OPEN","projectItems":{"nodes":[{"project":{"number":999995,"owner":{"login":"example-org"}},"status":{"name":"todo"}}]},"subIssues":{"nodes":[{"state":"OPEN","projectItems":{"nodes":[{"project":{"number":999995,"owner":{"login":"example-org"}},"status":{"name":"testing"}}]}}]}}}}}' > "$FAKE/epic-14.json"

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
  *"subIssues(first"*)                    doc="$FAKE/epic-14.json" ;;
  *"projectV2(number:"*)                  doc="$FAKE/project-id.json" ;;
  *"items(first:100, after:"*)            doc="$FAKE/board.json" ;;
  *"o=other-org"*"issues(states:OPEN"*)   doc="$FAKE/issues-other.json" ;;
  *"after=c1"*"issues(states:OPEN"*)      doc="$FAKE/issues-2.json" ;;
  *"issues(states:OPEN"*)                 doc="$FAKE/issues-1.json" ;;
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

echo 'one repository named: its issues in one query, its release from the clone'
run="$(cd "$clone" && bash "$ROOT/bin/status-sync.sh" --project "$PROJECT_NUMBER" --dry-run example-org/example-repo 2>&1)"
check 'exit 0' 0 "$?"
check 'released on the first environment and proven: would close' \
  'would close  example-repo#13  (testing -> done, released in deploy/prod/2 and proven)' \
  "$(grep '^would close' <<< "$run")"
check 'released without a proof record after its landing: due, and it stays' \
  'proof due    example-repo#18  (released in deploy/prod/2, no "Proven on" record after its landing)' \
  "$(grep '^proof due' <<< "$run")"
check 'an epic with one sub-issue is named' \
  'one child    example-repo#14  (its state follows its one sub-issue; work of its own belongs in a sub-issue of its own, or it is closed with that sub-issue)' \
  "$(grep '^one child' <<< "$run")"
check 'and follows its sub-issue moved by hand' \
  'would move   example-repo#14  (todo -> testing)' \
  "$(grep '^would move   example-repo#14' <<< "$run")"
check 'nothing else moves: not on master alone, not reopened, not by hand, not on test only, not untagged' \
  '' "$(grep -E 'example-repo#(12|16|17|19|20)' <<< "$run")"
check 'and the count says what it read, both pages' \
  "8 active cards scanned, 2 would move on board $PROJECT_NUMBER." \
  "$(printf '%s\n' "$run" | tail -1)"
check 'the board is not read' 0 "$(grep -c 'items(first:100' "$FAKE/calls.txt")"
check 'the issues are read once per page' 2 "$(grep -c 'issues(states:OPEN' "$FAKE/calls.txt")"
check 'nothing asks GitHub for a tag or a compare' 0 "$(grep -cE '/tags|/compare/' "$FAKE/calls.txt")"
check 'the fetch brought the tags' yes "$(git -C "$clone" rev-parse -q --verify refs/tags/deploy/prod/2 >/dev/null && echo yes || echo no)"

echo 'without LIVE_TAGS the newest tag by date decides, whatever its name'
: > "$FAKE/calls.txt"; : > "$clone/.ai-core/config.env"
run="$(cd "$clone" && bash "$ROOT/bin/status-sync.sh" --project "$PROJECT_NUMBER" --dry-run example-org/example-repo 2>&1)"
check 'the newest tag is 0.1-newest, which carries #13 and not #19' \
  'would close  example-repo#13  (testing -> done, released in 0.1-newest and proven)' \
  "$(grep '^would close' <<< "$run")"
printf 'LIVE_TAGS="prod=deploy/prod/* test=deploy/test/*"\n' > "$clone/.ai-core/config.env"

echo 'no repository named: the board is read to learn its repositories, each read under its owner'
: > "$FAKE/calls.txt"
run="$(cd "$clone" && bash "$ROOT/bin/status-sync.sh" --project "$PROJECT_NUMBER" --dry-run 2>&1)"
check 'exit 0' 0 "$?"
check 'the board is read once' 1 "$(grep -c 'items(first:100, after:' "$FAKE/calls.txt")"
check 'a repository of another organisation is read under its owner' 1 "$(grep -c 'graphql -f o=other-org -f n=example-repo' "$FAKE/calls.txt")"
check 'its card is counted' "9 active cards scanned, 2 would move on board $PROJECT_NUMBER." "$(printf '%s\n' "$run" | tail -1)"

echo 'a repository with no clone here: said, and its cards in testing stay'
: > "$FAKE/calls.txt"
run="$(cd "$FAKE" && bash "$ROOT/bin/status-sync.sh" --project "$PROJECT_NUMBER" --dry-run example-org/example-repo 2>&1)"
check 'it says so' "no clone of example-org/example-repo in $FAKE, so no release of it is read and its cards in testing stay" "$(grep '^no clone' <<< "$run")"
check 'nothing closes' '' "$(grep '^would close' <<< "$run")"
mkdir -p "$FAKE/folder/.ai-core"; cp "$clone/.ai-core/config.env" "$FAKE/folder/.ai-core/config.env"
run="$(cd "$FAKE/folder" && bash "$ROOT/bin/status-sync.sh" --project "$PROJECT_NUMBER" --dry-run example-org/example-repo 2>&1)"
check 'from the project folder, the clone in it is found' 'would close  example-repo#13  (testing -> done, released in deploy/prod/2 and proven)' "$(grep '^would close' <<< "$run")"

echo
if [ "$failed" -gt 0 ]; then echo "$failed failed"; exit 1; fi
echo 'all passed'
