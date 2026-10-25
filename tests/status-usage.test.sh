#!/usr/bin/env bash
# The status page reads the same Claude quota contract as usage; missing numbers are unknown.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export HOME="$work/home" AI_CORE_HOME="$work/home" AI_CORE_TRANSCRIPTS="$work/transcripts" CODEX_HOME="$work/codex"
export AI_CORE_NOW=1790000000 TZ=UTC
mkdir -p "$HOME/.ai-core" "$AI_CORE_TRANSCRIPTS" "$work/project"
: > "$work/items"
printf 'Done\n' > "$work/columns"
failed=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1: expected $2; got $3"; failed=$((failed + 1)); fi
}
page() {
  printf '{"rate_limits":{"five_hour":%s}}\n' "$1" > "$HOME/.ai-core/usage.json"
  node "$root/lib/status.mjs" --items-file "$work/items" --columns-file "$work/columns" \
    --board example-org/1 --folder "$work/project" --stop-at 92 --tokens
}
for window in '{"resets_at":1790003600}' '{"used_percentage":null,"resets_at":1790003600}' \
  '{"used_percentage":"5","resets_at":1790003600}' '{"used_percentage":-5,"resets_at":1790003600}' \
  '{"used_percentage":5}' '{"used_percentage":5,"resets_at":123.5}'; do
  out="$(page "$window")"; rc=$?
  check "invalid quota $window" '0 1' "$rc $(grep -c '^usage   5h unknown (invalid quota record)' <<< "$out")"
done
out="$(page '{"used_percentage":0,"resets_at":1790003600}')"
check 'a real zero remains numeric' 1 "$(grep -c '^usage   5h 0 % (reset ' <<< "$out")"
out="$(page '{"used_percentage":95,"resets_at":1789996400}')"
check 'a valid expired window counts as reset' 1 "$(grep -c '^usage   5h 0 % (reset ' <<< "$out")"
out="$(page '{"used_percentage":106,"resets_at":1790003600}')"
check 'a window over its limit, as Claude reports it, is read as it is' 1 "$(grep -c '^usage   5h 106 % (reset ' <<< "$out")"
out="$(page null)"
check 'a null window remains not recorded' 1 "$(grep -c '^usage   5h not recorded' <<< "$out")"
[ "$failed" -eq 0 ] || { echo "$failed failed"; exit 1; }
echo 'all status quota cases passed'
