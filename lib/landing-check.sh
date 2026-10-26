#!/usr/bin/env bash
# THE RECEIPT OF A CHECKED LANDING, so that a public repository's landing runs scripts/check.sh once per commit.
# Source it for the gate, or run it as
#
#   landing-check.sh open                          prints the path of a new, private receipt
#   landing-check.sh complete <receipt> <commit> <ci ref>
#   landing-check.sh close <receipt>
#   landing-check.sh mark <root> <commit> <remote ref>...   prints the path of a new mark of a harness landing
#   landing-check.sh unmark <mark>
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
# refuses every update of the default branch that carries no mark for exactly the commit it lands, so reviewed work
# reaches the default branch through `ai-core integrate-issue` and the few other paths of the harness that write one
# (a release, init's commit of the .gitignore block, the shims of `pre-push --install`, `ai-core push` of a project
# harness), never through a plain push. The
# mark is bound to the clone (its git common directory), the exact commit and the refs it may update. A landing writes
# it right before its push, hands the path to that push's Git children alone in AI_CORE_LANDING_MARK, and removes it on
# every way out; it is no setting of the shell, so two landings at the same moment never meet. The mark is no secret
# and no proof of a review: it keeps a plain `git push` from reaching the default branch by accident or by habit.

# shellcheck disable=SC2034 # the two REASON variables are read by the gate that sources this file
LANDING_CHECK_VERSION=1
LANDING_CHECK_REASON=""
LANDING_MARK_VERSION=1
LANDING_MARK_REASON=""

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
# them would otherwise reach the default branch under the harness's mark, past the review a landing stands for.
harness_commits_only() {
  local dir="$1" branch="$2" unpushed_range=(HEAD) sha files file
  if git -C "$dir" rev-parse -q --verify "refs/remotes/origin/$branch" >/dev/null; then unpushed_range=(HEAD "^refs/remotes/origin/$branch"); fi
  for sha in $(git -C "$dir" rev-list "${unpushed_range[@]}"); do
    files="$(git -C "$dir" diff-tree --no-commit-id --root -r --name-only "$sha" | sort -u | tr '\n' ' ')"
    case "$(git -C "$dir" log -1 --format='%(trailers:key=No-issue,valueonly)' "$sha")" in
      *'the .gitignore block written by ai-core init'*) [ "$files" = '.gitignore ' ] || return 1 ;;
      *'written, committed and pushed by ai-core pre-push --install'*)
        [ -n "$files" ] || return 1
        for file in $files; do
          case "$file" in .gitattributes|.githooks/pre-push|.githooks/post-checkout) ;; *) return 1 ;; esac
        done ;;
      *) return 1 ;;
    esac
  done
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
    *) echo "usage: landing-check.sh open | complete <receipt> <commit> <ci ref> | close <receipt> | mark <root> <commit> <remote ref>... | unmark <mark>" >&2; exit 2 ;;
  esac
fi
