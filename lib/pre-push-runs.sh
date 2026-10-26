#!/usr/bin/env bash
# THE RUN LOG OF THE PUSH GATE: where it stands and how its rows are read, for `pre-push --runs`, which lists
# them, and for lib/neighbours.sh, which measures the longest check from them. The gate writes the rows itself
# (bin/pre-push.sh). Source it, do not run it.

GATE_RUNS_HEADER=$'time\trepository\tworktree\tcommit\tverdict\tseconds\tlast line\tload at check start'

# gate_runs_file: the log of this machine
gate_runs_file() { printf '%s\n' "${AI_CORE_HOME:-$HOME}/.ai-core/pre-push-runs.tsv"; }

# gate_runs_rows <log>: the rows below the header, the oldest first, each with its eight fields: a row of seven
# was recorded before the load field existed, and its load, which was not measured, is -. The last row of a log
# that does not end with a newline is an append still in progress and is no run yet. Fails where the log cannot
# be read.
gate_runs_rows() {
  [ -f "$1" ] && [ -r "$1" ] || return 1
  if [ -n "$(tail -c 1 "$1")" ]; then sed '$d' "$1"; else cat "$1"; fi \
    | tail -n +2 | awk -F'\t' '{ print (NF == 7 ? $0 "\t-" : $0) }'
}

# gate_runs_timing <log>: reads the seconds the checks took and sets
#   GATE_RUNS_STATE      missing (no log yet), unreadable, or read
#   GATE_RUNS_TIMED      the rows of a check that ran to its verdict, green or red, with its seconds
#   GATE_RUNS_LONGEST    the most seconds one of them took, 0 with none
#   GATE_RUNS_UNTIMED    the rows that name no seconds because no check ran: a run with no check, a refusal
#                        before the check
#   GATE_RUNS_UNREADABLE the rows that are none of these, which count for nothing
#   GATE_RUNS_ROWS       all the rows, the denominator of the counts above
# and fails where the log exists and cannot be read.
GATE_RUNS_STATE=""; GATE_RUNS_TIMED=0; GATE_RUNS_LONGEST=0; GATE_RUNS_UNTIMED=0; GATE_RUNS_UNREADABLE=0; GATE_RUNS_ROWS=0
gate_runs_timing() {
  local counted
  GATE_RUNS_STATE=missing; GATE_RUNS_TIMED=0; GATE_RUNS_LONGEST=0; GATE_RUNS_UNTIMED=0; GATE_RUNS_UNREADABLE=0; GATE_RUNS_ROWS=0
  [ -e "$1" ] || return 0
  GATE_RUNS_STATE=unreadable
  [ -f "$1" ] && [ -r "$1" ] || return 1
  # nine digits at most, so that the seconds fit every shell's arithmetic
  counted="$(gate_runs_rows "$1" | awk -F'\t' '
    NF != 8 { unreadable++; next }
    $5 == "green" || $5 == "red" {
      if ($6 ~ /^[0-9]+$/ && length($6) <= 9) { timed++; if ($6 + 0 > longest) longest = $6 + 0 }
      else if ($6 == "-") untimed++
      else unreadable++
      next
    }
    $5 == "no check" && $6 == "-" { untimed++; next }
    { unreadable++ }
    END { printf "%d %d %d %d %d\n", timed, longest, untimed, unreadable, NR }')" || return 1
  read -r GATE_RUNS_TIMED GATE_RUNS_LONGEST GATE_RUNS_UNTIMED GATE_RUNS_UNREADABLE GATE_RUNS_ROWS <<< "$counted"
  GATE_RUNS_STATE=read
}
