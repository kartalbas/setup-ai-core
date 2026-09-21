#!/usr/bin/env bash
# The push gate of every repository the harness serves. Git starts it through the repository's
# .githooks/pre-push shim (`exec ai-core pre-push "$@"`) with git's own standard input, one line
# per ref,
#
#   <local ref> <local sha> <remote ref> <remote sha>
#
# and with the working directory set to the tree being pushed. THAT TREE IS THE SUBJECT: every
# git call below reads the calling repository, and scripts/check.sh is that repository's own.
#
# What it judges, in this order, stopping at the first refusal:
#
#   1. the pushed commit is the one that is checked out
#   2. every pushed commit names its issue, or says why it does not
#   3. the team modes are installed
#   4. every Windows entry point in the tree is the one text, and not a copy that decides
#   5. the repository's own scripts/check.sh is green
#   6. gitleaks over the commits the push carries, in a repository that carries .gitleaks.toml
#
# Run from a terminal, with nothing on standard input, it judges what `git push` would send from
# the current branch: the commits its upstream does not have.
#
#   pre-push.sh                              the gate, as git runs it
#   pre-push.sh --install [--all <folder>]   write the shim into .githooks/pre-push and arm it
#
set -uo pipefail

for arg in "$@"; do
  if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
    echo "Usage: pre-push.sh [--install [--all <folder>]]"
    echo ""
    echo "The push gate. Git runs it through the repository's .githooks/pre-push shim before a push"
    echo "and it refuses the push, exit 1, when: a pushed commit is not the one checked out; a pushed"
    echo "commit names no issue (#<n>), does not open with 'release:', touches more than *.md and"
    echo "LICENSE files, and carries no 'No-issue: <who asked and why>' trailer; a team mode is"
    echo "missing; a check.ps1 or build.ps1 differs from the one Windows entry point (lib/entry-point.ps1,"
    echo "judged where scripts/check.sh exists); scripts/check.sh is red; or gitleaks finds a credential"
    echo "in the pushed commits (where .gitleaks.toml exists). Merges are not judged; a deletion runs"
    echo "no checks. Run from a terminal it judges the current branch against its upstream."
    echo ""
    echo "Options:"
    echo "  --install         Write the shim into .githooks/pre-push of the current repository and of"
    echo "                    every worktree of it, set core.hooksPath to .githooks, commit the shim on"
    echo "                    its own (No-issue: trailer) and push it by ref to the branch checked out,"
    echo "                    through the gate; a worktree gets the file only. An unpushed commit that"
    echo "                    names no issue and touches nothing but .gitignore gets the trailer that"
    echo "                    says init wrote it, so the push goes through"
    echo "  --all <folder>    With --install: every git repository directly under the folder"
    echo "  -h, --help        Show this help message"
    echo ""
    echo "Examples:"
    echo "  ai-core pre-push"
    echo "  ai-core pre-push --install"
    echo "  ai-core pre-push --install --all ../my-org"
    exit 0
  fi
done

CORE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL=0; ALL_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --install) INSTALL=1 ;;
    --all) shift; [ $# -gt 0 ] || { echo "error: --all needs a folder" >&2; exit 2; }; ALL_DIR="$1" ;;
    -*) echo "error: unknown option '$1' (see --help)" >&2; exit 2 ;;
    *) # git hands the hook the remote's name and URL; they are not needed here
       [ "$INSTALL" -eq 0 ] || { echo "error: unexpected argument '$1' (see --help)" >&2; exit 2; } ;;
  esac
  shift
done
[ -z "$ALL_DIR" ] || [ "$INSTALL" -eq 1 ] || { echo "error: --all goes with --install" >&2; exit 2; }

refuse() { echo "pre-push: REFUSED — $*" >&2; exit 1; }
TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT

# --- --install: the shim, three lines that only start this gate ----------------------------
SHIM='#!/usr/bin/env bash
# The push gate is `ai-core pre-push` (setup-ai-core); this file only starts it with git'"'"'s own standard input.
command -v ai-core >/dev/null 2>&1 || { echo "pre-push: REFUSED — ai-core is not on the PATH of this shell, so nothing judged this push. Install setup-ai-core, or open a new terminal where its bin/ is on the PATH." >&2; exit 1; }
exec ai-core pre-push "$@"
'
write_shim() {  # write_shim <tree>: the shim into <tree>/.githooks/pre-push; prints unchanged, refreshed or created
  local dir="$1" path
  path="$dir/.githooks/pre-push"
  if [ -f "$path" ] && [ "$(tr -d '\r' < "$path")" = "$(printf '%s' "$SHIM")" ]; then echo unchanged; return 0; fi
  if [ -f "$path" ]; then echo refreshed; else echo created; fi
  mkdir -p "$dir/.githooks"
  printf '%s' "$SHIM" > "$path"
  chmod +x "$path"
}
# commit_shim <repository> <label>: the shim committed on its own, with the executable bit, and
# pushed by ref to the branch checked out; nothing when the commit already carries it
# excuse_gitignore_commits <repository> <label> <branch>: an unpushed commit that names no issue
# and touches nothing but .gitignore was written by an init before init committed the block
# itself; it gets the trailer that says so, in one rebase of the unpushed commits, author kept.
excuse_gitignore_commits() {
  local dir="$1" label="$2" branch="$3" sha short list=""
  git -C "$dir" rev-parse -q --verify "origin/$branch" >/dev/null 2>&1 || return 0
  for sha in $(git -C "$dir" rev-list --reverse --no-merges "origin/$branch..HEAD"); do
    case "$(git -C "$dir" log -1 --format=%B "$sha")" in *'#'[0-9]*) continue ;; esac
    case "$(git -C "$dir" log -1 --format=%s "$sha")" in 'release:'*) continue ;; esac
    [ -z "$(git -C "$dir" log -1 --format='%(trailers:key=No-issue,valueonly)' "$sha" | tr -d '[:space:]')" ] || continue
    [ "$(git -C "$dir" show --pretty=format: --name-only "$sha" | grep -v '^$' | sort -u | tr '\n' ' ')" = ".gitignore " ] || continue
    short="$(git -C "$dir" rev-parse --short "$sha")"
    list="$list $short"
    echo "pre-push: $label: $short ($(git -C "$dir" log -1 --format=%s "$sha")) touches only .gitignore and names no issue; it gets the trailer that says init wrote it"
  done
  [ -n "$list" ] || return 0
  : > "$TMPD/seq.sh"
  for short in $list; do printf 'sed -i "s/^pick %s /reword %s /" "$1"\n' "$short" "$short" >> "$TMPD/seq.sh"; done
  printf 'printf "\\nNo-issue: the .gitignore block written by ai-core init\\n" >> "$1"\n' > "$TMPD/msg.sh"
  GIT_SEQUENCE_EDITOR="sh $TMPD/seq.sh" GIT_EDITOR="sh $TMPD/msg.sh" git -C "$dir" rebase -q -i "origin/$branch" >/dev/null 2>&1 \
    || { git -C "$dir" rebase --abort >/dev/null 2>&1; echo "pre-push: $label: the trailer could not be added; the commits are as they were" >&2; return 1; }
}
# commit_only <repository> <path> <subject> <trailer>: one path, with the executable bit, as one
# commit on HEAD, whatever else is staged; built from an index of its own, because `git commit --
# <path>` reads the path from the working tree, which on Windows has no executable bit.
commit_only() {
  local dir="$1" path="$2" subject="$3" trailer="$4" idx tree commit parent=()
  idx="$TMPD/index"; rm -f "$idx"
  if git -C "$dir" rev-parse -q --verify HEAD >/dev/null 2>&1; then
    GIT_INDEX_FILE="$idx" git -C "$dir" read-tree HEAD || return 1; parent=(-p HEAD)
  else
    GIT_INDEX_FILE="$idx" git -C "$dir" read-tree --empty || return 1
  fi
  GIT_INDEX_FILE="$idx" git -C "$dir" add --chmod=+x -- "$path" || return 1
  tree="$(GIT_INDEX_FILE="$idx" git -C "$dir" write-tree)" || return 1
  commit="$(git -C "$dir" commit-tree "$tree" ${parent[@]+"${parent[@]}"} -m "$subject" -m "$trailer")" || return 1
  git -C "$dir" update-ref HEAD "$commit" || return 1
  git -C "$dir" add --chmod=+x -- "$path"   # the index follows HEAD for this path, so it is clean
}
commit_shim() {
  local dir="$1" label="$2" branch
  if git -C "$dir" ls-files --error-unmatch .githooks/pre-push >/dev/null 2>&1 && git -C "$dir" diff --quiet HEAD -- .githooks/pre-push 2>/dev/null; then :; else
    commit_only "$dir" .githooks/pre-push 'the push gate is ai-core pre-push' 'No-issue: written, committed and pushed by ai-core pre-push --install' \
      || { echo "pre-push: $label: the commit failed (see above); the shim is written" >&2; return 1; }
    echo "pre-push: $label: committed $(git -C "$dir" rev-parse --short HEAD)"
  fi
  git -C "$dir" remote get-url origin >/dev/null 2>&1 || { echo "pre-push: $label: no origin; not pushed"; return 0; }
  branch="$(git -C "$dir" symbolic-ref --short -q HEAD)" || { echo "pre-push: $label: not on a branch; not pushed" >&2; return 1; }
  if git -C "$dir" rev-parse -q --verify "origin/$branch" >/dev/null 2>&1 && [ "$(git -C "$dir" rev-list --count "origin/$branch..HEAD")" -eq 0 ]; then echo "pre-push: $label: nothing to push"; return 0; fi
  excuse_gitignore_commits "$dir" "$label" "$branch" || return 1
  git -C "$dir" push --quiet origin "HEAD:$branch" || { echo "pre-push: $label: the push was refused or failed (see above); the commit stays" >&2; return 1; }
  echo "pre-push: $label: pushed to origin/$branch"
}
install_shim() {  # install_shim <repository>: 0 written or unchanged, 1 not a repository
  local dir="$1" name tree
  name="$(basename "$dir")"
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "pre-push: $name is not a git repository; nothing installed" >&2; return 1; }
  # The hook runs only where git looks for it; the setting is the clone's own, never committed
  if [ "$(git -C "$dir" config --get core.hooksPath 2>/dev/null)" != ".githooks" ]; then
    git -C "$dir" config core.hooksPath .githooks
    echo "pre-push: $name: core.hooksPath set to .githooks"
  fi
  # A relative core.hooksPath is read from the tree being pushed, so every worktree of the
  # repository carries its own copy of the shim, and git runs the file on disk, committed or not.
  # The checkout commits and pushes it; a worktree is somebody's issue and gets the file only.
  echo "pre-push: $name: .githooks/pre-push $(write_shim "$dir")"
  while IFS= read -r tree; do
    tree="${tree#worktree }"
    [ -n "$tree" ] && [ "$tree" != "$(cd "$dir" && pwd)" ] && [ "$tree" != "$(cd "$dir" && pwd -W 2>/dev/null)" ] || continue
    [ -d "$tree" ] || continue
    echo "pre-push: $name (worktree $(basename "$tree")): .githooks/pre-push $(write_shim "$tree"); it goes out with that worktree's own commit"
  done <<< "$(git -C "$dir" worktree list --porcelain 2>/dev/null | grep '^worktree ' | tail -n +2)"
  commit_shim "$dir" "$name"
}
if [ "$INSTALL" -eq 1 ]; then
  if [ -n "$ALL_DIR" ]; then
    ALL_DIR="$(cd "$ALL_DIR" && pwd)"; OK=0; FAILED=""
    for repo in "$ALL_DIR"/*/; do
      repo="${repo%/}"; [ -e "$repo/.git" ] || continue
      if install_shim "$repo"; then OK=$((OK + 1)); else FAILED="$FAILED $(basename "$repo")"; fi
    done
    echo "==> pre-push --install --all: the shim is in $OK repositories${FAILED:+; failed:$FAILED}"
    [ -z "$FAILED" ]; exit $?
  fi
  install_shim "$(pwd)"; exit $?
fi

# --- the gate --------------------------------------------------------------------------------
# Git exports GIT_DIR, GIT_WORK_TREE and GIT_INDEX_FILE to a hook. A check that starts git itself
# in a temporary directory would then act on the pushing repository instead of its own. Git
# started this hook in the tree being pushed, so every git call below finds the repository by the
# working directory and nothing needs the variables.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR
root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "error: not inside a git repository" >&2; exit 2; }
head="$(git rev-parse HEAD 2>/dev/null)" || { echo "error: this repository has no commit yet" >&2; exit 2; }

# A sha of nothing but zeros, whatever length the repository's object format writes. SHA-1 sends
# forty digits and SHA-256 sends sixty-four, and a written-out constant reads the longer one as
# a real commit.
all_zero() {  # all_zero <sha>
  case "$1" in *[!0]*) return 1 ;; *) return 0 ;; esac
}

# Git sends the ref lines on standard input. With nothing there - a terminal, an agent's shell,
# nothing piped - the subject is the push git would make from here: the current branch against
# its upstream, or against every remote ref when it has none yet.
if [ -t 0 ]; then input=""; else input="$(cat)"; fi
if [ -z "$input" ]; then
  branch="$(git symbolic-ref --short -q HEAD)" || { echo "error: not on a branch; nothing to judge" >&2; exit 2; }
  upstream="$(git rev-parse -q --verify '@{upstream}' 2>/dev/null)" || upstream="0000000000000000000000000000000000000000"
  echo "pre-push: judging $branch against $(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || echo "every remote ref (no upstream yet)")"
  input="refs/heads/$branch $head refs/heads/$branch $upstream"
fi

# Every commit this push sends, across every ref on standard input, and the ranges they came from.
commits=''
scan_ranges=''
pushing=0
while read -r local_ref local_sha remote_ref remote_sha; do
  [ -n "${local_sha:-}" ] || continue
  all_zero "$local_sha" && continue                   # a deletion sends no commit
  pushing=1
  # WHAT IS PUSHED IS RESOLVED TO A COMMIT FIRST. An annotated tag hands its own object's sha
  # here, never the commit it names, so comparing it to HEAD unresolved refuses every annotated
  # tag there is. Resolving it asks the question the refusal below means to ask: is the tree this
  # ref names the tree the checks read.
  local_commit="$(git rev-parse --quiet --verify "${local_sha}^{commit}" 2>/dev/null || printf '%s' "$local_sha")"
  # Work is pushed by ref (`git push origin HEAD:<branch>`). A local sha that is not HEAD means
  # the tree the checks are about to run in is not the tree being sent.
  [ "$local_commit" = "$head" ] \
    || refuse "$local_ref is not what is checked out - push what you have: git push origin HEAD:${remote_ref##*/}"
  if all_zero "${remote_sha:-}"; then
    # An all-zero remote sha is a ref the remote does not have yet, so there is no "before" to
    # compare with. Reading that as "everything reachable" judges the whole history - every commit
    # already published, by whatever rule held when it was written. A TAG is exactly that case: it
    # names a commit the branch already carries, so what it introduces is nothing at all.
    # Excluding every remote ref this checkout knows asks the question this loop means to ask -
    # which commits does this push add - and answers it with none where none are added.
    range="$local_commit --not --remotes=origin"
  else
    # A remote sha this checkout does not carry cannot be measured from. Letting `git rev-list`
    # fail quietly would leave the range empty, and an empty range is read below as a push with
    # nothing in it - so a force push over an unfetched remote would go out unjudged.
    git cat-file -e "${remote_sha}^{commit}" 2>/dev/null \
      || refuse "the commit $remote_sha that $remote_ref points at is not in this checkout, so the commits being pushed cannot be listed. Run git fetch, then push again."
    range="$remote_sha..$local_commit"
  fi
  commits="$commits$(git rev-list --no-merges $range)"$'\n'
  scan_ranges="$scan_ranges$range"$'\n'
done <<< "$input"

# Nothing to send, or nothing but deletions: there is nothing to judge and nothing to test.
[ "$pushing" -eq 1 ] || exit 0
commits="$(printf '%s\n' "$commits" | grep -v '^$' || true)"
if [ -z "$commits" ]; then
  echo 'pre-push: nothing new to send.'
  exit 0
fi

# WHAT EXCUSES A COMMIT FROM NAMING AN ISSUE, and why each one is here:
#
#   a release stamp        the subject opens with `release:`; a version bump belongs to no issue
#   an explanation only    every file it touches is a `*.md` or a LICENSE; a typo in a document
#                          is not worth a ticket, and requiring one is how documents stop being
#                          corrected
#   a No-issue: trailer    somebody wrote down who asked and why there is no ticket. It is a
#                          sentence a reviewer reads, not a way around the rule
#
# THE NAME IS MATCHED WITHOUT ITS FOLDER. `LICENSE-MIT` and `docs/LICENSE` explain as much as
# `LICENSE` does, and a rule that reads the whole path gives one commit two verdicts depending
# on which repository it lands in.
explains_only() {  # explains_only <sha>
  local files file base
  files="$(git show --pretty=format: --name-only "$1" | grep -v '^$' || true)"
  [ -n "$files" ] || return 1
  while IFS= read -r file; do
    base="${file##*/}"
    case "$base" in
      *.md|LICENSE*) ;;
      *) return 1 ;;
    esac
  done <<< "$files"
  return 0
}
unnamed=0
while IFS= read -r sha; do
  [ -n "$sha" ] || continue
  message="$(git log -1 --format='%B' "$sha")"
  subject="$(git log -1 --format='%s' "$sha")"
  case "$message" in *'#'[0-9]*) continue ;; esac
  case "$subject" in 'release:'*) continue ;; esac
  # The trailer is read the way git reads a trailer, and it has to name a reason. Searching the
  # whole message for the two words accepts an empty `No-issue:` and accepts the words inside a
  # body sentence, and both of those are exactly the way around the rule this excuse is not.
  trailer="$(git log -1 --format='%(trailers:key=No-issue,valueonly)' "$sha" | tr -d '[:space:]')"
  [ -n "$trailer" ] && continue
  if explains_only "$sha"; then continue; fi
  echo "pre-push: $(git log -1 --format='%h %s' "$sha") names no issue" >&2
  unnamed=$((unnamed + 1))
done <<< "$commits"
[ "$unnamed" -eq 0 ] \
  || refuse "$unnamed commit(s) name no issue. Write #<number> in the message, open the subject with 'release:', touch only files that explain, or add a 'No-issue: <who asked and why>' trailer."

# The check prints one MISSING line per mode with the command that installs it, so it is never
# run quiet: the refusal sends the person to those lines.
bash "$CORE_ROOT/bin/team-modes-check.sh" \
  || refuse 'the team modes are missing - the lines above say which and how to install them'

# THE WINDOWS ENTRY POINT IS ONE TEXT, AND THIS IS WHERE IT IS HELD. Where the checks are written
# in scripts/check.sh, check.ps1 and build.ps1 decide nothing: each starts the .sh file of its own
# name, so one text serves every repository. Overwrite one of them with two lines that print the
# verdict and exit 0 and the person at the keyboard reads that the checks passed while nothing
# ran. No other step here can see that, because every one of them reads the .sh side.
#
# THE FILE NAME IS THE RULE AND NO REPOSITORY IS LISTED. The name is matched in full and without
# its folder: a pattern of *check.ps1 would take bin/case-check.ps1 with it, and that is a twin
# implementation with a test of its own, not a copy of anything.
if [ -f "$root/scripts/check.sh" ]; then
  shim="$CORE_ROOT/lib/entry-point.ps1"
  [ -f "$shim" ] || refuse "$shim is missing, and it is the one text every Windows entry point copies."
  while IFS= read -r -d '' door; do
    case "${door##*/}" in check.ps1|build.ps1) ;; *) continue ;; esac
    [ -f "$root/$door" ] || continue
    # Both sides are read without their carriage returns. A checkout that wrote CRLF runs the
    # same program, and refusing it would report drift where there is none.
    cmp -s <(tr -d '\r' < "$shim") <(tr -d '\r' < "$root/$door") \
      || refuse "$door is not the Windows entry point every repository carries. It starts the .sh file of its own name and decides nothing, and this copy says something else. Restore it: cp '$shim' '$root/$door'"
  done < <(git -C "$root" ls-files -z -- '*.ps1')   # -z: a path git would otherwise quote still matches
fi

# The wait is announced here and not earlier, so a push that is refused above is not first
# promised a run it never gets. How long it takes is the repository's own business.
if [ -f "$root/scripts/check.sh" ]; then
  echo "pre-push: $root/scripts/check.sh runs here, before anything leaves this machine."
  bash "$root/scripts/check.sh" || refuse 'a check failed - the lines above name which one.'
else
  echo 'pre-push: no scripts/check.sh in this repository; nothing runs before the push.'
fi

# THE COMMITS ARE SCANNED TOO, not only the working copy. scripts/check.sh reads one state: the
# files git would let you commit right now. A credential that was committed in one pushed commit
# and taken out again in a later one is not in that state, and it would leave this machine
# unread. The commits being pushed are the only place it still stands, and this hook is the only
# thing that knows which those are. The scan is armed by the file gitleaks reads its rules from,
# so a repository joins by carrying the configuration and no repository is named here.
if [ -f "$root/.gitleaks.toml" ]; then
  echo 'pre-push: gitleaks over the commits this push carries.'
  command -v gitleaks >/dev/null 2>&1 \
    || refuse "gitleaks is not on this path, and $root/.gitleaks.toml says the commits being pushed are read for credentials."
  while IFS= read -r scan_range; do
    [ -n "$scan_range" ] || continue
    gitleaks git --no-banner --log-opts="$scan_range" "$root" \
      || refuse 'a credential stands in a commit this push carries. The lines above name the commit, the file and the rule. Take it out of the history - a commit that is pushed cannot be recalled.'
  done <<< "$scan_ranges"
fi

echo 'pre-push: every check passed.'
