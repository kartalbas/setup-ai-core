#!/usr/bin/env bash
# Every command answers --help through ai-core: exit 0, some text, no error. It walks every
# script in bin/, so a command added later is held to it from its first day.
#
# It runs in a temporary folder that is no repository, with HOME pointed into it, so a command
# that does more than print its usage touches nothing of the machine.
#
#   bash tests/help.test.sh

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export HOME="$work/home" AI_CORE_HOME="$work/home"
mkdir -p "$HOME"

failed=0; walked=0
for f in "$root"/bin/*.sh; do
  c="$(basename "$f" .sh)"
  [ "$c" != ai-core ] || continue
  walked=$((walked + 1))
  out="$(cd "$work" && bash "$root/bin/ai-core" "$c" --help 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$out" ] || grep -qiE 'unknown argument|^error' <<< "$out"; then
    echo "  FAIL $c --help: exit $rc: $(head -2 <<< "$out" | tr '\n' ' ')"; failed=$((failed + 1))
  fi
done
echo "  $walked commands walked"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
