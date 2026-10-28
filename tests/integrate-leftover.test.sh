#!/usr/bin/env bash
# The temporary worktree of a landing (integrate-issue --from-origin) stands in .worktrees/<repository>/ beside the
# issue worktrees: init --all passes over it, and doctor names one whose landing no longer runs, with the command
# that removes it. Each defect is planted and shown red, and the innocent case beside it green.
#
#   bash tests/integrate-leftover.test.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export HOME="$WORK/home" AI_CORE_HOME="$WORK/ai-core-home"; mkdir -p "$HOME" "$AI_CORE_HOME"
make_gh_fake

# a project folder with one repository, an issue worktree, and the shapes a landing's temporary worktree has
FOLDER="$WORK/folder"; APP="$FOLDER/app"
mkdir -p "$FOLDER/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$FOLDER/.ai-core/config.env"
git init -q "$APP"; mkdir -p "$APP/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$APP/.ai-core/config.env"; git -C "$APP" commit -q --allow-empty -m start
git -C "$APP" worktree add -q -b issue-1-work "$FOLDER/.worktrees/app/issue-1-work"
git -C "$APP" worktree add -q --detach "$FOLDER/.worktrees/app/integrate-7.abc123"
git -C "$APP" worktree add -q --detach "$FOLDER/.worktrees/app/integrate-8.def456"
git init -q "$FOLDER/solo"; mkdir -p "$FOLDER/solo/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$FOLDER/solo/.ai-core/config.env"; git -C "$FOLDER/solo" commit -q --allow-empty -m start
git -C "$FOLDER/solo" worktree add -q --detach "$FOLDER/.worktrees/solo/integrate-3.xyz789"   # the only worktree of its repository: nothing for the sweep to look at
mkdir -p "$FOLDER/.worktrees/app/integrate-9.ghi789"   # a landing killed between the folder and the worktree: no worktree stands in it
# a repository whose own name starts like a temporary worktree's, under an issue folder: it is work, not a leftover
git init -q "$WORK/other-tool"; git -C "$WORK/other-tool" commit -q --allow-empty -m start
git -C "$WORK/other-tool" worktree add -q --detach "$FOLDER/.worktrees/issue-5-pkg/integrate-tool"
# a name that starts like a temporary worktree's, a digit first, and goes on with text: work as well, not a leftover
git -C "$WORK/other-tool" worktree add -q --detach "$FOLDER/.worktrees/issue-6-pkg/integrate-7-release.abc123"
carry_harness "$APP" "$FOLDER/solo" "$WORK/other-tool"
APP_REAL="$(cd "$APP" && pwd -P)"; TREE7="$(cd "$FOLDER/.worktrees/app/integrate-7.abc123" && pwd -P)"

section "init --all passes over the temporary worktree of a landing"
init_all() { ( cd "$FOLDER" && PATH="$PATH_SH" bash "${1:-$ROOT}/bin/init.sh" --all "$FOLDER" --no-doctor 2>&1 ) || true; }
out="$(init_all)"
! grep -q 'integrate-7.abc123' <<< "$out" || fail "init --all reports the temporary worktree of a landing: $(grep integrate-7 <<< "$out")"
[ ! -e "$FOLDER/.worktrees/app/integrate-7.abc123/.ai-core" ] || fail "init --all initialized the temporary worktree of a landing"
! grep -q '### solo: worktrees whose work landed' <<< "$out" || fail "init --all sweeps a repository whose only other worktree is the temporary worktree of a landing"
grep -q '^### \.worktrees/app/issue-1-work$' <<< "$out" && [ -f "$FOLDER/.worktrees/app/issue-1-work/.ai-core/rules/rules.md" ] || fail "innocent: init --all skipped an issue worktree"
grep -q '^### \.worktrees/issue-5-pkg/integrate-tool$' <<< "$out" && [ -f "$FOLDER/.worktrees/issue-5-pkg/integrate-tool/.ai-core/rules/rules.md" ] || fail "innocent: init --all skipped a repository named integrate-tool"
grep -q '^### \.worktrees/issue-6-pkg/integrate-7-release\.abc123$' <<< "$out" && [ -f "$FOLDER/.worktrees/issue-6-pkg/integrate-7-release.abc123/.ai-core/rules/rules.md" ] || fail "innocent: init --all skipped a worktree named integrate-7-release.abc123, whose issue number is not digits alone"
echo "  init --all: the worktrees integrate-7.abc123 and integrate-8.def456 are passed over; an issue worktree and the repositories named integrate-tool and integrate-7-release.abc123 are initialized"
planted="$WORK/planted"; mkdir -p "$planted"; cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/templates" "$ROOT/skills" "$ROOT/rules" "$ROOT/skeleton" "$ROOT/auto-mode.tsv" "$planted/" 2>/dev/null; cp "$ROOT/VERSION" "$planted/"
sed -i.bak '/\$LANDING_WORKTREE_RE \]\] && continue/d' "$planted/bin/init.sh"
cmp -s "$ROOT/bin/init.sh" "$planted/bin/init.sh" && fail "the planted copy equals the real init.sh"
out="$(init_all "$planted")"
grep -q '^### \.worktrees/app/integrate-7.abc123$' <<< "$out" || fail "planted: a copy that does not skip the temporary worktree does not walk it, so the check cannot go red"
echo "  planted: a copy without the skip walks the temporary worktree and the check sees it"

section "doctor names a temporary worktree whose landing no longer runs, and the command that removes it"
doctor_lines() { ( cd "$FOLDER" && PATH="$PATH_SH" bash "${1:-$ROOT}/bin/doctor.sh" --no-install 2>&1 ) || true; }
leftovers() { grep '^  landing ' <<< "$1" || true; }
out="$(doctor_lines)"
[ "$(leftovers "$out" | wc -l | tr -d ' ')" = 4 ] || fail "doctor should name the four leftovers, not these: $(leftovers "$out")"
grep -q "integrate-7.abc123 is what a landing of issue 7 left behind; no running landing holds it. Remove it with: git -C $APP_REAL worktree remove --force $TREE7\$" <<< "$out" || fail "the registered leftover is not named with its removal: $(leftovers "$out")"
grep -q "integrate-9.ghi789 is what a landing of issue 9 left behind; no running landing holds it. Remove it with: rm -r " <<< "$out" || fail "the leftover with no worktree is not named with rm -r: $(leftovers "$out")"
! grep -q 'issue-1-work\|integrate-tool\|integrate-7-release' <<< "$(leftovers "$out")" || fail "innocent: doctor names an issue worktree or a repository: $(leftovers "$out")"
[ -d "$FOLDER/.worktrees/app/integrate-7.abc123" ] && [ -d "$FOLDER/.worktrees/app/integrate-9.ghi789" ] || fail "doctor removed a leftover"
git -C "$APP" worktree list | grep -q 'integrate-7.abc123' || fail "doctor unregistered a leftover"
echo "  doctor: four leftovers named, each with its command (git worktree remove for a registered one, rm -r for a folder git does not know), an issue worktree and a repository left out, nothing removed"
planted_shape="$WORK/planted-shape"; mkdir -p "$planted_shape"; cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/templates" "$planted_shape/"; cp "$ROOT/VERSION" "$planted_shape/"
sed -i.bak '/\$LANDING_WORKTREE_RE \]\] || continue/d' "$planted_shape/bin/doctor.sh"
cmp -s "$ROOT/bin/doctor.sh" "$planted_shape/bin/doctor.sh" && fail "the planted copy equals the real doctor.sh"
grep -q 'integrate-7-release.abc123 is what a landing of issue 7-release left behind' <<< "$(doctor_lines "$planted_shape")" || fail "planted: a doctor that takes any name with a digit first for a landing's does not name integrate-7-release.abc123, so the check cannot go red"
echo "  planted: a doctor that takes a digit and any text for an issue number names integrate-7-release.abc123 as a leftover of issue 7-release"
# the command it prints works
eval "$(grep -o 'git -C [^ ]* worktree remove --force [^ ]*' <<< "$(leftovers "$out" | grep 'integrate-7')" | head -n1)" || fail "the printed command does not remove the leftover"
[ ! -e "$FOLDER/.worktrees/app/integrate-7.abc123" ] || fail "the printed command left the folder"
git -C "$APP" worktree add -q --detach "$FOLDER/.worktrees/app/integrate-7.abc123"

# a landing that runs holds the lock of the clone with its process id and its issue
sleep 120 & LIVE=$!
trap 'kill "$LIVE" 2>/dev/null || true; [ -n "${KEEP_WORK:-}" ] || rm -rf "$WORK"' EXIT
LOCK="$(git -C "$APP" rev-parse --path-format=absolute --git-common-dir)/ai-core-landing"
printf '%s\t%s\n' "$LIVE" "#7" > "$LOCK"
out="$(doctor_lines)"
! grep -q 'integrate-7.abc123' <<< "$out" || fail "innocent: doctor names the temporary worktree of a landing that runs: $(leftovers "$out")"
grep -q 'integrate-8.def456 is what a landing of issue 8 left behind' <<< "$out" || fail "doctor does not name the leftover of another issue while a landing of issue 7 runs"
printf '%s\t%s\n' "$LIVE" "example-org/other#7" > "$LOCK"
! grep -q 'integrate-7.abc123' <<< "$(doctor_lines)" || fail "innocent: the lock of an issue in another repository's form is not read by its number"
printf '%s\t%s\t%s\n' "$LIVE" "#7" "issue-7-landing" > "$LOCK"
! grep -q 'integrate-7.abc123' <<< "$(doctor_lines)" || fail "innocent: the lock that names its branch is not read by its number"
echo "  doctor: the temporary worktree of issue 7 is not named while a live process holds the lock for issue 7; that of issue 8 still is"
planted_doctor="$WORK/planted-doctor"; mkdir -p "$planted_doctor"; cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/templates" "$planted_doctor/"; cp "$ROOT/VERSION" "$planted_doctor/"
sed -i.bak 's|if ps -p "$pid" >/dev/null 2>&1 \&\& |if |' "$planted_doctor/bin/doctor.sh"
sed -i.bak 's|^  \[ -z "$held" \] \|\| continue$|  :|' "$planted_doctor/bin/doctor.sh"
cmp -s "$ROOT/bin/doctor.sh" "$planted_doctor/bin/doctor.sh" && fail "the planted doctor equals the real one"
grep -q 'integrate-7.abc123' <<< "$(doctor_lines "$planted_doctor")" || fail "planted: a doctor that ignores the lock does not name the live landing, so the check cannot go red"
kill "$LIVE"; wait "$LIVE" 2>/dev/null || true
printf '%s\t%s\n' "$LIVE" "#7" > "$LOCK"
grep -q 'integrate-7.abc123 is what a landing of issue 7 left behind' <<< "$(doctor_lines)" || fail "doctor does not name the leftover of a landing whose process is gone"
rm -f "$LOCK"
echo "  planted: a doctor that ignores the lock names the live landing; a lock whose process is gone holds nothing"

# a leftover is no prerequisite that fails: it must not stop init, which runs doctor first
code_with="$( cd "$FOLDER" && PATH="$PATH_SH" bash "$ROOT/bin/doctor.sh" --no-install > /dev/null 2>&1; echo $? )"
rm -rf "$FOLDER/.worktrees/app/integrate-9.ghi789"; git -C "$FOLDER/solo" worktree remove --force "$FOLDER/.worktrees/solo/integrate-3.xyz789"; git -C "$APP" worktree remove --force "$FOLDER/.worktrees/app/integrate-7.abc123"; git -C "$APP" worktree remove --force "$FOLDER/.worktrees/app/integrate-8.def456"
code_without="$( cd "$FOLDER" && PATH="$PATH_SH" bash "$ROOT/bin/doctor.sh" --no-install > /dev/null 2>&1; echo $? )"
[ "$code_with" = "$code_without" ] || fail "a leftover changes the exit code of doctor: $code_with with, $code_without without"
[ -z "$(leftovers "$(doctor_lines)")" ] || fail "doctor names a leftover after they were all removed"
echo "  a leftover does not change doctor's exit code, and nothing is named once they are removed"
echo "OK"
