#!/usr/bin/env bash
# ai-core git-credential get|store|erase: git's credential helper for a checkout whose origin is on the
# Forgejo instance FORGEJO_URL names. git runs it, as the line `credential.<FORGEJO_URL>.helper` of the
# clone says (ai-core init and the clone set it), gives it the host it wants a login for on standard input,
# and the helper answers with the token, read from FORGEJO_TOKEN_COMMAND at that moment. The token stands in
# no file and no argument; a changed command takes effect at once, because nothing was copied.
#
#   ai-core git-credential get       the answer git asks for; store and erase do nothing
#
# The settings are those of the checkout git runs in (.ai-core/config.env, or the environment); a clone
# that has none, such as the clone of a project harness, takes those of its project folder.
# A host other than FORGEJO_URL's gets no answer, so a token never goes to another server.
set -euo pipefail

CORE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$CORE/lib/forgejo/forge.sh"

case "${1:-}" in
  get) ;;
  store|erase) cat > /dev/null; exit 0 ;;
  *) echo "usage: ai-core git-credential get|store|erase" >&2; exit 2 ;;
esac

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

[ "$protocol://$host" = "$(forgejo_url)" ] || exit 0
token="$(token_from_command FORGEJO_TOKEN_COMMAND)" || exit 1
printf 'username=ai-core\npassword=%s\n' "$token"
