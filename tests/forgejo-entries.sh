#!/usr/bin/env bash
# The shared entries of the harness with TRACKER=forgejo: a Forgejo session loads no board code and no Bash
# tracker, and the same entries still load them where the tracker has a board. Run by tests/sections/16-forgejo.sh.
#
# The probe is a copy of the harness whose lib/board.sh and lib/tracker.sh only write a marker and fail. A Forgejo
# run must leave no marker; the same run with TRACKER=github must leave one, which is what shows the probe can go red.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

COPY="$WORK/harness"
MARKS="$WORK/marks"
mkdir -p "$COPY" "$MARKS"
tar -C "$ROOT" --exclude=node_modules --exclude=.git -cf - bin lib templates rules skills VERSION | tar -C "$COPY" -xf -
for loaded in board tracker; do
  printf '#!/usr/bin/env bash\ntouch "%s/%s"\nexit 1\n' "$MARKS" "$loaded" > "$COPY/lib/$loaded.sh"
done
loaded_code() { [ -e "$MARKS/board" ] || [ -e "$MARKS/tracker" ]; }
clear_marks() { rm -f "$MARKS/board" "$MARKS/tracker"; }

# A node that answers the commands the entries ask of the Forgejo tracker, and records what it was asked
SHIM="$WORK/shim"; mkdir -p "$SHIM"
cat > "$SHIM/node" <<EOS
#!/bin/sh
echo "\$*" >> "$WORK/node-calls.log"
case "\$2" in
  --version) echo "ai-core forgejo tracker 9.9.9" ;;
  issue-thread) printf '%s\n' '{"number":5,"title":"Example work","createdAt":"2026-01-01T00:00:00Z","state":"open","labels":["status/implementing"],"body":"Asked for by @someone on 2026-01-01 in the chat.","comments":[]}' ;;
  issue-mine) echo "example-org/shop#5 is assigned to @tester." ;;
  issue-comment) echo "https://forge.example.test/example-org/shop/issues/5#issuecomment-1" ;;
  issue-package) echo "example-org/shop#5 carries package/shop#5" ;;
  doctor) echo "ok: Forgejo at http://127.0.0.1:1 knows the token as tester" ;;
esac
EOS
chmod +x "$SHIM/node"
printf '#!/bin/sh\nif [ "$1" = "--version" ]; then echo "gh version 0.0.0"; else exit 1; fi\n' > "$SHIM/gh"; chmod +x "$SHIM/gh"

# A checkout on the branch of an issue, of the tracker given
make_checkout() {  # make_checkout <directory> <tracker>
  git init -q -b master "$1"
  git -C "$1" remote add origin https://forge.example.test/example-org/shop.git
  mkdir -p "$1/.ai-core/rules"
  printf '%s\n' '# rules' > "$1/.ai-core/rules/rules.md"
  printf 'TRACKER=%s\nFORGEJO_URL=http://127.0.0.1:1\nFORGEJO_TOKEN_COMMAND="printf token"\nUPDATE_CHECK="never"\n' "$2" > "$1/.ai-core/config.env"
  printf '/.ai-core/\n' >> "$1/.git/info/exclude"
  git -C "$1" commit -q --allow-empty -m 'Start'
  git -C "$1" checkout -q -b issue-5-example-work
}

section "session-start in the worktree of an issue: the thread and the assignment come from the Forgejo tracker, and no board code is loaded"
make_checkout "$WORK/forgejo-session" forgejo
clear_marks; : > "$WORK/node-calls.log"
(cd "$WORK/forgejo-session" && PATH="$SHIM:$PATH" bash "$COPY/bin/session-start.sh" --json > "$WORK/forgejo-session.json" 2> "$WORK/forgejo-session.err") || fail "session-start.sh on Forgejo (see $WORK/forgejo-session.err)"
loaded_code && fail "a Forgejo session start loaded board code: $(ls "$MARKS" | tr '\n' ' ')"
jq -e '.issue == 5 and .assigned == true and .thread.title == "Example work" and .refused == false' "$WORK/forgejo-session.json" > /dev/null || fail "session-start on Forgejo did not read the thread and the assignment of issue 5: $(cat "$WORK/forgejo-session.json")"
grep -q 'issue-thread 5 --json' "$WORK/node-calls.log" && grep -q 'issue-mine 5' "$WORK/node-calls.log" || fail "session-start did not ask the Forgejo tracker for the thread and the assignment: $(cat "$WORK/node-calls.log")"
echo "  a Forgejo worktree session reads issue 5 through the tracker in Node and loads neither board.sh nor tracker.sh"

make_checkout "$WORK/github-session" github
clear_marks
(cd "$WORK/github-session" && PATH="$SHIM:$PATH" bash "$COPY/bin/session-start.sh" --json > /dev/null 2>&1) || true
loaded_code || fail "planted: the same session start on GitHub did not load board code, so the probe cannot see it"
echo "  planted: with TRACKER=github the same start loads the board code, so the probe goes red when it should"

section "solution-path, team-modes-check and team-modes-install need no tracker; solution-path posts through the Forgejo tracker"
cat > "$WORK/path.md" <<'EOS'
## Where a person meets this
x
## What they see today
x
## What the system does behind it
x
## The decision
x
## Options
x
## Recommendation
x
## Code facts
x
## Reuse manifest
x
EOS
clear_marks; : > "$WORK/node-calls.log"
(cd "$WORK/forgejo-session" && PATH="$SHIM:$PATH" bash "$COPY/bin/solution-path.sh" 5 "$WORK/path.md" > "$WORK/forgejo-path.log" 2>&1) || fail "solution-path.sh on Forgejo (see $WORK/forgejo-path.log)"
loaded_code && fail "solution-path.sh on Forgejo loaded board code"
grep -q "issue-comment 5 --body-file $WORK/path.md" "$WORK/node-calls.log" || fail "solution-path.sh did not post through the Forgejo tracker: $(cat "$WORK/node-calls.log")"
grep -q 'issuecomment-1' "$WORK/forgejo-path.log" || fail "solution-path.sh did not print the address of the comment"
clear_marks
(cd "$WORK/github-session" && PATH="$SHIM:$PATH" bash "$COPY/bin/solution-path.sh" 5 "$WORK/path.md" --check > /dev/null 2>&1) || true
loaded_code || fail "planted: solution-path.sh on GitHub did not load board code"
for tracker in forgejo github; do
  clear_marks
  (cd "$WORK/$tracker-session" && bash "$COPY/bin/team-modes-check.sh" --quiet > "$WORK/modes-$tracker.log" 2>&1) || fail "team-modes-check.sh with TRACKER=$tracker (see $WORK/modes-$tracker.log)"
  (cd "$WORK/$tracker-session" && bash "$COPY/bin/team-modes-install.sh" --dry-run > "$WORK/modes-install-$tracker.log" 2>&1) || fail "team-modes-install.sh --dry-run with TRACKER=$tracker (see $WORK/modes-install-$tracker.log)"
  loaded_code && fail "the team modes scripts loaded board code with TRACKER=$tracker"
done
echo "  solution-path posts through ai-core on Forgejo and loads the board code on GitHub; the team modes scripts load none for either"

section "status --tokens with TRACKER=forgejo goes to the Forgejo tracker, which holds the option, and loads no board code; on GitHub the board code is loaded"
clear_marks; : > "$WORK/node-calls.log"
(cd "$WORK/forgejo-session" && PATH="$SHIM:$PATH" bash "$COPY/bin/ai-core" status --tokens > "$WORK/forgejo-status.log" 2>&1) || fail "ai-core status --tokens with TRACKER=forgejo (see $WORK/forgejo-status.log)"
grep -q 'cli.mts status --tokens$' "$WORK/node-calls.log" || fail "ai-core status --tokens did not reach the Forgejo tracker with its option: $(cat "$WORK/node-calls.log")"
loaded_code && fail "ai-core status --tokens on Forgejo loaded board code"
clear_marks
(cd "$WORK/github-session" && PATH="$SHIM:$PATH" bash "$COPY/bin/ai-core" status --tokens > /dev/null 2>&1) || true
loaded_code || fail "planted: ai-core status --tokens on GitHub did not load board code, so the probe cannot see it"
echo "  status --tokens reaches the Forgejo tracker with its option and no board code; with TRACKER=github it loads the board code"

section "issue-package with TRACKER=forgejo runs in Node and loads no board code; on GitHub the board code is loaded"
clear_marks; : > "$WORK/node-calls.log"
(cd "$WORK/forgejo-session" && PATH="$SHIM:$PATH" bash "$COPY/bin/ai-core" issue-package example-org/shop 5 --member example-org/shop#5 > "$WORK/forgejo-package.log" 2>&1) || fail "ai-core issue-package with TRACKER=forgejo (see $WORK/forgejo-package.log)"
grep -q 'cli.mts issue-package example-org/shop 5 --member example-org/shop#5$' "$WORK/node-calls.log" || fail "ai-core issue-package did not reach the Forgejo tracker with its arguments: $(cat "$WORK/node-calls.log")"
loaded_code && fail "ai-core issue-package on Forgejo loaded board code"
clear_marks
(cd "$WORK/github-session" && PATH="$SHIM:$PATH" bash "$COPY/bin/ai-core" issue-package example-org/shop 5 --member example-org/shop#5 > /dev/null 2>&1) || true
loaded_code || fail "planted: ai-core issue-package on GitHub did not load board code, so the probe cannot see it"
echo "  issue-package reaches the Forgejo tracker with its arguments and no board code; with TRACKER=github it runs the Bash script, which loads the board code"

section "issue-list with TRACKER=forgejo runs in Node and loads no board code; on GitHub the board code is loaded"
clear_marks; : > "$WORK/node-calls.log"
(cd "$WORK/forgejo-session" && PATH="$SHIM:$PATH" bash "$COPY/bin/ai-core" issue-list --state all --search gate > "$WORK/forgejo-list.log" 2>&1) || fail "ai-core issue-list with TRACKER=forgejo (see $WORK/forgejo-list.log)"
grep -q 'cli.mts issue-list --state all --search gate$' "$WORK/node-calls.log" || fail "ai-core issue-list did not reach the Forgejo tracker with its arguments: $(cat "$WORK/node-calls.log")"
loaded_code && fail "ai-core issue-list on Forgejo loaded board code"
clear_marks
(cd "$WORK/github-session" && PATH="$SHIM:$PATH" bash "$COPY/bin/ai-core" issue-list --state all --search gate > /dev/null 2>&1) || true
loaded_code || fail "planted: ai-core issue-list on GitHub did not load board code, so the probe cannot see it"
echo "  issue-list reaches the Forgejo tracker with its arguments and no board code; with TRACKER=github it runs the Bash script, which loads the board code"

section "finish-issue --sweep on Forgejo: ai-core runs the sweep of bin/finish-issue.sh, which loads no board code; finish-issue with a number still goes to Node"
SWEEP="$WORK/forgejo-sweep"
OLD_TREE="$WORK/.worktrees/forgejo-sweep/issue-7-old"
git init -q --bare -b master "$SWEEP-origin.git"
make_checkout "$SWEEP" forgejo
git -C "$SWEEP" checkout -q master
git -C "$SWEEP" remote set-url origin "$SWEEP-origin.git"
git -C "$SWEEP" push -q -u origin master 2>/dev/null; git -C "$SWEEP" remote set-head origin -a > /dev/null
long_ago="$(date -d '3 days ago' '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -v-3d '+%Y-%m-%dT%H:%M:%S')"
git -C "$SWEEP" worktree add -q -b issue-7-old "$OLD_TREE" origin/master 2>/dev/null
echo old > "$OLD_TREE/README.md"; git -C "$OLD_TREE" add README.md
GIT_AUTHOR_DATE="$long_ago" GIT_COMMITTER_DATE="$long_ago" git -C "$OLD_TREE" commit -q -m 'Land the old work #7'
git -C "$OLD_TREE" push -q origin HEAD:master 2>/dev/null; git -C "$SWEEP" pull -q --ff-only origin master 2>/dev/null
sweep_entry() { ( cd "$SWEEP" && PATH="$SHIM:$PATH" bash "$COPY/bin/ai-core" finish-issue "$@" 2>&1 ); }
clear_marks; : > "$WORK/node-calls.log"
out="$(sweep_entry --sweep --dry-run)" || fail "ai-core finish-issue --sweep --dry-run on Forgejo failed: $out"
grep -q 'issue-7-old: landed, would be removed' <<< "$out" || fail "the dry run on Forgejo did not name the landed worktree: $out"
out="$(sweep_entry --dry-run --sweep)" || fail "ai-core finish-issue --dry-run --sweep on Forgejo failed: $out"
grep -q 'issue-7-old: landed, would be removed' <<< "$out" || fail "with --dry-run ahead of --sweep, ai-core on Forgejo did not run the sweep: $out"
out="$(sweep_entry --sweep)" || fail "ai-core finish-issue --sweep on Forgejo failed: $out"
[ -d "$OLD_TREE" ] && fail "the sweep on Forgejo left the worktree whose work landed three days ago: $out"
loaded_code && fail "the sweep on Forgejo loaded board code: $(ls "$MARKS" | tr '\n' ' ')"
[ -s "$WORK/node-calls.log" ] && fail "the sweep on Forgejo asked the tracker in Node: $(cat "$WORK/node-calls.log")"
echo "  ai-core finish-issue --sweep on Forgejo removes the worktree that landed three days ago through bin/finish-issue.sh, and loads no board.sh, no tracker.sh and no Node"
: > "$WORK/node-calls.log"
sweep_entry 5 > /dev/null || true
grep -q 'finish-issue 5' "$WORK/node-calls.log" || fail "ai-core finish-issue 5 on Forgejo did not go to the tracker in Node: $(cat "$WORK/node-calls.log")"
echo "  ai-core finish-issue 5 on Forgejo still runs in Node"

section "init --all runs the sweep on Forgejo as on GitHub"
# in the copy, finish-issue only says that it ran
printf '#!/usr/bin/env bash\necho "$*" >> "%s/finish-issue"\n' "$MARKS" > "$COPY/bin/finish-issue.sh"
for tracker in forgejo github; do
  F="$WORK/sweep-$tracker"; O="$WORK/sweep-$tracker-origin.git"; A="$F/app"
  mkdir -p "$F/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$F/.ai-core/config.env"
  git init -q --bare -b master "$O"; git init -q -b master "$A"
  mkdir -p "$A/.ai-core"; printf 'TRACKER=%s\nUPDATE_CHECK="never"\n' "$tracker" > "$A/.ai-core/config.env"; printf '/.ai-core/\n' >> "$A/.git/info/exclude"; carry_harness "$A"
  echo one > "$A/README.md"; git -C "$A" add README.md; git -C "$A" commit -q -m 'Start #1'
  git -C "$A" remote add origin "$O"; git -C "$A" push -q -u origin master 2>/dev/null; git -C "$A" remote set-head origin -a >/dev/null
  git -C "$A" worktree add -q -b issue-5-old "$F/.worktrees/app/issue-5-old" origin/master 2>/dev/null
  rm -f "$MARKS/finish-issue"
  bash "$COPY/bin/init.sh" --all "$F" --no-doctor > "$F.log" 2>&1 || fail "init --all with TRACKER=$tracker failed (see $F.log)"
  [ -e "$MARKS/finish-issue" ] || fail "init --all did not run finish-issue --sweep with TRACKER=$tracker (see $F.log)"
done
echo "  the sweep runs for the repository on Forgejo and on GitHub"

section "doctor asks the Forgejo tracker whether it can run and what it finds: not configured, unreachable, healthy, and a Node that cannot run it"
mkdir -p "$WORK/doctor-home" "$WORK/shim-gh" "$WORK/shim-broken"
cp "$SHIM/gh" "$WORK/shim-gh/gh"
printf '#!/bin/sh\n[ "$1" != -v ] || { echo v24.0.0; exit 0; }\necho "SyntaxError: type stripping is not enabled" >&2\nexit 1\n' > "$WORK/shim-broken/node"; chmod +x "$WORK/shim-broken/node"
cp "$SHIM/gh" "$WORK/shim-broken/gh"
doctor_log() {  # doctor_log <name> <PATH> <directory>: the lines of doctor.sh, the exit status is the machine's and not judged
  (cd "$3" && HOME="$WORK/doctor-home" PATH="$2" bash "$COPY/bin/doctor.sh" --no-install > "$WORK/doctor-$1.log" 2>&1) || true
}
make_checkout "$WORK/doctor-bare" forgejo
sed -i.bak '/^FORGEJO_/d' "$WORK/doctor-bare/.ai-core/config.env"; rm -f "$WORK/doctor-bare/.ai-core/config.env.bak"
doctor_log unconfigured "$WORK/shim-gh:$PATH" "$WORK/doctor-bare"
grep -aEq '^  tracker +present +ai-core forgejo tracker [0-9]+\.[0-9]+\.[0-9]+$' "$WORK/doctor-unconfigured.log" || fail "doctor did not run the Forgejo tracker to ask for its version: $(grep -a tracker "$WORK/doctor-unconfigured.log")"
grep -aEq '^  tracker +problem +the Forgejo tracker is not configured: FORGEJO_URL and FORGEJO_TOKEN_COMMAND are not set' "$WORK/doctor-unconfigured.log" || fail "doctor did not report the Forgejo tracker as not configured: $(grep -a tracker "$WORK/doctor-unconfigured.log")"
grep -aq 'MISSING .*TRACKER names no folder' "$WORK/doctor-unconfigured.log" && fail "doctor still looks for a Bash tracker of Forgejo"
doctor_log unreachable "$WORK/shim-gh:$PATH" "$WORK/forgejo-session"
grep -aEq '^  tracker +problem +Forgejo cannot be reached' "$WORK/doctor-unreachable.log" || fail "doctor did not report the unreachable Forgejo: $(grep -a tracker "$WORK/doctor-unreachable.log")"
doctor_log healthy "$SHIM:$PATH" "$WORK/forgejo-session"
grep -aEq '^  tracker +ok +Forgejo at http://127.0.0.1:1 knows the token as tester$' "$WORK/doctor-healthy.log" || fail "doctor did not report a healthy Forgejo tracker: $(grep -a tracker "$WORK/doctor-healthy.log")"
doctor_log broken "$WORK/shim-broken:$PATH" "$WORK/forgejo-session"
grep -aEq '^  tracker +cannot run +node .* does not run lib/forgejo/tracker/cli.mts without a flag: SyntaxError' "$WORK/doctor-broken.log" || fail "doctor did not report a Node that cannot run the tracker: $(grep -a tracker "$WORK/doctor-broken.log")"
grep -aq '^doctor: [0-9]* problem' "$WORK/doctor-broken.log" || fail "doctor did not count the problem of the Node that cannot run the tracker"
echo "  not configured, unreachable and a Node that cannot run it are problems; a healthy tracker is one ok line; the capability is asked of the tracker, never read from a version number"

section "a config.env that cannot be read stops every entry that reads it: no tracker is chosen by default, node and gh are asked nothing, the update check does not run"
. "$ROOT/tests/unreadable.sh"
SHIM_GH="$WORK/shim-gh-log"; GH_LOG="$WORK/gh-calls.log"; mkdir -p "$SHIM_GH"
printf '#!/bin/sh\necho "$*" >> "%s"\nexit 1\n' "$GH_LOG" > "$SHIM_GH/gh"; chmod +x "$SHIM_GH/gh"
OLD="$WORK/old-harness"; old_reader_copy "$ROOT" "$OLD" || fail "no copy of the harness with the old reader"
for harness in "$COPY" "$OLD"; do printf '#!/usr/bin/env bash\ntouch "%s/update-ran"\nexit 0\n' "$MARKS" > "$harness/bin/update.sh"; done
make_checkout "$WORK/unreadable-forgejo" forgejo
UNREADABLE="$WORK/unreadable-forgejo/.ai-core/config.env"
make_unreadable "$UNREADABLE" || fail "the config.env of the checkout cannot be made unreadable"
ENTRY_ENV=()
run_entry() {  # run_entry <harness> <script of its bin/> [argument...]: the entry in the checkout whose config.env cannot be read, the shims for node and gh first
  ( cd "$WORK/unreadable-forgejo" && env -u AI_CORE_UPDATE_CHECK -u TRACKER -u FORGE ${ENTRY_ENV[@]+"${ENTRY_ENV[@]}"} PATH="$SHIM_GH:$SHIM:$PATH" bash "$1/bin/$2" "${@:3}" 2>&1 )
}
stopped() {  # stopped <file as the entry names it> <harness> <script> [argument...]: yes where the entry fails, names the file, and asked node, gh and the update check nothing
  local named="$1" out rc=0
  shift
  : > "$WORK/node-calls.log"; : > "$GH_LOG"; rm -f "$MARKS/update-ran"
  out="$(run_entry "$@")" || rc=$?
  if [ "$rc" -ne 0 ] && grep -qF "$named exists but cannot be read" <<< "$out" && [ ! -s "$WORK/node-calls.log" ] && [ ! -s "$GH_LOG" ] && [ ! -e "$MARKS/update-ran" ]; then echo yes
  else echo "no (status $rc; node asked [$(tr '\n' '|' < "$WORK/node-calls.log")] gh asked [$(tr '\n' '|' < "$GH_LOG")] update check $([ -e "$MARKS/update-ran" ] && echo ran || echo not run); said: $(tr '\n' '|' <<< "$out" | cut -c1-300))"; fi
}
[ "$(stopped "$UNREADABLE" "$COPY" ai-core issue-mine 5)" = yes ] || fail "ai-core issue-mine went on, or did not name the file, where config.env cannot be read: $(stopped "$UNREADABLE" "$COPY" ai-core issue-mine 5)"
[ "$(stopped "$UNREADABLE" "$OLD" ai-core issue-mine 5)" != yes ] && [ -s "$GH_LOG" ] || fail "planted: with the old reader ai-core did not run the GitHub command for the default tracker, so the check cannot go red"
echo "  dispatch: ai-core stops before it picks a tracker; planted: with the old reader it takes the default GitHub tracker and runs the Bash command"
forgejo_exec() {  # forgejo_exec <harness>: forgejo_tracker_exec as doctor runs it, in a subshell
  ( cd "$WORK/unreadable-forgejo" && PATH="$SHIM_GH:$SHIM:$PATH" bash -c '. "$1/lib/common.sh"; ( forgejo_tracker_exec issue-new ) 2>&1' _ "$1" )
}
: > "$WORK/node-calls.log"; out="$(forgejo_exec "$COPY")" && fail "the Forgejo dispatch went on where config.env cannot be read"
grep -qF "$UNREADABLE exists but cannot be read" <<< "$out" && [ ! -s "$WORK/node-calls.log" ] || fail "the Forgejo dispatch did not name the file, or started node: $out"
: > "$WORK/node-calls.log"; forgejo_exec "$OLD" > /dev/null 2>&1 || true
[ -s "$WORK/node-calls.log" ] || fail "planted: with the old reader the Forgejo dispatch did not start node on empty settings, so the check cannot go red"
echo "  Forgejo dispatch: no URL, token command or tracker is taken as empty and handed to node; planted: with the old reader node starts on empty settings"
ENTRY_ENV=(TRACKER=forgejo FORGE=forgejo FORGEJO_URL=http://127.0.0.1:1 "FORGEJO_TOKEN_COMMAND=printf token")
[ "$(stopped .ai-core/config.env "$COPY" session-start.sh)" = yes ] || fail "session-start went on, or did not name the file, where config.env cannot be read: $(stopped .ai-core/config.env "$COPY" session-start.sh)"
[ "$(stopped .ai-core/config.env "$OLD" session-start.sh)" != yes ] && [ -e "$MARKS/update-ran" ] || fail "planted: with the old reader session-start did not run the update check on the default, so the check cannot go red"
ENTRY_ENV=()
echo "  session-start: it stops before the update check, which the default of an unread UPDATE_CHECK would run; planted: with the old reader the check runs"
chmod 600 "$UNREADABLE"
