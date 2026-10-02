#!/usr/bin/env bash
# Open the team of one project in one terminal window, one tab per session: the coordinator,
# which starts as the person in charge, and two sessions of each model, which start with no
# prompt and so cost nothing until the coordinator sends them a package.
#
#   team-open.sh PROJECT_FOLDER [--dry-run]
#
# A session is named <first three letters of the folder>-<model>-<index>, so the coordinator
# finds its workers with ListAgents. The tabs open in Ptyxis or gnome-terminal on Linux and in
# Windows Terminal on Windows; AI_CORE_TERMINAL names one of the three where the first one found
# is not the one wanted. --dry-run prints the team and opens nothing.
set -uo pipefail

usage="usage: team-open.sh PROJECT_FOLDER [--dry-run]"
die() { echo "error: $1" >&2; exit "${2:-1}"; }

folder=""; dry=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) echo "$usage"; exit 0 ;;
    --dry-run) dry=1; shift ;;
    -*) die "unknown argument '$1' - $usage" 2 ;;
    *) [ -z "$folder" ] || die "one project folder, not '$folder' and '$1'" 2; folder="$1"; shift ;;
  esac
done
[ -n "$folder" ] || die "$usage" 2
[ -d "$folder" ] || die "$folder is not a folder"
folder="$(cd "$folder" && pwd)"
name="$(basename "$folder")"; prefix="${name:0:3}"

# The team is the project's: its harness's team.tsv where init laid one into the folder, else the
# default of setup-ai-core. One "<name> <model> <effort>" per session, the coordinator first.
CORE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
team_file="$folder/.ai-core/team.tsv"; [ -f "$team_file" ] || team_file="$CORE/templates/.ai-core/team.tsv"
team=""; lead=""; no=0
while IFS=$'\t' read -r role model effort count extra; do
  no=$((no + 1))
  case "$role" in ''|'#'*) continue ;; coordinator|worker) ;; *) die "$team_file:$no: the role is coordinator or worker, not '$role'" ;; esac
  [ -n "$model" ] && [ -z "${extra:-}" ] || die "$team_file:$no: a row is role, model, effort and count, tab-separated"
  case "$(tr '[:upper:]' '[:lower:]' <<< "$model")" in *haiku*) die "$team_file:$no: '$model' is below Sonnet, the floor of the harness" ;; esac
  case "$effort" in low|medium|high|xhigh|max) ;; *) die "$team_file:$no: the effort is low, medium, high, xhigh or max, not '$effort'" ;; esac
  case "$count" in ''|*[!0-9]*|0) die "$team_file:$no: the count is a whole number above 0, not '$count'" ;; esac
  if [ "$role" = coordinator ]; then [ -z "$lead" ] && [ "$count" = 1 ] || die "$team_file:$no: there is one coordinator, and only one"; fi
  for _ in $(seq 1 "$count"); do
    n="$prefix-$model-$(( $(awk -v m="$model" '$2 == m' <<< "$team" | grep -c .) + 1 ))"
    if [ "$role" = coordinator ]; then lead="$n"; team="$n $model $effort${team:+
$team}"; else team="${team:+$team
}$n $model $effort"; fi
  done
done < "$team_file"
[ -n "$lead" ] || die "$team_file names no coordinator"
# The coordinator gets its team from the table that starts it, so model and effort cannot drift
members="$(while read -r n m e; do [ "$n" = "$lead" ] || printf '%s %s %s, ' "$n" "$m" "$e"; done <<< "$team")"
lead_prompt="You are the person in charge of the project $name. Your team: ${members%, }."

terminal="${AI_CORE_TERMINAL:-}"
if [ -z "$terminal" ]; then
  for t in ptyxis gnome-terminal wt; do command -v "$t" >/dev/null 2>&1 && { terminal="$t"; break; }; done
fi
case "$terminal" in
  ''|ptyxis|gnome-terminal|wt) ;;
  *) die "AI_CORE_TERMINAL names '$terminal'; the terminals supported are ptyxis, gnome-terminal and wt" ;;
esac

echo "team of $name, in ${terminal:-no supported terminal}:"
while read -r n m e; do
  printf '  %-14s %-7s %-5s%s\n' "$n" "$m" "$e" "$([ "$n" = "$lead" ] && echo ' the person in charge')"
done <<< "$team"
[ "$dry" -eq 0 ] || exit 0
[ -n "$terminal" ] || die "no supported terminal: install Ptyxis or gnome-terminal (Linux), or Windows Terminal (Windows)"
command -v "$terminal" >/dev/null 2>&1 || die "$terminal is not installed"

first=1
while read -r n m e; do
  cmd="claude -n $n --model $m --effort $e"
  [ "$n" != "$lead" ] || cmd="$cmd '$lead_prompt'"
  case "$terminal" in
    ptyxis)         where=--tab; [ "$first" -eq 0 ] || where=--new-window
                    ptyxis "$where" -T "$n" -d "$folder" -- bash -lc "$cmd; exec bash" ;;
    gnome-terminal) where=--tab; [ "$first" -eq 0 ] || where=--window
                    gnome-terminal "$where" --title="$n" --working-directory="$folder" -- bash -lc "$cmd; exec bash" ;;
    wt)             wt -w "$name" new-tab --title "$n" -d "$folder" pwsh -NoLogo -NoExit -Command "$cmd" ;;
  esac || die "$terminal could not open the tab of $n"
  # The window stands before its tabs are sent: a tab goes into the window that is active
  [ "$first" -eq 0 ] || sleep 1
  first=0
done <<< "$team"
echo "opened: the 7 sessions of $name"
