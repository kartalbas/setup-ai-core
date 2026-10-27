#!/usr/bin/env bash
# THE RECEIPT OF A CHECKED LANDING, so that a public repository's landing runs scripts/check.sh once per commit.
# Source it for the gate, or run it as
#
#   landing-check.sh open                          prints the path of a new, private receipt
#   landing-check.sh complete <receipt> <commit> <ci ref>
#   landing-check.sh close <receipt>
#   landing-check.sh mark <root> <commit> <remote ref>...   prints the path of a new mark of a harness landing
#   landing-check.sh unmark <mark>
#   landing-check.sh rounds                        prints INTEGRATE_MAX_ROUNDS of the config.env of the checkout it runs in
#
# A landing of a public repository pushes its merge commit twice through the push gate: to ci/integrate-<branch>,
# whose CI it waits for, and then to the default branch. The landing opens one receipt in a folder of its own and
# hands the path to the Git children of those two pushes alone, in AI_CORE_LANDING_RECEIPT; it is no setting of the
# shell, so two landings at the same moment never meet. The gate of the first push writes into it what its green
# check proved: the clone, the origin, the commit, its tree, and the commit each neighbour copy stood at. The landing
# adds the ci/ ref once that push went through and the CI of the same commit was read green. Only then does the gate
# of the final push skip scripts/check.sh, and only for the exact push the receipt names. The landing deletes the
# receipt on every way out it can trap. A receipt is published whole by a rename.

# THE MARK OF A HARNESS LANDING is a second record of this unit, and it means something else. The receipt says "this
# commit was checked, skip scripts/check.sh"; the mark says "a harness landing path makes this push". The push gate
# refuses every update of the default branch that carries no mark for exactly the commit it lands, unless every commit it
# adds touches only files of DIRECT_PUSH_FILES (below), so reviewed work reaches the default branch through
# `ai-core integrate-issue` and the few other paths of the harness that write one
# (a release, init's commit of the .gitignore block, the shims of `pre-push --install`, `ai-core push` of a project
# harness), never through a plain push of other files. The
# mark is bound to the clone (its git common directory), the exact commit and the refs it may update. A landing writes
# it right before its push, hands the path to that push's Git children alone in AI_CORE_LANDING_MARK, and removes it on
# every way out; it is no setting of the shell, so two landings at the same moment never meet. The mark is no secret
# and no proof of a review: it keeps a plain `git push` from reaching the default branch by accident or by habit.

# shellcheck disable=SC2034 # the REASON variables are read by the gate that sources this file
LANDING_CHECK_VERSION=1
LANDING_CHECK_REASON=""
LANDING_MARK_VERSION=1
LANDING_MARK_REASON=""

# THE ROUNDS OF A LANDING: integrate-issue lands again by itself when the default branch moved during its gate, at most
# INTEGRATE_MAX_ROUNDS times, the first attempt counted. The setting is read from the config.env of the checkout the
# command runs in, as the file stands at each call and never from the environment, so a change reaches the next round of
# a landing that runs. Both implementations of integrate-issue, the Bash one and the Forgejo one, read it through here.
# landing_rounds_limit: prints the number, 3 where the file sets none; where the value is no whole number from 1 to
# 999999999 it says so, naming the key, and fails.
landing_rounds_limit() {
  local value
  value="$(config_file_value INTEGRATE_MAX_ROUNDS 3)" || return 1
  case "$value" in
    0*|*[!0-9]*|??????????*)
      echo "INTEGRATE_MAX_ROUNDS is '$value' in $(config_file_of INTEGRATE_MAX_ROUNDS); it is the most rounds a landing makes, the first one counted, a whole number from 1 to 999999999" >&2
      return 1 ;;
  esac
  printf '%s\n' "$value"
}

# landing_check_open: prints the path of a receipt that does not exist yet, in a folder only this landing knows
landing_check_open() {
  local dir
  dir="$(mktemp -d)" || return 1
  printf '%s/receipt\n' "$dir"
}

# landing_check_close <receipt>: removes the receipt, whatever state it is in, and its folder
landing_check_close() {
  case "$1" in */receipt) ;; *) echo "error: $1 is no receipt of a landing" >&2; return 1 ;; esac
  rm -f "$1" "$1".*; rmdir "$(dirname "$1")" 2>/dev/null || true
}

# landing_check_publish <receipt>: the receipt is what stands on the input, put in place whole
landing_check_publish() {
  local temporary="$1.$$.new"
  cat > "$temporary" && mv -f "$temporary" "$1"
}

# landing_check_record <receipt> <root> <commit> <remote ref> [neighbour lines]: the gate of a push of <commit>
# to <remote ref> has run scripts/check.sh in <root> and it was green. Each neighbour line is "name commit".
landing_check_record() {
  local receipt="$1" root="$2" commit="$3" ref="$4" name tip
  {
    printf 'landing-check\t%s\n' "$LANDING_CHECK_VERSION"
    printf 'clone\t%s\n' "$(git -C "$root" rev-parse --path-format=absolute --git-common-dir)"
    printf 'origin\t%s\n' "$(git -C "$root" remote get-url origin)"
    printf 'commit\t%s\n' "$commit"
    printf 'tree\t%s\n' "$(git -C "$root" rev-parse "$commit^{tree}")"
    printf 'ref\t%s\n' "$ref"
    while read -r name tip; do [ -z "$name" ] || printf 'neighbour\t%s\t%s\n' "$name" "$tip"; done <<< "${5:-}"
    printf 'check\tgreen\n'
  } | landing_check_publish "$receipt"
}

# landing_check_complete <receipt> <commit> <ci ref>: the push to <ci ref> went through and the CI of <commit> there
# was read green. Where the gate wrote no receipt, as in a repository without scripts/check.sh, there is nothing to
# complete. Fails, and changes nothing, where the receipt holds no green check of that very commit.
landing_check_complete() {
  local receipt="$1" commit="$2" ci_ref="$3"
  [ -f "$receipt" ] || return 0
  if [ "$(awk -F'\t' '$1 == "commit" { print $2 }' "$receipt")" != "$commit" ] \
     || ! grep -qxF "$(printf 'check\tgreen')" "$receipt"; then
    echo "error: the receipt $receipt holds no green check of $commit" >&2; return 1
  fi
  { cat "$receipt"; printf 'ci\t%s\t%s\tgreen\n' "$ci_ref" "$commit"; } | landing_check_publish "$receipt"
}

# landing_check_judge <receipt> <root> <commit> <pushed refs> <remote ref> <default branch> [neighbour lines]:
# succeeds where the receipt shows scripts/check.sh green for this very push; otherwise fails, and
# LANDING_CHECK_REASON says which part of the receipt does not hold
landing_check_judge() {
  local receipt="$1" root="$2" commit="$3" refs="$4" remote_ref="$5" default="$6" want have
  LANDING_CHECK_REASON=""
  field() { awk -F'\t' -v k="$1" '$1 == k { print $2 }' "$receipt"; }
  if [ ! -f "$receipt" ]; then LANDING_CHECK_REASON="no receipt of this landing stands at $receipt"; return 1; fi
  if [ "$(head -n 1 "$receipt")" != "$(printf 'landing-check\t%s' "$LANDING_CHECK_VERSION")" ]; then LANDING_CHECK_REASON="the receipt is not one this gate reads"; return 1; fi
  if [ "$refs" != 1 ] || [ "$remote_ref" != "refs/heads/$default" ]; then LANDING_CHECK_REASON="this push is not the one push of the checked commit to $default"; return 1; fi
  if [ "$(field commit)" != "$commit" ]; then LANDING_CHECK_REASON="the receipt holds a check of $(field commit), not of this commit"; return 1; fi
  if [ "$(field tree)" != "$(git -C "$root" rev-parse "$commit^{tree}" 2>/dev/null)" ]; then LANDING_CHECK_REASON="the tree of the commit is not the tree the check proved"; return 1; fi
  if [ "$(field clone)" != "$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ]; then LANDING_CHECK_REASON="the receipt belongs to another clone"; return 1; fi
  if [ "$(field origin)" != "$(git -C "$root" remote get-url origin 2>/dev/null)" ]; then LANDING_CHECK_REASON="the receipt belongs to another origin"; return 1; fi
  if ! grep -qxF "$(printf 'check\tgreen')" "$receipt"; then LANDING_CHECK_REASON="the receipt holds no green check"; return 1; fi
  case "$(field ref)" in refs/heads/ci/integrate-?*) ;; *) LANDING_CHECK_REASON="the check of the receipt was not the gate of a push to ci/integrate-<branch>"; return 1 ;; esac
  if ! grep -qxF "$(printf 'ci\t%s\t%s\tgreen' "$(field ref)" "$commit")" "$receipt"; then
    LANDING_CHECK_REASON="the receipt holds no green CI result of this commit on $(field ref)"; return 1
  fi
  want="$(awk -F'\t' '$1 == "neighbour" { print $2 " " $3 }' "$receipt" | LC_ALL=C sort)"
  have="$(printf '%s\n' "${7:-}" | sed '/^$/d' | LC_ALL=C sort)"
  if [ "$want" != "$have" ]; then LANDING_CHECK_REASON="the neighbour copies stand at other commits than the check read"; return 1; fi
}

# landing_mark_open <root> <commit> <remote ref>...: prints the path of a new mark, in a folder of its own, for a push of
# <commit> from the clone of <root> to those refs
landing_mark_open() {
  local root="$1" commit="$2" dir ref
  shift 2
  dir="$(mktemp -d)" || return 1
  {
    printf 'landing-mark\t%s\n' "$LANDING_MARK_VERSION"
    printf 'clone\t%s\n' "$(git -C "$root" rev-parse --path-format=absolute --git-common-dir)"
    printf 'commit\t%s\n' "$commit"
    for ref in "$@"; do printf 'ref\t%s\n' "$ref"; done
  } > "$dir/mark" || { rm -rf "$dir"; return 1; }
  printf '%s/mark\n' "$dir"
}

# landing_mark_close <mark>: removes the mark and its folder
landing_mark_close() {
  case "$1" in */mark) ;; *) echo "error: $1 is no mark of a landing" >&2; return 1 ;; esac
  rm -f "$1"; rmdir "$(dirname "$1")" 2>/dev/null || true
}

# with_landing_mark <root> <commit> <remote ref>... -- <command>...: runs the command with a mark for those refs in
# AI_CORE_LANDING_MARK and removes the mark afterwards, whatever the command did; its status is the command's
with_landing_mark() {
  local root="$1" commit="$2" refs=() mark status=0
  shift 2
  while [ "$1" != -- ]; do refs+=("$1"); shift; done
  shift
  mark="$(landing_mark_open "$root" "$commit" ${refs[@]+"${refs[@]}"})" || { echo "error: no folder for the mark of this landing" >&2; return 1; }
  AI_CORE_LANDING_MARK="$mark" "$@" || status=$?
  landing_mark_close "$mark"
  return "$status"
}

# harness_commits_only <checkout> <branch>: succeeds where every commit that HEAD holds and origin/<branch> lacks is one a
# path of the harness writes on its own: init's commit of the .gitignore block, or the commit of the shims of
# pre-push --install, each touching only its files and carrying its No-issue trailer. A commit of somebody else beneath
# them would otherwise reach the default branch under the harness's mark, past the review a landing stands for. A git
# call that fails stops it with status 1: a commit that could not be read is never taken for one of the harness.
harness_commits_only() {
  local dir="$1" branch="$2" unpushed_range=(HEAD) shas sha files file trailer
  if git -C "$dir" rev-parse -q --verify "refs/remotes/origin/$branch" >/dev/null; then unpushed_range=(HEAD "^refs/remotes/origin/$branch"); fi
  shas="$(git -C "$dir" rev-list "${unpushed_range[@]}")" || return 1
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    files="$(git -C "$dir" diff-tree --no-commit-id --root -r --name-only "$sha")" || return 1
    # no file stays no file, as git lists none for a merge: one blank name would pass the check of the shims below
    [ -z "$files" ] || files="$(printf '%s\n' "$files" | sort -u | tr '\n' ' ')"
    trailer="$(git -C "$dir" log -1 --format='%(trailers:key=No-issue,valueonly)' "$sha")" || return 1
    case "$trailer" in
      *'the .gitignore block written by ai-core init'*) [ "$files" = '.gitignore ' ] || return 1 ;;
      *'written, committed and pushed by ai-core pre-push --install'*)
        [ -n "$files" ] || return 1
        for file in $files; do
          case "$file" in .gitattributes|.githooks/pre-push|.githooks/post-checkout) ;; *) return 1 ;; esac
        done ;;
      *) return 1 ;;
    esac
  done <<< "$shas"
  return 0
}

# with_harness_commits_mark <checkout> <branch> -- <command>...: runs the command, a push of HEAD to <branch>, with the mark
# of a harness landing where harness_commits_only holds, and without one otherwise, so the gate judges a push that carries
# somebody's commit as the plain push it is
with_harness_commits_mark() {
  local dir="$1" branch="$2"
  shift 3
  if harness_commits_only "$dir" "$branch"; then
    with_landing_mark "$dir" "$(git -C "$dir" rev-parse HEAD)" "refs/heads/$branch" -- "$@"
  else
    echo "HEAD holds commits that origin/$branch lacks and the harness did not write, so this push carries no mark of a harness landing" >&2
    "$@"
  fi
}

# A DIRECT PUSH is the other way onto the default branch, beside the mark: a repository names in DIRECT_PUSH_FILES of its
# own .ai-core/config.env the files whose change needs no landing, a release manifest or a data table, and a plain push
# whose every new commit touches only those files reaches the default branch. The commits are judged one by one; neither
# the tip alone nor the net change of the push says what each of them touched.
DIRECT_PUSH_REASON=""

# direct_push_matches <path> <pattern>...: succeeds where one pattern matches the whole path, as a shell pattern does:
# * stands for any characters, a slash included, ? for one character, [...] for one of a set; anything else stands for
# itself, case counted, so a pattern without those names exactly one file.
direct_push_matches() {
  local path="$1" pattern
  shift
  for pattern in "$@"; do
    # shellcheck disable=SC2254 # the pattern is a glob on purpose
    case "$path" in $pattern) return 0 ;; esac
  done
  return 1
}

# direct_push_commits_only <checkout> <patterns> <ranges>: succeeds where every commit that one of the ranges names touches
# only paths that one of the patterns matches. <patterns> is the value of DIRECT_PUSH_FILES, separated by white space, none
# an absolute path or with an empty, . or .. component. <ranges> is one `git rev-list` range per line, which the caller
# draws from the ref lines of the push. A merge is judged against each of its parents, so what it resolves is read too; a
# rename counts as the removal of its old path and the addition of its new one. A commit that changes .ai-core/config.env
# fails it whatever the patterns say, because the gate reads them from that file in the tree the push brings. A git call
# that fails, a commit that cannot be listed and a push that names no commit at all fail it, and DIRECT_PUSH_REASON says why.
direct_push_commits_only() {
  local dir="$1" patterns="$2" ranges="$3" scratch status=0
  DIRECT_PUSH_REASON=""
  scratch="$(mktemp -d)" || { DIRECT_PUSH_REASON="no folder to read the commits of this push in"; return 1; }
  direct_push_inspect "$dir" "$patterns" "$ranges" "$scratch" || status=$?
  rm -rf "$scratch"
  return "$status"
}

# direct_push_inspect <checkout> <patterns> <ranges> <folder>: the work of direct_push_commits_only, in a folder it removes.
# The changed paths are read from a file, NUL-delimited, because a path may hold a line break.
direct_push_inspect() {
  local dir="$1" patterns="$2" ranges="$3" scratch="$4" entries=() pattern range words sha path shown judged=0
  IFS=$' \t\n' read -r -d '' -a entries <<< "$patterns" || true
  [ "${#entries[@]}" -gt 0 ] || { DIRECT_PUSH_REASON="DIRECT_PUSH_FILES names no file"; return 1; }
  for pattern in "${entries[@]}"; do
    case "/$pattern/" in
      //*|*//*|*/./*|*/../*)
        DIRECT_PUSH_REASON="DIRECT_PUSH_FILES names '$pattern', which is no path inside the repository: no leading /, and no empty, . or .. component"
        return 1 ;;
    esac
  done
  while IFS= read -r range; do
    [ -n "$range" ] || continue
    read -ra words <<< "$range"
    git -C "$dir" rev-list "${words[@]}" > "$scratch/commits" \
      || { DIRECT_PUSH_REASON="git rev-list $range failed, so the commits this push adds cannot be listed"; return 1; }
    while IFS= read -r sha; do
      judged=$((judged + 1))
      git -C "$dir" diff-tree --no-commit-id --root -r -m --no-renames --name-only -z "$sha" > "$scratch/paths" \
        || { DIRECT_PUSH_REASON="git diff-tree failed, so the paths of ${sha:0:12} cannot be listed"; return 1; }
      while IFS= read -r -d '' path; do
        [ "$path" != .ai-core/config.env ] || { DIRECT_PUSH_REASON="${sha:0:12} changes .ai-core/config.env, which holds DIRECT_PUSH_FILES, and a push is never judged by a list it writes"; return 1; }
        direct_push_matches "$path" "${entries[@]}" && continue
        shown="$(printf '%s' "$path" | tr '[:cntrl:]' '?')"
        DIRECT_PUSH_REASON="${sha:0:12} touches $shown, which DIRECT_PUSH_FILES does not list"
        return 1
      done < "$scratch/paths"
    done < "$scratch/commits"
  done <<< "$ranges"
  [ "$judged" -gt 0 ] || { DIRECT_PUSH_REASON="the ranges of this push name no commit to judge"; return 1; }
}

# landing_mark_judge <mark> <root> <commit> <remote ref>: succeeds where the mark names this very commit, this clone and
# this ref; otherwise fails, and LANDING_MARK_REASON says which part does not hold
landing_mark_judge() {
  local mark="$1" root="$2" commit="$3" remote_ref="$4"
  LANDING_MARK_REASON=""
  if [ -z "$mark" ]; then LANDING_MARK_REASON="no landing path of the harness made this push"; return 1; fi
  if [ ! -f "$mark" ]; then LANDING_MARK_REASON="the mark of this landing is not there"; return 1; fi
  if [ "$(head -n 1 "$mark")" != "$(printf 'landing-mark\t%s' "$LANDING_MARK_VERSION")" ]; then LANDING_MARK_REASON="the mark is not one this gate reads"; return 1; fi
  if [ "$(awk -F'\t' '$1 == "clone" { print $2 }' "$mark")" != "$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ]; then
    LANDING_MARK_REASON="the mark belongs to another clone"; return 1
  fi
  if [ "$(awk -F'\t' '$1 == "commit" { print $2 }' "$mark")" != "$commit" ]; then LANDING_MARK_REASON="the mark names another commit than the one this push lands"; return 1; fi
  if ! grep -qxF "$(printf 'ref\t%s' "$remote_ref")" "$mark"; then LANDING_MARK_REASON="the mark does not cover $remote_ref"; return 1; fi
}

if [ "${BASH_SOURCE[0]}" = "${0:-}" ]; then
  set -uo pipefail
  case "${1:-}" in
    open) landing_check_open ;;
    complete) [ $# -eq 4 ] || { echo "usage: landing-check.sh complete <receipt> <commit> <ci ref>" >&2; exit 2; }; landing_check_complete "$2" "$3" "$4" ;;
    close) [ $# -eq 2 ] || { echo "usage: landing-check.sh close <receipt>" >&2; exit 2; }; landing_check_close "$2" ;;
    mark) [ $# -ge 4 ] || { echo "usage: landing-check.sh mark <root> <commit> <remote ref>..." >&2; exit 2; }; shift; landing_mark_open "$@" ;;
    unmark) [ $# -eq 2 ] || { echo "usage: landing-check.sh unmark <mark>" >&2; exit 2; }; landing_mark_close "$2" ;;
    rounds) . "$(dirname "${BASH_SOURCE[0]}")/common.sh"; landing_rounds_limit ;;
    *) echo "usage: landing-check.sh open | complete <receipt> <commit> <ci ref> | close <receipt> | mark <root> <commit> <remote ref>... | unmark <mark> | rounds" >&2; exit 2 ;;
  esac
fi
