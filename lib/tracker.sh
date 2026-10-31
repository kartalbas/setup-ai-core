#!/usr/bin/env bash
# Where the project's issues and board live. TRACKER in the project's .ai-core/config.env (or in the
# environment) names the provider, the folder under lib/ whose tracker.sh implements the functions
# every command in bin/ calls; github when unset. Source it, do not run it.

. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
. "$(dirname "${BASH_SOURCE[0]}")/stated-time.sh"

# THE INTERFACE: every function the commands and lib/board.sh call to ask the tracker.
load_provider tracker "
  gh_org default_repo check_project_number resolve_project_for_repo template_project_number
  project_id board_cache_name fields_tsv project_repos board_repos repo_open_projects repo_archived
  issue_thread issue_landing_context issue_node_id issue_db_id parent_issue issue_parent
  item_id archived_item_id issue_board_items item_top board_items remove_board_item set_select
  epic_target_on_board open_subissues
  repo_visibility issue_create issue_edit issue_close issue_reopen issue_comment_post issue_body issue_transfer
  issue_labels issue_labels_set labels_create labels_list
  issue_assignees issue_assignees_set tracker_login
  issue_block issue_unblock subissue_attach subissue_attach_resolved subissue_detach
  duplicate_mark duplicate_unmark
  issue_rows issue_list issues_created_since projects_of_org
  item_unarchive issue_numbers_closed issue_summaries issue_title board_card_lines board_cards_of_repo
  card_rows open_issue_page board_fields_json field_options_replace project_create repo_boards_rows
  repo_link board_views view_filter_set tracker_doctor tracker_name closing_column"

# check_public_body <command> <destination> <text> <file or empty> [repo|project]: the stated time of the text, in a private
# repository as in a public one, then one visibility decision for all supplied text. No provider currently establishes
# project visibility.
check_public_body() {
  local command="$1" repo="$2" text="$3" file="$4" visibility addresses address stated
  if [ -n "$file" ]; then
    [ -f "$file" ] && [ -r "$file" ] || die "$command: cannot read body file: $file"
    text="$text"$'\n'"$(cat "$file")" || die "$command: cannot read body file: $file"
  fi
  stated="$(check_stated_time "$command" "$repo" "$text" 2>&1)" || die "$stated"
  visibility=unknown
  if [ "${5:-repo}" = repo ]; then
    visibility="$(repo_visibility "$repo")" || visibility=unknown
  fi
  [ "$visibility" != private ] || return 0
  # A git remote's user is no address. Dropped before the scan: the userinfo of a URL with a scheme,
  # up to its first delimiter and with a template expression in it, because its spaces would end the
  # URL; and the user of the scp-like SSH form, only where a path with a slash or a .git follows the
  # colon. mailto: has no "//", and an address before a port or a word stays scanned.
  # A match whose domain holds no dot and does not open with a bracket is no address, such as the digest
  # of an image reference or a scoped package name, and the scan goes on behind it. Beside letters,
  # marks and numbers, a domain takes the ten code points IDNA2008 allows inside a label, such as U+00B7
  # and U+200C, or the dot of a domain that holds one would go unseen. The scan runs twice
  # and refuses what either run finds. One run lets a quoted local part hold an at sign, so the outer
  # address of a quoted local part such as a quoted at sign before a domain is found. The other takes
  # no at sign inside the quotes, so an address inside them is found instead of being swallowed with
  # them. The bracketed domain follows the same split: the first run lets it hold an at sign, so the
  # outer address of a bracket that holds one is found, and the second takes none, so an address inside
  # is not swallowed.
  addresses="$(printf '%s' "$text" | jq -Rrs '
    def addresses($quoted; $bracketed): scan("(?:" + $quoted + "|(?:[A-Za-z0-9.!#$%&\u0027*+/=?^_`{|}~\\[\\]-]|[^\\x00-\\x7f])+)@(?:" + $bracketed + "|[[:alnum:]][[:alnum:]\\p{M}\u00b7\u0375\u05f3\u05f4\u06fd\u06fe\u0f0b\u200c\u200d\u30fb._\u3002\uff0e\uff61-]*)");
    gsub("(?<s>[A-Za-z][A-Za-z0-9+.-]*://)(?:\\{\\{[^}@\\r\\n]*\\}\\}|[^/?#\\s@{<>()\\[\\]\"\u0027`,;])*@"; "\(.s)")
    | gsub("(?<![^\\s`(\\[<\"\u0027])[A-Za-z0-9._-]+@(?=[A-Za-z0-9<][A-Za-z0-9.<>_-]*:[^\\s:]*(?:/|\\.git\\b))"; "")
    | (addresses("\"[^\"\\r\\n]+\""; "\\[[^\\]\\r\\n]+\\]"), addresses("\"[^\"@\\r\\n]+\""; "\\[[^\\]@\\r\\n]+\\]"))
    | . as $address | (split("@") | last | gsub("[\u3002\uff0e\uff61]"; ".") | ascii_downcase | sub("[.]+$"; "")) as $domain
    | select(($domain | test("[[:alpha:]]|^\\[")))
    | select(($domain | test("[.]|^\\[")))
    | select(($domain | test("(^|\\.)(invalid|example|test|localhost|example\\.(com|net|org))$")) | not)
    | select($domain != "users.noreply.github.com")
    | $address
  ')" || die "$command: could not inspect the body"
  while IFS= read -r address; do
    [ -z "$address" ] || die "$command: refused email address $address in a public or unknown tracker destination ($repo)"
  done <<< "$addresses"
}
