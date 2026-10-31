#!/usr/bin/env bash
# What the stated-time check refuses: a clock time written with a zone word that the clock in that zone does not
# show, beyond the tolerance, naming both; and what it lets through: the clock's time, a time inside the tolerance,
# a line with a date, a time with no zone word, copied text (a code block, a quote, inline code). The clock is
# pinned with AI_CORE_NOW, the zones are fixtures.
#
#   bash tests/stated-time.test.sh

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export HOME="$work/home" AI_CORE_HOME="$work/core"; mkdir -p "$HOME" "$AI_CORE_HOME"
unset STATED_TIME_ZONE STATED_TIME_ZONE_WORDS STATED_TIME_TOLERANCE_MINUTES TZ
failed=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}
at() { date -u -d "$1" +%s; }
# verdict <script> <text>: "passes", or "refused: <what it said>", under the settings and the clock exported by the caller
verdict() {
  local said
  if said="$(printf '%s\n' "$2" | bash "$1" check issue-comment example-org/example-repo 2>&1)"; then echo passes; else echo "refused: $said"; fi
}
script="$root/lib/stated-time.sh"
cd "$work" || exit 1

echo 'a time written with a zone word that the clock does not show is refused, and the refusal names both'
export AI_CORE_NOW="$(at '2026-10-31 12:00:00')"
check 'a time an hour ahead' 'refused: issue-comment to example-org/example-repo: the text says 13:10 UTC, the clock there shows 12:00 (UTC)' "$(verdict "$script" 'Landed at 13:10 UTC.')"
check 'a time in the past, without its date' 'refused: issue-comment to example-org/example-repo: the text says 09:10 UTC, the clock there shows 12:00 (UTC)' "$(verdict "$script" 'It started at 09:10 UTC')"
check 'a time of one digit in the hour' 'refused: issue-comment to example-org/example-repo: the text says 09:10 UTC, the clock there shows 12:00 (UTC)' "$(verdict "$script" 'It started at 9:10 UTC')"
check 'the second line of a text' 'refused: issue-comment to example-org/example-repo: the text says 13:10 UTC, the clock there shows 12:00 (UTC)' "$(verdict "$script" $'First line.\nSecond line, 13:10 UTC.')"
check 'the second time of a line' 'refused: issue-comment to example-org/example-repo: the text says 13:10 UTC, the clock there shows 12:00 (UTC)' "$(verdict "$script" 'From 12:01 UTC to 13:10 UTC')"
check 'a zone word in parentheses' 'refused: issue-comment to example-org/example-repo: the text says 13:10 UTC, the clock there shows 12:00 (UTC)' "$(verdict "$script" 'Landed at 13:10 (UTC)')"

echo 'a time inside the tolerance, a time with its date and a time with no zone word pass'
check 'the clock'"'"'s own time' passes "$(verdict "$script" 'Landed at 12:00 UTC.')"
check 'four minutes after' passes "$(verdict "$script" 'Landed at 12:04 UTC.')"
check 'five minutes before, the tolerance itself' passes "$(verdict "$script" 'Landed at 11:55 UTC.')"
check 'six minutes after' 'refused: issue-comment to example-org/example-repo: the text says 12:06 UTC, the clock there shows 12:00 (UTC)' "$(verdict "$script" 'Landed at 12:06 UTC.')"
check 'a time with an ISO date' passes "$(verdict "$script" 'Landed on 2026-10-30 at 09:10 UTC.')"
check 'a time with a day and a month' passes "$(verdict "$script" 'Landed on 30.10. at 09:10 UTC.')"
check 'a time with a day, a month and a year' passes "$(verdict "$script" 'Landed on 30.10.2026 at 09:10 UTC.')"
check 'a time with no zone word: a duration' passes "$(verdict "$script" 'The run took 13:10 in total.')"
check 'a time with a word that is no zone' passes "$(verdict "$script" 'Meet at 13:10 sharp.')"
check 'a time with seconds' passes "$(verdict "$script" 'Built at 13:10:45 UTC.')"
check 'a text with no time' passes "$(verdict "$script" 'Nothing to say.')"

echo 'the short way round midnight'
export AI_CORE_NOW="$(at '2026-10-31 23:58:00')"
check 'five minutes after midnight, the clock at 23:58' passes "$(verdict "$script" 'Done at 00:03 UTC.')"
check 'half an hour after midnight' 'refused: issue-comment to example-org/example-repo: the text says 00:30 UTC, the clock there shows 23:58 (UTC)' "$(verdict "$script" 'Done at 00:30 UTC.')"
export AI_CORE_NOW="$(at '2026-10-31 12:00:00')"

echo 'a zone name the system knows is judged in that zone, a word of the project in the zone of the project'
check 'a system zone name: the clock there is 13:00' passes "$(verdict "$script" 'Landed at 13:02 Europe/Zurich.')"
check 'a system zone name, an hour off' 'refused: issue-comment to example-org/example-repo: the text says 12:02 Europe/Zurich, the clock there shows 13:00 (Europe/Zurich)' "$(verdict "$script" 'Landed at 12:02 Europe/Zurich.')"
check 'a word of the project with no zone set: the word means nothing' passes "$(verdict "$script" 'Landed at 14:00 Zurich.')"
export STATED_TIME_ZONE=Europe/Zurich STATED_TIME_ZONE_WORDS='Zurich, CET'
check 'a word of the project, the clock there' passes "$(verdict "$script" 'Landed at 13:02 Zurich.')"
check 'a word of the project, its case not counted' passes "$(verdict "$script" 'Landed at 13:02 zurich.')"
check 'a second word of the project' passes "$(verdict "$script" 'Landed at 13:02 CET.')"
check 'a word of the project, an hour off' 'refused: issue-comment to example-org/example-repo: the text says 14:00 Zurich, the clock there shows 13:00 (Europe/Zurich)' "$(verdict "$script" 'Landed at 14:00 Zurich.')"
check 'UTC is still UTC where the project has a zone' passes "$(verdict "$script" 'Landed at 12:02 UTC.')"
export STATED_TIME_ZONE_WORDS=local STATED_TIME_ZONE=''
check 'a word with an empty zone means the clock of the machine' 'refused: issue-comment to example-org/example-repo: the text says 12:00 local, the clock there shows 21:00' "$(TZ=Asia/Tokyo verdict "$script" 'Landed at 12:00 local.')"
check 'the machine zone, the clock there' passes "$(TZ=Asia/Tokyo verdict "$script" 'Landed at 21:02 local.')"
unset STATED_TIME_ZONE STATED_TIME_ZONE_WORDS

echo 'the settings are the project'"'"'s config.env, and one that cannot be read is named'
mkdir -p "$work/project/.ai-core"; git init -q "$work/project"
printf 'STATED_TIME_ZONE="Europe/Zurich"\nSTATED_TIME_ZONE_WORDS="Zurich"\nSTATED_TIME_TOLERANCE_MINUTES="30"\n' > "$work/project/.ai-core/config.env"
cd "$work/project" || exit 1
check 'the file sets the zone, the word and the tolerance: twenty minutes off passes' passes "$(verdict "$script" 'Landed at 13:20 Zurich.')"
check 'and forty minutes off is refused' 'refused: issue-comment to example-org/example-repo: the text says 13:40 Zurich, the clock there shows 13:00 (Europe/Zurich)' "$(verdict "$script" 'Landed at 13:40 Zurich.')"
check 'the environment wins over the file' 'refused: issue-comment to example-org/example-repo: the text says 13:20 Zurich, the clock there shows 13:00 (Europe/Zurich)' "$(STATED_TIME_TOLERANCE_MINUTES=5 verdict "$script" 'Landed at 13:20 Zurich.')"
check 'a zone that is no zone is named, not read as UTC' 'refused: issue-comment to example-org/example-repo: STATED_TIME_ZONE is '"'"'Nowhere/City'"'"', which is no zone of /usr/share/zoneinfo' "$(STATED_TIME_ZONE=Nowhere/City verdict "$script" 'Landed at 13:00 Zurich.')"
check 'a tolerance that is no number is named' "refused: issue-comment to example-org/example-repo: STATED_TIME_TOLERANCE_MINUTES is 'soon'; it is the minutes a stated time may differ from the clock, a whole number from 0 to 999" "$(STATED_TIME_TOLERANCE_MINUTES=soon verdict "$script" 'Landed at 13:00 Zurich.')"
cd "$work" || exit 1

echo 'copied text states no time: a fenced code block, a quoted line and inline code pass, and the text around them is judged'
check 'a time in a fenced code block, such as a command'"'"'s output' passes "$(verdict "$script" $'Its answer:\n```\nfive_hour  40 % used  resets 09:10 UTC\n```')"
check 'a time in a fence of tildes' passes "$(verdict "$script" $'~~~\nstarted 09:10 UTC\n~~~')"
check 'a time after the fence closed' 'refused: issue-comment to example-org/example-repo: the text says 13:10 UTC, the clock there shows 12:00 (UTC)' "$(verdict "$script" $'```\nstarted 09:10 UTC\n```\nLanded at 13:10 UTC.')"
check 'a time on a quoted line' passes "$(verdict "$script" '> It started at 09:10 UTC')"
check 'a time in inline code' passes "$(verdict "$script" 'The log says `started 09:10 UTC` there.')"
check 'a time beside inline code' 'refused: issue-comment to example-org/example-repo: the text says 13:10 UTC, the clock there shows 12:00 (UTC)' "$(verdict "$script" 'The log says `09:10 UTC`; it landed at 13:10 UTC.')"
check 'a fence with an info string still hides its block' passes "$(verdict "$script" $'```bash\nstarted 09:10 UTC\n```')"
check 'a line that starts with three backticks and closes them is inline code, no fence: the next line is judged' 'refused: issue-comment to example-org/example-repo: the text says 13:10 UTC, the clock there shows 12:00 (UTC)' "$(verdict "$script" $'```x``` is the log.\nLanded at 13:10 UTC.')"

echo 'a call without its command and its destination'
bash "$script" check > /dev/null 2>&1; rc=$?
check 'a call without its command and destination is refused' 1 "$rc"

echo 'planted: a check that judges nothing lets the wrong time through, so the refusals above are what turn red'
mutant="$work/mutant"; mkdir -p "$mutant"; cp -R "$root/lib" "$mutant/"
sed -i.bak 's/"\$difference" -gt "\$tolerance"/"$difference" -gt 1440/' "$mutant/lib/stated-time.sh"
cmp -s "$root/lib/stated-time.sh" "$mutant/lib/stated-time.sh" && { echo '  FAIL the planted copy equals lib/stated-time.sh'; failed=$((failed + 1)); }
check 'the wrong time passes in the planted copy' passes "$(verdict "$mutant/lib/stated-time.sh" 'Landed at 13:10 UTC.')"
cp "$root/lib/stated-time.sh" "$mutant/lib/stated-time.sh"; sed -i.bak 's/\[\[ "\$line" =~ \$STATED_DATE_PATTERN \]\] && continue//' "$mutant/lib/stated-time.sh"
check 'a time with its date is refused in a planted copy that judges lines with a date' 'refused: issue-comment to example-org/example-repo: the text says 09:10 UTC, the clock there shows 12:00 (UTC)' "$(verdict "$mutant/lib/stated-time.sh" 'Landed on 2026-10-30 at 09:10 UTC.')"

cp "$root/lib/stated-time.sh" "$mutant/lib/stated-time.sh"; sed -i.bak 's/^    \[ -z "\$fence" \] || continue$//' "$mutant/lib/stated-time.sh"
cmp -s "$root/lib/stated-time.sh" "$mutant/lib/stated-time.sh" && { echo '  FAIL the planted copy equals lib/stated-time.sh'; failed=$((failed + 1)); }
check 'a time in a fenced code block is refused in a planted copy that judges inside a fence' 'refused: issue-comment to example-org/example-repo: the text says 09:10 UTC, the clock there shows 12:00 (UTC)' "$(verdict "$mutant/lib/stated-time.sh" $'```\nstarted 09:10 UTC\n```')"
cp "$root/lib/stated-time.sh" "$mutant/lib/stated-time.sh"; sed -i.bak 's/^    \[\[ "\$line" =~ \$STATED_QUOTE_PATTERN \]\] && continue$//' "$mutant/lib/stated-time.sh"
cmp -s "$root/lib/stated-time.sh" "$mutant/lib/stated-time.sh" && { echo '  FAIL the planted copy equals lib/stated-time.sh'; failed=$((failed + 1)); }
check 'a time on a quoted line is refused in a planted copy that judges quotes' 'refused: issue-comment to example-org/example-repo: the text says 09:10 UTC, the clock there shows 12:00 (UTC)' "$(verdict "$mutant/lib/stated-time.sh" '> It started at 09:10 UTC')"
cp "$root/lib/stated-time.sh" "$mutant/lib/stated-time.sh"; sed -i.bak 's/^    while \[\[ "\$line" =~ \$STATED_CODE_PATTERN \]\].*$//' "$mutant/lib/stated-time.sh"
cmp -s "$root/lib/stated-time.sh" "$mutant/lib/stated-time.sh" && { echo '  FAIL the planted copy equals lib/stated-time.sh'; failed=$((failed + 1)); }
check 'a time in inline code is refused in a planted copy that judges inline code' 'refused: issue-comment to example-org/example-repo: the text says 09:10 UTC, the clock there shows 12:00 (UTC)' "$(verdict "$mutant/lib/stated-time.sh" 'The log says `started 09:10 UTC` there.')"
cp "$root/lib/stated-time.sh" "$mutant/lib/stated-time.sh"; sed -i.bak 's/(```+\[^`\]\*\$|~~~)/(```|~~~)/' "$mutant/lib/stated-time.sh"
cmp -s "$root/lib/stated-time.sh" "$mutant/lib/stated-time.sh" && { echo '  FAIL the planted copy equals lib/stated-time.sh'; failed=$((failed + 1)); }
check 'a time after a line of inline code is passed in a planted copy that reads it as a fence' passes "$(verdict "$mutant/lib/stated-time.sh" $'```x``` is the log.\nLanded at 13:10 UTC.')"

if [ "$failed" -ne 0 ]; then echo "$failed failed"; exit 1; fi
echo 'all passed'
