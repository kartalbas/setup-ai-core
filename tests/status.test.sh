#!/usr/bin/env bash
# What `status` prints for one board: the usage, the pace, what an issue costs of a window, the
# tokens an issue took, and what is ready to close or sits on Done while open. The board has two pages, so paging is read.
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
  card 1 'In progress' P1 OPEN - - 3 'alpha' 'The alpha work.\n'
  card 2 'In progress' P2 OPEN - 1 0 'Second'
  card 3 Todo P1 OPEN - 1 0 'Third'
  card 4 Done P2 CLOSED $((now - 7200)) 1 0 'Fourth'
  card 5 Todo P2 OPEN - - 1 'beta'
  card 6 Done P2 CLOSED $((now - 3600)) 5 0 'Sixth'
  card 21 Todo P2 OPEN - - 1 'gamma'
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
# that refuses proves --tokens never asks for it.
printf '#!/usr/bin/env bash\necho "ps: unknown option -- A" >&2; exit 1\n' > "$work/bin/ps"
chmod +x "$work/bin/ps"
export PATH="$work/bin:$PATH"

# The usage now and its history, and the transcripts of the folder's sessions
printf '{"recorded_at":%s,"rate_limits":{"five_hour":{"used_percentage":25,"resets_at":%s},"seven_day":{"used_percentage":89,"resets_at":%s}}}\n' \
  "$now" $((now + 3600)) $((now + 432000)) > "$HOME/.ai-core/usage.json"
for row in "$((now - 10800)) 1 83" "$((now - 7200)) 13 86" "$now 25 89"; do
  set -- $row; echo "$1 $2 $((now + 3600)) $3 $((now + 432000))"
done > "$HOME/.ai-core/usage.log"
sessions="$work/transcripts/$(printf '%s' "$folder" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$sessions"
answer() { printf '{"type":"assistant","timestamp":"%s","cwd":"%s","message":{"id":"%s","usage":{"input_tokens":%s,"output_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s}}}\n' "$(iso "$1")" "${@:2}"; }
{
  printf '{"type":"user","cwd":"%s"}\n' "$folder/.worktrees/example-repo/issue-4-fix"
  answer $((now - 7200)) "$folder/.worktrees/example-repo/issue-4-fix" m1 100 50 10 1000
  answer $((now - 7200)) "$folder/.worktrees/example-repo/issue-4-fix" m1 100 50 10 1000
  answer $((now - 3600)) "$folder" m2 5000 0 0 0
  answer $((now - 1800)) "$folder/.worktrees/example-repo/issue-6-add" m3 200 100 0 0
  answer $((now - 2 * 86400)) "$folder" m4 99999 0 0 0
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
check 'the pace'      'pace 6 issues closed in the last 24 hours, 1.0 a day over 14 days' "$(line 'pace ')"
check 'the cost'      "cost this folder raises the 5h window 4.0 % and the week 1.00 % an hour, 50 % of the machine's fresh tokens; at the pace of 24 hours, 4.00 % of the week per issue closed here" "$(line 'cost ')"
echo 'the tokens of the day: an answer written twice counts once, every session counts, an older answer does not'
check 'the tokens'    'tokens in 24 hours the sessions of this folder used 5k fresh and read 1k from the cache: 910 fresh and 167 from the cache per closed issue' "$(line 'tokens ')"
check 'the context'   'context 2k per answer on average, 5k the largest, over 3 answers in 24 hours' "$(line 'context ')"
check 'the open work' 'open 8 issues · 3 epics, 1 ready to close · 2 outside epics' "$(line 'open ')"
echo 'no plan by worker and no forecast: the coordinator says who works on what'
check 'no plan'       0 "$(grep -cE '^(PLAN BY WORKER|PAUSES|DONE) ' <<< "$out" || true)"
check 'ready'         'CLOSE every sub-issue closed: example-repo#5' "$(line 'CLOSE')"
check 'open on Done'  'CHECK open on Done: example-repo#8' "$(line 'CHECK')"
echo 'every open issue, by epic, in work order, the second page among them'
check 'an epic'      'example-repo#1 alpha (2)' "$(line 'example-repo#1 alpha (' | sed 's/^ //')"
check 'nearest done first' 'example-repo#2 example-repo#3' "$(awk '/example-repo#1 alpha \(/ { on = 1; next } on && /^    / { printf "%s%s", sep, $2; sep = " "; next } on { exit }' <<< "$out")"
check 'outside'       'example-repo#8 example-repo#7' "$(awk '/^  outside epics/ { on = 1; next } on && /^    / { printf "%s%s", sep, $2; sep = " " }' <<< "$out")"

echo 'without --tokens: the agents that run now, from the process list alone'
: > "$work/no-processes"
# Claude Code's list of its sessions and the codex rollout files held open, through their
# stand-ins: the default view reads them with the process list
export AI_CORE_AGENTS="$work/no-agents" AI_CORE_ROLLOUTS="$work/no-rollouts"
: > "$AI_CORE_AGENTS"; : > "$AI_CORE_ROLLOUTS"
nothing="$(cd "$folder" && AI_CORE_PROCESSES="$work/no-processes" bash "$root/bin/status.sh" --project example-org/7 2>&1)"
tokens="$(cd "$folder" && bash "$root/bin/status.sh" --project example-org/7 --tokens 2>&1)"
check 'no agent runs: the pace and the forecast, as with --tokens' "$tokens" "$nothing"
check 'and they are there' 1 "$(grep -c '^pace ' <<< "$nothing")"
printf '%s\t%s\t%s\t%s\t%s\n' 100 1 '1-01:00:00' Ss 'claude --resume exa-lead' 101 100 '05:00' S 'bash run.sh' \
  102 101 '03:00' S 'codex exec -m big-model -c model_reasoning_effort=high work on example-repo#1' \
  103 102 '02:00' S 'agy -p nested child --model cheap-model --effort high' \
  104 1 '01:02:03' S 'codex exec resume thread-w2 --json' 105 1 '10' S 'sleep 30' 106 1 '01:00' S 'git log agy -p' \
  107 1 '2-00:00:00' S '/home/x/.local/bin/claude --chrome-native-host' \
  108 100 '01:00' R 'node /usr/lib/node_modules/gemini-cli/bin/gemini.js -p check example-repo#3' \
  109 1 '05:00' S 'agy' 110 1 '30:00' Ssl '/home/x/.local/bin/claude daemon run --origin transient' \
  111 110 '29:00' SNsl 'claude bg-pty-host --bg-pty-host /tmp/x.sock 200 50 -- /home/x/.local/share/claude/versions/2.1.289 --session-id 22222222-2222-2222-2222-222222222222' \
  112 111 '29:00' SNsl+ '/home/x/.local/share/claude/versions/2.1.289 --session-id 22222222-2222-2222-2222-222222222222 --name i1-sonnet5.5-low-100k-ab123 --model sonnet --effort low' \
  113 110 '40:00' SNsl+ 'claude bg-spare --bg-spare /tmp/x/spare/a1.claim.sock' \
  114 110 '20:00' SNsl+ 'claude bg-spare --bg-spare /tmp/x/spare/a2.claim.sock' \
  115 1 '50:00' Sl+ '/home/x/.local/bin/claude agents' \
  116 1 '3-00:00:00' Tl '/home/x/.local/bin/claude --resume old-lead' \
  > "$work/processes"
printf '%s\n' '[{"pid":100,"kind":"interactive","status":"busy","name":"exa-lead","sessionId":"11111111-1111-1111-1111-111111111111","id":null},' \
  '{"pid":112,"kind":"background","status":"idle","state":"blocked","name":"i1-sonnet5.5-low-100k-ab123","sessionId":"22222222-2222-2222-2222-222222222222","id":"22222222"},' \
  '{"pid":113,"kind":"background","status":"busy","state":"working","name":"r2-opus5.5-high-300k-cd456","cwd":"/home/x/.worktrees/shop/issue-4-fix-the-thing","sessionId":"33333333-3333-3333-3333-333333333333","id":"33333333"},' \
  '{"pid":116,"kind":"interactive","status":"busy","state":"working","name":"old-lead","sessionId":"55555555-5555-5555-5555-555555555555","id":null}]' > "$work/agents"
printf '%s\t%s\n' /proc/102/fd /home/x/.codex/sessions/2026/10/04/rollout-2026-10-04T11-52-48-01a106c2-71cd-7451-94ce-508f6229cd5b.jsonl \
  /proc/100/fd /home/x/.codex/sessions/2026/10/04/rollout-2026-10-04T11-00-00-01a10000-0000-7000-8000-000000000000.jsonl \
  /proc/104/fd /home/x/.ai-core/sessions/p30001-gpt6.1sol-xhigh-150k-cdc28.out > "$work/rollouts"
view="$(cd "$folder" && AI_CORE_PROCESSES="$work/processes" AI_CORE_AGENTS="$work/agents" AI_CORE_ROLLOUTS="$work/rollouts" bash "$root/bin/status.sh" --project example-org/7 2>&1)"; rc=$?
vline() { grep -m1 -F -- "$1" <<< "$view" | tr -s ' '; }
check 'exit 0'        0 "$rc"
check 'line 1: the time and the board counts' "example · board example-org/7 · $(when "$now") · Backlog 0 · Todo 5 · In progress 2 · Done 15" "$(sed -n 1p <<< "$view")"
check 'a session, named by its resume' '│ C exa-lead │ 100 │ │ 1500 min │ busy │ │ session │' "$(vline '│ C exa-lead ')"
check 'the runs it started, through a script too, newest first' '│ └ G gemini │ 108 │ │ 1 min │ │ example-repo#3 │ run │' "$(vline '└ G gemini')"
check 'with model and effort' '│ └ X codex │ 102 │ big-model · high │ 3 min │ │ example-repo#1 │ run │' "$(vline '└ X codex')"
check 'a run a run started' '│ └ A agy │ 103 │ cheap-model · high │ 2 min │ │ │ run │' "$(vline '└ A agy')"
check 'indented one step deeper' 1 "$(grep -c '^│     └ A agy ' <<< "$view")"
check 'a run no agent started stands alone' '│ X p30001-gpt6. │ 104 │ gpt6.1sol · xhigh │ 62 min │ │ │ resumed run │' "$(vline '│ X p30001-gpt6. ')"
check 'an agent CLI without a prompt is a session' '│ A agy │ 109 │ │ 5 min │ │ │ session │' "$(vline '│ A agy ')"
check 'a background session runs from the versioned binary' '│ C i1-sonnet5.5 │ 112 │ sonnet · low │ 29 min │ idle blocked │ │ session │' "$(vline '│ C i1-sonnet5.5 ')"
check 'its daemon and terminal host are no agents' 0 "$(grep -cE '│ 11[01] +│' <<< "$view" || true)"
check 'a claimed spare: name, model and effort from its name, the issue from its worktree' '│ C r2-opus5.5-h │ 113 │ opus5.5 · high │ 40 min │ busy working │ shop#4 at start │ session │' "$(vline '│ C r2-opus5.5')"
check 'a spare no session claimed and the agent list are no agents' 0 "$(grep -cE '│ 11[45] +│' <<< "$view" || true)"
check 'a stopped session is shown stopped' '│ C old-lead │ 116 │ │ stopped │ │ │ session │' "$(vline '│ C old-lead ')"
check 'in this order' '116 100 108 102 103 113 112 104 109' "$(awk -F'│' '$3 ~ /^ *[0-9]+ *$/ { printf "%s%s", sep, $3 + 0; sep = " " }' <<< "$view")"
check 'no helper, no tool word in another command, a stopped one apart' 'AGENTS 8 running: 3 claude (C), 1 gemini (G), 2 codex (X), 2 agy (A); 1 stopped' "$(vline ' running: ')"
check 'no token lines' '' "$(vline 'pace ')"
printf '%s\t%s\t%s\t%s\t%s\n' 116 1 '3-00:00:00' Tl '/home/x/.local/bin/claude --resume old-lead' > "$work/stopped-only"
only="$(cd "$folder" && AI_CORE_PROCESSES="$work/stopped-only" AI_CORE_AGENTS="$work/agents" AI_CORE_ROLLOUTS="$work/rollouts" bash "$root/bin/status.sh" --project example-org/7 2>&1)"
check 'only a stopped one: none running' 'AGENTS 0 running; 1 stopped' "$(grep -m1 '^AGENTS  *[0-9]' <<< "$only" | tr -s ' ')"
printf '%s\t%s\t%s\t%s\t%s\n' 117 1 '10:00' 'SNsl+' 'claude bg-spare --bg-spare /tmp/x/spare/a3.claim.sock' \
  118 1 '10:00' 'SNsl+' 'claude bg-spare --bg-spare /tmp/x/spare/a4.claim.sock' \
  119 1 '10:00' 'SNsl+' 'claude bg-spare --bg-spare /tmp/x/spare/a5.claim.sock' > "$work/unversioned"
# A name leads with the letter of its phase: p, i, r or t. Any other letter, the l of the names
# before the phases had one among them, is no worker's name and carries no model
printf '%s\n' '[{"pid":117,"kind":"background","status":7,"state":["idle"],"name":"t3-sonnet-high-200k-ef789","cwd":"/home/x/repos","sessionId":"44444444-4444-4444-4444-444444444444","id":"44444444"},' \
  '{"pid":118,"kind":"background","status":7,"state":["idle"],"name":"i4-opus5.5-xhigh-300k-ab001","cwd":"/home/x/repos","sessionId":"66666666-6666-6666-6666-666666666666","id":"66666666"},' \
  '{"pid":119,"kind":"background","status":7,"state":["idle"],"name":"l5-opus5.5-high-150k-ab002","cwd":"/home/x/repos","sessionId":"77777777-7777-7777-7777-777777777777","id":"77777777"}]' > "$work/unversioned-agents"
plain="$(cd "$folder" && AI_CORE_PROCESSES="$work/unversioned" AI_CORE_AGENTS="$work/unversioned-agents" AI_CORE_ROLLOUTS="$work/rollouts" bash "$root/bin/status.sh" --project example-org/7 2>&1)"
check 'a name without a version: its model and effort' '│ C t3-sonnet-hi │ 117 │ sonnet · high │ 10 min │ │ │ session │' "$(grep -m1 -F '│ C t3-sonnet' <<< "$plain" | tr -s ' ')"
check 'a build: its model and effort from its name' '│ C i4-opus5.5-x │ 118 │ opus5.5 · xhigh │ 10 min │ │ │ session │' "$(grep -m1 -F '│ C i4-opus' <<< "$plain" | tr -s ' ')"
check 'a name led by no phase letter: no model' '│ C l5-opus5.5-h │ 119 │ │ 10 min │ │ │ session │' "$(grep -m1 -F '│ C l5-opus' <<< "$plain" | tr -s ' ')"

echo 'the command that reaches each agent, from what its CLI reports'
reach() { awk '/^REACH$/ { on = 1; next } on' <<< "$1" | grep -m1 -E -- "^  $2 " | tr -s ' ' | sed 's/^ //'; }
check 'an interactive session: resume it, a rollout it holds changes nothing' '100 C exa-lead claude --resume 11111111-1111-1111-1111-111111111111' "$(reach "$view" 100)"
check 'a background session: attach to it' '112 C i1-sonnet5.5-low-100k-ab123 claude attach 22222222' "$(reach "$view" 112)"
check 'a codex process: the rollout it holds open' '102 X codex codex resume 01a106c2-71cd-7451-94ce-508f6229cd5b' "$(reach "$view" 102)"
check 'a codex process that holds none: a dash' '104 X p30001-gpt6.1sol-xhigh-150k-cdc28 —' "$(reach "$view" 104)"
check 'an agent its CLI says nothing about: a dash' '109 A agy —' "$(reach "$view" 109)"
check 'every agent, in the order of the table' '116 100 108 102 103 113 112 104 109' "$(awk '/^REACH$/ { on = 1; next } on && /^  [0-9]/ { printf "%s%s", sep, $1; sep = " " }' <<< "$view")"
echo 'claude agents --json failed' > "$work/bad-agents"
broken="$(cd "$folder" && AI_CORE_PROCESSES="$work/processes" AI_CORE_AGENTS="$work/bad-agents" AI_CORE_ROLLOUTS="$work/rollouts" bash "$root/bin/status.sh" --project example-org/7 2>&1)"
check 'a list that failed is shown, not swallowed' 'claude agents --json gave no list: claude agents --json failed' "$(grep -m1 'gave no list' <<< "$broken" | sed 's/^ *//')"
check 'and no command is guessed' '100 C claude —' "$(reach "$broken" 100)"
# Where no stand-in names the rollouts, status asks find, which exits 1 on the processes it may
# not read; what it found still reaches the page. Without /proc there is nothing to ask.
mkdir -p "$work/findbin"
cat > "$work/findbin/find" <<'STUB'
#!/usr/bin/env bash
# It stands in for the read of /proc only; the board cache's age is asked of the real find
[ "$1" = /proc ] || PATH="${PATH#*:}" exec find "$@"
printf '%s\t%s\n' /proc/104/fd /x/rollout-2026-10-04T12-00-00-01a10444-0000-7000-8000-000000000444.jsonl
exit 1
STUB
chmod +x "$work/findbin/find"
found="$(cd "$folder" && PATH="$work/findbin:$PATH" AI_CORE_PROCESSES="$work/processes" AI_CORE_AGENTS="$work/agents" AI_CORE_ROLLOUTS='' bash "$root/bin/status.sh" --project example-org/7 2>&1)"; rc=$?
check 'a find that exits 1 stops nothing' 0 "$rc"
if [ -d /proc ]; then held='104 X codex codex resume 01a10444-0000-7000-8000-000000000444'; else held='104 X codex —'; fi
check 'and what it found reaches the page' "$held" "$(reach "$found" 104)"

echo 'outside a repository with no board named: refused, naming --project'
refused="$(cd "$folder" && bash "$root/bin/status.sh" 2>&1)"; rc=$?
check 'exit 1'        1 "$rc"
check 'the line'      'error: outside a repository, name the board - status --project N' "$refused"

echo 'the testing cards and the worktrees the sweep keeps, read from git'
# A second board in a folder of its own: its column after implementing and review is testing, and
# its repository has release tags of two environments and four issue worktrees
live="$work/live"; mkdir -p "$live/.ai-core" "$work/cache/8"
# status spells the folder as node resolves it; the expectation does too
shown="$(node -e 'process.stdout.write(require("path").resolve(process.argv[1]))' "$live")"
printf 'LIVE_TAGS="prod=deploy/prod/* test=deploy/test/*"\nPROOF_HOURS=24\n' > "$live/.ai-core/config.env"
echo PVT_example8 > "$work/cache/8/project-id"
printf 'Status\tF1\t%s\tO%s\n' Todo 1 implementing 2 review 3 testing 4 Done 5 > "$work/cache/8/fields.tsv"
# #38 is a card of another organisation's repository of the same name: the local clone is not its
{ for n in 37 35 34 33 32 31; do card "$n" testing P1 OPEN - - 0 "Card $n"; done; card 36 implementing P1 OPEN - - 0 'Card 36'; card 39 review P1 OPEN - - 0 'Card 39'
  card 38 testing P1 OPEN - - 0 'Card 38' | sed 's#example-org/example-repo#other-org/example-repo#g'; } > "$work/page8"
cat > "$work/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *PVT_example8*)  cat "$work/page8" ;;
  *after=c2*)      cat "$work/page2" ;;
  *'items(first'*) cat "$work/page1" ;;
  *) echo "unexpected gh call: \$*" >&2; exit 1 ;;
esac
EOF
commit_at() {  # commit_at <dir> <seconds before now> <subject>: a commit of one new file, dated
  echo "$3" > "$1/$(( $2 )).txt"; git -C "$1" add -A
  GIT_AUTHOR_DATE="@$((now - $2)) +0000" GIT_COMMITTER_DATE="@$((now - $2)) +0000" \
    git -C "$1" -c user.name=check -c user.email=check@localhost commit -q -m "$3"
}
# The origin is named like a repository on GitHub, because a clone is found by its origin
origin="$work/remote/example-org/example-repo.git"
git init -q --bare "$origin"; git init -q "$work/seed"; git -C "$work/seed" checkout -q -b master
commit_at "$work/seed" 144000 'Start'
commit_at "$work/seed" 108000 'Land the first (#31)'; git -C "$work/seed" tag deploy/prod/1; git -C "$work/seed" tag deploy/test/1
# A promotion an hour ago: an annotated tag of its own date, first by name and last by date
GIT_COMMITTER_DATE="@$((now - 3600)) +0000" git -C "$work/seed" -c user.name=check -c user.email=check@localhost tag -a -m promoted deploy/prod/0.9
commit_at "$work/seed" 100800 'Land the second (#32)'; git -C "$work/seed" tag deploy/prod/2
commit_at "$work/seed" 93600 'Land the third (#33)'; git -C "$work/seed" tag deploy/test/3
commit_at "$work/seed" 7200 'Land the seventh (#37)'; git -C "$work/seed" tag deploy/test/4
commit_at "$work/seed" 3600 'Land the fourth (#34)'
commit_at "$work/seed" 2400 'Docs, see other-org/example-repo#33'
commit_at "$work/seed" 1800 'Mention another issue only (#310)'
git -C "$work/seed" push -q "$origin" master --tags
git -C "$origin" symbolic-ref HEAD refs/heads/master
repo="$live/example-repo"; git clone -q "$origin" "$repo"
trees="$live/.worktrees/example-repo"
git -C "$repo" worktree add -q -b issue-41-old "$trees/issue-41-old" origin/master; commit_at "$trees/issue-41-old" 259200 'Old work (#41)'
git -C "$repo" worktree add -q -b issue-42-changed "$trees/issue-42-changed" deploy/prod/1; echo half > "$trees/issue-42-changed/half.txt"
touch -d "@$((now - 108000))" "$trees/issue-42-changed/half.txt"
# An old base with a change made now is worked in, not left
git -C "$repo" worktree add -q -b issue-45-fresh "$trees/issue-45-fresh" deploy/prod/1; echo now > "$trees/issue-45-fresh/now.txt"
git -C "$repo" worktree add -q -b issue-43-young "$trees/issue-43-young" origin/master; commit_at "$trees/issue-43-young" 7201 'Young work (#43)'
git -C "$repo" worktree add -q -b issue-44-landed "$trees/issue-44-landed" origin/master; commit_at "$trees/issue-44-landed" 259201 'Landed work (#44)'
git -C "$trees/issue-44-landed" push -q origin HEAD:master; git -C "$repo" fetch -q
# The clone lacks a tag origin has: only status's own fetch brings it
git -C "$repo" tag -d deploy/prod/2 >/dev/null
: > "$work/no-agents"
page="$(cd "$live" && AI_CORE_PROCESSES="$work/no-processes" AI_CORE_AGENTS="$work/no-agents" AI_CORE_ROLLOUTS="$work/no-agents" bash "$root/bin/status.sh" --project example-org/8 2>&1)"; rc=$?
check 'exit 0' 0 "$rc"
check 'the testing line' 'TESTING 7 cards in testing: 2 live on prod, 2 live on test only, 1 not live, 1 without a landing commit, 1 without a checkout' "$(grep '^TESTING' <<< "$page")"
check 'live on prod, past PROOF_HOURS too' "  🟢 $(printf '%-26s' example-repo#31) live on prod since 30 h (deploy/prod/1)  Card 31" "$(grep 'example-repo#31 ' <<< "$page")"
check 'live on prod' "  🟢 $(printf '%-26s' example-repo#32) live on prod since 28 h (deploy/prod/2)  Card 32" "$(grep 'example-repo#32 ' <<< "$page")"
check 'on test only past PROOF_HOURS: overdue' "  🔴 $(printf '%-26s' example-repo#33) live on test since 26 h (deploy/test/3)  Card 33" "$(grep 'example-repo#33 ' <<< "$page")"
check 'on test only within PROOF_HOURS: due' "  🟡 $(printf '%-26s' example-repo#37) live on test since 2 h (deploy/test/4)  Card 37" "$(grep 'example-repo#37 ' <<< "$page")"
check 'not live' '  ⏸ not live: example-repo#34' "$(grep 'not live:' <<< "$page")"
check 'no landing commit' '  ⏸ no commit on the default branch names it: example-repo#35' "$(grep 'names it:' <<< "$page")"
check 'another organisation'"'"'s repository of the same name has no checkout here' "  ⏸ no checkout of its repository in $shown: other-org/example-repo#38" "$(grep 'no checkout' <<< "$page")"
check 'the live cards in order: the first environment, then the longest live' '31 32 33 37' "$(grep -E '^  (🟢|🟡|🔴) ' <<< "$page" | grep -oE 'example-repo#[0-9]+' | sed 's/.*#//' | tr '\n' ' ' | sed 's/ $//')"
check 'and the trees, the oldest first' '41 42' "$(awk '/^TREES/ { on = 1; next } on && /^  example-repo#/ { sub(/^  example-repo#/, ""); print $1 }' <<< "$page" | tr '\n' ' ' | sed 's/ $//')"
check 'a worktree changed a moment ago is not listed' '' "$(grep 'example-repo#45' <<< "$page")"
check 'a card in implementing is not listed' '' "$(grep 'example-repo#36' <<< "$page")"
check 'nor one in review' '' "$(grep 'example-repo#39' <<< "$page")"
check 'the trees line' 'TREES   2 worktrees the sweep keeps, older than a day:' "$(grep '^TREES' <<< "$page")"
check 'unlanded and old' "  $(printf '%-26s' example-repo#41)   3 d  has work origin/master does not have yet" "$(grep 'example-repo#41' <<< "$page")"
check 'with changes' "  $(printf '%-26s' example-repo#42)  30 h  has changes" "$(grep 'example-repo#42' <<< "$page")"
check 'young and landed ones are not listed' '' "$(grep -E 'example-repo#4[34]' <<< "$page")"
sed 's/^LIVE_TAGS=.*$//' "$live/.ai-core/config.env" > "$live/.ai-core/config.tmp" && mv "$live/.ai-core/config.tmp" "$live/.ai-core/config.env"
bare="$(cd "$live" && AI_CORE_PROCESSES="$work/no-processes" AI_CORE_AGENTS="$work/no-agents" AI_CORE_ROLLOUTS="$work/no-agents" bash "$root/bin/status.sh" --project example-org/8 2>&1)"
check 'without LIVE_TAGS, the testing line' 'TESTING 7 cards in testing: 5 landed, 1 without a landing commit, 1 without a checkout' "$(grep '^TESTING' <<< "$bare")"
check 'and why' '  LIVE_TAGS in .ai-core/config.env names no environment, so where the work is live is not read' "$(grep 'names no environment' <<< "$bare")"
check 'the landed cards, none called not live' '  ⏸ landed: example-repo#37 example-repo#34 example-repo#33 example-repo#32 example-repo#31|' "$(grep '⏸ landed:' <<< "$bare")|$(grep 'not live' <<< "$bare")"
printf 'LIVE_TAGS="prod=landed"\n' > "$live/.ai-core/config.env"
landed="$(cd "$live" && AI_CORE_PROCESSES="$work/no-processes" AI_CORE_AGENTS="$work/no-agents" AI_CORE_ROLLOUTS="$work/no-agents" bash "$root/bin/status.sh" --project example-org/8 2>&1)"
check 'LIVE_TAGS "prod=landed": every landed card is live on prod' 'TESTING 7 cards in testing: 5 live on prod, 0 not live, 1 without a landing commit, 1 without a checkout' "$(grep '^TESTING' <<< "$landed")"
check 'from its landing, named as such' yes "$(grep -qE "^  🟢 example-repo#32 +live on prod since .+ \(landed on origin/master\)  Card 32$" <<< "$landed" && echo yes || echo no)"
check 'and no environment is missing' '' "$(grep 'names no environment' <<< "$landed")"
printf 'LIVE_TAGS="oops prod=deploy/prod/* test=deploy/test/*"\nPROOF_HOURS=1\n' > "$live/.ai-core/config.env"
short="$(cd "$live" && AI_CORE_PROCESSES="$work/no-processes" AI_CORE_AGENTS="$work/no-agents" AI_CORE_ROLLOUTS="$work/no-agents" bash "$root/bin/status.sh" --project example-org/8 2>&1)"
check 'PROOF_HOURS is read: two hours on test are overdue at one' "  🔴 $(printf '%-26s' example-repo#37) live on test since 2 h (deploy/test/4)  Card 37" "$(grep 'example-repo#37 ' <<< "$short")"
check 'a word of LIVE_TAGS that is no environment is named' "  LIVE_TAGS has 'oops', which is no <environment>=<tag pattern>; it is left out" "$(grep "LIVE_TAGS has" <<< "$short")"
git -C "$repo" remote set-url origin "$work/gone/example-org/example-repo.git"
gone="$(cd "$live" && AI_CORE_PROCESSES="$work/no-processes" AI_CORE_AGENTS="$work/no-agents" AI_CORE_ROLLOUTS="$work/no-agents" bash "$root/bin/status.sh" --project example-org/8 2>&1)"
git -C "$repo" remote set-url origin "$origin"
check 'a fetch that fails says what git said' yes "$(grep -q '^  fetching origin of example-org/example-repo failed: .*; read from the refs its clone had$' <<< "$gone" && echo yes || echo no)"
check 'and the cards are still read from the clone' "  🔴 $(printf '%-26s' example-repo#33) live on test since 26 h (deploy/test/3)  Card 33" "$(grep 'example-repo#33 ' <<< "$gone")"
check 'a sweep that cannot run is named' yes "$(grep -q '^  example-repo: the sweep could not run: could not reach origin' <<< "$gone" && echo yes || echo no)"

# --- environments delivered by a project's own reader, in the testing block -------------------------------
#
# A project folder of its own, its board 9, and these repositories, each a clone of an origin named like one on
# GitHub (Node finds a clone by its origin):
#   engine   LIVE_TAGS "prod=command qa=command", a reader of its own; commits e1 to e4 and e5, which names #11
#   engine2  "live=command prod=command"       engine3  "stage=command Prod=command"
#   tagged   no LIVE_TAGS of its own: its cards are read by the caller's list, prod and test, as before
# The readers answer what the test planted for an environment, with commits of the clone; a card's landing is a
# comment of its issue, as GitHub gives it, behind a stand-in gh that writes down every call it gets.
echo 'a repository whose LIVE_TAGS says command: its cards are read by the landing and the delivery, every other card as before'
cmd="$work/cmd"; mkdir -p "$cmd/.ai-core" "$work/cache/9" "$work/ctx" "$work/answers" "$work/remote/example-org"
export CMD_WORK="$work"
shown_cmd="$(node -e 'process.stdout.write(require("path").resolve(process.argv[1]))' "$cmd")"
echo PVT_example9 > "$work/cache/9/project-id"
printf 'Status\tF1\t%s\tO%s\n' Todo 1 implementing 2 review 3 testing 4 Done 5 > "$work/cache/9/fields.tsv"
: > "$work/no-agents9"; : > "$work/no-processes9"
cmd_repo() {  # cmd_repo <name>: an origin and its seed, and its clone once the commits are made: cmd_clone <name> <LIVE_TAGS or empty> [command]
  git init -q --bare "$work/remote/example-org/$1.git"; git init -q "$work/seed-$1"; git -C "$work/seed-$1" checkout -q -b master
}
cmd_clone() {
  git -C "$work/seed-$1" push -q "$work/remote/example-org/$1.git" master --tags
  git -C "$work/remote/example-org/$1.git" symbolic-ref HEAD refs/heads/master
  git clone -q "$work/remote/example-org/$1.git" "$cmd/$1"
  mkdir -p "$cmd/$1/.ai-core" "$cmd/$1/tools"
  printf 'LIVE_TAGS="%s"\n' "$2" > "$cmd/$1/.ai-core/config.env"
  if [ -n "${3:-}" ]; then
    printf 'LIVE_RELEASE_COMMAND="tools/read"\n' >> "$cmd/$1/.ai-core/config.env"
    cat > "$cmd/$1/tools/read" <<'READER'
#!/usr/bin/env bash
# the planted reader: the answer the test wrote for the environment, null where it wrote none, a refusal where it says so
echo "$PWD|$#|$1|$2" >> "$CMD_WORK/reader-calls.log"
slug="${1##*/}"
[ -e "$CMD_WORK/answers/$slug.fail" ] && { echo "the registry is unreachable" >&2; exit 3; }
if [ -f "$CMD_WORK/answers/$slug-$2.json" ]; then cat "$CMD_WORK/answers/$slug-$2.json"; else echo null; fi
READER
    chmod +x "$cmd/$1/tools/read"
  fi
}
answer() {  # answer <repository name> <environment> <commit> <seconds ago> <source>
  printf '{"repository":"example-org/%s","environment":"%s","commit":"%s","releasedAt":"%s","source":"%s"}\n' "$1" "$2" "$3" "$(iso $((now - $4)))" "$5" > "$work/answers/$1-$2.json"
}
head_of() { git -C "$work/seed-$1" rev-parse HEAD; }
cmd_repo engine
commit_at "$work/seed-engine" 90000 'Land one'; e1="$(head_of engine)"
commit_at "$work/seed-engine" 80000 'Land two'; e2="$(head_of engine)"
commit_at "$work/seed-engine" 70000 'Land three'; e3="$(head_of engine)"
commit_at "$work/seed-engine" 60000 'Land four'; e4="$(head_of engine)"
commit_at "$work/seed-engine" 50000 'Rework #11'
cmd_clone engine 'prod=command qa=command' command
cmd_repo engine2; commit_at "$work/seed-engine2" 90000 'Land f'; f1="$(head_of engine2)"; cmd_clone engine2 'live=command prod=command' command
cmd_repo engine3; commit_at "$work/seed-engine3" 90000 'Land g'; g1="$(head_of engine3)"; cmd_clone engine3 'stage=command Prod=command' command
cmd_repo tagged
commit_at "$work/seed-tagged" 140000 'Start'
commit_at "$work/seed-tagged" 130000 'Land the first (#1)'
commit_at "$work/seed-tagged" 120000 'Land #12'
commit_at "$work/seed-tagged" 110000 'Carry the work

Carries example-org/tagged#40, a bare #41 and other-org/tagged#42 is not it.'
commit_at "$work/seed-tagged" 105000 'Docs, see other-org/tagged#43'
git -C "$work/seed-tagged" tag deploy/test/1
commit_at "$work/seed-tagged" 100000 'Rework #12'
cmd_clone tagged ''
printf 'LIVE_TAGS="prod=deploy/prod/* test=deploy/test/*"\nPROOF_HOURS=24\n' > "$cmd/.ai-core/config.env"
answer engine prod "$e1" 7200 'registry release 7'
answer engine qa "$e3" 3600 'registry release 9'
answer engine2 prod "$f1" 5400 'registry release 3'
answer engine3 Prod "$g1" 5400 'registry release 4'

cmd_card() { card "$1" testing P1 OPEN - - 0 "$3" | sed "s#example-org/example-repo#example-org/$2#g"; }   # cmd_card <number> <repository name> <title>
member_landing() {  # member_landing <ISO time> <commit> [landing repository]: a record of a landing, written by a member
  printf '{"created_at":"%s","author_association":"MEMBER","body":"Landed on master%s:\\n\\n- %s Its subject"}' "$1" "${3:+ of $3}" "$(printf '%s' "$2" | cut -c1-7)"
}
chatter() {  # chatter <author association> <count>: comments of no consequence
  local i out=""; for i in $(seq 1 "$2"); do out="$out${out:+,}{\"created_at\":\"2026-09-1${i:0:1}T10:00:0${i:1:1}Z\",\"author_association\":\"$1\",\"body\":\"talk $i\"}"; done; printf '%s' "$out"
}
context() { printf '[%s]\n' "$3" > "$work/ctx/$1-$2.json"; }   # context <repository name> <number> <comments, separated by a comma>
reopened() { printf '%s\n' "$3" > "$work/ctx/$1-$2.reopened"; }
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CMD_WORK/calls.log"
case "$*" in
  *PVT_example9*) cat "$CMD_WORK/page9" ;;
  *"repos/"*"/issues/"*"/comments"*)
    slug="$(printf '%s\n' "$@" | grep -m1 '^repos/' | sed 's#^repos/[^/]*/\([^/]*\)/issues/\([0-9]*\)/comments$#\1-\2#')"
    [ -e "$CMD_WORK/ctx/$slug.refuse-comments" ] && { echo "HTTP 502: bad gateway" >&2; exit 1; }
    cat "$CMD_WORK/ctx/$slug.json" 2>/dev/null || echo '[]' ;;
  *"timelineItems(last:1"*)
    slug="$(printf '%s\n' "$@" | sed -n 's/^n=//p')-$(printf '%s\n' "$@" | sed -n 's/^i=//p')"
    [ -e "$CMD_WORK/ctx/$slug.refuse-reopened" ] && { echo "HTTP 502: bad gateway" >&2; exit 1; }
    at="$(cat "$CMD_WORK/ctx/$slug.reopened" 2>/dev/null || true)"
    prog=""; prev=""; for a in "$@"; do [ "$prev" = "--jq" ] && prog="$a"; prev="$a"; done
    jq -rn --arg at "$at" "$(printf '{data:{repository:{issue:{reopened:{nodes:(if $at == "" then [] else [{createdAt:$at}] end)}}}}} | %s' "$prog")" ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$work/bin/gh"
run_status() {  # run_status [argument...]: the status of board 9, its page in $page and its exit status in $rc
  : > "$work/calls.log"; : > "$work/reader-calls.log"
  page="$(cd "$cmd" && AI_CORE_PROCESSES="$work/no-processes9" AI_CORE_AGENTS="$work/no-agents9" AI_CORE_ROLLOUTS="$work/no-agents9" bash "$root/bin/status.sh" --project example-org/9 "$@" 2>&1)"; rc=$?
}
reads() { grep -c "issues/.*/comments\|timelineItems" "$work/calls.log" || true; }
line_of() { grep -F "$1" <<< "$page" || true; }

echo 'the testing line counts each card by the list it was read against: first or later environment by its own name, zero buckets, and the categories add up'
{ cmd_card 1 engine 'A1 is live on its first environment'; cmd_card 4 engine 'A4 landed after what is delivered'; cmd_card 1 engine2 'B1 on a later environment'; cmd_card 1 engine3 'C1 on a later environment, spelled Prod'
  cmd_card 1 tagged 'L1 is read by the caller'; cmd_card 2 tagged 'L2 has no commit'; cmd_card 6 engine 'N1 has no landing record'; cmd_card 1 lost 'M1 has no clone'; cmd_card 5 engine 'U1 cannot be read'; } > "$work/page9"
context engine 1 "$(member_landing 2026-09-01T10:00:00Z "$e1")"
context engine 4 "$(member_landing 2026-09-01T10:00:00Z "$e4")"
context engine2 1 "$(member_landing 2026-09-01T10:00:00Z "$f1")"
context engine3 1 "$(member_landing 2026-09-01T10:00:00Z "$g1")"
context tagged 1 ''; context tagged 2 ''; context engine 6 ''; context lost 1 ''
touch "$work/ctx/engine-5.refuse-comments"
run_status
check 'exit 1: a card could not be read' 1 "$rc"
check 'the header: live buckets by exact name and place, the caller list first, then the clone lists in the order of their repositories, and the rest, adding up to 9' \
  'TESTING 9 cards in testing: 1 live on prod, 1 live on test only, 0 live on qa only, 0 live on live, 1 live on prod only, 0 live on stage, 1 live on Prod only, 1 not live, 2 without a landing, 1 without a checkout, 1 unknown' "$(grep '^TESTING' <<< "$page")"
check 'the first environment of a clone list is green, with what the reader inspected and when' \
  "  🟢 $(printf '%-26s' engine#1) live on prod since 2 h (registry release 7, $(iso $((now - 7200))))  A1 is live on its first environment" "$(line_of 'engine#1 ')"
check 'a later one of its own list is yellow, and within PROOF_HOURS' "  🟡 $(printf '%-26s' engine2#1) live on prod since 1 h (registry release 3, $(iso $((now - 5400))))  B1 on a later environment" "$(line_of 'engine2#1 ')"
check 'the same word spelled otherwise is another environment' "  🟡 $(printf '%-26s' engine3#1) live on Prod since 1 h (registry release 4, $(iso $((now - 5400))))  C1 on a later environment, spelled Prod" "$(line_of 'engine3#1 ')"
check 'a card of a clone that sets no list of its own is read by the caller'"'"'s list' "yes" "$(grep -qE "^  🔴 tagged#1 +live on test since 2[0-9] h \(deploy/test/1\)  L1 is read by the caller$" <<< "$page" && echo yes || echo no)"
check 'a card no commit names, a card with no landing record, a card without a clone, and a card that could not be read are each named' \
  "  ⏸ not live: engine#4
  ⏸ no commit on the default branch names it: tagged#2
  ⏸ no landing record of the issue names its work: engine#6
  ⏸ no checkout of its repository in $shown_cmd: lost#1
  ❓ unknown example-org/engine#5: error: cannot read the comments of example-org/engine#5 - gh exited 1" \
  "$(grep -E '^  (⏸|❓) ' <<< "$page" | sed 's/, and answered: .*//')"
check 'one read of the tracker per card, two requests for a card of one page: the comments and the last reopening, and none for the card that could not be asked' \
  "17" "$(reads)"
check 'each reader was started once in its clone with two arguments, the same one for both environments of a card that waits' \
  "$cmd/engine|2|example-org/engine|prod" "$(grep -m1 '^'"$cmd"'/engine|' "$work/reader-calls.log")"
rm -f "$work/ctx/engine-5.refuse-comments"

echo 'with the caller'"'"'s list empty, a card of it is landed and the header says so'
printf 'PROOF_HOURS=24\n' > "$cmd/.ai-core/config.env"
{ cmd_card 1 engine 'A1'; cmd_card 1 tagged 'L1'; } > "$work/page9"
run_status
check 'a mixed header counts the cards landed with no environment, and the rest' \
  'TESTING 2 cards in testing: 1 live on prod, 0 live on qa only, 1 landed, 0 not live, 0 without a landing' "$(grep '^TESTING' <<< "$page")"
check 'and exits 0 where nothing is unknown' 0 "$rc"
printf 'LIVE_TAGS="prod=deploy/prod/* test=deploy/test/*"\nPROOF_HOURS=24\n' > "$cmd/.ai-core/config.env"

echo 'the landing record the issue holds decides, not the newest commit that names the issue: in a clone that declares command only'
{ cmd_card 3 tagged 'X1 of a tagged repository, landed in the engine'; cmd_card 11 engine 'H1 has a newer commit naming it'; cmd_card 12 tagged 'H1 legacy: the newest commit names it after its release'
  cmd_card 12 engine 'H2 no comment'; cmd_card 13 engine 'H3 a stranger wrote the record'; cmd_card 14 engine 'H4 reopened after its record'; cmd_card 15 engine 'H5 a new record after the reopening'
  cmd_card 16 engine 'H6a the record is outside the last 50'; cmd_card 17 engine 'H6b the record is inside the last 50'; cmd_card 18 engine 'H7 landed in a repository with no clone'; } > "$work/page9"
context tagged 3 "$(member_landing 2026-09-01T10:00:00Z "$e1" example-org/engine)"
context engine 11 "$(member_landing 2026-09-01T10:00:00Z "$e1")"
context tagged 12 ''
context engine 12 ''
context engine 13 "$(printf '{"created_at":"2026-09-01T10:00:00Z","author_association":"NONE","body":"Landed on master:\\n\\n- %s Its subject"}' "$(printf '%s' "$e1" | cut -c1-7)")"
context engine 14 "$(member_landing 2026-09-01T10:00:00Z "$e1")"; reopened engine 14 2026-09-02T10:00:00Z
context engine 15 "$(member_landing 2026-09-01T10:00:00Z "$e1"),$(member_landing 2026-09-03T10:00:00Z "$e2")"; reopened engine 15 2026-09-02T10:00:00Z
context engine 16 "$(member_landing 2026-09-01T10:00:00Z "$e1"),$(chatter NONE 59 | sed 's/\\//')"
context engine 17 "$(chatter NONE 20),$(member_landing 2026-09-01T10:00:00Z "$e1"),$(chatter NONE 34)"
context engine 18 "$(member_landing 2026-09-01T10:00:00Z "$e1" example-org/ghost)"
run_status
check 'exit 0' 0 "$rc"
check 'a card of a repository with no command, whose record names a clone that declares it, is read there: live on its first environment' "yes" "$(grep -qE "^  🟢 tagged#3 +live on prod since 2 h \(registry release 7, " <<< "$page" && echo yes || echo no)"
check 'the record names the commit, though a newer commit names the issue: delivered with the engine'"'"'s first release' "yes" "$(grep -qE "^  🟢 engine#11 +live on prod since 2 h" <<< "$page" && echo yes || echo no)"
check 'the same shape in a clone with no command keeps its rule: the newest commit that names it came after the release' '  ⏸ not live: tagged#12' "$(grep '⏸ not live:' <<< "$page")"
check 'no comment, a stranger'"'"'s record, a record before the reopening, a record outside the last 50 comments: no landing record' \
  '  ⏸ no landing record of the issue names its work: engine#12 engine#13 engine#14 engine#16' "$(grep '⏸ no landing record' <<< "$page")"
check 'a new record after the reopening is the landing: later, on the second environment' "yes" "$(grep -qE "^  🟡 engine#15 +live on qa since 1 h \(registry release 9, " <<< "$page" && echo yes || echo no)"
check 'a record within the last 50 comments, behind chatter that a stranger wrote, is found: the slice is cut before the authors are judged' \
  "yes" "$(grep -qE "^  🟢 engine#17 +live on prod since 2 h" <<< "$page" && echo yes || echo no)"
check 'a landing in a repository with no clone here is named with it, and the card is not read in its owner'"'"'s clone' \
  "  ⏸ no checkout of the repository its work landed in, in $shown_cmd: engine#18 (example-org/ghost)" "$(grep 'its work landed in' <<< "$page")"

echo 'a refused read is one card'"'"'s line: the others are drawn, the card is unknown, nothing stands in for it, and the exit is not 0'
{ cmd_card 1 engine 'A1'; cmd_card 21 engine 'R1 the comments are refused'; cmd_card 22 engine 'R2 the reopening is refused'; cmd_card 23 engine 'R3 holds no comment'; cmd_card 1 engine2 'F1 the reader fails'; } > "$work/page9"
context engine 1 "$(member_landing 2026-09-01T10:00:00Z "$e1")"
context engine 21 "$(member_landing 2026-09-01T10:00:00Z "$e1")"; touch "$work/ctx/engine-21.refuse-comments"
context engine 22 "$(member_landing 2026-09-01T10:00:00Z "$e1")"; touch "$work/ctx/engine-22.refuse-reopened"
context engine 23 ''
context engine2 1 "$(member_landing 2026-09-01T10:00:00Z "$f1")"; touch "$work/answers/engine2.fail"
run_status
check 'exit 1' 1 "$rc"
check 'the cards that could be read are drawn' "yes" "$(grep -qE '^  🟢 engine#1 +live on prod' <<< "$page" && echo yes || echo no)"
check 'each refusal is named with the card, as unknown' \
  "  ❓ unknown example-org/engine#21: error: cannot read the comments of example-org/engine#21 - gh exited 1
  ❓ unknown example-org/engine#22: error: cannot read the last reopening of example-org/engine#22 - gh exited 1
  ❓ unknown example-org/engine2#1: the reader $cmd/engine2/tools/read exited 3 for example-org/engine2 live: the registry is unreachable" \
  "$(grep '^  ❓' <<< "$page" | sed 's/, and answered: .*//')"
check 'and they count: no live and no not-live, and an empty answer is no refusal' \
  'TESTING 5 cards in testing: 1 live on prod, 0 live on qa only, 0 live on live, 0 live on prod only, 0 not live, 1 without a landing, 3 unknown' "$(grep '^TESTING' <<< "$page")"
page="$(cd "$cmd" && AI_CORE_PROCESSES="$work/processes" AI_CORE_AGENTS="$work/agents" AI_CORE_ROLLOUTS="$work/rollouts" bash "$root/bin/status.sh" --project example-org/9 2>&1)"; rc=$?
check 'exit 1 beside the agents: the page with the agents that run ends with the testing block, and the exit is the same' "1|3" "$rc|$(grep -c '^  ❓ unknown' <<< "$page")"
rm -f "$work/ctx/engine-21.refuse-comments" "$work/ctx/engine-22.refuse-reopened" "$work/answers/engine2.fail"

echo 'the tracker is read for the cards only where a clone declares command, and never for --tokens or --issues'
{ cmd_card 1 engine 'A1'; cmd_card 1 tagged 'L1'; cmd_card 2 tagged 'L2'; } > "$work/page9"
run_status
check 'a clone declares it: three cards, six requests, none beyond' 6 "$(reads)"
for name in engine engine2 engine3; do sed -i.bak 's/=command/=deploy\/x\/*/g' "$cmd/$name/.ai-core/config.env"; rm -f "$cmd/$name/.ai-core/config.env.bak"; done
run_status
check 'no clone declares it: the default view reads nothing of the tracker for its cards' 0 "$(reads)"
check 'and it counts by the list of each clone that sets one and the caller'"'"'s list for the rest' 'TESTING 3 cards in testing: 0 live on prod, 1 live on test only, 0 live on qa only, 0 not live, 2 without a landing commit' "$(grep '^TESTING' <<< "$page")"
for name in engine engine2 engine3; do sed -i.bak 's/=deploy\/x\/\*/=command/g' "$cmd/$name/.ai-core/config.env"; rm -f "$cmd/$name/.ai-core/config.env.bak"; done
run_status --tokens
check '--tokens reads no landing, though a clone declares command' 0 "$(reads)"
run_status --issues
check '--issues reads no landing either' 0 "$(reads)"

echo 'the caller'"'"'s own command is no reader of a clone that did not declare it, and the environment does not select one'
printf 'LIVE_TAGS="prod=command test=deploy/test/*"\n' > "$cmd/.ai-core/config.env"
{ cmd_card 1 tagged 'L1'; } > "$work/page9"; context tagged 1 ''
run_status
check 'the card is unknown, and the missing declaration is named' \
  "  ❓ unknown example-org/tagged#1: LIVE_TAGS of $cmd/.ai-core/config.env says prod=command, and the clone of example-org/tagged declares no command: only a clone that does can have its reader run, so prod is not read" "$(grep '^  ❓' <<< "$page")"
check 'and exits 1' 1 "$rc"
printf 'LIVE_TAGS="prod=deploy/prod/* test=deploy/test/*"\n' > "$cmd/.ai-core/config.env"
: > "$work/reader-calls.log"
page="$(cd "$cmd" && LIVE_TAGS='prod=command' LIVE_RELEASE_COMMAND="$cmd/engine/tools/read" AI_CORE_PROCESSES="$work/no-processes9" AI_CORE_AGENTS="$work/no-agents9" AI_CORE_ROLLOUTS="$work/no-agents9" bash "$root/bin/status.sh" --project example-org/9 2>&1)"; rc=$?
check 'exported LIVE_TAGS and LIVE_RELEASE_COMMAND change nothing: the caller'"'"'s file and the clone'"'"'s decide, and no reader ran' "0|0" "$rc|$(grep -c . "$work/reader-calls.log")"

echo 'a commit message names its issue in its whole text, and only the issue'
{ cmd_card 40 tagged 'S1 own reference in the body'; cmd_card 41 tagged 'S2 bare reference in the body'; cmd_card 42 tagged 'S3 a foreign reference only'; cmd_card 43 tagged 'S4 a foreign reference'; cmd_card 410 tagged 'S5 a longer number'; } > "$work/page9"
for n in 40 41 42 43 410; do context tagged $n ''; done
printf 'LIVE_TAGS="prod=deploy/prod/* test=deploy/test/*"\n' > "$cmd/.ai-core/config.env"
run_status
check 'the own full reference and the bare reference of a message body find their cards; a foreign reference and a longer number do not' \
  "tagged#40 tagged#41|tagged#42 tagged#43 tagged#410" "$(grep -oE '^  🔴 tagged#(40|41) ' <<< "$page" | grep -oE 'tagged#[0-9]+' | tr '\n' ' ' | sed 's/ $//')|$(grep '⏸ no commit' <<< "$page" | sed 's/.*names it: //')"

echo 'a clone that sets its own LIVE_TAGS is read by it; a clone that sets none, by the caller'"'"'s'
# plugin: "oops prod=[0-9]*-stable-* qa=qa/*" (oops is no environment), its first commit in a tag the caller's list does not name, its second in qa/1;
# landing: "prod=landed"; tagged sets none, and its card is in deploy/test/1, which the caller's list names
cmd_repo plugin
commit_at "$work/seed-plugin" 90000 'Land the first (#1)'; git -C "$work/seed-plugin" tag 0.5.022-stable-20261021150415
commit_at "$work/seed-plugin" 7200 'Land the second (#2)'; git -C "$work/seed-plugin" tag qa/1
commit_at "$work/seed-plugin" 3600 'Land the third (#3)'
cmd_clone plugin 'oops prod=[0-9]*-stable-* qa=qa/*'
cmd_repo landing; commit_at "$work/seed-landing" 80000 'Land the first (#1)'; cmd_clone landing 'prod=landed'
{ cmd_card 1 plugin 'G1 is in the tag of its own list'; cmd_card 2 plugin 'G2 is on its second environment'; cmd_card 3 plugin 'G3 is in no tag'; cmd_card 1 landing 'H1 lands where it is live'; cmd_card 1 tagged 'T1 has no list of its own'; } > "$work/page9"
run_status
check 'exit 0' 0 "$rc"
check 'the header counts each card by the list of its clone: the caller'"'"'s first, then the clones'"'"' in the order of their repositories' \
  'TESTING 5 cards in testing: 2 live on prod, 1 live on test only, 1 live on qa only, 1 not live, 0 without a landing commit' "$(grep '^TESTING' <<< "$page")"
check 'a tag of the clone'"'"'s own pattern carries its card on the first environment, though the caller'"'"'s list names no such tag' \
  "  🟢 $(printf '%-26s' plugin#1) live on prod since 25 h (0.5.022-stable-20261021150415)  G1 is in the tag of its own list" "$(line_of 'plugin#1 ')"
check 'a clone that says prod=landed carries a landed card from its landing' \
  "  🟢 $(printf '%-26s' landing#1) live on prod since 22 h (landed on origin/master)  H1 lands where it is live" "$(line_of 'landing#1 ')"
check 'a later environment of its own list is yellow within the PROOF_HOURS of the caller' \
  "  🟡 $(printf '%-26s' plugin#2) live on qa since 2 h (qa/1)  G2 is on its second environment" "$(line_of 'plugin#2 ')"
check 'a card in none of the tags of its own list is not live' '  ⏸ not live: plugin#3' "$(grep '⏸ not live:' <<< "$page")"
check 'a clone that sets none is read by the caller'"'"'s list, as before' "yes" "$(grep -qE "^  🔴 tagged#1 +live on test since 2[0-9] h \(deploy/test/1\)  T1 has no list of its own$" <<< "$page" && echo yes || echo no)"
check 'a word of a clone'"'"'s own LIVE_TAGS that is no environment is named with its file, once, and the clones whose lists are whole say nothing' \
  "  LIVE_TAGS of $cmd/plugin/.ai-core/config.env has 'oops', which is no <environment>=<tag pattern>; it is left out" "$(grep -E "^  LIVE_TAGS (of .* )?has " <<< "$page")"
own="$(cd "$cmd/plugin" && AI_CORE_PROCESSES="$work/no-processes9" AI_CORE_AGENTS="$work/no-agents9" AI_CORE_ROLLOUTS="$work/no-agents9" bash "$root/bin/status.sh" --project example-org/9 2>&1)"
check 'where the caller is that clone, the word is named once, as the caller'"'"'s' \
  "  LIVE_TAGS has 'oops', which is no <environment>=<tag pattern>; it is left out" "$(grep -E "^  LIVE_TAGS (of .* )?has " <<< "$own")"
# status_mutant <sed expression> [directory to run in]: the page of board 9 in $planted, from a copy of the harness whose lib/status-live.mjs has one defect
status_mutant() {
  local mutant="$work/mutant"
  rm -rf "$mutant"; mkdir -p "$mutant"; cp -R "$root/bin" "$root/lib" "$root/templates" "$mutant/"; cp "$root/VERSION" "$mutant/"
  sed -i.bak "$1" "$mutant/lib/status-live.mjs"
  cmp -s "$root/lib/status-live.mjs" "$mutant/lib/status-live.mjs" && { echo "  FAIL the planted copy equals lib/status-live.mjs: $1"; failed=$((failed + 1)); }
  planted="$(cd "${2:-$cmd}" && AI_CORE_PROCESSES="$work/no-processes9" AI_CORE_AGENTS="$work/no-agents9" AI_CORE_ROLLOUTS="$work/no-agents9" bash "$mutant/bin/status.sh" --project example-org/9 2>&1)"
}
status_mutant 's/const list = set.envs.length ? set : caller;/const list = caller;/'
planted_not_live="$(grep -oE '⏸ not live: .*' <<< "$planted" | cut -d' ' -f4- | tr ' ' '\n' | grep -E '^(plugin|landing)' | sort | tr '\n' ' ')"
check 'planted: the caller'"'"'s list for every card leaves the cards of the clones that set their own not live, and the one that sets none as it was' \
  'landing#1 plugin#1 plugin#2 plugin#3 |1' "$planted_not_live|$(grep -c '^  🔴 tagged' <<< "$planted")"
status_mutant 's/^      if (!isCallerFile(file)) for (const word of declared.bad) out.push.*$//'
check 'planted: the words of a clone'"'"'s own list dropped with no line, as they were' '' "$(grep -E "^  LIVE_TAGS (of .* )?has " <<< "$planted")"
status_mutant 's/if (!isCallerFile(file)) for (const word/for (const word/' "$cmd/plugin"
check 'planted: a word of the caller'"'"'s own file named a second time as a clone'"'"'s, where the caller is that clone' 2 "$(grep -cE "^  LIVE_TAGS (of .* )?has " <<< "$planted")"

echo 'a card of a clone that declares command, whose work landed in a repository whose clone declares none: the unknown line names the declaration that is missing'
{ cmd_card 11 engine 'S1 landed in a repository whose clone declares no command'; } > "$work/page9"
context engine 11 "$(member_landing 2026-09-01T10:00:00Z "$(head_of tagged)" example-org/tagged)"
run_status
check 'exit 1' 1 "$rc"
check 'the file named is the one whose list says command, and the clone that lacks the declaration is the one the work landed in' \
  "  ❓ unknown example-org/engine#11: LIVE_TAGS of $cmd/engine/.ai-core/config.env says prod=command, and the clone of example-org/tagged, where the work of example-org/engine#11 landed, declares no command: only a clone that does can have its reader run, so prod is not read" \
  "$(grep '^  ❓' <<< "$page")"
status_mutant 's/^          const reader = .*$/          const reader = `the clone of ${card.repo}`;/'
check 'planted: the clone of the card named as the one that lacks the declaration, though it declares command' 'no yes' \
  "$(grep -qF 'the clone of example-org/tagged, where the work' <<< "$planted" && echo yes || echo no) $(grep -qF 'and the clone of example-org/engine declares no command' <<< "$planted" && echo yes || echo no)"
status_mutant 's/LIVE_TAGS of ${listFile || /LIVE_TAGS of ${configFile || /'
check 'planted: the file of the caller named as the list that says command, though the list is the clone'"'"'s' 'no yes' \
  "$(grep -qF "LIVE_TAGS of $cmd/engine/.ai-core/config.env says" <<< "$planted" && echo yes || echo no) $(grep -qF "LIVE_TAGS of $cmd/.ai-core/config.env says" <<< "$planted" && echo yes || echo no)"

echo 'the handoff of the cards is read as it is: a record that is missing or malformed is no context'
printf 'Todo\ntesting\nDone\n' > "$work/cmd-columns"
{ cmd_card 1 engine 'A1'; cmd_card 1 tagged 'L1'; } > "$work/cmd-items"
# the card rows of the tracker, as bin/status.sh hands them to Node: one JSON object a line
jq -c '{repo: .content.repository.nameWithOwner, number: .content.number, title: .content.title, open: true, status: .status.name, priority: null, parent: null, subs: 0, closedAt: null}' "$work/cmd-items" > "$work/cmd-rows"
node_status() {  # node_status <testing file or empty for none>
  local files=(); [ -z "$1" ] || files=(--testing-file "$1")
  : > "$work/no-agents9"
  page="$(cd "$cmd" && AI_CORE_PROCESSES="$work/no-processes9" AI_CORE_AGENTS="$work/no-agents9" AI_CORE_ROLLOUTS="$work/no-agents9" node "$root/lib/status.mjs" --items-file "$work/cmd-rows" --columns-file "$work/cmd-columns" \
    --board example-org/9 --folder "$cmd" --stop-at 92 --config-file "$cmd/.ai-core/config.env" "${files[@]}" 2>&1)"; rc=$?
}
node_status ''
check 'no handoff at all is refused by name' "1|error: --testing-file is required without --tokens" "$rc|$page"
printf 'not json\n{"repository":"example-org/engine","number":1,"pattern":"x","context":"read","reason":"","landing":"e1","landingClone":""}\n' > "$work/bad-records"
node_status "$work/bad-records"
check 'a record that is no JSON, and one of the wrong shape, give no card a verdict: both are unknown, and the exit is 1' \
  "1|  ❓ unknown example-org/engine#1: the record bin/status.sh hands over for example-org/engine#1 is missing or malformed
  ❓ unknown example-org/tagged#1: the record bin/status.sh hands over for example-org/tagged#1 is missing or malformed" "$rc|$(grep '^  ❓' <<< "$page")"
printf '{"repository":"example-org/engine","number":1,"pattern":"x","context":"none","reason":"","landing":null,"landingClone":""}\n' > "$work/stale-records"
node_status "$work/stale-records"
check 'a card of a clone that declares command, whose landing was never asked of the tracker, is not read from its commits' \
  "1|  ❓ unknown example-org/engine#1: the landing of example-org/engine#1 was not read from the tracker, and $cmd/engine declares an environment as command" "$rc|$(grep '^  ❓ unknown example-org/engine#1' <<< "$page")"

echo 'two runs at once, each with a temporary directory of its own, answer the same and leave nothing behind'
{ cmd_card 1 engine 'A1'; cmd_card 1 tagged 'L1'; } > "$work/page9"; context engine 1 "$(member_landing 2026-09-01T10:00:00Z "$e1")"; context tagged 1 ''
mkdir -p "$work/tmp-a" "$work/tmp-b"
for side in a b; do
  ( cd "$cmd" && TMPDIR="$work/tmp-$side" AI_CORE_PROCESSES="$work/no-processes9" AI_CORE_AGENTS="$work/no-agents9" AI_CORE_ROLLOUTS="$work/no-agents9" bash "$root/bin/status.sh" --project example-org/9 > "$work/run-$side.txt" 2>&1 ) &
done
wait
check 'both pages are the same, whole, and the temporary directories are empty again' "0|0|1" \
  "$(cmp -s "$work/run-a.txt" "$work/run-b.txt"; echo $?)|$(find "$work/tmp-a" "$work/tmp-b" -mindepth 1 | grep -c .)|$(grep -c '^TESTING 2 cards' "$work/run-a.txt")"

if [ "$failed" -gt 0 ]; then echo; echo "$out"; echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
