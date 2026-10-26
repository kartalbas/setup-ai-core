#!/usr/bin/env bash
# labels-sync --all on a GitHub board: an archived repository is named and skipped, and does not fail the
# run, because GitHub refuses every label write to it. A FAKE gh on PATH, so nothing is changed; the check
# is shown red on a copy of the harness whose labels-sync does not ask, and green on the real one.
#
#   bash tests/labels-sync-archived.test.sh
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
archived() { case " $ARCHIVED " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
case "$*" in
  *isArchived*) [ "${ARCHIVED_ANSWER:-}" = garbage ] && { echo maybe; exit 0; }
                [ "${ARCHIVED_ANSWER:-}" = refused ] && { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
                if archived "$3"; then echo true; else echo false; fi; exit 0 ;;
  *isPrivate*) echo '{"isPrivate":false}'; exit 0 ;;
  *'organization(login'*) echo PVT_example; exit 0 ;;
  *'repositories(first'*) printf '%s\n' $BOARD_REPOS; exit 0 ;;
  "label create"*) if archived "$5"; then echo "HTTP 403: Repository was archived so is read-only" >&2; exit 1; fi; exit 0 ;;
  "label list"*) exit 0 ;;
esac
echo '{}'
GH
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"
failed=0
check() {  # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: [$2]"; echo "       actual:   [$3]"; failed=$((failed + 1)); fi
}

# sync <harness root> <args>...: runs labels-sync, prints its output and then "exit N"
sync() {
  local root="$1"; shift
  : > "$LOG"
  ( cd "$WORK/project" && bash "$root/bin/labels-sync.sh" "$@" 2>&1; echo "exit $?" )
}
labelled() { grep -c "^label create .* --repo $1 " "$LOG" || true; }

export BOARD_REPOS="example-org/live example-org/legacy"
ARCHIVED="example-org/legacy"; export ARCHIVED
out="$(sync "$ROOT" --all --project example-org/1)"
check "an archived repository is named as skipped" "yes" "$(grep -qx 'example-org/legacy: archived, skipped' <<< "$out" && echo yes || echo no)"
check "the run exits 0" "exit 0" "$(tail -n 1 <<< "$out")"
check "the live repository gets its labels" "yes" "$([ "$(labelled example-org/live)" -gt 0 ] && echo yes || echo no)"
check "the archived repository is sent no label" "0" "$(labelled example-org/legacy)"

export BOARD_REPOS="example-org/legacy"
out="$(sync "$ROOT" --all --project example-org/1)"
check "a board whose only repository is archived exits 0" "exit 0" "$(tail -n 1 <<< "$out")"
check "and names it as skipped" "yes" "$(grep -qx 'example-org/legacy: archived, skipped' <<< "$out" && echo yes || echo no)"

# innocent: nothing archived, every repository is labelled and none is called skipped
export BOARD_REPOS="example-org/live example-org/other" ARCHIVED=""
out="$(sync "$ROOT" --all --project example-org/1)"
check "innocent: no archived repository, exit 0" "exit 0" "$(tail -n 1 <<< "$out")"
check "innocent: no repository is called skipped" "0" "$(grep -c 'skipped' <<< "$out" || true)"
check "innocent: both repositories are labelled" "yes" "$([ "$(labelled example-org/live)" -gt 0 ] && [ "$(labelled example-org/other)" -gt 0 ] && echo yes || echo no)"

# an answer that is no boolean is refused, never read as "not archived"
export BOARD_REPOS="example-org/live" ARCHIVED_ANSWER=garbage
out="$(sync "$ROOT" --all --project example-org/1)"
check "an unreadable isArchived stops the run, naming the repository" "yes" "$(grep -q 'cannot establish whether example-org/live is archived' <<< "$out" && echo yes || echo no)"
check "and it does not exit 0" "no" "$([ "$(tail -n 1 <<< "$out")" = "exit 0" ] && echo yes || echo no)"

# a read that gh refuses stops the run too, before any repository is labelled
export ARCHIVED_ANSWER=refused
out="$(sync "$ROOT" --all --project example-org/1)"
check "a refused isArchived read stops the run" "no" "$([ "$(tail -n 1 <<< "$out")" = "exit 0" ] && echo yes || echo no)"
check "and no repository is labelled" "0" "$(labelled example-org/live)"
unset ARCHIVED_ANSWER

# a repository named on the command line is not asked: the person named it, GitHub's refusal stands
export BOARD_REPOS="" ARCHIVED="example-org/legacy"
out="$(sync "$ROOT" example-org/legacy)"
check "a named archived repository is still tried, and GitHub's refusal reaches the person" "yes" \
  "$(grep -q 'HTTP 403' <<< "$out" && ! grep -q 'skipped' <<< "$out" && echo yes || echo no)"

# the planted defect: a labels-sync that does not ask must go red on the same board
mkdir -p "$WORK/planted"; cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/templates" "$WORK/planted/"
sed -i.bak 's/if repo_archived "\$r"; then/if false; then/' "$WORK/planted/bin/labels-sync.sh"
export BOARD_REPOS="example-org/live example-org/legacy" ARCHIVED="example-org/legacy"
out="$(sync "$WORK/planted" --all --project example-org/1)"
check "planted: a labels-sync that does not ask for archived is caught" "exit 1" "$(tail -n 1 <<< "$out")"
check "planted: the copy was changed at the one place" "1" "$(grep -c 'if false; then' "$WORK/planted/bin/labels-sync.sh")"

[ "$failed" -eq 0 ] || { echo "$failed failed"; exit 1; }
