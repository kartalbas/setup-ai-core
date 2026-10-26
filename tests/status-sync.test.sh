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
#   #24 implementing, only another repository's issue of that number is named -> not named
#   #27 implementing, its commit names it with the own repository written out -> named "not finished"
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
#   #31 testing, proven, its work landed in this repository and then in docs and in gone, the newest record the one of
#       gone, which has no clone here                                 -> would close, by the record of its own repository
#   #32 testing, proven, landed in docs and then in gone only        -> stays, named: its newest record is read, and gone has no clone
#   #33 testing, proven, its record names a commit origin/master does not hold -> stays, named as having no landing
# and #18 has a "Proven on" comment by somebody outside the repository, which is no proof.
#
# lib/board.sh, which the source above brought in, carries `set -e`. An assertion that counts
# zero matches exits non-zero, and under `set -e` that ends this test instead of failing it.
set +e

FAKE="$(mktemp -d)"
export HOME="$FAKE/home" AI_CORE_HOME="$FAKE/ai-core-home" GH_ORG=example-org
mkdir -p "$HOME" "$AI_CORE_HOME"
export GH_CACHE_DIRECTORY="$FAKE/cache"
PROJECT_NUMBER=999995
PROJECT_ID='PVT_kwstatussync'
trap 'rm -rf "$FAKE"' EXIT
mkdir -p "$GH_CACHE_DIRECTORY/$PROJECT_NUMBER"
printf '%s\n' "$PROJECT_ID" > "$GH_CACHE_DIRECTORY/$PROJECT_NUMBER/project-id"
echo '{}' > "$FAKE/empty.json"
echo '{"data":{"repository":{"issue":{"subIssues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}' > "$FAKE/no-open-children.json"
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
commit_at "$seed" 1700000027 'Work of the board

Carries Example-Org/example-repo#27 and other-org/other-repo#24 too.' >/dev/null
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
# The project folder's own list, the one a repository that sets none is read by
mkdir -p "$FAKE/folder/.ai-core"; printf 'LIVE_TAGS="prod=deploy/prod/* test=deploy/test/*"\n' > "$FAKE/folder/.ai-core/config.env"
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
  printf '{"number":%s,"createdAt":"2020-01-01T00:00:00Z","subIssuesSummary":{"total":%s},"projectItems":{"nodes":[{"project":{"number":5,"owner":{"login":"example-org"}},"status":{"name":"done"}},{"project":{"number":%s,"owner":{"login":"other-org"}},"status":{"name":"done"}},{"project":{"number":%s,"owner":{"login":"example-org"}},"status":{"name":"%s"}}]},"reopened":{"nodes":[%s]},"comments":{"nodes":[%s]}}' \
    "$1" "$3" "$PROJECT_NUMBER" "$PROJECT_NUMBER" "$2" "${5:+{\"createdAt\":\"$5\"\}}" "$4"
}
page() { printf '{"data":{"repository":{"issues":{"pageInfo":{"hasNextPage":%s,"endCursor":%s},"nodes":[%s]}}}}\n' "$1" "$2" "$3"; }
page true '"c1"' "$(issue 12 implementing 0 "$(landed 2026-09-01T10:00:00Z "$c12")"),$(issue 13 testing 0 "$(landed 2026-08-01T10:00:00Z 0000000),$(landed 2026-09-01T10:00:00Z "$c13"),{\"createdAt\":\"2026-09-02T12:00:00Z\",\"authorAssociation\":\"MEMBER\",\"body\":\"Landed on master as abc1313, the merge of the package\"},$(proven 2026-09-02T10:00:00Z),{\"createdAt\":\"2026-09-03T10:00:00Z\",\"authorAssociation\":\"MEMBER\",\"body\":\"Looks good, see 2222222\"}"),$(issue 14 todo 1 ''),$(issue 16 testing 0 "$(landed 2026-09-01T10:00:00Z "$c16"),$(proven 2026-09-02T10:00:00Z)" 2026-09-05T10:00:00Z),$(issue 17 testing 0 '{"createdAt":"2026-09-01T10:00:00Z","authorAssociation":"MEMBER","body":"Done in\n- abc1717 by hand"},{"createdAt":"2026-09-01T11:00:00Z","authorAssociation":"MEMBER","body":"Landed on master as abc1717, by hand"}')" > "$FAKE/issues-1.json"
page false null "$(issue 18 testing 0 "$(proven 2026-08-30T10:00:00Z),$(landed 2026-09-01T10:00:00Z "$c18"),$(proven 2026-09-02T10:00:00Z NONE)"),$(issue 22 testing 0 "$(landed 2026-09-01T10:00:00Z "$c13" example-org/gone),$(proven 2026-09-02T10:00:00Z)"),$(issue 23 testing 0 "$(landed 2026-09-01T10:00:00Z "$t23" example-org/tools),$(proven 2026-09-02T10:00:00Z)"),$(issue 19 testing 0 "$(landed 2026-09-01T10:00:00Z "$c19"),$(proven 2026-09-02T10:00:00Z)"),$(issue 20 testing 0 "$(landed 2026-09-01T10:00:00Z "$c20"),$(proven 2026-09-02T10:00:00Z)"),$(issue 21 '' 0 ''),$(issue 1 implementing 0 ''),$(issue 24 implementing 0 ''),$(issue 25 Review 0 ''),$(issue 27 implementing 0 ''),$(issue 26 done 0 ''),$(issue 28 testing 0 "$(landed 2026-09-01T10:00:00Z "$d28" example-org/docs),$(proven 2026-09-02T10:00:00Z)"),$(issue 29 testing 0 "$(landed 2026-09-01T10:00:00Z "$d29" example-org/docs),$(proven 2026-09-02T10:00:00Z)"),$(issue 31 testing 0 "$(landed 2026-09-01T10:00:00Z "$c13"),$(landed 2026-09-01T11:00:00Z "$d28" example-org/docs),$(landed 2026-09-01T12:00:00Z "$c13" example-org/gone),$(proven 2026-09-02T10:00:00Z)"),$(issue 32 testing 0 "$(landed 2026-09-01T10:00:00Z "$d28" example-org/docs),$(landed 2026-09-01T12:00:00Z "$c13" example-org/gone),$(proven 2026-09-02T10:00:00Z)"),$(issue 33 testing 0 "$(landed 2026-09-01T10:00:00Z abcdef0123),$(proven 2026-09-02T10:00:00Z)")" > "$FAKE/issues-2.json"
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
num="\$(printf '%s\n' "\$@" | sed -n 's/^n=\([0-9]*\)\$/\1/p' | head -1)"
case "\$*" in
  # the open sub-issues of an issue, the query of issue-close: none of the issues planted here has an open one
  *"subIssues(first"*"nameWithOwner"*)    doc="$FAKE/no-open-children.json" ;;
  # the sub-issues of an epic as its target reads them: the epic-<number> planted for it, else the one of #14
  *"subIssues(first"*)                    doc="$FAKE/epic-\$num.json"; [ -f "\$doc" ] || doc="$FAKE/epic-14.json" ;;
  *"projectV2(number:"*)                  doc="$FAKE/project-id.json" ;;
  *"items(first:100, after:"*)            doc="$FAKE/board.json" ;;
  *"o=other-org"*"issues(states:OPEN"*)   doc="$FAKE/issues-other.json" ;;
  *"n=component"*"issues(states:OPEN"*)   doc="$FAKE/issues-component.json" ;;
  *"n=relay"*"issues(states:OPEN"*)       doc="$FAKE/issues-relay.json" ;;
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
  '' "$(grep -E 'example-repo#(12|16|17|19|20)' <<< "$run" | grep -v -e '^proof due' -e '^no landing' -e '^not finished' -e '^not released')"
check 'work that landed in several repositories is read by the newest record of the repository of its issue, so a newer record of a repository with no clone here does not hide it' \
  'would close  example-repo#31  (testing -> done, released in deploy/prod/2 and proven)' \
  "$(grep '^would close  example-repo#31' <<< "$run")"
check 'a card whose records are all of other repositories is read by the newest one, and said where that repository has no clone here' \
  "unknown      example-repo#22  (no clone of example-org/gone in $shown, so its release is not read; the card stays)
unknown      example-repo#32  (no clone of example-org/gone in $shown, so its release is not read; the card stays)" \
  "$(grep -E '^unknown +example-repo#' <<< "$run")"
check 'a card whose commit is on the default branch and in no newer release than the newest one is named, with that tag' \
  "not released example-repo#19  (landed in $(printf '%s' "$c19" | cut -c1-7); the newest prod release deploy/prod/2 does not carry it)
not released example-repo#20  (landed in $(printf '%s' "$c20" | cut -c1-7); the newest prod release deploy/prod/2 does not carry it)" \
  "$(grep '^not released' <<< "$run")"
check 'a card a release carries, or with no landing, or no commit on a release at all, is not named so' \
  '' "$(grep -E '^not released +example-repo#(12|13|14|16|17|18|22|23|28|29|31|32|33) ' <<< "$run")"
check 'a repository without a tag and with no LIVE_TAGS of its own is read by the list of the checkout, and named once, with the cards that ask for its release, wherever they stand' \
  'no release   docs  (no tag of docs matches prod=deploy/prod/* of LIVE_TAGS; 2 cards in testing wait)' \
  "$(grep '^no release' <<< "$run")"
check 'a card before testing that a commit on the default branch names is named, in its column as the board spells it, and does not move' \
  "not finished example-repo#12  (in implementing, but origin/master has $(git -C "$clone" log -1 --format=%h "$(git -C "$clone" log origin/master --grep='Work of #12' --format=%H)") naming it: run ai-core finish-issue example-org/example-repo 12)
not finished example-repo#25  (in Review, but origin/master has $(git -C "$clone" log -1 --format=%h "$(git -C "$clone" log origin/master --grep='Work of #25' --format=%H)") naming it: run ai-core finish-issue example-org/example-repo 25)
not finished example-repo#27  (in implementing, but origin/master has $(git -C "$clone" log -1 --format=%h "$(git -C "$clone" log origin/master --grep='Work of the board' --format=%H)") naming it: run ai-core finish-issue example-org/example-repo 27)" \
  "$(grep '^not finished' <<< "$run")"
check 'a card no commit names is not named, nor one whose number is a prefix of a named one, nor a card in done, testing or an epic' \
  '' "$(grep -E '^not finished +example-repo#(1|24|26|13|14|18|19|20|22|23) ' <<< "$run")"
check 'a card in testing without a landing since it was last reopened, or moved by hand, is named, and so is one whose record names a commit its repository does not hold' \
  'no landing   example-repo#16  (in testing, but no "Landed on" record names its work: where it landed, run ai-core finish-issue example-org/example-repo 16)
no landing   example-repo#17  (in testing, but no "Landed on" record names its work: where it landed, run ai-core finish-issue example-org/example-repo 17)
no landing   example-repo#33  (in testing, but its "Landed on" record names abcdef0, which origin/master of example-org/example-repo does not hold: where it landed, run ai-core finish-issue example-org/example-repo 33)' \
  "$(grep '^no landing' <<< "$run")"
check 'a landing in another repository is read there, and that one has no clone here' \
  "no clone of example-org/gone in $shown, so no release of it is read and its cards in testing stay" "$(grep '^no clone' <<< "$run")"
check 'a landing in another repository closes through that one'"'"'s clone and release' \
  'would close  example-repo#23  (testing -> done, released in example-org/tools deploy/prod/7 and proven)' "$(grep '^would close  example-repo#23' <<< "$run")"
check 'and the count says what it read, both pages' \
  "19 active cards scanned, 4 would move on board $PROJECT_NUMBER." \
  "$(printf '%s\n' "$run" | tail -1)"
check 'the board is not read' 0 "$(grep -c 'items(first:100' "$FAKE/calls.txt")"
check 'the issues are read once per page' 2 "$(grep -c 'issues(states:OPEN' "$FAKE/calls.txt")"
check 'nothing asks GitHub for a tag or a compare' 0 "$(grep -cE '/tags|/compare/' "$FAKE/calls.txt")"
check 'the fetch brought the tags' yes "$(git -C "$clone" rev-parse -q --verify refs/tags/deploy/prod/2 >/dev/null && echo yes || echo no)"
check 'and kept the one origin never had, which no fetch prunes' yes "$(git -C "$clone" rev-parse -q --verify refs/tags/deploy/prod/3 >/dev/null && echo yes || echo no)"

echo 'planted: a card of several repositories read by the newest record of all, and a card nothing else names left unsaid'
# sweep_mutant <file of the copy> <sed expression> [more repositories]: a copy of the harness with one defect in one file of it, and the sweep of example-repo with it, run from $sweep_dir where that is set, else from the clone
sweep_mutant() {
  local mutant="$FAKE/mutant"
  rm -rf "$mutant"; mkdir -p "$mutant"; cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/templates" "$mutant/"; cp "$ROOT/VERSION" "$mutant/"
  sed -i.bak "$2" "$mutant/$1"
  cmp -s "$ROOT/$1" "$mutant/$1" && { echo "  FAIL the planted copy equals $1: $2"; failed=$((failed + 1)); }
  mutant_run="$(cd "${sweep_dir:-$clone}" && bash "$mutant/bin/status-sync.sh" --project "$PROJECT_NUMBER" --dry-run example-org/example-repo ${3:-} 2>&1)"
}
sweep_mutant lib/board.sh 's/^  | (\[\$all.*$/  | ($all | last)/'
check 'the newest record of all decides: #31 is read in a repository with no clone here and no longer closes' no "$(grep -q '^would close  example-repo#31' <<< "$mutant_run" && echo yes || echo no)"
check 'and #13, whose records are its own alone, closes as before' 'would close  example-repo#13  (testing -> done, released in deploy/prod/2 and proven)' "$(grep '^would close  example-repo#13' <<< "$mutant_run")"
sweep_mutant bin/status-sync.sh '/^        elif \[ -z "\$REL_CLONE" \]; then$/,/could not be read, as said where it was first asked for/d'
check 'without the line for a card nothing else names, #22, #32 and #33 are named nowhere' 0 "$(grep -cE ' example-repo#(22|32|33)  \(' <<< "$mutant_run")"
check 'and #13 is closed, #16 named as before' '1 1' "$(grep -c '^would close  example-repo#13' <<< "$mutant_run") $(grep -c '^no landing   example-repo#16' <<< "$mutant_run")"

echo 'the repositories alone, the board from GH_PROJECT_NUMBER'
: > "$FAKE/calls.txt"
run="$(cd "$clone" && GH_PROJECT_NUMBER="$PROJECT_NUMBER" bash "$ROOT/bin/status-sync.sh" example-org/example-repo other-org/example-repo --dry-run 2>&1)"
check 'exit 0' 0 "$?"
check 'both are read' "20 active cards scanned, 4 would move on board $PROJECT_NUMBER." "$(printf '%s\n' "$run" | tail -1)"

echo 'a board written with a leading zero is the board with that number'
: > "$FAKE/calls.txt"
run="$(cd "$clone" && GH_PROJECT_NUMBER="0$PROJECT_NUMBER" bash "$ROOT/bin/status-sync.sh" example-org/example-repo other-org/example-repo --dry-run 2>&1)"
check 'exit 0' 0 "$?"
check 'the cards of the board are read' "20 active cards scanned, 4 would move on board 0$PROJECT_NUMBER." "$(printf '%s\n' "$run" | tail -1)"

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
: > "$FAKE/calls.txt"; : > "$clone/.ai-core/config.env"; : > "$FAKE/folder/.ai-core/config.env"
run="$(cd "$clone" && bash "$ROOT/bin/status-sync.sh" --project "$PROJECT_NUMBER" --dry-run example-org/example-repo 2>&1)"
check 'the newest tag is 0.1-newest, which carries #13 and not #19' \
  'would close  example-repo#13  (testing -> done, released in 0.1-newest and proven)' \
  "$(grep '^would close  example-repo#13' <<< "$run")"
check 'and #19 is named against it, without an environment' \
  "not released example-repo#19  (landed in $(printf '%s' "$c19" | cut -c1-7); the newest release 0.1-newest does not carry it)" \
  "$(grep '^not released example-repo#19' <<< "$run")"
check 'where neither the project folder nor the repository names an environment, the repository without a tag is read by every tag, and says so' \
  'no release   docs  (no tag of docs matches * (LIVE_TAGS names no environment); 2 cards in testing wait)' \
  "$(grep '^no release' <<< "$run")"
printf 'LIVE_TAGS="prod=deploy/prod/* test=deploy/test/*"\n' > "$FAKE/folder/.ai-core/config.env"

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
check 'once, with the environment, the pattern and the five cards in testing that ask' \
  'no release   example-repo  (no tag of example-repo matches prod=release/* of LIVE_TAGS; 5 cards in testing wait)' \
  "$(grep '^no release   example-repo' <<< "$run")"
check 'none is named singly, and nothing closes or is due' '' "$(grep -E '^(not released|would close|proof due) +example-repo#(13|18|19|20) ' <<< "$run")"
printf 'LIVE_TAGS="prod=deploy/prod/* test=deploy/test/*"\n' > "$clone/.ai-core/config.env"

echo 'no repository named: the board is read to learn its repositories, each read under its owner'
: > "$FAKE/calls.txt"
run="$(cd "$clone" && bash "$ROOT/bin/status-sync.sh" --project "$PROJECT_NUMBER" --dry-run 2>&1)"
check 'exit 0' 0 "$?"
check 'the board is read once' 1 "$(grep -c 'items(first:100, after:' "$FAKE/calls.txt")"
check 'a repository of another organisation is read under its owner' 1 "$(grep -c 'graphql -f o=other-org -f n=example-repo' "$FAKE/calls.txt")"
check 'its card is counted' "20 active cards scanned, 4 would move on board $PROJECT_NUMBER." "$(printf '%s\n' "$run" | tail -1)"

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
check '#31 is closed' 1 "$(grep -c 'api --method PATCH repos/example-org/example-repo/issues/31 ' "$FAKE/calls.txt")"
check 'and no other issue' 3 "$(grep -c 'api --method PATCH repos/.*/issues/' "$FAKE/calls.txt")"
check 'the cards no release carries are named here too' 2 "$(grep -c '^not released' <<< "$run")"
check 'a card named "not finished" is named here too' 3 "$(grep -c '^not finished' <<< "$run")"
# Each mover looks the repository up on a board first, and here the stand-in has none and stops it
# before it names an issue, so the lookups count the movers: the three closes and the sweep's own
check 'and no card is moved or closed for being named: no mover runs beyond the three closes' 4 "$(grep -c 'projectsV2(first:50)' "$FAKE/calls.txt")"
rm -f "$FAKE/lenient"

echo 'a config.env of the repository or of the project folder that is there and cannot be read: the sweep stops, names it, and closes, labels and moves nothing from a default'
. "$ROOT/tests/unreadable.sh"
old_reader_copy "$ROOT" "$FAKE/old-reader" || { echo "  FAIL no copy of the harness with the old reader"; failed=$((failed + 1)); }
applied_sweep() {  # applied_sweep <harness root>: the real sweep of the repository in $clone, its output then a last line rc=<n>; the calls it made are in $FAKE/calls.txt
  local out rc=0
  : > "$FAKE/calls.txt"; touch "$FAKE/lenient"
  out="$(cd "$clone" && bash "$1/bin/status-sync.sh" --project "$PROJECT_NUMBER" example-org/example-repo 2>&1)" || rc=$?
  rm -f "$FAKE/lenient"
  printf '%s\nrc=%s\n' "$out" "$rc"
}
stopped_without_a_write() {  # stopped_without_a_write <what applied_sweep printed> <file>: yes where the exit status is not 0, the file is named once, and not one call wrote
  if [ "$(tail -n1 <<< "$1")" != rc=0 ] && [ "$(grep -acF -- "$2 exists but cannot be read" <<< "$1")" = 1 ] \
    && [ "$(grep -cE -- '--method|mutation' "$FAKE/calls.txt")" = 0 ]; then echo yes; else echo no; fi
}
printf 'LIVE_TAGS="prod=deploy/prod/* test=deploy/test/*"\n' > "$clone/.ai-core/config.env"
got="$(applied_sweep "$ROOT")"
check 'innocent: where every config.env can be read the three cards are closed' "rc=0 3" "$(tail -n1 <<< "$got") $(grep -c 'api --method PATCH repos/.*/issues/' "$FAKE/calls.txt")"
make_unreadable "$clone/.ai-core/config.env" || { echo "  FAIL the config.env of the repository cannot be made unreadable"; failed=$((failed + 1)); }
got="$(applied_sweep "$ROOT")"
check 'the config.env of the repository: the sweep stops, names it once, and writes nothing' yes "$(stopped_without_a_write "$got" "$clone/.ai-core/config.env")"
got="$(applied_sweep "$FAKE/old-reader")"
check 'planted: with the old reader the repository is released by the newest tag and a card is closed from the default' no "$(stopped_without_a_write "$got" "$clone/.ai-core/config.env")"
chmod 600 "$clone/.ai-core/config.env"
: > "$clone/.ai-core/config.env"
make_unreadable "$FAKE/folder/.ai-core/config.env" || { echo "  FAIL the config.env of the project folder cannot be made unreadable"; failed=$((failed + 1)); }
got="$(applied_sweep "$ROOT")"
check 'the config.env of the project folder, which a repository that sets no list is read by: the sweep stops, names it once, and writes nothing' yes "$(stopped_without_a_write "$got" "$FAKE/folder/.ai-core/config.env")"
got="$(applied_sweep "$FAKE/old-reader")"
check 'planted: with the old reader the project folder is read as naming no environment and a card is closed' no "$(stopped_without_a_write "$got" "$FAKE/folder/.ai-core/config.env")"
chmod 600 "$FAKE/folder/.ai-core/config.env"
printf 'LIVE_TAGS="prod=deploy/prod/* test=deploy/test/*"\n' > "$FAKE/folder/.ai-core/config.env"
printf 'LIVE_TAGS="prod=deploy/prod/* test=deploy/test/*"\n' > "$clone/.ai-core/config.env"

echo 'a # inside the quotes of LIVE_TAGS belongs to the pattern, in the readers the sweep and status share'
printf 'LIVE_TAGS="prod=deploy/#/* test=deploy/test/*"  # the first environment is prod\n' > "$FAKE/hash.env"
check 'the Bash reader gives the value whole' 'prod=deploy/#/* test=deploy/test/*' "$(config_value_in_file "$FAKE/hash.env" LIVE_TAGS unset)"
git -C "$seed" tag 'deploy/#/1' "$c20"; git -C "$seed" push -q "$origin" 'deploy/#/1'
cp "$FAKE/hash.env" "$clone/.ai-core/config.env"
run="$(cd "$clone" && bash "$ROOT/bin/status-sync.sh" --project "$PROJECT_NUMBER" --dry-run example-org/example-repo 2>&1)"
check 'the sweep releases #13 by the tag deploy/#/1, the pattern of the first environment whole' \
  'would close  example-repo#13  (testing -> done, released in deploy/#/1 and proven)' "$(grep '^would close  example-repo#13' <<< "$run")"
cat > "$FAKE/old-first.sed" <<'SED'
s@^  line="\$(config_value_in_file "\$1" LIVE_TAGS "")" || return 1$@  line="$(grep -E '^[[:space:]]*LIVE_TAGS[[:space:]]*=' "$1" 2>/dev/null | tail -n1 || true)"; line="${line#*=}"; line="${line%%#*}"; line="${line//[\\"\\']/}"@
SED
sweep_mutant bin/status-sync.sh "$(cat "$FAKE/old-first.sed")"
check 'planted: the old first_environment stops at the # and keeps half the pattern, so #13 is released by no tag' no "$(grep -q '^would close  example-repo#13' <<< "$mutant_run" && echo yes || echo no)"
git -C "$seed" push -q "$origin" :refs/tags/'deploy/#/1'; git -C "$seed" tag -d 'deploy/#/1' > /dev/null; git -C "$clone" tag -d 'deploy/#/1' > /dev/null 2>&1 || true
printf 'LIVE_TAGS="prod=deploy/prod/* test=deploy/test/*"\n' > "$clone/.ai-core/config.env"

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

# finish-issue tells an issue once what landed (it adds no copy of a record the issue holds), and these are
# the two cards that rule leaves to this sweep: the record and the proof of a landing it did not repeat,
# and the proof of a landing that a later record of new work has left behind
echo 'a rerun of finish-issue adds no record, so the old record and its proof still close the card; a record of new work asks for a new proof'
cp "$FAKE/issues-1.json" "$FAKE/issues-1.saved"
page false null "$(issue 32 testing 0 "$(landed 2026-09-01T10:00:00Z "$c13"),$(proven 2026-09-02T10:00:00Z)"),$(issue 30 testing 0 "$(landed 2026-09-01T10:00:00Z "$c13"),$(proven 2026-09-02T10:00:00Z),$(landed 2026-09-03T10:00:00Z "$c18")"),$(issue 33 testing 0 "{\"createdAt\":\"2026-09-01T10:00:00Z\",\"authorAssociation\":\"NONE\",\"body\":\"Landed on master:\\n\\n- $(printf '%s' "$c13" | cut -c1-7) Its subject\"},$(proven 2026-09-02T10:00:00Z)")" > "$FAKE/issues-1.json"
run="$(cd "$clone" && bash "$ROOT/bin/status-sync.sh" --project "$PROJECT_NUMBER" --dry-run example-org/example-repo 2>&1)"
check 'exit 0' 0 "$?"
check 'one record and its proof close' 'would close  example-repo#32  (testing -> done, released in deploy/prod/2 and proven)' "$(grep '^would close  example-repo#32' <<< "$run")"
check 'a record after the proof is a landing the proof does not cover' \
  'proof due    example-repo#30  (released in deploy/prod/2, no "Proven on" record after its landing)' "$(grep '^proof due    example-repo#30' <<< "$run")"
check 'and it does not close' '' "$(grep '^would close  example-repo#30' <<< "$run")"
check 'a record by a stranger is no record' \
  'no landing   example-repo#33  (in testing, but no "Landed on" record names its work: where it landed, run ai-core finish-issue example-org/example-repo 33)' "$(grep '^no landing   example-repo#33' <<< "$run")"
mv "$FAKE/issues-1.saved" "$FAKE/issues-1.json"

# An epic ahead of a released and proven leaf, one of its sub-issues closed and the other still open with
# its card in done on this board. The epic is not done: it moves to testing, nothing closes it, and the
# sweep goes on to the leaf behind it, dry run and applied, and ends well
echo 'an epic with an open sub-issue in done is not closed by the sweep, and the sweep reaches the leaf behind it'
cp "$FAKE/issues-1.json" "$FAKE/issues-1.saved"
page false null "$(issue 34 implementing 2 ''),$(issue 35 testing 0 "$(landed 2026-09-01T10:00:00Z "$c13"),$(proven 2026-09-02T10:00:00Z)")" > "$FAKE/issues-1.json"
printf '{"data":{"repository":{"issue":{"state":"OPEN","stateReason":null,"projectItems":{"nodes":[{"project":{"number":%s,"owner":{"login":"example-org"}},"status":{"name":"implementing"}}]},"subIssues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"state":"CLOSED","stateReason":"COMPLETED","projectItems":{"nodes":[]}},{"state":"OPEN","stateReason":null,"projectItems":{"nodes":[{"project":{"number":%s,"owner":{"login":"example-org"}},"status":{"name":"done"}}]}}]}}}}}\n' \
  "$PROJECT_NUMBER" "$PROJECT_NUMBER" > "$FAKE/epic-34.json"
run="$(cd "$clone" && bash "$ROOT/bin/status-sync.sh" --project "$PROJECT_NUMBER" --dry-run example-org/example-repo 2>&1)"
check 'dry run: exit 0' 0 "$?"
check 'dry run: the epic would move to testing' 'would move   example-repo#34  (implementing -> testing)' "$(grep '^would move   example-repo#34' <<< "$run")"
check 'dry run: the epic is not reported closed' '' "$(grep -E '^(would close|close) +example-repo#34' <<< "$run")"
check 'dry run: the leaf behind it is reached' 'would close  example-repo#35  (testing -> done, released in deploy/prod/2 and proven)' "$(grep '^would close  example-repo#35' <<< "$run")"
: > "$FAKE/calls.txt"; touch "$FAKE/lenient"
run="$(cd "$clone" && bash "$ROOT/bin/status-sync.sh" --project "$PROJECT_NUMBER" example-org/example-repo 2>&1)"; rc=$?
rm -f "$FAKE/lenient"
check 'applied: exit 0' 0 "$rc"
check 'applied: the epic is moved, not closed' 'move         example-repo#34  (implementing -> testing)' "$(grep -E '^(move|close) +example-repo#34' <<< "$run")"
check 'applied: the leaf behind it is closed' 'close        example-repo#35  (testing -> done, released in deploy/prod/2 and proven)' "$(grep '^close        example-repo#35' <<< "$run")"
check 'applied: the leaf was sent its close' 1 "$(grep -c 'api --method PATCH repos/example-org/example-repo/issues/35 ' "$FAKE/calls.txt")"
check 'applied: the epic was sent none' 0 "$(grep -c 'api --method PATCH repos/example-org/example-repo/issues/34 ' "$FAKE/calls.txt")"
check 'applied: nothing says the sweep failed' '' "$(grep -iE 'error|did NOT' <<< "$run")"
rm -f "$FAKE/epic-34.json"; mv "$FAKE/issues-1.saved" "$FAKE/issues-1.json"

# --- environments delivered by a project's own reader (LIVE_TAGS "prod=command") ----------------------
#
# Two repositories that are never tagged for their release, and what carries them out:
#   example-org/component  is released by a carrier: a separate repository whose tags prod/N and test/N each
#       hold a file pins/component naming the commit of the component the release ships. Its reader reads
#       that file AT THE TAG, never at the carrier's tip, which pins another commit than the newest release.
#       The component has a stale tag of its own, deploy/prod/0, that a tag glob would read.
#   example-org/service    is released by a redeploy: its reader reads the run records in $FAKE/runs.jsonl,
#       the last successful run, whatever came after it.
# Both readers are real executables over real scratch Git objects and planted records; the cards are the
# ones of example-repo, whose own tags are no part of it, and a card of the component itself.
#
# THE CARDS, all in testing, their work landed in the component unless written otherwise:
#   101 proven on prod after the delivery -> closes while the carrier's newest release pins its commit
#   102 landed after the pin of release 1 -> not released, with that release; 103 no proof -> proof due
#   104 proof AT the delivery's second, 105 on another environment, 106 before its landing, 107 between its
#       landing and the delivery, 109 by a stranger: none of them proves; 108 a fraction of a second after
#       the delivery's second does
#   110 "Proven on PROD:" and 111 "Proven on prod (https://example.test):" prove; 112 production, 113 prod-extra,
#       114 "test (prod)", 115 no colon, 116 an annotation and no colon after it, 117 the words in a later line,
#       118 behind a heading do not
#   120 landed on a branch that is not the default branch -> named, as having no landing on it
#   124 landed after what release 1 pins, proven on test only -> only the first environment decides
#   130 to 132 landed in the service; 140 is the component's own card
#   150 has no "Landed on" record at all, 151 a record whose time is no time: 150 is named as having no landing, 151 as unknown
echo 'a repository released by a carrier that pins it: the delivery is what the carrier'"'"'s release holds, and the proof must follow it'
carrier="$FAKE/carrier"; component_origin="$FAKE/remote/example-org/component.git"; component="$FAKE/folder/component"
service_origin="$FAKE/remote/example-org/service.git"; service="$FAKE/folder/service"
git init -q --bare "$component_origin"; git init -q "$FAKE/component-seed"; git -C "$FAKE/component-seed" checkout -q -b master
k0="$(commit_at "$FAKE/component-seed" 1700000100 'Before the pins')"; tag_at "$FAKE/component-seed" deploy/prod/0 1700000100
k1="$(commit_at "$FAKE/component-seed" 1700000101 'Land #101 and the rest')"
k2="$(commit_at "$FAKE/component-seed" 1700000102 'Land #102')"
k3="$(commit_at "$FAKE/component-seed" 1700000103 'Land #124 on the tip')"
git -C "$FAKE/component-seed" checkout -q -b side "$k1"; kx="$(commit_at "$FAKE/component-seed" 1700000104 'Work on a branch')"
git -C "$FAKE/component-seed" push -q "$component_origin" master side --tags
git -C "$component_origin" symbolic-ref HEAD refs/heads/master
git clone -q "$component_origin" "$component"
git -C "$component" tag -l | xargs -r git -C "$component" tag -d >/dev/null
git init -q --bare "$service_origin"; git init -q "$FAKE/service-seed"; git -C "$FAKE/service-seed" checkout -q -b master
s1="$(commit_at "$FAKE/service-seed" 1700000201 'Land #130')"; s2="$(commit_at "$FAKE/service-seed" 1700000202 'Land #131')"; s3="$(commit_at "$FAKE/service-seed" 1700000203 'Land #132')"
git -C "$FAKE/service-seed" push -q "$service_origin" master
git -C "$service_origin" symbolic-ref HEAD refs/heads/master
git clone -q "$service_origin" "$service"
# the carrier: each release is a commit that sets the pin, tagged on its own date; its tip pins the commit of the tip
git init -q "$carrier"; git -C "$carrier" checkout -q -b master; mkdir -p "$carrier/pins"
release_at() {  # release_at <tag> <pinned commit> <ISO time>: the carrier's release, a commit and an annotated tag at that time
  printf '%s\n' "$2" > "$carrier/pins/component"; git -C "$carrier" add -A
  GIT_AUTHOR_DATE="$3" GIT_COMMITTER_DATE="$3" gitc "$carrier" commit -q -m "release $1"
  GIT_COMMITTER_DATE="$3" gitc "$carrier" tag -a -m "$1" "$1"
}
release_at prod/1 "$k1" 2026-09-02T08:00:00Z
release_at test/1 "$k3" 2026-09-02T08:00:00Z
mkdir -p "$component/tools" "$service/tools"
cat > "$component/tools/read pin" <<EOF
#!/usr/bin/env bash
# the reader of a carrier that pins the component: the pin of the newest release of the environment, read at the release
echo "\$PWD|\$#|\$1|\$2" >> "$FAKE/reader-calls.txt"
if [ "\$(cat "$FAKE/pin-mode" 2>/dev/null)" = fail ]; then echo 'the carrier is down' >&2; exit 3; fi
tag="\$(git -C "$carrier" tag --list "\$2/*" --sort=-creatordate | head -n1)"
[ -n "\$tag" ] || { echo null; exit 0; }
at="\$(TZ=UTC git -C "$carrier" for-each-ref --format='%(creatordate:iso-strict)' "refs/tags/\$tag" | sed 's/+00:00\$/Z/')"
printf '{"repository":"%s","environment":"%s","commit":"%s","releasedAt":"%s","source":"carrier %s"}\n' "\$1" "\$2" "\$(git -C "$carrier" show "\$tag:pins/component")" "\$at" "\$tag"
EOF
cat > "$service/tools/read-run" <<EOF
#!/usr/bin/env bash
# the reader of a redeploy: the last successful run of the environment in the run records
echo "\$PWD|\$#|\$1|\$2" >> "$FAKE/reader-calls.txt"
last="\$(jq -c --arg e "\$2" 'select(.environment == \$e and .status == "success")' "$FAKE/runs.jsonl" | tail -n1)"
[ -n "\$last" ] || { echo null; exit 0; }
jq -c --arg r "\$1" '{repository: \$r, environment, commit, releasedAt: .finishedAt, source: .run}' <<< "\$last"
EOF
chmod +x "$component/tools/read pin" "$service/tools/read-run"
mkdir -p "$component/.ai-core" "$service/.ai-core"
printf 'LIVE_TAGS="prod=command test=command"\nLIVE_RELEASE_COMMAND="tools/read pin"\n' > "$component/.ai-core/config.env"
printf 'LIVE_TAGS="prod=command"\nLIVE_RELEASE_COMMAND="tools/read-run"\n' > "$service/.ai-core/config.env"
: > "$FAKE/runs.jsonl"

proof_at() {  # proof_at <time> <first line> [author association] [a second line]
  printf '{"createdAt":"%s","authorAssociation":"%s","body":"%s%s"}' "$1" "${3:-MEMBER}" "$2" "${4:+\\n$4}"
}
card_of() {  # card_of <number> <commit> <repository the work landed in> [proof]: a card of example-repo in testing
  issue "$1" testing 0 "$(landed 2026-09-01T10:00:00Z "$2" "$3")${4:+,$4}"
}
P=example-org/component
cmd_cards() {  # the page of example-repo: every card of the block
  page false null "$(card_of 101 "$k1" $P "$(proof_at 2026-09-03T10:00:00Z 'Proven on prod:')"),$(card_of 102 "$k2" $P "$(proof_at 2026-09-03T10:00:00Z 'Proven on prod:')"),$(card_of 103 "$k1" $P),$(card_of 104 "$k1" $P "$(proof_at 2026-09-02T08:00:00Z 'Proven on prod:')"),$(card_of 105 "$k1" $P "$(proof_at 2026-09-03T10:00:00Z 'Proven on test:')"),$(card_of 106 "$k1" $P "$(proof_at 2026-08-30T10:00:00Z 'Proven on prod:')"),$(card_of 107 "$k1" $P "$(proof_at 2026-09-01T12:00:00Z 'Proven on prod:')"),$(card_of 108 "$k1" $P "$(proof_at 2026-09-02T08:00:00.500Z 'Proven on prod:')"),$(card_of 109 "$k1" $P "$(proof_at 2026-09-03T10:00:00Z 'Proven on prod:' NONE)"),$(card_of 110 "$k1" $P "$(proof_at 2026-09-03T10:00:00Z 'Proven on PROD:')"),$(card_of 111 "$k1" $P "$(proof_at 2026-09-03T10:00:00Z 'Proven on prod (https://example.test):')"),$(card_of 112 "$k1" $P "$(proof_at 2026-09-03T10:00:00Z 'Proven on production:')"),$(card_of 113 "$k1" $P "$(proof_at 2026-09-03T10:00:00Z 'Proven on prod-extra:')"),$(card_of 114 "$k1" $P "$(proof_at 2026-09-03T10:00:00Z 'Proven on test (prod):')"),$(card_of 115 "$k1" $P "$(proof_at 2026-09-03T10:00:00Z 'Proven on prod')"),$(card_of 116 "$k1" $P "$(proof_at 2026-09-03T10:00:00Z 'Proven on prod (https://example.test)')"),$(card_of 117 "$k1" $P "$(proof_at 2026-09-03T10:00:00Z 'Verified by hand:' 'Proven on prod:')"),$(card_of 118 "$k1" $P "$(proof_at 2026-09-03T10:00:00Z '# Proven on prod:')"),$(card_of 120 "$kx" $P "$(proof_at 2026-09-03T10:00:00Z 'Proven on prod:')"),$(card_of 122 "$k2" $P "$(proof_at 2026-09-05T10:00:00Z 'Proven on prod:')"),$(card_of 123 "$k1" $P "$(proof_at 2026-09-07T10:00:00Z 'Proven on prod:')"),$(card_of 124 "$k3" $P "$(proof_at 2026-09-03T10:00:00Z 'Proven on test:')"),$(card_of 130 "$s1" example-org/service "$(proof_at 2026-09-03T10:00:00Z 'Proven on prod:')"),$(card_of 131 "$s2" example-org/service "$(proof_at 2026-09-06T10:00:00Z 'Proven on prod:')"),$(card_of 132 "$s3" example-org/service "$(proof_at 2026-09-06T10:00:00Z 'Proven on prod:')"),$(issue 150 testing 0 ''),$(issue 151 testing 0 "$(landed 'not a time' "$k1" $P)")" > "$FAKE/issues-1.json"
  page false null "$(issue 140 testing 0 "$(landed 2026-09-01T10:00:00Z "$k1"),$(proof_at 2026-09-03T10:00:00Z 'Proven on prod:')")" > "$FAKE/issues-component.json"
}
cp "$FAKE/issues-1.json" "$FAKE/issues-1.saved"
cmd_cards
sync_dry() { run="$(cd "$clone" && bash "$ROOT/bin/status-sync.sh" --project "$PROJECT_NUMBER" --dry-run example-org/example-repo example-org/component 2>&1)"; rc=$?; }
said() { grep " example-repo#$1  (" <<< "$run" || true; }   # the line of a card of example-repo
at1='example-org/component prod delivery carrier prod/1 at 2026-09-02T08:00:00Z'
due1="released in $at1, no \"Proven on prod\" record after both its landing and that delivery"
: > "$FAKE/calls.txt"; : > "$FAKE/reader-calls.txt"
sync_dry
check 'exit 0' 0 "$rc"
check 'proven after the delivery of the carrier release that pins its commit: it would close, with the carrier release named' \
  "would close  example-repo#101  (testing -> done, released in $at1 and proven)" "$(said 101)"
check 'landed after the pinned commit: not released, with the release it read, and the stale tag of the component is no release' \
  "not released example-repo#102  (landed in $(printf '%s' "$k2" | cut -c1-7); the newest prod delivery of example-org/component, carrier prod/1 at 2026-09-02T08:00:00Z, does not carry it)" "$(said 102)"
check 'delivered and not proven: proof due' "proof due    example-repo#103  ($due1)" "$(said 103)"
for n in 104 105 106 107 109 112 113 114 115 116 117 118; do
  check "#$n has no proof that qualifies: proof due, never close" "proof due    example-repo#$n  ($due1)" "$(said $n)"
done
check 'a proof a fraction of a second after the second of the delivery qualifies, and one at that second does not' \
  "would close  example-repo#108  (testing -> done, released in $at1 and proven)" "$(said 108)"
check 'the environment of the proof is read whatever its case' "would close  example-repo#110  (testing -> done, released in $at1 and proven)" "$(said 110)"
check 'and with an annotation, whose colon is no delimiter' "would close  example-repo#111  (testing -> done, released in $at1 and proven)" "$(said 111)"
check 'a landing that is not on the default branch is named, with the commit and the branch it is not on' \
  "no landing   example-repo#120  (in testing, but its \"Landed on\" record names $(printf '%s' "$kx" | cut -c1-7), which origin/master of example-org/component does not hold: where it landed, run ai-core finish-issue example-org/example-repo 120)" "$(said 120)"
check 'a card with no landing record at all is named as having none, never as one whose landing time cannot be read' \
  "no landing   example-repo#150  (in testing, but no \"Landed on\" record names its work: where it landed, run ai-core finish-issue example-org/example-repo 150)" "$(said 150)"
check 'a record whose time cannot be read is unknown, and the line says that it is the time' \
  "unknown      example-repo#151  (the time of its \"Landed on\" record cannot be read, so no proof is compared with it; the card stays)" "$(said 151)"
check 'only the first environment decides: a card proven on test and not on prod stays, though the carrier delivered test' \
  "not released example-repo#124  (landed in $(printf '%s' "$k3" | cut -c1-7); the newest prod delivery of example-org/component, carrier prod/1 at 2026-09-02T08:00:00Z, does not carry it)" "$(said 124)"
check 'the card of the component itself is read the same way' \
  "would close  component#140  (testing -> done, released in prod delivery carrier prod/1 at 2026-09-02T08:00:00Z and proven)" "$(grep '^would close  component#140' <<< "$run")"
check 'a read of the cards and a read of the carrier write nothing, and the carrier was asked once for the environment of the component, in its clone, with two arguments' \
  "0|1|$component|2|example-org/component|prod|0" \
  "$(grep -c -- '--method' "$FAKE/calls.txt")|$(grep -c "^$component|" "$FAKE/reader-calls.txt")|$(grep -m1 "^$component|" "$FAKE/reader-calls.txt")|$(grep "^$component|" "$FAKE/reader-calls.txt" | grep -vc '|prod$')"
ss="$FAKE/ss"; rm -rf "$ss"; mkdir -p "$ss"; cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/templates" "$ss/"; cp "$ROOT/VERSION" "$ss/"
sed -i.bak 's/^      if \[ "\$sha" = - \]; then$/      if false; then/' "$ss/bin/status-sync.sh"
cmp -s "$ROOT/bin/status-sync.sh" "$ss/bin/status-sync.sh" && { echo "  FAIL the planted copy equals bin/status-sync.sh"; failed=$((failed + 1)); }
planted_run="$(cd "$clone" && bash "$ss/bin/status-sync.sh" --project "$PROJECT_NUMBER" --dry-run example-org/example-repo example-org/component 2>&1)"
check 'planted: without its check for a missing landing, the card with none is no longer named as that' no "$([ "$(grep ' example-repo#150  (' <<< "$planted_run")" = "$(said 150)" ] && echo yes || echo no)"
check 'and the card with an unreadable time is named as before' "$(said 151)" "$(grep ' example-repo#151  (' <<< "$planted_run" || true)"

echo 'a new release moves the delivery, and a proof before it proves nothing of it'
release_at prod/2 "$k2" 2026-09-04T08:00:00Z
release_at test/2 "$k3" 2026-09-04T09:00:00Z
sync_dry
at2='example-org/component prod delivery carrier prod/2 at 2026-09-04T08:00:00Z'
check 'the commit of the release before it is carried as well, and its proof of 09-03 came before this delivery' \
  "proof due    example-repo#101  (released in $at2, no \"Proven on prod\" record after both its landing and that delivery)" "$(said 101)"
check 'a card the new release carries and a proof that follows it close' "would close  example-repo#122  (testing -> done, released in $at2 and proven)" "$(said 122)"
check 'the release is read at its tag: the tip of the carrier, a release of test, pins the commit of #124, and #124 stays out' \
  "not released example-repo#124  (landed in $(printf '%s' "$k3" | cut -c1-7); the newest prod delivery of example-org/component, carrier prod/2 at 2026-09-04T08:00:00Z, does not carry it)" "$(said 124)"

echo 'a rollback is a delivery of an older commit, and nothing remembers the one before'
release_at prod/3 "$k1" 2026-09-06T08:00:00Z
sync_dry
at3='example-org/component prod delivery carrier prod/3 at 2026-09-06T08:00:00Z'
check 'what the rollback no longer holds is not released again' \
  "not released example-repo#122  (landed in $(printf '%s' "$k2" | cut -c1-7); the newest prod delivery of example-org/component, carrier prod/3 at 2026-09-06T08:00:00Z, does not carry it)" "$(said 122)"
check 'what it holds and a proof after the rollback closes' "would close  example-repo#123  (testing -> done, released in $at3 and proven)" "$(said 123)"

echo 'a pin that is no commit of the component: every card of it is unknown, and none closes'
carrier_commit="$(git -C "$carrier" rev-parse HEAD)"
release_at prod/4 "$carrier_commit" 2026-09-08T08:00:00Z
sync_dry
check 'a commit of the carrier'"'"'s own graph is named, not read as no delivery' \
  "unknown      example-repo#123  (the reader $component/tools/read pin answered for example-org/component prod with the commit $carrier_commit, and the clone $component, fetched, has no such commit; the card stays)" "$(said 123)"
check 'and nothing of it closes or is due' '' "$(grep -E '^(would close|proof due|not released) +example-repo#1(0[1-9]|1[0-9]|2[0-4]) ' <<< "$run")"
git -C "$carrier" tag -d prod/4 >/dev/null
printf 'fail\n' > "$FAKE/pin-mode"
sync_dry
check 'a reader that fails is unknown, with its own words, though a stale tag of the component holds the commit of the card' \
  "unknown      example-repo#103  (the reader $component/tools/read pin exited 3 for example-org/component prod: the carrier is down; the card stays)" "$(said 103)"
check 'and no card of it closes' '' "$(grep -E '^would close +example-repo#1' <<< "$run")"
rm -f "$FAKE/pin-mode"
git -C "$component" remote set-url origin "$FAKE/gone/example-org/component.git"
sync_dry
check 'a fetch that fails leaves the delivery unread, whatever the refs the clone has' \
  "unknown      example-repo#103  (fetching origin of example-org/component in $shown/component failed: fatal: '$FAKE/gone/example-org/component.git' does not appear to be a git repository, so the delivery of prod is not read; the card stays)" "$(said 103)"
git -C "$component" remote set-url origin "$component_origin"

echo 'a failed fetch keeps the first error and ignores bytes after it'
real_git="$(command -v git)"
mkdir -p "$FAKE/fetch-bin"
{
  printf 'fatal: first error\n'
  for ((n = 0; n < 10000; n++)); do printf 'progress\n'; done
  printf 'fatal: bad\377text\n'
} > "$FAKE/fetch-error"
cat > "$FAKE/fetch-bin/git" <<EOF
#!/usr/bin/env bash
if [ "\${3:-}" = fetch ] && [ "\${2:-}" = "$component" ]; then cat "$FAKE/fetch-error" >&2; exit 1; fi
exec "$real_git" "\$@"
EOF
chmod +x "$FAKE/fetch-bin/git"
PATH="$FAKE/fetch-bin:$PATH" LC_ALL=C.UTF-8 sync_dry
check 'the fetch error keeps its first line' \
  "unknown      example-repo#103  (fetching origin of example-org/component in $shown/component failed: fatal: first error, so the delivery of prod is not read; the card stays)" "$(said 103)"
check 'later bytes do not print a second diagnostic' '' "$(grep 'binary file matches' <<< "$run")"

echo 'a repository delivered by a redeploy: the last successful run decides, never an attempt, a failure or the tip of the default branch'
run_at() {  # run_at <number> <status> <commit> <finish time or empty>
  jq -cn --arg n "$1" --arg s "$2" --arg c "$3" --arg t "$4" '{environment: "prod", status: $s, commit: $c, run: ("run " + $n), finishedAt: (if $t == "" then null else $t end)}' >> "$FAKE/runs.jsonl"
}
sync_dry
check 'no run at all: not released, the missing delivery named' \
  "not released example-repo#130  (landed in $(printf '%s' "$s1" | cut -c1-7); no completed prod delivery of example-org/service is recorded)" "$(said 130)"
run_at 1 success "$s1" 2026-09-02T09:00:00Z
sync_dry
sv1='example-org/service prod delivery run 1 at 2026-09-02T09:00:00Z'
check 'a successful run of the commit, proven later: it would close' "would close  example-repo#130  (testing -> done, released in $sv1 and proven)" "$(said 130)"
check 'a later commit than the run fetched is not carried by it' \
  "not released example-repo#131  (landed in $(printf '%s' "$s2" | cut -c1-7); the newest prod delivery of example-org/service, run 1 at 2026-09-02T09:00:00Z, does not carry it)" "$(said 131)"
run_at 2 failure "$s2" 2026-09-04T09:00:00Z
run_at 3 pending "$s3" ""
sync_dry
check 'a failed run and a pending one deliver nothing' \
  "not released example-repo#131  (landed in $(printf '%s' "$s2" | cut -c1-7); the newest prod delivery of example-org/service, run 1 at 2026-09-02T09:00:00Z, does not carry it)" "$(said 131)"
check 'and the tip of the default branch is no delivery' \
  "not released example-repo#132  (landed in $(printf '%s' "$s3" | cut -c1-7); the newest prod delivery of example-org/service, run 1 at 2026-09-02T09:00:00Z, does not carry it)" "$(said 132)"
run_at 4 success "$s2" 2026-09-05T09:00:00Z
sync_dry
sv4='example-org/service prod delivery run 4 at 2026-09-05T09:00:00Z'
check 'the later successful run carries the card, and its proof of 09-06 follows' "would close  example-repo#131  (testing -> done, released in $sv4 and proven)" "$(said 131)"
check 'the card of the run before it has a proof from before this delivery' \
  "proof due    example-repo#130  (released in $sv4, no \"Proven on prod\" record after both its landing and that delivery)" "$(said 130)"
run_at 5 success "$s1" 2026-09-07T09:00:00Z
sync_dry
check 'a rollback run takes the commit it fetched, and the card it no longer holds is not released' \
  "not released example-repo#131  (landed in $(printf '%s' "$s2" | cut -c1-7); the newest prod delivery of example-org/service, run 5 at 2026-09-07T09:00:00Z, does not carry it)" "$(said 131)"

echo 'closing happens in the clone of the repository that owns the card, and a second applied run invents no other transition'
: > "$FAKE/calls.txt"; touch "$FAKE/lenient"
run="$(cd "$clone" && bash "$ROOT/bin/status-sync.sh" --project "$PROJECT_NUMBER" example-org/example-repo 2>&1)"; rc=$?
first_run="$run"
check 'applied: exit 0' 0 "$rc"
check 'applied: the card the rollback delivered and a proof followed closes' "close        example-repo#123  (testing -> done, released in $at3 and proven)" "$(said 123)"
check 'applied: only the owning repository was written, and only that issue' \
  "1|1|0" "$(grep -c 'api --method PATCH repos/example-org/example-repo/issues/123 ' "$FAKE/calls.txt")|$(grep -c -- '--method PATCH' "$FAKE/calls.txt")|$(grep -c 'api --method PATCH repos/example-org/\(component\|service\)/' "$FAKE/calls.txt")"
: > "$FAKE/calls.txt"
run="$(cd "$clone" && bash "$ROOT/bin/status-sync.sh" --project "$PROJECT_NUMBER" example-org/example-repo 2>&1)"; rc=$?
rm -f "$FAKE/lenient"
check 'a second applied run says the same and writes the same one close' "0|1" "$([ "$run" = "$first_run" ] && echo 0 || echo 1)|$(grep -c -- '--method PATCH' "$FAKE/calls.txt")"

echo 'two sweeps at once keep their own evidence: each reader waits until the other has started, and each answers its own repository'
mkdir -p "$FAKE/barrier"
wrap_reader() {  # wrap_reader <reader> <its name> <the other's name>: the reader that starts, waits for the other one to have started, and then answers as it did
  mv "$1" "$1.real"
  cat > "$1" <<EOF
#!/usr/bin/env bash
touch "$FAKE/barrier/$2"
for i in \$(seq 1 100); do [ -e "$FAKE/barrier/$3" ] && break; sleep 0.2; done
[ -e "$FAKE/barrier/$3" ] && echo seen > "$FAKE/barrier/seen-$2"
exec "$1.real" "\$@"
EOF
  chmod +x "$1"
}
wrap_reader "$component/tools/read pin" component service
wrap_reader "$service/tools/read-run" service component
rm -f "$FAKE/barrier"/*
page false null "$(card_of 130 "$s1" example-org/service "$(proof_at 2026-09-08T10:00:00Z 'Proven on prod:')")" > "$FAKE/issues-1.json"
page false null "$(issue 141 testing 0 "$(landed 2026-09-01T10:00:00Z "$k1"),$(proof_at 2026-09-07T10:00:00Z 'Proven on prod:')")" > "$FAKE/issues-component.json"
( cd "$clone" && bash "$ROOT/bin/status-sync.sh" --project "$PROJECT_NUMBER" --dry-run example-org/example-repo > "$FAKE/sweep-service.txt" 2>&1 ) &
first_pid=$!
( cd "$clone" && bash "$ROOT/bin/status-sync.sh" --project "$PROJECT_NUMBER" --dry-run example-org/component > "$FAKE/sweep-component.txt" 2>&1 ) &
second_pid=$!
wait "$first_pid" "$second_pid"
check 'each reader saw the other running before it answered' 'seen|seen' "$(cat "$FAKE/barrier/seen-component" 2>/dev/null)|$(cat "$FAKE/barrier/seen-service" 2>/dev/null)"
check 'the sweep of the service answered its own card' "would close  example-repo#130  (testing -> done, released in example-org/service prod delivery run 5 at 2026-09-07T09:00:00Z and proven)" \
  "$(grep '^would close  example-repo#130' "$FAKE/sweep-service.txt")"
check 'the sweep of the component answered its own card' "would close  component#141  (testing -> done, released in prod delivery carrier prod/3 at 2026-09-06T08:00:00Z and proven)" "$(grep '^would close  component#141' "$FAKE/sweep-component.txt")"
check 'neither sweep names a card of the other' '' "$(grep -h 'component#141' "$FAKE/sweep-service.txt"; grep -h 'example-repo#130' "$FAKE/sweep-component.txt")"
mv "$component/tools/read pin.real" "$component/tools/read pin"; mv "$service/tools/read-run.real" "$service/tools/read-run"
cp "$FAKE/issues-1.saved" "$FAKE/issues-1.json"; rm -f "$FAKE/issues-component.json"

echo 'a repository that sets its own LIVE_TAGS is released by them: a glob over its tags, and prod=landed, as status reads them'
plug_origin="$FAKE/remote/example-org/plug.git"; plug="$FAKE/folder/plug"
git init -q --bare "$plug_origin"; git init -q "$FAKE/plug-seed"; git -C "$FAKE/plug-seed" checkout -q -b master
p1="$(commit_at "$FAKE/plug-seed" 1700000301 'Land #201')"; tag_at "$FAKE/plug-seed" 0.5.022-stable-20261021150415 1700000301
p2="$(commit_at "$FAKE/plug-seed" 1700000302 'Land #202')"
git -C "$FAKE/plug-seed" push -q "$plug_origin" master --tags; git -C "$plug_origin" symbolic-ref HEAD refs/heads/master
git clone -q "$plug_origin" "$plug"; git -C "$plug" tag -l | xargs -r git -C "$plug" tag -d >/dev/null
mkdir -p "$plug/.ai-core"; printf 'LIVE_TAGS="prod=[0-9]*-stable-*"\n' > "$plug/.ai-core/config.env"
lnd_origin="$FAKE/remote/example-org/lnd.git"; lnd="$FAKE/folder/lnd"
git init -q --bare "$lnd_origin"; git init -q "$FAKE/lnd-seed"; git -C "$FAKE/lnd-seed" checkout -q -b master
l1="$(commit_at "$FAKE/lnd-seed" 1700000303 'Land #203')"
git -C "$FAKE/lnd-seed" push -q "$lnd_origin" master; git -C "$lnd_origin" symbolic-ref HEAD refs/heads/master
git clone -q "$lnd_origin" "$lnd"; mkdir -p "$lnd/.ai-core"; printf 'LIVE_TAGS="prod=landed"\n' > "$lnd/.ai-core/config.env"
page false null "$(card_of 201 "$p1" example-org/plug "$(proof_at 2026-09-03T10:00:00Z 'Proven on prod:')"),$(card_of 202 "$p2" example-org/plug "$(proof_at 2026-09-03T10:00:00Z 'Proven on prod:')"),$(card_of 203 "$l1" example-org/lnd "$(proof_at 2026-09-03T10:00:00Z 'Proven on prod:')")" > "$FAKE/issues-1.json"
run="$(cd "$clone" && bash "$ROOT/bin/status-sync.sh" --project "$PROJECT_NUMBER" --dry-run example-org/example-repo 2>&1)"; rc=$?
check 'exit 0' 0 "$rc"
check 'a tag of the glob of the repository'"'"'s own list carries its card, which closes' \
  'would close  example-repo#201  (testing -> done, released in example-org/plug 0.5.022-stable-20261021150415 and proven)' "$(grep '^would close  example-repo#201' <<< "$run")"
check 'a commit after that tag is not carried, and the tag named is the one of the repository'"'"'s own list' \
  "not released example-repo#202  (landed in $(printf '%s' "$p2" | cut -c1-7); the newest prod release 0.5.022-stable-20261021150415 of example-org/plug does not carry it)" "$(grep '^not released example-repo#202' <<< "$run")"
check 'a repository that says prod=landed releases its card from its landing' \
  'would close  example-repo#203  (testing -> done, released in example-org/lnd its landing on origin/master and proven)' "$(grep '^would close  example-repo#203' <<< "$run")"
sweep_mutant bin/status-sync.sh 's/^    word="\$(first_environment "\$REL_CLONE\/.ai-core\/config.env")" || exit 1$/    word=""/'
check 'planted: the list of the checkout for every clone leaves the repository that sets its own list unreleased, #201 and #203 do not close' 'no no' \
  "$(grep -q '^would close  example-repo#201' <<< "$mutant_run" && echo yes || echo no) $(grep -q '^would close  example-repo#203' <<< "$mutant_run" && echo yes || echo no)"
cp "$FAKE/issues-1.saved" "$FAKE/issues-1.json"

echo 'a repository that sets no LIVE_TAGS is released by the list of the project folder, whichever checkout runs the sweep, and not by its newest tag of all'
# relay sets none; its newest tag, deploy/test/1, holds #211, and the only tag of the first environment of the folder's list, deploy/prod/1, stands on #210.
# The sweep of its own cards runs from the folder and from inside relay itself, as finish-issue and start-issue run it, and so does the sweep of cards of example-repo whose work landed in relay,
# the second also from inside a clone whose own list is another one
relay_origin="$FAKE/remote/example-org/relay.git"; relay="$FAKE/folder/relay"
git init -q --bare "$relay_origin"; git init -q "$FAKE/relay-seed"; git -C "$FAKE/relay-seed" checkout -q -b master
y0="$(commit_at "$FAKE/relay-seed" 1700000401 'Land #210')"; tag_at "$FAKE/relay-seed" deploy/prod/1 1700000401
y1="$(commit_at "$FAKE/relay-seed" 1700000402 'Land #211')"; tag_at "$FAKE/relay-seed" deploy/test/1 1700000402
git -C "$FAKE/relay-seed" push -q "$relay_origin" master --tags; git -C "$relay_origin" symbolic-ref HEAD refs/heads/master
git clone -q "$relay_origin" "$relay"; git -C "$relay" tag -l | xargs -r git -C "$relay" tag -d >/dev/null
mkdir -p "$relay/.ai-core"; printf 'LIVE_TAGS=""\n' > "$relay/.ai-core/config.env"
printf 'LIVE_TAGS="prod=deploy/test/*"\n' > "$clone/.ai-core/config.env"
page false null "$(card_of 210 "$y0" example-org/relay "$(proof_at 2026-09-03T10:00:00Z 'Proven on prod:')"),$(card_of 211 "$y1" example-org/relay "$(proof_at 2026-09-03T10:00:00Z 'Proven on test:')")" > "$FAKE/issues-1.json"
page false null "$(issue 210 testing 0 "$(landed 2026-09-01T10:00:00Z "$y0"),$(proof_at 2026-09-03T10:00:00Z 'Proven on prod:')"),$(issue 211 testing 0 "$(landed 2026-09-01T10:00:00Z "$y1"),$(proof_at 2026-09-03T10:00:00Z 'Proven on test:')")" > "$FAKE/issues-relay.json"
want_210='would close  example-repo#210  (testing -> done, released in example-org/relay deploy/prod/1 and proven)
would close  relay#210  (testing -> done, released in deploy/prod/1 and proven)'
want_211="not released example-repo#211  (landed in $(printf '%s' "$y1" | cut -c1-7); the newest prod release deploy/prod/1 of example-org/relay does not carry it)
not released relay#211  (landed in $(printf '%s' "$y1" | cut -c1-7); the newest prod release deploy/prod/1 does not carry it)"
for from in "$FAKE/folder" "$relay" "$clone"; do
  run="$(cd "$from" && bash "$ROOT/bin/status-sync.sh" --project "$PROJECT_NUMBER" --dry-run example-org/example-repo example-org/relay 2>&1)"
  check "run from ${from#"$FAKE"/}: a card that the first environment of the folder's list carries closes, by that tag" "$want_210" "$(grep -E '^would close +(example-repo|relay)#210' <<< "$run")"
  check "run from ${from#"$FAKE"/}: a card that only the newest tag of all, of a later environment, carries stays, and the tag named is the one of the first environment" "$want_211" "$(grep -E '^not released +(example-repo|relay)#211' <<< "$run")"
  check "run from ${from#"$FAKE"/}: it is not closed, though a proof of the later environment follows its landing" '' "$(grep -E '^would close +(example-repo|relay)#211' <<< "$run")"
done
sweep_dir="$relay" sweep_mutant bin/status-sync.sh 's/^    folder_config="\$(project_folder)\/\.ai-core\/config\.env"$/    folder_config="$(data_dir)\/config.env"/' example-org/relay
check 'planted: the list of the checkout the sweep runs in, where it is relay itself, reads relay by its newest tag of all and closes #211, of its own and of example-repo' 'yes yes' \
  "$(grep -q '^would close  relay#211' <<< "$mutant_run" && echo yes || echo no) $(grep -q '^would close  example-repo#211' <<< "$mutant_run" && echo yes || echo no)"
sweep_dir="$clone" sweep_mutant bin/status-sync.sh 's/^    folder_config="\$(project_folder)\/\.ai-core\/config\.env"$/    folder_config="$(data_dir)\/config.env"/'
check 'planted: the list of the checkout the sweep runs in, where that is a clone with a list of its own, reads relay by it and closes #211' yes "$(grep -q '^would close  example-repo#211' <<< "$mutant_run" && echo yes || echo no)"
sweep_dir="$FAKE/folder" sweep_mutant bin/status-sync.sh 's/^    folder_config="\$(project_folder)\/\.ai-core\/config\.env"$/    folder_config="$(data_dir)\/config.env"/'
check 'planted: the same copy run from the project folder stays as it is, the folder is the checkout there, so #211 stays' no "$(grep -q '^would close  example-repo#211' <<< "$mutant_run" && echo yes || echo no)"
sweep_mutant bin/status-sync.sh '/^    \[ -n "\$word" \] || { word="\$(first_environment "\$folder_config")" || exit 1; from_folder=1; }$/d'
check 'planted: the newest tag of all for a clone that names none closes #211 on the tag of the later environment' yes "$(grep -q '^would close  example-repo#211' <<< "$mutant_run" && echo yes || echo no)"
printf 'LIVE_TAGS="prod=command test=deploy/test/*"\n' > "$FAKE/folder/.ai-core/config.env"
run="$(cd "$clone" && bash "$ROOT/bin/status-sync.sh" --project "$PROJECT_NUMBER" --dry-run example-org/example-repo 2>&1)"
shown_config="$FAKE/folder/.ai-core/config.env"
check 'a command of the folder'"'"'s list is no reader of a clone that declares none: its cards are unknown, and the missing declaration is named' \
  "unknown      example-repo#210  (LIVE_TAGS of $shown_config says prod=command, and the clone of example-org/relay declares no command: only a clone that does can have its reader run, so prod is not read; the card stays)
unknown      example-repo#211  (LIVE_TAGS of $shown_config says prod=command, and the clone of example-org/relay declares no command: only a clone that does can have its reader run, so prod is not read; the card stays)" \
  "$(grep -E '^unknown +example-repo#21[01]' <<< "$run")"
check 'and no card of it closes' '' "$(grep -E '^would close +example-repo#21[01]' <<< "$run")"
printf 'LIVE_TAGS="prod=deploy/prod/* test=deploy/test/*"\n' > "$FAKE/folder/.ai-core/config.env"
printf 'LIVE_TAGS="prod=deploy/prod/* test=deploy/test/*"\n' > "$clone/.ai-core/config.env"
cp "$FAKE/issues-1.saved" "$FAKE/issues-1.json"

echo
if [ "$failed" -gt 0 ]; then echo "$failed failed"; exit 1; fi
echo 'all passed'
