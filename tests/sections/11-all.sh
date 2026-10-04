#!/usr/bin/env bash
# init --all; one section of the suite, run by tests/check.sh with the others
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

section "init --all: every git repository and start-issue worktree under a folder, a failing one reported, both twins"
for twin in sh ps; do
  mkdir -p "$WORK/all-$twin"
  for r in one two; do git init -q "$WORK/all-$twin/$r"; mkdir -p "$WORK/all-$twin/$r/.ai-core"; printf 'GRAFT_EXECUTION_MODE="skip"\n' > "$WORK/all-$twin/$r/.ai-core/config.env"; done
  git init -q "$WORK/all-$twin/broken"; mkdir -p "$WORK/all-$twin/broken/.ai-core"; printf 'GRAFT_EXECUTION_MODE="bogus"\n' > "$WORK/all-$twin/broken/.ai-core/config.env"
  mkdir -p "$WORK/all-$twin/not-a-repo" "$WORK/all-$twin/.ai-core"; printf 'GRAFT_EXECUTION_MODE="skip"\n' > "$WORK/all-$twin/.ai-core/config.env"
  git init -q "$WORK/all-$twin/x-ai-core"   # a harness clone beside the repositories is none of them
  # the worktrees ai-core start-issue puts under .worktrees/<repository>/: one of a repository, whose
  # own name ends like a harness clone's, and one of the harness clone
  for r in one x-ai-core; do git -C "$WORK/all-$twin/$r" commit -q --allow-empty -m start; done
  git -C "$WORK/all-$twin/one" worktree add -q -b issue-1-to-ai-core "$WORK/all-$twin/.worktrees/one/issue-1-to-ai-core"
  git -C "$WORK/all-$twin/x-ai-core" worktree add -q -b issue-2-rules "$WORK/all-$twin/.worktrees/x-ai-core/issue-2-rules"
  if [ "$twin" = sh ]; then
    bash "$ROOT/bin/init.sh" --all "$WORK/all-$twin" --no-doctor --dry-run > "$WORK/all-$twin-dry.log" 2>&1 && fail "init.sh --all --dry-run exited 0 with a failing repository"
    bash "$ROOT/bin/init.sh" --all "$WORK/all-$twin" --no-doctor > "$WORK/all-$twin.log" 2>&1 && fail "init.sh --all exited 0 with a failing repository"
  else
    pwsh -NoProfile -File "$ROOT/bin/init.ps1" -All "$(native "$WORK/all-$twin")" -NoDoctor -DryRun > "$WORK/all-$twin-dry.log" 2>&1 && fail "init.ps1 -All -DryRun exited 0 with a failing repository"
    pwsh -NoProfile -File "$ROOT/bin/init.ps1" -All "$(native "$WORK/all-$twin")" -NoDoctor > "$WORK/all-$twin.log" 2>&1 && fail "init.ps1 -All exited 0 with a failing repository"
  fi
  grep -aq '3 repositories would be initialized; failed: broken' "$WORK/all-$twin-dry.log" || fail "init --all --dry-run summary wrong for $twin: $(grep -a 'repositories' "$WORK/all-$twin-dry.log")"
  [ "$(grep -ac '^init would change in ' "$WORK/all-$twin-dry.log")" = 4 ] || fail "init --all --dry-run did not report every repository, the worktree and the folder ($twin)"
  grep -aq '^  created .*AGENTS.md' "$WORK/all-$twin.log" || fail "init --all did not report what it created ($twin)"
  grep -aq '3 repositories were initialized; failed: broken' "$WORK/all-$twin.log" || fail "init --all summary wrong for $twin: $(grep -a 'repositories' "$WORK/all-$twin.log")"
  [ -f "$WORK/all-$twin/one/AGENTS.md" ] && [ -f "$WORK/all-$twin/two/AGENTS.md" ] || fail "init --all did not initialize the good repositories ($twin)"
  grep -aq '^### \.worktrees/one/issue-1-to-ai-core' "$WORK/all-$twin.log" && [ -f "$WORK/all-$twin/.worktrees/one/issue-1-to-ai-core/.ai-core/rules/rules.md" ] || fail "init --all did not initialize the worktree under .worktrees/ ($twin)"
  [ -e "$WORK/all-$twin/.worktrees/x-ai-core/issue-2-rules/.ai-core" ] && fail "init --all initialized a worktree of a harness clone ($twin)"
  [ -e "$WORK/all-$twin/not-a-repo/.ai-core" ] && fail "init --all touched a folder that is not a repository ($twin)"
  [ -e "$WORK/all-$twin/x-ai-core/.ai-core" ] && fail "init --all initialized a harness clone ($twin)"
  grep -q 'x-ai-core' "$WORK/all-$twin/AGENTS.md" && fail "the project folder's AGENTS.md lists a harness clone ($twin)"
  grep -q 'written by init for a project folder' "$WORK/all-$twin/AGENTS.md" || fail "init --all did not write the project folder's AGENTS.md ($twin)"
  for r in one two broken; do grep -q "| \`$r\` | \`$r/AGENTS.md\` |" "$WORK/all-$twin/AGENTS.md" || fail "the project folder's AGENTS.md does not list $r ($twin)"; done
  grep -q 'not-a-repo' "$WORK/all-$twin/AGENTS.md" && fail "the project folder's AGENTS.md lists a folder that is not a repository ($twin)"
  [ -f "$WORK/all-$twin/.ai-core/rules/rules.md" ] || fail "init --all did not give the project folder the rules ($twin)"
done
diff <(sed "s/^# all-sh$/# FOLDER/" "$WORK/all-sh/AGENTS.md") <(sed "s/^# all-ps$/# FOLDER/" "$WORK/all-ps/AGENTS.md") > /dev/null || fail "the project folder's AGENTS.md differs between the twins"
echo "  2 repositories and a worktree under .worktrees/ initialized, 1 failed and named, the plain folder, the harness clone and its worktree untouched, the folder's AGENTS.md lists the three, on both twins"

section "init --all gives the folder its rules before its repositories: a repository with the folder's rules names them without the @ in one run, the folder's rules older or missing; both twins"
for twin in sh ps; do
  F="$WORK/order-$twin"; mkdir -p "$F/.ai-core"; printf 'GRAFT_EXECUTION_MODE="skip"\n' > "$F/.ai-core/config.env"
  git init -q "$F/app"; mkdir -p "$F/app/.ai-core"; printf 'GRAFT_EXECUTION_MODE="skip"\n' > "$F/app/.ai-core/config.env"
  for run in 1 2 3; do
    [ "$run" = 2 ] && printf 'a rule of an older version\n' >> "$F/.ai-core/rules/rules.md"
    if [ "$twin" = sh ]; then bash "$ROOT/bin/init.sh" --all "$F" --no-doctor $([ "$run" = 3 ] && echo --dry-run) > "$F-$run.log" 2>&1
    else pwsh -NoProfile -File "$ROOT/bin/init.ps1" -All "$(native "$F")" -NoDoctor $([ "$run" = 3 ] && echo -DryRun) > "$F-$run.log" 2>&1; fi || fail "init --all run $run failed ($twin, see $F-$run.log)"
    [ "$run" = 3 ] && continue
    grep -q '@\.ai-core/rules/rules\.md' "$F/app/AGENTS.md" && fail "init --all run $run: the repository imports the rules the folder's AGENTS.md loads already ($twin)"
    grep -q "rules/rules.md\`, the same as the project folder's" "$F/app/AGENTS.md" || fail "init --all run $run: the repository does not name the folder's rules ($twin)"
  done
  grep -aE '^  (created|refreshed|removed) ' "$F-3.log" && fail "init --all changes something on the run after ($twin, see $F-3.log)"
done
echo "  the repository names the folder's rules without the @ after the first run and after the folder held older ones, and the run after changes nothing, on both twins"
section "init --all removes a worktree whose work landed a day ago or more before it inits the rest, and leaves a fresh one; both twins"
for twin in sh ps; do
  F="$WORK/sweep-$twin"; O="$WORK/sweep-$twin-origin.git"; A="$F/app"
  mkdir -p "$F/.ai-core"; printf 'GRAFT_EXECUTION_MODE="skip"\n' > "$F/.ai-core/config.env"
  git init -q --bare -b master "$O"; git init -q -b master "$A"
  mkdir -p "$A/.ai-core"; printf 'GRAFT_EXECUTION_MODE="skip"\n' > "$A/.ai-core/config.env"; printf '/.ai-core/\n' >> "$A/.git/info/exclude"
  echo one > "$A/README.md"; git -C "$A" add README.md; git -C "$A" commit -q -m 'Start #1'
  git -C "$A" remote add origin "$O"; git -C "$A" push -q -u origin master 2>/dev/null; git -C "$A" remote set-head origin -a >/dev/null
  long_ago="$(date -d '3 days ago' '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -v-3d '+%Y-%m-%dT%H:%M:%S')"
  for w in issue-5-old issue-6-new; do
    T="$F/.worktrees/app/$w"; git -C "$A" worktree add -q -b "$w" "$T" origin/master 2>/dev/null
    echo "$w" >> "$T/README.md"; git -C "$T" add README.md
    if [ "$w" = issue-5-old ]; then GIT_AUTHOR_DATE="$long_ago" GIT_COMMITTER_DATE="$long_ago" git -C "$T" commit -q -m "Land $w #5"; else git -C "$T" commit -q -m "Land $w #6"; fi
    git -C "$T" push -q origin HEAD:master 2>/dev/null; git -C "$A" pull -q --ff-only origin master 2>/dev/null
  done
  if [ "$twin" = sh ]; then bash "$ROOT/bin/init.sh" --all "$F" --no-doctor > "$F.log" 2>&1
  else pwsh -NoProfile -File "$ROOT/bin/init.ps1" -All "$(native "$F")" -NoDoctor > "$F.log" 2>&1; fi || fail "init --all with landed worktrees failed ($twin, see $F.log)"
  [ -d "$F/.worktrees/app/issue-5-old" ] && fail "init --all left the worktree whose work landed three days ago ($twin, see $F.log)"
  git -C "$A" rev-parse -q --verify refs/heads/issue-5-old >/dev/null && fail "init --all left the branch of the landed worktree ($twin)"
  grep -aq 'issue-5-old: landed, removed' "$F.log" || fail "init --all does not name the worktree it removed ($twin, see $F.log)"
  [ -d "$F/.worktrees/app/issue-6-new" ] || fail "init --all removed a worktree whose work landed today ($twin)"
  [ -f "$F/.worktrees/app/issue-6-new/.ai-core/rules/rules.md" ] || fail "init --all did not init the worktree that stays ($twin)"
done
echo "  the worktree that landed three days ago is gone with its branch and named, the one of today stays and is inited, on both twins"

section "init links the other checkouts of the folder beside a worktree, so .. finds them from it; both twins"
for twin in sh ps; do
  F="$WORK/near-$twin"; T="$F/.worktrees/app/issue-1-x"
  for r in app lib docs; do
    git init -q "$F/$r"; mkdir -p "$F/$r/.ai-core"; printf 'GRAFT_EXECUTION_MODE="skip"\n' > "$F/$r/.ai-core/config.env"
    git -C "$F/$r" commit -q --allow-empty -m start; echo "$r" > "$F/$r/marker"
  done
  mkdir -p "$F/notes"                                  # a folder that is no checkout gets no link
  git -C "$F/app" worktree add -q -b issue-1-x "$T"
  echo mine > "$F/.worktrees/app/docs"                 # an entry that stands there already stays
  init_one() { # [dry]: init on the worktree, its log in $F-$twin-$1.log
    if [ "$twin" = sh ]; then bash "$ROOT/bin/init.sh" "$T" --no-doctor $([ "$1" = dry ] && echo --dry-run)
    else pwsh -NoProfile -File "$ROOT/bin/init.ps1" -TargetDir "$(native "$T")" -NoDoctor $([ "$1" = dry ] && echo -DryRun); fi > "$F-$1.log" 2>&1
  }
  init_one dry || fail "init --dry-run on a worktree failed ($twin, see $F-dry.log)"
  [ -e "$F/.worktrees/app/lib" ] && fail "init --dry-run made a link ($twin)"
  grep -aq '^  links to the neighbour checkouts would be made in \.worktrees/app/: lib; ' "$F-dry.log" || fail "init --dry-run does not say which link it would make ($twin, see $F-dry.log)"
  init_one real || fail "init on a worktree failed ($twin, see $F-real.log)"
  grep -aq '^  links to the neighbour checkouts made in \.worktrees/app/: lib; ' "$F-real.log" || fail "init does not say which link it made ($twin, see $F-real.log)"
  [ "$(cat "$T/../lib/marker" 2>/dev/null)" = lib ] || fail "from the worktree, ../lib is not the checkout lib ($twin)"
  [ "$(cat "$F/.worktrees/app/docs")" = mine ] || fail "init replaced an entry that stood beside the worktree already ($twin)"
  [ -e "$F/.worktrees/app/app" ] && fail "init linked the worktree's own repository beside it ($twin)"
  [ -e "$F/.worktrees/app/notes" ] && fail "init linked a folder that is no checkout ($twin)"
  if [ "$twin" = sh ]; then bash "$ROOT/bin/init.sh" --all "$F" --no-doctor
  else pwsh -NoProfile -File "$ROOT/bin/init.ps1" -All "$(native "$F")" -NoDoctor; fi > "$F-all.log" 2>&1 || fail "init --all over the folder failed ($twin, see $F-all.log)"
  grep -aq '^### \.worktrees/app/issue-1-x' "$F-all.log" || fail "init --all did not init the worktree ($twin, see $F-all.log)"
  grep -aq '^### \.worktrees/app/lib' "$F-all.log" && fail "init --all took the link to a neighbour for a worktree ($twin, see $F-all.log)"
done
echo "  a worktree finds the neighbour checkout through .., the dry run only names the link, an entry there, the repository itself and a plain folder get none, init --all inits no link, on both twins"
exit 0
