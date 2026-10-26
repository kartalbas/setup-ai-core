#!/usr/bin/env bash
# What run_split (lib/common.sh) leaves behind: the caller's INT and TERM traps as they stood, in the
# same shell and in a command substitution; and, for an interrupt while the command runs, no
# temporary file of its own and none of the three issue commands that call it.
#
# A test started by tests/run-all.sh or tests/check.sh runs as a background job, where bash
# ignores INT and silently sets no INT trap. Every case therefore runs in a child that env starts
# with INT at its default, and the child says so first: a child that could not reset INT fails the
# case instead of being skipped.
#
# The planted defects (the old run_split that restores nothing, a handler that leaves the file, a
# child with INT ignored) must turn their case red; the real tree must stay green.
#
#   bash tests/run-split.test.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/ai-core-home" "$T/cwd" "$T/ghbin"
export HOME="$T/home" AI_CORE_HOME="$T/ai-core-home" TRACKER=github GH_ORG=example-org

failed=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: [$2]"; echo "       actual:   [$3]"; failed=$((failed + 1)); fi
}

# The scenarios run in the same shell that calls run_split. Each prints one PASS or FAIL line per claim.
cat > "$T/scenarios.sh" <<'EOF'
#!/usr/bin/env bash
. "$LIBDIR/common.sh"
trap 'x' INT
case "$(trap -p INT)" in
  "trap -- 'x' SIGINT") echo 'reset ok' ;;
  *) echo 'reset missing'; exit 99 ;;
esac
trap - INT

pass() { echo "PASS $1"; }
same() { if [ "$2" = "$3" ]; then pass "$1"; else echo "FAIL $1: [$2] became [$3]"; fi; }
traps() { trap -p INT TERM HUP EXIT; }
calls() { run_split true; run_split sh -c 'exit 3'; run_split true; }

scenario_absent() {
  local before after
  same 'no INT or TERM trap before the calls' '' "$(trap -p INT TERM)"
  before="$(traps)"; calls; after="$(traps)"
  same 'every trap is as it was after the calls' "$before" "$after"
}

scenario_handlers() {
  local before rc
  trap 'echo int-handler' INT; trap 'echo term-handler' TERM
  before="$(traps)"
  run_split true
  same 'handlers survive a success' "$before" "$(traps)"
  run_split sh -c 'exit 3'; rc=$?
  same 'handlers survive a failure' "$before" "$(traps)"
  same 'the failure status is the command'"'"'s' 3 "$rc"
}

scenario_ignored() {
  local before
  trap '' INT TERM
  before="$(traps)"
  calls
  same 'ignored signals stay ignored' "$before" "$(traps)"
  kill -INT $$; kill -TERM $$; sleep 0.2
  pass 'the shell outlived both signals'
}

scenario_quoted() {
  local handler before
  handler="$(cat <<'H'
echo "a b" >> "$LOGFILE"
echo 'it'\''s $x; "q"' >> "$LOGFILE"
H
)"
  trap "$handler" INT
  before="$(traps)"
  calls
  same 'quoted handler text survives' "$before" "$(traps)"
  : > "$LOGFILE"; kill -INT $$; sleep 0.2
  same 'the quoted handler runs as written' "a b"$'\n'"it's "'$x; "q"' "$(cat "$LOGFILE")"
}

scenario_repeated() {
  local before i
  trap 'echo int-handler' INT; trap 'echo term-handler' TERM
  before="$(traps)"
  for i in 1 2 3; do
    run_split true;               same "repeated call $i, success" "$before" "$(traps)"
    run_split sh -c 'exit 3';     same "repeated call $i, failure" "$before" "$(traps)"
  done
}

scenario_hup_exit() {
  local before
  trap 'echo hup-handler' HUP; trap 'echo exit-handler >> "$LOGFILE"' EXIT
  before="$(traps)"
  calls
  same 'HUP and EXIT traps are kept' "$before" "$(traps)"
}

scenario_streams() {
  local rc
  run_split sh -c 'echo out; echo err >&2; exit 3'; rc=$?
  same 'split_out' out "$split_out"
  same 'split_err' err "$split_err"
  same 'the status' 3 "$rc"
}

scenario_apart() {
  local data rc before
  trap 'echo int-handler' INT; trap 'echo term-handler' TERM
  before="$(traps)"
  data="$(apart sh -c 'echo data; echo diag >&2' 2> "$SCRATCH/diag")"
  same 'apart: stdout holds the data alone' data "$data"
  same 'apart: the diagnostic stays on stderr' diag "$(cat "$SCRATCH/diag")"
  apart sh -c 'echo data; echo diag >&2' > "$SCRATCH/o" 2> "$SCRATCH/e"
  same 'apart in the caller shell: traps kept' "$before" "$(traps)"
  data="$(apart sh -c 'echo data; echo diag >&2; exit 4')"; rc=$?
  same 'apart on failure: both streams, stdout first' "data"$'\n'"diag" "$data"
  same 'apart on failure: the status' 4 "$rc"
  apart sh -c 'exit 4' > /dev/null; rc=$?
  same 'apart in the caller shell on failure: traps kept' "$before" "$(traps)"
}

scenario_gh() {
  local before rc
  . "$LIBDIR/github/gh.sh"
  mkdir -p "$SCRATCH/bin"
  printf '#!/bin/sh\necho DATA\necho diag >&2\nexit "${GH_FAKE_STATUS:-0}"\n' > "$SCRATCH/bin/gh"
  chmod +x "$SCRATCH/bin/gh"; PATH="$SCRATCH/bin:$PATH"
  trap 'echo int-handler' INT; trap 'echo term-handler' TERM
  before="$(traps)"
  gh api x > "$SCRATCH/o" 2> "$SCRATCH/e"
  same 'gh: stdout' DATA "$(cat "$SCRATCH/o")"
  same 'gh: stderr' diag "$(cat "$SCRATCH/e")"
  same 'gh: traps kept' "$before" "$(traps)"
  GH_FAKE_STATUS=5 gh api x > /dev/null 2>&1; rc=$?
  same 'gh: the failure status' 5 "$rc"
  same 'gh: traps kept after a failure' "$before" "$(traps)"
  apart gh api x > "$SCRATCH/o" 2> "$SCRATCH/e"
  same 'apart over gh: stdout holds the data alone' DATA "$(cat "$SCRATCH/o")"
  same 'apart over gh: the diagnostic stays on stderr' diag "$(cat "$SCRATCH/e")"
  same 'apart over gh: traps kept' "$before" "$(traps)"
}

scenario_fire() {  # fire <signal>: after a returned call, the caller's own handler runs
  : > "$LOGFILE"
  trap 'echo int >> "$LOGFILE"' INT; trap 'echo term >> "$LOGFILE"' TERM
  run_split true
  kill -"$1" $$; sleep 0.2
  same "$1 after a returned call runs the caller's handler" "$(echo "$1" | tr 'A-Z' 'a-z')" "$(cat "$LOGFILE")"
}
scenario_fire_int() { scenario_fire INT; }
scenario_fire_term() { scenario_fire TERM; }

scenario_no_tempfile() {
  local before rc
  trap 'echo int-handler' INT; trap 'echo term-handler' TERM
  before="$(traps)"; rm -f "$SCRATCH/ran"
  TMPDIR="$SCRATCH/missing" run_split sh -c ': > "$1"' _ "$SCRATCH/ran"; rc=$?
  same 'no temporary file: the status is 1' 1 "$rc"
  same 'no temporary file: the command did not run' no "$([ -e "$SCRATCH/ran" ] && echo yes || echo no)"
  same 'no temporary file: split_err says why' 'cannot create a temporary file for the stderr of the command' "$split_err"
  same 'no temporary file: the traps stand' "$before" "$(traps)"
}

# In $( ) the shell reports the calling shell's trap although the signal stands at its default
# there: the control proves the default, the other the trap run_split leaves in force.
scenario_substitution() {
  local signal ended result rc
  for signal in INT TERM; do
    if [ "$signal" = INT ]; then ended=130; else ended=143; fi
    trap 'echo "handler:$BASHPID" >> "$LOGFILE"' "$signal"
    : > "$LOGFILE"
    result="$(kill -"$signal" $BASHPID; sleep 0.2; echo alive)"; rc=$?
    same "$signal in a substitution without run_split: default, the substitution ends" "$ended " "$rc $result"
    : > "$LOGFILE"
    result="$(run_split true; kill -"$signal" $BASHPID; sleep 0.2; echo alive)"
    same "$signal in a substitution after run_split: the substitution lives" alive "$result"
    same "$signal in a substitution after run_split: the calling shell's handler ran there, once" 1 "$(grep -c '^handler:' "$LOGFILE")"
    same "$signal in a substitution after run_split: it ran in the substitution" yes "$([ "$(cut -d: -f2 "$LOGFILE")" != "$$" ] && echo yes || echo no)"
    trap - "$signal"
  done
}

scenario_hang() {
  run_split sh -c 'echo $$ > "$PIDFILE"; exec sleep 30'
  echo "returned $?"
}

"scenario_$1"
EOF

# scenario <libdir> <name>: the output of one scenario in a child with INT at its default
SCRATCH="$T/scratch"; mkdir -p "$SCRATCH"
scenario() {
  : > "$SCRATCH/log"
  env --default-signal=INT LIBDIR="$1" SCRATCH="$SCRATCH" LOGFILE="$SCRATCH/log" bash "$T/scenarios.sh" "$2" 2>&1
}
# verdict <output>: "<reset line>/<passes>/<fails>" of a scenario's output
verdict() { echo "$(head -1 <<< "$1")/$(grep -c '^PASS' <<< "$1")/$(grep -c '^FAIL' <<< "$1")"; }

# the planted run_split: the old one, that clears the traps and restores nothing; and one whose handler leaves the file
rm -rf "$T/old"; mkdir -p "$T/old"; cp -R "$ROOT/lib" "$T/old/"
sed -i.bak '/^  eval "\$caller_traps"$/d' "$T/old/lib/common.sh"
cmp -s "$ROOT/lib/common.sh" "$T/old/lib/common.sh" && { echo 'the planted defect changed nothing' >&2; exit 1; }
rm -rf "$T/noclean"; mkdir -p "$T/noclean"; cp -R "$ROOT/lib" "$T/noclean/"
sed -i.bak "s/trap 'rm -f \"\$err\"; exit 130' INT TERM/trap 'exit 130' INT TERM/" "$T/noclean/lib/common.sh"
cmp -s "$ROOT/lib/common.sh" "$T/noclean/lib/common.sh" && { echo 'the planted defect changed nothing' >&2; exit 1; }
# and one that goes on when no temporary file can be made
rm -rf "$T/unguarded"; mkdir -p "$T/unguarded"; cp -R "$ROOT/lib" "$T/unguarded/"
sed -i.bak '/^  if ! err="\$(mktemp)"; then$/,/^  fi$/c\
  err="$(mktemp)"' "$T/unguarded/lib/common.sh"
cmp -s "$ROOT/lib/common.sh" "$T/unguarded/lib/common.sh" && { echo 'the planted defect changed nothing' >&2; exit 1; }

echo 'the caller shell: its INT and TERM traps as they stood, after a success and after a failure'
for name_expected in absent:2 handlers:3 ignored:2 quoted:2 repeated:6 hup_exit:1 streams:3 apart:6 gh:8 no_tempfile:4; do
  name="${name_expected%%:*}"; expected="${name_expected##*:}"
  out="$(scenario "$ROOT/lib" "$name")"
  check "$name: the child reset INT, $expected claims pass, none fail" "reset ok/$expected/0" "$(verdict "$out")"
done

echo 'a signal after a returned call runs the caller handler, INT and TERM apart'
for name in fire_int fire_term; do
  out="$(scenario "$ROOT/lib" "$name")"
  check "$name" 'reset ok/1/0' "$(verdict "$out")"
done

echo 'run_split inside a command substitution, by a signal sent to the substitution'
out="$(scenario "$ROOT/lib" substitution)"
check 'INT and TERM: default without run_split, the calling shell trap after it' 'reset ok/8/0' "$(verdict "$out")"

echo 'planted: the old run_split loses the traps, and the cases catch it'
for name in handlers ignored quoted repeated apart gh; do
  out="$(scenario "$T/old/lib" "$name")"
  check "planted: $name is red" yes "$([ "$(verdict "$out" | cut -d/ -f3)" != 0 ] || [ "$(head -1 <<< "$out")" != 'reset ok' ] && echo yes || echo no)"
done
out="$(scenario "$T/old/lib" fire_int)"
check 'planted: INT after a returned call does not run the handler' 'reset ok/0/0' "$(verdict "$out")"
out="$(scenario "$T/old/lib" absent)"
check 'innocent: with no trap set the old run_split cannot be told from the new' 'reset ok/2/0' "$(verdict "$out")"
out="$(scenario "$T/old/lib" hup_exit)"
check 'innocent: HUP and EXIT were never touched, the old one passes too' 'reset ok/1/0' "$(verdict "$out")"
out="$(scenario "$T/unguarded/lib" no_tempfile)"
check 'planted: without a temporary file the unguarded one loses the traps and says nothing' 'reset ok/2/2' "$(verdict "$out")"

echo 'planted: a child whose INT is ignored says so, and no case counts it as run'
out="$( ( trap '' INT; LIBDIR="$ROOT/lib" SCRATCH="$SCRATCH" LOGFILE="$SCRATCH/log" bash "$T/scenarios.sh" absent ) 2>&1 )"
check 'the child reports the reset missing' 'reset missing/0/0' "$(verdict "$out")"

# interrupt <mode> <signal> <libdir>: scenario hang, interrupted while the command runs, as the process
# or as its process group; sets hang_out and hang_left, the files left in its TMPDIR
wait_for_file() {  # wait_for_file <file>: up to a minute
  local i; for i in $(seq 1 600); do [ -s "$1" ] && return 0; sleep 0.1; done; return 1
}
wait_for_end() {  # wait_for_end <pid>: up to 30 seconds
  local i; for i in $(seq 1 300); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.1; done; return 1
}
interrupt() {
  local mode="$1" signal="$2" lib="$3" pid starter=()
  rm -rf "$T/hang"; mkdir -p "$T/hang/tmp"
  [ "$mode" = group ] && starter=(setsid)
  ( exec ${starter[@]+"${starter[@]}"} env --default-signal=INT LIBDIR="$lib" SCRATCH="$T/hang" LOGFILE="$T/hang/log" \
      PIDFILE="$T/hang/sleeper" TMPDIR="$T/hang/tmp" bash "$T/scenarios.sh" hang > "$T/hang/out" 2>&1 ) &
  pid=$!
  hang_status=never-ran
  if wait_for_file "$T/hang/sleeper"; then
    if [ "$mode" = group ]; then kill -"$signal" -- "-$pid"; else kill -"$signal" "$pid"; kill "$(cat "$T/hang/sleeper")"; fi
    if wait_for_end "$pid"; then wait "$pid"; hang_status=$?; else kill -KILL -- "-$pid" 2>/dev/null; kill -KILL "$pid" 2>/dev/null; hang_status=never-ended; fi
  else
    kill -KILL -- "-$pid" 2>/dev/null; kill -KILL "$pid" 2>/dev/null
  fi
  hang_out="$(cat "$T/hang/out")"
  hang_left="$(ls -A "$T/hang/tmp" | wc -l | tr -d ' ')"
}

echo 'an interrupt while the command runs: the status, and no temporary file left'
for mode in process group; do
  for signal in INT TERM; do
    interrupt "$mode" "$signal" "$ROOT/lib"
    check "$mode $signal: the shell ended with 130, nothing returned, reset in force" "130/reset ok" "$hang_status/$(head -1 <<< "$hang_out")"
    check "$mode $signal: nothing left in TMPDIR" 0 "$hang_left"
  done
done
interrupt group TERM "$T/noclean/lib"
check 'planted: a handler that leaves the file is red' yes "$([ "$hang_left" -gt 0 ] && echo yes || echo no)"
interrupt process INT "$T/noclean/lib"
check 'planted: the same as a process' yes "$([ "$hang_left" -gt 0 ] && echo yes || echo no)"

# The three commands that trap HUP INT TERM themselves, against a stand-in gh that answers the
# visibility of the repository and hangs on every other call.
cat > "$T/ghbin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1 $2" = "repo view" ] && [ "${4-} ${5-}" = "--json isPrivate" ]; then echo '{"isPrivate":false}'; exit 0; fi
case "$*" in *projectsV2*) exit 0 ;; esac
echo $$ > "$GH_PIDFILE"
exec sleep 30
EOF
chmod +x "$T/ghbin/gh"
printf 'The body the caller owns.\nA second line.\n' > "$T/caller-body.md"
cp "$T/caller-body.md" "$T/caller-body.expected"

# interrupt_command <mode> <signal> <tree> <command> <argument>...: the command interrupted at the hang;
# sets cmd_status, cmd_left (files in its TMPDIR) and cmd_input (whether the caller's file is unchanged)
interrupt_command() {
  local mode="$1" signal="$2" tree="$3" command="$4" pid starter=()
  shift 4
  rm -rf "$T/cmd"; mkdir -p "$T/cmd/tmp"; cp "$T/caller-body.expected" "$T/caller-body.md"
  [ "$mode" = group ] && starter=(setsid)
  ( cd "$T/cwd" && exec ${starter[@]+"${starter[@]}"} env --default-signal=INT PATH="$T/ghbin:$PATH" GH_PIDFILE="$T/cmd/sleeper" \
      TMPDIR="$T/cmd/tmp" bash "$tree/bin/$command" "$@" > "$T/cmd/out" 2>&1 ) &
  pid=$!
  cmd_status=never-ran
  if wait_for_file "$T/cmd/sleeper"; then
    if [ "$mode" = group ]; then kill -"$signal" -- "-$pid"; else kill -"$signal" "$pid"; kill "$(cat "$T/cmd/sleeper")"; fi
    if wait_for_end "$pid"; then wait "$pid"; cmd_status=$?; else kill -KILL -- "-$pid" 2>/dev/null; kill -KILL "$pid" 2>/dev/null; cmd_status=never-ended; fi
  else
    kill -KILL -- "-$pid" 2>/dev/null; kill -KILL "$pid" 2>/dev/null
  fi
  cmd_left="$(ls -A "$T/cmd/tmp" | wc -l | tr -d ' ')"
  cmd_input="$(cmp -s "$T/caller-body.md" "$T/caller-body.expected" && echo unchanged || echo changed)"
}

commands() {  # commands <name>: the arguments of each command
  case "$1" in
    issue-comment.sh) echo "example-org/example-repo 94 --body-file $T/caller-body.md" ;;
    issue-edit.sh)    echo "example-org/example-repo 94 --body-file $T/caller-body.md" ;;
    issue-new.sh)     echo "--repo example-org/example-harness --title Put_every_new_issue_on_its_board,_or_nobody_sees_it --body-file $T/caller-body.md --label type:feature --label area:tooling --asked-by tester --asked-in the_test --no-board" ;;
  esac
}

echo 'the three issue commands interrupted while gh runs: no temporary file left, the caller file unchanged'
for command in issue-comment.sh issue-edit.sh issue-new.sh; do
  # shellcheck disable=SC2046
  for mode_signal in process:INT process:TERM group:INT group:TERM; do
    interrupt_command "${mode_signal%%:*}" "${mode_signal##*:}" "$ROOT" "$command" $(commands "$command")
    check "$command, $mode_signal: it ended, nothing left in TMPDIR, the input unchanged" "ended/0/unchanged" \
      "$([ "$cmd_status" = never-ran ] || [ "$cmd_status" = never-ended ] && echo "$cmd_status" || echo ended)/$cmd_left/$cmd_input"
  done
done

echo 'planted: the handler that leaves the file, in the tree the commands run from'
rm -rf "$T/tree"; mkdir -p "$T/tree"; cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/templates" "$T/tree/"; cp "$ROOT/VERSION" "$T/tree/"
sed -i.bak "s/trap 'rm -f \"\$err\"; exit 130' INT TERM/trap 'exit 130' INT TERM/" "$T/tree/lib/common.sh"
cmp -s "$ROOT/lib/common.sh" "$T/tree/lib/common.sh" && { echo 'the planted defect changed nothing' >&2; exit 1; }
# shellcheck disable=SC2046
interrupt_command group TERM "$T/tree" issue-comment.sh $(commands issue-comment.sh)
check 'planted: a temporary file stays behind' yes "$([ "$cmd_left" -gt 0 ] && echo yes || echo no)"

echo
if [ "$failed" -gt 0 ]; then echo "$failed failed"; exit 1; fi
echo 'all passed'
