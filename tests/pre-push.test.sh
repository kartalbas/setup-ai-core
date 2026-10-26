#!/usr/bin/env bash
# What the push gate lets out of a checkout, and what it refuses.
#
#   bash tests/pre-push.test.sh
#
# NOTHING IS PUSHED and github.com is never reached. A scratch repository is built in a
# temporary directory and git's own input is fed to the gate by hand - one line per ref:
#
#   <local ref> <local sha> <remote ref> <remote sha>
#
# The team modes come from a table of this test (green: every probe passes; red: a probe that
# cannot pass), scripts/check.sh is a stand-in that writes down which working tree it ran in,
# gitleaks is a stub that writes down its arguments, and a stub ai-core writes down what the
# shim hands it. The cases are the ones a hand-written gate got wrong: a push from a worktree, an
# empty `No-issue:` trailer, a LICENSE file under a folder, a remote sha this checkout does not
# carry, a sha of sixty-four zeros, an annotated tag.

set -uo pipefail

# The commits of the scratch repository carry its configured identity, which the gate holds them
# against: an identity in the caller's environment would make every one of them a stranger's.
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fake="$(mktemp -d)"
# Every run of the gate leaves a record under AI_CORE_HOME; a test writes none into the machine's own
export HOME="$fake/home" AI_CORE_HOME="$fake/ai-core-home"
mkdir -p "$HOME" "$AI_CORE_HOME"
trap 'git -C "$fake/checkouts/app" worktree remove --force "$fake/checkouts/.worktrees/app/issue-5-probe" >/dev/null 2>&1; rm -rf "$fake"' EXIT

failed=0
check() {  # name expected actual
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: [$2]"; echo "       actual:   [$3]"; failed=$((failed + 1)); fi
}

parent="$fake/checkouts"
repo="$parent/app"
wt="$parent/.worktrees/app/issue-5-probe"
check_runs="$fake/check-runs.txt"
: > "$check_runs"

# The team modes: a table whose probes pass, and one whose probe cannot. The check reads the rows
# of the tools on PATH, and a stub claude on PATH is the tool it finds.
green="$fake/modes-green.tsv"; red="$fake/modes-red.tsv"
printf 'claude\tmode\talways\t-\t-\ncodex\tmode\talways\t-\t-\n' > "$green"
for tool in claude codex; do printf '%s\tdiagrams\tfile:%s/never-there\tnpx skills add example/diagrams -g\t-\n' "$tool" "$fake"; done > "$red"
export TEAM_MODES_FILE="$green"
stub="$fake/stub"; mkdir -p "$stub"
# The real gitleaks, found before the stub shadows it: one case needs what git really shows it.
real_gitleaks="$(command -v gitleaks || true)"
mkdir -p "$fake/lib"; cp -R "$root/lib/." "$fake/lib/"
printf '#!/usr/bin/env bash\nexit 0\n' > "$stub/claude"
# The gitleaks stub writes down every argument it was given; asked for the help of `gitleaks git`,
# it has the subcommand unless PROBE_LEAKS is old, a gitleaks from before 8.19
leaks_args="$fake/leaks-args.txt"
cat > "$stub/gitleaks" <<EOF
#!/usr/bin/env bash
case "\$*" in *--help) [ "\${PROBE_LEAKS:-green}" != old ]; exit ;; esac
printf '[%s]\n' "\$*" >> "$leaks_args"
[ "\${PROBE_LEAKS:-green}" = green ] || { echo 'gitleaks: a credential stands in this range'; exit 1; }
exit 0
EOF
# The ai-core stub writes down what the shim hands it: its arguments and git's input
shim_args="$fake/shim-args.txt"
# PROBE_RACE names a script the stub runs once, while git waits on the gate, as another session's
# push to the same origin would; PROBE_GATE=red makes the gate refuse.
cat > "$stub/ai-core" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = git-credential ]; then shift; exec bash "$root/bin/git-credential.sh" "\$@"; fi
printf '[%s] ' "\$*" >> "$shim_args"; cat >> "$shim_args"
if [ -n "\${PROBE_RACE:-}" ] && [ ! -e "\$PROBE_RACE.done" ]; then : > "\$PROBE_RACE.done"; bash "\$PROBE_RACE" >/dev/null 2>&1; fi
[ "\${PROBE_GATE:-green}" = green ] || { echo 'gate: refused'; exit 1; }
exit 0
EOF
chmod +x "$stub/claude" "$stub/gitleaks" "$stub/ai-core"
. "$root/tests/load-stubs.sh"; make_load_stubs "$stub"
real_sleep="$(command -v sleep)"; real_mktemp="$(command -v mktemp)"; real_ln="$(command -v ln)"
real_sort="$(command -v sort)"; real_git="$(command -v git)"
cat > "$stub/sort" <<EOF
#!/usr/bin/env bash
if [ "\${PROBE_SORT_FAIL:-}" = paths ] && [ "\$#" -eq 1 ] && [ "\$1" = -u ]; then
  echo 'planted sort failure' >&2; exit 42
fi
exec "$real_sort" "\$@"
EOF
cat > "$stub/git" <<EOF
#!/usr/bin/env bash
if [ "\${PROBE_DIFF_TREE_FAIL:-}" = 1 ] && [ "\${1:-}" = diff-tree ] && [ "\${6:-}" = --diff-filter=AMR ]; then
  echo 'planted diff-tree failure' >&2; exit 42
fi
if [ -n "\${PROBE_CAT_FILE_FAIL:-}" ] && [ "\${1:-}" = cat-file ] && [ "\${2:-}" = -p ] && [ "\${3#*:}" = "\$PROBE_CAT_FILE_FAIL" ]; then
  echo 'planted cat-file failure' >&2; exit 42
fi
if [ -n "\${PROBE_LS_TREE_FAIL:-}" ] && [ "\${1:-}" = ls-tree ] && [ "\${4:-}" = "\$PROBE_LS_TREE_FAIL" ]; then
  echo 'planted ls-tree failure' >&2; exit 42
fi
exec "$real_git" "\$@"
EOF
chmod +x "$stub/sort" "$stub/git"
# While PROBE_LN is fail, no link can be made, as on a filesystem without hard links
cat > "$stub/ln" <<EOF
#!/usr/bin/env bash
[ "\${PROBE_LN:-}" != fail ] || exit 1
exec "$real_ln" "\$@"
EOF
chmod +x "$stub/ln"
# While PROBE_MKTEMP_BARRIER names a folder, the run log's temporary file is made only when two gates
# have both come to make it: the two then meet at the one moment where a log that does not exist is created
cat > "$stub/mktemp" <<EOF
#!/usr/bin/env bash
case "\$*" in *pre-push-runs.tsv*) if [ -n "\${PROBE_MKTEMP_BARRIER:-}" ]; then
  : > "\$PROBE_MKTEMP_BARRIER/at.\$\$"
  for _ in \$(seq 400); do [ "\$(ls "\$PROBE_MKTEMP_BARRIER" | grep -c '^at\.')" -ge 2 ] && break; "$real_sleep" 0.05; done
fi ;; esac
if [ "\$*" = -d ] && [ "\${PROBE_MKTEMP_BLOCK_BLOB:-}" = 1 ]; then
  folder="\$("$real_mktemp" -d)" || exit
  mkdir "\$folder/shebang"
  printf '%s\n' "\$folder"
  exit 0
fi
exec "$real_mktemp" "\$@"
EOF
chmod +x "$stub/mktemp"
export PROBE_STATE="$fake/state-default"; mkdir -p "$PROBE_STATE"; echo 0.10 > "$PROBE_STATE/loads"
# A second ai-core behind the stand-in, the way a developer's shell carries its own: a run without
# ai-core on the PATH has to take both away
machine="$fake/machine"; mkdir -p "$machine"; printf '#!/bin/sh\nexit 0\n' > "$machine/ai-core"; chmod +x "$machine/ai-core"
export PATH="$stub:$machine:$PATH"
# path_without_ai_core: the PATH without every directory that holds an ai-core
path_without_ai_core() {
  local d out=""
  while IFS= read -r d; do [ -z "$d" ] || [ -e "$d/ai-core" ] || [ -e "$d/ai-core.exe" ] || out="${out:+$out:}$d"; done <<< "$(tr ':' '\n' <<< "$PATH")"
  printf '%s' "$out"
}

# The repository: the stand-in check writes down its own path, which says which working tree it
# was started in.
mkdir -p "$repo/scripts" "$repo/bin"
cat > "$repo/scripts/check.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$0" >> "$check_runs"
env | grep '^GIT_CONFIG_\(COUNT\|KEY_\|VALUE_\)' | sort > "$check_runs.git-config"
if [ -n "\${PROBE_CREDENTIAL_CHECK:-}" ]; then bash "\$PROBE_CREDENTIAL_CHECK" || exit \$?; fi
if [ "\${PROBE_CHECK:-green}" = green ]; then echo 'check: OK — every check green'; exit 0; fi
echo 'check: FAIL — the stand-in was told to be red'
exit 1
EOF
chmod +x "$repo/scripts/check.sh"
git -C "$repo" init -q -b master
git -C "$repo" config user.email 'test@example.invalid'
git -C "$repo" config user.name 'test'
git -C "$repo" add -A
git -C "$repo" commit -q -m 'Set the repository up for the gate probe #1'

commit() {  # commit <path> <message> - one file, one commit
  mkdir -p "$repo/$(dirname "$1")"
  printf 'a line\n' >> "$repo/$1"
  git -C "$repo" add -- "$1"
  git -C "$repo" commit -q -F - <<< "$2"
}

# One ref line, fed the way git feeds it. The gate runs with the working tree as its directory,
# which is what git does before it starts a hook.
# The push goes to the default branch, which only a harness landing updates: it carries the mark of one for the commit it lands,
# as the landing paths of the harness write it, so that every case asserts its own rule. A case of the mark itself feeds
# the gate by hand below.
judge() {  # judge <working tree> <local sha> <remote sha>
  local mark rc
  mark="$(bash "$root/lib/landing-check.sh" mark "$1" "$(git -C "$1" rev-parse -q --verify "$2^{commit}" || echo "$2")" refs/heads/master)" || return 1
  printf 'refs/heads/master %s refs/heads/master %s\n' "$2" "$3" \
    | ( cd "$1" && AI_CORE_LANDING_MARK="$mark" ${GATE_TIMEOUT:+timeout "$GATE_TIMEOUT"} bash "${GATE_SCRIPT:-$root/bin/pre-push.sh}" origin 'https://example.invalid/x.git' 2>&1 )
  rc=$?
  bash "$root/lib/landing-check.sh" unmark "$mark"
  return "$rc"
}
only_new() {  # only_new <working tree> - judge the newest commit alone
  judge "$1" "$(git -C "$1" rev-parse HEAD)" "$(git -C "$1" rev-parse HEAD~1)"
}

# The gate in terminal mode on the checked-out branch of a working tree, as the landing of its HEAD would meet it.
marked_terminal_gate() {  # marked_terminal_gate <working tree>
  local mark rc
  mark="$(bash "$root/lib/landing-check.sh" mark "$1" "$(git -C "$1" rev-parse HEAD)" "refs/heads/$(git -C "$1" symbolic-ref --short HEAD)")" || return 1
  ( cd "$1" && AI_CORE_LANDING_MARK="$mark" bash "$root/bin/pre-push.sh" < /dev/null 2>&1 )
  rc=$?
  bash "$root/lib/landing-check.sh" unmark "$mark"
  return "$rc"
}

zeros40='0000000000000000000000000000000000000000'
zeros64='0000000000000000000000000000000000000000000000000000000000000000'

# --- the push from a worktree ------------------------------------------------------------------
#
# Work is done in a worktree at ../.worktrees/<repo>/issue-<n>-<slug>, and the check that runs is
# the one in the tree being pushed, not the main checkout's.
echo 'a push from a worktree runs the check of the WORKTREE'
git -C "$repo" worktree add -q -b issue-5-probe "$wt" master
printf 'a line\n' >> "$wt/notes-5.txt"
git -C "$wt" add -- notes-5.txt
git -C "$wt" commit -q -m 'Probe the gate from a worktree #5'
: > "$check_runs"
out="$(judge "$wt" "$(git -C "$wt" rev-parse HEAD)" "$(git -C "$repo" rev-parse master)")"; rc=$?
check 'exit 0'                     0 "$rc"
check 'the check ran'              yes "$(grep -q 'check: OK' <<< "$out" && echo yes || echo no)"
check 'nothing refused the push'   yes "$(grep -q 'pre-push: nothing refused this push' <<< "$out" && echo yes || echo no)"
check 'and the check that ran is the WORKTREE one' \
  "$(git -C "$wt" rev-parse --show-toplevel)/scripts/check.sh" "$(tail -1 "$check_runs")"

echo 'a push to the default branch that is not a fast-forward is refused, origin/HEAD naming a branch this clone does not have'
git -C "$repo" commit -q --allow-empty -m 'master moves on while the worktree works #5'
git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main   # as a clone keeps it after the origin renamed its default branch
out="$(judge "$wt" "$(git -C "$wt" rev-parse HEAD)" "$(git -C "$repo" rev-parse master)")"; rc=$?
check 'exit 1'                     1 "$rc"
check 'it says why'                yes "$(grep -q 'the push to master is not a fast-forward' <<< "$out" && echo yes || echo no)"
git -C "$repo" symbolic-ref --delete refs/remotes/origin/HEAD
git -C "$repo" reset -q --hard HEAD~1

# --- the team modes ---------------------------------------------------------------------------
echo 'a red modes check refuses, and the lines the refusal points at are in the output'
out="$(TEAM_MODES_FILE="$red" only_new "$wt")"; rc=$?
check 'exit 1'                    1 "$rc"
check 'the MISSING line is there' yes "$(grep -Eq '^MISSING .*(claude|codex) diagrams' <<< "$out" && echo yes || echo no)"
check 'and the refusal names the modes' yes "$(grep -q 'the team modes are missing' <<< "$out" && echo yes || echo no)"

# The gate turns log.showSignature off for its own git calls through git's environment configuration.
# The repository's check runs in the caller's, or a suite that reads it is red only in the gate.
echo "the check runs with the caller's git environment configuration, not the gate's own entry"
commit 'src/thing.txt' 'Read the caller configuration #7'
out="$(only_new "$repo")"; rc=$?
check 'exit 0'                              0 "$rc"
check 'no entry reaches the check'          '' "$(cat "$check_runs.git-config")"
git -C "$repo" commit -q --amend -m 'Read the caller configuration again #7'
out="$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.quotePath GIT_CONFIG_VALUE_0=false only_new "$repo")"; rc=$?
check 'exit 0 with an entry of the caller'  0 "$rc"
check 'the check sees exactly that entry'   "$(printf 'GIT_CONFIG_COUNT=1\nGIT_CONFIG_KEY_0=core.quotePath\nGIT_CONFIG_VALUE_0=false')" "$(cat "$check_runs.git-config")"

# --- the Forgejo sign-in follows git outside the checkout ------------------------------------
credential_url=https://forge.example.test
credential_key="credential.$credential_url.helper"
credential_command="printf 'called\\n' >> '$fake/token-command-runs'; printf gate-fake-token"
# The helper entry carries both settings to the helper alone, each in single quotes for git's shell
credential_helper="!FORGEJO_URL='$credential_url' FORGEJO_TOKEN_COMMAND='printf '\\''called\\n'\\'' >> '\\''$fake/token-command-runs'\\''; printf gate-fake-token' ai-core git-credential"
: > "$fake/token-command-runs"
mkdir -p "$repo/.ai-core" "$fake/outside" "$fake/fixture/.ai-core"
printf 'FORGEJO_URL="https://fixture.example.test"\nFORGEJO_TOKEN_COMMAND="printf fixture-token"\n' > "$fake/fixture/.ai-core/config.env"
printf '/.ai-core/\n' >> "$repo/.git/info/exclude"
printf 'FORGE=forgejo\nFORGEJO_URL="%s/"\nFORGEJO_TOKEN_COMMAND="%s"\n' "$credential_url" "$credential_command" > "$repo/.ai-core/config.env"
git -C "$repo" config --replace-all "$credential_key" ''
git -C "$repo" config --add "$credential_key" '!ai-core git-credential'
cat > "$fake/unwanted-helper" <<EOF
#!/usr/bin/env bash
printf 'called\n' >> "$fake/unwanted-helper-runs"
EOF
cat > "$fake/refuse-askpass" <<EOF
#!/usr/bin/env bash
printf 'refused\n' >> "$fake/askpass-runs"
exit 1
EOF
chmod +x "$fake/unwanted-helper" "$fake/refuse-askpass"
git config --file "$fake/credential.gitconfig" credential.helper "!$fake/unwanted-helper"
cat > "$fake/credential-check.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "$fake/outside"
echo "exported settings: \$(env | grep -c '^FORGEJO_\(URL\|TOKEN_COMMAND\)=' || true)"
echo "fixture: \$(cd "$fake/fixture" && . "$root/lib/common.sh" && printf '%s %s' "\$(config_value FORGEJO_URL '')" "\$(config_value FORGEJO_TOKEN_COMMAND '')")"
if [ "\$PROBE_CREDENTIAL_EXPECT" = answer ]; then
  printf 'protocol=https\nhost=%s\n\n' "\$PROBE_CREDENTIAL_HOST" | git credential fill | awk '
    /^username=ai-core$/ { username = 1 }
    /^password=gate-fake-token$/ { password = 1 }
    END { if (username && password) print "credential: answered"; else exit 1 }
  '
else
  if printf 'protocol=https\nhost=%s\n\n' "\$PROBE_CREDENTIAL_HOST" | git credential fill > /dev/null 2>&1; then
    echo 'credential: an unexpected answer'; exit 1
  fi
  echo 'credential: refused'
fi
EOF
credential_gate() (  # credential_gate <checkout> <host> <answer|refuse>
  unset FORGE FORGEJO_URL FORGEJO_TOKEN_COMMAND
  export GIT_CONFIG_GLOBAL="$fake/credential.gitconfig" GIT_CONFIG_NOSYSTEM=1
  export GIT_ASKPASS="$fake/refuse-askpass" SSH_ASKPASS="$fake/refuse-askpass" GIT_TERMINAL_PROMPT=0
  export PROBE_CREDENTIAL_CHECK="$fake/credential-check.sh" PROBE_CREDENTIAL_HOST="$2" PROBE_CREDENTIAL_EXPECT="$3"
  only_new "$1"
)

echo 'a Forgejo check in a worktree signs in from outside the checkout'
out="$(credential_gate "$wt" forge.example.test answer)"; rc=$?
check 'the outside git gets the helper answer' 0 "$rc"
check 'the helper answered' yes "$(grep -q '^credential: answered$' <<< "$out" && echo yes || echo no)"
check 'the check gets the two ordered helper entries' \
  "$(printf 'GIT_CONFIG_COUNT=2\nGIT_CONFIG_KEY_0=%s\nGIT_CONFIG_KEY_1=%s\nGIT_CONFIG_VALUE_0=\nGIT_CONFIG_VALUE_1=%s' "$credential_key" "$credential_key" "$credential_helper")" "$(cat "$check_runs.git-config")"
check 'the check itself gets neither setting' 'exported settings: 0' "$(grep '^exported settings:' <<< "$out")"
check "the check's own config_value reads its fixture, not the gate's settings" \
  'fixture: https://fixture.example.test printf fixture-token' "$(grep '^fixture:' <<< "$out")"
check 'the reset prevents an earlier helper from running' no "$([ -f "$fake/unwanted-helper-runs" ] && echo yes || echo no)"
check 'git did not ask for a username' no "$([ -f "$fake/askpass-runs" ] && echo yes || echo no)"
check 'only the helper runs the token command' called "$(cat "$fake/token-command-runs")"

echo 'the Forgejo helper entries follow all caller entries'
rm -f "$fake/unwanted-helper-runs"
out="$(GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=core.quotePath GIT_CONFIG_VALUE_0=false \
  GIT_CONFIG_KEY_1="$credential_key" GIT_CONFIG_VALUE_1="!$fake/unwanted-helper" credential_gate "$repo" forge.example.test answer)"; rc=$?
check 'the outside git still signs in' 0 "$rc"
check 'the caller entries stay before the two helper entries' \
  "$(printf 'GIT_CONFIG_COUNT=4\nGIT_CONFIG_KEY_0=core.quotePath\nGIT_CONFIG_KEY_1=%s\nGIT_CONFIG_KEY_2=%s\nGIT_CONFIG_KEY_3=%s\nGIT_CONFIG_VALUE_0=false\nGIT_CONFIG_VALUE_1=!%s/unwanted-helper\nGIT_CONFIG_VALUE_2=\nGIT_CONFIG_VALUE_3=%s' "$credential_key" "$credential_key" "$credential_key" "$fake" "$credential_helper")" "$(cat "$check_runs.git-config")"
check 'the reset also drops a caller helper for this host' no "$([ -f "$fake/unwanted-helper-runs" ] && echo yes || echo no)"

echo 'a Forgejo check gets no credentials for another host'
: > "$fake/token-command-runs"; rm -f "$fake/askpass-runs"
out="$(credential_gate "$repo" other.example.test refuse)"; rc=$?
check 'the check proves the refusal' 0 "$rc"
check 'git had to ask for a username' yes "$([ -s "$fake/askpass-runs" ] && echo yes || echo no)"
check 'the token command did not run' '' "$(cat "$fake/token-command-runs")"

echo 'a GitHub check gets no Forgejo helper entries or settings'
sed 's/^FORGE=forgejo$/FORGE=github/' "$repo/.ai-core/config.env" > "$fake/github-config"
mv "$fake/github-config" "$repo/.ai-core/config.env"
rm -f "$fake/askpass-runs"
out="$(credential_gate "$repo" forge.example.test refuse)"; rc=$?
check 'the check proves no credentials reached it' 0 "$rc"
check 'no entries were added' '' "$(cat "$check_runs.git-config")"
check 'no settings were exported' 'exported settings: 0' "$(grep '^exported settings:' <<< "$out")"
check 'git had to ask for a username' yes "$([ -s "$fake/askpass-runs" ] && echo yes || echo no)"
check 'the token command did not run' '' "$(cat "$fake/token-command-runs")"

echo 'a Forgejo repository without FORGEJO_URL is refused, naming it, and its check does not run'
printf 'FORGE=forgejo\nFORGEJO_TOKEN_COMMAND="%s"\n' "$credential_command" > "$repo/.ai-core/config.env"
: > "$check_runs"
out="$(credential_gate "$repo" forge.example.test answer)"; rc=$?
check 'exit 1' 1 "$rc"
check 'it names FORGEJO_URL' yes "$(grep -q '^error: FORGEJO_URL is not set' <<< "$out" && echo yes || echo no)"
check 'the check did not run' '' "$(cat "$check_runs")"
rm -rf "$repo/.ai-core"
git -C "$repo" config --unset-all "$credential_key"

echo 'a red scripts/check.sh refuses'
out="$(PROBE_CHECK=red only_new "$wt")"; rc=$?
check 'exit 1'          1 "$rc"
check 'and says which'  yes "$(grep -q 'check: FAIL' <<< "$out" && echo yes || echo no)"

# --- a file that starts with #! carries the executable bit ------------------------------------
echo 'a pushed file that starts with #! and is not executable is refused, with the command that sets the bit'
mkdir -p "$repo/tools"; printf '#!/bin/sh\necho run\n' > "$repo/tools/run.sh"; chmod -x "$repo/tools/run.sh"
git -C "$repo" add --chmod=-x -- tools/run.sh; git -C "$repo" commit -q -m 'Add a runner #7'
out="$(only_new "$repo")"; rc=$?
check 'exit 1'                         1 "$rc"
check 'it names the file and the command' yes "$(grep -qF 'git update-index --chmod=+x tools/run.sh' <<< "$out" && echo yes || echo no)"
echo 'a failed path sort or git diff-tree refuses the push instead of hiding the script'
out="$(PROBE_SORT_FAIL=paths only_new "$repo")"; rc=$?
check 'a failed sort refuses' 1 "$rc"
check 'the refusal names sort -u and the path listing' yes "$(grep -qF 'sort -u failed to list added or changed paths' <<< "$out" && echo yes || echo no)"
out="$(PROBE_DIFF_TREE_FAIL=1 only_new "$repo")"; rc=$?
check 'a failed diff-tree refuses' 1 "$rc"
check 'the refusal names git diff-tree and the path listing' yes "$(grep -qF 'git diff-tree failed to list added or changed paths' <<< "$out" && echo yes || echo no)"
echo 'a failed mode or two-byte read refuses and names the unread path'
out="$(PROBE_LS_TREE_FAIL=tools/run.sh only_new "$repo")"; rc=$?
check 'a failed ls-tree refuses' 1 "$rc"
check 'the refusal names git ls-tree and the path' yes "$(grep -qF 'git ls-tree failed to read the mode of tools/run.sh' <<< "$out" && echo yes || echo no)"
out="$(PROBE_CAT_FILE_FAIL=tools/run.sh only_new "$repo")"; rc=$?
check 'a failed cat-file refuses' 1 "$rc"
check 'the refusal names the two-byte read and the path' yes "$(grep -qF 'reading the first two bytes of tools/run.sh failed (git cat-file' <<< "$out" && echo yes || echo no)"
out="$(PROBE_MKTEMP_BLOCK_BLOB=1 only_new "$repo")"; rc=$?
check 'a scratch blob that cannot be written does not hide the script' 1 "$rc"
check 'the shebang refusal still names the file' yes "$(grep -qF 'git update-index --chmod=+x tools/run.sh' <<< "$out" && echo yes || echo no)"
echo 'the bit set by a later commit of the same push passes'
git -C "$repo" update-index --chmod=+x -- tools/run.sh; chmod +x "$repo/tools/run.sh"; git -C "$repo" commit -q -m 'Make the runner executable #7'
out="$(judge "$repo" "$(git -C "$repo" rev-parse HEAD)" "$(git -C "$repo" rev-parse HEAD~2)")"; rc=$?
check 'exit 0'                         0 "$rc"
echo 'a file without the bit that the push does not touch holds nothing up'
git -C "$repo" update-index --chmod=-x -- tools/run.sh; chmod -x "$repo/tools/run.sh"; git -C "$repo" commit -q -m 'The runner without the bit, as an older commit left it #7'
commit 'src/thing.txt' 'Touch another file #7'
out="$(only_new "$repo")"; rc=$?
check 'exit 0'                         0 "$rc"
git -C "$repo" rm -q -- tools/run.sh; git -C "$repo" commit -q -m 'Remove the runner #7'
echo 'a pushed file that starts with null bytes is read without a warning, and one that starts with # and a null byte is no script'
printf '\000\000\000\030ftypmp42' > "$repo/src/clip.mp4"; printf '#\000!/bin/sh\n' > "$repo/src/not-a-script"
git -C "$repo" add -- src/clip.mp4 src/not-a-script; git -C "$repo" commit -q -m 'Add a clip and a file that only looks like a script #7'
out="$(only_new "$repo")"; rc=$?
check 'exit 0'                         0 "$rc"
check 'no null byte warning'           '' "$(grep -F 'null byte' <<< "$out")"
git -C "$repo" rm -q -- src/clip.mp4 src/not-a-script; git -C "$repo" commit -q -m 'Remove the clip #7'
echo 'a pushed file whose first 8000 bytes are text and which holds a null byte later is read without a warning'
{ head -c 9000 /dev/zero | tr '\0' 'a'; printf '\nafter the text\000\n'; } > "$repo/src/late-null.dat"
git -C "$repo" add -- src/late-null.dat; git -C "$repo" commit -q -m 'Add a file with a late null byte #7'
out="$(only_new "$repo")"; rc=$?
check 'exit 0'                         0 "$rc"
check 'no null byte warning'           '' "$(grep -F 'null byte' <<< "$out")"
git -C "$repo" rm -q -- src/late-null.dat; git -C "$repo" commit -q -m 'Remove the late null file #7'

echo 'a 32 MiB first line still has its first two bytes checked'
{ printf '#!'; head -c 33554432 /dev/zero | tr '\0' x; } > "$repo/src/long-script"
git -C "$repo" add --chmod=-x -- src/long-script; git -C "$repo" commit -q -m 'Add a long script without its executable bit #7'
out="$(only_new "$repo")"; rc=$?
check 'the large script is refused' 1 "$rc"
check 'the two-byte read names the script' yes "$(grep -qF 'git update-index --chmod=+x src/long-script' <<< "$out" && echo yes || echo no)"
git -C "$repo" rm -q -- src/long-script; git -C "$repo" commit -q -m 'Remove the long script #7'

# --- the commit messages, the comments and the migrations ----------------------------
yesno() { grep -qF -- "$1" <<< "$out" && echo yes || echo no; }
echo 'a subject of 73 characters is refused and named; one of 72 passes'
commit 'src/thing.txt' "$(printf 'A%.0s' {1..70}) #7"
out="$(only_new "$repo")"; rc=$?
check 'exit 1'                         1 "$rc"
check 'it counts the characters'       yes "$(yesno 'has 73 characters')"
git -C "$repo" commit -q --amend -m "$(printf 'A%.0s' {1..69}) #7"
out="$(only_new "$repo")"; rc=$?
check 'exit 0'                         0 "$rc"
echo "an assistant's attribution is refused; a person as co-author passes"
commit 'src/thing.txt' "$(printf 'Tune the reader #7\n\nCo-Authored-By: Claude <noreply@anthropic.com>')"
out="$(only_new "$repo")"; rc=$?
check 'exit 1'                         1 "$rc"
check 'it says why'                    yes "$(yesno "an assistant's or a vendor's attribution")"
git -C "$repo" commit -q --amend -m "$(printf 'Tune the reader #7\n\nWritten by the build i12123 on Codex; committed by a coordinator.')"
out="$(only_new "$repo")"; rc=$?
check 'a writer line at the push: exit 1' 1 "$rc"
check 'it says why'                    yes "$(yesno "an assistant's or a vendor's attribution")"
git -C "$repo" commit -q --amend -m "$(printf 'Tune the reader #7\n\nCo-Authored-By: Ada Lovelace <ada@example.invalid>')"
out="$(only_new "$repo")"; rc=$?
check 'exit 0'                         0 "$rc"
echo 'a closing keyword before an issue reference is refused at the push; the word in another sense passes'
commit 'src/thing.txt' "$(printf 'Tune the reader #7\n\nFixes example-org/example-repo#7')"
out="$(only_new "$repo")"; rc=$?
check 'exit 1'                         1 "$rc"
check 'it names the keyword'           yes "$(yesno 'Fixes example-org/example-repo#7')"
check 'it says how to name the issue'  yes "$(yesno 'Name the issue as #<n> alone')"
git -C "$repo" commit -q --amend -m "$(printf 'Fix the reader, or it drops a card (#7)\n\nIt fixes the layout too.')"
out="$(only_new "$repo")"; rc=$?
check 'the word in another sense: exit 0' 0 "$rc"
echo 'an assistant as author or committer is refused; a person who shares the name passes'
git -C "$repo" commit -q --amend --no-edit --author='Claude <noreply@anthropic.com>'
out="$(only_new "$repo")"; rc=$?
check 'an assistant as author: exit 1' 1 "$rc"
check 'it names the identity'          yes "$(yesno 'author Claude <noreply@anthropic.com>')"
git -C "$repo" commit -q --amend --no-edit --reset-author
GIT_COMMITTER_NAME=Claude GIT_COMMITTER_EMAIL=noreply@anthropic.com git -C "$repo" commit -q --amend --no-edit
out="$(only_new "$repo")"; rc=$?
check 'an assistant as committer alone: exit 1' 1 "$rc"
check 'it says why'                    yes "$(yesno 'name an assistant as author or committer')"
git -C "$repo" commit -q --amend --no-edit --author='claude[bot] <209825114+claude[bot]@users.noreply.github.com>'
out="$(only_new "$repo")"; rc=$?
check "an assistant's GitHub bot: exit 1" 1 "$rc"
check 'it says why'                    yes "$(yesno 'name an assistant as author or committer')"
# as_identity <name> <address>: the repository's identity, and the newest commit rewritten under it
# as author and committer, so only the assistant rule is in question
as_identity() {
  git -C "$repo" config user.name "$1"; git -C "$repo" config user.email "$2"
  git -C "$repo" commit -q --amend --no-edit --reset-author
}
as_identity 'Claude Monet' claude@example.invalid
out="$(only_new "$repo")"; rc=$?
check 'a person named Claude: exit 0'  0 "$rc"
as_identity 'dependabot[bot]' '49699333+dependabot[bot]@users.noreply.github.com'
out="$(only_new "$repo")"; rc=$?
check 'a bot that is no assistant: exit 0' 0 "$rc"
as_identity test test@example.invalid

echo 'a commit under another address than git config user.email is refused, as author or as committer'
git -C "$repo" commit -q --amend --no-edit --author='Ada Lovelace <ada@example.invalid>'
out="$(only_new "$repo")"; rc=$?
check 'another author address: exit 1' 1 "$rc"
check 'it names the commit and both addresses' yes "$(yesno "$(git -C "$repo" rev-parse --short HEAD) author <ada@example.invalid>, committer <test@example.invalid>")"
check 'it gives the rewrite command'   yes "$(yesno 'git commit --amend --reset-author --no-edit')"
git -C "$repo" commit -q --amend --no-edit --reset-author
GIT_COMMITTER_EMAIL=ada@example.invalid git -C "$repo" commit -q --amend --no-edit
out="$(only_new "$repo")"; rc=$?
check 'another committer address: exit 1' 1 "$rc"
check 'it names the commit and both addresses' yes "$(yesno "$(git -C "$repo" rev-parse --short HEAD) author <test@example.invalid>, committer <ada@example.invalid>")"
echo 'the same address in other letter case passes'
GIT_AUTHOR_EMAIL=TEST@Example.Invalid GIT_COMMITTER_EMAIL=Test@EXAMPLE.invalid git -C "$repo" commit -q --amend --no-edit --reset-author
out="$(only_new "$repo")"; rc=$?
check 'exit 0'                         0 "$rc"
git -C "$repo" commit -q --amend --no-edit --reset-author
echo 'a signed commit passes while log.showSignature is set: the signature lines git prints are no commits'
check 'ssh-keygen is there to sign the probe commit' yes "$(command -v ssh-keygen >/dev/null 2>&1 && echo yes || echo no)"
ssh-keygen -q -t ed25519 -N '' -C probe -f "$fake/signing-key" >/dev/null
git -C "$repo" -c gpg.format=ssh -c user.signingkey="$fake/signing-key.pub" commit -q --amend --no-edit -S
git -C "$repo" config log.showSignature true
out="$(only_new "$repo")"; rc=$?
check 'exit 0'                         0 "$rc"
git -C "$repo" config --unset log.showSignature
git -C "$repo" commit -q --amend --no-edit
echo 'a signed commit that names no issue is refused while log.showSignature is set: the signature lines are no No-issue trailer'
commit 'src/thing.txt' 'Tune the reader once more'
git -C "$repo" -c gpg.format=ssh -c user.signingkey="$fake/signing-key.pub" commit -q --amend --no-edit -S
git -C "$repo" config log.showSignature true
out="$(only_new "$repo")"; rc=$?
check 'exit 1'                         1 "$rc"
check 'it names the missing issue'     yes "$(yesno 'names no issue')"
git -C "$repo" config --unset log.showSignature
out="$(only_new "$repo")"; rc=$?
check 'the same commit without the setting: exit 1' 1 "$rc"
git -C "$repo" commit -q --amend --no-edit -m 'Tune the reader once more #7'
echo "a caller's own GIT_CONFIG_COUNT entries reach the gate, and the gate's entry follows them"
out="$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.email GIT_CONFIG_VALUE_0=ada@example.invalid only_new "$repo")"; rc=$?
check "the address the caller's entry sets is the one read: exit 1" 1 "$rc"
check 'it names that address'          yes "$(yesno 'than yours, ada@example.invalid')"
out="$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.quotepath GIT_CONFIG_VALUE_0=false only_new "$repo")"; rc=$?
check 'an entry the gate does not read is carried along: exit 0' 0 "$rc"
echo 'a merge is read like any pushed commit: the pusher'"'"'s passes, another committer'"'"'s is refused'
base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -q -b side; commit 'src/side.txt' 'Work on a side branch #7'
git -C "$repo" checkout -q master; commit 'src/thing.txt' 'Work on master #7'
git -C "$repo" merge -q --no-ff side -m 'Merge side (#7)'
out="$(judge "$repo" "$(git -C "$repo" rev-parse HEAD)" "$base")"; rc=$?
check 'a merge by the pusher over the pusher'"'"'s commits: exit 0' 0 "$rc"
GIT_COMMITTER_EMAIL=ada@example.invalid git -C "$repo" commit -q --amend --no-edit
out="$(judge "$repo" "$(git -C "$repo" rev-parse HEAD)" "$base")"; rc=$?
check 'the same merge under another committer: exit 1' 1 "$rc"
check 'it names the merge'             yes "$(yesno "$(git -C "$repo" rev-parse --short HEAD) author <test@example.invalid>, committer <ada@example.invalid>")"
git -C "$repo" reset -q --hard "$base"; git -C "$repo" branch -q -D side
echo 'a commit the remote has already is not read, whoever wrote it'
git -C "$repo" commit -q --amend --no-edit --author='Ada Lovelace <ada@example.invalid>'
published="$(git -C "$repo" rev-parse HEAD)"
commit 'src/thing.txt' 'Build on a commit of someone else #7'
out="$(judge "$repo" "$(git -C "$repo" rev-parse HEAD)" "$published")"; rc=$?
check 'a remote sha beneath the pusher'"'"'s commit: exit 0' 0 "$rc"
git -C "$repo" update-ref refs/remotes/origin/master "$published"
out="$(judge "$repo" "$(git -C "$repo" rev-parse HEAD)" "$zeros40")"; rc=$?
check 'a new branch on top of a remote ref: exit 0' 0 "$rc"
git -C "$repo" update-ref -d refs/remotes/origin/master
git -C "$repo" reset -q --hard "$base"
echo 'no user.email configured: refused, with the command that sets one'
git -C "$repo" config --unset user.email
out="$(GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 only_new "$repo")"; rc=$?
check 'exit 1'                         1 "$rc"
check 'it says how to set it'          yes "$(yesno 'git config --global user.email')"
git -C "$repo" config user.email test@example.invalid
echo '--message judges one message as the commit is made: the same rules, comment lines left out, a merge passed'
msg="$fake/COMMIT_EDITMSG"
judge_message() { out="$( cd "$repo" && bash "$root/bin/pre-push.sh" --message "$msg" 2>&1 )"; rc=$?; }
printf '%s\n\n# %s\n' "$(printf 'A%.0s' {1..73})" "$(printf 'B%.0s' {1..90})" > "$msg"; judge_message
check 'a subject of 73: exit 1'        1 "$rc"
check 'it counts the characters'       yes "$(yesno 'the subject has 73 characters')"
check 'no commit is made'              yes "$(yesno 'commit-msg: REFUSED — the commit is not made')"
printf '%s\n\n# %s\n' "$(printf 'A%.0s' {1..72})" "$(printf 'B%.0s' {1..90})" > "$msg"; judge_message
check 'a subject of 72, a long comment line: exit 0' 0 "$rc"
printf '%s\n%s\n\nbody\n' "$(printf 'A%.0s' {1..40})" "$(printf 'A%.0s' {1..40})" > "$msg"; judge_message
check 'a subject over two lines, 81 as git reads it: exit 1' 1 "$rc"
printf '#8 Check the admin cases\n\n%s\n' "$(printf 'B%.0s' {1..262})" > "$msg"; judge_message
check 'a subject that starts with an issue number, a long body: exit 0' 0 "$rc"
printf '#8 %s\n\n%s\n' "$(printf 'A%.0s' {1..70})" "$(printf 'B%.0s' {1..80})" > "$msg"; judge_message
check 'that subject at 73 over a body of 80, too long either way: exit 1' 1 "$rc"
check 'it quotes that subject'         yes "$(yesno 'the subject has 73 characters, at most 72 are allowed: #8 AAAA')"
printf '#8 %s\n\nFix\n' "$(printf 'A%.0s' {1..70})" > "$msg"; judge_message
check 'that subject over Fix, which an editor run records: exit 0, the push gate judges it' 0 "$rc"
git -C "$repo" config core.commentChar ';'
printf 'Fix\n; ------------------------ >8 ------------------------\n%s\n' "$(printf 'A%.0s' {1..73})" > "$msg"; judge_message
check 'comment prefix ;, a long line below its scissors: exit 0, the push gate judges it' 0 "$rc"
out="$( cd "$repo" && GIT_CONFIG=/dev/null bash "$root/bin/pre-push.sh" --message "$msg" 2>&1 )"; rc=$?
check 'comment prefix ;, GIT_CONFIG pointing elsewhere: still exit 0' 0 "$rc"
out="$( cd "$repo" && GIT_AUTHOR_NAME=Claude GIT_AUTHOR_EMAIL=noreply@anthropic.com bash "$root/bin/pre-push.sh" --message "$msg" 2>&1 )"; rc=$?
check 'comment prefix ;, an assistant as author: still exit 1' 1 "$rc"
git -C "$repo" config --unset core.commentChar
git -C "$repo" config core.commentString '# extra'
printf 'Fix\n# extra ------------------------ >8 ------------------------\n%s\n' "$(printf 'A%.0s' {1..73})" > "$msg"; judge_message
check 'comment string "# extra", a long line below its scissors: exit 0' 0 "$rc"
git -C "$repo" config --unset core.commentString
printf 'Tune the reader #7\n\nCo-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>\n' > "$msg"; judge_message
check 'an attribution: exit 1'         1 "$rc"
check 'it says why'                    yes "$(yesno "an assistant's or a vendor's attribution")"
printf 'Tune the reader #7\n\nCo-Authored-By: Ada Lovelace <ada@example.invalid>\n' > "$msg"; judge_message
check 'a person as co-author: exit 0'  0 "$rc"
echo 'a line that says an assistant wrote the commit is refused; a message about an assistant as a tool passes'
printf 'Tune the reader #7\n\nWritten by the build i12123 on Codex; committed by a coordinator.\n' > "$msg"; judge_message
check 'a writer line: exit 1'          1 "$rc"
check 'it says why'                    yes "$(yesno "an assistant's or a vendor's attribution")"
printf 'Write the Codex brief from the model table #7\n\nBuilt the reader on the new table, so Claude and Codex read one file.\n' > "$msg"; judge_message
check 'a tool named in a message: exit 0' 0 "$rc"
for line in 'Built on the new table, so Claude and Codex read one file.' "Built on Claude Code's PreToolUse hook." 'Made in Claude Code settings.json' 'Built with Claude Code hooks in mind.' 'Generated with the Codex template list' 'Written in Gemini CLI syntax.' 'Made using the OpenAI API client' 'Committed in the Codex worktree'; do
  printf 'Tune the reader #7\n\n%s\n' "$line" > "$msg"; judge_message
  check "a tool named: $line" 0 "$rc"
done
for line in 'Written by Gemini Flash from my specification' 'Made with Claude Code.' 'Generated by claude' 'Written by Claude Opus and reviewed by a person'; do
  printf 'Tune the reader #7\n\n%s\n' "$line" > "$msg"; judge_message
  check "a writer line: $line" 1 "$rc"
done
printf 'Tune the reader #7\n\ncloses: #7\n' > "$msg"; judge_message
check 'closes: #7 at the commit: exit 1' 1 "$rc"
check 'it says why'                    yes "$(yesno 'the message closes an issue on the forge')"
printf 'Tune the reader #7\n\nResolved https://github.com/example-org/example-repo/issues/7\n' > "$msg"; judge_message
check 'resolved before an issue link: exit 1' 1 "$rc"
printf 'Fix the reader, or it drops a card (#7)\n\nIt fixes the layout, and close to #8 is fine.\n' > "$msg"; judge_message
check 'fix and close in another sense: exit 0' 0 "$rc"
out="$( cd "$repo" && GIT_AUTHOR_NAME=Claude GIT_AUTHOR_EMAIL=noreply@anthropic.com bash "$root/bin/pre-push.sh" --message "$msg" 2>&1 )"; rc=$?
check 'an assistant as author: exit 1' 1 "$rc"
check 'it names the identity'          yes "$(yesno 'Claude <noreply@anthropic.com>')"
out="$( cd "$repo" && GIT_AUTHOR_NAME='Claude Monet' GIT_AUTHOR_EMAIL=claude@example.invalid bash "$root/bin/pre-push.sh" --message "$msg" 2>&1 )"; rc=$?
check 'a person named Claude: exit 0'  0 "$rc"
printf '%s\n' "$(printf 'M%.0s' {1..90})" > "$msg"
git -C "$repo" rev-parse HEAD > "$repo/.git/MERGE_HEAD"; judge_message; rm -f "$repo/.git/MERGE_HEAD"
check 'a merge with a long subject: exit 0' 0 "$rc"
judge_message
check 'the same subject outside a merge: exit 1' 1 "$rc"
printf 'Fix the thing #7\n# ------------------------ >8 ------------------------\n+%s generated by claude\n' "$(printf 'D%.0s' {1..90})" > "$msg"; judge_message
check 'a diff below the scissors of commit -v: exit 0' 0 "$rc"
echo 'an added comment naming an issue as (#12) or <repo>#12 is refused; a number in code passes'
n=12  # the number is put together, so this line is no comment naming an issue to the gate itself
printf 'const a = 1; // read the board whole (#%s)\n' "$n" > "$repo/src/app.js"
printf '# see acme-shop#12 for the order\n' > "$repo/src/app.py"
git -C "$repo" add src/app.js src/app.py; git -C "$repo" commit -q -m 'Read the board whole #12'
out="$(only_new "$repo")"; rc=$?
check 'exit 1'                         1 "$rc"
check 'it names the (#12) line'        yes "$(yesno "src/app.js: const a = 1; // read the board whole (#$n)")"
check 'it names the <repo>#12 line'    yes "$(yesno 'src/app.py: # see acme-shop#12 for the order')"
echo 'a later commit of the same push that takes the number out of one comment clears that one only'
printf 'const a = 1; // read the board whole\n' > "$repo/src/app.js"
git -C "$repo" add src/app.js; git -C "$repo" commit -q -m 'Say what the line needs #12'
out="$(judge "$repo" "$(git -C "$repo" rev-parse HEAD)" "$(git -C "$repo" rev-parse HEAD~2)")"; rc=$?
check 'exit 1'                         1 "$rc"
check 'it no longer names the (#12) line' no "$(yesno "src/app.js: const a = 1; // read the board whole (#$n)")"
check 'it still names the <repo>#12 line' yes "$(yesno 'src/app.py: # see acme-shop#12 for the order')"
printf '# the order the board reads\n' > "$repo/src/app.py"
git -C "$repo" add src/app.py; git -C "$repo" commit -q -m 'Say what the order is #12'
out="$(judge "$repo" "$(git -C "$repo" rev-parse HEAD)" "$(git -C "$repo" rev-parse HEAD~3)")"; rc=$?
check 'both taken out: exit 0'         0 "$rc"
git -C "$repo" reset -q --hard HEAD~3
echo 'a tab-indented comment, a renamed file, a non-ASCII name and a name with a space still count while the line stands'
printf '\tx := 1 // read the board whole (#%s)\n' "$n" > "$repo/src/app.go"
printf '# see acme-shop#12 for the order\n' > "$repo/src/über.py"
printf '# the board in acme-shop#12, spaced\n' > "$repo/src/my file.py"
git -C "$repo" add src/app.go src/über.py "src/my file.py"; git -C "$repo" commit -q -m 'Read the board in Go #12'
git -C "$repo" mv src/app.go src/board.go; git -C "$repo" commit -q -m 'Name the file after the board #12'
out="$(judge "$repo" "$(git -C "$repo" rev-parse HEAD)" "$(git -C "$repo" rev-parse HEAD~2)")"; rc=$?
check 'exit 1'                         1 "$rc"
check 'it names the tab-indented line of the renamed file' yes "$(yesno "src/app.go: 	x := 1 // read the board whole (#$n)")"
check 'it names the line of the non-ASCII name' yes "$(yesno '# see acme-shop#12 for the order')"
check 'it names the line of a name with a space' yes "$(yesno 'src/my file.py: # the board in acme-shop#12, spaced')"
git -C "$repo" reset -q --hard HEAD~2
printf 'const ref = "acme-shop#12"; // the order the board reads\n' > "$repo/src/app.js"
git -C "$repo" add src/app.js; git -C "$repo" commit -q -m 'Read the board whole #12'
out="$(only_new "$repo")"; rc=$?
check 'exit 0'                         0 "$rc"
echo 'a comment naming an issue counts while it stands whole, also above thousands of lines that only hold it inside them'
{ printf '// read the board whole (#%s)\n' "$n"; for i in $(seq 1 20000); do printf 'const a%s = "x:// read the board whole (#%s)";\n' "$i" "$n"; done; } > "$repo/src/many.js"
git -C "$repo" add src/many.js; git -C "$repo" commit -q -m 'Read many boards whole #12'
out="$(only_new "$repo")"; rc=$?
check 'exit 1'                         1 "$rc"
check 'it names the line that stands whole' yes "$(yesno "src/many.js: // read the board whole (#$n)")"
tail -n +2 "$repo/src/many.js" > "$repo/src/many.js.next" && mv "$repo/src/many.js.next" "$repo/src/many.js"
git -C "$repo" add src/many.js; git -C "$repo" commit -q -m 'Say what the boards need #12'
out="$(judge "$repo" "$(git -C "$repo" rev-parse HEAD)" "$(git -C "$repo" rev-parse HEAD~2)")"; rc=$?
check 'taken out, and held only inside other lines: exit 0' 0 "$rc"
git -C "$repo" reset -q --hard HEAD~2
echo "a migration added passes; changed later it is refused, and passes with a 'Migration:' trailer"
commit 'db/migrations/0001_init.sql' 'Add the first migration #8'
out="$(only_new "$repo")"; rc=$?
check 'exit 0'                         0 "$rc"
commit 'db/migrations/0001_init.sql' 'Change the first migration #8'
out="$(only_new "$repo")"; rc=$?
check 'exit 1'                         1 "$rc"
check 'it names the migration'         yes "$(yesno 'changed or removed: db/migrations/0001_init.sql')"
git -C "$repo" commit -q --amend -m "$(printf 'Change the first migration #8\n\nMigration: it never left this machine')"
out="$(only_new "$repo")"; rc=$?
check 'exit 0'                         0 "$rc"
git -C "$repo" rm -q -r -- db src/app.js; git -C "$repo" commit -q -m 'Remove the probes #9'

# --- a branch that merges the default branch -------------------------------------------------
echo 'a branch that merges the default branch is judged on what it adds, not on what the default branch published'
base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -q -b issue-11-catch-up
commit 'src/branch.txt' 'Start the branch work #11'
branch_tip="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" update-ref refs/remotes/origin/issue-11-catch-up "$branch_tip"   # the branch is on the remote
git -C "$repo" checkout -q master
commit 'src/elsewhere.txt' 'A commit another flow wrote on the default branch'   # names no issue
git -C "$repo" update-ref refs/remotes/origin/master HEAD                        # and is published
git -C "$repo" checkout -q issue-11-catch-up
git -C "$repo" merge -q --no-edit -m 'Catch up with master #11' master
push_branch() { printf 'refs/heads/issue-11-catch-up %s refs/heads/issue-11-catch-up %s\n' "$(git -C "$repo" rev-parse HEAD)" "$branch_tip" \
  | ( cd "$repo" && bash "$root/bin/pre-push.sh" origin 'https://example.invalid/x.git' 2>&1 ); }
out="$(push_branch)"; rc=$?
check 'exit 0'                         0 "$rc"
check 'the merge, a tree the remote never had, is checked' yes "$(grep -q 'check: OK' <<< "$out" && echo yes || echo no)"
git -C "$repo" update-ref refs/remotes/origin/issue-11-catch-up HEAD           # the merge is published now
out="$(printf 'refs/tags/v0.1 %s refs/tags/v0.1 %s\n' "$(git -C "$repo" rev-parse HEAD)" "$zeros40" \
  | ( cd "$repo" && bash "$root/bin/pre-push.sh" origin 'https://example.invalid/x.git' 2>&1 ))"; rc=$?
check 'a tag on a published commit sends nothing new' yes "$(grep -q 'pre-push: nothing new to send' <<< "$out" && echo yes || echo no)"
echo 'a new commit on that branch that names no issue is still refused'
commit 'src/branch.txt' 'More branch work'
out="$(push_branch)"; rc=$?
check 'exit 1'                         1 "$rc"
check 'it names that commit'           yes "$(grep -qF "$(git -C "$repo" rev-parse --short HEAD) More branch work" <<< "$out" && echo yes || echo no)"
check 'and not the published one'      no "$(grep -qF 'A commit another flow wrote' <<< "$out" && echo yes || echo no)"
git -C "$repo" checkout -q master; git -C "$repo" reset -q --hard "$base"; git -C "$repo" branch -q -D issue-11-catch-up
git -C "$repo" update-ref -d refs/remotes/origin/master; git -C "$repo" update-ref -d refs/remotes/origin/issue-11-catch-up

# --- a commit origin carries only under a tag ---------------------------------------------------
echo 'a branch that merges a commit origin carries only under a tag is not judged on that commit'
tag_origin="$fake/origin-tags.git"
git init -q --bare "$tag_origin"
git -C "$repo" remote add origin "$tag_origin"
base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -q -b release-snapshot
commit 'src/snapshot.txt' 'Snapshot of the old tracker'                         # names no issue
snapshot="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -q master
git -C "$repo" push -q --no-verify origin "$snapshot:refs/tags/v1"              # only a tag holds it on origin
git -C "$repo" checkout -q -b issue-317-join
git -C "$repo" merge -q --no-ff -m 'Join the release history (#317)' "$snapshot"
join_tip="$(git -C "$repo" rev-parse HEAD)"
push_join() { printf 'refs/heads/issue-317-join %s refs/heads/issue-317-join %s\n' "$join_tip" "$base" \
  | ( cd "$repo" && bash "$root/bin/pre-push.sh" origin 'https://example.invalid/x.git' 2>&1 ); }
out="$(push_join)"; rc=$?
check 'exit 0'                                       0 "$rc"
check 'the tagged commit is not named'               no "$(grep -qF 'Snapshot of the old tracker' <<< "$out" && echo yes || echo no)"
check 'the merge, a tree origin never had, is checked' yes "$(grep -q 'check: OK' <<< "$out" && echo yes || echo no)"
echo 'an annotated tag on origin leaves its commit out too, though this checkout lacks the tag object'
git -C "$tag_origin" update-ref -d refs/tags/v1
git -C "$repo" tag -a -m 'Release two' v2 "$snapshot"
git -C "$repo" push -q --no-verify origin refs/tags/v2
git -C "$repo" tag -d v2 >/dev/null
out="$(push_join)"; rc=$?
check 'exit 0'                                       0 "$rc"
echo 'the same commit without the tag on origin is judged and refused'
git -C "$tag_origin" update-ref -d refs/tags/v2
out="$(push_join)"; rc=$?
check 'exit 1'                                       1 "$rc"
check 'it names the tagged commit'                   yes "$(grep -qF "$(git -C "$repo" rev-parse --short "$snapshot") Snapshot of the old tracker" <<< "$out" && echo yes || echo no)"
echo 'a local tag that origin does not have leaves nothing out'
git -C "$repo" tag v3 "$snapshot"
out="$(push_join)"; rc=$?
check 'exit 1'                                       1 "$rc"
check 'it names the tagged commit'                   yes "$(grep -qF 'Snapshot of the old tracker' <<< "$out" && echo yes || echo no)"
echo 'an origin that cannot be asked leaves nothing out, a local tag on the commit notwithstanding'
git -C "$repo" remote set-url origin "$fake/no-such-origin.git"
out="$(push_join)"; rc=$?
check 'exit 1'                                       1 "$rc"
check 'it names the tagged commit'                   yes "$(grep -qF 'Snapshot of the old tracker' <<< "$out" && echo yes || echo no)"
git -C "$repo" tag -d v3 >/dev/null
git -C "$repo" remote remove origin
git -C "$repo" checkout -q master; git -C "$repo" reset -q --hard "$base"
git -C "$repo" branch -q -D issue-317-join release-snapshot

# --- a default branch that goes live -----------------------------------------------------------
echo 'where the default branch goes live, a landing without a Reviewed-by trailer is refused'
mkdir -p "$repo/.ai-core"; printf 'DEFAULT_BRANCH_IS_LIVE="yes"\n' > "$repo/.ai-core/config.env"
grep -qxF '/.ai-core/' "$repo/.git/info/exclude" 2>/dev/null || printf '/.ai-core/\n' >> "$repo/.git/info/exclude"
commit 'src/thing.txt' 'Land a change on a live branch #16'
out="$(only_new "$repo")"; rc=$?
check 'exit 1'                         1 "$rc"
check 'it names the trailer'           yes "$(grep -qF "git commit --amend --trailer 'Reviewed-by: <reviewer>'" <<< "$out" && echo yes || echo no)"
echo 'with the trailer it lands'
git -C "$repo" commit -q --amend -m "$(printf 'Land a change on a live branch #16\n\nReviewed-by: a critic session')"
out="$(only_new "$repo")"; rc=$?
check 'exit 0'                         0 "$rc"
echo 'a push to another branch is not held to it'
commit 'src/thing.txt' 'Work on an issue branch #16'
out="$(printf 'refs/heads/issue-16-x %s refs/heads/issue-16-x %s\n' "$(git -C "$repo" rev-parse HEAD)" "$(git -C "$repo" rev-parse HEAD~1)" | ( cd "$repo" && bash "$root/bin/pre-push.sh" origin 'https://example.invalid/x.git' 2>&1 ))"; rc=$?
check 'exit 0'                         0 "$rc"
echo 'a live repository without scripts/check.sh is refused even with the trailer'
mv "$repo/scripts/check.sh" "$fake/check.sh.aside"
git -C "$repo" commit -q --amend -m "$(printf 'Work on an issue branch #16\n\nReviewed-by: a critic session')"
out="$(only_new "$repo")"; rc=$?
check 'exit 1'                         1 "$rc"
check 'it says nothing would test it'  yes "$(grep -qF 'has no scripts/check.sh, so nothing would test what goes live' <<< "$out" && echo yes || echo no)"
mv "$fake/check.sh.aside" "$repo/scripts/check.sh"
echo 'the harness-wide list form: the repository named in it is live, one not named is not'
printf 'DEFAULT_BRANCH_IS_LIVE="other-repo %s"\n' "$(basename "$repo")" > "$repo/.ai-core/config.env"
commit 'src/thing.txt' 'Land a change named in the list #16'
out="$(only_new "$repo")"; rc=$?
check 'exit 1 where it is named'       1 "$rc"
printf 'DEFAULT_BRANCH_IS_LIVE="other-repo"\n' > "$repo/.ai-core/config.env"
out="$(only_new "$repo")"; rc=$?
check 'exit 0 where it is not'         0 "$rc"
echo 'a config.env the gate cannot read: the push is refused, and the default branch is never taken for one that is not live'
. "$root/tests/unreadable.sh"
old_reader_copy "$root" "$fake/old-reader" || failed=$((failed + 1))
harness_copy "$root" "$fake/old-raw-read"
cat > "$fake/old-raw-read.sed" <<'SED'
/^live="\$(config_value_in_file "\$root\/.ai-core\/config.env" DEFAULT_BRANCH_IS_LIVE "")" \\$/{
N
s@.*@live="$(grep -E '^[[:space:]]*DEFAULT_BRANCH_IS_LIVE[[:space:]]*=' "$root/.ai-core/config.env" 2>/dev/null | tail -n1 || true)"; live="${live#*=}"; live="${live%%#*}"@
}
SED
sed -i.bak -f "$fake/old-raw-read.sed" "$fake/old-raw-read/bin/pre-push.sh"
cmp -s "$root/bin/pre-push.sh" "$fake/old-raw-read/bin/pre-push.sh" && { echo "  FAIL the copy with the old raw read equals bin/pre-push.sh"; failed=$((failed + 1)); }
printf 'DEFAULT_BRANCH_IS_LIVE="yes"\n' > "$repo/.ai-core/config.env"
commit 'src/thing.txt' 'Land a change where the settings cannot be read #16'
make_unreadable "$repo/.ai-core/config.env" || failed=$((failed + 1))
: > "$check_runs"
out="$(only_new "$repo")"; rc=$?
check 'exit 1'                         1 "$rc"
check 'it names the file'              yes "$(yesno "$repo/.ai-core/config.env exists but cannot be read")"
check 'the check did not run'          '' "$(cat "$check_runs")"
# with forge and tracker named in the environment the first read of the file is the gate's own, of DEFAULT_BRANCH_IS_LIVE
out="$(FORGE=github TRACKER=github only_new "$repo")"; rc=$?
check 'its own read: exit 1'           1 "$rc"
check 'it names the file again'        yes "$(yesno "$repo/.ai-core/config.env exists but cannot be read")"
check 'it says what it could not tell' yes "$(yesno "the settings of this repository cannot be read, so it is not known whether")"
check 'the check did not run again'    '' "$(cat "$check_runs")"
out="$(FORGE=github TRACKER=github GATE_SCRIPT="$fake/old-reader/bin/pre-push.sh" only_new "$repo")"; rc=$?
check 'planted: the old reader lets the same landing through, the repository taken for one that is not live' 0 "$rc"
out="$(FORGE=github TRACKER=github GATE_SCRIPT="$fake/old-raw-read/bin/pre-push.sh" only_new "$repo")"; rc=$?
check 'planted: the old raw read of the gate does not say that whether the branch goes live is unknown' no "$(yesno "so it is not known whether")"
chmod 600 "$repo/.ai-core/config.env"
out="$(only_new "$repo")"; rc=$?
check 'innocent: the same file, readable, holds the landing to the Reviewed-by rule again' 1 "$rc"
check 'it names the trailer'           yes "$(yesno "git commit --amend --trailer 'Reviewed-by: <reviewer>'")"
echo 'without the setting nothing changes'
rm -f "$repo/.ai-core/config.env"
commit 'src/thing.txt' 'Land a change on an ordinary branch #16'
out="$(only_new "$repo")"; rc=$?
check 'exit 0'                         0 "$rc"
echo 'a fast-forward landing of a branch origin carries already is checked, and held to the live rule'
commit 'src/landed.txt' 'Land a branch that origin carries already #74'
git -C "$repo" update-ref refs/remotes/origin/issue-74-landed HEAD   # pushed for review before it lands
: > "$check_runs"
out="$(only_new "$repo")"; rc=$?
check 'exit 0'                         0 "$rc"
check 'it is not called nothing new'   no "$(yesno 'pre-push: nothing new to send')"
check 'the check runs'                 yes "$([ -s "$check_runs" ] && echo yes || echo no)"
printf 'DEFAULT_BRANCH_IS_LIVE="yes"\n' > "$repo/.ai-core/config.env"
out="$(only_new "$repo")"; rc=$?
check 'where the branch goes live, without the trailer: exit 1' 1 "$rc"
check 'it names the trailer'           yes "$(yesno "git commit --amend --trailer 'Reviewed-by: <reviewer>'")"
echo 'a push that moves nothing lands nothing, also where the branch goes live'
: > "$check_runs"
out="$(judge "$repo" "$(git -C "$repo" rev-parse HEAD)" "$(git -C "$repo" rev-parse HEAD)")"; rc=$?
check 'exit 0'                         0 "$rc"
check 'it sends nothing new'           yes "$(yesno 'pre-push: nothing new to send')"
check 'and runs no check'              '' "$(cat "$check_runs")"
rm -f "$repo/.ai-core/config.env"
git -C "$repo" update-ref -d refs/remotes/origin/issue-74-landed

# --- what excuses a commit from naming an issue ----------------------------------------------
echo 'a commit naming its issue anywhere in the message passes'
commit 'src/thing.txt' 'Read the install order from one file

It is the work of #163.'
out="$(only_new "$repo")"; rc=$?
check 'exit 0' 0 "$rc"

echo 'a release stamp passes'
commit 'src/thing.txt' 'release: 0.8.100'
out="$(only_new "$repo")"; rc=$?
check 'exit 0' 0 "$rc"

echo 'a commit with no number and no excuse is refused, and is named'
commit 'src/thing.txt' 'Change a thing'
out="$(only_new "$repo")"; rc=$?
check 'exit 1'              1 "$rc"
check 'the commit is named' yes "$(grep -qF 'Change a thing names no issue' <<< "$out" && echo yes || echo no)"
check 'the check never ran' no "$(grep -q 'check: OK' <<< "$out" && echo yes || echo no)"

# THE TRAILER IS READ THE WAY git READS A TRAILER. Searching the whole message for the two words
# accepts an empty `No-issue:` and accepts them inside a body sentence, and both of those are a
# way around the rule rather than the reason the rule asks for.
echo 'a No-issue trailer naming a reason passes'
commit 'src/thing.txt' 'Change a thing

No-issue: the product owner asked for it on 2026-09-03'
out="$(only_new "$repo")"; rc=$?
check 'exit 0' 0 "$rc"

echo 'an EMPTY No-issue trailer is no reason, and is refused'
commit 'src/thing.txt' 'Change a thing

No-issue:'
out="$(only_new "$repo")"; rc=$?
check 'exit 1' 1 "$rc"

echo 'the two words inside a body sentence are not a trailer'
commit 'src/thing.txt' 'Change a thing

There is No-issue: for this one because nobody asked.'
out="$(only_new "$repo")"; rc=$?
check 'exit 1' 1 "$rc"

# THE NAME IS MATCHED WITHOUT ITS FOLDER: a rule that reads the whole path gives one commit two
# verdicts depending on which repository it lands in.
echo 'a commit that only explains passes, whatever folder the file stands in'
commit 'docs/notes.md' 'Correct a typo'
out="$(only_new "$repo")"; rc=$?
check 'a markdown file'      0 "$rc"
commit 'LICENSE-MIT' 'Add the licence text'
out="$(only_new "$repo")"; rc=$?
check 'LICENSE-MIT'          0 "$rc"
commit 'docs/LICENSE' 'Add the licence text under docs'
out="$(only_new "$repo")"; rc=$?
check 'docs/LICENSE'         0 "$rc"
commit 'src/notes.txt' 'Write a note that is not a document'
out="$(only_new "$repo")"; rc=$?
check 'and a file that explains nothing is refused' 1 "$rc"

# --- the shape of a sha -----------------------------------------------------------------------
#
# An all-zero sha is a ref the remote does not have yet, or a ref being removed. A SHA-256
# repository writes sixty-four zeros where these write forty, and a written-out constant reads
# the longer one as a real commit.
echo 'an all-zero remote sha judges every commit, at forty digits and at sixty-four'
head_sha="$(git -C "$repo" rev-parse HEAD)"
out="$(judge "$repo" "$head_sha" "$zeros40")"; rc=$?
check 'forty zeros: the history is judged and this one names no issue' 1 "$rc"
out="$(judge "$repo" "$head_sha" "$zeros64")"; rc=$?
check 'sixty-four zeros: the same verdict' 1 "$rc"

echo 'an all-zero LOCAL sha is a deletion: no commit is judged and no check is run'
: > "$check_runs"
out="$(judge "$repo" "$zeros64" "$(git -C "$repo" rev-parse HEAD)")"; rc=$?
check 'exit 0'                     0 "$rc"
check 'the modes check never ran'  no "$(grep -q 'team modes' <<< "$out" && echo yes || echo no)"
check 'and neither did check.sh'   '' "$(cat "$check_runs")"

# A remote sha this checkout does not carry cannot be measured from. Letting `git rev-list` fail
# quietly leaves the range empty, and an empty range reads as a push with nothing in it.
echo 'a remote sha this checkout does not carry is refused, with what to do about it'
out="$(judge "$repo" "$head_sha" 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef')"; rc=$?
check 'exit 1'            1 "$rc"
check 'it says git fetch' yes "$(grep -q 'Run git fetch, then push again' <<< "$out" && echo yes || echo no)"

echo 'a local sha that is not what is checked out is refused'
out="$(judge "$repo" "$(git -C "$repo" rev-parse HEAD~1)" "$(git -C "$repo" rev-parse HEAD~2)")"; rc=$?
check 'exit 1'              1 "$rc"
check 'it says what to push' yes "$(grep -q 'push what you have: git push origin HEAD:master' <<< "$out" && echo yes || echo no)"

echo 'a working tree that differs from the pushed commit is refused, and names the files'
commit 'src/clean.txt' 'Write a commit to push #17'
printf 'not committed\n' > "$repo/src/loose.txt"
out="$(only_new "$repo")"; rc=$?
check 'an untracked file: exit 1'      1 "$rc"
check 'it names the file'              yes "$(yesno '?? src/loose.txt')"
rm "$repo/src/loose.txt"; printf 'more\n' >> "$repo/src/clean.txt"
out="$(only_new "$repo")"; rc=$?
check 'an unstaged change: exit 1'     1 "$rc"
git -C "$repo" add src/clean.txt
out="$(only_new "$repo")"; rc=$?
check 'a staged change: exit 1'        1 "$rc"
git -C "$repo" reset -q --hard
printf 'loose.log\n' >> "$repo/.git/info/exclude"; printf 'ignored\n' > "$repo/src/loose.log"
out="$(only_new "$repo")"; rc=$?
check 'an ignored file counts not: exit 0' 0 "$rc"
rm "$repo/src/loose.log"

echo 'a deploy ref put on a commit origin already carries passes from a checkout that moved on'
deploy() {  # deploy <local sha> [<remote sha>] - put the deploy ref on that commit, new by default
  printf 'refs/heads/deploy %s refs/heads/deploy/test %s\n' "$1" "${2:-$zeros40}" \
    | ( cd "$repo" && bash "$root/bin/pre-push.sh" origin 'https://example.invalid/x.git' 2>&1 )
}
git -C "$repo" update-ref refs/remotes/origin/release-probe HEAD~1   # the release stands on origin
: > "$check_runs"
out="$(deploy "$(git -C "$repo" rev-parse HEAD~1)")"; rc=$?
check 'exit 0'                         0 "$rc"
check 'it sends nothing new'           yes "$(grep -q 'pre-push: nothing new to send' <<< "$out" && echo yes || echo no)"
check 'and runs no check'              '' "$(cat "$check_runs")"
out="$(judge "$repo" "$(git -C "$repo" rev-parse HEAD~1)" "$(git -C "$repo" rev-parse HEAD~2)")"; rc=$?
check 'the default branch still takes only what is checked out' 1 "$rc"
out="$(deploy "$(git -C "$repo" rev-parse HEAD~1)" "$(git -C "$repo" rev-parse HEAD~2)")"; rc=$?
check 'an existing deploy ref moves the same way' 0 "$rc"
out="$(deploy "$(git -C "$repo" rev-parse 'HEAD~1^{tree}')")"; rc=$?
check 'a tree is no commit, and is refused' 1 "$rc"
echo 'a commit origin does not carry is still refused there'
commit 'src/unpushed.txt' 'Write a commit origin does not have #16'
commit 'src/unpushed.txt' 'Move on past it #16'
out="$(deploy "$(git -C "$repo" rev-parse HEAD~1)")"; rc=$?
check 'exit 1'                         1 "$rc"
check 'it says what to push'           yes "$(grep -q 'push what you have: git push origin HEAD:deploy/test' <<< "$out" && echo yes || echo no)"
git -C "$repo" reset -q --hard HEAD~2
git -C "$repo" update-ref -d refs/remotes/origin/release-probe

# --- an annotated tag --------------------------------------------------------------------------
#
# A release is stamped with an annotated tag, and git hands a hook the TAG OBJECT's sha, never
# the commit it names. Compared to HEAD unresolved, that refuses every annotated tag there is.
echo 'an annotated tag naming the checked-out commit is not read as a foreign ref'
commit 'src/thing.txt' 'Stamp a version for the probe #15'
git -C "$repo" tag -a -m 'release 0.8.999' v0.8.999
out="$(judge "$repo" "$(git -C "$repo" rev-parse v0.8.999)" "$(git -C "$repo" rev-parse HEAD~1)")"; rc=$?
check 'exit 0'                        0 "$rc"
check 'and it is not called foreign'  no "$(grep -q 'is not what is checked out' <<< "$out" && echo yes || echo no)"

# --- the credential scan, armed by a file and by no name -------------------------------------
echo 'with no .gitleaks.toml in the tree, the commits are not scanned'
: > "$leaks_args"
commit 'src/thing.txt' 'Push once without the scan armed #15'
out="$(only_new "$repo")"; rc=$?
check 'exit 0'                 0 "$rc"
check 'gitleaks never ran'     '' "$(cat "$leaks_args")"

echo 'a .gitleaks.toml in the tree arms the scan, over the range the push carries'
: > "$leaks_args"
commit '.gitleaks.toml' 'Arm the credential scan of the probe #15'
before="$(git -C "$repo" rev-parse HEAD~1)"
out="$(judge "$repo" "$(git -C "$repo" rev-parse HEAD)" "$before")"; rc=$?
check 'exit 0'                    0 "$rc"
# Only the range is compared, not the tree.
check 'gitleaks read that range'  "git --no-banner --redact --report-format json --report-path - --log-opts=--diff-merges=remerge $(git -C "$repo" rev-parse HEAD) ^$before --not --remotes=origin" \
  "$(sed 's/^\[//; s/ [^ ]*$//' "$leaks_args")"

echo 'a credential in a pushed commit refuses, and says it cannot be recalled'
out="$(PROBE_LEAKS=red only_new "$repo")"; rc=$?
check 'exit 1'                 1 "$rc"
check 'it says what to do' yes "$(grep -q 'a commit that is pushed cannot be recalled' <<< "$out" && echo yes || echo no)"

echo 'a gitleaks without gitleaks git, one from before 8.19, refuses and names doctor'
out="$(PROBE_LEAKS=old only_new "$repo")"; rc=$?
check 'exit 1'                 1 "$rc"
check 'it names doctor'        yes "$(grep -q 'no gitleaks 8.19 or newer' <<< "$out" && grep -q 'Run ai-core doctor' <<< "$out" && echo yes || echo no)"

# --- a credential that stands only in how a merge was resolved ---------------------------------
# git log -p shows no patch for a merge unless asked to, so a push whose only new commit is a merge
# handed gitleaks nothing to read. The stub cannot show that: the real gitleaks reads the range.
echo 'a credential that stands only in a merge resolution is refused, by the real gitleaks'
real="$fake/real"; mkdir -p "$real"
[ -z "$real_gitleaks" ] || ln -s "$real_gitleaks" "$real/gitleaks"
check 'a real gitleaks is on this machine (ai-core doctor installs it)' yes "$([ -n "$real_gitleaks" ] && echo yes || echo no)"
merged="$fake/merged"; git init -q -b master "$merged"
git -C "$merged" config user.email 'test@example.invalid'; git -C "$merged" config user.name 'test'
printf '[extend]\nuseDefault = true\n' > "$merged/.gitleaks.toml"; printf 'value = 1\n' > "$merged/settings.txt"
git -C "$merged" add -A; git -C "$merged" commit -q -m 'Set the merge probe up #15'
git -C "$merged" checkout -q -b issue-15-merge
printf 'value = 2\n' > "$merged/settings.txt"; git -C "$merged" commit -q -a -m 'Change the value on the branch #15'
tip="$(git -C "$merged" rev-parse HEAD)"
git -C "$merged" update-ref refs/remotes/origin/issue-15-merge "$tip"   # the branch is on the remote
git -C "$merged" checkout -q master
printf 'value = 3\n' > "$merged/settings.txt"; git -C "$merged" commit -q -a -m 'Change the value on master #15'
git -C "$merged" update-ref refs/remotes/origin/master HEAD               # and so is master
git -C "$merged" checkout -q issue-15-merge
push_merge() {  # push_merge <resolution> [<message>] - merge master into the branch with a conflict, resolve it so, push the merge alone
  git -C "$merged" reset -q --hard "$tip"
  git -C "$merged" merge -q master >/dev/null 2>&1
  printf '%s\n' "$1" > "$merged/settings.txt"; git -C "$merged" add settings.txt; git -C "$merged" commit -q -m "${2:-Catch up with master}"
  printf 'refs/heads/issue-15-merge %s refs/heads/issue-15-merge %s\n' "$(git -C "$merged" rev-parse HEAD)" "$tip" \
    | ( cd "$merged" && PATH="$real:$PATH" bash "$root/bin/pre-push.sh" origin 'https://example.invalid/x.git' 2>&1 )
}
# Made here, so this file carries no string of a credential's shape.
token="ghp_$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 36)"
out="$(push_merge "value = 4")"; rc=$?
check 'PLANTED INNOCENT: a resolution without a credential goes out' 0 "$rc"
check 'and the merge was read'      yes "$(grep -q '1 commits scanned' <<< "$out" && echo yes || echo no)"
other="ghp_$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 36)"
in_message="ghp_$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 36)"
out="$(push_merge "token = \"$token\" other = \"$other\"" "Catch up, with $in_message in the message")"; rc=$?
check 'a resolution with a credential: exit 1' 1 "$rc"
check 'it says what to do'          yes "$(grep -q 'a commit that is pushed cannot be recalled' <<< "$out" && echo yes || echo no)"
# A file that had a conflict is b/<path> to gitleaks, as it parses git's conflict header.
check 'it names the file, the line and the rule' yes "$(grep -q ' b/settings.txt:1 github-pat$' <<< "$out" && echo yes || echo no)"
check 'and prints no part of any credential, the message one too' no "$(grep -qF -e "${token:4:12}" -e "${other:4:12}" -e "${in_message:4:12}" <<< "$out" && echo yes || echo no)"
echo 'a merge of three branches at once is refused: git shows no diff of what its author wrote'
git -C "$merged" reset -q --hard "$tip"
git -C "$merged" checkout -q -b side master~1; printf 'x\n' > "$merged/side.txt"; git -C "$merged" add side.txt; git -C "$merged" commit -q -m 'A side branch #15'
git -C "$merged" update-ref refs/remotes/origin/side HEAD
git -C "$merged" checkout -q issue-15-merge
git -C "$merged" merge -q --no-edit -s ours master side >/dev/null 2>&1
out="$(printf 'refs/heads/issue-15-merge %s refs/heads/issue-15-merge %s\n' "$(git -C "$merged" rev-parse HEAD)" "$tip" \
  | ( cd "$merged" && PATH="$real:$PATH" bash "$root/bin/pre-push.sh" origin 'https://example.invalid/x.git' 2>&1 ))"; rc=$?
check 'three parents'               3 "$(git -C "$merged" rev-list --parents -n1 HEAD | wc -w | tr -d ' ' | awk '{print $1-1}')"
check 'exit 1'                      1 "$rc"
check 'it says to merge one branch at a time' yes "$(grep -q 'Merge one branch at a time' <<< "$out" && echo yes || echo no)"
echo 'a git without --diff-merges=remerge, one before 2.36, refuses by name and never passes unread'
old_git="$fake/old-git"; mkdir -p "$old_git"
cat > "$old_git/git" <<EOF
#!/usr/bin/env bash
case "\$*" in *--diff-merges=remerge*) echo "fatal: invalid value for '--diff-merges': 'remerge'" >&2; exit 128 ;; esac
exec "$(command -v git)" "\$@"
EOF
chmod +x "$old_git/git"
out="$(PATH="$old_git:$PATH" push_merge "value = 5")"; rc=$?
check 'exit 1'                      1 "$rc"
check 'it names the git it needs'   yes "$(grep -q 'git 2.36 or newer' <<< "$out" && echo yes || echo no)"

# --- the names a push adds, derived from the families the trees already carry -------------------
# Two sibling repositories beside the one pushed: acme-shop has the parts backend, docs and
# frontend; acme-docs has docs and guide, so docs is a word of structure, no repository's name.
for s in acme-shop acme-docs; do git init -q -b master "$parent/$s"; git -C "$parent/$s" config user.email 'test@example.invalid'; git -C "$parent/$s" config user.name 'test'; done
for p in backend docs frontend; do mkdir -p "$parent/acme-shop/$p"; printf 'x\n' > "$parent/acme-shop/$p/a.txt"; done
for p in docs guide; do mkdir -p "$parent/acme-docs/$p"; printf 'x\n' > "$parent/acme-docs/$p/a.txt"; done
for s in acme-shop acme-docs; do git -C "$parent/$s" add -A; git -C "$parent/$s" commit -q -m 'The repository #1'; done
add_dirs() {  # add_dirs <message> <dir>... - one file in each new directory, one commit
  local message="$1" d; shift
  for d in "$@"; do mkdir -p "$repo/$d"; printf '{}\n' > "$repo/$d/en.json"; git -C "$repo" add -- "$d/en.json"; done
  git -C "$repo" commit -q -F - <<< "$message"
}

echo 'a family half named, and a part a sibling repository does not have: refused, with both'
add_dirs 'Add the shop texts #20' catalog/shop catalog/shop-server
out="$(only_new "$repo")"; rc=$?
check 'exit 1'                      1 "$rc"
check 'the half-named family'       yes "$(grep -q 'catalog/shop beside catalog/shop-server: one member of the family says its side, the other does not' <<< "$out" && echo yes || echo no)"
check 'the part the sibling lacks'  yes "$(grep -q 'catalog/shop-server names a part of the repository acme-shop, and acme-shop has no server; its parts are backend, docs, frontend' <<< "$out" && echo yes || echo no)"
git -C "$repo" reset -q --hard HEAD~1

echo 'names derived from the family pass'
add_dirs 'Add the shop texts, named after its parts #20' catalog/shop-backend catalog/shop-frontend
out="$(only_new "$repo")"; rc=$?
check 'exit 0'                      0 "$rc"

echo 'a word of structure is no repository'"'"'s name: manual/docs-extra is not held against acme-docs'
add_dirs 'Add the extra documents #21' manual/docs-extra
out="$(only_new "$repo")"; rc=$?
check 'exit 0'                      0 "$rc"

echo 'a lone name that opens with a repository'"'"'s name mirrors nothing: manual/shop-notes passes'
add_dirs 'Add the notes of the shop visit #23' manual/shop-notes
out="$(only_new "$repo")"; rc=$?
check 'exit 0'                      0 "$rc"

echo 'a Naming: trailer keeps a name, and says why'
add_dirs $'Add the server texts #22\n\nNaming: the product owner calls this part server' catalog/shop-server
out="$(only_new "$repo")"; rc=$?
check 'exit 0'                      0 "$rc"

# A move is read by its content, so every file below differs from every other: git pairs files of
# equal content across folders at will.
mark="$(git -C "$repo" rev-parse HEAD)"
seed_dirs() {  # seed_dirs <message> <dir>... - one file of its own content in each, one commit
  local message="$1" d; shift
  for d in "$@"; do mkdir -p "$repo/$d"; printf '{"seed":"%s"}\n' "$d" > "$repo/$d/en.json"; git -C "$repo" add -- "$d/en.json"; done
  git -C "$repo" commit -q -m "$message"
}
moved() {  # moved <message> <from> <to> - one git mv, one commit
  mkdir -p "$repo/$(dirname "$3")"; git -C "$repo" mv "$2" "$3"; git -C "$repo" commit -q -m "$1"
}
echo 'a folder moved with git mv keeps the names inside it'
seed_dirs 'Add the workshop seeds #24' apps/workshop/seeds apps/workshop/seeds-demo
moved 'Rename the workshop app #24' apps/workshop apps/bike-workshop
out="$(only_new "$repo")"; rc=$?
check 'exit 0'                      0 "$rc"

echo 'a member moved to a new half name is refused'
moved 'Rename the demo seeds #24' apps/bike-workshop/seeds-demo apps/bike-workshop/seeds-x
out="$(only_new "$repo")"; rc=$?
check 'exit 1'                      1 "$rc"
check 'the half-named family'       yes "$(grep -q 'apps/bike-workshop/seeds beside apps/bike-workshop/seeds-x: one member of the family' <<< "$out" && echo yes || echo no)"

echo 'a folder moved beside a member of a family it did not stand beside is refused'
seed_dirs 'Add the lab seeds #24' plain/seeds lab/seeds-demo
moved 'Move the plain seeds to the lab #24' plain/seeds lab/seeds
out="$(only_new "$repo")"; rc=$?
check 'exit 1'                      1 "$rc"
check 'the half-named family'       yes "$(grep -q 'lab/seeds beside lab/seeds-demo: one member of the family' <<< "$out" && echo yes || echo no)"

echo 'a member moved from its family to another member of the same name is refused'
seed_dirs 'Add the kiosk seeds #24' kiosk/seeds kiosk/seeds-demo stall/seeds-demo
moved 'Move the kiosk seeds to the stall #24' kiosk/seeds stall/seeds
out="$(only_new "$repo")"; rc=$?
check 'exit 1'                      1 "$rc"
check 'the half-named family'       yes "$(grep -q 'stall/seeds beside stall/seeds-demo: one member of the family' <<< "$out" && echo yes || echo no)"

echo 'a member moved to the top, beside a member there, is refused'
seed_dirs 'Add the market plants #24' market/plants market/plants-demo plants-demo
moved 'Move the market plants to the top #24' market/plants plants
out="$(only_new "$repo")"; rc=$?
check 'exit 1'                      1 "$rc"
check 'the half-named family'       yes "$(grep -q '^pre-push: plants beside plants-demo: one member of the family' <<< "$out" && echo yes || echo no)"

echo 'a folder moved whole keeps its names, also where git pairs its empty files across'
mkdir -p "$repo/depot/seeds" "$repo/depot/seeds-demo"; : > "$repo/depot/seeds/.gitkeep"; : > "$repo/depot/seeds-demo/.gitkeep"
git -C "$repo" add -- depot; git -C "$repo" commit -q -m 'Add the depot #24'
git -C "$repo" mv depot big-depot; mkdir -p "$repo/aaa"; : > "$repo/aaa/.gitkeep"; git -C "$repo" add -- aaa
git -C "$repo" commit -q -m 'Rename the depot, and add aaa #24'
out="$(only_new "$repo")"; rc=$?
check 'exit 0'                      0 "$rc"

echo 'a family copied out by moving one file of each member, the members staying, is refused'
for d in tools/seeds tools/seeds-demo; do mkdir -p "$repo/$d"; for f in a b; do printf '{"seed":"%s/%s"}\n' "$d" "$f" > "$repo/$d/$f.json"; done; done
git -C "$repo" add -- tools; git -C "$repo" commit -q -m 'Add the tool seeds #24'
mkdir -p "$repo/yard/seeds" "$repo/yard/seeds-demo"
git -C "$repo" mv tools/seeds/a.json yard/seeds/a.json; git -C "$repo" mv tools/seeds-demo/a.json yard/seeds-demo/a.json
git -C "$repo" commit -q -m 'Move one tool seed of each into the yard #24'
out="$(only_new "$repo")"; rc=$?
check 'exit 1'                      1 "$rc"
check 'the half-named family'       yes "$(grep -q 'yard/seeds beside yard/seeds-demo: one member of the family' <<< "$out" && echo yes || echo no)"

echo 'a moved folder that names a part only where it lands is refused'
seed_dirs 'Add the shop api notes #24' misc/shop-api
moved 'Move the shop api notes into the catalog #24' misc/shop-api catalog/shop-api
out="$(only_new "$repo")"; rc=$?
check 'exit 1'                      1 "$rc"
check 'the part the sibling lacks'  yes "$(grep -q 'catalog/shop-api names a part of the repository acme-shop, and acme-shop has no api' <<< "$out" && echo yes || echo no)"

echo 'a name below a folder of non-ASCII letters is read, not skipped'
seed_dirs 'Add the demo seeds of the fields #24' "über/lab/seeds-demo"
seed_dirs 'Add the seeds of the fields #24' "über/lab/seeds"
out="$(only_new "$repo")"; rc=$?
check 'exit 1'                      1 "$rc"
check 'the half-named family'       yes "$(grep -q 'über/lab/seeds beside über/lab/seeds-demo: one member of the family' <<< "$out" && echo yes || echo no)"

echo 'a member of non-ASCII letters is read beside its sibling, not skipped'
seed_dirs 'Add the green seeds of the fields #24' "feld/grün"
seed_dirs 'Add the green demo seeds of the fields #24' "feld/grün-demo"
out="$(only_new "$repo")"; rc=$?
check 'exit 1'                      1 "$rc"
check 'the half-named family'       yes "$(grep -q 'feld/grün beside feld/grün-demo: one member of the family' <<< "$out" && echo yes || echo no)"

echo 'a name below a folder with a double quote is read, not skipped'
seed_dirs 'Add the demo seeds of the quoted lab #24' 'q"x/lab/seeds-demo'
seed_dirs 'Add the seeds of the quoted lab #24' 'q"x/lab/seeds'
out="$(only_new "$repo")"; rc=$?
check 'exit 1'                      1 "$rc"
check 'the half-named family'       yes "$(grep -qF 'q"x/lab/seeds beside q"x/lab/seeds-demo: one member of the family' <<< "$out" && echo yes || echo no)"

echo 'a folder with a double quote moved with git mv keeps the names inside it'
seed_dirs 'Add the seeds of the quoted shop #24' 'q"x/shop/seeds' 'q"x/shop/seeds-demo'
moved 'Rename the quoted shop #24' 'q"x/shop' 'q"x/bike-shop'
out="$(only_new "$repo")"; rc=$?
check 'exit 0'                      0 "$rc"
git -C "$repo" reset -q --hard "$mark"

# --- a repository without scripts/check.sh --------------------------------------------------
echo 'a repository without scripts/check.sh: nothing runs before the push'
bare="$fake/bare.git"; git init -q --bare -b master "$bare"
plain="$fake/plain"; git init -q -b master "$plain"
git -C "$plain" config user.email 'test@example.invalid'; git -C "$plain" config user.name 'test'
printf 'a file\n' > "$plain/first.txt"
git -C "$plain" add -A; git -C "$plain" commit -q -m 'A repository with no check #7'
git -C "$plain" remote add origin "$bare"; git -C "$plain" push -q -u origin master 2>/dev/null
printf 'more\n' > "$plain/more.txt"; git -C "$plain" add -A; git -C "$plain" commit -q -m 'Add more #7'
out="$(only_new "$plain")"; rc=$?
check 'exit 0'                              0 "$rc"
check 'it says nothing runs'                yes "$(grep -q 'no scripts/check.sh in this repository' <<< "$out" && echo yes || echo no)"

# --- from a prompt: the current branch against its upstream ----------------------------------
echo 'with nothing on standard input, the branch is judged against its upstream'
out="$(marked_terminal_gate "$plain")"; rc=$?
check 'exit 0'                     0 "$rc"
check 'it names the upstream'      yes "$(grep -q 'pre-push: judging master against origin/master' <<< "$out" && echo yes || echo no)"
git -C "$plain" commit -q --allow-empty -m 'An empty commit that names nothing'
out="$(marked_terminal_gate "$plain")"; rc=$?
check 'a new unnamed commit is refused'  1 "$rc"
git -C "$plain" reset -q --hard HEAD~1

# --- --install: the shim, and what it hands the gate --------------------------------------------
echo '--install writes the shim, arms the clone, commits the shim on its own and says it has no origin to push to'
fresh="$fake/fresh"; git init -q -b master "$fresh"
git -C "$fresh" config user.email 'test@example.invalid'; git -C "$fresh" config user.name 'test'
printf 'work in progress\n' > "$fresh/open.txt"; git -C "$fresh" add open.txt   # somebody's staged work stays out of the commit
out="$( cd "$fresh" && bash "$root/bin/pre-push.sh" --install 2>&1 )"; rc=$?
check 'exit 0'                        0 "$rc"
check 'created'                       yes "$(grep -q '^pre-push: fresh: .githooks/pre-push created$' <<< "$out" && echo yes || echo no)"
check 'post-checkout created'         yes "$(grep -q '^pre-push: fresh: .githooks/post-checkout created$' <<< "$out" && echo yes || echo no)"
check 'post-checkout starts init where .ai-core/STAMP is missing' yes "$(grep -qx 'ai-core init --no-doctor || echo "post-checkout: the harness is NOT complete in this worktree (see above); run ai-core init here before you start" >&2' "$fresh/.githooks/post-checkout" && echo yes || echo no)"
check 'the attributes rule, so the shims check out LF' yes "$(grep -q '^pre-push: fresh: .gitattributes: .githooks/\* text eol=lf added; the shims check out LF everywhere$' <<< "$out" && grep -qxF '.githooks/* text eol=lf' "$fresh/.gitattributes" && echo yes || echo no)"
check 'git reads it'                  '.githooks/pre-push: eol: lf' "$(git -C "$fresh" check-attr eol -- .githooks/pre-push)"
check 'core.hooksPath set'            .githooks "$(git -C "$fresh" config --get core.hooksPath)"
check 'the shim starts the gate'      yes "$(grep -qx 'exec ai-core pre-push "$@"' "$fresh/.githooks/pre-push" && echo yes || echo no)"
check 'four lines'                    4 "$(wc -l < "$fresh/.githooks/pre-push" | tr -d ' ')"
check 'committed'                     yes "$(grep -q '^pre-push: fresh: committed [0-9a-f]' <<< "$out" && echo yes || echo no)"
check 'no origin, not pushed'         yes "$(grep -q '^pre-push: fresh: no origin; not pushed$' <<< "$out" && echo yes || echo no)"
check 'the commit subject'            'the hooks of ai-core: the push gate, init in a new worktree' "$(git -C "$fresh" log -1 --format=%s)"
check 'the No-issue trailer'          'written, committed and pushed by ai-core pre-push --install' "$(git -C "$fresh" log -1 --format='%(trailers:key=No-issue,valueonly)' | tr -d '\n')"
check 'the shims and the rule in the commit' '.gitattributes .githooks/post-checkout .githooks/pre-push' "$(git -C "$fresh" show --pretty=format: --name-only HEAD | grep -v '^$' | tr '\n' ' ' | sed 's/ $//')"
check 'the rule file is plain'        100644 "$(git -C "$fresh" ls-tree HEAD .gitattributes | cut -c1-6)"
check 'with the executable bit'       100755 "$(git -C "$fresh" ls-tree HEAD .githooks/pre-push | cut -c1-6)"
check 'post-checkout too'             100755 "$(git -C "$fresh" ls-tree HEAD .githooks/post-checkout | cut -c1-6)"
check 'the staged work is still staged, uncommitted' 'A  open.txt' "$(git -C "$fresh" status --porcelain open.txt)"
head1="$(git -C "$fresh" rev-parse HEAD)"
out="$( cd "$fresh" && bash "$root/bin/pre-push.sh" --install 2>&1 )"; rc=$?
check 'a second run: unchanged'       yes "$(grep -q '^pre-push: fresh: .githooks/pre-push unchanged$' <<< "$out" && echo yes || echo no)"
check 'post-checkout unchanged too'   yes "$(grep -q '^pre-push: fresh: .githooks/post-checkout unchanged$' <<< "$out" && echo yes || echo no)"
check 'and nothing about .gitattributes' no "$(grep -q 'gitattributes' <<< "$out" && echo yes || echo no)"
check 'and no new commit'             "$head1" "$(git -C "$fresh" rev-parse HEAD)"
check 'and nothing about hooksPath'   no "$(grep -q 'hooksPath' <<< "$out" && echo yes || echo no)"
printf '#!/usr/bin/env bash\nexec bash ../tooling/hooks/pre-push "$@"\n' > "$fresh/.githooks/pre-push"
git -C "$fresh" commit -q -am 'An older shim, as a repository of the old tooling carries #9'
out="$( cd "$fresh" && bash "$root/bin/pre-push.sh" --install 2>&1 )"; rc=$?
check 'a shim of another kind: refreshed and committed' yes "$(grep -q '^pre-push: fresh: .githooks/pre-push refreshed$' <<< "$out" && grep -q '^pre-push: fresh: committed' <<< "$out" && echo yes || echo no)"
check 'and it is the shim again'      yes "$(grep -qx 'exec ai-core pre-push "$@"' "$fresh/.githooks/pre-push" && echo yes || echo no)"

echo 'the shim hands the gate git'"'"'s arguments and input'
: > "$shim_args"
printf 'refs/heads/master abc refs/heads/master def\n' | ( cd "$fresh" && bash .githooks/pre-push origin 'https://example.invalid/x.git' )
check 'ai-core pre-push was started with them' '[pre-push origin https://example.invalid/x.git] refs/heads/master abc refs/heads/master def' "$(cat "$shim_args")"

echo 'without ai-core on the PATH the shim refuses and says so'
out="$( cd "$fresh" && PATH="$(path_without_ai_core)" bash .githooks/pre-push origin url < /dev/null 2>&1 )"; rc=$?
check 'exit 1'                  1 "$rc"
check 'it names the cause'      yes "$(grep -q 'ai-core is not on the PATH of this shell' <<< "$out" && echo yes || echo no)"

echo 'post-checkout: a worktree cut from the checkout starts ai-core init; a branch checkout where .ai-core/STAMP is present starts nothing'
: > "$shim_args"
mkdir -p "$fresh/.ai-core"; : > "$fresh/.ai-core/STAMP"
git -C "$fresh" checkout -q -b probe-branch < /dev/null 2>/dev/null
check 'nothing started in the checkout' '' "$(cat "$shim_args")"
fresh_wt="$fake/fresh-wt"
git -C "$fresh" worktree add -q --detach "$fresh_wt" HEAD < /dev/null 2>"$fake/wt-err.txt"; rc=$?
check 'git worktree add: exit 0'      0 "$rc"
check 'ai-core init started in the new worktree' '[init --no-doctor] ' "$(cat "$shim_args")"
check 'nothing on stderr'             '' "$(cat "$fake/wt-err.txt")"
git -C "$fresh" worktree remove --force "$fresh_wt" >/dev/null 2>&1
: > "$shim_args"

echo 'post-checkout: a worktree of a commit that tracks a file under .ai-core/ starts ai-core init too, the folder there before the harness; planted: the shim of before, which looked for the folder alone, starts nothing'
tracking="$fake/tracking"; git init -q -b master "$tracking"
git -C "$tracking" config user.email 'test@example.invalid'; git -C "$tracking" config user.name 'test'
mkdir -p "$tracking/.githooks" "$tracking/.ai-core"; cp "$fresh/.githooks/post-checkout" "$tracking/.githooks/"
printf 'area\tarea:own\t0E8A16\tIts own\n' > "$tracking/.ai-core/labels.tsv"
git -C "$tracking" add .githooks; git -C "$tracking" add -f .ai-core/labels.tsv; git -C "$tracking" commit -q -m 'Its own catalog #358'
git -C "$tracking" config core.hooksPath .githooks
tracking_wt="$fake/tracking-wt"
git -C "$tracking" worktree add -q --detach "$tracking_wt" HEAD < /dev/null 2>"$fake/wt-err.txt"; rc=$?
check 'git worktree add: exit 0'      0 "$rc"
check 'the tracked file is there, no STAMP' 'yes no' "$([ -f "$tracking_wt/.ai-core/labels.tsv" ] && echo yes || echo no) $([ -e "$tracking_wt/.ai-core/STAMP" ] && echo yes || echo no)"
check 'ai-core init started in the new worktree' '[init --no-doctor] ' "$(cat "$shim_args")"
git -C "$tracking" worktree remove --force "$tracking_wt" >/dev/null 2>&1
: > "$shim_args"
sed 's@\[ ! -f \.ai-core/STAMP \]@[ ! -d .ai-core ]@' "$tracking/.githooks/post-checkout" > "$fake/old-post-checkout"
cmp -s "$tracking/.githooks/post-checkout" "$fake/old-post-checkout" && { echo "  FAIL the planted shim equals the one --install writes"; failed=$((failed + 1)); }
cp "$fake/old-post-checkout" "$tracking/.githooks/post-checkout"; git -C "$tracking" commit -q -am 'The shim of before'
git -C "$tracking" worktree add -q --detach "$tracking_wt" HEAD < /dev/null 2>/dev/null
check 'planted: the shim of before starts nothing there, so the check above can go red' '' "$(cat "$shim_args")"
git -C "$tracking" worktree remove --force "$tracking_wt" >/dev/null 2>&1
: > "$shim_args"

echo 'post-checkout without ai-core on the PATH: the worktree is made, exit 0, and stderr says what to run'
out="$( cd "$fresh" && PATH="$(path_without_ai_core)" git worktree add -q --detach "$fresh_wt" HEAD < /dev/null 2>&1 )"; rc=$?
check 'exit 0'                        0 "$rc"
check 'the worktree is there'         yes "$([ -d "$fresh_wt" ] && echo yes || echo no)"
check 'it names the cause'            yes "$(grep -q 'post-checkout: ai-core is not on the PATH of this shell, so this worktree has no harness yet; run ai-core init here before you start' <<< "$out" && echo yes || echo no)"
git -C "$fresh" worktree remove --force "$fresh_wt" >/dev/null 2>&1
git -C "$fresh" checkout -q master < /dev/null 2>/dev/null; git -C "$fresh" branch -q -D probe-branch; rm -rf "$fresh/.ai-core"

echo 'with an origin, the commit is pushed by ref, through the gate'
origin_bare="$fake/origin.git"; git init -q --bare -b master "$origin_bare"
pushed="$fake/pushed"; git init -q -b master "$pushed"
git -C "$pushed" config user.email 'test@example.invalid'; git -C "$pushed" config user.name 'test'
printf 'a\n' > "$pushed/a.txt"; git -C "$pushed" add -A; git -C "$pushed" commit -q -m 'Start #3'
git -C "$pushed" remote add origin "$origin_bare"; git -C "$pushed" push -q -u origin master 2>/dev/null
# two clones of this state, which the origin moves past below: one clean, one with a change of its own
for c in behind dirty; do git clone -q "$origin_bare" "$fake/$c" 2>/dev/null; git -C "$fake/$c" config user.email 'test@example.invalid'; git -C "$fake/$c" config user.name 'test'; done
printf 'mine\n' >> "$fake/dirty/a.txt"
: > "$shim_args"
out="$( cd "$pushed" && bash "$root/bin/pre-push.sh" --install 2>&1 )"; rc=$?
check 'exit 0'                        0 "$rc"
check 'pushed to origin/master'       yes "$(grep -q '^pre-push: pushed: pushed to origin/master$' <<< "$out" && echo yes || echo no)"
check 'the origin has the commit'     "$(git -C "$pushed" rev-parse HEAD)" "$(git -C "$origin_bare" rev-parse master)"
check 'and the push went through the shim, so through ai-core pre-push' yes "$(grep -q '^\[pre-push origin ' "$shim_args" && echo yes || echo no)"

echo 'the origin moves on while the gate runs: the commit goes on top of it and is pushed once more'
race_origin="$fake/race-origin.git"; git clone -q --bare "$origin_bare" "$race_origin" 2>/dev/null   # its own origin: the other cases count the commits of theirs
racing="$fake/racing"; git clone -q "$race_origin" "$racing" 2>/dev/null
git -C "$racing" config user.email 'test@example.invalid'; git -C "$racing" config user.name 'test'
printf '#!/usr/bin/env bash\nexec bash ../tooling/hooks/pre-push "$@"\n' > "$racing/.githooks/pre-push"
git -C "$racing" commit -q -am 'An older shim #11'; git -C "$racing" push -q --no-verify origin HEAD:master 2>/dev/null
other="$fake/other"; git clone -q "$race_origin" "$other" 2>/dev/null
git -C "$other" config user.email 'test@example.invalid'; git -C "$other" config user.name 'test'
race="$fake/race.sh"; rm -f "$race.done"
printf 'cd %q && git pull -q --no-rebase origin master && printf "o\\n" >> other.txt && git add other.txt && git commit -q -m "Other work #12" && git push -q --no-verify origin HEAD:master\n' "$other" > "$race"
out="$( cd "$racing" && PROBE_RACE="$race" bash "$root/bin/pre-push.sh" --install 2>&1 )"; rc=$?
check 'exit 0'                        0 "$rc"
check 'the race happened'             yes "$([ -e "$race.done" ] && echo yes || echo no)"
check 'it says so'                    yes "$(grep -q '^pre-push: racing: the origin moved on during the push; the commit went on top of it and was pushed to origin/master$' <<< "$out" && echo yes || echo no)"
check 'the origin has the commit'     "$(git -C "$racing" rev-parse HEAD)" "$(git -C "$race_origin" rev-parse master)"
check 'on top of the other work'      'Other work #12' "$(git -C "$racing" log -1 --format=%s HEAD~1)"
check 'and the tree is clean'         '' "$(git -C "$racing" status --porcelain --untracked-files=no)"

echo 'the gate refuses the push of the hook commit: the commit is undone and the hooks are as they were'
printf '#!/usr/bin/env bash\nexec bash ../tooling/hooks/pre-push "$@"\n' > "$racing/.githooks/pre-push"
git -C "$racing" commit -q -am 'An older shim again #13'; git -C "$racing" push -q --no-verify origin HEAD:master 2>/dev/null
head_r="$(git -C "$racing" rev-parse HEAD)"; old_shim="$(cat "$racing/.githooks/pre-push")"
out="$( cd "$racing" && PROBE_GATE=red bash "$root/bin/pre-push.sh" --install 2>&1 )"; rc=$?
check 'exit 1'                        1 "$rc"
check 'it says what it did'           yes "$(grep -q '^pre-push: racing: the push was refused (see above), so its commit is undone and the hooks are as they were; run ai-core pre-push --install here again once a push can go$' <<< "$out" && echo yes || echo no)"
check 'no commit ahead of the origin' "$head_r" "$(git -C "$racing" rev-parse HEAD)"
check 'the origin is unchanged'       "$head_r" "$(git -C "$race_origin" rev-parse master)"
check 'the shim is the one it was'    "$old_shim" "$(cat "$racing/.githooks/pre-push")"
check 'and the tree is clean'         '' "$(git -C "$racing" status --porcelain --untracked-files=no)"

echo 'a session commits in the checkout while the gate runs, and the gate refuses: its commit and its file stay'
printf '#!/usr/bin/env bash\nexec bash ../tooling/hooks/pre-push "$@"\n' > "$racing/.githooks/pre-push"
git -C "$racing" commit -q -am 'An older shim a third time #14'; git -C "$racing" push -q --no-verify origin HEAD:master 2>/dev/null
race="$fake/race-local.sh"; rm -f "$race.done"
printf 'cd %q && printf "b\\n" > session-b.txt && git add session-b.txt && git commit -q -m "Session B work #15"\n' "$racing" > "$race"
out="$( cd "$racing" && PROBE_RACE="$race" PROBE_GATE=red bash "$root/bin/pre-push.sh" --install 2>&1 )"; rc=$?
check 'exit 1'                        1 "$rc"
check 'it says the commit stays'      yes "$(grep -q '^pre-push: racing: the push was refused (see above), and its commit could not be undone; it stays on master$' <<< "$out" && echo yes || echo no)"
check 'the session commit is HEAD'    'Session B work #15' "$(git -C "$racing" log -1 --format=%s HEAD)"
check 'and its file is there'         b "$(cat "$racing/session-b.txt" 2>/dev/null)"
git -C "$racing" reset -q --hard origin/master; rm -f "$racing/session-b.txt"

echo 'another session pushes the same hooks while the gate runs: nothing to push, and nothing undone'
printf '#!/usr/bin/env bash\nexec bash ../tooling/hooks/pre-push "$@"\n' > "$racing/.githooks/pre-push"
git -C "$racing" commit -q -am 'An older shim a fourth time #16'; git -C "$racing" push -q --no-verify origin HEAD:master 2>/dev/null
race="$fake/race-same.sh"; rm -f "$race.done"
printf 'cd %q && git pull -q --no-rebase origin master && cp %q/.githooks/pre-push %q/.githooks/post-checkout .githooks/ && git add .githooks && git commit -q -m "The same hooks #17" && git push -q --no-verify origin HEAD:master\n' "$other" "$racing" "$racing" > "$race"
out="$( cd "$racing" && PROBE_RACE="$race" PROBE_GATE=red bash "$root/bin/pre-push.sh" --install 2>&1 )"; rc=$?
check 'exit 0'                        0 "$rc"
check 'it says so'                    yes "$(grep -q '^pre-push: racing: the origin moved on during the push and carries these hooks already; nothing to push$' <<< "$out" && echo yes || echo no)"
check 'level with the origin'         "$(git -C "$race_origin" rev-parse master)" "$(git -C "$racing" rev-parse HEAD)"
check 'and the tree is clean'         '' "$(git -C "$racing" status --porcelain --untracked-files=no)"

echo 'with rebase.autoStash on and a change of a person in the tree, the rebase refuses and the change stays as it was'
printf '#!/usr/bin/env bash\nexec bash ../tooling/hooks/pre-push "$@"\n' > "$racing/.githooks/pre-push"
git -C "$racing" commit -q -am 'An older shim a fifth time #18'; git -C "$racing" push -q --no-verify origin HEAD:master 2>/dev/null
git -C "$racing" config rebase.autoStash true
printf 'mine\n' >> "$racing/other.txt"; edit="$(cat "$racing/other.txt")"; head_r="$(git -C "$racing" rev-parse HEAD)"
race="$fake/race-stash.sh"; rm -f "$race.done"
printf 'cd %q && git pull -q --no-rebase origin master && printf "theirs\\n" >> other.txt && git commit -q -am "Other work again #19" && git push -q --no-verify origin HEAD:master\n' "$other" > "$race"
out="$( cd "$racing" && PROBE_RACE="$race" bash "$root/bin/pre-push.sh" --install 2>&1 )"; rc=$?
check 'exit 1'                        1 "$rc"
check 'the commit is undone'          "$head_r" "$(git -C "$racing" rev-parse HEAD)"
check 'the change is as it was'       "$edit" "$(cat "$racing/other.txt")"
check 'no stash was left'             '' "$(git -C "$racing" stash list)"
check 'no file is unmerged'           '' "$(git -C "$racing" diff --name-only --diff-filter=U)"
git -C "$racing" config --unset rebase.autoStash; git -C "$racing" checkout -q -- other.txt

echo 'an unpushed commit that touches only .gitignore and names no issue gets the trailer, and the push goes through'
printf 'node_modules/\n' > "$pushed/.gitignore"; git -C "$pushed" add .gitignore; git -C "$pushed" commit -q -m 'chore: ignore node_modules'
out="$( cd "$pushed" && bash "$root/bin/pre-push.sh" --install 2>&1 )"; rc=$?
check 'exit 0'                        0 "$rc"
check 'the shim needs no commit of its own' no "$(grep -q '^pre-push: pushed: committed' <<< "$out" && echo yes || echo no)"
check 'it says which commit and why'  yes "$(grep -q 'chore: ignore node_modules) touches only .gitignore and names no issue; it gets the trailer' <<< "$out" && echo yes || echo no)"
check 'the trailer is on that commit' 'the .gitignore block written by ai-core init' "$(git -C "$pushed" log -1 --format='%(trailers:key=No-issue,valueonly)' HEAD | tr -d '\n')"
check 'its subject is kept'           'chore: ignore node_modules' "$(git -C "$pushed" log -1 --format=%s HEAD)"
check 'pushed'                        yes "$(grep -q '^pre-push: pushed: pushed to origin/master$' <<< "$out" && echo yes || echo no)"
check 'the origin has it all'         "$(git -C "$pushed" rev-parse HEAD)" "$(git -C "$origin_bare" rev-parse master)"

echo 'a clone the origin has moved past catches up first: the shims arrive with it, no second commit, nothing to push'
out="$( cd "$fake/behind" && bash "$root/bin/pre-push.sh" --install 2>&1 )"; rc=$?
check 'exit 0'                        0 "$rc"
check 'it says it caught up'          yes "$(grep -q '^pre-push: behind: pulled 2 commit(s) from origin/master first$' <<< "$out" && echo yes || echo no)"
check 'the shims came with it'        yes "$(grep -q '^pre-push: behind: .githooks/pre-push unchanged$' <<< "$out" && echo yes || echo no)"
check 'no commit of its own'          no "$(grep -q '^pre-push: behind: committed' <<< "$out" && echo yes || echo no)"
check 'level with the origin'         "$(git -C "$origin_bare" rev-parse master)" "$(git -C "$fake/behind" rev-parse HEAD)"

echo 'a clone behind its origin with a change of its own: nothing written, nothing committed, and why'
head_d="$(git -C "$fake/dirty" rev-parse HEAD)"
out="$( cd "$fake/dirty" && bash "$root/bin/pre-push.sh" --install 2>&1 )"; rc=$?
check 'exit 1'                        1 "$rc"
check 'it says why'                   yes "$(grep -q '^pre-push: dirty: this checkout is 2 commit(s) behind origin/master, with changes to tracked files; pull, then run this again; nothing installed$' <<< "$out" && echo yes || echo no)"
check 'no shims'                      no "$([ -e "$fake/dirty/.githooks" ] && echo yes || echo no)"
check 'no commit'                     "$head_d" "$(git -C "$fake/dirty" rev-parse HEAD)"

echo "shims committed without the executable bit, as a copy that drops the file modes leaves them: committed with it and pushed; the project's own hook named and left"
before="$(git -C "$pushed" rev-parse HEAD)"
printf '#!/bin/sh\nexit 0\n' > "$pushed/.githooks/pre-commit"
git -C "$pushed" add --chmod=-x .githooks/pre-push .githooks/post-checkout .githooks/pre-commit
chmod -x "$pushed/.githooks/pre-push" "$pushed/.githooks/post-checkout" "$pushed/.githooks/pre-commit"
git -C "$pushed" -c advice.ignoredHook=false commit -q -m 'The hooks as a copy without the file modes writes them #4'; git -C "$pushed" push -q --no-verify origin HEAD:master 2>/dev/null
out="$( cd "$pushed" && bash "$root/bin/pre-push.sh" --install 2>&1 )"; rc=$?
check 'exit 0'                        0 "$rc"
check 'committed'                     yes "$(grep -q '^pre-push: pushed: committed ' <<< "$out" && echo yes || echo no)"
check 'the origin has the bit'        '100755 100755' "$(git -C "$origin_bare" ls-tree master -- .githooks/post-checkout .githooks/pre-push | awk '{ print $1 }' | tr '\n' ' ' | sed 's/ $//')"
check "the project's own hook is named" yes "$(grep -q "^pre-push: pushed: .githooks/pre-commit is not executable, so git skips it; it is the project's own and stays as it is$" <<< "$out" && echo yes || echo no)"
check 'and left as it is'             100644 "$(git -C "$origin_bare" ls-tree master -- .githooks/pre-commit | awk '{ print $1 }')"
git -C "$pushed" push -q --no-verify --force origin "$before:master" 2>/dev/null; git -C "$pushed" reset -q --hard "$before"

echo 'an unpushed commit that touches something else and names no issue is still refused, by the gate: the install did not write it, so its push is a plain one'
printf 'x\n' > "$pushed/x.txt"; git -C "$pushed" add x.txt; git -C "$pushed" commit -q -m 'Add x without a ticket'
printf '#!/usr/bin/env bash\nexec bash ../tooling/hooks/pre-push "$@"\n' > "$pushed/.githooks/pre-push"
out="$( cd "$pushed" && PATH="$root/bin:$PATH" bash "$root/bin/pre-push.sh" --install 2>&1 )"; rc=$?
check 'exit 1'                        1 "$rc"
check 'the gate refuses it as a plain push' yes "$(grep -q 'master takes no plain push' <<< "$out" && echo yes || echo no)"
check 'the push was refused, the commit stays' yes "$(grep -q 'the push was refused or failed (see above); the commit stays' <<< "$out" && echo yes || echo no)"
git -C "$pushed" reset -q --hard origin/master   # the foreign commit goes; the origin is where the last push left it

echo "a worktree whose commit carries another gate gets this gate's shim, uncommitted; the post-checkout its commit carries is left; only the checkout commits"
printf '#!/usr/bin/env bash\nexec bash ../tooling/hooks/pre-push "$@"\n' > "$pushed/.githooks/pre-push"
git -C "$pushed" commit -q -am 'An older shim, as a worktree branched off it would carry #9'
pushed_wt="$fake/pushed-wt"; git -C "$pushed" worktree add -q -b issue-9-probe "$pushed_wt" master
head_before="$(git -C "$pushed" rev-parse HEAD)"
out="$( cd "$pushed" && bash "$root/bin/pre-push.sh" --install 2>&1 )"; rc=$?
check 'exit 0'                              0 "$rc"
check 'the checkout: refreshed, committed, pushed' yes "$(grep -q '^pre-push: pushed: .githooks/pre-push refreshed$' <<< "$out" && grep -q '^pre-push: pushed: pushed to origin/master$' <<< "$out" && echo yes || echo no)"
check 'the worktree: refreshed, and left to its own commit' yes "$(grep -q "^pre-push: pushed (worktree pushed-wt): .githooks/pre-push refreshed; it goes out with that worktree's own commit$" <<< "$out" && echo yes || echo no)"
check 'the worktree carries the shim'       yes "$(grep -qx 'exec ai-core pre-push "$@"' "$pushed_wt/.githooks/pre-push" && echo yes || echo no)"
check 'its post-checkout: not written'      no "$(grep -q '(worktree pushed-wt): .githooks/post-checkout' <<< "$out" && echo yes || echo no)"
check 'the worktree has pre-push uncommitted, nothing else' ' M .githooks/pre-push' "$(git -C "$pushed_wt" status --porcelain)"
check 'the checkout moved by one commit'    "$head_before" "$(git -C "$pushed" rev-parse HEAD~1)"
git -C "$pushed" worktree remove --force "$pushed_wt" >/dev/null 2>&1

echo "worktrees whose commit carries the shims stay clean: an earlier install's write goes back, a person's change stays; one cut before the shims gets them"
printf '#!/usr/bin/env bash\n# an older post-checkout, executable\nai-core init --no-doctor\n' > "$pushed/.githooks/post-checkout"
git -C "$pushed" commit -q -am 'An older post-checkout, as an issue branch cut before a hook commit carries it #10'
older="$(git -C "$pushed" rev-parse HEAD)"; git -C "$pushed" reset -q --hard HEAD~1   # the branch only: master never had it
current_checkout="$(git -C "$pushed" show HEAD:.githooks/post-checkout)"
for w in same rewritten mine; do git -C "$pushed" worktree add -q -b "issue-10-$w" "$fake/wt-$w" "$older" < /dev/null >/dev/null 2>&1; done
git -C "$pushed" worktree add -q -b issue-11-cut-before "$fake/wt-before" "$(git -C "$pushed" rev-list --max-parents=0 HEAD)" < /dev/null >/dev/null 2>&1
printf '%s\n' "$current_checkout" > "$fake/wt-rewritten/.githooks/post-checkout"   # what an earlier install wrote there
printf 'echo mine\n' >> "$fake/wt-mine/.githooks/post-checkout"
out="$( cd "$pushed" && bash "$root/bin/pre-push.sh" --install 2>&1 )"; rc=$?
check 'exit 0'                              0 "$rc"
check 'same: nothing written, clean'        'no|' "$(grep -q '(worktree wt-same)' <<< "$out" && echo yes || echo no)|$(git -C "$fake/wt-same" status --porcelain)"
check 'rewritten: put back, named'          yes "$(grep -q "^pre-push: pushed (worktree wt-rewritten): .githooks/post-checkout was an earlier install's write; put back to that worktree's own commit$" <<< "$out" && echo yes || echo no)"
check 'rewritten: clean, its commit on disk' "|$(git -C "$pushed" show "$older:.githooks/post-checkout")" "$(git -C "$fake/wt-rewritten" status --porcelain)|$(cat "$fake/wt-rewritten/.githooks/post-checkout")"
check 'mine: named and kept'                yes "$(grep -q "^pre-push: pushed (worktree wt-mine): .githooks/post-checkout holds a change that is not ai-core's; it stays$" <<< "$out" && grep -q '^echo mine$' "$fake/wt-mine/.githooks/post-checkout" && echo yes || echo no)"
check 'mine: still changed'                 ' M .githooks/post-checkout' "$(git -C "$fake/wt-mine" status --porcelain)"
check 'cut before the shims: both written'  yes "$(grep -q "^pre-push: pushed (worktree wt-before): .githooks/pre-push created; it goes out with that worktree's own commit$" <<< "$out" && grep -q "^pre-push: pushed (worktree wt-before): .githooks/post-checkout created; it goes out with that worktree's own commit$" <<< "$out" && [ -x "$fake/wt-before/.githooks/pre-push" ] && echo yes || echo no)"
for w in same rewritten mine before; do git -C "$pushed" worktree remove --force "$fake/wt-$w" >/dev/null 2>&1; done

echo 'a worktree that finish-issue removes while --install runs stays gone, and a live one beside it gets its shims'
git -C "$pushed" worktree add -q -b issue-12-gone "$fake/wt-gone" "$(git -C "$pushed" rev-list --max-parents=0 HEAD)" < /dev/null >/dev/null 2>&1
git -C "$pushed" worktree add -q -b issue-12-live "$fake/wt-live" "$(git -C "$pushed" rev-list --max-parents=0 HEAD)" < /dev/null >/dev/null 2>&1
mkdir -p "$fake/remover"
real_git="$(command -v git)"
printf '#!/bin/sh\n"%s" "$@"; rc=$?\ncase "$*" in *"-C %s ls-tree"*) rm -rf "%s" ;; esac\nexit $rc\n' "$real_git" "$fake/wt-gone" "$fake/wt-gone" > "$fake/remover/git"
chmod +x "$fake/remover/git"
out="$( cd "$pushed" && PATH="$fake/remover:$PATH" bash "$root/bin/pre-push.sh" --install 2>&1 )"; rc=$?
check 'planted: the removed worktree stays gone' no "$([ -e "$fake/wt-gone" ] && echo yes || echo no)"
check 'planted: and it is said that nothing was written there' yes "$(grep -q "(worktree wt-gone): .githooks/pre-push not written, $fake/wt-gone is gone$" <<< "$out" && echo yes || echo no)"
check 'innocent: the live worktree got both shims' yes "$([ -x "$fake/wt-live/.githooks/pre-push" ] && [ -f "$fake/wt-live/.githooks/post-checkout" ] && echo yes || echo no)"
git -C "$pushed" worktree remove --force "$fake/wt-live" >/dev/null 2>&1; git -C "$pushed" worktree prune

echo 'the shims of --install reach the default branch through the real gate, which takes no plain push: the install is a path of the harness'
real_origin="$fake/real-gate-origin.git"; git init -q --bare -b master "$real_origin"
real_gate="$fake/real-gate"; git init -q -b master "$real_gate"
git -C "$real_gate" config user.email 'test@example.invalid'; git -C "$real_gate" config user.name 'test'
printf 'a\n' > "$real_gate/a.txt"; git -C "$real_gate" add -A; git -C "$real_gate" commit -q -m 'Start #13'
git -C "$real_gate" remote add origin "$real_origin"; git -C "$real_gate" push -q -u origin master 2>/dev/null
out="$( cd "$real_gate" && PATH="$root/bin:$PATH" bash "$root/bin/pre-push.sh" --install 2>&1 )"; rc=$?
check 'exit 0'                        0 "$rc"
check 'the shims are on origin, pushed through the real gate' "$(git -C "$real_gate" rev-parse HEAD)" "$(git -C "$real_origin" rev-parse master)"
check 'it ran the real gate'          yes "$(grep -q 'no scripts/check.sh in this repository' <<< "$out" && echo yes || echo no)"
git -C "$real_gate" commit -q --allow-empty -m 'A plain push of the default branch #13'
out="$( cd "$real_gate" && PATH="$root/bin:$PATH" git push origin HEAD:master 2>&1 )"; rc=$?
check 'a plain push there: exit 1'    1 "$rc"
check 'it names integrate-issue'      yes "$(grep -q 'master takes no plain push' <<< "$out" && echo yes || echo no)"
echo 'a second --install, its shims unchanged, carries no commit of somebody else under its mark: the gate refuses that push as a plain one'
plain_tip="$(git -C "$real_gate" rev-parse HEAD)"; origin_before="$(git -C "$real_origin" rev-parse master)"
out="$( cd "$real_gate" && PATH="$root/bin:$PATH" bash "$root/bin/pre-push.sh" --install 2>&1 )"; rc=$?
check 'planted: origin did not move'  "$origin_before" "$(git -C "$real_origin" rev-parse master)"
check 'planted: the gate refused it as a plain push' yes "$(grep -q 'master takes no plain push' <<< "$out" && echo yes || echo no)"
check 'planted: the commit of somebody else stays as it was' "$plain_tip" "$(git -C "$real_gate" rev-parse HEAD)"

echo '--install --all: every repository under a folder, a plain folder skipped; a repository whose .gitattributes already makes the shims LF gets no rule'
folder="$fake/folder"; mkdir -p "$folder/not-a-repo"
for r in one two; do git init -q -b master "$folder/$r"; git -C "$folder/$r" config user.email 'test@example.invalid'; git -C "$folder/$r" config user.name 'test'; done
printf '* text=auto eol=lf\n' > "$folder/one/.gitattributes"; git -C "$folder/one" add .gitattributes; git -C "$folder/one" commit -q -m 'LF everywhere #2'
out="$( bash "$root/bin/pre-push.sh" --install --all "$folder" 2>&1 )"; rc=$?
check 'exit 0'                      0 "$rc"
check 'one: no rule added'          no "$(grep -q '^pre-push: one: .gitattributes' <<< "$out" && echo yes || echo no)"
check 'one: its .gitattributes is as it was' '* text=auto eol=lf' "$(cat "$folder/one/.gitattributes" | tr -d '\n')"
check 'one: the shims alone in the commit' '.githooks/post-checkout .githooks/pre-push' "$(git -C "$folder/one" show --pretty=format: --name-only HEAD | grep -v '^$' | tr '\n' ' ' | sed 's/ $//')"
check 'two: the rule added'         yes "$(grep -q '^pre-push: two: .gitattributes: .githooks/\* text eol=lf added' <<< "$out" && echo yes || echo no)"
check 'two repositories'            yes "$(grep -q 'the hooks are in 2 repositories' <<< "$out" && echo yes || echo no)"
check 'both carry the shim, committed' yes "$([ "$(git -C "$folder/one" log -1 --format=%s)" = 'the hooks of ai-core: the push gate, init in a new worktree' ] && [ "$(git -C "$folder/two" log -1 --format=%s)" = 'the hooks of ai-core: the push gate, init in a new worktree' ] && echo yes || echo no)"
check 'the plain folder does not'   no "$([ -e "$folder/not-a-repo/.githooks" ] && echo yes || echo no)"
out="$( cd "$folder/not-a-repo" && bash "$root/bin/pre-push.sh" --install 2>&1 )"; rc=$?
check '--install outside a repository: exit 1' 1 "$rc"

echo '--install where .gitleaks.toml arms the scan and no gitleaks can run it: nothing written, nothing committed, doctor named'
leaky="$fake/leaky"; git init -q -b master "$leaky"
git -C "$leaky" config user.email 'test@example.invalid'; git -C "$leaky" config user.name 'test'
printf '[extend]\nuseDefault = true\n' > "$leaky/.gitleaks.toml"; git -C "$leaky" add .gitleaks.toml; git -C "$leaky" commit -q -m 'Arm the credential scan #15'
head0="$(git -C "$leaky" rev-parse HEAD)"
out="$( cd "$leaky" && PROBE_LEAKS=old bash "$root/bin/pre-push.sh" --install 2>&1 )"; rc=$?
check 'exit 1'                      1 "$rc"
check 'it names doctor'             yes "$(grep -q 'so the push of the shims would be refused; nothing installed. Run ai-core doctor here' <<< "$out" && echo yes || echo no)"
check 'no shims'                    no "$([ -e "$leaky/.githooks" ] && echo yes || echo no)"
check 'core.hooksPath untouched'    '' "$(git -C "$leaky" config --get core.hooksPath)"
check 'no commit'                   "$head0" "$(git -C "$leaky" rev-parse HEAD)"

# What a push checked is printed only in the terminal of whoever pushed; the record keeps it.
echo 'every run of the gate leaves one record, and pre-push --runs lists them newest first'
runs="$AI_CORE_HOME/.ai-core/pre-push-runs.tsv"; rm -f "$runs"
commit 'src/thing.txt' 'Record a green check #7'
out="$(only_new "$repo")"; rc=$?
check 'a green check: exit 0'             0 "$rc"
commit 'src/thing.txt' 'Record a red check #7'
out="$(PROBE_CHECK=red only_new "$repo")"; rc=$?
check 'a red check: exit 1'               1 "$rc"
nocheck="$fake/nocheck"; git -C "$fake" init -q -b master nocheck
git -C "$nocheck" config user.email 'test@example.invalid'; git -C "$nocheck" config user.name 'test'
printf 'one\n' > "$nocheck/README.md"; git -C "$nocheck" add -A; git -C "$nocheck" commit -q -m 'Start the repository #1'
printf 'two\n' >> "$nocheck/README.md"; git -C "$nocheck" commit -q -am 'Push with nothing to check #2'
out="$(only_new "$nocheck")"; rc=$?
check 'no check to run: exit 0'           0 "$rc"
check 'three records under a header'      4 "$(wc -l < "$runs" | tr -d ' ')"
check 'the green one, with the last line of the check' \
  "green	check: OK — every check green" "$(sed -n 2p "$runs" | awk -F'\t' '{print $5 "\t" $7}')"
check 'the red one, with the last line of the check' \
  "red	check: FAIL — the stand-in was told to be red" "$(sed -n 3p "$runs" | awk -F'\t' '{print $5 "\t" $7}')"
check 'the run with no check is never green' 'no check' "$(sed -n 4p "$runs" | cut -f5)"
check 'it names the worktree and the commit' "$nocheck	$(git -C "$nocheck" rev-parse HEAD)" "$(sed -n 4p "$runs" | cut -f3,4)"
check 'the load at check start: the stand-in 0.10 for a check, - for no check' '0.10 - 0.10' "$(sed -n 2p "$runs" | cut -f8) $(sed -n 4p "$runs" | cut -f8) $(sed -n 3p "$runs" | cut -f8)"
check 'the header has the eight fields, the last one named' 'load at check start' "$(head -1 "$runs" | cut -f8)"
check 'the seconds of a check are counted'  yes "$(sed -n 2p "$runs" | cut -f6 | grep -qx '[0-9][0-9]*' && echo yes || echo no)"
printf '[extend]\nuseDefault = true\n' > "$repo/.gitleaks.toml"; git -C "$repo" add .gitleaks.toml
git -C "$repo" commit -q -m 'Arm the scan after a green check #7'
out="$(PROBE_LEAKS=red only_new "$repo")"; rc=$?
check 'a refusal after a green check: exit 1' 1 "$rc"
check 'it is recorded with the refusal, not the green line' \
  "red	a credential stands in a commit" "$(tail -1 "$runs" | awk -F'\t' '{print $5 "\t" substr($7, 1, 31)}')"
git -C "$repo" rm -q .gitleaks.toml; git -C "$repo" commit -q -m 'Disarm the scan again #7'
listed="$(bash "$root/bin/pre-push.sh" --runs)"
check '--runs: the header first, then the newest, in the order they ran' "$(printf 'red\nno check\nred\ngreen')" "$(sed -n '2,5p' <<< "$listed" | cut -f5)"
check '--since in the future lists none'   1 "$(bash "$root/bin/pre-push.sh" --runs --since 2999-01-01 | wc -l | tr -d ' ')"

# --- the wait for a lower load ---------------------------------------------------------------
# A scratch repository of its own: its check writes down when it started (by the injected clock), how
# long it takes, and, while PROBE_BARRIER names a folder, waits for a second gate to be in its check.
lw="$fake/lw"; git init -q -b master "$lw"
git -C "$lw" config user.email 'test@example.invalid'; git -C "$lw" config user.name 'test'
printf '.ai-core/\n' >> "$lw/.git/info/exclude"; mkdir -p "$lw/scripts" "$lw/.ai-core"
cat > "$lw/scripts/check.sh" <<'EOF'
#!/usr/bin/env bash
echo "$(cat "$PROBE_STATE/clock" 2>/dev/null || echo -)" >> "$PROBE_STATE/checks"
if [ -n "${PROBE_BARRIER:-}" ]; then
  : > "$PROBE_BARRIER/in.$$"
  for _ in $(seq 400); do [ "$(ls "$PROBE_BARRIER" | grep -c '^in\.')" -ge 2 ] && break; sleep 0.05; done
fi
[ -z "${PROBE_CHECK_TAKES:-}" ] || echo $(( $(cat "$PROBE_STATE/clock") + PROBE_CHECK_TAKES )) > "$PROBE_STATE/clock"
if [ "${PROBE_CHECK:-green}" = green ]; then echo 'check: OK'; exit 0; fi
echo 'check: FAIL'; exit 1
EOF
chmod +x "$lw/scripts/check.sh"; printf 'one\n' > "$lw/one.txt"
git -C "$lw" add -A; git -C "$lw" commit -q -m 'Set up the load probe #8'
runs="$AI_CORE_HOME/.ai-core/pre-push-runs.tsv"; plans=0
plan() {  # plan <load...> - a state of its own for each case
  plans=$((plans + 1)); export PROBE_STATE="$fake/state-$plans"; plan_load "$PROBE_STATE" "$@"
}
settings() {  # settings <limit> <bound> [file] - the checkout's config.env
  printf 'PRE_PUSH_LOAD_LIMIT="%s"\nPRE_PUSH_LOAD_WAIT_SECONDS="%s"\n' "$1" "$2" > "${3:-$lw/.ai-core/config.env}"
}
on_sleep() {  # on_sleep <n> <limit> <bound> - what the checkout's config.env becomes during the n-th sleep
  settings "$2" "$3" "$fake/next-$1.env"; printf 'cp "%s" "%s"\n' "$fake/next-$1.env" "$lw/.ai-core/config.env" > "$PROBE_STATE/on-sleep-$1"
}
lw_commit() {  # lw_commit <tree> - one more commit to judge
  printf 'more\n' >> "$1/one.txt"; git -C "$1" commit -q -am "Move the load probe on #8"
}
gate_lw() { lw_commit "$lw"; out="$(only_new "$lw")"; rc=$?; }
n_calls() { cat "$PROBE_STATE/uptime-calls" 2>/dev/null || echo 0; }
slept() { [ ! -f "$PROBE_STATE/sleeps" ] || tr '\n' ' ' < "$PROBE_STATE/sleeps"; }
n_checks() { if [ -f "$PROBE_STATE/checks" ]; then wc -l < "$PROBE_STATE/checks" | tr -d ' '; else echo 0; fi; }
says() { grep -c -- "$1" <<< "$out" || true; }
last_run() { tail -1 "$runs" | awk -F'\t' -v f="$1" '{ print $f }'; }
waiting='waiting for the 1-minute load to fall below'

echo 'a load at or above the limit is waited for, announced once, and the check starts below it with that load on record'
plan 25 24 23.5; settings 24 300; PROBE_CHECK_TAKES=3 gate_lw
check 'exit 0'                                   0 "$rc"
check 'it slept twice, five seconds each'        '5 5 ' "$(slept)"
check 'one announcement, naming the load and the limit' 1 "$(says "$waiting 24; it is 25")"
check 'a line says the load fell'                1 "$(says 'fell to 23.5, below 24')"
check 'one check, started after the wait'        '1010' "$(cat "$PROBE_STATE/checks")"
check 'three readings'                           3 "$(n_calls)"
check 'the record holds the sample the check started with' 23.5 "$(last_run 8)"
check 'the first seven fields keep their meaning: green, and the last line of the check' 'green	check: OK' "$(last_run 5)	$(last_run 7)"

echo 'a low load starts at once: no wait, no announcement, one reading'
plan 0.5; settings 24 300; gate_lw
check 'exit 0'                                   0 "$rc"
check 'no sleep'                                 '' "$(slept)"
check 'no announcement'                          0 "$(says "$waiting")"
check 'one reading, one check'                   '1 1' "$(n_calls) $(n_checks)"
check 'the record holds 0.5'                     0.5 "$(last_run 8)"

echo 'a load that stays above the limit is waited for up to the bound, then the check starts and the push says so; the seconds of the check leave the wait out'
plan 30; settings 24 12; PROBE_CHECK_TAKES=3 gate_lw
check 'exit 0'                                   0 "$rc"
check 'polls of five seconds, the last one shortened to the bound' '5 5 2 ' "$(slept)"
check 'one announcement'                         1 "$(says "$waiting")"
check 'one line says it starts at or above the limit' 1 "$(says 'the wait is over; the check starts at a 1-minute load of 30, at or above the limit of 24')"
check 'one check'                                1 "$(n_checks)"
check 'the record holds the high sample'         30 "$(last_run 8)"
check 'the seconds are the check, three, not the wait' 3 "$(last_run 6)"
plan 30; settings 24 5; PROBE_CHECK=red gate_lw
check 'a red check after the bound still refuses' 1 "$rc"
check 'and is recorded red with the high sample' 'red	30' "$(last_run 5)	$(last_run 8)"

echo 'with both settings above zero, a load that cannot be read refuses before the check, also at the bound'
for bad in FAIL EMPTY JUNK; do
  plan "$bad"; settings 24 300; gate_lw
  check "$bad: exit 1"                           1 "$rc"
  check "$bad: it says the load could not be read" 1 "$(says 'the 1-minute load could not be read from uptime')"
  check "$bad: no check, no sleep"               '0' "$(n_checks)$(slept)"
  check "$bad: the record holds -"               '-' "$(last_run 8)"
done
plan 30 FAIL; settings 24 5; gate_lw
check 'a reading that fails at the bound refuses and does not reuse the sample before it' '1 0' "$rc $(n_checks)"

echo 'PRE_PUSH_LOAD_LIMIT=0 turns the wait off: one reading for the record, one check at once'
plan 99; settings 0 300; gate_lw
check 'exit 0'                                   0 "$rc"
check 'no sleep, no announcement, no threshold message' '0 0 0' "$(slept | wc -w | tr -d ' ') $(says "$waiting") $(says 'at or above')"
check 'one reading, one check'                   '1 1' "$(n_calls) $(n_checks)"
check 'the record holds 99'                      99 "$(last_run 8)"
for bad in FAIL EMPTY JUNK; do
  plan "$bad"; settings 0 300; gate_lw
  check "$bad: the check runs, exit 0"           '0 1' "$rc $(n_checks)"
  check "$bad: it says the load could not be measured" 1 "$(says 'the 1-minute load could not be measured')"
  check "$bad: the record holds -"               '-' "$(last_run 8)"
done
plan FAIL; settings 0 300; PROBE_CHECK=red gate_lw
check 'a red check is still refused with the reader failing' '1 red' "$rc $(last_run 5)"
plan 99; settings 0 0; gate_lw
check 'both settings zero: the limit-zero rules, no threshold message' '0 99 0' "$rc $(last_run 8) $(says 'at or above')"

echo 'PRE_PUSH_LOAD_WAIT_SECONDS=0 starts at once, and says so when the load is at or above the limit'
plan 25; settings 24 0; gate_lw
check 'exit 0, no sleep, one reading, one check' '0 0 1 1' "$rc $(slept | wc -w | tr -d ' ') $(n_calls) $(n_checks)"
check 'it says it starts at or above the limit without waiting' 1 "$(says 'at or above the limit of 24: PRE_PUSH_LOAD_WAIT_SECONDS is 0')"
check 'the record holds 25'                      25 "$(last_run 8)"
plan 23.5; settings 24 0; gate_lw
check 'below the limit: no such message, the sample on record' '0 23.5' "$(says 'at or above') $(last_run 8)"
for bad in FAIL EMPTY JUNK; do
  plan "$bad"; settings 24 0; gate_lw
  check "$bad: the check runs, said and recorded as -" '0 1 - 1' "$rc $(n_checks) $(last_run 8) $(says 'could not be measured')"
done

echo 'the settings come from the checkout: defaults when missing, never from the environment, and an invalid value names its key'
plan 30; rm -f "$lw/.ai-core/config.env"; gate_lw
check 'no settings: the defaults wait 300 seconds in all' '300' "$(awk '{ s += $1 } END { print s }' "$PROBE_STATE/sleeps")"
check 'and start at the bound'                   '0 1' "$rc $(n_checks)"
plan 25 10; settings 24 300; PRE_PUSH_LOAD_LIMIT=0 PRE_PUSH_LOAD_WAIT_SECONDS=0 gate_lw
check 'exported names do not override the checkout' '5 ' "$(slept)"
plan 1; settings abc 0; gate_lw
check 'an invalid limit refuses and names the key, even with the bound at 0' '1 1' "$rc $(says 'PRE_PUSH_LOAD_LIMIT is .abc.')"
plan 1; settings 0 5x; gate_lw
check 'an invalid bound refuses and names the key, even with the limit at 0' '1 1' "$rc $(says 'PRE_PUSH_LOAD_WAIT_SECONDS is .5x.')"
check 'no check ran for either'                  0 "$(n_checks)"
check 'the template carries the documented defaults' '24 300' "$(sed -n 's/^PRE_PUSH_LOAD_LIMIT="\(.*\)"$/\1/p' "$root/templates/.ai-core/config.env") $(sed -n 's/^PRE_PUSH_LOAD_WAIT_SECONDS="\(.*\)"$/\1/p' "$root/templates/.ai-core/config.env")"
check 'the help and the README name both settings' '2 2' "$(bash "$root/bin/pre-push.sh" --help | grep -c 'PRE_PUSH_LOAD_\(LIMIT\|WAIT_SECONDS\) (') $(grep -c '^| `PRE_PUSH_LOAD_\(LIMIT\|WAIT_SECONDS\)` | .*`\(24\|300\)` when unset' "$root/README.md")"

echo 'a setting edited during the wait takes effect at the next poll and does not restart the wait'
plan 30; settings 24 300; on_sleep 1 24 8; gate_lw
check 'five seconds were slept, then the three that remain of the new bound' '0 5 3 ' "$rc $(slept)"
plan 30; settings 24 300; on_sleep 1 0 300; gate_lw
check 'the limit set to 0 ends the wait with one more reading and no threshold message' '0 5  2 0' "$rc $(slept) $(n_calls) $(says 'at or above')"
plan 30; settings 24 300; on_sleep 1 24 0; gate_lw
check 'the bound set to 0 starts the check, above the limit, and says so' '0 1' "$rc $(says 'PRE_PUSH_LOAD_WAIT_SECONDS is 0')"

echo 'a commit or a change of the tree during the wait is refused against the commit judged, and no check starts'
plan 30; settings 24 300; printf 'git -C "%s" commit -q --allow-empty -m "Moved while waiting #8"\n' "$lw" > "$PROBE_STATE/on-sleep-1"; gate_lw
check 'HEAD moved: exit 1'                       1 "$rc"
check 'it names the move'                        1 "$(says 'HEAD moved from')"
check 'no check'                                 0 "$(n_checks)"
check 'the record names the commit that was judged' "$(git -C "$lw" rev-parse HEAD~1)" "$(last_run 4)"
check 'and holds - for the load'                 '-' "$(last_run 8)"
plan 30; settings 24 300; printf 'echo late > "%s"\n' "$lw/late.txt" > "$PROBE_STATE/on-sleep-1"; gate_lw
check 'a file that appears: exit 1, the tree named' '1 1' "$rc $(says 'the working tree differs from the commit being pushed')"
check 'no check'                                 0 "$(n_checks)"
rm -f "$lw/late.txt"

echo 'a gate stopped during the wait starts no check and records no green run'
plan 30; settings 24 300; : > "$PROBE_STATE/block"; lw_commit "$lw"
printf 'refs/heads/master %s refs/heads/master %s\n' "$(git -C "$lw" rev-parse HEAD)" "$(git -C "$lw" rev-parse HEAD~1)" > "$fake/stop-input"
stop_mark="$(bash "$root/lib/landing-check.sh" mark "$lw" "$(git -C "$lw" rev-parse HEAD)" refs/heads/master)"
( cd "$lw" && AI_CORE_LANDING_MARK="$stop_mark" exec bash "$root/bin/pre-push.sh" < "$fake/stop-input" > "$fake/stop-out" 2>&1 ) & stopped=$!
for _ in $(seq 200); do [ -e "$PROBE_STATE/sleeping" ] && break; "$real_sleep" 0.05; done
kill -TERM "$stopped"; : > "$PROBE_STATE/wake"; wait "$stopped" 2>/dev/null; rc=$?
check 'the gate ended on the signal'             143 "$rc"
check 'no check ran'                             0 "$(n_checks)"
check 'the run is recorded as one with no check, not green, without a load' 'no check -' "$(last_run 5) $(last_run 8)"

echo 'a repository without scripts/check.sh reads no load and never waits'
plan 99; settings 24 300
printf 'three\n' >> "$nocheck/README.md"; git -C "$nocheck" commit -q -am 'Push with nothing to wait for #2'
out="$(only_new "$nocheck")"; rc=$?
check 'exit 0, no reading, no sleep'             '0 0 0' "$rc $(n_calls) $(slept | wc -w | tr -d ' ')"
check 'the record of a run with no check holds -' '-' "$(last_run 8)"

echo 'the listing reads rows of seven and of eight fields under the header of the log, shows the current header, and keeps its filters'
legacy_header=$'time\trepository\tworktree\tcommit\tverdict\tseconds\tlast line'
printf '%s\n2026-10-01T10:00:00Z\texample/old\t/old\t%s\tgreen\t4\told line\n2026-10-02T10:00:00Z\texample/other\t/other\t%s\tred\t5\tother line\n' "$legacy_header" aaaa bbbb > "$runs"
plan 0.7; settings 24 300; gate_lw
check 'the legacy header and rows of the log are unchanged' "$(printf '%s\n2026-10-01T10:00:00Z\texample/old\t/old\taaaa\tgreen\t4\told line\n2026-10-02T10:00:00Z\texample/other\t/other\tbbbb\tred\t5\tother line' "$legacy_header")" "$(head -3 "$runs")"
listed="$(bash "$root/bin/pre-push.sh" --runs)"
check 'the listing shows the current header'     'load at check start' "$(head -1 <<< "$listed" | cut -f8)"
check 'the newest first, every row of eight fields' '8 8 8' "$(awk -F'\t' 'NR > 1 { printf "%s ", NF }' <<< "$listed" | sed 's/ $//')"
check 'a row of seven fields is shown with - as its load' '-' "$(grep -F "aaaa" <<< "$listed" | cut -f8)"
check 'the order is newest first'                "$(git -C "$lw" rev-parse HEAD) bbbb aaaa" "$(cut -f4 <<< "$listed" | sed -n '2,4p' | tr '\n' ' ' | sed 's/ $//')"
check '--repo filters the old rows'              'aaaa' "$(bash "$root/bin/pre-push.sh" --runs --repo example/old | sed -n 2p | cut -f4)"
check '--since filters the old rows'             '0 1' "$(bash "$root/bin/pre-push.sh" --runs --since 2026-10-02 | grep -c aaaa) $(bash "$root/bin/pre-push.sh" --runs --since 2026-10-02 | grep -c bbbb)"
rm -f "$runs"

echo 'two gates at the same time share one run log: one header, one whole row each, the sample and the verdict of its own run'
lw2="$fake/lw2"; git clone -q "$lw" "$lw2"; git -C "$lw2" config user.email 'test@example.invalid'; git -C "$lw2" config user.name 'test'
printf '.ai-core/\n' >> "$lw2/.git/info/exclude"; mkdir -p "$lw2/.ai-core"
both() {  # both - two gates at once, each with a clock, loads and settings of its own, meeting in their checks and, for a new log, at its creation
  local state_a state_b barrier="$fake/barrier-$((plans + 1))"; mkdir -p "$barrier"
  plan 25 10; state_a="$PROBE_STATE"; plan 0.5; state_b="$PROBE_STATE"
  settings 24 300; mkdir -p "$lw2/.ai-core"; cp "$lw/.ai-core/config.env" "$lw2/.ai-core/config.env"
  lw_commit "$lw"; lw_commit "$lw2"
  local marks=() mark
  for each in "$lw:$state_a:green" "$lw2:$state_b:red"; do
    IFS=: read -r tree state verdict <<< "$each"
    printf 'refs/heads/master %s refs/heads/master %s\n' "$(git -C "$tree" rev-parse HEAD)" "$(git -C "$tree" rev-parse HEAD~1)" > "$state/input"
    mark="$(bash "$root/lib/landing-check.sh" mark "$tree" "$(git -C "$tree" rev-parse HEAD)" refs/heads/master)"; marks+=("$mark")
    ( cd "$tree" && AI_CORE_LANDING_MARK="$mark" PROBE_STATE="$state" PROBE_BARRIER="$barrier" PROBE_MKTEMP_BARRIER="$barrier" PROBE_CHECK="$verdict" \
        exec timeout 60 bash "${GATE_SCRIPT:-$root/bin/pre-push.sh}" < "$state/input" > "$state/out" 2>&1 ) &
  done
  wait
  for mark in "${marks[@]}"; do bash "$root/lib/landing-check.sh" unmark "$mark"; done
}
rm -f "$runs"; both
check 'a log made by two gates at once has one header' 1 "$(grep -c $'^time\trepository' "$runs")"
check 'and one row of eight fields for each run' '2 0' "$(grep -vc $'^time\trepository' "$runs") $(awk -F'\t' 'NR > 1 && NF != 8 { n++ } END { print n + 0 }' "$runs")"
check 'each row holds the verdict and the sample of its own run' "green 10 red 0.5" "$(awk -F'\t' -v a="$lw" -v b="$lw2" 'NR > 1 && ($3 == a || $3 == b) { print $5, $8 }' "$runs" | sort | tr '\n' ' ' | sed 's/ $//')"
check 'no stray temporary file is left beside the log' 1 "$(find "$(dirname "$runs")" -maxdepth 1 -name 'pre-push-runs*' | wc -l | tr -d ' ')"
printf '%s\n2026-10-01T10:00:00Z\texample/old\t/old\taaaa\tgreen\t4\told line\n' "$legacy_header" > "$runs"
both
check 'two gates appending to a log of seven fields leave its header and row as they were' "$(printf '%s\n2026-10-01T10:00:00Z\texample/old\t/old\taaaa\tgreen\t4\told line' "$legacy_header")" "$(head -2 "$runs")"
check 'and add one whole row each'                 '4 2' "$(wc -l < "$runs" | tr -d ' ') $(awk -F'\t' 'NR > 2 && NF == 8 { n++ } END { print n }' "$runs")"
check 'with the sample of its own run'             "green 10 red 0.5" "$(awk -F'\t' -v a="$lw" -v b="$lw2" 'NR > 2 && ($3 == a || $3 == b) { print $5, $8 }' "$runs" | sort | tr '\n' ' ' | sed 's/ $//')"

echo 'a new log that cannot be linked into place is not written another way: the run is said not to be recorded, and no log, header or temporary file stands'
rm -f "$runs"; plan 0.5; settings 24 300; PROBE_LN=fail gate_lw
check 'the push is judged as ever: exit 0, one check' '0 1' "$rc $(n_checks)"
check 'the gate says the run could not be recorded, once' 1 "$(says "this run could not be recorded in $runs")"
check 'no log and no temporary file stand beside where it was to be' 0 "$(find "$(dirname "$runs")" -maxdepth 1 -name 'pre-push-runs*' | wc -l | tr -d ' ')"
echo 'a log that exists needs no link: with the link failing, a run still adds its row and says nothing of it'
printf '%s\n2026-10-01T10:00:00Z\texample/old\t/old\taaaa\tgreen\t4\told line\n' "$legacy_header" > "$runs"
plan 0.5; settings 24 300; PROBE_LN=fail gate_lw
check 'one row was added under the header, and nothing was said of the record' '3 0' "$(wc -l < "$runs" | tr -d ' ') $(says 'could not be recorded')"
rm -f "$runs"

echo 'the run log has one reader, for the listing and for the longest check: rows of seven and eight fields, rows that ran no check, an unfinished row, rows that are none of these'
timing_log="$AI_CORE_HOME/.ai-core/pre-push-runs.tsv"; mkdir -p "$fake/mutant-runs"
timing() {  # timing <library> - what that reader makes of the log: its state, the rows it counts, the longest, the rows with no seconds, the rows it cannot read, all rows, its status
  ( . "$1"; status=0; gate_runs_timing "$timing_log" || status=$?; echo "$GATE_RUNS_STATE $GATE_RUNS_TIMED $GATE_RUNS_LONGEST $GATE_RUNS_UNTIMED $GATE_RUNS_UNREADABLE $GATE_RUNS_ROWS $status" )
}
timing_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }   # a row of the last 14 days, which is all the reader counts
timing_row() {  # timing_row <verdict> <seconds> [seven]
  printf '%s\texample/old\t/old\taaaa\t%s\t%s\tlast line' "$(timing_now)" "$1" "$2"; [ -n "${3:-}" ] || printf '\t0.5'; printf '\n'
}
timing_log_of() { { printf '%s\n' "$legacy_header"; cat; } > "$timing_log"; }
rm -rf "$timing_log"
check 'no log yet: nothing is on record, and that is no failure' 'missing 0 0 0 0 0 0' "$(timing "$root/lib/pre-push-runs.sh")"
timing_log_of < /dev/null
check 'a log with its header only holds no run' 'read 0 0 0 0 0 0' "$(timing "$root/lib/pre-push-runs.sh")"
{ timing_row green 100; timing_row red 40 seven; timing_row green 7 seven; } | timing_log_of
check 'rows of eight and seven fields count, and the longest is named' 'read 3 100 0 0 3 0' "$(timing "$root/lib/pre-push-runs.sh")"
{ timing_row 'no check' -; timing_row red -; timing_row green - seven; } | timing_log_of
check 'rows that ran no check name no seconds and measure nothing' 'read 0 0 3 0 3 0' "$(timing "$root/lib/pre-push-runs.sh")"
{ timing_row green 200; printf '%s\texample/old\t/old\taaaa\tgreen\t99999' "$(timing_now)"; } | timing_log_of
check 'the row an append has not ended is no run yet' 'read 1 200 0 0 1 0' "$(timing "$root/lib/pre-push-runs.sh")"
{ timing_row green 300; printf 'not a row\n'; timing_row weird 5000; timing_row green many; timing_row green 1234567890; timing_row 'no check' 12; } | timing_log_of
check 'rows that are none of these are counted as unreadable, never as a measured zero' 'read 1 300 0 5 6 0' "$(timing "$root/lib/pre-push-runs.sh")"
rm -f "$timing_log"; mkdir "$timing_log"
check 'a log that is a folder cannot be read, and the reader fails' 'unreadable 0 0 0 0 0 1' "$(timing "$root/lib/pre-push-runs.sh")"
check '--runs fails on it and says so'   '1 error: the runs in '"$timing_log"' cannot be read' "$(bash "$root/bin/pre-push.sh" --runs > /dev/null 2> "$fake/runs-err"; echo "$?" "$(cat "$fake/runs-err")")"
rmdir "$timing_log"
{ timing_row green 5; printf '%s\texample/old\t/old\tbbbb\tred\t6\tunfinished' "$(timing_now)"; } | timing_log_of
check '--runs does not list the row an append has not ended' '1 0' "$(bash "$root/bin/pre-push.sh" --runs | grep -c aaaa) $(bash "$root/bin/pre-push.sh" --runs | grep -c bbbb)"
# planted: each copy of the reader has one defect, and the case of that defect must turn red; the same log read by the reader itself is the innocent case
planted_reader() {  # planted_reader <name> <sed expression>: the copy with that defect reads the log as it stands otherwise than the real reader
  sed "$2" "$root/lib/pre-push-runs.sh" > "$fake/mutant-runs/$1.sh"
  cmp -s "$root/lib/pre-push-runs.sh" "$fake/mutant-runs/$1.sh" && { echo "  FAIL the planted defect changed nothing: $2"; failed=$((failed + 1)); return; }
  check "planted: $1 changes what is read" yes "$([ "$(timing "$fake/mutant-runs/$1.sh")" != "$(timing "$root/lib/pre-push-runs.sh")" ] && echo yes || echo no)"
}
{ timing_row red -; timing_row green 300; } | timing_log_of
planted_reader untimed-as-timed 's/else if (\$6 == "-") untimed++/else if ($6 == "-") timed++/'
{ timing_row 'no check' -; timing_row green 300; } | timing_log_of
planted_reader untimed-no-check 's/\$5 == "no check" \&\& \$6 == "-" { untimed++; next }/$5 == "no check" { timed++; next }/'
{ timing_row green 200; printf '%s\texample/old\t/old\taaaa\tgreen\t99999' "$(timing_now)"; } | timing_log_of
planted_reader unfinished-row-kept "s/sed '\\\$d' \"\\\$1\"/cat \"\\\$1\"/"
{ timing_row green 1234567890; } | timing_log_of
planted_reader no-digit-bound 's/ \&\& length(\$6) <= 9//'
{ timing_row green 300; printf 'not a row\n'; } | timing_log_of
planted_reader unreadable-rows-forgotten 's/{ unreadable++; next }/{ next }/'
check 'the innocent log is read as before' 'read 1 300 0 1 2 0' "$(timing "$root/lib/pre-push-runs.sh")"
rm -f "$timing_log"

# --- planted defects: each of these copies of the gate must turn the named case red ------------
mkdir -p "$fake/mutant/bin"; ln -s "$root/lib" "$fake/mutant/lib"
mutate() {  # mutate <sed expression> - a copy of the gate with one defect, in GATE_SCRIPT
  sed "$1" "$root/bin/pre-push.sh" > "$fake/mutant/bin/pre-push.sh"
  cmp -s "$root/bin/pre-push.sh" "$fake/mutant/bin/pre-push.sh" && { echo "  FAIL the planted defect changed nothing: $1"; failed=$((failed + 1)); }
  export GATE_SCRIPT="$fake/mutant/bin/pre-push.sh"
}
echo 'planted: no wait at all'
mutate 's/exit !(sample + 0 >= limit + 0)/exit 1/'
plan 25 24 23.5; settings 24 300; gate_lw
check 'the slept seconds are not what the wait sleeps' no "$([ "$(slept)" = '5 5 ' ] && echo yes || echo no)"
echo 'planted: a load exactly at the limit is below it'
mutate 's/sample + 0 >= limit + 0/sample + 0 > limit + 0/'
plan 25 24 23.5; settings 24 300; gate_lw
check 'the wait ends one sample early and records 24' no "$([ "$(slept)" = '5 5 ' ] && [ "$(last_run 8)" = 23.5 ] && echo yes || echo no)"
echo 'planted: no bound'
mutate 's/\[ "\$remaining" -le 0 \]/false/'
plan 30; settings 24 12; GATE_TIMEOUT=10 gate_lw
check 'a load that never falls is waited for without end: the run is cut off, no check started' no "$([ "$rc" = 0 ] && [ "$(n_checks)" = 1 ] && echo yes || echo no)"
echo 'planted: the first sample is the one recorded'
mutate 's/^    if ! at_or_above "\$sample" "\$LOAD_LIMIT"; then$/    first="${first:-$sample}"; &/; s/^  LOAD_AT_START="\$sample"$/  LOAD_AT_START="${first:-$sample}"/'
plan 25 24 23.5; settings 24 300; gate_lw
check 'the record holds 25, not the start sample' no "$([ "$(last_run 8)" = 23.5 ] && echo yes || echo no)"
echo 'planted: an unreadable load refuses in a zero mode'
mutate 's/^        sample=-$/        refuse "unreadable"/'
plan FAIL; settings 0 300; gate_lw
check 'the limit-zero case with a failing reader no longer starts the check' no "$([ "$rc" = 0 ] && [ "$(n_checks)" = 1 ] && echo yes || echo no)"
plan FAIL; settings 24 0; gate_lw
check 'nor the bound-zero case'                  no "$([ "$rc" = 0 ] && [ "$(n_checks)" = 1 ] && echo yes || echo no)"
echo 'planted: a header written by whoever finds no log, as the gate wrote it before'
mutate "s|^  if \[ ! -e \"\$GATE_RUNS_FILE\" \]; then\$|  [ -s \"\$GATE_RUNS_FILE\" ] \|\| missing=1\n  mktemp -u \"\$GATE_RUNS_FILE.XXXXXX\" >/dev/null\n  [ -z \"\${missing:-}\" ] \|\| printf '%s\\\\n' \"\$GATE_RUNS_HEADER\" >> \"\$GATE_RUNS_FILE\"\n  if false; then|"
rm -f "$runs"; both
check 'two gates at once write two headers'      2 "$(grep -c $'^time\trepository' "$runs")"
echo 'planted: a link that failed is followed by the append that writes the log, as the gate wrote it before'
mutate 's/^    \[ -e "\$GATE_RUNS_FILE" \] || return 1$/    [ -s "$GATE_RUNS_FILE" ] || echo "$GATE_RUNS_HEADER" >> "$GATE_RUNS_FILE"/'
rm -f "$runs"; plan 0.5; settings 24 300; PROBE_LN=fail gate_lw
check 'a log stands though no link could be made, with no word that the run was not recorded' 'yes 0' "$([ -s "$runs" ] && echo yes || echo no) $(says 'could not be recorded')"
unset GATE_SCRIPT GATE_TIMEOUT

# --- the default branch takes only a harness landing -------------------------------------------
echo 'a push to the default branch needs the mark of a harness landing for exactly the commit it lands, this clone and this ref'
commit 'src/landing.txt' 'Land by a plain push #16'
land_sha="$(git -C "$repo" rev-parse HEAD)"; land_parent="$(git -C "$repo" rev-parse HEAD~1)"
mark_gate() {  # mark_gate <mark, or nothing>: the push of the new commit to master, with that mark
  printf 'refs/heads/master %s refs/heads/master %s\n' "$land_sha" "$land_parent" \
    | ( cd "$repo" && AI_CORE_LANDING_MARK="${1:-}" bash "$root/bin/pre-push.sh" origin 'https://example.invalid/x.git' 2>&1 )
}
out="$(mark_gate)"; rc=$?
check 'planted: no mark: exit 1'                      1 "$rc"
check 'planted: it refuses a plain push and names integrate-issue' yes "$(grep -q 'pre-push: REFUSED — master takes no plain push (no landing path of the harness made this push)' <<< "$out" && grep -q 'ai-core integrate-issue <number> --reviewed-by' <<< "$out" && echo yes || echo no)"
mark_other_commit="$(bash "$root/lib/landing-check.sh" mark "$repo" "$land_parent" refs/heads/master)"
out="$(mark_gate "$mark_other_commit")"; rc=$?
check 'planted: the mark of another commit: exit 1'   1 "$rc"
check 'planted: it says the mark names another commit' yes "$(grep -q 'the mark names another commit than the one this push lands' <<< "$out" && echo yes || echo no)"
foreign="$fake/foreign-clone"; git init -q -b master "$foreign"
mark_other_clone="$(bash "$root/lib/landing-check.sh" mark "$foreign" "$land_sha" refs/heads/master)"
out="$(mark_gate "$mark_other_clone")"; rc=$?
check 'planted: the mark of another clone: exit 1'    1 "$rc"
check 'planted: it says the mark belongs to another clone' yes "$(grep -q 'the mark belongs to another clone' <<< "$out" && echo yes || echo no)"
mark_other_ref="$(bash "$root/lib/landing-check.sh" mark "$repo" "$land_sha" refs/heads/elsewhere)"
out="$(mark_gate "$mark_other_ref")"; rc=$?
check 'planted: the mark of another ref: exit 1'      1 "$rc"
check 'planted: it says the mark does not cover master' yes "$(grep -q 'the mark does not cover refs/heads/master' <<< "$out" && echo yes || echo no)"
mark_right="$(bash "$root/lib/landing-check.sh" mark "$repo" "$land_sha" refs/heads/master)"
out="$(mark_gate "$mark_right")"; rc=$?
check 'innocent: the mark of this very landing: exit 0' 0 "$rc"
printf 'refs/heads/topic %s refs/heads/topic %s\n' "$land_sha" "$land_parent" > "$fake/topic-input"
out="$( cd "$repo" && bash "$root/bin/pre-push.sh" origin 'https://example.invalid/x.git' < "$fake/topic-input" 2>&1 )"; rc=$?
check 'innocent: a push of another branch needs no mark: exit 0' 0 "$rc"
bash "$root/lib/landing-check.sh" unmark "$mark_other_commit"; bash "$root/lib/landing-check.sh" unmark "$mark_other_clone"
bash "$root/lib/landing-check.sh" unmark "$mark_other_ref"; bash "$root/lib/landing-check.sh" unmark "$mark_right"
rm -rf "$foreign"

echo 'a harness landing holds only what it adds to origin to the address of the person pushing: the commit of another person that a ref of origin carries lands, and the other checks still judge it'
base_sha="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" update-ref refs/remotes/origin/master "$base_sha"   # where origin's default branch stands when the landing starts
land_branch_of_another() {  # land_branch_of_another <branch> <subject>: a commit of Ada on <branch>, which origin carries, merged into master by the pusher
  git -C "$repo" checkout -q -b "$1" "$base_sha"
  printf 'by ada\n' > "$repo/src/$1.txt"; git -C "$repo" add "src/$1.txt"
  GIT_AUTHOR_NAME='Ada Lovelace' GIT_AUTHOR_EMAIL=ada@example.invalid GIT_COMMITTER_NAME='Ada Lovelace' GIT_COMMITTER_EMAIL=ada@example.invalid \
    git -C "$repo" commit -q -m "$2"
  git -C "$repo" update-ref "refs/remotes/origin/$1" HEAD
  git -C "$repo" checkout -q master; git -C "$repo" reset -q --hard "$base_sha"
  git -C "$repo" merge -q --no-ff "$1" -m "Land the work of Ada (#17)"
  landed_sha="$(git -C "$repo" rev-parse HEAD)"
  landed_mark="$(bash "$root/lib/landing-check.sh" mark "$repo" "$landed_sha" refs/heads/master)"
  out="$(printf 'refs/heads/master %s refs/heads/master %s\n' "$landed_sha" "$base_sha" \
    | ( cd "$repo" && AI_CORE_LANDING_MARK="$landed_mark" bash "$root/bin/pre-push.sh" origin 'https://example.invalid/x.git' 2>&1 ))"; rc=$?
  bash "$root/lib/landing-check.sh" unmark "$landed_mark"
}
land_branch_of_another issue-17-ada 'Work of another person, pushed through their own gate (#17)'
check 'planted: the landing of a branch of another person: exit 0' 0 "$rc$([ "$rc" -eq 0 ] || echo " $out")"
check 'planted: their address refuses nothing' no "$(grep -q 'carry another address than yours' <<< "$out" && echo yes || echo no)"
land_branch_of_another issue-18-ada 'Work of another person whose subject no gate judged, as it is far beyond the limit (#18)'
check 'and: the same landing with a subject over 72: exit 1' 1 "$rc"
check 'and: the subject check judges that commit of origin' yes "$(grep -q 'subjects are longer than 72 characters' <<< "$out" && echo yes || echo no)"
git -C "$repo" reset -q --hard "$base_sha"
git -C "$repo" branch -q -D issue-17-ada issue-18-ada
for ref in master issue-17-ada issue-18-ada; do git -C "$repo" update-ref -d "refs/remotes/origin/$ref"; done

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
