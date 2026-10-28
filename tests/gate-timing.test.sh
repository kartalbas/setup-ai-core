#!/usr/bin/env bash
# Where the check of the push gate spends its seconds (lib/gate-timing.sh, bin/pre-push.sh). What is pinned: every line of the
# check's output is written to check.log with the seconds since the check started and shown to the pusher as the check wrote it;
# the gate prints the five longest gaps between two lines, each with the line before the gap, and a check with a planted slow step
# shows that step first, while a check of fast steps shows no gap of two seconds or more; the check's exit status, its last line
# in the run record, which is the check's own without the seconds, and its total seconds stay as they were; a check that ends its
# last line without a newline loses nothing. The cases run in a scratch repository with HOME and AI_CORE_HOME in a scratch folder.
#
#   bash tests/gate-timing.test.sh

set -uo pipefail
# The commits of the scratch repository carry its configured identity, which the gate holds them against: an identity in the
# caller's environment would make every one of them a stranger's.
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fake="$(mktemp -d)"
export HOME="$fake/home" AI_CORE_HOME="$fake/ai-core-home"; mkdir -p "$HOME" "$AI_CORE_HOME"
trap 'rm -rf "$fake"' EXIT
failed=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: [$2]"; echo "       actual:   [$3]"; failed=$((failed + 1)); fi
}
printf 'claude\tmode\talways\t-\t-\n' > "$fake/modes.tsv"; export TEAM_MODES_FILE="$fake/modes.tsv"
tab="$(printf '\t')"

echo 'timed_tee: every line is shown unchanged and logged with the seconds since it started, the last line without a newline too'
. "$root/lib/gate-timing.sh"
log="$fake/timed.log"
shown="$( { printf 'first\n'; sleep 2; printf '  second  with\ttab\n\nlast without newline'; } | timed_tee "$log" )"
check 'the lines shown are the lines written, and a newline ends the last'  $'first\n  second  with\ttab\n\nlast without newline' "$shown"
check 'the log holds each line, led by its whole seconds' $'0\tfirst\n2\t  second  with\ttab\n2\t\n2\tlast without newline' "$(cat "$log")"
check 'the last line that is not blank, as the check wrote it' 'last without newline' "$(check_last_line "$log")"
check 'a log of blank lines only has no last line' '' "$(printf '0\t\n1\t   \n' | check_last_line /dev/stdin)"
{ echo out; exit 3; } | timed_tee "$fake/status.log" > /dev/null; writer_failed=$?
echo out | timed_tee "$fake/status.log" > /dev/null; writer_succeeded=$?
check 'the status of the pipeline it stands in is the writer s, a failure and a success' '3 0' "$writer_failed $writer_succeeded"
: > "$log"
{ printf '0\tfast step\n'; printf '1\tfast step two\n'; printf '9\tslow step done\n'; printf '9\tcolored \033[31mred\033[0m\n'; printf '12\tend\n'; } > "$log"
check 'the gaps, longest first, each with the line before it, its control characters spelled as ?' "8${tab}fast step two
3${tab}colored ?[31mred?[0m
1${tab}fast step" "$(check_longest_gaps "$log" 5)"
check 'a count of one keeps the longest only' "8${tab}fast step two" "$(check_longest_gaps "$log" 1)"
check 'the line before a gap is cut at 160 characters' "$(printf '3\t%0160d' 0)" "$(printf '0\t%0200d\n3\tend\n' 0 | check_longest_gaps /dev/stdin 5)"
check 'no gap of a second or more: nothing' '' "$(printf '0\ta\n0\tb\n0\tc\n' | check_longest_gaps /dev/stdin 5)"

echo 'the gate: a check with a planted slow step shows it first among the longest gaps, and a check of fast steps shows none'
origin="$fake/origin.git"; repo="$fake/project/app"
git init -q --bare -b master "$origin"
git init -q -b master "$repo"; git -C "$repo" remote add origin "$origin"
git -C "$repo" config user.email test@example.invalid; git -C "$repo" config user.name test
mkdir -p "$repo/scripts" "$repo/.ai-core"
printf 'PRE_PUSH_LOAD_LIMIT="0"\n' > "$repo/.ai-core/config.env"; printf '.ai-core/\n' >> "$repo/.git/info/exclude"
write_check() { printf '#!/usr/bin/env bash\n%s\n' "$1" > "$repo/scripts/check.sh"; chmod +x "$repo/scripts/check.sh"; }
write_check 'echo "check: OK"'
git -C "$repo" add scripts; git -C "$repo" commit -q -m 'Start #1'; git -C "$repo" push -q origin master
zeros=0000000000000000000000000000000000000000
runs="$AI_CORE_HOME/.ai-core/pre-push-runs.tsv"
# gate <pre-push.sh>: a new commit on a topic branch, judged by the gate of that harness; out and rc, and the last run on record
gate() {
  local sha
  printf 'more\n' >> "$repo/one.txt"; git -C "$repo" add one.txt scripts; git -C "$repo" commit -q -m 'Move the check on #2'
  sha="$(git -C "$repo" rev-parse HEAD)"
  out="$(printf '%s %s refs/heads/topic %s\n' "$sha" "$sha" "$zeros" | ( cd "$repo" && bash "$1" origin x 2>&1 ))"; rc=$?
  record="$(tail -1 "$runs" | cut -f5,7)"
}
gap_lines() { grep -E '^pre-push:   [0-9]+s after: ' <<< "$out" || true; }
gap_seconds() { gap_lines | sed -n "${1}s/^pre-push:   \([0-9]*\)s after: .*/\1/p"; }

write_check 'echo "step one"; echo "step two"; sleep 4; echo "step three"; echo "check: OK"'
gate "$root/bin/pre-push.sh"
check 'exit 0' 0 "$rc"
check 'it names the longest gaps' 1 "$(grep -c '^pre-push: the longest gaps between two lines of the check, in seconds, each with the line before the gap:$' <<< "$out")"
check 'the planted slow step is first, with the line before it' 'step two' "$(gap_lines | head -1 | sed 's/^pre-push:   [0-9]*s after: //')"
check 'its gap is the 4 seconds it took, give or take the second boundary' yes "$(case "$(gap_seconds 1)" in 4|5) echo yes ;; *) echo no ;; esac)"
check 'the run record keeps the green verdict and the check s own last line' $'green\tcheck: OK' "$record"
check 'the check still shows its lines as it wrote them' 1 "$(grep -c '^step three$' <<< "$out")"

write_check 'echo "a"; echo "b"; echo "c"; echo "check: OK"'
gate "$root/bin/pre-push.sh"
check 'fast steps: exit 0' 0 "$rc"
check 'no gap of two seconds or more is printed' 0 "$(gap_lines | awk '{ s = $2; sub(/s$/, "", s); if (s + 0 >= 2) n++ } END { print n + 0 }')"

write_check 'echo "step one"; sleep 2; echo "check: FAIL"; exit 3'
gate "$root/bin/pre-push.sh"
check 'a red check: the gate refuses, exit 1' 1 "$rc"
check 'it names the gap of the red check too' yes "$([ -n "$(gap_lines)" ] && echo yes || echo no)"
check 'the run record is red, with the check s own last line' $'red\tcheck: FAIL' "$record"

write_check 'printf "no newline at the end"'
gate "$root/bin/pre-push.sh"
check 'a last line without a newline: exit 0' 0 "$rc"
check 'it is the last line on record, unchanged' $'green\tno newline at the end' "$record"

echo 'planted: a gap printer that lists the shortest gap first does not show the slow step first'
planted="$fake/planted"; mkdir -p "$planted"; cp -R "$root/bin" "$root/lib" "$root/VERSION" "$planted/" 2>/dev/null
sed -i 's/-k1,1nr/-k1,1n/' "$planted/lib/gate-timing.sh"
cmp -s "$root/lib/gate-timing.sh" "$planted/lib/gate-timing.sh" && { echo "  FAIL the planted copy equals lib/gate-timing.sh"; failed=$((failed + 1)); }
write_check 'echo "step one"; echo "step two"; sleep 2; echo "step three"; sleep 4; echo "step four"; echo "check: OK"'
gate "$planted/bin/pre-push.sh"
check 'planted: the shortest gap comes first, so the slow step is not first' 'step two' "$(gap_lines | head -1 | sed 's/^pre-push:   [0-9]*s after: //')"
gate "$root/bin/pre-push.sh"
check 'the real gate on the same check: the slowest step, step three, is first' 'step three' "$(gap_lines | head -1 | sed 's/^pre-push:   [0-9]*s after: //')"

[ "$failed" -eq 0 ] && echo 'all passed' || { echo "$failed failed"; exit 1; }
