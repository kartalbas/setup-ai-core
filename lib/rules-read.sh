#!/usr/bin/env bash
# THE RULES A SESSION READS AGAIN AFTER A COMPACTION (rules/80): the list of the files, the record of the ones
# still unread, and the judgement of what a whole read is. bin/session-start.sh prints the list and writes the
# record after a compaction, bin/pre-tool-use.sh refuses every call but the read of a listed file while the record
# stands, and bin/post-tool-use.sh takes a file out of the record once it was read whole. Source it, do not run it.
#
# The record of a session is the file ~/.ai-core/rules-unread/<session id> (AI_CORE_HOME in place of ~ where set),
# one absolute path a line, and it is there only between a compaction and the last read.

RULES_UNREAD_DIRECTORY="${AI_CORE_HOME:-$HOME}/.ai-core/rules-unread"
# What one Read returns without a limit: a file longer than this is not read whole by it
READ_DEFAULT_LINES=2000

# rules_files_to_read <root> <rule files of a harness source, relative to the root, one a line, or empty> <the assembled rules path or empty> <local rules paths, one a line>:
# every file to read, as an absolute path a line, in the order the session start names them
rules_files_to_read() {
  { if [ -n "$2" ]; then printf '%s' "$2"
    else [ -z "$3" ] || echo "$3"; [ ! -f "$1/.ai-core/rules/skills.md" ] || echo .ai-core/rules/skills.md; fi
    printf '%s' "$4"; } | sed "/^\$/d; s#^\\([^/]\\)#$1/\\1#"
}

# rules_unread_file <session id>: the record of that session; fails for an id that could name another place
rules_unread_file() {
  case "$1" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
  echo "$RULES_UNREAD_DIRECTORY/$1"
}

# rules_unread_record <session id> <list>: the session reads these files again before its next step
rules_unread_record() {
  local file
  file="$(rules_unread_file "$1")" || return 1
  mkdir -p "$RULES_UNREAD_DIRECTORY" && printf '%s\n' "$2" > "$file"
}

# rules_unread_clear <session id>: the session owes no read
rules_unread_clear() {
  local file
  file="$(rules_unread_file "$1")" || return 0
  rm -f "$file"
}

# rules_path_of <path>: where the path leads, a link followed, so a listed file and a read of it by another name are one
rules_path_of() { realpath -m -- "$1"; }

# rules_is_listed <list, one path a line> <path>: whether the path is one of the listed files
rules_is_listed() {
  local listed wanted
  wanted="$(rules_path_of "$2")"
  while IFS= read -r listed; do
    [ -z "$listed" ] || [ "$(rules_path_of "$listed")" != "$wanted" ] || return 0
  done <<< "$1"
  return 1
}

# rules_read_is_whole <file> <offset or empty> <limit or empty>: whether one Read call with this offset and limit returns the
# file from its first line to its last
rules_read_is_whole() {
  local lines offset="${2:-1}" limit="${3:-}"
  lines="$(awk 'END { print NR }' "$1" 2>/dev/null)" || return 1
  [ -n "$lines" ] || return 1
  case "$offset$limit" in *[!0-9]*) return 1 ;; esac
  [ "$offset" -le 1 ] || return 1
  [ -n "$limit" ] || limit="$READ_DEFAULT_LINES"
  [ "$limit" -ge "$lines" ]
}

# rules_unread_remove <session id> <file>: the file was read whole; the record goes with its last file
rules_unread_remove() {
  local file line wanted rest=""
  file="$(rules_unread_file "$1")" || return 0
  [ -f "$file" ] || return 0
  wanted="$(rules_path_of "$2")"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$(rules_path_of "$line")" = "$wanted" ] || rest="$rest$line"$'\n'
  done < "$file"
  if [ -n "$rest" ]; then printf '%s' "$rest" > "$file"; else rm -f "$file"; fi
}
