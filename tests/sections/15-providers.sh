#!/usr/bin/env bash
# no gh outside lib/github/; one section of the suite, run by tests/check.sh with the others
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

section "the providers: no command and no library outside lib/github/ calls gh, so a second provider needs no copy of any of them"
# scan <root>: prints "<file>:<line>:<text>" for every line of bin/* and lib/*.sh that uses gh as a
# command, gh_read, or command gh; a comment, `command -v gh` and the word in a message are no use of it
scan() {
  local f
  for f in "$1"/bin/* "$1"/lib/*.sh; do
    [ -f "$f" ] || continue
    awk -v f="${f#"$1"/}" '
      /^[[:space:]]*#/ { next }
      { line = $0; sub(/[[:space:]]#[[:space:]].*$/, "", line) }
      line ~ /(^|[^A-Za-z0-9_])gh_read([^A-Za-z0-9_]|$)/ || line ~ /command[[:space:]]+gh([[:space:]]|$)/ ||
      line ~ /(apart|run_split|xargs)[[:space:]]+gh([[:space:]]|$)/ ||
      line ~ /(^|[;&|(`!]|\$\(|[[:space:]](then|do|else|if|elif|while|until))[[:space:]]*gh([[:space:]]|$)/ { print f ":" NR ":" $0 }' "$f"
  done
}
files_read() { ls "$1"/bin/* "$1"/lib/*.sh 2>/dev/null | wc -l | tr -d ' '; }

found="$(scan "$ROOT")"
[ -z "$found" ] || fail "gh is used outside lib/github/:
$found"

# the same scan finds gh where it is allowed, so it can see a call at all
inside="$(for f in "$ROOT"/lib/github/*.sh; do awk '/^[[:space:]]*#/ { next } /(^|[^A-Za-z0-9_])gh_read([^A-Za-z0-9_]|$)/ || /command[[:space:]]+gh([[:space:]]|$)/' "$f"; done | wc -l | tr -d ' ')"
[ "$inside" -gt 0 ] || fail "the scan finds no gh call in lib/github/, so it cannot be told to see one"

# planted: three lines in a copy of a command, one of each shape, and the word in a comment, a
# message and `command -v gh`, which are no use of gh
plant="$WORK/plant"; mkdir -p "$plant/bin" "$plant/lib"
cp "$ROOT/bin/issue-reopen.sh" "$plant/bin/issue-reopen.sh"
cp "$ROOT/lib/common.sh" "$plant/lib/common.sh"
printf '%s\n' 'gh issue view 4' 'x="$(gh_read "x" api repos/a/b)"' 'command gh api user' >> "$plant/bin/issue-reopen.sh"
red="$(scan "$plant")"
[ "$(printf '%s\n' "$red" | grep -c .)" = 3 ] || fail "the scan did not go red on three planted lines (gh issue view, gh_read, command gh); it found: $red"
cp "$ROOT/bin/issue-reopen.sh" "$plant/bin/issue-reopen.sh"
printf '%s\n' '# gh issue view 4 is the call this line once was' 'echo "gh is not on the PATH"' 'command -v gh >/dev/null 2>&1 || exit 2' >> "$plant/bin/issue-reopen.sh"
green="$(scan "$plant")"
[ -z "$green" ] || fail "the scan went red on the word gh in a comment, a message and command -v: $green"
echo "  $(files_read "$ROOT") files of bin/ and lib/ read, none calls gh; red on three planted calls, green on the word in a comment, a message and command -v gh; $inside calls found in lib/github/"
exit 0
