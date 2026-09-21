#!/usr/bin/env bash
# releases, install and update; one section of the suite, run by tests/check.sh with the others
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

section "releases: release commits VERSION, pushes, waits for the green run and tags; install checks the newest release out; update moves to it and --check reports; on both twins"
make_graft_fake; make_gh_fake
for twin in sh ps1; do
  RO="$WORK/rel-$twin-origin.git"; git init -q --bare -b main "$RO"
  RD="$WORK/rel-$twin-dev"; mkdir -p "$RD"
  (cd "$ROOT" && git ls-files -co --exclude-standard -z | tar --null -cf - -T -) | tar -xf - -C "$RD"   # the working tree, not a clone
  git init -q -b main "$RD"; git -C "$RD" add -A; git -C "$RD" commit -q -m 'The tree #1'
  git -C "$RD" remote add origin "$RO"
  printf '9.9.0\n' > "$RD/VERSION"; git -C "$RD" commit -q -am 'release: 9.9.0'
  git -C "$RD" push -q -u origin main 2>/dev/null; git -C "$RD" remote set-head origin main
  RH="$WORK/rel-$twin-home"; mkdir -p "$RH"
  rel() { if [ "$twin" = sh ]; then AI_CORE_RELEASE_POLL=1 PATH="$PATH_SH" bash "$RD/bin/release.sh" "$@" 2>&1; else AI_CORE_RELEASE_POLL=1 PATH="$PATH_SH" pwsh -NoProfile -File "$RD/bin/release.ps1" "$@" 2>&1; fi; }
  upd() { (cd "$RH" && if [ "$twin" = sh ]; then HOME="$RH" bash "$RH/.setup-ai-core/bin/update.sh" "$@" 2>&1; else HOME="$RH" USERPROFILE="$(native "$RH")" pwsh -NoProfile -File "$RH/.setup-ai-core/bin/update.ps1" "$@" 2>&1; fi); }
  printf 'dirty\n' > "$RD/dirty.txt"
  out="$(rel 9.9.0)" && fail "release.$twin released from a tree that is not clean"
  printf '%s\n' "$out" | grep -q 'the tree is not clean' || fail "release.$twin does not name the dirty tree: $out"
  rm -f "$RD/dirty.txt"
  printf 'x\n' > "$RD/scratch.txt"; git -C "$RD" add scratch.txt; git -C "$RD" commit -q -m 'Add scratch #1'
  out="$(rel 9.9.0)" || fail "release.$twin refused a clean commit that was not pushed yet: $out"
  printf '%s\n' "$out" | grep -q '^release: [0-9a-f]\{7\} pushed to origin/main$' || fail "release.$twin did not say it pushed the commit: $out"
  printf '%s\n' "$out" | grep -q '^release: v9.9.0 on ' || fail "release.$twin did not report the tag: $out"
  printf '%s\n' "$out" | grep -q 'VERSION 9.9.0' && fail "release.$twin wrote VERSION although it carried the version: $out"
  [ "$(git -C "$RO" rev-parse main)" = "$(git -C "$RD" rev-parse HEAD)" ] || fail "release.$twin did not push the commit to the origin"
  git -C "$RO" rev-parse -q --verify refs/tags/v9.9.0 > /dev/null || fail "release.$twin did not push v9.9.0 to the origin"
  out="$(rel 9.9.0)" && fail "release.$twin tagged v9.9.0 twice"
  printf '%s\n' "$out" | grep -q 'v9.9.0 exists already' || fail "release.$twin does not name the tag that exists: $out"
  if [ "$twin" = sh ]; then
    HOME="$RH" bash "$RD/bin/install.sh" --repo "$RO" --dir "$RH/.setup-ai-core" --no-path --no-doctor > "$WORK/rel-$twin-install.log" 2>&1 || fail "install.sh from the release origin (see $WORK/rel-$twin-install.log)"
  else
    HOME="$RH" USERPROFILE="$(native "$RH")" pwsh -NoProfile -File "$RD/bin/install.ps1" -Repo "$(native "$RO")" -Dir "$(native "$RH/.setup-ai-core")" -NoPath -NoDoctor > "$WORK/rel-$twin-install.log" 2>&1 || fail "install.ps1 from the release origin (see $WORK/rel-$twin-install.log)"
  fi
  grep -aq '==> release v9.9.0' "$WORK/rel-$twin-install.log" || fail "install.$twin did not report the release it checked out"
  [ "$(git -C "$RH/.setup-ai-core" describe --tags --exact-match HEAD 2>/dev/null)" = v9.9.0 ] || fail "install.$twin did not check out v9.9.0"
  rc=0; out="$(upd --check)" || rc=$?
  [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q '^setup-ai-core: current (v9.9.0)$' || fail "update.$twin --check on the newest release: exit $rc, $out"
  : > "$GH_FAKE/run-pending"   # the first answer of gh: the run is still going
  out="$(rel 9.9.1)" || fail "release.$twin 9.9.1 from a VERSION that carries 9.9.0: $out"
  printf '%s\n' "$out" | grep -q "^release: VERSION 9.9.0 -> 9.9.1, committed as 'release: 9.9.1'$" || fail "release.$twin did not say it wrote VERSION: $out"
  printf '%s\n' "$out" | grep -q '^release: waiting for the checks of [0-9a-f]\{7\} (asked every 1s, 30 minute(s) at most)$' || fail "release.$twin did not wait for the run that was still going: $out"
  [ "$(tr -d '\r\n' < "$RD/VERSION")" = 9.9.1 ] || fail "release.$twin left VERSION at $(cat "$RD/VERSION")"
  [ "$(git -C "$RD" log -1 --format=%s)" = 'release: 9.9.1' ] || fail "release.$twin did not commit 'release: 9.9.1': $(git -C "$RD" log -1 --format=%s)"
  [ "$(git -C "$RD" show --pretty=format: --name-only HEAD | grep -v '^$')" = VERSION ] || fail "release.$twin committed more than VERSION"
  [ "$(git -C "$RO" rev-parse main)" = "$(git -C "$RD" rev-parse HEAD)" ] || fail "release.$twin did not push the release commit"
  git -C "$RO" rev-parse -q --verify refs/tags/v9.9.1 > /dev/null || fail "release.$twin did not push v9.9.1 to the origin"
  [ -z "$(git -C "$RD" status --porcelain)" ] || fail "release.$twin left the tree dirty: $(git -C "$RD" status --porcelain)"
  rc=0; out="$(upd --check)" || rc=$?
  [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -q '^setup-ai-core: release v9.9.1 available (this machine: v9.9.0)$' || fail "update.$twin --check with a newer release: exit $rc, $out"
  out="$(upd)" || fail "update.$twin: $out"
  printf '%s\n' "$out" | grep -q 'release v9.9.1 (was v9.9.0)' || fail "update.$twin did not move to v9.9.1: $out"
  [ "$(git -C "$RH/.setup-ai-core" describe --tags --exact-match HEAD 2>/dev/null)" = v9.9.1 ] || fail "update.$twin left the clone on $(git -C "$RH/.setup-ai-core" describe --tags --always HEAD)"
  rc=0; out="$(upd --check)" || rc=$?
  [ "$rc" -eq 0 ] || fail "update.$twin --check after the update: exit $rc, $out"
  out="$(upd --main)" || fail "update.$twin --main: $out"
  printf '%s\n' "$out" | grep -q 'follows main' || fail "update.$twin --main did not follow main: $out"
  [ "$(git -C "$RH/.setup-ai-core" symbolic-ref --short -q HEAD)" = main ] || fail "update.$twin --main did not check main out"
  out="$(upd)" || fail "update.$twin back from main: $out"
  [ "$(git -C "$RH/.setup-ai-core" describe --tags --exact-match HEAD 2>/dev/null)" = v9.9.1 ] || fail "update.$twin did not move a clean clone from main to the newest release"
  printf 'local\n' > "$RH/.setup-ai-core/scratch.txt"
  out="$(upd)" || fail "update.$twin with a dirty clone: $out"
  printf '%s\n' "$out" | grep -q 'left alone (1 uncommitted change(s), 0 commit(s) not pushed)' || fail "update.$twin touched a dirty clone: $out"
  unset -f rel upd
done
echo "  refused dirty and twice; an unpushed commit pushed and tagged; 9.9.1 written into VERSION, committed, pushed, waited for and tagged; v9.9.0 installed, v9.9.1 announced and moved to, main followed on request, a dirty clone left alone, on both twins"
exit 0
