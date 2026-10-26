#!/usr/bin/env bash
# The forge of this harness on Forgejo: repositories, the check of a commit and the signed-in user, asked
# with curl against the REST API v1 of the instance (Forgejo 15.0: https://forgejo.org/docs/v15.0/user/api-usage/,
# routes in routers/api/v1/api.go of its source), and the line that lets git sign in with the same token.
# lib/forge.sh sources it when FORGE is forgejo; bin/git-credential.sh sources it for the host and the
# line. FORGEJO_URL, the scheme and host of the instance, and FORGEJO_TOKEN_COMMAND, the command that
# prints an access token, have no default: a call without them stops and names the missing one. Source it,
# do not run it.

. "$(dirname "${BASH_SOURCE[0]}")/../common.sh"

# THE LINE THAT LETS GIT SIGN IN: git runs this command through the shell and gives it get on its standard
# input, and bin/git-credential.sh answers with the token. The token stands in no file, so a changed
# FORGEJO_TOKEN_COMMAND takes effect at once. The line is two values of credential.<url>.helper, an empty one
# and then this: git asks every helper it collected from the system and the user's configuration first, and a
# store or a cache among them would keep the token this helper answered with, and go on answering with it after
# the token command has changed; an empty value drops everything collected before it.
FORGEJO_CREDENTIAL_HELPER='!ai-core git-credential'

# sign_in_line_set <checkout> <url>: the helpers of this instance in the checkout's own .git/config are the
# harness's alone
sign_in_line_set() {
  git -C "$1" config --replace-all "credential.$2.helper" ""
  git -C "$1" config --add "credential.$2.helper" "$FORGEJO_CREDENTIAL_HELPER"
}

# sign_in_line_stands <checkout> <url>: whether that is all the checkout has
sign_in_line_stands() {
  [ "$(git -C "$1" config --local --get-all "credential.$2.helper" 2>/dev/null || true)" = "$(printf '\n%s' "$FORGEJO_CREDENTIAL_HELPER")" ]
}

# sign_in_line_export: the same line in git's environment configuration, after the entries already there, for git
# started from this shell in any directory. The helper's own command carries the two settings it reads, quoted for
# git's shell, so no other command sees them in its environment and reads them instead of its own config.env.
sign_in_line_export() {
  local url command n tick="'" quoted_tick="'\\''"
  url="$(forgejo_url)" || return 1
  command="$(config_value FORGEJO_TOKEN_COMMAND "")" || return 1
  n=${GIT_CONFIG_COUNT:-0}
  export "GIT_CONFIG_KEY_$n=credential.$url.helper" "GIT_CONFIG_VALUE_$n="
  n=$((n + 1))
  export "GIT_CONFIG_KEY_$n=credential.$url.helper" \
    "GIT_CONFIG_VALUE_$n=!FORGEJO_URL='${url//$tick/$quoted_tick}' FORGEJO_TOKEN_COMMAND='${command//$tick/$quoted_tick}' ${FORGEJO_CREDENTIAL_HELPER#!}" \
    "GIT_CONFIG_COUNT=$((n + 1))"
}

forgejo_url() {  # the scheme and host of the instance, without a closing slash
  local url
  url="$(config_value FORGEJO_URL "")" || exit 1
  [ -n "$url" ] || die "FORGEJO_URL is not set: set it in .ai-core/config.env or the environment to the address of the Forgejo instance, such as https://forge.example.test"
  url="${url%/}"
  case "$url" in http://*|https://*) ;; *) die "FORGEJO_URL '$url' is no http or https address" ;; esac
  case "${url#*://}" in */*) die "FORGEJO_URL '$url' names a path: give the scheme and host only, such as https://forge.example.test" ;; esac
  printf '%s\n' "$url"
}

# forge_host: the host of the instance (with its port), as the origin of a checkout spells it
forge_host() {
  local url
  url="$(forgejo_url)" || exit 1
  url="${url#*://}"
  printf '%s\n' "$url"
}

forge_name() { forge_host; }

not_signed_in_words() { echo "FORGEJO_URL or FORGEJO_TOKEN_COMMAND is not set, or the instance refuses the token"; }

checks_unreadable_message() {  # checks_unreadable_message <sha> <what Forgejo said last>
  echo "the checks of $1 could not be read from $(forge_host) until the deadline; it said last: $2 (is anyone signed in there?)"
}

# forgejo_call <method> <path under /api/v1> [json body]: sets forgejo_status (000 where curl got no answer) and
# forgejo_body; returns 0 for any answer. Called in this shell, never as `$( )`.
forgejo_call() {
  local base
  base="$(forgejo_url)" || exit 1
  http_call FORGEJO_TOKEN_COMMAND Authorization "token " "$1" "$base/api/v1$2" "${3:-}"
  forgejo_status="$http_status"; forgejo_body="$http_body"
}

# forgejo_said: what Forgejo answered, on one line, for a message
forgejo_said() { printf '%s' "$forgejo_status${forgejo_body:+: $(printf '%s' "$forgejo_body" | tr -s '\r\n' '  ' | cut -c1-300)}"; }

# forgejo_api <what was asked for> <method> <path> [json body]: prints the answer. Anything but 2xx stops the
# caller with "cannot read <what> - Forgejo answered <status>" and the words Forgejo gave: `x="$(forgejo_api ...)" || exit 1`.
forgejo_api() {
  local what="$1"
  shift
  forgejo_call "$@"
  case "$forgejo_status" in
    2??) printf '%s\n' "$forgejo_body" ;;
    000) die "cannot read $what - Forgejo did not answer: $forgejo_body" ;;
    *)   die "cannot read $what - Forgejo answered $(forgejo_said)" ;;
  esac
}

# The functions below that the commands call in an `if` or after `||` are subshells: a missing setting stops
# that call and says so, and the shell that asked goes on.

repo_exists() (  # repo_exists <owner/repo>
  forgejo_call GET "/repos/$1"
  case "$forgejo_status" in
    2??) ;;
    404) exit 1 ;;
    *) echo "cannot tell whether $1 exists - Forgejo answered $(forgejo_said)" >&2; exit 1 ;;
  esac
)

# forgejo_git <git arguments>: git with the two settings the credential line reads, in its environment: a push or a
# pull inside the clone of a project harness runs the helper where this checkout's .ai-core is not. Both are
# settings, not the token.
forgejo_git() {
  local url command
  url="$(forgejo_url)" || return 1
  command="$(config_value FORGEJO_TOKEN_COMMAND "")" || return 1
  FORGEJO_URL="$url" FORGEJO_TOKEN_COMMAND="$command" git "$@"
}

repo_clone() (  # repo_clone <owner/repo> <dir>: the clone keeps the line that lets git sign in
  local base
  base="$(forgejo_url)" || exit 1
  forgejo_git clone --quiet -c "credential.$base.helper=" -c "credential.$base.helper=$FORGEJO_CREDENTIAL_HELPER" "$base/$1.git" "$2"
)

# repo_create <owner/repo> <dir>: private, and pushes the checkout in <dir>. The owner is the signed-in user or
# an organisation the user may create repositories in.
repo_create() (
  local base me login path body
  base="$(forgejo_url)" || exit 1
  me="$(forgejo_api "the signed-in user" GET /user)" || exit 1
  login="$(jq -r '.login // empty' <<< "$me")"
  path="/orgs/${1%%/*}/repos"
  if [ "$(printf '%s' "${1%%/*}" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$login" | tr '[:upper:]' '[:lower:]')" ]; then path=/user/repos; fi
  body="$(jq -cn --arg name "${1#*/}" '{name: $name, private: true}')"
  forgejo_call POST "$path" "$body"
  case "$forgejo_status" in
    2??) ;;
    *) echo "cannot create $1 - Forgejo answered $(forgejo_said)" >&2; exit 1 ;;
  esac
  git -C "$2" remote add origin "$base/$1.git"
  sign_in_line_set "$2" "$base"
  forgejo_git -C "$2" push --quiet -u origin HEAD
)

# repo_default_branch <owner/repo>: nothing for a repository without a commit, which has none
repo_default_branch() {
  local repo
  repo="$(forgejo_api "the default branch of $1" GET "/repos/$1")" || exit 1
  jq -r 'if .empty then empty else .default_branch // empty end' <<< "$repo"
}

# repo_file_tree <owner/repo>: every file of the default branch, as {tree: [{path, type}...], truncated: false}.
# The listing is paged by total_count: the truncated flag of Forgejo is true on every page of a tree longer
# than one, so it says nothing about the end. The first page names the default branch by HEAD and answers the
# sha of its tree; every later page asks for that tree, because HEAD is resolved again by each request and a
# branch that moves between two pages would otherwise mix two trees. The count of the first page is the count
# to reach. A listing that ends before it stops the caller.
repo_file_tree() {
  local page=1 got=0 total chunk count entries ref=HEAD tree=""
  entries="$(mktemp)"
  while :; do
    chunk="$(forgejo_api "the files of $1" GET "/repos/$1/git/trees/$ref?recursive=true&per_page=1000&page=$page")" || { rm -f "$entries"; exit 1; }
    jq -c '.tree[]?' <<< "$chunk" >> "$entries"
    count="$(jq -r '(.tree // []) | length' <<< "$chunk")"
    if [ "$page" -eq 1 ]; then
      total="$(jq -r '.total_count // 0' <<< "$chunk")"
      tree="$(jq -r '.sha // empty' <<< "$chunk")"
    fi
    got=$((got + count))
    [ "$got" -lt "$total" ] || break
    [ "$count" -gt 0 ] || { rm -f "$entries"; die "the files of $1 ended at $got of $total entries"; }
    [ -n "$tree" ] || { rm -f "$entries"; die "the files of $1: Forgejo named no tree for the default branch, so the next page cannot be pinned to it"; }
    ref="$tree"
    page=$((page + 1))
  done
  jq -cs '{tree: ., truncated: false}' "$entries"
  rm -f "$entries"
}

# repo_head_revision <owner/repo>: the commit the default branch stands at; exit 3 for a repository that is not
# there or has no commit
repo_head_revision() (
  local branch
  forgejo_call GET "/repos/$1"
  case "$forgejo_status" in
    2??) ;;
    404) exit 3 ;;
    *) echo "cannot read $1 - Forgejo answered $(forgejo_said)" >&2; exit 1 ;;
  esac
  [ "$(jq -r '.empty // false' <<< "$forgejo_body")" = false ] || exit 3
  branch="$(jq -r '.default_branch // empty' <<< "$forgejo_body")"
  [ -n "$branch" ] || { echo "cannot read $1: Forgejo named no default branch" >&2; exit 1; }
  forgejo_call GET "/repos/$1/branches/$branch"
  case "$forgejo_status" in
    2??) ;;
    *) echo "cannot read the branch $branch of $1 - Forgejo answered $(forgejo_said)" >&2; exit 1 ;;
  esac
  jq -er '.commit.id | select(type == "string" and test("^[0-9a-f]{40,64}$"))' <<< "$forgejo_body" 2>/dev/null \
    || { echo "cannot read the branch $branch of $1: Forgejo named no commit id" >&2; exit 1; }
)

# repo_file_at <owner/repo> <revision> <path> <file>: the contents of the path at that commit; a 404 names no file
repo_file_at() (
  forgejo_call GET "/repos/$1/contents/$3?ref=$2"
  case "$forgejo_status" in
    2??) ;;
    404) exit 3 ;;
    *) echo "cannot read $3 of $1 at $2 - Forgejo answered $(forgejo_said)" >&2; exit 1 ;;
  esac
  forge_content_file "$3 of $1 at $2" "$forgejo_body" "$4" || exit 1
)

# forge_repo_visibility <owner/repo>: public or private, from the private field of the repository; fails,
# saying why, where Forgejo does not answer or the field is no boolean.
forge_repo_visibility() (
  local repo
  repo="$(forgejo_api "the visibility of $1" GET "/repos/$1")" || exit 1
  jq -er 'if (.private | type) == "boolean" then (if .private then "private" else "public" end)
    else error("private is not boolean") end' <<< "$repo" 2>/dev/null \
    || { echo "cannot establish the visibility of $1: private was not a boolean in Forgejo's answer" >&2; exit 1; }
)

# commit_checked <checkout> <sha>: the combined commit status of the sha, over every context (the pipeline posts
# the context check). green on success; red on error, failure or warning; pending while it is pending or no status
# exists yet (Forgejo answers {} then); unreadable when the query failed or the state is none of these, and
# then Forgejo's words are on stderr.
commit_checked() {
  local repo state total
  repo="$(origin_repo "$1")" || { echo unreadable; echo "$1 has no origin to ask for the checks" >&2; return 0; }
  forgejo_call GET "/repos/$repo/commits/$2/status"
  case "$forgejo_status" in
    2??) ;;
    *) echo unreadable; echo "Forgejo answered $(forgejo_said)" >&2; return 0 ;;
  esac
  { read -r state total || true; } < <(jq -r '[((.state // "") | if . == "" then "none" else . end), (.total_count // 0)] | @tsv' <<< "$forgejo_body" 2>/dev/null)
  if [ "${total:-}" = 0 ]; then echo pending; return 0; fi
  case "${state:-}" in
    success) echo green ;;
    error|failure|warning) echo red ;;
    pending) echo pending ;;
    *) echo unreadable; echo "Forgejo answered $forgejo_status with no state the harness knows (${state:-no JSON}) for the checks of $2" >&2 ;;
  esac
}

# signed_in_user: the login the token belongs to; exit 1 where there is no token, no URL or Forgejo refuses
# the token. It says nothing on stderr: forge_doctor says why.
signed_in_user() (
  exec 2>/dev/null
  forgejo_call GET /user
  [ "$forgejo_status" = 200 ] || exit 1
  jq -er '.login // empty' <<< "$forgejo_body"
)

# clone_sign_in <checkout> [dry]: a checkout whose origin is on this instance gets, in its own .git/config, the
# line that makes git ask ai-core git-credential for the token; an origin over ssh signs in as it is. Prints the
# report line when it set the line (with dry: would set it), nothing when it stood there or the origin is elsewhere.
clone_sign_in() (
  local url origin
  url="$(config_value FORGEJO_URL "")" || exit 1
  url="${url%/}"
  [ -n "$url" ] || exit 0
  origin="$(git -C "$1" remote get-url origin 2>/dev/null)" || exit 0
  case "$origin" in "$url"/*) ;; *) exit 0 ;; esac
  ! sign_in_line_stands "$1" "$url" || exit 0
  [ "${2:-}" = dry ] || sign_in_line_set "$1" "$url"
  echo "credential.$url.helper $([ "${2:-}" = dry ] && echo "would be set" || echo set) in .git/config: git asks ai-core git-credential for the token"
)

# forge_doctor: the lines `ai-core doctor` prints for the forge, through doctor's own report and problem, which
# doctor.sh defines. The token is asked of the instance and never printed.
forge_doctor() {
  local url command out origin said line_args=()
  if ! url="$(config_value FORGEJO_URL "")" || ! command="$(config_value FORGEJO_TOKEN_COMMAND "")"; then
    echo "  forge: forgejo"
    report forge unreadable "the settings that hold FORGEJO_URL and FORGEJO_TOKEN_COMMAND cannot be read (see above)"; problem
    return 0
  fi
  if [ -z "$url" ] || [ -z "$command" ]; then
    echo "  forge: forgejo"
    report forge "not configured" "set FORGEJO_URL and FORGEJO_TOKEN_COMMAND in .ai-core/config.env"; problem
    return 0
  fi
  if ! out="$( { forgejo_call GET /user && printf '%s' "$forgejo_status"; } 2>&1 )"; then
    echo "  forge: forgejo"
    report forge "no token" "$(printf '%s' "$out" | tr -s '\r\n' '  ' | sed 's/^error: //')"; problem
    return 0
  fi
  case "$out" in
    200) echo "  forge: forgejo (${url%/}, the token answers)" ;;
    000) echo "  forge: forgejo"; report forge "not reachable" "${url%/} did not answer"; problem; return 0 ;;
    401|403) echo "  forge: forgejo"; report forge refused "${url%/} refuses the token (status $out); check FORGEJO_TOKEN_COMMAND"; problem; return 0 ;;
    *) echo "  forge: forgejo"; report forge "unexpected" "the API of ${url%/} answered $out"; problem; return 0 ;;
  esac
  # git signs in on its own: the origin of the checkout the doctor runs in answers, over ssh or through the line
  # clone_sign_in sets
  origin="$(git remote get-url origin 2>/dev/null)" || return 0
  case "$origin" in *"$(forge_host)"[:/]*) ;; *) return 0 ;; esac
  case "$origin" in "${url%/}"/*)
    sign_in_line_stands . "${url%/}" || line_args=(-c "credential.${url%/}.helper=" -c "credential.${url%/}.helper=$FORGEJO_CREDENTIAL_HELPER") ;;
  esac
  said="$(mktemp)"
  if GIT_TERMINAL_PROMPT=0 forgejo_git ${line_args[@]+"${line_args[@]}"} ls-remote origin >/dev/null 2>"$said"; then
    if [ ${#line_args[@]} -gt 0 ]; then
      report origin "no sign-in" "git ls-remote reaches the origin through the line init would set; the line is not set in this checkout, ai-core init sets it"
    else
      report origin answers "git ls-remote reaches the origin of this checkout"
    fi
  else
    report origin refused "git ls-remote could not read the origin: $(tr -s '\r\n' '  ' < "$said" | cut -c1-200)"; problem
  fi
  rm -f "$said"
}
