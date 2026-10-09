#!/usr/bin/env bash
# What every section of the suite starts with: the root, fail, native, a throwaway directory of
# its own, and the stand-ins a section puts on the PATH. Sourced by tests/sections/*.sh; not run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
# pwsh on Windows needs a native path
native() { cygpath -w "$1" 2>/dev/null || echo "$1"; }
section() { echo "==> $1"; }
WORK="$(mktemp -d)"
[ -n "${KEEP_WORK:-}" ] || trap 'rm -rf "$WORK"' EXIT   # KEEP_WORK=1 leaves the directory for a look
# the number of generic rule sections, what an assembled rules.md is measured against
SECTIONS="$(ls "$ROOT"/rules/[0-9][0-9]-*.md | wc -l | tr -d ' ')"

# A push init makes to an origin that is not there fails at once instead of asking for a login
export GIT_TERMINAL_PROMPT=0
# The commits init and pre-push --install make in the scratch repositories need an identity, and a
# runner has none configured
export GIT_AUTHOR_NAME=check GIT_AUTHOR_EMAIL=check@localhost GIT_COMMITTER_NAME=check GIT_COMMITTER_EMAIL=check@localhost
# pwsh on Linux colours an error record even when it is captured, and a test that reads the text
# then reads escape codes; NO_COLOR is honoured by PowerShell 7.2+
export NO_COLOR=1
# session-start does not ask the origins here: nothing in this suite reaches the network
export AI_CORE_UPDATE_CHECK=never
# A team-modes table whose probes always pass, so the tools of this machine never decide a check
printf 'claude\tmode\ton\talways\t-\t-\ncodex\tmode\ton\talways\t-\t-\ngemini\tmode\ton\talways\t-\t-\n' > "$WORK/modes.tsv"; export TEAM_MODES_FILE="$WORK/modes.tsv"

# A stand-in gh keeps GitHub on this disk: bare repositories under $GH_FAKE/github.com/<org>/<name>.git
make_gh_fake() {
GH_FAKE="$WORK/github"; mkdir -p "$GH_FAKE/github.com/example-org" "$WORK/ghbin"; export GH_FAKE
cat > "$WORK/ghbin/gh" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "repo view")   [ -d "$GH_FAKE/github.com/$3.git" ] ;;
  "repo clone")  git clone -q "$GH_FAKE/github.com/$3.git" "$4" ;;
  "repo create") [ "${3%%/*}" != nocreate-org ] && git init -q --bare "$GH_FAKE/github.com/$3.git" && git -C "$6" remote add origin "$GH_FAKE/github.com/$3.git" && git -C "$6" push -q -u origin HEAD ;;
  "run list") if [ -f "$GH_FAKE/run-broken" ]; then echo 'HTTP 502: Bad Gateway' >&2; exit 1; fi
              if [ -f "$GH_FAKE/run-fail" ]; then rm -f "$GH_FAKE/run-fail"; echo 'HTTP 502: Bad Gateway' >&2; exit 1; fi
              if [ -f "$GH_FAKE/run-pending" ]; then rm -f "$GH_FAKE/run-pending"; [ -z "${GH_FAKE_MOVE:-}" ] || git -C "$GH_FAKE_MOVE" commit -q --allow-empty -m "moved during the wait" >/dev/null 2>&1; echo '[{"status":"in_progress","conclusion":null}]'; else echo '[{"status":"completed","conclusion":"success"}]'; fi ;;
  "auth status") exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/ghbin/gh"
GH_FAKE_WIN="$(native "$GH_FAKE" | sed 's|\\|/|g')"
GH_FAKE_BS="$(native "$GH_FAKE" | sed 's|/|\\|g')"
printf '@echo off\r\nif "%%1 %%2"=="repo view" (if exist "%s/github.com/%%3.git" (exit /b 0) else (exit /b 1))\r\nif "%%1 %%2"=="repo clone" (git clone -q "%s/github.com/%%3.git" "%%4" & exit /b %%ERRORLEVEL%%)\r\nif "%%1 %%2 %%3"=="repo create nocreate-org/nocreate-ai-core" exit /b 1\r\nif "%%1 %%2"=="repo create" (git init -q --bare "%s/github.com/%%3.git" & git -C "%%6" remote add origin "%s/github.com/%%3.git" & git -C "%%6" push -q -u origin HEAD & exit /b %%ERRORLEVEL%%)\r\nif "%%1 %%2"=="auth status" exit /b 0\r\nif "%%1 %%2"=="run list" if exist "%s\\run-broken" (echo HTTP 502: Bad Gateway 1>&2 & exit /b 1)\r\nif "%%1 %%2"=="run list" if exist "%s\\run-fail" (del "%s\\run-fail" & echo HTTP 502: Bad Gateway 1>&2 & exit /b 1)\r\nif "%%1 %%2"=="run list" (if exist "%s\\run-pending" (del "%s\\run-pending" & (if defined GH_FAKE_MOVE git -C "%%GH_FAKE_MOVE%%" commit -q --allow-empty -m "moved during the wait" >nul 2>&1) & echo [{"status":"in_progress","conclusion":null}] & exit /b 0) else (echo [{"status":"completed","conclusion":"success"}] & exit /b 0))\r\nexit /b 1\r\n' "$GH_FAKE_WIN" "$GH_FAKE_WIN" "$GH_FAKE_WIN" "$GH_FAKE_WIN" "$GH_FAKE_BS" "$GH_FAKE_BS" "$GH_FAKE_BS" "$GH_FAKE_BS" "$GH_FAKE_BS" > "$WORK/ghbin/gh.cmd"
PATH_SH="$WORK/ghbin:$PATH"
}
