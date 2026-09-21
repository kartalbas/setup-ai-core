#!/usr/bin/env bash
# The Bash twin of argument-binding.test.ps1, asserting the SAME rules against bin/*.sh.
#
#   bash test/argument-binding.test.sh
#
# THE CLASS THIS HOLDS CLOSED. Every parser in bin/ matches option names by hand, so on its own
# bash refuses nothing: a parser that files what it did not match under the positional arguments
# turns a misspelt `--project` into a status name, a repo, an issue number, a label or a board
# title, and `--project --dry-run` takes the next FLAG as the board number. Both read downstream
# as "no board was named", and a board that was not named is resolved from the CURRENT DIRECTORY
# - which is a real board, so nothing afterwards can tell. The guards are `need_value` and
# `reject_options` in lib/board.sh plus a `-*)` arm in every parse loop, and they are held here
# rather than by discipline because a script added without them re-opens exactly that.
#
# NOTHING REACHES A REAL BOARD, INCLUDING WHEN A CHECK FAILS. A stand-in `gh` is on PATH for the
# whole run: it records what it was asked and answers an empty board. Sections 1 and 2 stop before
# any gh call while the guards hold, but a run with a guard MISSING is exactly what those sections
# are for, and such a run walks on to the board lookup - against github.com if the stand-in were
# installed later. Section 3 additionally seeds one cached project id per board number, so which
# board the script acted on can be read back from the id it sent.
#
# THE PLANTED CASE, so a green run means the checks looked rather than that nothing was there.
# Section 1 builds a throwaway script carrying the OLD parse loop - the one with no `-*)` arm and
# no `need_value` - and asserts that it swallows both shapes. Without it, every refusal below
# could equally be bash stopping for some reason of its own.
#
# WHAT THIS DOES NOT REACH, named rather than counted:
#   - a VALUE that begins with a dash. `need_value` refuses `--title '-x marks the spot'`, and
#     the PowerShell twin BINDS it, because its parser still knows which words were quoted and
#     bash has lost that by the time "$2" is read. lib/board.sh states the asymmetry and what it
#     costs. The twins answer differently for exactly that input and this suite asserts neither
#     side of it as correct.
#   - whether gh accepts what it is handed. That is gh's own check and is not asked here.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAKE="$(mktemp -d)"
export GH_CACHE_DIRECTORY="$FAKE/cache"

# Two board numbers no real project carries, so the caches these seed cannot be mistaken for a
# live board's - and are removed again below. They differ so which one a run used can be read off
# the project id it sent.
GIVEN=999994
FROM_ENVIRONMENT=999993

failed=0

cleanup() { rm -rf "$FAKE"; }
trap cleanup EXIT

check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}

# The stand-in, installed before the first check. It records what it was asked and answers a board
# with no cards, which is enough for every script this suite drives.
mkdir -p "$FAKE/bin"
cat > "$FAKE/bin/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$FAKE/calls"
echo '{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}'
exit 0
EOF
chmod +x "$FAKE/bin/gh"
export PATH="$FAKE/bin:$PATH"

# What a run did: the message it stopped with, or 'ran' when it did not stop at all.
refusal() { # refusal <command>...
  local out
  out="$("$@" 2>&1)" && { echo 'ran'; return; }
  printf '%s\n' "$out" | head -1
}

# Whether a message names the word the caller got wrong. A refusal that does not say which word
# to fix costs the same round trip as no refusal at all.
names() { # names <message> <word>
  case "$1" in *"$2"*) echo yes ;; *) echo "no: $1" ;; esac
}

# --- 1. an argument the script does not take -------------------------------------------------

echo 'an argument bin/*.sh does not take stops the run'

check 'board-list.sh --projekt is refused' yes \
      "$(names "$(refusal bash "$ROOT/bin/board-list.sh" --projekt 6)" "--projekt")"
check 'epics-top.sh --projekt is refused'  yes \
      "$(names "$(refusal bash "$ROOT/bin/epics-top.sh" --projekt 6)" "--projekt")"
check 'issue-new.sh --titel is refused'    yes \
      "$(names "$(refusal bash "$ROOT/bin/issue-new.sh" --titel t)" "--titel")"
# issue-label takes two flags that are one letter apart in effect: --add puts a label on and
# --remove takes it off. A misspelt one filed under the positional arguments would be read as
# an issue number or dropped, and the run would report a change it did not make.
check 'issue-label.sh --remove-lable is refused' yes \
      "$(names "$(refusal bash "$ROOT/bin/issue-label.sh" 8 --remove-lable tooling)" "--remove-lable")"
# reject_options is the whole check for the three scripts that take no flags at all.
check 'subissue-add.sh --project is refused' yes \
      "$(names "$(refusal bash "$ROOT/bin/subissue-add.sh" --project 5 6)" "--project")"
check 'repo-boards.sh --project is refused'  yes \
      "$(names "$(refusal bash "$ROOT/bin/repo-boards.sh" --project 6)" "--project")"
check 'field-option-add.sh --feld is refused' yes \
      "$(names "$(refusal bash "$ROOT/bin/field-option-add.sh" --feld Priority)" "--feld")"

# THE PLANTED DEFECT. The parse loop as it stood before the guards, so the refusals above are
# shown to be the guards and not bash stopping of its own accord.
cat > "$FAKE/old-parse.sh" <<EOF
#!/usr/bin/env bash
project=""
args=()
while [ \$# -gt 0 ]; do
  case "\$1" in
    --project) project="\$2"; shift 2 ;;
    *)         args+=("\$1"); shift ;;
  esac
done
echo "project=[\$project] positional=[\${args[*]:-}]"
EOF

check 'the plant: a misspelt flag became a positional argument' 'project=[] positional=[--projekt 6]' \
      "$(bash "$FAKE/old-parse.sh" --projekt 6)"
check 'the plant: the next flag became the board number' 'project=[--dry-run] positional=[]' \
      "$(bash "$FAKE/old-parse.sh" --project --dry-run)"

# --- 2. a flag without its value ---------------------------------------------------------------

echo
echo 'a flag whose value is missing, or is the next flag'

check 'board-list.sh --project with nothing after it' yes \
      "$(names "$(refusal bash "$ROOT/bin/board-list.sh" --project)" "--project needs a value")"
check 'epics-top.sh --project followed by --dry-run'  yes \
      "$(names "$(refusal bash "$ROOT/bin/epics-top.sh" --project --dry-run)" "--project needs a value")"
check 'issue-new.sh --title followed by --repo'       yes \
      "$(names "$(refusal bash "$ROOT/bin/issue-new.sh" --title --repo x)" "--title needs a value")"
check 'field-option-add.sh --field with nothing after it' yes \
      "$(names "$(refusal bash "$ROOT/bin/field-option-add.sh" --field)" "--field needs a value")"
check 'issue-label.sh --remove with nothing after it'     yes \
      "$(names "$(refusal bash "$ROOT/bin/issue-label.sh" 8 --remove)" "--remove needs a value")"
check 'issue-label.sh --add followed by --remove'         yes \
      "$(names "$(refusal bash "$ROOT/bin/issue-label.sh" 8 --add --remove tooling)" "--add needs a value")"

# --- 3. a number that is not a number ------------------------------------------------------------

# THE TWELVE INPUTS, and the reason example-tools#22 exists. Measured 2026-09-05, PowerShell's
# `[int]` binding against this shell's `case "$n" in ''|*[!0-9]*)` answered differently on ELEVEN
# of them, and `12.6` bound to 13 - the command edited the neighbouring issue and said nothing.
# The same twelve are driven here and in the PowerShell twin, and the two tables must read the
# same, line for line.
#
# solution-path is what they are driven through, because it reaches NOTHING: no board, no gh, no
# network. A number that passes the guard runs to the end against a file that carries all eight
# sections, so `ran` and `refused` say exactly which side of the rule the input fell on.
#
# `-12` is refused on both sides for two different reasons: here it is an argument beginning with
# a dash, which the parse loop refuses because bash cannot tell it from a flag, and there it is
# refused by the rule. The asymmetry is the one named at the top of this file; both refuse.

echo
echo 'a number that is not a number is refused, on the same twelve inputs as the PowerShell twin'

printf '## Where a person meets this\n\nx\n\n## What they see today\n\nx\n\n## What the system does behind it\n\nx\n\n## The decision\n\nx\n\n## Options\n\nx\n\n## Recommendation\n\nx\n\n## Code facts\n\nx\n\n## Reuse manifest\n\nx\n' \
  > "$FAKE/path.md"

number_answer() { # number_answer <value>
  case "$(refusal bash "$ROOT/bin/solution-path.sh" --check "$1" "$FAKE/path.md")" in
    ran) echo ran ;;
    *)   echo refused ;;
  esac
}

check 'a whole number'          ran       "$(number_answer '12')"
check 'a trailing newline'      refused   "$(number_answer $'12\n')"
check 'a leading space'         refused   "$(number_answer ' 12')"
check 'a trailing space'        refused   "$(number_answer '12 ')"
check 'a leading plus'          refused   "$(number_answer '+12')"
check 'a leading minus'         refused   "$(number_answer '-12')"
check 'rounding down'           refused   "$(number_answer '12.4')"
check 'rounding UP to 13'       refused   "$(number_answer '12.6')"
check 'scientific notation'     refused   "$(number_answer '1e2')"
check 'a thousands separator'   refused   "$(number_answer '1,234')"
check 'hexadecimal'             refused   "$(number_answer '0x1F')"
check 'Arabic-Indic digits'     refused   "$(number_answer '١٢')"

# The board number arrives at set_project, from a flag or from the environment, and is judged
# there - one guard for every command that passes one in.
check 'board-list.sh --project abc' yes \
      "$(names "$(refusal bash "$ROOT/bin/board-list.sh" --project abc)" "the board number must be numeric, not 'abc'")"
check 'epics-top.sh --project abc'  yes \
      "$(names "$(refusal bash "$ROOT/bin/epics-top.sh" --project abc)" "the board number must be numeric, not 'abc'")"
check 'GH_PROJECT_NUMBER=12.6'      yes \
      "$(names "$(refusal env GH_PROJECT_NUMBER=12.6 bash "$ROOT/bin/epics-top.sh" --dry-run)" "the board number must be numeric, not '12.6'")"

# --- 4. the board named is the board acted on ---------------------------------------------------

# THE ONE THAT COSTS A CARD, and the reason the ticket exists. The two sections above catch a
# misspelt flag at the parse loop; this one catches the SILENT case underneath it - the number
# arriving nowhere and the board being resolved from somewhere else, which no error announces
# because the other board is a real board.
#
# Which board a run acted on is read back from the project id it sent gh. One cached id per board
# number, so the two cannot be confused, and no lookup is needed to get them.

echo
echo 'the board named on the command line is the board that is acted on'

for n in "$GIVEN" "$FROM_ENVIRONMENT"; do
  mkdir -p "$GH_CACHE_DIRECTORY/$n"
  printf 'PVT_kwboard%s\n' "$n" > "$GH_CACHE_DIRECTORY/$n/project-id"
done

board_reached() { # board_reached <epics-top.sh argument>...
  local said
  : > "$FAKE/calls"
  GH_PROJECT_NUMBER="$FROM_ENVIRONMENT" bash "$ROOT/bin/epics-top.sh" "$@" >/dev/null 2>&1
  said="$(cat "$FAKE/calls")"
  case "$said" in
    *pid=PVT_kwboard*) printf '%s\n' "$said" | sed -n 's/.*\(PVT_kwboard[0-9]*\).*/\1/p' | head -1 ;;
    *) echo "no board id was sent, and gh was asked: $said" ;;
  esac
}

check 'the number given on the command line wins over the environment' "PVT_kwboard$GIVEN" \
      "$(board_reached --project "$GIVEN" --dry-run)"

# The innocent case: with nothing on the command line the environment is what is left, so the
# assertion above measures the argument arriving and not a board that was never a choice.
check 'and with no number given, the environment is used' "PVT_kwboard$FROM_ENVIRONMENT" \
      "$(board_reached --dry-run)"

# And the board was never resolved from the directory this test happens to run in. That lookup is
# the fallback a lost value lands on, and it is silent because it succeeds.
board_reached --project "$GIVEN" --dry-run >/dev/null
check 'the current directory was never asked' 'not asked' \
      "$(case "$(cat "$FAKE/calls")" in *"repo view"*) echo 'gh repo view was called' ;; *) echo 'not asked' ;; esac)"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo; echo 'all passed'
