#!/usr/bin/env bash
# What `ai-core start-phase` starts, on which tuple, and what it refuses.
#
#   bash tests/start-phase.test.sh
#
# Claude Code, Codex, agy and gh are stand-ins on PATH; the quota reader of phase-model is a stand-in too, so no tool
# is asked for anything. HOME and AI_CORE_HOME are a scratch folder, and the key is a made-up string in it.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/tool-environment.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" AI_CORE_HOME="$WORK/state" TMPDIR="$WORK/tmp"
mkdir -p "$HOME" "$AI_CORE_HOME/.ai-core/sessions" "$TMPDIR"
STATE="$AI_CORE_HOME/.ai-core"; SESSIONS="$STATE/sessions"

failed=0
check() {  # name expected actual
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: [$2]"; echo "       actual:   [$3]"; failed=$((failed + 1)); fi
}
has() { grep -qF -- "$2" <<< "$1" && echo yes || echo no; }

# The source tree of the command, with a quota reader that has nothing to read
SRC="$WORK/src"; mkdir -p "$SRC"
cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/templates" "$SRC/"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SRC/bin/usage.sh"

FAKE="$WORK/fake"; mkdir -p "$FAKE/bin"
cat > "$FAKE/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE/claude.args"
case "$1" in
  agents) cat "$FAKE/agents.json"; exit 0 ;;
  stop) printf '%s\n' "$2" >> "$FAKE/claude.stopped"; exit 0 ;;
esac
name=''; print=0; prev=''
for a in "$@"; do [ "$prev" != --name ] || name="$a"; [ "$a" != -p ] || print=1; prev="$a"; done
if [ "$print" = 1 ]; then
  printf '%s' "${ANTHROPIC_API_KEY:-}" | cut -c1-8 > "$FAKE/key-prefix-seen"
  sleep "${FAKE_RUN_SECONDS:-0}"
  printf '{"type":"result","result":"the report","total_cost_usd":0.5,"session_id":"print-1"}\n'
else
  jq -c --arg name "$name" '. + [{name:$name,id:"agent-\(length + 1)",sessionId:"sess-\(length + 1)",cwd:"/",status:"idle"}]' "$FAKE/agents.json" > "$FAKE/agents.next" && mv "$FAKE/agents.next" "$FAKE/agents.json"
  echo started
fi
EOF
cat > "$FAKE/bin/codex" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE/codex.args"
readlink /proc/self/fd/0 > "$FAKE/codex.stdin"
[ -z "${HEAD_MARK:-}" ] || for _ in $(seq 1 200); do [ -e "$HEAD_MARK" ] && break; sleep 0.05; done
printf '{"type":"thread.started","thread_id":"thread-1"}\n'
sleep "${FAKE_RUN_SECONDS:-0}"
printf '{"type":"item.completed","item":{"type":"agent_message","text":"codex report"}}\n{"type":"turn.completed"}\n'
EOF
cat > "$FAKE/bin/agy" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE/agy.args"
pwd > "$FAKE/agy.cwd"
printf '{"status":"SUCCESS","conversation_id":"conv-1","message":"agy report"}\n'
EOF
cat > "$FAKE/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE/gh.calls"
for a in "$@"; do case "$a" in body=@*) cp "${a#body=@}" "$FAKE/posted.$(date +%s%N)" ;; esac; done
case "$*" in
  *"--jq .html_url"*) echo "https://example.invalid/o/r/issues/7#issuecomment-900"; exit 0 ;;
  *comments*) cat "$FAKE/comments.json"; exit 0 ;;
  *"repos/o/r/issues/7"*) echo '{"number":7,"title":"The plan","state":"open","labels":[],"body":"plan","created_at":"2026-10-30T08:00:00Z"}'; exit 0 ;;
  *) echo o/r; exit 0 ;;
esac
EOF
chmod +x "$FAKE/bin/"*
export FAKE PATH="$FAKE/bin:$PATH" GH_ORG=o
echo '[]' > "$FAKE/agents.json"; echo '[]' > "$FAKE/comments.json"

PROJECT="$WORK/project"; mkdir -p "$PROJECT/.ai-core"; git -C "$PROJECT" init -q
KEY=sk-ant-FAKEKEY-0123456789; PREFIX="${KEY:0:8}"
mkdir -p "$STATE/secrets"; chmod 700 "$STATE/secrets"; printf '%s' "$KEY" > "$STATE/secrets/acme-key"; chmod 600 "$STATE/secrets/acme-key"
printf '{"permissions":{"deny":[]}}\n' > "$STATE/claude-run-settings.json"
printf 'chrome-stub\n' > /dev/null; mkdir -p "$FAKE/bin"; printf '#!/bin/sh\nexit 0\n' > "$FAKE/bin/google-chrome"; chmod +x "$FAKE/bin/google-chrome"
table() {  # table <claude build model>
  {
    printf 'claude\tbuild\t*\t%s\thigh\n' "${1:-claude-sonnet-5-5}"
    printf 'claude\tplan-check\t*\tclaude-opus-5-5\thigh\nclaude\tre-plan\t*\tclaude-fable-5-1\txhigh\nclaude\tui-test\t*\tclaude-sonnet-5-5\thigh\nclaude\tkeeper\t*\tclaude-opus-5-5\thigh\n'
    printf 'codex\tbuild\t*\tgpt-6-astra\txhigh\nagy\tbuild\t*\tclaude-sonnet-5-5-high\t-\nacme-key\tbuild\t*\tclaude-fable-5-1\thigh\nacme-key\tui-test\t*\tclaude-fable-5-1\thigh\n'
  } > "$PROJECT/.ai-core/models.tsv"
}
table
order() { printf '{"version":1,"orders":[{"generation":1,"time":%s,"tools":["%s"]}]}\n' "$(( $(date +%s) - 1000 ))" "$1" > "$STATE/tool-order.json"; }
printf '# Brief: build a test thing\n\nRead one file.\nReported by {{session name}}.\nReport on {{session issue repository}} number {{session issue number}}.\n' > "$WORK/brief.md"
number=10000
start() {  # start <args>... : in the project, one stdout line, stderr to $WORK/err
  number=$((number + 1))
  ( cd "$PROJECT" && bash "$SRC/bin/start-phase.sh" "$@" ) 2> "$WORK/err"
}
begin() { number=$((number + 1)); }
nameof() { printf '%s\n' "$1" | cut -d' ' -f1; }
last_selected() { tail -n 1 "$STATE/phase-model.jsonl" | jq -r '.selected | "\(.tool) \(.model) \(.effort)"'; }
recorded() { jq -r 'select(.kind == "attempt") | "\(.tool) \(.model) \(.effort)"' "$SESSIONS/$1.start.jsonl" | tail -n 1; }

echo 'a start on Claude Code prints one worker line and writes the record of the selector tuple'
order claude
out="$(start build mechanical --issue o/r#7 --brief "$WORK/brief.md" --number 10001 --budget 100)"; rc=$?
name="$(nameof "$out")"
check 'exit 0' 0 "$rc"
check 'one line' 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
check 'the worker line' "$name claude build o/r#7: Brief: build a test thing (deadline: unmeasured)" "$out"
check 'the name' yes "$(grep -Eq '^build10001-sonnet5\.5-high-100k-[0-9a-f]{5}$' <<< "$name" && echo yes || echo no)"
check 'the record holds the tuple phase-model printed' "$(last_selected)" "$(recorded "$name")"
check 'the record says what it does' "Brief: build a test thing" "$(jq -r 'select(.kind == "attempt") | .does' "$SESSIONS/$name.start.jsonl")"
check 'the record says the deadline is unmeasured' null "$(jq -c 'select(.kind == "attempt") | .deadline' "$SESSIONS/$name.start.jsonl")"
check 'the record names the native session' sess-1 "$(jq -r 'select(.kind == "native") | .nativeIdentity' "$SESSIONS/$name.start.jsonl")"
check 'claude ran with the selected model and effort, in the background, under its name' yes \
  "$(grep -qF -- "--bg --name $name --model claude-sonnet-5-5 --effort high" "$FAKE/claude.args" && echo yes || echo no)"
brief="$(cat "$SESSIONS/$name.brief.md")"
check 'the brief names the session where it said so' yes "$(has "$brief" "Reported by $name.")"
check 'the brief names the issue where it said so' yes "$(has "$brief" "Report on o/r number 7.")"
check 'the frame holds the sentence on temporary files' yes "$(has "$brief" 'Temporary files go under $TMPDIR (mktemp or $TMPDIR/<name>), never a literal /tmp path.')"
check 'the frame holds the sentence on deleting' yes "$(has "$brief" 'Delete nothing outside your own scratch folders: no prune and no clean of a shared cache or store.')"
check 'a build brief has no plan check sentence' no "$(has "$brief" 'A plan check repairs what it can')"

echo 'a start that gives another model than the selector, or no number of the block, or a used one, is refused'
out="$(start build mechanical --issue o/r#7 --brief "$WORK/brief.md" --number 10002 --budget 100 --model claude-opus-5-5)"; rc=$?
check '--model: exit 2' 2 "$rc"
check '--model: nothing on stdout' '' "$out"
check '--model: both tuples named' yes "$(grep -qF 'tuple of ai-core phase-model, claude claude-sonnet-5-5 high' "$WORK/err" && grep -qF 'you gave - claude-opus-5-5 -' "$WORK/err" && echo yes || echo no)"
check '--model: no session was written' no "$(ls "$SESSIONS" | grep -q 10002 && echo yes || echo no)"
out="$(start build mechanical --issue o/r#7 --brief "$WORK/brief.md" --number 10001 --budget 100)"; rc=$?
check 'a used number: exit 2' 2 "$rc"
check 'a used number is named' yes "$(grep -qF 'number 10001 is used already' "$WORK/err" && echo yes || echo no)"
start build mechanical --issue o/r#7 --brief "$WORK/brief.md" --number 10003 > /dev/null; rc=$?
check 'no budget: exit 2' 2 "$rc"
start helper mechanical --issue o/r#7 --brief "$WORK/brief.md" --number 10003 --budget 100 > /dev/null; rc=$?
check 'helper: exit 2' 2 "$rc"
start coordinator mechanical --issue o/r#7 --brief "$WORK/brief.md" --number 10003 --budget 100 > /dev/null; rc=$?
check 'coordinator: exit 2' 2 "$rc"
printf '# Brief: a thing\n\n{{worktree path}}\n' > "$WORK/open.md"
start build mechanical --issue o/r#7 --brief "$WORK/open.md" --number 10003 --budget 100 > /dev/null; rc=$?
check 'a brief with a placeholder left: exit 2' 2 "$rc"
check 'the placeholder is named' yes "$(grep -qF '{{worktree path}}' "$WORK/err" && echo yes || echo no)"

echo 'the brief of a plan check carries the sentence on repairing, and the budget comes from the setup file'
printf '{"build":{"claude":{"model":"claude-sonnet-5-5","effort":"high","estimate_tokens":200000,"budget_tokens":300000,"reason":"test"}}}\n' > "$WORK/setup.json"
out="$(start plan-check normal-hard --issue o/r#7 --brief "$WORK/brief.md" --number 10004 --budget 150 --written-by claude-sonnet-5-5)"
check 'the plan check brief holds the sentence' yes "$(has "$(cat "$SESSIONS/$(nameof "$out").brief.md")" 'it says NO only when the approach is wrong, because a NO pays a whole round.')"
out="$(start build normal-hard --issue o/r#7 --brief "$WORK/brief.md" --number 10005 --setup-file "$WORK/setup.json")"
check 'a budget from the setup file: 300k in the name' yes "$(grep -Eq '^build10005-sonnet5\.5-high-300k-' <<< "$out" && echo yes || echo no)"

echo 'a second run of a phase and class is measured from the first one that ended'
first="$name"
now="$(jq -n now)"
jq -cn --argjson ended "$now" '{version:1,kind:"end",operation:"start",tool:"claude",model:"claude-sonnet-5-5",effort:"high",phase:"build",class:"mechanical",writer:"",invoked:($ended - 600),ended:$ended,duration:600,report:"u",costUsd:null}' >> "$SESSIONS/$first.start.jsonl"
out="$(start build mechanical --issue o/r#7 --brief "$WORK/brief.md" --number 10006 --budget 100)"; second="$(nameof "$out")"
check 'the worker line names the measured run' yes "$(has "$out" "(deadline in 15 min, 1.5 x 600 s of $first)")"
check 'the record holds the measured seconds' 600 "$(jq -r 'select(.kind == "attempt") | .measuredSeconds' "$SESSIONS/$second.start.jsonl")"
check 'the record holds the run it came from' "$first" "$(jq -r 'select(.kind == "attempt") | .measuredFrom' "$SESSIONS/$second.start.jsonl")"
check 'the deadline is the start plus one and a half times the run' 900 "$(jq -r 'select(.kind == "attempt") | (.deadline - .invoked) | round' "$SESSIONS/$second.start.jsonl")"

echo 'a start on Codex and on agy prints the worker line and records the tuple of the selector'
order codex
out="$(start build mechanical --issue o/r#7 --brief "$WORK/brief.md" --number 10007 --budget 100)"; cname="$(nameof "$out")"
check 'codex: the worker line names the tool' yes "$(has "$out" "$cname codex build o/r#7: ")"
check 'codex: the tuple' "$(last_selected)" "$(recorded "$cname")"
check 'codex: the thread is registered' "$cname	thread-1" "$(grep "^$cname" "$STATE/codex-sessions.tsv")"
check 'codex: it ran with the profile and the selected model' yes "$(grep -qF -- 'exec -p ai-core -m gpt-6-astra -c model_reasoning_effort=xhigh' "$FAKE/codex.args" && echo yes || echo no)"
order agy
out="$(start build mechanical --issue o/r#7 --brief "$WORK/brief.md" --number 10008 --budget 100)"; aname="$(nameof "$out")"
for _ in $(seq 1 50); do [ -f "$SESSIONS/$aname.exit" ] && break; sleep 0.1; done
check 'agy: the worker line names the tool' yes "$(has "$out" "$aname agy build o/r#7: ")"
check 'agy: the tuple' "$(last_selected)" "$(recorded "$aname")"
check 'agy: it ran with the selected model' yes "$(grep -qF -- '--model claude-sonnet-5-5-high' "$FAKE/agy.args" && echo yes || echo no)"

echo 'a print run holds none of the output of the start, so a caller that reads it is not held until the run ends'
order codex
began="$(date +%s)"
out="$(FAKE_RUN_SECONDS=8 start build mechanical --issue o/r#7 --brief "$WORK/brief.md" --number 10031 --budget 100)"; held=$(( $(date +%s) - began )); hname="$(nameof "$out")"
check 'the start returns before the run ends' yes "$([ "$held" -lt 5 ] && echo yes || echo "no, after $held s")"
check 'the run still runs then' no "$([ -f "$SESSIONS/$hname.exit" ] && echo yes || echo no)"
for _ in $(seq 1 120); do [ -f "$SESSIONS/$hname.exit" ] && break; sleep 0.1; done
check 'and ends by itself' 0 "$(cat "$SESSIONS/$hname.exit" 2>/dev/null)"

echo 'Codex that ends between the read of its output and the look at its process still gives its thread'
# The first read of the output is taken before Codex writes its thread, and it returns once Codex has ended.
SLOW="$WORK/slow-head"; mkdir -p "$SLOW"
cat > "$SLOW/head" <<'EOF'
#!/usr/bin/env bash
real="$(PATH="$REAL_PATH" command -v head)"; last="${!#}"
if [ "${last%.out}" = "$last" ] || [ -e "$HEAD_MARK" ]; then exec "$real" "$@"; fi
content="$("$real" "$@")"; : > "$HEAD_MARK"
pid="$(cat "${last%.out}.pid")"
for _ in $(seq 1 100); do kill -0 "$pid" 2> /dev/null || break; sleep 0.05; done
printf '%s' "$content"
EOF
chmod +x "$SLOW/head"
race() {  # race <source tree> <number>: a Codex start whose first read of its output is stale
  rm -f "$WORK/head-mark"
  ( cd "$PROJECT" && HEAD_MARK="$WORK/head-mark" REAL_PATH="$PATH" PATH="$SLOW:$PATH" bash "$1/bin/start-phase.sh" build mechanical --issue o/r#7 --brief "$WORK/brief.md" --number "$2" --budget 100 ) 2> "$WORK/err"
}
out="$(race "$SRC" 10040)"; rc=$?
check 'the race: exit 0' 0 "$rc"
check 'the race: the thread is recorded' thread-1 "$(jq -r 'select(.kind == "native") | .nativeIdentity' "$SESSIONS/$(nameof "$out").start.jsonl" 2> /dev/null)"

echo 'a key tool runs with the key in the environment of that run alone'
order acme-key
FAKE_RUN_SECONDS=3 start build mechanical --issue o/r#7 --brief "$WORK/brief.md" --number 10009 --budget 100 > "$WORK/key.out"; rc=$?
kname="$(nameof "$(cat "$WORK/key.out")")"
check 'key: exit 0' 0 "$rc"
check 'key: the worker line names the key tool' yes "$(has "$(cat "$WORK/key.out")" "$kname acme-key build o/r#7: ")"
check 'key: the tuple' "$(last_selected)" "$(recorded "$kname")"
sleep 1
hidden="[${PREFIX:0:1}]${PREFIX:1}"
bash -c 'sleep 5; :' "$KEY" & leaker=$!
check 'planted: a process that holds the key in its arguments is found by the same grep' 1 "$(ps -eo args | grep -c -- "$hidden" || true)"
kill "$leaker" 2>/dev/null; wait "$leaker" 2>/dev/null
check 'key: while it runs, no process line holds the key' 0 "$(ps -eo args | grep -c -- "$hidden" || true)"
for _ in $(seq 1 50); do [ -f "$SESSIONS/$kname.exit" ] && break; sleep 0.2; done
check 'key: the run saw the key in its environment' "$PREFIX" "$(cat "$FAKE/key-prefix-seen")"
check 'key: the run asked for JSON' yes "$(grep -qF -- '--output-format json' "$FAKE/claude.args" && echo yes || echo no)"
check 'key: nothing the command wrote holds the key' 0 "$(cat "$SESSIONS/$kname".* "$WORK/key.out" "$WORK/err" 2>/dev/null | grep -c -F -- "$PREFIX" || true)"
check 'key: the key is in no argument of the fake' 0 "$(grep -c -F -- "$PREFIX" "$FAKE/claude.args" || true)"
echo 'planted: a leaked key is found by the same grep'
printf '%s\n' "$KEY" > "$WORK/leak.txt"
check 'the grep finds the planted leak' 1 "$(cat "$WORK/leak.txt" | grep -c -F -- "$PREFIX")"
chmod 644 "$STATE/secrets/acme-key"
out="$(start build mechanical --issue o/r#7 --brief "$WORK/brief.md" --number 10010 --budget 100)"; rc=$?
check 'a key with the wrong mode: exit 2' 2 "$rc"
check 'it names the mode' yes "$(grep -qF 'has mode 644, not 600' "$WORK/err" && echo yes || echo no)"
chmod 600 "$STATE/secrets/acme-key"

echo 'a resume re-selects and is refused where the tuple changed'
order claude
out="$(start build mechanical --issue o/r#7 --brief "$WORK/brief.md" --number 10011 --budget 100)"; rname="$(nameof "$out")"
out="$(cd "$PROJECT" && bash "$SRC/bin/start-phase.sh" --resume "$rname" "go on" 2> "$WORK/err")"; rc=$?
[ "$rc" = 0 ] || cat "$WORK/err" >&2
check 'resume: exit 0' 0 "$rc"
check 'resume: the worker line says it is a resume' yes "$(grep -Eq "^$rname claude build o/r#7: Brief: build a test thing \(deadline.*\), resumed\$" <<< "$out" && echo yes || echo no)"
native="$(jq -r 'select(.kind == "native") | .nativeIdentity' "$SESSIONS/$rname.start.jsonl" | head -n 1)"
check 'resume: it resumed the native session on the same tuple' yes "$(grep -qF -- "go on --bg --resume $native --model claude-sonnet-5-5 --effort high" "$FAKE/claude.args" && echo yes || echo no)"
check 'resume: the record holds a second attempt' 2 "$(jq -r 'select(.kind == "attempt")' "$SESSIONS/$rname.start.jsonl" | jq -s length)"
table claude-opus-5-5
out="$(cd "$PROJECT" && bash "$SRC/bin/start-phase.sh" --resume "$rname" "go on" 2> "$WORK/err")"; rc=$?
check 'a resume on a changed table: exit 2' 2 "$rc"
check 'it names both tuples' yes "$(grep -qF 'started on claude claude-sonnet-5-5 high and phase-model now selects claude claude-opus-5-5 high' "$WORK/err" && echo yes || echo no)"
table

echo 'a re-plan starts only on a plan-check NO or an owner decision, and writes its PHASE line'
phase_line='PHASE the area: plan | plan10001-opus | order not set | selected claude m high | plans 1 | reviews 0 | context fit | next | package o/r#7 | members o/r#7 | previous none'
comments() { jq -cn --argjson list "$1" '$list | to_entries | map({user:{login:"a"},created_at:"2026-10-30T09:00:00Z",html_url:"https://example.invalid/o/r/issues/7#issuecomment-\(.key + 1)",body:.value})' > "$FAKE/comments.json"; }
replan() { local reason=(); [ -z "$2" ] || reason=(--reason "$2"); start re-plan normal-hard --issue o/r#7 --brief "$WORK/brief.md" --number "$1" --budget 150 --package o/r#7 ${reason[@]+"${reason[@]}"}; }
comments "$(jq -cn --arg line "$phase_line" '[$line, "PLAN CHECK the area: NO\nGAPS: a wrong approach", "PLAN CHECK the area: GO\nREPAIRED: a citation", "A comment of nobody\nabout drift", "Owner'"'"'s yes, 2026-10-31, 01:50 Zurich, in the dialog\nre-plan the cut"]')"
order claude
: > "$FAKE/gh.calls"
out="$(replan 10012 '')"; rc=$?
check 're-plan without --reason: exit 2' 2 "$rc"
check 'it names the direct path' yes "$(grep -qF 'a build on the new base' "$WORK/err" && grep -qF 'an edit of the section by the coordinator' "$WORK/err" && echo yes || echo no)"
out="$(replan 10012 https://example.invalid/o/r/issues/7#issuecomment-3)"; rc=$?
check 're-plan on a GO verdict comment: exit 2' 2 "$rc"
check 'a GO verdict is no reason' yes "$(grep -qF 'is no reason for a re-plan' "$WORK/err" && echo yes || echo no)"
out="$(replan 10012 4)"; rc=$?
check 're-plan on an unrelated comment: exit 2' 2 "$rc"
out="$(replan 10012 99)"; rc=$?
check 're-plan on a comment the issue does not hold: exit 2' 2 "$rc"
check 'no re-plan session was written by a refusal' no "$(ls "$SESSIONS" | grep -q '^re-plan10012' && echo yes || echo no)"
check 'no PHASE line was posted by a refusal' no "$(ls "$FAKE"/posted.* >/dev/null 2>&1 && echo yes || echo no)"
: > "$FAKE/gh.calls"
out="$(replan 10012 https://example.invalid/o/r/issues/7#issuecomment-2)"; rc=$?
check 're-plan on a NO verdict comment: exit 0' 0 "$rc"
check 'the worker line is of a re-plan' yes "$(grep -Eq '^re-plan10012-fable5\.1-xhigh-150k-[0-9a-f]{5} claude re-plan o/r#7: ' <<< "$out" && echo yes || echo no)"
check 'the PHASE line was posted' 1 "$(grep -c -- '--jq .html_url' "$FAKE/gh.calls")"
check 'the posted line is the PHASE line of a re-plan, number 2, with the link to the reason' yes "$(cat "$FAKE"/posted.* | grep -q "^PHASE the area: re-plan | re-plan10012-fable5.1-xhigh-150k-[0-9a-f]* | order claude | selected claude claude-fable-5-1 xhigh | plans 2 | reviews 0 | context fit | re-plan number 2 of the package, reason https://example.invalid/o/r/issues/7#issuecomment-2 | package o/r#7 | members o/r#7 | previous none\$" && echo yes || echo no)"
out="$(replan 10013 5)"; rc=$?
check 're-plan on an owner decision comment by its number: exit 0' 0 "$rc"
check 'the owner decision comment started it' yes "$([ "$rc" = 0 ] && echo yes || echo no)"

echo 'the launch of each tool carries its folders, its profile and the identity of its native session'
EXTRA="$WORK/extra"; mkdir -p "$EXTRA"
export CODEX_HOME="$WORK/codex-home"; mkdir -p "$CODEX_HOME"
printf "[auto_review]\npolicy = \047\047\047\nfixture approval policy\n\047\047\047\n" > "$CODEX_HOME/ai-core.config.toml"
lines() { grep -vc "^agents " "$1" 2> /dev/null || echo 0; }
bounded() { jq -e -s 'all(.[]; (tojson | length) < 4095)' "$SESSIONS/$1.start.jsonl" > /dev/null && echo yes || echo no; }
kinds() { jq -r '.kind + ":" + .operation' "$SESSIONS/$1.start.jsonl" | paste -sd' ' -; }
observed_after_invoked() { jq -e -s 'all(.[]; .observed >= .invoked)' "$SESSIONS/$1.start.jsonl" > /dev/null && echo yes || echo no; }
order codex
: > "$FAKE/codex.args"
out="$(start build mechanical --issue o/r#7 --brief "$WORK/brief.md" --number 10020 --budget 100 --add-dir "$EXTRA")"; cx="$(nameof "$out")"
cargs="$(tail -n 1 "$FAKE/codex.args")"
check 'codex: the folder of the project, no git check, and the folders added' yes \
  "$(grep -qF -- "-C $PROJECT --skip-git-repo-check --add-dir $PROJECT --add-dir $STATE --add-dir $EXTRA --json" <<< "$cargs" && echo yes || echo no)"
check 'codex: standard input is /dev/null' /dev/null "$(cat "$FAKE/codex.stdin")"
check 'codex: an attempt, then the native session' 'attempt:start native:start' "$(kinds "$cx")"
check 'codex: every line of the record is bounded' yes "$(bounded "$cx")"
check 'codex: every line of the record is observed after the invocation' yes "$(observed_after_invoked "$cx")"
check 'codex: the native identity is the thread' thread-1 "$(jq -r 'select(.kind == "native") | .nativeIdentity' "$SESSIONS/$cx.start.jsonl")"
out="$(cd "$PROJECT" && bash "$SRC/bin/start-phase.sh" --resume "$cx" "continue" 2> "$WORK/err")"; rc=$?
[ "$rc" = 0 ] || cat "$WORK/err" >&2
rargs="$(tail -n 1 "$FAKE/codex.args")"
check 'codex resume: exit 0' 0 "$rc"
check 'codex resume: the thread, the selected model and effort, and no profile' yes \
  "$(grep -qF -- 'exec resume thread-1 -m gpt-6-astra -c model_reasoning_effort=xhigh --skip-git-repo-check' <<< "$rargs" && ! grep -qF -- ' -p ai-core' <<< "$rargs" && echo yes || echo no)"
check 'codex resume: the project, the state and the added folder are writable' yes \
  "$(grep -qF -- "sandbox_workspace_write.writable_roots=[\"$PROJECT\",\"$STATE\",\"$EXTRA\"]" <<< "$rargs" && echo yes || echo no)"
check 'codex resume: a second attempt and a second native line, one start' 'attempt:start native:start attempt:resume native:resume' "$(kinds "$cx")"

order agy
: > "$FAKE/agy.args"
out="$(start build mechanical --issue o/r#7 --brief "$WORK/brief.md" --number 10021 --budget 100 --add-dir "$EXTRA")"; ax="$(nameof "$out")"
for _ in $(seq 1 50); do [ -f "$SESSIONS/$ax.exit" ] && break; sleep 0.1; done
check 'agy: the selected model, accept-edits, the folders, JSON, and no effort' yes \
  "$(grep -qF -- "--model claude-sonnet-5-5-high --mode accept-edits --add-dir $PROJECT --add-dir $STATE --add-dir $EXTRA --output-format json" "$FAKE/agy.args" && ! grep -qF -- '--effort' "$FAKE/agy.args" && echo yes || echo no)"
check 'agy: it ran in the project' "$PROJECT" "$(cat "$FAKE/agy.cwd")"
jq -cn '{version:1,kind:"native",operation:"start",tool:"agy",model:"claude-sonnet-5-5-high",effort:"-",phase:"build",class:"mechanical",writer:"",invoked:1,observed:2,nativeIdentity:"conv-1"}' >> "$SESSIONS/$ax.start.jsonl"
out="$(cd "$PROJECT" && bash "$SRC/bin/start-phase.sh" --resume "$ax" "continue" 2> "$WORK/err")"; rc=$?
for _ in $(seq 1 50); do [ -f "$SESSIONS/$ax.exit" ] && break; sleep 0.1; done
check 'agy resume: exit 0' 0 "$rc"
check 'agy resume: the recorded conversation and the selected model, never --continue' yes \
  "$(tail -n 1 "$FAKE/agy.args" | grep -qF -- '--conversation conv-1' && tail -n 1 "$FAKE/agy.args" | grep -qF -- '--model claude-sonnet-5-5-high' && ! tail -n 1 "$FAKE/agy.args" | grep -qE -- ' (-c|--continue)( |$)' && echo yes || echo no)"
printf 'agy\tui-test\t*\tclaude-sonnet-5-5-high\t-\n' >> "$PROJECT/.ai-core/models.tsv"
out="$(start ui-test mechanical --issue o/r#7 --brief "$WORK/brief.md" --number 10022 --budget 100)"; ux="$(nameof "$out")"
for _ in $(seq 1 50); do [ -f "$SESSIONS/$ux.exit" ] && break; sleep 0.1; done
check 'agy UI test: it ran in its throwaway folder' "$SESSIONS/$ux.cwd" "$(cat "$FAKE/agy.cwd")"
check 'agy UI test: no folder of the project is added' no "$(tail -n 1 "$FAKE/agy.args" | grep -qF -- '--add-dir' && echo yes || echo no)"
table

order claude
: > "$FAKE/claude.args"
out="$(start build mechanical --issue o/r#7 --brief "$WORK/brief.md" --number 10023 --budget 100 --add-dir "$EXTRA")"; clx="$(nameof "$out")"
check 'claude: the window is the budget plus 100000, and the folders are added' yes \
  "$(grep -F -- '--bg --name' "$FAKE/claude.args" | tail -n 1 | grep -qF -- "--settings {\"autoCompactWindow\":200000} --strict-mcp-config --add-dir $SESSIONS --add-dir $PROJECT --add-dir $STATE --add-dir $EXTRA" && echo yes || echo no)"
check 'claude: an attempt, then the native session' 'attempt:start native:start' "$(kinds "$clx")"
out="$(cd "$PROJECT" && bash "$SRC/bin/start-phase.sh" --resume "$clx" "continue" 2> "$WORK/err")"; rc=$?
check 'claude resume: exit 0' 0 "$rc"
check 'claude resume: the folders of the start again' yes "$(grep -F -- '--resume' "$FAKE/claude.args" | tail -n 1 | grep -qF -- "--strict-mcp-config --add-dir $PROJECT --add-dir $STATE --add-dir $EXTRA" && echo yes || echo no)"
jq -c --arg name "$clx" 'map(if .name == $name then .status = "busy" else . end)' "$FAKE/agents.json" > "$FAKE/agents.next" && mv "$FAKE/agents.next" "$FAKE/agents.json"
before="$(lines "$FAKE/claude.args")"
out="$(cd "$PROJECT" && bash "$SRC/bin/start-phase.sh" --resume "$clx" "again" 2> "$WORK/err")"; rc=$?
check 'a conversation that still runs cannot resume: exit 2' 2 "$rc"
check 'it says so' yes "$(grep -qF 'no longer running' "$WORK/err" && echo yes || echo no)"
check 'and no tool ran for it' "$before" "$(lines "$FAKE/claude.args")"

echo 'a refused start runs no tool'
before="$(( $(lines "$FAKE/claude.args") + $(lines "$FAKE/codex.args") + $(lines "$FAKE/agy.args") ))"
start build mechanical --issue o/r#7 --brief "$WORK/brief.md" --number 10001 --budget 100 > /dev/null; rc=$?
start build mechanical --issue o/r#7 --brief "$WORK/brief.md" --number 10024 --budget 100 --model claude-opus-5-5 > /dev/null; rc2=$?
check 'a used number and a given model are refused' '2 2' "$rc $rc2"
check 'no tool ran for either' "$before" "$(( $(lines "$FAKE/claude.args") + $(lines "$FAKE/codex.args") + $(lines "$FAKE/agy.args") ))"
start plan mechanical --issue o/r#7 --brief "$WORK/brief.md" --number 10038 --budget 100 > /dev/null; rc=$?
check 'a selector that finds no row for the phase: exit 2' 2 "$rc"
check 'no tool ran for it' "$before" "$(( $(lines "$FAKE/claude.args") + $(lines "$FAKE/codex.args") + $(lines "$FAKE/agy.args") ))"
check 'no session of it was written' no "$(ls "$SESSIONS" | grep -q '^plan10038' && echo yes || echo no)"

echo 'planted defects in the command each turn a case red'
planted() {  # planted <name> <file> <sed script>: the command of a copy with one changed line, started on Claude Code
  local tree="$WORK/src-$1"
  rm -rf "$tree"; cp -R "$SRC" "$tree"; sed "$3" "$SRC/$2" > "$tree/$2"
  cmp -s "$SRC/$2" "$tree/$2" && { echo "the planted defect $1 changed nothing in $2"; failed=$((failed + 1)); }
  number=$((number + 1)); : > "$FAKE/claude.args"
  planted_out="$(cd "$PROJECT" && bash "$tree/bin/start-phase.sh" build mechanical --issue o/r#7 --brief "$WORK/brief.md" --number "$((number + 10100))" --budget 100 2> /dev/null)" || :
  planted_name="$(nameof "$planted_out")"
}
planted wrong-model lib/start-phase.sh 's/--model "$SP_MODEL" --effort "$SP_EFFORT" --permission-mode auto \\$/--model stale-model --effort "$SP_EFFORT" --permission-mode auto \\/'
check 'a start on another model than the selected one is seen' no "$(grep -F -- '--bg --name' "$FAKE/claude.args" | tail -n 1 | grep -qF -- '--model claude-sonnet-5-5 ' && echo yes || echo no)"
check 'the planted start did run, on the stale model' yes "$(grep -F -- '--bg --name' "$FAKE/claude.args" | tail -n 1 | grep -qF -- '--model stale-model ' && echo yes || echo no)"
planted no-native bin/start-phase.sh 's/^\[ -z "\$SP_NATIVE" \] || start_phase_observe native.*$/true/'
check 'a start that records no native session is seen' 'attempt:start' "$(kinds "$planted_name")"
planted no-attempt bin/start-phase.sh 's/^start_phase_observe attempt || exit 2$/true/'
check 'a start that records no attempt is seen' native:start "$(kinds "$planted_name")"
tree="$WORK/src-no-selector"; rm -rf "$tree"; cp -R "$SRC" "$tree"
sed 's/^selection="\$(bash "\$ROOT\/bin\/phase-model\.sh" "\${select_args\[@\]}")" || exit 2$/selection="claude claude-opus-5-5 high"/' "$SRC/bin/start-phase.sh" > "$tree/bin/start-phase.sh"
cmp -s "$SRC/bin/start-phase.sh" "$tree/bin/start-phase.sh" && { echo 'the planted selector defect changed nothing'; failed=$((failed + 1)); }
(cd "$PROJECT" && bash "$tree/bin/start-phase.sh" plan mechanical --issue o/r#7 --brief "$WORK/brief.md" --number 10039 --budget 100 > /dev/null 2>&1) || :
check 'a start that does not ask the selector runs where the selector finds no row, and is seen' yes "$(grep -qF -- '--bg --name plan10039-' "$FAKE/claude.args" && echo yes || echo no)"
order codex
tree="$WORK/src-no-resume-model"; rm -rf "$tree"; cp -R "$SRC" "$tree"
sed 's/codex exec resume "\$SP_NATIVE_ID" -m "\$SP_MODEL" -c "model_reasoning_effort=\$SP_EFFORT"/codex exec resume "$SP_NATIVE_ID"/' "$SRC/lib/start-phase.sh" > "$tree/lib/start-phase.sh"
cmp -s "$SRC/lib/start-phase.sh" "$tree/lib/start-phase.sh" && { echo 'the planted resume defect changed nothing'; failed=$((failed + 1)); }
(cd "$PROJECT" && bash "$tree/bin/start-phase.sh" --resume "$cx" "continue" > /dev/null 2>&1) || :
check 'a Codex resume without its model and effort is seen' no "$(tail -n 1 "$FAKE/codex.args" | grep -qF -- 'resume thread-1 -m gpt-6-astra -c model_reasoning_effort=xhigh' && echo yes || echo no)"
tree="$WORK/src-racy"; rm -rf "$tree"; cp -R "$SRC" "$tree"
sed -e '/^    alive=1; kill -0 /d' -e 's/if \[ "\$alive" = 0 \]; then/if ! kill -0 "$(cat "$SP_PID")" 2> \/dev\/null; then/' "$SRC/lib/start-phase.sh" > "$tree/lib/start-phase.sh"
cmp -s "$SRC/lib/start-phase.sh" "$tree/lib/start-phase.sh" && { echo 'the planted race changed nothing'; failed=$((failed + 1)); }
race "$tree" 10041 > /dev/null; rc=$?
check 'Codex looked at only after its stale output is seen as no evidence' '2 yes' "$rc $(has "$(cat "$WORK/err")" 'no native thread evidence')"
order claude

if [ "$failed" -ne 0 ]; then echo "start-phase: $failed checks failed"; exit 1; fi
echo "start-phase: all checks passed"
