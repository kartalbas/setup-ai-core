#!/usr/bin/env bash
# What `status` prints for one board: the usage, the pace, what an issue costs of a window, the
# tokens an issue took, the plan of every worker with a pause where the week reaches the limit, and
# what is ready to close or sits on Done while open. The board has two pages, so paging is read.
# The transcripts carry an answer written twice (counted once), an answer outside a worktree
# (counted, as every session of the folder is) and one older than the day (not counted)
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
  card 21 Todo P2 OPEN - - 1 'Package: gamma' 'Worker: exa-hand-1\n'
  card 22 Todo P2 OPEN - 21 0 'Twenty-second'
  for n in 9 10 11 12; do card "$n" Done - CLOSED $((now - (n - 5) * 3600)) - 0 "Closed $n"; done
  for n in 13 14 15 16 17 18 19 20; do card "$n" Done - CLOSED $((now - (n - 7) * 86400)) - 0 "Closed $n"; done
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
# Claude Code writes the folder as the system spells it: on Windows C:/..., where Git Bash says /c/...
seen_as="$(cygpath -m "$folder" 2>/dev/null || echo "$folder")"
sessions="$work/transcripts/$(printf '%s' "$seen_as" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$sessions"
answer() { printf '{"type":"assistant","timestamp":"%s","cwd":"%s","message":{"id":"%s","usage":{"input_tokens":%s,"output_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s}}}\n' "$(iso "$1")" "${@:2}"; }
{
  printf '{"type":"user","cwd":"%s"}\n' "$seen_as/.worktrees/example-repo/issue-4-fix"
  answer $((now - 7200)) "$seen_as/.worktrees/example-repo/issue-4-fix" m1 100 50 10 1000
  answer $((now - 7200)) "$seen_as/.worktrees/example-repo/issue-4-fix" m1 100 50 10 1000
  answer $((now - 3600)) "$seen_as" m2 5000 0 0 0
  answer $((now - 1800)) "$seen_as/.worktrees/example-repo/issue-6-add" m3 200 100 0 0
  answer $((now - 2 * 86400)) "$seen_as" m4 99999 0 0 0
} > "$sessions/session.jsonl"

out="$(cd "$folder" && bash "$root/bin/status.sh" --project example-org/7 --issues 2>&1)"; rc=$?
line() { grep -m1 -F -- "$1" <<< "$out" | tr -s ' '; }
echo 'the head of the page'
check 'exit 0'        0 "$rc"
check 'the board'     "example · board example-org/7 · $(when "$now")" "$(sed -n 1p <<< "$out")"
check 'the usage'     "usage 5h 25 % (reset $(when $((now + 3600)))) · week 89 % (reset $(when $((now + 432000)))) · limit 92 %" "$(line 'usage ')"
check 'the pace'      'pace 6 issues closed in the last 24 hours, 1.0 a day over 14 days; 2 workers, shared evenly: too few packages name their worker' "$(line 'pace ')"
check 'the cost'      'cost an issue closed here raises the 5h window 10.0 % and the week 2.00 %' "$(line 'cost ')"
echo 'the tokens of the day: an answer written twice counts once, every session counts, an older answer does not'
check 'the tokens'    'tokens in 24 hours the sessions of this folder used 5k fresh and read 1k from the cache: 910 fresh and 167 from the cache per closed issue' "$(line 'tokens ')"
check 'the context'   'context 2k per answer on average, 5k the largest, over 3 answers in 24 hours' "$(line 'context ')"
check 'the open work' 'open 8 issues · 3 packages, 1 ready to close · 2 outside packages' "$(line 'open ')"
echo 'the plan: each named package on its worker, a session started by hand in place of a free lane, the rest on the one that frees first, the week pausing both'
check 'the worker'    'exa-sonnet-1 sonnet max 3.0 issues a day' "$(line 'exa-sonnet-1' | sed 's/^ //')"
check 'its package'   "▸ example-repo#1 alpha 2 $(when "$now") $(when $((now + 5 * 86400 + 28800)))" "$(line '▸ example-repo#1' | sed 's/^ //')"
check 'the hand-started session' 'exa-hand-1 a model team.tsv does not name 3.0 issues a day' "$(line 'exa-hand-1 ' | sed 's/^ //')"
check 'its package, as written' "▸ example-repo#21 gamma 1 $(when "$now") $(when $((now + 28800)))" "$(line '▸ example-repo#21' | sed 's/^ //')"
check 'the lanes stay the team' '' "$(line 'exa-sonnet-2')"
check 'the rest'      "· outside packages 1 issue 1 $(when $((now + 5 * 86400))) $(when $((now + 5 * 86400 + 28800)))" "$(line '· outside packages' | sed 's/^ //')"
check 'the pause'     "PAUSES week $(when $((now + 28800))) until $(when $((now + 5 * 86400)))" "$(line 'PAUSES')"
check 'the end'       "DONE about $(when $((now + 5 * 86400 + 28800))), an estimate from the pace of the last 24 hours, the cost per issue and the pauses" "$(line 'DONE')"
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
