#!/usr/bin/env bash
# The calls issue-block, issue-unblock, subissue-add and labels-sync send, word for word, and what
# each says when the tracker refuses. They go through lib/tracker.sh, so a second tracker can answer
# them; on GitHub the calls are the ones the commands always made.
#
# Run with a FAKE gh on PATH, so nothing is changed. The calls are shown red on a copy of the
# harness whose provider sends another field, and green on the real one.
#
#   bash tests/issue-link-commands.test.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" AI_CORE_HOME="$WORK/ai-core-home" GH_CACHE_DIRECTORY="$WORK/cache"
mkdir -p "$HOME" "$AI_CORE_HOME" "$WORK/bin" "$WORK/project"
git init -q "$WORK/project"
LOG="$WORK/calls"; export LOG
cat > "$WORK/bin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LOG"
case "$*" in
  *"repos/example-org/blocked/issues/7/dependencies"*) [ -z "${REFUSE:-}" ] || { echo "gh: HTTP $REFUSE" >&2; exit 1; }; echo '{}'; exit 0 ;;
  *"repos/example-org/blocker/issues/9 "*"--jq .id"*) echo 9009; exit 0 ;;
  *"repos/example-org/parent/issues/3/sub_issues"*) echo '{}'; exit 0 ;;
  *"repos/example-org/child/issues/4 "*"--jq .id"*) echo 9004; exit 0 ;;
  *'projectsV2(first:50)'*) exit 0 ;;
  *'subIssues(first'*) printf 'todo\n'; exit 0 ;;
  *"label "*) exit 0 ;;
esac
echo '{}'
GH
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"

# calls <harness root>: runs the four commands and prints what each sent and said
calls() {
  local root="$1"
  : > "$LOG"
  ( cd "$WORK/project" || exit 1
    echo "block: $(bash "$root/bin/issue-block.sh" example-org/blocked 7 example-org/blocker 9 2>&1)"
    echo "unblock: $(bash "$root/bin/issue-unblock.sh" example-org/blocked 7 example-org/blocker 9 2>&1)"
    echo "subissue-add: $(bash "$root/bin/subissue-add.sh" example-org/parent 3 example-org/child#4 2>&1)"
    echo "block refused 422: $(REFUSE=422 bash "$root/bin/issue-block.sh" example-org/blocked 7 example-org/blocker 9 2>&1)"
    echo "unblock refused 404: $(REFUSE=404 bash "$root/bin/issue-unblock.sh" example-org/blocked 7 example-org/blocker 9 2>&1)"
  ); grep -E '^api (--method|repos/)' "$LOG"
}
expected="block: example-org/blocked#7 is blocked by example-org/blocker#9
unblock: example-org/blocked#7 is no longer blocked by example-org/blocker#9
subissue-add: example-org/child#4 -> #3
block refused 422: error: example-org/blocked#7 is already blocked by example-org/blocker#9 - nothing was changed
unblock refused 404: error: example-org/blocked#7 is not blocked by example-org/blocker#9 - nothing was changed
api repos/example-org/blocker/issues/9 --jq .id
api --method POST repos/example-org/blocked/issues/7/dependencies/blocked_by -F issue_id=9009
api repos/example-org/blocker/issues/9 --jq .id
api --method DELETE repos/example-org/blocked/issues/7/dependencies/blocked_by/9009
api repos/example-org/child/issues/4 --jq .id
api --method POST repos/example-org/parent/issues/3/sub_issues -F sub_issue_id=9004
api repos/example-org/blocker/issues/9 --jq .id
api --method POST repos/example-org/blocked/issues/7/dependencies/blocked_by -F issue_id=9009
api repos/example-org/blocker/issues/9 --jq .id
api --method DELETE repos/example-org/blocked/issues/7/dependencies/blocked_by/9009"
failed=0
check() {  # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected:"; sed 's/^/         /' <<< "$2"; echo "       actual:"; sed 's/^/         /' <<< "$3"; failed=$((failed + 1)); fi
}
actual="$(calls "$ROOT")"
# the said lines come first, then the calls, in the order the commands ran
check "the four commands say and send what they always did" "$expected" "$actual"

# labels-sync: one create per label of the taxonomy, with the colour and description, and the list read after
: > "$LOG"
( cd "$WORK/project" && bash "$ROOT/bin/labels-sync.sh" example-org/x > "$WORK/ls.out" 2>&1 )
rows="$(grep -c '^[a-z]' "$ROOT/templates/.ai-core/labels.tsv" || true)"
check "labels-sync creates every label of the taxonomy" "$rows" "$(grep -c '^label create ' "$LOG")"
check "labels-sync forces, with colour and description" "yes" "$(grep -q '^label create .* --repo example-org/x --color [0-9a-fA-F]* --description .* --force$' "$LOG" && echo yes || echo no)"
check "labels-sync reads the labels once afterwards" "1" "$(grep -c '^label list --repo example-org/x --limit 200 --json name --jq' "$LOG")"

# the planted defect: a provider that sends another field must make the same check go red
mkdir -p "$WORK/planted"; cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/templates" "$WORK/planted/"
sed -i.bak 's/-F issue_id=/-F blocker=/' "$WORK/planted/lib/github/tracker.sh"
planted="$(calls "$WORK/planted")"
check "planted: a provider that sends another field is caught" "no" "$([ "$planted" = "$expected" ] && echo yes || echo no)"
check "innocent: the copy still says what the real one says" "yes" \
  "$([ "$(grep -c '^block:\|^unblock:\|^subissue-add:' <<< "$planted")" = 3 ] && echo yes || echo no)"
[ "$failed" -eq 0 ] || { echo "$failed failed"; exit 1; }
