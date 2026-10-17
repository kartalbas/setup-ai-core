#!/usr/bin/env bash
# Where the project's issues and board live. TRACKER in the project's .ai-core/config.env (or in the
# environment) names the provider, the folder under lib/ whose tracker.sh implements the functions
# every command in bin/ calls; github when unset. A value with no folder stops the command and names
# the folders there are. Source it, do not run it.

. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

TRACKER="$(config_value TRACKER github | tr '[:upper:]' '[:lower:]')"
# a name of letters and digits only cannot lead out of lib/
case "$TRACKER" in *[!a-z0-9]*) tracker_known="" ;; *) tracker_known="$(dirname "${BASH_SOURCE[0]}")/$TRACKER/tracker.sh" ;; esac
if [ ! -f "$tracker_known" ]; then
  die "TRACKER is '$TRACKER', and this harness has no tracker of that name. It has: $(
    for f in "$(dirname "${BASH_SOURCE[0]}")"/*/tracker.sh; do basename "$(dirname "$f")"; done | paste -sd' ' -)"
fi
. "$(dirname "${BASH_SOURCE[0]}")/$TRACKER/tracker.sh"
