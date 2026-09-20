#!/usr/bin/env bash
# Install the team modes that team-modes-check reports as missing.
#
#   team-modes-install.sh [--tool NAME ...] [--dry-run]
#
# Runs the install column of team-modes.tsv for every missing mode of the tools named with
# --tool - or, without it, of every tool whose command is on PATH. A row without a probe or
# without an install command is reported, never guessed at. After it, the tool has to be
# started again: a plugin loads when the tool starts, and a session that was already running
# does not see it.
#
# It is run by a person, or by an agent on that person's word; it changes the machine.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The library is sourced for data_file only; its set -e is undone, this script judges its own steps
. "$ROOT/lib/board.sh"; set +e
TABLE="${TEAM_MODES_FILE:-$(data_file team-modes.tsv)}"
usage='usage: team-modes-install.sh [--tool NAME ...] [--dry-run]'

# A FLAG WITHOUT ITS VALUE, WHICH BASH DOES NOT NOTICE ON ITS OWN. `--tool --dry-run` would
# take the next flag as a tool name, and `--tool` written last would take nothing at all. Both
# read downstream as a tool this table has never heard of, which is a refusal about the wrong
# thing. This is what need_value does for the commands in bin/ that source lib/board.sh.
tools=''; dry=0
while [ $# -gt 0 ]; do
  case "$1" in
    --tool)    case "${2-}" in ''|-*) echo "--tool needs a value" >&2; echo "$usage" >&2; exit 2 ;; esac
               tools="${tools}$2"$'\n'; shift 2 ;;
    --dry-run) dry=1; shift ;;
    -h|--help) echo "$usage"; exit 0 ;;
    *)         echo "$usage" >&2; exit 2 ;;
  esac
done

[ -f "$TABLE" ] || { echo "REFUSED: $TABLE is missing - it is the table of the team modes."; exit 1; }

if [ -z "$tools" ]; then
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    command -v "$name" >/dev/null 2>&1 && tools="${tools}${name}"$'\n'
  done < <(tr -d '\r' < "$TABLE" | awk -F'\t' '!/^#/ && NF >= 5 { print $1 }' | sort -u)
  [ -n "$tools" ] || { echo "team modes: no agent tool from $(basename "$TABLE") is on PATH; pass --tool to name one."; exit 0; }
fi

# The check decides what is missing, so the two never disagree about it. One line of its
# report per mode, and the MISSING lines are the ones to act on.
#
# EACH LOOP READS ON ITS OWN FILE DESCRIPTOR, AND NOT ON STANDARD INPUT. An install command is
# started inside the inner loop and inherits whatever standard input the loop reads from, so a
# command that reads a single character - `npx` asking whether to fetch a package, a plugin
# installer confirming a marketplace - swallows the rest of the report. The loop then ends
# after the first row, and the run reports "installed 1" over a machine that is still missing
# two modes. On fd 3 and fd 4 the lists cannot be reached, and standard input stays what it
# was: the terminal of the person who started this, where an install command may still ask.
installed=0; failed=0; skipped=0
while IFS= read -r tool <&3; do
  [ -n "$tool" ] || continue
  report="$(bash "$ROOT/bin/team-modes-check.sh" --tool "$tool" 2>&1 </dev/null || true)"
  while IFS= read -r line <&4; do
    case "$line" in
      MISSING*)
        mode="$(printf '%s' "$line" | awk '{print $3}')"
        install="$(tr -d '\r' < "$TABLE" | awk -F'\t' -v t="$tool" -v m="$mode" '!/^#/ && $1 == t && $2 == m { print $5 }')"
        if [ -z "$install" ] || [ "$install" = "-" ]; then
          echo "SKIPPED     $tool $mode: no install command in the table; see the mode's own documentation."
          skipped=$((skipped + 1)); continue
        fi
        echo "installing  $tool $mode: $install"
        if [ "$dry" -eq 1 ]; then continue; fi
        if bash -c "$install"; then installed=$((installed + 1))
        else echo "FAILED      $tool $mode: the install command exited non-zero."; failed=$((failed + 1)); fi ;;
      UNVERIFIED*) echo "$line"; skipped=$((skipped + 1)) ;;
      ok*|"team modes"*) echo "$line" ;;
    esac
  done 4<<< "$report"
done 3<<< "$tools"

echo
echo "installed $installed, failed $failed, skipped $skipped."
[ "$installed" -eq 0 ] || echo "Start the tool again now: a plugin loads when the tool starts, and a running session does not see it."
[ "$failed" -eq 0 ] && [ "$skipped" -eq 0 ] || exit 1
