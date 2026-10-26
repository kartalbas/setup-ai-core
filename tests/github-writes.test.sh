#!/usr/bin/env bash
# What every write of lib/github/tracker.sh says when GitHub refuses it and when the answer is lost, and what it
# prints when it succeeds. One table of the real calls, each run against a stand-in gh in three modes:
#   refuse  GitHub refuses with HTTP 403 and its own message (the one a plan issue with 2500 comments gets):
#           the call fails, says it was NOT done, carries GitHub's words, never says it could not read
#           something, prints nothing on stdout and sends the write once;
#   lost    the write is stored and the answer is lost, no status: the call fails, says it is not known
#           whether it was done, never that it was NOT done, and sends the write once;
#   ok      the call succeeds and prints the shape its caller reads.
# The read behind a write, the lookup of an id, stays gh_read and still says "cannot read".
#
# THE PLANTED DEFECTS, each shown red beside the innocent run: a write that goes back to gh_read, a write helper
# that forgets the status of the refusal, and one that does not keep the two streams apart.
#
#   bash tests/github-writes.test.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAKE="$(mktemp -d)"
trap 'rm -rf "$FAKE"' EXIT
export HOME="$FAKE/home" AI_CORE_HOME="$FAKE/ai-core-home" FAKE GH_ORG=example-org GH_PROJECT_NUMBER=7 GH_CACHE_DIRECTORY="$FAKE/cache" AI_CORE_SLEEP=true
mkdir -p "$HOME" "$AI_CORE_HOME" "$FAKE/bin" "$FAKE/work" "$GH_CACHE_DIRECTORY/7"
echo PVT_board7 > "$GH_CACHE_DIRECTORY/7/project-id"
printf '{"query":"mutation"}\n' > "$FAKE/request.json"
git init -q "$FAKE/work"

# The write is told from the read by its shape: a REST method, a GraphQL mutation, a transfer, a request file,
# or a body posted to a comments path. Every write is recorded, and a stored one stays stored whatever the answer.
cat > "$FAKE/bin/gh" <<'EOF'
#!/usr/bin/env bash
all="$*"
case "$all" in
  *'--jq .node_id'*) [ "${GH_MODE:-}" != readfail ] || { echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }; echo NODE_1; exit 0 ;;
  *'--jq .id'*)      [ "${GH_MODE:-}" != readfail ] || { echo '{"message":"Not Found"}'; echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }; echo 9001; exit 0 ;;
  *includeArchived*) exit 0 ;;
  *'organization(login:$o){ id }'*) echo O_1; exit 0 ;;
  *'projectV2(number:$n){ id }'*) echo PVT_src; exit 0 ;;
esac
write=no
case "$all" in
  *--method*|*mutation*|*'issue transfer'*|*--input*) write=yes ;;
  *'/comments '*body*) write=yes ;;
esac
[ "$write" = yes ] || { echo "the stand-in gh has no answer for: $all" >&2; exit 9; }
echo write >> "$FAKE/writes"
case "${GH_MODE:-ok}" in
  refuse) echo '{"message":"Commenting is disabled on issues with more than 2500 comments","documentation_url":"https://docs.github.com"}'
          echo 'gh: Commenting is disabled on issues with more than 2500 comments (HTTP 403)' >&2; exit 1 ;;
  lost)   echo stored >> "$FAKE/stored"; echo 'error connecting to api.github.com' >&2; exit 1 ;;
esac
echo stored >> "$FAKE/stored"
case "$all" in
  *addProjectV2ItemById*)        echo ITEM_1 ;;
  *copyProjectV2*)               printf '12\thttps://example.test/boards/12\n' ;;
  *linkProjectV2ToRepository*)   echo example-org/shop ;;
  *updateProjectV2View*)         echo 'Board: repo:example-org/shop' ;;
  *--input*)                     echo P1 ;;
  *'issue transfer'*)            echo https://github.com/example-org/other/issues/7 ;;
  *'/comments '*)                echo https://github.com/example-org/shop/issues/94#issuecomment-1 ;;
  *) echo '{}' ;;
esac
EOF
chmod +x "$FAKE/bin/gh"
export PATH="$FAKE/bin:$PATH"

failed=0
check() {  # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}

# The writes of the tracker: the function, the call as the commands make it, what its success prints.
ROWS=(
  "item_id|item_id example-org/shop 5|ITEM_1"
  "subissue_detach|subissue_detach example-org/parent 3 example-org/child 4|"
  "issue_close|issue_close example-org/shop 5 completed|"
  "issue_reopen|issue_reopen example-org/shop 5|"
  "issue_comment_post|issue_comment_post example-org/shop 94 'A comment' ''|https://github.com/example-org/shop/issues/94#issuecomment-1"
  "duplicate_mark|duplicate_mark example-org/shop 1 example-org/shop 2 'Duplicate of #1'|"
  "duplicate_unmark|duplicate_unmark example-org/shop 1 example-org/shop 2|"
  "issue_edit|issue_edit example-org/shop 5 'A new title' ''|"
  "issue_transfer|issue_transfer example-org/shop 5 example-org/other|https://github.com/example-org/other/issues/7"
  "field_options_replace|field_options_replace Priority $FAKE/request.json|P1"
  "project_create|project_create example-org 5 'A board'|$(printf '12\thttps://example.test/boards/12')"
  "repo_link|repo_link example-org/shop|example-org/shop"
  "view_filter_set|view_filter_set VIEW_1 'repo:example-org/shop'|Board: repo:example-org/shop"
)

# call <harness root> <mode> <call>: runs the call, leaves its stdout, stderr and status in $FAKE/out, $FAKE/err, $rc
call() {
  : > "$FAKE/writes"; : > "$FAKE/stored"
  rc=0
  ( cd "$FAKE/work" && GH_MODE="$2" bash -c '. "$1/lib/board.sh"; set_project 7 example-org/shop > /dev/null; eval "$2"' _ "$1" "$3" ) > "$FAKE/out" 2> "$FAKE/err" || rc=$?
}
# row_result <harness root> <name> <call> <success output>: "ok" when the row behaves in all three modes, else what differed
row_result() {
  local root="$1" name="$2" command="$3" shape="$4" wrong=""
  call "$root" refuse "$command"
  [ "$rc" -ne 0 ] || wrong="$wrong refuse-exit-0"
  grep -q 'was NOT' "$FAKE/err" || wrong="$wrong refuse-no-NOT"
  grep -q 'HTTP 403' "$FAKE/err" && grep -q '2500 comments' "$FAKE/err" || wrong="$wrong refuse-no-words"
  ! grep -q 'cannot read' "$FAKE/err" || wrong="$wrong refuse-says-cannot-read"
  [ ! -s "$FAKE/out" ] || wrong="$wrong refuse-prints-stdout"
  [ "$(grep -c . "$FAKE/writes")" = 1 ] || wrong="$wrong refuse-writes-$(grep -c . "$FAKE/writes")"
  call "$root" lost "$command"
  [ "$rc" -ne 0 ] || wrong="$wrong lost-exit-0"
  grep -q 'not known whether' "$FAKE/err" || wrong="$wrong lost-no-unknown"
  ! grep -q 'was NOT' "$FAKE/err" || wrong="$wrong lost-says-NOT"
  ! grep -q 'cannot read' "$FAKE/err" || wrong="$wrong lost-says-cannot-read"
  [ "$(grep -c . "$FAKE/writes")" = 1 ] && [ "$(grep -c . "$FAKE/stored")" = 1 ] || wrong="$wrong lost-writes-$(grep -c . "$FAKE/writes")"
  call "$root" ok "$command"
  [ "$rc" -eq 0 ] && [ "$(cat "$FAKE/out")" = "$shape" ] || wrong="$wrong ok-shape($rc:$(cat "$FAKE/out"))"
  printf '%s' "${wrong:- ok}" | sed 's/^ //'
}

echo 'every write of the tracker, refused, lost and answered'
for row in "${ROWS[@]}"; do
  IFS='|' read -r name command shape <<< "$row"
  check "$name" ok "$(row_result "$ROOT" "$name" "$command" "$shape")"
done

echo 'the read behind a write is still a read'
call "$ROOT" readfail 'subissue_detach example-org/parent 3 example-org/child 4'
check 'the lookup of the id says cannot read, and nothing was written' "yes 0" \
  "$(grep -q 'cannot read the database id of example-org/child#4' "$FAKE/err" && echo yes || echo no) $(grep -c . "$FAKE/writes")"
call "$ROOT" readfail 'repo_link example-org/shop'
check 'so does the node id of a repository to link' "yes 0" \
  "$(grep -q 'cannot read the node id of example-org/shop' "$FAKE/err" && echo yes || echo no) $(grep -c . "$FAKE/writes")"

echo 'planted: a write that goes back to gh_read, a helper without the status, a helper without the streams'
plant() {  # plant <name> <file> <sed expression>: a copy of the harness with one change; the change must differ
  local dir="$FAKE/plant-$1"
  rm -rf "$dir"; mkdir -p "$dir"; cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/templates" "$ROOT/VERSION" "$dir/"
  sed -i.bak "$3" "$dir/$2"
  if cmp -s "$ROOT/$2" "$dir/$2"; then echo "the plant $1 equals $2" >&2; failed=$((failed + 1)); fi
  echo "$dir"
}
for row in "issue_close|issue_close example-org/shop 5 completed|" "issue_comment_post|issue_comment_post example-org/shop 94 'A comment' ''|https://github.com/example-org/shop/issues/94#issuecomment-1" "view_filter_set|view_filter_set VIEW_1 'repo:example-org/shop'|Board: repo:example-org/shop"; do
  IFS='|' read -r name command shape <<< "$row"
  case "$name" in
    issue_close)        planted="$(plant read-close lib/github/tracker.sh 's|gh_write "\$1#\$2" closed api|gh_read "the close of $1#$2" api|')" ;;
    issue_comment_post) planted="$(plant read-comment lib/github/tracker.sh 's|gh_write "the comment on \$1#\$2" posted api|gh_read "the comment posted on $1#$2" api|')" ;;
    view_filter_set)    planted="$(plant read-view lib/github/tracker.sh "s|gh_write \"the filter of view '\$1'\" set api|gh_read \"the filter set on view '\$1'\" api|")" ;;
  esac
  check "planted: $name sent back to gh_read is red" "no" "$([ "$(row_result "$planted" "$name" "$command" "$shape")" = ok ] && echo yes || echo no)"
  check "innocent: $name as it is stays green" ok "$(row_result "$ROOT" "$name" "$command" "$shape")"
done
planted="$(plant no-status lib/github/gh.sh "s|'HTTP 4'??) die|'HTTP 9'??) die|")"
check 'planted: a helper that forgets the status of a refusal says unknown for every refusal' "no" \
  "$([ "$(row_result "$planted" issue_close 'issue_close example-org/shop 5 completed' '')" = ok ] && echo yes || echo no)"
planted="$(plant no-streams lib/github/gh.sh 's|run_split gh "\$@" \|\| rc=\$?|split_out="$(gh "$@" 2>\&1)" \|\| rc=$?; split_err=""|')"
check 'planted: a helper that does not keep the streams apart loses the status of the refusal' "no" \
  "$([ "$(row_result "$planted" issue_close 'issue_close example-org/shop 5 completed' '')" = ok ] && echo yes || echo no)"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo; echo 'all passed'
