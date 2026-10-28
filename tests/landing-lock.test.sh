#!/usr/bin/env bash
# The landing lock of a clone (lib/landing-lock.sh) and the run log it measures a deadline from. What is pinned: the deadline of a
# wait is one and a half times the longest check of the repository in the run log of the last 14 days, a check of another
# repository, a check older than that, a run that ran no check and an unreadable log never set it, and where none is measured the
# wait has no deadline and says why; the lock names the issue and the branch of its holder; it is released only by the process that
# wrote it; a second landing stops at the deadline with the holder named and the lock of the holder untouched. Every case runs in
# a scratch clone with HOME and AI_CORE_HOME in a scratch folder.
#
#   bash tests/landing-lock.test.sh

set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fake="$(mktemp -d)"
trap 'rm -rf "$fake"' EXIT
export HOME="$fake/home" AI_CORE_HOME="$fake/home"
mkdir -p "$HOME/.ai-core"
failed=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}

clone="$fake/clone"
git -c init.defaultBranch=master init -q "$clone"
git -C "$clone" remote add origin "https://example.invalid/example-org/example-repo.git"
log="$AI_CORE_HOME/.ai-core/pre-push-runs.tsv"
header=$'time\trepository\tworktree\tcommit\tverdict\tseconds\tlast line\tload at check start'
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
old="$(date -u -d '@'"$(( $(date +%s) - 30 * 86400 ))" +%Y-%m-%dT%H:%M:%SZ)"
# row <time> <repository> <verdict> <seconds>
row() { printf '%s\t%s\t/somewhere\taaaa\t%s\t%s\tlast line\t0.5\n' "$1" "$2" "$3" "$4"; }
# allowance <library>: what that reader makes of the log for example-org/example-repo
allowance() { ( . "$1"; landing_lock_allowance example-org/example-repo; echo "${LANDING_LOCK_SECONDS:-none}" ); }
basis() { ( . "$1"; landing_lock_allowance example-org/example-repo; echo "$LANDING_LOCK_BASIS" ); }

echo 'the deadline is one and a half times the longest check of the repository in the last 14 days'
rm -f "$log"
check 'no log: no deadline'          none "$(allowance "$root/lib/landing-lock.sh")"
check 'and it says there is no log'  "no run log stands at $log yet" "$(basis "$root/lib/landing-lock.sh")"
printf '%s\n' "$header" > "$log"
check 'a log with no check of the repository: no deadline' none "$(allowance "$root/lib/landing-lock.sh")"
{ printf '%s\n' "$header"; row "$now" Example-Org/Example-Repo green 100; row "$now" example-org/example-repo red 40; row "$now" example-org/example-repo green 7; } > "$log"
check 'the longest of 100, 40 and 7 seconds, in either case of the name, makes 150' 150 "$(allowance "$root/lib/landing-lock.sh")"
check 'an odd number rounds up' 2 "$( { printf '%s\n' "$header"; row "$now" example-org/example-repo green 1; } > "$log"; allowance "$root/lib/landing-lock.sh")"
{ printf '%s\n' "$header"; row "$now" example-org/example-repo green 10; row "$now" example-org/other green 5000; row "$old" example-org/example-repo green 4000; row "$now" example-org/example-repo 'no check' -; row "$now" example-org/example-repo red -; } > "$log"
check 'another repository, a row older than 14 days and runs without seconds set nothing: 10 seconds make 15' 15 "$(allowance "$root/lib/landing-lock.sh")"
check 'the basis names the seconds and the repository' "one and a half times the 10 seconds of the longest check of example-org/example-repo in the last 14 days of $log" "$(basis "$root/lib/landing-lock.sh")"
rm -f "$log"; mkdir "$log"
check 'a log that cannot be read: no deadline' none "$(allowance "$root/lib/landing-lock.sh")"
check 'and it says so'               "the run log $log cannot be read" "$(basis "$root/lib/landing-lock.sh")"
rmdir "$log"
# planted: a reader that takes the longest check of any repository, and one that counts rows of any age
planted() {  # planted <name> <sed expression>
  sed "$2" "$root/lib/pre-push-runs.sh" > "$fake/pre-push-runs-$1.sh"
  cmp -s "$root/lib/pre-push-runs.sh" "$fake/pre-push-runs-$1.sh" && { echo "  FAIL the planted copy $1 equals lib/pre-push-runs.sh"; failed=$((failed + 1)); return; }
  mkdir -p "$fake/planted-$1"; cp "$root/lib/landing-lock.sh" "$fake/planted-$1/"; cp "$fake/pre-push-runs-$1.sh" "$fake/planted-$1/pre-push-runs.sh"
}
{ printf '%s\n' "$header"; row "$now" example-org/example-repo green 10; row "$now" example-org/other green 5000; row "$old" example-org/example-repo green 4000; } > "$log"
planted any-repository 's/ && tolower(\$2) == tolower(repository)//'
planted any-age 's/NF == 8 && \$1 >= start/NF == 8/'
check 'planted: a reader of every repository takes 5000 seconds' 7500 "$(allowance "$fake/planted-any-repository/landing-lock.sh")"
check 'planted: a reader of every age takes 4000 seconds' 6000 "$(allowance "$fake/planted-any-age/landing-lock.sh")"
check 'the real reader of the same log: 10 seconds make 15' 15 "$(allowance "$root/lib/landing-lock.sh")"

echo 'the lock names its holder, and only the process that wrote it releases it'
lock="$clone/.git/ai-core-landing"
sleep 300 & holder=$!
( . "$root/lib/landing-lock.sh"; landing_lock_take "$clone" "$holder" example-org/example-repo#1 issue-1-holder example-org/example-repo ) 2>/dev/null
check 'the file holds the process, the issue and the branch' "$holder"$'\t'"example-org/example-repo#1"$'\t'"issue-1-holder" "$(cat "$lock")"
( . "$root/lib/landing-lock.sh"; landing_lock_release "$clone" 999999 )
check 'another process releases nothing' yes "$([ -e "$lock" ] && echo yes || echo no)"
( . "$root/lib/landing-lock.sh"; landing_lock_release "$clone" "$holder" )
check 'the holder releases it'       no "$([ -e "$lock" ] && echo yes || echo no)"

echo 'a second landing stops at the deadline, names the holder, and leaves its lock alone'
{ printf '%s\n' "$header"; row "$now" example-org/example-repo green 1; } > "$log"
bash "$root/lib/landing-lock.sh" take "$clone" "$holder" example-org/example-repo#1 issue-1-holder 2>/dev/null
check 'the holder took it'           yes "$([ -e "$lock" ] && echo yes || echo no)"
out="$(bash "$root/lib/landing-lock.sh" take "$clone" "$$" example-org/example-repo#2 issue-2-second 2>&1)"; rc=$?
check 'exit 1'                       1 "$rc"
check 'it says who holds the lock'   yes "$(grep -qE "^waiting: example-org/example-repo#1 on issue-1-holder is landing from this clone \(process $holder\); this one lands after it\$" <<< "$out" && echo yes || echo no)"
check 'it says the deadline'         yes "$(grep -qE '^deadline: 2 seconds, one and a half times the 1 seconds of the longest check of example-org/example-repo' <<< "$out" && echo yes || echo no)"
check 'it names the holder in the refusal' yes "$(grep -qE "^nothing landed: the landing lock is still held by example-org/example-repo#1 on issue-1-holder \(process $holder\) after [0-9]+ seconds" <<< "$out" && echo yes || echo no)"
check 'the lock of the holder stands' "$holder" "$(cut -f1 "$lock")"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
rm -f "$lock"
echo 'a lock whose process is gone is taken over'
sh -c 'exit 0' & dead=$!; wait "$dead"
printf '%s\t%s\t%s\n' "$dead" example-org/example-repo#3 issue-3-dead > "$lock"
out="$(bash "$root/lib/landing-lock.sh" take "$clone" "$$" example-org/example-repo#4 issue-4-next 2>&1)"; rc=$?
check 'exit 0'                       0 "$rc"
check 'it says it took the lock over' "taken over: the landing lock of example-org/example-repo#3 on issue-3-dead, whose process $dead no longer runs" "$(grep -m1 '^taken over' <<< "$out")"
check 'the lock is now its own'      "$$" "$(cut -f1 "$lock")"

[ "$failed" -eq 0 ] && echo 'all passed' || { echo "$failed failed"; exit 1; }
