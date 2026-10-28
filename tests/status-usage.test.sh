#!/usr/bin/env bash
# The usage line of the status page is the windows of the tool whose shell runs it, as lib/usage.sh reads them
# for `usage`, and the lines that only Claude Code's records can give say there is no source for any other tool.
# Also the token cache: a sibling folder is not this folder, a transcript that shrank or was replaced is read
# anew, and the cache is replaced whole, never rewritten in place.
#
#   bash tests/status-usage.test.sh
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export HOME="$work/home" AI_CORE_HOME="$work/home" AI_CORE_TRANSCRIPTS="$work/transcripts" CODEX_HOME="$work/codex"
export AI_CORE_NOW=1790000000 TZ=UTC
. "$root/tests/tool-environment.sh"
now=$AI_CORE_NOW
folder="$work/project"
mkdir -p "$HOME/.ai-core" "$AI_CORE_TRANSCRIPTS" "$folder" "$work/agy-bin"
: > "$work/items"
printf 'Done\n' > "$work/columns"
failed=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1: expected $2; got $3"; failed=$((failed + 1)); fi
}
when() { LC_ALL=C date -u -d "@$1" '+%a %d.%m. %H:%M' 2>/dev/null || LC_ALL=C date -u -r "$1" '+%a %d.%m. %H:%M'; }
iso() { LC_ALL=C date -u -d "@$1" '+%Y-%m-%dT%H:%M:%S.000Z' 2>/dev/null || LC_ALL=C date -u -r "$1" '+%Y-%m-%dT%H:%M:%S.000Z'; }
inode() { stat -c %i "$1" 2>/dev/null || stat -f %i "$1"; }
# snapshot <tool>: the structured reading of lib/usage.sh that bin/status.sh hands over, in $work/snapshot.json
snapshot() { bash -c '. "$1/lib/usage.sh"; usage_snapshot "$2"' _ "$root" "$1" > "$work/snapshot.json"; }
page() {
  node "$root/lib/status.mjs" --items-file "$work/items" --columns-file "$work/columns" \
    --board example-org/1 --folder "$folder" --stop-at 92 --usage-file "$work/snapshot.json" --tokens
}
line() { grep -m1 -F -- "$1" <<< "$out" | tr -s ' '; }

echo 'Claude: a record that cannot be used is named, a usable one is read as usage reads it'
claude_page() {
  printf '{"recorded_at":%s,"rate_limits":{"five_hour":%s}}\n' "$now" "$1" > "$HOME/.ai-core/usage.json"
  snapshot claude; out="$(page)"; rc=$?
}
for window in '{"resets_at":1790003600}' '{"used_percentage":null,"resets_at":1790003600}' \
  '{"used_percentage":"5","resets_at":1790003600}' '{"used_percentage":-5,"resets_at":1790003600}' \
  '{"used_percentage":5}' '{"used_percentage":5,"resets_at":123.5}'; do
  claude_page "$window"
  check "invalid quota $window" '0 1' "$rc $(grep -c "^usage   Claude: .*usage.json: .*window five_hour" <<< "$out")"
done
claude_page '{"used_percentage":0,"resets_at":1790003600}'
check 'a real zero remains numeric' "usage 5h 0 % used (reset $(when 1790003600)) · limit 92 % used" "$(line 'usage ')"
claude_page '{"used_percentage":95,"resets_at":1789996400}'
check 'a valid expired window counts as reset' "usage 5h 0 % used (reset $(when 1789996400)) · limit 92 % used" "$(line 'usage ')"
claude_page '{"used_percentage":106,"resets_at":1790003600}'
check 'a window over its limit, as Claude reports it, is read as it is' "usage 5h 106 % used (reset $(when 1790003600)) · limit 92 % used" "$(line 'usage ')"
printf '{"recorded_at":%s,"rate_limits":{"seven_day":null,"five_hour":{"used_percentage":5,"resets_at":1790003600}}}\n' "$now" > "$HOME/.ai-core/usage.json"
snapshot claude; out="$(page)"
check 'a null window beside a usable one (innocent)' "usage 5h 5 % used (reset $(when 1790003600)) · limit 92 % used" "$(line 'usage ')"
printf '{"recorded_at":%s,"rate_limits":{"five_hour":null}}\n' "$now" > "$HOME/.ai-core/usage.json"
snapshot claude; out="$(page)"
check 'a record with no window is named' 1 "$(grep -c '^usage   Claude: .*rate_limits holds no window' <<< "$out")"
rm -f "$HOME/.ai-core/usage.json"
snapshot claude; out="$(page)"
check 'nothing recorded is named' 'usage Claude: no usage recorded yet: the status line records it once a session has had an answer · limit 92 % used' "$(line 'usage ')"
printf '{"recorded_at":%s,"rate_limits":{"five_hour":{"used_percentage":5,"resets_at":1790003600}}}\n' "$now" > "$HOME/.ai-core/usage.json"
printf 'not a line of the history\n' > "$HOME/.ai-core/usage.log"
snapshot claude; out="$(page)"
check 'a history that cannot be read is named on the usage line' 1 "$(grep -c '^usage   Claude: malformed usage history at ' <<< "$out")"
check 'and the cost says the windows were not read, not that the status line logged for less than two hours' \
  'cost not measured: the windows of Claude were not read, as the usage line says' "$(line 'cost ')"
rm -f "$HOME/.ai-core/usage.json" "$HOME/.ai-core/usage.log"

echo 'Codex: its windows, named and marked used, with the time of the record; no figure of Claude among them'
sessions="$CODEX_HOME/sessions/2026/09/21"; mkdir -p "$sessions"
printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":5,"window_minutes":10080,"resets_at":%s},"secondary":{"used_percent":21,"window_minutes":300,"resets_at":%s}}}}\n' \
  "$(iso $((now - 600)))" $((now + 400000)) $((now + 3600)) > "$sessions/rollout-a.jsonl"
printf '{"recorded_at":%s,"rate_limits":{"five_hour":{"used_percentage":98,"resets_at":%s},"seven_day":{"used_percentage":97,"resets_at":%s}}}\n' "$now" $((now + 3600)) $((now + 400000)) > "$HOME/.ai-core/usage.json"
printf '%s 1 %s 90 %s\n%s 98 %s 97 %s\n' $((now - 20000)) $((now + 3600)) $((now + 400000)) "$now" $((now + 3600)) $((now + 400000)) > "$HOME/.ai-core/usage.log"
transcripts="$AI_CORE_TRANSCRIPTS/$(printf '%s' "$folder" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$transcripts"
answer() {  # answer <epoch> <cwd> <message id> <input> <output> <cache creation> <cache read>
  printf '{"type":"assistant","timestamp":"%s","cwd":"%s","message":{"id":"%s","usage":{"input_tokens":%s,"output_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s}}}\n' "$(iso "$1")" "${@:2}"
}
answer $((now - 1800)) "$folder" c1 7000 0 0 500 > "$transcripts/claude-session.jsonl"
snapshot codex; out="$(page)"
check 'Codex at 21 % used, as usage prints it' "usage Codex week 5 % used (reset $(when $((now + 400000)))) · 5h 21 % used (reset $(when $((now + 3600)))) · recorded $(when $((now - 600))) · limit 92 % used" "$(line 'usage ')"
check 'the cost has no source for Codex, not Claude'"'"'s rise of 98 %' 'cost no source for Codex' "$(line 'cost ')"
check 'the tokens have no source for Codex, not the 7k of the Claude session' 'tokens no source for Codex' "$(line 'tokens ')"
check 'the context has no source for Codex' 'context no source for Codex' "$(line 'context ')"
check 'the pace is a board figure and says so' 'pace 0 issues closed on the board in the last 24 hours, 0.0 a day over 14 days' "$(line 'pace ')"
check 'no number of Claude is on the page' 0 "$(grep -c '98 %\|97 %\|7k\|7000' <<< "$out")"
echo 'at the clock of the machine, the same record: 21 % used on the page and in usage'
real=$(date +%s)
printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":null,"secondary":{"used_percent":21,"window_minutes":300,"resets_at":%s}}}}\n' \
  "$(iso $((real - 5)))" $((real + 3600)) > "$sessions/rollout-z.jsonl"
touch "$sessions/rollout-z.jsonl"
snapshot codex; out="$(AI_CORE_NOW=$real page)"
check 'the page says 21 % used' 1 "$(grep -c '^usage   Codex 5h 21 % used' <<< "$out")"
check 'usage says 21 % used' 1 "$(bash "$root/bin/usage.sh" --tool codex 2>/dev/null | grep -c '^five_hour   21 % used')"
rm "$sessions/rollout-z.jsonl"
echo 'a Codex window with no length says nothing, and an expired one counts as reset'
printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":40,"window_minutes":300,"resets_at":%s},"secondary":{"used_percent":0.0,"window_minutes":0,"resets_at":%s}}}}\n' \
  "$(iso $((now - 60)))" $((now - 10)) $((now + 3600)) > "$sessions/rollout-b.jsonl"
snapshot codex; out="$(page)"
check 'only the real window, as reset' "usage Codex 5h 0 % used (reset $(when $((now - 10)))) · recorded $(when $((now - 60))) · limit 92 % used" "$(line 'usage ')"
rm -rf "$CODEX_HOME"
snapshot codex; out="$(page)"
check 'no Codex session file: named, with no Claude window in its place' 'usage Codex: no usage recorded yet: Codex records it in its session files once a session has had an answer · limit 92 % used' "$(line 'usage ')"

echo 'agy: its groups, never one model'"'"'s figure'
reset_stamp="$(LC_ALL=C date -u -d "@$((now + 3600))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || LC_ALL=C date -u -r "$((now + 3600))" '+%Y-%m-%dT%H:%M:%SZ')"
cat > "$work/agy-bin/agy" <<TOOL
#!/usr/bin/env bash
echo '{"status":"SUCCESS","command":{"data":{"groups":[{"name":"Gemini Models","description":"Models: Gemini","buckets":[{"id":"g5","window":"5h","remaining_fraction":0.75,"reset_time":"$reset_stamp"}]},{"name":"Other Models","description":"Models: Other","buckets":[{"id":"o5","window":"5h","remaining_fraction":0.5,"reset_time":"$reset_stamp"}]}]}}}'
TOOL
chmod +x "$work/agy-bin/agy"
PATH="$work/agy-bin:$PATH" snapshot agy; out="$(page)"
check 'every group a window, as used' "usage agy Gemini Models: five_hour 25 % used (reset $(when $((now + 3600)))) · Other Models: five_hour 50 % used (reset $(when $((now + 3600)))) · recorded $(when "$(jq -r .recorded "$work/snapshot.json")") · limit 92 % used" "$(line 'usage ')"
check 'and its tokens have no source for agy' 'tokens no source for agy' "$(line 'tokens ')"

echo 'a tool with no quota reader is named, never read as Claude'
snapshot gemini; out="$(page)"
check 'gemini' 'usage Gemini: usage does not read the quota of gemini · limit 92 % used' "$(line 'usage ')"
check 'and its cost' 'cost no source for Gemini' "$(line 'cost ')"

echo 'Claude: the figures as they were, from its records'
printf '{"recorded_at":%s,"rate_limits":{"five_hour":{"used_percentage":25,"resets_at":%s},"seven_day":{"used_percentage":89,"resets_at":%s}}}\n' "$now" $((now + 3600)) $((now + 400000)) > "$HOME/.ai-core/usage.json"
snapshot claude; out="$(page)"
check 'the usage' "usage 5h 25 % used (reset $(when $((now + 3600)))) · week 89 % used (reset $(when $((now + 400000)))) · limit 92 % used" "$(line 'usage ')"
check 'the tokens' 'tokens in 24 hours the sessions of this folder used 7k fresh and read 500 from the cache, and closed no issue' "$(line 'tokens ')"

echo 'the token cache'
rm -f "$HOME"/.ai-core/tokens*.json
fresh_of() { sed -n 's/^tokens .*used \([0-9k]*\) fresh.*/\1/p' <<< "$out" | head -1; }
cache="$HOME/.ai-core/tokens$(printf '%s' "$folder" | sed 's/[^A-Za-z0-9]/-/g').json"
: > "$transcripts/claude-session.jsonl"
for i in 1 2 3; do answer $((now - 1800)) "$folder" "m$i" 100 0 0 0; done >> "$transcripts/claude-session.jsonl"
out="$(page)"
check 'three answers of this folder' 300 "$(fresh_of)"
sibling="$AI_CORE_TRANSCRIPTS/$(printf '%s' "$folder-other" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$sibling"; answer $((now - 1800)) "$folder-other" s1 1000 0 0 0 > "$sibling/session.jsonl"
out="$(page)"
check 'a sibling folder whose name begins with this one'"'"'s is not this folder: a sibling folder is not counted' 300 "$(fresh_of)"
beneath="$AI_CORE_TRANSCRIPTS/$(printf '%s' "$folder/.worktrees/repo/issue-1-fix" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$beneath"; answer $((now - 1800)) "$folder/.worktrees/repo/issue-1-fix" w1 50 0 0 0 > "$beneath/session.jsonl"
out="$(page)"
check 'a worktree of this folder is this folder (innocent)' 350 "$(fresh_of)"
out="$(page)"
check 'a second read adds nothing' 350 "$(fresh_of)"
ino_before="$(inode "$cache")"
answer $((now - 1700)) "$folder" m4 25 0 0 0 >> "$transcripts/claude-session.jsonl"
out="$(page)"
check 'an answer appended is read on from where the last run stopped' 375 "$(fresh_of)"
check 'the cache is replaced whole, a new file beside the old, never written in place' yes "$([ "$ino_before" != "$(inode "$cache")" ] && echo yes || echo no)"
check 'and no temporary file is left' 0 "$(ls "$HOME/.ai-core" | grep -c '\.tmp$')"
answer $((now - 1800)) "$folder" n1 10 0 0 0 > "$transcripts/claude-session.jsonl"
out="$(page)"
check 'a transcript that shrank is read anew: a truncated transcript is counted anew' 60 "$(fresh_of)"
for i in 1 2 3 4 5 6; do answer $((now - 1800)) "$folder" "r$i" 20 0 0 0; done > "$work/replacement.jsonl"
mv "$work/replacement.jsonl" "$transcripts/claude-session.jsonl"
out="$(page)"
check 'a transcript replaced by a longer one is read anew, none of the old counts kept: a replaced transcript is counted anew' 170 "$(fresh_of)"

echo 'two runs at once over growing transcripts: both pages whole, the totals not doubled, the cache whole JSON'
rm -f "$cache" "$transcripts"/*.jsonl "$sibling"/*.jsonl "$beneath"/*.jsonl
for i in $(seq 1 400); do answer $((now - 1800)) "$folder" "g$i" 10 0 0 0; done > "$transcripts/growing.jsonl"
for round in 1 2 3; do
  ( page > "$work/run1.out" 2>&1 ) & first=$!
  ( page > "$work/run2.out" 2>&1 ) & second=$!
  wait "$first" "$second"
  for i in $(seq 1 100); do answer $((now - 1700)) "$folder" "h$round-$i" 10 0 0 0; done >> "$transcripts/growing.jsonl"
done
out="$(page 2>&1)"
check 'the cache is one whole JSON object' yes "$(jq -e 'type == "object"' "$cache" > /dev/null 2>&1 && echo yes || echo no)"
check 'the last page counts every answer once: 700 answers of 10 fresh tokens' '7k' "$(fresh_of)"
check 'both concurrent pages were whole' '1 1' "$(grep -c '^tokens ' "$work/run1.out") $(grep -c '^tokens ' "$work/run2.out")"

[ "$failed" -eq 0 ] || { echo "$failed failed"; exit 1; }
echo 'all status usage cases passed'
