#!/usr/bin/env bash
# The stand-in date of tests/date-stub.sh: it tells the time of the call that pins it, the real time of a call
# that does not, and a pinned clock crossing midnight changes the day and, from a Sunday, the week as well.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
. "$root/tests/date-stub.sh"
make_date_stub "$work/bin"
at() { local clock="$1"; shift; PATH="$work/bin:$PATH" DATE_STUB_NOW="$(epoch_of "$clock")" "$@"; }
want() {  # want <what> <expected> <actual>
  [ "$2" = "$3" ] || fail "$1: expected [$2], got [$3]"
}

want 'a call that pins no clock reads the real one' "$(date +%Y)" "$(PATH="$work/bin:$PATH" date +%Y)"
want 'the day of a pinned clock' 2026-10-25 "$(at 2026-10-25T23:59:59Z date +%Y-%m-%d)"
want 'the pinned clock reads in UTC' 23:59:59 "$(TZ=Pacific/Auckland at 2026-10-25T23:59:59Z date +%H:%M:%S)"
want 'the week of a Sunday' 2026-W43 "$(at 2026-10-25T23:59:59Z date -u +%G-W%V)"
want 'the week after midnight on the Monday' 2026-W44 "$(at 2026-10-26T00:00:01Z date -u +%G-W%V)"
want 'a day after midnight in mid-week' 2026-10-28 "$(at 2026-10-28T00:00:01Z date +%Y-%m-%d)"
want 'and the week stays, from a Tuesday to a Wednesday' "$(at 2026-10-27T23:59:59Z date -u +%G-W%V)" "$(at 2026-10-28T00:00:01Z date -u +%G-W%V)"
want 'N days ago counts from the pinned clock' 2026-10-18 "$(at 2026-10-25T23:59:59Z date -u -d '7 days ago' +%Y-%m-%d)"
want 'a time that is named is the one named' 2026-W42 "$(at 2026-10-25T23:59:59Z date -u -d 2026-10-13T01:02:03Z +%G-W%V)"
want 'the epoch seconds' "$(epoch_of 2026-10-25T23:59:59Z)" "$(at 2026-10-25T23:59:59Z date +%s)"
# two clocks at once: a pin is the call's own, and moves no other
at 2026-10-25T23:59:59Z bash -c 'sleep 0.2; date +%Y-%m-%d' > "$work/first" &
at 2026-10-26T00:00:01Z bash -c 'date +%Y-%m-%d' > "$work/second"
wait
want 'a pin does not reach another call' "2026-10-25 2026-10-26" "$(cat "$work/first") $(cat "$work/second")"
echo "date-stub.test.sh: a pinned clock tells its own day and week, the real one is left alone"
