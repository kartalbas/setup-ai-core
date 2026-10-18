#!/usr/bin/env bash
# Isolation at both suite entry points, with fixtures that can still select their own tool.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
export HOME="$work/home" AI_CORE_HOME="$work/core"
mkdir -p "$HOME" "$AI_CORE_HOME"
export CODEX_SANDBOX=fixture CODEX_SANDBOX_NETWORK_DISABLED=1 CODEX_THREAD_ID=fixture
export ANTIGRAVITY_AGENT=fixture CLAUDECODE=fixture GEMINI_CLI=fixture
export UNRELATED_TOOL_SETTING=keep
probe='for v in CODEX_SANDBOX CODEX_SANDBOX_NETWORK_DISABLED CODEX_THREAD_ID ANTIGRAVITY_AGENT CLAUDECODE GEMINI_CLI; do [ -z "${!v:-}" ] || exit 7; done; [ "$UNRELATED_TOOL_SETTING" = keep ]'
if ! bash -c '. "$1/tests/lib.sh"; eval "$2"' _ "$root" "$probe"; then fail 'section boundary retained inherited identity'; fi
[ "$CODEX_THREAD_ID" = fixture ] || fail 'child reset changed its parent'
[ -f "$root/tests/tool-environment.sh" ] || fail 'shared initializer missing'
copy="$work/copy"; mkdir -p "$copy/tests" "$copy/lib" "$copy/rules"
cp "$root/lib/common.sh" "$copy/lib/"
cp "$root/tests/"{run-all.sh,lib.sh,tool-environment.sh} "$copy/tests/"
printf '# fixture\n' > "$copy/rules/00-fixture.md"
printf '#!/usr/bin/env bash\nset -u\n%s\n' "$probe" > "$copy/tests/sentinel.test.sh"
run() { bash "$copy/tests/run-all.sh" > "$work/out" 2>&1; }
run || fail "runner boundary retained identity: $(cat "$work/out")"
sed '/\. .*tool-environment.sh/d' "$copy/tests/run-all.sh" > "$work/mutant"
cp "$work/mutant" "$copy/tests/run-all.sh"
if run; then fail 'runner reset removal escaped'; fi
cp "$root/tests/run-all.sh" "$copy/tests/run-all.sh"
sed '/\. .*tool-environment.sh/d' "$copy/tests/lib.sh" > "$work/mutant"
cp "$work/mutant" "$copy/tests/lib.sh"
if bash -c '. "$1/tests/lib.sh"; eval "$2"' _ "$copy" "$probe"; then fail 'section reset removal escaped'; fi
cp "$root/tests/lib.sh" "$copy/tests/lib.sh"
# Extending the declaration must extend both cleanup and detection.
sed 's/codex CODEX_SANDBOX/codex SYNTHETIC_TOOL\ncodex CODEX_SANDBOX/' "$copy/lib/common.sh" > "$work/mutant"
cp "$work/mutant" "$copy/lib/common.sh"
export SYNTHETIC_TOOL=fixture
bash -c '. "$1/tests/tool-environment.sh"; [ -z "${SYNTHETIC_TOOL:-}" ]; [ "$UNRELATED_TOOL_SETTING" = keep ];
  for v in $(tool_environment_variables); do
    result="$(export "$v=fixture"; session_tool)"; [ -n "$result" ] || exit 8
  done
  SYNTHETIC_TOOL=fixture; [ "$(session_tool)" = codex ]' _ "$copy" || fail 'canonical declaration parity'
# A detector that drops an input independently of enumeration is detected.
printf '\nsession_tool() { :; }\n' >> "$copy/lib/common.sh"
if bash -c '. "$1/tests/tool-environment.sh"; CODEX_THREAD_ID=fixture; [ "$(session_tool)" = codex ]' _ "$copy"; then fail 'detector drift escaped'; fi
cp "$root/lib/common.sh" "$copy/lib/common.sh"
for identity in clean inherited; do
  if [ "$identity" = clean ]; then . "$root/tests/tool-environment.sh"
  else while IFS= read -r variable; do export "$variable=fixture"; done < <(tool_environment_variables); fi
  printf '#!/usr/bin/env bash\nexit 9\n' > "$copy/tests/sentinel.test.sh"
  if run; then fail "failing sentinel hidden ($identity)"; fi
  printf '#!/usr/bin/env bash\nexit 0\n' > "$copy/tests/sentinel.test.sh"
  run || fail "innocent sentinel failed ($identity)"
done
. "$root/tests/tool-environment.sh"
[ -z "$(session_tool)" ] || fail 'empty identity detected'
CODEX_THREAD_ID=''; [ -z "$(session_tool)" ] || fail 'empty value detected'
for pair in 'codex CODEX_SANDBOX' 'codex CODEX_SANDBOX_NETWORK_DISABLED' 'codex CODEX_THREAD_ID' 'agy ANTIGRAVITY_AGENT' 'claude CLAUDECODE' 'gemini GEMINI_CLI'; do
  read -r tool variable <<< "$pair"
  result="$(export "$variable=fixture"; session_tool)"
  [ "$result" = "$tool" ] || fail "$variable selected $result"
done
[ "$(CODEX_THREAD_ID=fixture ANTIGRAVITY_AGENT=1 CLAUDECODE=1 session_tool)" = codex ] || fail 'Codex precedence'
[ "$(ANTIGRAVITY_AGENT=1 CLAUDECODE=1 session_tool)" = agy ] || fail 'agy precedence'
# Both production readers must honor each declared input, not only the shared detector itself.
mkdir -p "$copy/bin"
cp -R "$root/lib/." "$copy/lib/"
cp "$root/bin/team-modes-check.sh" "$root/bin/usage.sh" "$copy/bin/"
printf 'codex\tmode\talways\t-\t-\nagy\tmode\talways\t-\t-\nclaude\tmode\talways\t-\t-\ngemini\tmode\talways\t-\t-\n' > "$work/modes"
export CODEX_HOME="$work/usage-codex"
mkdir -p "$AI_CORE_HOME/.ai-core" "$CODEX_HOME/sessions/2026/10/18"
reset_at=$(( $(date +%s) + 3600 ))
printf '{"recorded_at":%s,"rate_limits":{"seven_day":{"used_percentage":99,"resets_at":%s}}}\n' "$(date +%s)" "$reset_at" > "$AI_CORE_HOME/.ai-core/usage.json"
printf '{"timestamp":"%s","payload":{"rate_limits":{"primary":{"used_percent":7,"window_minutes":10080,"resets_at":%s},"secondary":null}}}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$reset_at" > "$CODEX_HOME/sessions/2026/10/18/rollout-fixture.jsonl"
consumer_identity() {  # consumer_identity <command> <variable> <expected tool>
  local consumer="$1" variable="$2" expected="$3" result rc=0 want=3
  result="$(
    . "$copy/tests/tool-environment.sh"
    case "$expected" in codex|agy) export CLAUDECODE=parent ;; esac
    export "$variable=fixture"
    TEAM_MODES_FILE="$work/modes" bash "$copy/bin/$consumer.sh" ${consumer_args[@]+"${consumer_args[@]}"}
  )" || rc=$?
  if [ "$consumer" = usage ]; then
    [ "$expected" != codex ] || want=0
    [ "$rc" = "$want" ]
  else
    [ "$rc" = 0 ] && grep -qF "team modes: all 1 present for: $expected" <<< "$result"
  fi
}
consumer_args=()
while read -r expected variable; do
  consumer_identity team-modes-check "$variable" "$expected" || fail "mode consumer ignored $variable"
  consumer_args=(--stop-at 92)
  consumer_identity usage "$variable" "$expected" || fail "usage consumer ignored $variable"
  consumer_args=()
done <<< "$TOOL_ENVIRONMENT"
for consumer in team-modes-check usage; do
  sed 's/$(session_tool)/$(CODEX_SANDBOX= session_tool)/' "$root/bin/$consumer.sh" > "$copy/bin/$consumer.sh"
  cmp -s "$root/bin/$consumer.sh" "$copy/bin/$consumer.sh" && fail 'consumer mutant unchanged'
  consumer_args=(); [ "$consumer" != usage ] || consumer_args=(--stop-at 92)
  if consumer_identity "$consumer" CODEX_SANDBOX codex; then fail "$consumer ignored-input mutant escaped"; fi
  cp "$root/bin/$consumer.sh" "$copy/bin/$consumer.sh"
done
echo 'all tool environment boundaries, mutations, and controls passed'
