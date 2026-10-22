#!/usr/bin/env bash
# Work in flight at the switch of a project from GitHub to Plane: a branch or worktree named issue-<GitHub number>-...
# that was cut before the carry, and the work item the carry made of its issue under another number. TRACKER=plane
# in a project whose curl is the stand-in of tests/lib.sh, a local bare origin, a gh stand-in for the visibility
# of the repository, and dates planted into every commit and every branch (the reflog entry of a branch is dated by
# GIT_COMMITTER_DATE). Every rule is shown red on a copy of the tree with one planted defect and green on the real
# one, and the GitHub side stays pinned by tests/finish-issue.test.sh, tests/integrate-issue.test.sh,
# tests/start-issue.test.sh and tests/status.test.sh as they stand.
#
# The numbers: work item 44 was carried from GitHub issue 287 of example-org/example-repo, and a work item 287 was made after the
# carry, in the same project, so the number 287 is both. A branch issue-287-the-slug was cut on 2026-03-01, before
# work item 287 existed (2026-03-12), so it is work item 44's.
#
#   bash tests/plane-in-flight.test.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
make_plane_project
make_gh_fake
export GH_VISIBILITY=private
PATH_CURL="$WORK/ghbin:$PATH_CURL"

mkdir -p "$WORK/origins/example-org" "$WORK/trees"
ORIGIN="$WORK/origins/example-org/example-repo.git"
git init -q --bare -b master "$ORIGIN"
git -C "$P" remote set-url origin "$ORIGIN"
git -C "$P" checkout -q -B master
GIT_AUTHOR_DATE=2026-01-01T00:00:00Z GIT_COMMITTER_DATE=2026-01-01T00:00:00Z git -C "$P" commit -q --allow-empty -m "Start"
git -C "$P" push -q -u origin master
git -C "$P" remote set-head origin master

epoch() { date -u -d "$1" +%s; }
ai_in() { local dir="$1" command="$2"; shift 2; ( cd "$dir" && PATH="$PATH_CURL" bash "${ROOT_UNDER_TEST:-$ROOT}/bin/$command.sh" "$@" ); }
state_of() { planeq "const it=p.issues.find((i)=>i.sequence_id===$1);console.log(p.states.find((s)=>s.id===it.state).name)"; }
set_state() { planeset "p.issues.find((i)=>i.sequence_id===$1).state=p.states.find((s)=>s.name==='$2').id"; }
item() {  # item <number> <title> <created at> <external id or empty> [label...]: a work item of ENG made at that time
  local number="$1" title="$2" created="$3" external="$4"
  shift 4
  ITEM_CREATED_AT="$created" ITEM_EXTERNAL_SOURCE="${external:+github}" ITEM_EXTERNAL_ID="$external" plane_add_item "$number" "$title" "$@"
}
# cut <branch> <time> [start point]: the branch and its worktree under $WORK/trees, cut from origin/master unless a start point is given, at <time>
cut() {
  GIT_COMMITTER_DATE="$2" git -C "$P" branch -f --no-track "$1" "${3:-origin/master}" > /dev/null
  git -C "$P" branch -q --set-upstream-to=refs/remotes/origin/master "$1"
  git -C "$P" worktree add -q "$WORK/trees/$1" "$1"
}
work() { GIT_AUTHOR_DATE="$2" GIT_COMMITTER_DATE="$2" git -C "$WORK/trees/$1" commit -q --allow-empty -m "$3"; }   # work <branch> <time> <subject>
publish() { git -C "$WORK/trees/$1" push -q origin "$1:$1"; }
on_origin() { [ -n "$(git -C "$P" ls-remote --heads origin "refs/heads/$1")" ]; }
mutant_root() {  # mutant_root <file> <sed expression>: a copy of the tree with one planted defect, in $WORK/mutant; prints its path
  rm -rf "$WORK/mutant"; mkdir -p "$WORK/mutant"; cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/templates" "$WORK/mutant/"; cp "$ROOT/VERSION" "$WORK/mutant/"
  sed -i.bak "$2" "$WORK/mutant/$1"
  cmp -s "$ROOT/$1" "$WORK/mutant/$1" && fail "the planted defect changed nothing in $1: $2"
  printf '%s' "$WORK/mutant"
}
repo=example-org/example-repo

# --- the work items ---------------------------------------------------------------------------------
item 44 "Carried one" 2026-03-10T12:00:00Z "$repo#287" repo:example-repo
item 287 "Fresh 287" 2026-03-12T12:00:00Z "$repo#100" repo:example-repo
item 45 "Carried two" 2026-03-10T12:00:00Z "$repo#288" repo:example-repo
item 46 "Carried 291" 2026-03-10T12:00:00Z "$repo#291" repo:example-repo
item 291 "Of the other repository" 2026-03-12T12:00:00Z "" repo:other-repo
item 292 "Fresh 292" 2026-03-12T12:00:00Z "" repo:example-repo
item 293 "Fresh 293" 2026-03-10T12:00:00Z "" repo:example-repo
item 47 "Carried four" 2026-03-10T12:00:00Z "$repo#289" repo:example-repo
item 289 "Fresh 289" 2026-03-12T12:00:00Z "" repo:example-repo
item 50 "Carried from its own number" 2026-03-10T12:00:00Z "$repo#50" repo:example-repo

section "referenced_issue: which work item a reference to a number means"
ref() { plane_fn referenced_issue "$repo" "$@"; }
tab=$'\t'
[ "$(ref 287 "$(epoch 2026-03-13T00:00:00Z)")" = 287 ] || fail "(a) a reference made after work item 287 was made names it"
[ "$(ref 287 "$(epoch 2026-03-12T12:00:00Z)")" = 287 ] || fail "(a) a reference made in the second the work item was made names it"
[ "$(ref 287 "$(epoch 2026-03-01T00:00:00Z)")" = 44 ] || fail "(b) a reference made before work item 287 existed names the work item carried from #287"
[ "$(ref 293 "$(epoch 2026-03-01T00:00:00Z)")" = "${tab}names GitHub $repo#293, which no work item was carried from" ] || fail "(b) a reference made before work item 293 existed, with nothing carried from #293, names none: $(ref 293 "$(epoch 2026-03-01T00:00:00Z)")"
[ "$(ref 293)" = 293 ] || fail "(c) with no time, an own item nothing was carried from is the answer"
[ "$(ref 287)" = "${tab}names both #287 and #44, which was carried from $repo#287, and when it was made cannot be read" ] || fail "(c) with no time, both the own item and the carried one are named, and none is answered: $(ref 287)"
[ "$(ref 288 "$(epoch 2026-03-01T00:00:00Z)")" = 45 ] || fail "(d) without an own item the carried one is the answer"
[ "$(ref 288)" = 45 ] || fail "(d) without an own item and without a time the carried one is the answer"
[ "$(ref 291 "$(epoch 2026-03-01T00:00:00Z)")" = 46 ] || fail "(d) an item of another repository is no own item: the carried one is the answer"
[ "$(ref 291 "$(epoch 2026-03-20T00:00:00Z)")" = 46 ] || fail "(d) an item of another repository is no own item, however late the reference was made"
[ "$(ref 999 "$(epoch 2026-03-20T00:00:00Z)")" = 999 ] || fail "(d) where nothing exists the number itself stays, for its reader to refuse"
[ "$(ref 50 "$(epoch 2026-03-01T00:00:00Z)")" = 50 ] || fail "a reference made before the carry names the item carried from it under the same number: $(ref 50 "$(epoch 2026-03-01T00:00:00Z)")"
[ "$(ref 50)" = 50 ] || fail "with no time, an item carried from its own number is one work item, not both: $(ref 50)"
[ "$(plane_fn referenced_issue other-org/example-repo 287 "$(epoch 2026-03-01T00:00:00Z)")" = 287 ] || fail "a repository of another owner is not in the project: its reference stays"
echo "  referenced_issue: the own item from its creation on, the carried item before it or none, both named when the time is unknown, the carried item or the number itself without an own item, an item carried under its own number at any time"
planted="$(mutant_root lib/plane/tracker.sh 's/if \[ -n "\$own" \] \&\& \[ -n "\$at" \] \&\& \[ "\$at" -ge "\$own_at" \]; then/if [ -n "$own" ] \&\& [ -n "$at" ]; then/')"
[ "$(ROOT_UNDER_TEST="$planted" ref 287 "$(epoch 2026-03-01T00:00:00Z)")" = 287 ] || fail "planted: without the time rule a reference made before work item 287 should name it"
planted="$(mutant_root lib/plane/tracker.sh 's/^  if \[ "\$c" = "\$number" \]; then printf .*$/  [ "$c" != "$number" ] || c=""/')"
[ "$(ROOT_UNDER_TEST="$planted" ref 50 "$(epoch 2026-03-01T00:00:00Z)")" = "${tab}names GitHub $repo#50, which no work item was carried from" ] || fail "planted: with an item carried under its own number dropped, a reference made before the carry should name none"
planted="$(mutant_root lib/plane/tracker.sh 's/^  if \[ "\$c" = "\$number" \]; then printf .*$/  true/')"
[ "$(ROOT_UNDER_TEST="$planted" ref 50)" = "${tab}names both #50 and #50, which was carried from $repo#50, and when it was made cannot be read" ] || fail "planted: without the rule for an item carried under its own number, a reference without a time should name it twice"
echo "  planted: without the time rule 287 is answered before it existed; an item carried under its own number is dropped before the carry, or named twice without a time"

section "branch_started_at: the earliest of the oldest commit origin lacks and the oldest entry of the reflog"
started() { ( cd "$P" && PATH="$PATH_CURL" bash -c '. "$1/lib/board.sh"; shift; branch_started_at "$@"' _ "${ROOT_UNDER_TEST:-$ROOT}" "$@" ); }
cut issue-300-reflog 2026-03-01T00:00:00Z
work issue-300-reflog 2026-03-05T00:00:00Z "Later work"
[ "$(started issue-300-reflog)" = "$(epoch 2026-03-01T00:00:00Z)" ] || fail "the reflog entry of the cutting is older than the commit: $(started issue-300-reflog)"
cut issue-301-commit 2026-03-10T00:00:00Z
work issue-301-commit 2026-03-02T00:00:00Z "Older than the branch"
[ "$(started issue-301-commit)" = "$(epoch 2026-03-02T00:00:00Z)" ] || fail "a commit older than the reflog entry is the start: $(started issue-301-commit)"
publish issue-300-reflog
git -C "$P" worktree remove --force "$WORK/trees/issue-300-reflog"; git -C "$P" branch -q -D issue-300-reflog
[ "$(started issue-300-reflog)" = "$(epoch 2026-03-05T00:00:00Z)" ] || fail "a branch only on origin is as old as its oldest commit origin's master lacks: $(started issue-300-reflog)"
git -C "$P" push -q origin issue-300-reflog:master 2>/dev/null || git -C "$P" push -q origin "origin/issue-300-reflog:refs/heads/master"
git -C "$P" fetch -q origin
[ -z "$(started issue-300-reflog)" ] || fail "a branch only on origin whose every commit landed has no start: $(started issue-300-reflog)"
git -C "$P" worktree remove --force "$WORK/trees/issue-301-commit"; git -C "$P" branch -q -D issue-301-commit
echo "  branch_started_at: the reflog entry or the oldest commit, whichever is older; an origin branch by its commits; none where all landed"
planted="$(mutant_root lib/board.sh 's/| sort -n | sed -n 1p/| sort -rn | sed -n 1p/')"
cut issue-302-planted 2026-03-01T00:00:00Z
work issue-302-planted 2026-03-05T00:00:00Z "Later work"
[ "$(ROOT_UNDER_TEST="$planted" started issue-302-planted)" = "$(epoch 2026-03-05T00:00:00Z)" ] || fail "planted: the latest instead of the earliest time should read 2026-03-05"
git -C "$P" worktree remove --force "$WORK/trees/issue-302-planted"; git -C "$P" branch -q -D issue-302-planted
echo "  planted: the latest time instead of the earliest is told apart"

# --- the branches in flight, all cut before the carry ---------------------------------------------------
cut issue-287-the-slug 2026-03-01T00:00:00Z
cut issue-288-two 2026-03-02T00:00:00Z
cut issue-291-other 2026-03-02T00:00:00Z
cut issue-292-ghost 2026-03-02T00:00:00Z
cut issue-293-fresh 2026-03-11T00:00:00Z

section "session-start in a worktree named by a GitHub number"
start_here() { ai_in "$WORK/trees/$1" session-start 2>&1 || true; }
head_of() { printf '%s\n' "$1" | sed -n '/^This worktree carries/,/^labels:/p; /^carried from/p'; }
out="$(start_here issue-287-the-slug)"
grep -q '^This worktree carries issue #44\.' <<< "$out" || fail "session-start in issue-287-the-slug does not carry work item #44: $out"
grep -q '^#44 Carried one$' <<< "$out" || fail "session-start does not print the thread of #44: $out"
grep -q "^carried from $repo#287: this worktree is named by that GitHub number 287, and its commits name #44 from now on\$" <<< "$out" \
  || fail "the head of the thread does not say where #44 came from and what the commits name: $out"
! grep -q '^#287 Fresh 287' <<< "$out" || fail "session-start printed the thread of work item #287 for a worktree cut before it existed"
out="$(start_here issue-288-two)"
grep -q '^#45 Carried two$' <<< "$out" || fail "where work item #288 does not exist, the thread of #45 is not printed: $out"
out="$(start_here issue-291-other)"
grep -q '^#46 Carried 291$' <<< "$out" || fail "where work item #291 belongs to another repository, the thread of #46 is not printed: $out"
out="$(start_here issue-293-fresh)"
grep -q '^#293 Fresh 293$' <<< "$out" || fail "a worktree cut after its work item was made does not print that work item: $out"
! grep -q '^carried from' <<< "$out" || fail "a worktree cut after its work item was made says it was carried: $out"
mkdir -p "$WORK/trees/issue-292-ghost/.ai-core/rules"; echo "rules" > "$WORK/trees/issue-292-ghost/.ai-core/rules/rules.md"
out="$(start_here issue-292-ghost)"
grep -q "^Ready for task execution, but WITHOUT the issue: #292 could not be read (this worktree names GitHub $repo#292, which no work item was carried from)" <<< "$out" \
  || fail "a worktree whose GitHub number was never carried is not ready WITHOUT the issue, with the reason: $out"
echo "  session-start: the thread of the carried work item with its head, where #287 exists, does not exist or belongs to another repository; a fresh worktree as before; none carried is ready WITHOUT the issue"
start_here issue-287-the-slug > "$WORK/start-one" & start_here issue-287-the-slug > "$WORK/start-two" & wait
first="$(head_of "$(cat "$WORK/start-one")")"
grep -q '^#44 Carried one$' <<< "$first" || fail "the head of the first of two simultaneous session-starts has no thread: $first"
[ "$(head_of "$(cat "$WORK/start-two")")" = "$first" ] || fail "two session-starts at once in one worktree print different heads"
echo "  session-start: a second start at the same time prints the same head"
planted="$(mutant_root lib/plane/tracker.sh 's/if \[ -n "\$own" \] \&\& \[ -n "\$at" \] \&\& \[ "\$at" -ge "\$own_at" \]; then/if [ -n "$own" ] \&\& [ -n "$at" ]; then/')"
out="$(ROOT_UNDER_TEST="$planted" start_here issue-287-the-slug)"
grep -q '^#287 Fresh 287$' <<< "$out" || fail "planted: without the time rule session-start should print the thread of work item #287"
echo "  planted: without the time rule the thread of work item #287 is printed in the worktree of #44"

section "finish-issue after the switch: the worktree issue-287-the-slug is work item #44's"
forget() { planeset "const it=p.issues.find((i)=>i.sequence_id===$1);p.comments=p.comments.filter((c)=>c.issue!==it.id)"; set_state "$1" "${2:-implementing}"; }   # forget <number> [state]: no comment, in that state
comments_of() { planeq "const it=p.issues.find((i)=>i.sequence_id===$1);console.log(p.comments.filter((c)=>c.issue===it.id).map((c)=>c.comment_html).join('\n---\n'))"; }
set_state 44 implementing; set_state 287 ready
work issue-287-the-slug 2026-03-05T00:00:00Z "Do it (#287)"
publish issue-287-the-slug
git -C "$WORK/trees/issue-287-the-slug" push -q origin issue-287-the-slug:master
sha="$(git -C "$WORK/trees/issue-287-the-slug" rev-parse --short HEAD)"
elsewhere="issue-287-elsewhere"
stays() { [ -d "$WORK/trees/issue-287-the-slug" ] && git -C "$P" rev-parse -q --verify refs/heads/issue-287-the-slug > /dev/null && on_origin issue-287-the-slug; }

out="$(ai finish-issue 287 2>&1)" && fail "finish-issue 287 finished a work item that has no commit: $out"
grep -q 'the branch issue-287-the-slug belongs to #44, not to #287: it stays' <<< "$out" || fail "finish-issue 287 does not name the branch as #44's: $out"
stays || fail "finish-issue 287 touched the worktree or the branches of #44"
[ "$(state_of 44)" = implementing ] || fail "finish-issue 287 moved the card of #44"
echo "  finish-issue 287 (work item #287 made after the branch) leaves issue-287-the-slug, its worktree and its origin branch alone, and names them as #44's"

planted="$(mutant_root bin/finish-issue.sh 's/"\$number" \${carried_number:+"\$carried_number"})" || exit 1/"$number")" || exit 1/')"
out="$(ROOT_UNDER_TEST="$planted" ai finish-issue 44 2>&1)" || true
grep -q 'no worktree of issue 44 stands here' <<< "$out" || fail "planted: the carried number not matched should find no worktree of #44: $out"
stays || fail "planted: the carried number not matched should leave the branches in place"
forget 44
echo "  planted: with the carried number not matched, finish-issue 44 finds no worktree and the origin branch stays"

planted="$(mutant_root lib/plane/tracker.sh 's/if \[ -n "\$own" \] \&\& \[ -n "\$at" \] \&\& \[ "\$at" -ge "\$own_at" \]; then/if [ -n "$own" ] \&\& [ -n "$at" ]; then/')"
ROOT_UNDER_TEST="$planted" ai finish-issue 287 > /dev/null 2>&1 || true
[ ! -d "$WORK/trees/issue-287-the-slug" ] || fail "planted: without the time rule finish-issue 287 should remove the worktree of #44"
cut issue-287-the-slug 2026-03-01T00:00:00Z
publish issue-287-the-slug
forget 44
echo "  planted: without the time rule finish-issue 287 removes the worktree of #44"

cut "$elsewhere" 2026-03-01T00:00:00Z
git -C "$P" config "branch.$elsewhere.issueRepository" example-org/other-repo
out="$(ai finish-issue 44 2>&1)" || fail "finish-issue 44: $out"
grep -q 'Worktree .*issue-287-the-slug and its branch issue-287-the-slug removed' <<< "$out" || fail "finish-issue 44 did not remove the worktree: $out"
grep -q "the branch issue-287-elsewhere stays: it belongs to an issue of example-org/other-repo" <<< "$out" || fail "the worktree of an issue of another repository is not named: $out"
[ ! -d "$WORK/trees/issue-287-the-slug" ] && ! git -C "$P" rev-parse -q --verify refs/heads/issue-287-the-slug > /dev/null || fail "the worktree or the branch of #44 stands"
! on_origin issue-287-the-slug || fail "the origin branch issue-287-the-slug was not deleted"
[ -d "$WORK/trees/$elsewhere" ] && on_origin "$elsewhere" || [ -d "$WORK/trees/$elsewhere" ] || fail "the worktree of another repository's issue was removed"
[ "$(state_of 44)" = testing ] || fail "the card of #44 is not in testing: $(state_of 44)"
grep -q "^<pre>Landed on master:" <<< "$(comments_of 44)" && grep -q "$sha Do it (#287)" <<< "$(comments_of 44)" || fail "#44 does not hold the record listing the commit: $(comments_of 44)"
[ -z "$(comments_of 287)" ] || fail "work item #287 was told what landed: $(comments_of 287)"
echo "  finish-issue 44: removes the worktree and its branch, deletes the origin branch, writes the Landed record naming the commit (#287) on #44 and moves the card to testing; #287 is not touched"
git -C "$P" worktree remove --force "$WORK/trees/$elsewhere"; git -C "$P" branch -q -D "$elsewhere"

git -C "$WORK/trees/issue-293-fresh" rebase -q origin/master
work issue-293-fresh 2026-03-12T00:00:00Z "Do the fresh thing (#293)"
publish issue-293-fresh
git -C "$WORK/trees/issue-293-fresh" push -q origin issue-293-fresh:master
set_state 293 implementing
out="$(ai finish-issue 293 2>&1)" || fail "finish-issue 293: $out"
[ ! -d "$WORK/trees/issue-293-fresh" ] && [ "$(state_of 293)" = testing ] || fail "a worktree cut after its work item was made is not finished as before: $out"
echo "  finish-issue 293: a worktree cut after its work item was made is finished as on GitHub"

section "integrate-issue after the switch: the worktree issue-288-two is work item #45's"
subject_of() { git -C "$P" log -1 --format=%s "origin/master"; }
fetch() { git -C "$P" fetch -q origin; }
# land_in <branch> <number>: the commands run in the worktree of the branch, with the reviewer r1
land_in() { ai_in "$WORK/trees/$1" integrate-issue "$2" --reviewed-by r1 2>&1; }
refresh() { git -C "$WORK/trees/$1" rebase -q origin/master; }

# planted: the branch check on the Plane number alone
refresh issue-288-two
work issue-288-two 2026-03-06T00:00:00Z "Two (#288)"
planted="$(mutant_root bin/integrate-issue.sh 's/\[ "\$WORK_ITEM" = "\$number" \] || whose=/[ "$(name_issue_number "$branch")" = "$number" ] || whose=/')"
before="$(git -C "$P" rev-parse origin/master)"
out="$(ROOT_UNDER_TEST="$planted" land_in issue-288-two 45)" && fail "planted: the branch check on the number of the name alone should refuse #45: $out"
grep -q 'this runs in the worktree of issue 45' <<< "$out" || fail "planted: the refusal is not the one of the number of the name: $out"
fetch; [ "$(git -C "$P" rev-parse origin/master)" = "$before" ] || fail "planted: a refused integration moved origin"
echo "  planted: the branch check on the number of the name alone refuses the branch of #45 from its own worktree"

# planted: the next: lines without the rule, on the branch of work item 46
refresh issue-291-other
work issue-291-other 2026-03-06T00:00:00Z "Other (#291)"
work issue-291-other 2026-03-06T00:00:01Z "Ref (#287)"
planted="$(mutant_root bin/integrate-issue.sh 's/if reference_answer "\${landed_repo:-\$own_repo}" "\${named##\*#}" "\${line%% \*}"; then/WORK_ITEM="${named##*#}"; WORK_ITEM_REASON=""; if true; then/')"
out="$(ROOT_UNDER_TEST="$planted" land_in issue-291-other 46)" || fail "planted: integrate-issue 46: $out"
grep -q '^next: ai-core finish-issue 287$' <<< "$out" || fail "planted: without the rule the next: line should name the GitHub number 287: $out"
echo "  planted: the next: lines without the rule name finish-issue 287, which is another work item"

# the landing of work item 45 from its worktree, named by a GitHub number
refresh issue-288-two
work issue-288-two 2026-03-06T00:00:01Z "Ref (#287)"
work issue-288-two 2026-03-06T00:00:02Z "Ref (#291)"
work issue-288-two 2026-03-06T00:00:03Z "Ref (#292)"
work issue-288-two 2026-03-20T00:00:00Z "Ref (#293)"
out="$(land_in issue-288-two 45)" || fail "integrate-issue 45 in the worktree issue-288-two: $out"
fetch
[ "$(subject_of)" = "Carried two (#45)" ] || fail "the merge commit is not named after #45: $(subject_of)"
grep -q '^Reviewed-by: r1$' <<< "$(git -C "$P" log -1 --format=%B origin/master)" || fail "the merge commit has no Reviewed-by trailer"
for number in 45 44 46 293; do grep -q "^next: ai-core finish-issue $number\$" <<< "$out" || fail "the next: lines do not name #$number: $out"; done
for number in 287 288 291 292; do ! grep -q "^next: ai-core finish-issue $number\$" <<< "$out" || fail "a next: line names the GitHub number $number: $out"; done
grep -q "^note: the commit (#292) names GitHub $repo#292, which no work item was carried from, so no finish-issue follows for it" <<< "$out" \
  || fail "a commit naming a GitHub issue that was not carried is not named: $out"
echo "  integrate-issue 45 in the worktree: merges under '<title> (#45)'; the next: lines give the work items 45, 44 (from #287), 46 (from #291, whose own item belongs to another repository) and 293 (younger than its item), and name the GitHub issue #292 that was not carried"

section "integrate-issue --from-origin after the switch: the branch issue-289-four is work item #47's"
origin_branch() {  # origin_branch <branch> <time> <subject>: a branch of origin cut from its master at <time> with one commit
  cut "$1" "$2"; refresh "$1"; work "$1" "$2" "$3"; publish "$1"
  git -C "$P" worktree remove --force "$WORK/trees/$1"; git -C "$P" branch -q -D "$1"
}
land_from_origin() { ai_in "$P" integrate-issue "$@" --from-origin --reviewed-by r1 2>&1; }
planted="$(mutant_root lib/plane/tracker.sh 's/if \[ -n "\$own" \] \&\& \[ -n "\$at" \] \&\& \[ "\$at" -ge "\$own_at" \]; then/if [ -n "$own" ] \&\& [ -n "$at" ]; then/')"
origin_branch issue-289-planted 2026-03-02T00:00:00Z "Planted (#289)"
out="$(ROOT_UNDER_TEST="$planted" land_from_origin 289)" || fail "planted: integrate-issue 289 --from-origin: $out"
fetch; [ "$(subject_of)" = "Fresh 289 (#289)" ] || fail "planted: without the time rule integrate-issue 289 should merge the branch of #47: $(subject_of)"
git -C "$P" push -q origin --delete issue-289-planted
echo "  planted: without the time rule integrate-issue 289 --from-origin merges the branch of #47"
origin_branch issue-289-four 2026-03-02T00:00:00Z "Four (#289)"
before="$(git -C "$P" rev-parse origin/master)"
out="$(land_from_origin 289)" && fail "integrate-issue 289 --from-origin took the branch of #47: $out"
grep -q 'the branch issue-289-four on origin is not taken: it belongs to #47' <<< "$out" || fail "the branch is not named as #47's: $out"
fetch; [ "$(git -C "$P" rev-parse origin/master)" = "$before" ] || fail "a refused integration moved origin"
out="$(land_from_origin 47)" || fail "integrate-issue 47 --from-origin: $out"
fetch; [ "$(subject_of)" = "Carried four (#47)" ] || fail "the merge commit of the branch from origin is not named after #47: $(subject_of)"
grep -q '^merging: origin/issue-289-four at ' <<< "$out" || fail "the branch merged is not named: $out"
grep -q '^next: ai-core finish-issue 47$' <<< "$out" || fail "the next: line does not name #47: $out"
echo "  integrate-issue --from-origin: 289 does not take the branch of #47 and names it; 47 finds issue-289-four on origin and merges it under '<title> (#47)'"

section "start-issue after the switch: the number 287 is both the GitHub number of #44 and work item #287"
assign() { planeset "p.issues.find((i)=>i.sequence_id===$1).assignees=[s.users[0].id]"; }
rename() { planeset "p.issues.find((i)=>i.sequence_id===$1).name=process.env.NEW_NAME" ; }
assign 44; assign 287
cut issue-287-the-slug 2026-03-01T00:00:00Z
refresh issue-287-the-slug
work issue-287-the-slug 2026-03-05T00:00:00Z "More of #44 (#287)"
git -C "$P" worktree remove --force "$WORK/trees/issue-287-the-slug"
tip="$(git -C "$P" rev-parse refs/heads/issue-287-the-slug)"
NEW_NAME="The slug" rename 287
set_state 287 ready

out="$(ai start-issue 44 2>&1)" && fail "start-issue 44 cut a second branch for the issue whose branch issue-287-the-slug stands: $out"
grep -q 'a branch for this issue exists already: issue-287-the-slug - use its worktree instead' <<< "$out" || fail "start-issue 44 does not name issue-287-the-slug: $out"
out="$(ai start-issue 287 2>&1)" && fail "start-issue 287 moved issue-287-the-slug, the branch of #44: $out"
grep -q 'the name issue-287-the-slug is the name of a branch of another work item already: issue-287-the-slug (belongs to #44)' <<< "$out" || fail "the name collision is not named: $out"
[ "$(git -C "$P" rev-parse refs/heads/issue-287-the-slug)" = "$tip" ] || fail "start-issue 287 moved the branch of #44"
echo "  start-issue: 44 is refused where issue-287-the-slug stands; 287 is refused where its own name would move the branch of #44, and that branch stays at its commit"

# a landed local branch of 44 under the new name, cut before 287 existed and checked out by no worktree: moved, it would keep its reflog
cut issue-287-landed-one 2026-03-01T00:00:00Z
git -C "$P" worktree remove --force "$WORK/trees/issue-287-landed-one"
NEW_NAME="Landed one" rename 287
out="$(ai start-issue 287 2>&1)" && fail "start-issue 287 took over issue-287-landed-one, the landed branch of #44: $out"
grep -q 'the name issue-287-landed-one is the name of a branch of another work item already: issue-287-landed-one (belongs to #44; it has landed and no worktree has it checked out: git branch -d issue-287-landed-one deletes it)' <<< "$out" \
  || fail "the landed branch of #44 under the new name is not named with the way on: $out"
planted="$(mutant_root bin/start-issue.sh 's/^      \[ "\$owner" != "\$number" \] && \[ "\$ref" = "\$name" \] || continue$/      continue/')"
ROOT_UNDER_TEST="$planted" ai start-issue 287 > /dev/null 2>&1 || fail "planted: without the check of a landed branch start-issue 287 should take over issue-287-landed-one"
landed_tree="$(git -C "$P" worktree list --porcelain | sed -n 's|^worktree \(.*issue-287-landed-one\)$|\1|p')"
[ -n "$landed_tree" ] && [ "$(cd "$landed_tree" && PATH="$PATH_CURL" bash -c '. "$1/lib/board.sh"; worktree_issue' _ "$ROOT" | jq -r '.workItem')" = 44 ] \
  || fail "planted: the worktree start-issue 287 cut on issue-287-landed-one should read as the worktree of #44"
git -C "$P" worktree remove --force "$landed_tree"; git -C "$P" branch -q -D issue-287-landed-one
NEW_NAME="The slug" rename 287
set_state 287 ready
echo "  start-issue 287 is refused where its name is the landed local branch of #44, and names the way on; planted: taken over, the new worktree reads as #44's"

planted="$(mutant_root bin/start-issue.sh 's/^  owner="\$(awk .*$/  owner="$number"/')"
NEW_NAME="Fresh 287" rename 287
out="$(ROOT_UNDER_TEST="$planted" ai start-issue 287 2>&1)" && fail "planted: the taken check by the number alone should refuse start-issue 287: $out"
grep -q 'a branch for this issue exists already: issue-287-the-slug' <<< "$out" || fail "planted: the taken check by the number alone does not name issue-287-the-slug: $out"
NEW_NAME="The slug" rename 287
planted="$(mutant_root bin/start-issue.sh 's/^  elif \[ "\${ref#origin\/}" = "\$name" \]; then$/  elif false; then/')"
ROOT_UNDER_TEST="$planted" ai start-issue 287 > /dev/null 2>&1 || true
[ "$(git -C "$P" rev-parse refs/heads/issue-287-the-slug)" != "$tip" ] || fail "planted: without the collision check start-issue 287 should move issue-287-the-slug"
git -C "$P" worktree remove --force "$(git -C "$P" worktree list --porcelain | sed -n 's|^worktree \(.*issue-287-the-slug\)$|\1|p')" 2>/dev/null || true
git -C "$P" branch -q -f issue-287-the-slug "$tip"
echo "  planted: the taken check by the number alone refuses start-issue 287; without the collision check issue-287-the-slug is moved to origin's tip"

NEW_NAME="Fresh 287" rename 287
out="$(ai start-issue 287 2>&1)" || fail "start-issue 287 with a slug of its own: $out"
grep -q 'on issue-287-fresh-287, cut from origin/master' <<< "$out" || fail "start-issue 287 did not cut issue-287-fresh-287: $out"
[ "$(git -C "$P" rev-parse refs/heads/issue-287-the-slug)" = "$tip" ] || fail "start-issue 287 moved the branch of #44"
[ "$(state_of 287)" = implementing ] || fail "the card of #287 did not move to implementing: $(state_of 287)"
echo "  start-issue 287: cuts issue-287-fresh-287 and leaves issue-287-the-slug of #44 where it was"

section "the tracker settings of a worktree are the checkout's"
tree="$WORK/trees/settings-tree"
git -C "$P" worktree add -q -b settings-tree "$tree" origin/master
mkdir -p "$tree/.ai-core"
printf 'TRACKER="github"\nPLANE_URL=https://elsewhere.example.test\nPLANE_WORKSPACE=elsewhere\nPLANE_PROJECT=OTHER\nPLANE_TOKEN_COMMAND="echo not-the-key"\nKEPT_SETTING=the-worktrees-own\n' > "$tree/.ai-core/config.env"
mkdir -p "$WORK/ghlog"; printf '#!/bin/sh\necho "$@" >> "%s/calls"\nexit 1\n' "$WORK/ghlog" > "$WORK/ghlog/gh"; chmod +x "$WORK/ghlog/gh"
: > "$WORK/ghlog/calls"
in_tree() { ( PATH_CURL="$WORK/ghlog:$PATH_CURL"; ai_in "$tree" "$@" ); }   # in_tree <command> [args]: the command in the worktree, a gh that logs and fails ahead of the stand-ins
out="$(in_tree doctor 2>&1)" || true
grep -q '  tracker: plane (https://plane.example.test, the key answers)' <<< "$out" || fail "doctor in the worktree does not read the checkout's tracker: $(grep 'tracker' <<< "$out")"
out="$(in_tree issue-thread 44 2>&1)" || fail "issue-thread 44 in the worktree: $out"
grep -q 'Carried one' <<< "$out" || fail "issue-thread 44 in the worktree does not read the stand-in of Plane: $out"
out="$(in_tree finish-issue 293 2>&1)" || fail "finish-issue 293 in the worktree: $out"
grep -q 'the issue says what landed' <<< "$out" && grep -q 'Ref (#293)' <<< "$(comments_of 293)" || fail "finish-issue in the worktree does not write the Landed record to Plane: $out"
in_tree issue-comment 44 "Written from a worktree" > /dev/null 2>&1 || fail "issue-comment in the worktree"
grep -q 'Written from a worktree' <<< "$(comments_of 44)" || fail "the comment written from the worktree is not on the work item of Plane"
out="$(in_tree board-sync 2>&1)" || fail "board-sync in the worktree: $out"
grep -q 'on plane every work item of a project is on its board already' <<< "$out" || fail "board-sync in the worktree does not say it is on plane: $out"
! grep -q '^api' "$WORK/ghlog/calls" || fail "gh was asked for an issue from the worktree: $(cat "$WORK/ghlog/calls")"
[ "$(cd "$tree" && bash -c '. "$1/lib/common.sh"; config_value KEPT_SETTING none' _ "$ROOT")" = the-worktrees-own ] || fail "a setting that is not one of the five stopped being the worktree's own"
out="$(TRACKER=github in_tree issue-thread 44 2>&1)" && fail "TRACKER=github in the environment did not win in the worktree: $out"
grep -q '^api' "$WORK/ghlog/calls" || fail "TRACKER=github in the environment did not reach gh"
: > "$WORK/ghlog/calls"
echo "  a worktree whose own config.env says github and another server: doctor, issue-thread, finish-issue, issue-comment and board-sync read and write the checkout's Plane, gh is asked for no issue, a setting beyond the five stays the worktree's, and TRACKER in the environment still wins"
mkdir -p "$WORK/nogit/.ai-core"; printf 'TRACKER=forgejo-own\n' > "$WORK/nogit/.ai-core/config.env"
[ "$(cd "$WORK/nogit" && bash -c '. "$1/lib/common.sh"; config_value TRACKER github' _ "$ROOT")" = forgejo-own ] || fail "a folder outside any git working copy does not read its own config.env"
[ "$(cd "$P" && bash -c '. "$1/lib/common.sh"; config_value TRACKER github' _ "$ROOT")" = plane ] || fail "the checkout does not read its own config.env"
echo "  the checkout and a folder outside any git working copy read their own config.env"
planted="$(mutant_root lib/common.sh 's/^TRACKER_SETTINGS=.*/TRACKER_SETTINGS=" "/')"
out="$(ROOT_UNDER_TEST="$planted" in_tree doctor 2>&1)" || true
grep -q '  tracker: github' <<< "$out" || fail "planted: the keys read from the worktree's copy should say github: $(grep tracker <<< "$out")"
out="$(ROOT_UNDER_TEST="$planted" in_tree issue-thread 44 2>&1)" && fail "planted: the worktree's own copy should not read Plane: $out"
grep -q '^api' "$WORK/ghlog/calls" || fail "planted: the worktree's own copy should call gh"
: > "$WORK/ghlog/calls"
echo "  planted: with the keys read from the worktree's copy, doctor says github and gh is called"
git -C "$P" worktree remove --force "$tree"; git -C "$P" branch -q -D settings-tree

section "status: a worktree is keyed by the work item it belongs to"
git -C "$P" branch -q -D issue-287-the-slug
cut issue-287-the-slug 2026-03-01T00:00:00Z
refresh issue-287-the-slug
work issue-287-the-slug 2026-03-05T00:00:00Z "More of #44 (#287)"
cut issue-293-again 2026-03-11T00:00:00Z "$(git -C "$P" rev-list --max-parents=0 origin/master)"
printf '110\t1\t30:00\tSsl\tclaude daemon run --origin transient\n111\t110\t29:00\tSNsl\tclaude bg-pty-host --bg-pty-host /tmp/x.sock 200 50 -- /home/x/.local/share/claude/versions/2.1.289 --session-id 22222222-2222-2222-2222-222222222222\n112\t111\t29:00\tSNsl+\t/home/x/.local/share/claude/versions/2.1.289 --session-id 22222222-2222-2222-2222-222222222222 --name i1-sonnet5.5-low-100k-ab123 --model sonnet --effort low\n' > "$WORK/processes"
printf '[{"pid":112,"kind":"background","status":"busy","state":"working","name":"i1-sonnet5.5-low-100k-ab123","cwd":"%s","sessionId":"22222222-2222-2222-2222-222222222222","id":"22222222"}]\n' "$WORK/trees/issue-287-the-slug" > "$WORK/agents"
: > "$WORK/rollouts"
status_page() { ( cd "$P" && PATH="$PATH_CURL" AI_CORE_PROCESSES="$WORK/processes" AI_CORE_AGENTS="$WORK/agents" AI_CORE_ROLLOUTS="$WORK/rollouts" bash "${ROOT_UNDER_TEST:-$ROOT}/bin/status.sh" 2>&1 ) || true; }
page="$(status_page)"
grep -q '^TREES ' <<< "$page" || fail "the page has no TREES block: $page"
grep -qE '^ +project#44 .*has work origin/master does not have yet' <<< "$page" || fail "the TREES block does not key the worktree issue-287-the-slug by work item #44: $(grep -A8 '^TREES' <<< "$page")"
grep -qE '^ +project#293 .*never committed in' <<< "$page" || fail "the worktree issue-293-again, cut after its work item was made, is not keyed #293: $(grep -A8 '^TREES' <<< "$page")"
grep -qE '^ +project issue-292-ghost ' <<< "$page" || fail "a worktree whose number names no work item is not keyed by its directory: $(grep -A8 '^TREES' <<< "$page")"
grep -qE '│ C i1-sonnet5\.5 +│ 112 +│ .*│ trees#44 at start +│ session +│' <<< "$page" || fail "the agent table does not name trees#44 at start: $(grep -B2 -A6 'AGENTS ON' <<< "$page")"
echo "  status: the worktree of #44 is keyed project#44 in the TREES block and trees#44 (the folder it stands in) in the agent table, the worktree cut after its work item #293, project#293, and one that names no work item by its directory"
planted="$(mutant_root lib/status-live.mjs 's/const n = workItems.has(dir) ? workItems.get(dir) : (/const n = (/')"
grep -qE '^ +project#287 .*has work origin/master does not have yet' <<< "$(ROOT_UNDER_TEST="$planted" status_page)" || fail "planted: the key read from the directory should be project#287 in the TREES block"
planted="$(mutant_root lib/status-now.mjs "s/const treeNumber = workItems.has(treeDir) ? workItems.get(treeDir) : tree ? tree\[2\] : '';/const treeNumber = tree ? tree[2] : '';/")"
grep -qE 'trees#287 at start' <<< "$(ROOT_UNDER_TEST="$planted" status_page)" || fail "planted: the key read from the directory should be trees#287 at start in the agent table"
echo "  planted: the key read from the directory's number gives project#287 in the TREES block and trees#287 in the agent table"
