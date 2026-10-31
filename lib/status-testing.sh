#!/usr/bin/env bash
# The testing block for a tracker that has no board: lib/forgejo/tracker/commands/status.mts hands over the issues as the
# card rows lib/status.mjs reads and, for each open issue in testing, what the tracker holds of it
# ({repository, number, createdAt, context, reason, landing, proofs}); this adds what only a clone answers, how a commit
# names the issue and the clone of the landing, as bin/status.sh does for a board, and prints the lines of the block.
#
#   status-testing.sh ITEMS_FILE COLUMNS_FILE TESTING_FILE BOARD
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/common.sh"
. "$here/usage.sh"

[ $# -eq 4 ] || die "usage: status-testing.sh ITEMS_FILE COLUMNS_FILE TESTING_FILE BOARD"
command -v node >/dev/null 2>&1 || die "status counts with node, and node is not on the PATH"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
folder="$(project_folder_of "$PWD")"
stop="$(usage_stop_at)" || exit 1
: > "$work/testing"
while IFS= read -r record; do
  [ -n "$record" ] || continue
  repo="$(jq -r '.repository' <<< "$record")"; number="$(jq -r '.number' <<< "$record")"
  landing_clone=""
  if [ "$(jq -r '.landing != null' <<< "$record")" = true ]; then landing_clone="$(clone_of "$(jq -r '.landing.repository' <<< "$record")")"; fi
  jq -c --arg pattern "$(issue_mention_pattern "$repo" "$number" "$repo")" --arg landingClone "$landing_clone" \
    '. + {pattern: $pattern, landingClone: $landingClone}' <<< "$record" >> "$work/testing" || exit 1
done < "$3"
node "$here/status.mjs" --items-file "$1" --columns-file "$2" --board "$4" --folder "$folder" --stop-at "$stop" \
  --config-file "$folder/.ai-core/config.env" --testing-file "$work/testing" --testing
