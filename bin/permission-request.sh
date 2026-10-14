#!/usr/bin/env bash
# The PermissionRequest hook, which init puts into .claude/settings.json. Claude Code runs it when it
# is about to ask a person whether a tool call may run, and hands it the call as JSON on standard
# input. A background session (CLAUDE_JOB_DIR set) has nobody at its terminal, so the prompt would
# wait for good: the hook answers deny, with a message that names the call and the ways that need no
# prompt, and the session goes on. Everywhere else it prints nothing, and the prompt is shown as before.
# It never answers allow: a prompt is what Claude Code keeps for a person, and an automatic yes would
# pass all of it unread.
#
#   permission-request.sh    Claude Code's PermissionRequest JSON on standard input
set -uo pipefail

case "${1:-}" in -h|--help) echo "usage: permission-request.sh  (Claude Code's PermissionRequest JSON on standard input; denies the prompt in a background session)"; exit 0 ;; esac
input="$(cat)"
[ -n "${CLAUDE_JOB_DIR:-}" ] || exit 0
jq -c '(.tool_input.command // .tool_input.file_path // .tool_input.path // (.tool_input | tostring)) as $what
  | {hookSpecificOutput: {hookEventName: "PermissionRequest", decision: {behavior: "deny", interrupt: false,
     message: "Denied without asking: this is a background session and nobody answers its permission prompts, so the prompt for \(.tool_name // "this tool") `\($what)` would wait for good. Take a way that needs no prompt: an absolute path instead of cd, git -C <dir>, the Read tool for a file. If the step truly needs a yes, report it to your coordinator with the exact command and go on with the rest."}}}' <<< "$input"
