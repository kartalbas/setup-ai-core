#!/usr/bin/env bash
# The tally of review verdicts that `status --tokens` prints per builder setup: counted from the comments of the plan
# issues of the board (a title that starts with "Plan: packages"), within the 14 days of the pace, and what it does not
# count is named, never a zero. A fake gh answers the board and the threads; HOME and the clock are fixed.
#
#   bash tests/status-reviews.test.sh

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export HOME="$work/home" AI_CORE_HOME="$work/home" AI_CORE_TRANSCRIPTS="$work/transcripts" CODEX_HOME="$work/codex"
export GH_ORG=example-org GH_CACHE_DIRECTORY="$work/cache" AI_CORE_NOW=1790000000 TZ=UTC
. "$root/tests/tool-environment.sh"
now=$AI_CORE_NOW
folder="$work/example"
mkdir -p "$HOME/.ai-core" "$folder/.ai-core" "$work/cache/7" "$work/bin" "$AI_CORE_TRANSCRIPTS"

failed=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}
when() { LC_ALL=C date -u -d "@$1" '+%a %d.%m. %H:%M' 2>/dev/null || LC_ALL=C date -u -r "$1" '+%a %d.%m. %H:%M'; }
iso() { LC_ALL=C date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || LC_ALL=C date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ'; }
day=86400

# The board: four cards behind a fake gh. #1 and #2 are plan issues (#2 is closed), #3 is a plan issue whose thread
# cannot be read, #4 is no plan issue and holds a verdict that must not be read.
echo PVT_example7 > "$work/cache/7/project-id"
printf 'Status\tF1\t%s\tO%s\n' Backlog 1 Todo 2 'In progress' 3 Done 4 > "$work/cache/7/fields.tsv"
card() {  # card <number> <status> <state> <title>
  printf '{"status":{"name":"%s"},"priority":null,"content":{"number":%s,"title":"%s","state":"%s","closedAt":null,"createdAt":"2026-01-01T00:00:00Z","body":"","repository":{"nameWithOwner":"example-org/example-repo"},"parent":null,"subIssuesSummary":{"total":0}}}\n' "$2" "$1" "$4" "$3"
}
{ card 1 'In progress' OPEN 'Plan: packages of the week'; card 2 Done CLOSED 'Plan: packages of the week before'
  card 3 'In progress' OPEN 'Plan: packages that cannot be read'; card 4 Todo OPEN 'Not a plan: a review verdict inside'; } > "$work/board"

verdict() {  # verdict <age in days> <first line> [more lines...]: one comment of a thread, its time that many days before now
  local age="$1" body
  shift
  body="$(printf '%s\n' "$@")"
  jq -nc --arg at "$(iso $((now - age * day)))" --arg body "$body" '{user: {login: "reviewer"}, created_at: $at, body: $body}'
}
identity() { printf 'Reviewer: %s (%s, %s). Builder: %s (%s, %s).' "$@"; }
S=(claude-sonnet-5.5 high) O=(claude-opus-5.5 medium)
{
  verdict 3 'REVIEW area-a: GO' "$(identity r1 claude-opus-5.5 xhigh b1 "${S[@]}")" 'REPAIRED:' '- example-repo lib/x.mjs:3: wrong; commit abc1234' 'FINDINGS:' 'CRITERIA: 2 of 2 met'
  verdict 3 'REVIEW area-b: NO' "$(identity r1 claude-opus-5.5 xhigh b2 "${S[@]}")" 'FINDINGS:' '- example-repo lib/y.mjs:9: a defect; state: x'
  verdict 2 'REVIEW area-c: GO' "$(identity r2 claude-opus-5.5 xhigh b3 "${O[@]}")" 'HEAD: example-repo#3 abc1234' 'REPAIRED:' 'FINDINGS:'
} > "$work/thread-1-page-1"
{
  verdict 20 'REVIEW area-old: NO' "$(identity r9 claude-opus-5.5 xhigh b9 "${S[@]}")" 'FINDINGS:' '- a defect from before the interval'
  verdict 1 'REVIEW area-d: NO' "$(identity r3 claude-opus-5.5 xhigh b5 "${S[@]}")" 'FINDINGS: needs a full review: the repair changed a file no finding names'
  verdict 1 'REVIEW area-a: GO' "$(identity r1 claude-opus-5.5 xhigh b1 "${S[@]}")" 'REPAIRED:' '- example-repo lib/x.mjs:3: wrong; commit abc1234' 'FINDINGS:' 'CRITERIA: 2 of 2 met'
  verdict 1 'The reviewer said:' '> REVIEW area-q: NO' "> $(identity r4 claude-opus-5.5 xhigh b6 "${S[@]}")"
  verdict 1 'REVIEW area-e: NO' 'FINDINGS:' '- a verdict from before the line existed'
  verdict 1 'REVIEW area-u: GO' "$(identity r8 claude-opus-5.5 xhigh b10 unknown unknown)" 'FINDINGS:'
  verdict 1 'RE-CHECK area-a: GO' 'the repair settles it'
  verdict 1 'VERDICT: GO' 'a plan check in another shape'
  verdict 1 'PLAN CHECK area-a: NO' 'GAPS:'
  verdict 1 'REVIEW area-f: GO' "$(identity r5 claude-opus-5.5 xhigh b7 "${O[@]}")" 'FINDINGS:'
  verdict 1 'REVIEW area-f: NO' "$(identity r5 claude-opus-5.5 xhigh b7 "${O[@]}")" 'FINDINGS:' '- a contradiction'
} > "$work/thread-1-page-2"
{ verdict 4 'REVIEW area-g: GO' "$(identity r6 claude-opus-5.5 xhigh b8 "${S[@]}")" 'FINDINGS:'; } > "$work/thread-2-page-1"
verdict 1 'REVIEW area-z: NO' "$(identity r7 claude-opus-5.5 xhigh b9 "${S[@]}")" 'FINDINGS:' '- not a plan issue' > "$work/thread-4-page-1"
cat > "$work/bin/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$work/gh.log"
case "\$*" in
  *'items(first'*) cat "$work/board" ;;
  'api repos/example-org/example-repo/issues/1'|'api repos/example-org/example-repo/issues/2')
    printf '{"number":%s,"title":"Plan","state":"open","labels":[],"body":"","created_at":"2026-01-01T00:00:00Z"}\n' "\${2##*/}" ;;
  'api --paginate repos/example-org/example-repo/issues/1/comments') jq -s '.' "$work/thread-1-page-1"; jq -s '.' "$work/thread-1-page-2" ;;
  'api --paginate repos/example-org/example-repo/issues/2/comments') jq -s '.' "$work/thread-2-page-1" ;;
  'api repos/example-org/example-repo/issues/3') echo 'gh: Bad credentials' >&2; exit 1 ;;
  *) echo "unexpected gh call: \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$work/bin/gh"
printf '#!/usr/bin/env bash\necho "ps: unknown option -- A" >&2; exit 1\n' > "$work/bin/ps"; chmod +x "$work/bin/ps"
export PATH="$work/bin:$PATH"
printf '{"recorded_at":%s,"rate_limits":{"five_hour":{"used_percentage":25,"resets_at":%s}}}\n' "$now" $((now + 3600)) > "$HOME/.ai-core/usage.json"

run_status() { (cd "$folder" && bash "${1:-$root}/bin/status.sh" --project example-org/7 --tokens 2>&1); }
out="$(run_status)"; rc=$?
reviews() { awk '/^reviews / { on = 1 } /^open / { on = 0 } on' <<< "$1"; }
echo 'the tally over the pages of the plan issues, open and closed, per builder setup'
check 'exit 0' 0 "$rc"
check 'the interval, the board, the coverage and the count' "reviews 14 days to $(when "$now") on board example-org/7: 2 of 3 plan issues read, 6 verdicts counted" "$(reviews "$out" | sed -n 1p)"
check 'the setup of the Opus builder: one GO, no NO' '        claude-opus-5.5 medium: 1 GO, 0 NO' "$(reviews "$out" | sed -n 2p)"
check 'the setup of the Sonnet builder: two GO, one with REPAIRED, and the one NO' '        claude-sonnet-5.5 high: 2 GO (1 with REPAIRED), 1 NO' "$(reviews "$out" | sed -n 3p)"
check 'a verdict with no line of builders, or with a builder the coordinator did not know, is unattributed, not lost' '        unattributed, with no builder named: 1 GO, 1 NO' "$(reviews "$out" | sed -n 4p)"
check 'a full review asked for, a repost and a contradiction are named and not counted' '        not counted: 1 asking for a full review, 1 reposted, 1 contradicting another verdict of the same reviewer and builder' "$(reviews "$out" | sed -n 5p)"
check 'the other shapes and the unreadable plan issue are unmeasured, with their count' \
  '        unmeasured: 3 comments in a shape this does not count (RE-CHECK, PLAN CHECK, VERDICT: or a REVIEW line of another form); 1 plan issue that could not be read, so the tally is incomplete: example-org/example-repo#3 (error: cannot read the issue example-org/example-repo#3 - gh exited 1)' \
  "$(reviews "$out" | sed -n 6p)"
check 'the rest of the page stays beside the incomplete tally' 1 "$(grep -c '^tokens ' <<< "$out")"
check 'a comment older than 14 days, the quoted verdict and an issue that is no plan issue are not read' '0 0' \
  "$(grep -c 'area-old\|area-q' <<< "$out") $(grep -c 'issues/4' "$work/gh.log")"
check 'every comment page of a plan issue is read' 1 "$(grep -c -- '--paginate repos/example-org/example-repo/issues/1/comments' "$work/gh.log")"

echo 'two status runs at once give the same tally'
( run_status > "$work/first.out" ) & first=$!
( run_status > "$work/second.out" ) & second=$!
wait "$first" "$second"
check 'both tallies are the one above' "$(reviews "$out")" "$(reviews "$(cat "$work/first.out")")"
check 'and the same' "$(reviews "$out")" "$(reviews "$(cat "$work/second.out")")"

echo 'a board with no plan issue says so, and says no zero'
sed -i.bak 's/Plan: packages/Package list/g' "$work/board"
out="$(run_status)"
check 'no plan issue' "reviews 14 days to $(when "$now") on board example-org/7: no plan issue (a title that starts with \"Plan: packages\") on this board" "$(reviews "$out")"

echo 'planted defects in a copy of the harness: each turns the count red'
mutant="$work/mutant"
plant() {  # plant <sed script> <file>: the board restored, the copy carrying one defect
  mv "$work/board.bak" "$work/board" 2>/dev/null
  rm -rf "$mutant"; mkdir -p "$mutant"; cp -R "$root/bin" "$root/lib" "$root/templates" "$mutant/"; cp "$root/VERSION" "$mutant/"
  sed -i.bak "$1" "$mutant/$2"
  cmp -s "$root/$2" "$mutant/$2" && { echo "  FAIL the planted copy equals $2: $1"; failed=$((failed + 1)); }
  planted="$(reviews "$(run_status "$mutant")")"
}
plant 's/if (verdict.fullReview) { left.fullReview++; continue; }//' lib/status-reviews.mjs
check 'a request for a full review counted as a NO' no "$(grep -q '2 GO (1 with REPAIRED), 1 NO' <<< "$planted" && echo yes || echo no)"
plant 's/else if (earlier.result === verdict.result) left.reposts++;/else if (false) left.reposts++;/' lib/status-reviews.mjs
check 'a repost counted twice' no "$(grep -q 'claude-sonnet-5.5 high: 2 GO (1 with REPAIRED), 1 NO' <<< "$planted" && echo yes || echo no)"
plant 's/if (Number.isFinite(at) \&\& (at < since || at > now)) continue;//' lib/status-reviews.mjs
check 'a verdict older than the interval counted' no "$(grep -q ' 6 verdicts counted' <<< "$planted" && echo yes || echo no)"
plant 's/startswith("Plan: packages")/test("lan")/' bin/status.sh
check 'an issue that is no plan issue read' no "$(grep -q '2 of 3 plan issues read' <<< "$planted" && echo yes || echo no)"

[ "$failed" -eq 0 ] || { echo "$failed failed"; exit 1; }
echo 'all passed'
