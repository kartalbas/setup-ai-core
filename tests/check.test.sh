#!/usr/bin/env bash
# What a red section tells: a command that ends a section names its file, line, command and status,
# the runner prints the section's status, and a failed release setup shows what git said. The
# sections here are a miniature suite of planted ones in a folder of their own, never the whole suite.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# need <output> <text>: the output holds the text, as written
need() { grep -qF -- "$2" <<< "$1" || { echo "the report lacks: $2"; return 1; }; }
# refuse <output> <text>: the output does not hold the text
refuse() { ! grep -qF -- "$2" <<< "$1" || { echo "the report holds, and must not: $2"; return 1; }; }

# make_mini <folder>: the files a section and the runner need, copied from the tree under test
make_mini() {
  mkdir -p "$1/tests/sections" "$1/lib" "$1/rules"
  cp "$root/lib/common.sh" "$root/lib/tool-order.sh" "$1/lib/"
  cp "$root/tests/"{check.sh,lib.sh,tool-environment.sh,date-stub.sh,load-stubs.sh} "$1/tests/"
  printf '# fixture\n' > "$1/rules/00-fixture.md"
}
# plant_section <folder> <name>: the section of that name, its body on the standard input
plant_section() {
  { printf '#!/usr/bin/env bash\n. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"\n'; cat; } > "$1/tests/sections/$2.sh"
}
# run_section <folder> <name>: out and rc of the runner on that section alone
run_section() {
  rc=0; out="$(MINI_MARK="$work/mark" bash "$1/tests/check.sh" "$2" 2>&1)" || rc=$?
}
line_of() { grep -n -- "$2" "$1" | head -1 | cut -d: -f1; }

mkdir -p "$work/mark"
mini="$work/mini"; make_mini "$mini"

plant_section "$mini" top-level <<'EOF'
echo "$WORK" > "$MINI_MARK/top-level-work"
sh -c 'echo marker-top-level >&2; exit 4'
echo "reached after the failure"
EOF
plant_section "$mini" in-function <<'EOF'
. "$ROOT/tests/load-stubs.sh"
make_load_stubs "$WORK/stubs"
echo "reached after the failure"
EOF
awk '{ print } /^  mkdir -p "\$dir"$/ { print "  sh -c '\''echo marker-in-function >&2; exit 5'\''" }' "$root/tests/load-stubs.sh" > "$mini/tests/load-stubs.sh"
plant_section "$mini" captured <<'EOF'
out="$(sh -c 'echo marker-captured >&2; exit 6')"
echo "reached after the failure"
EOF
plant_section "$mini" tolerated <<'EOF'
echo "$WORK" > "$MINI_MARK/tolerated-work"
inner() { grep -q absent <<< present; echo after-the-miss; }
value="$(inner)"
[ "$value" = after-the-miss ] || fail "a captured value changed: $value"
if grep -q absent <<< present; then fail "grep found what is not there"; fi
grep -q absent <<< present || echo "a miss that a list judges"
multi="$(printf 'one\ntwo')"
[ "$multi" = "$(printf 'one\ntwo')" ] || fail "a captured value of two lines changed"
( false ) || echo "a subshell that failed, judged by its caller"
section "tolerated"
EOF

# plants_hold <folder>: the planted failures of the folder's sections are named, and the tolerated ones are not
plants_hold() {
  local dir="$1" n
  run_section "$dir" top-level
  need "$out" "FATAL: tests/sections/top-level.sh:$(line_of "$dir/tests/sections/top-level.sh" marker-top-level): sh -c 'echo marker-top-level >&2; exit 4' (exit 4)" || return 1
  need "$out" "marker-top-level" && need "$out" "FAIL: top-level (exit 4)" && need "$out" "red: top-level" || return 1
  [ "$rc" -eq 1 ] || { echo "the runner ended with $rc, not 1"; return 1; }
  refuse "$out" "reached after the failure" || return 1
  [ ! -e "$(cat "$work/mark/top-level-work")" ] || { echo "the section left its working directory behind after it failed"; return 1; }
  run_section "$dir" in-function
  need "$out" "FATAL: tests/load-stubs.sh:$(line_of "$dir/tests/load-stubs.sh" marker-in-function): sh -c 'echo marker-in-function >&2; exit 5' (exit 5)" || return 1
  need "$out" "FAIL: in-function (exit 5)" && [ "$rc" -eq 1 ] || { echo "in-function: exit $rc"; return 1; }
  run_section "$dir" captured
  need "$out" "FATAL: tests/sections/captured.sh:$(line_of "$dir/tests/sections/captured.sh" marker-captured):" || return 1
  need "$out" "(exit 6)" && need "$out" "marker-captured" && need "$out" "FAIL: captured (exit 6)" || return 1
  run_section "$dir" tolerated
  refuse "$out" "FATAL" && refuse "$out" "FAIL" || return 1
  need "$out" "a miss that a list judges" && need "$out" "OK" && [ "$rc" -eq 0 ] || { echo "tolerated: exit $rc"; return 1; }
  [ ! -e "$(cat "$work/mark/tolerated-work")" ] || { echo "a green section left its working directory behind"; return 1; }
  rc=0; MINI_MARK="$work/mark" KEEP_WORK=1 bash "$dir/tests/check.sh" tolerated > /dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] && [ -d "$(cat "$work/mark/tolerated-work")" ] || { echo "KEEP_WORK did not keep the working directory"; return 1; }
  rm -rf "$(cat "$work/mark/tolerated-work")"
}

plants_hold "$mini" || fail "the planted failures of the miniature suite are not named: $out"
# a bash -c string that sources lib.sh has no file of its own: its failing command is named, and keeps its status
rc=0; out="$(bash -c '. "$1/tests/lib.sh"; sh -c "echo marker-dash-c >&2; exit 7"' _ "$mini" 2>&1)" || rc=$?
[ "$rc" -eq 7 ] && need "$out" 'FATAL: bash -c:1: sh -c "echo marker-dash-c >&2; exit 7" (exit 7)' \
  || fail "a bash -c that sources lib.sh does not name its failing command with its status: exit $rc, $out"

mutant="$work/mutant"; cp -R "$mini" "$mutant"
grep -v "report_fatal \"\$?\"" "$mini/tests/lib.sh" > "$mutant/tests/lib.sh"
cmp -s "$mini/tests/lib.sh" "$mutant/tests/lib.sh" && fail "the mutant without the error report is unchanged"
if plants_hold "$mutant" > /dev/null; then fail "a suite without the error report passed the planted failures"; fi

cp -R "$mini" "$work/mutant-runner"
sed 's/ (exit \$rc)//' "$mini/tests/check.sh" > "$work/mutant-runner/tests/check.sh"
cmp -s "$mini/tests/check.sh" "$work/mutant-runner/tests/check.sh" && fail "the mutant runner is unchanged"
if plants_hold "$work/mutant-runner" > /dev/null; then fail "a runner that prints no status passed"; fi

# The release setup: what git said reaches the report, for a push of the setup and for the install
stubs="$work/stubs"; mkdir -p "$stubs"
# stub_git <case pattern> <marker>: a git that fails with the marker on the arguments of the pattern
stub_git() {
  printf '#!/bin/sh\ncase "$*" in\n  %s) echo %s >&2; exit 1 ;;\nesac\nexec "%s" "$@"\n' "$1" "$2" "$(command -v git)" > "$stubs/git"
  chmod +x "$stubs/git"
}
# release_section <tree>: out and rc of the runner on the release section of that tree, with the stub first on PATH
release_section() {
  rc=0; out="$(PATH="$stubs:$PATH" bash "$1/tests/check.sh" 09-releases 2>&1)" || rc=$?
}
stub_git '*" push "*' marker-setup-push
release_section "$root"
need "$out" "FATAL: tests/sections/09-releases.sh:$(line_of "$root/tests/sections/09-releases.sh" 'push -q -u origin main'): git -C \"\$RD\" push" || fail "a failed setup push is not named: $out"
need "$out" "marker-setup-push" && need "$out" "FAIL: 09-releases (exit 1)" || fail "a failed setup push does not show what git said: $out"
stub_git '*.setup-ai-core*' marker-install-clone
release_section "$root"
need "$out" "FAIL: install.sh from the release origin: " && need "$out" "marker-install-clone" || fail "a failed install does not show what it said: $out"

tree="$work/tree"; mkdir -p "$tree"
(cd "$root" && git ls-files -co --exclude-standard -z | tar --null -cf - -T -) | tar -xf - -C "$tree"
git init -q "$tree"
sed -e 's/^git -C "\$RD" push -q -u origin main$/& 2>\/dev\/null/' -e 's/: \$(cat "\$WORK\/rel-install.log")"/ (see the log)"/' "$root/tests/sections/09-releases.sh" > "$tree/tests/sections/09-releases.sh"
cmp -s "$root/tests/sections/09-releases.sh" "$tree/tests/sections/09-releases.sh" && fail "the mutant release section is unchanged"
release_section "$tree"
if need "$out" "marker-install-clone" > /dev/null; then fail "an install that shows only the name of its log showed what it said"; fi
stub_git '*" push "*' marker-setup-push
release_section "$tree"
if need "$out" "marker-setup-push" > /dev/null; then fail "a setup push that hides what git said showed it"; fi

echo "check.test.sh: a section that ends names its line, command and status; the runner prints the status; a failed release setup shows what git said; tolerated failures stay silent"
