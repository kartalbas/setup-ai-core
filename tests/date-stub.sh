#!/usr/bin/env bash
# A date that tells the time of DATE_STUB_NOW (epoch seconds) while the variable is set and is the real date
# otherwise, so a test pins the clock of a command per call and never moves the clock of the machine.
# A pinned clock reads in UTC. GNU date only. Sourced by the tests whose commands print a day or a week:
#
#   . tests/date-stub.sh; make_date_stub <folder to put first on PATH>
#   DATE_STUB_NOW=$(epoch_of 2026-10-25T23:59:59Z) command ...

epoch_of() { date -u -d "$1" +%s; }   # epoch_of <UTC timestamp>: its epoch seconds

make_date_stub() {  # make_date_stub <folder>
  mkdir -p "$1"
  cat > "$1/date" <<EOF2
#!/usr/bin/env bash
if [ -z "\${DATE_STUB_NOW:-}" ]; then exec "$(command -v date)" "\$@"; fi
args=(); has_from=0
while [ \$# -gt 0 ]; do
  if [ "\$1" = -d ] && [ \$# -gt 1 ]; then
    has_from=1; from="\$2"
    case "\$from" in *" days ago") from="@\$(( DATE_STUB_NOW - \${from%% *} * 86400 ))" ;; esac
    args+=(-d "\$from"); shift 2
  else args+=("\$1"); shift; fi
done
[ "\$has_from" = 1 ] || args=(-d "@\$DATE_STUB_NOW" "\${args[@]}")
TZ=UTC exec "$(command -v date)" "\${args[@]}"
EOF2
  chmod +x "$1/date"
}
