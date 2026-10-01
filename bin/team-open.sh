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

# <name> <model> <effort>: the coordinator first, then the pairs
team="$prefix-opus-1 opus max
$prefix-fable-1 fable max
$prefix-fable-2 fable max
$prefix-opus-2 opus high
$prefix-opus-3 opus high
$prefix-sonnet-1 sonnet max
$prefix-sonnet-2 sonnet max"
lead="$prefix-opus-1"
lead_prompt="You are the person in charge of the project $name."

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
