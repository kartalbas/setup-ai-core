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
case "$FAKE_RUNS" in
  broken) echo 'HTTP 502: Bad Gateway' >&2; exit 1 ;;
  *) echo "$FAKE_RUNS" ;;
esac
GH
chmod +x "$WORK/fake/gh"
checked() {  # checked <what the fake gh answers>
  ( cd "$WORK/project" && PATH="$WORK/fake:$PATH" FAKE_RUNS="$1" bash -c '. "$1/lib/forge.sh"; commit_checked "$2" abc 2>&1' _ "$ROOT" "$WORK/project" )
}
check "commit_checked: a completed success is green" "green" "$(checked '[{"status":"completed","conclusion":"success"}]')"
check "commit_checked: completed with no success is red" "red" "$(checked '[{"status":"completed","conclusion":"failure"},{"status":"completed","conclusion":"cancelled"}]')"
check "commit_checked: a run still going is pending" "pending" "$(checked '[{"status":"in_progress","conclusion":null}]')"
check "commit_checked: no run yet is pending" "pending" "$(checked '[]')"
check "commit_checked: a failed query is unreadable, with the words of the forge" "unreadable
HTTP 502: Bad Gateway " "$(checked broken)"
check "commit_checked: an empty answer is unreadable" "unreadable" "$(checked '')"

[ "$failed" -eq 0 ] || { echo "$failed failed"; exit 1; }
