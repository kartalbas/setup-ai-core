#!/usr/bin/env bash
# nothing to commit after init, in a clone and in a worktree; one section of the suite, run by tests/check.sh with the others
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

section "nothing to commit after init, in a clone and in a worktree"
git init -q "$WORK/repo"
git -C "$WORK/repo" -c user.name=check -c user.email=check@localhost commit -q --allow-empty -m init
git -C "$WORK/repo" worktree add -q "$WORK/wt" > /dev/null 2>&1 || fail "git worktree add"
for t in repo wt; do
  mkdir -p "$WORK/$t/.ai-core" "$WORK/$t/.claude"
  printf 'UPDATE_CHECK="never"\n' > "$WORK/$t/.ai-core/config.env"
  printf '{"permissions":{"allow":["Bash(x)"]},"autoCompactWindow":500000}\n' > "$WORK/$t/.claude/settings.json"   # a settings.json from before the hook, with a compact window init takes out
  [ "$t" = "repo" ] && printf '{"permissions":{"allow":["Bash(x)"],"deny":["Bash(rm -rf:*)"]},"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"ai-core session-start --tool claude","timeout":60},{"type":"command","command":"echo other"}]}],"PermissionRequest":[{"hooks":[{"type":"command","command":"ai-core permission-request","timeout":10},{"type":"command","command":"echo other-prompt"}]}]}}\n' > "$WORK/$t/.claude/settings.json"   # one with hooks of an older form and hooks of somebody else's
  for run in 1 2; do
    bash "$ROOT/bin/init.sh" "$WORK/$t" --no-doctor > "$WORK/$t-init.log" 2>&1 || fail "init.sh in $t (run $run)"
    if [ "$run" = 1 ]; then
      dirty="$(git -C "$WORK/$t" status --porcelain | tr -d '\r')"
      if [ "$t" = "repo" ]; then
        # the checkout: init committed the block itself, and nothing else
        [ -z "$dirty" ] || fail "init.sh in $t left something uncommitted: $(echo "$dirty" | tr '\n' ' ')"
        [ "$(git -C "$WORK/$t" log -1 --format=%s)" = "the agent files of this repository are ignored" ] || fail "init.sh in $t did not commit .gitignore itself"
        [ "$(git -C "$WORK/$t" log -1 --format='%(trailers:key=No-issue,valueonly)' | tr -d '\n')" = "the .gitignore block written by ai-core init" ] || fail "init.sh: the .gitignore commit carries no No-issue trailer"
        [ "$(git -C "$WORK/$t" show --pretty=format: --name-only HEAD | grep -v '^$' | tr '\n' ' ')" = ".gitignore " ] || fail "init.sh: the .gitignore commit carries more than .gitignore"
      else
        # the worktree: somebody's issue; init leaves its .gitignore as the branch has it, and
        # the exclude file it shares with the checkout keeps the deployed files out
        [ -z "$dirty" ] || fail "init.sh in $t left something uncommitted: $(echo "$dirty" | tr '\n' ' ')"
        [ "$(git -C "$WORK/$t" log -1 --format=%s)" = init ] || fail "init.sh committed in the worktree $t: $(git -C "$WORK/$t" log -1 --format=%s)"
      fi
    fi
  done
  dirty="$(git -C "$WORK/$t" status --porcelain)"
  [ -z "$dirty" ] || fail "init.sh left untracked files in $t: $(echo "$dirty" | tr '\n' ' ')"
  AI_CORE_CMD="$ROOT/bin/ai-core"
  jq -e --arg c "\"$AI_CORE_CMD\" session-start --tool claude" '([.hooks.SessionStart[].hooks[].command] - ["echo other"] == [$c]) and ((.permissions.allow | index("Bash(x)")) != null) and ((.permissions.allow | index("Bash(ai-core:*)")) != null) and ([.permissions.allow[] | select(. == "Bash(ai-core:*)")] | length == 1)' "$WORK/$t/.claude/settings.json" > /dev/null || fail "init.sh did not merge the session-start hook, by the full path of ai-core and once, and Bash(ai-core:*), once, into the settings.json $t had: $(tr -d '\n' < "$WORK/$t/.claude/settings.json")"
  [ "$t" = "repo" ] && { [ "$(jq '[.hooks.SessionStart[].hooks[].command] | index("echo other") != null' "$WORK/$t/.claude/settings.json")" = true ] || fail "init.sh took somebody else's hook out of the settings.json $t had"; }
  jq -e --arg p "\"$AI_CORE_CMD\" permission-request" '[.hooks.PermissionRequest[].hooks[].command] - ["echo other-prompt"] == [$p]' "$WORK/$t/.claude/settings.json" > /dev/null || fail "init.sh did not merge the permission-request hook, by the full path of ai-core and once, into the settings.json $t had: $(jq -c '.hooks.PermissionRequest' "$WORK/$t/.claude/settings.json")"
  [ "$t" = "repo" ] && { [ "$(jq '[.hooks.PermissionRequest[].hooks[].command] | index("echo other-prompt") != null' "$WORK/$t/.claude/settings.json")" = true ] || fail "init.sh took somebody else's permission-request hook out of the settings.json $t had"; }
  jq -e --slurpfile t "$ROOT/templates/.claude/settings.json" '(($t[0].permissions.deny - .permissions.deny) | length == 0) and ([.permissions.deny[] | select(. == "Read(**/.env)")] | length == 1)' "$WORK/$t/.claude/settings.json" > /dev/null || fail "init.sh did not merge the denials of the template, once, into the settings.json $t had: $(jq -c '.permissions.deny' "$WORK/$t/.claude/settings.json")"
  [ "$t" = "repo" ] && { [ "$(jq '.permissions.deny | index("Bash(rm -rf:*)") != null' "$WORK/$t/.claude/settings.json")" = true ] || fail "init.sh took the denial the settings.json of $t had out"; }
  # the context size is the coordinator's, per session; init sets none and takes an old one out
  [ "$(jq 'has("autoCompactWindow")' "$WORK/$t/.claude/settings.json")" = false ] || fail "init.sh left a compact window in the settings.json of $t: $(jq -c '.autoCompactWindow' "$WORK/$t/.claude/settings.json")"
  # Claude Code asks no session to sign: the attribution of the template, merged into the one the checkout had
  [ "$(jq -c '.attribution' "$WORK/$t/.claude/settings.json")" = '{"commit":"","pr":"","sessionUrl":false}' ] || fail "init.sh did not set the empty attribution in the settings.json of $t: $(jq -c '.attribution' "$WORK/$t/.claude/settings.json")"
  [ "$run" = 1 ] && [ "$t" = "repo" ] && { grep -aq '^  refreshed .*\.claude/settings\.json' "$WORK/$t-init.log" || fail "init.sh did not report the merged settings.json as refreshed"; }
  [ "$run" = 2 ] && grep -aq '^  refreshed .*\.claude/settings\.json' "$WORK/$t-init.log" && fail "init.sh refreshed the settings.json of $t a second time"
  # a compact window written by hand into a settings.json that is otherwise current goes too
  jq '.autoCompactWindow = 500000' "$WORK/$t/.claude/settings.json" > "$WORK/$t-settings.json" && cat "$WORK/$t-settings.json" > "$WORK/$t/.claude/settings.json"
  bash "$ROOT/bin/init.sh" "$WORK/$t" --no-doctor > "$WORK/$t-init.log" 2>&1 || fail "init.sh in $t (run 3)"
  [ "$(jq 'has("autoCompactWindow")' "$WORK/$t/.claude/settings.json")" = false ] || fail "init.sh kept a compact window written by hand into the settings.json of $t"
  # a status line taken out of, or another one put into, a settings.json that is otherwise current is set again
  if [ "$t" = "repo" ]; then jq 'del(.statusLine)' "$WORK/$t/.claude/settings.json" > "$WORK/$t-settings.json"
  else jq '.statusLine = {type: "command", command: "echo mine"}' "$WORK/$t/.claude/settings.json" > "$WORK/$t-settings.json"; fi
  cat "$WORK/$t-settings.json" > "$WORK/$t/.claude/settings.json"
  bash "$ROOT/bin/init.sh" "$WORK/$t" --no-doctor > "$WORK/$t-init.log" 2>&1 || fail "init.sh in $t (run 4)"
  [ "$(jq -r '.statusLine.command' "$WORK/$t/.claude/settings.json")" = "\"$AI_CORE_CMD\" statusline" ] || fail "init.sh did not set the status line again in the settings.json of $t: $(jq -c '.statusLine' "$WORK/$t/.claude/settings.json")"
done
n="$(grep -c '^# setup-ai-core start' "$WORK/repo/.git/info/exclude")"
[ "$n" = 1 ] || fail "exclude block written $n times by init.sh"
echo "  git status empty in 2 targets, the checkouts' .gitignore committed by init with its trailer, the worktrees' left as their branch has it; exclude block written once each; the session-start and permission-request hooks merged into the settings.json each had, once; no compact window left in it; the status line set again where it was taken out or replaced"
exit 0
