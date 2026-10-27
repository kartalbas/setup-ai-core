#!/usr/bin/env bash
# Check the prerequisites of the harness on this machine; install what is missing where that
# can be automated; exit 1 with the instruction for what cannot.
#
#   doctor.sh [--no-install]
#
set -euo pipefail

NO_INSTALL=0
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      echo "Usage: doctor.sh [--no-install]"
      echo ""
      echo "Checks Git, gh (with its login), Bash, Node.js 20+ with npx, with TRACKER=forgejo the Forgejo"
      echo "tracker (it must run in this Node, and say not configured, not authorized or healthy), and reports"
      echo "the agent CLIs (claude, agy, codex), and names the temporary worktree of a landing that no"
      echo "longer runs (.worktrees/<repository>/integrate-<issue>.XXXXXX) with the command that removes it."
      echo "Missing required tools are installed with the"
      echo "platform's package manager (brew, apt-get). A login cannot be automated and"
      echo "is reported with its command. Exit 1 when a required tool is still missing afterwards."
      echo ""
      echo "Options:"
      echo "  --no-install  Only report; install nothing"
      echo "  -h, --help    Show this help message"
      exit 0 ;;
    --no-install) NO_INSTALL=1 ;;
    *) echo "error: unknown option '$arg' (see --help)" >&2; exit 1 ;;
  esac
done

case "$(uname -s)" in
  Darwin) OS=macos ;;
  Linux) OS=linux ;;
  *) OS=other ;;
esac

PM=""
case "$OS" in
  macos) command -v brew >/dev/null 2>&1 && PM=brew ;;
  linux) command -v apt-get >/dev/null 2>&1 && PM=apt-get ;;
esac

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/forge.sh"

PROBLEMS=0
INSTALLED_SOMETHING=0

report() { printf '  %-12s %-12s %s\n' "$1" "$2" "$3"; }
problem() { PROBLEMS=$((PROBLEMS + 1)); }

# install <tool> <brew formula> <apt package>
install_tool() {
  local tool="$1" brew_formula="$2" apt_pkg="$3"
  [ "$NO_INSTALL" -eq 0 ] || return 1
  [ -n "$PM" ] || return 1
  echo "--> Installing $tool with $PM..."
  case "$PM" in
    brew) brew install "$brew_formula" >/dev/null || return 1 ;;
    apt-get)
      if [ "$(id -u)" = 0 ]; then apt-get install -y "$apt_pkg" >/dev/null || return 1
      elif command -v sudo >/dev/null 2>&1; then sudo apt-get install -y "$apt_pkg" >/dev/null || return 1
      else return 1; fi ;;
  esac
  INSTALLED_SOMETHING=1
}

major_of() { echo "$1" | sed -E 's/^[^0-9]*([0-9]+).*/\1/'; }

echo "==> doctor: $OS, package manager: ${PM:-none}"

# Git
if ! command -v git >/dev/null 2>&1; then install_tool git git git || true; fi
if command -v git >/dev/null 2>&1; then
  report git present "$(git --version 2>/dev/null | sed -n 1p)"
else
  report git MISSING "install Git from https://git-scm.com"; problem
fi

# the tracker and the forge of the project, and the forge's tool (gh for GitHub)
tracker="$(config_value_lower TRACKER github)" || exit 1
if [ -f "$HARNESS_ROOT/lib/$tracker/tracker.sh" ]; then
  . "$HARNESS_ROOT/lib/tracker.sh"
  tracker_doctor
elif [ "$tracker" = forgejo ]; then
  # the Forgejo tracker has no Bash provider: it runs in Node, which must run .mts files without a flag, so the
  # capability is asked of the tracker itself and no version number is compared
  echo "  tracker: forgejo"
  if ! command -v node >/dev/null 2>&1; then
    report tracker MISSING "the Forgejo tracker runs in Node; install a Node.js that runs .mts files without a flag, from https://nodejs.org"; problem
  elif ! tracker_version="$(node "$HARNESS_ROOT/lib/forgejo/tracker/cli.mts" --version 2>&1)"; then
    report tracker "cannot run" "node $(node -v 2>/dev/null) does not run lib/forgejo/tracker/cli.mts without a flag: $(grep -m1 . <<< "$tracker_version" || echo 'no message')"; problem
  else
    report tracker present "$tracker_version"
    tracker_lines="$( (forgejo_tracker_exec doctor) 2>&1 || true )"
    while IFS= read -r line; do
      case "$line" in
        "ok: "*) report tracker ok "${line#ok: }" ;;
        "problem: "*) report tracker problem "${line#problem: }"; problem ;;
        "") ;;
        *) report tracker problem "the Forgejo doctor said: $line"; problem ;;
      esac
    done <<< "$tracker_lines"
  fi
else
  echo "  tracker: $tracker"
  report tracker MISSING "TRACKER names no folder of lib/ with a tracker.sh"; problem
fi
forge_doctor

# Bash (this script runs in it)
report bash present "${BASH_VERSION%%(*}"

# Node.js 20+ with npx
if ! command -v node >/dev/null 2>&1; then install_tool node node nodejs || true; fi
if command -v node >/dev/null 2>&1; then
  NODE_VERSION="$(node -v 2>/dev/null)"
  if [ "$(major_of "$NODE_VERSION")" -ge 20 ] 2>/dev/null; then
    if command -v npx >/dev/null 2>&1; then
      report node present "Node.js $NODE_VERSION with npx"
    else
      if [ "$PM" = apt-get ]; then install_tool npx npm npm npm || true; fi
      if command -v npx >/dev/null 2>&1; then report node present "Node.js $NODE_VERSION with npx"; else report npx MISSING "Node.js $NODE_VERSION has no npx; install npm"; problem; fi
    fi
  else
    report node "too old" "Node.js $NODE_VERSION; 20 or newer is needed, see https://nodejs.org"; problem
  fi
else
  report node MISSING "install Node.js 20 or newer from https://nodejs.org"; problem
fi

# jq: every board and issue command reads GitHub's answers through it
if ! command -v jq >/dev/null 2>&1; then install_tool jq jq jq || true; fi
if command -v jq >/dev/null 2>&1; then
  report jq present "$(jq --version 2>/dev/null | sed -n 1p)"
else
  report jq MISSING "install jq from https://jqlang.github.io/jq"; problem
fi

# gitleaks, where a repository of this project folder that carries the harness has .gitleaks.toml: the push gate reads
# every push there with `gitleaks git`, which came with gitleaks 8.19, and refuses the push without
# it. brew has a recent one; apt's is 8.16 on every Ubuntu to date, so elsewhere the
# release comes from GitHub, into ~/.local/bin.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/layers.sh"
LEAKS_REPOS=""
# the checkout doctor runs in counts too: `ai-core init <path>` runs doctor there before it writes the STAMP
LEAKS_HERE="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" && LEAKS_HERE="$(dirname "$LEAKS_HERE")" || LEAKS_HERE=""
for f in "$(project_folder_of "$PWD")"/*/.gitleaks.toml; do
  [ -f "$f" ] || continue
  # a clone without the harness runs no gate; a harness clone does, though init is never run in it
  case "$(basename "$(dirname "$f")")" in *-ai-core) ;; *) carries_harness "$(dirname "$f")" || [ "$(dirname "$f")" -ef "$LEAKS_HERE" ] || continue ;; esac
  LEAKS_REPOS="$LEAKS_REPOS $(basename "$(dirname "$f")")"
done
if [ -n "$LEAKS_REPOS" ]; then
  leaks_ok() { command -v gitleaks >/dev/null 2>&1 && gitleaks git --help >/dev/null 2>&1; }
  leaks_release() {
    local os arch tmp url rc=0
    case "$OS" in linux) os=linux ;; macos) os=darwin ;; *) return 1 ;; esac
    case "$(uname -m)" in x86_64|amd64) arch=x64 ;; aarch64|arm64) arch=arm64 ;; armv7l) arch=armv7 ;; *) return 1 ;; esac
    command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v tar >/dev/null 2>&1 || return 1
    echo "--> Installing gitleaks from its GitHub release into ~/.local/bin..."
    tmp="$(mktemp -d)"
    # an outside project's public release, read without a login, so it needs no forge tool
    { url="$(curl -fsSL https://api.github.com/repos/gitleaks/gitleaks/releases/latest 2>/dev/null \
             | jq -r --arg name "_${os}_${arch}.tar.gz" '[.assets[] | select(.name | startswith("gitleaks_") and endswith($name)) | .browser_download_url][0] // empty')" \
      && [ -n "$url" ] && curl -fsSL "$url" -o "$tmp/gitleaks.tar.gz" 2>/dev/null \
      && mkdir -p "$HOME/.local/bin" && tar -xzf "$tmp/gitleaks.tar.gz" -C "$HOME/.local/bin" gitleaks; } || rc=1
    rm -rf "$tmp"
    [ "$rc" -eq 0 ] || return 1
    case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH"; LEAKS_NOTE="note: ~/.local/bin, where gitleaks is now, is not on the PATH of this shell; log in again (a login shell adds it once it exists) or add it to your profile" ;; esac
    INSTALLED_SOMETHING=1
  }
  LEAKS_NOTE=""; LEAKS_NEW=0
  if ! leaks_ok && [ "$NO_INSTALL" -eq 0 ]; then
    case "$PM" in brew) install_tool gitleaks gitleaks - && LEAKS_NEW=1 ;; *) leaks_release && LEAKS_NEW=1 ;; esac
  fi
  case "$OS" in
    macos) how="brew install gitleaks" ;;
    *) how="the gitleaks release for this machine from https://github.com/gitleaks/gitleaks/releases, unpacked into ~/.local/bin" ;;
  esac
  [ "$NO_INSTALL" -eq 0 ] || how="run doctor without --no-install, which installs it, or: $how"
  if leaks_ok; then
    v="$(gitleaks version 2>/dev/null | sed -n '1s/^v\{0,1\}\([0-9][0-9.]*\)$/\1/p')"
    report gitleaks "$([ "$LEAKS_NEW" -eq 1 ] && echo installed || echo present)" "gitleaks${v:+ $v}, for .gitleaks.toml in:$LEAKS_REPOS"
  elif command -v gitleaks >/dev/null 2>&1; then report gitleaks "too old" "$(command -v gitleaks) has no 'gitleaks git', which the push gate runs (8.19 or newer); $how"; problem
  else report gitleaks MISSING "the push gate reads every push with it where .gitleaks.toml is:$LEAKS_REPOS; $how"; problem; fi
  [ -z "$LEAKS_NOTE" ] || echo "$LEAKS_NOTE"
  # The gate reads a merge by its remerge diff, which came with git 2.36, and refuses a git without it
  set -- $LEAKS_REPOS
  git -C "$(project_folder_of "$PWD")/$1" log --diff-merges=remerge -n0 --all >/dev/null 2>&1 \
    || { report git "too old" "$(git --version 2>/dev/null) cannot show what a merge's author wrote (--diff-merges=remerge, git 2.36 or newer), which the push gate reads where .gitleaks.toml is:$LEAKS_REPOS; update git"; problem; }
fi

# The temporary worktree of a landing (integrate-issue --from-origin) stands in
# <project folder>/.worktrees/<repository>/integrate-<issue number>.XXXXXX until the landing's EXIT trap
# removes it. A landing killed before that leaves it, and nothing else names it. It is named here and never
# removed: a landing that still runs holds ai-core-landing in the git directory of the clone, with its process
# id and its issue, so a folder whose issue is not the one a running process holds is a leftover. The command
# that removes it is for the person to run.
for tree in "$(project_folder_of "$PWD")"/.worktrees/*/integrate-[0-9]*.??????/; do
  [ -d "$tree" ] || continue
  tree="$(cd "$tree" && pwd -P)"
  [[ "$tree" =~ $LANDING_WORKTREE_RE ]] || continue
  number="${tree##*/integrate-}"; number="${number%%.*}"
  container="$(dirname "$tree")"; checkout="$(dirname "$(dirname "$container")")/${container##*/}"
  held=""
  if [ -e "$checkout/.git" ] && common="$(git -C "$checkout" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
     && holder="$(cat "$common/ai-core-landing" 2>/dev/null)"; then
    pid="${holder%%$'\t'*}"
    case "$pid" in ''|*[!0-9]*) ;; *) if ps -p "$pid" >/dev/null 2>&1 && [ "${holder##*#}" = "$number" ]; then held=1; fi ;; esac
  fi
  [ -z "$held" ] || continue
  listed=""; [ ! -e "$checkout/.git" ] || listed="$(git -C "$checkout" worktree list --porcelain 2>/dev/null || true)"
  if grep -qxF "worktree $tree" <<< "$listed"; then remove="$(printf 'git -C %q worktree remove --force %q' "$checkout" "$tree")"; else remove="$(printf 'rm -r %q' "$tree")"; fi
  report landing leftover "$tree is what a landing of issue $number left behind; no running landing holds it. Remove it with: $remove"
done

# An agent definition of this machine that names a model below Sonnet
for f in "$HOME"/.claude/agents/*.md; do
  [ -f "$f" ] || continue
  m="$(sed -n '2,/^---/{s/^model:[[:space:]]*//p;}' "$f" | sed -n 1p | tr -d "\r\"'")"
  case "$(tr '[:upper:]' '[:lower:]' <<< "$m")" in *haiku*) report agent "below Sonnet" "$f names the model $m" ;; esac
done

# Agent CLIs: reported, never installed by doctor
for cli in claude agy codex; do
  if command -v "$cli" >/dev/null 2>&1; then
    report "$cli" present "$(command -v "$cli")"
  else
    case "$cli" in
      claude) hint="Claude Code: https://claude.ai/install.sh" ;;
      agy) hint="Antigravity: https://antigravity.google/cli/install.sh" ;;
      codex) hint="Codex: npm install -g @openai/codex" ;;
    esac
    report "$cli" absent "$hint"
  fi
done

# A session-start hook in the machine-wide Claude Code settings that starts a script of an
# earlier layout (a session-start.sh beside the repositories): the repository's own
# .claude/settings.json carries the hook now, so the stale one is taken out.
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
if [ -f "$CLAUDE_SETTINGS" ] && command -v jq >/dev/null 2>&1; then
  STALE_HOOKS="$(jq '[.hooks.SessionStart[]?.hooks[]?.command // empty | select(test("session-start\\.sh"))] | length' "$CLAUDE_SETTINGS" 2>/dev/null || echo 0)"
  if [ "$STALE_HOOKS" -gt 0 ]; then
    if [ "$NO_INSTALL" -eq 1 ]; then report "claude hook" stale "$CLAUDE_SETTINGS starts a session-start script of an earlier layout; run doctor without --no-install to take it out"; problem
    else
      jq '.hooks.SessionStart = [.hooks.SessionStart[]? | .hooks = [.hooks[]? | select((.command // "") | test("session-start\\.sh") | not)] | select(.hooks | length > 0)]' "$CLAUDE_SETTINGS" > "$CLAUDE_SETTINGS.tmp" && mv "$CLAUDE_SETTINGS.tmp" "$CLAUDE_SETTINGS"
      report "claude hook" repaired "$CLAUDE_SETTINGS started a session-start script of an earlier layout; taken out, the repository's own .claude/settings.json carries the hook now"
    fi
  fi
fi

# Claude Code keeps a project's memory in ~/.claude/projects/<project>/memory. A tool of an earlier
# layout made that folder a link into a repository; where the target is gone, Claude Code cannot
# write a memory for that project, so the dead link is taken out and Claude Code makes a real
# folder at the next memory it writes. Nothing is lost: the target is not there.
for link in "$HOME"/.claude/projects/*/memory; do
  [ -L "$link" ] && [ ! -e "$link/" ] || continue
  target="$(readlink "$link" || true)"
  if [ "$NO_INSTALL" -eq 1 ]; then report "claude memory" stale "$link points at $target, which is gone; run doctor without --no-install to take the link out"; problem
  else rm "$link" && report "claude memory" repaired "$link pointed at $target, which is gone; taken out, Claude Code makes a real folder at the next memory it writes"; fi
done

# The team modes of every agent tool on this machine: checked, and installed when one is missing
# (team-modes.tsv says how, per tool). A plugin loads when the tool starts, so a fresh install
# needs the tool restarted; the check says which.
DOCTOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if bash "$DOCTOR_DIR/team-modes-check.sh" --quiet >/dev/null 2>&1; then
  report "team modes" present "every mode of every agent tool here is installed"
elif [ "$NO_INSTALL" -eq 1 ]; then
  report "team modes" MISSING "run: ai-core team-modes-install, then restart the tool"; problem
else
  echo "--> installing the missing team modes (ai-core team-modes-install)..."
  if bash "$DOCTOR_DIR/team-modes-install.sh" && bash "$DOCTOR_DIR/team-modes-check.sh" --quiet >/dev/null 2>&1; then
    report "team modes" installed "restart your agent tool: a plugin loads when the tool starts"
    INSTALLED_SOMETHING=1
  else
    report "team modes" MISSING "the lines above say which mode and how; run: ai-core team-modes-check"; problem
  fi
fi

if [ "$INSTALLED_SOMETHING" -eq 1 ]; then
  echo "note: something was installed; open a new terminal if a tool is still reported missing."
fi

if [ "$PROBLEMS" -gt 0 ]; then
  echo "doctor: $PROBLEMS problem(s); fix them and run doctor again."
  exit 1
fi
echo "doctor: OK"
