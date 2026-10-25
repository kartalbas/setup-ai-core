#!/usr/bin/env bash
# Local-only repositories prove default refresh preserves every dirty checkout and held worktree.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export HOME="$WORK/home" AI_CORE_HOME="$WORK/core"
mkdir -p "$HOME" "$AI_CORE_HOME"
. "$ROOT/lib/common.sh"
[ "$(type -t fast_forward_default_branch)" = function ] || fail 'default refresh helper missing'
git_() { command git -c user.name=test -c user.email=test@example.invalid "$@"; }
sequence=0
# fixture [default] [the body of scripts/install.sh, which then is tracked with an ignored `installed`]
fixture() {
 sequence=$((sequence+1)); default="${1:-main}"; dir="$WORK/case-$sequence"; mkdir -p "$dir"
 seed="$dir/seed"; repo="$dir/checkout"; remote="$dir/origin.git"
 git_ init -q -b "$default" "$seed"
 if [ -n "${2:-}" ]; then
  mkdir -p "$seed/scripts"; printf '%s\n' "$2" > "$seed/scripts/install.sh"; printf 'installed\n' > "$seed/.gitignore"
  git_ -C "$seed" add scripts .gitignore
 fi
 printf 'base\n' > "$seed/tracked"; git_ -C "$seed" add tracked; git_ -C "$seed" commit -qm base
 git clone -q --bare "$seed" "$remote"; git clone -q "$remote" "$repo"
 git_ -C "$seed" remote add origin "$remote"
 for number in one two; do printf '%s\n' "$number" > "$seed/remote-file"; git_ -C "$seed" add remote-file; git_ -C "$seed" commit -qm "$number"; done
 git_ -C "$seed" push -q origin "$default"
}
state() {
 local path="$1" file
 command git -C "$path" for-each-ref --format='%(refname) %(objectname)'
 command git -C "$path" rev-parse HEAD
 command git -C "$path" symbolic-ref -q HEAD || true
 GIT_OPTIONAL_LOCKS=0 command git -C "$path" status --porcelain=v1
 command git -C "$path" diff --binary
 command git -C "$path" diff --cached --binary
 for file in index FETCH_HEAD MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
  location="$(command git -C "$path" rev-parse --path-format=absolute --git-path "$file")"
  if [ -f "$location" ]; then printf '%s ' "$file"; command git hash-object "$location"; else printf '%s absent\n' "$file"; fi
 done
 ( cd "$path" && command git ls-files -co --exclude-standard | sort -u | while IFS= read -r file; do [ ! -f "$file" ] || { printf '%s ' "$file"; command git hash-object "$file"; }; done )
}
git() { [ -z "${RECORD_GIT:-}" ] || printf '%s\n' "$*" >> "$RECORD_GIT"; command git "$@"; }
refresh() { : > "$dir/calls"; rc=0; RECORD_GIT="$dir/calls" fast_forward_default_branch "$repo" > "$dir/out" 2>&1 || rc=$?; }
unchanged() {
 before="$(state "$repo")"; refresh
 [ "$rc" -ne 0 ] || fail 'unsafe refresh reported success'
 [ "$before" = "$(state "$repo")" ] || fail "dirty refresh changed state: $(cat "$dir/out")"
 ! grep -q ' fetch ' "$dir/calls" || fail 'dirty refusal fetched'
 grep -qF "$repo" "$dir/out" || fail 'refusal omitted checkout path'
}
for default in main master; do
 fixture "$default"; refresh; [ "$rc" = 0 ] || fail "clean refresh: $(cat "$dir/out")"
 [ "$(command git -C "$repo" rev-parse HEAD)" = "$(command git --git-dir="$remote" rev-parse "$default")" ] || fail 'clean checkout stayed behind'
 refresh; [ "$rc" = 0 ] || fail 'already current checkout refused'
done
for kind in staged unstaged untracked unmerged rebase; do
 fixture
 case "$kind" in
  staged) printf 'mine\n' > "$repo/tracked"; git_ -C "$repo" add tracked ;;
  unstaged) printf 'mine\n' > "$repo/tracked" ;;
  untracked) printf 'mine\n' > "$repo/loose" ;;
  unmerged)
   git_ -C "$repo" switch -qc conflict; printf 'other\n' > "$repo/tracked"; git_ -C "$repo" commit -qam other
   git_ -C "$repo" switch -q "$default"; printf 'mine\n' > "$repo/tracked"; git_ -C "$repo" commit -qam mine
   git_ -C "$repo" merge conflict > /dev/null 2>&1 && fail 'conflict fixture did not conflict' ;;
  rebase) mkdir "$(command git -C "$repo" rev-parse --path-format=absolute --git-path rebase-merge)" ;;
 esac
 unchanged
done
fixture; git_ -C "$repo" switch -qc feature; printf 'mine\n' > "$repo/tracked"; unchanged
fixture; touch "$repo/tracked"; printf 'mine\n' > "$repo/loose"; unchanged
for kind in ahead diverged; do
 fixture
 if [ "$kind" = ahead ]; then command git -C "$repo" fetch -q origin; command git -C "$repo" merge -q --ff-only "origin/$default"; fi
 printf 'mine\n' > "$repo/local-file"; git_ -C "$repo" add local-file; git_ -C "$repo" commit -qm mine
 tip="$(command git -C "$repo" rev-parse "$default")"; refresh
 [ "$rc" -ne 0 ] || fail "$kind was reported current"
 [ "$tip" = "$(command git -C "$repo" rev-parse "$default")" ] || fail "$kind default moved"
 grep -q 'local commits' "$dir/out" || fail "$kind reason missing"
done
for kind in feature detached; do
 fixture
 if [ "$kind" = feature ]; then git_ -C "$repo" switch -qc feature; else git_ -C "$repo" switch -q --detach; fi
 head="$(command git -C "$repo" rev-parse HEAD)"; index="$(command git hash-object "$(command git -C "$repo" rev-parse --path-format=absolute --git-path index)")"
 refresh; [ "$rc" = 0 ] || fail "$kind refresh: $(cat "$dir/out")"
 [ "$head" = "$(command git -C "$repo" rev-parse HEAD)" ] || fail 'selected HEAD moved'
 [ "$index" = "$(command git hash-object "$(command git -C "$repo" rev-parse --path-format=absolute --git-path index)")" ] || fail 'selected index changed'
 [ ! -e "$repo/remote-file" ] && [ "$(cat "$repo/tracked")" = base ] || fail 'selected files changed'
 [ "$(command git -C "$repo" rev-parse "$default")" = "$(command git --git-dir="$remote" rev-parse "$default")" ] || fail 'unheld default stayed behind'
done
fixture; git_ -C "$repo" switch -qc feature
held="$dir/held checkout"; command git -C "$repo" worktree add -q "$held" "$default"
printf 'held work\n' > "$held/tracked"; before="$(state "$held")"; tip="$(command git -C "$repo" rev-parse "$default")"
refresh; [ "$rc" -ne 0 ] || fail 'held default reported refreshed'
[ "$tip" = "$(command git -C "$repo" rev-parse "$default")" ] || fail 'held default moved'
[ "$(cat "$held/tracked")" = 'held work' ] || fail 'held work changed'
grep -qF "$held" "$dir/out" || fail 'holding worktree omitted'
for kind in unreachable missing; do
 fixture
 if [ "$kind" = unreachable ]; then command git -C "$repo" remote set-url origin "$dir/absent.git"
 else command git -C "$repo" switch -q --detach; command git -C "$repo" branch -D "$default" >/dev/null; fi
 tip="$(command git -C "$repo" rev-parse HEAD)"; refresh
 [ "$rc" -ne 0 ] || fail "$kind reported refreshed"
 [ "$tip" = "$(command git -C "$repo" rev-parse HEAD)" ] || fail "$kind changed HEAD"
 grep -qF "$repo" "$dir/out" || fail "$kind omitted path"
done
# A refresh that moves the checked-out default runs the repository's install there once; one that moves
# nothing, or only an unheld default, runs none; a failing install is named and not a finished refresh.
fixture main 'printf "run\n" >> installed'; refresh
[ "$rc" = 0 ] || fail "install refresh: $(cat "$dir/out")"
[ "$(cat "$repo/installed" 2>/dev/null)" = run ] || fail 'a moved checkout was not installed'
grep -qF "installed: scripts/install.sh ran in $repo" "$dir/out" || fail 'the install was not named'
refresh; [ "$rc" = 0 ] && [ "$(wc -l < "$repo/installed")" -eq 1 ] || fail 'a current checkout was installed again'
fixture main 'printf "run\n" >> installed'; git_ -C "$repo" switch -qc feature; refresh
[ "$rc" = 0 ] && [ ! -e "$repo/installed" ] || fail 'an unheld default refresh ran the install'
fixture main 'echo boom >&2; exit 1'; refresh
[ "$rc" -ne 0 ] || fail 'a failing install reported a finished refresh'
grep -qF "not installed: $repo: scripts/install.sh failed after the refresh: boom" "$dir/out" || fail "the failing install was not named: $(cat "$dir/out")"
# The same preservation assertion must detect both a removed guard and a fetch moved before it.
mutant="$WORK/mutant"; mkdir -p "$mutant/lib"
for kind in no-guard early-fetch; do
 fixture; printf 'mine\n' > "$repo/tracked"
 if [ "$kind" = no-guard ]; then
  sed 's/if \[ -n "$dirty" \]; then/if false; then/' "$ROOT/lib/common.sh" > "$mutant/lib/common.sh"
 else
  sed 's/^fast_forward_default_branch() {/fast_forward_default_branch_real() {/' "$ROOT/lib/common.sh" > "$mutant/lib/common.sh"
  printf '\nfast_forward_default_branch() { git -C "$1" fetch -q origin; fast_forward_default_branch_real "$1"; }\n' >> "$mutant/lib/common.sh"
 fi
 before="$(state "$repo")"
 ( . "$mutant/lib/common.sh"; refresh ) || true
 [ "$before" != "$(state "$repo")" ] || fail "$kind mutant escaped full-state check"
 grep -q ' fetch ' "$dir/calls" || fail "$kind mutant escaped fetch-call check"
done
# A forced ref update must be rejected by the local-only-commit assertion.
fixture; printf 'mine\n' > "$repo/local-file"; git_ -C "$repo" add local-file; git_ -C "$repo" commit -qm mine
before="$(command git -C "$repo" rev-parse "$default")"
sed 's/^fast_forward_default_branch() {/fast_forward_default_branch_real() {/' "$ROOT/lib/common.sh" > "$mutant/lib/common.sh"
printf '\nfast_forward_default_branch() { git -C "$1" fetch -q origin; git -C "$1" update-ref refs/heads/main refs/remotes/origin/main; }\n' >> "$mutant/lib/common.sh"
( . "$mutant/lib/common.sh"; refresh )
[ "$before" != "$(command git -C "$repo" rev-parse "$default")" ] || fail 'forced-update mutant escaped'
echo 'all default branch safety states, mutations, and controls passed'
