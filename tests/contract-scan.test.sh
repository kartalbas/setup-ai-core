#!/usr/bin/env bash
# What contract-scan.sh finds, and when it goes red.
#
# A project folder of three clones and one folder that is no clone. What is pinned: a term read in
# one repository and shipped by another is red for a package that holds only one of them (the
# planted defect) and green for the package that holds both (the planted innocent); the tree
# searched is origin/HEAD where it exists, else HEAD, so a commit not pushed and an edit not
# committed are never hits; and a repository with many hits prints ten and counts the rest.
#
#   bash tests/contract-scan.test.sh

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
scan="$root/bin/contract-scan.sh"

failed=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}
gitc() { git -C "$1" -c user.name=check -c user.email=check@localhost "${@:2}"; }

# clone_with_origin <name> <file> <content>: a clone whose origin's default branch carries the file
clone_with_origin() {
  git init -q --bare "$t/origin/$1.git"
  git clone -q "$t/origin/$1.git" "$t/proj/$1" 2>/dev/null
  printf '%s\n' "$3" > "$t/proj/$1/$2"
  gitc "$t/proj/$1" add -A && gitc "$t/proj/$1" commit -q -m init && gitc "$t/proj/$1" push -q origin HEAD 2>/dev/null
  gitc "$t/proj/$1" remote set-head origin -a > /dev/null
}
mkdir -p "$t/proj"
clone_with_origin shop-api config.env 'CATALOG_DIRS=webs'
clone_with_origin shop-web build.mjs 'read(process.env.CATALOG_DIRS)'
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do echo "MANY $i"; done > "$t/proj/shop-web/many.txt"
gitc "$t/proj/shop-web" add -A && gitc "$t/proj/shop-web" commit -q -m many && gitc "$t/proj/shop-web" push -q origin HEAD 2>/dev/null
git init -q "$t/proj/shop-docs"   # no origin: its HEAD is what is searched
echo 'DOCS_ONLY' > "$t/proj/shop-docs/README.md"
gitc "$t/proj/shop-docs" add -A && gitc "$t/proj/shop-docs" commit -q -m docs
mkdir -p "$t/proj/notes"; echo 'CATALOG_DIRS' > "$t/proj/notes/todo.txt"   # no clone: never searched
git init -q "$t/proj/x&y z"; echo 'ODD_NAME' > "$t/proj/x&y z/f.txt"; gitc "$t/proj/x&y z" add -A && gitc "$t/proj/x&y z" commit -q -m odd
echo 'LOCAL_ONLY' > "$t/proj/shop-api/local.txt"
gitc "$t/proj/shop-api" add -A && gitc "$t/proj/shop-api" commit -q -m 'not pushed'
echo 'CATALOG_DIRS' > "$t/proj/shop-docs/draft.txt"   # not committed

echo 'the planted defect: the contract has a side outside the package'
out="$(cd "$t/proj/shop-web" && bash "$scan" --package shop-web CATALOG_DIRS 2>&1)"; rc=$?
check 'it exits 3'         3 "$rc"
check 'the count line'     'CATALOG_DIRS: 2 hit(s) in 2 of 4 repositories' "$(sed -n 1p <<< "$out")"
check 'the producer'       '  shop-api config.env:1:CATALOG_DIRS=webs' "$(sed -n 2p <<< "$out")"
check 'the reader'         '  shop-web build.mjs:1:read(process.env.CATALOG_DIRS)' "$(sed -n 3p <<< "$out")"
check 'the side outside'   '  outside the package: shop-api (1)' "$(sed -n 4p <<< "$out")"

echo 'the planted innocent: both sides in the package, and the same from a subfolder'
mkdir -p "$t/proj/shop-api/sub"
out="$(cd "$t/proj/shop-api/sub" && bash "$scan" --package shop-web,shop-api CATALOG_DIRS 2>&1)"; rc=$?
check 'it exits 0'         0 "$rc"
check 'no side outside'    no "$(grep -q 'outside the package' <<< "$out" && echo yes || echo no)"

echo 'what ships, not what is local'
out="$(cd "$t/proj/shop-api" && bash "$scan" LOCAL_ONLY DOCS_ONLY 2>&1)"; rc=$?
check 'a commit not pushed' 'LOCAL_ONLY: 0 hit(s) in 0 of 4 repositories' "$(sed -n 1p <<< "$out")"
check 'HEAD without origin' 'DOCS_ONLY: 1 hit(s) in 1 of 4 repositories' "$(sed -n 2p <<< "$out")"
check 'its hit'             '  shop-docs README.md:1:DOCS_ONLY' "$(sed -n 3p <<< "$out")"
check 'without --package'   0 "$rc"

echo 'ten hits per repository, and the count of the rest'
out="$(cd "$t/proj/shop-web" && bash "$scan" MANY 2>&1)"
check 'the count line'     'MANY: 12 hit(s) in 1 of 4 repositories' "$(sed -n 1p <<< "$out")"
check 'ten lines'          10 "$(grep -c '^  shop-web many.txt:' <<< "$out")"
check 'the rest'           '  shop-web ... and 2 more' "$(sed -n 12p <<< "$out")"

echo 'a clone whose name holds a space and an ampersand is one repository, printed as it is'
out="$(cd "$t/proj/shop-web" && bash "$scan" --package 'x&y z' ODD_NAME 2>&1)"; rc=$?
check 'it exits 0'         0 "$rc"
check 'the count line'     'ODD_NAME: 1 hit(s) in 1 of 4 repositories' "$(sed -n 1p <<< "$out")"
check 'its hit'            '  x&y z f.txt:1:ODD_NAME' "$(sed -n 2p <<< "$out")"

echo 'usage errors'
out="$(cd "$t/proj/shop-web" && bash "$scan" --package '' CATALOG_DIRS 2>&1)"; rc=$?
check 'an empty package'   '1 error: --package needs a value' "$rc $out"
out="$(cd "$t/proj/shop-web" && bash "$scan" --package shop-cms CATALOG_DIRS 2>&1)"; rc=$?
# Git Bash names the folder in its own spelling (C:/...), so only the name and the folder's end are compared
check 'a package repo that is no clone' "1 error: --package names shop-cms, which is no clone of .../proj" "$rc ${out%% of *} of .../${out##*/}"
out="$(cd "$t/proj/shop-web" && bash "$scan" 2>&1)"; rc=$?
check 'no term'            1 "$rc"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
