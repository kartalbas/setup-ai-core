#!/usr/bin/env bash
# Which provider answers the issue and board calls, and how a setting is read: TRACKER in the
# project's config.env (or the environment) names the folder of lib/ that implements the tracker,
# github when it is unset; a name with no folder stops the command and says which folders there are.
# config_value reads any key the same way for every provider that follows.
#
#   bash tests/tracker-provider.test.sh
#
# Nothing here reaches GitHub: board.sh is only sourced. The refusal is shown red on a copy of lib/
# whose check is taken out, and green on the real one. The folder lookup is lib/common.sh's, shared
# with lib/forge.sh.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" AI_CORE_HOME="$WORK/ai-core-home"
mkdir -p "$HOME" "$AI_CORE_HOME" "$WORK/project/.ai-core"
git init -q "$WORK/project"
git -C "$WORK/project" remote add origin https://github.com/example-org/example-repo.git
failed=0
check() {  # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: [$2]"; echo "       actual:   [$3]"; failed=$((failed + 1)); fi
}

# config_value <key> <default>, asked inside the project and with a clean environment
ask() {  # ask <key> <default>
  ( cd "$WORK/project" && env -u TRACKER -u TKEY bash -c '. "$1/lib/common.sh"; config_value "$2" "$3"' _ "$ROOT" "$1" "$2" )
}
config() { printf '%b' "$1" > "$WORK/project/.ai-core/config.env"; }

config 'TKEY=plain\n'
check "a setting is read from config.env" "plain" "$(ask TKEY dflt)"
check "a key that is not set gives the default" "dflt" "$(ask OTHER dflt)"
config 'TKEY="two words" # a comment\n'
check "a quoted value is read whole, the comment dropped" "two words" "$(ask TKEY dflt)"
config 'TKEY=bare words # a comment\n'
check "an unquoted value stops at its comment" "bare words" "$(ask TKEY dflt)"
config 'TKEY="a # b"\n'
check "a # inside quotes stays" "a # b" "$(ask TKEY dflt)"
config 'TKEY=first\nTKEY=last\n'
check "the last line that sets a key wins" "last" "$(ask TKEY dflt)"
config 'TKEY=crlf\r\n'
check "a CRLF line ending is not part of the value" "crlf" "$(ask TKEY dflt)"
config 'TKEY=\n'
check "an empty value gives the default" "dflt" "$(ask TKEY dflt)"
config 'TKEY=file\n'
check "the environment wins over the file" "env" "$( cd "$WORK/project" && TKEY=env bash -c '. "$1/lib/common.sh"; config_value TKEY dflt' _ "$ROOT" )"

# a harness clone has no .ai-core/config.env: its five tracker settings are the layer's config.env at its root,
# the file init copies into the repositories the layer serves. Every other setting, and a product clone, read as before.
harness="$WORK/shop-ai-core"; mkdir -p "$harness"; git init -q "$harness"
git -C "$harness" remote add origin https://github.com/example-org/shop-ai-core.git
printf 'TRACKER="plane"\nPLANE_URL=https://plane.example.test\nPLANE_WORKSPACE=ws\nPLANE_PROJECT=SHOP\nTKEY=layer-only\n' > "$harness/config.env"
product="$WORK/shop-web"; mkdir -p "$product/.ai-core"; git init -q "$product"
git -C "$product" remote add origin https://github.com/example-org/shop-web.git
printf 'TRACKER=github\nPLANE_PROJECT=OWN\n' > "$product/.ai-core/config.env"
printf 'TRACKER=plane\nPLANE_PROJECT=ROOT\n' > "$product/config.env"
unbound="$WORK/shop-api"; mkdir -p "$unbound"; git init -q "$unbound"
git -C "$unbound" remote add origin https://github.com/example-org/shop-api.git
printf 'TRACKER=plane\nPLANE_PROJECT=ROOT\n' > "$unbound/config.env"
git -C "$harness" -c user.name=t -c user.email=t@example.test commit -q --allow-empty -m start
git -C "$harness" worktree add -q "$WORK/shop-ai-core-tree" -b layer-tree
read_in() {  # read_in <lib root> <directory> <key> <default>
  ( cd "$2" && env -u TRACKER -u PLANE_PROJECT -u TKEY bash -c '. "$1/lib/common.sh"; config_value "$2" "$3"' _ "$1" "$3" "$4" )
}
check "a harness clone reads TRACKER from the layer's config.env" "plane" "$(read_in "$ROOT" "$harness" TRACKER github)"
check "a harness clone reads PLANE_PROJECT from the layer's config.env" "SHOP" "$(read_in "$ROOT" "$harness" PLANE_PROJECT none)"
check "a worktree of a harness clone reads the layer's config.env too" "SHOP" "$(read_in "$ROOT" "$WORK/shop-ai-core-tree" PLANE_PROJECT none)"
check "a harness clone reads a setting beyond the five as before: not from the layer's file" "none" "$(read_in "$ROOT" "$harness" TKEY none)"
check "the environment wins over the layer's config.env" "env" "$( cd "$harness" && PLANE_PROJECT=env bash -c '. "$1/lib/common.sh"; config_value PLANE_PROJECT none' _ "$ROOT" )"
check "a product clone with a config.env at its root still reads its own .ai-core/config.env" "OWN" "$(read_in "$ROOT" "$product" PLANE_PROJECT none)"
check "a product clone with no .ai-core/config.env does not read a config.env at its root" "none" "$(read_in "$ROOT" "$unbound" PLANE_PROJECT none)"
owned="$WORK/tool-ai-core"; mkdir -p "$owned/.ai-core"; git init -q "$owned"
git -C "$owned" remote add origin https://github.com/example-org/tool-ai-core.git
printf 'PLANE_PROJECT=LAYER\n' > "$owned/config.env"; printf 'PLANE_PROJECT=OWN\n' > "$owned/.ai-core/config.env"
check "a harness clone with its own .ai-core/config.env reads that file, not the layer's" "OWN" "$(read_in "$ROOT" "$owned" PLANE_PROJECT none)"
mkdir -p "$WORK/planted-layer"; rm -rf "$WORK/planted-layer/lib"; cp -R "$ROOT/lib" "$WORK/planted-layer/lib"
sed -i.bak 's|&& is_harness_clone "\$main"; then|\&\& false; then|' "$WORK/planted-layer/lib/common.sh"
cmp -s "$ROOT/lib/common.sh" "$WORK/planted-layer/lib/common.sh" && { echo "  FAIL the planted copy equals the real common.sh"; failed=$((failed + 1)); }
check "planted: without the read from the layer's config.env a harness clone reads nothing" "none" "$(read_in "$WORK/planted-layer" "$harness" PLANE_PROJECT none)"
check "innocent: the same copy still reads a product clone's own .ai-core/config.env" "OWN" "$(read_in "$WORK/planted-layer" "$product" PLANE_PROJECT none)"

# the dispatch: sourcing board.sh in the project with TRACKER set as asked; prints what happened
dispatch() {  # dispatch <lib root> <TRACKER or 'unset'>
  ( cd "$WORK/project" && { [ "$2" = unset ] && unset TRACKER || export TRACKER="$2"; } &&
    bash -c '. "$1/lib/board.sh" && echo "tracker=$TRACKER $(type -t gh_org)"' _ "$1" 2>&1 | tail -n1 )
}
config ''
check "no TRACKER means github, whose functions are loaded" "tracker=github function" "$(dispatch "$ROOT" unset)"
check "TRACKER=github" "tracker=github function" "$(dispatch "$ROOT" github)"
check "TRACKER is read without regard to case" "tracker=github function" "$(dispatch "$ROOT" GitHub)"
config 'TRACKER="github"\n'
check "TRACKER in config.env" "tracker=github function" "$(dispatch "$ROOT" unset)"
config 'TRACKER="nonesuch"\n'
refusal="error: TRACKER is 'nonesuch', and this harness has no tracker of that name. It has: github plane"
check "a name with no folder is refused and the folders are named" "$refusal" "$(dispatch "$ROOT" unset)"
config ''
check "a name that leads out of lib/ is refused" "error: TRACKER is '../skeleton', and this harness has no tracker of that name. It has: github plane" "$(dispatch "$ROOT" ../skeleton)"

# the planted defect: a copy of lib/ whose refusal is taken out must make the same check go red
mkdir -p "$WORK/planted"; cp -R "$ROOT/lib" "$WORK/planted/lib"
sed -i.bak 's/^  if \[ ! -f "\$file" \]; then/  if false; then/' "$WORK/planted/lib/common.sh"
cmp -s "$ROOT/lib/common.sh" "$WORK/planted/lib/common.sh" && { echo "  FAIL the planted copy equals the real common.sh"; failed=$((failed + 1)); }
check "planted: the copy without its refusal is not refused as the real one is" "no" \
  "$([ "$(dispatch "$WORK/planted" nonesuch)" = "$refusal" ] && echo yes || echo no)"
check "innocent: the same copy still loads github" "tracker=github function" "$(dispatch "$WORK/planted" github)"

# the interface: a provider that lacks a function is refused at once, and names it
mkdir -p "$WORK/planted/lib/lacking"
printf 'gh_org() { :; }\n' > "$WORK/planted/lib/lacking/tracker.sh"
lacks="$(dispatch "$WORK/planted" lacking)"
check "a provider without the functions is refused" "yes" "$(case "$lacks" in "error: the tracker 'lacking' lacks these functions: default_repo "*issue_rows*) echo yes ;; *) echo no ;; esac)"
check "a provider with them all is not" "tracker=github function" "$(dispatch "$ROOT" github)"

cp -R "$ROOT/lib" "$WORK/visibility-lib"
mkdir -p "$WORK/visibility-copy"; mv "$WORK/visibility-lib" "$WORK/visibility-copy/lib"
sed '/^repo_visibility() {/,/^}/d' "$ROOT/lib/github/tracker.sh" > "$WORK/visibility-copy/lib/github/tracker.sh"
lacks="$(dispatch "$WORK/visibility-copy" github)"
check "missing visibility interface is named" yes "$(grep -q 'lacks these functions: repo_visibility' <<< "$lacks" && echo yes || echo no)"

# a provider that answers no landing context cannot tell finish-issue whether an issue holds a record, and one that
# cannot name the work item a reference means cannot tell finish-issue, integrate-issue, start-issue or session-start
# which branch is an issue's
for provider in github plane; do
  for function in issue_landing_context referenced_issue; do
    cp -R "$ROOT/lib" "$WORK/context-lib"
    mkdir -p "$WORK/context-copy"; rm -rf "$WORK/context-copy/lib"; mv "$WORK/context-lib" "$WORK/context-copy/lib"
    sed "/^$function() {/,/^}/d" "$ROOT/lib/$provider/tracker.sh" > "$WORK/context-copy/lib/$provider/tracker.sh"
    cmp -s "$ROOT/lib/$provider/tracker.sh" "$WORK/context-copy/lib/$provider/tracker.sh" && { echo "  FAIL the planted copy equals $provider's $function"; failed=$((failed + 1)); }
    lacks="$(dispatch "$WORK/context-copy" "$provider")"
    check "$provider without $function is named" yes "$(grep -q "lacks these functions: $function" <<< "$lacks" && echo yes || echo no)"
  done
done
check "github names the number a reference gives, whatever the time" "287" "$( cd "$WORK/project" && bash -c '. "$1/lib/board.sh"; referenced_issue example-org/example-repo 287 1700000000' _ "$ROOT" )"

# the forge: FORGE names the folder of lib/ the same way, and the check of a commit answers four ways
fdispatch() {  # fdispatch <lib root> <FORGE or 'unset'>
  ( cd "$WORK/project" && { [ "$2" = unset ] && unset FORGE || export FORGE="$2"; } &&
    bash -c '. "$1/lib/forge.sh" && echo "forge=$FORGE $(forge_host)"' _ "$1" 2>&1 | tail -n1 )
}
config ''
check "no FORGE means github" "forge=github github.com" "$(fdispatch "$ROOT" unset)"
check "a FORGE with no folder is refused and the folders are named" "error: FORGE is 'nonesuch', and this harness has no forge of that name. It has: forgejo github" "$(fdispatch "$ROOT" nonesuch)"
mkdir -p "$WORK/fake"
cat > "$WORK/fake/gh" <<'GH'
#!/bin/sh
# FAKE_RUNS answers `gh run list`, FAKE_STATUS the commit statuses (none when unset); "broken" fails the call
case "$1" in
  api) answer="${FAKE_STATUS:-{\"state\":\"pending\",\"total_count\":0\}}" ;;
  *) # as gh does where the repository has no workflow of that name, a status-only one among them
     case " $* " in *" --workflow "*) echo 'could not find any workflows named check' >&2; exit 1 ;; esac
     answer="$FAKE_RUNS" ;;
esac
case "$answer" in
  broken) echo 'HTTP 502: Bad Gateway' >&2; exit 1 ;;
  *) echo "$answer" ;;
esac
GH
chmod +x "$WORK/fake/gh"
checked() {  # checked <what the fake gh answers for the runs> [what it answers for the commit statuses]
  ( cd "$WORK/project" && PATH="$WORK/fake:$PATH" FAKE_RUNS="$1" FAKE_STATUS="${2:-}" bash -c '. "$1/lib/forge.sh"; commit_checked "$2" abc 2>&1' _ "$ROOT" "$WORK/project" )
}
check "commit_checked: a completed success is green" "green" "$(checked '[{"status":"completed","conclusion":"success","workflowName":"check"}]')"
check "commit_checked: completed with no success is red" "red" "$(checked '[{"status":"completed","conclusion":"failure","workflowName":"check"},{"status":"completed","conclusion":"cancelled","workflowName":"check"}]')"
check "commit_checked: a run still going is pending" "pending" "$(checked '[{"status":"in_progress","conclusion":null,"workflowName":"check"}]')"
check "commit_checked: no run yet is pending" "pending" "$(checked '[]')"
check "commit_checked: a failed query is unreadable, with the words of the forge" "unreadable
HTTP 502: Bad Gateway " "$(checked broken)"
check "commit_checked: an empty answer is unreadable" "unreadable" "$(checked '')"
# a pipeline that posts a commit status and no run (tekton/ci): the statuses decide
none='[]'
check "commit_checked: only a status, success, is green" "green" "$(checked "$none" '{"state":"success","total_count":1}')"
check "commit_checked: only a status, failure, is red" "red" "$(checked "$none" '{"state":"failure","total_count":1}')"
check "commit_checked: only a status, error, is red" "red" "$(checked "$none" '{"state":"error","total_count":1}')"
check "commit_checked: only a status, pending, is pending" "pending" "$(checked "$none" '{"state":"pending","total_count":1}')"
check "commit_checked: a failed query for the statuses is unreadable, with the words of the forge" "unreadable
HTTP 502: Bad Gateway " "$(checked "$none" broken)"
check "commit_checked: an answer for the statuses that is no JSON is unreadable" "unreadable" "$(checked "$none" 'not json' | head -n1)"
# a repository with statuses and no workflow `check` (hostyour-cloud): gh lists the runs of other workflows or none
check "commit_checked: a status alone is green where gh finds no workflow check" "green" "$(checked '[]' '{"state":"success","total_count":1}')"
other='[{"status":"completed","conclusion":"success","workflowName":"build"}]'
check "commit_checked: a green run of another workflow is no check, so a green status decides" "green" "$(checked "$other" '{"state":"success","total_count":1}')"
check "commit_checked: a green run of another workflow with no status is pending" "pending" "$(checked "$other")"
check "commit_checked: a failed run of another workflow does not turn a green check red" "green" "$(checked '[{"status":"completed","conclusion":"failure","workflowName":"build"},{"status":"completed","conclusion":"success","workflowName":"check"}]')"
check "commit_checked: a checkout with no origin is unreadable, and says so" "unreadable
$WORK/no-origin has no origin to ask for the checks" "$(git init -q "$WORK/no-origin"; PATH="$WORK/fake:$PATH" FAKE_RUNS='[]' bash -c '. "$1/lib/forge.sh"; commit_checked "$2" abc 2>&1' _ "$ROOT" "$WORK/no-origin")"
# runs and statuses together: green needs both, red needs one
done_ok='[{"status":"completed","conclusion":"success","workflowName":"check"}]'
check "commit_checked: a green run and a green status are green" "green" "$(checked "$done_ok" '{"state":"success","total_count":1}')"
check "commit_checked: a green run and a pending status are pending" "pending" "$(checked "$done_ok" '{"state":"pending","total_count":1}')"
check "commit_checked: a green run and a failed status are red" "red" "$(checked "$done_ok" '{"state":"failure","total_count":1}')"
check "commit_checked: a run still going and a green status are pending" "pending" "$(checked '[{"status":"in_progress","conclusion":null,"workflowName":"check"}]' '{"state":"success","total_count":1}')"
check "commit_checked: a failed run and a green status are red" "red" "$(checked '[{"status":"completed","conclusion":"failure","workflowName":"check"}]' '{"state":"success","total_count":1}')"
check "commit_checked: a run still going and a failed status are red" "red" "$(checked '[{"status":"in_progress","conclusion":null,"workflowName":"check"}]' '{"state":"failure","total_count":1}')"

# the visibility of a repository: the forge reads isPrivate as the tracker does, and both refuse what is no boolean
cat > "$WORK/fake/gh" <<'GH'
#!/bin/sh
case "$FAKE_VISIBILITY" in
  broken) echo 'visibility denied' >&2; exit 1 ;;
  *) echo "$FAKE_VISIBILITY" ;;
esac
GH
visible() {
  ( cd "$WORK/project" && PATH="$WORK/fake:$PATH" FAKE_VISIBILITY="$2" bash -c '. "$1/lib/forge.sh"; . "$1/lib/tracker.sh"; "$2" example-org/example-repo 2>&1' _ "$ROOT" "$1" )
}
for fn in forge_repo_visibility repo_visibility; do
  check "$fn: isPrivate false is public" "public" "$(visible $fn '{"isPrivate":false}')"
  check "$fn: isPrivate true is private" "private" "$(visible $fn '{"isPrivate":true}')"
  check "$fn: a string for isPrivate is refused" "yes" "$(case "$(visible $fn '{"isPrivate":"true"}')" in *'isPrivate was not a boolean'*) echo yes ;; *) echo no ;; esac)"
  check "$fn: a refused query is refused with the words of gh" "yes" "$(case "$(visible $fn broken)" in *'visibility denied'*) echo yes ;; *) echo no ;; esac)"
done

[ "$failed" -eq 0 ] || { echo "$failed failed"; exit 1; }
