#!/usr/bin/env bash
# push of a harness clone; one section of the suite, run by tests/check.sh with the others
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

section "push: what changed in a harness clone beside the repositories is committed with the No-issue trailer the gate wants and pushed, a message that names an issue gets none, a second run has nothing, on both twins"
for twin in sh ps1; do
  H="$WORK/push-folder-$twin"; mkdir -p "$H"
  git init -q --bare "$WORK/push-origin-$twin.git"
  git clone -q "$WORK/push-origin-$twin.git" "$H/shop-ai-core" 2>/dev/null
  git -C "$H/shop-ai-core" config core.autocrlf false
  echo one > "$H/shop-ai-core/README.md"; git -C "$H/shop-ai-core" add -A; git -C "$H/shop-ai-core" -c user.name=check -c user.email=check@localhost commit -q -m first; git -C "$H/shop-ai-core" push -q -u origin HEAD
  mkdir -p "$H/shop-ai-core/rules"; printf '## Releases\n\n- **A release is a tag.** [review]\n' > "$H/shop-ai-core/rules/35-releases.md"
  if [ "$twin" = sh ]; then
    (cd "$H" && HOME="$H" GIT_AUTHOR_NAME=check GIT_AUTHOR_EMAIL=check@localhost GIT_COMMITTER_NAME=check GIT_COMMITTER_EMAIL=check@localhost bash "$ROOT/bin/push.sh" "the release rule" > "$WORK/push-$twin.log" 2>&1) || fail "push.sh (see $WORK/push-$twin.log)"
    (cd "$H" && HOME="$H" bash "$ROOT/bin/push.sh" > "$WORK/push-$twin-2.log" 2>&1) || fail "push.sh second run (see $WORK/push-$twin-2.log)"
  else
    (cd "$H" && HOME="$H" USERPROFILE="$(native "$H")" GIT_AUTHOR_NAME=check GIT_AUTHOR_EMAIL=check@localhost GIT_COMMITTER_NAME=check GIT_COMMITTER_EMAIL=check@localhost pwsh -NoProfile -File "$ROOT/bin/push.ps1" "the release rule" > "$WORK/push-$twin.log" 2>&1) || fail "push.ps1 (see $WORK/push-$twin.log)"
    (cd "$H" && HOME="$H" USERPROFILE="$(native "$H")" pwsh -NoProfile -File "$ROOT/bin/push.ps1" > "$WORK/push-$twin-2.log" 2>&1) || fail "push.ps1 second run (see $WORK/push-$twin-2.log)"
  fi
  grep -aq 'shop-ai-core: committed 1 file(s): the release rule' "$WORK/push-$twin.log" || fail "push.$twin did not commit with the message (see $WORK/push-$twin.log)"
  grep -aq 'shop-ai-core: pushed to' "$WORK/push-$twin.log" || fail "push.$twin did not push"
  [ "$(git -C "$WORK/push-origin-$twin.git" log --format=%s -1)" = "the release rule" ] || fail "push.$twin: origin does not carry the commit"
  [ "$(git -C "$WORK/push-origin-$twin.git" log -1 --format='%(trailers:key=No-issue,valueonly)' | tr -d '\n')" = "the release rule, committed and pushed by ai-core push" ] || fail "push.$twin: the commit carries no No-issue trailer with the message: $(git -C "$WORK/push-origin-$twin.git" log -1 --format=%B | tr '\n' '|')"
  grep -aq 'shop-ai-core: nothing to push' "$WORK/push-$twin-2.log" || fail "push.$twin second run did not say nothing to push"
  printf 'x\n' > "$H/shop-ai-core/labels.tsv"
  if [ "$twin" = sh ]; then
    (cd "$H" && HOME="$H" GIT_AUTHOR_NAME=check GIT_AUTHOR_EMAIL=check@localhost GIT_COMMITTER_NAME=check GIT_COMMITTER_EMAIL=check@localhost bash "$ROOT/bin/push.sh" "the labels of #7" > "$WORK/push-$twin-3.log" 2>&1) || fail "push.sh with an issue in the message (see $WORK/push-$twin-3.log)"
  else
    (cd "$H" && HOME="$H" USERPROFILE="$(native "$H")" GIT_AUTHOR_NAME=check GIT_AUTHOR_EMAIL=check@localhost GIT_COMMITTER_NAME=check GIT_COMMITTER_EMAIL=check@localhost pwsh -NoProfile -File "$ROOT/bin/push.ps1" "the labels of #7" > "$WORK/push-$twin-3.log" 2>&1) || fail "push.ps1 with an issue in the message (see $WORK/push-$twin-3.log)"
  fi
  [ "$(git -C "$WORK/push-origin-$twin.git" log --format=%s -1)" = "the labels of #7" ] || fail "push.$twin: origin does not carry the issue commit"
  [ -z "$(git -C "$WORK/push-origin-$twin.git" log -1 --format='%(trailers:key=No-issue,valueonly)' | tr -d '\n')" ] || fail "push.$twin: a message that names an issue got a No-issue trailer"
done
echo "  committed with the message and the No-issue trailer, pushed to origin, no trailer when the message names an issue, nothing on the second run, on both twins"
exit 0
