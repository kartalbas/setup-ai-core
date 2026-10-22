#!/usr/bin/env bash
# An epic follows its sub-issues through the movers: issue-status moves it to testing once every
# sub-issue stands in testing or done, issue-close closes it with the last one, and an epic in
# testing goes back to implementing once a sub-issue stands before testing, also when subissue-add
# attaches one, and an epic in done or closed goes back to where its sub-issues stand once one that
# counts is open under it (a closed one is reopened first); subissue-remove lets it follow the
# sub-issues it keeps. epic_target, the rule
# itself, is checked on its own first. A fake gh answers, so nothing leaves the machine.
#
#   bash tests/epic-follow.test.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAKE="$(mktemp -d)"
trap 'rm -rf "$FAKE"' EXIT
export GH_ORG=example-org GH_CACHE_DIRECTORY="$FAKE/cache"
mkdir -p "$GH_CACHE_DIRECTORY/7" "$FAKE/bin"
echo PVT_epic7 > "$GH_CACHE_DIRECTORY/7/project-id"
printf 'Status\tF1\t%s\tO%s\n' todo 1 implementing 2 testing 3 done 4 ready 5 backlog 6 planned 7 review 8 > "$GH_CACHE_DIRECTORY/7/fields.tsv"
mkdir -p "$GH_CACHE_DIRECTORY/5"; echo PVT_own5 > "$GH_CACHE_DIRECTORY/5/project-id"
cp "$GH_CACHE_DIRECTORY/7/fields.tsv" "$GH_CACHE_DIRECTORY/5/fields.tsv"

failed=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: [$2]"; echo "       actual:   [$3]"
       [ -z "${out:-}" ] || printf '       output of the last command: %s\n' "$(printf '%s' "$out" | tr '\n' '|' | cut -c1-600)"
       failed=$((failed + 1)); fi
}

echo 'the rule: where an epic stands follows from its counted sub-issues alone, forward and back'
. "$ROOT/lib/board.sh"
# board.sh turns on `set -e`; under it a mover that exits non-zero ends the test at `out=$(...)`,
# before its exit code is checked, and the red run prints nothing for that case.
set +e
check 'nothing started, the epic stands there' ''   "$(epic_target todo todo backlog)"
check 'one started'                  implementing   "$(epic_target todo implementing todo)"
check 'one in review has started'    implementing   "$(epic_target backlog review backlog)"
check 'all in testing or done'       testing        "$(epic_target implementing testing done)"
check 'all done'                     CLOSE          "$(epic_target testing done done)"
check 'from testing back to implementing' implementing "$(epic_target testing implementing testing)"
check 'and so with a new backlog beside one in testing' implementing "$(epic_target testing testing backlog backlog)"
check 'from testing back to the least advanced place' backlog "$(epic_target testing backlog backlog)"
check 'case B: two went back from implementing to backlog' backlog "$(epic_target implementing backlog backlog ready backlog)"
check 'the least advanced of backlog, ready, planned: ready' ready "$(epic_target implementing planned ready ready)"
check 'the least advanced of backlog, ready, planned: planned' planned "$(epic_target implementing planned planned)"
check 'the least advanced of backlog, ready, planned: backlog' backlog "$(epic_target ready planned backlog ready)"
check 'forward within the places that have not started' ready "$(epic_target backlog ready planned)"
check 'an epic that stands in the place its sub-issues derive stays' '' "$(epic_target ready planned ready)"
check 'implementing stays where one has started' '' "$(epic_target implementing implementing backlog)"
check 'an epic in done goes back to implementing' implementing "$(epic_target done implementing backlog)"
check 'an epic in done goes back to backlog, none started' backlog "$(epic_target done backlog backlog)"
check 'an epic in done goes back to testing' testing "$(epic_target done testing done)"
check 'an open epic in done beside sub-issues that are all done is closed' CLOSE "$(epic_target done done done)"
check 'a closed epic is reopened into implementing' 'reopen implementing' "$(epic_target closed implementing backlog)"
check 'a done sub-issue has started: a closed epic with a new one under it' 'reopen implementing' "$(epic_target closed done backlog)"
check 'a closed epic is reopened into backlog, none started' 'reopen backlog' "$(epic_target closed backlog backlog)"
check 'a closed epic is reopened into ready' 'reopen ready' "$(epic_target closed ready planned)"
check 'a closed epic is reopened into testing' 'reopen testing' "$(epic_target closed testing done)"
check 'a closed epic beside a sub-issue closed as not planned is reopened as the open ones stand' 'reopen planned' "$(epic_target closed planned 'not planned')"
check 'a closed epic whose sub-issues are all done stays closed' '' "$(epic_target closed done done)"
check 'a closed epic whose sub-issues are all not planned stays closed' '' "$(epic_target closed 'not planned' 'not planned')"
check 'a closed epic whose sub-issues are done or not planned stays closed' '' "$(epic_target closed done 'not planned')"
check 'no sub-issues, nothing'       ''             "$(epic_target todo)"
check 'not planned left out'         CLOSE          "$(epic_target testing done 'not planned')"
check 'only not planned, nothing'    ''             "$(epic_target testing 'not planned')"
check 'an epic closed as not planned with open sub-issues is reopened as the others' 'reopen implementing' "$(epic_target closed implementing)"

# The fake gh: #3 is a sub-issue of #44, #44 has no parent; $FAKE/epic-44 holds the statuses of
# #44 and of its sub-issues as the board gives them, one a line, the epic first
cat > "$FAKE/bin/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" | tr '\n' ' ' >> "$FAKE/calls"; printf '\n' >> "$FAKE/calls"
num="\$(printf '%s\n' "\$@" | sed -n 's/^\(num\|n\)=\([0-9]*\)$/\2/p' | head -1)"
after="\$(printf '%s\n' "\$@" | sed -n 's/^after=\(.*\)$/\1/p' | head -1)"
prog=""; prev=""; for a in "\$@"; do [ "\$prev" = --jq ] && prog="\$a"; prev="\$a"; done
case "\$*" in
  # the open sub-issues of an issue, the query of issue-close: its own --jq runs over children-<number>.json,
  # and children-<number>-<cursor>.json is the page behind that cursor
  *'subIssues(first'*'nameWithOwner'*)
                              [ -e "$FAKE/children-down" ] && { echo 'gh: HTTP 502' >&2; exit 1; }
                              [ -f "$FAKE/children-\$num\${after:+-\$after}.json" ] || exit 0
                              jq -r "\$prog" < "$FAKE/children-\$num\${after:+-\$after}.json" | tr -d '\r' ;;
  # the sub-issues of the epic as the target reads them: epic-44.json, epic-44-<cursor>.json, or the lines of
  # epic-44 as that program would have printed them
  *'subIssues(first'*)        if [ -f "$FAKE/epic-44\${after:+-\$after}.json" ]; then
                                jq -r "\$prog" < "$FAKE/epic-44\${after:+-\$after}.json" | tr -d '\r'
                              else cat "$FAKE/epic-44"; fi ;;
  *'--jq .id'*)               echo "90\$num" ;;
  *'--method POST'*|*'--method DELETE'*) echo '{}' ;;
  *'parent {'*)               [ "\$num" = 3 ] && echo 'example-org/example-repo 44' ;;
  *includeArchived*)          printf 'PVT_epic7\tPVTI_card%s\nPVT_own5\tPVTI_card%s\n' "\$num" "\$num" ;;
  *'projectsV2(first:50)'*)   printf '5\tthe repository board\n' ;;
  *'projectItems(first:20)'*) if [ "\$num" = 44 ] && [ -f "$FAKE/boards-44" ]; then cat "$FAKE/boards-44"; else printf 'example-org/7\tPVTI_card%s\n' "\$num"; fi ;;
  *updateProjectV2ItemFieldValue*) echo '{}' ;;
  *'--method PATCH'*)         echo '{}' ;;
  *) echo "the stand-in gh has no answer for: \$*" >&2; exit 9 ;;
esac
exit 0
EOF
chmod +x "$FAKE/bin/gh"
export PATH="$FAKE/bin:$PATH"
moves() { grep -o 'iid=PVTI_card[0-9]*' "$FAKE/calls" | tr '\n' ' ' | sed 's/ $//'; }

echo 'issue-status: the last sub-issue in testing moves its epic to testing'
: > "$FAKE/calls"; printf 'implementing\ntesting\ntesting\n' > "$FAKE/epic-44"
out="$(bash "$ROOT/bin/issue-status.sh" --project 7 example-org/example-repo 3 testing 2>&1)"; rc=$?
check 'exit 0'        0 "$rc"
check 'it says so'    'epic example-org/example-repo#44 -> testing, as its sub-issues stand' "$(grep '^epic' <<< "$out")"
check 'both cards moved, the sub-issue first' 'iid=PVTI_card3 iid=PVTI_card44' "$(moves)"

echo 'issue-status: a sub-issue back in implementing takes its epic from testing back to implementing'
: > "$FAKE/calls"; printf 'testing\nimplementing\ntesting\n' > "$FAKE/epic-44"
out="$(bash "$ROOT/bin/issue-status.sh" --project 7 example-org/example-repo 3 implementing 2>&1)"; rc=$?
check 'exit 0'        0 "$rc"
check 'it says so'    'epic example-org/example-repo#44 -> implementing, as its sub-issues stand' "$(grep '^epic' <<< "$out")"
check 'both cards moved, the sub-issue first' 'iid=PVTI_card3 iid=PVTI_card44' "$(moves)"

echo 'subissue-add: a todo sub-issue attached to an epic in testing takes it back to implementing'
: > "$FAKE/calls"; printf 'testing\ntesting\ntodo\n' > "$FAKE/epic-44"
out="$(bash "$ROOT/bin/subissue-add.sh" example-org/example-repo 44 5 2>&1)"; rc=$?
check 'exit 0'        0 "$rc"
check 'it says so'    'epic example-org/example-repo#44 -> implementing, as its sub-issues stand' "$(grep '^epic' <<< "$out")"
check 'the epic moved on its own board 5' 'pid=PVT_own5' "$(grep 'iid=PVTI_card44 ' "$FAKE/calls" | grep -o 'pid=PVT_[a-z0-9]*')"

echo 'subissue-remove: an epic whose last sub-issue before testing is detached moves to testing'
: > "$FAKE/calls"; printf 'implementing\ntesting\ndone\n' > "$FAKE/epic-44"
out="$(bash "$ROOT/bin/subissue-remove.sh" example-org/example-repo 44 5 2>&1)"; rc=$?
check 'exit 0'        0 "$rc"
check 'it says so'    'epic example-org/example-repo#44 -> testing, as its sub-issues stand' "$(grep '^epic' <<< "$out")"
check 'only the epic moved' 'iid=PVTI_card44' "$(moves)"

# A closed epic is reopened through issue-reopen, which puts its card in ready, and then moved to where its sub-issues stand.
# The stand-in answers the epic's first line as its own status: closed for a closed epic, a column name for an open one.
patched() { grep -o 'PATCH repos/example-org/example-repo/issues/[0-9]*' "$FAKE/calls" | sed 's#.*/issues/#issues/#' | tr '\n' ' ' | sed 's/ $//'; }
echo 'subissue-add: a closed epic with a todo sub-issue attached is reopened and goes to implementing, a done sub-issue having started'
: > "$FAKE/calls"; printf 'closed\ndone\ntodo\n' > "$FAKE/epic-44"
out="$(bash "$ROOT/bin/subissue-add.sh" example-org/example-repo 44 5 2>&1)"; rc=$?
check 'exit 0'        0 "$rc"
check 'it says so'    'epic example-org/example-repo#44 -> reopened in implementing, as its sub-issues stand' "$(grep '^epic' <<< "$out")"
check 'the epic was reopened' 'issues/44' "$(patched)"
check 'its card went to ready, then to implementing' 'iid=PVTI_card44 iid=PVTI_card44' "$(moves)"

echo 'issue-status: a sub-issue moved to todo under a closed epic whose others are done reopens it into implementing'
: > "$FAKE/calls"; printf 'closed\ntodo\ndone\n' > "$FAKE/epic-44"
out="$(bash "$ROOT/bin/issue-status.sh" --project 7 example-org/example-repo 3 todo 2>&1)"; rc=$?
check 'exit 0'        0 "$rc"
check 'it says so'    'epic example-org/example-repo#44 -> reopened in implementing, as its sub-issues stand' "$(grep '^epic' <<< "$out")"
check 'the epic was reopened' 'issues/44' "$(patched)"
check 'the sub-issue moved, then the epic twice' 'iid=PVTI_card3 iid=PVTI_card44 iid=PVTI_card44' "$(moves)"

echo 'issue-status: a closed epic whose only open sub-issue stands in ready is reopened into ready, and moved no further'
: > "$FAKE/calls"; printf 'closed\nready\n' > "$FAKE/epic-44"
out="$(bash "$ROOT/bin/issue-status.sh" --project 7 example-org/example-repo 3 ready 2>&1)"; rc=$?
check 'exit 0'        0 "$rc"
check 'it says so'    'epic example-org/example-repo#44 -> reopened in ready, as its sub-issues stand' "$(grep '^epic' <<< "$out")"
check 'the epic was reopened' 'issues/44' "$(patched)"
check 'the sub-issue moved, then the epic once, to ready' 'iid=PVTI_card3 iid=PVTI_card44' "$(moves)"

echo 'issue-status: a closed epic whose only open sub-issue stands in backlog is reopened into backlog'
: > "$FAKE/calls"; printf 'closed\nbacklog\n' > "$FAKE/epic-44"
out="$(bash "$ROOT/bin/issue-status.sh" --project 7 example-org/example-repo 3 backlog 2>&1)"; rc=$?
check 'exit 0'        0 "$rc"
check 'it says so'    'epic example-org/example-repo#44 -> reopened in backlog, as its sub-issues stand' "$(grep '^epic' <<< "$out")"
check 'the epic was reopened, then moved' 'iid=PVTI_card3 iid=PVTI_card44 iid=PVTI_card44' "$(moves)"

echo 'issue-status: an open epic whose card stands in done goes back to where its sub-issues stand, and says so again each time it is asked'
for round in 1 2; do
  : > "$FAKE/calls"; printf 'done\nimplementing\nbacklog\n' > "$FAKE/epic-44"
  out="$(bash "$ROOT/bin/issue-status.sh" --project 7 example-org/example-repo 3 implementing 2>&1)"; rc=$?
  check "round $round: exit 0"     0 "$rc"
  check "round $round: it says so" 'epic example-org/example-repo#44 -> implementing, as its sub-issues stand' "$(grep '^epic' <<< "$out")"
  check "round $round: the epic stays open" '' "$(patched)"
  check "round $round: the sub-issue and the epic moved" 'iid=PVTI_card3 iid=PVTI_card44' "$(moves)"
done
: > "$FAKE/calls"; printf 'done\nbacklog\nbacklog\n' > "$FAKE/epic-44"
out="$(bash "$ROOT/bin/issue-status.sh" --project 7 example-org/example-repo 3 backlog 2>&1)"; rc=$?
check 'none started: exit 0'      0 "$rc"
check 'none started: back to backlog' 'epic example-org/example-repo#44 -> backlog, as its sub-issues stand' "$(grep '^epic' <<< "$out")"

echo 'case B: an epic in implementing whose two sub-issues went back to backlog goes to backlog, the least advanced place'
: > "$FAKE/calls"; printf 'implementing\nbacklog\nbacklog\nready\n' > "$FAKE/epic-44"
out="$(bash "$ROOT/bin/issue-status.sh" --project 7 example-org/example-repo 3 backlog 2>&1)"; rc=$?
check 'exit 0'        0 "$rc"
check 'it says so'    'epic example-org/example-repo#44 -> backlog, as its sub-issues stand' "$(grep '^epic' <<< "$out")"
check 'the sub-issue and the epic moved' 'iid=PVTI_card3 iid=PVTI_card44' "$(moves)"
: > "$FAKE/calls"; printf 'implementing\nready\nplanned\nready\n' > "$FAKE/epic-44"
out="$(bash "$ROOT/bin/issue-status.sh" --project 7 example-org/example-repo 3 ready 2>&1)"; rc=$?
check 'ready is the least advanced of ready and planned' 'epic example-org/example-repo#44 -> ready, as its sub-issues stand' "$(grep '^epic' <<< "$out")"

echo 'an epic that already stands where its sub-issues derive gets no write'
for lines in 'implementing\nimplementing\nbacklog' 'backlog\nbacklog\nready' 'testing\ntesting\ndone' 'closed\ndone\ndone'; do
  : > "$FAKE/calls"; printf "$lines\n" > "$FAKE/epic-44"
  out="$(bash "$ROOT/bin/issue-status.sh" --project 7 example-org/example-repo 3 "$(sed -n 2p "$FAKE/epic-44")" 2>&1)"; rc=$?
  check "$(sed 's/\\n/ /g' <<< "$lines"): exit 0" 0 "$rc"
  check "$(sed 's/\\n/ /g' <<< "$lines"): no epic line" '' "$(grep '^epic' <<< "$out")"
  check "$(sed 's/\\n/ /g' <<< "$lines"): only the sub-issue moved" 'iid=PVTI_card3' "$(moves)"
done

echo 'a closed epic stays closed where nothing open counts under it: all sub-issues done, all not planned, one done and one not planned'
for lines in 'closed\ndone\ndone' 'closed\nnot planned\nnot planned' 'closed\ndone\nnot planned'; do
  : > "$FAKE/calls"; printf "$lines\n" > "$FAKE/epic-44"
  out="$(bash "$ROOT/bin/subissue-add.sh" example-org/example-repo 44 5 2>&1)"; rc=$?
  check "$(printf '%s' "$lines" | tr '\n' ' ' | sed 's/\\n/ /g'): exit 0"        0 "$rc"
  check "$(printf '%s' "$lines" | sed 's/\\n/ /g'): no epic line"  '' "$(grep '^epic' <<< "$out")"
  check "$(printf '%s' "$lines" | sed 's/\\n/ /g'): nothing reopened or moved" '' "$(patched)$(moves)"
done

# Each rule is shown red on a copy of the tree with one planted defect
mutant_tree() {  # mutant_tree <sed expression> [file]: a copy of the tree with the file, lib/board.sh where none is named, changed by it, in $FAKE/mutant; prints its path
  local file="${2:-lib/board.sh}"
  rm -rf "$FAKE/mutant"; mkdir -p "$FAKE/mutant"; cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/templates" "$FAKE/mutant/"; cp "$ROOT/VERSION" "$FAKE/mutant/"
  sed -i.bak "$1" "$FAKE/mutant/$file"
  cmp -s "$ROOT/$file" "$FAKE/mutant/$file" && { echo "the planted defect changed nothing: $1" >&2; exit 1; }
  printf '%s' "$FAKE/mutant"
}
in_mutant() {  # in_mutant <command>...: the command with a cache of its own, because a planted defect may make a board read its fields again
  rm -rf "$FAKE/mutant-cache"; cp -R "$GH_CACHE_DIRECTORY" "$FAKE/mutant-cache"
  GH_CACHE_DIRECTORY="$FAKE/mutant-cache" "$@"
}
epic_line() { grep '^epic' <<< "$1"; }
echo 'planted: the reopen taken out leaves a closed epic closed'
M="$(mutant_tree '/issue-reopen.sh/d')" || exit 1
: > "$FAKE/calls"; printf 'closed\ndone\nbacklog\n' > "$FAKE/epic-44"
in_mutant bash "$M/bin/subissue-add.sh" example-org/example-repo 44 5 > /dev/null 2>&1
check 'the epic was not reopened' '' "$(patched)"
echo 'planted: the move back from done taken out leaves an epic in done'
M="$(mutant_tree 's/^  \[ "\$t" != "\$cur" \] || return 0$/  [ "$t" != "$cur" ] \&\& [ "$cur" != done ] || return 0/')" || exit 1
: > "$FAKE/calls"; printf 'done\nimplementing\nbacklog\n' > "$FAKE/epic-44"
out="$(in_mutant bash "$M/bin/issue-status.sh" --project 7 example-org/example-repo 3 implementing 2>&1)"
check 'no epic line' '' "$(epic_line "$out")"
echo 'planted: the move back from implementing taken out leaves case B where it is'
M="$(mutant_tree 's/^  \[ "\$t" != "\$cur" \] || return 0$/&\n  [ "$cur" = implementing ] \&\& [ "$t" != testing ] \&\& [ "$t" != CLOSE ] \&\& return 0/')" || exit 1
: > "$FAKE/calls"; printf 'implementing\nbacklog\nbacklog\nready\n' > "$FAKE/epic-44"
out="$(in_mutant bash "$M/bin/issue-status.sh" --project 7 example-org/example-repo 3 backlog 2>&1)"
check 'no epic line' '' "$(epic_line "$out")"
echo 'planted: the furthest of the places that have not started instead of the least advanced'
M="$(mutant_tree 's/if \[ "\$e" -lt "\$early_rank" \]; then/if [ -z "$early" ] || [ "$e" -gt "$early_rank" ]; then/')" || exit 1
: > "$FAKE/calls"; printf 'implementing\nbacklog\nbacklog\nready\n' > "$FAKE/epic-44"
out="$(in_mutant bash "$M/bin/issue-status.sh" --project 7 example-org/example-repo 3 backlog 2>&1)"
check 'the epic goes to ready, not to backlog' 'epic example-org/example-repo#44 -> ready, as its sub-issues stand' "$(epic_line "$out")"
echo 'planted: a closed epic closed again beside sub-issues that are all done'
M="$(mutant_tree 's/\[ "\$cur" = closed \] || echo CLOSE/echo CLOSE/')" || exit 1
: > "$FAKE/calls"; printf 'closed\ndone\ndone\n' > "$FAKE/epic-44"
in_mutant bash "$M/bin/subissue-add.sh" example-org/example-repo 44 5 > /dev/null 2>&1
check 'the innocent case is closed again, so its check can go red' 'issues/44' "$(patched)"
echo 'planted: an epic written to where it already stands'
M="$(mutant_tree '/^  \[ "\$t" != "\$cur" \] || return 0$/d')" || exit 1
: > "$FAKE/calls"; printf 'implementing\nimplementing\nbacklog\n' > "$FAKE/epic-44"
out="$(in_mutant bash "$M/bin/issue-status.sh" --project 7 example-org/example-repo 3 implementing 2>&1)"
check 'the epic is written, so the check of no write can go red' 'epic example-org/example-repo#44 -> implementing, as its sub-issues stand' "$(epic_line "$out")"

echo 'issue-close: the last sub-issue closed closes its epic'
: > "$FAKE/calls"; printf 'testing\ndone\ndone\n' > "$FAKE/epic-44"
out="$(bash "$ROOT/bin/issue-close.sh" example-org/example-repo 3 2>&1)"; rc=$?
check 'exit 0'        0 "$rc"
check 'it says so'    'epic example-org/example-repo#44 -> closed, every sub-issue done' "$(grep '^epic' <<< "$out")"
check 'both issues closed' 'issues/3 issues/44' "$(grep -o 'PATCH repos/example-org/example-repo/issues/[0-9]*' "$FAKE/calls" | sed 's#.*/issues/#issues/#' | tr '\n' ' ' | sed 's/ $//')"

echo 'issue-close: a sub-issue closed as not planned does not close an epic that has nothing else'
: > "$FAKE/calls"; printf 'testing\nnot planned\n' > "$FAKE/epic-44"
out="$(bash "$ROOT/bin/issue-close.sh" example-org/example-repo 3 2>&1)"; rc=$?
check 'exit 0'        0 "$rc"
check 'no epic line'  '' "$(grep '^epic' <<< "$out")"
check 'only the sub-issue closed' 'issues/3' "$(grep -o 'PATCH repos/example-org/example-repo/issues/[0-9]*' "$FAKE/calls" | sed 's#.*/issues/#issues/#' | tr '\n' ' ' | sed 's/ $//')"

echo 'issue-status: an epic with no card on the selected board moves on its own repository board, never gets a card on the selected one'
: > "$FAKE/calls"; printf 'implementing\ntesting\ntesting\n' > "$FAKE/epic-44"; printf 'other-org/3\tPVTI_elsewhere\n' > "$FAKE/boards-44"
out="$(bash "$ROOT/bin/issue-status.sh" --project 7 example-org/example-repo 3 testing 2>&1)"; rc=$?
rm -f "$FAKE/boards-44"
check 'exit 0'        0 "$rc"
check 'it says so'    'epic example-org/example-repo#44 -> testing, as its sub-issues stand' "$(grep '^epic' <<< "$out")"
check 'the sub-issue moved on the selected board 7' 'pid=PVT_epic7' "$(grep 'iid=PVTI_card3 ' "$FAKE/calls" | grep -o 'pid=PVT_[a-z0-9]*')"
check 'the epic moved on its own board 5, not on 7' 'pid=PVT_own5' "$(grep 'iid=PVTI_card44 ' "$FAKE/calls" | grep -o 'pid=PVT_[a-z0-9]*')"

# Read through the query's own jq: the sub-issue of another repository has no card on board 7,
# a card without a status on other-org/3 and one with a status on other-org/5, and counts there
echo 'issue-status: a sub-issue with no card on the selected board counts where its own card stands'
cat > "$FAKE/epic-44.json" <<'J'
{"data":{"repository":{"issue":{"state":"OPEN","stateReason":null,
 "projectItems":{"nodes":[{"project":{"number":7,"owner":{"login":"example-org"}},"status":{"name":"implementing"}}]},
 "subIssues":{"nodes":[
  {"state":"OPEN","stateReason":null,"projectItems":{"nodes":[{"project":{"number":7,"owner":{"login":"example-org"}},"status":{"name":"testing"}}]}},
  {"state":"OPEN","stateReason":null,"projectItems":{"nodes":[{"project":{"number":3,"owner":{"login":"other-org"}},"status":null},{"project":{"number":5,"owner":{"login":"other-org"}},"status":{"name":"testing"}}]}}]}}}}}
J
: > "$FAKE/calls"
out="$(bash "$ROOT/bin/issue-status.sh" --project 7 example-org/example-repo 3 testing 2>&1)"; rc=$?
check 'exit 0'        0 "$rc"
check 'its first card with a status counts: the epic follows to testing' 'epic example-org/example-repo#44 -> testing, as its sub-issues stand' "$(grep '^epic' <<< "$out")"
# The other sub-issue is closed and this one, still open, says Done on that other board
cat > "$FAKE/epic-44.json" <<'J'
{"data":{"repository":{"issue":{"state":"OPEN","stateReason":null,
 "projectItems":{"nodes":[{"project":{"number":7,"owner":{"login":"example-org"}},"status":{"name":"implementing"}}]},
 "subIssues":{"nodes":[
  {"state":"CLOSED","stateReason":"COMPLETED","projectItems":{"nodes":[]}},
  {"state":"OPEN","stateReason":null,"projectItems":{"nodes":[{"project":{"number":3,"owner":{"login":"other-org"}},"status":null},{"project":{"number":5,"owner":{"login":"other-org"}},"status":{"name":"Done"}}]}}]}}}}}
J
: > "$FAKE/calls"
out="$(bash "$ROOT/bin/issue-status.sh" --project 7 example-org/example-repo 3 testing 2>&1)"; rc=$?
check 'Done on another board, still open: exit 0' 0 "$rc"
check 'counts as testing, so the epic goes to testing and is not closed' 'epic example-org/example-repo#44 -> testing, as its sub-issues stand' "$(grep '^epic' <<< "$out")"
rm -f "$FAKE/epic-44.json"

# --- an epic with an open sub-issue stays open -------------------------------------------------------
#
# Where the card of an OPEN sub-issue says done on the selected board, the epic must not read that as
# done: it would be closed with a sub-issue open. The sub-issues are read through the query's own jq, so
# the state of the issue decides and the column of a card does not.
pageinfo() {  # pageinfo [cursor]: the page info of a page that has a page behind it where a cursor is given
  if [ -n "${1:-}" ]; then printf '{"hasNextPage":true,"endCursor":"%s"}' "$1"; else printf '{"hasNextPage":false,"endCursor":null}'; fi
}
planted() {  # planted <epic status> <the sub-issues, as JSON nodes> [page cursor]: the epic read as the target reads it
  printf '{"data":{"repository":{"issue":{"state":"OPEN","stateReason":null,"projectItems":{"nodes":[{"project":{"number":7,"owner":{"login":"example-org"}},"status":{"name":"%s"}},{"project":{"number":5,"owner":{"login":"example-org"}},"status":{"name":"%s"}}]},"subIssues":{"pageInfo":%s,"nodes":[%s]}}}}}\n' \
    "$1" "$1" "$(pageinfo "${3:-}")" "$2"
}
closed_child='{"state":"CLOSED","stateReason":"COMPLETED","projectItems":{"nodes":[]}}'
done_card_child='{"state":"OPEN","stateReason":null,"projectItems":{"nodes":[{"project":{"number":7,"owner":{"login":"example-org"}},"status":{"name":"done"}}]}}'
plain() { grep -o 'PATCH repos/example-org/example-repo/issues/[0-9]*' "$FAKE/calls" | sed 's#.*/issues/#issues/#' | tr '\n' ' ' | sed 's/ $//'; }
child_of() {  # child_of <number> <repository> <state>: a sub-issue as the query of issue-close reads it
  printf '{"number":%s,"state":"%s","repository":{"nameWithOwner":"%s"}}' "$1" "$3" "$2"
}
children() { printf '{"data":{"repository":{"issue":{"subIssues":{"pageInfo":%s,"nodes":[%s]}}}}}\n' "$(pageinfo "${2:-}")" "$1"; }
# An open sub-issue whose card stands in a column that reads as closed: done on the selected board 7, done on
# the epic's own board 5 (where subissue-add and subissue-remove read), and not planned on board 7
open_child_with_card() {  # open_child_with_card <board number> <column>
  printf '{"state":"OPEN","stateReason":null,"projectItems":{"nodes":[{"project":{"number":%s,"owner":{"login":"example-org"}},"status":{"name":"%s"}}]}}' "$1" "$2"
}
own_done_card_child="$(open_child_with_card 5 done)"
not_planned_card_child="$(open_child_with_card 7 'Not planned')"

echo 'issue-close: a sub-issue closed beside an open one whose card says done moves the epic to testing and closes nothing more'
: > "$FAKE/calls"; planted implementing "$closed_child,$done_card_child" > "$FAKE/epic-44.json"
out="$(bash "$ROOT/bin/issue-close.sh" example-org/example-repo 3 2>&1)"; rc=$?
check 'exit 0'                  0 "$rc"
check 'the epic goes to testing' 'epic example-org/example-repo#44 -> testing, as its sub-issues stand' "$(grep '^epic' <<< "$out")"
check 'the epic is not closed'  'issues/3' "$(plain)"
rm -f "$FAKE/epic-44.json"

echo 'the same epic already in testing stays there: no move, no close, exit 0'
: > "$FAKE/calls"; planted testing "$closed_child,$done_card_child" > "$FAKE/epic-44.json"
out="$(bash "$ROOT/bin/issue-close.sh" example-org/example-repo 3 2>&1)"; rc=$?
check 'exit 0'                  0 "$rc"
check 'no epic line'            '' "$(grep '^epic' <<< "$out")"
check 'only the sub-issue closed' 'issues/3' "$(plain)"
check 'the epic card did not move' '' "$(grep -o 'iid=PVTI_card44' "$FAKE/calls" | sort -u | tr '\n' ' ')"
rm -f "$FAKE/epic-44.json"

echo 'issue-status, subissue-add and subissue-remove: an open sub-issue whose card says done moves the epic to testing, never closes it'
: > "$FAKE/calls"; planted implementing "$closed_child,$done_card_child" > "$FAKE/epic-44.json"
out="$(bash "$ROOT/bin/issue-status.sh" --project 7 example-org/example-repo 3 testing 2>&1)"; rc=$?
check 'issue-status: exit 0'    0 "$rc"
check 'issue-status: the epic goes to testing' 'epic example-org/example-repo#44 -> testing, as its sub-issues stand' "$(grep '^epic' <<< "$out")"
# subissue-add and subissue-remove select no board, so the epic is read on its own board 5: the card that says done stands there
planted implementing "$closed_child,$own_done_card_child" > "$FAKE/epic-44.json"
: > "$FAKE/calls"
out="$(bash "$ROOT/bin/subissue-add.sh" example-org/example-repo 44 5 2>&1)"; rc=$?
check 'subissue-add: exit 0'    0 "$rc"
check 'subissue-add: the epic goes to testing' 'epic example-org/example-repo#44 -> testing, as its sub-issues stand' "$(grep '^epic' <<< "$out")"
: > "$FAKE/calls"
out="$(bash "$ROOT/bin/subissue-remove.sh" example-org/example-repo 44 5 2>&1)"; rc=$?
check 'subissue-remove: exit 0' 0 "$rc"
check 'subissue-remove: the epic goes to testing' 'epic example-org/example-repo#44 -> testing, as its sub-issues stand' "$(grep '^epic' <<< "$out")"
check 'no command sent a close' '' "$(plain)"
planted testing "$closed_child,$own_done_card_child" > "$FAKE/epic-44.json"
: > "$FAKE/calls"
out="$(bash "$ROOT/bin/subissue-add.sh" example-org/example-repo 44 5 2>&1)"; rc=$?
check 'an epic in testing stays: exit 0' 0 "$rc"
check 'and no epic line'        '' "$(grep '^epic' <<< "$out")"
rm -f "$FAKE/epic-44.json"

echo 'an open sub-issue whose card says not planned is no closed one: the epic goes to testing, nothing is closed, the command exits 0'
children "$(child_of 8 example-org/example-repo OPEN)" > "$FAKE/children-44.json"
: > "$FAKE/calls"; planted implementing "$closed_child,$not_planned_card_child" > "$FAKE/epic-44.json"
out="$(bash "$ROOT/bin/issue-status.sh" --project 7 example-org/example-repo 3 testing 2>&1)"; rc=$?
check 'issue-status: exit 0'    0 "$rc"
check 'issue-status: the epic goes to testing' 'epic example-org/example-repo#44 -> testing, as its sub-issues stand' "$(grep '^epic' <<< "$out")"
check 'issue-status: no epic close' '' "$(plain)"
: > "$FAKE/calls"
out="$(bash "$ROOT/bin/issue-close.sh" example-org/example-repo 3 2>&1)"; rc=$?
check 'issue-close of a sibling: exit 0' 0 "$rc"
check 'issue-close of a sibling: the epic goes to testing' 'epic example-org/example-repo#44 -> testing, as its sub-issues stand' "$(grep '^epic' <<< "$out")"
check 'issue-close of a sibling: only the sibling closed' 'issues/3' "$(plain)"
planted testing "$closed_child,$not_planned_card_child" > "$FAKE/epic-44.json"
: > "$FAKE/calls"
out="$(bash "$ROOT/bin/issue-status.sh" --project 7 example-org/example-repo 3 testing 2>&1)"; rc=$?
check 'an epic in testing stays: exit 0' 0 "$rc"
check 'and no epic line'        '' "$(grep '^epic' <<< "$out")"
check 'and no epic close'       '' "$(plain)"
rm -f "$FAKE/epic-44.json" "$FAKE/children-44.json"

echo 'an open sub-issue beyond the first page of sub-issues keeps the epic open as well'
: > "$FAKE/calls"
planted implementing "$closed_child" c2 > "$FAKE/epic-44.json"
planted implementing "$done_card_child" > "$FAKE/epic-44-c2.json"
out="$(bash "$ROOT/bin/issue-close.sh" example-org/example-repo 3 2>&1)"; rc=$?
check 'exit 0'                  0 "$rc"
check 'the epic goes to testing' 'epic example-org/example-repo#44 -> testing, as its sub-issues stand' "$(grep '^epic' <<< "$out")"
check 'the second page was read' 1 "$(grep -c 'after=c2' "$FAKE/calls" || true)"
check 'the epic is not closed'  'issues/3' "$(plain)"
rm -f "$FAKE/epic-44.json" "$FAKE/epic-44-c2.json"

echo 'every sub-issue closed as completed closes the epic, also over two pages; a mix with not planned and duplicate as well'
: > "$FAKE/calls"
planted implementing "$closed_child" c2 > "$FAKE/epic-44.json"
planted implementing "$closed_child" > "$FAKE/epic-44-c2.json"
out="$(bash "$ROOT/bin/issue-close.sh" example-org/example-repo 3 2>&1)"; rc=$?
check 'exit 0'                  0 "$rc"
check 'the epic is closed'      'epic example-org/example-repo#44 -> closed, every sub-issue done' "$(grep '^epic' <<< "$out")"
check 'both issues closed'      'issues/3 issues/44' "$(plain)"
rm -f "$FAKE/epic-44-c2.json"
: > "$FAKE/calls"
planted testing "$closed_child,{\"state\":\"CLOSED\",\"stateReason\":\"NOT_PLANNED\",\"projectItems\":{\"nodes\":[]}},{\"state\":\"CLOSED\",\"stateReason\":\"DUPLICATE\",\"projectItems\":{\"nodes\":[]}}" > "$FAKE/epic-44.json"
out="$(bash "$ROOT/bin/issue-close.sh" example-org/example-repo 3 2>&1)"; rc=$?
check 'a mix with at least one completed: exit 0' 0 "$rc"
check 'the epic is closed'      'epic example-org/example-repo#44 -> closed, every sub-issue done' "$(grep '^epic' <<< "$out")"
: > "$FAKE/calls"
planted testing "{\"state\":\"CLOSED\",\"stateReason\":\"NOT_PLANNED\",\"projectItems\":{\"nodes\":[]}},{\"state\":\"CLOSED\",\"stateReason\":\"DUPLICATE\",\"projectItems\":{\"nodes\":[]}}" > "$FAKE/epic-44.json"
out="$(bash "$ROOT/bin/issue-close.sh" example-org/example-repo 3 2>&1)"; rc=$?
check 'all cancelled: exit 0'   0 "$rc"
check 'the epic does not move'  '' "$(grep '^epic' <<< "$out")"
check 'only the sub-issue closed' 'issues/3' "$(plain)"
rm -f "$FAKE/epic-44.json"

echo 'subissue-add: a closed epic reads as closed through the query'"'"'s own jq, whatever its cards say, and is reopened'
closed_epic() {  # closed_epic <the sub-issues, as JSON nodes>: a closed epic whose cards say done, read as the target reads it
  planted done "$1" | jq -c '.data.repository.issue += {state: "CLOSED", stateReason: "COMPLETED"}'
}
: > "$FAKE/calls"; closed_epic "$closed_child,$(open_child_with_card 5 backlog)" > "$FAKE/epic-44.json"
out="$(bash "$ROOT/bin/subissue-add.sh" example-org/example-repo 44 5 2>&1)"; rc=$?
check 'exit 0'                  0 "$rc"
check 'it says so'              'epic example-org/example-repo#44 -> reopened in implementing, as its sub-issues stand' "$(grep '^epic' <<< "$out")"
check 'the epic was reopened'   'issues/44' "$(plain)"
M="$(mutant_tree 's/then \\"closed\\" else (card/then closed else (card/' lib/github/tracker.sh)" || exit 1
: > "$FAKE/calls"
out="$(in_mutant bash "$M/bin/subissue-add.sh" example-org/example-repo 44 5 2>&1)"
check 'planted: the closed epic read as done is moved and left closed' 'epic example-org/example-repo#44 -> implementing, as its sub-issues stand|' "$(grep '^epic' <<< "$out")|$(plain)"
rm -f "$FAKE/epic-44.json"

echo 'issue-close of the epic itself: refused with an open sub-issue, whatever its card says, with both reasons, and nothing is written'
children "$(child_of 7 example-org/example-repo CLOSED),$(child_of 8 example-org/example-repo OPEN),$(child_of 9 other-org/tracker OPEN)" > "$FAKE/children-44.json"
for reason in '' not-planned; do
  : > "$FAKE/calls"
  out="$(bash "$ROOT/bin/issue-close.sh" example-org/example-repo ${reason:+--reason "$reason"} 44 2>&1)"; rc=$?
  check "${reason:-completed}: exit 1" 1 "$rc"
  check "${reason:-completed}: it names the open sub-issues, not the closed one" \
    'error: example-org/example-repo#44 has open sub-issues, so it stays open and its card where it is: example-org/example-repo#8 other-org/tracker#9 - close them first, or take them out of it' "$out"
  check "${reason:-completed}: nothing was closed or moved" '' "$(grep -E 'PATCH|updateProjectV2ItemFieldValue|addProjectV2ItemById' "$FAKE/calls" || true)"
done

echo 'an open sub-issue on the second page of sub-issues is named too'
: > "$FAKE/calls"
children "$(child_of 7 example-org/example-repo CLOSED)" c2 > "$FAKE/children-44.json"
children "$(child_of 12 example-org/example-repo OPEN)" > "$FAKE/children-44-c2.json"
out="$(bash "$ROOT/bin/issue-close.sh" example-org/example-repo 44 2>&1)"; rc=$?
check 'exit 1'                  1 "$rc"
check 'the open one is named'   'error: example-org/example-repo#44 has open sub-issues, so it stays open and its card where it is: example-org/example-repo#12 - close them first, or take them out of it' "$out"
check 'nothing was closed'      '' "$(grep -E 'PATCH' "$FAKE/calls" || true)"
rm -f "$FAKE/children-44-c2.json"

echo 'a read of the sub-issues that fails refuses the close: no answer is not "none open"'
: > "$FAKE/calls"; touch "$FAKE/children-down"
out="$(bash "$ROOT/bin/issue-close.sh" example-org/example-repo 44 2>&1)"; rc=$?
rm -f "$FAKE/children-down"
check 'exit 1'                  1 "$rc"
check 'it says what it could not read' yes "$(grep -q 'cannot read the sub-issues of example-org/example-repo#44' <<< "$out" && echo yes || echo no)"
check 'nothing was closed or moved' '' "$(grep -E 'PATCH|updateProjectV2ItemFieldValue' "$FAKE/calls" || true)"

echo 'all its sub-issues closed: the epic closes, as completed and as not planned; a leaf closes'
children "$(child_of 7 example-org/example-repo CLOSED),$(child_of 9 other-org/tracker CLOSED)" > "$FAKE/children-44.json"
: > "$FAKE/calls"
out="$(bash "$ROOT/bin/issue-close.sh" example-org/example-repo 44 2>&1)"; rc=$?
check 'completed: exit 0'       0 "$rc"
check 'completed: closed'       'issues/44' "$(plain)"
: > "$FAKE/calls"
out="$(bash "$ROOT/bin/issue-close.sh" example-org/example-repo --reason not-planned 44 2>&1)"; rc=$?
check 'not planned: exit 0'     0 "$rc"
check 'not planned: closed'     'issues/44' "$(plain)"
rm -f "$FAKE/children-44.json"
: > "$FAKE/calls"
out="$(bash "$ROOT/bin/issue-close.sh" example-org/example-repo 3 2>&1)"; rc=$?
check 'a leaf: exit 0'          0 "$rc"
check 'a leaf: closed'          'issues/3' "$(plain)"

echo
if [ "$failed" -gt 0 ]; then echo "$failed failed"; exit 1; fi
echo 'all passed'
