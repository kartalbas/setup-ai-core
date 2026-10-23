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
#   1. the pushed commit is the one that is checked out, or, beside the default branch, a commit
#      origin already carries
#   2. every pushed commit names its issue, or says why it does not
#   3. the team modes are installed
#   4. the names of the new directories are derived from the families the trees carry
#   5. the repository's own scripts/check.sh is green, run in a working tree equal to the commit,
#      started once the 1-minute load is below PRE_PUSH_LOAD_LIMIT or PRE_PUSH_LOAD_WAIT_SECONDS is up
#   6. gitleaks over the commits the push carries, in a repository that carries .gitleaks.toml
#
# Run from a terminal, with nothing on standard input, it judges what `git push` would send from
# the current branch: the commits its upstream does not have.
#
#   pre-push.sh                              the gate, as git runs it
#   pre-push.sh --install [--all <folder>]   write the two shims into .githooks/ and arm them
#   pre-push.sh --message <file>             the message rules on one message, as a commit is made
#
set -uo pipefail

# A person's log.showSignature prints signature lines into every formatted git log this gate reads;
# one entry after the caller's own in git's environment configuration turns it off for all of them.
# The repository's own check runs without this entry (with_caller_git_config).
caller_git_config_count="${GIT_CONFIG_COUNT-unset}"
n=${GIT_CONFIG_COUNT:-0}; export "GIT_CONFIG_KEY_$n=log.showSignature" "GIT_CONFIG_VALUE_$n=false" "GIT_CONFIG_COUNT=$((n + 1))"
gate_git_config_index="$n"
with_caller_git_config() (  # with_caller_git_config <command...>
  unset "GIT_CONFIG_KEY_$gate_git_config_index" "GIT_CONFIG_VALUE_$gate_git_config_index"
  if [ "$caller_git_config_count" = unset ]; then
    unset GIT_CONFIG_COUNT
  else
    export GIT_CONFIG_COUNT="$caller_git_config_count"
  fi
  "$@"
)
# On Forgejo, git that the command starts outside the checkout, such as a package manager's fetch, signs in too.
with_sign_in_line() (  # with_sign_in_line <command...>
  [ "$FORGE" != forgejo ] || sign_in_line_export || exit 1
  "$@"
)

for arg in "$@"; do
  if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
    echo "Usage: pre-push.sh [--install [--all <folder>] | --message <file>]"
    echo ""
    echo "The push gate. Git runs it through the repository's .githooks/pre-push shim before a push"
    echo "and it refuses the push, exit 1, when: a pushed commit is not the one checked out (beside the"
    echo "default branch a commit origin already carries passes); a pushed commit names no issue (#<n>),"
    echo "does not open with 'release:', touches more than *.md and"
    echo "LICENSE files, and carries no 'No-issue: <who asked and why>' trailer; a team mode is"
    echo "missing; a file the push adds or changes starts with #! and is"
    echo "not executable; a subject is longer than 72 characters; a message carries an assistant's or a"
    echo "vendor's attribution, or a closing keyword before an issue reference (Fixes #<n>), or its"
    echo "author or committer is an assistant; an author or committer"
    echo "address, a merge's too, differs from git config user.email (none set is refused); an added comment names an"
    echo "issue as (#<n>) or <repo>#<n>; an existing"
    echo "migrations/*.sql is changed or removed (a 'Migration: <why>' trailer allows it);"
    echo "a new directory's name is invented where the families"
    echo "of the trees give it (a 'Naming: <why>' trailer keeps one); the working tree differs from the commit where"
    echo "scripts/check.sh would run, or scripts/check.sh is red; or gitleaks"
    echo "finds a credential in the pushed commits (where .gitleaks.toml exists). The message of a merge is not"
    echo "judged; its addresses are. A deletion runs"
    echo "no checks. Run from a terminal it judges the current branch against its upstream."
    echo ""
    echo "Before scripts/check.sh starts, the gate waits while the 1-minute load average (uptime) is at or"
    echo "above PRE_PUSH_LOAD_LIMIT (24 when unset) in the .ai-core/config.env of the checkout, at most"
    echo "PRE_PUSH_LOAD_WAIT_SECONDS (300 when unset), and then starts the check and says it started above"
    echo "the limit. Both settings are read again at every poll. With both positive, a load that cannot be"
    echo "read refuses the push. With PRE_PUSH_LOAD_LIMIT 0 the wait is off, and with"
    echo "PRE_PUSH_LOAD_WAIT_SECONDS 0 the check starts at once: the load is still measured once for the"
    echo "record, and a reading that fails is said and recorded as -, never as a number."
    echo ""
    echo "With FORGE=forgejo, scripts/check.sh gets credential.<FORGEJO_URL>.helper in git's environment"
    echo "configuration after the caller's entries: an empty value, then 'ai-core git-credential' with the"
    echo "checkout's FORGEJO_URL and FORGEJO_TOKEN_COMMAND set for that helper alone, so git started outside"
    echo "the checkout can sign in to that instance. The check's own environment gets neither setting, and"
    echo "only the command that prints the token is passed. With FORGE=github the check gets nothing added."
    echo ""
    echo "Options:"
    echo "  --install         Write the two shims, .githooks/pre-push (this gate) and .githooks/post-checkout"
    echo "                    (ai-core init in a new worktree), into the current repository and every"
    echo "                    worktree of it, set core.hooksPath to .githooks, commit them on their own"
    echo "                    (No-issue: trailer) and push by ref to the branch checked out, through the"
    echo "                    gate; a worktree gets only the files its own commit lacks, uncommitted,"
    echo "                    and a file an earlier install rewrote there goes back to that commit,"
    echo "                    so its finish-issue finds it clean. An unpushed commit that names no"
    echo "                    issue and touches nothing but .gitignore gets the trailer that says init"
    echo "                    wrote it, so the push goes through. The checkout catches up with its"
    echo "                    origin first; one behind it with work of its own gets nothing"
    echo "  --all <folder>    With --install: every git repository directly under the folder"
    echo "  --message <file>  Judge one commit message by the message rules above (the subject's length,"
    echo "                    an attribution, an assistant as author or committer) while the commit is"
    echo "                    made, where a fault costs no rewrite: init deploys .githooks/commit-msg,"
    echo "                    which runs this. A merge is not judged"
    echo "  --runs            List the runs of the gate recorded on this machine, newest first: the time,"
    echo "                    the repository, the worktree, the commit, the verdict (green, red, or no"
    echo "                    check), the seconds scripts/check.sh took (the wait for a lower load not"
    echo "                    counted), its last line and the load at check start (- where none was"
    echo "                    measured, as in a run recorded before the field existed). Every run of"
    echo "                    the gate appends one, to \${AI_CORE_HOME:-\$HOME}/.ai-core/pre-push-runs.tsv"
    echo "  --repo OWNER/REPO With --runs: the runs of that repository only"
    echo "  --since TIME      With --runs: the runs at or after TIME, in UTC as recorded (2026-10-20T06:00)"
    echo "  -h, --help        Show this help message"
    echo ""
    echo "Examples:"
    echo "  ai-core pre-push"
    echo "  ai-core pre-push --install"
    echo "  ai-core pre-push --install --all ../my-org"
    echo "  ai-core pre-push --runs --repo my-org/my-repo --since 2026-10-20"
    exit 0
  fi
done

CORE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL=0; ALL_DIR=""; MESSAGE_FILE=""; RUNS=0; RUNS_REPO=""; RUNS_SINCE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --install) INSTALL=1 ;;
    --all) shift; [ $# -gt 0 ] || { echo "error: --all needs a folder" >&2; exit 2; }; ALL_DIR="$1" ;;
    --message) shift; [ $# -gt 0 ] || { echo "error: --message needs a file" >&2; exit 2; }; MESSAGE_FILE="$1" ;;
    --runs) RUNS=1 ;;
    --repo) shift; [ $# -gt 0 ] || { echo "error: --repo needs OWNER/REPO" >&2; exit 2; }; RUNS_REPO="$1" ;;
    --since) shift; [ $# -gt 0 ] || { echo "error: --since needs a time" >&2; exit 2; }; RUNS_SINCE="$1" ;;
    -*) echo "error: unknown option '$1' (see --help)" >&2; exit 2 ;;
    *) # git hands the hook the remote's name and URL; they are not needed here
       [ "$INSTALL" -eq 0 ] || { echo "error: unexpected argument '$1' (see --help)" >&2; exit 2; } ;;
  esac
  shift
done
[ -z "$ALL_DIR" ] || [ "$INSTALL" -eq 1 ] || { echo "error: --all goes with --install" >&2; exit 2; }
[ -z "$MESSAGE_FILE" ] || [ "$INSTALL" -eq 0 ] || { echo "error: --message does not go with --install" >&2; exit 2; }
[ "$RUNS" -eq 1 ] || [ -z "$RUNS_REPO$RUNS_SINCE" ] || { echo "error: --repo and --since go with --runs" >&2; exit 2; }
GATE_RUNS_FILE="${AI_CORE_HOME:-$HOME}/.ai-core/pre-push-runs.tsv"
GATE_RUNS_HEADER=$'time\trepository\tworktree\tcommit\tverdict\tseconds\tlast line\tload at check start'
if [ "$RUNS" -eq 1 ]; then
  [ -s "$GATE_RUNS_FILE" ] || { echo "no run of the gate is recorded on this machine yet ($GATE_RUNS_FILE)"; exit 0; }
  echo "$GATE_RUNS_HEADER"
  # A row of seven fields was recorded before the load field existed: its load was not measured
  tail -n +2 "$GATE_RUNS_FILE" \
    | awk -F'\t' -v repo="$RUNS_REPO" -v since="$RUNS_SINCE" '(repo == "" || tolower($2) == tolower(repo)) && (since == "" || $1 >= since) { kept[++n] = (NF == 7 ? $0 "\t-" : $0) } END { while (n > 0) print kept[n--] }'
  exit 0
fi

. "$CORE_ROOT/lib/layers.sh"
GATE_REFUSAL=""
refuse() { GATE_REFUSAL="$(printf '%s\n' "$*" | head -1)"; echo "pre-push: REFUSED — $*" >&2; exit 1; }

# An assistant's or a vendor's attribution in a message (a trailer, or a line that says an assistant wrote,
# made or built the commit), and an assistant as author or committer
# ("Name <address>" per line): the commit rules, judged on every pushed commit below and on one
# message by --message.
ATTRIBUTION_PATTERN='^co-authored-by:.*(claude|codex|gemini|copilot|chatgpt|anthropic|openai)|generated (with|by) \[?(claude|codex|gemini|copilot|chatgpt)|^(written|made|built|authored|created|drafted|generated|produced|committed)[[:space:]]+(by|with|on|using|in|through)[[:space:]]+([^[:space:]]+[[:space:]]+){0,4}(claude|codex|gemini|copilot|chatgpt|anthropic|openai)([^a-z]|$)'
# A closing keyword before an issue reference closes that issue on the forge when the commit reaches
# the default branch, before any release carries it; GitHub and Forgejo both document these nine
# (docs.github.com, "Linking a pull request to an issue"; forgejo.org/docs, "Linked references").
CLOSING_PATTERN='(^|[^A-Za-z0-9_-])(close[sd]?|fix(e[sd])?|resolve[sd]?):?[[:space:]]+(([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#[0-9]+|https?://[^[:space:]]+/issues/[0-9]+)'
ASSISTANT_IDENTITY_PATTERN='@(anthropic|openai)\.com>$|(claude|codex|copilot|chatgpt|gemini)[a-z-]*\[bot\]@users\.noreply\.github\.com>$|^(claude|claude code|codex|copilot|chatgpt|gemini) <'

# --- --message: the message rules while the commit is made -----------------------------------
# Git runs .githooks/commit-msg with the file that holds the message, and a refusal leaves no
# commit behind. At the push the same fault needs a rewrite of history, which an agent's safety
# check refuses without its owner's word. A merge is not judged, as the gate does not judge one:
# its subject is git's own.
if [ -n "$MESSAGE_FILE" ]; then
  git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 && exit 0
  [ -f "$MESSAGE_FILE" ] || { echo "error: there is no message file '$MESSAGE_FILE'" >&2; exit 2; }
  # Git cleans the message after this hook and does not tell it how: an editor run strips the
  # comment lines and cuts at the scissors line of -v, while -m and -F keep every line, a subject
  # such as "#8 Fix" included. A fault is refused only where git records it either way; where the
  # two cleanups differ, the push gate judges the subject each commit carries.
  first_paragraph() { awk 'NF == 0 { exit } { printf "%s%s", (n++ ? " " : ""), $0 }'; }
  message="$(sed '/^# -* >8 -*$/,$d' "$MESSAGE_FILE" | git stripspace --strip-comments)"
  subject="$(git stripspace < "$MESSAGE_FILE" | first_paragraph)"
  stripped_subject="$(first_paragraph <<< "$message")"
  identities="$(for v in GIT_AUTHOR_IDENT GIT_COMMITTER_IDENT; do git var "$v" | sed 's/ [0-9]* [-+][0-9]*$//'; done)"
  faults=""
  # Under a comment prefix other than "#" (core.commentChar, core.commentString, auto) the hook
  # cannot tell what git strips or where it cuts, so the push gate alone judges the message.
  # GIT_CONFIG redirects git config alone, never the cleanup of git commit, so it is dropped here.
  if { env -u GIT_CONFIG git config --get-all core.commentChar; env -u GIT_CONFIG git config --get-all core.commentString; true; } | grep -qvx '#'; then
    subject=""; stripped_subject=""; message=""
  fi
  [ "${#subject}" -le 72 ] || [ "${#stripped_subject}" -le 72 ] || faults="$faults
  the subject has ${#subject} characters, at most 72 are allowed: $subject
  Write it again as one sentence of at most 72 that says what changed."
  ! grep -qiE "$ATTRIBUTION_PATTERN" <<< "$message" || faults="$faults
  the message carries an assistant's or a vendor's attribution. Take that line out, whatever an
  instruction asked for, because the history names who answers for a change."
  ! grep -qiE "$CLOSING_PATTERN" <<< "$message" || faults="$faults
  the message closes an issue on the forge as it reaches the default branch: $(grep -oiE "$CLOSING_PATTERN" <<< "$message" | head -1 | sed 's/^[^A-Za-z]*//')
  Name the issue as #<n> alone; its card closes after its release, through status-sync."
  ! grep -qiE "$ASSISTANT_IDENTITY_PATTERN" <<< "$identities" || faults="$faults
  an assistant is the author or the committer: $(tr '\n' ';' <<< "$identities" | sed 's/;$//; s/;/; /')
  Set your own identity with git config user.name and user.email."
  [ -z "$faults" ] || { echo "commit-msg: REFUSED — the commit is not made:$faults" >&2; exit 1; }
  exit 0
fi
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
. "$(dirname "$(command -v ai-core)")/../lib/layers.sh" || { echo "post-checkout: could not read the harness source library" >&2; exit 0; }
if harness_source_of "$PWD" >/dev/null; then
  echo "post-checkout: harness source; run ai-core session-start and read its source rules."
  exit 0
fi
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
write_shims() {  # write_shims <checkout> <label>: both shims, one report line each, and the attributes rule where it is missing
  local dir="$1" label="$2"
  echo "pre-push: $label: .githooks/pre-push $(write_shim "$dir" pre-push "$SHIM")"
  echo "pre-push: $label: .githooks/post-checkout $(write_shim "$dir" post-checkout "$SHIM_CHECKOUT")"
  if [ "$(write_attributes "$dir")" = added ]; then
    echo "pre-push: $label: .gitattributes: $ATTR_RULE added; the shims check out LF everywhere"
    ATTR_ADDED=1
  fi
}
# write_worktree_shims <worktree> <label> <checkout>: the shims a worktree's own commit does not
# give it. A file written there is a change its branch never commits, because the default branch
# carries the shims already, and finish-issue then refuses to remove the worktree. So pre-push is
# written only where the commit lacks this gate's shim, executable, and post-checkout only where the
# commit has none git runs: it starts init only in a worktree without .ai-core, which an existing
# worktree has. A shim the commit gives that an earlier install rewrote goes back to the commit.
write_worktree_shims() {
  local tree="$1" label="$2" dir="$3" hook text path mode written=0
  for hook in pre-push post-checkout; do
    path=".githooks/$hook"; text="$SHIM"; [ "$hook" = pre-push ] || text="$SHIM_CHECKOUT"
    mode="$(git -C "$tree" ls-tree HEAD -- "$path" | awk '{ print $1 }')"
    if [ "$mode" != 100755 ] || { [ "$hook" = pre-push ] && [ "$(git -C "$tree" show "HEAD:$path" | tr -d '\r')" != "$(printf '%s' "$text")" ]; }; then
      echo "pre-push: $label: $path $(write_shim "$tree" "$hook" "$text"); it goes out with that worktree's own commit"
      written=1
    else
      put_back_own_write "$tree" "$label" "$dir" "$path" "$text"
    fi
  done
  if [ "$written" -eq 1 ] && [ "$(write_attributes "$tree")" = added ]; then
    echo "pre-push: $label: .gitattributes: $ATTR_RULE added; the shims check out LF everywhere; it goes out with that worktree's own commit"
  fi
}
# put_back_own_write <worktree> <label> <checkout> <path> <text>: a shim the worktree's commit gives,
# changed on disk to the text this run writes or to the one the checkout carries, is an earlier
# install's own write: it goes back to the commit. Any other change is somebody's and stays.
put_back_own_write() {
  local tree="$1" label="$2" dir="$3" path="$4" text="$5" carried
  git -C "$tree" diff --quiet HEAD -- "$path" 2>/dev/null && return 0
  carried="$(git -C "$dir" rev-parse -q --verify "HEAD:$path" 2>/dev/null || true)"
  if [ -f "$tree/$path" ] && { [ "$(tr -d '\r' < "$tree/$path")" = "$(printf '%s' "$text")" ] \
    || { [ -n "$carried" ] && [ "$(git -C "$tree" hash-object -- "$path")" = "$carried" ]; }; }; then
    # without hooks: a checkout of a path starts post-checkout, which has nothing to do here
    if git -C "$tree" -c core.hooksPath=/dev/null checkout -q HEAD -- "$path"; then
      echo "pre-push: $label: $path was an earlier install's write; put back to that worktree's own commit"
    else
      echo "pre-push: $label: $path was an earlier install's write and could not be put back (see above); it stays" >&2
    fi
  else
    echo "pre-push: $label: $path holds a change that is not ai-core's; it stays"
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
# `git commit -- <path>` reads the path from the working tree, whose file may lack the executable bit.
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
  local dir="$1" label="$2" branch committed=""
  local paths=("${SHIM_PATHS[@]}"); [ "$ATTR_ADDED" -eq 0 ] || paths+=(.gitattributes)
  # a commit whose shims lack the executable bit (a copy that drops the file modes writes them so) is
  # one git skips them in: it gets a commit of its own as well
  if git -C "$dir" ls-files --error-unmatch "${paths[@]}" >/dev/null 2>&1 && git -C "$dir" diff --quiet HEAD -- "${paths[@]}" 2>/dev/null \
    && [ -z "$(git -C "$dir" ls-tree HEAD -- "${SHIM_PATHS[@]}" | awk '$1 != "100755"')" ]; then :; else
    commit_only "$dir" 'the hooks of ai-core: the push gate, init in a new worktree' 'No-issue: written, committed and pushed by ai-core pre-push --install' "${paths[@]}" \
      || { echo "pre-push: $label: the commit failed (see above); the shims are written" >&2; return 1; }
    committed=yes
    echo "pre-push: $label: committed $(git -C "$dir" rev-parse --short HEAD)"
  fi
  git -C "$dir" remote get-url origin >/dev/null 2>&1 || { echo "pre-push: $label: no origin; not pushed"; return 0; }
  branch="$(git -C "$dir" symbolic-ref --short -q HEAD)"
  if git -C "$dir" rev-parse -q --verify "origin/$branch" >/dev/null 2>&1 && [ "$(git -C "$dir" rev-list --count "origin/$branch..HEAD")" -eq 0 ]; then echo "pre-push: $label: nothing to push"; return 0; fi
  excuse_gitignore_commits "$dir" "$label" "$branch" || return 1
  # The commit of this run, read before the push: the rewording above gives it a new id, and a
  # session that commits in this checkout while the gate runs moves HEAD past it
  local ours=""; [ -z "$committed" ] || ours="$(git -C "$dir" rev-parse HEAD)"
  if git -C "$dir" push --quiet origin "HEAD:$branch"; then echo "pre-push: $label: pushed to origin/$branch"; return 0; fi
  [ -n "$ours" ] || { echo "pre-push: $label: the push was refused or failed (see above); the commit stays" >&2; return 1; }
  push_again_or_undo "$dir" "$label" "$branch" "$ours"
}
# push_again_or_undo <repository> <label> <branch> <the commit of this run>: a refused push leaves
# no commit of this run on the branch, because a commit the origin lacks makes every release that
# wants the checkout level with its origin refuse. Where the origin moved on while the gate ran and
# this commit is the only one it lacks, the commit goes on top of the origin and is pushed once
# more; otherwise, or when that fails as well, the commit is undone and the hooks are as they were.
push_again_or_undo() {
  local dir="$1" label="$2" branch="$3" ours="$4" upstream
  if [ "$(git -C "$dir" rev-parse HEAD)" = "$ours" ] && git -C "$dir" fetch --quiet origin "$branch" 2>/dev/null \
    && upstream="$(git -C "$dir" rev-parse FETCH_HEAD)" \
    && ! git -C "$dir" merge-base --is-ancestor "$upstream" HEAD \
    && [ "$(git -C "$dir" rev-list --count "$upstream..HEAD")" -eq 1 ]; then
    # Without autostash, so a tree with a person's change refuses instead of being merged into, and
    # without hooks, because post-checkout would start an init this rebase has no use for
    if git -C "$dir" -c core.hooksPath=/dev/null rebase --quiet --no-autostash "$upstream" >/dev/null 2>&1; then
      if [ "$(git -C "$dir" rev-list --count "$upstream..HEAD")" -eq 0 ]; then
        echo "pre-push: $label: the origin moved on during the push and carries these hooks already; nothing to push"
        return 0
      fi
      ours="$(git -C "$dir" rev-parse HEAD)"
      if git -C "$dir" push --quiet origin "HEAD:$branch"; then
        echo "pre-push: $label: the origin moved on during the push; the commit went on top of it and was pushed to origin/$branch"
        return 0
      fi
    else
      git -C "$dir" -c core.hooksPath=/dev/null rebase --abort >/dev/null 2>&1
    fi
  fi
  if [ "$(git -C "$dir" rev-parse HEAD)" = "$ours" ] && git -C "$dir" reset --quiet --keep HEAD~1 >/dev/null 2>&1; then
    echo "pre-push: $label: the push was refused (see above), so its commit is undone and the hooks are as they were; run ai-core pre-push --install here again once a push can go" >&2
  else
    echo "pre-push: $label: the push was refused (see above), and its commit could not be undone; it stays on $branch" >&2
  fi
  return 1
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
  # The checkout commits and pushes them; a worktree is somebody's issue and gets only the files its
  # own commit does not give it.
  ATTR_ADDED=0
  write_shims "$dir" "$name"
  while IFS= read -r tree; do
    tree="${tree#worktree }"
    [ -n "$tree" ] && [ "$tree" != "$(cd "$dir" && pwd)" ] && [ "$tree" != "$(cd "$dir" && pwd -W 2>/dev/null)" ] || continue
    [ -d "$tree" ] || continue
    # a published copy (init links it beside the worktrees as the neighbour) is nobody's work: a shim
    # written there would be a change in it, and init then holds it on an old commit
    case "$tree" in */.ai-core/neighbours/*|*/.worktrees/*/origin-*) continue ;; esac
    write_worktree_shims "$tree" "$name (worktree $(basename "$tree"))" "$dir"
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

# EVERY RUN OF THE GATE LEAVES ONE RECORD on this machine, because what a push checked is printed
# only in the terminal of whoever pushed: pre-push --runs reads them back.
GATE_CHECK=absent; GATE_CHECK_SECONDS=-; GATE_CHECK_LAST=""; GATE_COMMIT=""; GATE_LOAD=-
# write_gate_run <row>: a new log is made whole, header and first row, and linked into place, so two
# gates that both find none cannot both write a header; a log that exists, whatever header it carries,
# only gets the row, appended in one write. Where the new log cannot be linked into place and none stands
# there afterwards, the run is not recorded: the status is 1, and no second way writes a header.
write_gate_run() {
  local row="$1" made linked
  if [ ! -e "$GATE_RUNS_FILE" ]; then
    made="$(mktemp "$GATE_RUNS_FILE.XXXXXX")" || return 1
    printf '%s\n%s\n' "$GATE_RUNS_HEADER" "$row" > "$made" && ln "$made" "$GATE_RUNS_FILE" 2>/dev/null
    linked=$?
    rm -f "$made"
    [ "$linked" -ne 0 ] || return 0
    [ -e "$GATE_RUNS_FILE" ] || return 1
  fi
  printf '%s\n' "$row" >> "$GATE_RUNS_FILE"
}
record_gate_run() {
  local rc=$? verdict repository last
  if [ "$rc" -ne 0 ]; then verdict=red; elif [ "$GATE_CHECK" = green ]; then verdict=green; else verdict="no check"; fi
  # A red check names its own last line; a refusal after a green check, or with none, names itself
  last="$GATE_CHECK_LAST"; [ "$GATE_CHECK" = red ] || [ -z "$GATE_REFUSAL" ] || last="$GATE_REFUSAL"
  repository="$(git -C "$root" remote get-url origin 2>/dev/null | sed 's#\.git$##; s#.*[:/]\([^/:]*/[^/:]*\)$#\1#')"
  if mkdir -p "$(dirname "$GATE_RUNS_FILE")" 2>/dev/null; then
    write_gate_run "$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${repository:--}" "$root" "${GATE_COMMIT:-$head}" \
      "$verdict" "$GATE_CHECK_SECONDS" "$(printf '%s' "$last" | tr '\t\n' '  ')" "$GATE_LOAD")" \
      || echo "pre-push: this run could not be recorded in $GATE_RUNS_FILE" >&2
  else
    echo "pre-push: this run could not be recorded: no folder $(dirname "$GATE_RUNS_FILE")" >&2
  fi
  rm -rf "$TMPD"
}
trap record_gate_run EXIT

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

# A checkout keeps no record of origin's tags, and its own tags need not be origin's, so the
# commits origin carries under a tag are read from origin: once per push, as the commit each
# tag line names (a peeled line names the commit of an annotated tag). One cat-file keeps the
# objects this checkout has that are commits, so a tag object, whose peeled line follows it, and a
# commit this checkout lacks are skipped. Each one becomes ^<sha> in every range, before the --not
# that flips the meaning of what follows it. The ask neither prompts for a password nor waits on a
# stalled transfer; when origin cannot be asked, nothing more is left out than the branches of
# origin leave out.
tagged_lines="$(GIT_TERMINAL_PROMPT=0 git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=10 ls-remote --tags origin 2>/dev/null)" || tagged_lines=''
tag_exclusions=''
[ -z "$tagged_lines" ] || tag_exclusions="$(cut -f1 <<< "$tagged_lines" | git cat-file --batch-check='%(objectname) %(objecttype)' \
  | awk '$2 == "commit" { printf " ^%s", $1 }')"

# Every commit this push sends, across every ref on standard input, and the ranges they came from.
commits=''
scan_ranges=''
# Whether the push adds any commit at all, a merge among them. The message rules judge the commits
# that are not merges, but a merge of commits the remote has is a tree nobody has checked yet.
adds=0
pushing=0
landing=''   # the commit a push to the default branch lands, judged below where that branch goes live
while read -r local_ref local_sha remote_ref remote_sha; do
  [ -n "${local_sha:-}" ] || continue
  all_zero "$local_sha" && continue                   # a deletion sends no commit
  GATE_COMMIT="$local_sha"
  pushing=1
  # WHAT IS PUSHED IS RESOLVED TO A COMMIT FIRST. An annotated tag hands its own object's sha
  # here, never the commit it names, so comparing it to HEAD unresolved refuses every annotated
  # tag there is. Resolving it asks the question the refusal below means to ask: is the tree this
  # ref names the tree the checks read.
  local_commit="$(git rev-parse --quiet --verify "${local_sha}^{commit}" 2>/dev/null)" && is_commit=1 \
    || { local_commit="$local_sha"; is_commit=0; }
  if all_zero "${remote_sha:-}"; then
    # An all-zero remote sha is a ref the remote does not have yet, so there is no "before" to
    # compare with. Reading that as "everything reachable" judges the whole history - every commit
    # already published, by whatever rule held when it was written. A TAG is exactly that case: it
    # names a commit the branch already carries, so what it introduces is nothing at all.
    # Excluding every remote branch this checkout knows and every tag origin carries asks the
    # question this loop means to ask - which commits does this push add - and answers it with
    # none where none are added.
    range="$local_commit$tag_exclusions --not --remotes=origin"
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
    # What the remote carries on ANY branch or tag is published already. A branch that merged the default
    # branch brings every commit the default branch gained since the fork; judging those again
    # holds commits other flows wrote to today's rules, and the branch could only catch up by a
    # rebase and a force push.
    range="$local_commit ^$remote_sha$tag_exclusions --not --remotes=origin"
  fi
  # Work is pushed by ref (`git push origin HEAD:<branch>`). A local sha that is not HEAD means
  # the tree the checks are about to run in is not the tree being sent. Only a ref beside the
  # default branch may name another commit, and only one that origin already carries: such a push
  # sends no commit, as when a release is put on a stage by its deploy ref from a checkout that has
  # moved on. A tree or a blob pushed as a ref is no commit, and git lists nothing for it.
  [ "$local_commit" = "$head" ] \
    || { [ "$is_commit" = 1 ] && [ "$remote_ref" != "refs/heads/$default" ] && [ -z "$(git rev-list -n1 $range)" ]; } \
    || refuse "$local_ref is not what is checked out - push what you have: git push origin HEAD:${remote_ref#refs/heads/}"
  # Git runs the hook for a push that moves nothing too, so a default branch equal to origin's lands nothing.
  [ "$remote_ref" != "refs/heads/$default" ] || [ "$local_commit" = "${remote_sha:-}" ] || landing="$local_commit"
  commits="$commits$(git rev-list --no-merges $range)"$'\n'
  [ -z "$(git rev-list -n1 $range)" ] || adds=1
  scan_ranges="$scan_ranges$range"$'\n'
done <<< "$input"

# Nothing to send, or nothing but deletions: there is nothing to judge and nothing to test.
# A push that moves the default branch is never nothing: a branch pushed for review before it
# lands has every commit on origin already, yet the default branch takes a tree now, and below it
# is tested and, where that branch goes live, judged.
[ "$pushing" -eq 1 ] || exit 0
commits="$(grep -v '^$' <<< "$commits" || true)"
if [ -z "$commits" ] && [ "$adds" -eq 0 ] && [ -z "$landing" ]; then
  echo 'pre-push: nothing new to send.'
  exit 0
fi

# A DEFAULT BRANCH THAT GOES LIVE (the owner's rule). Where the repository's .ai-core/config.env
# names it in DEFAULT_BRANCH_IS_LIVE (its folder name, as the harness-wide config.env lists the
# repositories, or "yes"), a controller or a job deploys that branch, so landing on it is
# deploying. Such a landing needs the repository's own checks, because the gate's would be all that
# tests what goes live, and its last commit names who reviewed the change in a 'Reviewed-by:' trailer.
live="$(grep -E '^[[:space:]]*DEFAULT_BRANCH_IS_LIVE[[:space:]]*=' "$root/.ai-core/config.env" 2>/dev/null | tail -n1 || true)"
live="${live#*=}"; live="${live%%#*}"; live="${live//[\"\',]/ }"
repo_name="$(basename "$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's|/\.git$||')")"
case " $(tr -s '[:space:]' ' ' <<< "$live") " in *" yes "*|*" $repo_name "*) live=yes ;; *) live=no ;; esac
if [ -n "$landing" ] && [ "$live" = yes ]; then
  [ -f "$root/scripts/check.sh" ] \
    || refuse "$default of this repository goes live, and it has no scripts/check.sh, so nothing would test what goes live. Add the checks first; until then the owner lands here."
  [ -n "$(git log -1 --format='%(trailers:key=Reviewed-by,valueonly)' "$landing" | tr -d '[:space:]')" ] \
    || refuse "$default of this repository goes live, so the last commit of the push names who reviewed the change: git commit --amend --trailer 'Reviewed-by: <reviewer>', then push again."
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

# A FILE THAT STARTS WITH #! IS RUN BY ITS NAME, so it carries the executable bit: without it
# ./release/release.sh fails and git skips a hook in .githooks. A tool that writes files (an agent's,
# a copy made through an API) leaves the bit off, and git keeps what it was given. Judged on what the
# push adds or changes, as the commit checked out has it; a file the push does not touch is left alone.
modeless=""
while IFS= read -r path; do
  [ -n "$path" ] || continue
  [ "$(git ls-tree "$head" -- "$path" | cut -d' ' -f1)" = 100644 ] || continue
  [ "$(git cat-file -p "$head:$path" 2>/dev/null | head -c 2 | tr -d '\0' || true)" = '#!' ] || continue
  modeless="$modeless $path"
done < <(while IFS= read -r sha; do [ -z "$sha" ] || git diff-tree --no-commit-id --root -r --name-only --diff-filter=AMR "$sha"; done <<< "$commits" | sort -u)
[ -z "$modeless" ] || refuse "these files start with #! and are not executable, so running them by name fails and git skips a hook among them:$modeless. Set the bit and commit it: git update-index --chmod=+x$modeless"

# THE COMMIT MESSAGES (the commit rules). A subject is at most 72 characters, because the log, the
# tracker and every list view cut a longer one and the rest is lost where it is read; and no
# message carries an assistant's or a vendor's attribution, because the history names who answers
# for a change, and a tool cannot. For the same reason no author or committer is an assistant: a
# vendor's address, an assistant's GitHub bot, or a name that is only an assistant's, which is the
# identity a cloud session commits under unless the person sets their own. The assistant check
# names that reason when the configured identity is itself an assistant's; it does not replace the
# check below it, which holds every pushed commit, a merge too, to the one address the person
# pushing it set as their git identity: a commit made under a repository-local override, in another
# environment or by another tool would otherwise name somebody who does not answer for it. Each
# message is read whole before it is searched.
long=""; attributed=""; closing=""; assistant_identities=""
while IFS= read -r sha; do
  [ -n "$sha" ] || continue
  subject="$(git log -1 --format=%s "$sha")"
  [ "${#subject}" -le 72 ] || long="$long
  $(git log -1 --format=%h "$sha") has ${#subject} characters: $subject"
  message="$(git log -1 --format=%B "$sha")"
  if grep -qiE "$ATTRIBUTION_PATTERN" <<< "$message"; then
    attributed="$attributed $(git log -1 --format=%h "$sha")"
  fi
  if grep -qiE "$CLOSING_PATTERN" <<< "$message"; then
    closing="$closing
  $(git log -1 --format=%h "$sha"): $(grep -oiE "$CLOSING_PATTERN" <<< "$message" | head -1 | sed 's/^[^A-Za-z]*//')"
  fi
  if git log -1 --format='%an <%ae>%n%cn <%ce>' "$sha" \
      | grep -qiE "$ASSISTANT_IDENTITY_PATTERN"; then
    assistant_identities="$assistant_identities
  $(git log -1 --format='%h author %an <%ae>, committer %cn <%ce>' "$sha")"
  fi
done <<< "$commits"
[ -z "$long" ] || refuse "these subjects are longer than 72 characters:$long
  Shorten each to one sentence of at most 72 that says what changed, with git commit --amend for the last commit or git rebase -i for an earlier one."
[ -z "$attributed" ] || refuse "these commits carry an assistant's or a vendor's attribution:$attributed. Take the line out of the message (git commit --amend, or git rebase -i), because the history names who answers for a change."
[ -z "$closing" ] || refuse "these messages close an issue on the forge as they reach the default branch, before any release carries the work:$closing
  Name the issue as #<n> alone (git commit --amend, or git rebase -i); its card closes after its release, through status-sync."
[ -z "$assistant_identities" ] || refuse "these commits name an assistant as author or committer:$assistant_identities
  Set your own identity (git config user.name and user.email), then rewrite them under it: git commit --amend --reset-author --no-edit for the last commit, or git rebase --exec 'git commit --amend --reset-author --no-edit' origin/$default for all of them."

# Every commit this push sends, a merge among them, carries as author and committer the address
# that git config user.email holds in this repository, compared without regard to case. Only the
# ranges of this push are read, so a commit on a ref of origin this clone knows, another person's
# or a platform's, never refuses a push; one origin has and this clone has not fetched is read as
# new, which the refusal says.
pushed="$(while IFS= read -r scan_range; do
  [ -n "$scan_range" ] || continue
  read -ra range_words <<< "$scan_range"
  git rev-list "${range_words[@]}"
done <<< "$scan_ranges" | awk '!seen[$0]++')"
if [ -n "$pushed" ]; then
  pusher_email="$(git config user.email || true)"
  [ -n "$pusher_email" ] \
    || refuse "git holds no user.email, so the commits being pushed cannot be matched to the person pushing them. Set your own address: git config --global user.email <your address> (git config user.email inside this repository sets it for this repository alone)."
  foreign="$(git log --no-walk=unsorted --stdin --format='%h%x09%ae%x09%ce' <<< "$pushed" \
    | awk -F'\t' -v want="$pusher_email" 'BEGIN { want = tolower(want) } tolower($2) != want || tolower($3) != want { printf "\n  %s author <%s>, committer <%s>", $1, $2, $3 }')"
  [ -z "$foreign" ] || refuse "these commits carry another address than yours, $pusher_email, the one git config user.email holds:$foreign
  A commit of somebody else that origin carries and this clone has not fetched yet is listed too: git fetch origin, then push again. Every pushed commit names the person who pushes it, because the history names who answers for a change, so rewrite your own commits under your identity, never another person's: git commit --amend --reset-author --no-edit for the last commit, or git rebase --exec 'git commit --amend --reset-author --no-edit' origin/$default for all of them."
fi

# AN ISSUE NUMBER IS NEVER WRITTEN INTO A COMMENT (the comment rules): it sends the reader to a
# tracker that moves on while the line stays. What the line needs is said in the comment, and the
# issue is named in the commit message. Judged on the lines the push adds, in the two spellings a
# number is written in, a hash and digits in brackets, and a repository's name, a hash and digits;
# a number in code that is no comment is left alone. A line counts only while it stands in the tree
# the push leaves, so a later commit of the same push that takes it out clears it, and nothing has
# to be rewritten.
numbered=""
while IFS= read -r sha; do
  [ -n "$sha" ] || continue
  added="$(git show --format= --unified=0 --no-color "$sha" -- . ':!*.md' ':!*.json' ':!*.lock' ':!CHANGELOG*' 2>/dev/null | tr -d '\0' || true)"
  hits="$(awk '
    # git ends a name that holds a space with a tab, which would join the line read after it
    /^\+\+\+ / { file = substr($0, 7); sub(/\t$/, "", file); next }
    /^\+/ {
      line = substr($0, 2)
      # the comment is the whole line where it opens one, else what follows a trailing // or /*
      if (line ~ /^[[:space:]]*(#|\*|--|;|\/\/|\/\*|<!--)/) comment = line
      else if (match(line, /[^:]\/\/|\/\*/)) comment = substr(line, RSTART)
      else next
      if (comment ~ /\(#[0-9]+\)|[A-Za-z0-9._-]+#[0-9]+/) print file "\t" line
    }' <<< "$added")"
  # split on the first tab only: a tab-indented line keeps its indent, and the tree is asked for
  # the line in any file, so a later rename keeps it standing and a quoted path asks nothing wrong
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    file="${hit%%$'\t'*}"; line="${hit#*$'\t'}"
    standing="$(git grep -h -I -F -e "$line" "$head" -- . ':!*.md' ':!*.json' ':!*.lock' ':!CHANGELOG*' 2>/dev/null)"
    grep -qxF -- "$line" <<< "$standing" || continue
    numbered="$numbered
  $file: $line"
  done <<< "$hits"
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

# The findings of one directory in one tree, as words to compare: `family <a> <b>` where <a>
# stands beside <b> and only one of the two says its side, `part <repository> <x>` where the name
# claims a part <x> that repository lacks.
dir_findings() {  # <tree-ish> <dir>
  local seg entries base o repo parts rest mirrors=0
  seg="${2##*/}"
  if [ "$seg" = "$2" ]; then entries="$(git ls-tree -z -d --name-only "$1" | tr '\0' '\n')"; else entries="$(git ls-tree -z -d --name-only "$1:${2%/*}" | tr '\0' '\n')"; fi
  case "$seg" in
    *-*) base="${seg%%-*}"; if grep -qxF -- "$base" <<< "$entries"; then printf 'family\t%s\t%s\n' "$base" "$seg"; fi ;;
    *) awk -v s="$seg-" 'index($0, s) == 1' <<< "$entries" | while IFS= read -r o; do printf 'family\t%s\t%s\n' "$seg" "$o"; done ;;
  esac
  while IFS=$'\t' read -r o repo parts; do
    grep -qxF -- "$o" "$TMPD/naming-structure" && continue
    mirrors=$((mirrors + $(awk -v o="$o" '$0 == o || index($0, o "-") == 1 || index($0, o "_") == 1' <<< "$entries" | grep -c .)))
  done < "$TMPD/naming-owners"
  [ "$mirrors" -ge 2 ] || return 0
  while IFS=$'\t' read -r o repo parts; do
    case "$seg" in "$o"-?*|"$o"_?*) ;; *) continue ;; esac
    grep -qxF -- "$o" "$TMPD/naming-structure" && continue
    rest="${seg#"$o"}"; rest="${rest#?}"
    case "$parts" in *" $rest "*) ;; *) printf 'part\t%s\t%s\n' "$repo" "$rest" ;; esac
  done < "$TMPD/naming-owners"
  return 0
}

# Where a rename of this commit brought a directory from under the name it has: the old path of the
# directory itself, or of the nearest folder above it that moved, with the directory below it; or
# nothing. It counts only where the directory is new, its old path stood before and is gone now,
# so a folder that only some files left, or one that was there already, has moved nowhere. git
# pairs files by their content, so a folder above can name the move where the files inside it
# were paired across.
moved_from() {  # <sha> <dir>
  local p="$2" q s
  git cat-file -e "$1^:$2" 2>/dev/null && return 0
  while :; do
    while IFS= read -r q; do
      [ -n "$q" ] || continue
      s="$q${2#"$p"}"
      [ "${s##*/}" = "${2##*/}" ] || continue
      if git cat-file -e "$1^:$s" 2>/dev/null && ! git cat-file -e "$1:$s" 2>/dev/null; then echo "$s"; return 0; fi
    done <<< "$(awk -F'\t' -v p="$p" '$1 == p { print $2 }' "$TMPD/naming-moves")"
    case "$p" in */*) p="${p%/*}" ;; *) return 0 ;; esac
  done
}

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
  local folder main d name owner parts sha dir seg parent found from before kept line other
  local kind a b
  folder="$(project_folder_of "$root")"
  main="$(cd "$(git -C "$root" rev-parse --path-format=absolute --git-common-dir)/.." && pwd)"
  git -C "$root" ls-tree -z -d --name-only HEAD 2>/dev/null | tr '\0' '\n' > "$TMPD/naming-words"
  : > "$TMPD/naming-owners"
  for d in "$folder"/*/; do
    d="${d%/}"; [ -e "$d/.git" ] || continue
    name="${d##*/}"; case "$name" in *-ai-core) continue ;; esac
    [ "$(cd "$d" && pwd)" != "$main" ] || continue
    parts="$(git -C "$d" ls-tree -z -d --name-only HEAD 2>/dev/null | tr '\0' '\n')"
    [ -z "$parts" ] || printf '%s\n' "$parts" >> "$TMPD/naming-words"
    case "$name" in *-*) owner="${name#*-}" ;; *) owner="$name" ;; esac
    printf '%s\t%s\t %s \n' "$owner" "$name" "$(tr '\n' ' ' <<< "$parts")" >> "$TMPD/naming-owners"
  done
  sort "$TMPD/naming-words" | uniq -d > "$TMPD/naming-structure"
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    [ -z "$(git log -1 --format='%(trailers:key=Naming,valueonly)' "$sha" | tr -d '[:space:]')" ] || continue
    # -z hands every name over as git stores it, never quoted. A known limit: a name that holds a line
    # break still splits in two and goes unchecked, and one that holds a tab pairs no rename; read
    # NUL-separated to the end if one appears
    git diff-tree -z --no-commit-id --root -r --name-only --diff-filter=A "$sha" | tr '\0' '\n' \
      | awk -F/ '{ p = ""; for (i = 1; i < NF; i++) { p = (p == "" ? $i : p "/" $i); print p } }' | sort -u > "$TMPD/naming-dirs"
    # The renames of the commit, as <new folder> <old folder> for every folder above a renamed file,
    # each beside the one as far above its old path, the nearest first; moved_from reads them
    git diff-tree -z --no-commit-id --root -r -M --name-status --diff-filter=R "$sha" | tr '\0' '\n' | paste - - - \
      | awk -F'\t' '{ n = split($3, d, "/"); m = split($2, s, "/")
          for (k = 1; k < n && k < m; k++) {
            p = d[1]; for (j = 2; j <= n - k; j++) p = p "/" d[j]
            q = s[1]; for (j = 2; j <= m - k; j++) q = q "/" s[j]
            print p "\t" q
          } }' | awk '!seen[$0]++' > "$TMPD/naming-moves"
    while IFS= read -r dir; do
      [ -n "$dir" ] || continue
      git cat-file -e "$sha^:$dir" 2>/dev/null && continue   # it was there before this commit
      seg="${dir##*/}"; parent=""; [ "$seg" = "$dir" ] || parent="${dir%/*}/"
      found="$(dir_findings "$sha" "$dir")"
      from=""; [ -z "$found" ] || from="$(moved_from "$sha" "$dir")"
      # A folder the commit moves (git mv a b brings b/seeds from a/seeds) keeps a finding it had
      # where it stood. A family finding stood there only where the other member moved along from
      # the same folder: beside another member, the family is new.
      if [ -n "$from" ]; then
        before="$(dir_findings "$sha^" "$from")"; kept=""
        while IFS=$'\t' read -r kind a b; do
          [ -n "$kind" ] || continue
          line="$kind"$'\t'"$a"$'\t'"$b"
          if grep -qxF -- "$line" <<< "$before"; then
            [ "$kind" = family ] || continue
            other="$a"; [ "$a" != "$seg" ] || other="$b"
            case "$from" in */*) [ "$(moved_from "$sha" "$parent$other")" != "${from%/*}/$other" ] || continue ;;
                            *)   [ "$(moved_from "$sha" "$parent$other")" != "$other" ] || continue ;; esac
          fi
          kept="$kept$line"$'\n'
        done <<< "$found"
        found="$kept"
      fi
      while IFS=$'\t' read -r kind a b; do
        case "$kind" in
          family) echo "$parent$a beside $parent$b: one member of the family says its side, the other does not; name every member, or none" ;;
          part) parts="$(awk -F'\t' -v r="$a" '$2 == r { print $3; exit }' "$TMPD/naming-owners")"
            echo "$dir names a part of the repository $a, and $a has no $b; its parts are$(sed 's/ *$//; s/ \([^ ]\)/, \1/g; s/^,//' <<< "$parts")" ;;
        esac
      done <<< "$found"
    done < "$TMPD/naming-dirs"
  done <<< "$commits"
}
findings="$(naming_findings | sort -u)"
if [ -n "$findings" ]; then
  while IFS= read -r line; do echo "pre-push: $line" >&2; done <<< "$findings"
  refuse "the names above are invented where they should be derived from what they belong to. Rename them, or give the commit that adds them a 'Naming: <why>' trailer. A folder moved whole keeps the names inside it where git still pairs its files as renames: move it in a commit of its own."
fi

# THE WAIT FOR A LOWER LOAD. A check that starts on a busy machine goes red on timing, not on the code,
# so it starts once the 1-minute load is below PRE_PUSH_LOAD_LIMIT, or when PRE_PUSH_LOAD_WAIT_SECONDS are
# used up. A sample reserves no CPU and the load can rise again after it. Both settings are the
# checkout's own and are read again at every poll; a zero is a mode of its own and still measures once.
LOAD_POLL_SECONDS=5
read_load_settings() {  # sets LOAD_LIMIT and LOAD_WAIT_SECONDS, or refuses
  local decimal='^[0-9]+(\.[0-9]+)?$' whole='^[0-9]+$'
  LOAD_LIMIT="$(config_file_value PRE_PUSH_LOAD_LIMIT 24)"
  LOAD_WAIT_SECONDS="$(config_file_value PRE_PUSH_LOAD_WAIT_SECONDS 300)"
  [[ "$LOAD_LIMIT" =~ $decimal ]] \
    || refuse "PRE_PUSH_LOAD_LIMIT is '$LOAD_LIMIT' in $root/.ai-core/config.env; it is the 1-minute load below which a check starts, a number of 0 or more such as 24 or 23.5, and 0 turns the wait off"
  [[ "$LOAD_WAIT_SECONDS" =~ $whole ]] \
    || refuse "PRE_PUSH_LOAD_WAIT_SECONDS is '$LOAD_WAIT_SECONDS' in $root/.ai-core/config.env; it is the seconds the gate waits for a lower load, a whole number of 0 or more, and 0 starts the check at once"
}
read_load() {  # the 1-minute load average, or nothing and status 1; the locale is the reader's alone
  local line load
  line="$(LC_ALL=C uptime 2>/dev/null)" || return 1
  load="$(sed -n 's/.*load averages\{0,1\}:[[:space:]]*\([0-9][0-9]*\(\.[0-9][0-9]*\)\{0,1\}\).*/\1/p' <<< "$line")"
  [ -n "$load" ] || return 1
  printf '%s\n' "$load"
}
is_zero() { awk -v v="$1" 'BEGIN { exit !(v + 0 == 0) }'; }
at_or_above() { awk -v sample="$1" -v limit="$2" 'BEGIN { exit !(sample + 0 >= limit + 0) }'; }
wait_for_lower_load() {  # sets LOAD_AT_START to the sample the check starts with, or -
  local started now remaining step sample announced=0
  started="$(date +%s)"
  while :; do
    read_load_settings
    if is_zero "$LOAD_LIMIT" || [ "$LOAD_WAIT_SECONDS" -eq 0 ]; then
      if sample="$(read_load)"; then
        if ! is_zero "$LOAD_LIMIT" && at_or_above "$sample" "$LOAD_LIMIT"; then
          echo "pre-push: the check starts at a 1-minute load of $sample, at or above the limit of $LOAD_LIMIT: PRE_PUSH_LOAD_WAIT_SECONDS is 0, so it does not wait."
        fi
      else
        echo "pre-push: the 1-minute load could not be measured, so no load is recorded for this check; the wait for a lower load is off (PRE_PUSH_LOAD_LIMIT or PRE_PUSH_LOAD_WAIT_SECONDS is 0)."
        sample=-
      fi
      break
    fi
    sample="$(read_load)" \
      || refuse "the 1-minute load could not be read from uptime, so the check cannot wait for a lower one. Fix uptime, or set PRE_PUSH_LOAD_LIMIT or PRE_PUSH_LOAD_WAIT_SECONDS to 0 in $root/.ai-core/config.env to start without waiting."
    if ! at_or_above "$sample" "$LOAD_LIMIT"; then
      [ "$announced" -eq 0 ] || echo "pre-push: the 1-minute load fell to $sample, below $LOAD_LIMIT; the check starts."
      break
    fi
    if [ "$announced" -eq 0 ]; then
      echo "pre-push: waiting for the 1-minute load to fall below $LOAD_LIMIT; it is $sample. It waits $LOAD_WAIT_SECONDS seconds at most (PRE_PUSH_LOAD_LIMIT, PRE_PUSH_LOAD_WAIT_SECONDS in $root/.ai-core/config.env)."
      announced=1
    fi
    now="$(date +%s)"; remaining=$((LOAD_WAIT_SECONDS - (now - started)))
    if [ "$remaining" -le 0 ]; then
      echo "pre-push: the wait is over; the check starts at a 1-minute load of $sample, at or above the limit of $LOAD_LIMIT."
      break
    fi
    step="$LOAD_POLL_SECONDS"; [ "$remaining" -ge "$step" ] || step="$remaining"
    sleep "$step"
  done
  LOAD_AT_START="$sample"
}
refuse_if_tree_differs() {
  local dirty
  dirty="$(git -C "$root" -c core.quotePath=false status --porcelain)"
  [ -z "$dirty" ] || refuse "the working tree differs from the commit being pushed, so the check would prove a tree that is not sent:
$(sed 's/^/  /' <<< "$dirty")
  Commit these files, ignore them, or move them out of the tree, then push again."
}

# The run is announced after the refusals above, so a push that is refused is not first promised a run
# it never gets. How long it takes is the repository's own business.
if [ -f "$root/scripts/check.sh" ]; then
  # The check reads the working tree, so it proves the pushed commit only where the two are equal.
  refuse_if_tree_differs
  wait_for_lower_load
  # The commit and the tree are judged again: both can change while the push waits.
  [ "$(git -C "$root" rev-parse HEAD)" = "$head" ] \
    || refuse "HEAD moved from ${head:0:12} to $(git -C "$root" rev-parse --short=12 HEAD) while the push waited for a lower load, so the check would prove a commit that is not the one judged. Push again."
  refuse_if_tree_differs
  GATE_LOAD="$LOAD_AT_START"
  echo "pre-push: $root/scripts/check.sh runs here, before anything leaves this machine."
  check_started="$(date +%s)"; check_rc=0
  # Both streams go to the log, so its last line is the check's last word on either of them
  with_caller_git_config with_sign_in_line bash "$root/scripts/check.sh" 2>&1 | tee "$TMPD/check.log" || check_rc=$?
  GATE_CHECK_SECONDS=$(( $(date +%s) - check_started ))
  GATE_CHECK_LAST="$(grep -v '^[[:space:]]*$' "$TMPD/check.log" | tail -1)"
  GATE_CHECK=green; [ "$check_rc" -eq 0 ] || GATE_CHECK=red
  [ "$check_rc" -eq 0 ] || refuse 'a check failed - the lines above name which one.'
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
  # gitleaks hands its log options to git and counts git's refusal of one as "no leaks found", so
  # a git that cannot show a merge's own diff would let every push out unread.
  git -C "$root" log --diff-merges=remerge -n0 HEAD >/dev/null 2>&1 \
    || refuse "$(git --version) cannot show what a merge's author wrote beyond git's own merge (--diff-merges=remerge, git 2.36 or newer), and $root/.gitleaks.toml says the commits being pushed are read for credentials. Update git, then push again."
  while IFS= read -r scan_range; do
    [ -n "$scan_range" ] || continue
    # git shows no remerge diff for a merge of three or more parents, so its own lines go unread.
    [ -z "$(git -C "$root" rev-list --min-parents=3 -n1 $scan_range)" ] \
      || refuse 'this push carries a merge of three or more branches at once, and git shows no diff of what its author wrote there, so the credential scan cannot read it. Merge one branch at a time, then push again.'
    # A merge shows no patch in git log unless asked to, and a credential that stands only in how a
    # conflict was resolved would go out unread. The remerge diff is what the merge's author wrote
    # beyond git's own merge: nothing the remote carries already. gitleaks names a file that had a
    # conflict b/<path>, as it parses git's conflict header. Of each finding only the commit, the
    # file, the line and the rule are shown: the report's other fields carry the line around the
    # value and the commit message, which gitleaks neither scans nor redacts.
    findings="$(gitleaks git --no-banner --redact --report-format json --report-path - --log-opts="--diff-merges=remerge $scan_range" "$root")" && continue
    jq -r '.[] | "pre-push: \(.Commit[0:12]) \(.File):\(.StartLine) \(.RuleID)"' <<< "$findings" >&2
    refuse 'a credential stands in a commit this push carries. The lines above name the commit, the file and the rule. Take it out of the history - a commit that is pushed cannot be recalled.'
  done <<< "$scan_ranges"
fi

echo 'pre-push: nothing refused this push.'
