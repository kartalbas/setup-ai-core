#!/usr/bin/env bash
# Which issue a new issue is attached to when --parent is given. The Bash twin of
# issue-parent.test.ps1, asserting the SAME rules against bin/issue-new.sh.
#
#   bash test/issue-parent.test.sh
#
# THE CLASS THIS HOLDS CLOSED. A parent number is only a number: every repository counts
# its own issues, so the same number resolves in every one of them, to unrelated issues.
# The REST sub_issues endpoint reads the number in the ONE repository it is posted to,
# accepts it, and answers success - so a parent meant for another repository silently
# became whatever issue carried that number locally. The guards are parent_issue in
# lib/board.sh, which resolves the reference against GitHub BEFORE anything is created
# and refuses one that resolves nowhere, and the addSubIssue mutation, which takes two
# node ids and is bound to no repository. What is asserted is the node id the mutation
# was sent, because that is the identity that cannot mean a different issue elsewhere.
#
# NOTHING REACHES github.com. A stand-in `gh` is on PATH for the whole run: it holds the
# issues that exist in a directory of files, answers the parent lookup from it the way gh
# answers - rows with exit 0, or the error body on stdout with a complaint on stderr and
# exit 1 - and records every call. The board lookups are fed from a seeded cache under a
# board number no real project carries.
#
# WHAT THIS DOES NOT REACH, named rather than counted:
#   - whether github.com accepts the addSubIssue mutation it is sent. Only the calls are
#     asserted; anything gh or the server would refuse is their own check.
#   - the title's characters. jq-escaping.test.sh is where a quote, a backslash and
#     non-ASCII in a value are held; the titles here are plain.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAKE="$(mktemp -d)"
export GH_CACHE_DIRECTORY="$FAKE/cache"
REPO="example-org/example-repo"
# A board number no real project carries, so the cache this seeds cannot be mistaken for
# a live board's - and is removed again below. The PowerShell twin uses its own number,
# so the two can run at the same time without reading each other's cache.
PROJECT_NUMBER=999992
failed=0

cleanup() { rm -rf "$FAKE"; }
trap cleanup EXIT

check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}

# The issues that exist: one file per issue, holding "<node id>\t<title>". Number 33
# exists in BOTH repositories with different node ids, which is exactly the ambiguity
# under test - only the node id says which one the mutation was pointed at.
mkdir -p "$FAKE/issues/example-org/other-repo" "$FAKE/issues/example-org/example-repo"
printf 'I_other33\tCollect the rebuild work\n'   > "$FAKE/issues/example-org/other-repo/33"
printf 'I_example33\tAn unrelated local issue\n' > "$FAKE/issues/example-org/example-repo/33"
printf 'I_example44\tThe local epic\n'           > "$FAKE/issues/example-org/example-repo/44"

# The board answers, seeded so no lookup has to be faked: the project id and the two
# single-select fields issue-new sets.
mkdir -p "$GH_CACHE_DIRECTORY/$PROJECT_NUMBER"
printf 'PVT_kwfake%s\n' "$PROJECT_NUMBER" > "$GH_CACHE_DIRECTORY/$PROJECT_NUMBER/project-id"
printf 'Status\tF1\tTodo\tO1\nPriority\tF2\tP2\tO2\n' > "$GH_CACHE_DIRECTORY/$PROJECT_NUMBER/fields.tsv"

# The stand-in. It records what it was asked, answers the reads issue-new makes, and
# refuses anything else - a call outside this list is issue-new resolving something it
# was not asked to resolve.
mkdir -p "$FAKE/bin"
cat > "$FAKE/bin/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$FAKE/calls"
line="\$*"
if [ "\$1" = "issue" ] && [ "\$2" = "create" ]; then
  echo "https://github.com/$REPO/issues/123"; exit 0
fi
if [ "\$1" = "api" ] && [ "\$2" = "graphql" ]; then
  case "\$line" in
    *addSubIssue*)                   echo '{}'; exit 0 ;;
    *updateProjectV2ItemFieldValue*) echo '{}'; exit 0 ;;
    *addProjectV2ItemById*)          echo 'PVTI_item1'; exit 0 ;;
    *projectItems*)                  exit 0 ;;
    *'issue(number:'*)
      o=""; n=""; num=""
      for a in "\$@"; do
        case "\$a" in
          o=*)   o="\${a#o=}" ;;
          n=*)   n="\${a#n=}" ;;
          num=*) num="\${a#num=}" ;;
        esac
      done
      f="$FAKE/issues/\$o/\$n/\$num"
      if [ -f "\$f" ]; then cat "\$f"; exit 0; fi
      echo '{"data":{"repository":{"issue":null}},"errors":[{"message":"Could not resolve to an Issue"}]}'
      echo "gh: Could not resolve to an Issue with the number of \$num. (repository.issue)" >&2
      exit 1 ;;
  esac
fi
if [ "\$1" = "api" ]; then
  case "\$2" in repos/*/issues/*) echo 'I_child123'; exit 0 ;; esac
fi
echo "the stand-in was asked something it does not answer: \$line" >&2
exit 1
EOF
chmod +x "$FAKE/bin/gh"
export PATH="$FAKE/bin:$PATH"
echo body > "$FAKE/b.md"

new_issue() { # new_issue [parent reference]; stdout to $FAKE/out, stderr to $FAKE/err
  : > "$FAKE/calls"
  local args=(--repo "$REPO" --title t --body-file "$FAKE/b.md"
              --label type:bug --label area:tooling --priority P2 --project "$PROJECT_NUMBER"
              --asked-by kartalbas --asked-in 'the test')
  [ $# -gt 0 ] && args+=(--parent "$1")
  bash "$ROOT/bin/issue-new.sh" "${args[@]}" > "$FAKE/out" 2> "$FAKE/err"
}

# Whether the mutation was sent this parent node id, with the new issue as the child.
attached_to() { # attached_to <parent node id>
  if grep -q -- "parent=$1 -f child=I_child123" "$FAKE/calls"; then echo yes
  else echo "no: $(grep -- '-f parent=' "$FAKE/calls" || echo 'no attach was sent')"; fi
}

# Whether a message names the word the caller got wrong. A refusal that does not say
# which word to fix costs the same round trip as no refusal at all.
names() { # names <message> <word>
  case "$1" in *"$2"*) echo yes ;; *) echo "no: $1" ;; esac
}

# --- 1. a parent in another repository ---------------------------------------------------------

echo 'a parent in another repository is the issue that is attached to'

new_issue 'example-org/other-repo#33'
check 'the run succeeds'                       0 "$?"
check 'stdout stays the number, capturable'    '123' "$(cat "$FAKE/out")"
check "the attach names THAT repository's issue 33" yes "$(attached_to I_other33)"
check 'and the report says which issue, by repository, number and title' \
      '#123 -> sub-issue of example-org/other-repo#33  Collect the rebuild work' \
      "$(grep 'sub-issue of' "$FAKE/err")"

new_issue 'other-repo#33'
check 'REPO#N reads the owner from the repo the issue is created in' yes "$(attached_to I_other33)"

# --- 2. a bare number keeps today's meaning ----------------------------------------------------

echo
echo 'a bare number stays an issue of the same repository'

new_issue 44
check 'the run succeeds'                    0 "$?"
check 'the attach names the local issue 44' yes "$(attached_to I_example44)"
check 'and the report says so' \
      '#123 -> sub-issue of example-org/example-repo#44  The local epic' \
      "$(grep 'sub-issue of' "$FAKE/err")"

# --- 3. a parent that does not exist -----------------------------------------------------------

echo
echo 'a parent that does not exist refuses before anything is created'

new_issue 'example-org/other-repo#77'
check 'the run stops'                1 "$?"
check 'naming what was asked for'    yes "$(names "$(cat "$FAKE/err")" 'the parent issue example-org/other-repo#77')"
check 'and no issue was created'     0 "$(grep -c '^issue create' "$FAKE/calls")"

new_issue bogus
check 'a reference that is no reference is refused' yes \
      "$(names "$(cat "$FAKE/err")" "'bogus' is not an issue reference")"
check 'before gh was asked anything' 0 "$(grep -c . "$FAKE/calls")"

# WHAT SEPARATES THE TWO TWINS. .NET's $ matches at the end of the string OR immediately before a
# final newline, so `-notmatch '^[0-9]+$'` accepted "12\n" while the `case` glob below refused it,
# and one reference resolved a parent on one side and was refused on the other. Both twins assert
# the same two answers here, which is what makes the pair provable rather than merely both green.
new_issue $'12\n'
check 'a number with a trailing newline is refused' yes \
      "$(names "$(cat "$FAKE/err")" 'is not an issue reference')"
check 'before gh was asked anything' 0 "$(grep -c . "$FAKE/calls")"

new_issue ' 12'
check 'a number with a leading space is refused' yes \
      "$(names "$(cat "$FAKE/err")" "' 12' is not an issue reference")"
check 'before gh was asked anything' 0 "$(grep -c . "$FAKE/calls")"

# --- 4. the innocent case ----------------------------------------------------------------------

echo
echo 'and with no parent named, nothing is resolved and nothing attached'

new_issue
check 'the run succeeds'          0 "$?"
check 'stdout stays the number'   '123' "$(cat "$FAKE/out")"
check 'no attach was sent'        0 "$(grep -c 'addSubIssue' "$FAKE/calls")"
check 'and nothing was reported'  0 "$(grep -c 'sub-issue of' "$FAKE/err")"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo; echo 'all passed'
