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
#   5. the names of the new directories are derived from the families the trees carry
#   6. the repository's own scripts/check.sh is green
#   7. gitleaks over the commits the push carries, in a repository that carries .gitleaks.toml
#
# Run from a terminal, with nothing on standard input, it judges what `git push` would send from
# the current branch: the commits its upstream does not have.
#
#   pre-push.sh                              the gate, as git runs it
#   pre-push.sh --install [--all <folder>]   write the two shims into .githooks/ and arm them
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
    echo "judged where scripts/check.sh exists); a file the push adds or changes starts with #! and is"
    echo "not executable; a subject is longer than 72 characters; a message carries an assistant's or a"
    echo "vendor's attribution; an added comment names an issue as (#<n>) or <repo>#<n>; an existing"
    echo "migrations/*.sql is changed or removed (a 'Migration: <why>' trailer allows it); one spelling"
    echo "of a script changes without the other where x.sh and x.ps1 both stand (a 'Twin: <why>' trailer"
    echo "allows it); a new directory's name is invented where the families"
    echo "of the trees give it (a 'Naming: <why>' trailer keeps one); scripts/check.sh is red; or gitleaks"
    echo "finds a credential in the pushed commits (where .gitleaks.toml exists). Merges are not judged; a deletion runs"
    echo "no checks. Run from a terminal it judges the current branch against its upstream."
    echo ""
    echo "Options:"
    echo "  --install         Write the two shims, .githooks/pre-push (this gate) and .githooks/post-checkout"
    echo "                    (ai-core init in a new worktree), into the current repository and every"
    echo "                    worktree of it, set core.hooksPath to .githooks, commit them on their own"
    echo "                    (No-issue: trailer) and push by ref to the branch checked out, through the"
    echo "                    gate; a worktree gets the files only. An unpushed commit that names no"
    echo "                    issue and touches nothing but .gitignore gets the trailer that says init"
    echo "                    wrote it, so the push goes through. The checkout catches up with its"
    echo "                    origin first; one behind it with work of its own gets nothing"
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

. "$CORE_ROOT/lib/layers.sh"
refuse() { echo "pre-push: REFUSED — $*" >&2; exit 1; }
TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT

# --- --install: two shims; the first only starts this gate ------------------------------------
SHIM='#!/usr/bin/env bash
# The push gate is `ai-core pre-push` (setup-ai-core); this file only starts it with git'"'"'s own standard input.
command -v ai-core >/dev/null 2>&1 || { echo "pre-push: REFUSED — ai-core is not on the PATH of this shell, so nothing judged this push. Install setup-ai-core, or open a new terminal where its bin/ is on the PATH." >&2; exit 1; }
exec ai-core pre-push "$@"
'
# The second shim: the harness is in no commit, so a worktree starts without it. Git runs
# .githooks/post-checkout in the new tree after `git worktree add` (third argument 1, as after
# any branch checkout), and where .ai-core/ is missing the shim starts `ai-core init`. It exits 0
# whatever happened, because a failing hook fails the checkout too; what went wrong is on stderr.
SHIM_CHECKOUT='#!/usr/bin/env bash
# A new worktree starts with the harness: git runs this file after `git worktree add` and after every checkout; where .ai-core/ is missing, `ai-core init` (setup-ai-core) writes it.
[ "${3:-0}" = 1 ] && [ ! -d .ai-core ] || exit 0
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR
command -v ai-core >/dev/null 2>&1 || { echo "post-checkout: ai-core is not on the PATH of this shell, so this worktree has no harness yet; run ai-core init here before you start" >&2; exit 0; }
ai-core init --no-doctor || echo "post-checkout: the harness is NOT complete in this worktree (see above); run ai-core init here before you start" >&2
'
SHIM_PATHS=(.githooks/pre-push .githooks/post-checkout)
# Git runs the shims through bash, and a shim checked out with CRLF fails on the first line; the
# repository's .gitattributes gets a rule for them where no rule makes them check out with LF.
ATTR_RULE='.githooks/* text eol=lf'
ATTR_ADDED=0
write_attributes() {  # write_attributes <tree>: the rule into <tree>/.gitattributes when nothing makes the shims LF; prints unchanged or added
  local dir="$1" path="$1/.gitattributes"
  [ "$(git -C "$dir" check-attr eol -- .githooks/pre-push 2>/dev/null | sed 's/.*: //')" != lf ] || { echo unchanged; return 0; }
  if [ -f "$path" ]; then [ -z "$(tail -c 1 "$path")" ] || printf '\n' >> "$path"; fi
  printf '%s\n' "$ATTR_RULE" >> "$path"
  echo added
}
write_shim() {  # write_shim <tree> <hook> <text>: the text into <tree>/.githooks/<hook>; prints unchanged, refreshed or created
  local dir="$1" hook="$2" text="$3" path
  path="$dir/.githooks/$hook"
  if [ -f "$path" ] && [ "$(tr -d '\r' < "$path")" = "$(printf '%s' "$text")" ]; then
    if [ -x "$path" ]; then echo unchanged; else chmod +x "$path"; echo "made executable"; fi
    return 0
  fi
  if [ -f "$path" ]; then echo refreshed; else echo created; fi
  mkdir -p "$dir/.githooks"
  printf '%s' "$text" > "$path"
  chmod +x "$path"
}
write_shims() {  # write_shims <tree> <label> <suffix> [checkout]: both shims, one report line each, and the attributes rule where it is missing
  local dir="$1" label="$2" suffix="$3"
  echo "pre-push: $label: .githooks/pre-push $(write_shim "$dir" pre-push "$SHIM")$suffix"
  echo "pre-push: $label: .githooks/post-checkout $(write_shim "$dir" post-checkout "$SHIM_CHECKOUT")$suffix"
  if [ "$(write_attributes "$dir")" = added ]; then
    echo "pre-push: $label: .gitattributes: $ATTR_RULE added; the shims check out LF everywhere$suffix"
    [ "${4:-}" != checkout ] || ATTR_ADDED=1
  fi
}
# commit_shim <repository> <label>: the shims committed on their own, with the executable bit,
# and pushed by ref to the branch checked out; nothing when the commit already carries them
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
# commit_only <repository> <subject> <trailer> <path>...: the paths, the shims with the executable
# bit, as one commit on HEAD, whatever else is staged; built from an index of its own, because
# `git commit -- <path>` reads the path from the working tree, which on Windows has no executable bit.
add_paths() {  # add_paths <repository> <path>...: into the index git works on; the shims with the executable bit
  local dir="$1" p; shift
  for p in "$@"; do
    case "$p" in .githooks/*) git -C "$dir" add --chmod=+x -- "$p" || return 1 ;; *) git -C "$dir" add -- "$p" || return 1 ;; esac
  done
}
commit_only() {
  local dir="$1" subject="$2" trailer="$3" idx tree commit parent=(); shift 3
  idx="$TMPD/index"; rm -f "$idx"
  if git -C "$dir" rev-parse -q --verify HEAD >/dev/null 2>&1; then
    GIT_INDEX_FILE="$idx" git -C "$dir" read-tree HEAD || return 1; parent=(-p HEAD)
  else
    GIT_INDEX_FILE="$idx" git -C "$dir" read-tree --empty || return 1
  fi
  ( export GIT_INDEX_FILE="$idx"; add_paths "$dir" "$@" ) || return 1
  tree="$(GIT_INDEX_FILE="$idx" git -C "$dir" write-tree)" || return 1
  commit="$(git -C "$dir" commit-tree "$tree" ${parent[@]+"${parent[@]}"} -m "$subject" -m "$trailer")" || return 1
  git -C "$dir" update-ref HEAD "$commit" || return 1
  add_paths "$dir" "$@"   # the index follows HEAD for these paths, so it is clean
}
commit_shim() {
  local dir="$1" label="$2" branch
  local paths=("${SHIM_PATHS[@]}"); [ "$ATTR_ADDED" -eq 0 ] || paths+=(.gitattributes)
  # a commit whose shims lack the executable bit (a copy that drops the file modes writes them so) is
  # one git skips them in: it gets a commit of its own as well
  if git -C "$dir" ls-files --error-unmatch "${paths[@]}" >/dev/null 2>&1 && git -C "$dir" diff --quiet HEAD -- "${paths[@]}" 2>/dev/null \
    && [ -z "$(git -C "$dir" ls-tree HEAD -- "${SHIM_PATHS[@]}" | awk '$1 != "100755"')" ]; then :; else
    commit_only "$dir" 'the hooks of ai-core: the push gate, init in a new worktree' 'No-issue: written, committed and pushed by ai-core pre-push --install' "${paths[@]}" \
      || { echo "pre-push: $label: the commit failed (see above); the shims are written" >&2; return 1; }
    echo "pre-push: $label: committed $(git -C "$dir" rev-parse --short HEAD)"
  fi
  git -C "$dir" remote get-url origin >/dev/null 2>&1 || { echo "pre-push: $label: no origin; not pushed"; return 0; }
  branch="$(git -C "$dir" symbolic-ref --short -q HEAD)" || { echo "pre-push: $label: not on a branch; not pushed" >&2; return 1; }
  if git -C "$dir" rev-parse -q --verify "origin/$branch" >/dev/null 2>&1 && [ "$(git -C "$dir" rev-list --count "origin/$branch..HEAD")" -eq 0 ]; then echo "pre-push: $label: nothing to push"; return 0; fi
  excuse_gitignore_commits "$dir" "$label" "$branch" || return 1
  git -C "$dir" push --quiet origin "HEAD:$branch" || { echo "pre-push: $label: the push was refused or failed (see above); the commit stays" >&2; return 1; }
  echo "pre-push: $label: pushed to origin/$branch"
}
# gitleaks_git: a gitleaks that can run the scan of this gate; `gitleaks git` came with gitleaks 8.19
gitleaks_git() { command -v gitleaks >/dev/null 2>&1 && gitleaks git --help >/dev/null 2>&1; }
install_shim() {  # install_shim <repository>: 0 written or unchanged, 1 not a repository
  local dir="$1" name tree
  name="$(basename "$dir")"
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "pre-push: $name is not a git repository; nothing installed" >&2; return 1; }
  # The shims go out through this gate: where .gitleaks.toml arms its scan and no gitleaks can run
  # it, their push is refused and the commit stays behind, so nothing is written
  if [ -f "$dir/.gitleaks.toml" ] && ! gitleaks_git; then
    echo "pre-push: $name: .gitleaks.toml arms the gitleaks scan of this gate, and no gitleaks 8.19 or newer is on this path, so the push of the shims would be refused; nothing installed. Run ai-core doctor here, which installs it, then this again." >&2; return 1
  fi
  # Their commit goes on top of what the origin has: the checkout catches up first
  local caught
  if ! caught="$(catch_up "$dir")"; then echo "pre-push: $name: this checkout is $caught; nothing installed" >&2; return 1; fi
  [ -z "$caught" ] || echo "pre-push: $name: $caught"
  # The hook runs only where git looks for it; the setting is the clone's own, never committed
  if [ "$(git -C "$dir" config --get core.hooksPath 2>/dev/null)" != ".githooks" ]; then
    git -C "$dir" config core.hooksPath .githooks
    echo "pre-push: $name: core.hooksPath set to .githooks"
  fi
  # A relative core.hooksPath is read from the tree git works in, so every worktree of the
  # repository carries its own copy of the shims, and git runs the files on disk, committed or not.
  # The checkout commits and pushes them; a worktree is somebody's issue and gets the files only.
  ATTR_ADDED=0
  write_shims "$dir" "$name" "" checkout
  while IFS= read -r tree; do
    tree="${tree#worktree }"
    [ -n "$tree" ] && [ "$tree" != "$(cd "$dir" && pwd)" ] && [ "$tree" != "$(cd "$dir" && pwd -W 2>/dev/null)" ] || continue
    [ -d "$tree" ] || continue
    write_shims "$tree" "$name (worktree $(basename "$tree"))" "; it goes out with that worktree's own commit"
  done <<< "$(git -C "$dir" worktree list --porcelain 2>/dev/null | grep '^worktree ' | tail -n +2)"
  commit_shim "$dir" "$name" || return 1
  # a hook of the project's own that git skips for want of the executable bit is named, not changed
  git -C "$dir" ls-tree HEAD -- .githooks/ | awk '$1 == "100644" { print $4 }' | while IFS= read -r hook; do
    echo "pre-push: $name: $hook is not executable, so git skips it; it is the project's own and stays as it is"
  done
}
if [ "$INSTALL" -eq 1 ]; then
  if [ -n "$ALL_DIR" ]; then
    ALL_DIR="$(cd "$ALL_DIR" && pwd)"; OK=0; FAILED=""
    for repo in "$ALL_DIR"/*/; do
      repo="${repo%/}"; [ -e "$repo/.git" ] || continue
      if install_shim "$repo"; then OK=$((OK + 1)); else FAILED="$FAILED $(basename "$repo")"; fi
    done
    echo "==> pre-push --install --all: the hooks are in $OK repositories${FAILED:+; failed:$FAILED}"
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

# The default branch: origin/HEAD where it names a branch this clone has, else what the origin
# names (a clone keeps origin/HEAD pointing at a branch the origin renamed since), else master
default="$(git symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null || true)"
git rev-parse -q --verify "refs/remotes/$default" >/dev/null 2>&1 \
  || default="$(git ls-remote --symref origin HEAD 2>/dev/null | awk '$1 == "ref:" && $3 == "HEAD" { sub("^refs/heads/", "", $2); print $2 }')"
default="${default#origin/}"; [ -n "$default" ] || default=master

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
    # A push that is not a fast-forward drops commits the remote has. On the default branch that is
    # history everybody else builds on, so it is refused, whatever tool or person forced it.
    [ "$remote_ref" != "refs/heads/$default" ] || git merge-base --is-ancestor "$remote_sha" "$local_commit" \
      || refuse "the push to $default is not a fast-forward: it would drop commits the remote has. Fetch, rebase onto origin/$default and push again; a force push to the default branch is refused."
    # What the remote carries on ANY ref is published already. A branch that merged the default
    # branch brings every commit the default branch gained since the fork; judging those again
    # holds commits other flows wrote to today's rules, and the branch could only catch up by a
    # rebase and a force push.
    range="$local_commit ^$remote_sha --not --remotes=origin"
  fi
  commits="$commits$(git rev-list --no-merges $range)"$'\n'
  scan_ranges="$scan_ranges$range"$'\n'
done <<< "$input"

# Nothing to send, or nothing but deletions: there is nothing to judge and nothing to test.
[ "$pushing" -eq 1 ] || exit 0
commits="$(grep -v '^$' <<< "$commits" || true)"
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

# A FILE THAT STARTS WITH #! IS RUN BY ITS NAME, so it carries the executable bit: without it
# ./release/release.sh fails and git skips a hook in .githooks. A tool that writes files (an agent's,
# a copy made through an API) leaves the bit off, and git keeps what it was given. Judged on what the
# push adds or changes, as the commit checked out has it; a file the push does not touch is left alone.
modeless=""
while IFS= read -r path; do
  [ -n "$path" ] || continue
  [ "$(git ls-tree "$head" -- "$path" | cut -d' ' -f1)" = 100644 ] || continue
  [ "$(git cat-file -p "$head:$path" 2>/dev/null | head -c 2 || true)" = '#!' ] || continue
  modeless="$modeless $path"
done < <(while IFS= read -r sha; do [ -z "$sha" ] || git diff-tree --no-commit-id --root -r --name-only --diff-filter=AMR "$sha"; done <<< "$commits" | sort -u)
[ -z "$modeless" ] || refuse "these files start with #! and are not executable, so running them by name fails and git skips a hook among them:$modeless. Set the bit and commit it: git update-index --chmod=+x$modeless"

# THE COMMIT MESSAGES (the commit rules). A subject is at most 72 characters, because the log, the
# tracker and every list view cut a longer one and the rest is lost where it is read; and no
# message carries an assistant's or a vendor's attribution, because the history names who answers
# for a change, and a tool cannot. Each message is read whole before it is searched.
long=""; attributed=""
while IFS= read -r sha; do
  [ -n "$sha" ] || continue
  subject="$(git log -1 --format=%s "$sha")"
  [ "${#subject}" -le 72 ] || long="$long
  $(git log -1 --format=%h "$sha") has ${#subject} characters: $subject"
  message="$(git log -1 --format=%B "$sha")"
  if grep -qiE '^co-authored-by:.*(claude|codex|gemini|copilot|chatgpt|anthropic|openai)|generated (with|by) \[?(claude|codex|gemini|copilot|chatgpt)' <<< "$message"; then
    attributed="$attributed $(git log -1 --format=%h "$sha")"
  fi
done <<< "$commits"
[ -z "$long" ] || refuse "these subjects are longer than 72 characters:$long
  Shorten each to one sentence of at most 72 that says what changed, with git commit --amend for the last commit or git rebase -i for an earlier one."
[ -z "$attributed" ] || refuse "these commits carry an assistant's or a vendor's attribution:$attributed. Take the line out of the message (git commit --amend, or git rebase -i), because the history names who answers for a change."

# AN ISSUE NUMBER IS NEVER WRITTEN INTO A COMMENT (the comment rules): it sends the reader to a
# tracker that moves on while the line stays. What the line needs is said in the comment, and the
# issue is named in the commit message. Judged on the lines the push adds, in the two spellings a
# number is written in, a hash and digits in brackets, and a repository's name, a hash and digits;
# a number in code that is no comment is left alone.
numbered=""
while IFS= read -r sha; do
  [ -n "$sha" ] || continue
  added="$(git show --format= --unified=0 --no-color "$sha" -- . ':!*.md' ':!*.json' ':!*.lock' ':!CHANGELOG*' 2>/dev/null || true)"
  hits="$(awk '
    /^\+\+\+ / { file = substr($0, 7); next }
    /^\+/ {
      line = substr($0, 2)
      # the comment is the whole line where it opens one, else what follows a trailing // or /*
      if (line ~ /^[[:space:]]*(#|\*|--|;|\/\/|\/\*|<!--)/) comment = line
      else if (match(line, /[^:]\/\/|\/\*/)) comment = substr(line, RSTART)
      else next
      if (comment ~ /\(#[0-9]+\)|[A-Za-z0-9._-]+#[0-9]+/) print "  " file ": " line
    }' <<< "$added")"
  [ -z "$hits" ] || numbered="$numbered
$hits"
done <<< "$commits"
[ -z "$numbered" ] || refuse "these added comments name an issue by its number:$numbered
  Say in the comment what the line needs, and name the issue in the commit message."

# A MIGRATION THAT REACHED A DATABASE IS NEVER CHANGED (the database rules): the schema moves
# forward through a new migration. One that never left this machine may still change, and the
# commit that changes it says so in a 'Migration: <why>' trailer.
migrated=""
while IFS= read -r sha; do
  [ -n "$sha" ] || continue
  [ -z "$(git log -1 --format='%(trailers:key=Migration,valueonly)' "$sha" | tr -d '[:space:]')" ] || continue
  changed="$(git diff-tree --no-commit-id --root -r --name-only --diff-filter=MDR "$sha" 2>/dev/null || true)"
  hits="$(grep -E '(^|/)migrations/[^/]+\.sql$' <<< "$changed" || true)"
  while IFS= read -r f; do [ -z "$f" ] || migrated="$migrated $f"; done <<< "$hits"
done <<< "$commits"
[ -z "$migrated" ] || refuse "these migrations exist already and are changed or removed:$migrated
  Move the schema forward with a new migration. A migration that never reached a database may change in a commit with a 'Migration: <why>' trailer."

# THE TWO SPELLINGS OF A SCRIPT CHANGE TOGETHER (the harness rules): where x.sh and x.ps1 both stand,
# they are one program, and a push that changes one of them changes the other. Where a fault lives in
# one spelling alone, a commit of the push says so in a 'Twin: <why>' trailer. The Windows entry
# point is no twin: where scripts/check.sh stands, a check.ps1 or build.ps1 is the one text held
# above, which starts the .sh of its own name and never changes with it.
all_changed="$(while IFS= read -r sha; do [ -z "$sha" ] || git diff-tree --no-commit-id --root -r --name-only "$sha"; done <<< "$commits" | LC_ALL=C sort -u)"
twin_excused=0
while IFS= read -r sha; do
  [ -n "$sha" ] || continue
  [ -z "$(git log -1 --format='%(trailers:key=Twin,valueonly)' "$sha" | tr -d '[:space:]')" ] || twin_excused=1
done <<< "$commits"
one_sided=""
if [ "$twin_excused" -eq 0 ]; then
  tree_files="$(git ls-tree -r --name-only "$head" 2>/dev/null || true)"
  while IFS= read -r path; do
    case "$path" in *.sh) other="${path%.sh}.ps1"; ps1="$other" ;; *.ps1) other="${path%.ps1}.sh"; ps1="$path" ;; *) continue ;; esac
    if [ -f "$root/scripts/check.sh" ]; then case "${ps1##*/}" in check.ps1|build.ps1) continue ;; esac; fi
    { grep -qxF -- "$path" <<< "$tree_files" && grep -qxF -- "$other" <<< "$tree_files"; } || continue
    grep -qxF -- "$other" <<< "$all_changed" || one_sided="$one_sided $path (not $other)"
  done <<< "$all_changed"
fi
[ -z "$one_sided" ] || refuse "one spelling of a script changed without the other:$one_sided
  Change both in this push. Where the fault lives in one spelling alone, give a commit a 'Twin: <why>' trailer."

# THE NAMES A PUSH ADDS ARE DERIVED, NOT INVENTED (the naming rules). No list is kept: the
# families are read from the trees themselves. Two things are held against every new directory:
#   - `<a>` beside `<a>-<x>`, or `<a>-<x>` beside `<a>`, names one member of a family and leaves
#     the other unnamed: every member says which side it is on, or none does.
#   - `<owner>-<x>`, where the owner is a repository of this project folder, names a part of that
#     repository, so `<x>` is one of its top-level directories. This is held in a directory that
#     mirrors the repositories, where two or more entries carry a repository's name; elsewhere a
#     name that happens to open with one (post-processing) refers to no repository.
# A repository's owner word is its name after the project prefix (acme-shop: shop), or its whole
# name where it has none. A word that is a top-level directory in two or more repositories is a
# word of structure (docs, deploy, scripts), no repository's name, and is not held. A commit with a
# 'Naming: <why>' trailer keeps the names it adds, and says why to whoever reads it.
naming_findings() {  # one finding per line
  local folder main d name owner parts sha dir seg parent entries base o repo rest
  folder="$(project_folder_of "$root")"
  main="$(cd "$(git -C "$root" rev-parse --path-format=absolute --git-common-dir)/.." && pwd)"
  git -C "$root" ls-tree -d --name-only HEAD > "$TMPD/naming-words" 2>/dev/null
  : > "$TMPD/naming-owners"
  for d in "$folder"/*/; do
    d="${d%/}"; [ -e "$d/.git" ] || continue
    name="${d##*/}"; case "$name" in *-ai-core) continue ;; esac
    [ "$(cd "$d" && pwd)" != "$main" ] || continue
    parts="$(git -C "$d" ls-tree -d --name-only HEAD 2>/dev/null)"
    [ -z "$parts" ] || printf '%s\n' "$parts" >> "$TMPD/naming-words"
    case "$name" in *-*) owner="${name#*-}" ;; *) owner="$name" ;; esac
    printf '%s\t%s\t %s \n' "$owner" "$name" "$(tr '\n' ' ' <<< "$parts")" >> "$TMPD/naming-owners"
  done
  sort "$TMPD/naming-words" | uniq -d > "$TMPD/naming-structure"
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    [ -z "$(git log -1 --format='%(trailers:key=Naming,valueonly)' "$sha" | tr -d '[:space:]')" ] || continue
    git diff-tree --no-commit-id --root -r --name-only --diff-filter=A "$sha" \
      | awk -F/ '{ p = ""; for (i = 1; i < NF; i++) { p = (p == "" ? $i : p "/" $i); print p } }' | sort -u > "$TMPD/naming-dirs"
    while IFS= read -r dir; do
      [ -n "$dir" ] || continue
      git cat-file -e "$sha^:$dir" 2>/dev/null && continue   # it was there before this commit
      seg="${dir##*/}"; parent=""; [ "$seg" = "$dir" ] || parent="${dir%/*}/"
      if [ -n "$parent" ]; then entries="$(git ls-tree -d --name-only "$sha:${parent%/}")"; else entries="$(git ls-tree -d --name-only "$sha")"; fi
      case "$seg" in
        *-*) base="${seg%%-*}"; grep -qxF -- "$base" <<< "$entries" && echo "$parent$base beside $parent$seg: one member of the family says its side, the other does not; name every member, or none" ;;
        *) awk -v s="$seg-" 'index($0, s) == 1' <<< "$entries" | while IFS= read -r o; do echo "$parent$seg beside $parent$o: one member of the family says its side, the other does not; name every member, or none"; done ;;
      esac
      mirrors=0
      while IFS=$'\t' read -r o repo parts; do
        grep -qxF -- "$o" "$TMPD/naming-structure" && continue
        mirrors=$((mirrors + $(awk -v o="$o" '$0 == o || index($0, o "-") == 1 || index($0, o "_") == 1' <<< "$entries" | grep -c .)))
      done < "$TMPD/naming-owners"
      [ "$mirrors" -ge 2 ] || continue
      while IFS=$'\t' read -r o repo parts; do
        case "$seg" in "$o"-?*|"$o"_?*) ;; *) continue ;; esac
        grep -qxF -- "$o" "$TMPD/naming-structure" && continue
        rest="${seg#"$o"}"; rest="${rest#?}"
        case "$parts" in *" $rest "*) ;; *) echo "$dir names a part of the repository $repo, and $repo has no $rest; its parts are$(sed 's/ *$//; s/ \([^ ]\)/, \1/g; s/^,//' <<< "$parts")" ;; esac
      done < "$TMPD/naming-owners"
    done < "$TMPD/naming-dirs"
  done <<< "$commits"
}
findings="$(naming_findings | sort -u)"
if [ -n "$findings" ]; then
  while IFS= read -r line; do echo "pre-push: $line" >&2; done <<< "$findings"
  refuse "the names above are invented where they should be derived from what they belong to. Rename them, or give the commit that adds them a 'Naming: <why>' trailer."
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
  gitleaks_git \
    || refuse "no gitleaks 8.19 or newer (the one with 'gitleaks git') is on this path, and $root/.gitleaks.toml says the commits being pushed are read for credentials. Run ai-core doctor in this repository, which installs it."
  while IFS= read -r scan_range; do
    [ -n "$scan_range" ] || continue
    gitleaks git --no-banner --log-opts="$scan_range" "$root" \
      || refuse 'a credential stands in a commit this push carries. The lines above name the commit, the file and the rule. Take it out of the history - a commit that is pushed cannot be recalled.'
  done <<< "$scan_ranges"
fi

echo 'pre-push: nothing refused this push.'
