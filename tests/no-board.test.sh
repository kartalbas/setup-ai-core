#!/usr/bin/env bash
# --no-board files an issue in a repository that is linked to no open board and touches no
# board, and it is refused everywhere it would keep work off a board that exists.
#
#   bash tests/no-board.test.sh

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fake="$(mktemp -d)"
export GH_CACHE_DIRECTORY="$fake/cache"
trap 'rm -rf "$fake"' EXIT
log="$fake/calls.txt"

# A fake gh that writes down every call. The repository in the request decides whether it is
# linked: example-harness answers no open project, every other repository answers one. That is
# the whole distinction --no-board turns on, so the fake makes it rather than assuming it.
cat > "$fake/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$log"
case "\$*" in
  *n=example-harness*projectsV2*) exit 0 ;;
  *projectsV2*)                   printf '9\tBoard Nine\n'; exit 0 ;;
  *issue*create*area:missing*)    echo "could not add label: 'area:missing' not found" >&2; exit 1 ;;
  *issue*create*)                 printf 'https://github.com/example-org/example-harness/issues/999\n'; exit 0 ;;
  *projectItems*)                 exit 0 ;;
  *addProjectV2ItemById*)         echo 'PVTI_new'; exit 0 ;;
  *) echo '{}'; exit 0 ;;
esac
EOF
chmod +x "$fake/gh"
export PATH="$fake:$PATH"

failed=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}
called() { grep -q -- "$1" "$log" && echo yes || echo no; }

body="$fake/body.md"; printf 'the body\n' > "$body"
harness='example-org/example-harness'; linked='example-org/example-repo'
new() {  # new <repo> [argument]...
  local repo="$1"; shift
  : > "$log"
  out="$(bash "$root/bin/issue-new.sh" --repo "$repo" \
    --title 'Put every new issue on its board, or nobody reading the board sees it' \
    --body-file "$body" --asked-by kartalbas --asked-in 'the test' "$@" 2>&1)"
}

echo 'a repository on no board: the issue is filed, and no board is touched'
new "$harness" --label type:feature --label area:tooling --no-board; rc=$?
check 'exit 0'                    0 "$rc"
check 'the issue is created'      yes "$(called 'issue create')"
check 'no card is added'          no "$(called 'addProjectV2ItemById')"
check 'no field is written'       no "$(called 'updateProjectV2ItemFieldValue')"
check 'it says so'                yes "$(grep -q '^#999 -> on no board: example-org/example-harness is linked to none$' <<< "$out" && echo yes || echo no)"

echo 'a repository that IS on a board: refused, nothing filed'
new "$linked" --label type:feature --label area:tooling --no-board; rc=$?
check 'exit 1'                    1 "$rc"
check 'nothing filed'             no "$(called 'issue create')"
check 'it says why'               yes "$(grep -q 'is linked to an open project, so --no-board would keep this issue off a board that exists' <<< "$out" && echo yes || echo no)"

echo 'a field of the board or the board itself, named with the flag: refused'
for extra in '--priority P2' '--status todo' '--project 9'; do
  # shellcheck disable=SC2086  # the pair is split into its flag and its value on purpose
  new "$harness" --label type:feature --label area:tooling --no-board $extra; rc=$?
  check "with $extra: exit 1"     1 "$rc"
  check "with $extra: nothing filed" no "$(called 'issue create')"
  check "with $extra: it says they contradict" yes "$(grep -q 'contradict each other' <<< "$out" && echo yes || echo no)"
done

echo 'the flag does not relax the two labels'
new "$harness" --label area:tooling --no-board; rc=$?
check 'exit 1'                    1 "$rc"
check 'it names the labels'       yes "$(grep -q 'at least two labels are required' <<< "$out" && echo yes || echo no)"

echo 'without the flag, a repository on no board is still refused'
new "$harness" --label type:feature --label area:tooling --priority P2; rc=$?
check 'exit 1'                    1 "$rc"
check 'nothing filed'             no "$(called 'issue create')"

echo 'a create gh refuses over a label the repository lacks: nothing filed, and labels-sync named'
new "$harness" --label type:feature --label area:missing --no-board; rc=$?
check 'exit 1'                    1 "$rc"
check "gh's reason stays"         yes "$(grep -q "could not add label: 'area:missing' not found" <<< "$out" && echo yes || echo no)"
check 'it names the command'      yes "$(grep -q 'the issue was NOT created in example-org/example-harness - gh exited 1, .* run: ai-core labels-sync example-org/example-harness' <<< "$out" && echo yes || echo no)"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
