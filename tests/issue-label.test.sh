#!/usr/bin/env bash
# What issue-label puts on an issue, what it takes off, and what it sends to do it.
#
#   bash test/issue-label.test.sh
#
# NOTHING REACHES github.com. A stand-in `gh` holds the labels of each issue in a file,
# answers `issue view` from it and applies `issue edit` to it, so the assertion is the
# label set the issue is left carrying and not merely the words the script printed. No
# board is resolved either: issue-label never selects a project.
#
# THE STAND-IN REFUSES WHAT gh REFUSES. Measured against github.com on 2026-08-26:
#
#   gh issue edit 12 --repo example-org/example-tools --remove-label does-not-exist-anywhere
#     -> failed to update ...: 'does-not-exist-anywhere' not found        exit 1
#   gh issue edit 12 --repo example-org/example-tools --remove-label type:bug   (not on it)
#     -> https://github.com/example-org/example-tools/issues/12               exit 0
#
# So a name the REPOSITORY does not carry kills the run, and a name the ISSUE does not
# carry is a no-op. That is the whole reason issue-label reads the issue's labels before
# it sends anything, and the stand-in models both answers so the difference can be shown.
#
# THE PLANTED DEFECTS, one per shape this suite catches, each replayed against the
# stand-in so it is shown RED rather than argued about:
#   - the edit call with its --remove-label half dropped, which is an edit that only ever
#     adds: the retired label is still on the issue afterwards.
#   - the removal sent without reading the issue first: gh exits 1 and the run is dead.
#   - a label name holding a space, word-split the way a glued command line splits it:
#     gh is asked to remove 'help', which the repository does not have, and exits 1.
#
# THE PLANTED INNOCENT CASES, so a green run means the checks looked: a run that only
# adds, a second run of the same call that changes nothing, and a removal of a name the
# taxonomy declares nothing about, which must be allowed.
#
# WHAT THIS DOES NOT REACH, named rather than counted:
#   - the taxonomy itself. The names used below are read from the tracked labels.tsv:
#     type:bug, type:chore, area:installation and area:tooling are declared there and
#     area:install, tooling and design are not, which is the retirement this ticket is
#     about. A change to that file that undeclares one of the first four, or declares
#     one of the last three, turns this suite red and is meant to.
#   - whether gh accepts what it is handed. Only the two answers measured above are
#     modelled; anything else gh does is gh's own check.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAKE="$(mktemp -d)"
REPO="example-org/example-repo"
failed=0

cleanup() { rm -rf "$FAKE"; }
trap cleanup EXIT

check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}

# The labels the REPOSITORY carries. labels-sync leaves a retired name alone, so the
# names taken off tickets below are all still here - which is why removing them works.
cat > "$FAKE/repo-labels" <<'EOF'
type:bug
type:chore
area:installation
area:tooling
area:install
tooling
design
help wanted
EOF

# One file per issue, holding the labels it carries.
seed() { # seed <number> <label>...
  local n="$1"; shift
  printf '%s\n' "$@" > "$FAKE/issue-$n"
}
labels_on() { tr '\n' ' ' < "$FAKE/issue-$1" | sed 's/ $//'; }

mkdir -p "$FAKE/bin"
cat > "$FAKE/bin/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$FAKE/calls"
sub="\$2"; num="\$3"; shift 3
case "\$sub" in
  view) cat "$FAKE/issue-\$num"; exit 0 ;;
  edit)
    adds=(); removes=()
    while [ \$# -gt 0 ]; do
      case "\$1" in
        --add-label)    adds+=("\$2");    shift 2 ;;
        --remove-label) removes+=("\$2"); shift 2 ;;
        *) shift ;;
      esac
    done
    for l in \${adds[@]+"\${adds[@]}"} \${removes[@]+"\${removes[@]}"}; do
      grep -qxF -- "\$l" "$FAKE/repo-labels" || {
        echo "failed to update https://github.com/$REPO/issues/\$num: '\$l' not found" >&2
        echo 'failed to update 1 issue' >&2
        exit 1; }
    done
    for l in \${removes[@]+"\${removes[@]}"}; do
      grep -vxF -- "\$l" "$FAKE/issue-\$num" > "$FAKE/tmp" || true
      mv "$FAKE/tmp" "$FAKE/issue-\$num"
    done
    for l in \${adds[@]+"\${adds[@]}"}; do
      grep -qxF -- "\$l" "$FAKE/issue-\$num" || printf '%s\n' "\$l" >> "$FAKE/issue-\$num"
    done
    echo "https://github.com/$REPO/issues/\$num"
    exit 0 ;;
esac
echo "the stand-in was asked something it does not answer: \$sub" >&2
exit 1
EOF
chmod +x "$FAKE/bin/gh"
export PATH="$FAKE/bin:$PATH"

run() { # run <issue-label.sh argument>...
  : > "$FAKE/calls"
  bash "$ROOT/bin/issue-label.sh" "$REPO" "$@" 2>&1
}
edits() { grep -c '^issue edit' "$FAKE/calls"; }
edit_call() { grep '^issue edit' "$FAKE/calls" | head -1; }

# --- 1. retiring a label and putting its replacement on, in one call ---------------------------

echo 'a retired label off and its replacement on, in one call'

seed 72 type:bug area:install
out="$(run 72 --add area:installation --remove area:install)"
check 'the run says what it did'  '#72 -> +area:installation -area:install' "$out"
check 'the retired name is gone and the rest is untouched' 'type:bug area:installation' "$(labels_on 72)"
check 'one edit was sent, carrying both halves' \
      "issue edit 72 --repo $REPO --add-label area:installation --remove-label area:install" "$(edit_call)"

# THE PLANTED DEFECT: an edit that only ever adds.
# Replayed against the same starting point, the retired label is still there afterwards.
seed 72 type:bug area:install
"$FAKE/bin/gh" issue edit 72 --repo "$REPO" --add-label area:installation >/dev/null
check 'the plant: an edit with no remove half leaves the retired name on' \
      'type:bug area:install area:installation' "$(labels_on 72)"

# --- 2. a name the taxonomy no longer declares ------------------------------------------------

echo
echo 'a name labels.tsv does not declare comes off, and does not go on'

seed 8 tooling design type:chore area:tooling
out="$(run 8 --remove tooling --remove design)"
check 'both retired names come off'          '#8 -> -tooling -design' "$out"
check 'and the declared ones stay'           'type:chore area:tooling' "$(labels_on 8)"

seed 8 type:chore area:tooling
out="$(run 8 --add tooling)"
check 'the same name is refused on --add' yes \
      "$(case "$out" in *'"tooling" is not in the taxonomy'*) echo yes ;; *) echo "no: $out" ;; esac)"
check 'and nothing was sent' 0 "$(edits)"

# --- 3. a label the issue does not carry ------------------------------------------------------

echo
echo 'a label the issue does not carry is reported, and the run stays green'

seed 84 type:bug area:tooling
out="$(run 84 --remove area:instal)"
check 'it is named, and nothing changed' '#84 -> unchanged  not on it: area:instal' "$out"
check 'the labels are as they were'      'type:bug area:tooling' "$(labels_on 84)"
check 'and no edit was sent'             0 "$(edits)"

# THE PLANTED DEFECT: the same removal sent without reading the issue first, which is
# what a script that trusted its arguments would send.
"$FAKE/bin/gh" issue edit 84 --repo "$REPO" --remove-label area:instal >/dev/null 2>"$FAKE/err"
check 'the plant: sent unread, gh refuses it' 1 "$?"
check 'the plant: and says which name'  yes \
      "$(case "$(cat "$FAKE/err")" in *"'area:instal' not found"*) echo yes ;; *) echo "no: $(cat "$FAKE/err")" ;; esac)"

# --- 4. what the ticket is left missing -------------------------------------------------------

echo
echo 'a ticket left without a type or an area is named'

seed 95 type:bug area:tooling
out="$(run 95 --remove type:bug)"
check 'the missing family is named' '#95 -> -type:bug  MISSING a type label' "$out"

seed 96 type:bug area:tooling
out="$(run 96 --remove area:tooling)"
check 'and so is the other one'     '#96 -> -area:tooling  MISSING an area label' "$out"

# --- 5. a label name holding a space ----------------------------------------------------------

echo
echo 'a label name holding a space stays one argument'

seed 97 'help wanted' type:bug area:tooling
out="$(run 97 --remove 'help wanted')"
check 'it comes off whole'      '#97 -> -help wanted' "$out"
check 'and nothing else went with it' 'type:bug area:tooling' "$(labels_on 97)"

# THE PLANTED DEFECT: the same name word-split, the way a glued command line splits it.
seed 97 'help wanted' type:bug area:tooling
"$FAKE/bin/gh" issue edit 97 --repo "$REPO" --remove-label help wanted >/dev/null 2>"$FAKE/err"
check 'the plant: split in two, gh is asked for a label that does not exist' yes \
      "$(case "$(cat "$FAKE/err")" in *"'help' not found"*) echo yes ;; *) echo "no: $(cat "$FAKE/err")" ;; esac)"
check 'the plant: and the issue keeps it' 'help wanted type:bug area:tooling' "$(labels_on 97)"

# --- 6. the same name on both sides -----------------------------------------------------------

echo
echo 'the same name to add and to remove'

seed 98 type:bug area:tooling
out="$(run 98 --add area:tooling --remove area:tooling)"
check 'is refused, and named' yes \
      "$(case "$out" in *"'area:tooling' is named to add and to remove"*) echo yes ;; *) echo "no: $out" ;; esac)"
check 'and nothing was sent' 0 "$(edits)"

# --- 7. the innocent cases --------------------------------------------------------------------

echo
echo 'a run that only adds, and a second run of it'

seed 99 type:bug
out="$(run 99 --add area:tooling)"
check 'the label goes on'       '#99 -> +area:tooling' "$out"
check 'and the issue carries it' 'type:bug area:tooling' "$(labels_on 99)"

out="$(run 99 --add area:tooling)"
check 'running it again changes nothing' '#99 -> unchanged  already on it: area:tooling' "$out"
check 'and no edit was sent'             0 "$(edits)"

echo
echo 'a call that names no label, and the spelling this script used to take'

seed 102 type:bug area:tooling
out="$(run 102)"
check 'naming no label stops the run' 'error: nothing to do - name a label to add or to remove' "$out"
check 'and nothing was sent' 0 "$(edits)"

# The positional label list this script took before. It must refuse and say what to type,
# rather than reading the label as an issue number or dropping it.
out="$(run 102 type:chore)"
check 'a label where a number belongs is refused' \
      "error: 'type:chore' is not an issue number - a label is named with --add or --remove" "$out"
check 'and nothing was sent' 0 "$(edits)"

echo
echo 'several issues in one call'

seed 100 type:bug area:install
seed 101 type:bug
out="$(run 100 101 --add area:installation --remove area:install)"
check 'each one reports its own line' \
      '#100 -> +area:installation -area:install
#101 -> +area:installation  not on it: area:install' "$out"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo; echo 'all passed'
