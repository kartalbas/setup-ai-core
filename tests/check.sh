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

# A red check can be a crash of pwsh rather than a defect of the code under test: under parallel
# load pwsh now and then dies of SIGSEGV inside the .NET runtime, and the test that waited for it
# reads the empty answer as a wrong one. The kernel logs every such death, so a red run says how
# many fell into its time, or that it could not look. A log that gives no line at all is one this
# user cannot read, since the kernel writes lines from the first second of a boot.
pwsh_crashes() {
  local log n
  if [ -z "$(journalctl -k -q --no-pager -n 1 2>/dev/null)" ] \
    || ! log="$(journalctl -k -q --no-pager --since "@$START" 2>/dev/null)"; then
    echo "the kernel log could not be read, so a crash of pwsh during this run is not ruled out"
    return
  fi
  n="$(grep -c 'pwsh\[[0-9]*\]: segfault' <<< "$log")"
  if [ "$n" -gt 0 ]; then
    echo "pwsh crashed $n time(s) on this machine during this run (kernel log): a red check above may be that crash, not the code under test"
  else
    echo "no crash of pwsh in the kernel log during this run"
  fi
}

red=""
for s in "${SECTIONS[@]}"; do
  n="$(basename "$s" .sh)"
  echo "### $n ($(cat "$RUN/$n.took")s)"
  cat "$RUN/$n.log"
  [ "$(cat "$RUN/$n.rc")" = 0 ] || { red="$red $n"; echo "FAIL: $n"; }
  echo
done
echo "==> the whole suite took $(( $(date +%s) - START ))s, ${#SECTIONS[@]} sections at once"
[ -z "$red" ] || { echo "red:$red"; pwsh_crashes; exit 1; }
echo "OK"
