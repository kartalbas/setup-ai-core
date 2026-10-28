#!/usr/bin/env bash
# THE RUN LOG OF THE PUSH GATE: where it stands and how its rows are read, for `pre-push --runs`, which lists
# them, for lib/neighbours.sh, which measures the longest check from them, and for lib/landing-lock.sh, which measures the
# longest hold of the landing lock from them, in the rows of the last 14 days only, so one outlier ages out by itself. The
# gate writes a row for each run of its check (bin/pre-push.sh), and a landing writes one for each time it held the landing
# lock, with the verdict landing lock and the seconds it held it (lib/landing-lock.sh). Source it, do not run it.

GATE_RUNS_HEADER=$'time\trepository\tworktree\tcommit\tverdict\tseconds\tlast line\tload at check start'

GATE_RUNS_WINDOW_DAYS=14

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

# gate_runs_clock <epoch seconds>: that time as the log writes it (UTC)
gate_runs_clock() {
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ
}

# gate_runs_window_start: the time, as the log writes it (UTC), from which a row counts: GATE_RUNS_WINDOW_DAYS before now
gate_runs_window_start() { gate_runs_clock $(( $(date +%s) - GATE_RUNS_WINDOW_DAYS * 86400 )); }

# gate_runs_append <row>: a new log is made whole, header and first row, and linked into place, so two writers
# that both find none cannot both write a header; a log that exists, whatever header it carries, only gets the row,
# appended in one write. Where the new log cannot be linked into place and none stands there afterwards, the row is
# not recorded: the status is 1, and no second way writes a header.
gate_runs_append() {
  local row="$1" log made linked
  log="$(gate_runs_file)"
  if [ ! -e "$log" ]; then
    made="$(mktemp "$log.XXXXXX")" || return 1
    printf '%s\n%s\n' "$GATE_RUNS_HEADER" "$row" > "$made" && ln "$made" "$log" 2>/dev/null
    linked=$?
    rm -f "$made"
    [ "$linked" -ne 0 ] || return 0
    [ -e "$log" ] || return 1
  fi
  printf '%s\n' "$row" >> "$log"
}

# gate_runs_timing <log>: reads the seconds the checks took in the rows of the last GATE_RUNS_WINDOW_DAYS days and sets
#   GATE_RUNS_STATE      missing (no log yet), unreadable, or read
#   GATE_RUNS_TIMED      the rows of a check that ran to its verdict, green or red, with its seconds
#   GATE_RUNS_LONGEST    the most seconds one of them took, 0 with none
#   GATE_RUNS_UNTIMED    the rows that name no seconds because no check ran: a run with no check, a refusal
#                        before the check
#   GATE_RUNS_UNREADABLE the rows that are none of these, a time that is none among them, which count for nothing
#   GATE_RUNS_ROWS       the rows of the window, the denominator of the counts above; the rows of a landing lock hold are
#                        in none of the counts and not in this one, and one that names no seconds counts as unreadable
#   GATE_RUNS_OLDER      the rows before the window, which count for nothing and are in none of the counts above
# and fails where the log exists and cannot be read.
GATE_RUNS_STATE=""; GATE_RUNS_TIMED=0; GATE_RUNS_LONGEST=0; GATE_RUNS_UNTIMED=0; GATE_RUNS_UNREADABLE=0; GATE_RUNS_ROWS=0; GATE_RUNS_OLDER=0
gate_runs_timing() {
  local counted start
  GATE_RUNS_STATE=missing; GATE_RUNS_TIMED=0; GATE_RUNS_LONGEST=0; GATE_RUNS_UNTIMED=0; GATE_RUNS_UNREADABLE=0; GATE_RUNS_ROWS=0; GATE_RUNS_OLDER=0
  [ -e "$1" ] || return 0
  GATE_RUNS_STATE=unreadable
  [ -f "$1" ] && [ -r "$1" ] || return 1
  start="$(gate_runs_window_start)" && [ -n "$start" ] || return 1
  # nine digits at most, so that the seconds fit every shell's arithmetic
  counted="$(gate_runs_rows "$1" | awk -F'\t' -v start="$start" '
    NF != 8 || $1 !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/ { unreadable++; next }
    $1 < start { older++; next }
    $5 == "green" || $5 == "red" {
      if ($6 ~ /^[0-9]+$/ && length($6) <= 9) { timed++; if ($6 + 0 > longest) longest = $6 + 0 }
      else if ($6 == "-") untimed++
      else unreadable++
      next
    }
    $5 == "no check" && $6 == "-" { untimed++; next }
    $5 == "landing lock" && $6 ~ /^[0-9]+$/ && length($6) <= 9 { held++; next }
    { unreadable++ }
    END { printf "%d %d %d %d %d %d\n", timed, longest, untimed, unreadable, NR - older - held, older }')" || return 1
  read -r GATE_RUNS_TIMED GATE_RUNS_LONGEST GATE_RUNS_UNTIMED GATE_RUNS_UNREADABLE GATE_RUNS_ROWS GATE_RUNS_OLDER <<< "$counted"
  GATE_RUNS_STATE=read
}

# gate_runs_repository_longest <log> <repository> check|hold: the most seconds a check of that repository took (check), or
# a landing held the landing lock of it (hold), in the rows of the last GATE_RUNS_WINDOW_DAYS days, the repository as
# owner/name; nothing is printed where none ran in them. Fails where the log cannot be read.
gate_runs_repository_longest() {
  local start
  start="$(gate_runs_window_start)" && [ -n "$start" ] || return 1
  gate_runs_rows "$1" | awk -F'\t' -v start="$start" -v repository="$2" -v kind="$3" '
    NF == 8 && $1 >= start && tolower($2) == tolower(repository) && (kind == "hold" ? $5 == "landing lock" : ($5 == "green" || $5 == "red")) && $6 ~ /^[0-9]+$/ && length($6) <= 9 {
      if ($6 + 0 > longest) longest = $6 + 0
      timed = 1
    }
    END { if (timed) print longest }'
}
