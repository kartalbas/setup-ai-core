#!/usr/bin/env bash
# Where the project's code lives. FORGE in the project's .ai-core/config.env (or in the environment)
# names the provider, the folder under lib/ whose forge.sh implements the functions below; github
# when unset. lib/layers.sh, bin/init.sh, bin/release.sh, bin/session-start.sh, bin/doctor.sh and
# bin/issue-map.sh call only these. Source it, do not run it.

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
#   commit_checked <checkout> <sha>  green, red, pending or unreadable (what the forge said, on stderr)
#   signed_in_user               the login, exit 1 where nobody is signed in
#   clone_sign_in <checkout> [dry]   what git needs to sign in to the forge from that checkout, set in the checkout
#                                    itself; prints its report line when it set something (dry: would set), else nothing
#   forge_doctor                 the lines doctor prints for the forge, "  forge: <name>" first, through its report and problem
load_provider forge "
  forge_host forge_name not_signed_in_words checks_unreadable_message repo_exists repo_clone repo_create repo_default_branch repo_file_tree
  commit_checked signed_in_user clone_sign_in forge_doctor"
