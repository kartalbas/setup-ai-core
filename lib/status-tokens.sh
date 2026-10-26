#!/usr/bin/env bash
# The page of `status --tokens` for a tracker that has no board: lib/forgejo/tracker/commands/status.mts hands
# over the issues as the card rows lib/status.mjs reads, and this prints the page with the windows of the tool
# of the session, as bin/status.sh does for a board.
#
#   status-tokens.sh ITEMS_FILE COLUMNS_FILE BOARD
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/common.sh"
. "$here/usage.sh"

[ $# -eq 3 ] || die "usage: status-tokens.sh ITEMS_FILE COLUMNS_FILE BOARD"
command -v node >/dev/null 2>&1 || die "status counts with node, and node is not on the PATH"
work="$(mktemp -d)"; trap 'usage_release; rm -rf "$work"' EXIT
tool="$(session_tool)"; [ -n "$tool" ] || tool=claude
usage_snapshot "$tool" > "$work/usage.json" || exit 1
node "$here/status.mjs" --items-file "$1" --columns-file "$2" --board "$3" --folder "$(project_folder_of "$PWD")" \
  --stop-at "$(usage_stop_at)" --usage-file "$work/usage.json" --tokens
