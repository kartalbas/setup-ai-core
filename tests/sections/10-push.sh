#!/usr/bin/env bash
# push of a harness clone; one section of the suite, run by tests/check.sh with the others
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

section "push: what changed in a harness clone beside the repositories is committed and pushed, a second run has nothing, on both twins"
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
  grep -aq 'shop-ai-core: nothing to push' "$WORK/push-$twin-2.log" || fail "push.$twin second run did not say nothing to push"
done
echo "  committed with the message, pushed to origin, nothing on the second run, on both twins"
exit 0
