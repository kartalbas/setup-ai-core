#!/usr/bin/env bash
# Start a phase session on exactly the tuple that ai-core phase-model selects, for every tool, and print its worker line.
#
#   start-phase.sh PHASE CLASS --issue OWNER/REPO#N --brief FILE --number N [--written-by MODEL] [--setup-file PATH]
#                  [--budget K] [--add-dir PATH]... [--package OWNER/REPO#N --reason COMMENT]
#   start-phase.sh --resume NAME "TEXT"
#
# Run it in the folder the phase starts in. PHASE is plan, re-plan, plan-check, build, review, ui-test or keeper.
# The tool, model and effort are the ones phase-model prints; the command takes no --tool, --model or --effort, and
# one given is refused with the selector's tuple beside it. The session is named
# <phase><number>-<model><version>-<effort>-<budget>k-<5 hex>, the number from --number, the budget from the Setup file's
# budget_tokens of the phase and tool, or from --budget in thousands of tokens. The brief is copied to
# ~/.ai-core/sessions/<name>.brief.md with the frame of the harness, and the session is told to read it.
# --add-dir names a folder the session may also edit in; a resume adds the same ones again.
# The start record ~/.ai-core/sessions/<name>.start.jsonl carries the issue, what the brief says it does, and the deadline:
# one and a half times the duration of the newest ended run of the same phase and class, or "unmeasured" where none ended.
# A re-plan needs --package, the first issue of the package as its PHASE lines name it, and --reason: the URL or the
# number of a comment on the plan issue (--issue) whose first line is a plan-check verdict `PLAN CHECK ...: NO`, or whose
# first line is `Owner's decision` or `Owner's yes` with the date of the answer. A re-plan for drift, a merge, a rebase or a
# conflict is a build on the new base, and one for a cut, an order, a host, a name or a path is an edit of the section by the
# coordinator. The command posts the PHASE line of the re-plan on the plan issue: "re-plan number N of the package", the
# first plan counted, with the link to the reason.
# --resume starts the same session on the same tuple again with TEXT; it refuses where the selector's tuple changed.
#
# Stdout is one line: <name> <tool> <phase> OWNER/REPO#N: <what it does> (<the deadline>). Exit 2 refuses, on stderr.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/lib/common.sh"
. "$ROOT/lib/tool-order.sh"
. "$ROOT/lib/start-phase.sh"
tool_order_paths

usage='usage: start-phase.sh PHASE CLASS --issue OWNER/REPO#N --brief FILE --number N [--written-by MODEL] [--setup-file PATH] [--budget K] [--add-dir PATH]... [--package OWNER/REPO#N --reason COMMENT] | start-phase.sh --resume NAME TEXT'
case "${1-}" in
  -h|--help) awk 'NR == 1 && /^#!/ { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
esac
refuse() { start_phase_error "$*"; exit 2; }

sessions="$(start_phase_sessions)"
SP_OPERATION=start; SP_TEXT=''; SP_NATIVE_ID=''; SP_NATIVE=''; SP_WRITER=''; SP_PROJECT="$PWD"
setup_file=''; budget=''; number=''; issue=''; brief=''; package=''; reason=''; resume_name=''
given_tool=''; given_model=''; given_effort=''; extra_roots=()

if [ "${1-}" = --resume ]; then
  [ $# -eq 3 ] && [ -n "$2" ] && [ -n "$3" ] || refuse "--resume takes the session name and the text: $usage"
  resume_name="$2"; SP_TEXT="$3"; SP_OPERATION=resume
else
  [ $# -ge 2 ] || refuse "start-phase needs PHASE and CLASS: $usage"
  SP_PHASE="$1"; SP_CLASS="$2"; shift 2
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] && [ -n "$2" ] || refuse "$1 takes a value: $usage"
    case "$1" in
      --issue) issue="$2" ;; --brief) brief="$2" ;; --number) number="$2" ;; --written-by) SP_WRITER="$2" ;;
      --setup-file) setup_file="$2" ;; --budget) budget="$2" ;; --add-dir) extra_roots+=("$2") ;;
      --package) package="$2" ;; --reason) reason="$2" ;;
      --tool) given_tool="$2" ;; --model) given_model="$2" ;; --effort) given_effort="$2" ;;
      *) refuse "unknown argument $1: $usage" ;;
    esac
    shift 2
  done
fi

# --- the intent, before anything is read or started ------------------------------------------------------------------------

if [ "$SP_OPERATION" = resume ]; then
  record="$sessions/$resume_name.start.jsonl"
  [ -f "$record" ] || refuse "no start record of $resume_name: $record"
  attempt="$(jq -c 'select(.kind == "attempt" and .operation == "start")' "$record" | head -n 1)"
  [ -n "$attempt" ] || refuse "the start record of $resume_name holds no launch attempt"
  SP_NAME="$resume_name"; SP_PHASE="$(jq -r .phase <<< "$attempt")"; SP_CLASS="$(jq -r .class <<< "$attempt")"; SP_WRITER="$(jq -r .writer <<< "$attempt")"
  setup_file="$(jq -r '.setupFile // ""' <<< "$attempt")"; issue="$(jq -r .issue <<< "$attempt")"; budget="$(jq -r .budgetK <<< "$attempt")"
  SP_PROJECT="$(jq -r .project <<< "$attempt")"
  while IFS= read -r root; do extra_roots+=("$root"); done < <(jq -r '.addDirs[]' <<< "$attempt")
  SP_NATIVE_ID="$(jq -r 'select(.kind == "native") | .nativeIdentity' "$record" | tail -n 1)"
else
  case " $START_PHASE_PHASES " in *" $SP_PHASE "*) ;; *)
    case "$SP_PHASE" in
      helper) refuse "helper is no phase session: a helper call is made by the session that asks it" ;;
      coordinator) refuse "coordinator is not started here: the owner starts the coordinator" ;;
      *) refuse "unknown phase $SP_PHASE: the phases are $START_PHASE_PHASES" ;;
    esac ;;
  esac
  [[ "$issue" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+#[0-9]+$ ]] || refuse "--issue takes OWNER/REPO#N, not '$issue'"
  [ -f "$brief" ] && [ -r "$brief" ] || refuse "--brief names no readable file: '$brief'"
  [[ "$number" =~ ^[0-9]+$ ]] && [ "$number" -ge 10001 ] && [ $((number % 10000)) -ne 0 ] || refuse "--number takes a number of the coordinator's block (10001 and on), not '$number'"
  start_phase_number_used "$number" && refuse "the number $number is used already by a session in $sessions"
  if [ "$SP_PHASE" = re-plan ]; then
    [[ "$package" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+#[0-9]+$ ]] && [ -n "$reason" ] \
      || refuse "a re-plan needs --package OWNER/REPO#N and --reason: the comment on the plan issue $issue that holds a plan-check NO or an owner's decision. A re-plan for drift, a merge, a rebase or a conflict is a build on the new base; one for a cut, an order, a host, a name or a path is an edit of the section by the coordinator"
  elif [ -n "$reason$package" ]; then refuse "--reason and --package belong to a re-plan"; fi
fi
case "$SP_CLASS" in normal-hard|high-risk|mechanical) ;; *) refuse "unknown class $SP_CLASS: the classes are normal-hard, high-risk and mechanical" ;; esac
[ -z "$setup_file" ] || [ -r "$setup_file" ] || refuse "the setup file is not readable: $setup_file"
for root in ${extra_roots[@]+"${extra_roots[@]}"}; do [ -d "$root" ] || refuse "--add-dir names no folder: $root"; done

# --- the re-plan gate --------------------------------------------------------------------------------------------------------

replan_reason_url=''; replan_number=''; replan_line=''
check_replan_reason() {
  local plan_repo="${issue%%#*}" plan_number="${issue##*#}" thread comment first newest count
  thread="$(bash "$ROOT/bin/ai-core" issue-thread "$plan_repo" "$plan_number" --json)" || refuse "the plan issue $issue could not be read, so the reason of the re-plan is not known"
  comment="$(jq -c --arg reason "$reason" '[.comments[] | select(.url != null) | select(.url == $reason or (($reason | test("^[0-9]+$")) and (.url | endswith("#issuecomment-" + $reason))))]
    | if length == 1 then .[0] else empty end' <<< "$thread")"
  [ -n "$comment" ] || refuse "--reason $reason names no comment of the plan issue $issue"
  first="$(jq -r '.body | split("\n")[0]' <<< "$comment")"
  if ! [[ "$first" =~ ^PLAN\ CHECK\ .*:\ NO$ ]] && ! [[ "$first" =~ ^Owner\'s\ (decision|yes).*[0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then
    refuse "the comment $reason is no reason for a re-plan: its first line is neither a plan-check verdict 'PLAN CHECK ...: NO' nor an owner's decision ('Owner's decision' or 'Owner's yes' with the date of the answer). Drift, a merge, a rebase or a conflict goes to the build on the new base; a cut, an order, a host, a name or a path is an edit of the section by the coordinator"
  fi
  replan_reason_url="$(jq -r .url <<< "$comment")"
  count="$(jq -r --arg package "$package" '[.comments[].body | split("\n")[0] | select(test("^PHASE [^:]+: (plan|re-plan) \\| ") and contains(" | package \($package) |"))] | length' <<< "$thread")"
  [ "$count" -gt 0 ] || refuse "the plan issue $issue holds no PHASE line of a plan of the package $package: a re-plan follows a plan"
  newest="$(jq -r --arg package "$package" '[.comments[].body | split("\n")[0] | select(test("^PHASE [^:]+: (plan|re-plan|plan-check|build|review|ui-test|keeper) \\| ") and contains(" | package \($package) |"))] | last' <<< "$thread")"
  replan_number=$((count + 1))
  replan_line="$newest"
}
[ "$SP_PHASE" != re-plan ] || [ "$SP_OPERATION" = resume ] || check_replan_reason

# --- the selection ---------------------------------------------------------------------------------------------------------

select_args=("$SP_PHASE" "$SP_CLASS")
[ -z "$SP_WRITER" ] || select_args+=(--written-by "$SP_WRITER")
[ -z "$setup_file" ] || select_args+=(--setup-file "$setup_file")
cd "$SP_PROJECT" || refuse "the folder of the start is gone: $SP_PROJECT"
selection="$(bash "$ROOT/bin/phase-model.sh" "${select_args[@]}")" || exit 2
read -r SP_TOOL SP_MODEL SP_EFFORT <<< "$selection"
if [ -n "$given_tool$given_model$given_effort" ]; then
  refuse "start-phase starts on the tuple of ai-core phase-model, $SP_TOOL $SP_MODEL $SP_EFFORT, and takes no --tool, --model or --effort: you gave ${given_tool:--} ${given_model:--} ${given_effort:--}"
fi
if [ "$SP_OPERATION" = resume ]; then
  [ "$(jq -r '"\(.tool) \(.model) \(.effort)"' <<< "$attempt")" = "$SP_TOOL $SP_MODEL $SP_EFFORT" ] \
    || refuse "$resume_name started on $(jq -r '"\(.tool) \(.model) \(.effort)"' <<< "$attempt") and phase-model now selects $SP_TOOL $SP_MODEL $SP_EFFORT: start a fresh session through start-phase with the current brief, saved work and last report; no foreign id"
fi
key=''
if ! tool_order_is_native "$SP_TOOL"; then key="$SP_TOOL"; tool_order_check_secret "$key" || exit 2; fi

# --- the name, the brief, the deadline and the record --------------------------------------------------------------------------

mkdir -p "$sessions" || refuse "cannot create $sessions"
if [ "$SP_OPERATION" = start ]; then
  if [ -n "$budget" ]; then
    [[ "$budget" =~ ^[0-9]+$ ]] && [ "$budget" -gt 0 ] || refuse "--budget takes thousands of tokens, a whole number above 0, not '$budget'"
  elif [ -n "$setup_file" ]; then
    budget="$(jq -r --arg phase "$SP_PHASE" --arg tool "$SP_TOOL" '.[$phase][$tool].budget_tokens // empty | (. + 999) / 1000 | floor' "$setup_file")" \
      || refuse "cannot read the budget from $setup_file"
  fi
  [ -n "$budget" ] || refuse "no budget: the setup file holds none for $SP_PHASE on $SP_TOOL, and --budget (thousands of tokens) is not given"
  SP_NAME="$(start_phase_name "$SP_PHASE" "$number" "$SP_MODEL" "$SP_EFFORT" "$budget")" || exit 2
  SP_BRIEF="$sessions/$SP_NAME.brief.md"
  start_phase_compose_brief "$brief" "$SP_NAME" "$SP_PHASE" > "$SP_BRIEF.tmp" && mv "$SP_BRIEF.tmp" "$SP_BRIEF" || { rm -f "$SP_BRIEF.tmp"; exit 2; }
  SP_PROMPT="Read $SP_BRIEF whole and carry it out. It is your whole task. Your last message is your report."
else
  SP_BRIEF="$sessions/$SP_NAME.brief.md"
  [ -f "$SP_BRIEF" ] || refuse "the brief of $SP_NAME is gone: $SP_BRIEF"
  SP_PROMPT=''
fi
SP_BUDGET_K="$budget"
does="$(start_phase_does "$SP_BRIEF")"
measured="$(start_phase_measured "$SP_PHASE" "$SP_CLASS")"
SP_INVOKED="$(jq -n now)"
if [ -n "$measured" ]; then
  measured_seconds="${measured%%$'\t'*}"; measured_from="${measured#*$'\t'}"
  deadline="$(jq -n --argjson at "$SP_INVOKED" --argjson seconds "$measured_seconds" '$at + $seconds * 1.5')"
  deadline_text="deadline in $(awk -v s="$measured_seconds" 'BEGIN { printf "%d", s * 1.5 / 60 + 0.999 }') min, 1.5 x ${measured_seconds} s of $measured_from"
else
  measured_seconds=null; measured_from=''; deadline=null; deadline_text="deadline: unmeasured"
fi
SP_ROOTS="$(jq -cn --arg project "$SP_PROJECT" --arg state "$TOOL_ORDER_HOME" '[$project,$state] + $ARGS.positional' --args ${extra_roots[@]+"${extra_roots[@]}"})"
SP_CWD="$SP_PROJECT"
if [ "$SP_PHASE" = ui-test ]; then SP_CWD="$sessions/$SP_NAME.cwd"; mkdir -p "$SP_CWD" || exit 2; fi
SP_OUTPUT=none
if [ -n "$key" ]; then SP_OUTPUT=json
elif [ "$SP_TOOL" = codex ]; then SP_OUTPUT=jsonl
elif [ "$SP_TOOL" = agy ]; then SP_OUTPUT=json
elif [ "$SP_PHASE" = ui-test ]; then SP_OUTPUT=text; fi
if [ "$SP_OPERATION" = resume ] && { [ -n "$key" ] || { [ "$SP_PHASE" = ui-test ] && [ "$SP_TOOL" = claude ]; }; }; then
  refuse "$SP_NAME was a print run, which has no session to resume: start a fresh session through start-phase with the current brief, saved work and last report"
fi
SP_RECORD="$sessions/$SP_NAME.start.jsonl"
SP_OUT="$sessions/$SP_NAME.out"; SP_ERR="$sessions/$SP_NAME.err"; SP_PID="$sessions/$SP_NAME.pid"; SP_EXIT="$sessions/$SP_NAME.exit"
if [ "$SP_OPERATION" = resume ] && [ "$SP_OUTPUT" != none ]; then
  for suffix in out err; do [ ! -e "$sessions/$SP_NAME.$suffix" ] || mv "$sessions/$SP_NAME.$suffix" "$sessions/$SP_NAME.$suffix.before-$SP_INVOKED"; done
  rm -f "$SP_PID" "$SP_EXIT"
elif [ "$SP_OPERATION" = start ] && [ -e "$SP_RECORD" ]; then refuse "a start record of $SP_NAME exists already"; fi
SP_EXTRA="$(jq -cn --arg issue "$issue" --arg does "$does" --arg project "$SP_PROJECT" --arg setup "$setup_file" --arg output "$SP_OUTPUT" --argjson budget "$SP_BUDGET_K" \
  --argjson deadline "$deadline" --argjson measuredSeconds "$measured_seconds" --argjson measuredFrom "$(jq -cn --arg from "$measured_from" 'if $from == "" then null else $from end')" \
  --argjson roots "$(jq -cn '$ARGS.positional' --args ${extra_roots[@]+"${extra_roots[@]}"})" \
  '{issue:$issue,does:$does,project:$project,setupFile:$setup,output:$output,budgetK:$budget,deadline:$deadline,measuredSeconds:$measuredSeconds,measuredFrom:$measuredFrom,addDirs:$roots}')" || exit 2
start_phase_observe attempt || exit 2

# --- the start -------------------------------------------------------------------------------------------------------------

if [ -n "$key" ]; then start_phase_claude_print "$key" || exit 2
elif [ "$SP_TOOL" = claude ] && [ "$SP_PHASE" = ui-test ]; then start_phase_claude_print "" || exit 2
elif [ "$SP_TOOL" = claude ]; then start_phase_claude_background || exit 2
elif [ "$SP_TOOL" = codex ]; then start_phase_codex || exit 2
else SP_TEXT="${SP_TEXT:-}"; start_phase_agy || exit 2; fi
[ -z "$SP_NATIVE" ] || start_phase_observe native "$SP_NATIVE" || exit 2

printf '%s %s %s %s: %s (%s)%s\n' "$SP_NAME" "$SP_TOOL" "$SP_PHASE" "$issue" "$does" "$deadline_text" "$([ "$SP_OPERATION" = resume ] && echo ', resumed')"

if [ "$SP_PHASE" = re-plan ] && [ "$SP_OPERATION" = start ]; then
  line="$(jq -rn --arg line "$replan_line" --arg name "$SP_NAME" --arg tuple "$SP_TOOL $SP_MODEL $SP_EFFORT" --arg number "$replan_number" --arg url "$replan_reason_url" \
    --arg order "$(tail -n 1 "$TOOL_ORDER_DECISIONS" | jq -r '.order | if . == null then "not set" else .tools | join(",") end')" '
    ($line | split(" | ")) as $f | ($f[0] | sub("^PHASE (?<area>[^:]+): .*$"; "PHASE \(.area): re-plan")) as $head
    | if ($f | length) < 11 then error("the newest PHASE line of the package has \($f | length) fields, not 11") else
      [$head, $name, "order \($order)", "selected \($tuple)", "plans \($number)", $f[5], $f[6], "re-plan number \($number) of the package, reason \($url)", $f[8], $f[9], $f[10]] | join(" | ") end')" \
    || { start_phase_error "the PHASE line of the re-plan cannot be written; $SP_NAME runs"; exit 2; }
  body="$(mktemp)" && printf '%s\n' "$line" > "$body" \
    && bash "$ROOT/bin/ai-core" issue-comment "${issue%%#*}" "${issue##*#}" --body-file "$body" > /dev/null 2>&1 \
    || { rm -f "$body"; start_phase_error "the PHASE line of the re-plan was NOT posted on $issue; $SP_NAME runs, post this line: $line"; exit 2; }
  rm -f "$body"
fi
