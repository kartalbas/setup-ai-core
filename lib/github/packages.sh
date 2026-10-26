#!/usr/bin/env bash
# The GitHub operations behind bin/issue-package.sh: the repository labels of a package, the labels of an issue and what an
# issue answers about its completion. Every read is established as an answer before it is used (gh_read); a write returns
# gh's status and leaves the decision to the caller, which knows what was confirmed before it. Source it, do not run it.

. "$(dirname "${BASH_SOURCE[0]}")/gh.sh"

PACKAGE_LABEL_COLOR=5319e7

# package_uri <text>: the text as one segment of a URL path
package_uri() { jq -rn --arg value "$1" '$value | @uri'; }

# package_labels <owner/repo>: every label of the repository, every page, as one JSON array. A page that cannot be read fails
# the read: it is no shorter list.
package_labels() {
  local pages
  pages="$(gh_read "the labels of $1" api --paginate "repos/$1/labels?per_page=100")" || return 1
  printf '%s\n' "$pages" | jq -s 'add // []'
}

# package_label_in <labels JSON> <name>: the label of that name as one JSON object, or nothing. GitHub holds label names
# apart without regard to case, so it is compared so.
package_label_in() {
  printf '%s' "$1" | jq -c --arg name "$2" 'map(select((.name | ascii_downcase) == ($name | ascii_downcase))) | .[0] // empty'
}

# package_label_is_archived <label JSON>: prints true or false, and fails where GitHub did not say
package_label_is_archived() {
  printf '%s' "$1" | jq -r 'if has("archived_at") then (.archived_at != null) else error("no archived_at") end' 2>/dev/null
}

# package_label_create <owner/repo> <name> <description>: prints the label JSON
package_label_create() {
  gh api --method POST "repos/$1/labels" -f name="$2" -f color="$PACKAGE_LABEL_COLOR" -f description="$3"
}

# package_label_archive <owner/repo> <name> <true | false>: prints the label JSON as GitHub answers the change
package_label_archive() {
  gh api --method PATCH "repos/$1/labels/$(package_uri "$2")" -F archived="$3"
}

# package_issue <owner/repo> <number>: the issue as GitHub answers it
package_issue() {
  gh_read "the issue $1#$2" api "repos/$1/issues/$2"
}

# package_issue_label_names <issue JSON>: its label names, one per line
package_issue_label_names() {
  printf '%s' "$1" | jq -r '.labels[].name'
}

# package_issue_is_complete <issue JSON>: succeeds for an issue that is closed as completed. An issue GitHub closed before it
# kept a reason, or one closed as not planned, is no proof.
package_issue_is_complete() {
  printf '%s' "$1" | jq -e '.state == "closed" and .state_reason == "completed"' >/dev/null
}

# package_issue_label_add <owner/repo> <number> <name>
package_issue_label_add() {
  jq -n --arg name "$3" '{labels: [$name]}' | gh api --method POST "repos/$1/issues/$2/labels" --input - >/dev/null
}

# package_issue_label_remove <owner/repo> <number> <name>
package_issue_label_remove() {
  gh api --method DELETE "repos/$1/issues/$2/labels/$(package_uri "$3")" >/dev/null
}
