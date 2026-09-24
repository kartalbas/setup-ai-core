#!/usr/bin/env bash
# Which ORGANISATION a board is resolved under, and where its cache lands.
#
#   bash test/board-org.test.sh
#
# Two organisations keep boards here, and a board number alone names neither. A bare number is
# a board of the organisation the named repository belongs to, ORG/N names one outright, and a
# command that names no repository falls back to GH_ORG - the one rule set_project holds, and
# the one that used to be "every number is a board of GH_ORG", which put a customer's cards on
# the platform's board (example-tools#25).
#
# Run with a FAKE gh on PATH that records every call, so which organisation the id query was
# sent for is read back off the record and no board is touched.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAKE="$(mktemp -d)"
export GH_CACHE_DIRECTORY="$FAKE/cache"
trap 'rm -rf "$FAKE"' EXIT
LOG="$FAKE/calls.txt"

cat > "$FAKE/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" | tr '\n' ' ' >> "$LOG"; printf '\n' >> "$LOG"
line="\$*"
case "\$line" in
  *"projectV2(number"*) echo 'PVT_kworgtest'; exit 0 ;;
  *"issues/3"*)         echo 'I_node3'; exit 0 ;;
  *projectItems*)       exit 0 ;;
esac
if [ "\$1" = "repo" ]; then echo 'other-org/example-repo'; exit 0; fi
echo '{}'
exit 0
EOF
chmod +x "$FAKE/gh"
export PATH="$FAKE:$PATH"

failed=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}
id_query() { grep 'projectV2(number' "$LOG" | head -1; }
# The cache directory the library chooses for a board, read off the library itself in a subshell.
cache_dir_of() { ( . "$ROOT/lib/board.sh"; set_project "$1" "$2" >/dev/null; cache_dir ); }
org_asked() { id_query | grep -o 'org=[A-Za-z0-9_-]*' | head -1; }
num_asked() { id_query | grep -o 'num=[0-9]*' | head -1; }

echo
echo 'a bare number with a repository of another organisation is that organisation'"'"'s board'
: > "$LOG"; rm -rf "$GH_CACHE_DIRECTORY"
bash "$ROOT/bin/issue-status.sh" --project 999979 other-org/example-repo 3 testing >/dev/null 2>&1 || true
check 'the id is asked of other-org' 'org=other-org' "$(org_asked)"
check 'for the number given'             'num=999979'         "$(num_asked)"
check 'and cached under the organisation and the number' "$GH_CACHE_DIRECTORY/other-org/999979" "$(cache_dir_of 999979 other-org/example-repo)"

echo
echo 'ORG/N names the organisation outright, whatever repository the command names'
: > "$LOG"; rm -rf "$GH_CACHE_DIRECTORY"
bash "$ROOT/bin/issue-status.sh" --project example-org/999978 other-org/example-repo 3 testing >/dev/null 2>&1 || true
check 'the id is asked of example-org' 'org=example-org' "$(org_asked)"
check 'for the number after the slash' 'num=999978'    "$(num_asked)"
check 'and a board of GH_ORG caches under its number alone, as it always has' "$GH_CACHE_DIRECTORY/999978" "$(cache_dir_of example-org/999978 other-org/example-repo)"

echo
echo 'a command that names no repository falls back to GH_ORG'
: > "$LOG"; rm -rf "$GH_CACHE_DIRECTORY"
bash "$ROOT/bin/board-list.sh" --project 999977 >/dev/null 2>&1 || true
check 'the id is asked of GH_ORG' 'org=example-org' "$(org_asked)"
check 'for the number given'      'num=999977'    "$(num_asked)"

echo
echo 'a board written with a slash and nothing on one side of it is refused by name'
: > "$LOG"; rm -rf "$GH_CACHE_DIRECTORY"
out="$(bash "$ROOT/bin/issue-status.sh" --project /7 other-org/example-repo 3 testing 2>&1)"; rc=$?
check 'exits non-zero' yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'and says how a board is written' yes "$(grep -q "a board is written N or ORG/N, not '/7'" <<< "$out" && echo yes || echo no)"
check 'and asked gh for no id' '' "$(id_query)"

echo
echo 'a card on another organisation'"'"'s board is acted on under THAT organisation (example-tools#26)'
mkdir -p "$FAKE/carded"
cat > "$FAKE/carded/gh" <<EOF2
#!/usr/bin/env bash
printf '%s
' "\$*" | tr '
' ' ' >> "$LOG"; printf '
' >> "$LOG"
line="\$*"
case "\$line" in
  *projectItems*)       printf 'other-org/1	PVTI_card3
'; exit 0 ;;
  *"projectV2(number"*) echo 'PVT_kworgtest'; exit 0 ;;
  *"fields(first"*)     printf 'Status	F1	done	O_done
'; exit 0 ;;
esac
if [ "\$1" = "repo" ]; then echo 'other-org/example-repo'; exit 0; fi
echo '{}'
exit 0
EOF2
chmod +x "$FAKE/carded/gh"
: > "$LOG"; rm -rf "$GH_CACHE_DIRECTORY"
out="$(PATH="$FAKE/carded:$PATH" bash "$ROOT/bin/issue-close.sh" other-org/example-repo 3 2>&1)"; rc=$?
check 'exits zero' 0 "$rc"
check 'the id is asked of other-org' 'org=other-org' "$(org_asked)"
check 'for board 1' 'num=1' "$(num_asked)"
check 'and the board is named with its owner' yes "$(printf '%s
' "$out" | grep -q '#3 -> done (board other-org/1)' && echo yes || echo no)"

echo
if [ "$failed" -eq 0 ]; then echo 'board-org: every check green'; exit 0
else echo "board-org: $failed check(s) red"; exit 1; fi
