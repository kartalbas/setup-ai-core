#!/usr/bin/env bash
# Persist the owner's execution-tool preference across projects and coordinator restarts.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/lib/common.sh"
. "$ROOT/lib/tool-order.sh"
tool_order_paths
case "${1-}" in
  -h|--help) echo 'Usage: ai-core tool-order [TOOL[,TOOL...] | --clear]'; echo 'Read or atomically replace the machine-wide order and its set time.'
    echo '--clear removes the saved order, so each session selects by its native tool and the routing rows of the model table.'; exit 0 ;;
  --clear) [ $# -eq 1 ] || { tool_order_error '--clear takes no order'; exit 2; }
    tool_order_save '' || exit 2; tool_order_show; exit $? ;;
esac
[ $# -le 1 ] || { tool_order_error 'tool-order takes one comma-separated order'; exit 2; }
[ $# -gt 0 ] || { tool_order_show; exit $?; }
order="$1"
case "$order" in ''|,*|*,|*,,*) tool_order_error 'tool-order rejects empty entries'; exit 2 ;; esac
table="$(data_file models.tsv)"; seen=','
IFS=',' read -r -a tools <<< "$order"
for tool in "${tools[@]}"; do
  tool_order_is_tool "$tool" || { tool_order_error "unknown tool: $tool (the tools are $(tool_order_tools | paste -sd, - | sed 's/,/, /g'))"; exit 2; }
  case "$seen" in *",$tool,"*) tool_order_error "duplicate tool: $tool"; exit 2 ;; esac
  seen="$seen$tool,"
  model="$(awk -F'\t' -v t="$tool" '!/^#/ && $1 == t && NF == 5 { print $4; exit }' "$table")" \
    || { tool_order_error "cannot read $table"; exit 2; }
  [ -n "$model" ] || { tool_order_error "$tool has no model rows in $table"; exit 2; }
  args=(--tool "$tool"); [ "$tool" != agy ] || args+=(--model "${model#agy:}")
  rc=0; reading="$(bash "$ROOT/bin/usage.sh" "${args[@]}" 2>&1)" || rc=$?
  case "$rc" in 0|3) ;; *) tool_order_error "$tool usage failed (exit $rc): $reading"; exit 2 ;; esac
done
tool_order_save "$order" || exit 2
tool_order_show
