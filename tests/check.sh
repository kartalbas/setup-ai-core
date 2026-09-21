#!/usr/bin/env bash
# Verify the harness itself: every file under tests/sections/ is one section of the suite, and
# they all run at once, each in its own process and its own throwaway directory. The report
# comes in the order of the files, with the time each section took; a red section prints its
# whole log. Needs bash, pwsh and node; nothing here reaches the network.
#
#   bash tests/check.sh [section ...]       a section by its file name, e.g. 08-harness
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ $# -gt 0 ]; then
  SECTIONS=(); for s in "$@"; do SECTIONS+=("$HERE/sections/${s%.sh}.sh"); done
else
  SECTIONS=("$HERE"/sections/*.sh)
fi
for s in "${SECTIONS[@]}"; do [ -f "$s" ] || { echo "no such section: $s" >&2; exit 2; }; done

RUN="$(mktemp -d)"
trap 'rm -rf "$RUN"' EXIT
START="$(date +%s)"
for s in "${SECTIONS[@]}"; do
  n="$(basename "$s" .sh)"
  ( t0="$(date +%s)"; bash "$s" > "$RUN/$n.log" 2>&1; echo $? > "$RUN/$n.rc"; echo $(( $(date +%s) - t0 )) > "$RUN/$n.took" ) &
done
wait

red=""
for s in "${SECTIONS[@]}"; do
  n="$(basename "$s" .sh)"
  echo "### $n ($(cat "$RUN/$n.took")s)"
  cat "$RUN/$n.log"
  [ "$(cat "$RUN/$n.rc")" = 0 ] || { red="$red $n"; echo "FAIL: $n"; }
  echo
done
echo "==> the whole suite took $(( $(date +%s) - START ))s, ${#SECTIONS[@]} sections at once"
[ -z "$red" ] || { echo "red:$red"; exit 1; }
echo "OK"
