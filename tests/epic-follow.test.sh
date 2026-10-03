#!/usr/bin/env bash
# An epic follows its sub-issues through the movers: issue-status moves it to testing once every
# sub-issue stands in testing or done, issue-close closes it with the last one, and a sub-issue
# that has only started never moves an epic that stands further on. epic_target, the rule itself,
# is checked on its own first. A fake gh answers, so nothing leaves the machine.
#
#   bash tests/epic-follow.test.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAKE="$(mktemp -d)"
trap 'rm -rf "$FAKE"' EXIT
export GH_ORG=example-org GH_CACHE_DIRECTORY="$FAKE/cache"
mkdir -p "$GH_CACHE_DIRECTORY/7" "$FAKE/bin"
echo PVT_epic7 > "$GH_CACHE_DIRECTORY/7/project-id"
printf 'Status\tF1\t%s\tO%s\n' todo 1 implementing 2 testing 3 done 4 > "$GH_CACHE_DIRECTORY/7/fields.tsv"

failed=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: [$2]"; echo "       actual:   [$3]"; failed=$((failed + 1)); fi
}

echo 'the rule: where an epic stands follows from its sub-issues, forward only'
. "$ROOT/lib/board.sh"
check 'nothing started'              ''             "$(epic_target todo todo backlog)"
check 'one started'                  implementing   "$(epic_target todo implementing todo)"
check 'all in testing or done'       testing        "$(epic_target implementing testing done)"
check 'all done'                     CLOSE          "$(epic_target testing done done)"
check 'never backward'               ''             "$(epic_target testing implementing testing)"
check 'no sub-issues, nothing'       ''             "$(epic_target todo)"
check 'not planned left out'         CLOSE          "$(epic_target testing done 'not planned')"
check 'only not planned, nothing'    ''             "$(epic_target testing 'not planned')"
check 'a closed epic never moves'    ''             "$(epic_target 'not planned' implementing)"

# The fake gh: #3 is a sub-issue of #44, #44 has no parent; $FAKE/epic-44 holds the statuses of
# #44 and of its sub-issues as the board gives them, one a line, the epic first
cat > "$FAKE/bin/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" | tr '\n' ' ' >> "$FAKE/calls"; printf '\n' >> "$FAKE/calls"
num="\$(printf '%s\n' "\$@" | sed -n 's/^\(num\|n\)=\([0-9]*\)$/\2/p' | head -1)"
case "\$*" in
  *'subIssues(first'*)        cat "$FAKE/epic-44" ;;
  *'parent {'*)               [ "\$num" = 3 ] && echo 'example-org/example-repo 44' ;;
  *includeArchived*)          printf 'PVT_epic7\tPVTI_card%s\n' "\$num" ;;
  *'projectItems(first:20)'*) printf 'example-org/7\tPVTI_card%s\n' "\$num" ;;
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

echo 'issue-status: a sub-issue that only started leaves an epic in testing where it is'
: > "$FAKE/calls"; printf 'testing\nimplementing\ntesting\n' > "$FAKE/epic-44"
out="$(bash "$ROOT/bin/issue-status.sh" --project 7 example-org/example-repo 3 implementing 2>&1)"; rc=$?
check 'exit 0'        0 "$rc"
check 'no epic line'  '' "$(grep '^epic' <<< "$out")"
check 'only the sub-issue moved' 'iid=PVTI_card3' "$(moves)"

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

echo
if [ "$failed" -gt 0 ]; then echo "$failed failed"; exit 1; fi
echo 'all passed'
