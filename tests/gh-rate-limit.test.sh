#!/usr/bin/env bash
# What the commands do when GitHub refuses a call with a rate limit: the GraphQL limit for bursts
# (the secondary limit, "API rate limit already exceeded" while points are left) and the spent
# budget (the primary limit). The wait and the retries live in lib/board.sh, in the function that
# shadows gh, so a status move stands for every command here.
#
# Run with a FAKE gh on PATH, and a recorder in place of sleep (AI_CORE_SLEEP), so the suite waits
# for nothing and the seconds a command would have waited are read from the record.
#
#   bash tests/gh-rate-limit.test.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAKE="$(mktemp -d)"
trap 'rm -rf "$FAKE"' EXIT
export FAKE GH_ORG=example-org GH_CACHE_DIRECTORY="$FAKE/cache"
mkdir -p "$GH_CACHE_DIRECTORY/7" "$FAKE/bin"
echo PVT_epic7 > "$GH_CACHE_DIRECTORY/7/project-id"
printf 'Status\tF1\ttodo\tO1\nStatus\tF1\timplementing\tO2\nStatus\tF1\ttesting\tO3\nStatus\tF1\tdone\tO4\n' > "$GH_CACHE_DIRECTORY/7/fields.tsv"

# The card move is refused while $FAKE/refusals still counts down; what the refusal says is in
# $FAKE/refusal, what a rateLimit question answers is in $FAKE/probe.
cat > "$FAKE/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" | tr '\n' ' ' >> "$FAKE/calls"; printf '\n' >> "$FAKE/calls"
case "$*" in
  *rateLimit*)  cat "$FAKE/probe"; exit 0 ;;
  *rate_limit*) cat "$FAKE/probe-rest"; exit 0 ;;
  *updateProjectV2ItemFieldValue*)
    n=$(( $(cat "$FAKE/mutations") + 1 )); echo "$n" > "$FAKE/mutations"
    if [ -e "$FAKE/hang" ]; then : > "$FAKE/running"; sleep 30; fi
    if [ "$n" -le "$(cat "$FAKE/refusals")" ]; then
      cat "$FAKE/refusal"; cat "$FAKE/refusal-err" >&2; exit 1
    fi
    echo '{}'; exit 0 ;;
  *includeArchived*) printf 'PVT_epic7\tPVTI_card3\n'; exit 0 ;;
  *'parent {'*)      exit 0 ;;
esac
echo "the stand-in gh has no answer for: $*" >&2; exit 9
EOF
chmod +x "$FAKE/bin/gh"
cat > "$FAKE/bin/record-sleep" <<'EOF'
#!/usr/bin/env bash
echo "$1" >> "$FAKE/slept"
EOF
chmod +x "$FAKE/bin/record-sleep"
export PATH="$FAKE/bin:$PATH" AI_CORE_SLEEP="$FAKE/bin/record-sleep"

failed=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: [$2]"; echo "       actual:   [$3]"; failed=$((failed + 1)); fi
}

SECONDARY='{"message":"API rate limit already exceeded for user ID 1."}'
SECONDARY_ERR='gh: API rate limit already exceeded for user ID 1. (HTTP 403)'
iso_in() { date -u -d "@$(( $(date +%s) + $1 ))" +%Y-%m-%dT%H:%M:%SZ; }
probe_json() {  # probe_json <remaining> <resetAt>
  printf '{"data":{"rateLimit":{"remaining":%s,"resetAt":"%s"}}}' "$1" "$2"
}
probe_rest() {  # probe_rest <remaining> <seconds until the reset>
  printf '{"resources":{"core":{"remaining":%s,"reset":%s}}}' "$1" "$(( $(date +%s) + $2 ))"
}
# scene <refusals> <refusal on stdout> <refusal on stderr> <what a rateLimit question answers> [REST answer]
scene() {
  : > "$FAKE/calls"; : > "$FAKE/slept"; rm -f "$FAKE/hang" "$FAKE/running"
  echo 0 > "$FAKE/mutations"; echo "$1" > "$FAKE/refusals"
  printf '%s\n' "$2" > "$FAKE/refusal"; printf '%s\n' "$3" > "$FAKE/refusal-err"; printf '%s\n' "$4" > "$FAKE/probe"
  printf '%s\n' "${5:-$(probe_rest 4000 3000)}" > "$FAKE/probe-rest"
}
move() { bash "$ROOT/bin/issue-status.sh" --project 7 example-org/example-repo 3 testing 2>&1; }
slept() { tr '\n' ' ' < "$FAKE/slept" | sed 's/ $//'; }

echo 'the secondary limit lifts after two refusals: the move is repeated and goes through'
scene 2 "$SECONDARY" "$SECONDARY_ERR" "$(probe_json 4100 "$(iso_in 3000)")"
out="$(move)"; rc=$?
check 'exit 0'                   0 "$rc"
check 'the card moved'           '#3 -> testing' "$(grep '^#3' <<< "$out")"
check 'the mutation was sent three times' 3 "$(cat "$FAKE/mutations")"
check 'a minute, then two'       '60 120' "$(slept)"
check 'the wait names the limit' yes "$(grep -q "waiting 60s for GitHub's secondary rate limit (try 1 of 3)" <<< "$out" && echo yes || echo no)"

echo 'a spent budget is waited out until the reset GraphQL names'
scene 1 "$SECONDARY" "$SECONDARY_ERR" "$(probe_json 0 "$(iso_in 90)")"
out="$(move)"; rc=$?
check 'exit 0'                   0 "$rc"
check 'about ninety seconds'     yes "$([ "$(slept)" -ge 88 ] && [ "$(slept)" -le 92 ] && echo yes || echo no)"
check 'the wait names the primary limit' yes "$(grep -q "GitHub's primary GraphQL rate limit (spent until " <<< "$out" && echo yes || echo no)"

echo 'a reset further away than the wait may last stops at once and names the limit'
scene 1 "$SECONDARY" "$SECONDARY_ERR" "$(probe_json 0 "$(iso_in 3600)")"
out="$(move)"; rc=$?
check 'exit nonzero'             yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'it did not wait'          '' "$(slept)"
check 'the mutation was sent once' 1 "$(cat "$FAKE/mutations")"
check 'it names the primary limit' yes "$(grep -q "GitHub's primary GraphQL rate limit (spent until .*) refuses and does not lift within 900 seconds" <<< "$out" && echo yes || echo no)"

echo 'a refusal that never lifts stops after its bounded retries and names the secondary limit'
scene 99 "$SECONDARY" "$SECONDARY_ERR" "$(probe_json 4100 "$(iso_in 3000)")"
out="$(move)"; rc=$?
check 'exit nonzero'             yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'three waits, doubling'    '60 120 240' "$(slept)"
check 'the first try and three more' 4 "$(cat "$FAKE/mutations")"
check 'it names the secondary limit' yes "$(grep -q "GitHub's secondary rate limit still refuses after 3 waits" <<< "$out" && echo yes || echo no)"

echo 'a probe that gets no answer is treated as the secondary limit'
scene 1 "$SECONDARY" "$SECONDARY_ERR" 'not json'
out="$(move)"; rc=$?
check 'exit 0'                   0 "$rc"
check 'a minute'                 60 "$(slept)"

echo 'a refusal that is no rate limit is not repeated'
scene 1 '{"message":"Could not resolve to a node with the global id of x"}' 'gh: Could not resolve to a node (HTTP 404)' "$(probe_json 4100 "$(iso_in 3000)")"
out="$(move)"; rc=$?
check 'exit nonzero'             yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'no wait'                  '' "$(slept)"
check 'sent once'                1 "$(cat "$FAKE/mutations")"

echo 'a spent REST budget is told from the limit for bursts, and waited out until its reset'
scene 1 "$SECONDARY" "$SECONDARY_ERR" "$(probe_json 4100 "$(iso_in 3000)")" "$(probe_rest 0 60)"
out="$(move)"; rc=$?
check 'exit 0'                   0 "$rc"
check 'about a minute'           yes "$([ "$(slept)" -ge 58 ] && [ "$(slept)" -le 62 ] && echo yes || echo no)"
check 'it names the REST limit'  yes "$(grep -q "GitHub's primary REST rate limit (spent until " <<< "$out" && echo yes || echo no)"

echo 'a failure that only quotes the limit on stdout is not repeated'
scene 1 "$SECONDARY" 'gh: HTTP 502: Bad Gateway' "$(probe_json 4100 "$(iso_in 3000)")"
out="$(move)"; rc=$?
check 'exit nonzero'             yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'no wait'                  '' "$(slept)"
check 'sent once'                1 "$(cat "$FAKE/mutations")"

echo 'an interrupted call leaves no temporary file behind'
mkdir -p "$FAKE/tmp"; scene 0 '' '' "$(probe_json 4100 "$(iso_in 3000)")"; touch "$FAKE/hang"
( cd "$ROOT" && TMPDIR="$FAKE/tmp" exec setsid bash bin/issue-status.sh --project 7 example-org/example-repo 3 testing >/dev/null 2>&1 ) &
mover=$!
for _ in $(seq 1 100); do [ -e "$FAKE/running" ] && break; sleep 0.1; done
check 'the call was running'     yes "$([ -e "$FAKE/running" ] && echo yes || echo no)"
kill -TERM -- "-$mover" 2>/dev/null || true   # the whole process group, the stand-in's sleep with it
wait "$mover" 2>/dev/null
check 'nothing left in TMPDIR'   0 "$(ls "$FAKE/tmp" | wc -l | tr -d ' ')"
rm -f "$FAKE/hang"

echo 'session-start reads the thread of its issue through a refusal that lifts: the JSON is the thread alone'
mkdir -p "$FAKE/ss/bin"
cat > "$FAKE/ss/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"repos/{owner}/{repo}"*) echo example-org/example-repo ;;
  *comments*) echo '[]' ;;
  *issues/5*)
    if [ -e "$FAKE/ss/refuse-once" ]; then rm -f "$FAKE/ss/refuse-once"; echo '{"message":"API rate limit already exceeded for user ID 1."}'; echo 'gh: API rate limit already exceeded for user ID 1. (HTTP 403)' >&2; exit 1; fi
    echo '{"number":5,"title":"Read the board whole","state":"open","labels":[],"assignees":[{"login":"t"}],"body":"b"}' ;;
  *) echo '{}' ;;
esac
EOF
chmod +x "$FAKE/ss/bin/gh"
printf 'claude\tmode\talways\t-\t-\n' > "$FAKE/ss/modes.tsv"
git -c init.defaultBranch=issue-5-board init -q "$FAKE/ss/repo"
git -C "$FAKE/ss/repo" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m first
touch "$FAKE/ss/refuse-once"
out="$(cd "$FAKE/ss/repo" && PATH="$FAKE/ss/bin:$PATH" AI_CORE_UPDATE_CHECK=never TEAM_MODES_FILE="$FAKE/ss/modes.tsv" bash "$ROOT/bin/session-start.sh" --json 2>/dev/null)"
check 'the refusal was used up'  no "$([ -e "$FAKE/ss/refuse-once" ] && echo yes || echo no)"
check 'the thread is the issue'  'Read the board whole' "$(jq -r '.thread.title' <<< "$out" 2>/dev/null)"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
