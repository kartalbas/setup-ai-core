#!/usr/bin/env bash
# What the tests of the `command` environments (tests/status-sync.test.sh, tests/status.test.sh) can tell: each rule of the
# release by a reader is planted as a defect in a copy of the tree, and the test that holds the rule must turn red on that
# copy, naming the assertion. A rule whose planted defect leaves every assertion green is a rule nothing checks.
#
#   bash tests/status-defects.test.sh

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
failed=0
jobs_at_once="${CHECK_JOBS:-6}"

# the defects: <name>|<file>|<sed expression>|<the test that holds the rule>|<words of the assertion that must turn red>
DEFECTS="$W/defects.tsv"
{
  printf '%s\t' 'a command environment is read as a tag glob, so a stale tag of the repository decides'
  printf '%s\t' bin/status-sync.sh 's/elif \[ "\$pattern" = command \]; then/elif [ "$pattern" = command-never ]; then/'
  printf '%s\t%s\n' status-sync.test.sh 'proven after the delivery of the carrier release'
  printf '%s\t' 'the delivery is the tip of the default branch, not what the reader answered'
  printf '%s\t' bin/status-sync.sh 's/merge-base --is-ancestor "\$commit" "\$REL_DELIVERED"/merge-base --is-ancestor "$commit" "$REL_REF"/'
  printf '%s\t%s\n' status-sync.test.sh 'landed after the pinned commit'
  printf '%s\t' 'the time of a proof is not compared with the delivery and the landing'
  printf '%s\t' bin/status-sync.sh 's/\[ "\$word" = "\$environment" \] \&\& instant_after "\$at" "\$3" \&\& instant_after "\$at" "\$4" \&\& return 0/[ "$word" = "$environment" ] \&\& return 0/'
  printf '%s\t%s\n' status-sync.test.sh 'has no proof that qualifies'
  printf '%s\t' 'the environment of a proof is compared with its case'
  printf '%s\t' bin/status-sync.sh "s/word=\"\$(printf '%s' \"\${proof#\*=}\" | tr '\[:upper:\]' '\[:lower:\]')\"/word=\"\${proof#*=}\"/"
  printf '%s\t%s\n' status-sync.test.sh 'the environment of the proof is read whatever its case'
  printf '%s\t' 'the environment of a proof is a prefix match'
  printf '%s\t' bin/status-sync.sh 's/\[ "\$word" = "\$environment" \] \&\&/[ "${word#"$environment"}" != "$word" ] \&\&/'
  printf '%s\t%s\n' status-sync.test.sh 'has no proof that qualifies'
  printf '%s\t' 'one repository is given the delivery another one was answered'
  printf '%s\t' bin/status-sync.sh '/_DELIVERIES")/s/tolower(\$1) == tolower(r)/1/'
  printf '%s\t%s\n' status-sync.test.sh 'a successful run of the commit'
  printf '%s\t' 'a fetch that failed is ignored, and the commits of the refs the clone had are compared'
  printf '%s\t' bin/status-sync.sh '/\[ -z "\$fetch_failed" \] || REL_ERROR=/d'
  printf '%s\t%s\n' status-sync.test.sh 'a fetch that fails leaves the delivery unread'
  printf '%s\t' 'the project folder'"'"'s command is run as the reader of a clone that declared none, by status-sync'
  printf '%s\t' bin/status-sync.sh '/^      \[ -z "\$from_folder" \] || REL_ERROR=/d'
  printf '%s\t%s\n' status-sync.test.sh 'a command of the folder'"'"'s list is no reader of a clone that declares none'
  printf '%s\t' 'a reader that failed is no error: the card is read as undelivered'
  printf '%s\t' bin/status-sync.sh 's/if \[ "\$REL_COMMAND" = 1 \] \&\& \[ -n "\$REL_ERROR" \]; then/if false; then/'
  printf '%s\t%s\n' status-sync.test.sh 'a reader that fails is unknown'
  printf '%s\t' 'the author of a record is not judged'
  printf '%s\t' lib/board.sh 's/^def trusted: select(.*$/def trusted: select(true);/'
  printf '%s\t%s\n' status-sync.test.sh 'a record by a stranger is no record'
  printf '%s\t' 'the last 50 comments are cut after the authors are judged'
  printf '%s\t' bin/status.sh 's/\[\.comments | \.\[(0 - \$window):\] | \.\[\] | trusted\] | selected_landing/[.comments | .[] | trusted] | .[(0 - $window):] | selected_landing/'
  printf '%s\t%s\n' status.test.sh 'no comment, a stranger'
  printf '%s\t' 'the testing file is not handed to Node'
  printf '%s\t' bin/status.sh 's/testing_file=(--testing-file "\$work\/testing")/testing_file=()/'
  printf '%s\t%s\n' status.test.sh 'the header: live buckets'
  printf '%s\t' 'a clone that declares command is read by the project folder'"'"'s list as every other'
  printf '%s\t' lib/status-live.mjs 's/if (declared \&\& namesCommand(declared.envs)) {/if (false) {/'
  printf '%s\t%s\n' status.test.sh 'the header: live buckets'
  printf '%s\t' 'the live counts are by position only'
  printf '%s\t' lib/status-live.mjs 's/l.where.env === env.name \&\& (l.where.n === 0) === (n === 0)/l.where.n === n/'
  printf '%s\t%s\n' status.test.sh 'the header: live buckets'
  printf '%s\t' 'the own full reference of a message body is not a reference'
  printf '%s\t' lib/status-live.mjs 's/named(record.pattern, /named(`(^|[^A-Za-z0-9._\/-])#${record.number}([^0-9]|$)`, /'
  printf '%s\t%s\n' status.test.sh 'the own full reference and the bare reference'
  printf '%s\t' 'a card whose landing could not be read is counted as not live'
  printf '%s\t' lib/status-live.mjs "s/if (record.context === 'failed') return result('unknown', { reason: record.reason });/if (record.context === 'failed') return result('notLive');/"
  printf '%s\t%s\n' status.test.sh 'each refusal is named with the card'
  printf '%s\t' 'an unknown card leaves the exit status at 0 on the page without agents'
  printf '%s\t' lib/status.mjs 's/process.exitCode = unknownCards ? 1 : 0;/process.exitCode = 0;/'
  printf '%s\t%s\n' status.test.sh 'exit 1: a card could not be read'
  printf '%s\t' 'an unknown card leaves the exit status at 0 where agents run'
  printf '%s\t' lib/status.mjs 's/process.exit(unknownCards ? 1 : 0)/process.exit(0)/'
  printf '%s\t%s\n' status.test.sh 'exit 1 beside the agents'
  printf '%s\t' 'the project folder'"'"'s own command is run as the reader of a clone that declared none'
  printf '%s\t' lib/status-live.mjs 's/if (!command) {/if (false) {/'
  printf '%s\t%s\n' status.test.sh 'the card is unknown, and the missing declaration is named'
  printf '%s\t' 'a folder whose name begins with the project folder'"'"'s is counted as the project folder'
  printf '%s\t' lib/status.mjs 's/cwd === folder || cwd.startsWith(folder + path.sep)/cwd.startsWith(folder)/'
  printf '%s\t%s\n' status-usage.test.sh 'a sibling folder is not counted'
  printf '%s\t' 'a transcript that shrank keeps the counts of its old content'
  printf '%s\t' lib/status.mjs 's/ \&\& st.size >= cache\[f\].off//'
  printf '%s\t%s\n' status-usage.test.sh 'a truncated transcript is counted anew'
  printf '%s\t' 'a transcript that was replaced by a longer one keeps the counts of the old file'
  printf '%s\t' lib/status.mjs 's/cache\[f\].ino === st.ino \&\& //'
  printf '%s\t%s\n' status-usage.test.sh 'a replaced transcript is counted anew'
  printf '%s\t' 'the token cache is rewritten in place, where a run reading it at the same time sees half of it'
  printf '%s\t' lib/status.mjs 's/fs.writeFileSync(temporary, JSON.stringify(kept));/fs.writeFileSync(cacheFile, JSON.stringify(kept));/'
  printf '%s\t%s\n' status-usage.test.sh 'the cache is replaced whole'
  printf '%s\t' 'the tokens of Claude Code are shown in the shell of another tool'
  printf '%s\t' lib/status.mjs "s/const fromClaude = usage.tool === 'claude';/const fromClaude = true;/"
  printf '%s\t%s\n' status-usage.test.sh 'the tokens have no source for Codex'
  printf '%s\t' 'the tool of the shell is not asked, so every page reads the windows of Claude'
  printf '%s\t' bin/status.sh 's/^tool="\$(session_tool)"; \[ -n "\$tool" \] || tool=claude$/tool=claude/'
  printf '%s\t%s\n' status.test.sh 'the usage line is Codex'"'"'s, with the time of its record'
} > "$DEFECTS"

# red_at <output of a test> <words of an assertion>: whether a FAIL line of the output names the assertion. The FAIL
# lines are held in a variable first: grep -q stops at its first match, and a grep that still writes into that pipe
# after it is killed by SIGPIPE, which pipefail reads as no match.
red_at() {
  local failures
  failures="$(grep 'FAIL' <<< "$1")"
  grep -qF -- "$2" <<< "$failures"
}

run_defect() {  # run_defect <index> <name> <file> <sed expression> <test> <assertion>: the verdict goes to $W/verdict.<index>
  local k="$1" name="$2" file="$3" expression="$4" test="$5" assertion="$6" copy="$W/tree.$1" out
  mkdir -p "$copy/tests"
  cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/templates" "$ROOT/VERSION" "$copy/"
  cp "$ROOT/tests/$test" "$ROOT/tests/tool-environment.sh" "$copy/tests/"
  sed -i.bak "$expression" "$copy/$file"
  if cmp -s "$ROOT/$file" "$copy/$file"; then echo "FAIL the defect '$name' did not change $file" > "$W/verdict.$k"; return; fi
  out="$(cd "$copy" && . tests/tool-environment.sh && GH_ORG=example-org CODEX_HOME=/nonexistent/codex-home bash "tests/$test" 2>&1)" && {
    echo "FAIL $test stays green on: $name" > "$W/verdict.$k"; return; }
  if red_at "$out" "$assertion"; then echo "ok   $test is red on: $name" > "$W/verdict.$k"
  else echo "FAIL $test is red on: $name, but not at '$assertion': $(grep -m3 'FAIL' <<< "$out" | tr '\n' '|')" > "$W/verdict.$k"; fi
}

echo 'the verdict on a long output: the assertion that turned red is found whatever the output holds'
many="$(printf '  FAIL the first assertion\n'; for n in $(seq 1 20000); do printf '  FAIL assertion number %s of a defect that breaks the whole page\n' "$n"; done)"
if ! red_at "$many" 'the first assertion'; then echo "  FAIL a red assertion in a long output is not found"; failed=$((failed + 1))
elif red_at "$many" 'an assertion nobody wrote'; then echo "  FAIL an assertion that did not turn red is found"; failed=$((failed + 1))
else echo '  ok   found in a long output, and not found where it is not there'; fi

echo 'each rule of a release read by a command is planted as a defect, and the test that holds it must turn red there'
k=0; running=0
while IFS=$'\t' read -r name file expression test assertion; do
  [ -n "$name" ] || continue
  k=$((k + 1))
  run_defect "$k" "$name" "$file" "$expression" "$test" "$assertion" &
  running=$((running + 1))
  if [ "$running" -ge "$jobs_at_once" ]; then
    if wait -n 2>/dev/null; then running=$((running - 1)); else wait; running=0; fi
  fi
done < "$DEFECTS"
wait
for i in $(seq 1 "$k"); do
  cat "$W/verdict.$i"
  case "$(cat "$W/verdict.$i")" in ok*) ;; *) failed=$((failed + 1)) ;; esac
done

echo
if [ "$failed" -gt 0 ]; then echo "$failed failed"; exit 1; fi
echo 'all passed'
