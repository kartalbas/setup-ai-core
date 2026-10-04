#!/usr/bin/env bash
# What tests/check.sh says about a crash of pwsh when the suite is red.
#
#   bash test/check.test.sh
#
# The suite runs here as a copy beside sections of this test's own, one red and one green, so
# nothing of the real suite runs twice. journalctl is a fake on PATH that prints a kernel log
# written by hand: the real one holds whatever this machine logged, and a test that read it would
# prove nothing twice the same.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
failed=0
trap 'rm -rf "$WORK"' EXIT

check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}

mkdir -p "$WORK/suite/sections" "$WORK/bin"
cp "$ROOT/tests/check.sh" "$WORK/suite/check.sh"
printf '#!/usr/bin/env bash\necho "  FAIL a check"; exit 1\n' > "$WORK/suite/sections/01-red.sh"
printf '#!/usr/bin/env bash\necho "  ok   a check"\n' > "$WORK/suite/sections/02-green.sh"

# The fake answers `-n 1` with the first line of the log and `--since` with all of it, records the
# arguments it was given, and fails the windowed read where SINCE_FAILS says so.
cat > "$WORK/bin/journalctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$JOURNAL_CALLS"
case " $* " in
  *" -n 1 "*) head -n 1 "$JOURNAL" ;;
  *" --since "*) [ -z "${SINCE_FAILS:-}" ] || exit 1; cat "$JOURNAL" ;;
esac
EOF
chmod +x "$WORK/bin/journalctl"
export JOURNAL="$WORK/journal" JOURNAL_CALLS="$WORK/calls"

run() { # sections... ; the suite's output in $out, its exit status in $rc
  : > "$JOURNAL_CALLS"
  out="$(PATH="$WORK/bin:$PATH" bash "$WORK/suite/check.sh" "$@" 2>&1)"; rc=$?
}

echo "a red run with two crashes of pwsh in the kernel log names them"
cat > "$JOURNAL" <<'EOF'
Oct 04 16:18:42 host kernel: pwsh[297522]: segfault at 28 ip 00007439401dc9da sp 0000741a097fe940 error 4 in libcoreclr.so[3db9da,74393ffc9000+4b1000]
Oct 04 16:19:01 host kernel: node[12345]: segfault at 0 ip 0000000000000000 sp 00007ffd error 14 in node[400000+2000000]
Oct 04 16:20:13 host kernel: pwsh[297600]: segfault at 7 ip 000079b11fc4346c sp 00007991e8ffe960 error 4 in libcoreclr.so[44246c,79b11f9c9000+4b1000]
EOF
run 01-red 02-green
check 'the run stays red' 1 "$rc"
check 'it counts the two crashes of pwsh, not the one of node' yes \
  "$(grep -q 'pwsh crashed 2 time(s) on this machine during this run' <<< "$out" && echo yes || echo no)"
check 'it reads the log from the start of the run' yes \
  "$(grep -qE -- '--since @[0-9]+' "$JOURNAL_CALLS" && echo yes || echo no)"

echo "a red run with no crash of pwsh in the kernel log says so"
cat > "$JOURNAL" <<'EOF'
Oct 04 16:19:01 host kernel: node[12345]: segfault at 0 ip 0000000000000000 sp 00007ffd error 14 in node[400000+2000000]
EOF
run 01-red
check 'the run stays red' 1 "$rc"
check 'it says there was none' yes \
  "$(grep -q 'no crash of pwsh in the kernel log during this run' <<< "$out" && echo yes || echo no)"

echo "a red run that cannot read the kernel log says so, and does not report none"
: > "$JOURNAL"
run 01-red
check 'it says the log could not be read' yes \
  "$(grep -q 'the kernel log could not be read' <<< "$out" && echo yes || echo no)"
check 'it does not say there was none' no \
  "$(grep -q 'no crash of pwsh' <<< "$out" && echo yes || echo no)"
echo 'Oct 04 00:00:01 host kernel: Linux version 7.0.0' > "$JOURNAL"
export SINCE_FAILS=1; run 01-red; unset SINCE_FAILS
check 'nor when only the read of the run time fails' yes \
  "$(grep -q 'the kernel log could not be read' <<< "$out" && echo yes || echo no)"

echo "a green run says nothing about the kernel log"
run 02-green
check 'the run is green' 0 "$rc"
check 'it does not read the kernel log' '' "$(cat "$JOURNAL_CALLS")"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo; echo 'all passed'
