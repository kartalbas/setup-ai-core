#!/usr/bin/env bash
# Where a contract stands across the repositories of the project: the file:line of each term in
# every repository, and with --package the repositories outside the package that hold one.
#
#   contract-scan.sh TERM...                        each term's hits, repository by repository
#   contract-scan.sh --package REPO,REPO... TERM...  and exit 3 where a repository outside the
#                                                    package holds a hit
#
# A CONTRACT IS WHAT ONE REPOSITORY READS AND ANOTHER SHIPS: a file name, a manifest field, a
# configuration key, an environment variable, a route. A package cut by file or module splits it
# where reader and producer sit in two repositories, and the two then release apart. The planner
# names the terms the package's issues touch; this prints where each one stands, so both sides
# join the package, and the plan check runs it with the package's repositories.
#
# THE TREE SEARCHED IS WHAT SHIPS: the default branch of origin as the clone last fetched it
# (origin/HEAD), else the clone's HEAD; never a working tree with somebody's edits. The search is
# literal, `git grep -F`. The repositories are the git clones directly in the project folder (the
# folder holding the clone this runs in, or the current directory); REPO is a clone's folder name.
# Up to 10 hits per repository and term are printed, with the count of all of them.
#
# Exit 0: no --package, or every hit lies inside it. Exit 3: a term has a hit outside the package.
# Exit 1: a usage error, or a REPO of --package that is no clone of the project folder.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/board.sh"

usage='usage: contract-scan.sh [--package REPO,REPO...] TERM...'
package=""; with_package=0; terms=()
while [ $# -gt 0 ]; do
  case "$1" in
    --package) need_value "$1" "${2-}"; package="$2"; with_package=1; shift 2 ;;
    --) shift; while [ $# -gt 0 ]; do terms+=("$1"); shift; done ;;
    -*) die "unknown argument '$1'" ;;
    *) terms+=("$1"); shift ;;
  esac
done
[ "${#terms[@]}" -gt 0 ] || die "$usage"

folder="$(project_folder)"
repos="$(for d in "$folder"/*/; do d="${d%/}"; if [ -e "$d/.git" ]; then printf '%s\n' "${d##*/}"; fi; done | LC_ALL=C sort | tr '\n' ' ')"
[ -n "${repos// /}" ] || die "no git clone in $folder"

inside() {  # inside <repo> - is the repository one of the package's
  case ",$package," in *",$1,"*) return 0 ;; esac
  return 1
}
if [ "$with_package" -eq 1 ]; then
  old_ifs="$IFS"; IFS=','
  for p in $package; do
    case " $repos " in *" $p "*) ;; *) IFS="$old_ifs"; die "--package names $p, which is no clone of $folder" ;; esac
  done
  IFS="$old_ifs"
fi

outside=0
for term in "${terms[@]}"; do
  total=0; holders=0; lines=""; foreign=""
  for r in $repos; do
    ref=HEAD
    git -C "$folder/$r" rev-parse --verify -q refs/remotes/origin/HEAD >/dev/null && ref=origin/HEAD
    hits="$(git -C "$folder/$r" grep -n -I -F -e "$term" "$ref" -- 2>/dev/null | tr -d '\r' || true)"
    [ -n "$hits" ] || continue
    n="$(printf '%s\n' "$hits" | grep -c .)"
    total=$((total + n)); holders=$((holders + 1))
    # cut counts bytes, so a line with non-ASCII text ends a few characters before the twin's
    lines="$lines$(printf '%s\n' "$hits" | sed -n '1,10p' | sed -e "s|^$ref:||" -e "s|^|  $r |" | cut -c1-200)"$'\n'
    [ "$n" -gt 10 ] && lines="$lines  $r ... and $((n - 10)) more"$'\n'
    if [ "$with_package" -eq 1 ] && ! inside "$r"; then foreign="$foreign $r ($n)"; fi
  done
  echo "$term: $total hit(s) in $holders of $(printf '%s\n' $repos | grep -c .) repositories"
  printf '%s' "$lines"
  if [ -n "$foreign" ]; then
    echo "  outside the package:$foreign"
    outside=1
  fi
done
[ "$outside" -eq 0 ] || exit 3
