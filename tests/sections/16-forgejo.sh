#!/usr/bin/env bash
# the Forgejo tracker (lib/forgejo/tracker): the type check and every test of it; one section of the suite, run by
# tests/check.sh with the others. Needs the development-only compiler under tests/typescript
# (npm ci --prefix tests/typescript); without it the section is red, never skipped.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

section "the Forgejo tracker: the type check, then every test of it, against a fake Forgejo that reaches no network"
TRACKER_DIR="$ROOT/lib/forgejo/tracker"

# typecheck <the folder that holds node_modules/.bin/tsc>: the strict check of the whole tree, with no output files
typecheck() {
  local compiler="$1/node_modules/.bin/tsc"
  [ -x "$compiler" ] || { echo "the compiler is missing: $compiler - run: npm ci --prefix tests/typescript"; return 1; }
  "$compiler" -p "$TRACKER_DIR/tsconfig.json"
}

# the check can go red: with no compiler it is red, and the real one is held to the same function
if typecheck "$WORK/no-compiler" > "$WORK/no-compiler.log" 2>&1; then fail "the type check passed with no compiler"; fi
grep -q 'the compiler is missing' "$WORK/no-compiler.log" || fail "a missing compiler is not named: $(cat "$WORK/no-compiler.log")"
echo "  planted: without the compiler the type check is red and says why"

typecheck "$ROOT/tests/typescript" > "$WORK/typecheck.log" 2>&1 || { cat "$WORK/typecheck.log"; fail "the type check of lib/forgejo/tracker"; }
echo "  the type check is clean: $(find "$TRACKER_DIR" -name '*.mts' | wc -l | tr -d ' ') files, strict, no output"

node "$TRACKER_DIR/cli.mts" --version > "$WORK/version.log" 2>&1 || { cat "$WORK/version.log"; fail "this Node does not run .mts files without a flag: $(node --version)"; }

tests=()
while IFS= read -r file; do tests+=("$file"); done < <(find "$TRACKER_DIR" -name '*.test.mts' | sort)
[ "${#tests[@]}" -gt 0 ] || fail "no test of the Forgejo tracker found"
node --test "${tests[@]}" > "$WORK/node-test.log" 2>&1 || { cat "$WORK/node-test.log"; fail "node --test of the Forgejo tracker"; }
echo "  ${#tests[@]} test files: $(grep -E '^ℹ (tests|pass|fail) ' "$WORK/node-test.log" | tr -s ' ' | paste -sd ',' - | sed 's/ℹ //g')"

section "the shared entries with TRACKER=forgejo: no board code is loaded, the GitHub path still loads it"
bash "$ROOT/tests/forgejo-entries.sh" > "$WORK/entries.log" 2>&1 || { cat "$WORK/entries.log"; fail "tests/forgejo-entries.sh"; }
grep -a '^  ' "$WORK/entries.log"
