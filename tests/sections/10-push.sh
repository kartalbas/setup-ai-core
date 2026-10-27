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

section "push: a subject over 72 characters is refused before anything is committed, the list of changed files is cut to 72, a harness repository is not initialised and a checkout it serves is"
. "$ROOT/tests/unreadable.sh"
plant() {  # plant <name> <sed expression>: a copy of the harness whose push.sh has one check less
  harness_copy "$ROOT" "$WORK/push-$1"; sed -i.bak "$2" "$WORK/push-$1/bin/push.sh"; rm -f "$WORK/push-$1/bin/push.sh.bak"
  ! cmp -s "$ROOT/bin/push.sh" "$WORK/push-$1/bin/push.sh" || fail "the planted defect $1 changed nothing"
}
plant no-subject-limit 's/^\[ "\${#subject}" -le 72 \] || .*$/true/'
plant first-line-only "$(cat <<'SED'
s/^subject="\$(printf .*$/subject="${MESSAGE%%$'\\n'*}"/
SED
)"
plant no-fit 's/^    .* -le 72 ] || break$/    true/'
plant init-everywhere 's| \&\& ! harness_source_of "\$(pwd)" >/dev/null 2>\&1||'
shop="$H/shop-ai-core"; shop_head="$(git -C "$shop" rev-parse HEAD)"; shop_origin="$(git -C "$WORK/push-origin.git" rev-parse HEAD)"
push_from() {  # push_from <directory> <push.sh> <argument>...: push.sh run in that directory, its output in push-run.log and its status in rc
  local dir="$1" script="$2"
  shift 2
  rc=0; ( cd "$dir" && HOME="$H" bash "$script" "$@" > "$WORK/push-run.log" 2>&1 ) || rc=$?
}
subject_length() { git -C "$shop" log -1 --format=%s | tr -d '\n' | wc -c | tr -d ' '; }
long="$(printf 'A%.0s' {1..73})"
printf 'x\n' > "$shop/long.tsv"
push_from "$H" "$ROOT/bin/push.sh" "$long"
[ "$rc" -eq 2 ] || fail "a message whose first line has 73 characters was not refused with status 2 (status $rc)"
grep -aq 'the subject of the message, its first paragraph, has 73 characters, at most 72 are allowed' "$WORK/push-run.log" || fail "the refusal does not name the length: $(cat "$WORK/push-run.log")"
[ "$(git -C "$shop" rev-parse HEAD)" = "$shop_head" ] || fail "a message of 73 characters left a commit behind"
[ "$(git -C "$WORK/push-origin.git" rev-parse HEAD)" = "$shop_origin" ] || fail "a message of 73 characters moved origin"
push_from "$H" "$WORK/push-no-subject-limit/bin/push.sh" "$long"
[ "$(git -C "$shop" rev-parse HEAD)" != "$shop_head" ] || fail "planted: without the check, the commit of 73 characters is not made, so the check above cannot go red"
[ "$rc" -eq 1 ] || fail "planted: the armed gate did not refuse the subject of 73 characters (status $rc)"
git -C "$shop" reset -q --hard "$shop_head"
# two lines of 40 with no blank line between them: git joins them into one subject of 81
two_lines="$(printf '%s\n%s' "$(printf 'B%.0s' {1..40})" "$(printf 'C%.0s' {1..40})")"
printf 'x\n' > "$shop/long.tsv"
push_from "$H" "$ROOT/bin/push.sh" "$two_lines"
[ "$rc" -eq 2 ] && grep -aq 'its first paragraph, has 81 characters' "$WORK/push-run.log" || fail "a first paragraph of two lines of 40 was not refused with status 2 and its length (status $rc): $(cat "$WORK/push-run.log")"
[ "$(git -C "$shop" rev-parse HEAD)" = "$shop_head" ] || fail "a first paragraph of 81 characters left a commit behind"
push_from "$H" "$WORK/push-first-line-only/bin/push.sh" "$two_lines"
[ "$(git -C "$shop" rev-parse HEAD)" != "$shop_head" ] && [ "$rc" -eq 1 ] || fail "planted: measuring the first line alone, the subject of 81 is not committed and refused, so the check above cannot go red (status $rc)"
git -C "$shop" reset -q --hard "$shop_head"
printf 'x\n' > "$shop/long.tsv"
push_from "$H" "$ROOT/bin/push.sh" "$(printf 'A%.0s' {1..72})"
[ "$rc" -eq 0 ] && [ "$(subject_length)" -eq 72 ] || fail "a first line of 72 characters was refused: $(cat "$WORK/push-run.log")"
shop_head="$(git -C "$shop" rev-parse HEAD)"
# the generated message: three files of 44 characters each would make a subject of 136
for n in one two three; do printf 'x\n' > "$shop/$(printf "$n%.0s" {1..14})$n.tsv"; done
first_name="$(printf 'one%.0s' {1..14})one.tsv"
push_from "$H" "$WORK/push-no-fit/bin/push.sh"
[ "$(subject_length)" -gt 72 ] && [ "$rc" -eq 1 ] || fail "planted: without the cut, the list of three files is no subject above 72 (length $(subject_length), status $rc)"
git -C "$shop" reset -q --hard "$shop_head"
for n in one two three; do printf 'x\n' > "$shop/$(printf "$n%.0s" {1..14})$n.tsv"; done
push_from "$H" "$ROOT/bin/push.sh"
[ "$rc" -eq 0 ] || fail "the generated message was refused: $(cat "$WORK/push-run.log")"
[ "$(git -C "$shop" log -1 --format=%s)" = "$first_name (+2)" ] || fail "the generated message is not the first name and the count of the rest: $(git -C "$shop" log -1 --format=%s)"
[ "$(git -C "$WORK/push-origin.git" rev-parse HEAD)" = "$(git -C "$shop" rev-parse HEAD)" ] || fail "the generated message did not reach origin"
shop_head="$(git -C "$shop" rev-parse HEAD)"
printf 'x\n' > "$shop/$(printf 'w%.0s' {1..80}).tsv"
push_from "$H" "$ROOT/bin/push.sh"
[ "$rc" -eq 0 ] && [ "$(git -C "$shop" log -1 --format=%s)" = '1 file(s) changed' ] || fail "a name that does not fit in 72 left no short subject: $(git -C "$shop" log -1 --format=%s)"
# init after the push: not in a harness repository, as before in a checkout the harness serves
probe="$H/probe-ai-core"; git init -q "$probe"; mkdir -p "$probe/.ai-core"; printf '/.ai-core/\n' >> "$probe/.git/info/exclude"
git -C "$probe" remote add origin https://github.com/example-org/probe-ai-core.git
app="$H/app"; git init -q "$app"; mkdir -p "$app/.ai-core"; printf 'UPDATE_CHECK="never"\n' > "$app/.ai-core/config.env"; printf '/.ai-core/\n' >> "$app/.git/info/exclude"
printf 'y\n' >> "$shop/more.tsv"
push_from "$probe" "$ROOT/bin/push.sh" "more of #8" --harness shop-ai-core
[ "$rc" -eq 0 ] || fail "ai-core push from a harness repository failed: $(cat "$WORK/push-run.log")"
grep -aq 'shop-ai-core: pushed to' "$WORK/push-run.log" || fail "ai-core push from a harness repository did not push: $(cat "$WORK/push-run.log")"
! grep -aq 'Refreshing this checkout\|init here reported a problem' "$WORK/push-run.log" || fail "ai-core push ran init in a harness repository: $(cat "$WORK/push-run.log")"
printf 'y\n' >> "$shop/more.tsv"
push_from "$probe" "$WORK/push-init-everywhere/bin/push.sh" "more of #9" --harness shop-ai-core
grep -aq 'note: init here reported a problem' "$WORK/push-run.log" || fail "planted: without the skip, init does not refuse in a harness repository, so the check above cannot go red: $(cat "$WORK/push-run.log")"
printf 'y\n' >> "$shop/more.tsv"
push_from "$app" "$ROOT/bin/push.sh" "more of #10" --harness shop-ai-core
[ "$rc" -eq 0 ] && grep -aq -- '--> This checkout is current' "$WORK/push-run.log" || fail "a checkout the harness serves was not refreshed: $(cat "$WORK/push-run.log")"
echo "  a subject of 73 refused before the commit, a first paragraph of two lines of 40 too, and one of 72 taken, three long names cut to the first and the count, a name too long for a subject replaced, no init in a harness repository, a checkout refreshed; each planted copy goes red"
exit 0
