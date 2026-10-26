#!/usr/bin/env bash
# The push gate brings the published copy of a neighbour to its origin's newest commit before the check reads it,
# and keeps it there while the check runs; one section of the suite, run by tests/check.sh with the others
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

command -v flock >/dev/null 2>&1 || fail "flock (util-linux) is not installed, and the copies of the neighbours are locked with it"
export PATH="$ROOT/bin:$PATH" PRE_PUSH_LOAD_LIMIT=0
F="$WORK/nb"; CHECK_LOG="$WORK/nb-check.log"; export CHECK_LOG; : > "$CHECK_LOG"
mkdir -p "$F/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$F/.ai-core/config.env"
git_as() { git -c user.email=check@localhost -c user.name=check "$@"; }

# neighbours: cat and dog publish a marker, eel has no origin
for r in cat dog; do
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
if [ -n "${CHECK_HOLD:-}" ]; then
  : > "$CHECK_HOLD.started"
  while [ ! -e "$CHECK_HOLD" ]; do sleep 0.1; done
  echo "$(cat ../cat/marker) $(cat ../dog/marker) again" >> "$CHECK_LOG"
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

section "two gates read one copy together; a copy a check reads is moved by nobody, and the next gate sees the later commit"
push_gate "$T1" issue-2-y "$F-push6.log" || fail "the push after the repairs was refused: $(tail -5 "$F-push6.log")"
cat_one="$(git -C "$CAT" rev-parse HEAD)"
work_on "$T2" e
HOLD="$WORK/nb-hold"; rm -f "$HOLD" "$HOLD.started"
work_on "$T1" f
started="$(wc -l < "$CHECK_LOG")"
CHECK_HOLD="$HOLD" git -C "$T1" push origin HEAD:refs/heads/issue-2-y > "$F-hold1.log" 2>&1 &
holder=$!
for _ in $(seq 1 100); do [ -e "$HOLD.started" ] && break; sleep 0.1; done
[ -e "$HOLD.started" ] || fail "the first gate never started its check (see $F-hold1.log)"
# the same tip is read by a second gate at the same moment: shared, so it does not wait for the first
push_gate "$T2" issue-3-z "$F-hold2.log" || fail "a second gate could not read the copy the first one reads: $(tail -5 "$F-hold2.log")"
# the origin moves while the first check reads: a second gate cannot move the copy under it, and says so
land cat four
work_on "$T2" g
push_gate "$T2" issue-3-z "$F-hold3.log" && fail "a gate moved the copy under a check that still read it"
grep -aq "REFUSED.*the copy $CAT cannot move to origin/master, as a check still reads it" "$F-hold3.log" || fail "the refusal does not say that a check reads the copy (see $F-hold3.log)"
bash "$ROOT/bin/init.sh" "$T2" --no-doctor > "$F-init5.log" 2>&1 || fail "init beside a reading gate failed: $(tail -3 "$F-init5.log")"
grep -aq 'may stand behind.*cat (the lock .* is held by another gate or init' "$F-init5.log" || fail "init does not name the copy it could not move under a reading gate (see $F-init5.log)"
[ "$(git -C "$CAT" rev-parse HEAD)" = "$cat_one" ] || fail "the copy moved under a running check"
: > "$HOLD"; wait "$holder" || fail "the first gate was refused: $(tail -5 "$F-hold1.log")"
[ "$(sed -n "$((started + 1))p" "$CHECK_LOG")" = "$(grep ' again$' "$CHECK_LOG" | tail -1 | sed 's/ again$//')" ] || fail "the check saw the copy change between its two reads: $(tail -4 "$CHECK_LOG")"
push_gate "$T2" issue-3-z "$F-hold4.log" || fail "the next gate was refused once the check ended: $(tail -5 "$F-hold4.log")"
[ "$(cut -d' ' -f1 <<< "$(last_check)")" = four ] || fail "the next gate did not observe the later commit: $(last_check)"
echo "  a second gate reads the same tip beside the first, none moves a copy under a running check, init names the copy it could not move, and the next gate observes the later commit"
exit 0
