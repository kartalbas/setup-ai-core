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
# that refuses, as the one of Git for Windows refuses -A, proves --tokens never asks for it.
printf '#!/usr/bin/env bash\necho "ps: unknown option -- A" >&2; exit 1\n' > "$work/bin/ps"
chmod +x "$work/bin/ps"
export PATH="$work/bin:$PATH"

# The usage now and its history, and the transcripts of the folder's sessions
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
  112 111 '29:00' SNsl+ '/home/x/.local/share/claude/versions/2.1.289 --session-id 22222222-2222-2222-2222-222222222222 --name l1-sonnet5.5-low-100k-ab123 --model sonnet --effort low' \
  113 110 '40:00' SNsl+ 'claude bg-spare --bg-spare /tmp/x/spare/a1.claim.sock' \
  114 110 '20:00' SNsl+ 'claude bg-spare --bg-spare /tmp/x/spare/a2.claim.sock' \
  115 1 '50:00' Sl+ '/home/x/.local/bin/claude agents' \
  116 1 '3-00:00:00' Tl '/home/x/.local/bin/claude --resume old-lead' \
  > "$work/processes"
printf '%s\n' '[{"pid":100,"kind":"interactive","status":"busy","name":"exa-lead","sessionId":"11111111-1111-1111-1111-111111111111","id":null},' \
  '{"pid":112,"kind":"background","status":"idle","state":"blocked","name":"l1-sonnet5.5-low-100k-ab123","sessionId":"22222222-2222-2222-2222-222222222222","id":"22222222"},' \
  '{"pid":113,"kind":"background","status":"busy","state":"working","name":"l2-opus5.5-high-300k-cd456","cwd":"/home/x/.worktrees/shop/issue-4-fix-the-thing","sessionId":"33333333-3333-3333-3333-333333333333","id":"33333333"}]' > "$work/agents"
printf '%s\t%s\n' /proc/102/fd /home/x/.codex/sessions/2026/10/04/rollout-2026-10-04T11-52-48-01a106c2-71cd-7451-94ce-508f6229cd5b.jsonl \
  /proc/100/fd /home/x/.codex/sessions/2026/10/04/rollout-2026-10-04T11-00-00-01a10000-0000-7000-8000-000000000000.jsonl > "$work/rollouts"
view="$(cd "$folder" && AI_CORE_PROCESSES="$work/processes" AI_CORE_AGENTS="$work/agents" AI_CORE_ROLLOUTS="$work/rollouts" bash "$root/bin/status.sh" --project example-org/7 2>&1)"; rc=$?
vline() { grep -m1 -F -- "$1" <<< "$view" | tr -s ' '; }
check 'exit 0'        0 "$rc"
check 'line 1: the time and the board counts' "example · board example-org/7 · $(when "$now") · Backlog 0 · Todo 5 · In progress 2 · Done 15" "$(sed -n 1p <<< "$view")"
check 'a session, named by its resume' '│ claude exa-lead │ 100 │ │ 1500 min │ busy │ │ session │' "$(vline '│ claude exa-lead ')"
check 'the runs it started, through a script too, newest first' '│ └ gemini │ 108 │ │ 1 min │ │ example-repo#3 │ run │' "$(vline '└ gemini')"
check 'with model and effort' '│ └ codex │ 102 │ big-model · high │ 3 min │ │ example-repo#1 │ run │' "$(vline '└ codex')"
check 'a run a run started' '│ └ agy │ 103 │ cheap-model · high │ 2 min │ │ │ run │' "$(vline '└ agy')"
check 'indented one step deeper' 1 "$(grep -c '^│     └ agy ' <<< "$view")"
check 'a run no agent started stands alone' '│ codex │ 104 │ │ 62 min │ │ │ resumed run │' "$(vline '│ codex ')"
check 'an agent CLI without a prompt is a session' '│ agy │ 109 │ │ 5 min │ │ │ session │' "$(vline '│ agy ')"
check 'a background session runs from the versioned binary' '│ claude l1-sonnet5.5 │ 112 │ sonnet · low │ 29 min │ idle blocked │ │ session │' "$(vline '│ claude l1-sonnet5.5 ')"
check 'its daemon and terminal host are no agents' 0 "$(grep -cE '│ 11[01] +│' <<< "$view" || true)"
check 'a claimed spare: name, model and effort from its name, the issue from its worktree' '│ claude l2-opus5.5-h │ 113 │ opus5.5 · high │ 40 min │ busy working │ shop#4 at start │ session │' "$(vline '│ claude l2-opus5.5')"
check 'a spare no session claimed and the agent list are no agents' 0 "$(grep -cE '│ 11[45] +│' <<< "$view" || true)"
check 'a stopped session is shown stopped' '│ claude old-lead │ 116 │ │ stopped │ │ │ session │' "$(vline '│ claude old-lead ')"
check 'in this order' '116 100 108 102 103 104 113 112 109' "$(awk -F'│' '$3 ~ /^ *[0-9]+ *$/ { printf "%s%s", sep, $3 + 0; sep = " " }' <<< "$view")"
check 'no helper, no tool word in another command, a stopped one apart' 'AGENTS 8 running: 3 claude, 1 gemini, 2 codex, 2 agy; 1 stopped' "$(vline ' running: ')"
check 'no token lines' '' "$(vline 'pace ')"
printf '%s\t%s\t%s\t%s\t%s\n' 116 1 '3-00:00:00' Tl '/home/x/.local/bin/claude --resume old-lead' > "$work/stopped-only"
only="$(cd "$folder" && AI_CORE_PROCESSES="$work/stopped-only" AI_CORE_AGENTS="$work/agents" AI_CORE_ROLLOUTS="$work/rollouts" bash "$root/bin/status.sh" --project example-org/7 2>&1)"
check 'only a stopped one: none running' 'AGENTS 0 running; 1 stopped' "$(grep -m1 '^AGENTS  *[0-9]' <<< "$only" | tr -s ' ')"
printf '%s\t%s\t%s\t%s\t%s\n' 117 1 '10:00' 'SNsl+' 'claude bg-spare --bg-spare /tmp/x/spare/a3.claim.sock' > "$work/unversioned"
printf '%s\n' '[{"pid":117,"kind":"background","name":"l3-sonnet-high-200k-ef789","cwd":"/home/x/repos","sessionId":"44444444-4444-4444-4444-444444444444","id":"44444444"}]' > "$work/unversioned-agents"
plain="$(cd "$folder" && AI_CORE_PROCESSES="$work/unversioned" AI_CORE_AGENTS="$work/unversioned-agents" AI_CORE_ROLLOUTS="$work/rollouts" bash "$root/bin/status.sh" --project example-org/7 2>&1)"
check 'a name without a version: its model and effort' '│ claude l3-sonnet-hi │ 117 │ sonnet · high │ 10 min │ │ │ session │' "$(grep -m1 -F '│ claude l3-sonnet' <<< "$plain" | tr -s ' ')"

echo 'the command that reaches each agent, from what its CLI reports'
reach() { awk '/^REACH$/ { on = 1; next } on' <<< "$1" | grep -m1 -E -- "^  $2 " | tr -s ' ' | sed 's/^ //'; }
check 'an interactive session: resume it, a rollout it holds changes nothing' '100 exa-lead claude --resume 11111111-1111-1111-1111-111111111111' "$(reach "$view" 100)"
check 'a background session: attach to it' '112 l1-sonnet5.5-low-100k-ab123 claude attach 22222222' "$(reach "$view" 112)"
check 'a codex process: the rollout it holds open' '102 codex codex resume 01a106c2-71cd-7451-94ce-508f6229cd5b' "$(reach "$view" 102)"
check 'a codex process that holds none: a dash' '104 codex —' "$(reach "$view" 104)"
check 'an agent its CLI says nothing about: a dash' '109 agy —' "$(reach "$view" 109)"
check 'every agent, in the order of the table' '116 100 108 102 103 104 113 112 109' "$(awk '/^REACH$/ { on = 1; next } on && /^  [0-9]/ { printf "%s%s", sep, $1; sep = " " }' <<< "$view")"
echo 'claude agents --json failed' > "$work/bad-agents"
broken="$(cd "$folder" && AI_CORE_PROCESSES="$work/processes" AI_CORE_AGENTS="$work/bad-agents" AI_CORE_ROLLOUTS="$work/rollouts" bash "$root/bin/status.sh" --project example-org/7 2>&1)"
check 'a list that failed is shown, not swallowed' 'claude agents --json gave no list: claude agents --json failed' "$(grep -m1 'gave no list' <<< "$broken" | sed 's/^ *//')"
check 'and no command is guessed' '100 claude —' "$(reach "$broken" 100)"
# Where no stand-in names the rollouts, the twin asks find, which exits 1 on the processes it may
# not read; what it found still reaches the page. Without /proc there is nothing to ask.
mkdir -p "$work/findbin"
cat > "$work/findbin/find" <<'STUB'
#!/usr/bin/env bash
printf '%s\t%s\n' /proc/104/fd /x/rollout-2026-10-04T12-00-00-01a10444-0000-7000-8000-000000000444.jsonl
exit 1
STUB
chmod +x "$work/findbin/find"
found="$(cd "$folder" && PATH="$work/findbin:$PATH" AI_CORE_PROCESSES="$work/processes" AI_CORE_AGENTS="$work/agents" AI_CORE_ROLLOUTS='' bash "$root/bin/status.sh" --project example-org/7 2>&1)"; rc=$?
check 'a find that exits 1 stops nothing' 0 "$rc"
if [ -d /proc ]; then held='104 codex codex resume 01a10444-0000-7000-8000-000000000444'; else held='104 codex —'; fi
check 'and what it found reaches the page' "$held" "$(reach "$found" 104)"

echo 'outside a repository with no board named: refused, naming --project'
refused="$(cd "$folder" && bash "$root/bin/status.sh" 2>&1)"; rc=$?
check 'exit 1'        1 "$rc"
check 'the line'      'error: outside a repository, name the board - status --project N' "$refused"

echo 'the testing cards and the worktrees the sweep keeps, read from git'
# A second board in a folder of its own: its column after implementing is testing, and its
# repository has release tags of two environments and four issue worktrees
live="$work/live"; mkdir -p "$live/.ai-core" "$work/cache/8"
# status spells the folder as node resolves it, which on Windows is C:\...; the expectation does too
shown="$(node -e 'process.stdout.write(require("path").resolve(process.argv[1]))' "$live")"
printf 'LIVE_TAGS="prod=deploy/prod/* test=deploy/test/*"\nPROOF_HOURS=24\n' > "$live/.ai-core/config.env"
echo PVT_example8 > "$work/cache/8/project-id"
printf 'Status\tF1\t%s\tO%s\n' Todo 1 implementing 2 testing 3 Done 4 > "$work/cache/8/fields.tsv"
# #38 is a card of another organisation's repository of the same name: the local clone is not its
{ for n in 37 35 34 33 32 31; do card "$n" testing P1 OPEN - - 0 "Card $n"; done; card 36 implementing P1 OPEN - - 0 'Card 36'
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
check 'the trees line' 'TREES   2 worktrees the sweep keeps, older than a day:' "$(grep '^TREES' <<< "$page")"
check 'unlanded and old' "  $(printf '%-26s' example-repo#41)   3 d  has work origin/master does not have yet" "$(grep 'example-repo#41' <<< "$page")"
check 'with changes' "  $(printf '%-26s' example-repo#42)  30 h  has changes" "$(grep 'example-repo#42' <<< "$page")"
check 'young and landed ones are not listed' '' "$(grep -E 'example-repo#4[34]' <<< "$page")"
sed 's/^LIVE_TAGS=.*$//' "$live/.ai-core/config.env" > "$live/.ai-core/config.tmp" && mv "$live/.ai-core/config.tmp" "$live/.ai-core/config.env"
bare="$(cd "$live" && AI_CORE_PROCESSES="$work/no-processes" AI_CORE_AGENTS="$work/no-agents" AI_CORE_ROLLOUTS="$work/no-agents" bash "$root/bin/status.sh" --project example-org/8 2>&1)"
check 'without LIVE_TAGS, the testing line' 'TESTING 7 cards in testing: 5 landed, 1 without a landing commit, 1 without a checkout' "$(grep '^TESTING' <<< "$bare")"
check 'and why' '  LIVE_TAGS in .ai-core/config.env names no environment, so where the work is live is not read' "$(grep 'names no environment' <<< "$bare")"
check 'the landed cards, none called not live' '  ⏸ landed: example-repo#37 example-repo#34 example-repo#33 example-repo#32 example-repo#31|' "$(grep '⏸ landed:' <<< "$bare")|$(grep 'not live' <<< "$bare")"
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

if [ "$failed" -gt 0 ]; then echo; echo "$out"; echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
