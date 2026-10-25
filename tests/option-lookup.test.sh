#!/usr/bin/env bash
# How a board's single-select options are matched, and what a name that matches nothing costs.
#
#   bash test/option-lookup.test.sh
#
# Nothing reaches a real board: the fields cache is written by hand, so `option_id` reads it without
# ever asking github.com, and `gh` is not needed at all for the two lookups.
#
# TWO PROPERTIES, and the platform paid for both before they were held here.
#
# THE NAME IS MATCHED WITHOUT CASE. A board spells its options however whoever made it typed them,
# and issue-new carries `ready` as its default while a board may say `Ready`. Matched with case,
# that default would never resolve, and every issue the tooling created would land with no status.
#
# A NAME THAT MATCHES NOTHING STOPS THE SCRIPT. `die` inside `$( )` exits the substitution and
# nothing else, so a refused option printed its error, left an EMPTY value behind, and the mutation
# went ahead with it: a person read the tool's own error, then a second one from gh about an id
# belonging to no field, and the script exited 0. A caller reading that status was told the card had
# moved.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
export HOME="$WORK/home" AI_CORE_HOME="$WORK/ai-core-home"
mkdir -p "$HOME" "$AI_CORE_HOME"
export GH_CACHE_DIRECTORY="$WORK/cache"
export GH_ORG=example-org
PROJECT_NUMBER=999998
failed=0

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}

. "$ROOT/lib/board.sh"
PROJECT="$PROJECT_NUMBER"
PROJECT_ORG="$GH_ORG"

# The cache the lookups read, written directly. The option names are this organisation's own,
# lower-case, which is the whole reason the first property matters.
mkdir -p "$GH_CACHE_DIRECTORY/$PROJECT_NUMBER"
cat > "$GH_CACHE_DIRECTORY/$PROJECT_NUMBER/fields.tsv" <<'EOF'
Status	PVTSSF_status	backlog	OPT_backlog
Status	PVTSSF_status	todo	OPT_todo
Status	PVTSSF_status	implementing	OPT_implementing
Status	PVTSSF_status	testing	OPT_testing
Status	PVTSSF_status	done	OPT_done
Priority	PVTSSF_priority	P1	OPT_p1
EOF

# A name the cache does not know reads the board once more, so every gh of this test is a
# stand-in: it answers the fields query from $WORK/board.tsv, the board as it is, and records any
# other call as the mutation it would be.
printf '%s\n' PVT_test > "$GH_CACHE_DIRECTORY/$PROJECT_NUMBER/project-id"
cp "$GH_CACHE_DIRECTORY/$PROJECT_NUMBER/fields.tsv" "$WORK/board.tsv"
FAKE="$WORK/fake"
mkdir -p "$FAKE/bin"
cat > "$FAKE/bin/gh" <<EOF
#!/usr/bin/env bash
if [ "\$1 \$2" = "repo view" ] && [ "\${4-} \${5-}" = "--json isPrivate" ]; then echo '{"isPrivate":false}'; exit 0; fi
case "\$*" in
  *"fields(first:50)"*) cat "$WORK/board.tsv"; echo read >> "$FAKE/board-reads" ;;
  *"repo view"*|"api repos/{owner}/{repo} --jq .full_name"*) exit 1 ;;
  *) echo "the mutation ran" >> "$FAKE/reached" ;;
esac
exit 0
EOF
chmod +x "$FAKE/bin/gh"
export PATH="$FAKE/bin:$PATH"

echo 'the option a name resolves to'

check 'the name as the board spells it'      OPT_todo "$(option_id Status todo)"
check 'the same name capitalised'            OPT_todo "$(option_id Status Todo)"
check 'and shouted'                          OPT_todo "$(option_id Status TODO)"
check 'a longer one, capitalised'            OPT_implementing "$(option_id Status Implementing)"
check 'the field name too'                   OPT_todo "$(option_id status todo)"
check 'a value that is already upper-case'   OPT_p1   "$(option_id Priority p1)"

echo
echo 'a name that matches nothing'

# The substitution is what swallows the refusal, so the exit status is taken from an
# assignment exactly as set_select takes it.
refusal="$( { option_id Status Invented; } 2>&1 )" && resolved=yes || resolved=no
check 'does not resolve'                     no  "$resolved"
check 'says which option was asked for'      yes "$(case "$refusal" in *Invented*) echo yes ;; *) echo no ;; esac)"
check 'and names every one there is'         yes "$(case "$refusal" in *"backlog todo implementing testing done"*) echo yes ;; *) echo no ;; esac)"

# WHAT set_select ITSELF DOES WITH IT, driven through the real function rather than through a
# rebuilt copy of its shape — a first version of this case wrote the `|| exit 1` chain out here and
# stayed green when the library's was taken away, which proves the test and not the tool.
#
# `gh` is a stand-in that succeeds and records the call, so a resolution that was swallowed would
# reach the mutation and leave a line behind. Nothing does, and the script stops with 1.
: > "$FAKE/reached"
outcome="$( PATH="$FAKE/bin:$PATH"; ( set_select PVTI_something Status Invented ) 2>/dev/null; echo "exit=$?" )"
check 'set_select stops rather than mutating' "exit=1" "$outcome"
check 'and nothing reached the board'        no "$([ -s "$FAKE/reached" ] && echo yes || echo no)"

# The innocent case, or the two above pass for a function that never works at all.
rm -f "$FAKE/reached"
ok="$( PATH="$FAKE/bin:$PATH"; ( set_select PVTI_something Status Todo ) 2>/dev/null; echo "exit=$?" )"
check 'a resolvable option does mutate'      "exit=0" "$ok"
check 'and the board was reached'            yes "$([ -s "$FAKE/reached" ] && echo yes || echo no)"

echo
echo 'a cache written before the board gained an option'

# The board has `ready` now; the cache was written before. The lookup reads the board once, finds
# it, and the cache holds it afterwards. The name nobody has costs that one read and is refused.
printf 'Status\tPVTSSF_status\tready\tOPT_ready\n' >> "$WORK/board.tsv"
: > "$FAKE/board-reads"
check 'the new option resolves'               OPT_ready "$(option_id Status ready)"
check 'after one read of the board'           1 "$(wc -l < "$FAKE/board-reads" | tr -d ' ')"
check 'and the cache holds it now'            yes "$(grep -q 'OPT_ready' "$GH_CACHE_DIRECTORY/$PROJECT_NUMBER/fields.tsv" && echo yes || echo no)"
check 'a known option reads no board'         OPT_todo "$(option_id Status todo)"
check 'still one read'                        1 "$(wc -l < "$FAKE/board-reads" | tr -d ' ')"
printf 'Priority\tPVTSSF_priority\tP1\tOPT_p1\n' > "$GH_CACHE_DIRECTORY/$PROJECT_NUMBER/fields.tsv"
check 'a field the cache lacks resolves too'  PVTSSF_status "$(field_id Status)"

echo
echo 'a cache older than an hour'

printf 'Status\tPVTSSF_status\ttodo\tOPT_todo\n' > "$GH_CACHE_DIRECTORY/$PROJECT_NUMBER/fields.tsv"
touch -d "@$(( $(date +%s) - 3660 ))" "$GH_CACHE_DIRECTORY/$PROJECT_NUMBER/fields.tsv"
check 'is read again'                         yes "$(fields_tsv | grep -q OPT_ready && echo yes || echo no)"
printf 'Status\tPVTSSF_status\ttodo\tOPT_todo\n' > "$GH_CACHE_DIRECTORY/$PROJECT_NUMBER/fields.tsv"
check 'one within the hour is not'            no "$(fields_tsv | grep -q OPT_ready && echo yes || echo no)"

echo
echo 'a large cache with the wanted row first'
printf 'Status\tPVTSSF_status\ttodo\tOPT_todo\n' > "$GH_CACHE_DIRECTORY/$PROJECT_NUMBER/fields.tsv"
for ((i = 1; i <= 5000; i++)); do
  printf 'Extra%s\tFIELD_%s\toption%s\tOPTION_%s\n' "$i" "$i" "$i" "$i"
done >> "$GH_CACHE_DIRECTORY/$PROJECT_NUMBER/fields.tsv"

for signal in default ignored; do
  for lookup in option_id field_id; do
    # Bash cannot reset SIGPIPE if it was already ignored when Bash started.
    if output="$(ROOT="$ROOT" GH_CACHE_DIRECTORY="$GH_CACHE_DIRECTORY" env --default-signal=PIPE bash -c '
      . "$ROOT/lib/board.sh"
      PROJECT=999998
      PROJECT_ORG=example-org
      if [ "$1" = ignored ]; then trap "" PIPE; else trap - PIPE; fi
      if [ "$2" = option_id ]; then option_id Status todo; else field_id Status; fi
    ' _ "$signal" "$lookup" 2> "$WORK/lookup.err")"; then rc=0; else rc=$?; fi
    check "$lookup with SIGPIPE $signal exits cleanly" 0 "$rc"
    if [ "$lookup" = option_id ]; then want=OPT_todo; else want=PVTSSF_status; fi
    check "$lookup with SIGPIPE $signal returns the first id" "$want" "$output"
    check "$lookup with SIGPIPE $signal has no error" '' "$(cat "$WORK/lookup.err")"
  done
done

echo
echo 'Plane lookups preserve a later parse error after the wanted row'
plane_cache="$WORK/plane-cache"; mkdir -p "$plane_cache"
plane_lookup() {
  bash -euo pipefail -c '
    . "$1/lib/plane/tracker.sh"
    fixture="$2"; shift 2
    carry_dir() { printf "%s\n" "$fixture"; }
    plane_states() { cat "$fixture/states.jsonl"; }
    plane_pages() { cat "$fixture/labels.jsonl"; }
    plane_setting() { echo fixture; }
    plane_project_uuid() { echo fixture; }
    "$@"
  ' _ "$ROOT" "$plane_cache" "$@"
}
for invocation in 'carry_state_id status ready' 'carry_state_id cancelled' 'carry_state_id default' \
                  'carry_label_id ready' 'plane_state_id ready' 'plane_state_id group:unstarted' 'plane_label_ids ready'; do
  read -r -a arguments <<< "$invocation"
  group=unstarted; [ "$invocation" != 'carry_state_id cancelled' ] || group=cancelled
  printf '{"name":"ready","group":"%s","default":true,"id":"first"}\n' "$group" > "$plane_cache/states.jsonl"
  printf '{"name":"ready","group":"%s","default":true,"id":"second"}\n' "$group" >> "$plane_cache/states.jsonl"
  cp "$plane_cache/states.jsonl" "$plane_cache/labels.jsonl"
  if output="$(plane_lookup "${arguments[@]}" 2> "$WORK/plane.err")"; then rc=0; else rc=$?; fi
  want=first; [ "$invocation" != 'plane_label_ids ready' ] || want='["first"]'
  check "$invocation returns the first match" "$want" "$output"
  check "$invocation exits cleanly" 0 "$rc"
  check "$invocation has no error" '' "$(cat "$WORK/plane.err")"
  printf '{broken\n' >> "$plane_cache/states.jsonl"
  cp "$plane_cache/states.jsonl" "$plane_cache/labels.jsonl"
  if output="$(plane_lookup "${arguments[@]}" 2> "$WORK/plane.err")"; then rc=0; else rc=$?; fi
  check "$invocation refuses the truncated cache" yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
  check "$invocation keeps the parse error visible" yes "$(grep -qi 'parse error' "$WORK/plane.err" && echo yes || echo no)"
done
if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo; echo 'all passed'
