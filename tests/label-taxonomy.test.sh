#!/usr/bin/env bash
# What labels.tsv is held to, and what a row nobody looked at costs.
#
#   bash test/label-taxonomy.test.sh
#
# Nothing reaches github.com: `labels_tsv` reads one file and calls nothing.
#
# THE DEFECT THIS EXISTS AGAINST IS INVISIBLE, which is why it needs a test rather than a
# reader. labels.tsv is read in three places - labels-sync creates the labels from it,
# board-sync decides from it which ticket is missing one, issue-label refuses a name that
# is not in it. board-sync's reading picks rows by their GROUP column. A row whose group
# is misspelt is therefore not seen at all: it is not a type and not an area, so every
# ticket carrying that label is reported as missing a label that is right there on it, and
# the run stays green, because finding nothing is what green looks like. A row named
# `area:gate` filed under group `type` is the same defect one turn worse - it is counted
# as the family it is not, and the board then filters on a lie.
#
# So the file is held against its shape ONCE, in lib/board.sh, and every reader comes
# through there. Each shape below is planted into a copy of labels.tsv, and the run must
# REFUSE and name the line.
#
# THE PLANTED INNOCENT CASE is the repository's own labels.tsv, copied back and read at
# the end: without it every refusal above could equally be a reader that refuses anything.
#
# THE PLANTED UNGUARDED READER shows what the refusals are worth. It is a bare awk over the
# group column - a reader that looks at nothing - run against the same misspelt file, and it
# answers with an empty type list and exit 0, which is the silent failure in full.
#
# THE TRACKED FILE IS NEVER WRITTEN TO. Every plant goes into a copy in a temp directory,
# named `labels.tsv` so the refusals still read as `labels.tsv:<line>`. Planting into the
# repository's own file would stop the two twins running at the same time - each would read
# the other's plant - and a killed run would leave the taxonomy damaged in the working tree.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL="$ROOT/templates/.ai-core/labels.tsv"
WORK="$(mktemp -d)"
FILE="$WORK/labels.tsv"
KEEP="$WORK/keep"
failed=0

cp "$REAL" "$KEEP"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}

. "$ROOT/lib/board.sh"

# What a run of labels_tsv did with the file as it stands: the message it stopped with, or
# 'read' when it did not stop at all. The substitution is what swallows a refusal,
# so the status is taken from an assignment exactly as every caller in bin/ takes it.
outcome() {
  local out
  out="$( { labels_tsv "$FILE" >/dev/null; } 2>&1 )" && { echo 'read'; return; }
  printf '%s\n' "$out" | head -1
}

# Whether a refusal names the line the reader has to open. A refusal that does not say
# which line to fix costs the same round trip as no refusal at all.
names() { # names <message> <word>
  case "$1" in *"$2"*) echo yes ;; *) echo "no: $1" ;; esac
}

plant() { # plant <row>
  cp "$KEEP" "$FILE"
  printf '%s\n' "$1" >> "$FILE"
}

# The line the planted row lands on: the file as it stands plus one.
planted_line() { echo $(( $(wc -l < "$KEEP") + 1 )); }

echo 'a row board-sync could not read is refused, and the line is named'

plant "$(printf 'typ\ttyp:bug\tD73A4A\tA mechanism that misbehaves today')"
check 'a group that is not one of the three' yes \
      "$(names "$(outcome)" "labels.tsv:$(planted_line)")"

# The name is one no other row carries, so the only rule that can fire here is the prefix
# one. Planted as `area:gate` it tripped the duplicate rule instead, and the check stayed
# green with the prefix rule taken out of the library.
plant "$(printf 'type\tarea:not-declared-anywhere\tD73A4A\tA name no other row carries')"
check 'a name whose prefix is not its group'  yes \
      "$(names "$(outcome)" "labels.tsv:$(planted_line)")"

plant "$(printf 'area\tarea\t1D76DB\tA name with no suffix at all')"
check 'a name that is the bare prefix'        yes \
      "$(names "$(outcome)" "labels.tsv:$(planted_line)")"

plant "$(printf 'area\tarea:new\tblue\tA colour that is not six hex digits')"
check 'a colour that is not six hex digits'   yes \
      "$(names "$(outcome)" "labels.tsv:$(planted_line)")"

plant "$(printf 'area\tarea:new\t1D76DB\t')"
check 'a row with no description'             yes \
      "$(names "$(outcome)" "labels.tsv:$(planted_line)")"

plant "$(printf 'area\tarea:new\t1D76DB\tA description\tand a fifth column')"
check 'a row with a fifth column'             yes \
      "$(names "$(outcome)" "labels.tsv:$(planted_line)")"

plant "$(printf 'area\tarea:gate\t1D76DB\tThe same name a second time')"
check 'a name declared twice'                 yes \
      "$(names "$(outcome)" "labels.tsv:$(planted_line)")"

# WHAT THE REFUSALS ARE WORTH. board-sync's old reading of the same misspelt file, so the
# checks above are shown to be the guard and not a reader that refuses whatever it is given.
echo
echo 'what the reader that did not look answered for the same file'

plant "$(printf 'typ\ttyp:bug\tD73A4A\tA mechanism that misbehaves today')"
# `|| true` belongs to grep, which reports "no line matched" with the same status it
# reports an error - and here no match is the answer being measured.
old="$(awk -F'\t' '$1=="type" {print $2}' "$FILE" | grep -cx 'typ:bug' || true)"
check 'the plant: the old parse never saw the row' 0 "$old"
check 'the plant: and it ended without an error'   0 "$(awk -F'\t' '$1=="type" {print $2}' "$FILE" >/dev/null; echo $?)"

# THE INNOCENT CASE. The repository's own file, restored, must read.
echo
echo "the repository's own labels.tsv"

cp "$KEEP" "$FILE"
check 'reads without refusing'                   read "$(outcome)"
check 'and every row carries its own prefix'     ok \
      "$(labels_tsv "$FILE" | awk -F'\t' '$2 !~ "^"$1":" {print "row "NR" is "$1"/"$2; found=1} END {if (!found) print "ok"}')"
check 'the type group is not empty'              yes \
      "$(case "$(label_names_in_group type "$FILE" | grep -c .)" in 0) echo no ;; *) echo yes ;; esac)"
check 'the area group is not empty'              yes \
      "$(case "$(label_names_in_group area "$FILE" | grep -c .)" in 0) echo no ;; *) echo yes ;; esac)"
check 'the closes group is not empty'            yes \
      "$(case "$(label_names_in_group closes "$FILE" | grep -c .)" in 0) echo no ;; *) echo yes ;; esac)"

# HOW MUCH THE READER COVERED, printed rather than assumed: a count that moves when a line
# is added is what says the assertions above ran against the whole file.
echo
echo "labels.tsv declares $(labels_tsv "$FILE" | wc -l | tr -d ' ') labels: \
$(label_names_in_group type "$FILE" | grep -c .) type, \
$(label_names_in_group area "$FILE" | grep -c .) area, \
$(label_names_in_group closes "$FILE" | grep -c .) closes"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo; echo 'all passed'
