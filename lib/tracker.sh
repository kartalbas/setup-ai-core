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
  issue_create issue_edit issue_close issue_reopen issue_comment_post issue_body issue_transfer
  issue_labels issue_labels_set labels_create labels_list
  issue_assignees issue_assignees_set tracker_login
  issue_block issue_unblock subissue_attach subissue_attach_resolved subissue_detach
  duplicate_mark duplicate_unmark
  issue_rows issues_created_since projects_of_org
  item_unarchive issue_numbers_closed issue_summaries issue_title board_card_lines board_cards_of_repo
  card_rows open_issue_page board_fields_json field_options_replace project_create repo_boards_rows
  repo_link board_views view_filter_set tracker_doctor writes_run_in_repo_clone closing_column"
