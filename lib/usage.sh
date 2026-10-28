#!/usr/bin/env bash
# What an account's usage windows stand at, as the tool of the session recorded them: the one reader of
# bin/usage.sh (its display and its exit statuses) and of bin/status.sh (its page). Source it, do not run it.
#
#   usage_read TOOL [MODEL]   TOOL is claude, codex or agy; MODEL is for agy. Returns 0 and sets
#     usage_shown     used or left: the share the tool itself shows
#     usage_windows   one row each, tab separated: the window's key in the history, the name shown, its
#                     length in minutes (0 when unknown), the share used, the epoch of its reset
#     usage_recorded  the epoch the tool recorded the windows at
#     usage_readings  the history, one row each: the key, the epoch of the reading, the share used, the
#                     epoch of the reset the reading belonged to
#     usage_notice    one line to show beside the reading, empty when there is nothing to say
#   Returns 2 with usage_failure set to the line to print: "error: ..." for a reading that cannot be used,
#   a plain line for nothing recorded yet.
#   usage_release     releases what usage_read holds (agy's history lock and temporary file); call it on exit.
#   usage_stop_at     the limit in percent used: USAGE_STOP_AT of the project's config.env, else 92.
#   usage_snapshot TOOL   prints the structured snapshot lib/status.mjs reads, one JSON object, for any
#                     tool the session can run on. A reading that failed is the snapshot's "failure", not an error of the
#                     snapshot, which fails only when usage_release does.

usage_history_lock=""
usage_agy_error=""
usage_notice=""

usage_now() { echo "${AI_CORE_NOW:-$(date +%s)}"; }

# A Codex record older than this is refreshed by one minimal Codex call before it counts; the call is given
# the seconds in REFRESH_SECONDS, and a reader that finds another one's call running waits for it that long, and a margin.
USAGE_CODEX_MAX_AGE_SECONDS=3600
USAGE_CODEX_REFRESH_SECONDS=120
USAGE_CODEX_REFRESH_WAIT_SECONDS=150

usage_stop_at() {
  local config stop
  config="$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.ai-core/config.env"
  stop="$(config_value_in_file "$config" USAGE_STOP_AT "")" || return 1
  stop="${stop//[[:space:]]/}"
  echo "${stop:-92}"
}

usage_reject() { usage_failure="error: $*"; }

usage_release() {
  local status=0
  if [ -n "$usage_history_lock" ]; then
    rm "$usage_history_lock" || { echo "error: cannot release $usage_history_lock" >&2; status=2; }
    usage_history_lock=""
  fi
  if [ -n "$usage_agy_error" ]; then
    rm -f "$usage_agy_error" || { echo "error: cannot remove $usage_agy_error" >&2; status=2; }
    usage_agy_error=""
  fi
  return "$status"
}

USAGE_DATES='def stamp:
  if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$") then
    sub("\\.[0-9]+"; "") as $text | ($text | fromdateiso8601) as $epoch
    | if $epoch <= 0 then error("\($text) is not a positive epoch second")
      elif ($epoch | strftime("%Y-%m-%dT%H:%M:%SZ")) == $text then $epoch else error("invalid calendar time \($text)") end
  else error("\(tojson) is not a UTC time like 2026-11-01T02:21:43Z") end;'

usage_read() {  # usage_read <tool> [model]
  local tool="$1" model="${2-}" status=0
  usage_failure=""; usage_notice=""; usage_shown=""; usage_windows=""; usage_recorded=""; usage_readings=""
  case "$tool" in
    codex) usage_read_codex || status=2 ;;
    agy) usage_read_agy "$model" || status=2 ;;
    claude) usage_read_claude || status=2 ;;
    *) usage_reject "usage does not read the quota of $tool"; status=2 ;;
  esac
  if [ "$status" -eq 0 ] && [ -z "$usage_windows" ]; then usage_reject "$tool gave no usage window"; status=2; fi
  # What a reader had in hand when it failed is no reading
  [ "$status" -eq 0 ] || { usage_windows=""; usage_recorded=""; usage_readings=""; }
  return "$status"
}

# The record of Codex's own session files is the only reading of its quota, and a Codex that nobody has run
# since a refill still shows the old one: past the age limit, one Codex call is made for a new record.
usage_read_codex() {
  local reason
  usage_read_codex_records || return 2
  [ "$(( $(usage_now) - usage_recorded ))" -gt "$USAGE_CODEX_MAX_AGE_SECONDS" ] || return 0
  if reason="$(usage_refresh_codex)"; then
    usage_read_codex_records || return 2
  else
    usage_notice="the Codex record is older than $((USAGE_CODEX_MAX_AGE_SECONDS / 60)) minutes and its refresh failed: $reason"
  fi
}

# usage_refresh_codex: makes the one call under a lock, so readers that find the same old record start one call
# between them, and the others read what it wrote. Prints why it failed, and fails, or prints nothing.
usage_refresh_codex() {
  local lock_dir="${AI_CORE_HOME:-$HOME}/.ai-core"
  command -v flock >/dev/null 2>&1 || { echo "flock is not on the PATH"; return 1; }
  command -v timeout >/dev/null 2>&1 || { echo "timeout is not on the PATH"; return 1; }
  command -v codex >/dev/null 2>&1 || { echo "codex is not on the PATH"; return 1; }
  mkdir -p "$lock_dir" || { echo "cannot create $lock_dir"; return 1; }
  (
    flock -w "$USAGE_CODEX_REFRESH_WAIT_SECONDS" 9 || { echo "the refresh of another reader did not end in $USAGE_CODEX_REFRESH_WAIT_SECONDS seconds"; exit 1; }
    usage_read_codex_records >/dev/null 2>&1 || :
    [ -z "$usage_recorded" ] || [ "$(( $(usage_now) - usage_recorded ))" -gt "$USAGE_CODEX_MAX_AGE_SECONDS" ] || exit 0
    . "$(dirname "${BASH_SOURCE[0]}")/tool-order.sh"
    row="$(phase_model_row codex helper '*' "$(data_file models.tsv)" 2>&1)" && [ -n "$row" ] \
      || { echo "the models table has no codex helper row${row:+: $row}"; exit 1; }
    scratch="$(mktemp -d)" || { echo "cannot create a scratch folder"; exit 1; }
    trap 'rm -rf "$scratch"' EXIT
    rc=0
    (cd "$scratch" && timeout "$USAGE_CODEX_REFRESH_SECONDS" codex exec --skip-git-repo-check -s read-only \
      -m "$(cut -f4 <<< "$row")" -c "model_reasoning_effort=\"$(cut -f5 <<< "$row")\"" \
      "Answer with the one word: ok" < /dev/null > /dev/null 2> "$scratch/error") || rc=$?
    case "$rc" in
      0) ;;
      124) echo "codex exec did not end in $USAGE_CODEX_REFRESH_SECONDS seconds"; exit 1 ;;
      *) echo "codex exec exited $rc: $(grep -m1 . "$scratch/error" | cut -c1-200)"; exit 1 ;;
    esac
    usage_read_codex_records >/dev/null 2>&1 || { echo "codex exec answered, but its session files cannot be read"; exit 1; }
    [ "$(( $(usage_now) - usage_recorded ))" -le "$USAGE_CODEX_MAX_AGE_SECONDS" ] \
      || { echo "codex exec answered, but wrote no usage record"; exit 1; }
  ) 9>>"$lock_dir/codex-usage-refresh.lock"
}

usage_read_codex_records() {
  local records parsed now
  now="$(date +%s)"
  # A record counts only with a window in it; a window that is null or 0 minutes long says nothing.
  usage_shown=left
  records="$( {
    files=(); for f in "${CODEX_HOME:-$HOME/.codex}"/sessions/*/*/*/rollout-*.jsonl; do
      [ ! -e "$f" ] || files+=("$f")
    done
    [ "${#files[@]}" -gt 0 ] || exit 0
    ls -tr "${files[@]}" | while IFS= read -r f; do
      grep -E '"rate_limits"[[:space:]]*:[[:space:]]*\{' "$f"; rc=$?
      [ "$rc" -le 1 ] || exit "$rc"
    done
  } 2>&1)" || { usage_reject "Codex session files cannot be read: $records"; return 2; }
  [ -n "$records" ] || { usage_failure="no usage recorded yet: Codex records it in its session files once a session has had an answer"; return 2; }
  parsed="$(jq -sc "$USAGE_DATES"'
    [.[] | [.payload.rate_limits | (.primary, .secondary) | select(. != null and .window_minutes != 0)] as $windows
      | select($windows | length > 0)
      | (.timestamp | try stamp catch error("no usable timestamp: \(.)")) as $at
      | {recorded: $at, fraction: (.timestamp | split(".")[1] // "0Z" | rtrimstr("Z") | "0." + . | tonumber), windows: [$windows[]
        | if [.used_percent, .window_minutes, .resets_at] | all(type == "number") then .
          else error("a window without a number for used_percent, window_minutes or resets_at") end
        | if .used_percent < 0 or .window_minutes <= 0 or (.window_minutes | floor) != .window_minutes
            or .resets_at <= 0 or .resets_at > 253402300799 or (.resets_at | floor) != .resets_at
          then error("invalid percentage, duration or reset in a Codex window") else . end
        | {key: (if .window_minutes == 300 then "five_hour" elif .window_minutes == 10080 then "seven_day" else "\(.window_minutes)_minutes" end),
           minutes: .window_minutes, used: .used_percent, resets: .resets_at}]}]
    | sort_by([.recorded, .fraction])' <<< "$records" 2>&1)" || { usage_reject "Codex session file: ${parsed#jq: *: }"; return 2; }
  usage_windows="$(jq -r 'last.windows[]? | "\(.key)\t\(.key)\t\(.minutes)\t\(.used)\t\(.resets)"' <<< "$parsed")"
  usage_recorded="$(jq -r 'last.recorded' <<< "$parsed")"
  usage_readings="$(jq -r --argjson since "$((now - 7 * 86400))" '.[] | select(.recorded >= $since) | .recorded as $t
    | .windows[] | "\(.key)\t\($t)\t\(.used)\t\(.resets)"' <<< "$parsed")"
}

usage_read_agy() {  # usage_read_agy <model>
  local model="$1" rc names display answer history day attempts n f
  usage_shown=left
  command -v agy >/dev/null 2>&1 || { usage_reject "agy is not on the PATH, so its quota cannot be read"; return 2; }
  usage_agy_error="$(mktemp)" || { usage_agy_error=""; usage_reject 'cannot create a temporary file for agy errors'; return 2; }
  usage_history_lock=""
  trap 'exit 130' INT
  trap 'exit 143' TERM
  answer="$(agy -p /usage --output-format json < /dev/null 2>"$usage_agy_error")"; rc=$?
  [ "$rc" -eq 0 ] || { usage_reject "agy -p /usage exited $rc: $(head -n1 "$usage_agy_error" | cut -c1-200)"; return 2; }
  usage_recorded="$(date +%s)"
  display=""
  if [ -n "$model" ]; then
    names="$(agy models < /dev/null 2>"$usage_agy_error")"; rc=$?
    [ "$rc" -eq 0 ] || { usage_reject "agy models exited $rc: $(head -n1 "$usage_agy_error" | cut -c1-200)"; return 2; }
    display="$(awk -F'\t' -v m="$model" '$1 == m { print $2; exit }' <<< "$names")"
    [ -n "$display" ] || { usage_reject "agy does not list the model $model in agy models"; return 2; }
  fi
  jq -se 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1 <<< "$answer" \
    || { usage_reject "the answer of agy -p /usage is not a JSON object (expected one JSON object)"; return 2; }
  # A bucket whose remaining_fraction is no number is no reading, and so is every other bucket the
  # program below cannot read; nothing is made up for it. A model belongs to the group whose
  # description lists a family that the model's display name starts with, allowing version words.
  usage_windows="$(jq -r --arg model "$model" --arg display "$display" "$USAGE_DATES"'
    def unusable($why): error("the answer of agy -p /usage cannot be used - \($why)");
    def families: (.description | if type == "string" then . else "" end) | split(":")[1:] | join(":") | split(",")
      | map(sub("^\\s+"; "") | sub("\\s+$"; "")) | map(select(. != ""));
    def unversioned: ascii_downcase | split(" ") | map(select(test("^[0-9]+(\\.[0-9]+)*$") | not)) | join(" ");
    def leads($name; $family): ($family | ascii_downcase) as $f
      | any([($name | ascii_downcase), ($name | unversioned)][];
          startswith($f) and ((.[($f | length):]) | . == "" or test("^[^a-z0-9]")));
    def lists($name): any(families[]; leads($name; .));
    def duration: {"weekly": {"name": "seven_day", "minutes": 10080}, "5h": {"name": "five_hour", "minutes": 300}};
    if .status != "SUCCESS" then unusable("the status \(.status | tojson) is not SUCCESS") else . end
    | (.command.data.groups) as $groups
    | if ($groups | type) != "array" or ($groups | length) == 0 then unusable("it holds no usage groups in .command.data.groups") else . end
    | ($groups | map(if (.name | type) != "string" or .name == "" then unusable("a group has no name") else . end)) as $named
    | if ($named | map(.name) | unique | length) != ($named | length) then unusable("two groups are named alike") else . end
    | ($named | map(select(lists($display)))) as $holders
    | (if $model == "" then $named
       elif ($holders | length) == 0 then error("no group lists the family of \($model) (\($display)); the groups list: \($named | map("\(.name): \(families | join(", "))") | join("; "))")
       elif ($holders | length) > 1 then error("\($model) (\($display)) is listed by the groups \($holders | map(.name) | join(" and ")), so its group is ambiguous")
       else $holders end)
    | [.[] | if (.buckets | type) != "array" or (.buckets | length) == 0 then unusable("the group \(.name) has no buckets") else . end
        | .name as $group | .buckets[]
        | (.id | if type == "string" and . != "" then . else unusable("a bucket of \($group) has no id") end) as $id
        | (duration[.window | if type == "string" then . else "" end]) as $length
        | if $length == null then unusable("\($group)/\($id): the window \(.window | tojson) is neither weekly nor 5h")
          elif (.remaining_fraction | type) != "number" or .remaining_fraction < 0 or .remaining_fraction > 1
          then unusable("\($group)/\($id): remaining_fraction \(.remaining_fraction | tojson) is not a number from 0 to 1")
          else {"key": ([$group, $id] | tojson), "label": "\($group | gsub("[[:cntrl:]]"; " ")): \($length.name)", "minutes": $length.minutes,
                "used": (100 - 100 * .remaining_fraction),
                "resets": (.reset_time | try stamp catch unusable("\($group)/\($id): reset_time \(.)"))} end]
    | if (map(.key) | unique | length) != length then unusable("two buckets of a group share an id") else . end
    | .[] | "\(.key)\t\(.label)\t\(.minutes)\t\(.used)\t\(.resets)"' <<< "$answer" 2>&1)" \
    || { usage_reject "${usage_windows#jq: *: }"; return 2; }
  # Appending can take several writes; the lock covers the append, pruning and the read, never agy.
  history="${AI_CORE_HOME:-$HOME}/.ai-core/usage-agy"; day=$((usage_recorded / 86400))
  mkdir -p "$history" || { usage_reject "the usage history folder $history cannot be made"; return 2; }
  attempts=0
  # The shell creates the lock file exclusively itself: the mkdir of some coreutils builds succeeds for two callers racing.
  until ( set -C; : > "$history/.lock" ) 2>"$usage_agy_error"; do
    [ -w "$history" ] || { usage_reject "the usage history lock cannot be made: $(head -n1 "$usage_agy_error")"; return 2; }
    attempts=$((attempts + 1))
    [ "$attempts" -lt 100 ] || { usage_reject "the usage history lock $history/.lock is still held after 10 seconds"; return 2; }
    sleep 0.1
  done
  usage_history_lock="$history/.lock"
  for f in "$history"/*.log; do
    [ -e "$f" ] || continue
    n="${f##*/}"; n="${n%.log}"
    case "$n" in ''|*[!0-9]*) continue ;; esac
    [ "$n" -ge $((day - 8)) ] || rm -f "$f" || { usage_reject "the old usage history $f cannot be removed"; return 2; }
  done
  awk -F'\t' -v t="$usage_recorded" '{ print $1 "\t" t "\t" $4 "\t" $5 }' <<< "$usage_windows" >> "$history/$day.log" \
    || { usage_reject "the usage history $history/$day.log cannot be written"; return 2; }
  usage_readings="$(awk -F'\t' 'NF != 4 || $2 !~ /^[0-9]+$/ || $2 <= 0 || $3 + 0 != $3 || $3 < 0 || $3 > 100 || $4 !~ /^[0-9]+$/ || $4 <= 0 { print "the usage history has a malformed line at " FILENAME ":" FNR > "/dev/stderr"; exit 1 } { print }' "$history"/*.log 2>"$usage_agy_error")" \
    || { usage_reject "$(head -n1 "$usage_agy_error")"; return 2; }
  cut -f1 <<< "$usage_readings" | jq -se 'all(.[]; type == "array" and length == 2 and all(.[]; type == "string" and length > 0))' >/dev/null 2>"$usage_agy_error" \
    || { usage_reject "the usage history $history has an invalid group/bucket key: $(head -n1 "$usage_agy_error")"; return 2; }
  rm "$usage_history_lock" || { usage_reject "the usage history lock $usage_history_lock cannot be released"; return 2; }
  usage_history_lock=""
}

usage_read_claude() {
  local file record history
  usage_shown=used
  file="${AI_CORE_HOME:-$HOME}/.ai-core/usage.json"
  [ -f "$file" ] || { usage_failure="no usage recorded yet: the status line records it once a session has had an answer"; return 2; }
  record="$(cat "$file")" || { usage_reject "$file cannot be read"; return 2; }
  usage_windows="$(jq -sr 'if length != 1 or (.[0] | type) != "object" then error("expected one JSON object") else .[0] end
    | (.rate_limits // {} | to_entries | map(select(.value != null))) as $limits
    | if ($limits | length) == 0 then error("rate_limits holds no window") else . end
    | $limits[] | .key as $name | .value
    | if [.used_percentage, .resets_at] | all(type == "number") then .
      else error("the window \($name) has no number for used_percentage or resets_at") end
    | if .used_percentage < 0 or .resets_at <= 0 or .resets_at > 253402300799 or (.resets_at | floor) != .resets_at
      then error("the window \($name) has an invalid percentage or reset") else . end
    | "\($name)\t\($name)\t\({"five_hour": 300, "seven_day": 10080}[$name] // 0)\t\(.used_percentage)\t\(.resets_at)"' <<< "$record" 2>&1)" \
    || { usage_reject "$file: ${usage_windows#jq: *: }"; return 2; }
  usage_recorded="$(jq -r '.recorded_at | if type == "number" then . else error("recorded_at is not a number") end
    | if . > 0 and . <= 253402300799 and floor == . then . else error("recorded_at is not a positive epoch second") end' <<< "$record" 2>&1)" \
    || { usage_reject "$file: ${usage_recorded#jq: *: }"; return 2; }
  history="${AI_CORE_HOME:-$HOME}/.ai-core/usage.log"
  if [ -e "$history" ]; then
    usage_readings="$(awk '
      function window(u, r) { return (u == "-" && r == "-") || (u + 0 == u && u >= 0 && r ~ /^[0-9]+$/ && r > 0) }
      NF != 5 || $1 !~ /^[0-9]+$/ || $1 <= 0 || !window($2, $3) || !window($4, $5) { print "malformed usage history at " FILENAME ":" FNR; exit 1 }
      { if ($2 != "-") print "five_hour\t" $1 "\t" $2 "\t" $3; if ($4 != "-") print "seven_day\t" $1 "\t" $4 "\t" $5 }
      ' "$history" 2>&1)" || { usage_reject "${usage_readings##*$'\n'}"; return 2; }
  fi
}

usage_snapshot() {  # usage_snapshot <tool>
  local tool="$1" status=0
  usage_read "$tool" "" || :
  usage_release || status=2
  jq -n --arg tool "$tool" --arg shown "$usage_shown" --arg recorded "$usage_recorded" --arg failure "${usage_failure#error: }" --arg notice "$usage_notice" \
    --rawfile windows <(printf '%s\n' "$usage_windows") --rawfile readings <(printf '%s\n' "$usage_readings") '
    def rows($text): $text | split("\n") | map(select(. != "") | split("\t"));
    {tool: $tool, shown: $shown, recorded: ($recorded | if . == "" then null else tonumber end), failure: $failure, notice: $notice,
     windows: [rows($windows)[] | {key: .[0], name: .[1], minutes: (.[2] | tonumber), used: (.[3] | tonumber), resets: (.[4] | tonumber)}],
     readings: [rows($readings)[] | {key: .[0], at: (.[1] | tonumber), used: (.[2] | tonumber), resets: (.[3] | tonumber)}]}'
  return "$status"
}
