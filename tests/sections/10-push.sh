#!/usr/bin/env bash
# push of a harness clone; one section of the suite, run by tests/check.sh with the others
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

section "push: what changed in a harness clone beside the repositories is committed with the No-issue trailer the gate wants and pushed, a message that names an issue gets none, a second run has nothing"
H="$WORK/push-folder"; mkdir -p "$H"
git init -q --bare "$WORK/push-origin.git"
git clone -q "$WORK/push-origin.git" "$H/shop-ai-core" 2>/dev/null
echo one > "$H/shop-ai-core/README.md"; git -C "$H/shop-ai-core" add -A; git -C "$H/shop-ai-core" -c user.name=check -c user.email=check@localhost commit -q -m first; git -C "$H/shop-ai-core" push -q -u origin HEAD
mkdir -p "$H/shop-ai-core/rules"; printf '## Releases\n\n- **A release is a tag.** [review]\n' > "$H/shop-ai-core/rules/35-releases.md"
(cd "$H" && HOME="$H" GIT_AUTHOR_NAME=check GIT_AUTHOR_EMAIL=check@localhost GIT_COMMITTER_NAME=check GIT_COMMITTER_EMAIL=check@localhost bash "$ROOT/bin/push.sh" "the release rule" > "$WORK/push.log" 2>&1) || fail "push.sh (see $WORK/push.log)"
(cd "$H" && HOME="$H" bash "$ROOT/bin/push.sh" > "$WORK/push-2.log" 2>&1) || fail "push.sh second run (see $WORK/push-2.log)"
grep -aq 'shop-ai-core: committed 1 file(s): the release rule' "$WORK/push.log" || fail "push.sh did not commit with the message (see $WORK/push.log)"
grep -aq 'shop-ai-core: pushed to' "$WORK/push.log" || fail "push.sh did not push"
[ "$(git -C "$WORK/push-origin.git" log --format=%s -1)" = "the release rule" ] || fail "push.sh: origin does not carry the commit"
[ "$(git -C "$WORK/push-origin.git" log -1 --format='%(trailers:key=No-issue,valueonly)' | tr -d '\n')" = "the release rule, committed and pushed by ai-core push" ] || fail "push.sh: the commit carries no No-issue trailer with the message: $(git -C "$WORK/push-origin.git" log -1 --format=%B | tr '\n' '|')"
grep -aq 'shop-ai-core: nothing to push' "$WORK/push-2.log" || fail "push.sh second run did not say nothing to push"
printf 'x\n' > "$H/shop-ai-core/labels.tsv"
(cd "$H" && HOME="$H" GIT_AUTHOR_NAME=check GIT_AUTHOR_EMAIL=check@localhost GIT_COMMITTER_NAME=check GIT_COMMITTER_EMAIL=check@localhost bash "$ROOT/bin/push.sh" "the labels of #7" > "$WORK/push-3.log" 2>&1) || fail "push.sh with an issue in the message (see $WORK/push-3.log)"
[ "$(git -C "$WORK/push-origin.git" log --format=%s -1)" = "the labels of #7" ] || fail "push.sh: origin does not carry the issue commit"
[ -z "$(git -C "$WORK/push-origin.git" log -1 --format='%(trailers:key=No-issue,valueonly)' | tr -d '\n')" ] || fail "push.sh: a message that names an issue got a No-issue trailer"
# an agent below Sonnet is refused before the commit, and nothing reaches origin
mkdir -p "$H/shop-ai-core/agents"; printf -- '---\nname: cheap\ndescription: runs on haiku\nmodel: haiku\n---\n' > "$H/shop-ai-core/agents/cheap.md"
before="$(git -C "$WORK/push-origin.git" rev-parse HEAD)"
(cd "$H" && HOME="$H" bash "$ROOT/bin/push.sh" "a cheap agent" > "$WORK/push-3.log" 2>&1) && fail "push.sh pushed a harness whose agent names haiku"
grep -aq "cheap.md: model 'haiku' is below Sonnet" "$WORK/push-3.log" && grep -aq 'shop-ai-core: not committed; rules-check found the problems above' "$WORK/push-3.log" && [ "$(git -C "$WORK/push-origin.git" rev-parse HEAD)" = "$before" ] || fail "push.sh did not refuse the harness with an agent below Sonnet (see $WORK/push-3.log)"
# with the push gate armed in the clone, a plain push to the default branch is refused and ai-core push, a path of the harness, goes through
mkdir -p "$WORK/push-hooks"; printf '#!/bin/sh\nexec bash "%s/bin/pre-push.sh" "$@"\n' "$ROOT" > "$WORK/push-hooks/pre-push"; chmod +x "$WORK/push-hooks/pre-push"
rm -rf "$H/shop-ai-core/agents"
git -C "$H/shop-ai-core" config user.email check@localhost; git -C "$H/shop-ai-core" config user.name check
git -C "$H/shop-ai-core" config core.hooksPath "$WORK/push-hooks"
before="$(git -C "$WORK/push-origin.git" rev-parse HEAD)"
git -C "$H/shop-ai-core" commit -q --allow-empty -m 'A plain push of the default branch #7'
plain="$(git -C "$H/shop-ai-core" push origin HEAD 2>&1)" && fail "a plain push to the default branch went through the armed gate"
grep -aq 'takes no plain push' <<< "$plain" && [ "$(git -C "$WORK/push-origin.git" rev-parse HEAD)" = "$before" ] || fail "the plain push was refused for another reason, or moved origin: $plain"
printf 'y\n' > "$H/shop-ai-core/more.tsv"
(cd "$H" && HOME="$H" bash "$ROOT/bin/push.sh" "more of #7" > "$WORK/push-4.log" 2>&1) || fail "push.sh through the armed gate (see $WORK/push-4.log)"
[ "$(git -C "$WORK/push-origin.git" log --format=%s -1)" = "more of #7" ] || fail "push.sh: the armed gate did not let ai-core push through: $(cat "$WORK/push-4.log")"
echo "  committed with the message and the No-issue trailer, pushed to origin, no trailer when the message names an issue, nothing on the second run, an agent below Sonnet refused before the commit, an armed gate refusing a plain push and letting ai-core push through"
exit 0
