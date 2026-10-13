#!/usr/bin/env bash
# init arms the push gate and fills a worktree; one section of the suite, run by tests/check.sh with the others
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

section "init arms a clone that carries .githooks/pre-push: core.hooksPath set, reported, once; a dry run only says so"
H="$WORK/hooks"; git init -q "$H"; mkdir -p "$H/.githooks" "$H/.ai-core"
printf '#!/usr/bin/env bash\nexec ai-core pre-push "$@"\n' > "$H/.githooks/pre-push"; chmod +x "$H/.githooks/pre-push"
printf 'UPDATE_CHECK="never"\n' > "$H/.ai-core/config.env"
bash "$ROOT/bin/init.sh" "$H" --no-doctor --dry-run > "$WORK/hooks-dry.log" 2>&1 || fail "init.sh --dry-run on a repository with the shim (see $WORK/hooks-dry.log)"
bash "$ROOT/bin/init.sh" "$H" --no-doctor > "$WORK/hooks-1.log" 2>&1 || fail "init.sh on a repository with the shim (see $WORK/hooks-1.log)"
bash "$ROOT/bin/init.sh" "$H" --no-doctor > "$WORK/hooks-2.log" 2>&1 || fail "init.sh second run on a repository with the shim"
grep -aq '^  core.hooksPath would be set to .githooks: the push gate runs here$' "$WORK/hooks-dry.log" || fail "init.sh --dry-run does not say core.hooksPath would be set"
grep -aq '^  core.hooksPath set to .githooks: the push gate runs here$' "$WORK/hooks-1.log" || fail "init.sh does not report core.hooksPath"
[ "$(git -C "$H" config --get core.hooksPath)" = ".githooks" ] || fail "init.sh did not set core.hooksPath"
grep -aq 'core.hooksPath' "$WORK/hooks-2.log" && fail "init.sh reports core.hooksPath again on the second run"
cmp -s "$ROOT/templates/.githooks/commit-msg" "$H/.githooks/commit-msg" || fail "init.sh did not write .githooks/commit-msg beside the push gate"
[ -x "$H/.githooks/commit-msg" ] || fail "init.sh wrote .githooks/commit-msg without the executable bit, so git skips it"
git -C "$H" check-ignore -q .githooks/commit-msg || fail "init.sh did not put .githooks/commit-msg into the exclude file"
printf 'one\n' > "$H/one.txt"; git -C "$H" add one.txt
PATH="$ROOT/bin:$PATH" git -C "$H" commit -q -m "$(printf 'A%.0s' {1..73})" > "$WORK/hooks-commit.log" 2>&1 && fail "init.sh: a subject of 73 characters was committed"
grep -aq 'commit-msg: REFUSED' "$WORK/hooks-commit.log" || fail "init.sh: the commit of a subject of 73 was not refused by commit-msg: $(cat "$WORK/hooks-commit.log")"
PATH="$ROOT/bin:$PATH" git -C "$H" commit -q -m "$(printf 'A%.0s' {1..72})" > "$WORK/hooks-commit.log" 2>&1 || fail "init.sh: a subject of 72 characters was refused: $(cat "$WORK/hooks-commit.log")"
O="$WORK/hooks-own"; git init -q "$O"; mkdir -p "$O/.githooks" "$O/.ai-core"
printf '#!/usr/bin/env bash\nexec ai-core pre-push "$@"\n' > "$O/.githooks/pre-push"; printf '#!/usr/bin/env bash\necho own\n' > "$O/.githooks/commit-msg"
printf 'UPDATE_CHECK="never"\n' > "$O/.ai-core/config.env"; git -C "$O" add .githooks
bash "$ROOT/bin/init.sh" "$O" --no-doctor > "$WORK/hooks-own.log" 2>&1 || fail "init.sh on a repository with its own commit-msg"
grep -aq '^echo own$' "$O/.githooks/commit-msg" || fail "init.sh overwrote the commit-msg the repository tracks"
echo "  core.hooksPath set once and reported, the dry run announces it, commit-msg written and judging, a tracked one kept"

section "init in a worktree that starts empty takes the checkout's .ai-core data first; a dry run only says so"
H="$WORK/hooks"; git -C "$H" add -A 2>/dev/null; git -C "$H" commit -q -m 'the tree #1' >/dev/null 2>&1 || true
mkdir -p "$H/.ai-core/rules"; printf '# mine\n' > "$H/.ai-core/rules/rules.local.md"
W="$WORK/hooks-wt"; git -C "$H" worktree add -q --detach "$W" HEAD < /dev/null 2>/dev/null || fail "worktree add"
[ ! -d "$W/.ai-core" ] || fail "the worktree starts with .ai-core (nothing should have written it)"
bash "$ROOT/bin/init.sh" "$W" --no-doctor --dry-run > "$WORK/wt-dry.log" 2>&1 || fail "init.sh --dry-run in a worktree (see $WORK/wt-dry.log)"
[ ! -d "$W/.ai-core" ] || fail "init.sh --dry-run wrote .ai-core into the worktree"
bash "$ROOT/bin/init.sh" "$W" --no-doctor > "$WORK/wt-1.log" 2>&1 || fail "init.sh in a worktree (see $WORK/wt-1.log)"
bash "$ROOT/bin/init.sh" "$W" --no-doctor > "$WORK/wt-2.log" 2>&1 || fail "init.sh second run in a worktree"
grep -aq "^  .ai-core would be taken from the checkout .*hooks: a worktree starts with the checkout's configuration, local rules and documents$" "$WORK/wt-dry.log" || fail "init.sh --dry-run does not say the checkout's .ai-core would be taken"
grep -aq "^  .ai-core taken from the checkout .*hooks: a worktree starts with the checkout's configuration, local rules and documents$" "$WORK/wt-1.log" || fail "init.sh does not report the checkout's .ai-core"
[ "$(cat "$W/.ai-core/rules/rules.local.md")" = '# mine' ] || fail "init.sh did not take the checkout's local rules into the worktree"
grep -q 'UPDATE_CHECK="never"' "$W/.ai-core/config.env" || fail "init.sh did not take the checkout's config.env into the worktree"
grep -aq 'taken from the checkout' "$WORK/wt-2.log" && fail "init.sh reports the checkout's .ai-core again on the second run"
git -C "$H" worktree remove --force "$W" >/dev/null 2>&1
echo "  a worktree gets the checkout's config.env and rules.local.md before the harness is assembled, reported once, the dry run announces it and writes nothing"

section "init hands a checkout whose shims git skips for want of the executable bit to pre-push --install, and names a hook of the project's own git skips; a dry run only says so"
X="$WORK/mode"; git init -q -b master "$X"; mkdir -p "$X/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$X/.ai-core/config.env"
(cd "$X" && bash "$ROOT/bin/pre-push.sh" --install > "$X-install.log" 2>&1) || fail "pre-push --install (see $X-install.log)"
printf '#!/bin/sh\nexit 0\n' > "$X/.githooks/pre-commit"
git -C "$X" add --chmod=-x .githooks/pre-push .githooks/post-checkout .githooks/pre-commit
git -C "$X" -c advice.ignoredHook=false commit -q -m 'The hooks as a copy without the file modes writes them #4'
bash "$ROOT/bin/init.sh" "$X" --no-doctor --dry-run > "$X-dry.log" 2>&1 || fail "init.sh --dry-run on shims without the bit (see $X-dry.log)"
bash "$ROOT/bin/init.sh" "$X" --no-doctor > "$X-1.log" 2>&1 || fail "init.sh on shims without the bit (see $X-1.log)"
grep -aq '^  the shims in .githooks are not executable, so git skips the push gate: ai-core pre-push --install would make them so$' "$X-dry.log" || fail "init.sh --dry-run does not say the shims would be made executable"
grep -aq '^  the shims in .githooks were not executable, so git skipped the push gate: ai-core pre-push --install made them so$' "$X-1.log" || fail "init.sh does not report the shims it had made executable (see $X-1.log)"
[ "$(git -C "$X" ls-tree HEAD -- .githooks/post-checkout .githooks/pre-push | awk '{ print $1 }' | tr '\n' ' ')" = '100755 100755 ' ] || fail "init.sh left the shims without the executable bit in the commit"
grep -aq "^  .githooks/pre-commit is not executable, so git skips it; it is the project's own and stays as it is$" "$X-1.log" || fail "init.sh does not name the project's own hook git skips"
[ "$(git -C "$X" ls-tree HEAD -- .githooks/pre-commit | awk '{ print $1 }')" = 100644 ] || fail "init.sh changed the project's own hook"
echo "  the shims committed with the executable bit through pre-push --install, the project's own hook named and left, the dry run announces it"
exit 0
