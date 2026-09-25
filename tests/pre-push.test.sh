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
# carry, a sha of sixty-four zeros, an annotated tag, and a Windows entry point that decides.

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fake="$(mktemp -d)"
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
printf 'claude\tmode\ton\talways\t-\t-\n' > "$green"
printf 'claude\tcaveman\tlite\tfile:%s/never-there\tnpx skills add example/caveman -g\t-\n' "$fake" > "$red"
export TEAM_MODES_FILE="$green"
stub="$fake/stub"; mkdir -p "$stub"
printf '#!/usr/bin/env bash\nexit 0\n' > "$stub/claude"
# The gitleaks stub writes down every argument it was given
leaks_args="$fake/leaks-args.txt"
cat > "$stub/gitleaks" <<EOF
#!/usr/bin/env bash
printf '[%s]\n' "\$*" >> "$leaks_args"
[ "\${PROBE_LEAKS:-green}" = green ] || { echo 'gitleaks: a credential stands in this range'; exit 1; }
exit 0
EOF
# The ai-core stub writes down what the shim hands it: its arguments and git's input
shim_args="$fake/shim-args.txt"
cat > "$stub/ai-core" <<EOF
#!/usr/bin/env bash
printf '[%s] ' "\$*" >> "$shim_args"; cat >> "$shim_args"
exit 0
EOF
chmod +x "$stub/claude" "$stub/gitleaks" "$stub/ai-core"
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
# was started in; both Windows entry points are the one text, and one .ps1 is neither.
mkdir -p "$repo/scripts" "$repo/bin"
cat > "$repo/scripts/check.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$0" >> "$check_runs"
if [ "\${PROBE_CHECK:-green}" = green ]; then echo 'check: OK — every check green'; exit 0; fi
echo 'check: FAIL — the stand-in was told to be red'
exit 1
EOF
chmod +x "$repo/scripts/check.sh"
cp "$root/lib/entry-point.ps1" "$repo/scripts/check.ps1"
cp "$root/lib/entry-point.ps1" "$repo/build.ps1"
printf '#!/usr/bin/env pwsh\nWrite-Host "not a shim, and never was"\n' > "$repo/bin/case-check.ps1"
git -C "$repo" init -q -b master
git -C "$repo" config user.email 'test@example.invalid'
git -C "$repo" config user.name 'test'
git -C "$repo" config core.autocrlf false
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
judge() {  # judge <working tree> <local sha> <remote sha>
  printf 'refs/heads/master %s refs/heads/master %s\n' "$2" "$3" \
    | ( cd "$1" && bash "$root/bin/pre-push.sh" origin 'https://example.invalid/x.git' 2>&1 )
}
only_new() {  # only_new <working tree> - judge the newest commit alone
  judge "$1" "$(git -C "$1" rev-parse HEAD)" "$(git -C "$1" rev-parse HEAD~1)"
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
check 'every check passed'         yes "$(grep -q 'pre-push: every check passed' <<< "$out" && echo yes || echo no)"
check 'and the check that ran is the WORKTREE one' \
  "$(git -C "$wt" rev-parse --show-toplevel)/scripts/check.sh" "$(tail -1 "$check_runs")"

# --- the team modes ---------------------------------------------------------------------------
echo 'a red modes check refuses, and the lines the refusal points at are in the output'
out="$(TEAM_MODES_FILE="$red" only_new "$wt")"; rc=$?
check 'exit 1'                    1 "$rc"
check 'the MISSING line is there' yes "$(grep -q '^MISSING .*claude caveman' <<< "$out" && echo yes || echo no)"
check 'and the refusal names the modes' yes "$(grep -q 'the team modes are missing' <<< "$out" && echo yes || echo no)"

echo 'a red scripts/check.sh refuses'
out="$(PROBE_CHECK=red only_new "$wt")"; rc=$?
check 'exit 1'          1 "$rc"
check 'and says which'  yes "$(grep -q 'check: FAIL' <<< "$out" && echo yes || echo no)"

# --- what excuses a commit from naming an issue ----------------------------------------------
echo 'a commit naming its issue anywhere in the message passes'
commit 'src/thing.txt' 'Read the install order from one file

It closes #163.'
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
# Only the range is compared: the tree is named the way the operating system writes a path,
# which on Windows is not the form this shell writes.
check 'gitleaks read that range'  "git --no-banner --log-opts=$before..$(git -C "$repo" rev-parse HEAD)" \
  "$(sed 's/^\[//; s/ [^ ]*$//' "$leaks_args")"

echo 'a credential in a pushed commit refuses, and says it cannot be recalled'
out="$(PROBE_LEAKS=red only_new "$repo")"; rc=$?
check 'exit 1'                 1 "$rc"
check 'it says what to do' yes "$(grep -q 'a commit that is pushed cannot be recalled' <<< "$out" && echo yes || echo no)"

# --- the Windows entry point, held against the one text it copies ----------------------------
#
# check.ps1 and build.ps1 decide nothing: each starts the .sh file of its own name. Overwritten
# with two lines that print the verdict and exit 0, a copy tells the person at the keyboard that
# the checks passed while nothing ran. The planted bin/case-check.ps1 differs from the text and
# must NOT be refused: without it, a green answer here could mean that no file was compared.
stub_ps1() {  # stub_ps1 <path> - a copy that prints the verdict and runs nothing
  printf "Write-Host 'check: OK — every check green'\nexit 0\n" > "$1"
}
push_wt() { judge "$wt" "$(git -C "$wt" rev-parse HEAD)" "$(git -C "$repo" rev-parse master)"; }

echo 'a Windows entry point that is not the one text is refused, under either of its two names'
out="$(push_wt)"; rc=$?
check 'both entry points and the .ps1 that is neither: exit 0' 0 "$rc"
stub_ps1 "$wt/scripts/check.ps1"
out="$(push_wt)"; rc=$?
check 'the green stub at scripts/check.ps1: exit 1' 1 "$rc"
check 'the refusal names the file' yes \
  "$(grep -qF 'scripts/check.ps1 is not the Windows entry point every repository carries' <<< "$out" && echo yes || echo no)"
check 'and says how to restore it' yes "$(grep -q 'Restore it: cp ' <<< "$out" && echo yes || echo no)"
git -C "$wt" checkout -q -- scripts/check.ps1
stub_ps1 "$wt/build.ps1"
out="$(push_wt)"; rc=$?
check 'the green stub at build.ps1: exit 1' 1 "$rc"
git -C "$wt" checkout -q -- build.ps1
out="$(push_wt)"; rc=$?
check 'both restored: exit 0' 0 "$rc"

# --- a repository without a check entry point --------------------------------------------------
echo 'a repository without scripts/check.sh: nothing runs before the push, and no entry point is judged'
bare="$fake/bare.git"; git init -q --bare -b master "$bare"
plain="$fake/plain"; git init -q -b master "$plain"
git -C "$plain" config user.email 'test@example.invalid'; git -C "$plain" config user.name 'test'
printf 'Write-Host "decides on its own"\n' > "$plain/build.ps1"
git -C "$plain" add -A; git -C "$plain" commit -q -m 'A repository with no check #7'
git -C "$plain" remote add origin "$bare"; git -C "$plain" push -q -u origin master 2>/dev/null
printf 'more\n' > "$plain/more.txt"; git -C "$plain" add -A; git -C "$plain" commit -q -m 'Add more #7'
out="$(only_new "$plain")"; rc=$?
check 'exit 0'                              0 "$rc"
check 'it says nothing runs'                yes "$(grep -q 'no scripts/check.sh in this repository' <<< "$out" && echo yes || echo no)"
check 'the own build.ps1 is not refused'    no "$(grep -q 'Windows entry point' <<< "$out" && echo yes || echo no)"

# --- from a prompt: the current branch against its upstream ----------------------------------
echo 'with nothing on standard input, the branch is judged against its upstream'
out="$( cd "$plain" && bash "$root/bin/pre-push.sh" < /dev/null 2>&1 )"; rc=$?
check 'exit 0'                     0 "$rc"
check 'it names the upstream'      yes "$(grep -q 'pre-push: judging master against origin/master' <<< "$out" && echo yes || echo no)"
git -C "$plain" commit -q --allow-empty -m 'An empty commit that names nothing'
out="$( cd "$plain" && bash "$root/bin/pre-push.sh" < /dev/null 2>&1 )"; rc=$?
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
check 'post-checkout starts init where .ai-core is missing' yes "$(grep -qx 'ai-core init --no-doctor || echo "post-checkout: the harness is NOT complete in this worktree (see above); run ai-core init here before you start" >&2' "$fresh/.githooks/post-checkout" && echo yes || echo no)"
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

echo 'post-checkout: a worktree cut from the checkout starts ai-core init; a branch checkout where .ai-core is present starts nothing'
: > "$shim_args"
mkdir -p "$fresh/.ai-core"
git -C "$fresh" checkout -q -b probe-branch < /dev/null 2>/dev/null
check 'nothing started in the checkout' '' "$(cat "$shim_args")"
fresh_wt="$fake/fresh-wt"
git -C "$fresh" worktree add -q --detach "$fresh_wt" HEAD < /dev/null 2>"$fake/wt-err.txt"; rc=$?
check 'git worktree add: exit 0'      0 "$rc"
check 'ai-core init started in the new worktree' '[init --no-doctor] ' "$(cat "$shim_args")"
check 'nothing on stderr'             '' "$(cat "$fake/wt-err.txt")"
git -C "$fresh" worktree remove --force "$fresh_wt" >/dev/null 2>&1
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
: > "$shim_args"
out="$( cd "$pushed" && bash "$root/bin/pre-push.sh" --install 2>&1 )"; rc=$?
check 'exit 0'                        0 "$rc"
check 'pushed to origin/master'       yes "$(grep -q '^pre-push: pushed: pushed to origin/master$' <<< "$out" && echo yes || echo no)"
check 'the origin has the commit'     "$(git -C "$pushed" rev-parse HEAD)" "$(git -C "$origin_bare" rev-parse master)"
check 'and the push went through the shim, so through ai-core pre-push' yes "$(grep -q '^\[pre-push origin ' "$shim_args" && echo yes || echo no)"

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

echo 'an unpushed commit that touches something else and names no issue is still refused, by the gate'
printf 'x\n' > "$pushed/x.txt"; git -C "$pushed" add x.txt; git -C "$pushed" commit -q -m 'Add x without a ticket'
printf '#!/usr/bin/env bash\nexec bash ../tooling/hooks/pre-push "$@"\n' > "$pushed/.githooks/pre-push"
out="$( cd "$pushed" && PATH="$root/bin:$PATH" bash "$root/bin/pre-push.sh" --install 2>&1 )"; rc=$?
check 'exit 1'                        1 "$rc"
check 'the gate names the commit'     yes "$(grep -q 'Add x without a ticket names no issue' <<< "$out" && echo yes || echo no)"
check 'the push was refused, the commit stays' yes "$(grep -q 'the push was refused or failed (see above); the commit stays' <<< "$out" && echo yes || echo no)"
git -C "$pushed" reset -q --hard origin/master   # the foreign commit goes; the origin is where the last push left it

echo 'every worktree of the repository gets the shim too, and only the checkout commits it'
printf '#!/usr/bin/env bash\nexec bash ../tooling/hooks/pre-push "$@"\n' > "$pushed/.githooks/pre-push"
git -C "$pushed" commit -q -am 'An older shim, as a worktree branched off it would carry #9'
pushed_wt="$fake/pushed-wt"; git -C "$pushed" worktree add -q -b issue-9-probe "$pushed_wt" master
head_before="$(git -C "$pushed" rev-parse HEAD)"
out="$( cd "$pushed" && bash "$root/bin/pre-push.sh" --install 2>&1 )"; rc=$?
check 'exit 0'                              0 "$rc"
check 'the checkout: refreshed, committed, pushed' yes "$(grep -q '^pre-push: pushed: .githooks/pre-push refreshed$' <<< "$out" && grep -q '^pre-push: pushed: pushed to origin/master$' <<< "$out" && echo yes || echo no)"
check 'the worktree: refreshed, and left to its own commit' yes "$(grep -q "^pre-push: pushed (worktree pushed-wt): .githooks/pre-push refreshed; it goes out with that worktree's own commit$" <<< "$out" && echo yes || echo no)"
check 'the worktree carries the shim'       yes "$(grep -qx 'exec ai-core pre-push "$@"' "$pushed_wt/.githooks/pre-push" && echo yes || echo no)"
check 'and post-checkout, carried already'          yes "$(grep -q "^pre-push: pushed (worktree pushed-wt): .githooks/post-checkout unchanged; it goes out with that worktree's own commit$" <<< "$out" && grep -q 'ai-core init --no-doctor' "$pushed_wt/.githooks/post-checkout" && echo yes || echo no)"
check 'the worktree has it uncommitted'     ' M .githooks/pre-push' "$(git -C "$pushed_wt" status --porcelain .githooks/pre-push)"
check 'the checkout moved by one commit'    "$head_before" "$(git -C "$pushed" rev-parse HEAD~1)"
git -C "$pushed" worktree remove --force "$pushed_wt" >/dev/null 2>&1

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

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
