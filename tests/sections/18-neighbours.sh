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
mutant keeps-lock lib/neighbours.sh '/^    \[ -n "\$blocked" \] || return 0$/{n;s/neighbours_release/:/;}; s/NEIGHBOUR_FDS=" 40"/NEIGHBOUR_FDS="$NEIGHBOUR_FDS 99"/; s/neighbour_open 40 /neighbour_open 99 /; s/neighbour_wait_flock 40 /neighbour_wait_flock 99 /g'
probe_wait "$WORK/mutant-keeps-lock"
[ "$(cat "$WORK/nb-probe")" = held ] || fail "planted: a gate that keeps cat's lock through the wait was not found holding it, so this case cannot tell"
echo "  the gate of today, which keeps the lock of cat through the wait for dog, is the planted defect: its mover of cat finds the lock held"
land dog ten-b
dog_before="$(git -C "$DOG" rev-parse HEAD)"
mutant moves-under-reader lib/neighbours.sh 's/neighbour_wait_flock 40 "\$NEIGHBOUR_DIR\/.copy.lock" exclusive/neighbour_wait_flock 40 "$NEIGHBOUR_DIR\/.copy.lock" shared/'
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
  on_clock 1000 "flock -x -n '$(lock_of dog)' true && echo free > '$WORK/nb-probe' || echo held > '$WORK/nb-probe'; echo '$2' > '$WORK/nb-dog-pusher/marker'; git -C '$WORK/nb-dog-pusher' -c user.email=check@localhost -c user.name=check commit -q -am '$2'; git -C '$WORK/nb-dog-pusher' push -q origin master"
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
echo "  the gate of today, which holds the copies for a receipt through the wait, is the planted defect: its mover of dog finds the lock held"

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
exit 0
