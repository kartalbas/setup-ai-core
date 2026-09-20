#!/usr/bin/env bash
# What repo-boards calls a link, and what it does with a repository that has none.
#
#   bash test/repo-boards.test.sh
#
# NOTHING REACHES github.com. A stand-in `gh` is on PATH for the whole run and answers a
# prepared organisation, so every case below is a shape somebody would otherwise have to
# create real repositories to produce - a closed board, a template board, two boards on
# one repository, a second page.
#
# THE CLASS THIS HOLDS CLOSED. An issue filed in a repository that is linked to no board
# is on no board, and it stays invisible until somebody remembers it exists. Nothing else
# in bin/ can report that: every other path starts from a repository and asks which board
# it resolves to, so a repository that resolves to none stops that one call and is never
# counted, and board-sync sweeps "every repo linked to the project", which by construction
# cannot reach a repository linked to no project.
#
# WHAT COUNTS AS A LINK is the same rule resolve_project_for_repo applies to one
# repository, and each half of it is planted here: a CLOSED project is not a link, because
# a repository keeps its old boards after they are closed; the TEMPLATE board is not a
# link, because it is a shape to copy and no work is tracked on it. Read either as a link
# and the report says a repository is covered when nothing sweeps it.
#
# THE PLANTED INNOCENT CASE is an organisation where every repository resolves to exactly
# one open board: it must pass, or every red above could equally be a script that refuses
# whatever it is handed.
#
# THE SECOND PAGE is planted too. The organisation is read a page at a time, and a script
# that took the first page only would report an organisation that is entirely linked while
# the repository nobody linked sits on page two.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAKE="$(mktemp -d)"
failed=0

cleanup() { rm -rf "$FAKE"; }
trap cleanup EXIT

check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}

# The stand-in answers one prepared page per call, so a run that reads a second page gets
# the second file and a run that stops after the first never sees it.
mkdir -p "$FAKE/bin"
cat > "$FAKE/bin/gh" <<EOF
#!/usr/bin/env bash
n=\$(cat "$FAKE/n" 2>/dev/null || echo 0)
n=\$((n + 1))
echo "\$n" > "$FAKE/n"
cat "$FAKE/page-\$n.json"
EOF
chmod +x "$FAKE/bin/gh"
export PATH="$FAKE/bin:$PATH"

# One repository node. The board list is written out by the caller as JSON.
node() { # node <name> <archived> <boards json>
  printf '{"nameWithOwner":"example-org/%s","isArchived":%s,"projectsV2":{"nodes":[%s]}}' "$1" "$2" "$3"
}
board() { # board <number> <title> <closed>
  printf '{"number":%s,"title":"%s","closed":%s}' "$1" "$2" "$3"
}
page() { # page <hasNextPage> <nodes...>
  local more="$1"; shift
  local IFS=,
  printf '{"data":{"organization":{"repositories":{"pageInfo":{"hasNextPage":%s,"endCursor":"CUR"},"nodes":[%s]}}}}' \
    "$more" "$*"
}

# Runs the sweep against the prepared pages and prints "exit=N" after the report, so both
# halves of the answer are asserted from one string.
sweep() {
  rm -f "$FAKE/n"
  bash "$ROOT/bin/repo-boards.sh" 2>&1; echo "exit=$?"
}

# The verdict line, which is what a caller acts on.
verdict() { sweep | grep -E 'linked to no open board|^exit=' | paste -sd' ' -; }

one_linked="$(node one false "$(board 6 beta false)")"

echo 'a repository linked to no open board'

printf '%s' "$(page false "$one_linked" "$(node lost false '')")" > "$FAKE/page-1.json"
check 'is named'                  yes \
      "$(case "$(sweep)" in *"example-org/lost"*"LINKED TO NO OPEN BOARD"*) echo yes ;; *) echo no ;; esac)"
check 'is counted, and the run is red' '1 linked to no open board, 0 linked to more than one exit=1' \
      "$(verdict)"

echo
echo 'what does not count as a link'

printf '%s' "$(page false "$one_linked" "$(node closed_only false "$(board 5 'the old board' true)")")" > "$FAKE/page-1.json"
check 'a CLOSED project is not a link'   '1 linked to no open board, 0 linked to more than one exit=1' \
      "$(verdict)"

printf '%s' "$(page false "$one_linked" "$(node template_only false "$(board 9 '[TEMPLATE] shape to copy' false)")")" > "$FAKE/page-1.json"
check 'the TEMPLATE board is not a link' '1 linked to no open board, 0 linked to more than one exit=1' \
      "$(verdict)"

echo
echo 'a repository linked to more than one open board'

printf '%s' "$(page false "$one_linked" "$(node both false "$(board 6 beta false),$(board 7 alpha false)")")" > "$FAKE/page-1.json"
check 'is named with both boards'  yes \
      "$(case "$(sweep)" in *"example-org/both"*"LINKED TO 2 BOARDS: 6 beta, 7 alpha"*) echo yes ;; *) echo no ;; esac)"
check 'and the run is red'         'exit=1' \
      "$(sweep | tail -1)"

echo
echo 'an archived repository'

printf '%s' "$(page false "$one_linked" "$(node dead true '')")" > "$FAKE/page-1.json"
check 'is listed and left out of the count' \
      '1 repositories read, 1 archived and left out of the count' \
      "$(sweep | grep 'repositories read')"
check 'and does not make the run red'  'exit=0' "$(sweep | tail -1)"

echo
echo 'the second page'

printf '%s' "$(page true "$one_linked")"                > "$FAKE/page-1.json"
printf '%s' "$(page false "$(node lost false '')")"     > "$FAKE/page-2.json"
check 'is read, and what is on it is counted' '1 linked to no open board, 0 linked to more than one exit=1' \
      "$(verdict)"

# THE INNOCENT CASE. Every repository on exactly one open board, and one of them ALSO
# carrying a closed board and a template board - which must not turn into a second link
# and make it ambiguous.
echo
echo 'an organisation where every repository resolves to exactly one board'

printf '%s' "$(page false "$one_linked" \
  "$(node two false "$(board 7 alpha false),$(board 5 'the old board' true),$(board 9 '[TEMPLATE] shape to copy' false)")")" \
  > "$FAKE/page-1.json"
check 'passes'  '0 linked to no open board, 0 linked to more than one' \
      "$(sweep | grep 'linked to no open board')"
check 'and the run is green'  'exit=0' "$(sweep | tail -1)"
check 'and the one with three boards resolves to its open one' yes \
      "$(case "$(sweep)" in *"example-org/two"*"7 alpha"*) echo yes ;; *) echo no ;; esac)"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo; echo 'all passed'
