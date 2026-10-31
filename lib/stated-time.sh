#!/usr/bin/env bash
# THE STATED TIME: a clock time written into a message to another session or into a tracker text
# must be the time the clock shows, because the owner decides on it. Source it for check_stated_time,
# or run it, where the Forgejo commands reach it:
#
#   stated-time.sh check COMMAND DESTINATION     the text on standard input; exit 1 and the refusal on standard error
#
# A time is judged where it is written as H:MM or HH:MM and the word right behind it, after spaces or
# an opening parenthesis, names a zone: a word of STATED_TIME_ZONE_WORDS, which means STATED_TIME_ZONE,
# or a zone name the system knows (UTC, or a file under /usr/share/zoneinfo). A time with no zone word
# can be a duration, a build name or a time of another day, so it is not judged. A line that also holds
# a date (YYYY-MM-DD, or D.M. with an optional year) is not judged: it names a day that is not today.
# Copied text is not judged either, as it states no time of the writer's: a fenced code block (``` or ~~~,
# to its closing fence or the end of the text; a line that opens with three backticks and holds another is inline
# code, no fence), a quoted line (>) and inline code (`...`), such as a log or a command's output.
# The clock is AI_CORE_NOW where set, as lib/usage.sh reads it, else the machine's.
# Settings of the project's config.env: STATED_TIME_ZONE (empty: the zone of the machine's clock),
# STATED_TIME_ZONE_WORDS (comma-separated, empty: none) and STATED_TIME_TOLERANCE_MINUTES (5 when unset).

. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ZONE_DIRECTORY=/usr/share/zoneinfo
STATED_TIME_PATTERN='(^|[^0-9:.])([01]?[0-9]|2[0-3]):([0-5][0-9])[[:space:]]*[(]?([A-Za-z][A-Za-z0-9_+/-]*)'
STATED_DATE_PATTERN='[0-9]{4}-[0-9]{2}-[0-9]{2}|(^|[^0-9.])[0-9]{1,2}\.[0-9]{1,2}\.'
STATED_FENCE_PATTERN='^[[:space:]]{0,3}(```+[^`]*$|~~~)'
STATED_QUOTE_PATTERN='^[[:space:]]{0,3}>'
STATED_CODE_PATTERN='`[^`]*`'

# zone_is_known <zone>: UTC, or a file of the zone database; date reads an unknown zone as UTC without a word
zone_is_known() { [ "$1" = UTC ] || [ -f "$ZONE_DIRECTORY/$1" ]; }

# zone_clock <zone or empty> <epoch seconds>: HH:MM in that zone, the machine's where it is empty
zone_clock() {
  if [ -n "$1" ]; then TZ="$1" LC_ALL=C date -d "@$2" +%H:%M; else LC_ALL=C date -d "@$2" +%H:%M; fi
}

# zone_of_word <word> <the project's zone> <its zone words, each between commas, lower case>: sets STATED_ZONE to the zone a word
# means, empty for the machine's, and fails for a word that names none
zone_of_word() {
  local lower
  lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  if [[ "$3" == *",$lower,"* ]]; then STATED_ZONE="$2"
  elif zone_is_known "$1"; then STATED_ZONE="$1"
  else return 1; fi
}

# check_stated_time <command> <destination> <text>: status 1 with the refusal on standard error where a time in
# the text, written with a zone word, differs from the clock in that zone by more than the tolerance, the short
# way round midnight, and where a setting cannot be read; the refusal names the written time and the clock's.
check_stated_time() {
  local command="$1" destination="$2" text="$3" zone words tolerance now line rest hour minute word shown difference fence=""
  zone="$(config_value STATED_TIME_ZONE "")" || return 1
  words="$(config_value STATED_TIME_ZONE_WORDS "")" || return 1
  tolerance="$(config_value STATED_TIME_TOLERANCE_MINUTES 5)" || return 1
  case "$tolerance" in ''|*[!0-9]*|????*) echo "$command to $destination: STATED_TIME_TOLERANCE_MINUTES is '$tolerance'; it is the minutes a stated time may differ from the clock, a whole number from 0 to 999" >&2; return 1 ;; esac
  if [ -n "$zone" ] && ! zone_is_known "$zone"; then
    echo "$command to $destination: STATED_TIME_ZONE is '$zone', which is no zone of $ZONE_DIRECTORY" >&2; return 1
  fi
  now="${AI_CORE_NOW:-$(date +%s)}"
  words=",$(printf '%s' "$words" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]'),"
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ $STATED_FENCE_PATTERN ]]; then
      if [ -z "$fence" ]; then fence="${BASH_REMATCH[1]:0:1}"; elif [ "${BASH_REMATCH[1]:0:1}" = "$fence" ]; then fence=""; fi
      continue
    fi
    [ -z "$fence" ] || continue
    [[ "$line" =~ $STATED_QUOTE_PATTERN ]] && continue
    while [[ "$line" =~ $STATED_CODE_PATTERN ]]; do line="${line/"${BASH_REMATCH[0]}"/ }"; done
    [[ "$line" =~ $STATED_DATE_PATTERN ]] && continue
    rest="$line"
    while [[ "$rest" =~ $STATED_TIME_PATTERN ]]; do
      hour="$((10#${BASH_REMATCH[2]}))"; minute="$((10#${BASH_REMATCH[3]}))"; word="${BASH_REMATCH[4]}"
      rest="${rest#*"${BASH_REMATCH[0]}"}"
      zone_of_word "$word" "$zone" "$words" || continue
      shown="$(zone_clock "$STATED_ZONE" "$now")" || { echo "$command to $destination: the clock could not be read" >&2; return 1; }
      difference="$(( hour * 60 + minute - (10#${shown%:*} * 60 + 10#${shown#*:}) ))"
      [ "$difference" -ge 0 ] || difference="$((0 - difference))"
      [ "$difference" -le 720 ] || difference="$((1440 - difference))"
      if [ "$difference" -gt "$tolerance" ]; then
        printf '%s to %s: the text says %02d:%02d %s, the clock there shows %s%s\n' "$command" "$destination" "$hour" "$minute" "$word" "$shown" "${STATED_ZONE:+ ($STATED_ZONE)}" >&2
        return 1
      fi
    done
  done <<< "$text"
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    check) [ $# -eq 3 ] || die "usage: stated-time.sh check COMMAND DESTINATION  (the text on standard input)"
           check_stated_time "$2" "$3" "$(cat)" ;;
    *) die "usage: stated-time.sh check COMMAND DESTINATION  (the text on standard input)" ;;
  esac
fi
