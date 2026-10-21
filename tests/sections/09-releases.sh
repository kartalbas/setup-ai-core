#!/usr/bin/env bash
# releases, install and update; one section of the suite, run by tests/check.sh with the others
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

section "releases: release commits VERSION, pushes, waits for the green run and tags; install checks the newest release out; update moves to it and --check reports"
make_gh_fake
RO="$WORK/rel-origin.git"; git init -q --bare -b main "$RO"
RD="$WORK/rel-dev"; mkdir -p "$RD"
(cd "$ROOT" && git ls-files -co --exclude-standard -z | tar --null -cf - -T -) | tar -xf - -C "$RD"   # the working tree, not a clone
git init -q -b main "$RD"; git -C "$RD" add -A; git -C "$RD" commit -q -m 'The tree #1'
git -C "$RD" remote add origin "$RO"
printf '9.9.0\n' > "$RD/VERSION"; git -C "$RD" commit -q -am 'release: 9.9.0'
git -C "$RD" push -q -u origin main 2>/dev/null
git -C "$RD" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/gone   # a branch the origin no longer has, as a clone keeps it after a rename: the origin names its default branch
RH="$WORK/rel-home"; mkdir -p "$RH"
rel() { AI_CORE_RELEASE_POLL=1 PATH="$PATH_SH" bash "$RD/bin/release.sh" "$@" 2>&1; }
upd() { (cd "$RH" && HOME="$RH" bash "$RH/.setup-ai-core/bin/update.sh" "$@" 2>&1); }
printf 'dirty\n' > "$RD/dirty.txt"
out="$(rel 9.9.0)" && fail "release.sh released from a tree that is not clean"
grep -q 'the tree is not clean' <<< "$out" || fail "release.sh does not name the dirty tree: $out"
rm -f "$RD/dirty.txt"
printf 'x\n' > "$RD/scratch.txt"; git -C "$RD" add scratch.txt; git -C "$RD" commit -q -m 'Add scratch #1'
out="$(rel 9.9.0)" || fail "release.sh refused a clean commit that was not pushed yet: $out"
grep -q '^release: [0-9a-f]\{7\} pushed to origin/main$' <<< "$out" || fail "release.sh did not say it pushed the commit: $out"
grep -q '^release: v9.9.0 on ' <<< "$out" || fail "release.sh did not report the tag: $out"
grep -q 'VERSION 9.9.0' <<< "$out" && fail "release.sh wrote VERSION although it carried the version: $out"
[ "$(git -C "$RO" rev-parse main)" = "$(git -C "$RD" rev-parse HEAD)" ] || fail "release.sh did not push the commit to the origin"
git -C "$RO" rev-parse -q --verify refs/tags/v9.9.0 > /dev/null || fail "release.sh did not push v9.9.0 to the origin"
out="$(rel 9.9.0)" && fail "release.sh tagged v9.9.0 twice"
grep -q 'v9.9.0 exists already' <<< "$out" || fail "release.sh does not name the tag that exists: $out"
HOME="$RH" bash "$RD/bin/install.sh" --repo "$RO" --dir "$RH/.setup-ai-core" --no-path --no-doctor > "$WORK/rel-install.log" 2>&1 || fail "install.sh from the release origin (see $WORK/rel-install.log)"
grep -aq '==> release v9.9.0' "$WORK/rel-install.log" || fail "install.sh did not report the release it checked out"
[ "$(git -C "$RH/.setup-ai-core" describe --tags --exact-match HEAD 2>/dev/null)" = v9.9.0 ] || fail "install.sh did not check out v9.9.0"
rc=0; out="$(upd --check)" || rc=$?
[ "$rc" -eq 0 ] && grep -q '^setup-ai-core: current (v9.9.0)$' <<< "$out" || fail "update.sh --check on the newest release: exit $rc, $out"
: > "$GH_FAKE/run-fail"      # the first query of gh fails, as a query does now and then
: > "$GH_FAKE/run-pending"   # the next answer: the run is still going, and a commit lands on the branch meanwhile
out="$(GH_FAKE_MOVE="$RD" rel 9.9.1)" || fail "release.sh 9.9.1 from a VERSION that carries 9.9.0, one gh query failing on the way: $out"
grep -q "^release: VERSION 9.9.0 -> 9.9.1, committed as 'release: 9.9.1'$" <<< "$out" || fail "release.sh did not say it wrote VERSION: $out"
grep -q '^release: waiting for the checks of [0-9a-f]\{7\} (asked every 1s, 30 minute(s) at most)$' <<< "$out" || fail "release.sh did not wait for the run that was still going: $out"
[ "$(tr -d '\r\n' < "$RD/VERSION")" = 9.9.1 ] || fail "release.sh left VERSION at $(cat "$RD/VERSION")"
[ "$(git -C "$RD" log -1 --format=%s HEAD)" = 'moved during the wait' ] || fail "the stand-in gh did not put a commit on the branch during the wait"
[ "$(git -C "$RD" log -1 --format=%s HEAD~1)" = 'release: 9.9.1' ] || fail "release.sh did not commit 'release: 9.9.1': $(git -C "$RD" log -1 --format=%s HEAD~1)"
[ "$(git -C "$RD" show --pretty=format: --name-only HEAD~1 | grep -v '^$')" = VERSION ] || fail "release.sh committed more than VERSION"
[ "$(git -C "$RO" rev-parse main)" = "$(git -C "$RD" rev-parse HEAD~1)" ] || fail "release.sh did not push the release commit"
git -C "$RO" rev-parse -q --verify refs/tags/v9.9.1 > /dev/null || fail "release.sh did not push v9.9.1 to the origin"
[ "$(git -C "$RO" rev-parse 'v9.9.1^{commit}')" = "$(git -C "$RD" rev-parse HEAD~1)" ] || fail "release.sh tagged a commit it did not wait for: v9.9.1 is on '$(git -C "$RO" log -1 --format=%s 'v9.9.1^{commit}')'"
[ -z "$(git -C "$RD" status --porcelain)" ] || fail "release.sh left the tree dirty: $(git -C "$RD" status --porcelain)"
rc=0; out="$(upd --check)" || rc=$?
[ "$rc" -eq 2 ] && grep -q '^setup-ai-core: release v9.9.1 available (this machine: v9.9.0)$' <<< "$out" || fail "update.sh --check with a newer release: exit $rc, $out"
out="$(upd)" || fail "update.sh: $out"
grep -q 'release v9.9.1 (was v9.9.0)' <<< "$out" || fail "update.sh did not move to v9.9.1: $out"
[ "$(git -C "$RH/.setup-ai-core" describe --tags --exact-match HEAD 2>/dev/null)" = v9.9.1 ] || fail "update.sh left the clone on $(git -C "$RH/.setup-ai-core" describe --tags --always HEAD)"
rc=0; out="$(upd --check)" || rc=$?
[ "$rc" -eq 0 ] || fail "update.sh --check after the update: exit $rc, $out"
out="$(upd --main)" || fail "update.sh --main: $out"
grep -q 'follows main' <<< "$out" || fail "update.sh --main did not follow main: $out"
[ "$(git -C "$RH/.setup-ai-core" symbolic-ref --short -q HEAD)" = main ] || fail "update.sh --main did not check main out"
out="$(upd)" || fail "update.sh back from main: $out"
[ "$(git -C "$RH/.setup-ai-core" describe --tags --exact-match HEAD 2>/dev/null)" = v9.9.1 ] || fail "update.sh did not move a clean clone from main to the newest release"
printf 'local\n' > "$RH/.setup-ai-core/scratch.txt"
out="$(upd)" || fail "update.sh with a dirty clone: $out"
grep -q 'left alone (1 uncommitted change(s), 0 commit(s) not pushed)' <<< "$out" || fail "update.sh touched a dirty clone: $out"
git clone -q "$RO" "$RH/x-ai-core" 2>/dev/null; git -C "$RH/x-ai-core" checkout -q --detach HEAD~1   # a harness clone, detached and one commit behind
git -C "$RH/x-ai-core" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/gone
rc=0; out="$(upd --check)" || rc=$?
[ "$rc" -eq 2 ] && grep -q '^x-ai-core: behind by 1 commit(s)$' <<< "$out" || fail "update.sh --check did not measure a detached harness clone against the origin's default branch: $out"
: > "$GH_FAKE/run-broken"    # a gh that never answers: the deadline ends the wait and names what gh said
rc=0; out="$(AI_CORE_RELEASE_WAIT=0 rel 9.9.2)" || rc=$?
rm -f "$GH_FAKE/run-broken"
[ "$rc" -ne 0 ] && grep -q 'until the deadline; it said last: HTTP 502: Bad Gateway (is gh logged in?)$' <<< "$out" || fail "release.sh with a gh that never answers: exit $rc, $out"
git -C "$RO" rev-parse -q --verify refs/tags/v9.9.2 > /dev/null && fail "release.sh tagged v9.9.2 without an answer from gh"
# The real gate reaches a release through its push: one wait for a lower load at the one local check, none at the tag push
. "$ROOT/tests/load-stubs.sh"; make_load_stubs "$WORK/loadstubs"
printf 'claude\tmode\talways\t-\t-\n' > "$WORK/modes-green.tsv"
mkdir -p "$WORK/gate-hooks" "$RD/scripts" "$RD/.ai-core"; printf '#!/bin/sh\nexec bash "%s/bin/pre-push.sh" "$@"\n' "$RD" > "$WORK/gate-hooks/pre-push"; chmod +x "$WORK/gate-hooks/pre-push"
printf '#!/usr/bin/env bash\ncat "$PROBE_STATE/clock" >> "%s"\necho "check: OK"\n' "$WORK/release-checks.txt" > "$RD/scripts/check.sh"; chmod +x "$RD/scripts/check.sh"
printf '.ai-core/\n' >> "$RD/.git/info/exclude"; printf 'PRE_PUSH_LOAD_LIMIT="24"\nPRE_PUSH_LOAD_WAIT_SECONDS="300"\n' > "$RD/.ai-core/config.env"
git -C "$RD" config user.email check@localhost; git -C "$RD" config user.name check
git -C "$RD" add scripts/check.sh; git -C "$RD" commit -q -m 'Plant the check #1'
git -C "$RD" config core.hooksPath "$WORK/gate-hooks"
PROBE_STATE="$WORK/load-state"; plan_load "$PROBE_STATE" 25 24 23.5; : > "$WORK/release-checks.txt"
out="$(TEAM_MODES_FILE="$WORK/modes-green.tsv" PROBE_STATE="$PROBE_STATE" PATH="$WORK/loadstubs:$PATH_SH" AI_CORE_RELEASE_POLL=1 bash "$RD/bin/release.sh" 9.9.3 2>&1)" || fail "release.sh 9.9.3 through the real gate: $out"
[ "$(grep -c 'waiting for the 1-minute load to fall below 24; it is 25' <<< "$out")" = 1 ] || fail "the release did not show the wait for a lower load once: $out"
[ "$(tr '\n' ' ' < "$PROBE_STATE/sleeps")" = '5 5 ' ] || fail "the release slept $(tr '\n' ' ' < "$PROBE_STATE/sleeps") instead of two polls of the gate: the wait is not the gate's alone, or the reading of the checks was delayed by the load"
[ "$(cat "$PROBE_STATE/uptime-calls")" = 3 ] || fail "the load was read $(cat "$PROBE_STATE/uptime-calls") times: the tag push, which sends no commit, must not wait"
[ "$(cat "$WORK/release-checks.txt")" = 1010 ] || fail "the check did not run once, after the wait: $(cat "$WORK/release-checks.txt" | tr '\n' ' ')"
[ "$(git -C "$RO" rev-parse 'v9.9.3^{commit}')" = "$(git -C "$RO" rev-parse main)" ] || fail "v9.9.3 is not on the release commit the gate let out"
echo "  refused dirty and twice; the real gate waited once for a lower load at the release commit and not at the tag; an unpushed commit pushed and tagged; 9.9.1 written into VERSION, committed, pushed, waited for and tagged on the commit waited for, not on one made meanwhile; v9.9.0 installed, v9.9.1 announced and moved to, main followed on request, a dirty clone left alone"
exit 0
