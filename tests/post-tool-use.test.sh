#!/usr/bin/env bash
# What the PostToolUse hook for Read does with the list of unread rules files that bin/session-start.sh wrote after a
# compaction: a Read that covered a listed file from its first line to its last takes it out, the last file takes the
# list with it, and a Read of one span of a file, of an unlisted file, or by another session changes nothing.
#
#   bash tests/post-tool-use.test.sh

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export HOME="$work/home" AI_CORE_HOME="$work/core"; mkdir -p "$HOME" "$AI_CORE_HOME"
failed=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}
hook="$root/bin/post-tool-use.sh"
records="$AI_CORE_HOME/.ai-core/rules-unread"
rules="$work/rules"; mkdir -p "$rules"
printf 'one\ntwo\nthree\n' > "$rules/a.md"; printf 'only\n' > "$rules/b.md"; printf 'x\n' > "$rules/c.md"
record() { mkdir -p "$records"; printf '%s\n%s\n' "$rules/a.md" "$rules/b.md" > "$records/$1"; }
read_done() {  # read_done <session> <file> [offset] [limit]: the hook after that Read
  jq -nc --arg s "$1" --arg f "$2" --arg o "${3:-}" --arg l "${4:-}" '{session_id: $s, hook_event_name: "PostToolUse", tool_name: "Read", tool_input: ({file_path: $f} + (if $o != "" then {offset: ($o | tonumber)} else {} end) + (if $l != "" then {limit: ($l | tonumber)} else {} end)), tool_response: {}}' | bash "$hook" 2>&1
}
# left <session>: the files still listed, names only, comma-separated, or "no list"
left() { if [ -f "$records/$1" ]; then xargs -n1 basename < "$records/$1" | paste -sd, -; else echo 'no list'; fi; }

echo 'a Read of one span of a file leaves it listed'
record s1
check 'a limit shorter than the file' 'a.md,b.md' "$(read_done s1 "$rules/a.md" '' 2 > /dev/null; left s1)"
check 'an offset past the first line' 'a.md,b.md' "$(read_done s1 "$rules/a.md" 2 > /dev/null; left s1)"
check 'a file that is not listed' 'a.md,b.md' "$(read_done s1 "$rules/c.md" > /dev/null; left s1)"
check 'another session reading a listed file' 'a.md,b.md' "$(read_done s2 "$rules/a.md" > /dev/null; left s1)"

echo 'a whole Read takes the file out, and the last file takes the list'
check 'a whole Read of a.md' b.md "$(read_done s1 "$rules/a.md" > /dev/null; left s1)"
check 'a second Read of a.md changes nothing' b.md "$(read_done s1 "$rules/a.md" > /dev/null; left s1)"
out="$(read_done s1 "$rules/b.md" 1 5)"
check 'the whole Read of b.md, with limit 5, prints nothing' '' "$out"
check 'and the list is gone' 'no list' "$(left s1)"
check 'a Read with no list at all prints nothing' '' "$(read_done s1 "$rules/a.md")"

echo 'a Read through a link and by a path with .. is the same file'
record s1; ln -s "$rules/a.md" "$work/link.md"
check 'through a link' b.md "$(read_done s1 "$work/link.md" > /dev/null; left s1)"
check 'by a path with ..' 'no list' "$(read_done s1 "$rules/../rules/b.md" > /dev/null; left s1)"

echo 'other tools and input that is not a Read'
record s1
check 'a Bash call changes nothing' 'a.md,b.md' "$(jq -nc '{session_id: "s1", tool_name: "Bash", tool_input: {command: "cat a"}}' | bash "$hook" > /dev/null 2>&1; left s1)"
check 'a Read with no file changes nothing' 'a.md,b.md' "$(jq -nc '{session_id: "s1", tool_name: "Read", tool_input: {}}' | bash "$hook" > /dev/null 2>&1; left s1)"
out="$(echo 'not json' | bash "$hook" 2>&1)"; rc=$?
check 'input that is not JSON, with a list: exit 1 and a word on stderr' '1 post-tool-use: the PostToolUse input is not JSON this hook can read' "$rc $out"
rm -rf "$records"
out="$(echo 'not json' | bash "$hook" 2>&1)"; rc=$?
check 'input that is not JSON, no list on the machine: silent exit 0' '0 ' "$rc $out"
check 'a session id with a slash names no list' '' "$(read_done '../x' "$rules/a.md")"

echo 'planted: a hook that marks any Read whole takes a span out of the list, so the cases above are what turn red'
mutant="$work/mutant"; mkdir -p "$mutant/bin"; cp -R "$root/lib" "$mutant/"; cp "$hook" "$mutant/bin/"
sed -i.bak 's/ && rules_read_is_whole "\$path" "\$offset" "\$limit"//' "$mutant/bin/post-tool-use.sh"
cmp -s "$hook" "$mutant/bin/post-tool-use.sh" && { echo '  FAIL the planted copy equals bin/post-tool-use.sh'; failed=$((failed + 1)); }
record s1
jq -nc --arg f "$rules/a.md" '{session_id: "s1", tool_name: "Read", tool_input: {file_path: $f, limit: 1}}' | bash "$mutant/bin/post-tool-use.sh" > /dev/null 2>&1
check 'the span takes a.md out in the planted copy' b.md "$(left s1)"
rm -rf "$records"
out="$(bash "$hook" --help)"; rc=$?
check '--help: exit code' 0 "$rc"

if [ "$failed" -ne 0 ]; then echo "$failed failed"; exit 1; fi
echo 'all passed'
