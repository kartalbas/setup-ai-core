#!/usr/bin/env bash
# The push gate brings the published copy of a neighbour to its origin's newest commit before the check reads it,
# and keeps it there while the check runs; a gate or init that must move a copy waits for the checks that read it
# as long as the checks take. One section of the suite, run by tests/check.sh with the others
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

command -v flock >/dev/null 2>&1 || fail "flock (util-linux) is not installed, and the copies of the neighbours are locked with it"
export PATH="$ROOT/bin:$PATH" PRE_PUSH_LOAD_LIMIT=0
F="$WORK/nb"; CHECK_LOG="$WORK/nb-check.log"; CHECK_IDS="$WORK/nb-check-ids.log"; export CHECK_LOG CHECK_IDS; : > "$CHECK_LOG"; : > "$CHECK_IDS"
mkdir -p "$F/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$F/.ai-core/config.env"
git_as() { git -c user.email=check@localhost -c user.name=check "$@"; }

# neighbours: cat, dog and Zed publish a marker, eel has no origin. Zed sorts before cat in the C order and after dog in
# the order of a locale such as en_US, which is what the glob of the links follows.
for r in cat dog Zed; do
  git init -q --bare -b master "$WORK/nb-$r.git"
  git clone -q "$WORK/nb-$r.git" "$F/$r" 2>/dev/null
  echo one > "$F/$r/marker"; git -C "$F/$r" add marker; git_as -C "$F/$r" commit -q -m one; git -C "$F/$r" push -q origin master
  git clone -q "$WORK/nb-$r.git" "$WORK/nb-$r-pusher" 2>/dev/null
done
git init -q -b master "$F/eel"; git_as -C "$F/eel" commit -q --allow-empty -m one
carry_harness "$F/cat" "$F/dog" "$F/Zed" "$F/eel"
land() {  # land <neighbour> <marker>: another session lands a commit in the neighbour's origin
  echo "$2" > "$WORK/nb-$1-pusher/marker"; git_as -C "$WORK/nb-$1-pusher" commit -q -am "$2"; git -C "$WORK/nb-$1-pusher" push -q origin master
}
# the repository under test: its check reads both published copies through .., as a contract test does
git init -q --bare -b master "$WORK/nb-app.git"
git clone -q "$WORK/nb-app.git" "$F/app" 2>/dev/null
mkdir -p "$F/app/scripts" "$F/app/.githooks" "$F/app/.ai-core"
printf '#!/usr/bin/env bash\nexec ai-core pre-push "$@"\n' > "$F/app/.githooks/pre-push"; chmod +x "$F/app/.githooks/pre-push"
cat > "$F/app/scripts/check.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
echo "$(cat ../cat/marker) $(cat ../dog/marker)" >> "$CHECK_LOG"
echo "$(git -C ../cat rev-parse HEAD) $(git -C ../dog rev-parse HEAD)" >> "$CHECK_IDS"
if [ -n "${CHECK_DAEMON:-}" ]; then ( nohup sleep 120 >/dev/null 2>&1 & echo $! >> "$CHECK_DAEMON" ); fi
if [ -n "${CHECK_HOLD:-}" ]; then
  : > "$CHECK_HOLD.started"
  while [ ! -e "$CHECK_HOLD" ]; do sleep 0.1; done
  echo "$(cat ../cat/marker) $(cat ../dog/marker) again" >> "$CHECK_LOG"
  echo "$(git -C ../cat rev-parse HEAD) $(git -C ../dog rev-parse HEAD) again" >> "$CHECK_IDS"
fi
EOF
chmod +x "$F/app/scripts/check.sh"
printf 'UPDATE_CHECK="never"\nNEIGHBOUR_LOCK_WAIT_SECONDS="2"\nPRE_PUSH_LOAD_LIMIT="0"\n' > "$F/app/.ai-core/config.env"
git -C "$F/app" config user.email check@localhost; git -C "$F/app" config user.name check
git -C "$F/app" add scripts .githooks; git -C "$F/app" commit -q -m "start (#1)"; git -C "$F/app" push -q origin master
T1="$F/.worktrees/app/issue-2-y"; T2="$F/.worktrees/app/issue-3-z"
git -C "$F/app" worktree add -q -b issue-2-y "$T1"; git -C "$F/app" worktree add -q -b issue-3-z "$T2"
bash "$ROOT/bin/init.sh" "$T1" --no-doctor > "$F-init1.log" 2>&1 || fail "init in the first worktree failed: $(tail -5 "$F-init1.log")"
bash "$ROOT/bin/init.sh" "$T2" --no-doctor > "$F-init2.log" 2>&1 || fail "init in the second worktree failed: $(tail -5 "$F-init2.log")"
CAT="$F/.ai-core/neighbours/cat/origin-master"; DOG="$F/.ai-core/neighbours/dog/origin-master"
[ "$(readlink "$F/.worktrees/app/cat")" = ../../.ai-core/neighbours/cat/origin-master ] || fail "init did not link cat to its published copy: $(readlink "$F/.worktrees/app/cat" 2>&1)"
[ "$(readlink "$F/.worktrees/app/eel")" = ../../eel ] || fail "init did not link eel, which has no origin, to its checkout"
work_on() {  # work_on <worktree> <name>: one commit that names its issue
  echo "$2" > "$1/work-$2"; git -C "$1" add "work-$2"; git -C "$1" commit -q -m "work $2 (#2)"
}
push_gate() {  # push_gate <worktree> <branch> <log>: a real push, so git runs the real hook
  git -C "$1" push origin "HEAD:refs/heads/$2" > "$3" 2>&1
}
last_check() { tail -1 "$CHECK_LOG"; }

# A wait of twenty minutes runs on a clock of its own: the stand-in date and sleep of tests/load-stubs.sh, which only
# the command named after `clocked` finds first on its PATH. The clock moves only when a sleep moves it, and a script
# that on_clock plants runs in the first sleep that ends at or after its moment.
STUBS="$WORK/nb-stubs"; STATE="$WORK/nb-clock"; REAL_SLEEP="$(command -v sleep)"
. "$ROOT/tests/load-stubs.sh"; make_load_stubs "$STUBS"
clock_reset() { plan_load "$STATE" 0.1; rm -f "$STATE"/fired-*; }
clocked() { PATH="$STUBS:$PATH" PROBE_STATE="$STATE" "$@"; }
slept() { if [ -f "$STATE/sleeps" ]; then awk '{ s += $1 } END { print s + 0 }' "$STATE/sleeps"; else echo 0; fi; }
on_clock() {  # on_clock <clock> <script text>
  cat >> "$STATE/on-every-sleep" <<ON
if [ "\$1" -ge $1 ] && [ ! -e "$STATE/fired-$1" ]; then : > "$STATE/fired-$1"; $2; fi
ON
}
lock_of() { printf '%s/.ai-core/neighbours/%s/.copy.lock\n' "$F" "$1"; }
all_free() {  # all_free <neighbour>...: none of these copies is read or moved by anybody
  local n; for n in "$@"; do flock -x -n "$(lock_of "$n")" true || return 1; done
}
set_wait() {  # set_wait <seconds>: the least wait of every worktree's gate and init
  local t; for t in "$F/app" "$T1" "$T2" "${T3:-$T1}"; do
    [ -d "$t/.ai-core" ] || continue
    printf 'UPDATE_CHECK="never"\nNEIGHBOUR_LOCK_WAIT_SECONDS="%s"\nPRE_PUSH_LOAD_LIMIT="0"\n' "$1" > "$t/.ai-core/config.env"
  done
}
hold_lock() {  # hold_lock <neighbour> <release file> -s|-x: a process that holds the lock of the copy until the release file exists
  local other=-s; [ "$3" = -x ] || other=-x
  rm -f "$2"
  flock "$3" "$(lock_of "$1")" -c "while [ ! -e '$2' ]; do '$REAL_SLEEP' 0.1; done" &
  READER=$!
  for _ in $(seq 1 100); do flock "$other" -n "$(lock_of "$1")" true || return 0; "$REAL_SLEEP" 0.05; done
  fail "the holder of the lock of $1 never took it"
}
reader() { hold_lock "$1" "$2" -s; }  # reader <neighbour> <release file>: a process that reads the copy, holding its lock shared
mover() { hold_lock "$1" "$2" -x; }   # mover <neighbour> <release file>: a process that moves the copy, holding its lock exclusive
hold_gate() {  # hold_gate <worktree> <branch> <hold file> <log>: a real gate whose check reads both copies and then waits for the hold file
  rm -f "$3" "$3.started"
  CHECK_HOLD="$3" git -C "$1" push origin "HEAD:refs/heads/$2" > "$4" 2>&1 &
  HOLDER=$!
  for _ in $(seq 1 600); do [ -e "$3.started" ] && break; sleep 0.1; done
  [ -e "$3.started" ] || fail "the first gate never started its check (see $4)"
}
release_script() {  # release_script <file> <pid>: the script text that ends a gate or a reader waiting for that file, and waits until it is gone
  printf ": > '%s'; for _ in \$(seq 1 600); do kill -0 %s 2>/dev/null || break; '%s' 0.05; done" "$1" "$2" "$REAL_SLEEP"
}
release() {  # release <hold or release file> <pid>: ends a gate or a reader that waits for that file
  : > "$1"; wait "$2" || fail "the process that held its copies ended with an error"
}
# mutant <name> <file> <sed expression>: the harness with one defect in one file, in $WORK/mutant-<name>; ai-core on its
# bin-path runs the gate and init of that tree
mutant() {
  local root="$WORK/mutant-$1" entry dir="${2%/*}"
  rm -rf "$root"; mkdir -p "$root/bin-path"
  for entry in "$ROOT"/*; do ln -s "$entry" "$root/${entry##*/}"; done
  rm "$root/$dir"; mkdir "$root/$dir"
  for entry in "$ROOT/$dir"/*; do ln -s "$entry" "$root/$dir/${entry##*/}"; done
  rm "$root/$2"; sed "$3" "$ROOT/$2" > "$root/$2"
  cmp -s "$ROOT/$2" "$root/$2" && fail "the planted defect changed nothing: $3"
  printf '#!/usr/bin/env bash\ncmd="$1"; shift\ncase "$cmd" in pre-push|init) exec bash "%s/bin/$cmd.sh" "$@" ;; esac\nexec "%s/bin/ai-core" "$cmd" "$@"\n' "$root" "$ROOT" > "$root/bin-path/ai-core"
  chmod +x "$root/bin-path/ai-core"
}
cat > "$WORK/nb-hold.sh" <<'EOF'
#!/usr/bin/env bash
set -u
. "$1/lib/common.sh"; . "$1/lib/neighbours.sh"
status=0; neighbours_hold "$2" || status=$?
echo "status=$status"; echo "error=$NEIGHBOUR_ERROR"
printf '%s' "$NEIGHBOUR_REPORT" | sed 's/^/report=/'
for n in cat dog Zed; do flock -x -n "$FOLDER/.ai-core/neighbours/$n/.copy.lock" true && echo "free=$n" || echo "held=$n"; done
neighbours_release
EOF
hold_probe() {  # hold_probe <harness root> <worktree>: neighbours_hold of that harness's library in a shell of its own, on the clock, and which copies it then holds
  FOLDER="$F" clocked bash "$WORK/nb-hold.sh" "$1" "$2"
}

section "the gate reads the neighbour at the commit its origin landed after the last init, without an init in between"
land cat two
work_on "$T1" a
before="$(git -C "$CAT" rev-parse HEAD)"; tip="$(git -C "$WORK/nb-cat.git" rev-parse master)"
[ "$before" != "$tip" ] || fail "the case is not planted: the copy already stands at the landed commit"
push_gate "$T1" issue-2-y "$F-push1.log" || fail "the push of a change beside a neighbour that moved was refused: $(tail -5 "$F-push1.log")"
[ "$(last_check)" = "two one" ] || fail "the check read cat as '$(last_check)', not at the landed commit (see $F-push1.log)"
[ "$(git -C "$CAT" rev-parse HEAD)" = "$tip" ] || fail "the gate left the copy at $(git -C "$CAT" rev-parse HEAD), not at the landed $tip"
grep -aq "neighbour cat: the published copy $CAT stands at $tip (moved from $before to origin/master)" "$F-push1.log" || fail "the gate does not show the measured tip of cat (see $F-push1.log)"
grep -aq "neighbour dog: the published copy $DOG stands at $(git -C "$DOG" rev-parse HEAD) (already at origin/master)" "$F-push1.log" || fail "the gate does not show dog's tip (see $F-push1.log)"
[ "$(grep -an 'neighbour cat:' "$F-push1.log" | head -1 | cut -d: -f1)" -lt "$(grep -an 'neighbour dog:' "$F-push1.log" | head -1 | cut -d: -f1)" ] || fail "the neighbours are not held in the order of their names (see $F-push1.log)"
grep -aq 'neighbour eel' "$F-push1.log" && fail "the gate held eel, which is linked as its checkout and published nothing (see $F-push1.log)"
echo "  a landing in the neighbour after the last init reaches the check, each measured tip is shown in the order of the names, and a checkout without an origin is left alone"

section "a copy with a change or with a commit its origin lacks stays, and the gate names it"
land cat three
echo edited > "$CAT/marker"
work_on "$T1" b
push_gate "$T1" issue-2-y "$F-push2.log" || fail "the push beside a held copy was refused: $(tail -5 "$F-push2.log")"
[ "$(cat "$CAT/marker")" = edited ] || fail "the gate moved a copy that carried a change"
[ "$(last_check)" = "edited one" ] || fail "the check did not read the copy as it stands: $(last_check)"
grep -aq "neighbour cat: .*NOT moved to origin/master ($(git -C "$WORK/nb-cat.git" rev-parse master)): it holds a change in its tree" "$F-push2.log" || fail "the gate does not name the copy it held for its change (see $F-push2.log)"
git -C "$CAT" checkout -q -- marker
git_as -C "$CAT" commit -q --allow-empty -m "somebody's fix"; kept="$(git -C "$CAT" rev-parse HEAD)"
work_on "$T1" c
push_gate "$T1" issue-2-y "$F-push3.log" || fail "the push beside a copy with a commit of its own was refused: $(tail -5 "$F-push3.log")"
[ "$(git -C "$CAT" rev-parse HEAD)" = "$kept" ] || fail "the gate moved a copy off a commit its origin lacks"
grep -aq "neighbour cat: .*NOT moved .*: it holds a commit its origin lacks" "$F-push3.log" || fail "the gate does not name the copy it held for its commit (see $F-push3.log)"
git -C "$CAT" checkout -q --detach origin/master
echo "  a changed copy and a copy with a commit of its own stay as they were and are named"

section "a neighbour whose freshness cannot be established refuses the push, with nothing run"
runs="$(wc -l < "$CHECK_LOG")"
git -C "$F/cat" remote set-url origin "$WORK/nowhere.git"
work_on "$T1" d
push_gate "$T1" issue-2-y "$F-push4.log" && fail "the push went out although the origin of cat could not be asked"
grep -aq "REFUSED.*the origin of cat could not be asked, so its copy $CAT may stand behind it" "$F-push4.log" || fail "the refusal does not name cat and its copy (see $F-push4.log)"
[ "$(wc -l < "$CHECK_LOG")" = "$runs" ] || fail "the check ran against a copy whose freshness was not established"
git -C "$F/cat" remote set-url origin "$WORK/nb-cat.git"
cp "$CAT/.git" "$WORK/nb-copy-git"; printf 'garbage\n' > "$CAT/.git"
push_gate "$T1" issue-2-y "$F-push5.log" && fail "the push went out although the copy of cat could not be read"
grep -aq "REFUSED.*the freshness of $CAT cannot be established" "$F-push5.log" || fail "the refusal does not name the unreadable copy (see $F-push5.log)"
cp "$WORK/nb-copy-git" "$CAT/.git"
git -C "$F/cat" remote set-head origin master >/dev/null 2>&1 || true
bash "$ROOT/bin/init.sh" "$T2" --no-doctor > "$F-init3.log" 2>&1 || fail "init failed: $(tail -3 "$F-init3.log")"
git -C "$F/dog" remote set-url origin "$WORK/nowhere.git"
bash "$ROOT/bin/init.sh" "$T2" --no-doctor > "$F-init4.log" 2>&1 || fail "init beside an origin that cannot be asked failed: $(tail -3 "$F-init4.log")"
grep -aq 'may stand behind their origin.s newest commit.*dog (its origin could not be asked' "$F-init4.log" || fail "init does not name the neighbour whose origin it could not ask (see $F-init4.log)"
git -C "$F/dog" remote set-url origin "$WORK/nb-dog.git"
echo "  an origin that cannot be asked and a copy that cannot be read refuse the push before the check, and init names the origin it could not ask"

section "a copy that is gone, or a default branch that origin renamed since the link was made, refuses the push and names init"
runs="$(wc -l < "$CHECK_LOG")"
mv "$CAT" "$CAT.away"
work_on "$T1" e2
push_gate "$T1" issue-2-y "$F-gone.log" && fail "the push went out although the copy of cat was gone"
mv "$CAT.away" "$CAT"
grep -aq "REFUSED.*the link $F/.worktrees/app/cat leads to $CAT, and that copy or the checkout $F/cat is gone: run ai-core init in this worktree" "$F-gone.log" || fail "the refusal does not name the link and the copy that is gone (see $F-gone.log)"
git -C "$WORK/nb-cat-pusher" push -q origin master:refs/heads/trunk
git -C "$WORK/nb-cat.git" symbolic-ref HEAD refs/heads/trunk
push_gate "$T1" issue-2-y "$F-renamed.log" && fail "the push went out although the origin of cat names another default branch than the link leads to"
git -C "$WORK/nb-cat.git" symbolic-ref HEAD refs/heads/master
grep -aq "REFUSED.*the origin of cat names origin/trunk and the link leads to the copy of master: run ai-core init in this worktree, which follows it" "$F-renamed.log" || fail "the refusal does not name the renamed default branch (see $F-renamed.log)"
[ "$(wc -l < "$CHECK_LOG")" = "$runs" ] || fail "a check ran although a copy was gone or its default branch renamed"
echo "  a copy that is gone and a default branch that origin renamed refuse the push before the check, each naming the link and init"

section "two gates read one copy together; a copy a check reads is moved by nobody, and the next gate sees the later commit"
push_gate "$T1" issue-2-y "$F-push6.log" || fail "the push after the repairs was refused: $(tail -5 "$F-push6.log")"
cat_one="$(git -C "$CAT" rev-parse HEAD)"
work_on "$T2" e
HOLD="$WORK/nb-hold"
work_on "$T1" f
started="$(wc -l < "$CHECK_LOG")"
hold_gate "$T1" issue-2-y "$HOLD" "$F-hold1.log"; holder="$HOLDER"
# the same tip is read by a second gate at the same moment: shared, so it does not wait for the first
push_gate "$T2" issue-3-z "$F-hold2.log" || fail "a second gate could not read the copy the first one reads: $(tail -5 "$F-hold2.log")"
# init reads the copies beside the check too: a copy that is current already waits for no check (planted: init waited)
bash "$ROOT/bin/init.sh" "$T2" --no-doctor > "$F-init6.log" 2>&1 || fail "init beside a reading gate failed: $(tail -3 "$F-init6.log")"
grep -aq 'may stand behind' "$F-init6.log" && fail "init waited for a check that reads copies it had no need to move, and named them (see $F-init6.log)"
# the origin moves while the first check reads, and the check outlasts the allowance: the gate waits it out, refuses, and says what it waited for
land cat four
work_on "$T2" g
runs="$(wc -l < "$CHECK_LOG")"
clock_reset
clocked push_gate "$T2" issue-3-z "$F-hold3.log" && fail "a gate moved the copy under a check that still read it"
grep -aq "REFUSED.*the copy $CAT cannot move to origin/master, as a check still reads it" "$F-hold3.log" || fail "the refusal does not say that a check reads the copy (see $F-hold3.log)"
grep -aq "was not free in 1980 seconds (NEIGHBOUR_LOCK_WAIT_SECONDS is 2, the least; the automatic 1980 seconds are one and a half times 1320 seconds, the initial 1320, as no check on record was longer (the longest of the [0-9]* checks among the [0-9]* rows of .*took [0-9]* seconds))" "$F-hold3.log" || fail "the refusal does not name the setting, the automatic wait and the history it came from (see $F-hold3.log)"
grep -aq 'A check that runs longer, or hangs, keeps the copy' "$F-hold3.log" || fail "the refusal does not name the limit of a finite wait (see $F-hold3.log)"
[ "$(slept)" = 1980 ] || fail "the wait did not end at its allowance: it slept $(slept) seconds in all, not 1980"
[ "$(wc -l < "$CHECK_LOG")" = "$runs" ] || fail "the check ran although the copy could not move"
clock_reset
clocked bash "$ROOT/bin/init.sh" "$T2" --no-doctor > "$F-init5.log" 2>&1 || fail "init beside a reading gate failed: $(tail -3 "$F-init5.log")"
grep -aq 'may stand behind.*cat (the lock .* is held by another gate or init and was not free in 1980 seconds' "$F-init5.log" || fail "init does not name the copy it could not move under a reading gate (see $F-init5.log)"
[ "$(git -C "$CAT" rev-parse HEAD)" = "$cat_one" ] || fail "the copy moved under a running check"
release "$HOLD" "$holder"
[ "$(sed -n "$((started + 1))p" "$CHECK_LOG")" = "$(grep ' again$' "$CHECK_LOG" | tail -1 | sed 's/ again$//')" ] || fail "the check saw the copy change between its two reads: $(tail -4 "$CHECK_LOG")"
push_gate "$T2" issue-3-z "$F-hold4.log" || fail "the next gate was refused once the check ended: $(tail -5 "$F-hold4.log")"
[ "$(cut -d' ' -f1 <<< "$(last_check)")" = four ] || fail "the next gate did not observe the later commit: $(last_check)"
echo "  a second gate reads the same tip beside the first, none moves a copy under a running check, a wait that outlasts its allowance refuses and says what it waited for, and the next gate observes the later commit"

section "a gate and an init that must move a copy wait for the gate that reads it, with no setting changed, and pass once it ended"
HOLD="$WORK/nb-hold6"; work_on "$T1" j; work_on "$T2" k
T3="$F/.worktrees/app/issue-4-w"; git -C "$F/app" worktree add -q -b issue-4-w "$T3"
set_wait 2
started="$(wc -l < "$CHECK_LOG")"
hold_gate "$T1" issue-2-y "$HOLD" "$F-wait1.log"; holder="$HOLDER"
land cat five; land dog five
cat_tip="$(git -C "$WORK/nb-cat.git" rev-parse master)"; dog_tip="$(git -C "$WORK/nb-dog.git" rev-parse master)"
config_before="$(cat "$T2/.ai-core/config.env")"
push_gate "$T2" issue-3-z "$F-wait2.log" & waiting_gate=$!
bash "$ROOT/bin/init.sh" "$T3" --no-doctor > "$F-wait3.log" 2>&1 & waiting_init=$!
for _ in $(seq 1 600); do grep -aq 'neighbours: waiting for the lock' "$F-wait2.log" && grep -aq 'neighbours: waiting for the lock' "$F-wait3.log" && break; sleep 0.1; done
grep -aq 'neighbours: waiting for the lock' "$F-wait2.log" && grep -aq 'neighbours: waiting for the lock' "$F-wait3.log" || fail "the gate and the init did not both wait for the reading check: see $F-wait2.log and $F-wait3.log"
sleep 3
kill -0 "$waiting_gate" "$waiting_init" 2>/dev/null || fail "a gate or an init that had to move a copy under a reading check ended after waiting 3 seconds, the setting being 2: see $F-wait2.log and $F-wait3.log"
release "$HOLD" "$holder"
wait "$waiting_gate" || fail "the gate that waited for the reading check was refused: $(tail -5 "$F-wait2.log")"
wait "$waiting_init" || fail "the init that waited for the reading check failed: $(tail -5 "$F-wait3.log")"
[ "$(cat "$T2/.ai-core/config.env")" = "$config_before" ] || fail "the case is not planted without a setting changed: the config.env of the worktree differs"
[ "$(sed -n "$((started + 1))p" "$CHECK_LOG")" = "$(grep ' again$' "$CHECK_LOG" | tail -1 | sed 's/ again$//')" ] || fail "the reading check saw a copy change between its two reads: $(tail -4 "$CHECK_LOG")"
[ "$(sed -n "$((started + 1))p" "$CHECK_IDS" | cut -d' ' -f1-2)" = "$(grep ' again$' "$CHECK_IDS" | tail -1 | cut -d' ' -f1-2)" ] || fail "the reading check read other commits at its second read: $(tail -4 "$CHECK_IDS")"
[ "$(tail -1 "$CHECK_LOG")" = "five five" ] || fail "the check of the waiting gate read '$(tail -1 "$CHECK_LOG")', not the commits landed in the neighbours"
[ "$(tail -1 "$CHECK_IDS")" = "$cat_tip $dog_tip" ] || fail "the check of the waiting gate read other full commits than $cat_tip $dog_tip: $(tail -1 "$CHECK_IDS")"
grep -aq "neighbour cat: the published copy $CAT stands at $cat_tip (moved from .* to origin/master)" "$F-wait2.log" || grep -aq "neighbour cat: the published copy $CAT stands at $cat_tip (already at origin/master)" "$F-wait2.log" \
  || fail "the waiting gate does not show cat at the landed commit (see $F-wait2.log)"
grep -aq 'may stand behind' "$F-wait3.log" && fail "the init that waited reports a stale copy (see $F-wait3.log)"
[ "$(readlink "$F/.worktrees/app/cat")" = ../../.ai-core/neighbours/cat/origin-master ] && [ "$(cat "$T3/../cat/marker")" = five ] || fail "the init that waited left no link of cat to its published copy at the landed commit: $(readlink "$F/.worktrees/app/cat" 2>&1)"
[ -f "$T3/.ai-core/VERSION" ] || fail "the init that waited did not deploy the harness into its worktree"
[ "$(git -C "$CAT" rev-parse HEAD)" = "$cat_tip" ] && [ "$(git -C "$DOG" rev-parse HEAD)" = "$dog_tip" ] || fail "a copy does not stand at the commit its origin landed"
echo "  a gate and an init that need the copies of a reading check wait for it with the setting at 2, the check reads the same commits twice, and both pass afterwards"

section "a reader of twenty minutes is waited out at the old setting of 600, and a fixed wait refuses; a copy that need not move waits for nobody"
set_wait 600
work_on "$T1" l; work_on "$T2" m
HOLD="$WORK/nb-hold7"; hold_gate "$T1" issue-2-y "$HOLD" "$F-clock-hold.log"; holder="$HOLDER"
land cat six; land dog six
cat_tip="$(git -C "$WORK/nb-cat.git" rev-parse master)"; dog_tip="$(git -C "$WORK/nb-dog.git" rev-parse master)"
clock_reset; on_clock 2200 "$(release_script "$HOLD" "$holder")"
clocked push_gate "$T2" issue-3-z "$F-clock1.log" || fail "the gate beside a reader of 1200 seconds was refused with the setting at 600: $(tail -5 "$F-clock1.log")"
wait "$holder" || fail "the reading gate was refused: $(tail -5 "$F-clock-hold.log")"
[ "$(slept)" -ge 1200 ] && [ "$(slept)" -lt 1980 ] || fail "the wait was $(slept) seconds, not from the 1200 of the reader to the 1980 of its allowance"
grep -aq 'neighbours: waiting for the lock .*cat/.copy.lock, which another gate or init holds: for 1980 seconds at most (NEIGHBOUR_LOCK_WAIT_SECONDS is 600, the least; the automatic 1980 seconds' "$F-clock1.log" || fail "the gate did not say what it waited for and how long (see $F-clock1.log)"
[ "$(tail -1 "$CHECK_IDS")" = "$cat_tip $dog_tip" ] || fail "the check read other full commits than $cat_tip $dog_tip: $(tail -1 "$CHECK_IDS")"
echo "  with no longer check on record the wait is 1980 seconds, the gate moved both copies after the reader of 1200 seconds ended and its check read the commits that landed"
# innocent: nothing has to move, so a gate beside a reader waits for nobody; planted: the fixed wait of the setting, which refuses where the reader outlasts it
HOLD="$WORK/nb-hold7b"; work_on "$T1" n; work_on "$T2" o
hold_gate "$T1" issue-2-y "$HOLD" "$F-clock-hold2.log"; holder="$HOLDER"
clock_reset
clocked push_gate "$T2" issue-3-z "$F-clock2.log" || fail "a gate that needed no move waited for the reading check: $(tail -5 "$F-clock2.log")"
[ "$(slept)" = 0 ] || fail "a gate that needed no move slept $(slept) seconds"
land cat seven; work_on "$T2" p
mutant fixed-wait lib/neighbours.sh 's/^  NEIGHBOUR_BASE="\$NEIGHBOUR_WAIT_LONGEST"$/  NEIGHBOUR_ALLOWANCE="$1"; return 0/'
clock_reset; on_clock 2200 "$(release_script "$HOLD" "$holder")"
PATH="$WORK/mutant-fixed-wait/bin-path:$PATH" clocked push_gate "$T2" issue-3-z "$F-clock3.log" && fail "planted: the fixed wait of the setting passed, so this case cannot tell the new wait from the old"
[ "$(slept)" = 600 ] || fail "planted: the fixed wait slept $(slept) seconds, not the 600 of the setting"
grep -aq 'REFUSED.*cannot move to origin/master, as a check still reads it' "$F-clock3.log" || fail "planted: the fixed wait did not refuse as the old gate did (see $F-clock3.log)"
release "$HOLD" "$holder"
push_gate "$T2" issue-3-z "$F-clock4.log" || fail "the gate after the reading check ended was refused: $(tail -5 "$F-clock4.log")"
echo "  a copy that need not move waits for no reader, and the fixed wait of the setting refuses the same reader, which is how the case goes red"

section "the wait is the greater of the setting and one and a half times the longest check on record, which counts for no less than 1320 seconds"
LOG="$AI_CORE_HOME/.ai-core/pre-push-runs.tsv"; ALLOW_ENV="$WORK/nb-allow.env"
stamp_ago() { date -u -d "@$(( $(date +%s) - $1 ))" +%Y-%m-%dT%H:%M:%SZ; }  # stamp_ago <seconds>: the time that long ago, as the log writes it
log_row() {  # log_row <verdict> <seconds> [seven]: one row of the run log, of seven fields where a third argument says so, written ROW_AGE seconds ago (now when unset)
  printf '%s\texample/app\t/work\taaaa\t%s\t%s\tlast line' "$(stamp_ago "${ROW_AGE:-0}")" "$1" "$2"; [ -n "${3:-}" ] || printf '\t0.5'; printf '\n'
}
log_make() { mkdir -p "$(dirname "$LOG")"; { printf '%s\n' "$GATE_HEADER"; cat; } > "$LOG"; }
GATE_HEADER=$'time\trepository\tworktree\tcommit\tverdict\tseconds\tlast line\tload at check start'
allowance_for() {  # allowance_for <harness root> <configured>: the allowance of that library with the log as it stands, and what it says of the log
  ( . "$1/lib/common.sh"; . "$1/lib/neighbours.sh"
    printf 'NEIGHBOUR_LOCK_WAIT_SECONDS="%s"\n' "$2" > "$ALLOW_ENV"
    neighbour_wait_begin "$ALLOW_ENV"; neighbour_allowance "$2"; echo "$NEIGHBOUR_ALLOWANCE|$NEIGHBOUR_WAIT_HISTORY" )
}
expect_allowance() {  # expect_allowance <case> <configured> <allowance> <history phrase>
  local got; got="$(allowance_for "$ROOT" "$2")"
  [ "$got" = "$3|$4" ] || fail "$1: the allowance for a setting of $2 is '$got', not '$3|$4'"
}
rm -f "$LOG"
expect_allowance "no run log" 600 1980 "no run log stands at $LOG yet"
log_make < /dev/null
expect_allowance "a log with its header only" 600 1980 "no check that ran is recorded among the 0 rows of the last 14 days of $LOG"
{ log_row green 100; log_row red 40 seven; } | log_make
expect_allowance "the old setting of 600 and short checks" 600 1980 "the longest of the 2 checks among the 2 rows of the last 14 days of $LOG took 100 seconds"
{ log_row green 1500 seven; log_row red 1400; } | log_make
expect_allowance "rows of seven and eight fields, the longest 1500" 600 2250 "the longest of the 2 checks among the 2 rows of the last 14 days of $LOG took 1500 seconds"
{ log_row green 3000; log_row green 10; } | log_make
expect_allowance "a larger measured maximum" 600 4500 "the longest of the 2 checks among the 2 rows of the last 14 days of $LOG took 3000 seconds"
expect_allowance "a setting above the automatic wait is the least" 9000 9000 "the longest of the 2 checks among the 2 rows of the last 14 days of $LOG took 3000 seconds"
expect_allowance "a setting of 0 is one attempt, whatever the log says" 0 0 "the longest of the 2 checks among the 2 rows of the last 14 days of $LOG took 3000 seconds"
{ log_row green 1321; } | log_make
expect_allowance "the half is rounded up" 600 1982 "the longest of the 1 checks among the 1 rows of the last 14 days of $LOG took 1321 seconds"
{ printf 'time\trepository\tworktree\tcommit\tverdict\tseconds\tlast line\n'; log_row green 90 seven; } > "$LOG"
expect_allowance "a log of the old header" 600 1980 "the longest of the 1 checks among the 1 rows of the last 14 days of $LOG took 90 seconds"
{ log_row 'no check' - ; log_row red - ; log_row green - seven; } | log_make
expect_allowance "rows that name no seconds, because no check ran, measure nothing" 600 1980 "no check that ran is recorded among the 3 rows of the last 14 days of $LOG"
{ log_row green 200; printf '%s\texample/app\t/work\taaaa\tgreen\t99999' "$(stamp_ago 0)"; } | log_make
expect_allowance "a row an append has not ended is no run yet" 600 1980 "the longest of the 1 checks among the 1 rows of the last 14 days of $LOG took 200 seconds"
{ log_row green 1600; printf 'not a row\n'; log_row weird 5000; log_row green many; log_row green 12345678901; } | log_make
expect_allowance "rows that are none of these count for nothing and are named" 600 2400 "the longest of the 1 checks among the 5 rows of the last 14 days of $LOG took 1600 seconds, and 4 of those rows could not be read"
{ ROW_AGE=$((15 * 86400)) log_row green 9000; log_row green 100; } | log_make
expect_allowance "a check older than 14 days is not counted, and the rows before the window are named" 600 1980 "the longest of the 1 checks among the 1 rows of the last 14 days of $LOG took 100 seconds, and the 1 rows before them are not counted"
{ ROW_AGE=$((13 * 86400)) log_row green 9000; log_row green 100; } | log_make
expect_allowance "a check of 13 days ago is counted" 600 13500 "the longest of the 2 checks among the 2 rows of the last 14 days of $LOG took 9000 seconds"
{ ROW_AGE=$((20 * 86400)) log_row green 9000; ROW_AGE=$((14 * 86400 + 600)) log_row red 8000; } | log_make
expect_allowance "a log whose rows are all older than the window measures nothing" 600 1980 "no check that ran is recorded among the 0 rows of the last 14 days of $LOG, and the 2 rows before them are not counted"
{ log_row green 100; printf 'soon\texample/app\t/work\taaaa\tgreen\t9000\tlast line\t0.5\n'; } | log_make
expect_allowance "a row whose time is none is named and counts for nothing" 600 1980 "the longest of the 1 checks among the 2 rows of the last 14 days of $LOG took 100 seconds, and 1 of those rows could not be read"
rm -f "$LOG"; mkdir -p "$LOG"
expect_allowance "a log that cannot be read is not a measured zero" 600 1980 "the run log $LOG cannot be read"
rmdir "$LOG"
for bad in abc -1 1.5 12345678901; do
  printf 'NEIGHBOUR_LOCK_WAIT_SECONDS="%s"\n' "$bad" > "$ALLOW_ENV"
  ( . "$ROOT/lib/common.sh"; . "$ROOT/lib/neighbours.sh"; neighbour_lock_wait "$ALLOW_ENV" ) > /dev/null 2>&1 && fail "the setting '$bad' was taken for a number of seconds"
done
printf 'NEIGHBOUR_LOCK_WAIT_SECONDS="0600"\n' > "$ALLOW_ENV"
[ "$( . "$ROOT/lib/common.sh"; . "$ROOT/lib/neighbours.sh"; neighbour_lock_wait "$ALLOW_ENV")" = 600 ] || fail "a setting of 0600 is not 600 seconds"
# planted: a wait that ignores the log, which the larger maximum and the half rounded up must turn red
mutant history-ignored lib/neighbours.sh 's/^  NEIGHBOUR_BASE="\$NEIGHBOUR_WAIT_LONGEST"$/  NEIGHBOUR_BASE=0/'
{ log_row green 3000; } | log_make
[ "$(allowance_for "$ROOT" 600 | cut -d'|' -f1)" = 4500 ] || fail "the case is not planted: the library does not give 4500 for a check of 3000 seconds"
[ "$(allowance_for "$WORK/mutant-history-ignored" 600 | cut -d'|' -f1)" = 4500 ] && fail "planted: a wait that ignores the log gave the allowance of the log, so this case cannot tell"
# planted: a window that counts every row, which the outlier older than 14 days must turn red
mutant window-ignored lib/pre-push-runs.sh '/^    \$1 < start { older++; next }$/d'
{ ROW_AGE=$((15 * 86400)) log_row green 9000; log_row green 100; } | log_make
[ "$(allowance_for "$ROOT" 600 | cut -d'|' -f1)" = 1980 ] || fail "the case is not planted: the library does not give 1980 with an outlier of 15 days ago"
[ "$(allowance_for "$WORK/mutant-window-ignored" 600 | cut -d'|' -f1)" = 13500 ] || fail "planted: a window that counts every row did not give the allowance of the old outlier, so this case cannot tell"
rm -f "$LOG"
echo "  the allowance follows the log: 1980 with no longer check, a larger maximum and the half rounded up, the setting as the least, 0 as one attempt, and rows that measure nothing, an unfinished row or an unreadable log are named and never taken for a measured zero"

section "a gate that holds one copy gives it up while it waits for another, then holds all together and reads each at its newest commit"
set_wait 600
land dog nine
dog_tip="$(git -C "$WORK/nb-dog.git" rev-parse master)"; cat_tip="$(git -C "$WORK/nb-cat.git" rev-parse master)"
probe_wait() {  # probe_wait <harness root>: neighbours_hold of T2 while a reader holds dog, and cat is tried by a mover during the wait
  rm -f "$WORK/nb-probe"; reader dog "$WORK/nb-release9"
  clock_reset
  on_clock 1000 "flock -x -n '$(lock_of cat)' true && echo free > '$WORK/nb-probe' || echo held > '$WORK/nb-probe'; git -C '$DOG' rev-parse HEAD > '$WORK/nb-dogsnap'"
  on_clock 1100 "$(release_script "$WORK/nb-release9" "$READER")"
  rm -f "$WORK/nb-dogsnap"
  hold_probe "$1" "$T2" > "$WORK/nb-probe-out" 2>&1; release "$WORK/nb-release9" "$READER"
}
dog_before="$(git -C "$DOG" rev-parse HEAD)"
probe_wait "$ROOT"
[ "$(cat "$WORK/nb-dogsnap")" = "$dog_before" ] || fail "the copy of dog moved while the reader held it: it stood at $(cat "$WORK/nb-dogsnap"), not at $dog_before"
[ "$(cat "$WORK/nb-probe")" = free ] || fail "the gate kept the lock of cat while it waited for dog: a mover of cat found it held ($(cat "$WORK/nb-probe-out"))"
grep -qx 'status=0' "$WORK/nb-probe-out" || fail "the gate that waited for dog did not hold the copies: $(cat "$WORK/nb-probe-out")"
grep -q "^report=cat: the published copy $CAT stands at $cat_tip (already at origin/master)$" "$WORK/nb-probe-out" || fail "cat is not shown at its newest commit: $(cat "$WORK/nb-probe-out")"
grep -q "^report=dog: the published copy $DOG stands at $dog_tip (moved from .* to origin/master)$" "$WORK/nb-probe-out" || fail "dog is not shown moved to its newest commit: $(cat "$WORK/nb-probe-out")"
[ "$(grep -c '^held=' "$WORK/nb-probe-out")" = 3 ] || fail "the gate did not hold the copy of cat, dog and Zed together at the end: $(cat "$WORK/nb-probe-out")"
echo "  a mover of cat took its lock while the gate waited for dog, and the gate then held all three copies together at their newest commits"
land dog ten
mutant keeps-lock lib/neighbours.sh '/^    \[ -n "\$blocked" \] || return 0$/{n;s/neighbours_release/:/;}'
probe_wait "$WORK/mutant-keeps-lock"
[ "$(cat "$WORK/nb-probe")" = held ] || fail "planted: a gate that keeps cat's lock through the wait was not found holding it, so this case cannot tell"
echo "  a gate that keeps the lock of cat through the wait for dog is the planted defect: its mover of cat finds the lock held"
land dog ten-b
dog_before="$(git -C "$DOG" rev-parse HEAD)"
mutant moves-under-reader lib/neighbours.sh 's/\(neighbour_wait_flock 9 "\$dir\/.copy.lock"\) exclusive; } || return 1/\1 shared; } || return 1/'
probe_wait "$WORK/mutant-moves-under-reader"
[ "$(cat "$WORK/nb-dogsnap" 2>/dev/null || true)" = "$dog_before" ] && fail "planted: a gate that takes the lock of a move shared did not move the copy under its reader, so this case cannot tell"
echo "  a gate that moves a copy under a shared lock, the other planted defect, moves dog while its reader holds it, and the case sees the copy moved"

section "two gates that must move the same copies at the same moment both pass, and the copy moves once"
land cat eleven; land dog eleven
cat_tip="$(git -C "$WORK/nb-cat.git" rev-parse master)"; dog_tip="$(git -C "$WORK/nb-dog.git" rev-parse master)"
work_on "$T1" q; work_on "$T2" r
push_gate "$T1" issue-2-y "$F-two1.log" & first=$!
push_gate "$T2" issue-3-z "$F-two2.log" & second=$!
wait "$first" || fail "the first of two gates that move one copy was refused: $(tail -5 "$F-two1.log")"
wait "$second" || fail "the second of two gates that move one copy was refused: $(tail -5 "$F-two2.log")"
[ "$(tail -2 "$CHECK_IDS" | sort -u)" = "$cat_tip $dog_tip" ] || fail "a check of the two read other commits than the landed $cat_tip $dog_tip: $(tail -2 "$CHECK_IDS")"
[ "$(cat "$F-two1.log" "$F-two2.log" | grep -ac "neighbour cat: .*(moved from")" = 1 ] || fail "the copy of cat did not move exactly once between the two gates"
[ -z "$(git -C "$CAT" status --porcelain)" ] && [ -z "$(git -C "$DOG" status --porcelain)" ] || fail "a copy was left with a change in its tree by the two movers"
all_free cat dog Zed || fail "a lock is still held after both gates ended"
echo "  two gates that find the copies behind both pass, read the commits that landed, and one of them moved each copy"

section "a setting of 0 is one attempt, and a setting changed during a wait counts from the start of that wait"
land dog twelve
set_wait 0
reader dog "$WORK/nb-release11"; clock_reset
hold_probe "$ROOT" "$T2" > "$WORK/nb-zero-out" 2>&1
grep -qx 'status=1' "$WORK/nb-zero-out" && grep -q 'was not free in 0 seconds (NEIGHBOUR_LOCK_WAIT_SECONDS is 0, which is one attempt)' "$WORK/nb-zero-out" || fail "a setting of 0 did not refuse at once beside a reader: $(cat "$WORK/nb-zero-out")"
[ "$(slept)" = 0 ] || fail "a setting of 0 waited $(slept) seconds"
release "$WORK/nb-release11" "$READER"
hold_probe "$ROOT" "$T2" > "$WORK/nb-zero-out2" 2>&1
grep -qx 'status=0' "$WORK/nb-zero-out2" || fail "a setting of 0 refused although no reader held the copy: $(cat "$WORK/nb-zero-out2")"
grep -q 'A check that runs longer, or hangs, keeps the copy' "$WORK/nb-zero-out" || fail "the refusal beside a reading check does not name the check as what keeps the copy: $(cat "$WORK/nb-zero-out")"
mover dog "$WORK/nb-release11b"; clock_reset
hold_probe "$ROOT" "$T2" > "$WORK/nb-zero-out3" 2>&1
release "$WORK/nb-release11b" "$READER"
grep -qx 'status=1' "$WORK/nb-zero-out3" && grep -q "^error=the copy $DOG cannot be read: .*was not free in 0 seconds (NEIGHBOUR_LOCK_WAIT_SECONDS is 0, which is one attempt)\. A move of the copy that runs longer, or hangs, keeps it:" "$WORK/nb-zero-out3" \
  || fail "the refusal beside a move of the copy does not name the move as what keeps it: $(cat "$WORK/nb-zero-out3")"
land dog thirteen
set_wait 600
reader dog "$WORK/nb-release12"; clock_reset
on_clock 1100 "printf 'UPDATE_CHECK=\"never\"\nNEIGHBOUR_LOCK_WAIT_SECONDS=\"0\"\n' > '$T2/.ai-core/config.env'"
hold_probe "$ROOT" "$T2" > "$WORK/nb-lower-out" 2>&1
grep -qx 'status=1' "$WORK/nb-lower-out" && grep -q 'NEIGHBOUR_LOCK_WAIT_SECONDS is 0, which is one attempt' "$WORK/nb-lower-out" || fail "a setting lowered to 0 during the wait did not end it: $(cat "$WORK/nb-lower-out")"
[ "$(slept)" -ge 100 ] && [ "$(slept)" -lt 200 ] || fail "the wait ended after $(slept) seconds, not soon after the setting changed at 100"
mutant config-frozen lib/neighbours.sh 's/^    configured="\$(neighbour_lock_wait "\$NEIGHBOUR_WAIT_CONFIG")" \\$/    configured="${NEIGHBOUR_FROZEN:=$(neighbour_lock_wait "$NEIGHBOUR_WAIT_CONFIG")}" \\/'
set_wait 600; clock_reset
on_clock 1100 "printf 'UPDATE_CHECK=\"never\"\nNEIGHBOUR_LOCK_WAIT_SECONDS=\"0\"\n' > '$T2/.ai-core/config.env'"
hold_probe "$WORK/mutant-config-frozen" "$T2" > "$WORK/nb-frozen-out" 2>&1
[ "$(slept)" -ge 1980 ] || fail "planted: a wait that reads its setting once ended after $(slept) seconds, so this case cannot tell it from one that reads it at every poll"
set_wait 600; clock_reset
on_clock 1100 "printf 'UPDATE_CHECK=\"never\"\nNEIGHBOUR_LOCK_WAIT_SECONDS=\"abc\"\n' > '$T2/.ai-core/config.env'"
hold_probe "$ROOT" "$T2" > "$WORK/nb-bad-out" 2>&1
grep -qx 'status=1' "$WORK/nb-bad-out" && grep -q "NEIGHBOUR_LOCK_WAIT_SECONDS is not a whole number of seconds in $T2/.ai-core/config.env" "$WORK/nb-bad-out" || fail "a setting broken during the wait did not end it with the key named: $(cat "$WORK/nb-bad-out")"
set_wait 600
clock_reset
on_clock 1500 "printf 'UPDATE_CHECK=\"never\"\nNEIGHBOUR_LOCK_WAIT_SECONDS=\"9000\"\n' > '$T2/.ai-core/config.env'"
on_clock 3500 "$(release_script "$WORK/nb-release12" "$READER")"
hold_probe "$ROOT" "$T2" > "$WORK/nb-raise-out" 2>&1; wait "$READER" || true
grep -qx 'status=0' "$WORK/nb-raise-out" || fail "a setting raised during the wait did not let it go on past 1980 seconds: $(cat "$WORK/nb-raise-out")"
[ "$(slept)" -ge 2500 ] || fail "the wait ended after $(slept) seconds, not at the reader's end 2500 seconds after its start"
set_wait 2
echo "  0 refuses at once and passes where nothing reads, a refusal names a reading check or a move as what keeps the copy, and a setting lowered, broken or raised during a wait is read again at the next poll, counting from the start of the wait"

section "a wait that is interrupted leaves no lock, and a setting that is no number refuses before anything runs"
land dog fourteen
work_on "$T2" s
reader dog "$WORK/nb-release13"
runs="$(wc -l < "$CHECK_LOG")"
setsid git -C "$T2" push origin HEAD:refs/heads/issue-3-z > "$F-term.log" 2>&1 & waiting=$!
for _ in $(seq 1 600); do grep -aq 'neighbours: waiting for the lock' "$F-term.log" && break; sleep 0.1; done
grep -aq 'neighbours: waiting for the lock' "$F-term.log" || fail "the gate never said it waited for the reader (see $F-term.log)"
all_free cat Zed || fail "the gate holds the lock of cat or Zed while it waits for dog"
kill -TERM -- "-$waiting"
status=0; wait "$waiting" || status=$?
[ "$status" -ne 0 ] || fail "a push that was interrupted by TERM reported success"
all_free cat Zed || fail "an interrupted gate left the lock of cat or Zed held, though it holds none while it waits for dog"
release "$WORK/nb-release13" "$READER"
all_free cat dog Zed || fail "a lock is still held after the reader ended and the gate was interrupted"
[ "$(wc -l < "$CHECK_LOG")" = "$runs" ] || fail "the interrupted gate ran its check"
push_gate "$T2" issue-3-z "$F-term2.log" || fail "the push after the interrupted one was refused: $(tail -5 "$F-term2.log")"
printf 'UPDATE_CHECK="never"\nNEIGHBOUR_LOCK_WAIT_SECONDS="soon"\nPRE_PUSH_LOAD_LIMIT="0"\n' > "$T2/.ai-core/config.env"
work_on "$T2" t
runs="$(wc -l < "$CHECK_LOG")"
push_gate "$T2" issue-3-z "$F-bad.log" && fail "the push went out with NEIGHBOUR_LOCK_WAIT_SECONDS set to 'soon'"
grep -aq 'REFUSED.*NEIGHBOUR_LOCK_WAIT_SECONDS is not a whole number of seconds' "$F-bad.log" || fail "the refusal does not name the setting (see $F-bad.log)"
[ "$(wc -l < "$CHECK_LOG")" = "$runs" ] || fail "the check ran under a setting that is no number"
mutant invalid-accepted lib/neighbours.sh '/^  case "\$wait" in/d; s/^  printf .%s\\n. "\$((10#\$wait))"$/  printf "600\\n"/'
PATH="$WORK/mutant-invalid-accepted/bin-path:$PATH" push_gate "$T2" issue-3-z "$F-bad2.log" || fail "planted: a library that takes any setting for a number refused the push, so this case cannot tell: $(tail -3 "$F-bad2.log")"
printf 'UPDATE_CHECK="never"\nNEIGHBOUR_LOCK_WAIT_SECONDS="soon"\n' > "$F/app/.ai-core/config.env"
bash "$ROOT/bin/init.sh" "$T2" --no-doctor > "$F-bad-init.log" 2>&1 && fail "init went on with NEIGHBOUR_LOCK_WAIT_SECONDS set to 'soon'"
grep -aq 'NEIGHBOUR_LOCK_WAIT_SECONDS is .soon.' "$F-bad-init.log" || fail "init does not name the setting (see $F-bad-init.log)"
# a config.env that exists and cannot be read: the wait is not taken from its default, by the explicit read and by init
. "$ROOT/tests/unreadable.sh"
old_reader_copy "$ROOT" "$WORK/nb-old-reader" || fail "no copy of the harness with the old reader"
wait_of() {  # wait_of <harness root> <config.env>: what neighbour_lock_wait prints, its status and its words on standard error, one line
  local out rc=0
  out="$(bash -c '. "$1/lib/common.sh"; . "$1/lib/neighbours.sh"; neighbour_lock_wait "$2"' _ "$1" "$2" 2> "$WORK/nb-wait.err")" || rc=$?
  printf 'status %s, printed [%s], said [%s]' "$rc" "$out" "$(tr '\n' ' ' < "$WORK/nb-wait.err" | sed 's/ *$//')"
}
printf 'NEIGHBOUR_LOCK_WAIT_SECONDS="7"\n' > "$WORK/nb-wait.env"
[ "$(wait_of "$ROOT" "$WORK/nb-wait.env")" = 'status 0, printed [7], said []' ] || fail "a readable setting is not read: $(wait_of "$ROOT" "$WORK/nb-wait.env")"
[ "$(wait_of "$ROOT" "$WORK/nb-wait.none")" = 'status 0, printed [600], said []' ] || fail "a config.env that is not there no longer gives the default wait: $(wait_of "$ROOT" "$WORK/nb-wait.none")"
make_unreadable "$WORK/nb-wait.env" || fail "the file of the wait cannot be made unreadable"
case "$(wait_of "$ROOT" "$WORK/nb-wait.env")" in
  "status 1, printed [], said ["*"error: $WORK/nb-wait.env exists but cannot be read; fix its permissions, or remove it to take the defaults]") ;;
  *) fail "the wait of an unreadable config.env was chosen, or the file not named: $(wait_of "$ROOT" "$WORK/nb-wait.env")" ;;
esac
case "$(wait_of "$WORK/nb-old-reader" "$WORK/nb-wait.env")" in
  *"exists but cannot be read"*) fail "planted: the old reader still names the unreadable file" ;;
  "status 0, printed [600], said ["*) ;;
  *) fail "planted: the old reader did not give the default wait of 600 seconds for the unreadable file: $(wait_of "$WORK/nb-old-reader" "$WORK/nb-wait.env")" ;;
esac
chmod 600 "$WORK/nb-wait.env"
printf 'UPDATE_CHECK="never"\nNEIGHBOUR_LOCK_WAIT_SECONDS="2"\nPRE_PUSH_LOAD_LIMIT="0"\n' > "$T2/.ai-core/config.env"
make_unreadable "$T2/.ai-core/config.env" || fail "the config.env of the worktree cannot be made unreadable"
bash "$ROOT/bin/init.sh" "$T2" --no-doctor --dry-run > "$F-unreadable-init.log" 2>&1 && fail "init went on with a config.env of the worktree that cannot be read"
grep -aq "$T2/.ai-core/config.env exists but cannot be read" "$F-unreadable-init.log" || fail "init does not name the file it cannot read (see $F-unreadable-init.log)"
bash "$WORK/nb-old-reader/bin/init.sh" "$T2" --no-doctor --dry-run > "$F-unreadable-init-old.log" 2>&1 || fail "planted: init with the old reader did not go on with the default wait, so this case cannot tell (see $F-unreadable-init-old.log)"
chmod 600 "$T2/.ai-core/config.env"
set_wait 2
echo "  the gate killed while it waited holds no lock, the copies are free once the reader ends, and a setting that is no number refuses the gate and init, naming the key"

section "a landing whose receipt does not hold holds no copy through the wait for a lower load, and reads the copies as they stand after it"
work_on "$T2" u
printf 'UPDATE_CHECK="never"\nNEIGHBOUR_LOCK_WAIT_SECONDS="2"\nPRE_PUSH_LOAD_LIMIT="24"\nPRE_PUSH_LOAD_WAIT_SECONDS="300"\n' > "$T2/.ai-core/config.env"
landing_wait() {  # landing_wait <harness root>: a gate with a receipt that holds nothing, one wait for a lower load, and a mover at the first sleep
  rm -f "$WORK/nb-probe"; clock_reset; printf '%s\n' 30 30 0.5 > "$STATE/loads"
  on_clock 1000 "flock -x -n '$(lock_of dog)' true && flock -x -n '$(lock_of dog | sed 's/copy/admission/')' true && echo free > '$WORK/nb-probe' || echo held > '$WORK/nb-probe'; echo '$2' > '$WORK/nb-dog-pusher/marker'; git -C '$WORK/nb-dog-pusher' -c user.email=check@localhost -c user.name=check commit -q -am '$2'; git -C '$WORK/nb-dog-pusher' push -q origin master"
  PATH="$1/bin-path:$PATH" AI_CORE_LANDING_RECEIPT="$WORK/nb-no-receipt/receipt" clocked push_gate "$T2" issue-3-z "$F-recv-$2.log"
}
landing_wait "$ROOT" during || fail "the gate with a receipt that does not hold was refused: $(tail -5 "$F-recv-during.log")"
[ "$(cat "$WORK/nb-probe")" = free ] || fail "the gate held the copies through the wait for a lower load, though its receipt did not hold: a mover of dog found the lock held"
grep -aq 'no receipt of this landing stands at' "$F-recv-during.log" || fail "the gate does not say why its check runs (see $F-recv-during.log)"
[ "$(tail -1 "$CHECK_LOG" | cut -d' ' -f2)" = during ] || fail "the check read '$(tail -1 "$CHECK_LOG")', not the commit that landed in dog during the wait"
echo "  a gate whose receipt does not hold let a mover take dog's lock during the wait for a lower load, and its check read dog as it stood after it"
work_on "$T2" v
mutant holds-through-wait bin/pre-push.sh '/^      neighbours_release   # no copy stays held/d'
landing_wait "$WORK/mutant-holds-through-wait" while || true
[ "$(cat "$WORK/nb-probe")" = held ] || fail "planted: a gate that holds the copies through the wait for a lower load was not found holding them, so this case cannot tell"
set_wait 2
echo "  a gate that holds the copies for a receipt through the wait is the planted defect: its mover of dog finds the lock held"

section "a process that a step of the gate starts and leaves running holds none of the locks of the gate"
daemons="$WORK/nb-daemons"; : > "$daemons"
work_on "$T1" h
CHECK_DAEMON="$daemons" push_gate "$T1" issue-2-y "$F-lock.log"; lock_push=$?
held=""
for neighbour in Zed cat dog; do
  flock -x -n "$F/.ai-core/neighbours/$neighbour/.copy.lock" true || held="$held $neighbour/.copy.lock"
done
spawned="$(wc -l < "$daemons" | tr -d ' ')"
while read -r pid; do kill "$pid" 2>/dev/null || true; done < "$daemons"
[ "$lock_push" -eq 0 ] || fail "the push beside the process left running was refused: $(tail -5 "$F-lock.log")"
[ "$spawned" -eq 1 ] || fail "the case is not planted: $spawned process(es) were left running by the check, not one"
[ -z "$held" ] || fail "a process the check left running still holds a lock of the gate:$held (see $F-lock.log)"
echo "  the check leaves a process running, and the locks of the gate are free once the gate ends"

# git runs a hook with its own folder first on the PATH, so a stand-in for git reaches the fetch only outside a hook
gitwrap="$WORK/nb-gitwrap"; mkdir -p "$gitwrap"; : > "$daemons"
cat > "$gitwrap/git" <<WRAP
#!/usr/bin/env bash
case " \$* " in *" fetch "*) ( nohup sleep 120 >/dev/null 2>&1 & echo \$! >> "$daemons" ) ;; esac
exec "$(command -v git)" "\$@"
WRAP
chmod +x "$gitwrap/git"
( . "$ROOT/lib/neighbours.sh"; PATH="$gitwrap:$PATH" neighbour_fetch "$F" cat 5 ) || fail "the fetch of cat failed"
spawned="$(wc -l < "$daemons" | tr -d ' ')"
fetch_held=""; flock -x -n "$F/.ai-core/neighbours/cat/.fetch.lock" true || fetch_held=1
while read -r pid; do kill "$pid" 2>/dev/null || true; done < "$daemons"
[ "$spawned" -eq 1 ] || fail "the case is not planted: the fetch left $spawned process(es) running, not one"
[ -z "$fetch_held" ] || fail "the process the fetch left running, as the automatic maintenance of git does, still holds .fetch.lock"
echo "  the fetch of a neighbour leaves a process running, and its lock is free once the fetch ends"

section "the neighbours are held in the C order of their names, whatever order the locale gives the links"
glob_order="$(cd "$F/.worktrees/app" && LC_ALL=en_US.utf8 bash -c 'for link in *; do [ -L "$link" ] && echo "$link"; done' | tr '\n' ' ')"
[ "$glob_order" = "cat dog eel Zed " ] || fail "the case is not planted: the glob of this machine lists the links as '$glob_order' under en_US.utf8, not apart from the C order (Zed first)"
work_on "$T1" i
LC_ALL=en_US.utf8 push_gate "$T1" issue-2-y "$F-order.log" || fail "the push under en_US.utf8 was refused: $(tail -5 "$F-order.log")"
[ "$(grep -an 'neighbour Zed:' "$F-order.log" | head -1 | cut -d: -f1)" -lt "$(grep -an 'neighbour cat:' "$F-order.log" | head -1 | cut -d: -f1)" ] || fail "the neighbours are not held in the C order of their names (see $F-order.log)"
echo "  Zed is held before cat although the glob of the locale lists it last"

# A gate's reader that enters a copy through the admission of the library under test, as the gate does, and holds it until its
# release file exists. It logs when it was admitted and the commit the copy stood at then.
EV="$WORK/nb-events.log"; RD="$WORK/nb-rd"; mkdir -p "$RD"
cat > "$WORK/nb-reader.sh" <<'EOF'
#!/usr/bin/env bash
# nb-reader.sh <harness root> <config.env> <neighbour directory> <label> <events> <state directory>
set -u
. "$1/lib/common.sh"; . "$1/lib/neighbours.sh"
dir="$3"; label="$4"
neighbour_wait_begin "$2"
neighbour_open 40 "$dir/.copy.lock" || exit 2
neighbour_wait_for "$dir/.admission.lock or $dir/.copy.lock" "A move keeps it" neighbour_enter 40 "$dir/.copy.lock" "$dir/.admission.lock" 2> "$6/$label.err" \
  || { echo "$label refused: $NEIGHBOUR_ERROR" >> "$5"; exit 3; }
echo "$label admitted at $(git -C "$dir/origin-master" rev-parse HEAD)" >> "$5"; : > "$6/admitted-$label"
while [ ! -e "$6/release-$label" ]; do sleep 0.1; done
echo "$label released" >> "$5"
EOF
await() {  # await <seconds> <command>...: until the command succeeds, at most that long
  local n=$(( $1 * 10 )); shift
  until "$@"; do n=$((n - 1)); [ "$n" -gt 0 ] || return 1; "$REAL_SLEEP" 0.1; done
}
gone() { ! kill -0 "$1" 2>/dev/null; }
reader_start() { bash "$WORK/nb-reader.sh" "$1" "$F/app/.ai-core/config.env" "$F/.ai-core/neighbours/$2" "$3" "$EV" "$RD" > "$RD/$3.out" 2>&1 & echo $! > "$RD/pid-$3"; }
reader_stop() {  # reader_stop <label>...: ends the readers, one that was never admitted by TERM
  local l pid
  for l in "$@"; do
    pid="$(cat "$RD/pid-$l")"; : > "$RD/release-$l"
    [ -e "$RD/admitted-$l" ] || kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
}
stop_group() { kill -TERM -- "-$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }  # stop_group <pid of a process that setsid started>
reader_decided() { [ -e "$RD/admitted-$1" ] || grep -aq 'neighbours: waiting for the lock' "$RD/$1.err" 2>/dev/null; }
waiting_on() { grep -aq "neighbours: waiting for the lock $2" "$1" 2>/dev/null; }
locks_on() {  # locks_on <lock file> READ|WRITE: how many flock locks of that kind the kernel lists on the file (/proc/locks)
  grep -c "FLOCK .* $2 [0-9]* [0-9a-f]*:[0-9a-f]*:$(stat -c %i "$1") " /proc/locks || true
}
# starve_run <init|gate> <harness root> <tag> <early readers> <late readers>: a copy that must move while early readers hold it
# and late readers keep arriving. Sets STARVE to ok, or to the first thing that went wrong; every process is reaped.
STARVE=""
starve_run() {
  local kind="$1" root="$2" tag="$3" i mover tip old status=0
  STARVE=ok; : > "$EV"; RD="$WORK/nb-rd-$tag"; mkdir -p "$RD"; set_wait 600
  for ((i = 1; i <= $4; i++)); do reader_start "$root" cat "e$i-$tag"; done
  for ((i = 1; i <= $4; i++)); do await 120 test -e "$RD/admitted-e$i-$tag" || STARVE="early reader $i was not admitted"; done
  land cat "$tag"; tip="$(git -C "$WORK/nb-cat.git" rev-parse master)"; old="$(git -C "$CAT" rev-parse HEAD)"
  if [ "$kind" = init ]; then setsid bash "$root/bin/init.sh" "$T3" --no-doctor > "$RD/mover.out" 2>&1 & mover=$!
  else work_on "$T2" "st-$tag"; PATH="$root/bin-path:$PATH" setsid git -C "$T2" push origin "HEAD:refs/heads/st-$tag" > "$RD/mover.out" 2>&1 & mover=$!; fi
  if [ "$4" -gt 0 ]; then
    await 120 waiting_on "$RD/mover.out" "" || STARVE="the move never waited for the early readers: $(tail -3 "$RD/mover.out")"
    [ "$(git -C "$CAT" rev-parse HEAD)" = "$old" ] || STARVE="the copy moved under the early readers"
  fi
  for ((i = 1; i <= $5; i++)); do reader_start "$root" cat "l$i-$tag"; done
  for ((i = 1; i <= $5; i++)); do
    await 120 reader_decided "l$i-$tag" || STARVE="late reader $i was neither admitted nor refused"
    [ ! -e "$RD/admitted-l$i-$tag" ] || [ "$STARVE" != ok ] || STARVE="a later reader was admitted while the move waited"
  done
  for ((i = 1; i <= $4; i++)); do reader_stop "e$i-$tag"; done
  [ "$STARVE" != ok ] || await 120 gone "$mover" || STARVE="the move did not finish after the early readers ended"
  if [ "$STARVE" = ok ]; then
    wait "$mover" || status=$?
    [ "$status" -eq 0 ] || STARVE="the mover ended with status $status: $(tail -3 "$RD/mover.out")"
    [ "$(git -C "$CAT" rev-parse HEAD)" = "$tip" ] || STARVE="the copy does not stand at the landed commit"
    for ((i = 1; i <= $5; i++)); do
      await 120 test -e "$RD/admitted-l$i-$tag" || STARVE="late reader $i was never admitted after the move"
      grep -q "^l$i-$tag admitted at $tip$" "$EV" || STARVE="late reader $i was admitted at another commit than the moved $tip"
    done
  fi
  for ((i = 1; i <= $5; i++)); do reader_stop "l$i-$tag"; done
  [ "$STARVE" != ok ] || await 120 gone "$mover" || true
  stop_group "$mover"
}

section "a copy that must move gets its turn while later readers keep arriving; the old acquisition starves it, and a single holder only delays it"
starve_run init "$ROOT" a1 2 2
[ "$STARVE" = ok ] || fail "init did not get its turn: $STARVE"
starve_run gate "$ROOT" a2 2 2
[ "$STARVE" = ok ] || fail "a gate that must move the copy did not get its turn: $STARVE"
echo "  an init and a gate that must move a copy wait for the two readers admitted before them, finish before two later readers enter, and those read the moved commit"
starve_run init "$ROOT" b1 1 0
[ "$STARVE" = ok ] || fail "init beside a single holder: $STARVE"
starve_run init "$ROOT" b2 0 0
[ "$STARVE" = ok ] || fail "init with no reader: $STARVE"
echo "  innocent: a single holder is waited for and the move follows its release, and a move with no reader needs no wait"
STARVED="a later reader was admitted while the move waited"
mutant old-acquisition lib/neighbours.sh 's/^  neighbour_try_flock 7 shared || rc=\$?$/  :/; s/^  if \[ "\$4" -ne 1 \]; then$/  if false; then/; s/\(neighbour_wait_flock "\$fd" "\$dir\/.admission.lock" exclusive\) "A move[^"]*"/true/'
starve_run init "$WORK/mutant-old-acquisition" c1 2 2
[ "$STARVE" = "$STARVED" ] || fail "planted: the old acquisition, the library with its admission bypassed, did not starve the move of init: $STARVE"
starve_run gate "$WORK/mutant-old-acquisition" c2 2 2
[ "$STARVE" = "$STARVED" ] || fail "planted: the old acquisition did not starve the move of a gate: $STARVE"
echo "  planted: the library with its admission bypassed lets later readers in beside the move of init and of a gate, and the progress assertion goes red"
mutant no-intent-init lib/neighbours.sh 's/\(neighbour_wait_flock "\$fd" "\$dir\/.admission.lock" exclusive\) "A move[^"]*"/true/'
starve_run init "$WORK/mutant-no-intent-init" d1 2 2
[ "$STARVE" = "$STARVED" ] || fail "planted: init without its writer intent did not starve: $STARVE"
mutant no-intent-gate lib/neighbours.sh 's/^  if \[ "\$4" -ne 1 \]; then$/  if false; then/'
starve_run gate "$WORK/mutant-no-intent-gate" d2 2 2
[ "$STARVE" = "$STARVED" ] || fail "planted: a gate mover without its writer intent did not starve: $STARVE"
starve_run init "$WORK/mutant-no-intent-gate" d3 2 2
[ "$STARVE" = ok ] || fail "innocent: init, whose intent is its own, failed beside the gate's planted defect: $STARVE"
echo "  planted: no writer intent in init, and none in the movement of a gate, each starve their own move, and the other one still passes"

admission_of() { printf '%s/.ai-core/neighbours/%s/.admission.lock\n' "$F" "$1"; }
# multi_run <harness root> <tag>: two inits and two gates, cat and dog behind, three early readers that overlap differently, and a late one
MULTI=""
multi_run() {
  local root="$1" tag="$2" l i1 i2 g1 g2 tc td status=0
  MULTI=ok; : > "$EV"; RD="$WORK/nb-rd-$tag"; mkdir -p "$RD"; set_wait 600
  reader_start "$root" cat "rc1-$tag"; reader_start "$root" cat "rc2-$tag"; reader_start "$root" dog "rd1-$tag"
  for l in rc1 rc2 rd1; do await 120 test -e "$RD/admitted-$l-$tag" || MULTI="reader $l was not admitted"; done
  land cat "$tag"; land dog "$tag"; tc="$(git -C "$WORK/nb-cat.git" rev-parse master)"; td="$(git -C "$WORK/nb-dog.git" rev-parse master)"
  setsid bash "$root/bin/init.sh" "$T2" --no-doctor > "$RD/i1.out" 2>&1 & i1=$!
  await 120 waiting_on "$RD/i1.out" "" || MULTI="the first init never waited for the readers"
  setsid bash "$root/bin/init.sh" "$T3" --no-doctor > "$RD/i2.out" 2>&1 & i2=$!
  await 120 waiting_on "$RD/i2.out" "$(admission_of cat)" || MULTI="the second init never waited for the admission of cat"
  work_on "$T1" "m1-$tag"; work_on "$T2" "m2-$tag"
  PATH="$root/bin-path:$PATH" setsid git -C "$T1" push origin "HEAD:refs/heads/m1-$tag" > "$RD/g1.out" 2>&1 & g1=$!
  PATH="$root/bin-path:$PATH" setsid git -C "$T2" push origin "HEAD:refs/heads/m2-$tag" > "$RD/g2.out" 2>&1 & g2=$!
  await 120 waiting_on "$RD/g1.out" "$(admission_of cat) or" || MULTI="the first gate never waited for the admission of cat"
  await 120 waiting_on "$RD/g2.out" "$(admission_of cat) or" || MULTI="the second gate never waited for the admission of cat"
  [ "$(locks_on "$(lock_of Zed)" READ)" = 0 ] || MULTI="a gate that waits for the admission of cat keeps the shared lock of Zed"
  [ "$(locks_on "$(lock_of cat)" READ)" = 2 ] || MULTI="a gate or an init that waits for the admission of cat keeps a shared lock of cat: $(locks_on "$(lock_of cat)" READ) are held, the two readers hold two"
  reader_start "$root" dog "ld-$tag"; await 120 reader_decided "ld-$tag" || MULTI="the late reader of dog was neither admitted nor refused"
  [ ! -e "$RD/admitted-ld-$tag" ] || [ "$MULTI" != ok ] || MULTI="a later reader of dog was admitted while init waited for the readers of cat, so init would wait for it too"
  reader_stop "rd1-$tag" "rc1-$tag" "rc2-$tag"
  if [ "$MULTI" = ok ]; then
    for l in $i1 $i2 $g1 $g2; do await 120 gone "$l" || MULTI="a process did not finish after the readers ended: $l"; done
    for l in $i1 $i2 $g1 $g2; do wait "$l" || MULTI="a process ended with an error: $l ($(tail -2 "$RD/i1.out" "$RD/i2.out" "$RD/g1.out" "$RD/g2.out" | tr '\n' ' '))"; done
    [ "$(git -C "$CAT" rev-parse HEAD)" = "$tc" ] && [ "$(git -C "$DOG" rev-parse HEAD)" = "$td" ] || MULTI="a copy does not stand at the commit that landed"
    await 120 test -e "$RD/admitted-ld-$tag" || MULTI="the late reader of dog was never admitted"
  fi
  reader_stop "ld-$tag"
  for l in $i1 $i2 $g1 $g2; do stop_group "$l"; done
}
section "two inits and two gates that must move two copies finish without a deadlock and without waiting for a later cohort, and the locks are told by the kernel"
multi_run "$ROOT" e1
[ "$MULTI" = ok ] || fail "two inits and two gates over two copies: $MULTI"
all_free cat dog Zed || fail "a lock is still held after two inits and two gates ended"
mutant keeps-while-waiting lib/neighbours.sh '/^neighbour_read_state() {$/,/^}$/s/^  neighbour_unlock 9$/  :/'
multi_run "$WORK/mutant-keeps-while-waiting" e2
case "$MULTI" in *"keeps a shared lock of cat"*) ;; *) fail "planted: a mover that keeps the shared lock it read the state under while it waits for admission was not found holding it: $MULTI" ;; esac
mutant no-pending-set bin/init.sh 's/^        neighbour_pending_begin .*$/        :/'
multi_run "$WORK/mutant-no-pending-set" e3
case "$MULTI" in *"so init would wait for it too"*) ;; *) fail "planted: an init that claims one copy after the other did not meet a later cohort at the next copy: $MULTI" ;; esac
echo "  two inits and two gates over two copies pass with readers released in another order, a waiting gate or init keeps no shared lock, and a later reader waits; the planted keeper and the planted one-at-a-time init are red"

section "a waiting init and a waiting gate that end by TERM or by KILL leave no admission or copy lock, and a fresh move and reader go through"
for how in TERM KILL; do
  RD="$WORK/nb-rd-x$how"; mkdir -p "$RD"; set_wait 600; : > "$EV"
  reader_start "$ROOT" cat "x1-$how"; await 120 test -e "$RD/admitted-x1-$how" || fail "the reader was not admitted"
  land cat "x$how"; tip="$(git -C "$WORK/nb-cat.git" rev-parse master)"
  setsid bash "$ROOT/bin/init.sh" "$T3" --no-doctor > "$RD/init.out" 2>&1 & first=$!
  await 120 waiting_on "$RD/init.out" "" || fail "the init never waited"
  work_on "$T2" "x$how"
  setsid git -C "$T2" push origin "HEAD:refs/heads/x-$how" > "$RD/gate.out" 2>&1 & gate=$!
  await 120 waiting_on "$RD/gate.out" "$(admission_of cat) or" || fail "the gate never waited for the admission of cat"
  kill "-$how" -- "-$gate"; wait "$gate" 2>/dev/null || true
  [ "$(locks_on "$(admission_of cat)" WRITE)" = 1 ] || fail "$how: the interrupted gate left an admission lock: $(locks_on "$(admission_of cat)" WRITE) are held, init holds one"
  [ "$(locks_on "$(lock_of cat)" READ)" = 1 ] || fail "$how: the interrupted gate left a shared lock of cat"
  setsid bash "$ROOT/bin/init.sh" "$T1" --no-doctor > "$RD/init2.out" 2>&1 & second=$!
  await 120 waiting_on "$RD/init2.out" "$(admission_of cat)" || fail "the second init never waited for the admission"
  kill "-$how" -- "-$second"; wait "$second" 2>/dev/null || true
  [ "$(locks_on "$(admission_of cat)" WRITE)" = 1 ] || fail "$how: the interrupted init left an admission lock"
  reader_stop "x1-$how"
  await 120 gone "$first" || fail "$how: the first init did not finish once the reader ended"
  wait "$first" || fail "$how: the first init failed: $(tail -3 "$RD/init.out")"
  [ "$(git -C "$CAT" rev-parse HEAD)" = "$tip" ] || fail "$how: the copy was not moved"
  land cat "y$how"; bash "$ROOT/bin/init.sh" "$T3" --no-doctor > "$RD/init3.out" 2>&1 || fail "$how: a fresh move after the interrupted ones failed: $(tail -3 "$RD/init3.out")"
  reader_start "$ROOT" cat "x2-$how"; await 120 test -e "$RD/admitted-x2-$how" || fail "$how: a fresh reader was not admitted"; reader_stop "x2-$how"
  all_free cat dog Zed || fail "$how: a lock is held after all ended"
done
echo "  after TERM and after KILL of a gate and of an init that waited, one admission lock and one copy lock stay, the reader's, and a fresh move and a fresh reader proceed with no lock file removed"

section "a lock that cannot be opened, a checkout that fails, and a landing whose receipt does not hold refuse the gate and name the copy in init"
RD="$WORK/nb-rd-f"; mkdir -p "$RD"; set_wait 2
land dog fail; runs="$(wc -l < "$CHECK_LOG")"
mv "$(admission_of dog)" "$RD/admission-away"; mkdir "$(admission_of dog)"; work_on "$T2" f1
push_gate "$T2" f-1 "$RD/gate1.out" && fail "the gate went on although the admission lock of dog could not be opened"
grep -aq "REFUSED.*the copy $DOG cannot be read: the lock file $(admission_of dog) cannot be opened" "$RD/gate1.out" || fail "the refusal does not name the lock file (see $RD/gate1.out)"
bash "$ROOT/bin/init.sh" "$T3" --no-doctor > "$RD/init1.out" 2>&1 || fail "init failed as a whole"
grep -aq "may stand behind.*dog (the lock file $(admission_of dog) cannot be opened" "$RD/init1.out" || fail "init does not name dog and its lock file (see $RD/init1.out)"
rmdir "$(admission_of dog)"; mv "$RD/admission-away" "$(admission_of dog)"
gd="$(git -C "$DOG" rev-parse --absolute-git-dir)"; : > "$gd/index.lock"; work_on "$T2" f2
push_gate "$T2" f-2 "$RD/gate2.out" && fail "the gate went on although the checkout of dog failed"
grep -aq "REFUSED.*the copy $DOG could not move to origin/master: git checkout of origin/master in $DOG failed" "$RD/gate2.out" || fail "the refusal does not name the failed checkout (see $RD/gate2.out)"
bash "$ROOT/bin/init.sh" "$T3" --no-doctor > "$RD/init2.out" 2>&1 || fail "init failed as a whole"
grep -aq "may stand behind.*dog (git checkout of origin/master in $DOG failed" "$RD/init2.out" || fail "init does not name dog and its failed checkout (see $RD/init2.out)"
rm -f "$gd/index.lock"
[ "$(wc -l < "$CHECK_LOG")" = "$runs" ] || fail "a check ran although the admission lock or the checkout failed"
push_gate "$T2" f-3 "$RD/gate3.out" || fail "the gate after the failures was refused: $(tail -3 "$RD/gate3.out")"
echo "  an admission lock that cannot be opened and a checkout that git refuses stop the gate before its check and are named by it and by init, and the next gate passes"

section "a process that a move of init leaves running holds neither the admission nor the copy lock of the copy"
: > "$daemons"; land cat daemon
cat > "$gitwrap/git" <<WRAP
#!/usr/bin/env bash
case " \$* " in *" checkout "*) ( nohup sleep 120 >/dev/null 2>&1 & echo \$! >> "$daemons" ) ;; esac
exec "$(command -v git)" "\$@"
WRAP
daemon_move() {  # daemon_move <harness root>: init moves cat with a stand-in git that leaves a process running
  : > "$daemons"; set_wait 2
  PATH="$gitwrap:$PATH" bash "$1/bin/init.sh" "$T3" --no-doctor > "$WORK/nb-daemon-init.log" 2>&1 || fail "init failed: $(tail -3 "$WORK/nb-daemon-init.log")"
  spawned="$(wc -l < "$daemons" | tr -d ' ')"; kept=""
  flock -x -n "$(admission_of cat)" true || kept="$kept admission"; flock -x -n "$(lock_of cat)" true || kept="$kept copy"
  while read -r pid; do kill "$pid" 2>/dev/null || true; done < "$daemons"
}
daemon_move "$ROOT"
[ "$spawned" -ge 1 ] || fail "the case is not planted: the move left no process running"
[ -z "$kept" ] || fail "a process the move left running still holds a lock of cat:$kept"
land cat daemon2
mutant keeps-descriptors lib/neighbours.sh 's/^  for fd in \$NEIGHBOUR_FDS; do closing=.*$/  :/'
daemon_move "$WORK/mutant-keeps-descriptors"
[ -n "$kept" ] || fail "planted: a move whose children keep the descriptors of init was not found holding the admission lock, so this case cannot tell"
echo "  the process a checkout of init leaves running holds no lock once init ends, and a child that keeps the descriptors of init holds the admission lock, which is the planted defect"

section "two inits that make the same copy at the same moment both leave a complete copy, made once"
set_wait 600; RD="$WORK/nb-rd-k"; mkdir -p "$RD"
git -C "$F/dog" worktree remove --force "$DOG"; land dog made; dog_tip="$(git -C "$WORK/nb-dog.git" rev-parse master)"
bash "$ROOT/bin/init.sh" "$T2" --no-doctor > "$RD/k1.out" 2>&1 & first=$!
bash "$ROOT/bin/init.sh" "$T3" --no-doctor > "$RD/k2.out" 2>&1 & second=$!
wait "$first" || fail "the first creator failed: $(tail -3 "$RD/k1.out")"
wait "$second" || fail "the second creator failed: $(tail -3 "$RD/k2.out")"
[ "$(git -C "$DOG" rev-parse HEAD)" = "$dog_tip" ] && [ -z "$(git -C "$DOG" status --porcelain)" ] || fail "the copy that two inits made is not complete at the landed commit"
[ "$(git -C "$F/dog" worktree list --porcelain | grep -c "^worktree $DOG$")" = 1 ] || fail "the copy is registered other than once"
cat "$RD/k1.out" "$RD/k2.out" | grep -aq 'may stand behind\|cannot become' && fail "a creator reports a copy it could not make (see $RD/k1.out, $RD/k2.out)"
all_free cat dog Zed || fail "a lock is held after both creators ended"
echo "  two inits that make dog's copy together both succeed and the copy stands once, complete, at the commit that landed"

section "git worktree add runs the real shim and the real init: the new worktree is equipped and current once the readers admitted before it ended, and a second init waits for nothing"
RD="$WORK/nb-rd-w"; mkdir -p "$RD"; : > "$EV"
( cd "$F/app" && bash "$ROOT/bin/pre-push.sh" --install ) > "$RD/install.out" 2>&1 || fail "the shims could not be installed: $(tail -3 "$RD/install.out")"
[ -x "$F/app/.githooks/post-checkout" ] || fail "no executable post-checkout shim stands in the product"
reader_start "$ROOT" cat w1; await 120 test -e "$RD/admitted-w1" || fail "the reader was not admitted"
land cat shim; tip="$(git -C "$WORK/nb-cat.git" rev-parse master)"
W="$F/.worktrees/app/issue-9-new"
git -C "$F/app" worktree add -q -b issue-9-new "$W" > "$RD/wt.out" 2>&1 & adding=$!
await 120 waiting_on "$RD/wt.out" "" || fail "the init of the shim never waited for the reader: $(cat "$RD/wt.out")"
reader_start "$ROOT" cat w2; await 120 reader_decided w2 || fail "the later reader was neither admitted nor refused"
[ ! -e "$RD/admitted-w2" ] || fail "a later reader was admitted before the worktree got its copy"
reader_stop w1
await 120 gone "$adding" || fail "git worktree add did not end after the reader that came before it ended: $(cat "$RD/wt.out")"
wait "$adding" || fail "git worktree add failed: $(cat "$RD/wt.out")"
grep -aq 'may stand behind\|NOT complete' "$RD/wt.out" && fail "the new worktree is not complete: $(cat "$RD/wt.out")"
[ -f "$W/.ai-core/STAMP" ] || fail "the new worktree has no harness: $(cat "$RD/wt.out")"
[ "$(readlink "$F/.worktrees/app/cat")" = ../../.ai-core/neighbours/cat/origin-master ] && [ "$(cat "$W/../cat/marker")" = shim ] || fail "the new worktree reads cat through .. as $(cat "$W/../cat/marker" 2>&1), not at the landed commit"
[ "$(git -C "$CAT" rev-parse HEAD)" = "$tip" ] && [ -z "$(git -C "$CAT" status --porcelain)" ] || fail "the copy of cat does not stand clean at $tip"
await 120 test -e "$RD/admitted-w2" || fail "the later reader was never admitted"
grep -q "^w2 admitted at $tip$" "$EV" || fail "the later reader was admitted at another commit than $tip"
bash "$ROOT/bin/init.sh" "$W" --no-doctor > "$RD/again.out" 2>&1 & again=$!
await 120 gone "$again" || fail "the second init waited for the check that reads the copy: $(cat "$RD/again.out")"
wait "$again" || fail "the second init failed: $(tail -3 "$RD/again.out")"
waiting_on "$RD/again.out" "" && fail "the second init waited, though the copy was current"
reader_stop w2
echo "  the shim of the product ran the init of the harness in the worktree git made, which waited for the reader before it, not for the later one, and ended with the harness, the link and the copy at the landed commit; a second init finished beside a reader"

section "an init keeps no claim while it waits for the admission of a copy it did not claim, so two inits never wait for each other"
RD="$WORK/nb-rd-c"; mkdir -p "$RD"; set_wait 600
keeps_open() {  # keeps_open <pid> <file>: the process has the file open on one of its descriptors
  local fd; for fd in /proc/"$1"/fd/*; do [ "$(readlink "$fd" 2>/dev/null)" != "$2" ] || return 0; done; return 1
}
CIRCLED="init B waits for the admission of Zed and keeps its claim of cat, which init A waits for while it holds Zed"
# circle_run <harness root> <tag>: init B claims cat and stops at the read of dog, which a mover holds; then Zed lands, and
# init A claims Zed and waits for the claim of cat; then dog is free. Under C, B's links list Zed before cat. Sets CIRCLE to
# ok, or to the first thing that went wrong; both inits are stopped at the end.
CIRCLE=""
circle_run() {
  local root="$1" tag="$2" a b tc tz n=1200 status=0
  CIRCLE=ok
  bash "$root/bin/init.sh" "$T2" --no-doctor > "$RD/sync-$tag.out" 2>&1 || CIRCLE="the init that brings every copy up failed: $(tail -3 "$RD/sync-$tag.out")"
  land cat "c-$tag"; tc="$(git -C "$WORK/nb-cat.git" rev-parse master)"
  mover dog "$RD/free-dog-$tag"
  LC_ALL=C setsid bash "$root/bin/init.sh" "$T3" --no-doctor > "$RD/b-$tag.out" 2>&1 & b=$!
  await 120 waiting_on "$RD/b-$tag.out" "$(lock_of dog)" || CIRCLE="init B never stopped at the read of dog: $(tail -3 "$RD/b-$tag.out")"
  land Zed "c-$tag"; tz="$(git -C "$WORK/nb-Zed.git" rev-parse master)"
  LC_ALL=C setsid bash "$root/bin/init.sh" "$T2" --no-doctor > "$RD/a-$tag.out" 2>&1 & a=$!
  await 120 waiting_on "$RD/a-$tag.out" "$(admission_of cat)" || CIRCLE="init A never waited for the claim of cat: $(tail -3 "$RD/a-$tag.out")"
  : > "$RD/free-dog-$tag"; wait "$READER" 2>/dev/null || true
  until gone "$a" && gone "$b"; do
    if waiting_on "$RD/b-$tag.out" "$(admission_of Zed)" && keeps_open "$b" "$(admission_of cat)"; then CIRCLE="$CIRCLED"; break; fi
    n=$((n - 1)); [ "$n" -gt 0 ] || { CIRCLE="the two inits did not finish once dog was free"; break; }
    "$REAL_SLEEP" 0.1
  done
  if [ "$CIRCLE" = ok ]; then
    wait "$a" || status=$?; wait "$b" || status=$?
    [ "$status" -eq 0 ] || CIRCLE="an init ended with status $status: $(tail -2 "$RD/a-$tag.out" "$RD/b-$tag.out" | tr '\n' ' ')"
    cat "$RD/a-$tag.out" "$RD/b-$tag.out" | grep -aq 'may stand behind' && CIRCLE="an init reports a copy that may stand behind (see $RD/a-$tag.out, $RD/b-$tag.out)"
    [ "$(git -C "$CAT" rev-parse HEAD)" = "$tc" ] && [ "$(git -C "$F/.ai-core/neighbours/Zed/origin-master" rev-parse HEAD)" = "$tz" ] \
      || CIRCLE="cat or Zed does not stand at the commit that landed"
  fi
  stop_group "$a"; stop_group "$b"
  unlock_after_kill "$T2" "$T3"
}
unlock_after_kill() {  # unlock_after_kill <worktree>...: the lock an init that was stopped left on its worktree goes
  local w; for w in "$@"; do git -C "$F/app" worktree unlock "$w" 2>/dev/null || true; done
}
circle_run "$ROOT" g1
[ "$CIRCLE" = ok ] || fail "two inits that each claim a copy the other must move: $CIRCLE"
all_free cat dog Zed || fail "a lock is still held after the two inits ended"
mutant claimed-later bin/init.sh 's|^      for neighbour in "\${link_order\[@]}"; do$|      for neighbour in "$folder"/*/; do|'
circle_run "$WORK/mutant-claimed-later" g2
[ "$CIRCLE" = "$CIRCLED" ] || fail "planted: an init that refreshes its copies in the order of the folder did not wait for the admission of Zed while it kept its claim of cat: $CIRCLE"
echo "  init B refreshes the copy it claimed first and gives the claim up, so init A, which holds Zed and waits for cat, goes on, and both end with the copies at the landed commits; an init that refreshes Zed first, its claim of cat kept, waits for A, which waits for it, the planted defect"

section "a copy init claimed, whose origin renamed its default branch since, is made under that claim, and the claim ends with it"
RD="$WORK/nb-rd-r"; mkdir -p "$RD"; set_wait 600
SELF_WAITED="init B waits for the admission of cat, which its own claim holds"
CLAIM_KEPT="init B reads Zed, which it did not claim, and keeps its claim of cat"
stopped_after_cat() { waiting_on "$1" "$(lock_of Zed)" || waiting_on "$1" "$(admission_of cat)"; }
# rename_run <harness root> <tag>: init B claims cat and stops at the read of dog; cat's origin then publishes trunk-<tag>
# as its default branch, which a fetch tells the checkout of cat; once dog is free, B makes the copy of that branch and
# stops at the read of Zed, a copy it did not claim. Sets RENAME to ok, or to the first thing that went wrong.
RENAME=""
rename_run() {
  local root="$1" tag="$2" b dog_mover zed_mover status=0
  RENAME=ok
  bash "$root/bin/init.sh" "$T2" --no-doctor > "$RD/sync-$tag.out" 2>&1 || RENAME="the init that brings every copy up failed: $(tail -3 "$RD/sync-$tag.out")"
  land cat "r-$tag"
  mover dog "$RD/free-dog-$tag"; dog_mover=$READER
  LC_ALL=C setsid bash "$root/bin/init.sh" "$T3" --no-doctor > "$RD/b-$tag.out" 2>&1 & b=$!
  await 120 waiting_on "$RD/b-$tag.out" "$(lock_of dog)" || RENAME="init B never stopped at the read of dog: $(tail -3 "$RD/b-$tag.out")"
  git -C "$WORK/nb-cat.git" branch "trunk-$tag" master && git -C "$WORK/nb-cat.git" symbolic-ref HEAD "refs/heads/trunk-$tag"
  git -C "$F/cat" fetch -q origin && git -C "$F/cat" remote set-head origin --auto > /dev/null
  mover Zed "$RD/free-zed-$tag"; zed_mover=$READER
  : > "$RD/free-dog-$tag"; wait "$dog_mover" 2>/dev/null || true
  await 120 stopped_after_cat "$RD/b-$tag.out" || RENAME="init B reached neither the read of Zed nor a wait for cat: $(tail -3 "$RD/b-$tag.out")"
  if waiting_on "$RD/b-$tag.out" "$(admission_of cat)"; then RENAME="$SELF_WAITED"
  elif keeps_open "$b" "$(admission_of cat)"; then RENAME="$CLAIM_KEPT"; fi
  : > "$RD/free-zed-$tag"; wait "$zed_mover" 2>/dev/null || true
  if [ "$RENAME" = ok ]; then
    await 120 gone "$b" || RENAME="init B did not finish once Zed was free"
    wait "$b" || status=$?
    [ "$status" -eq 0 ] || RENAME="init B ended with status $status: $(tail -3 "$RD/b-$tag.out")"
    [ "$(readlink "$F/.worktrees/app/cat")" = "../../.ai-core/neighbours/cat/origin-trunk-$tag" ] || RENAME="the link of cat leads to $(readlink "$F/.worktrees/app/cat"), not to the copy of trunk-$tag"
    grep -aq 'may stand behind\|cannot become' "$RD/b-$tag.out" && RENAME="init B names cat stale or blocked (see $RD/b-$tag.out)"
  fi
  stop_group "$b"; unlock_after_kill "$T3"
  git -C "$WORK/nb-cat.git" symbolic-ref HEAD refs/heads/master; git -C "$F/cat" remote set-head origin --auto > /dev/null
}
rename_run "$ROOT" h1
[ "$RENAME" = ok ] || fail "a claimed copy whose origin renamed its default branch: $RENAME"
all_free cat dog Zed || fail "a lock is still held after the init that followed the renamed branch ended"
mutant claim-ignored lib/neighbours.sh 's/{ neighbour_claimed "\$2" || {/{ false || {/'
rename_run "$WORK/mutant-claim-ignored" h2
[ "$RENAME" = "$SELF_WAITED" ] || fail "planted: a copy made without regard to the claim of init did not wait for that claim: $RENAME"
mutant claim-kept bin/init.sh 's/; neighbour_pending_end "\$name"$//; s/^\(      outcome="\$(neighbour_refresh_copy .*\)$/\1; neighbour_pending_end "$2"/'
rename_run "$WORK/mutant-claim-kept" h3
[ "$RENAME" = "$CLAIM_KEPT" ] || fail "planted: a claim that ends only after a refresh was not found kept while init read Zed: $RENAME"
echo "  init makes the copy of the renamed branch under its own claim and gives the claim up before it reads Zed; a copy made beside the claim waits for it, and a claim that ends only after a refresh is kept, the planted defects"
exit 0
