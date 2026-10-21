#!/usr/bin/env bash
# The load, the clock and the sleeping of the push gate, injected through PATH and never burnt. Sourced by
# the tests that run the real gate:
#
#   . tests/load-stubs.sh; make_load_stubs <folder to put first on PATH>
#
# PROBE_STATE names a folder with the loads the stand-in uptime answers (file loads: one per call, the
# last one repeating; FAIL is a reader that fails, EMPTY one that prints nothing, JUNK one that prints no
# number). While it holds a file clock, the stand-in date (+%s) and sleep keep a clock of their own that
# sleep advances; sleeps lists what was slept, and a script on-sleep-<n> runs during the n-th sleep. A
# test that plants nothing finds the real date and sleep.

make_load_stubs() {  # make_load_stubs <folder>
  local dir="$1" real_date real_sleep
  real_date="$(command -v date)"; real_sleep="$(command -v sleep)"
  mkdir -p "$dir"
  cat > "$dir/uptime" <<'EOF'
#!/usr/bin/env bash
n=$(( $(cat "$PROBE_STATE/uptime-calls" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$PROBE_STATE/uptime-calls"
value="$(sed -n "${n}p" "$PROBE_STATE/loads")"; [ -n "$value" ] || value="$(tail -1 "$PROBE_STATE/loads")"
case "$value" in
  FAIL) exit 1 ;;
  EMPTY) exit 0 ;;
  JUNK) echo ' 10:00:00 up 1 day, load average: n/a' ;;
  *) printf ' 10:00:00 up 1 day,  2 users,  load average: %s, 1.00, 1.00\n' "$value" ;;
esac
EOF
  cat > "$dir/date" <<EOF
#!/usr/bin/env bash
if [ "\$*" = '+%s' ] && [ -f "\$PROBE_STATE/clock" ]; then cat "\$PROBE_STATE/clock"; exit 0; fi
exec "$real_date" "\$@"
EOF
  cat > "$dir/sleep" <<EOF
#!/usr/bin/env bash
[ -f "\$PROBE_STATE/clock" ] || exec "$real_sleep" "\$@"
echo "\$1" >> "\$PROBE_STATE/sleeps"; n=\$(wc -l < "\$PROBE_STATE/sleeps" | tr -d ' ')
echo \$(( \$(cat "\$PROBE_STATE/clock") + \$1 )) > "\$PROBE_STATE/clock"
[ ! -f "\$PROBE_STATE/on-sleep-\$n" ] || bash "\$PROBE_STATE/on-sleep-\$n"
if [ -f "\$PROBE_STATE/block" ]; then : > "\$PROBE_STATE/sleeping"; while [ ! -e "\$PROBE_STATE/wake" ]; do "$real_sleep" 0.05; done; fi
exit 0
EOF
  chmod +x "$dir/uptime" "$dir/date" "$dir/sleep"
}
# plan_load <state folder> <load...>: a clock of its own at 1000 and the loads the readings answer
plan_load() {
  local state="$1"; shift
  mkdir -p "$state"; rm -f "$state"/uptime-calls "$state"/sleeps "$state"/checks "$state"/on-sleep-* "$state"/block "$state"/wake "$state"/sleeping
  printf '%s\n' "$@" > "$state/loads"; echo 1000 > "$state/clock"
}
