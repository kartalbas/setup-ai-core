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
# The process list is read by the default view only, and through AI_CORE_PROCESSES there: a ps
# that refuses, as the one of Git for Windows refuses -A, proves --tokens never asks for it.
printf '#!/usr/bin/env bash\necho "ps: unknown option -- A" >&2; exit 1\n' > "$work/bin/ps"
chmod +x "$work/bin/ps"
export PATH="$work/bin:$PATH"

# The team, the usage now and its history, and the transcripts of the folder's sessions
printf 'coordinator\topus\tmax\t1\nworker\tsonnet\tmax\t2\n' > "$folder/.ai-core/team.tsv"
printf '{"recorded_at":%s,"rate_limits":{"five_hour":{"used_percentage":25,"resets_at":%s},"seven_day":{"used_percentage":89,"resets_at":%s}}}\n' \
  "$now" $((now + 3600)) $((now + 432000)) > "$HOME/.ai-core/usage.json"
for row in "$((now - 10800)) 1 83" "$((now - 7200)) 13 86" "$now 25 89"; do
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
# Another folder of the machine used as many fresh tokens in the same hours: it carries half the rise
mkdir -p "$work/transcripts/-elsewhere"
answer $((now - 3600)) /elsewhere o1 5460 0 0 0 > "$work/transcripts/-elsewhere/session.jsonl"

out="$(cd "$folder" && bash "$root/bin/status.sh" --project example-org/7 --issues 2>&1)"; rc=$?
line() { grep -m1 -F -- "$1" <<< "$out" | tr -s ' '; }
echo 'the head of the page'
check 'exit 0'        0 "$rc"
check 'the board'     "example · board example-org/7 · $(when "$now")" "$(sed -n 1p <<< "$out")"
check 'the usage'     "usage 5h 25 % (reset $(when $((now + 3600)))) · week 89 % (reset $(when $((now + 432000)))) · limit 92 %" "$(line 'usage ')"
check 'the pace'      'pace 6 issues closed in the last 24 hours, 1.0 a day over 14 days; 2 workers, shared evenly: too few packages name their worker' "$(line 'pace ')"
check 'the cost'      "cost this folder raises the 5h window 4.0 % and the week 1.00 % an hour, 50 % of the machine's fresh tokens; at the pace of 24 hours, 4.00 % of the week per issue closed here" "$(line 'cost ')"
echo 'the tokens of the day: an answer written twice counts once, every session counts, an older answer does not'
check 'the tokens'    'tokens in 24 hours the sessions of this folder used 5k fresh and read 1k from the cache: 910 fresh and 167 from the cache per closed issue' "$(line 'tokens ')"
check 'the context'   'context 2k per answer on average, 5k the largest, over 3 answers in 24 hours' "$(line 'context ')"
check 'the open work' 'open 8 issues · 3 packages, 1 ready to close · 2 outside packages' "$(line 'open ')"
echo 'the plan: each named package on its worker, a session started by hand in place of a free lane, the rest on the one that frees first, the week pausing both'
check 'the worker'    'exa-sonnet-1 sonnet max 3.0 issues a day' "$(line 'exa-sonnet-1' | sed 's/^ //')"
check 'its package'   "▸ example-repo#1 alpha 2 $(when "$now") $(when $((now + 5 * 86400 + 52200)))" "$(line '▸ example-repo#1' | sed 's/^ //')"
check 'the hand-started session' 'exa-hand-1 a model team.tsv does not name 3.0 issues a day' "$(line 'exa-hand-1 ' | sed 's/^ //')"
check 'its package, as written' "▸ example-repo#21 gamma 1 $(when "$now") $(when $((now + 5 * 86400 + 23400)))" "$(line '▸ example-repo#21' | sed 's/^ //')"
check 'the lanes stay the team' '' "$(line 'exa-sonnet-2')"
check 'the rest'      "· outside packages 1 issue 1 $(when $((now + 5 * 86400 + 23400))) $(when $((now + 5 * 86400 + 52200)))" "$(line '· outside packages' | sed 's/^ //')"
check 'the pause'     "PAUSES week $(when $((now + 5400))) until $(when $((now + 5 * 86400)))" "$(line 'PAUSES')"
check 'the end'       "DONE about $(when $((now + 5 * 86400 + 52200))), an estimate from the pace of the last 24 hours, the measured rise of the windows and the pauses" "$(line 'DONE')"
check 'ready'         'CLOSE every sub-issue closed: example-repo#5' "$(line 'CLOSE')"
check 'open on Done'  'CHECK open on Done: example-repo#8' "$(line 'CHECK')"
echo 'every open issue, by package, in work order, the second page among them'
check 'a package'     'example-repo#1 alpha (2)' "$(line 'example-repo#1 alpha (' | sed 's/^ //')"
check 'nearest done first' 'example-repo#2 example-repo#3' "$(awk '/example-repo#1 alpha \(/ { on = 1; next } on && /^    / { printf "%s%s", sep, $2; sep = " "; next } on { exit }' <<< "$out")"
check 'outside'       'example-repo#8 example-repo#7' "$(awk '/^  outside packages/ { on = 1; next } on && /^    / { printf "%s%s", sep, $2; sep = " " }' <<< "$out")"

echo 'without --tokens: the agents that run now, from the process list alone'
: > "$work/no-processes"
nothing="$(cd "$folder" && AI_CORE_PROCESSES="$work/no-processes" bash "$root/bin/status.sh" --project example-org/7 2>&1)"
tokens="$(cd "$folder" && bash "$root/bin/status.sh" --project example-org/7 --tokens 2>&1)"
check 'no agent runs: the pace and the forecast, as with --tokens' "$tokens" "$nothing"
check 'and they are there' 1 "$(grep -c '^pace ' <<< "$nothing")"
printf '%s\t%s\t%s\t%s\n' 100 1 '1-01:00:00' 'claude --resume exa-lead' 101 100 '05:00' 'bash run.sh' \
  102 101 '03:00' 'codex exec -m big-model -c model_reasoning_effort=high work on example-repo#1' \
  103 102 '02:00' 'agy -p nested child --model cheap-model --effort high' \
  104 1 '01:02:03' 'codex exec resume thread-w2 --json' 105 1 '10' 'sleep 30' 106 1 '01:00' 'git log agy -p' \
  107 1 '2-00:00:00' '/home/x/.local/bin/claude --chrome-native-host' \
  108 100 '01:00' 'node /usr/lib/node_modules/gemini-cli/bin/gemini.js -p check example-repo#3' \
  109 1 '05:00' 'agy' > "$work/processes"
view="$(cd "$folder" && AI_CORE_PROCESSES="$work/processes" bash "$root/bin/status.sh" --project example-org/7 2>&1)"; rc=$?
vline() { grep -m1 -F -- "$1" <<< "$view" | tr -s ' '; }
check 'exit 0'        0 "$rc"
check 'line 1: the time and the board counts' "example · board example-org/7 · $(when "$now") · Backlog 0 · Todo 5 · In progress 2 · Done 15" "$(sed -n 1p <<< "$view")"
check 'a session, named by its resume' '│ claude exa-lead │ 100 │ │ 1500 min │ │ session │' "$(vline '│ claude exa-lead ')"
check 'the runs it started, through a script too, newest first' '│ └ gemini │ 108 │ │ 1 min │ example-repo#3 │ run │' "$(vline '└ gemini')"
check 'with model and effort' '│ └ codex │ 102 │ big-model · high │ 3 min │ example-repo#1 │ run │' "$(vline '└ codex')"
check 'a run a run started' '│ └ agy │ 103 │ cheap-model · high │ 2 min │ │ run │' "$(vline '└ agy')"
check 'indented one step deeper' 1 "$(grep -c '^│     └ agy ' <<< "$view")"
check 'a run no agent started stands alone' '│ codex │ 104 │ │ 62 min │ │ resumed run │' "$(vline '│ codex ')"
check 'an agent CLI without a prompt is a session' '│ agy │ 109 │ │ 5 min │ │ session │' "$(vline '│ agy ')"
check 'in this order' '100 108 102 103 104 109' "$(awk -F'│' '$3 ~ /^ *[0-9]+ *$/ { printf "%s%s", sep, $3 + 0; sep = " " }' <<< "$view")"
check 'no helper, no tool word in another command' 'AGENTS 6 running: 1 claude, 1 gemini, 2 codex, 2 agy' "$(vline ' running: ')"
check 'no token lines' '' "$(vline 'pace ')"

echo 'outside a repository with no board named: refused, naming --project'
refused="$(cd "$folder" && bash "$root/bin/status.sh" 2>&1)"; rc=$?
check 'exit 1'        1 "$rc"
check 'the line'      'error: outside a repository, name the board - status --project N' "$refused"

if [ "$failed" -gt 0 ]; then echo; echo "$out"; echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
