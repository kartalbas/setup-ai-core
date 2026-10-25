#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

section "bin/ and lib/: a piped reader must drain its writer"
export HOME="$WORK/home" AI_CORE_HOME="$WORK/ai-core-home"
mkdir -p "$HOME" "$AI_CORE_HOME"

list_files() { find "$1/bin" "$1/lib" -type f -name '*.sh' | LC_ALL=C sort; }
files_read() { list_files "$1" | wc -l | tr -d ' '; }

scan_file() {
  awk -v f="$2" '
    function check(s, line, number,   n, words, i, opt, program) {
      sub(/^[[:space:]\\]+/, "", s)
      if (s ~ /^head([^[:alnum:]_]|$)/) {
        print f ":" number ":" line; return
      }
      if (s ~ /^grep[[:space:]]/) {
        n = split(s, words, /[[:space:]]+/)
        for (i = 2; i <= n && words[i] ~ /^-/; i++) {
          opt = words[i]
          if (opt ~ /^-[^-]*[qm]/ || opt ~ /^--(quiet|max-count)(=|$)/) {
            print f ":" number ":" line; return
          }
        }
      }
      if (s ~ /^awk[[:space:]]/) {
        program = s
        gsub(/END[[:space:]]*\{[^}]*\}/, "", program)
        if ((" " program " ") ~ /[^[:alnum:]_]exit[^[:alnum:]_]/) {
          print f ":" number ":" line; return
        }
      }
      if (s ~ /^sed[[:space:]]/ && (" " s " ") ~ /[^[:alnum:]_][0-9]*q[^[:alnum:]_]/) {
        print f ":" number ":" line
      }
    }
    {
      line = $0
      if (pending && line !~ /^[[:space:]]*$/) {
        check(line, line, NR)
        pending = 0
      }
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        nextc = substr(line, i + 1, 1)
        if (quote == "\047") { if (c == "\047") quote = ""; continue }
        if (quote == "\"") {
          if (c == "\\") { i++; continue }
          if (c == "$" && nextc == "(") {
            depth++; saved[depth] = quote; quote = ""; i++; continue
          }
          if (c == "\"") quote = ""
          continue
        }
        if (c == "\\") { i++; continue }
        if (c == "#" && (i == 1 || substr(line, i - 1, 1) ~ /[[:space:]]/)) break
        if (c == "\047" || c == "\"") { quote = c; continue }
        if (c == "$" && nextc == "(") {
          depth++; saved[depth] = quote; i++; continue
        }
        if (c == "(" && depth) { depth++; saved[depth] = ""; continue }
        if (c == ")" && depth) { quote = saved[depth]; delete saved[depth]; depth--; continue }
        if (c != "|") continue
        if (nextc == "|") { i++; continue }
        tail = substr(line, i + 1)
        if (tail ~ /^[[:space:]\\]*$/) pending = 1
        else check(tail, line, NR)
      }
    }
  ' "$1"
}

scan() {
  local f
  list_files "$1" | while IFS= read -r f; do scan_file "$f" "${f#"$1"/}"; done
}

found="$(scan "$ROOT")"
[ -z "$found" ] || fail "early reader after a pipe:
$found"

plant="$WORK/plant"; planted=0
plant_case() {
  local want="$1" line="$2" got
  planted=$((planted + 1))
  rm -rf "$plant"; mkdir -p "$plant/bin" "$plant/lib"
  printf '%s\n' "$line" > "$plant/bin/example.sh"
  got="$(scan "$plant")"
  if [ "$want" = red ]; then
    [ "$(printf '%s\n' "$got" | grep -c .)" = 1 ] || fail "the scan missed a planted defect: $line; found: $got"
  else
    [ -z "$got" ] || fail "the scan rejected an innocent line: $line; found: $got"
  fi
}

plant_case red 'printf "%s\n" "$rows" | head -1'
plant_case red 'git status --short | head -n1'
plant_case red 'printf "%s\n" "$rows" | grep -m1 wanted'
plant_case red 'git config --get-all foo | grep -q wanted'
plant_case red "printf '%s\\n' \"\$rows\" | awk '{print; exit}'"
plant_case red 'printf "%s\n" "$rows" | sed 3q'
plant_case green 'awk '\''{print; exit}'\'' <<< "$rows"'
plant_case green 'git status --short | sed -n 1p'
plant_case green '# git status --short | head -1'
plant_case green 'echo "run git status --short | head -1 to inspect it"'
plant_case green 'head -n1 "$file"'
plant_case green "tr -d '\\r' < \"\$file\" | awk 'END { exit !seen }'"

echo "  $(files_read "$ROOT") Bash files of bin/ and lib/ read; $planted planted cases: early readers red, safe readers and text green"
