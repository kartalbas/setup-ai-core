#!/usr/bin/env bash
# The Claude Code settings the harness writes: into a checkout by bin/init.sh, and into a harness source, which init never
# assembles, by arm_claude_hooks of lib/layers.sh. Source it.
#
# They hold the hook that starts the session, the hook that denies a permission prompt in a background session, where
# nobody would answer it (bin/permission-request.sh), the hooks that hold the rules a script can hold: before every tool
# call the one that refuses a call after a compaction until the rules files are read and a message with a time the clock
# does not show (bin/pre-tool-use.sh), and after a Read the one that marks a rules file read whole (bin/post-tool-use.sh),
# the status line that records the account's usage windows for `ai-core usage` (bin/statusline.sh), the permissions of
# the template (the ai-core commands) and its denials (the secrets of a checkout and the credentials of the machine are
# not read, a push is not forced, git reset --hard and git clean are refused), each list read from the template, and its
# empty attribution, so Claude Code asks no session to sign a commit or a pull request, which the commit rules forbid.
# The hooks and the status line name ai-core by its full path on this machine, so a Claude Code started from a terminal
# opened before the install still runs them. A settings.json the tree had before gets what it lacks merged in, and an
# ai-core hook of an older form gives way to this one.

CLAUDE_SETTINGS_HAS='def ours: (.command // "") | test("ai-core.? session-start --tool claude$"); def ours_p: (.command // "") | test("ai-core.? permission-request$"); def ours_pre: (.command // "") | test("ai-core.? pre-tool-use$"); def ours_post: (.command // "") | test("ai-core.? post-tool-use$"); ($t[0].permissions.allow // []) as $allow | ($t[0].permissions.deny // []) as $deny | ([.hooks.SessionStart[]?.hooks[]? | select(ours) | .command] == [$c]) and ([.hooks.PermissionRequest[]?.hooks[]? | select(ours_p) | .command] == [$p]) and ([.hooks.PreToolUse[]?.hooks[]? | select(ours_pre) | .command] == [$pre]) and ([.hooks.PostToolUse[]?.hooks[]? | select(ours_post) | .command] == [$post]) and ([.hooks.PostToolUse[]? | select(.matcher == "Read") | .hooks[]? | select(ours_post)] | length == 1) and (($allow - (.permissions.allow // [])) | length == 0) and (($deny - (.permissions.deny // [])) | length == 0) and (has("autoCompactWindow") | not) and (.statusLine.command == $s) and (.attribution == ((.attribution // {}) + $t[0].attribution))'
CLAUDE_SETTINGS_ADD='def ours: (.command // "") | test("ai-core.? session-start --tool claude$"); def ours_p: (.command // "") | test("ai-core.? permission-request$"); def ours_pre: (.command // "") | test("ai-core.? pre-tool-use$"); def ours_post: (.command // "") | test("ai-core.? post-tool-use$"); ($t[0].permissions.allow // []) as $allow | ($t[0].permissions.deny // []) as $deny | .hooks.SessionStart = ([.hooks.SessionStart[]? | .hooks = [.hooks[]? | select(ours | not)] | select(.hooks | length > 0)] + [{hooks: [{type: "command", command: $c, timeout: 60}]}]) | .hooks.PermissionRequest = ([.hooks.PermissionRequest[]? | .hooks = [.hooks[]? | select(ours_p | not)] | select(.hooks | length > 0)] + [{hooks: [{type: "command", command: $p, timeout: 10}]}]) | .hooks.PreToolUse = ([.hooks.PreToolUse[]? | .hooks = [.hooks[]? | select(ours_pre | not)] | select(.hooks | length > 0)] + [{hooks: [{type: "command", command: $pre, timeout: 10}]}]) | .hooks.PostToolUse = ([.hooks.PostToolUse[]? | .hooks = [.hooks[]? | select(ours_post | not)] | select(.hooks | length > 0)] + [{matcher: "Read", hooks: [{type: "command", command: $post, timeout: 10}]}]) | .permissions.allow = ((.permissions.allow // []) + ($allow - (.permissions.allow // []))) | .permissions.deny = ((.permissions.deny // []) + ($deny - (.permissions.deny // []))) | del(.autoCompactWindow) | .statusLine = {type: "command", command: $s} | .attribution = ((.attribution // {}) + $t[0].attribution)'

# claude_settings_merged <setup-ai-core root> <settings file>: prints the settings the tree needs, the file merged with the
# template of the harness, or the template where the file is missing. Returns 1, and prints nothing, where the file holds
# all of it already; 2 where jq cannot read it.
claude_settings_merged() {
  local command="$1/bin/ai-core" template="$1/templates/.claude/settings.json" settings="$2" source merged
  set -- --arg c "\"$command\" session-start --tool claude" --arg p "\"$command\" permission-request" \
    --arg pre "\"$command\" pre-tool-use" --arg post "\"$command\" post-tool-use" --arg s "\"$command\" statusline" \
    --slurpfile t "$template"
  source="$settings"; [ -f "$source" ] || source="$template"
  if [ "$source" = "$settings" ] && jq -e "$@" "$CLAUDE_SETTINGS_HAS" "$settings" > /dev/null 2>&1; then return 1; fi
  merged="$(jq "$@" "$CLAUDE_SETTINGS_ADD" "$source" 2> /dev/null)" && [ -n "$merged" ] || return 2
  printf '%s\n' "${merged//$'\r'/}"
}
