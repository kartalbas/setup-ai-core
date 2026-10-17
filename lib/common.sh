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
