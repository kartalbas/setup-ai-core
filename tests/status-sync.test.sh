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
check 'ready'        0 "$(status_rank ready)"
check 'planned'      0 "$(status_rank planned)"
check 'implementing' 1 "$(status_rank implementing)"
check 'review'       1 "$(status_rank review)"
check 'testing'      2 "$(status_rank testing)"
check 'done'         3 "$(status_rank done)"
check 'CLOSE is done' 3 "$(status_rank CLOSE)"

# --- the signal path, driven end to end against a stand-in gh and a real clone ----
#
# The decision above is pure, and everything that FEEDS it is not: the one query per repository
# that reads its open issues with their cards and comments, the clone the release is read from,
# and the board that is read only when no repository is named. A suite that only calls
# derive_target cannot see any of them.
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
#   #12 implementing, its commit on master                          -> named "not finished", stays
#   #1  implementing, no commit names it, though one names #12      -> not named (#1 is no prefix match)
#   #24 implementing, no commit names it                            -> not named
#   #25 Review, spelled as the board spells it, its commit on master -> named "not finished", stays
#   #26 done, its commit on master                                  -> not named
#   #13 testing, in deploy/prod/1, a "Proven on" record after it    -> would close, though a report
#       that starts "Landed on" but lists no commit comes after its record and its proof
#   #14 todo, an epic with ONE sub-issue, a commit names it         -> named, follows it, not "not finished"
#   #15 todo, a repository of another organisation                  -> read under its owner
#   #16 testing, reopened after its work landed                     -> no landing, stays
#   #17 testing, moved by hand: no "Landed on" record, only a report -> no landing, stays
#   #18 testing, in deploy/prod/2, no proof record                  -> proof due, stays
#   #19 testing, in deploy/test/9 only, proven                      -> stays, named: not released
#   #20 testing, on master in no tag, proven, on the second page    -> stays, named: not released,
#       though the clone has a newer prod tag of its own that never reached origin
#   #28, #29 testing, proven, landed in example-org/docs, which has a clone and no tag at all and
#       names no LIVE_TAGS                                           -> stay, named once: no release
#   #22 testing, proven, landed in example-org/gone, which has no clone here -> stays and is named,
#       although its commit is in deploy/prod/1 of this repository
#   #23 testing, proven, landed in example-org/tools, whose clone stands in the project folder
#       with its own LIVE_TAGS and its tag deploy/prod/7 on that commit -> would close
# and #18 has a "Proven on" comment by somebody outside the repository, which is no proof.
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
echo '{}' > "$FAKE/empty.json"
printf '{"data":{"repository":{"projectsV2":{"nodes":[{"number":%s,"title":"Board","closed":false}]}}}}\n' "$PROJECT_NUMBER" > "$FAKE/tools-projects.json"
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
commit_at "$seed" 1700000014 'Work of #14' >/dev/null
c16="$(commit_at "$seed" 1700000016 'Land #16')"
c18="$(commit_at "$seed" 1700000018 'Land #18')"; tag_at "$seed" deploy/prod/2 1700000018; tag_at "$seed" 0.1-newest 1700000099
c19="$(commit_at "$seed" 1700000019 'Land #19')"; tag_at "$seed" deploy/test/9 1700000019
c20="$(commit_at "$seed" 1700000020 'Land #20')"
commit_at "$seed" 1700000025 'Work of #25' >/dev/null
commit_at "$seed" 1700000026 'Land #26' >/dev/null
git -C "$seed" push -q "$origin" master --tags
git -C "$origin" symbolic-ref HEAD refs/heads/master
mkdir -p "$FAKE/folder"; git clone -q "$origin" "$clone"
shown="$(dirname "$(git -C "$clone" rev-parse --show-toplevel)")"
# The tags reach the clone through the fetch status-sync makes, not through the clone
git -C "$clone" tag -l | xargs -r git -C "$clone" tag -d >/dev/null
# A release run whose push was refused left this tag in the clone alone, newer than every other
GIT_COMMITTER_DATE="@1700000300 +0000" gitc "$clone" tag -a -m 'never pushed' deploy/prod/3 "$c20"
mkdir -p "$clone/.ai-core"; printf 'LIVE_TAGS="prod=deploy/prod/* test=deploy/test/*"\n' > "$clone/.ai-core/config.env"
# A third repository of the project that is never released: no tag, and no LIVE_TAGS
docs_origin="$FAKE/remote/example-org/docs.git"; docs="$FAKE/folder/docs"
git init -q --bare "$docs_origin"; git init -q "$FAKE/docs-seed"; git -C "$FAKE/docs-seed" checkout -q -b master
d28="$(commit_at "$FAKE/docs-seed" 1700000028 'Land #28')"; d29="$(commit_at "$FAKE/docs-seed" 1700000029 'Land #29')"
git -C "$FAKE/docs-seed" push -q "$docs_origin" master
git -C "$docs_origin" symbolic-ref HEAD refs/heads/master
git clone -q "$docs_origin" "$docs"
# A second repository of the project, whose release carries the work of #23 and of nothing here
tools_origin="$FAKE/remote/example-org/tools.git"; tools="$FAKE/folder/tools"
git init -q --bare "$tools_origin"; git init -q "$FAKE/tools-seed"; git -C "$FAKE/tools-seed" checkout -q -b master
t23="$(commit_at "$FAKE/tools-seed" 1700000023 'Land #23')"; tag_at "$FAKE/tools-seed" deploy/prod/7 1700000023
git -C "$FAKE/tools-seed" push -q "$tools_origin" master --tags
git -C "$tools_origin" symbolic-ref HEAD refs/heads/master
git clone -q "$tools_origin" "$tools"
mkdir -p "$tools/.ai-core"; printf 'LIVE_TAGS="prod=deploy/prod/*"\n' > "$tools/.ai-core/config.env"

card() {  # card <number> <title> <status> [owner]: a card as board-list reads it
  printf '{"fieldValues":{"nodes":[{"name":"%s","field":{"name":"Status"}}]},"content":{"number":%s,"title":"%s","state":"OPEN","repository":{"name":"example-repo","nameWithOwner":"%s/example-repo"}}}' \
    "$3" "$1" "$2" "${4:-example-org}"
}
printf '{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[%s,%s]}}}}\n' \
  "$(card 12 'A commit of its own is on master' implementing)" \
  "$(card 15 'An issue of another organisation on this board' todo other-org)" > "$FAKE/board.json"

# An open issue as the query of one repository reads it: its card on this board and on another
# Every comment is written by a member, but for the one stranger's
landed() { printf '{"createdAt":"%s","authorAssociation":"MEMBER","body":"Landed on master%s:\\n\\n- %s Its subject\\n- 1111111 an older commit"}' "$1" "${3:+ of $3}" "$(printf '%s' "$2" | cut -c1-7)"; }
proven() { printf '{"createdAt":"%s","authorAssociation":"%s","body":"Proven on prod:\\n\\n- TC-1 PASS"}' "$1" "${2:-MEMBER}"; }
# The card of board 5 and the one of a board numbered like this one under another owner are not
# this board's
issue() {  # issue <number> <status> <sub-issues> <comments> [reopened at]
  printf '{"number":%s,"subIssuesSummary":{"total":%s},"projectItems":{"nodes":[{"project":{"number":5,"owner":{"login":"example-org"}},"status":{"name":"done"}},{"project":{"number":%s,"owner":{"login":"other-org"}},"status":{"name":"done"}},{"project":{"number":%s,"owner":{"login":"example-org"}},"status":{"name":"%s"}}]},"reopened":{"nodes":[%s]},"comments":{"nodes":[%s]}}' \
    "$1" "$3" "$PROJECT_NUMBER" "$PROJECT_NUMBER" "$2" "${5:+{\"createdAt\":\"$5\"\}}" "$4"
}
page() { printf '{"data":{"repository":{"issues":{"pageInfo":{"hasNextPage":%s,"endCursor":%s},"nodes":[%s]}}}}\n' "$1" "$2" "$3"; }
page true '"c1"' "$(issue 12 implementing 0 "$(landed 2026-09-01T10:00:00Z "$c12")"),$(issue 13 testing 0 "$(landed 2026-08-01T10:00:00Z 0000000),$(landed 2026-09-01T10:00:00Z "$c13"),{\"createdAt\":\"2026-09-02T12:00:00Z\",\"authorAssociation\":\"MEMBER\",\"body\":\"Landed on master as abc1313, the merge of the package\"},$(proven 2026-09-02T10:00:00Z),{\"createdAt\":\"2026-09-03T10:00:00Z\",\"authorAssociation\":\"MEMBER\",\"body\":\"Looks good, see 2222222\"}"),$(issue 14 todo 1 ''),$(issue 16 testing 0 "$(landed 2026-09-01T10:00:00Z "$c16"),$(proven 2026-09-02T10:00:00Z)" 2026-09-05T10:00:00Z),$(issue 17 testing 0 '{"createdAt":"2026-09-01T10:00:00Z","authorAssociation":"MEMBER","body":"Done in\n- abc1717 by hand"},{"createdAt":"2026-09-01T11:00:00Z","authorAssociation":"MEMBER","body":"Landed on master as abc1717, by hand"}')" > "$FAKE/issues-1.json"
page false null "$(issue 18 testing 0 "$(proven 2026-08-30T10:00:00Z),$(landed 2026-09-01T10:00:00Z "$c18"),$(proven 2026-09-02T10:00:00Z NONE)"),$(issue 22 testing 0 "$(landed 2026-09-01T10:00:00Z "$c13" example-org/gone),$(proven 2026-09-02T10:00:00Z)"),$(issue 23 testing 0 "$(landed 2026-09-01T10:00:00Z "$t23" example-org/tools),$(proven 2026-09-02T10:00:00Z)"),$(issue 19 testing 0 "$(landed 2026-09-01T10:00:00Z "$c19"),$(proven 2026-09-02T10:00:00Z)"),$(issue 20 testing 0 "$(landed 2026-09-01T10:00:00Z "$c20"),$(proven 2026-09-02T10:00:00Z)"),$(issue 21 '' 0 ''),$(issue 1 implementing 0 ''),$(issue 24 implementing 0 ''),$(issue 25 Review 0 ''),$(issue 26 done 0 ''),$(issue 28 testing 0 "$(landed 2026-09-01T10:00:00Z "$d28" example-org/docs),$(proven 2026-09-02T10:00:00Z)"),$(issue 29 testing 0 "$(landed 2026-09-01T10:00:00Z "$d29" example-org/docs),$(proven 2026-09-02T10:00:00Z)")" > "$FAKE/issues-2.json"
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
  *"--method PATCH"*)                     doc="$FAKE/empty.json" ;;
  *"n=tools"*"projectsV2(first:50)"*)     doc="$FAKE/tools-projects.json" ;;
  # the checkout is on this board only where a case says it stands in one
  *"o=example-org -f n=example-repo"*"projectsV2(first:50)"*)
    [ -e "$FAKE/here" ] && doc="$FAKE/tools-projects.json"
    [ -e "$FAKE/here" ] || { [ -e "$FAKE/lenient" ] && exit 0; echo "the stand-in gh has no answer for: \$*" >&2; exit 9; } ;;
  *"repo view"*|"api repos/{owner}/{repo} --jq .full_name"*)                          [ -e "$FAKE/here" ] && { echo 'example-org/example-repo'; exit 0; }
                                          [ -e "$FAKE/lenient" ] && exit 0; echo 'no git remotes found' >&2; exit 1 ;;
  *) [ -e "$FAKE/lenient" ] && exit 0; echo "the stand-in gh has no answer for: \$*" >&2; exit 9 ;;
esac
if [ -n "\$prog" ]; then jq -r "\$prog" < "\$doc"
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
  "$(grep '^would close  example-repo#13' <<< "$run")"
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
  '' "$(grep -E 'example-repo#(12|16|17|19|20|22)' <<< "$run" | grep -v -e '^proof due' -e '^no landing' -e '^not finished' -e '^not released')"
check 'a card whose commit is on the default branch and in no newer release than the newest one is named, with that tag' \
  "not released example-repo#19  (landed in $(printf '%s' "$c19" | cut -c1-7); the newest prod release deploy/prod/2 does not carry it)
not released example-repo#20  (landed in $(printf '%s' "$c20" | cut -c1-7); the newest prod release deploy/prod/2 does not carry it)" \
  "$(grep '^not released' <<< "$run")"
check 'a card a release carries, or with no landing, or no commit on a release at all, is not named so' \
  '' "$(grep -E '^not released +example-repo#(12|13|14|16|17|18|22|23|28|29) ' <<< "$run")"
check 'a repository without a tag is named once, with the cards that ask for its release, wherever they stand' \
  'no release   docs  (no tag of docs matches * (LIVE_TAGS names no environment); 2 cards in testing wait)' \
  "$(grep '^no release' <<< "$run")"
check 'a card before testing that a commit on the default branch names is named, in its column as the board spells it, and does not move' \
  "not finished example-repo#12  (in implementing, but origin/master has $(git -C "$clone" log -1 --format=%h "$(git -C "$clone" log origin/master --grep='Work of #12' --format=%H)") naming it: run ai-core finish-issue example-org/example-repo 12)
not finished example-repo#25  (in Review, but origin/master has $(git -C "$clone" log -1 --format=%h "$(git -C "$clone" log origin/master --grep='Work of #25' --format=%H)") naming it: run ai-core finish-issue example-org/example-repo 25)" \
  "$(grep '^not finished' <<< "$run")"
check 'a card no commit names is not named, nor one whose number is a prefix of a named one, nor a card in done, testing or an epic' \
  '' "$(grep -E '^not finished +example-repo#(1|24|26|13|14|18|19|20|22|23) ' <<< "$run")"
check 'a card in testing without a landing since it was last reopened, or moved by hand, is named' \
  'no landing   example-repo#16  (in testing, but no "Landed on" record names its work: where it landed, run ai-core finish-issue example-org/example-repo 16)
no landing   example-repo#17  (in testing, but no "Landed on" record names its work: where it landed, run ai-core finish-issue example-org/example-repo 17)' \
  "$(grep '^no landing' <<< "$run")"
check 'a landing in another repository is read there, and that one has no clone here' \
  "no clone of example-org/gone in $shown, so no release of it is read and its cards in testing stay" "$(grep '^no clone' <<< "$run")"
check 'a landing in another repository closes through that one'"'"'s clone and release' \
  'would close  example-repo#23  (testing -> done, released in example-org/tools deploy/prod/7 and proven)' "$(grep '^would close  example-repo#23' <<< "$run")"
check 'and the count says what it read, both pages' \
  "15 active cards scanned, 3 would move on board $PROJECT_NUMBER." \
  "$(printf '%s\n' "$run" | tail -1)"
check 'the board is not read' 0 "$(grep -c 'items(first:100' "$FAKE/calls.txt")"
check 'the issues are read once per page' 2 "$(grep -c 'issues(states:OPEN' "$FAKE/calls.txt")"
check 'nothing asks GitHub for a tag or a compare' 0 "$(grep -cE '/tags|/compare/' "$FAKE/calls.txt")"
check 'the fetch brought the tags' yes "$(git -C "$clone" rev-parse -q --verify refs/tags/deploy/prod/2 >/dev/null && echo yes || echo no)"
check 'and kept the one origin never had, which no fetch prunes' yes "$(git -C "$clone" rev-parse -q --verify refs/tags/deploy/prod/3 >/dev/null && echo yes || echo no)"

echo 'the repositories alone, the board from GH_PROJECT_NUMBER'
: > "$FAKE/calls.txt"
run="$(cd "$clone" && GH_PROJECT_NUMBER="$PROJECT_NUMBER" bash "$ROOT/bin/status-sync.sh" example-org/example-repo other-org/example-repo --dry-run 2>&1)"
check 'exit 0' 0 "$?"
check 'both are read' "16 active cards scanned, 3 would move on board $PROJECT_NUMBER." "$(printf '%s\n' "$run" | tail -1)"

echo 'no board named: the board is the one the first repository named is linked to, not the checkout'"'"'s'
: > "$FAKE/calls.txt"
run="$(cd "$clone" && env -u GH_PROJECT_NUMBER bash "$ROOT/bin/status-sync.sh" --dry-run example-org/tools 2>&1)"
check 'exit 0' 0 "$?"
check 'it is swept on that board' "on board $PROJECT_NUMBER." "$(printf '%s\n' "$run" | tail -1 | grep -o 'on board .*')"

echo 'no board named, from a checkout on a board: that board, also for a repository of another organisation'
: > "$FAKE/calls.txt"; touch "$FAKE/here"
run="$(cd "$clone" && env -u GH_PROJECT_NUMBER bash "$ROOT/bin/status-sync.sh" --dry-run other-org/example-repo 2>&1)"
check 'exit 0' 0 "$?"
check 'its card on this board is read' "1 active cards scanned, 0 would move on board $PROJECT_NUMBER." "$(printf '%s\n' "$run" | tail -1)"
rm -f "$FAKE/here"

echo 'without LIVE_TAGS the newest tag by date decides, whatever its name'
: > "$FAKE/calls.txt"; : > "$clone/.ai-core/config.env"
run="$(cd "$clone" && bash "$ROOT/bin/status-sync.sh" --project "$PROJECT_NUMBER" --dry-run example-org/example-repo 2>&1)"
check 'the newest tag is 0.1-newest, which carries #13 and not #19' \
  'would close  example-repo#13  (testing -> done, released in 0.1-newest and proven)' \
  "$(grep '^would close  example-repo#13' <<< "$run")"
check 'and #19 is named against it, without an environment' \
  "not released example-repo#19  (landed in $(printf '%s' "$c19" | cut -c1-7); the newest release 0.1-newest does not carry it)" \
  "$(grep '^not released example-repo#19' <<< "$run")"

echo 'LIVE_TAGS "prod=landed": the landing on the default branch is the release, so a proven card on it closes and one without a proof is due'
: > "$FAKE/calls.txt"; printf 'LIVE_TAGS="prod=landed"\n' > "$clone/.ai-core/config.env"
run="$(cd "$clone" && bash "$ROOT/bin/status-sync.sh" --project "$PROJECT_NUMBER" --dry-run example-org/example-repo 2>&1)"
check '#20, on master in no tag and proven, would close' \
  'would close  example-repo#20  (testing -> done, released in its landing on origin/master and proven)' \
  "$(grep '^would close  example-repo#20' <<< "$run")"
check '#18, without a proof, is due' \
  'proof due    example-repo#18  (released in its landing on origin/master, no "Proven on" record after its landing)' \
  "$(grep '^proof due    example-repo#18' <<< "$run")"
check '#16 and #17, without a landing, stay' '' "$(grep -E '^would close  example-repo#1[67] ' <<< "$run")"
check 'where the landing is the release, no card is named for lacking one' '' "$(grep -E '^(not released|no release) +example-repo' <<< "$run")"
tip="$(git -C "$origin" rev-parse refs/heads/master)"; git -C "$origin" update-ref refs/heads/master "$c19"
run="$(cd "$clone" && bash "$ROOT/bin/status-sync.sh" --project "$PROJECT_NUMBER" --dry-run example-org/example-repo 2>&1)"
git -C "$origin" update-ref refs/heads/master "$tip"
check 'with origin'"'"'s default branch back before #20, proven #20 stays, while #19 on it closes' \
  '|would close  example-repo#19  (testing -> done, released in its landing on origin/master and proven)' \
  "$(grep '^would close  example-repo#20' <<< "$run")|$(grep '^would close  example-repo#19' <<< "$run")"
printf 'LIVE_TAGS="prod=deploy/prod/* test=deploy/test/*"\n' > "$clone/.ai-core/config.env"

echo 'LIVE_TAGS names a pattern no tag of origin matches: the repository is named once, with its count, and no card is named singly'
printf 'LIVE_TAGS="prod=release/*"\n' > "$clone/.ai-core/config.env"
run="$(cd "$clone" && bash "$ROOT/bin/status-sync.sh" --project "$PROJECT_NUMBER" --dry-run example-org/example-repo 2>&1)"
check 'once, with the environment, the pattern and the four cards in testing that ask' \
  'no release   example-repo  (no tag of example-repo matches prod=release/* of LIVE_TAGS; 4 cards in testing wait)' \
  "$(grep '^no release   example-repo' <<< "$run")"
check 'none is named singly, and nothing closes or is due' '' "$(grep -E '^(not released|would close|proof due) +example-repo#(13|18|19|20) ' <<< "$run")"
printf 'LIVE_TAGS="prod=deploy/prod/* test=deploy/test/*"\n' > "$clone/.ai-core/config.env"

echo 'no repository named: the board is read to learn its repositories, each read under its owner'
: > "$FAKE/calls.txt"
run="$(cd "$clone" && bash "$ROOT/bin/status-sync.sh" --project "$PROJECT_NUMBER" --dry-run 2>&1)"
check 'exit 0' 0 "$?"
check 'the board is read once' 1 "$(grep -c 'items(first:100, after:' "$FAKE/calls.txt")"
check 'a repository of another organisation is read under its owner' 1 "$(grep -c 'graphql -f o=other-org -f n=example-repo' "$FAKE/calls.txt")"
check 'its card is counted' "16 active cards scanned, 3 would move on board $PROJECT_NUMBER." "$(printf '%s\n' "$run" | tail -1)"

echo 'a repository with no clone here: said, and its cards in testing stay'
: > "$FAKE/calls.txt"
run="$(cd "$FAKE" && bash "$ROOT/bin/status-sync.sh" --project "$PROJECT_NUMBER" --dry-run example-org/example-repo 2>&1)"
check 'it says so' "no clone of example-org/example-repo in $FAKE, so no release of it is read and its cards in testing stay" "$(grep '^no clone of example-org/example-repo ' <<< "$run")"
check 'nothing closes' '' "$(grep '^would close' <<< "$run")"
run="$(cd "$FAKE/folder" && bash "$ROOT/bin/status-sync.sh" --project "$PROJECT_NUMBER" --dry-run example-org/example-repo 2>&1)"
check 'from the project folder, the clone in it is found, and LIVE_TAGS read from the clone' 'would close  example-repo#13  (testing -> done, released in deploy/prod/2 and proven)' "$(grep '^would close  example-repo#13' <<< "$run")"

echo 'a tag origin moved back still stands on its old commit in the clone: no tag counts, since the newest is not known'
moved="$(git -C "$origin" rev-parse refs/tags/deploy/prod/2)"
GIT_COMMITTER_DATE="@1700000018 +0000" gitc "$origin" tag -f -a -m 'moved back' deploy/prod/2 "$c12" >/dev/null
run="$(cd "$clone" && bash "$ROOT/bin/status-sync.sh" --project "$PROJECT_NUMBER" --dry-run example-org/example-repo 2>&1)"
check 'the fetch says why it failed' \
  "fetching origin of example-org/example-repo in $shown/example-repo failed: ! [rejected] deploy/prod/2 -> deploy/prod/2 (would clobber existing tag); the refs it had are read" \
  "$(grep '^fetching origin' <<< "$run")"
check 'it names the tag' "origin of example-org/example-repo has deploy/prod/2 on a commit its clone in $shown/example-repo does not have it on, so no tag of it counts as a release and its cards in testing stay" "$(grep '^origin of' <<< "$run")"
check 'and the tag before it does not stand in: nothing of it closes' '' "$(grep -E '^(would close|proof due) +example-repo#(13|18)' <<< "$run")"
check 'where which tag is newest is not known, no card is named for lacking a release' '' "$(grep -E '^(not released|no release) +example-repo' <<< "$run")"
git -C "$origin" update-ref refs/tags/deploy/prod/2 "$moved"

echo 'an origin that cannot be listed: no tag counts, and it says so'
git -C "$clone" remote set-url origin "$FAKE/gone/example-org/example-repo.git"
run="$(cd "$clone" && bash "$ROOT/bin/status-sync.sh" --project "$PROJECT_NUMBER" --dry-run example-org/example-repo 2>&1)"
check 'it says so' "origin of example-org/example-repo could not be listed from $shown/example-repo, so no tag of it counts as a release and its cards in testing stay" "$(grep '^origin of' <<< "$run")"
check 'nothing of it closes, not even on the tag the clone holds' '' "$(grep '^would close  example-repo#13' <<< "$run")"
check 'and, with no tag read, no card is named for lacking a release' '' "$(grep -E '^(not released|no release) +example-repo' <<< "$run")"
git -C "$clone" remote set-url origin "$origin"

echo 'without --dry-run: the closing card is closed through issue-close, and nothing else is'
# issue-close asks more than the close, where the issue stands on boards and under an epic, and
# the stand-in answers every such question with nothing
: > "$FAKE/calls.txt"; touch "$FAKE/lenient"
run="$(cd "$clone" && bash "$ROOT/bin/status-sync.sh" --project "$PROJECT_NUMBER" example-org/example-repo 2>&1)"
check 'exit 0' 0 "$?"
check 'it says so' 'close        example-repo#13  (testing -> done, released in deploy/prod/2 and proven)' "$(grep '^close        example-repo#13' <<< "$run")"
check '#13 is closed' 1 "$(grep -c 'api --method PATCH repos/example-org/example-repo/issues/13 ' "$FAKE/calls.txt")"
check '#23 is closed' 1 "$(grep -c 'api --method PATCH repos/example-org/example-repo/issues/23 ' "$FAKE/calls.txt")"
check 'and no other issue' 2 "$(grep -c 'api --method PATCH repos/.*/issues/' "$FAKE/calls.txt")"
check 'the cards no release carries are named here too' 2 "$(grep -c '^not released' <<< "$run")"
check 'a card named "not finished" is named here too' 2 "$(grep -c '^not finished' <<< "$run")"
# Each mover looks the repository up on a board first, and here the stand-in has none and stops it
# before it names an issue, so the lookups count the movers: the two closes and the sweep's own
check 'and no card is moved or closed for being named: no mover runs beyond the two closes' 3 "$(grep -c 'projectsV2(first:50)' "$FAKE/calls.txt")"
rm -f "$FAKE/lenient"

# The only card read is an epic whose one sub-issue is done: no card in testing has named a release
# when its close is reported
echo 'an epic that closes before any card in testing is read: it closes, and the run goes on'
cp "$FAKE/issues-1.json" "$FAKE/issues-1.saved"
page false null "$(issue 31 todo 1 '')" > "$FAKE/issues-1.json"
cp "$FAKE/epic-14.json" "$FAKE/epic-14.saved"
printf '%s\n' '{"data":{"repository":{"issue":{"state":"OPEN","projectItems":{"nodes":[{"project":{"number":999995,"owner":{"login":"example-org"}},"status":{"name":"todo"}}]},"subIssues":{"nodes":[{"state":"CLOSED","stateReason":"COMPLETED","projectItems":{"nodes":[]}}]}}}}}' > "$FAKE/epic-14.json"
run="$(cd "$clone" && bash "$ROOT/bin/status-sync.sh" --project "$PROJECT_NUMBER" --dry-run example-org/example-repo 2>&1)"
check 'exit 0' 0 "$?"
check 'it would close, as its sub-issues stand' 'would close  example-repo#31  (todo -> done, every sub-issue done)' "$(grep '^would close' <<< "$run")"
mv "$FAKE/issues-1.saved" "$FAKE/issues-1.json"; mv "$FAKE/epic-14.saved" "$FAKE/epic-14.json"

echo
if [ "$failed" -gt 0 ]; then echo "$failed failed"; exit 1; fi
echo 'all passed'
