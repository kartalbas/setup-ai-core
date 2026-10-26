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
  local before; before="$(wc -l < "$runs")"
  out="$(printf '%s\n' "$@" | ( cd "$repo" && if [ "$receipt" = - ]; then bash "$root/bin/pre-push.sh" origin x; else AI_CORE_LANDING_RECEIPT="$receipt" bash "$root/bin/pre-push.sh" origin x; fi 2>&1 ))"; rc=$?
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

echo
if [ "$failed" -eq 0 ]; then echo "all passed"; else echo "$failed failed"; exit 1; fi
