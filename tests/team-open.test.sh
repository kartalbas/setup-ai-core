#!/usr/bin/env bash
# What team-open.sh opens for a project folder, read off a stand-in terminal: no window opens.
#
#   bash tests/team-open.test.sh

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fake="$(mktemp -d)"
trap 'rm -rf "$fake"' EXIT
mkdir -p "$fake/bin" "$fake/repos/digitaplatform"
calls="$fake/calls.txt"
cat > "$fake/bin/ptyxis" <<STUB
#!/usr/bin/env bash
printf '%s|' "\$@" >> "$calls"; printf '\n' >> "$calls"
STUB
chmod +x "$fake/bin/ptyxis"

failed=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}
run() { PATH="$fake/bin:$PATH" AI_CORE_TERMINAL="${TERMINAL_WANTED:-ptyxis}" bash "$root/bin/team-open.sh" "$@" 2>&1; }
project="$(cd "$fake/repos/digitaplatform" && pwd)"

echo 'the team of a folder, each named after the first three letters of it'
out="$(run "$project" --dry-run)"; rc=$?
check 'exit 0'         0 "$rc"
check 'the team'       "$(printf '%s\n' \
  '  dig-opus-1     opus    max   the person in charge' \
  '  dig-fable-1    fable   max  ' \
  '  dig-fable-2    fable   max  ' \
  '  dig-opus-2     opus    high ' \
  '  dig-opus-3     opus    high ' \
  '  dig-sonnet-1   sonnet  max  ' \
  '  dig-sonnet-2   sonnet  max  ')" "$(grep '^  ' <<< "$out")"
check 'nothing opened' no "$([ -s "$calls" ] && echo yes || echo no)"

echo 'the run opens one window and six tabs, each session with its name, model and effort'
out="$(run "$project")"; rc=$?
check 'exit 0'         0 "$rc"
check 'seven calls'    7 "$(grep -c . "$calls")"
check 'the window, the person in charge' \
  "--new-window|-T|dig-opus-1|-d|$project|--|bash|-lc|claude -n dig-opus-1 --model opus --effort max 'You are the person in charge of the project digitaplatform. Your team: dig-fable-1 fable max, dig-fable-2 fable max, dig-opus-2 opus high, dig-opus-3 opus high, dig-sonnet-1 sonnet max, dig-sonnet-2 sonnet max.'; exec bash|" \
  "$(sed -n 1p "$calls")"
check 'a tab, a worker with no prompt' \
  "--tab|-T|dig-sonnet-2|-d|$project|--|bash|-lc|claude -n dig-sonnet-2 --model sonnet --effort max; exec bash|" \
  "$(sed -n 7p "$calls")"
check 'and it says so'  yes "$(grep -q '^opened: the 7 sessions of digitaplatform$' <<< "$out" && echo yes || echo no)"

echo "a project's own team.tsv sets the team"
mkdir -p "$project/.ai-core"; printf 'coordinator\tsonnet\thigh\t1\nworker\tfable\tmax\t1\n' > "$project/.ai-core/team.tsv"
out="$(run "$project" --dry-run)"; rc=$?
check 'exit 0'         0 "$rc"
check 'its team'       "$(printf '%s\n' '  dig-sonnet-1   sonnet  high  the person in charge' '  dig-fable-1    fable   max  ')" "$(grep '^  ' <<< "$out")"
echo 'a model below the floor of the harness is refused'
printf 'coordinator\topus\tmax\t1\nworker\thaiku\tmax\t2\n' > "$project/.ai-core/team.tsv"
out="$(run "$project" --dry-run)"; rc=$?
check 'exit 1'         1 "$rc"
check 'it names it'    yes "$(grep -q "'haiku' is below Sonnet" <<< "$out" && echo yes || echo no)"
rm -rf "$project/.ai-core"

echo 'a folder that is not there is refused'
out="$(run "$fake/nowhere")"; rc=$?
check 'exit 1'         1 "$rc"
check 'it names it'    yes "$(grep -q "error: $fake/nowhere is not a folder" <<< "$out" && echo yes || echo no)"

echo 'a terminal that is not supported is refused by name'
out="$(TERMINAL_WANTED=xterm run "$project")"; rc=$?
check 'exit 1'         1 "$rc"
check 'it names it'    yes "$(grep -q "AI_CORE_TERMINAL names 'xterm'" <<< "$out" && echo yes || echo no)"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
