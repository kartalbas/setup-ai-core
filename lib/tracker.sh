#!/usr/bin/env bash
# Where the project's issues and board live. TRACKER in the project's .ai-core/config.env (or in the
# environment) names the provider, the folder under lib/ whose tracker.sh implements the functions
# every command in bin/ calls; github when unset. Source it, do not run it.

. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# THE INTERFACE: every function the commands and lib/board.sh call to ask the tracker.
load_provider tracker "
  gh_org default_repo check_project_number resolve_project_for_repo template_project_number
  project_id board_cache_name fields_tsv project_repos board_repos repo_open_projects
  issue_thread issue_node_id issue_db_id parent_issue issue_parent
  item_id archived_item_id issue_board_items item_top board_items remove_board_item set_select
  epic_target_on_board
  repo_visibility issue_create issue_edit issue_close issue_reopen issue_comment_post issue_body issue_transfer
  issue_labels issue_labels_set labels_create labels_list
  issue_assignees issue_assignees_set tracker_login
  issue_block issue_unblock subissue_attach subissue_attach_resolved subissue_detach
  duplicate_mark duplicate_unmark
  issue_rows issues_created_since projects_of_org
  item_unarchive issue_numbers_closed issue_summaries issue_title board_card_lines board_cards_of_repo
  card_rows open_issue_page board_fields_json field_options_replace project_create repo_boards_rows
  repo_link board_views view_filter_set tracker_doctor tracker_name writes_run_in_repo_clone closing_column"

# check_public_body <command> <destination> <text> <file or empty> [repo|project]: one visibility
# decision for all supplied text. No provider currently establishes project visibility.
check_public_body() {
  local command="$1" repo="$2" text="$3" file="$4" visibility addresses address
  if [ -n "$file" ]; then
    [ -f "$file" ] && [ -r "$file" ] || die "$command: cannot read body file: $file"
    text="$text"$'\n'"$(cat "$file")" || die "$command: cannot read body file: $file"
  fi
  visibility=unknown
  if [ "${5:-repo}" = repo ]; then
    visibility="$(repo_visibility "$repo")" || visibility=unknown
  fi
  [ "$visibility" != private ] || return 0
  # A git remote's user is no address. Dropped before the scan: the userinfo of a URL with a scheme,
  # up to its first delimiter and with a template expression in it, because its spaces would end the
  # URL; and the user of the scp-like SSH form, only where a path with a slash or a .git follows the
  # colon. mailto: has no "//", and an address before a port or a word stays scanned.
  # A scoped package name (an at sign, a scope without a dot, a slash, a package name) is replaced by a
  # space, with its opening backtick. It must not stand behind a character of a local part or a quote,
  # and no letter, digit, dot, hyphen, underscore, at sign or non-ASCII character may follow it: a
  # longer name, an address inside the package part and a dotted scope, which is a domain, then keep
  # their letters and stay scanned. Any other follower, such as a backtick or a slash, stays in the
  # text, so an address behind it is scanned as before. A quoted local part and a bracketed domain
  # take no at sign, so one match cannot swallow an address that the replacement would then hide.
  addresses="$(printf '%s' "$text" | jq -Rrs '
    gsub("(?<s>[A-Za-z][A-Za-z0-9+.-]*://)(?:\\{\\{[^}@\\r\\n]*\\}\\}|[^/?#\\s@{<>()\\[\\]\"\u0027`,;])*@"; "\(.s)")
    | gsub("(?<![^\\s`(\\[<\"\u0027])[A-Za-z0-9._-]+@(?=[A-Za-z0-9<][A-Za-z0-9.<>_-]*:[^\\s:]*(?:/|\\.git\\b))"; "")
    | gsub("(?<![A-Za-z0-9.!#$%&\u0027*+/=?^_`{|}~\\[\\]\"-]|[^\\x00-\\x7f])`?@[a-z0-9_-]+/[a-z0-9][a-z0-9._-]*(?![A-Za-z0-9.@_-]|[^\\x00-\\x7f])"; " ")
    | scan("(?:\"[^\"@\\r\\n]+\"|(?:[A-Za-z0-9.!#$%&\u0027*+/=?^_`{|}~\\[\\]-]|[^\\x00-\\x7f])+)@(?:\\[[^\\]@\\r\\n]+\\]|[[:alnum:]][[:alnum:]\\p{M}._\u3002\uff0e\uff61-]*)")
    | . as $address | (split("@") | last | gsub("[\u3002\uff0e\uff61]"; ".") | ascii_downcase | sub("[.]+$"; "")) as $domain
    | select(($domain | test("[[:alpha:]]|^\\[")))
    | select(($domain | test("(^|\\.)(invalid|example|test|localhost|example\\.(com|net|org))$")) | not)
    | select($domain != "users.noreply.github.com")
    | $address
  ')" || die "$command: could not inspect the body"
  while IFS= read -r address; do
    [ -z "$address" ] || die "$command: refused email address $address in a public or unknown tracker destination ($repo)"
  done <<< "$addresses"
}
