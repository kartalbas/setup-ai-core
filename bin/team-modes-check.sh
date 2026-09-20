#!/usr/bin/env bash
# Are the three team modes installed for the agent tools on this machine?
#
#   team-modes-check.sh [--tool NAME ...] [--quiet]
#
# Reads team-modes.tsv, one row per tool and mode, and probes each row for the tools named
# with --tool - or, without it, for every tool whose command is on PATH. Prints one line per
# row and, where a mode is missing, the command that installs it. Exits 1 when any mode is
# missing or unverifiable, because the rules say no work starts without the three, and this
# check is what makes that sentence true: session-start, start-issue and the push hook run it
# first.
#
# The activation inside a session (the mode's own slash command at its level) is not something
# a file on disk can prove; session-start prints the three commands for the agent to run.
#
# THE TOOL LIST IS A STRING AND NOT AN ARRAY. bash 3.2 refuses `${#arr[@]}` on an empty array
# while `set -u` is on, and this script runs on macOS as well as on Linux and Git Bash.
#
# TEAM_MODES_FILE overrides the table, for tests.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The library is sourced for data_file only; its set -e is undone, this script judges its own steps
. "$ROOT/lib/board.sh"; set +e
TABLE="${TEAM_MODES_FILE:-$(data_file team-modes.tsv)}"
usage='usage: team-modes-check.sh [--tool NAME ...] [--quiet]'

# A FLAG WITHOUT ITS VALUE, WHICH BASH DOES NOT NOTICE ON ITS OWN. `--tool --quiet` would take
# the next flag as a tool name, and `--tool` written last would take nothing at all. Both read
# downstream as a tool this table has never heard of, which is a refusal about the wrong thing.
# This is what need_value does for the commands in bin/ that source lib/board.sh.
tools=''; quiet=0
while [ $# -gt 0 ]; do
  case "$1" in
    --tool)    case "${2-}" in ''|-*) echo "--tool needs a value" >&2; echo "$usage" >&2; exit 2 ;; esac
               tools="${tools}$2"$'\n'; shift 2 ;;
    --quiet)   quiet=1; shift ;;
    -h|--help) echo "$usage"; exit 0 ;;
    *)         echo "$usage" >&2; exit 2 ;;
  esac
done

[ -f "$TABLE" ] || { echo "REFUSED: $TABLE is missing - it is the table of the team modes."; exit 1; }

# Without --tool, the tool that RUNS this session is the one checked, read from the variables
# each tool sets in its shells: a tool that is merely installed beside it must not hold the
# session up. Where no tool runs (a person in a plain terminal), every tool the table knows and
# whose command is on this PATH is checked. A machine with none of them gets a note and a green
# exit: there is nothing here to hold, and refusing would stop a person who works through a tool
# this table has never heard of.
if [ -z "$tools" ]; then
  if [ -n "${CLAUDECODE:-}" ]; then tools='claude'$'\n'
  elif [ -n "${CODEX_SANDBOX:-}${CODEX_SANDBOX_NETWORK_DISABLED:-}${CODEX_THREAD_ID:-}" ]; then tools='codex'$'\n'
  elif [ -n "${GEMINI_CLI:-}" ]; then tools='gemini'$'\n'
  fi
fi
if [ -z "$tools" ]; then
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    command -v "$name" >/dev/null 2>&1 && tools="${tools}${name}"$'\n'
  done < <(tr -d '\r' < "$TABLE" | awk -F'\t' '!/^#/ && NF >= 5 { print $1 }' | sort -u)
  if [ -z "$tools" ]; then
    [ "$quiet" -eq 1 ] || echo "team modes: no agent tool from $(basename "$TABLE") is on PATH, so nothing is checked here."
    exit 0
  fi
fi

# The names on one line, for the sentences that list them.
named="$(printf '%s' "$tools" | tr '\n' ' ' | sed 's/ *$//')"

say() { [ "$quiet" -eq 1 ] || echo "$*"; }

# Each tool lists what it installed with its own command, and puts skills in its own folder.
# The shared .agents/skills folder is where the skills installer writes for every tool at once.
plugin_list() {  # plugin_list <tool>
  case "$1" in
    claude) claude plugin list 2>/dev/null ;;
    # Codex lists every plugin its marketplaces offer, installed or not, so the name alone
    # proves nothing; the lines that say "not installed" are dropped first.
    codex)  codex plugin list 2>/dev/null | awk 'tolower($0) !~ /not installed/' ;;
    gemini) gemini extensions list 2>/dev/null ;;
    *)      return 1 ;;
  esac
}
skill_dirs() {  # skill_dirs <tool> <name>
  printf '%s\n' "$HOME/.$1/skills/$2" "./.$1/skills/$2" "$HOME/.agents/skills/$2" "./.agents/skills/$2"
}

probe() {  # probe <tool> <probe> -> 0 installed, 1 missing, 2 no probe
  local tool="$1" kind="${2%%:*}" name="${2#*:}" d
  case "$kind" in
    always) return 0 ;;
    none)   return 2 ;;
    plugin) plugin_list "$tool" | grep -qi -- "$name" ;;
    skill)  while IFS= read -r d; do [ -d "$d" ] && return 0; done < <(skill_dirs "$tool" "$name"); return 1 ;;
    file)   [ -e "${name/#\~/$HOME}" ] ;;
    *)      return 2 ;;
  esac
}

# EACH LOOP READS ON ITS OWN FILE DESCRIPTOR, AND NOT ON STANDARD INPUT. A probe starts the
# tool's own command inside these loops, and that command inherits whatever standard input the
# loop reads from. A tool that reads one character would swallow the rest of the list, the loop
# would end early, and the modes it never reached would be reported as present.
missing=0; unverified=0; checked=0
while IFS= read -r tool <&3; do
  [ -n "$tool" ] || continue
  rows="$(tr -d '\r' < "$TABLE" | awk -F'\t' -v t="$tool" '!/^#/ && NF >= 5 && $1 == t')"
  if [ -z "$rows" ]; then
    say "UNVERIFIED  $tool: no rows in $(basename "$TABLE") - whoever uses this tool adds them (probe and install per mode)."
    unverified=$((unverified + 1))
    continue
  fi
  while IFS=$'\t' read -r _ mode level pr install verified <&4; do
    checked=$((checked + 1))
    if probe "$tool" "$pr"; then
      say "ok          $tool $mode ($level)"
    else
      case $? in
        2) say "UNVERIFIED  $tool $mode: no probe yet - fill the row in $(basename "$TABLE") (its install column says: ${install:--})."
           unverified=$((unverified + 1)) ;;
        *) say "MISSING     $tool $mode ($level) - install: ${install:--}"
           missing=$((missing + 1)) ;;
      esac
    fi
  done 4<<< "$rows"
done 3<<< "$tools"

if [ "$missing" -gt 0 ] || [ "$unverified" -gt 0 ]; then
  echo "REFUSED: $missing mode(s) missing, $unverified unverifiable, for: $named. Run team-modes-install, restart the tool, then start again. No work starts without the three modes."
  exit 1
fi
say "team modes: all $checked present for: $named."
exit 0
