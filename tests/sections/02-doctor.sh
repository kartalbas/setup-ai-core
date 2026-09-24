#!/usr/bin/env bash
# doctor on both twins, and init stopping when doctor fails; one section of the suite, run by tests/check.sh with the others
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

section "doctor reports an old Node.js and a missing gh login the same way on both twins"
mkdir -p "$WORK/doctorbin"
printf '#!/bin/sh\necho v18.0.0\n' > "$WORK/doctorbin/node"
printf '#!/bin/sh\nif [ "$1" = "--version" ]; then echo "gh version 0.0.0"; else exit 1; fi\n' > "$WORK/doctorbin/gh"
chmod +x "$WORK/doctorbin/node" "$WORK/doctorbin/gh"
printf '@echo v18.0.0\r\n' > "$WORK/doctorbin/node.cmd"
printf '@if "%%1"=="--version" (echo gh version 0.0.0) else (exit /b 1)\r\n' > "$WORK/doctorbin/gh.cmd"
# the team modes of this machine are not what is judged here: a table whose probes always pass
printf 'claude\tcaveman\tlite\talways\t-\t-\ncodex\tcaveman\tlite\talways\t-\t-\ngemini\tcaveman\tlite\talways\t-\t-\n' > "$WORK/always.tsv"
mkdir -p "$WORK/doctor-home"; HOME="$WORK/doctor-home" TEAM_MODES_FILE="$WORK/always.tsv" PATH="$WORK/doctorbin:$PATH" bash "$ROOT/bin/doctor.sh" --no-install > "$WORK/doctor.sh.log" 2>&1 && fail "doctor.sh exited 0 with an old Node.js"
HOME="$WORK/doctor-home" USERPROFILE="$(native "$WORK/doctor-home")" TEAM_MODES_FILE="$(native "$WORK/always.tsv")" PATH="$WORK/doctorbin:$PATH" pwsh -NoProfile -File "$ROOT/bin/doctor.ps1" -NoInstall > "$WORK/doctor.ps1.log" 2>&1 && fail "doctor.ps1 exited 0 with an old Node.js"
for t in sh ps1; do
  grep -aq 'node .*too old' "$WORK/doctor.$t.log" || fail "doctor.$t did not report the old Node.js"
  grep -aq 'gh .*not logged in' "$WORK/doctor.$t.log" || fail "doctor.$t did not report the missing gh login"
  grep -aq 'doctor: 2 problem' "$WORK/doctor.$t.log" || fail "doctor.$t did not count 2 problems"
done
echo "  both exit 1 with the same two problems"

section "init runs doctor first and deploys nothing when it fails, on both twins"
mkdir -p "$WORK/nodoc-sh" "$WORK/nodoc-ps"
PATH="$WORK/doctorbin:$PATH" bash "$ROOT/bin/init.sh" "$WORK/nodoc-sh" > "$WORK/nodoc-sh.log" 2>&1 && fail "init.sh exited 0 although doctor failed"
PATH="$WORK/doctorbin:$PATH" pwsh -NoProfile -File "$ROOT/bin/init.ps1" -TargetDir "$(native "$WORK/nodoc-ps")" > "$WORK/nodoc-ps.log" 2>&1 && fail "init.ps1 exited 0 although doctor failed"
for t in sh ps; do
  grep -aq 'doctor reported' "$WORK/nodoc-$t.log" || fail "init in nodoc-$t did not point at doctor"
  [ -e "$WORK/nodoc-$t/.ai-core" ] && fail "init in nodoc-$t deployed files although doctor failed"
done
echo "  both stop before deploying"

section "doctor takes out a project memory link of Claude Code whose target is gone, and leaves a live one alone, on both twins"
for t in sh ps1; do
  DH="$WORK/memory-home-$t"; mkdir -p "$DH/.claude/projects/gone" "$DH/.claude/projects/live" "$WORK/memory-gone-$t" "$WORK/memory-live-$t"
  for p in gone live; do
    if command -v cmd.exe >/dev/null 2>&1; then cmd.exe //c mklink //J "$(native "$DH/.claude/projects/$p/memory")" "$(native "$WORK/memory-$p-$t")" > /dev/null || fail "mklink for $p"
    else ln -s "$WORK/memory-$p-$t" "$DH/.claude/projects/$p/memory"; fi
  done
  rm -rf "$WORK/memory-gone-$t"
  for run in dry fix; do
    if [ "$t" = sh ]; then
      if [ "$run" = dry ]; then HOME="$DH" TEAM_MODES_FILE="$WORK/always.tsv" bash "$ROOT/bin/doctor.sh" --no-install > "$WORK/memory-$t-$run.log" 2>&1 || true; else HOME="$DH" TEAM_MODES_FILE="$WORK/always.tsv" bash "$ROOT/bin/doctor.sh" > "$WORK/memory-$t-$run.log" 2>&1 || true; fi
    else
      if [ "$run" = dry ]; then HOME="$DH" USERPROFILE="$(native "$DH")" TEAM_MODES_FILE="$(native "$WORK/always.tsv")" pwsh -NoProfile -File "$ROOT/bin/doctor.ps1" -NoInstall > "$WORK/memory-$t-$run.log" 2>&1 || true; else HOME="$DH" USERPROFILE="$(native "$DH")" TEAM_MODES_FILE="$(native "$WORK/always.tsv")" pwsh -NoProfile -File "$ROOT/bin/doctor.ps1" > "$WORK/memory-$t-$run.log" 2>&1 || true; fi
    fi
    if [ "$run" = dry ]; then
      grep -aq 'claude memory .*stale .*gone.*memory points at .*, which is gone' "$WORK/memory-$t-$run.log" && [ -L "$DH/.claude/projects/gone/memory" ] || fail "doctor.$t --no-install did not report the dead memory link, or took it out (see $WORK/memory-$t-$run.log)"
    else
      grep -aq 'claude memory .*repaired' "$WORK/memory-$t-$run.log" && [ ! -L "$DH/.claude/projects/gone/memory" ] && [ ! -e "$DH/.claude/projects/gone/memory" ] || fail "doctor.$t did not take the dead memory link out (see $WORK/memory-$t-$run.log)"
    fi
    [ -e "$DH/.claude/projects/live/memory/" ] || fail "doctor.$t touched the live memory link"
  done
done
echo "  reported by a dry run, taken out otherwise; the live one kept, on both twins"
exit 0
