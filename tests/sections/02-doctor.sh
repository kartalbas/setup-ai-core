#!/usr/bin/env bash
# doctor, and init stopping when doctor fails; one section of the suite, run by tests/check.sh with the others
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

section "doctor reports an old Node.js and a missing gh login"
mkdir -p "$WORK/doctorbin"
printf '#!/bin/sh\necho v18.0.0\n' > "$WORK/doctorbin/node"
printf '#!/bin/sh\nif [ "$1" = "--version" ]; then echo "gh version 0.0.0"; else exit 1; fi\n' > "$WORK/doctorbin/gh"
chmod +x "$WORK/doctorbin/node" "$WORK/doctorbin/gh"
# the team modes of this machine are not what is judged here: a table whose probes always pass
printf 'claude\tmode\talways\t-\t-\ncodex\tmode\talways\t-\t-\ngemini\tmode\talways\t-\t-\n' > "$WORK/always.tsv"
mkdir -p "$WORK/doctor-home/.claude/agents"; printf -- '---\nname: cheap\ndescription: runs on haiku\nmodel: haiku\n---\n' > "$WORK/doctor-home/.claude/agents/cheap.md"; HOME="$WORK/doctor-home" TEAM_MODES_FILE="$WORK/always.tsv" PATH="$WORK/doctorbin:$PATH" bash "$ROOT/bin/doctor.sh" --no-install > "$WORK/doctor.sh.log" 2>&1 && fail "doctor.sh exited 0 with an old Node.js"
grep -aq 'node .*too old' "$WORK/doctor.sh.log" || fail "doctor.sh did not report the old Node.js"
grep -aq 'gh .*not logged in' "$WORK/doctor.sh.log" || fail "doctor.sh did not report the missing gh login"
grep -aq 'doctor: 2 problem' "$WORK/doctor.sh.log" || fail "doctor.sh did not count 2 problems"
grep -aq '^  agent .*below Sonnet .*cheap.md names the model haiku' "$WORK/doctor.sh.log" || fail "doctor.sh did not report the agent that names a model below Sonnet"
echo "  exit 1 with the two problems"

section "doctor refuses a gh login without the project scope and keeps one with it"
for c in noscope scope; do
  mkdir -p "$WORK/ghbin-$c"
  if [ "$c" = noscope ]; then sc="'gist', 'read:org', 'read:project', 'repo'"; else sc="'gist', 'project', 'read:org', 'repo'"; fi
  printf '#!/bin/sh\nif [ "$1" = "--version" ]; then echo "gh version 0.0.0"; else echo "  - Token scopes: %s"; fi\n' "$sc" > "$WORK/ghbin-$c/gh"
  chmod +x "$WORK/ghbin-$c/gh"
  # the machine decides the rest of the report, so only the noscope run is held to its exit code
  HOME="$WORK/doctor-home" TEAM_MODES_FILE="$WORK/always.tsv" PATH="$WORK/ghbin-$c:$PATH" bash "$ROOT/bin/doctor.sh" --no-install > "$WORK/ghscope-$c.sh.log" 2>&1 && [ "$c" = noscope ] && fail "doctor.sh exited 0 without the project scope"
done
grep -aq '^  gh .*no project scope .*run: gh auth refresh -h github.com -s project$' "$WORK/ghscope-noscope.sh.log" || fail "doctor.sh did not refuse the login without the project scope (see $WORK/ghscope-noscope.sh.log)"
grep -aq '^  gh .*present .*gh version 0.0.0, logged in$' "$WORK/ghscope-scope.sh.log" || fail "doctor.sh did not keep the login with the project scope (see $WORK/ghscope-scope.sh.log)"
echo "  read:project alone is refused and project is kept"

section "doctor wants gitleaks with 'gitleaks git' where a repository of the project folder carries .gitleaks.toml: missing, too old, present, not needed"
LF="$WORK/leaks-folder"; mkdir -p "$LF/plain" "$WORK/plain-folder/web"; git init -q "$LF/shop"; : > "$LF/shop/.gitleaks.toml"
NOLEAKS="$(while IFS= read -r d; do [ -z "$d" ] || [ -e "$d/gitleaks" ] || printf '%s:' "$d"; done <<< "$(tr ':' '\n' <<< "$PATH")")"
mkdir -p "$WORK/leaksbin-new" "$WORK/leaksbin-old"
printf '#!/bin/sh\ncase "$1" in version) echo 8.30.1 ;; esac\nexit 0\n' > "$WORK/leaksbin-new/gitleaks"
printf '#!/bin/sh\n[ "$1" = git ] && exit 1\necho 8.16.0\n' > "$WORK/leaksbin-old/gitleaks"
chmod +x "$WORK/leaksbin-new/gitleaks" "$WORK/leaksbin-old/gitleaks"
leaks_doctor() {  # leaks_doctor <case> <directory> <PATH>: doctor --no-install started in the directory
  (cd "$2" && HOME="$WORK/doctor-home" TEAM_MODES_FILE="$WORK/always.tsv" PATH="$3" bash "$ROOT/bin/doctor.sh" --no-install > "$WORK/leaks-$1.log" 2>&1)
}
leaks_doctor missing "$LF" "$NOLEAKS" && fail "doctor.sh exited 0 without gitleaks where .gitleaks.toml is"
grep -aq '^  gitleaks .*MISSING .*the push gate reads every push with it where .gitleaks.toml is: shop; run doctor without --no-install, which installs it' "$WORK/leaks-missing.log" || fail "doctor.sh did not report gitleaks missing for shop (see $WORK/leaks-missing.log)"
leaks_doctor old "$LF" "$WORK/leaksbin-old:$NOLEAKS" && fail "doctor.sh exited 0 with a gitleaks from before 8.19"
grep -aq '^  gitleaks .*too old .*has no .gitleaks git., which the push gate runs (8.19 or newer)' "$WORK/leaks-old.log" || fail "doctor.sh did not report the gitleaks without 'gitleaks git' (see $WORK/leaks-old.log)"
leaks_doctor new "$LF/shop" "$WORK/leaksbin-new:$NOLEAKS" || true   # started inside a repository of the folder
grep -aq '^  gitleaks .*present .*gitleaks 8\.30\.1, for .gitleaks.toml in: shop' "$WORK/leaks-new.log" || fail "doctor.sh did not report gitleaks present (see $WORK/leaks-new.log)"
grep -aq '^  git .*too old' "$WORK/leaks-new.log" && fail "doctor.sh called a git that shows remerge diffs too old (see $WORK/leaks-new.log)"
# A git before 2.36 rejects --diff-merges=remerge; the gate refuses it, so doctor names it first
mkdir -p "$WORK/gitbin-old"
printf '#!/bin/sh
case "$*" in *--diff-merges=remerge*) echo "fatal: unknown value for --diff-merges: remerge" >&2; exit 128 ;; esac
exec %s "$@"
' "$(command -v git)" > "$WORK/gitbin-old/git"
chmod +x "$WORK/gitbin-old/git"
leaks_doctor oldgit "$LF/shop" "$WORK/gitbin-old:$WORK/leaksbin-new:$NOLEAKS" && fail "doctor.sh exited 0 with a git that cannot show remerge diffs where .gitleaks.toml is"
grep -aq '^  git .*too old .*--diff-merges=remerge, git 2.36 or newer.*where .gitleaks.toml is: shop' "$WORK/leaks-oldgit.log" || fail "doctor.sh did not report the git without remerge diffs (see $WORK/leaks-oldgit.log)"
leaks_doctor none "$WORK/plain-folder" "$NOLEAKS" || true
grep -aq '^  gitleaks' "$WORK/leaks-none.log" && fail "doctor.sh names gitleaks where no repository carries .gitleaks.toml"
echo "  missing and too old are problems that name how to install it, present names the repositories, a git without remerge diffs is a problem too, and no repository with .gitleaks.toml means no line"

section "init runs doctor in the folder it serves: a repository there with .gitleaks.toml stops it without gitleaks"
F="$WORK/leaks-init"; git init -q "$F/shop"; : > "$F/shop/.gitleaks.toml"
HOME="$WORK/doctor-home" TEAM_MODES_FILE="$WORK/always.tsv" PATH="$NOLEAKS" bash "$ROOT/bin/init.sh" --all "$F" --dry-run > "$F.log" 2>&1 && fail "init.sh --all went on without gitleaks (see $F.log)"
grep -aq '^  gitleaks .*MISSING .*is: shop' "$F.log" && grep -aq 'doctor reported' "$F.log" || fail "init.sh did not stop on doctor's gitleaks line for the folder it serves (see $F.log)"
echo "  it stops with doctor's gitleaks line"

section "init runs doctor first and deploys nothing when it fails"
mkdir -p "$WORK/nodoc"
PATH="$WORK/doctorbin:$PATH" bash "$ROOT/bin/init.sh" "$WORK/nodoc" > "$WORK/nodoc.log" 2>&1 && fail "init.sh exited 0 although doctor failed"
grep -aq 'doctor reported' "$WORK/nodoc.log" || fail "init in nodoc did not point at doctor"
[ -e "$WORK/nodoc/.ai-core" ] && fail "init in nodoc deployed files although doctor failed"
echo "  it stops before deploying"

section "doctor takes out a project memory link of Claude Code whose target is gone, and leaves a live one alone"
DH="$WORK/memory-home"; mkdir -p "$DH/.claude/projects/gone" "$DH/.claude/projects/live" "$WORK/memory-gone" "$WORK/memory-live"
for p in gone live; do ln -s "$WORK/memory-$p" "$DH/.claude/projects/$p/memory"; done
rm -rf "$WORK/memory-gone"
for run in dry fix; do
  if [ "$run" = dry ]; then HOME="$DH" TEAM_MODES_FILE="$WORK/always.tsv" bash "$ROOT/bin/doctor.sh" --no-install > "$WORK/memory-$run.log" 2>&1 || true; else HOME="$DH" TEAM_MODES_FILE="$WORK/always.tsv" bash "$ROOT/bin/doctor.sh" > "$WORK/memory-$run.log" 2>&1 || true; fi
  if [ "$run" = dry ]; then
    grep -aq 'claude memory .*stale .*gone.*memory points at .*, which is gone' "$WORK/memory-$run.log" && [ -L "$DH/.claude/projects/gone/memory" ] || fail "doctor.sh --no-install did not report the dead memory link, or took it out (see $WORK/memory-$run.log)"
  else
    grep -aq 'claude memory .*repaired' "$WORK/memory-$run.log" && [ ! -L "$DH/.claude/projects/gone/memory" ] && [ ! -e "$DH/.claude/projects/gone/memory" ] || fail "doctor.sh did not take the dead memory link out (see $WORK/memory-$run.log)"
  fi
  [ -e "$DH/.claude/projects/live/memory/" ] || fail "doctor.sh touched the live memory link"
done
echo "  reported by a dry run, taken out otherwise; the live one kept"
exit 0
