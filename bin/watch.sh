#!/usr/bin/env bash
# Waits until a session that oversees other sessions has something to look at, prints one line that
# names it, and returns. Run in the background, its end wakes the session that started it; that
# session looks, acts and runs it again. Each run counts from its own start.
#
#   watch.sh [--session NAME]... [--ref CLONE:REF]... [--file PATH]... [--still S] [--every S] [--heartbeat S]
#
#   --session    a Claude Code session, by its name in `claude agents --json`; it wakes the caller
#                once it has not been `busy` for --still seconds in a row, or has left the list for
#                as long. `state` says only whether a background job is finished, and an
#                interactive session has none; `status` says whether it works at this moment.
#                It also wakes the caller, however busy the session is, once the session compacts in
#                a loop, read from its transcript (<root>/*/<sessionId>.jsonl, the root being
#                AI_CORE_TRANSCRIPTS, else ~/.claude/projects): three `compact_boundary` lines of
#                different uuids within the last 600 seconds, or Claude Code's own error message
#                "Autocompact is thrashing" within them; the line names the session, and the id where
#                one name stands on several entries, and says which sign it saw. A session whose
#                transcript cannot be found, read, or understood (a line that is no JSON, a
#                compaction without its time or uuid) wakes the caller with exit 1 and is named,
#                never counted as healthy. Only Claude Code sessions are covered here: a Codex or agy
#                session has no such transcript, and --file is the way to watch a Codex run
#   --ref        a ref of a clone, such as /path/clone:origin/master; the clone is fetched every
#                round, and the caller is woken when the ref moves
#   --file       a readable output file; wake after --still seconds without growth unless the last
#                JSON event is turn.completed. Inactivity is not proof that a process is hung
#   --still      900 unless given: longer than a coordinator's round of 600 seconds, so a
#                coordinator between two rounds wakes nobody
#   --every      seconds between two rounds, 60 unless given
#   --heartbeat  seconds after which it returns anyway, with every session's status and every ref's
#                head, plus every file's path, bytes and minutes since growth, 1800 unless given
#
# Exit 0: one line, "<HH:MM> <what happened>". Exit 1: a fetch, `claude agents`, a file read or a transcript read
# failed, named in the line. Exit 2: a wrong argument, nothing to watch, or a ref that names nothing, or an invalid file.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage="usage: watch.sh [--session NAME]... [--ref CLONE:REF]... [--file PATH]... [--still S] [--every S] [--heartbeat S]"
names=(); clones=(); refs=(); files=(); still=900; every=60; heartbeat=1800
while [ $# -gt 0 ]; do
  case "$1" in -h|--help) awk 'NR == 1 && /^#!/ { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"; exit 0 ;; esac
  [ $# -ge 2 ] || { echo "error: $1 takes a value - $usage" >&2; exit 2; }
  case "$1" in
    --session) names[${#names[@]}]="$2" ;;
    # A ref name never holds a colon, so the last one ends the clone's path
    --ref) case "$2" in *:*) ;; *) echo "error: --ref takes CLONE:REF, not '$2'" >&2; exit 2 ;; esac
      clones[${#clones[@]}]="${2%:*}"; refs[${#refs[@]}]="${2##*:}" ;;
    --file) case "$2" in ''|--*) echo "error: --file takes a path - $usage" >&2; exit 2 ;; esac
      files[${#files[@]}]="$2" ;;
    --still) still="$2" ;;
    --every) every="$2" ;;
    --heartbeat) heartbeat="$2" ;;
    *) echo "error: unknown argument '$1' - $usage" >&2; exit 2 ;;
  esac
  shift 2
done
for n in "$still" "$every" "$heartbeat"; do
  case "$n" in ''|*[!0-9]*|0) echo "error: --still, --every and --heartbeat take whole seconds above 0, not '$n'" >&2; exit 2 ;; esac
done
[ $((${#names[@]} + ${#refs[@]} + ${#files[@]})) -gt 0 ] || { echo "error: nothing to watch - $usage" >&2; exit 2; }

# Validate every file before a ref fetch or a session query can have side effects.
for file in ${files[@]+"${files[@]}"}; do
  [ -f "$file" ] && [ -r "$file" ] || { echo "error: file is not readable: $file" >&2; exit 2; }
done

if [ "${#names[@]}" -gt 0 ] && ! command -v node >/dev/null 2>&1; then
  echo "error: a session is watched by its transcript, which node reads, and node is not on the PATH" >&2; exit 2
fi

err="$(mktemp)"; states="$(mktemp -d)"; trap 'rm -rf "$err" "$states"' EXIT
transcripts="${AI_CORE_TRANSCRIPTS:-$HOME/.claude/projects}"
say() { echo "$(date +%H:%M) $1"; exit "${2:-0}"; }

# Every entry of one name in `claude agents --json` ($json) has a transcript, and none may thrash: three compactions
# or Claude Code's own message within 600 seconds wake the caller (exit 0), a transcript that is missing, ambiguous, in
# another folder than its cwd names or not understood wakes it with exit 1. Each transcript is read on from where the
# last round stopped (lib/watch-transcript.mjs keeps that in $states).
check_transcripts() {  # check_transcripts <name>
  local name="$1" entries count entry sid cwd files file label line rc folder
  entries="$(jq -c --arg n "$name" '.[] | select(.name == $n) | {sessionId: (.sessionId // ""), cwd: (.cwd // "")}' <<< "$json" 2>&1)" \
    || say "claude agents gave no list: ${entries##*$'\n'}" 1
  count="$(grep -c . <<< "$entries")"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    sid="$(jq -r '.sessionId' <<< "$entry")"; cwd="$(jq -r '.cwd' <<< "$entry")"
    label="$name"; [ "$count" -le 1 ] || label="$name ($sid)"
    case "$sid" in ''|*[!A-Za-z0-9-]*) say "$label: its entry in claude agents has no usable sessionId, so its transcript cannot be found" 1 ;; esac
    files=(); for file in "$transcripts"/*/"$sid.jsonl"; do [ ! -e "$file" ] || files[${#files[@]}]="$file"; done
    [ "${#files[@]}" -gt 0 ] || say "$label: no transcript $sid.jsonl under $transcripts" 1
    [ "${#files[@]}" -eq 1 ] || say "$label: ${#files[@]} transcripts named $sid.jsonl under $transcripts" 1
    folder="$(basename "$(dirname "${files[0]}")")"
    if [ -n "$cwd" ] && [ "$folder" != "$(printf '%s' "$cwd" | sed 's/[^A-Za-z0-9]/-/g')" ]; then
      say "$label: its transcript is in $folder, which is not the folder of its cwd $cwd" 1
    fi
    rc=0; line="$(node "$here/../lib/watch-transcript.mjs" --state "$states/$sid.json" --file "${files[0]}" --now "$now")" || rc=$?
    case "$rc" in 0) ;; 10) say "$label: $line" ;; *) say "$label: ${line:-the transcript could not be read}" 1 ;; esac
  done <<< "$entries"
}
fetch() { local out; out="$(git -C "${clones[$1]}" fetch -q 2>&1)" || say "${clones[$1]}: the fetch failed: ${out##*$'\n'}" 1; }
# The full name: a short one grows as the clone does, and would read as a move
head_of() { git -C "${clones[$1]}" rev-parse --verify -q "${refs[$1]}^{commit}"; }

file_size() {
  local size file="${files[$1]}"
  [ -f "$file" ] && [ -r "$file" ] || { echo "file is no longer readable: $file" >&2; return 1; }
  size="$(wc -c < "$file")" || { echo "cannot read file size: $file" >&2; return 1; }
  printf '%s\n' "${size//[[:space:]]/}"
}

start="$(date +%s)"; heads=(); seen=(); sizes=(); grown=()
i=0; while [ "$i" -lt "${#files[@]}" ]; do
  sizes[i]="$(file_size "$i")" || say "${files[$i]}: cannot read file size" 1
  grown[i]="$start"; i=$((i + 1))
done
i=0; while [ "$i" -lt "${#refs[@]}" ]; do
  fetch "$i"
  heads[i]="$(head_of "$i")" || { echo "error: ${refs[$i]} names nothing in ${clones[$i]}" >&2; exit 2; }
  i=$((i + 1))
done
i=0; while [ "$i" -lt "${#names[@]}" ]; do seen[i]="$start"; i=$((i + 1)); done

while :; do
  sleep "$every"
  now="$(date +%s)"; report=""
  i=0; while [ "$i" -lt "${#refs[@]}" ]; do
    fetch "$i"
    head="$(head_of "$i")"; short="${head:0:9}"
    [ "$head" = "${heads[$i]}" ] || say "${clones[$i]}:${refs[$i]} moved: ${heads[$i]:0:9} -> ${short:-nothing}"
    report="$report; ${clones[$i]}:${refs[$i]} at ${head:0:9}"
    i=$((i + 1))
  done
  if [ "${#names[@]}" -gt 0 ]; then
    json="$(claude agents --json 2> "$err")" || say "claude agents failed: $(tail -n1 "$err")" 1
  fi
  i=0; while [ "$i" -lt "${#names[@]}" ]; do
    # A name can stand on several entries, an interactive session and a background one: the
    # session works while any of them is busy
    status="$(jq -r --arg n "${names[$i]}" '[.[] | select(.name == $n) | .status]
      | if length == 0 then "gone" elif any(. == "busy") then "busy" else unique | join(",") end' <<< "$json" 2>&1)" \
      || say "claude agents gave no list: ${status##*$'\n'}" 1
    [ "$status" = busy ] && seen[i]="$now"
    minutes=$(( (now - ${seen[$i]}) / 60 ))
    [ $((now - ${seen[$i]})) -lt "$still" ] \
      || say "${names[$i]} is $status and has not been busy for $minutes minutes"
    check_transcripts "${names[$i]}"
    report="$report; ${names[$i]} $status, $minutes minutes since it was busy"
    i=$((i + 1))
  done
  i=0; while [ "$i" -lt "${#files[@]}" ]; do
    size="$(file_size "$i")" || say "${files[$i]}: file is no longer readable" 1
    if [ "$size" -gt "${sizes[$i]}" ]; then grown[i]="$now"; fi
    sizes[i]="$size"
    minutes=$(( (now - ${grown[$i]}) / 60 ))
    if [ $((now - ${grown[$i]})) -ge "$still" ]; then
      last="$(tail -n1 "${files[$i]}" 2> "$err")" || say "${files[$i]}: cannot read final event: $(tail -n1 "$err")" 1
      if ! printf '%s' "$last" | jq -se 'length == 1 and (.[0] | type == "object" and .type == "turn.completed")' >/dev/null 2>/dev/null; then
        say "${files[$i]} has not grown for $minutes minutes ($size bytes)"
      fi
    fi
    report="$report; ${files[$i]}, $size bytes, $minutes minutes since growth"
    i=$((i + 1))
  done
  [ $((now - start)) -lt "$heartbeat" ] || say "heartbeat after $(( (now - start) / 60 )) minutes: ${report#; }"
done
