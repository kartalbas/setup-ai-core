#!/usr/bin/env bash
# The landing lock of a clone (lib/landing-lock.sh) and the run log it measures a deadline from. What is pinned: a landing records
# how long it held the lock, in a row of the run log, when it gives the lock up; the allowance of a wait is one and a half times the
# longest hold of the repository in the last 14 days, a hold of another repository, a row older than that, a check, a row without
# seconds and an unreadable log never set it; it is never less than the configured allowance, the sum of one and a half times the
# longest check on record (or the initial value), the wait for the load and, under CI_GATE=public, the wait for the CI, which is the
# allowance where no hold is recorded or the recorded ones make less, and it says so; every wait has a deadline in every state; the deadline counts per holder from the moment that holder took the
# lock, so three landings at once each wait for one holder at a time; the lock names its holder, the time, and the repository; it
# is released only by the process that wrote it. Every case runs in a scratch clone with HOME and AI_CORE_HOME in a scratch folder.
#
#   bash tests/landing-lock.test.sh

set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fake="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$fake"' EXIT
export HOME="$fake/home" AI_CORE_HOME="$fake/home"
mkdir -p "$HOME/.ai-core"
unset AI_CORE_INTEGRATE_WAIT
failed=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}
yesno() { if "$@" >/dev/null 2>&1; then echo yes; else echo no; fi; }

clone="$fake/clone"
git -c init.defaultBranch=master init -q "$clone"
git -C "$clone" remote add origin "https://example.invalid/example-org/example-repo.git"
mkdir -p "$clone/.ai-core"
repository=example-org/example-repo
log="$AI_CORE_HOME/.ai-core/pre-push-runs.tsv"
lock="$clone/.git/ai-core-landing"
header=$'time\trepository\tworktree\tcommit\tverdict\tseconds\tlast line\tload at check start'
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
old="$(date -u -d '@'"$(( $(date +%s) - 30 * 86400 ))" +%Y-%m-%dT%H:%M:%SZ)"
# row <time> <repository> <verdict> <seconds>
row() { printf '%s\t%s\t/somewhere\taaaa\t%s\t%s\tlast line\t0.5\n' "$1" "$2" "$3" "$4"; }
# log_of <row>...: the run log holds these rows
log_of() { { printf '%s\n' "$header"; printf '%s\n' "$@"; } > "$log"; }
# settings <line>...: the config.env of the clone
settings() { printf '%s\n' "$@" > "$clone/.ai-core/config.env"; }
# allowance <library>: what that library makes of the log and the settings for the repository, or its refusal
allowance() { ( . "$1"; if landing_lock_allowance "$clone" "${2-$repository}"; then echo "$LANDING_LOCK_SECONDS"; else echo "refused: $LANDING_LOCK_REFUSAL"; fi ); }
basis() { ( . "$1"; landing_lock_allowance "$clone" "${2-$repository}"; echo "$LANDING_LOCK_BASIS" ); }
# plant_lock <pid> <issue> <branch> <seconds ago>: the lock of a landing that took it that long ago
plant_lock() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$(( $(date +%s) - $4 ))" "$repository" > "$lock"; }
lib="$root/lib/landing-lock.sh"
# longest_hold <library folder>: the longest hold of the repository that the run log reader of that folder finds
longest_hold() { ( . "$1/pre-push-runs.sh"; gate_runs_repository_longest "$log" "$repository" hold ); }

echo 'the longest hold of the repository in the last 14 days is read from the run log; one and a half times it is the allowance where that is no less than the configured one'
log_of "$(row "$now" Example-Org/Example-Repo 'landing lock' 100)" "$(row "$now" $repository 'landing lock' 40)" "$(row "$now" $repository 'landing lock' 7)"
check 'the longest of 100, 40 and 7 seconds, in either case of the name, is 100' 100 "$(longest_hold "$root/lib")"
log_of "$(row "$now" $repository 'landing lock' 10)" "$(row "$now" example-org/other 'landing lock' 5000)" "$(row "$old" $repository 'landing lock' 4000)" \
  "$(row "$now" $repository green 5000)" "$(row "$now" $repository 'landing lock' -)" "$(row "$now" $repository 'landing lock' abc)"
check 'another repository, a row older than 14 days, a check, and holds without seconds set nothing: 10' 10 "$(longest_hold "$root/lib")"
check 'the timing of the gate counts no hold among its rows' 'read 1 5000 0 2 3 1' "$( . "$root/lib/pre-push-runs.sh"; gate_runs_timing "$log"; echo "$GATE_RUNS_STATE $GATE_RUNS_TIMED $GATE_RUNS_LONGEST $GATE_RUNS_UNTIMED $GATE_RUNS_UNREADABLE $GATE_RUNS_ROWS $GATE_RUNS_OLDER" )"
settings 'CI_GATE="none"' 'PRE_PUSH_LOAD_WAIT_SECONDS="0"'
log_of "$(row "$now" $repository green 1)" "$(row "$now" $repository 'landing lock' 100)"
check 'a check of 1 second and no load wait configure 2 seconds: the hold of 100 makes 150' 150 "$(allowance "$lib")"
check 'the basis says measured, and names the seconds, the repository and the configured seconds' "measured: one and a half times the 100 seconds of the longest hold of the landing lock of $repository in the last 14 days of $log, no less than the 2 seconds configured" "$(basis "$lib")"
log_of "$(row "$now" $repository green 1)" "$(row "$now" $repository 'landing lock' 1)"
check 'an odd number rounds up, and a measured allowance equal to the configured one is the measured one' '2 measured' "$(allowance "$lib") $(basis "$lib" | cut -d: -f1)"

echo 'a recorded hold never makes the allowance less than the configured one: a refused landing records a short hold, and a holder that waits for the load holds longer'
settings 'CI_GATE="none"' 'PRE_PUSH_LOAD_WAIT_SECONDS="300"'
log_of "$(row "$now" $repository green 60)" "$(row "$now" $repository 'landing lock' 1)"
check 'a hold of 1 second, a check of 60 and a load wait of 300: 90 and 300 make 390, not 2' 390 "$(allowance "$lib")"
check 'it says configured, names the measured seconds and why they do not count' "configured, not measured (one and a half times the 1 seconds of the longest hold of the landing lock of $repository in the last 14 days of $log make 2 seconds, less than the bounds a holder may spend under the lock): one and a half times the 60 seconds of the longest check of $repository, PRE_PUSH_LOAD_WAIT_SECONDS 300" "$(basis "$lib")"
log_of "$(row "$now" $repository green 60)" "$(row "$now" $repository 'landing lock' 1000)"
check 'innocent: a hold of 1000 seconds, longer than the bounds, makes 1500' 1500 "$(allowance "$lib")"
sed 's/^    if \[ "\$measured" -ge "\$configured" \]; then$/    if true; then/' "$lib" > "$fake/planted-no-floor.sh"
mkdir -p "$fake/planted-no-floor"; cp "$root/lib/"*.sh "$fake/planted-no-floor/"; cp "$fake/planted-no-floor.sh" "$fake/planted-no-floor/landing-lock.sh"
cmp -s "$lib" "$fake/planted-no-floor/landing-lock.sh" && { echo "  FAIL the planted copy without the floor equals lib/landing-lock.sh"; failed=$((failed + 1)); }
log_of "$(row "$now" $repository green 60)" "$(row "$now" $repository 'landing lock' 1)"
check 'planted: a copy that takes the measured hold alone makes 2 of the hold of 1 second' 2 "$(allowance "$fake/planted-no-floor/landing-lock.sh")"

echo 'planted: a reader that takes the longest hold of any repository, one that counts rows of any age, and one that counts checks as holds'
planted() {  # planted <name> <sed expression>
  sed "$2" "$root/lib/pre-push-runs.sh" > "$fake/pre-push-runs-$1.sh"
  cmp -s "$root/lib/pre-push-runs.sh" "$fake/pre-push-runs-$1.sh" && { echo "  FAIL the planted copy $1 equals lib/pre-push-runs.sh"; failed=$((failed + 1)); return; }
  mkdir -p "$fake/planted-$1"; cp "$root/lib/"*.sh "$fake/planted-$1/"; cp "$fake/pre-push-runs-$1.sh" "$fake/planted-$1/pre-push-runs.sh"
}
log_of "$(row "$now" $repository 'landing lock' 10)" "$(row "$now" example-org/other 'landing lock' 5000)" "$(row "$old" $repository 'landing lock' 4000)" "$(row "$now" $repository green 3000)"
planted any-repository 's/ && tolower(\$2) == tolower(repository)//'
planted any-age 's/NF == 8 && \$1 >= start/NF == 8/'
planted check-as-hold 's/(kind == "hold" ? \$5 == "landing lock" : (\$5 == "green" || \$5 == "red"))/(\$5 == "landing lock" || \$5 == "green")/'
check 'planted: a reader of every repository takes 5000 seconds' 5000 "$(longest_hold "$fake/planted-any-repository")"
check 'planted: a reader of every age takes 4000 seconds' 4000 "$(longest_hold "$fake/planted-any-age")"
check 'planted: a reader that counts a check as a hold takes its 3000 seconds' 3000 "$(longest_hold "$fake/planted-check-as-hold")"
check 'the real reader of the same log: 10 seconds' 10 "$(longest_hold "$root/lib")"

echo 'where no hold is recorded the allowance is configured: the check, the wait for the load, and under CI_GATE=public the wait for the CI'
rm -f "$log"; settings 'CI_GATE="none"' 'PRE_PUSH_LOAD_WAIT_SECONDS="300"'
check 'no log, no check on record: 1.5 times the initial 1320 seconds and the 300 of the load wait make 2280' 2280 "$(allowance "$lib")"
check 'it says configured, not measured, and why, and names the settings' "configured, not measured (no run log stands at $log yet): one and a half times the 1320 seconds of NEIGHBOUR_INITIAL_CHECK_SECONDS, as no check of the repository is on record, PRE_PUSH_LOAD_WAIT_SECONDS 300" "$(basis "$lib")"
check 'no repository named by origin: the same, and it says so' "configured, not measured (origin names no repository, so no hold of it is recorded): one and a half times the 1320 seconds of NEIGHBOUR_INITIAL_CHECK_SECONDS, as no check of the repository is on record, PRE_PUSH_LOAD_WAIT_SECONDS 300" "$(basis "$lib" '')"
log_of
check 'a log with no row of the repository: 2280 as well' 2280 "$(allowance "$lib")"
check 'and it says there is no hold in the log' "configured, not measured (no hold of the landing lock of $repository is recorded in the last 14 days of $log): one and a half times the 1320 seconds of NEIGHBOUR_INITIAL_CHECK_SECONDS, as no check of the repository is on record, PRE_PUSH_LOAD_WAIT_SECONDS 300" "$(basis "$lib")"
rm -f "$log"; mkdir "$log"
check 'a log that cannot be read: 2280 as well' 2280 "$(allowance "$lib")"
check 'and it says so'               "configured, not measured (the run log $log cannot be read): one and a half times the 1320 seconds of NEIGHBOUR_INITIAL_CHECK_SECONDS, as no check of the repository is on record, PRE_PUSH_LOAD_WAIT_SECONDS 300" "$(basis "$lib")"
rmdir "$log"
log_of "$(row "$now" $repository green 60)"
check 'a recorded check of 60 seconds and a holder that waits 300 seconds for the load: 90 and 300 make 390' 390 "$(allowance "$lib")"
check 'it names the check and the load wait' "configured, not measured (no hold of the landing lock of $repository is recorded in the last 14 days of $log): one and a half times the 60 seconds of the longest check of $repository, PRE_PUSH_LOAD_WAIT_SECONDS 300" "$(basis "$lib")"
settings 'CI_GATE="none"' 'PRE_PUSH_LOAD_WAIT_SECONDS="0"'
check 'the load wait set to 0 adds nothing: 90' 90 "$(allowance "$lib")"
rm -f "$clone/.ai-core/config.env"
check 'no settings: the load wait is 300 and CI_GATE is public with 1800 seconds for the CI: 90, 300 and 1800 make 2190' 2190 "$(allowance "$lib")"
check 'it names the CI wait'         "configured, not measured (no hold of the landing lock of $repository is recorded in the last 14 days of $log): one and a half times the 60 seconds of the longest check of $repository, PRE_PUSH_LOAD_WAIT_SECONDS 300, AI_CORE_INTEGRATE_WAIT 1800 because CI_GATE is public" "$(basis "$lib")"
check 'a public holder whose CI wait of 600 seconds outlasts its check: 90, 300 and 600 make 990' 990 "$(AI_CORE_INTEGRATE_WAIT=600 allowance "$lib")"
settings 'CI_GATE="none"'
check 'innocent: where the repository lands on the push gate alone the CI wait is no part of it: 90 and 300 make 390' 390 "$(AI_CORE_INTEGRATE_WAIT=600 allowance "$lib")"
settings 'CI_GATE="Public"' 'AI_CORE_INTEGRATE_WAIT="50"' 'PRE_PUSH_LOAD_WAIT_SECONDS="10"'
check 'the settings of the checkout are read: 90, 10 and 50 make 150' 150 "$(allowance "$lib")"
settings 'CI_GATE="public"' 'PRE_PUSH_LOAD_WAIT_SECONDS="soon"'
check 'a load wait that is no number refuses and names the key' "refused: PRE_PUSH_LOAD_WAIT_SECONDS is 'soon' in the settings of $clone; it is a whole number of seconds" "$(allowance "$lib")"
settings 'CI_GATE="sometimes"'
check 'a CI_GATE that is neither public nor none refuses and names the key, in the words of the landings' "refused: nothing landed: CI_GATE is 'sometimes' in the config.env of the project; it is public or none" "$(allowance "$lib")"
settings 'CI_GATE="none"' 'PRE_PUSH_LOAD_WAIT_SECONDS="0"'

echo 'the lock names its holder, the time it took it and the repository; only the process that wrote it releases it, and the release records the hold'
rm -f "$log"
sleep 300 & holder=$!
bash "$lib" take "$clone" "$holder" "$repository#1" issue-1-holder 2>/dev/null
check 'the file holds the process, the issue, the branch and the repository' "$holder"$'\t'"$repository#1"$'\t'"issue-1-holder"$'\t'"$repository" "$(cut -f1-3,5 "$lock")"
since="$(cut -f4 "$lock")"
check 'and the time it was taken, in epoch seconds, now' yes "$([ "$since" -le "$(date +%s)" ] && [ "$since" -ge $(( $(date +%s) - 20 )) ] && echo yes || echo no)"
bash "$lib" release "$clone" 999999
check 'another process releases nothing' yes "$([ -e "$lock" ] && echo yes || echo no)"
check 'and records no hold'          no "$([ -e "$log" ] && echo yes || echo no)"
plant_lock "$holder" "$repository#1" issue-1-holder 7
bash "$lib" release "$clone" "$holder"
check 'the holder releases it'       no "$([ -e "$lock" ] && echo yes || echo no)"
check 'the log was made with its header' "$header" "$(head -n1 "$log")"
hold_row="$(sed -n 2p "$log" | cut -f2-8)"
check 'one row records the hold: repository, worktree, verdict, who' "$repository"$'\t'"$clone"$'\t''-'$'\t''landing lock'$'\t'"$repository#1 on issue-1-holder"$'\t''-' "$(cut -f1-4,6-7 <<< "$hold_row")"
hold_seconds="$(cut -f5 <<< "$hold_row")"
# The release comes a moment after the take planted 7 seconds back, so a second boundary may pass between them.
check 'and its seconds from the planted take: 7 or 8' yes "$(case "$hold_seconds" in 7|8) echo yes ;; *) echo "no, $hold_seconds" ;; esac)"
check 'and the longest hold of the repository is that hold' "$hold_seconds" "$(longest_hold "$root/lib")"
printf '%s\t%s\t%s\n' "$holder" "$repository#2" issue-2-older > "$lock"
bash "$lib" release "$clone" "$holder"
check 'innocent: a lock of an older version names no time and no repository, is released and records nothing' '2 no' "$(wc -l < "$log" | tr -d ' ') $([ -e "$lock" ] && echo yes || echo no)"
rm -f "$log"; mkdir "$log"; plant_lock "$holder" "$repository#3" issue-3-holder 1
out="$(bash "$lib" release "$clone" "$holder" 2>&1)"; rc=$?
check 'a hold that cannot be recorded: exit 1, the lock is gone, and it says so' "1 no yes" "$rc $([ -e "$lock" ] && echo yes || echo no) $(case "$out" in *"the landing lock was released, but its hold of "[12]" seconds could not be recorded in $log"*) echo yes ;; *) echo no ;; esac)"
rmdir "$log"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

echo 'a second landing waits for each holder up to the allowance counted from the moment that holder took the lock'
settings 'CI_GATE="none"' 'PRE_PUSH_LOAD_WAIT_SECONDS="0"'
log_of "$(row "$now" $repository green 1)" "$(row "$now" $repository 'landing lock' 1)"
sleep 300 & holder=$!
plant_lock "$holder" "$repository#1" issue-1-holder 5
out="$(bash "$lib" take "$clone" "$$" "$repository#2" issue-2-second 2>&1)"; rc=$?
check 'a holder that held it 5 seconds against an allowance of 2: exit 1' 1 "$rc"
check 'the waiting line names the holder, since when it holds the lock and when its deadline is' yes "$(grep -qE "^waiting: $repository#1 on issue-1-holder holds the lock since [0-9T:Z-]+ \(process $holder\); this one lands after it\$" <<< "$out" && grep -qE '^deadline: [0-9T:Z-]+ for this holder, 2 seconds after it took the lock; measured: one and a half times the 1 seconds of the longest hold' <<< "$out" && echo yes || echo no)"
check 'the refusal names the holder, when it took the lock and how long it held it' yes "$(grep -qE "^nothing landed: the landing lock is still held by $repository#1 on issue-1-holder \(process $holder\), which took it at [0-9T:Z-]+ and held it [0-9]+ seconds, longer than the 2 seconds of its deadline \(measured: " <<< "$out" && echo yes || echo no)"
check 'the lock of the holder stands' "$holder" "$(cut -f1 "$lock")"
log_of "$(row "$now" $repository green 1)" "$(row "$now" $repository 'landing lock' 100)"
plant_lock "$holder" "$repository#1" issue-1-holder 5
( bash "$lib" take "$clone" "$$" "$repository#2" issue-2-second > "$fake/waits.out" 2>&1; echo $? > "$fake/waits.rc" ) & waiter=$!
for _ in $(seq 1 60); do grep -q '^deadline: ' "$fake/waits.out" 2>/dev/null && break; sleep 0.25; done
sleep 1
check 'innocent: a holder that held it 5 seconds against an allowance of 150 is waited for' yes "$([ ! -e "$fake/waits.rc" ] && echo yes || echo no)"
rm -f "$lock"; wait "$waiter"
check 'and the landing takes the lock once it is released' "0 $$" "$(cat "$fake/waits.rc") $(cut -f1 "$lock")"
rm -f "$lock" "$fake/waits.rc"

echo 'a public holder whose CI wait outlasts its check holds the lock for longer than the check: the landing behind it waits on, and where the CI is no part of the landing it does not'
# behind_holder <seconds> [<env assignment>]: a landing takes the lock in the background, behind a holder that took it 1 second ago; once the
# landing names its deadline, the holder keeps the lock for that many more seconds, and the landing's exit status is left in waits.rc
behind_holder() {
  local waiter
  rm -f "$fake/waits.rc"; : > "$fake/waits.out"
  plant_lock "$holder" "$repository#1" issue-1-ci 1
  ( env ${2:+"$2"} bash "$lib" take "$clone" "$$" "$repository#2" issue-2-second > "$fake/waits.out" 2>&1; echo $? > "$fake/waits.rc" ) & waiter=$!
  for _ in $(seq 1 60); do grep -q '^deadline: ' "$fake/waits.out" 2>/dev/null && break; sleep 0.25; done
  sleep "$1"
  rm -f "$lock"; wait "$waiter"
}
log_of "$(row "$now" $repository green 1)"
settings 'PRE_PUSH_LOAD_WAIT_SECONDS="0"'
behind_holder 5 AI_CORE_INTEGRATE_WAIT=60
check 'CI_GATE public: a CI wait of up to 60 seconds, a check of 1: the landing waited the 5 seconds and took the lock' "0 $$" "$(cat "$fake/waits.rc") $(cut -f1 "$lock")"
check 'its deadline names the CI wait' yes "$(grep -qE '^deadline: [0-9T:Z-]+ for this holder, 62 seconds after it took the lock; configured, not measured .*, AI_CORE_INTEGRATE_WAIT 60 because CI_GATE is public$' "$fake/waits.out" && echo yes || echo no)"
rm -f "$lock"
settings 'CI_GATE="none"' 'PRE_PUSH_LOAD_WAIT_SECONDS="0"'
behind_holder 5 AI_CORE_INTEGRATE_WAIT=60
check 'innocent: CI_GATE none, the CI is no part of the landing: the same holder is stopped at 2 seconds, exit 1' 1 "$(cat "$fake/waits.rc")"
rm -f "$lock"

echo 'a refused landing recorded a hold of 1 second, and the next holder waits for the load: the landing behind it waits on'
log_of "$(row "$now" $repository green 1)" "$(row "$now" $repository 'landing lock' 1)"
settings 'CI_GATE="none"' 'PRE_PUSH_LOAD_WAIT_SECONDS="30"'
behind_holder 5
check 'the holder keeps the lock 6 seconds against the 2 of the load wait of 30 and the check of 1: the landing took the lock' "0 $$" "$(cat "$fake/waits.rc") $(cut -f1 "$lock")"
check 'its deadline is configured, and names the hold that made fewer' yes "$(grep -qE '^deadline: [0-9T:Z-]+ for this holder, 32 seconds after it took the lock; configured, not measured \(one and a half times the 1 seconds of the longest hold .* make 2 seconds, less than the bounds a holder may spend under the lock\)' "$fake/waits.out" && echo yes || echo no)"
rm -f "$lock"
lib_real="$lib"; lib="$fake/planted-no-floor/landing-lock.sh"
behind_holder 5
lib="$lib_real"
check 'planted: a copy that takes the measured hold alone stops the landing at 2 seconds while the holder works, exit 1' 1 "$(cat "$fake/waits.rc")"
rm -f "$lock"; settings 'CI_GATE="none"' 'PRE_PUSH_LOAD_WAIT_SECONDS="0"'

echo 'a lock of an older version names no time: the count starts where this wait first saw it'
log_of "$(row "$now" $repository green 1)" "$(row "$now" $repository 'landing lock' 1)"
printf '%s\t%s\t%s\n' "$holder" "$repository#1" issue-1-holder > "$lock"
out="$(timeout 30 bash "$lib" take "$clone" "$$" "$repository#2" issue-2-second 2>&1)"; rc=$?
check 'it stops at the deadline, not never: exit 1' 1 "$rc"
check 'it says its lock names no time' yes "$(grep -qF '(its lock names no time, so counted from now)' <<< "$out" && echo yes || echo no)"
rm -f "$lock"

echo 'no hold of the repository is recorded and a live holder hangs: the wait ends at the configured deadline'
log_of
settings 'CI_GATE="none"' 'PRE_PUSH_LOAD_WAIT_SECONDS="0"'
plant_lock "$holder" "$repository#1" issue-1-hangs 0
cat > "$fake/take-with-initial-check.sh" <<'SCRIPT'
. "$1"; shift
NEIGHBOUR_INITIAL_CHECK_SECONDS=1
landing_lock_take "$@" || { echo "$LANDING_LOCK_REFUSAL"; exit 1; }
SCRIPT
out="$(timeout 30 bash "$fake/take-with-initial-check.sh" "$lib" "$clone" "$$" "$repository#2" issue-2-second "$repository" 2>&1)"; rc=$?
check 'exit 1, not 124 (the timeout)' 1 "$rc"
check 'the deadline line says configured, not measured, and from which settings' yes "$(grep -qE "^deadline: [0-9T:Z-]+ for this holder, 2 seconds after it took the lock; configured, not measured \(no hold of the landing lock of $repository is recorded in the last 14 days of $log\): one and a half times the 1 seconds of NEIGHBOUR_INITIAL_CHECK_SECONDS, as no check of the repository is on record, PRE_PUSH_LOAD_WAIT_SECONDS 0\$" <<< "$out" && echo yes || echo no)"
check 'the refusal names the hung holder' yes "$(grep -qE "^nothing landed: the landing lock is still held by $repository#1 on issue-1-hangs \(process $holder\)" <<< "$out" && echo yes || echo no)"
rm -f "$lock"

echo 'three landings at once, each holder holding just under the allowance: each waits for one holder at a time'
log_of "$(row "$now" $repository 'landing lock' 3)" "$(row "$now" $repository green 3)"
# landing <name>: takes the lock, holds it 4 seconds against an allowance of 5, gives it up
landing() { bash -c 'bash "$0" take "$1" "$$" "$2" "$3" >/dev/null 2>&1 || exit 1; sleep 4; bash "$0" release "$1" "$$"' "$lib" "$clone" "$repository#$1" "issue-$1-landing"; }
rcs="$fake/three"; rm -f "$rcs".*
pids=""; for n in 11 12 13; do ( landing "$n"; echo $? > "$rcs.$n" ) & pids="$pids $!"; done
wait $pids
check 'the three landings all took the lock and gave it up' '0 0 0' "$(cat "$rcs.11") $(cat "$rcs.12") $(cat "$rcs.13")"
check 'and each recorded its hold of at least 4 seconds, in whole seconds from its take to its release' 3 "$(awk -F'\t' '$5 == "landing lock" && $6 >= 4' "$log" | wc -l | tr -d ' ')"
echo 'planted: a deadline counted from the start of the wait stops the third landing'
sed -e 's/^      holder_since="\$(landing_lock_field "\$holder" 4)"$/      holder_since=""/' -e 's/if \[ "\$holder_pid:\$holder_since" != "\$seen" \]; then$/if [ -z "$seen" ]; then/' "$lib" > "$fake/planted-deadline.sh"
mkdir -p "$fake/planted-start"; cp "$root/lib/"*.sh "$fake/planted-start/"; cp "$fake/planted-deadline.sh" "$fake/planted-start/landing-lock.sh"
cmp -s "$lib" "$fake/planted-start/landing-lock.sh" && { echo "  FAIL the planted copy equals lib/landing-lock.sh"; failed=$((failed + 1)); }
log_of "$(row "$now" $repository 'landing lock' 3)" "$(row "$now" $repository green 3)"
planted_lib="$fake/planted-start/landing-lock.sh"
landing_planted() { bash -c 'bash "$0" take "$1" "$$" "$2" "$3" >/dev/null 2>&1 || exit 1; sleep 4; bash "$0" release "$1" "$$"' "$planted_lib" "$clone" "$repository#$1" "issue-$1-landing"; }
rm -f "$rcs".*
pids=""; for n in 11 12 13; do ( landing_planted "$n"; echo $? > "$rcs.$n" ) & pids="$pids $!"; done
wait $pids
check 'planted: one of the three stops at the deadline of its first wait' yes "$(cat "$rcs".11 "$rcs".12 "$rcs".13 | grep -q '^1$' && echo yes || echo no)"
rm -f "$lock"

echo 'a lock whose process is gone is taken over'
sh -c 'exit 0' & dead=$!; wait "$dead"
printf '%s\t%s\t%s\n' "$dead" $repository#3 issue-3-dead > "$lock"
out="$(bash "$lib" take "$clone" "$$" $repository#4 issue-4-next 2>&1)"; rc=$?
check 'exit 0'                       0 "$rc"
check 'it says it took the lock over' "taken over: the landing lock of $repository#3 on issue-3-dead, whose process $dead no longer runs" "$(grep -m1 '^taken over' <<< "$out")"
check 'the lock is now its own'      "$$" "$(cut -f1 "$lock")"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

[ "$failed" -eq 0 ] && echo 'all passed' || { echo "$failed failed"; exit 1; }
