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
  *rateLimit*) cat "$FAKE/probe"; exit 0 ;;
  *updateProjectV2ItemFieldValue*)
    n=$(( $(cat "$FAKE/mutations") + 1 )); echo "$n" > "$FAKE/mutations"
    if [ "$n" -le "$(cat "$FAKE/refusals")" ]; then
      cat "$FAKE/refusal"; echo "gh: $(head -n1 "$FAKE/refusal")" >&2; exit 1
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
iso_in() { date -u -d "@$(( $(date +%s) + $1 ))" +%Y-%m-%dT%H:%M:%SZ; }
# scene <refusals> <refusal text> <what a rateLimit question answers>
scene() {
  : > "$FAKE/calls"; : > "$FAKE/slept"
  echo 0 > "$FAKE/mutations"; echo "$1" > "$FAKE/refusals"
  printf '%s\n' "$2" > "$FAKE/refusal"; printf '%s\n' "$3" > "$FAKE/probe"
}
probe_json() {  # probe_json <remaining> <resetAt>
  printf '{"data":{"rateLimit":{"remaining":%s,"resetAt":"%s"}}}' "$1" "$2"
}
move() { bash "$ROOT/bin/issue-status.sh" --project 7 example-org/example-repo 3 testing 2>&1; }
slept() { tr '\n' ' ' < "$FAKE/slept" | sed 's/ $//'; }

echo 'the secondary limit lifts after two refusals: the move is repeated and goes through'
scene 2 "$SECONDARY" "$(probe_json 4100 "$(iso_in 3000)")"
out="$(move)"; rc=$?
check 'exit 0'                   0 "$rc"
check 'the card moved'           '#3 -> testing' "$(grep '^#3' <<< "$out")"
check 'the mutation was sent three times' 3 "$(cat "$FAKE/mutations")"
check 'a minute, then two'       '60 120' "$(slept)"
check 'the wait names the limit' yes "$(grep -q "waiting 60s for GitHub's secondary rate limit (try 1 of 3)" <<< "$out" && echo yes || echo no)"

echo 'a refusal that names its retry-after is waited for that long'
scene 1 "$SECONDARY
Retry-After: 7" "$(probe_json 4100 "$(iso_in 3000)")"
out="$(move)"; rc=$?
check 'exit 0'                   0 "$rc"
check 'seven seconds'            7 "$(slept)"

echo 'a spent budget is waited out until the reset GraphQL names'
scene 1 "$SECONDARY" "$(probe_json 0 "$(iso_in 90)")"
out="$(move)"; rc=$?
check 'exit 0'                   0 "$rc"
check 'about ninety seconds'     yes "$([ "$(slept)" -ge 88 ] && [ "$(slept)" -le 92 ] && echo yes || echo no)"
check 'the wait names the primary limit' yes "$(grep -q "GitHub's primary rate limit (spent until " <<< "$out" && echo yes || echo no)"

echo 'a reset further away than the wait may last stops at once and names the limit'
scene 1 "$SECONDARY" "$(probe_json 0 "$(iso_in 3600)")"
out="$(move)"; rc=$?
check 'exit nonzero'             yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'it did not wait'          '' "$(slept)"
check 'the mutation was sent once' 1 "$(cat "$FAKE/mutations")"
check 'it names the primary limit' yes "$(grep -q "GitHub's primary rate limit (spent until .*) refuses and does not lift within 900 seconds" <<< "$out" && echo yes || echo no)"

echo 'a refusal that never lifts stops after its bounded retries and names the secondary limit'
scene 99 "$SECONDARY" "$(probe_json 4100 "$(iso_in 3000)")"
out="$(move)"; rc=$?
check 'exit nonzero'             yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'three waits, doubling'    '60 120 240' "$(slept)"
check 'the first try and three more' 4 "$(cat "$FAKE/mutations")"
check 'it names the secondary limit' yes "$(grep -q "GitHub's secondary rate limit still refuses after 3 waits" <<< "$out" && echo yes || echo no)"

echo 'a probe that gets no answer is treated as the secondary limit'
scene 1 "$SECONDARY" 'not json'
out="$(move)"; rc=$?
check 'exit 0'                   0 "$rc"
check 'a minute'                 60 "$(slept)"

echo 'a refusal that is no rate limit is not repeated'
scene 1 '{"message":"Could not resolve to a node with the global id of x"}' "$(probe_json 4100 "$(iso_in 3000)")"
out="$(move)"; rc=$?
check 'exit nonzero'             yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'no wait'                  '' "$(slept)"
check 'sent once'                1 "$(cat "$FAKE/mutations")"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
