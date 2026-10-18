#!/usr/bin/env bash
# What every library and every provider of this harness shares: the error exit, where the project's
# data and settings live, the read of a setting, and a command's data kept apart from its stderr.
# lib/tracker.sh and lib/forge.sh source it, and so does every provider under lib/<provider>/, because
# bin/release.sh and lib/layers.sh never source lib/board.sh. Source it, do not run it.

HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { echo "error: $*" >&2; exit 1; }

# --- where the data lives -----------------------------------------------------

# THE DATA FILES ARE THE PROJECT'S, NOT THE HARNESS'S: labels.tsv, assignees.tsv, team-modes.tsv,
# models.tsv.
# A checkout carries them in .ai-core/, put there by init; the clone's templates hold the
# defaults a project starts from. Every reader asks here, so every command
# reads the same file: the one of the repository the caller stands in, or of the project folder.
data_dir() {
  local top
  top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$top" ] || top="$PWD"
  echo "$top/.ai-core"
}
data_file() {  # data_file <name>
  local f
  f="$(data_dir)/$1"
  if [ -f "$f" ]; then echo "$f"; else echo "$HARNESS_ROOT/templates/.ai-core/$1"; fi
}

# A SETTING OF THE PROJECT: KEY in the environment, then KEY= in the checkout's .ai-core/config.env,
# then DEFAULT. The value is what stands between the quotes, or up to a comment, so a command with
# spaces in it is read whole. The last line of the file that sets KEY wins.
config_value() {  # config_value <key> <default>
  local key="$1" line
  if [ -n "${!key:-}" ]; then echo "${!key}"; return 0; fi
  if [ -f "$(data_dir)/config.env" ]; then
    line="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$(data_dir)/config.env" | tail -n1 || true)"
    if [ -n "$line" ]; then
      line="${line#*=}"; line="${line%$'\r'}"
      line="${line#"${line%%[![:space:]]*}"}"
      case "$line" in
        \"*) line="${line#\"}"; line="${line%%\"*}" ;;
        \'*) line="${line#\'}"; line="${line%%\'*}" ;;
        '#'*) line="" ;;
        *)   line="${line%%[[:space:]]#*}"; line="${line%"${line##*[![:space:]]}"}" ;;
      esac
      if [ -n "$line" ]; then echo "$line"; return 0; fi
    fi
  fi
  echo "$2"
}

# THE PROVIDER OF A SUBJECT: the key named after the subject (TRACKER for tracker, FORGE for forge)
# in the project's config.env or the environment names a folder of lib/, github when unset, and that
# folder's <subject>.sh is sourced. A value with no such folder stops the command and names the
# folders there are, and so does a provider that lacks a function of the interface, at once and not
# at the first command that happens to call it.
load_provider() {  # load_provider <subject> <the functions of the interface, separated by spaces>
  local subject="$1" key value file f missing="" folders=""
  key="$(printf '%s' "$subject" | tr '[:lower:]' '[:upper:]')"
  value="$(config_value "$key" github | tr '[:upper:]' '[:lower:]')"
  printf -v "$key" '%s' "$value"
  # a name of letters and digits only cannot lead out of lib/
  case "$value" in *[!a-z0-9]*) file="" ;; *) file="$HARNESS_ROOT/lib/$value/$subject.sh" ;; esac
  if [ ! -f "$file" ]; then
    for f in "$HARNESS_ROOT"/lib/*/"$subject.sh"; do folders="$folders $(basename "$(dirname "$f")")"; done
    die "$key is '$value', and this harness has no $subject of that name. It has:$folders"
  fi
  # shellcheck source=/dev/null
  . "$file"
  for f in $2; do [ "$(type -t "$f")" = function ] || missing="$missing $f"; done
  [ -z "$missing" ] || die "the $subject '$value' lacks these functions:$missing"
}

# A COMMAND'S DATA AND ITS STDERR, KEPT APART.
#
# `x="$(cmd 2>&1)"` makes everything the command says on stderr part of x. For a caller that parses
# x, a line of the gh function below ("waiting 60s ...") then stands in front of the JSON or the
# repository name, and the parse fails or reads a wrong value. A caller that parses what it
# captured therefore takes it through `apart`: on success the data is the stdout alone and the
# stderr goes on to the caller's own stderr; on failure both come out together, stdout first, as the
# text for the caller's error message, and the exit status is passed on.
#
# run_split is the shared half: it runs a command with the two streams in separate places, sets
# split_out and split_err and returns the command's status. Its temporary file goes with an
# interrupt (INT, TERM); no script of this repository traps those two.
run_split() {  # run_split <command>...
  local err rc=0
  err="$(mktemp)"
  trap 'rm -f "$err"; exit 130' INT TERM
  split_out="$("$@" 2>"$err")" || rc=$?
  split_err="$(cat "$err")"
  rm -f "$err"; trap - INT TERM
  return "$rc"
}

apart() {  # apart <command>...
  local rc=0
  run_split "$@" || rc=$?
  if [ "$rc" -eq 0 ]; then
    [ -z "$split_err" ] || printf '%s\n' "$split_err" >&2
    [ -z "$split_out" ] || printf '%s\n' "$split_out"
  else
    printf '%s\n' "${split_out:+$split_out$'\n'}$split_err"
  fi
  return "$rc"
}

# --- calls to a service with a token -------------------------------------------

# A TOKEN IS READ WHEN A CALL NEEDS IT, from the command a setting names, and goes nowhere but into the
# one call: not into an argument list, a file, the environment or the terminal. KEY is the setting
# (PLANE_TOKEN_COMMAND, FORGEJO_TOKEN_COMMAND); its value is a command run by bash whose standard
# output is the token. The command's standard error is dropped: it may carry what the token is read
# from. A missing setting, a failing command and an empty answer each stop the caller and name KEY.
token_from_command() {  # token_from_command <setting>
  local key="$1" command token rc=0
  command="$(config_value "$key" "")"
  [ -n "$command" ] || die "$key is not set: set it in .ai-core/config.env or the environment to the command that prints the token"
  token="$(bash -c "$command" 2>/dev/null </dev/null)" || rc=$?
  [ "$rc" -eq 0 ] || die "the command of $key failed (exit $rc), so there is no token"
  token="${token%$'\n'}"; token="${token%$'\r'}"
  [ -n "$token" ] || die "the command of $key printed no token"
  printf '%s\n' "$token"
}

# one line of a curl configuration: the option and its value in quotes, a backslash and a quote escaped
curl_config_line() {  # curl_config_line <option> <value>
  printf '%s = "%s"\n' "$1" "$(printf '%s' "$2" | sed 's/\\/\\\\/g; s/"/\\"/g')"
}

# http_call <token setting> <header name> <header value prefix> <method> <url> [json body]: one HTTP call.
# Sets http_status (000 where curl got no answer), http_body and http_headers, and returns 0 for any
# answer, so the caller judges the status. THE TOKEN REACHES curl THROUGH ITS CONFIGURATION ON STANDARD
# INPUT, because an argument is listed by ps and the environment by /proc: neither holds it. The body is
# the caller's text and goes through a file of its own, never through the shell's arguments, because an
# issue body outgrows what an argument may hold. Called in this shell, never as `$( )`, or what it sets
# ends with the subshell.
http_call() {
  local key="$1" name="$2" prefix="$3" method="$4" url="$5" body="${6:-}" token dir rc=0
  token="$(token_from_command "$key")" || exit 1
  dir="$(mktemp -d)"
  {
    curl_config_line url "$url"; curl_config_line request "$method"; curl_config_line header "$name: $prefix$token"
    if [ -n "$body" ]; then
      printf '%s' "$body" > "$dir/request"
      curl_config_line header "Content-Type: application/json"; curl_config_line data-binary "@$dir/request"
    fi
  } | curl --silent --show-error --connect-timeout 15 --max-time 120 --config - \
        --output "$dir/answer" --dump-header "$dir/headers" --write-out '%{http_code}' > "$dir/status" 2> "$dir/error" || rc=$?
  token=""
  if [ "$rc" -eq 0 ]; then http_status="$(cat "$dir/status")"; else http_status=000; fi
  http_body="$(cat "$dir/answer" 2>/dev/null || true)"
  http_headers="$(cat "$dir/headers" 2>/dev/null || true)"
  [ "$rc" -eq 0 ] || http_body="$(cat "$dir/error")"
  rm -rf "$dir"
  return 0
}
