#!/usr/bin/env bash
# What issue-close.sh sends GitHub as the close reason, and what it does to the card.
#
# Run with a FAKE gh on PATH, so nothing is closed and the arguments the command would have sent
# are recorded instead. That is the only way to test this: the rule is about what reaches
# `gh api`, and a wrong close reason is invisible until somebody reads the issue afterwards and
# sees "completed" on a rejected design.
#
#   bash test/close-reason.test.sh

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fake="$(mktemp -d)"
export GH_CACHE_DIRECTORY="$fake/cache"
trap 'rm -rf "$fake"' EXIT
log="$fake/calls.txt"

# The stand-in. It answers the reads the command makes with jq-shaped output - the real gh would
# have applied each --jq already - and records every call. The issue is on one board and nowhere
# else, so the card half has exactly one board to write. The number is one no real board
# carries, so the id this test invents lands in a cache directory of its own.
cat > "$fake/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
j="\$*"
case "\$j" in
  # the open sub-issues of the issue asked for (-F n=), as the --jq of the query prints them, one a line
  *'subIssues(first'*)             [ -e "$fake/children-down" ] && { echo 'gh: HTTP 502' >&2; exit 1; }
                                   cat "$fake/open-children-\$(printf '%s\n' "\$@" | sed -n 's/^n=\([0-9]*\)\$/\1/p')" 2>/dev/null; exit 0 ;;
  *projectItems*)                  printf 'example-org/998\tPVTI_item\n'; exit 0 ;;
  *'projectsV2(first'*)            printf '998\talpha\n'; exit 0 ;;
  *'projectV2(number'*)            echo 'PVT_kwclose'; exit 0 ;;
  *'fields(first:50'*)             printf 'Status\tF1\tdone\tD1\nStatus\tF1\ttodo\tT1\n'; exit 0 ;;
  *addProjectV2ItemById*)          echo 'PVTI_item'; exit 0 ;;
esac
if [ "\$*" = "api repos/{owner}/{repo} --jq .full_name" ]; then echo 'example-org/example-repo'; exit 0; fi
if [ "\$1" = "repo" ]; then echo 'example-org/example-repo'; exit 0; fi
echo '{}'
exit 0
EOF
chmod +x "$fake/gh"
export PATH="$fake:$PATH"

failed=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}

close="$root/bin/issue-close.sh"
repo='example-org/example-repo'

patch_line() {
  : > "$log"
  local reason_flag=()
  if [ -n "${1:-}" ]; then reason_flag=(--reason "$1"); fi
  "$close" "$repo" ${reason_flag[@]+"${reason_flag[@]}"} 270 >/dev/null 2>&1
  grep -m1 'api --method PATCH repos/' "$log" 2>/dev/null || true
}

reason_sent_for() {
  local line
  line="$(patch_line "${1:-}")"
  grep -o 'state_reason=[^ ]*' <<< "$line" | head -1 | cut -d= -f2
}

echo 'the close reason that reaches gh api'
check 'omitted -> completed'       'completed'   "$(reason_sent_for '')"
check 'not-planned -> not_planned' 'not_planned' "$(reason_sent_for 'not-planned')"
check 'completed stays explicit'   'completed'   "$(reason_sent_for 'completed')"

echo 'a reason GitHub does not know stops before anything is sent'
: > "$log"
out="$("$close" "$repo" --reason superseded 270 2>&1)"; rc=$?
check 'exits nonzero'         yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'names the value'       yes "$(grep -q "not 'superseded'" <<< "$out" && echo yes || echo no)"
check 'nothing reached github' 0  "$(grep -c 'api --method PATCH' "$log" || true)"

echo 'the card is moved to done on every board the issue is on'
: > "$log"
out="$("$close" "$repo" 270 2>&1)"
check 'the close line'  '#270 -> closed' "$(printf '%s\n' "$out" | sed -n '1p')"
check 'the board line'  '#270 -> done (board example-org/998)' "$(printf '%s\n' "$out" | sed -n '2p')"
check 'the option sent' yes "$(grep -q 'oid=D1' "$log" && echo yes || echo no)"

# A repository on NO board is not a card that is missing: the issue tooling's own repository is
# deliberately unlinked, and reading the two alike ends the run after the issue has already
# been closed.
echo 'an issue in a repository on no board is closed and says so'
lonely="$fake/lonely"
mkdir -p "$lonely"
cat > "$lonely/gh" <<'NO'
#!/usr/bin/env bash
case "$*" in
  *'subIssues(first'*)  exit 0 ;;
  *projectItems*)       exit 0 ;;
  *'projectsV2(first'*) exit 0 ;;
esac
if [ "$*" = "api repos/{owner}/{repo} --jq .full_name" ]; then echo 'example-org/example-repo'; exit 0; fi
if [ "$1" = "repo" ]; then echo 'example-org/example-repo'; exit 0; fi
echo '{}'
exit 0
NO
chmod +x "$lonely/gh"
out="$(PATH="$lonely:$PATH" "$close" "$repo" 270 2>&1)"; rc=$?
check 'exits zero'      0 "$rc"
check 'the close line'  '#270 -> closed' "$(printf '%s\n' "$out" | sed -n '1p')"
check 'and says why there is no card' "#270 -> done (issue only; $repo is on no board)" \
  "$(printf '%s\n' "$out" | sed -n '2p')"

# An epic carries no work of its own: closed with an open sub-issue, as completed or as not planned, it says
# done on the board while its work is not, or leaves the sub-issues without the issue that tracks them
echo 'an issue with an open sub-issue is refused, with both reasons, and nothing is written for it'
printf 'example-org/example-repo#271\nother-org/tracker#9\n' > "$fake/open-children-270"
for reason in '' not-planned; do
  : > "$log"
  out="$("$close" "$repo" ${reason:+--reason "$reason"} 270 2>&1)"; rc=$?
  check "${reason:-completed}: exits nonzero" yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
  check "${reason:-completed}: it names the open sub-issues as <repo>#<n>" \
    "error: $repo#270 has open sub-issues, so it stays open and its card where it is: example-org/example-repo#271 other-org/tracker#9 - close them first, or take them out of it" \
    "$out"
  check "${reason:-completed}: nothing was closed" 0 "$(grep -c 'api --method PATCH' "$log" || true)"
  check "${reason:-completed}: no card was moved" 0 "$(grep -cE 'updateProjectV2ItemFieldValue|addProjectV2ItemById' "$log" || true)"
done
check 'the sub-issues were read before anything was written' yes "$(grep -q 'subIssues(first' "$log" && echo yes || echo no)"

echo 'two numbers: the one with an open sub-issue is refused where it stands, the one before it is closed'
: > "$log"
rm -f "$fake/open-children-270"; printf 'example-org/example-repo#272\n' > "$fake/open-children-271"
out="$("$close" "$repo" 270 271 2>&1)"; rc=$?
check 'the first of the two is closed' 1 "$(grep -c 'api --method PATCH repos/example-org/example-repo/issues/270 ' "$log" || true)"
check 'exits nonzero' yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'the second is not closed' 0 "$(grep -c 'api --method PATCH repos/example-org/example-repo/issues/271 ' "$log" || true)"
rm -f "$fake/open-children-271"

echo 'a read of the sub-issues that fails closes nothing: no answer is not "no sub-issues"'
: > "$log"; touch "$fake/children-down"
out="$("$close" "$repo" 270 2>&1)"; rc=$?
rm -f "$fake/children-down"
check 'exits nonzero'    yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'it says what it could not read' yes "$(grep -q "cannot read the sub-issues of $repo#270" <<< "$out" && echo yes || echo no)"
check 'nothing was closed' 0 "$(grep -c 'api --method PATCH' "$log" || true)"
check 'no card was moved'  0 "$(grep -cE 'updateProjectV2ItemFieldValue' "$log" || true)"

echo 'an issue whose sub-issues are all closed is closed, as is a leaf'
: > "$log"
out="$("$close" "$repo" 270 2>&1)"; rc=$?
check 'exits zero'       0 "$rc"
check 'the close line'   '#270 -> closed' "$(printf '%s\n' "$out" | sed -n '1p')"
check 'closed'           1 "$(grep -c 'api --method PATCH repos/example-org/example-repo/issues/270 ' "$log" || true)"

echo 'a number that is not one is refused before anything is sent'
: > "$log"
out="$("$close" "$repo" not-a-number 2>&1)"; rc=$?
check 'exits nonzero'  yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'nothing sent'   0 "$(grep -c 'api --method PATCH' "$log" || true)"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
