#!/usr/bin/env bash
# WHERE THE CHECK OF THE PUSH GATE SPENDS ITS SECONDS. bin/pre-push.sh runs scripts/check.sh through timed_tee, which writes every
# line of the check's output into check.log with the whole seconds since the check started, and when the check ends it prints the
# longest gaps between two lines with check_longest_gaps, so that a slow step shows by name. Source it, do not run it.

# timed_tee <log>: copies standard input to standard output unchanged and appends each line to <log>, led by the whole seconds
# since this started and a tab; <log> is made where it is missing, as tee makes it, so a writer that writes nothing leaves an
# empty log. It reads to the end of its input, so the writer is never cut short and no line is lost; it
# ends with status 0, so that the status of the pipeline it stands in is the writer's.
timed_tee() {
  local line began=$SECONDS
  : >> "$1"
  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s\n' "$line"
    printf '%s\t%s\n' "$((SECONDS - began))" "$line" >> "$1"
  done
}

# check_last_line <log>: the last line of a log of timed_tee that is not blank, as the check wrote it, without its seconds
check_last_line() {
  awk -F'\t' '{ text = substr($0, index($0, "\t") + 1); if (text !~ /^[[:space:]]*$/) last = text } END { if (last != "") print last }' "$1"
}

# check_longest_gaps <log> <count>: the <count> longest gaps of one second or more between two lines of a log of timed_tee,
# longest first, an earlier one first among equals, one per line: the seconds, a tab, and the line that came before the gap,
# cut to 160 characters, its control characters spelled as ?
check_longest_gaps() {
  awk -F'\t' '
    NR > 1 && $1 - previous_seconds >= 1 { text = previous_text; gsub(/[[:cntrl:]]/, "?", text); print $1 - previous_seconds "\t" substr(text, 1, 160) }
    { previous_seconds = $1; previous_text = substr($0, index($0, "\t") + 1) }' "$1" \
    | sort -s -t "$(printf '\t')" -k1,1nr | awk -v count="$2" 'NR <= count'
}
