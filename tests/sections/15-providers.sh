#!/usr/bin/env bash
# no gh outside lib/github/; one section of the suite, run by tests/check.sh with the others
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

section "the providers: no command and no library outside lib/github/ calls gh, so a second provider needs no copy of any of them"
# list_files <root>: every file under bin/ and lib/ of <root>, whatever its extension, except lib/github/
list_files() { find "$1/bin" "$1/lib" -type f ! -path "$1/lib/github/*" | sort; }
# scan_file <file> <name>: prints "<name>:<line>:<text>" for every line that uses gh. A line counts when
# gh stands where a command stands (line start, or after ; & | ( ) { ! $( ` or then do else if elif while
# until, so the arm of a case is one), behind any of the prefixes that pass the command on (VAR=x, exec, env, command, nohup, time,
# sudo, nice, timeout N, xargs with its flags, apart, run_split), bare or in quotes; when gh_read is used; or when a
# spawn or exec call of a .mjs file names gh first. A line that starts with // or * is a comment only
# in a JavaScript file; in a shell file it can be a case arm. The comment is cut where a # follows a space outside
# quotes, so a # inside a string hides nothing; `command -v gh`, the word in a message and in a comment
# are no use of gh, because no command position holds it.
scan_file() {
  awk -v f="$2" -v sq="'" '
    function strip(s,   i, c, q, n) {
      q = ""; n = length(s)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (q == "\"" && c == "\\") { i++; continue }
        if (q == "") {
          if (c == "\"" || c == sq) q = c
          else if (c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[[:space:]]/)) return substr(s, 1, i - 1)
        } else if (c == q) q = ""
      }
      return s
    }
    BEGIN {
      lead = "(^|[;&|()`!{]|\\$\\(|[[:space:]](then|do|else|if|elif|while|until))[[:space:]]*"
      prefix = "(([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*|exec|env|command|nohup|time|sudo|nice|xargs([[:space:]]+-[^[:space:]]+)*|apart|run_split|timeout[[:space:]]+[0-9a-z.]+)[[:space:]]+)*"
      call = lead prefix "(gh([[:space:]]|$)|\"gh\"|" sq "gh" sq ")"
      spawn = "(spawn|exec)[A-Za-z]*[[:space:]]*\\([[:space:]]*[\"`" sq "]gh([\"`" sq "]|[[:space:]])"
    }
    f ~ /\.[cm]?js$/ && /^[[:space:]]*(\/\/|\/?\*)/ { next }
    { line = " " strip($0) }
    line ~ /(^|[^A-Za-z0-9_])gh_read([^A-Za-z0-9_]|$)/ || line ~ call || line ~ spawn { print f ":" NR ":" $0 }' "$1"
}
scan() {
  local f
  list_files "$1" | while IFS= read -r f; do scan_file "$f" "${f#"$1"/}"; done
}
files_read() { list_files "$1" | wc -l | tr -d ' '; }

found="$(scan "$ROOT")"
[ -z "$found" ] || fail "gh is used outside lib/github/:
$found"

# the same scan finds gh where it is allowed, so it can see a call at all
inside="$(find "$ROOT/lib/github" -type f | while IFS= read -r f; do scan_file "$f" "$f"; done | wc -l | tr -d ' ')"
[ "$inside" -gt 0 ] || fail "the scan finds no gh call in lib/github/, so it cannot be told to see one"

# plant_case <file in the plant> <red|green> <line>: the line alone in a fresh tree, the scan must find
# it (red) or find nothing (green)
plant="$WORK/plant"; planted=0
plant_case() {
  local target="$1" want="$2" line="$3" got
  planted=$((planted + 1))
  rm -rf "$plant"; mkdir -p "$plant/bin" "$plant/lib/plane"
  printf '%s\n' "$line" > "$plant/$target"
  got="$(scan "$plant")"
  if [ "$want" = red ]; then
    [ "$(printf '%s\n' "$got" | grep -c .)" = 1 ] || fail "the scan did not go red on one planted line in $target: $line; it found: $got"
  else
    [ -z "$got" ] || fail "the scan went red on an innocent line in $target: $line; it found: $got"
  fi
}
while IFS= read -r line; do plant_case lib/plane/tracker.sh red "$line"; done <<'PLANTED'
gh issue view 4
  gh issue view 4
x="$(gh_read "x" api repos/a/b)"
command gh api user
x=1; gh api user
y="$(gh api user)"
if gh auth status >/dev/null 2>&1; then :; fi
while gh api user; do :; done
until gh api user; do :; done
{ gh release download v1; }
GH_TOKEN=x gh api user
exec gh api user
timeout 5 gh api user
env gh api user
"gh" api user
'gh' api user
echo "a # b"; gh api user
PLANTED
plant_case lib/plane/tracker.sh red 'x | xargs gh api'
plant_case lib/plane/tracker.sh red 'x | xargs -n1 gh issue view'
plant_case lib/plane/tracker.sh red 'x | xargs -I{} gh issue view {}'
plant_case lib/plane/tracker.sh red '    --me) gh api user ;;'
plant_case lib/plane/tracker.sh red '  *) gh issue view 4 ;;'
plant_case lib/plane/tracker.sh red '  github) gh api user ;;'
plant_case lib/plane/tracker.sh red 'case "$x" in *) gh api user ;; esac'
plant_case lib/notes.txt red 'gh api user'
plant_case bin/issue-new red 'if gh auth status; then :; fi'
plant_case lib/call.mjs red "spawnSync('gh', ['api', 'user']);"
plant_case lib/call.mjs red 'execFileSync("gh", ["api", "user"]);'
plant_case lib/call.mjs red 'execSync(`gh api user`);'
while IFS= read -r line; do plant_case lib/plane/tracker.sh green "$line"; done <<'INNOCENT'
# gh issue view 4 is the call this line once was
echo "gh is not on the PATH"
printf '%s\n' "run gh issue view 4 yourself"
command -v gh >/dev/null 2>&1 || exit 2
x=1 # then gh api user
INNOCENT
plant_case lib/plane/tracker.sh green '  *) die "gh is missing" ;;'
plant_case lib/plane/tracker.sh green '  --me) echo "run gh api user" ;;'
plant_case lib/call.mjs green "// spawnSync('gh', ['api', 'user']);"
plant_case lib/call.mjs green 'console.log("gh is missing");'
echo "  $(files_read "$ROOT") files of bin/ and lib/ read, none calls gh; $planted planted cases, red on each spelling of a call and green on the word in a comment, a message and command -v gh; $inside calls found in lib/github/"
exit 0
