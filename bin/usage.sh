#!/usr/bin/env bash
# What the selected account's usage windows stand at, as its tool last recorded them, where each
# will stand at its reset at the burn measured since the window's first reading, and whether one
# has reached the limit or will reach it before its reset. Claude Code's windows are what its status
# line records, its history the status line's log; Codex's are what Codex writes into its session
# files after every answer; agy's are what `agy -p /usage` answers now, each group of models with
# its own windows, its history the readings this command saved under ~/.ai-core/usage-agy/.
#
#   usage.sh [--tool claude|codex|agy] [--model MODEL] [--stop-at N]
#                                                     N percent used; else USAGE_STOP_AT of the project's config.env; else 92
#
# Claude's windows are shown as the share used, Codex's and agy's as the share left, as each tool
# shows its own; the limit N is always a share used. --model, for agy only, judges just the group
# whose description lists the family of the model's display name from `agy models`.
# Exit 0: every window below N, and none projected to N by its reset. Exit 4: a window projected to
# N or more by its reset, so nothing new starts on it. Exit 3: a window at N or more. Exit 2: nothing
# recorded yet, a reading that cannot be used, or a wrong argument. A window whose reset time has
# passed counts as reset; a window whose readings span less than 30 minutes has no measured burn and
# is judged by what it stands at. One model's own weekly quota is not among the windows Claude Code
# hands the status line, so it is not here either.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/lib/common.sh"

tool=""; model=""
usage="usage: usage.sh [--tool claude|codex|agy] [--model MODEL] [--stop-at N]"
config="$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.ai-core/config.env"
stop="$(grep -E '^[[:space:]]*USAGE_STOP_AT[[:space:]]*=' "$config" 2>/dev/null | tail -n1 || true)"
stop="${stop#*=}"; stop="${stop%%#*}"; stop="${stop//[[:space:]\"\']/}"; stop="${stop:-92}"
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) echo "$usage"
      echo 'Reads the windows of one tool, selected explicitly or by the session tool (Claude otherwise).'
      echo 'Exit 2 means usage is unknown or an argument is invalid; it is not a successful preflight.'
      exit 0 ;;
    --tool) case "${2-}" in claude|codex|agy) tool="$2"; shift 2 ;; *) echo "error: --tool takes claude, codex or agy - $usage" >&2; exit 2 ;; esac ;;
    --model) case "${2-}" in ''|-*) echo "error: --model takes a model of agy - $usage" >&2; exit 2 ;; *) model="$2"; shift 2 ;; esac ;;
    --stop-at) stop="${2:-}"; shift 2 || { echo "error: --stop-at takes a percentage - $usage" >&2; exit 2; } ;;
    *) echo "error: unknown argument '$1' - $usage" >&2; exit 2 ;;
  esac
done
reject() { echo "error: $*" >&2; exit 2; }
case "$stop" in ''|*[!0-9]*) reject "--stop-at takes a whole percentage, not '$stop'" ;; esac
stop="$(awk -v n="$stop" 'BEGIN { if (n > 100) exit 1; printf "%d", n }')" \
  || reject '--stop-at takes a whole percentage from 0 to 100'
# With its zone, because a reset on the night the clocks change reads an hour off without it.
when() { LC_ALL=C date -d "@$1" '+%a %H:%M %Z' 2>/dev/null || LC_ALL=C date -r "$1" '+%a %H:%M %Z'; }
left() { local m=$((($1 - now) / 60)); if [ "$m" -lt 60 ]; then echo "in $m min"; elif [ "$m" -lt 2880 ]; then echo "in $((m / 60)) h $((m % 60)) min"; else echo "in $((m / 1440)) d $((m % 1440 / 60)) h"; fi; }
# A Codex session started from a Claude Code shell inherits CLAUDECODE, so the Codex variables decide.
[ -n "$tool" ] || tool="$(session_tool)"
[ -n "$tool" ] || tool=claude
case "$tool" in claude|codex|agy) ;; *) reject "usage does not read the quota of $tool: --tool takes claude, codex or agy" ;; esac
[ -z "$model" ] || [ "$tool" = agy ] || reject "--model is for agy, which has a quota per group of models; $tool has none - $usage"
now="$(date +%s)"
dates='def stamp:
  if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$") then
    sub("\\.[0-9]+"; "") as $text | ($text | fromdateiso8601) as $epoch
    | if $epoch <= 0 then error("\($text) is not a positive epoch second")
      elif ($epoch | strftime("%Y-%m-%dT%H:%M:%SZ")) == $text then $epoch else error("invalid calendar time \($text)") end
  else error("\(tojson) is not a UTC time like 2026-11-01T02:21:43Z") end;'
# What the readers hand on, one tab-separated row each. windows: the window's key in the history, the
# name shown, its length in minutes (0 when unknown), the share used, the epoch of its reset.
# readings: the key, the epoch of the reading, the share used, the epoch of the reset the reading
# belonged to. shown: the share the tool itself shows, used or left.
if [ "$tool" = codex ]; then
  # A record counts only with a window in it; a window that is null or 0 minutes long says nothing.
  shown=left
  records="$( {
    files=(); for f in "${CODEX_HOME:-$HOME/.codex}"/sessions/*/*/*/rollout-*.jsonl; do
      [ ! -e "$f" ] || files+=("$f")
    done
    [ "${#files[@]}" -gt 0 ] || exit 0
    ls -tr "${files[@]}" | while IFS= read -r f; do
      grep -E '"rate_limits"[[:space:]]*:[[:space:]]*\{' "$f"; rc=$?
      [ "$rc" -le 1 ] || exit "$rc"
    done
  } 2>&1)" || reject "Codex session files cannot be read: $records"
  [ -n "$records" ] || { echo "no usage recorded yet: Codex records it in its session files once a session has had an answer" >&2; exit 2; }
  parsed="$(jq -sc "$dates"'
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
    | sort_by([.recorded, .fraction])' <<< "$records" 2>&1)" || reject "Codex session file: ${parsed#jq: *: }"
  windows="$(jq -r 'last.windows[]? | "\(.key)\t\(.key)\t\(.minutes)\t\(.used)\t\(.resets)"' <<< "$parsed")"
  recorded="$(jq -r 'last.recorded' <<< "$parsed")"
  readings="$(jq -r --argjson since "$((now - 7 * 86400))" '.[] | select(.recorded >= $since) | .recorded as $t
    | .windows[] | "\(.key)\t\($t)\t\(.used)\t\(.resets)"' <<< "$parsed")"
elif [ "$tool" = agy ]; then
  shown=left
  command -v agy >/dev/null 2>&1 || reject "agy is not on the PATH, so its quota cannot be read"
  agy_error="$(mktemp)" || reject 'cannot create a temporary file for agy errors'
  history_lock=""
  trap '[ -z "$history_lock" ] || rmdir "$history_lock"; rm -f "$agy_error"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  answer="$(agy -p /usage --output-format json < /dev/null 2>"$agy_error")"; rc=$?
  [ "$rc" -eq 0 ] || reject "agy -p /usage exited $rc: $(head -n1 "$agy_error" | cut -c1-200)"
  recorded="$(date +%s)"
  display=""
  if [ -n "$model" ]; then
    names="$(agy models < /dev/null 2>"$agy_error")"; rc=$?
    [ "$rc" -eq 0 ] || reject "agy models exited $rc: $(head -n1 "$agy_error" | cut -c1-200)"
    display="$(awk -F'\t' -v m="$model" '$1 == m { print $2; exit }' <<< "$names")"
    [ -n "$display" ] || reject "agy does not list the model $model in agy models"
  fi
  jq -se 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1 <<< "$answer" \
    || reject "the answer of agy -p /usage is not a JSON object (expected one JSON object)"
  # A bucket whose remaining_fraction is no number is no reading, and so is every other bucket the
  # program below cannot read; nothing is made up for it. A model belongs to the group whose
  # description lists a family that the model's display name starts with, allowing version words.
  windows="$(jq -r --arg model "$model" --arg display "$display" "$dates"'
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
    || reject "${windows#jq: *: }"
  # Appending can take several writes; the lock covers the append, pruning and the read, never agy.
  history="${AI_CORE_HOME:-$HOME}/.ai-core/usage-agy"; day=$((recorded / 86400))
  mkdir -p "$history" || reject "the usage history folder $history cannot be made"
  attempts=0
  until mkdir "$history/.lock" 2>"$agy_error"; do
    [ -d "$history/.lock" ] || reject "the usage history lock cannot be made: $(head -n1 "$agy_error")"
    attempts=$((attempts + 1))
    [ "$attempts" -lt 100 ] || reject "the usage history lock $history/.lock is still held after 10 seconds"
    sleep 0.1
  done
  history_lock="$history/.lock"
  for f in "$history"/*.log; do
    [ -e "$f" ] || continue
    n="${f##*/}"; n="${n%.log}"
    case "$n" in ''|*[!0-9]*) continue ;; esac
    [ "$n" -ge $((day - 8)) ] || rm -f "$f" || reject "the old usage history $f cannot be removed"
  done
  awk -F'\t' -v t="$recorded" '{ print $1 "\t" t "\t" $4 "\t" $5 }' <<< "$windows" >> "$history/$day.log" \
    || reject "the usage history $history/$day.log cannot be written"
  readings="$(awk -F'\t' 'NF != 4 || $2 !~ /^[0-9]+$/ || $2 <= 0 || $3 + 0 != $3 || $3 < 0 || $3 > 100 || $4 !~ /^[0-9]+$/ || $4 <= 0 { print "the usage history has a malformed line at " FILENAME ":" FNR > "/dev/stderr"; exit 1 } { print }' "$history"/*.log 2>"$agy_error")" \
    || reject "$(head -n1 "$agy_error")"
  cut -f1 <<< "$readings" | jq -se 'all(.[]; type == "array" and length == 2 and all(.[]; type == "string" and length > 0))' >/dev/null 2>"$agy_error" \
    || reject "the usage history $history has an invalid group/bucket key: $(head -n1 "$agy_error")"
  rmdir "$history_lock" || reject "the usage history lock $history_lock cannot be released"
  history_lock=""
else
  shown=used
  file="${AI_CORE_HOME:-$HOME}/.ai-core/usage.json"
  [ -f "$file" ] || { echo "no usage recorded yet: the status line records it once a session has had an answer" >&2; exit 2; }
  record="$(cat "$file")" || reject "$file cannot be read"
  windows="$(jq -sr 'if length != 1 or (.[0] | type) != "object" then error("expected one JSON object") else .[0] end
    | (.rate_limits // {} | to_entries | map(select(.value != null))) as $limits
    | if ($limits | length) == 0 then error("rate_limits holds no window") else . end
    | $limits[] | .key as $name | .value
    | if [.used_percentage, .resets_at] | all(type == "number") then .
      else error("the window \($name) has no number for used_percentage or resets_at") end
    | if .used_percentage < 0 or .resets_at <= 0 or .resets_at > 253402300799 or (.resets_at | floor) != .resets_at
      then error("the window \($name) has an invalid percentage or reset") else . end
    | "\($name)\t\($name)\t\({"five_hour": 300, "seven_day": 10080}[$name] // 0)\t\(.used_percentage)\t\(.resets_at)"' <<< "$record" 2>&1)" \
    || reject "$file: ${windows#jq: *: }"
  recorded="$(jq -r '.recorded_at | if type == "number" then . else error("recorded_at is not a number") end
    | if . > 0 and . <= 253402300799 and floor == . then . else error("recorded_at is not a positive epoch second") end' <<< "$record" 2>&1)" \
    || reject "$file: ${recorded#jq: *: }"
  history="${AI_CORE_HOME:-$HOME}/.ai-core/usage.log"; readings=""
  if [ -e "$history" ]; then
    readings="$(awk '
      function window(u, r) { return (u == "-" && r == "-") || (u + 0 == u && u >= 0 && r ~ /^[0-9]+$/ && r > 0) }
      NF != 5 || $1 !~ /^[0-9]+$/ || $1 <= 0 || !window($2, $3) || !window($4, $5) { print "malformed usage history at " FILENAME ":" FNR; exit 1 }
      { if ($2 != "-") print "five_hour\t" $1 "\t" $2 "\t" $3; if ($4 != "-") print "seven_day\t" $1 "\t" $4 "\t" $5 }
      ' "$history" 2>&1)" || reject "${readings##*$'\n'}"
  fi
fi
[ -n "$windows" ] || reject "$tool gave no usage window"
now="$(date +%s)"
# The limit is a share used for every tool; the tools that show what is left say so beside it.
if [ "$shown" = left ]; then limit="$stop % used"; at_limit="$((100 - stop)) % left"; else limit="$stop %"; at_limit="$stop %"; fi
reached=0; projected=0; warnings=""
# Readings are whole percents, so over a shorter span one rounding step reads as a steep burn.
trusted_span=1800
width="$(awk -F'\t' '{ if (length($2) > w) w = length($2) } END { print (w > 10 ? w : 10) }' <<< "$windows")"
while IFS=$'\t' read -r key name length used resets; do
  [ -n "$key" ] || continue
  if [ "$resets" -gt 0 ] && [ "$resets" -le "$now" ]; then
    printf '%-*s %3d %% %s  reset since %s\n' "$width" "$name" "$([ "$shown" = left ] && echo 100 || echo 0)" "$shown" "$(when "$resets")"; continue
  fi
  # The burn runs from the window's first reading, one with the same reset taken after the window
  # began, to the last record.
  forecast="$(AI_CORE_USAGE_KEY="$key" awk -F'\t' -v r="$resets" -v u="$used" -v at="$recorded" -v s="$stop" -v len="$length" -v span="$trusted_span" -v show="$shown" '
    BEGIN { k = ENVIRON["AI_CORE_USAGE_KEY"] }
    function face(x) { return show == "left" ? sprintf("%d %% left", 100 - x) : sprintf("%d %%", x) }
    $1 == k && $4 == r && (len == 0 || $2 >= r - len * 60) && (t == "" || $2 < t) { t = $2; first = $3 }
    END {
      if (t == "" || at - t < span) { print "unmeasured\t"; exit }
      burn = (u - first) / (at - t)
      if (burn <= 0) { print "0.0 %/h\t"; exit }
      p = u + burn * (r - at); cross = at + (s - u) / burn
      if (p < s) printf "%.1f %%/h, %s at reset\t\n", burn * 3600, face(p)
      else printf "%.1f %%/h\t%d\n", burn * 3600, (cross > at ? cross : at)
    }' <<< "$readings")"
  cross="${forecast##*$'\t'}"; burn="${forecast%%$'\t'*}"
  [ -z "$cross" ] || burn="$burn, $at_limit at $(when "$cross")"
  printf '%-*s %3d %% %s  resets %s, %s  burn %s\n' "$width" "$name" "$(awk -v u="$used" -v show="$shown" 'BEGIN { printf "%d", show == "left" ? 100 - u : u }')" "$shown" "$(when "$resets")" "$(left "$resets")" "$burn"
  awk -v u="$used" -v s="$stop" 'BEGIN { exit !(u >= s) }' && reached=1
  [ -n "$cross" ] || continue
  # A window of a day or less resets soon after, so waiting costs little; a longer one is a
  # person's decision, another account or slower work, and needs the hour ahead of time.
  if [ "$length" -gt 0 ] && [ "$length" -le 1440 ]; then projected=1
  else warnings="$warnings$name reaches $limit at $(when "$cross"), before its reset; the person who holds the account watches it"$'\n'; fi
done <<< "$windows"
echo "recorded $(when "$recorded"), limit $limit"
printf '%s' "$warnings"
[ "$reached" -eq 0 ] || { echo "a window stands at $limit or more: finish the step in hand, commit and report it, then wait for its reset"; exit 3; }
[ "$projected" -eq 0 ] || { echo "a window reaches $limit before its reset at the measured burn: start nothing new on this account, and have what runs commit before that hour"; exit 4; }
