#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

section "bin/ and lib/: a piped reader must drain its writer"
export HOME="$WORK/home" AI_CORE_HOME="$WORK/ai-core-home"
mkdir -p "$HOME" "$AI_CORE_HOME"

list_files() {
  local f first
  find "$1/bin" "$1/lib" -type f | LC_ALL=C sort | while IFS= read -r f; do
    case "$f" in
      *.sh) printf '%s\n' "$f" ;;
      *) first=""; IFS= read -r first < "$f" || [ -n "$first" ] || continue
         case "$first" in '#!'*bash*|'#!'*/sh) printf '%s\n' "$f" ;; esac ;;
    esac
  done
}

scan_file() {
  awk -v f="$2" '
    function words(s, out,   i, c, q, word, active, n) {
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (q == "\047") {
          if (c == q) q = ""; else word = word c
          continue
        }
        if (c == "\\") {
          c = substr(s, ++i, 1)
          if (c != "\n") { word = word c; active = 1 }
          continue
        }
        if (q == "\"") {
          if (c == q) q = ""; else word = word c
          continue
        }
        if (c == "\047" || c == "\"") { q = c; active = 1; continue }
        if (c == "#" && !active) {
          while (i <= length(s) && substr(s, i, 1) != "\n") i++
          if (n) break
          continue
        }
        if (c ~ /[|;&()]/ || (c == "\n" && (n || active))) break
        if (c ~ /[[:space:]]/) {
          if (active) out[++n] = word
          word = ""; active = 0
        } else { word = word c; active = 1 }
      }
      if (active) out[++n] = word
      return n
    }
    function sed_quits(s,   i, c, delimiter, fields) {
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c ~ /[[:space:]0-9$,!;{}]/) continue
        if (c == "/") {
          while (++i <= length(s)) {
            c = substr(s, i, 1)
            if (c == "\\") i++; else if (c == "/") break
          }
          continue
        }
        if (c == "q" || c == "Q") return 1
        if (c == "#") { while (i <= length(s) && substr(s, i, 1) != "\n") i++; continue }
        if (c == "s") {
          delimiter = substr(s, ++i, 1); fields = 0
          while (++i <= length(s) && fields < 2) {
            c = substr(s, i, 1)
            if (c == "\\") i++; else if (c == delimiter) fields++
          }
        }
        while (i <= length(s) && substr(s, i, 1) !~ /[;\n]/) i++
      }
      return 0
    }
    function without_end(s,   before, i, level, c) {
      while (match(s, /(^|[^[:alnum:]_])END[[:space:]]*\{/)) {
        before = before substr(s, 1, RSTART - 1); i = RSTART + RLENGTH; level = 1
        for (; i <= length(s) && level; i++) {
          c = substr(s, i, 1)
          if (c == "{") level++; else if (c == "}") level--
        }
        s = substr(s, i)
      }
      return before s
    }
    function check(s, number,   n, args, i, j, opt, command, program, seen) {
      n = words(s, args); i = 1
      while (i <= n && (args[i] ~ /^[[:alpha:]_][[:alnum:]_]*=/ || args[i] ~ /^(env|command|exec|!)$/)) i++
      command = args[i++]; sub(/^.*\//, "", command)
      if (command == "head") { print f ":" number ":" lines[number]; return }
      for (; i <= n; i++) {
        opt = args[i]
        if (command == "grep") {
          if (opt == "--") break
          if (opt ~ /^--(quiet|silent|max-count)(=|$)/) { print f ":" number ":" lines[number]; return }
          if (opt ~ /^--(regexp|file|after-context|before-context|context)$/) { i++; continue }
          if (opt !~ /^-[^-]/) continue
          for (j = 2; j <= length(opt); j++) {
            if (substr(opt, j, 1) ~ /[qm]/) { print f ":" number ":" lines[number]; return }
            if (substr(opt, j, 1) ~ /[efABC]/) { if (j == length(opt)) i++; break }
          }
        } else if (command == "awk") {
          if (opt ~ /^-(F|v|f)$/) { i++; continue }
          if (opt ~ /^-/) continue
          program = opt
          gsub(/"([^"\\]|\\.)*"/, "", program)
          gsub(/\/([^\/\\]|\\.)*\//, "", program)
          program = without_end(program)
          if ((" " program " ") ~ /[^[:alnum:]_]exit[^[:alnum:]_]/) print f ":" number ":" lines[number]
          return
        } else if (command == "sed") {
          if (opt == "-f" || opt == "--file") { i++; seen = 1; continue }
          if (opt == "-e" || opt == "--expression") program = args[++i]
          else if (opt ~ /^-e./) program = substr(opt, 3)
          else if (opt ~ /^--expression=/) { program = opt; sub(/^[^=]*=/, "", program) }
          else if (opt ~ /^-/ || seen) continue
          else program = opt
          seen = 1
          if (sed_quits(program)) { print f ":" number ":" lines[number]; return }
        }
      }
    }
    { lines[NR] = $0; source = source $0 "\n" }
    END {
      number = 1
      for (i = 1; i <= length(source); i++) {
        c = substr(source, i, 1)
        nextc = substr(source, i + 1, 1)
        if (c == "\n") number++
        if (quote == "\047") { if (c == "\047") quote = ""; continue }
        if (quote == "\"") {
          if (c == "\\") { if (nextc == "\n") number++; i++; continue }
          if (c == "$" && nextc == "(") {
            depth++; saved[depth] = quote; quote = ""; i++; continue
          }
          if (c == "\"") quote = ""
          continue
        }
        if (c == "\\") { if (nextc == "\n") number++; i++; continue }
        if (c == "#" && (i == 1 || substr(source, i - 1, 1) ~ /[[:space:]]/)) {
          while (i < length(source) && substr(source, i + 1, 1) != "\n") i++
          continue
        }
        if (c == "\047" || c == "\"") { quote = c; continue }
        if (c == "$" && nextc == "(") {
          depth++; saved[depth] = quote; i++; continue
        }
        if (c == "(" && depth) { depth++; saved[depth] = ""; continue }
        if (c == ")" && depth) { quote = saved[depth]; delete saved[depth]; depth--; continue }
        if (c != "|") continue
        if (nextc == "|") { i++; continue }
        check(substr(source, i + 1), number)
      }
    }
  ' "$1"
}

scan() {
  local f files count=0
  files="$(list_files "$1")" || return 1
  [ -n "$files" ] || { echo "no Bash files found in $1/bin and $1/lib" >&2; return 1; }
  while IFS= read -r f; do
    scan_file "$f" "${f#"$1"/}" || return 1
    count=$((count + 1))
  done <<< "$files"
  [ $# -lt 2 ] || printf '%s\n' "$count" > "$2"
}

found="$(scan "$ROOT" "$WORK/files-read")" || fail "the pipe scan could not read bin/ and lib/"
[ -z "$found" ] || fail "early reader after a pipe:
$found"

plant="$WORK/plant"; planted=0
plant_case() {
  local want="$1" line="$2" target="${3:-bin/example.sh}" got
  planted=$((planted + 1))
  rm -rf "$plant"; mkdir -p "$plant/bin" "$plant/lib"
  printf '#!/usr/bin/env bash\n%s\n' "$line" > "$plant/$target"
  got="$(scan "$plant")" || fail "the scan could not read the planted case: $line"
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
plant_case red 'printf x | head -1' bin/ai-core
plant_case red 'printf x | LC_ALL=C grep -q x'
plant_case red 'printf x | "head" -1'
plant_case red 'printf x | command head -1'
plant_case red 'printf x | grep -e x -q'
plant_case red 'printf x | grep --max-count=1 x'
plant_case red 'printf x | sed "1q0"'
plant_case red 'printf x | sed -n "/x/q"'
plant_case red $'printf x |\n  head -1'
plant_case red $'printf x | grep \\\n  -q x'
plant_case red $'printf x | awk \'{\n  print; exit\n}\''
plant_case green 'awk '\''{print; exit}'\'' <<< "$rows"'
plant_case green 'git status --short | sed -n 1p'
plant_case green '# git status --short | head -1'
plant_case green 'echo "run git status --short | head -1 to inspect it"'
plant_case green 'head -n1 "$file"'
plant_case green "tr -d '\\r' < \"\$file\" | awk 'END { exit !seen }'"
plant_case green 'printf x | grep -e "-q"'
plant_case green 'printf x | sed "s/q/r/"'
plant_case green 'printf x | sed "s;q;r;"'
plant_case green "printf x | awk '{ print \"exit\" }'"
plant_case green "printf x | awk '/exit/ { print }'"
plant_case green "printf x | awk 'END { if (seen) { print \"done\" } exit !seen }'"
plant_case green 'printf x | sed "# a comment; q"'

rm -rf "$plant"; mkdir -p "$plant/bin" "$plant/lib"
if scan "$plant" > "$WORK/empty.out" 2> "$WORK/empty.err"; then fail "the scan passed without reading a file"; fi
grep -q 'no Bash files found' "$WORK/empty.err" || fail "the empty scan did not say why it failed"

echo "  $(cat "$WORK/files-read") Bash files of bin/ and lib/ read; $planted planted cases: early readers red, safe readers and text green; an empty scan refused"
