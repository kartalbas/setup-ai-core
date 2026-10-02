#!/usr/bin/env bash
# What `status` prints for one board: the usage, the pace, what an issue costs of a window, the
# tokens an issue took, the plan of every worker with a pause where the week reaches the limit, and
# what is ready to close or sits on Done while open. The board has two pages, so paging is read.
# The transcripts carry an answer written twice (counted once) and an answer outside a worktree
# (counted to no issue). A fake gh, a fixed clock and a temporary HOME keep the machine out of it.
#
#   bash tests/status.test.sh

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export HOME="$work/home" AI_CORE_HOME="$work/home" AI_CORE_TRANSCRIPTS="$work/transcripts"
export GH_ORG=example-org GH_CACHE_DIRECTORY="$work/cache" AI_CORE_NOW=1790000000 TZ=UTC
now=$AI_CORE_NOW
folder="$work/example"
mkdir -p "$HOME/.ai-core" "$folder/.ai-core" "$work/cache/7" "$work/bin"

failed=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}
when() { LC_ALL=C date -u -d "@$1" '+%a %d.%m. %H:%M' 2>/dev/null || LC_ALL=C date -u -r "$1" '+%a %d.%m. %H:%M'; }
iso() { LC_ALL=C date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || LC_ALL=C date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ'; }

# The board: its id and columns cached, its cards on two pages behind a fake gh
echo PVT_example7 > "$work/cache/7/project-id"
printf 'Status\tF1\t%s\tO%s\n' Backlog 1 Todo 2 'In progress' 3 Done 4 > "$work/cache/7/fields.tsv"
card() {  # card <number> <status> <priority> <state> <closed at> <parent> <sub-issues> <title> [body]
  printf '{"status":{"name":"%s"},"priority":%s,"content":{"number":%s,"title":"%s","state":"%s","closedAt":%s,"body":"%s","repository":{"nameWithOwner":"example-org/example-repo"},"parent":%s,"subIssuesSummary":{"total":%s}}}\n' \
    "$2" "$([ "$3" = - ] && echo null || echo "{\"name\":\"$3\"}")" "$1" "$8" "$4" \
    "$([ "$5" = - ] && echo null || echo "\"$(iso "$5")\"")" "${9:-}" \
    "$([ "$6" = - ] && echo null || echo "{\"number\":$6,\"repository\":{\"nameWithOwner\":\"example-org/example-repo\"}}")" "$7"
}
{
  card 1 'In progress' P1 OPEN - - 3 'Package: alpha' 'The alpha work.\nWorker: exa-sonnet-1\n'
  card 2 'In progress' P2 OPEN - 1 0 'Second'
  card 3 Todo P1 OPEN - 1 0 'Third'
  card 4 Done P2 CLOSED $((now - 7200)) 1 0 'Fourth'
  card 5 Todo P2 OPEN - - 1 'Package: beta'
  card 6 Done P2 CLOSED $((now - 3600)) 5 0 'Sixth'
  for n in 9 10 11 12 13 14 15 16 17 18 19 20; do card "$n" Done - CLOSED $((now - (n - 7) * 86400)) - 0 "Closed $n"; done
  echo '{"status":{"name":"Todo"},"priority":null,"content":{}}'
  echo 'after c2'
} > "$work/page1"
{
  card 7 Todo - OPEN - - 0 'Seventh'
  card 8 Done - OPEN - - 0 'Eighth'
} > "$work/page2"
cat > "$work/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *after=c2*)     cat "$work/page2" ;;
  *'items(first'*) cat "$work/page1" ;;
  *) echo "unexpected gh call: \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$work/bin/gh"
export PATH="$work/bin:$PATH"

# The team, the usage now and its history, and the transcripts of the folder's sessions
printf 'coordinator\topus\tmax\t1\nworker\tsonnet\tmax\t2\n' > "$folder/.ai-core/team.tsv"
printf '{"recorded_at":%s,"rate_limits":{"five_hour":{"used_percentage":25,"resets_at":%s},"seven_day":{"used_percentage":89,"resets_at":%s}}}\n' \
  "$now" $((now + 3600)) $((now + 432000)) > "$HOME/.ai-core/usage.json"
for row in "$((now - 10800)) 5 85" "$((now - 7200)) 15 87" "$now 25 89"; do
  set -- $row; echo "$1 $2 $((now + 3600)) $3 $((now + 432000))"
done > "$HOME/.ai-core/usage.log"
mkdir -p "$work/transcripts/$(printf '%s' "$folder" | sed 's/[^A-Za-z0-9]/-/g')"
answer() { printf '{"type":"assistant","cwd":"%s","message":{"id":"%s","usage":{"input_tokens":%s,"output_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s}}}\n' "$@"; }
{
  printf '{"type":"user","cwd":"%s"}\n' "$folder/.worktrees/example-repo/issue-4-fix"
  answer "$folder/.worktrees/example-repo/issue-4-fix" m1 100 50 10 1000
  answer "$folder/.worktrees/example-repo/issue-4-fix" m1 100 50 10 1000
  answer "$folder" m2 5000 0 0 0
  answer "$folder/.worktrees/example-repo/issue-6-add" m3 200 100 0 0
} > "$work/transcripts/$(printf '%s' "$folder" | sed 's/[^A-Za-z0-9]/-/g')/session.jsonl"

out="$(cd "$folder" && bash "$root/bin/status.sh" --project example-org/7 --issues 2>&1)"; rc=$?
line() { grep -m1 -F -- "$1" <<< "$out" | tr -s ' '; }
echo 'the head of the page'
check 'exit 0'        0 "$rc"
check 'the board'     "example · board example-org/7 · $(when "$now")" "$(sed -n 1p <<< "$out")"
check 'the usage'     "usage 5h 25 % (reset $(when $((now + 3600)))) · week 89 % (reset $(when $((now + 432000)))) · limit 92 %" "$(line 'usage ')"
check 'the pace'      'pace 1.0 issues a day over 14 days, 2 workers, shared evenly: too few packages name their worker' "$(line 'pace ')"
check 'the cost'      'cost an issue closed here raises the 5h window 10.0 % and the week 2.00 %' "$(line 'cost ')"
echo 'the tokens: an answer written twice counts once, an answer outside a worktree counts to no issue'
check 'the tokens'    'tokens 1k per issue, 300 of them fresh, not read from the cache (median of 2 closed issues)' "$(line 'tokens ')"
check 'the open work' 'open 6 issues · 2 packages, 1 ready to close · 2 outside packages' "$(line 'open ')"
echo 'the plan: the named package on its worker, the rest on the one that frees first, the week pausing both'
check 'the worker'    'exa-sonnet-1 sonnet max 0.5 issues a day' "$(line 'exa-sonnet-1' | sed 's/^ //')"
check 'its package'   "▸ example-repo#1 alpha 2 $(when "$now") $(when $((now + 7 * 86400)))" "$(line '▸ example-repo#1' | sed 's/^ //')"
check 'the rest'      "· outside packages 1 issue 1 $(when "$now") $(when $((now + 2 * 86400)))" "$(line '· outside packages' | sed 's/^ //')"
check 'the pause'     "PAUSES week $(when $((now + 2 * 86400))) until $(when $((now + 5 * 86400)))" "$(line 'PAUSES')"
check 'the end'       "DONE about $(when $((now + 7 * 86400))), an estimate from the pace of 14 days, the cost per issue and the pauses" "$(line 'DONE')"
check 'ready'         'CLOSE every sub-issue closed: example-repo#5' "$(line 'CLOSE')"
check 'open on Done'  'CHECK open on Done: example-repo#8' "$(line 'CHECK')"
echo 'every open issue, by package, in work order, the second page among them'
check 'a package'     'example-repo#1 alpha (2)' "$(line 'example-repo#1 alpha (' | sed 's/^ //')"
check 'nearest done first' 'example-repo#2 example-repo#3' "$(awk '/example-repo#1 alpha \(/ { on = 1; next } on && /^    / { printf "%s%s", sep, $2; sep = " "; next } on { exit }' <<< "$out")"
check 'outside'       'example-repo#8 example-repo#7' "$(awk '/^  outside packages/ { on = 1; next } on && /^    / { printf "%s%s", sep, $2; sep = " " }' <<< "$out")"

echo 'outside a repository with no board named: refused, naming --project'
refused="$(cd "$folder" && bash "$root/bin/status.sh" 2>&1)"; rc=$?
check 'exit 1'        1 "$rc"
check 'the line'      'error: outside a repository, name the board - status --project N' "$refused"

if [ "$failed" -gt 0 ]; then echo; echo "$out"; echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
