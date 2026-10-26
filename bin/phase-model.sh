#!/usr/bin/env bash
# Select the first execution tool with a declared independent model and a successful quota read.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/lib/common.sh"
. "$ROOT/lib/tool-order.sh"
tool_order_paths
began="$(jq -n now)" || exit 2
case "${1-}" in
  -h|--help) echo 'Usage: ai-core phase-model PHASE CLASS [--written-by MODEL]'; echo 'Print exactly TOOL MODEL EFFORT; plan-check and review require the actual writer.'; exit 0 ;;
esac
[ $# -ge 2 ] || { tool_order_error 'phase-model needs PHASE CLASS [--written-by MODEL]'; exit 2; }
phase="$1"; class="$2"; shift 2
writer=''
if [ $# -gt 0 ]; then
  [ $# -eq 2 ] && [ "$1" = --written-by ] && [ -n "$2" ] && [[ "$2" != -* ]] \
    || { tool_order_error 'phase-model takes only --written-by MODEL after PHASE CLASS'; exit 2; }
  writer="$2"
fi
project="$(project_folder_of "$PWD")" && project="$(cd "$project" && pwd -P)" || exit 2
reasons='[]'; selected=null; failure=''; order=null
reason() { reasons="$(jq -c --arg tool "$1" --arg reason "$2" --argjson exit "${3:-null}" '. + [{tool:$tool,reason:$reason,exit:$exit}]' <<< "$reasons")"; }
order="$(tool_order_snapshot)" || { order=null; failure='cannot read tool order'; }
case "$phase" in plan|re-plan|plan-check|build|review|ui-test|coordinator|helper) ;; *) failure="unknown phase: $phase" ;; esac
case "$class" in normal-hard|high-risk|mechanical) ;; *) failure="unknown class: $class" ;; esac
case "$phase" in plan-check|review) [ -n "$writer" ] || failure="$phase requires --written-by MODEL" ;; esac
if [ -z "$failure" ]; then
  if [ "$order" = null ]; then
    tools="$(session_tool)"; tools="${tools:-claude}"
    printf 'tool order: not set; native-tool selection (%s)\n' "$tools" >&2
  else tools="$(jq -r '.tools[]' <<< "$order")"; fi
  table="$(data_file models.tsv)"
  while IFS= read -r tool; do
    case "$tool" in codex|agy|claude) ;; *) failure="usage does not support native tool $tool"; reason "$tool" "$failure"; break ;; esac
    row="$(phase_model_row "$tool" "$phase" "$class" "$table")" || { failure="cannot read $table for $tool"; reason "$tool" "$failure"; break; }
    if [ -z "$row" ]; then reason "$tool" "no row for $phase $class"; continue; fi
    IFS=$'\t' read -r source row_phase row_class model effort <<< "$row"
    actual="$tool"
    if [[ "$model" == *:* ]]; then
      actual="${model%%:*}"; model="${model#*:}"
      case "$actual" in codex|agy|claude) ;; *) failure="unsupported destination $actual"; reason "$tool" "$failure"; break ;; esac
      if [ "$order" != null ] && [ "$actual" != "$tool" ]; then reason "$tool" "row routes to $actual; saved order governs execution tools"; continue; fi
      destination="$(phase_model_row "$actual" "$phase" "$class" "$table")" || { failure="cannot resolve $actual:$model"; reason "$tool" "$failure"; break; }
      IFS=$'\t' read -r dest_tool dest_phase dest_class dest_model dest_effort <<< "$destination"
      if [ "${dest_model-}" != "$model" ]; then reason "$tool" "no declared destination row for $actual:$model"; continue; fi
      effort="$dest_effort"
    fi
    if [ -n "$writer" ] && [ "$(phase_model_base "$model")" = "$(phase_model_base "$writer")" ]; then reason "$tool" "writer model $writer is not independent"; continue; fi
    args=(--tool "$actual"); [ "$actual" != agy ] || args+=(--model "$model")
    rc=0; reading="$(bash "$ROOT/bin/usage.sh" "${args[@]}" 2>&1)" || rc=$?
    reason "$actual" "$reading" "$rc"
    case "$rc" in
      0) selected="$(jq -cn --arg tool "$actual" --arg model "$model" --arg effort "$effort" '{tool:$tool,model:$model,effort:$effort}')"; break ;;
      3|4) ;;
      *) failure="$actual usage failed (exit $rc): $reading"; break ;;
    esac
  done <<< "$tools"
  [ "$selected" != null ] || failure="${failure:-no eligible tool for $phase $class}"
fi
record="$(jq -cn --argjson began "$began" --arg project "$project" --arg phase "$phase" --arg class "$class" --arg writer "$writer" \
  --argjson order "$order" --argjson selected "$selected" --argjson reasons "$reasons" --arg refusal "$failure" \
  '{version:1,began:$began,time:now,project:$project,phase:$phase,class:$class,writer:$writer,order:$order,selected:$selected,refusal:$refusal,reasons:$reasons}')" || exit 2
tool_order_record "$record" || exit 2
if [ -n "$failure" ]; then
  printf 'error: %s\n' "$failure" >&2
  jq -r '.[] | "\(.tool): \(.reason)"' <<< "$reasons" >&2
  exit 2
fi
jq -r '"\(.tool) \(.model) \(.effort)"' <<< "$selected"
