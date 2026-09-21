#!/usr/bin/env bash
# Graft failing and Graft succeeding; one section of the suite, run by tests/check.sh with the others
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

section "a failing Graft build fails init, on both twins (fake npx on the PATH, no network)"
mkdir -p "$WORK/fakebin"
printf '#!/bin/sh\necho "fake npx: tests never reach the network" >&2\nexit 1\n' > "$WORK/fakebin/npx"
printf '@echo fake npx: tests never reach the network 1>&2\r\n@exit /b 1\r\n' > "$WORK/fakebin/npx.cmd"
chmod +x "$WORK/fakebin/npx"
for twin in sh ps1; do
  mkdir -p "$WORK/nograft-$twin"
  if [ "$twin" = sh ]; then
    PATH="$WORK/fakebin:$PATH" bash "$ROOT/bin/init.sh" "$WORK/nograft-$twin" --no-doctor > "$WORK/nograft-$twin.log" 2>&1 && fail "init.sh exited 0 although Graft failed"
  else
    PATH="$WORK/fakebin:$PATH" pwsh -NoProfile -File "$ROOT/bin/init.ps1" -TargetDir "$(native "$WORK/nograft-$twin")" -NoDoctor > "$WORK/nograft-$twin.log" 2>&1 && fail "init.ps1 exited 0 although Graft failed"
  fi
  grep -aq 'code graph is not' "$WORK/nograft-$twin.log" || fail "init.$twin did not explain the Graft failure"
  [ -f "$WORK/nograft-$twin/AGENTS.md" ] || fail "init.$twin failed before deploying the harness files"
done
echo "  both exit 1 with the harness files in place"

section "a Graft that succeeds: called without the picker, everything it wrote excluded, the committed file it changed named, on both twins"
make_graft_fake
for twin in sh ps1; do
  git init -q "$WORK/graft-$twin"
  echo readme > "$WORK/graft-$twin/README.md"
  git -C "$WORK/graft-$twin" add README.md
  git -C "$WORK/graft-$twin" -c user.name=check -c user.email=check@localhost commit -q -m init
  git -C "$WORK/graft-$twin" config core.autocrlf false
  echo wired-earlier > "$WORK/graft-$twin/GEMINI.md"
  : > "$WORK/graft-$twin.args"
  for run in 1 2; do
    if [ "$twin" = sh ]; then
      GRAFT_FAKE_LOG="$WORK/graft-$twin.args" PATH="$WORK/graftbin:$PATH" bash "$ROOT/bin/init.sh" "$WORK/graft-$twin" --no-doctor >> "$WORK/graft-$twin.log" 2>&1 || fail "init.sh with a succeeding Graft (run $run, see $WORK/graft-$twin.log)"
    else
      GRAFT_FAKE_LOG="$(native "$WORK/graft-$twin.args")" PATH="$WORK/graftbin:$PATH" pwsh -NoProfile -File "$ROOT/bin/init.ps1" -TargetDir "$(native "$WORK/graft-$twin")" -NoDoctor >> "$WORK/graft-$twin.log" 2>&1 || fail "init.ps1 with a succeeding Graft (run $run, see $WORK/graft-$twin.log)"
    fi
  done
  grep -aq '^-y @nanonets/graft init --agents claude agents antigravity --no-build' "$WORK/graft-$twin.args" || fail "init.$twin did not wire the agents of config.env without the picker (args: $(tr '\n' '|' < "$WORK/graft-$twin.args"))"
  grep -aq '^-y @nanonets/graft build' "$WORK/graft-$twin.args" || fail "init.$twin did not run graft build"
  [ "$(git -C "$WORK/graft-$twin" status --porcelain | tr -d '\r' | sort | tr '\n' '|')" = " M README.md|" ] || fail "init.$twin: git status after Graft is not the changed README.md and the new .gitignore: $(git -C "$WORK/graft-$twin" status --porcelain | tr '\n' ' ')"
  grep -aq 'Graft changed committed files: README.md' "$WORK/graft-$twin.log" || fail "init.$twin did not name the committed file Graft changed"
  for p in /graft/ /GEMINI.md /.gemini/settings.json; do
    grep -qxF "$p" "$WORK/graft-$twin/.git/info/exclude" || fail "init.$twin: $p missing from the Graft exclude block"
  done
  [ "$(grep -c '^# setup-ai-core graft start' "$WORK/graft-$twin/.git/info/exclude")" = 1 ] || fail "Graft exclude block written more than once by init.$twin"
done
echo "  both twins: no picker, GEMINI.md (there before) and .gemini/ excluded after two runs, README.md named"
exit 0
