#!/usr/bin/env bash
# The push gate runs scripts/check.sh once per commit of a landing: the receipt that a landing hands its two
# pushes shows the green check of the first one to the gate of the second, and only an exact match skips it.
#
#   bash tests/landing-check.test.sh
#
# Git's input is fed to the gate by hand, one line per ref, in a scratch repository with a local origin; the
# check is a stand-in that writes down each run.

set -uo pipefail
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fake="$(mktemp -d)"
export HOME="$fake/home" AI_CORE_HOME="$fake/ai-core-home"; mkdir -p "$HOME" "$AI_CORE_HOME"
trap 'rm -rf "$fake"' EXIT
failed=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: [$2]"; echo "       actual:   [$3]"; failed=$((failed + 1)); fi
}
printf 'claude\tmode\talways\t-\t-\n' > "$fake/modes.tsv"; export TEAM_MODES_FILE="$fake/modes.tsv"

origin="$fake/origin.git"; repo="$fake/project/app"; runs="$fake/check-runs.txt"; : > "$runs"
git init -q --bare -b master "$origin"
git init -q -b master "$repo"; git -C "$repo" remote add origin "$origin"
git -C "$repo" config user.email test@example.invalid; git -C "$repo" config user.name test
mkdir -p "$repo/scripts" "$repo/.ai-core"
printf '#!/usr/bin/env bash\necho run >> "%s"\necho "check: OK"\n' "$runs" > "$repo/scripts/check.sh"; chmod +x "$repo/scripts/check.sh"
printf 'PRE_PUSH_LOAD_LIMIT="0"\n' > "$repo/.ai-core/config.env"; printf '.ai-core/\n' >> "$repo/.git/info/exclude"
git -C "$repo" add scripts; git -C "$repo" commit -q -m 'Start #1'; git -C "$repo" push -q origin master
git -C "$repo" remote set-head origin master >/dev/null 2>&1 || git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master
base="$(git -C "$repo" rev-parse HEAD)"
echo work > "$repo/work.txt"; git -C "$repo" add work.txt; git -C "$repo" commit -q -m 'Merge issue-9 (#9)'
merged="$(git -C "$repo" rev-parse HEAD)"
zeros=0000000000000000000000000000000000000000
ci_ref=refs/heads/ci/integrate-issue-9-x

# gate <receipt or -> <ref line...>: the gate, as git starts it, with the receipt of the landing in the environment of this
# one process; the output is in out, the status in rc, and how often the check ran in ran
gate() {
  local receipt="$1"; shift
  local before mark refs=() line carried=()
  [ "$receipt" = - ] || carried=(AI_CORE_LANDING_RECEIPT="$receipt")
  before="$(wc -l < "$runs")"
  # Every push here is made by a path of the harness, which marks it: the default branch takes no other.
  while read -r _ _ line _; do refs+=("$line"); done <<< "$(printf '%s\n' "$@")"
  mark="$(bash "$root/lib/landing-check.sh" mark "$repo" "${1%% *}" "${refs[@]}")"
  out="$(printf '%s\n' "$@" | ( cd "$repo" && env AI_CORE_LANDING_MARK="$mark" ${carried[@]+"${carried[@]}"} bash "$root/bin/pre-push.sh" origin x 2>&1 ))"; rc=$?
  bash "$root/lib/landing-check.sh" unmark "$mark"
  ran=$(( $(wc -l < "$runs") - before ))
}
first_push() { gate "$1" "$merged $merged $ci_ref $zeros"; }
final_push() { gate "$1" "$merged $merged refs/heads/master $base"; }
r="$fake/receipt"
said() { grep -qF -- "$1" <<< "$out" && echo yes || echo no; }

echo 'a push outside a landing runs the check as it always did'
final_push -
check 'exit 0, the check ran once, the old line'  '0 1 yes' "$rc $ran $(said "scripts/check.sh runs here, before anything leaves this machine.")"

echo 'the first push of a landing runs the check and leaves a receipt'
rm -f "$r"; first_push "$r"
check 'exit 0, the check ran once'                 '0 1' "$rc $ran"
check 'the line names the full commit'             yes "$(said "scripts/check.sh runs for $merged:")"
check 'the receipt names the commit and the green check, and no CI result yet' '1 1 0' "$(grep -c "^commit	$merged\$" "$r") $(grep -c '^check	green$' "$r") $(grep -c '^ci	' "$r")"

echo 'a final push whose receipt holds no green CI result runs the check again'
final_push "$r"
check 'the check ran, and the reason names the CI' '1 yes' "$ran $(said 'holds no green CI result of this commit')"

echo 'once the push and the CI went through, the final push of the same commit does not run the check (planted: it ran twice)'
bash "$root/lib/landing-check.sh" complete "$r" "$merged" "$ci_ref" || check 'the receipt is completed' 0 1
final_push "$r"
check 'exit 0, the check did not run'              '0 0' "$rc $ran"
check 'the line names the full commit and says it does not run again' yes "$(said "scripts/check.sh of $merged does not run again")"
check 'the run record says that no check ran'      yes "$(bash "$root/bin/pre-push.sh" --runs | sed -n 2p | grep -qF "$merged	no check	" && echo yes || echo no)"
check 'nothing else was skipped: the gate still ended with its verdict' yes "$(said 'nothing refused this push')"

echo 'a second commit on the final push runs the check again (planted)'
echo more > "$repo/more.txt"; git -C "$repo" add more.txt; git -C "$repo" commit -q -m 'Another commit (#9)'
second="$(git -C "$repo" rev-parse HEAD)"
gate "$r" "$second $second refs/heads/master $base"
check 'the check ran, naming the commit it holds'  "1 yes" "$ran $(said "holds a check of $merged, not of this commit")"
git -C "$repo" reset -q --hard "$merged"

echo 'a receipt that does not hold runs the check, each time with its reason'
tamper() {  # tamper <label> <expected reason> <sed program>
  sed "$3" "$r" > "$fake/receipt.t"; final_push "$fake/receipt.t"
  check "$1: the check ran, and the reason is given" "1 yes" "$ran $(said "$2")"
}
tamper 'another clone'         'belongs to another clone'    's#^clone	.*#clone	/elsewhere/.git#'
tamper 'another origin'        'belongs to another origin'   's#^origin	.*#origin	/elsewhere.git#'
tamper 'another tree'          'is not the tree'             's#^tree	.*#tree	0000000000000000000000000000000000000001#'
tamper 'a neighbour snapshot the check never read' 'stand at other commits' 's#^check	green$#neighbour	cat	1111111111111111111111111111111111111111\ncheck	green#'
tamper 'a receipt without its green check' 'holds no green check' '/^check	green$/d'
tamper 'a CI result of another commit' 'no green CI result' 's#^ci	\(.*\)	'"$merged"'	green#ci	\1	2222222222222222222222222222222222222222	green#'
tamper 'a first push that was not a ci/ branch' 'was not the gate of a push to ci/integrate' 's#^ref	.*#ref	refs/heads/other#'
printf 'garbage\n' > "$fake/receipt.t"; final_push "$fake/receipt.t"
check 'a receipt of no version: the check ran'     "1 yes" "$ran $(said 'is not one this gate reads')"
final_push "$fake/nowhere"
check 'a receipt that does not exist: the check ran' "1 yes" "$ran $(said 'no receipt of this landing stands')"
gate "$r" "$merged $merged refs/heads/master $base" "$merged $merged refs/heads/other $zeros"
check 'a push of two refs: the check ran'          "1 yes" "$ran $(said 'not the one push of the checked commit')"
gate "$r" "$merged $merged refs/heads/other $zeros"
check 'a push to another branch: the check ran'    "1 yes" "$ran $(said 'not the one push of the checked commit')"
echo dirty > "$repo/work.txt"; final_push "$r"
check 'a dirty tree is refused even with a receipt, and nothing is skipped' '1 0' "$rc $ran"
git -C "$repo" checkout -q -- work.txt

echo 'a check that is red leaves no receipt'
printf '#!/usr/bin/env bash\necho run >> "%s"\necho "check: FAIL"; exit 1\n' "$runs" > "$repo/scripts/check.sh"; git -C "$repo" commit -q -am 'Red check (#9)'
red="$(git -C "$repo" rev-parse HEAD)"
rm -f "$fake/receipt.red"; gate "$fake/receipt.red" "$red $red $ci_ref $zeros"
check 'exit 1, the check ran, no receipt'          '1 1 no' "$rc $ran $([ -e "$fake/receipt.red" ] && echo yes || echo no)"

# --- the commits a path of the harness writes on its own ---------------------------------------------------------------
# harness_commits_only holds where every unpushed commit is one of init's or of pre-push --install; a commit that it could
# not read is not one of them. A git that fails on cue stands in front of the real one.
. "$root/lib/landing-check.sh"
real_git="$(command -v git)"; stub="$fake/stub"; mkdir -p "$stub"
cat > "$stub/git" <<EOF
#!/usr/bin/env bash
if [ -n "\${PROBE_GIT_FAIL:-}" ] && [ "\${1:-}" = -C ] && [ "\${3:-}" = "\$PROBE_GIT_FAIL" ]; then echo 'planted git failure' >&2; exit 42; fi
exec "$real_git" "\$@"
EOF
chmod +x "$stub/git"; export PATH="$stub:$PATH"
hc="$fake/harness-commits"; hc_origin="$fake/harness-commits-origin.git"
git init -q --bare -b master "$hc_origin"; git init -q -b master "$hc"; git -C "$hc" remote add origin "$hc_origin"
git -C "$hc" config user.email test@example.invalid; git -C "$hc" config user.name test
echo one > "$hc/README"; git -C "$hc" add README; git -C "$hc" commit -q -m 'Start #1'; git -C "$hc" push -q origin master
# The old loop, as it stood: a failed git rev-list in its substitution leaves it nothing to read, and nothing read is success.
old_harness_commits_only() {
  local dir="$1" branch="$2" unpushed_range=(HEAD) sha files file
  if git -C "$dir" rev-parse -q --verify "refs/remotes/origin/$branch" >/dev/null; then unpushed_range=(HEAD "^refs/remotes/origin/$branch"); fi
  for sha in $(git -C "$dir" rev-list "${unpushed_range[@]}"); do
    files="$(git -C "$dir" diff-tree --no-commit-id --root -r --name-only "$sha" | sort -u | tr '\n' ' ')"
    case "$(git -C "$dir" log -1 --format='%(trailers:key=No-issue,valueonly)' "$sha")" in
      *'the .gitignore block written by ai-core init'*) [ "$files" = '.gitignore ' ] || return 1 ;;
      *'written, committed and pushed by ai-core pre-push --install'*)
        [ -n "$files" ] || return 1
        for file in $files; do
          case "$file" in .gitattributes|.githooks/pre-push|.githooks/post-checkout) ;; *) return 1 ;; esac
        done ;;
      *) return 1 ;;
    esac
  done
}
marked() {  # marked <old|new>: whether a push of HEAD of the scratch repository carries a mark of a landing
  local out
  out="$( { [ "$1" = new ] || harness_commits_only() { old_harness_commits_only "$@"; }; with_harness_commits_mark "$hc" master -- bash -c 'echo "${AI_CORE_LANDING_MARK:-none}"'; } 2>/dev/null)"
  [ "$out" != none ] && echo yes || echo no
}
echo 'nothing unpushed: the mark is there'
check 'the push of nothing is the harness'"'"'s' yes "$(marked new)"
echo 'the commit of the .gitignore block and the commit of the shims, each with its trailer and its files alone'
echo '/.ai-core/' > "$hc/.gitignore"; git -C "$hc" add .gitignore
git -C "$hc" commit -q -m 'ai-core init: the .gitignore block' -m 'No-issue: the .gitignore block written by ai-core init'
mkdir -p "$hc/.githooks"; echo shim > "$hc/.githooks/pre-push"; git -C "$hc" add .githooks
git -C "$hc" commit -q -m 'the hooks of ai-core' -m 'No-issue: the shims, written, committed and pushed by ai-core pre-push --install'
check 'innocent: both are the harness'"'"'s, and get the mark' yes "$(marked new)"
echo 'a git call that fails while the commits are read: no mark, and the old loop gave one after the failed listing'
for failing in rev-list diff-tree log; do
  check "$failing fails: the commits of the harness get no mark" no "$(PROBE_GIT_FAIL=$failing marked new)"
done
check 'planted: the old loop, its listing failed, grants the mark' yes "$(PROBE_GIT_FAIL=rev-list marked old)"
echo 'a commit of somebody else beneath them'
echo two >> "$hc/README"; git -C "$hc" commit -q -am 'Change the readme #2'
check 'no mark' no "$(marked new)"

echo 'a push judged as a direct push needs a commit to judge, and a range git can list'
head="$(git -C "$hc" rev-parse HEAD)"
direct_push_commits_only "$hc" 'README' "$head ^$head"; rc=$?
check 'a range that names no commit fails' '1 yes' "$rc $(grep -q 'name no commit to judge' <<< "$DIRECT_PUSH_REASON" && echo yes || echo no)"
direct_push_commits_only "$hc" 'README' "$head ^0123456789012345678901234567890123456789" 2>/dev/null; rc=$?
check 'a range git cannot list fails' '1 yes' "$rc $(grep -q 'cannot be listed' <<< "$DIRECT_PUSH_REASON" && echo yes || echo no)"
direct_push_commits_only "$hc" 'README' "$head ^$(git -C "$hc" rev-parse HEAD~1)"; rc=$?
check 'innocent: the commit that changes the listed file alone passes' "0 " "$rc $DIRECT_PUSH_REASON"

echo 'a commit for which git lists no file is no commit of the harness: an empty one, and a merge of commits origin has that brings a file of its own'
git -C "$hc" reset -q --hard origin/master
echo second > "$hc/second"; git -C "$hc" add second; git -C "$hc" commit -q -m 'Second #3'; git -C "$hc" push -q origin master
shims_trailer='No-issue: the shims, written, committed and pushed by ai-core pre-push --install'
# The planted copy turns an empty list of files into one blank name, which passes the check of the shims.
blank_name="$fake/landing-check-blank-name.sh"
sed 's/^    \[ -z "\$files" \] || files=/    files=/' "$root/lib/landing-check.sh" > "$blank_name"
cmp -s "$root/lib/landing-check.sh" "$blank_name" && { echo "  FAIL the planted copy equals lib/landing-check.sh"; failed=$((failed + 1)); }
marked_by() {  # marked_by <library>: whether a push of HEAD of the scratch repository carries a mark, with the functions of that library
  local out
  # shellcheck disable=SC1090 # the library is the argument: the real one or its planted copy
  out="$( { . "$1"; with_harness_commits_mark "$hc" master -- bash -c 'echo "${AI_CORE_LANDING_MARK:-none}"'; } 2>/dev/null)"
  [ "$out" != none ] && echo yes || echo no
}
git -C "$hc" commit -q --allow-empty -m 'the hooks of ai-core' -m "$shims_trailer"
check 'an empty commit with the trailer of the shims: no mark' no "$(marked_by "$root/lib/landing-check.sh")"
check 'planted: the blank name grants it the mark' yes "$(marked_by "$blank_name")"
git -C "$hc" reset -q --hard origin/master
echo code > "$hc/brought.sh"; git -C "$hc" add brought.sh; tree="$(git -C "$hc" write-tree)"; git -C "$hc" reset -q --hard origin/master
git -C "$hc" reset -q --hard "$(git -C "$hc" commit-tree "$tree" -p origin/master -p origin/master~1 -m 'the hooks of ai-core' -m "$shims_trailer")"
check 'a merge of two commits of origin that brings brought.sh, with the trailer of the shims: no mark' no "$(marked_by "$root/lib/landing-check.sh")"
check 'planted: the blank name grants that merge the mark' yes "$(marked_by "$blank_name")"
git -C "$hc" reset -q --hard origin/master
mkdir -p "$hc/.githooks"; echo shim > "$hc/.githooks/pre-push"; git -C "$hc" add .githooks; git -C "$hc" commit -q -m 'the hooks of ai-core' -m "$shims_trailer"
check 'innocent: the commit of the shims gets the mark' yes "$(marked_by "$root/lib/landing-check.sh")"

echo
if [ "$failed" -eq 0 ]; then echo "all passed"; else echo "$failed failed"; exit 1; fi
