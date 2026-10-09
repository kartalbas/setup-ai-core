#!/usr/bin/env bash
# doctor on both twins, and init stopping when doctor fails; one section of the suite, run by tests/check.sh with the others
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

section "doctor reports an old Node.js and a missing gh login the same way on both twins"
mkdir -p "$WORK/doctorbin"
printf '#!/bin/sh\necho v18.0.0\n' > "$WORK/doctorbin/node"
printf '#!/bin/sh\nif [ "$1" = "--version" ]; then echo "gh version 0.0.0"; else exit 1; fi\n' > "$WORK/doctorbin/gh"
chmod +x "$WORK/doctorbin/node" "$WORK/doctorbin/gh"
printf '@echo v18.0.0\r\n' > "$WORK/doctorbin/node.cmd"
printf '@if "%%1"=="--version" (echo gh version 0.0.0) else (exit /b 1)\r\n' > "$WORK/doctorbin/gh.cmd"
# the team modes of this machine are not what is judged here: a table whose probes always pass
printf 'claude\tcaveman\tlite\talways\t-\t-\ncodex\tcaveman\tlite\talways\t-\t-\ngemini\tcaveman\tlite\talways\t-\t-\n' > "$WORK/always.tsv"
mkdir -p "$WORK/doctor-home/.claude/agents"; printf -- '---\nname: cheap\ndescription: runs on haiku\nmodel: haiku\n---\n' > "$WORK/doctor-home/.claude/agents/cheap.md"; HOME="$WORK/doctor-home" TEAM_MODES_FILE="$WORK/always.tsv" PATH="$WORK/doctorbin:$PATH" bash "$ROOT/bin/doctor.sh" --no-install > "$WORK/doctor.sh.log" 2>&1 && fail "doctor.sh exited 0 with an old Node.js"
HOME="$WORK/doctor-home" USERPROFILE="$(native "$WORK/doctor-home")" TEAM_MODES_FILE="$(native "$WORK/always.tsv")" PATH="$WORK/doctorbin:$PATH" pwsh -NoProfile -File "$ROOT/bin/doctor.ps1" -NoInstall > "$WORK/doctor.ps1.log" 2>&1 && fail "doctor.ps1 exited 0 with an old Node.js"
for t in sh ps1; do
  grep -aq 'node .*too old' "$WORK/doctor.$t.log" || fail "doctor.$t did not report the old Node.js"
  grep -aq 'gh .*not logged in' "$WORK/doctor.$t.log" || fail "doctor.$t did not report the missing gh login"
  grep -aq 'doctor: 2 problem' "$WORK/doctor.$t.log" || fail "doctor.$t did not count 2 problems"
  grep -aq '^  agent .*below Sonnet .*cheap.md names the model haiku' "$WORK/doctor.$t.log" || fail "doctor.$t did not report the agent that names a model below Sonnet"
done
echo "  both exit 1 with the same two problems"

section "doctor refuses a gh login without the project scope and keeps one with it, on both twins"
for c in noscope scope; do
  mkdir -p "$WORK/ghbin-$c"
  if [ "$c" = noscope ]; then sc="'gist', 'read:org', 'read:project', 'repo'"; else sc="'gist', 'project', 'read:org', 'repo'"; fi
  printf '#!/bin/sh\nif [ "$1" = "--version" ]; then echo "gh version 0.0.0"; else echo "  - Token scopes: %s"; fi\n' "$sc" > "$WORK/ghbin-$c/gh"
  printf '@if "%%1"=="--version" (echo gh version 0.0.0) else (echo   - Token scopes: %s)\r\n' "$sc" > "$WORK/ghbin-$c/gh.cmd"
  chmod +x "$WORK/ghbin-$c/gh"
  # the machine decides the rest of the report, so only the noscope run is held to its exit code
  HOME="$WORK/doctor-home" TEAM_MODES_FILE="$WORK/always.tsv" PATH="$WORK/ghbin-$c:$PATH" bash "$ROOT/bin/doctor.sh" --no-install > "$WORK/ghscope-$c.sh.log" 2>&1 && [ "$c" = noscope ] && fail "doctor.sh exited 0 without the project scope"
  HOME="$WORK/doctor-home" USERPROFILE="$(native "$WORK/doctor-home")" TEAM_MODES_FILE="$(native "$WORK/always.tsv")" PATH="$WORK/ghbin-$c:$PATH" pwsh -NoProfile -File "$ROOT/bin/doctor.ps1" -NoInstall > "$WORK/ghscope-$c.ps1.log" 2>&1 && [ "$c" = noscope ] && fail "doctor.ps1 exited 0 without the project scope"
done
for t in sh ps1; do
  grep -aq '^  gh .*no project scope .*run: gh auth refresh -h github.com -s project$' "$WORK/ghscope-noscope.$t.log" || fail "doctor.$t did not refuse the login without the project scope (see $WORK/ghscope-noscope.$t.log)"
  grep -aq '^  gh .*present .*gh version 0.0.0, logged in$' "$WORK/ghscope-scope.$t.log" || fail "doctor.$t did not keep the login with the project scope (see $WORK/ghscope-scope.$t.log)"
done
echo "  both refuse read:project alone and keep project"

section "doctor wants gitleaks with 'gitleaks git' where a repository of the project folder carries .gitleaks.toml: missing, too old, present, not needed; on both twins"
LF="$WORK/leaks-folder"; mkdir -p "$LF/plain" "$WORK/plain-folder/web"; git init -q "$LF/shop"; : > "$LF/shop/.gitleaks.toml"
NOLEAKS="$(while IFS= read -r d; do [ -z "$d" ] || [ -e "$d/gitleaks" ] || [ -e "$d/gitleaks.exe" ] || [ -e "$d/gitleaks.cmd" ] || printf '%s:' "$d"; done <<< "$(tr ':' '\n' <<< "$PATH")")"
# pwsh can share its folder with gitleaks (both in ~/.local/bin); the folder it is installed in,
# found through its link, keeps it on the PATH of the ps1 case
NOLEAKS="$(dirname "$(readlink -f "$(command -v pwsh)")"):$NOLEAKS"
mkdir -p "$WORK/leaksbin-new" "$WORK/leaksbin-old"
printf '#!/bin/sh\ncase "$1" in version) echo 8.30.1 ;; esac\nexit 0\n' > "$WORK/leaksbin-new/gitleaks"
printf '@if "%%1"=="version" echo 8.30.1\r\n@exit /b 0\r\n' > "$WORK/leaksbin-new/gitleaks.cmd"
printf '#!/bin/sh\n[ "$1" = git ] && exit 1\necho 8.16.0\n' > "$WORK/leaksbin-old/gitleaks"
printf '@if "%%1"=="git" exit /b 1\r\n@echo 8.16.0\r\n' > "$WORK/leaksbin-old/gitleaks.cmd"
chmod +x "$WORK/leaksbin-new/gitleaks" "$WORK/leaksbin-old/gitleaks"
leaks_doctor() {  # leaks_doctor <twin> <case> <directory> <PATH>: doctor --no-install started in the directory
  if [ "$1" = sh ]; then (cd "$3" && HOME="$WORK/doctor-home" TEAM_MODES_FILE="$WORK/always.tsv" PATH="$4" bash "$ROOT/bin/doctor.sh" --no-install > "$WORK/leaks-$1-$2.log" 2>&1)
  else (cd "$3" && HOME="$WORK/doctor-home" USERPROFILE="$(native "$WORK/doctor-home")" TEAM_MODES_FILE="$(native "$WORK/always.tsv")" PATH="$4" pwsh -NoProfile -File "$(native "$ROOT/bin/doctor.ps1")" -NoInstall > "$WORK/leaks-$1-$2.log" 2>&1); fi
}
for t in sh ps1; do
  leaks_doctor "$t" missing "$LF" "$NOLEAKS" && fail "doctor.$t exited 0 without gitleaks where .gitleaks.toml is"
  grep -aq '^  gitleaks .*MISSING .*the push gate reads every push with it where .gitleaks.toml is: shop; run doctor without -\{1,2\}[Nn]o-\{0,1\}[Ii]nstall, which installs it' "$WORK/leaks-$t-missing.log" || fail "doctor.$t did not report gitleaks missing for shop (see $WORK/leaks-$t-missing.log)"
  leaks_doctor "$t" old "$LF" "$WORK/leaksbin-old:$NOLEAKS" && fail "doctor.$t exited 0 with a gitleaks from before 8.19"
  grep -aq '^  gitleaks .*too old .*has no .gitleaks git., which the push gate runs (8.19 or newer)' "$WORK/leaks-$t-old.log" || fail "doctor.$t did not report the gitleaks without 'gitleaks git' (see $WORK/leaks-$t-old.log)"
  leaks_doctor "$t" new "$LF/shop" "$WORK/leaksbin-new:$NOLEAKS" || true   # started inside a repository of the folder
  grep -aq '^  gitleaks .*present .*gitleaks 8\.30\.1, for .gitleaks.toml in: shop' "$WORK/leaks-$t-new.log" || fail "doctor.$t did not report gitleaks present (see $WORK/leaks-$t-new.log)"
  leaks_doctor "$t" none "$WORK/plain-folder" "$NOLEAKS" || true
  grep -aq '^  gitleaks' "$WORK/leaks-$t-none.log" && fail "doctor.$t names gitleaks where no repository carries .gitleaks.toml"
done
echo "  missing and too old are problems that name how to install it, present names the repositories, and no repository with .gitleaks.toml means no line, on both twins"

section "init runs doctor in the folder it serves: a repository there with .gitleaks.toml stops it without gitleaks, on both twins"
for t in sh ps1; do
  F="$WORK/leaks-init-$t"; git init -q "$F/shop"; : > "$F/shop/.gitleaks.toml"
  if [ "$t" = sh ]; then HOME="$WORK/doctor-home" TEAM_MODES_FILE="$WORK/always.tsv" PATH="$NOLEAKS" bash "$ROOT/bin/init.sh" --all "$F" --dry-run > "$F.log" 2>&1
  else HOME="$WORK/doctor-home" USERPROFILE="$(native "$WORK/doctor-home")" TEAM_MODES_FILE="$(native "$WORK/always.tsv")" PATH="$NOLEAKS" pwsh -NoProfile -File "$ROOT/bin/init.ps1" -All "$(native "$F")" -DryRun > "$F.log" 2>&1; fi && fail "init.$t --all went on without gitleaks (see $F.log)"
  grep -aq '^  gitleaks .*MISSING .*is: shop' "$F.log" && grep -aq 'doctor reported' "$F.log" || fail "init.$t did not stop on doctor's gitleaks line for the folder it serves (see $F.log)"
done
echo "  both stop with doctor's gitleaks line"

section "init runs doctor first and deploys nothing when it fails, on both twins"
mkdir -p "$WORK/nodoc-sh" "$WORK/nodoc-ps"
PATH="$WORK/doctorbin:$PATH" bash "$ROOT/bin/init.sh" "$WORK/nodoc-sh" > "$WORK/nodoc-sh.log" 2>&1 && fail "init.sh exited 0 although doctor failed"
PATH="$WORK/doctorbin:$PATH" pwsh -NoProfile -File "$ROOT/bin/init.ps1" -TargetDir "$(native "$WORK/nodoc-ps")" > "$WORK/nodoc-ps.log" 2>&1 && fail "init.ps1 exited 0 although doctor failed"
for t in sh ps; do
  grep -aq 'doctor reported' "$WORK/nodoc-$t.log" || fail "init in nodoc-$t did not point at doctor"
  [ -e "$WORK/nodoc-$t/.ai-core" ] && fail "init in nodoc-$t deployed files although doctor failed"
done
echo "  both stop before deploying"

section "doctor takes out a project memory link of Claude Code whose target is gone, and leaves a live one alone, on both twins"
for t in sh ps1; do
  DH="$WORK/memory-home-$t"; mkdir -p "$DH/.claude/projects/gone" "$DH/.claude/projects/live" "$WORK/memory-gone-$t" "$WORK/memory-live-$t"
  for p in gone live; do
    if command -v cmd.exe >/dev/null 2>&1; then cmd.exe //c mklink //J "$(native "$DH/.claude/projects/$p/memory")" "$(native "$WORK/memory-$p-$t")" > /dev/null || fail "mklink for $p"
    else ln -s "$WORK/memory-$p-$t" "$DH/.claude/projects/$p/memory"; fi
  done
  rm -rf "$WORK/memory-gone-$t"
  for run in dry fix; do
    if [ "$t" = sh ]; then
      if [ "$run" = dry ]; then HOME="$DH" TEAM_MODES_FILE="$WORK/always.tsv" bash "$ROOT/bin/doctor.sh" --no-install > "$WORK/memory-$t-$run.log" 2>&1 || true; else HOME="$DH" TEAM_MODES_FILE="$WORK/always.tsv" bash "$ROOT/bin/doctor.sh" > "$WORK/memory-$t-$run.log" 2>&1 || true; fi
    else
      if [ "$run" = dry ]; then HOME="$DH" USERPROFILE="$(native "$DH")" TEAM_MODES_FILE="$(native "$WORK/always.tsv")" pwsh -NoProfile -File "$ROOT/bin/doctor.ps1" -NoInstall > "$WORK/memory-$t-$run.log" 2>&1 || true; else HOME="$DH" USERPROFILE="$(native "$DH")" TEAM_MODES_FILE="$(native "$WORK/always.tsv")" pwsh -NoProfile -File "$ROOT/bin/doctor.ps1" > "$WORK/memory-$t-$run.log" 2>&1 || true; fi
    fi
    if [ "$run" = dry ]; then
      grep -aq 'claude memory .*stale .*gone.*memory points at .*, which is gone' "$WORK/memory-$t-$run.log" && [ -L "$DH/.claude/projects/gone/memory" ] || fail "doctor.$t --no-install did not report the dead memory link, or took it out (see $WORK/memory-$t-$run.log)"
    else
      grep -aq 'claude memory .*repaired' "$WORK/memory-$t-$run.log" && [ ! -L "$DH/.claude/projects/gone/memory" ] && [ ! -e "$DH/.claude/projects/gone/memory" ] || fail "doctor.$t did not take the dead memory link out (see $WORK/memory-$t-$run.log)"
    fi
    [ -e "$DH/.claude/projects/live/memory/" ] || fail "doctor.$t touched the live memory link"
  done
done
echo "  reported by a dry run, taken out otherwise; the live one kept, on both twins"
exit 0
