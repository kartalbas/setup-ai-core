#!/usr/bin/env bash
# tests/git-http-server.mjs stays up when git exits before it has read the request body, and answers the next
# request. Nothing here reaches a network.
#
#   bash tests/git-http-server.test.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

section "the git server of the Forgejo tests survives a git that hangs up"
mkdir -p "$WORK/remote/example-org"; git init -q --bare "$WORK/remote/example-org/example-repo.git"
printf 'server-token\n' > "$WORK/token"; : > "$WORK/log"
node "$ROOT/tests/git-http-server.mjs" "$WORK/remote" "$WORK/token" "$WORK/log" > "$WORK/port" 2> "$WORK/server-err" &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true; [ -n "${KEEP_WORK:-}" ] || rm -rf "$WORK"' EXIT
waited=0
while [ ! -s "$WORK/port" ]; do
  waited=$((waited + 1)); [ "$waited" -le 100 ] || fail "the git server did not start"
  sleep 0.1
done
BASE="http://127.0.0.1:$(cat "$WORK/port")"
refs_status() { curl -s -o /dev/null -w '%{http_code}' -u any:server-token "$BASE/example-org/example-repo.git/info/refs?service=git-upload-pack"; }
[ "$(refs_status)" = 200 ] || fail "innocent: the server does not answer a plain request before any hang-up"

# git http-backend answers 404 for a repository that is not there and exits without reading the body, so a body
# larger than the pipe buffer is written into a pipe nobody reads
head -c 20000000 /dev/zero > "$WORK/big-body"
curl -s -o /dev/null -u any:server-token -H 'Expect:' -H 'Content-Type: application/x-git-upload-pack-request' \
  --data-binary @"$WORK/big-body" "$BASE/example-org/missing.git/git-upload-pack" || true
sleep 0.3
kill -0 "$SERVER_PID" 2>/dev/null || fail "the server died when git exited before reading the request body: $(head -5 "$WORK/server-err")"
[ "$(refs_status)" = 200 ] || fail "the server did not answer the request after a git that exited before reading the body"
echo "  git exits before reading the request body: the server stays up and answers the next request"
