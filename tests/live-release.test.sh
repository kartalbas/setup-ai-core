#!/usr/bin/env bash
# The reader of a `command` environment (lib/live-release.sh): what the harness runs, what it accepts
# of the answer, and what it refuses. Every refusal is planted once as a project's executable that
# answers wrongly, and each rule of the unit is planted as a defect in a copy of it, which the same
# assertions must catch. Nothing reaches a network.
#
#   bash tests/live-release.test.sh

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W="$(mktemp -d)"
export HOME="$W/home" AI_CORE_HOME="$W/ai-core-home"
mkdir -p "$HOME" "$AI_CORE_HOME"
trap 'rm -rf "$W"' EXIT
failed=0; bad=0; quiet=""
expect() {  # expect <name> <expected> <actual>
  if [ "$2" = "$3" ]; then [ -n "$quiet" ] || echo "  ok   $1"
  else bad=$((bad + 1)); [ -n "$quiet" ] || { echo "  FAIL $1"; echo "       expected: [$2]"; echo "       actual:   [$3]"; }; fi
}

# A clone with one commit, and a reader of its own that answers what $W/mode says
clone="$W/folder/component"
mkdir -p "$clone/.ai-core" "$clone/tools"
git init -q "$clone"
git -C "$clone" -c user.name=check -c user.email=check@localhost commit -q --allow-empty -m 'Land #1'
commit="$(git -C "$clone" rev-parse HEAD)"
absent="$(printf '%040d' 0 | tr 0 a)"
reader="$clone/tools/read release"
cat > "$reader" <<EOF
#!/usr/bin/env bash
# A planted reader: it writes down how it was started and answers what the mode file says
printf '%s|%s|%s|%s\n' "\$PWD" "\$#" "\$1" "\$2" >> "$W/calls.txt"
if IFS= read -r -t 1 line; then echo "stdin was not empty" >> "$W/calls.txt"; fi
answer() { printf '{"repository":"%s","environment":"%s","commit":"%s","releasedAt":"%s","source":"%s"}\n' "\${1:-\$REPO}" "\${2:-\$ENV}" "\${3:-$commit}" "\${4:-2026-09-01T10:00:00Z}" "\${5:-carrier release 7}"; }
REPO="\$1"; ENV="\$2"
case "\$(cat "$W/mode")" in
  ok)           answer ;;
  null)         echo null ;;
  fail)         echo "the carrier cannot be reached" >&2; echo '{"ignored":true}'; exit 3 ;;
  failbinary)   printf 'bad\\377text\\n' >&2; exit 3 ;;
  failsilent)   exit 4 ;;
  empty)        : ;;
  text)         echo 'not json at all' ;;
  two)          answer; answer ;;
  array)        echo '[]' ;;
  string)       echo '"delivered"' ;;
  otherrepo)    answer example-org/another ;;
  otherenv)     answer "\$REPO" test ;;
  missing)      printf '{"repository":"%s","environment":"%s","commit":"%s","releasedAt":"2026-09-01T10:00:00Z"}\n' "\$REPO" "\$ENV" "$commit" ;;
  number)       printf '{"repository":"%s","environment":"%s","commit":"%s","releasedAt":"2026-09-01T10:00:00Z","source":7}\n' "\$REPO" "\$ENV" "$commit" ;;
  emptyfield)   printf '{"repository":"%s","environment":"%s","commit":"%s","releasedAt":"2026-09-01T10:00:00Z","source":""}\n' "\$REPO" "\$ENV" "$commit" ;;
  shortcommit)  answer "\$REPO" "\$ENV" "${commit:0:7}" ;;
  absentcommit) answer "\$REPO" "\$ENV" "$absent" ;;
  spacetime)    answer "\$REPO" "\$ENV" "$commit" '2026-09-01 10:00:00' ;;
  fraction)     answer "\$REPO" "\$ENV" "$commit" 2026-09-01T10:00:00.5Z ;;
  nodate)       answer "\$REPO" "\$ENV" "$commit" 2026-02-30T10:00:00Z ;;
  future)       answer "\$REPO" "\$ENV" "$commit" 2099-01-01T00:00:00Z ;;
  stdin)        answer ;;
esac
EOF
chmod +x "$reader"
printf 'LIVE_TAGS="prod=command"\nLIVE_RELEASE_COMMAND="tools/read release"\n' > "$clone/.ai-core/config.env"
set_mode() { printf '%s\n' "$1" > "$W/mode"; }

# What the unit says for one mode: sets rc (its exit status), out (its standard output) and err (the first line of its standard error)
say() {  # say <lib directory> <mode> [repository] [environment]
  set_mode "$2"
  rc=0; out="$(bash "$1/live-release.sh" read "$clone" "${3:-example-org/component}" "${4:-prod}" 2> "$W/stderr" < /dev/null)" || rc=$?
  err="$(head -n1 "$W/stderr")"
}
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
refused() {  # refused <name> <lib directory> <mode> <what the reason holds>
  say "$2" "$3"
  expect "$1: exit 1, nothing on standard output" "1|" "$rc|$out"
  expect "$1: the reason names the reader, the repository and the environment, and why" yes \
    "$([ "$(has "$err" "$reader")" = yes ] && [ "$(has "$err" 'example-org/component prod')" = yes ] && [ "$(has "$err" "$4")" = yes ] && echo yes || echo "no: $err")"
}

# The whole matrix against the unit in the directory given
matrix() {
  local lib="$1"
  : > "$W/calls.txt"
  say "$lib" ok
  expect 'an answer in the shape is passed on whole, with the commit it names' \
    "0|{\"delivered\":{\"repository\":\"example-org/component\",\"environment\":\"prod\",\"commit\":\"$commit\",\"releasedAt\":\"2026-09-01T10:00:00Z\",\"source\":\"carrier release 7\"}}|" "$rc|$out|$err"
  expect 'the reader is started in the clone with the repository and the environment as two arguments, its path relative to the clone with a space in it' \
    "$clone|2|example-org/component|prod" "$(head -n1 "$W/calls.txt")"
  say "$lib" null
  expect 'JSON null with exit 0 is a read that found no completed delivery' '0|{"delivered":null}|' "$rc|$out|$err"
  refused 'a reader that exits non-zero, and prints JSON too, is an error with the reader'"'"'s own words' "$lib" fail 'exited 3 for example-org/component prod: the carrier cannot be reached'
  refused 'a reader that exits non-zero and says nothing' "$lib" failsilent 'it said nothing'
  LC_ALL=C.UTF-8 say "$lib" failbinary
  expect 'a reader with invalid UTF-8 still fails without standard output' '1|' "$rc|$out"
  expect 'the binary-input diagnostic stays visible' yes "$(has "$err" 'binary file matches')"
  refused 'no output' "$lib" empty 'printed nothing'
  refused 'text that is no JSON' "$lib" text 'no JSON'
  refused 'two JSON values' "$lib" two 'printed 2 JSON values'
  refused 'an array' "$lib" array 'no JSON object'
  refused 'a string' "$lib" string 'no JSON object'
  refused 'another repository' "$lib" otherrepo 'the repository example-org/another'
  refused 'another environment' "$lib" otherenv 'the environment test'
  refused 'a missing field' "$lib" missing 'source is no nonempty string'
  refused 'a field that is no string' "$lib" number 'source is no nonempty string'
  refused 'an empty field' "$lib" emptyfield 'source is no nonempty string'
  refused 'a commit that is no full object ID' "$lib" shortcommit 'no full object ID'
  refused 'a commit the clone does not hold' "$lib" absentcommit 'has no such commit'
  refused 'a time that is not YYYY-MM-DDTHH:MM:SSZ' "$lib" spacetime 'is not YYYY-MM-DDTHH:MM:SSZ'
  refused 'a time with a fraction' "$lib" fraction 'is not YYYY-MM-DDTHH:MM:SSZ'
  refused 'a day the calendar has not' "$lib" nodate 'no time of the calendar'
  refused 'a time in the future' "$lib" future 'is in the future'
  set_mode ok
  : > "$W/calls.txt"; printf 'cards\n' | bash "$lib/live-release.sh" read "$clone" example-org/component prod >/dev/null 2>&1
  expect 'the reader gets no standard input: the caller may be reading its cards from it' '' "$(grep 'stdin was not empty' "$W/calls.txt")"
  # the settings: the clone's own file, never the environment
  out="$(cd "$W" && LIVE_RELEASE_COMMAND=/bin/false bash "$lib/live-release.sh" read "$clone" example-org/component prod 2>&1 < /dev/null | head -c 12)"
  expect 'an exported LIVE_RELEASE_COMMAND does not replace the declaration, and the caller'"'"'s folder does not matter' '{"delivered"' "$out"
  printf 'LIVE_RELEASE_COMMAND="%s"\n' "$reader" > "$clone/.ai-core/config.env"
  say "$lib" ok
  expect 'an absolute path is read as it stands' 0 "$rc"
  printf 'LIVE_RELEASE_COMMAND="tools/gone"\n' > "$clone/.ai-core/config.env"
  say "$lib" ok
  expect 'an absent reader is an error that names its path' "1|yes" "$rc|$(has "$err" "$clone/tools/gone")"
  printf -- '#!/bin/sh\necho null\n' > "$clone/tools/plain"
  printf 'LIVE_RELEASE_COMMAND="tools/plain"\n' > "$clone/.ai-core/config.env"
  say "$lib" ok
  expect 'a file that is not executable is an error' "1|yes" "$rc|$(has "$err" 'is not an executable file')"
  printf 'LIVE_TAGS="prod=command"\n' > "$clone/.ai-core/config.env"
  say "$lib" ok
  expect 'no LIVE_RELEASE_COMMAND is an error that names the setting' "1|yes" "$rc|$(has "$err" 'LIVE_RELEASE_COMMAND is not set in ')"
  printf 'LIVE_TAGS="prod=command"\nLIVE_RELEASE_COMMAND="tools/read release"\n' > "$clone/.ai-core/config.env"
}

echo 'the reader of a command environment: what is run, what is accepted and what is refused'
matrix "$ROOT/lib"
failed=$((failed + bad)); bad=0

echo 'each rule is planted as a defect in a copy of the unit, and the matrix catches it'
mutant="$W/mutant"
detects() {  # detects <name> <sed expression>
  rm -rf "$mutant"; mkdir -p "$mutant"; cp "$ROOT"/lib/*.sh "$mutant"/
  sed -i.bak "$2" "$mutant/live-release.sh"
  if cmp -s "$mutant/live-release.sh" "$ROOT/lib/live-release.sh"; then echo "  FAIL the defect '$1' did not change the unit"; failed=$((failed + 1)); return; fi
  bad=0; quiet=1; matrix "$mutant" >/dev/null; quiet=""
  if [ "$bad" -gt 0 ]; then echo "  ok   the matrix is red on: $1 ($bad assertions)"; else echo "  FAIL the matrix stays green on: $1"; failed=$((failed + 1)); fi
  bad=0
}
detects 'another repository is accepted' '/elif .repository != \$repo then/d'
detects 'another environment is accepted' '/elif .environment != \$environment then/d'
detects 'a time in the future is accepted' '/is in the future/d'
detects 'a day the calendar has not is accepted' '/no time of the calendar/d'
detects 'a commit the clone does not hold is accepted' 's/if \[ "\$resolved" != /if false \&\& [ "$resolved" != /'
detects 'a failing reader is read as no delivery' 's/^    LIVE_RELEASE_ERROR="the reader \$reader exited.*$/    LIVE_RELEASE_ANSWER='"'"'{"delivered":null}'"'"'; return 0/'
detects 'the reader keeps the caller'"'"'s standard input' 's| < /dev/null)|)|'
detects 'the setting is read from the environment' 's|config_file_value LIVE_RELEASE_COMMAND ""|config_value LIVE_RELEASE_COMMAND ""|'

echo
if [ "$failed" -gt 0 ]; then echo "$failed failed"; exit 1; fi
echo 'all passed'
