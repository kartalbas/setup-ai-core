#!/usr/bin/env bash
# ai-core git-credential get|store|erase: git's credential helper for the Forgejo instance FORGEJO_URL names.
# git runs it, as the line `credential.<FORGEJO_URL>.helper` says: in the clone (ai-core init and the clone set it),
# in the user's git configuration (ai-core init sets it there too, for git that a tool starts in a repository of its
# own, such as the cache of a package manager), or in the environment the push gate passes to a repository's check
# (sign_in_line_export). git gives it the host it wants a login for on standard input, and the helper answers with the
# token, read from FORGEJO_TOKEN_COMMAND at that moment. The token stands in no file and no argument; a changed
# command takes effect at once, because nothing was copied.
#
#   ai-core git-credential get       the answer git asks for; store and erase do nothing
#
# The settings are those of the checkout git runs in (.ai-core/config.env, or the environment), where that checkout
# names this helper in its own .git/config or the environment carries FORGEJO_URL and FORGEJO_TOKEN_COMMAND; a clone
# that has none, such as the clone of a project harness, takes those of its project folder. Where they name another
# instance than the one git asks for, or there are none it may take, the settings files that init registered in the
# user's git configuration for that instance answer, and refuse where they yield different tokens.
# A host other than FORGEJO_URL's gets no answer, so a token never goes to another server.
set -euo pipefail

CORE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$CORE/lib/forgejo/forge.sh"

case "${1:-}" in
  get) ;;
  store|erase) cat > /dev/null; exit 0 ;;
  *) echo "usage: ai-core git-credential get|store|erase" >&2; exit 2 ;;
esac

# git started with --git-dir hands its repository down in these, and that one is no checkout of the project
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR
top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ ! -f "${top:-$PWD}/.ai-core/config.env" ]; then
  folder="$(project_folder_of "${top:-$PWD}")"
  if [ -f "$folder/.ai-core/config.env" ]; then cd "$folder"; fi
fi

protocol=""; host=""
while IFS= read -r line; do
  line="${line%$'\r'}"
  [ -n "$line" ] || break
  case "$line" in protocol=*) protocol="${line#protocol=}" ;; host=*) host="${line#host=}" ;; esac
done
requested="$protocol://$host"

# The settings of the place git runs in answer only where the harness signed git in there: the checkout's own .git/config
# holds the pair for this instance (init and the clone set it), or git's environment carries both settings (ai-core's own
# git and the push gate). A .ai-core/config.env anywhere else, such as one that a clone nobody initialized tracks, is not
# the user's word: its token command never runs, and only the files init registered answer.
signed_in_here=""
if { [ -n "${FORGEJO_URL:-}" ] && [ -n "${FORGEJO_TOKEN_COMMAND:-}" ]; } || { [ -n "$top" ] && sign_in_line_stands "$top" "$requested"; }; then
  signed_in_here=1
fi
url=""
if [ -n "$signed_in_here" ]; then
  url="$(config_value FORGEJO_URL "")" || exit 1
  [ -z "$url" ] || url="$(forgejo_url_of "$url")" || exit 1
fi
# a trace of this script (bash -x) prints every assignment and argument it expands, the token among them
set +x
if [ "$url" = "$requested" ]; then
  token="$(token_from_command FORGEJO_TOKEN_COMMAND)" || exit 1
else
  rc=0; token="$(registered_token "$requested")" || rc=$?
  case "$rc" in
    0) ;;
    3) [ -z "$signed_in_here" ] || [ -n "$url" ] || forgejo_url > /dev/null; exit 0 ;;   # forgejo_url stops here, naming the missing FORGEJO_URL
    4) echo "ai-core git-credential: no settings file registered for $requested names it as FORGEJO_URL; ai-core init in a checkout of it registers its file" >&2; exit 0 ;;
    *) exit 1 ;;
  esac
fi
printf 'username=ai-core\npassword=%s\n' "$token"
