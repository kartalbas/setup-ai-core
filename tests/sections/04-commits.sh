#!/usr/bin/env bash
# nothing to commit after init, in a clone and in a worktree; one section of the suite, run by tests/check.sh with the others
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

section "nothing to commit after init, in a clone and in a worktree, for both twins"
for twin in sh ps1; do
  git init -q "$WORK/repo-$twin"
  git -C "$WORK/repo-$twin" -c user.name=check -c user.email=check@localhost commit -q --allow-empty -m init
  git -C "$WORK/repo-$twin" worktree add -q "$WORK/wt-$twin" > /dev/null 2>&1 || fail "git worktree add"
  for t in "repo-$twin" "wt-$twin"; do
    mkdir -p "$WORK/$t/.ai-core" "$WORK/$t/.claude"
    printf 'GRAFT_EXECUTION_MODE="skip"\n' > "$WORK/$t/.ai-core/config.env"
    printf '{"permissions":{"allow":["Bash(x)"]}}\n' > "$WORK/$t/.claude/settings.json"   # a settings.json from before the hook
    for run in 1 2; do
      if [ "$twin" = sh ]; then
        bash "$ROOT/bin/init.sh" "$WORK/$t" --no-doctor > "$WORK/$t-init.log" 2>&1 || fail "init.sh in $t (run $run)"
      else
        pwsh -NoProfile -File "$ROOT/bin/init.ps1" -TargetDir "$(native "$WORK/$t")" -NoDoctor > "$WORK/$t-init.log" 2>&1 || fail "init.ps1 in $t (run $run)"
      fi
      if [ "$run" = 1 ]; then
        dirty="$(git -C "$WORK/$t" status --porcelain | tr -d '\r')"
        if [ "$t" = "repo-$twin" ]; then
          # the checkout: init committed the block itself, and nothing else
          [ -z "$dirty" ] || fail "init.$twin in $t left something uncommitted: $(echo "$dirty" | tr '\n' ' ')"
          [ "$(git -C "$WORK/$t" log -1 --format=%s)" = "the agent files of this repository are ignored" ] || fail "init.$twin in $t did not commit .gitignore itself"
          [ "$(git -C "$WORK/$t" log -1 --format='%(trailers:key=No-issue,valueonly)' | tr -d '\n')" = "the .gitignore block written by ai-core init" ] || fail "init.$twin: the .gitignore commit carries no No-issue trailer"
          [ "$(git -C "$WORK/$t" show --pretty=format: --name-only HEAD | grep -v '^$' | tr '\n' ' ')" = ".gitignore " ] || fail "init.$twin: the .gitignore commit carries more than .gitignore"
        else
          # the worktree: somebody's issue; init leaves the change for its own commit
          [ "$dirty" = "?? .gitignore" ] || [ "$dirty" = " M .gitignore" ] || fail "init.$twin in $t left something besides .gitignore: $(echo "$dirty" | tr '\n' ' ')"
          git -C "$WORK/$t" add .gitignore
          git -C "$WORK/$t" -c user.name=check -c user.email=check@localhost commit -q -m ignore
        fi
      fi
    done
    dirty="$(git -C "$WORK/$t" status --porcelain)"
    [ -z "$dirty" ] || fail "init.$twin left untracked files in $t: $(echo "$dirty" | tr '\n' ' ')"
    jq -e '(.hooks.SessionStart[0].hooks[0].command == "ai-core session-start --tool claude") and ((.permissions.allow | index("Bash(x)")) != null) and ((.permissions.allow | index("Bash(ai-core:*)")) != null) and ((.permissions.allow | index("mcp__graft")) != null) and ([.permissions.allow[] | select(. == "mcp__graft")] | length == 1)' "$WORK/$t/.claude/settings.json" > /dev/null || fail "init.$twin did not merge the session-start hook and the two permissions, once, into the settings.json $t had: $(tr -d '\n' < "$WORK/$t/.claude/settings.json")"
    jq -e '(.hooks.SessionStart[0].hooks[0].command == "ai-core session-start --tool claude") and ((.permissions.allow | index("Bash(x)")) != null)' "$WORK/$t/.claude/settings.json" > /dev/null || fail "init.$twin did not merge the session-start hook into the settings.json $t had (or lost its own entry)"
    [ "$run" = 1 ] && [ "$t" = "repo-$twin" ] && { grep -aq '^  refreshed .*\.claude/settings\.json' "$WORK/$t-init.log" || fail "init.$twin did not report the merged settings.json as refreshed"; }
    [ "$(jq '[.hooks.SessionStart[].hooks[].command] | length' "$WORK/$t/.claude/settings.json")" = 1 ] || fail "init.$twin merged the hook more than once in $t"
  done
  n="$(grep -c '^# setup-ai-core start' "$WORK/repo-$twin/.git/info/exclude")"
  [ "$n" = 1 ] || fail "exclude block written $n times by init.$twin"
done
echo "  git status empty in 4 targets, the checkouts' .gitignore committed by init with its trailer, the worktrees' left to their own commit; exclude block written once each; the session-start hook merged into the settings.json each had, once"
exit 0
