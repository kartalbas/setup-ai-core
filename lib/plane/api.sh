#!/usr/bin/env bash
# The Plane REST API as every Plane provider of this harness calls it: curl with the API key read from
# PLANE_TOKEN_COMMAND at the moment of the call, the rate limit of 60 requests per minute met once
# (plane_call), the refusals made visible (plane_api) and a paged listing read to its end
# (plane_pages). lib/plane/tracker.sh sources it. Every path is under /api/v1: Plane CE 1.4.2 routes
# api/v1/ and no other prefix (apps/api/plane/urls.py:22 at tag v1.4.2). Source it, do not run it.

. "$(dirname "${BASH_SOURCE[0]}")/../common.sh"

# A SETTING THAT ONLY THE DEPLOYMENT CAN KNOW HAS NO DEFAULT: a missing one stops the call and names it.
plane_setting() {  # plane_setting <PLANE_URL | PLANE_WORKSPACE | PLANE_PROJECT>
  local value
  value="$(config_value "$1" "")"
  [ -n "$value" ] || die "$1 is not set: set it in .ai-core/config.env or the environment"
  printf '%s\n' "$value"
}

# plane_path <path under the workspace>: the API path of this workspace
plane_path() { printf '/api/v1/workspaces/%s/%s\n' "$(plane_setting PLANE_WORKSPACE)" "$1"; }

# PLANE ANSWERS 429 WHEN THE KEY HAS SPENT ITS MINUTE, and X-RateLimit-Reset is the UTC epoch second at
# which the window ends (developers.plane.so/api-reference/introduction). The call waits until then and is
# made again, PLANE_RATE_RETRIES times at most; a wait longer than PLANE_RATE_WAIT_MAX seconds, or the
# last 429, ends in a refusal that says so. AI_CORE_SLEEP names the command that waits, as for gh.
PLANE_RATE_RETRIES=3
PLANE_RATE_WAIT_MAX=120

# plane_call <method> <path> [json body]: sets plane_status, plane_body and plane_headers; returns 0 for any
# answer Plane gave. Called in this shell, never as `$( )`.
plane_call() {
  local try=0 reset wait
  while :; do
    http_call PLANE_TOKEN_COMMAND X-API-Key "" "$1" "$(plane_setting PLANE_URL | sed 's|/*$||')$2" "${3:-}"
    plane_status="$http_status"; plane_body="$http_body"; plane_headers="$http_headers"
    [ "$plane_status" = 429 ] || return 0
    reset="$(printf '%s\n' "$plane_headers" | tr -d '\r' | awk 'tolower($1) == "x-ratelimit-reset:" { print $2; exit }')"
    case "$reset" in ''|*[!0-9]*) wait=60 ;; *) wait=$(( reset - $(date +%s) + 1 )) ;; esac
    [ "$wait" -ge 1 ] || wait=1
    if [ "$try" -ge "$PLANE_RATE_RETRIES" ]; then
      plane_body="$plane_body"$'\n'"Plane's rate limit still refuses after $try waits"; return 0
    fi
    if [ "$wait" -gt "$PLANE_RATE_WAIT_MAX" ]; then
      plane_body="$plane_body"$'\n'"Plane's rate limit does not lift within $PLANE_RATE_WAIT_MAX seconds"; return 0
    fi
    try=$((try + 1))
    echo "waiting ${wait}s for Plane's rate limit (try $try of $PLANE_RATE_RETRIES)" >&2
    "${AI_CORE_SLEEP:-sleep}" "$wait"
  done
}

# plane_api <what was asked for> <method> <path> [json body]: prints the answer. Anything but 2xx stops the
# caller with "cannot read <what> - the Plane API answered <status>" and the words Plane gave, the way
# gh_read does for gh: `x="$(plane_api ...)" || exit 1`.
plane_api() {
  local what="$1"
  shift
  plane_call "$@"
  case "$plane_status" in
    2??) printf '%s\n' "$plane_body" ;;
    000) die "cannot read $what - the Plane API did not answer: $plane_body" ;;
    *)   die "cannot read $what - the Plane API answered $plane_status${plane_body:+: $(printf '%s' "$plane_body" | tr -s '\r\n' '  ' | cut -c1-300)}" ;;
  esac
}

# plane_pages <what> <path with its query, or without> : every result of a listing, one JSON object per
# line, read page by page (per_page and cursor are Plane's own, apps/api/plane/utils/paginator.py at
# v1.4.2). A listing outgrows one page quickly, and a single unpaged read silently reports the rest absent.
plane_pages() {
  local what="$1" path="$2" cursor="" page sep="?"
  case "$path" in *"?"*) sep="&" ;; esac
  while :; do
    page="$(plane_api "$what" GET "$path${sep}per_page=100${cursor:+&cursor=$cursor}")" || exit 1
    printf '%s' "$page" | jq -c '.results[]'
    [ "$(printf '%s' "$page" | jq -r '.next_page_results // false')" = true ] || break
    cursor="$(printf '%s' "$page" | jq -r '.next_cursor')"
  done
}
