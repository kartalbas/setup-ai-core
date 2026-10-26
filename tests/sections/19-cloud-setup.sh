#!/usr/bin/env bash
# The setup script of a cloud environment, as README.md section 4.11 gives it to be pasted: it is
# extracted from the README and run, so the text a person pastes is the text that is proven.
# One section of the suite, run by tests/check.sh with the others.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

RAW_URL="https://raw.githubusercontent.com/kartalbas/setup-ai-core/master/bin/install.sh"
TOKEN_SENTINEL="sentinel-token-never-to-appear"
SB="$WORK/cloud"; mkdir -p "$SB/bin"

# The first bash block of section 4.11 is the script
extract_script() {
  awk '/^### 4\.11 /{ in_section = 1; next } /^### /{ in_section = 0 }
       in_section && /^```bash$/ && !done { in_block = 1; next }
       in_block && /^```$/ { in_block = 0; done = 1 }
       in_block { print }' "$1"
}

# The commands the script reaches over the network, answered from this disk: curl serves the
# install.sh of this checkout for the one URL the README names and fails for any other, and git
# clones this checkout where install.sh asks for GitHub
REAL_GIT="$(command -v git)"
cat > "$SB/bin/curl" <<EOF
#!/bin/bash
url=""; for a in "\$@"; do case "\$a" in http*) url="\$a" ;; esac; done
echo "\$url" >> "$SB/curl.log"
[ "\$url" = "$RAW_URL" ] || exit 22
cat "$ROOT/bin/install.sh"
EOF
cat > "$SB/bin/git" <<EOF
#!/bin/bash
args=(); for a in "\$@"; do [ "\$a" = "https://github.com/kartalbas/setup-ai-core" ] && a="$ROOT"; args+=("\$a"); done
exec "$REAL_GIT" "\${args[@]}"
EOF
# gh answers as logged in or not, by the file $SB/gh-state
cat > "$SB/bin/gh" <<EOF
#!/bin/sh
case "\$1" in
  --version) echo "gh version 0.0.0" ;;
  auth) [ "\$(cat "$SB/gh-state")" = in ] && { echo "  - Token scopes: 'project', 'repo'"; exit 0; }; echo "You are not logged into any GitHub hosts." >&2; exit 1 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$SB/bin/curl" "$SB/bin/git" "$SB/bin/gh"

# The team mode of the table is the skill folder in the home; the real claude command is hidden
# from the PATH, as it is not there yet when a cloud environment runs its setup script
printf 'claude\tarchify\tskill:archify\tmkdir -p "$HOME/.claude/skills/archify"\t-\n' > "$SB/modes.tsv"
cloud_path="$SB/bin"; shadow_n=0
IFS=: read -r -a path_dirs <<< "$PATH"
for d in "${path_dirs[@]}"; do
  if [ -e "$d/claude" ]; then
    shadow="$SB/shadow$((++shadow_n))"; mkdir -p "$shadow"
    for f in "$d"/*; do [ "$(basename "$f")" = claude ] || ln -s "$f" "$shadow/$(basename "$f")"; done
    cloud_path="$cloud_path:$shadow"
  else cloud_path="$cloud_path:$d"; fi
done

# run_case <script> <case>: the script in a fresh home and a fresh clone, the way a cloud
# environment runs it; the case is what the environment looks like. Prints nothing; the verdict
# is the status in $SB/rc and the log in $SB/log.
run_case() {
  local script="$1" case_name="$2" home="$SB/home-$2-$RANDOM" clone="$SB/clone-$2-$RANDOM"
  mkdir -p "$home" "$clone"
  case "$case_name" in outside) ;; *) git -C "$clone" init -q . && git -C "$clone" commit -q --allow-empty -m 'First commit' ;; esac
  case "$case_name" in loggedout) echo out > "$SB/gh-state" ;; *) echo in > "$SB/gh-state" ;; esac
  : > "$SB/curl.log"
  ( cd "$clone" && HOME="$home" PATH="$cloud_path" TEAM_MODES_FILE="$SB/modes.tsv" GH_TOKEN="$TOKEN_SENTINEL" \
      bash "$script" > "$SB/log" 2>&1 ) && echo 0 > "$SB/rc" || echo $? > "$SB/rc"
  echo "$home" > "$SB/last-home"; echo "$clone" > "$SB/last-clone"
}

# verdict <script>: the failures of a script, one per line; nothing when it holds on every case
verdict() {
  local script="$1" home clone
  if grep -qi 'token' "$script"; then echo "the script names a token"; fi
  run_case "$script" installed
  home="$(cat "$SB/last-home")"; clone="$(cat "$SB/last-clone")"
  [ "$(cat "$SB/rc")" = 0 ] || echo "installed: the script ended with status $(cat "$SB/rc")"
  grep -q '^Ready for task execution\.$' "$SB/log" || echo "installed: the session start did not report ready"
  [ -f "$clone/AGENTS.md" ] && [ -f "$clone/.ai-core/rules/rules.md" ] && [ -f "$clone/.claude/settings.json" ] || echo "installed: the clone lacks the deployed harness"
  [ -z "$(git -C "$clone" status --porcelain)" ] || echo "installed: git status shows $(git -C "$clone" status --porcelain | tr '\n' ' ')"
  [ "$(cat "$SB/curl.log")" = "$RAW_URL" ] || echo "installed: curl was asked for $(tr '\n' ' ' < "$SB/curl.log")"
  if grep -rqF "$TOKEN_SENTINEL" "$SB/log" "$home" "$clone" 2>/dev/null; then echo "installed: the token reached the log or a file"; fi
  run_case "$script" loggedout
  [ "$(cat "$SB/rc")" != 0 ] || echo "loggedout: the script ended with status 0 where gh is not signed in"
  grep -q 'failed at: deploy the harness in the clone$' "$SB/log" || echo "loggedout: the log does not name the step"
  [ ! -e "$(cat "$SB/last-clone")/AGENTS.md" ] || echo "loggedout: a harness was deployed"
  run_case "$script" outside
  [ "$(cat "$SB/rc")" != 0 ] || echo "outside: the script ended with status 0 outside a clone"
  grep -q 'failed at: find the clone$' "$SB/log" || echo "outside: the log does not name the step"
}

section "the setup script of README 4.11 deploys the harness in a clone, stops at a named step, and handles no token"
extract_script "$ROOT/README.md" > "$SB/setup.sh"
[ -s "$SB/setup.sh" ] || fail "README.md section 4.11 holds no bash block"
got="$(verdict "$SB/setup.sh")"
[ -z "$got" ] || fail "the setup script of README 4.11: $got (log $(cat "$SB/log"))"
echo "  the script ends ready in a clone, names its step where gh is signed out or no clone is there, and the token appears nowhere"

section "planted defects turn the verdict red, an innocent rewrite keeps it green"
# the same script with comments, blank lines and other spacing: only a changed command may matter
{ echo '# pasted from the README'; echo; sed 's/^\(ai-core [a-z-]*\)$/\1  # the step/' "$SB/setup.sh"; echo; } > "$SB/innocent.sh"
cmp -s "$SB/setup.sh" "$SB/innocent.sh" && fail "the innocent rewrite changed nothing"
got="$(verdict "$SB/innocent.sh")"
[ -z "$got" ] || fail "an innocent rewrite turned the verdict red: $got"
echo "  innocent: comments and blank lines, green"

plant() {  # plant <name> <sed expression> <text the verdict must name>
  sed "$2" "$SB/setup.sh" > "$SB/plant-$1.sh"
  cmp -s "$SB/setup.sh" "$SB/plant-$1.sh" && fail "planted defect $1 changed nothing"
  got="$(verdict "$SB/plant-$1.sh")"
  grep -qF "$3" <<< "$got" || fail "planted defect $1 was not caught as '$3'; the verdict was: ${got:-green}"
  echo "  planted: $1, red"
}
plant no-tool-named 's/team-modes-install --tool claude/team-modes-install/' "installed: the script ended with status"
plant init-failure-swallowed 's/^ai-core init$/ai-core init || true/' "loggedout: the log does not name the step"
plant token-printed '/^export PATH/a\
echo "$GH_TOKEN"' "the script names a token"
plant token-read-quietly 's/^STEP="session start"$/STEP="session start"; : "$GH_TOKEN"/' "the script names a token"
plant no-clone-check 's/^CLONE=.*$/CLONE="$PWD"/' "outside: the script ended with status 0"

section "the README row for sandboxes names the setup script and no longer says nothing reaches a sandbox"
row_ok() { grep -F '| Agents that run in a sandbox (OpenHands, cloud agents) |' "$1" | grep -q 'setup script of the cloud environment' && ! grep -qF 'nothing of the harness reaches a sandbox' "$1"; }
row_ok "$ROOT/README.md" || fail "README.md row of the sandboxes"
sed 's/setup script of the cloud environment/pointer file/' "$ROOT/README.md" > "$SB/README.planted"
row_ok "$SB/README.planted" && fail "the planted README row passed"
echo "  the row is held, a planted row is refused"
