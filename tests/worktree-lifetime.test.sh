#!/usr/bin/env bash
# The lifetime of a worktree while init equips it, and what init and session-start write into a path
# that is no worktree any more.
#
# It runs inside TEMPORARY repositories with a temporary origin, and with a stand-in git on the PATH
# that holds one call of a run until the test lets it go, so a test can remove a worktree, lock it or
# kill the run at an exact point. What is pinned: init locks the worktree it equips and lifts the lock on
# every way out it can see; finish-issue --sweep names the lock and goes on; a worktree that is gone or
# is the leftover of one under .worktrees/ gets nothing written and nothing created; a kill -9 leaves a
# lock that is named and can be lifted. Nothing leaves the machine.
#
#   bash tests/worktree-lifetime.test.sh

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fake="$(mktemp -d)"
export HOME="$fake/home" AI_CORE_HOME="$fake/ai-core-home" CLAUDE_CONFIG_DIR="$fake/claude-config" CODEX_HOME="$fake/codex-config"
export AI_CORE_UPDATE_CHECK=never GIT_TERMINAL_PROMPT=0 AI_CORE_SLEEP=true
export GIT_AUTHOR_NAME=check GIT_AUTHOR_EMAIL=check@localhost GIT_COMMITTER_NAME=check GIT_COMMITTER_EMAIL=check@localhost
mkdir -p "$HOME" "$AI_CORE_HOME"
trap 'rm -rf "$fake"' EXIT
printf 'claude\tmode\talways\t-\t-\ncodex\tmode\talways\t-\t-\ngemini\tmode\talways\t-\t-\n' > "$fake/modes.tsv"; export TEAM_MODES_FILE="$fake/modes.tsv"

failed=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}
yes_no() { if "$@"; then echo yes; else echo no; fi; }

# The stand-in git. GATE_MATCH is a glob over the words of a call; the first call that matches holds, before
# it runs or, with GATE_AFTER=1, after it ran, until $GATE/go exists, and says that it holds by creating
# $GATE/reached.
real_git="$(command -v git)"
mkdir -p "$fake/shim"
# a gh that is signed in nowhere, so that no command of this test asks GitHub
mkdir -p "$fake/ghbin"; printf '#!/bin/sh\nexit 1\n' > "$fake/ghbin/gh"; chmod +x "$fake/ghbin/gh"; export PATH="$fake/ghbin:$PATH"
cat > "$fake/shim/git" <<EOF
#!/usr/bin/env bash
words="\$*"
hold() { : > "\$GATE/reached"; while [ ! -e "\$GATE/go" ]; do sleep 0.05; done; }
if [ -n "\${SHIM_NO_NETWORK:-}" ]; then
  case "\$words" in *"fetch -q origin"*|*"ls-remote"*) echo "no network in this test" >&2; exit 1 ;; esac
fi
if [ -n "\${GATE:-}" ] && [ ! -e "\$GATE/reached" ]; then
  case "\$words" in
    \$GATE_MATCH)
      if [ "\${GATE_AFTER:-0}" = 1 ]; then "$real_git" "\$@"; rc=\$?; hold; exit \$rc; fi
      hold ;;
  esac
fi
if [ -n "\${VANISH:-}" ] && [ "\$PWD" = "\$VANISH" ]; then
  case "\$words" in *"rev-parse --git-common-dir"*) "$real_git" "\$@"; rc=\$?; rm -rf "\$VANISH"; exit \$rc ;; esac
fi
exec "$real_git" "\$@"
EOF
chmod +x "$fake/shim/git"
# the same hold for the call of jq that follows the validation of a source's rule inputs, just before session-start writes
real_jq="$(command -v jq)"
cat > "$fake/shim/jq" <<EOF
#!/usr/bin/env bash
if [ -n "\${GATE:-}" ] && [ ! -e "\$GATE/reached" ] && [[ "\$*" == *split* ]]; then : > "\$GATE/reached"; while [ ! -e "\$GATE/go" ]; do sleep 0.05; done; fi
exec "$real_jq" "\$@"
EOF
chmod +x "$fake/shim/jq"
gate="$fake/gate"
gate_open() { rm -rf "$gate"; mkdir -p "$gate"; }
gate_wait() { local _; for _ in $(seq 200); do [ -e "$gate/reached" ] && return 0; sleep 0.05; done; return 1; }
gate_release() { : > "$gate/go"; }

dress() {
  git -C "$1" config user.email 'test@example.invalid'
  git -C "$1" config user.name 'test'
  git -C "$1" config commit.gpgsign false
}

origin="$fake/origin.git"
proj="$fake/proj"
app="$proj/app"
trees="$proj/.worktrees/app"
git -c init.defaultBranch=master init -q --bare "$origin"
git -c init.defaultBranch=master init -q "$app"
dress "$app"
echo one > "$app/README.md"
git -C "$app" add -A && git -C "$app" commit -q -m 'the first commit'
git -C "$app" remote add origin "$origin"
git -C "$app" push -q -u origin master
git -C "$app" remote set-head origin -a >/dev/null
mkdir -p "$app/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$app/.ai-core/config.env"

init="$root/bin/init.sh"
finish="$root/bin/finish-issue.sh"
sweep() { (cd "$app" && bash "$finish" --sweep 2>&1); }
open() { git -C "$app" worktree add -q -b "$1" "$trees/$1" origin/master && dress "$trees/$1"; }
# landed <name>: a worktree whose one commit reached master three days ago, so that the sweep may remove it
landed() {
  git -C "$app" fetch -q origin
  open "$1" || return 1
  GIT_COMMITTER_DATE="$(date -d '3 days ago' +%s) +0000" git -C "$trees/$1" commit -q --allow-empty -m "work of $1" \
    && git -C "$trees/$1" push -q origin HEAD:master
}
locked_reason() { git -C "$app" worktree list --porcelain | awk -v want="$1" '/^worktree / { current = substr($0, 10) } current == want && /^locked/ { print substr($0, 8); found = 1 } END { exit found ? 0 : 1 }'; }
lists() { git -C "$app" worktree list --porcelain | grep -qF "$1"; }
tree_files() { (cd "$1" && find . -path ./.git -prune -o -print | sort | tr '\n' ' '); }
# init_held <tree> <glob> [after]: init in the background, held at the call the glob names; waits until it holds
init_held() {
  gate_open
  GATE="$gate" GATE_MATCH="$2" GATE_AFTER="${3:-0}" PATH="$fake/shim:$PATH" bash "$init" "$1" --no-doctor > "$fake/held.log" 2>&1 &
  held_pid=$!
  gate_wait
}
held_end() { gate_release; wait "$held_pid" 2>/dev/null; held_rc=$?; }

echo 'init locks the worktree while it equips it; the sweep names the lock, goes on to the other worktree and removes the first once init is done'
landed issue-1-held && landed issue-2-free
init_held "$trees/issue-1-held" '*worktree lock*' 1
check 'init holds after taking the lock'            yes "$(yes_no gate_wait)"
check 'the lock carries the reason ai-core init'    'ai-core init' "$(locked_reason "$trees/issue-1-held")"
out="$(sweep)"; rc=$?
check 'sweep exits zero'                            0 "$rc"
check 'sweep names the lock of the worktree'        yes "$(yes_no grep -qxF "worktree $trees/issue-1-held: locked by ai-core init, which is equipping it, stays" <<< "$out")"
check 'sweep removes the free worktree'             no "$(yes_no test -d "$trees/issue-2-free")"
check 'sweep reports the free worktree as removed'  yes "$(yes_no grep -qxF "worktree $trees/issue-2-free: landed, removed" <<< "$out")"
check 'the locked worktree stands'                  yes "$(yes_no test -d "$trees/issue-1-held")"
check 'its branch stands'                           yes "$(yes_no git -C "$app" show-ref -q --verify refs/heads/issue-1-held)"
out="$(cd "$app" && bash "$finish" --sweep --dry-run 2>&1)"
check 'the dry run names the lock as well'          yes "$(yes_no grep -qxF "worktree $trees/issue-1-held: locked by ai-core init, which is equipping it, stays" <<< "$out")"
held_end
check 'init exits zero'                             0 "$held_rc"
check 'the lock is lifted when init ends'           no "$(yes_no locked_reason "$trees/issue-1-held")"
out="$(sweep)"
check 'sweep removes it now'                        yes "$(yes_no grep -qxF "worktree $trees/issue-1-held: landed, removed" <<< "$out")"
check 'the worktree is gone'                        no "$(yes_no test -e "$trees/issue-1-held")"

echo 'a worktree locked by somebody else stays locked: init equips it and lifts nothing'
open issue-3-own
git -C "$app" worktree lock --reason 'portable disk' "$trees/issue-3-own"
out="$(PATH="$fake/shim:$PATH" bash "$init" "$trees/issue-3-own" --no-doctor 2>&1)"; rc=$?
check 'init exits zero'                             0 "$rc"
check 'it names the lock it leaves'                 yes "$(yes_no grep -qF 'The worktree is locked by somebody else (portable disk); init leaves that lock as it is.' <<< "$out")"
check 'the lock is still the other one'             'portable disk' "$(locked_reason "$trees/issue-3-own")"
check 'the worktree is equipped'                    yes "$(yes_no test -f "$trees/issue-3-own/.ai-core/config.env")"
git -C "$app" worktree unlock "$trees/issue-3-own"

echo 'a second init is refused while the first holds the tree, and never lifts the first one'"'"'s lock'
open issue-4-twice
init_held "$trees/issue-4-twice" '*worktree lock*' 1
out="$(PATH="$fake/shim:$PATH" bash "$init" "$trees/issue-4-twice" --no-doctor 2>&1)"; rc=$?
check 'the second init fails'                       1 "$rc"
check 'it names the holder and the way out'         yes "$(yes_no grep -qF "error: another ai-core init holds the worktree $trees/issue-4-twice (it is locked: ai-core init)" <<< "$out")"
check 'the first lock is still there'               'ai-core init' "$(locked_reason "$trees/issue-4-twice")"
held_end
check 'the first init still exits zero'             0 "$held_rc"
check 'its lock is lifted at the end'               no "$(yes_no locked_reason "$trees/issue-4-twice")"

echo 'the lock is lifted when init fails after taking it, and when it is terminated'
open issue-5-fails
init_held "$trees/issue-5-fails" '*ls-files --error-unmatch AGENTS.md'
check 'init holds late, after its lock'             'ai-core init' "$(locked_reason "$trees/issue-5-fails")"
out="$(git -C "$app" worktree remove "$trees/issue-5-fails" 2>&1)"; rc=$?
check 'git refuses to remove the locked worktree'   yes "$(yes_no test "$rc" -ne 0 -a -d "$trees/issue-5-fails")"
git -C "$app" worktree remove -f -f "$trees/issue-5-fails"
held_end
check 'init fails when the worktree was removed by force' 1 "$held_rc"
check 'it names the path and says what happened'    yes "$(yes_no grep -qF "error: $trees/issue-5-fails was removed while init ran: nothing more is written there" "$fake/held.log")"
check 'the path is not created again'               no "$(yes_no test -e "$trees/issue-5-fails")"
check 'the removed worktree is not listed any more' no "$(yes_no lists issue-5-fails)"
git -C "$app" branch -D issue-5-fails >/dev/null 2>&1

open issue-6-term
init_held "$trees/issue-6-term" '*ls-files --error-unmatch AGENTS.md'
check 'init holds the lock before the signal'       'ai-core init' "$(locked_reason "$trees/issue-6-term")"
kill -TERM "$held_pid"
held_end
check 'init ends with 143 after a TERM'             143 "$held_rc"
check 'the lock is lifted after the TERM'           no "$(yes_no locked_reason "$trees/issue-6-term")"

echo 'a kill that no trap sees leaves a lock that is named, refuses a second init and can be lifted'
landed issue-7-killed
init_held "$trees/issue-7-killed" '*worktree lock*' 1
kill -KILL "$held_pid"
gate_release; wait "$held_pid" 2>/dev/null
check 'the lock of the dead init stays'             'ai-core init' "$(locked_reason "$trees/issue-7-killed")"
out="$(sweep)"
check 'the sweep names it and leaves the worktree'  yes "$(yes_no grep -qxF "worktree $trees/issue-7-killed: locked by ai-core init, which is equipping it, stays" <<< "$out")"
out="$(bash "$init" "$trees/issue-7-killed" --no-doctor 2>&1)"; rc=$?
check 'a new init is refused and names the unlock'  yes "$(yes_no test "$rc" -eq 1 && grep -qF "git worktree unlock $trees/issue-7-killed" <<< "$out")"
git -C "$app" worktree unlock "$trees/issue-7-killed"
out="$(bash "$init" "$trees/issue-7-killed" --no-doctor 2>&1)"; rc=$?
check 'after the unlock init runs'                  0 "$rc"
out="$(sweep)"
check 'and the sweep removes the worktree'          yes "$(yes_no grep -qxF "worktree $trees/issue-7-killed: landed, removed" <<< "$out")"

echo 'the post-checkout shim starts init, which finds the lock of git lifted and takes its own'
# the shim is the one pre-push --install writes; it starts `ai-core init`, found on the PATH, and the stand-in
# ai-core below writes down the lock of the new worktree for as long as that init runs
git -c init.defaultBranch=master init -q "$fake/hookrepo"; dress "$fake/hookrepo"; git -C "$fake/hookrepo" commit -q --allow-empty -m 'the first commit'
(cd "$fake/hookrepo" && bash "$root/bin/pre-push.sh" --install > "$fake/install.log" 2>&1)
hooks="$fake/hooks"; mkdir -p "$hooks"; cp "$fake/hookrepo/.githooks/post-checkout" "$hooks/post-checkout"
check 'the shim of the harness is installed'        yes "$(yes_no test -x "$hooks/post-checkout")"
mkdir -p "$fake/aiwrap/bin"; ln -s "$root/lib" "$fake/aiwrap/lib"
cat > "$fake/aiwrap/bin/ai-core" <<EOF
#!/usr/bin/env bash
gitdir="\$(git rev-parse --absolute-git-dir)"
bash "$root/bin/ai-core" "\$@" &
running=\$!
while kill -0 "\$running" 2>/dev/null; do
  if [ -e "\$gitdir/locked" ]; then { cat "\$gitdir/locked"; echo; } >> "$fake/lock-samples"; fi
  sleep 0.01
done
wait "\$running"
EOF
chmod +x "$fake/aiwrap/bin/ai-core"
git -C "$app" fetch -q origin
: > "$fake/lock-samples"
out="$(PATH="$fake/aiwrap/bin:$PATH" git -C "$app" -c core.hooksPath="$hooks" worktree add -b issue-8-hooked "$trees/issue-8-hooked" origin/master 2>&1)"; rc=$?
check 'the worktree is added'                       0 "$rc"
check 'the hook equipped the worktree'              yes "$(yes_no test -f "$trees/issue-8-hooked/.ai-core/config.env")"
check 'init found no lock of git'                   no "$(yes_no grep -q 'locked by somebody else' <<< "$out")"
check 'init held the lock, and it was its own'      'ai-core init' "$(sort -u "$fake/lock-samples" | grep . | paste -sd '|' -)"
check 'nothing stays locked'                        no "$(yes_no locked_reason "$trees/issue-8-hooked")"

echo 'init on a path that is gone creates nothing and names it'
gone="$trees/issue-9-gone"
out="$(bash "$init" "$gone" --no-doctor 2>&1)"; rc=$?
check 'init exits nonzero'                          1 "$rc"
check 'it names the path'                           yes "$(yes_no grep -qF "error: $gone does not exist, so there is nothing to initialize there and nothing is created" <<< "$out")"
check 'the path does not exist afterwards'          no "$(yes_no test -e "$gone")"

echo 'init serves one folder: a second one is refused before anything is written, and one --all folder runs as before'
first="$fake/one-folder-a"; second="$fake/one-folder-b"; mkdir -p "$first" "$second"
before="$(tree_files "$first")$(tree_files "$second")"
for shape in "--all $first $second" "$first --all $second" "$second --all $first" "$first $second" "--all $first --all $second"; do
  out="$(bash "$init" $shape --no-doctor 2>&1)"; rc=$?
  check "init $shape exits 1"                        1 "$rc"
  check "init $shape names the second folder"        yes "$(yes_no grep -qE "error: init serves one folder, and '($first|$second)' is a second one; run init once per folder" <<< "$out")"
  check "init $shape writes nothing"                 "$before" "$(tree_files "$first")$(tree_files "$second")"
done
out="$(bash "$init" --all "$first" --no-doctor --dry-run 2>&1)"; rc=$?
check 'init --all with one folder runs'             0 "$rc"
check 'it refuses nothing'                          no "$(yes_no grep -q 'is a second one' <<< "$out")"

echo 'a leftover under .worktrees/ without .git gets no write; a real project folder and a worktree are initialized as before'
orphan="$trees/issue-10-orphan"
mkdir -p "$orphan"; echo keep > "$orphan/notes.txt"
before="$(tree_files "$orphan")"
out="$(bash "$init" "$orphan" --no-doctor 2>&1)"; rc=$?
check 'init exits nonzero'                          1 "$rc"
check 'it says the path is no worktree'             yes "$(yes_no grep -qF "error: $orphan stands under a .worktrees/ folder and holds no .git: it is no worktree, so nothing is written there" <<< "$out")"
check 'nothing is written into the leftover'        "$before" "$(tree_files "$orphan")"
mkdir -p "$fake/plain/one"; git init -q "$fake/plain/one"
out="$(bash "$init" "$fake/plain" --no-doctor 2>&1)"; rc=$?
check 'a project folder is initialized'             0 "$rc"
check 'it got its AGENTS.md'                        yes "$(yes_no test -f "$fake/plain/AGENTS.md")"
open issue-11-real
out="$(bash "$init" "$trees/issue-11-real" --no-doctor 2>&1)"; rc=$?
check 'a registered worktree is initialized'        0 "$rc"
check 'it got its rules'                            yes "$(yes_no test -f "$trees/issue-11-real/.ai-core/rules/rules.md")"
check 'and its lock is lifted'                      no "$(yes_no locked_reason "$trees/issue-11-real")"
git -C "$app" worktree remove -f "$trees/issue-11-real"; git -C "$app" branch -D issue-11-real >/dev/null 2>&1

echo 'init --all skips a worktree that vanishes before its turn, instead of failing the rollout'
printf 'setup-ai-core 0000000\n' > "$app/.ai-core/STAMP"   # init --all walks only what carries the harness
open issue-12-vanishes
out="$(PATH="$fake/shim:$PATH" VANISH="$trees/issue-12-vanishes" bash "$init" --all "$proj" --no-doctor 2>&1)"; rc=$?
check 'the rollout exits zero'                      0 "$rc"
check 'it says that the worktree was skipped'       yes "$(yes_no grep -qF "==> .worktrees/app/issue-12-vanishes was removed while init --all ran: skipped, nothing was created there" <<< "$out")"
check 'it reports no failure'                       no "$(yes_no grep -q 'failed:' <<< "$out")"
check 'the path is not created again'               no "$(yes_no test -e "$trees/issue-12-vanishes")"
git -C "$app" worktree prune; git -C "$app" branch -D issue-12-vanishes >/dev/null 2>&1

echo 'session-start writes nothing into a source worktree that was removed under it, and says why'
src="$fake/src/shop-ai-core"
mkdir -p "$fake/src"
git -c init.defaultBranch=master init -q "$src"; dress "$src"
git -C "$src" remote add origin https://github.com/example-org/shop-ai-core.git
cp -R "$root/skeleton/." "$src/"
git -C "$src" add . && git -C "$src" commit -q -m 'the source'
git -C "$src" worktree add -q -b issue-13-source "$fake/src/.worktrees/shop-ai-core/issue-13-source"
source_tree="$fake/src/.worktrees/shop-ai-core/issue-13-source"
gate_open
(cd "$source_tree" && SHIM_NO_NETWORK=1 GATE="$gate" PATH="$fake/shim:$PATH" bash "$root/bin/session-start.sh" > "$fake/start.log" 2>&1; echo $? > "$fake/start.rc") &
start_pid=$!
check 'session-start holds before its first write'  yes "$(yes_no gate_wait)"
git -C "$src" worktree remove -f "$source_tree"
gate_release; wait "$start_pid" 2>/dev/null
check 'the path is not created again'               no "$(yes_no test -e "$source_tree")"
check 'it says that it wrote nothing there'         yes "$(yes_no grep -qF "AGENTS.md was not written: $source_tree is removed or is no worktree, so nothing is written there" "$fake/start.log")"

echo 'init lifts its lock also when it was given a link to the worktree, or a folder below its top (planted: git lists the resolved top)'
ln -s "$proj" "$fake/proj-link"
open issue-14-linked
out="$(bash "$init" "$fake/proj-link/.worktrees/app/issue-14-linked" --no-doctor 2>&1)"; rc=$?
check 'init through a link exits zero'              0 "$rc"
check 'its lock is lifted'                          no "$(yes_no locked_reason "$trees/issue-14-linked")"
open issue-15-below; mkdir -p "$trees/issue-15-below/src"
init_held "$trees/issue-15-below/src" '*worktree lock*' 1
check 'init in a folder below the top locks the worktree' 'ai-core init' "$(locked_reason "$trees/issue-15-below")"
held_end
check 'it exits zero'                               0 "$held_rc"
check 'and lifts the lock'                          no "$(yes_no locked_reason "$trees/issue-15-below")"

echo 'the sweep names a worktree whose branch went after it listed the worktrees, and goes on (planted: another finish removes it meanwhile)'
open issue-16-raced
landed issue-17-beside
gate_open
(cd "$app" && GATE="$gate" GATE_MATCH='*worktree list --porcelain*' GATE_AFTER=1 PATH="$fake/shim:$PATH" bash "$finish" --sweep > "$fake/sweep.log" 2>&1; echo $? > "$fake/sweep.rc") &
sweep_pid=$!
check 'the sweep holds after it listed the worktrees' yes "$(yes_no gate_wait)"
git -C "$app" worktree remove -f "$trees/issue-16-raced"; git -C "$app" branch -q -D issue-16-raced
gate_release; wait "$sweep_pid"
check 'sweep exits zero'                            0 "$(cat "$fake/sweep.rc")"
check 'it names the worktree whose branch is gone'  yes "$(yes_no grep -qxF "worktree $trees/issue-16-raced: could not be measured against origin/master - the branch issue-16-raced points at no commit, stays" "$fake/sweep.log")"
check 'it removes the landed one beside it'         yes "$(yes_no grep -qxF "worktree $trees/issue-17-beside: landed, removed" "$fake/sweep.log")"

[ "$failed" -eq 0 ] && echo "all passed"
exit "$failed"
