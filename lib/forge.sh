#!/usr/bin/env bash
# Where the project's code lives. FORGE in the project's .ai-core/config.env (or in the environment)
# names the provider, the folder under lib/ whose forge.sh implements the functions below; github
# when unset. lib/layers.sh, bin/init.sh, bin/release.sh, bin/integrate-issue.sh, bin/session-start.sh,
# bin/doctor.sh and bin/issue-map.sh call only these. Source it, do not run it.

. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# THE INTERFACE:
#   forge_host                   the host the origin of a checkout names
#   forge_name                   the forge as a message names it: GitHub, or the host of the instance
#   not_signed_in_words          what a refused call most likely means, in the words of the forge's tool
#   checks_unreadable_message <sha> <what the forge said last>
#                                the refusal of a release that could not read the checks of the commit until its deadline
#   repo_exists <owner/repo>     whether the repository is there
#   repo_clone <owner/repo> <dir>
#   repo_create <owner/repo> <dir>   private, from the checkout in <dir>, which it pushes
#   repo_default_branch <owner/repo> its default branch, nothing for a repository with no commit
#   repo_file_tree <owner/repo>      its files, as the JSON tree issue-map reads
#   repo_head_revision <owner/repo>  the commit its default branch stands at; exit 3 where the repository is not there or
#                                    holds no commit, exit 1 with the reason on stderr where the forge could not say
#   repo_file_at <owner/repo> <revision> <path> <file>
#                                    writes the file as that commit holds it; exit 3 where the commit holds no such file,
#                                    exit 1 with the reason on stderr where the forge could not say or the answer is no file
#   forge_repo_visibility <owner/repo>  public or private; fails, saying why, where the forge does not establish it
#   commit_checked <checkout> <sha>  green, red, pending or unreadable (what the forge said, on stderr)
#   signed_in_user               the login, exit 1 where nobody is signed in
#   clone_sign_in <checkout> [dry]   what git needs to sign in to the forge from that checkout and from a tool's own
#                                    repositories, set in the checkout itself and in the user's git configuration; prints
#                                    a report line for each it set (dry: would set), else nothing
#   forge_doctor                 the lines doctor prints for the forge, "  forge: <name>" first, through its report and problem
load_provider forge "
  forge_host forge_name not_signed_in_words checks_unreadable_message repo_exists repo_clone repo_create repo_default_branch repo_file_tree
  repo_head_revision repo_file_at forge_repo_visibility commit_checked signed_in_user clone_sign_in forge_doctor"

# forge_content_file <what was read> <contents answer> <file>: the file of a contents answer, which both forges give
# as {type: "file", encoding: "base64", content, size}, written to <file>. An answer of any other shape, a content
# that does not decode and a file of another size than the answer names are no file.
forge_content_file() {
  local what="$1" answer="$2" file="$3" size
  jq -e '.type == "file" and .encoding == "base64" and (.content | type) == "string" and (.size | type) == "number"' <<< "$answer" >/dev/null 2>&1 \
    || { echo "cannot read $what: the answer is no file in base64" >&2; return 1; }
  mkdir -p "$(dirname "$file")" || { echo "cannot read $what: no folder for $file" >&2; return 1; }
  jq -j '.content | gsub("\\s"; "") | @base64d' <<< "$answer" > "$file" 2>/dev/null \
    || { rm -f "$file"; echo "cannot read $what: its content does not decode" >&2; return 1; }
  size="$(wc -c < "$file" | tr -d ' ')"
  [ "$size" = "$(jq -r '.size' <<< "$answer")" ] \
    || { rm -f "$file"; echo "cannot read $what: it holds $size bytes, and the answer names $(jq -r '.size' <<< "$answer")" >&2; return 1; }
}

# wait_for_checks <checkout> <sha> <poll seconds> <limit seconds> <line to say once, when it waits>
# The one wait for the checks of a commit, for release and integrate-issue; each caller words its own
# refusal. Returns 0 when commit_checked answers green, 1 red, 2 when the limit ends the wait with the
# checks pending, 3 when it ends with no answer: checks_said then holds what the forge said last. A
# query that fails is no answer yet, so only the limit ends the wait.
wait_for_checks() {
  local checkout="$1" sha="$2" poll="$3" limit="$4" waiting_line="$5" deadline waiting=0
  deadline=$(( $(date +%s) + limit ))
  while :; do
    run_split commit_checked "$checkout" "$sha" || true
    case "$split_out" in
      green) return 0 ;;
      red) return 1 ;;
      pending) checks_said="" ;;
      *) checks_said="${split_err:-an empty answer}" ;;
    esac
    if [ "$(date +%s)" -ge "$deadline" ]; then
      [ -n "$checks_said" ] || return 2
      checks_said="${checks_said% }"
      return 3
    fi
    [ "$waiting" -eq 1 ] || { echo "$waiting_line"; waiting=1; }
    sleep "$poll"
  done
}
