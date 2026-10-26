#!/usr/bin/env bash
# Clear inherited identity before fixtures deliberately select a tool, and keep the git config of the
# machine out of every test: a commit made without an identity fails here as it does on a runner.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
while IFS= read -r tool_variable; do unset "$tool_variable"; done < <(tool_environment_variables)
unset tool_variable
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
