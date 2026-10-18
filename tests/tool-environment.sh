#!/usr/bin/env bash
# Clear inherited identity before fixtures deliberately select a tool.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
while IFS= read -r tool_variable; do unset "$tool_variable"; done < <(tool_environment_variables)
unset tool_variable
