#!/usr/bin/env bash
# What issue-comment.sh sends GitHub, inline and from a file.
#
# Run with a FAKE gh on PATH, so nothing is commented and every call is recorded instead.
# The contract lives in the recorded call: the comment goes over REST, not GraphQL, so a rate
# limit on GraphQL cannot lose it; an inline body travels as -f body=, a file as -F body=@file so
# no shell reads its backticks and newlines on the way, and a call naming both or neither stops
# before GitHub is reached.
#
#   bash test/issue-comment.test.sh

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fake="$(mktemp -d)"
trap 'rm -rf "$fake"' EXIT
log="$fake/calls.txt"

cat > "$fake/gh" <<EOF
#!/usr/bin/env bash
if [ "\$1 \$2" = "repo view" ] && [ "\${4-} \${5-}" = "--json isPrivate" ]; then echo '{"isPrivate":false}'; exit 0; fi
printf '%s\n' "\$*" >> "$log"
for a in "\$@"; do case "\$a" in body=@*) cp "\${a#body=@}" "$fake/sent-body" ;; esac; done
if [ "\$*" = "api repos/{owner}/{repo} --jq .full_name" ]; then echo 'example-org/example-repo'; exit 0; fi
if [ "\$1" = "repo" ]; then echo 'example-org/example-repo'; exit 0; fi
echo 'https://github.com/example-org/example-repo/issues/94#issuecomment-1'
exit 0
EOF
chmod +x "$fake/gh"
export PATH="$fake:$PATH"
export AI_CORE_SLEEP=true   # the waits of a refused call take no time here

failed=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}

comment="$root/bin/issue-comment.sh"
repo='example-org/example-repo'
body_file="$fake/comment.md"
printf 'A body with a `backtick` in it.\n' > "$body_file"

echo 'an inline body travels as a field of the REST call'
: > "$log"
"$comment" "$repo" 94 'Comment here' >/dev/null 2>&1
check 'the whole call' "api repos/$repo/issues/94/comments -f body=Comment here --jq .html_url" "$(cat "$log")"

echo 'a file travels as -F body=@file, never as its content'
: > "$log"
"$comment" "$repo" 94 --body-file "$body_file" >/dev/null 2>&1
check 'the flag'            yes "$(grep -q -- '-F body=@' "$log" && echo yes || echo no)"
check 'a snapshot is sent'  no "$(grep -qF -- "-F body=@$body_file" "$log" && echo yes || echo no)"
check 'the snapshot bytes'  yes "$(cmp -s "$body_file" "$fake/sent-body" && echo yes || echo no)"
check 'the issue and repo'  yes "$(grep -q "api repos/$repo/issues/94/comments" "$log" && echo yes || echo no)"
check 'no inline body'      no  "$(grep -q -- '-f body=' "$log" && echo yes || echo no)"

echo 'what gh prints is what the caller gets'
out="$("$comment" "$repo" 94 --body-file "$body_file" 2>/dev/null)"
check 'the comment url' 'https://github.com/example-org/example-repo/issues/94#issuecomment-1' "$out"

echo 'the repo resolves from the checkout when left out'
: > "$log"
"$comment" 94 --body-file "$body_file" >/dev/null 2>&1
check 'default repo' yes "$(grep -q -- "repos/$repo/issues/94/comments" "$log" && echo yes || echo no)"

: > "$log"
"$comment" 94 'Comment here' >/dev/null 2>&1
check 'default repo, inline' yes "$(grep -q -- "repos/$repo/issues/94/comments" "$log" && echo yes || echo no)"

echo 'an unusable call stops before GitHub is reached'
for name in 'no body at all' 'both a body and a file' 'a file that is not there'; do
  : > "$log"
  case "$name" in
    'no body at all')          "$comment" "$repo" 94 >/dev/null 2>&1 ;;
    'both a body and a file')  "$comment" "$repo" 94 'Comment here' --body-file "$body_file" >/dev/null 2>&1 ;;
    'a file that is not there') "$comment" "$repo" 94 --body-file "$fake/nope.md" >/dev/null 2>&1 ;;
  esac
  rc=$?
  check "$name: exits nonzero"   yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
  check "$name: nothing sent"    0   "$(grep -c . "$log" || true)"
done

out="$("$comment" "$repo" 94 --body-file "$fake/nope.md" 2>&1)"
check 'the missing file is named' yes "$(grep -q 'does not exist' <<< "$out" && echo yes || echo no)"

# --body-file with nothing after it would leave the path empty and let `shift 2` end the run
# with no word at all; need_value is what turns that into a sentence.
echo 'a flag without its value is named'
out="$("$comment" "$repo" 94 --body-file 2>&1)"; rc=$?
check 'exits nonzero'  yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'names the flag' yes "$(grep -q -- '--body-file needs a value' <<< "$out" && echo yes || echo no)"

echo 'a refused post stops the run rather than printing nothing and exiting zero'
refusing="$fake/refusing"
mkdir -p "$refusing"
cat > "$refusing/gh" <<'NO'
#!/usr/bin/env bash
if [ "$1 $2" = "repo view" ] && [ "${4-} ${5-}" = "--json isPrivate" ]; then echo '{"isPrivate":false}'; exit 0; fi
if [ "$*" = "api repos/{owner}/{repo} --jq .full_name" ]; then echo 'example-org/example-repo'; exit 0; fi
if [ "$1" = "repo" ]; then echo 'example-org/example-repo'; exit 0; fi
echo '{"message":"Issue is locked"}'
echo 'gh: HTTP 403' >&2
exit 1
NO
chmod +x "$refusing/gh"
out="$(PATH="$refusing:$PATH" "$comment" "$repo" 94 --body-file "$body_file" 2>&1)"; rc=$?
check 'exits nonzero'    yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'and says the comment was not posted' yes "$(grep -q 'the comment on example-org/example-repo#94 was NOT posted - GitHub refused it (HTTP 403)' <<< "$out" && echo yes || echo no)"
check 'with GitHub'"'"'s own words' yes "$(grep -q 'Issue is locked' <<< "$out" && echo yes || echo no)"
check 'and never that it could not read it' no "$(grep -q 'cannot read' <<< "$out" && echo yes || echo no)"

echo 'a GraphQL refusal by a rate limit does not lose the comment'
limited="$fake/limited"
mkdir -p "$limited"
cat > "$limited/gh" <<'NO'
#!/usr/bin/env bash
if [ "$1 $2" = "repo view" ] && [ "${4-} ${5-}" = "--json isPrivate" ]; then echo '{"isPrivate":false}'; exit 0; fi
printf '%s\n' "$*" >> "$LIMITED_LOG"
case "$*" in
  *graphql*|"issue comment"*|"repo view"*)
    echo '{"message":"API rate limit already exceeded for user ID 1."}'
    echo 'gh: API rate limit already exceeded for user ID 1. (HTTP 403)' >&2
    exit 1 ;;
  "api repos/{owner}/{repo} --jq .full_name") echo 'example-org/example-repo'; exit 0 ;;
  "api repos/"*"/comments "*) echo 'https://github.com/example-org/example-repo/issues/94#issuecomment-2'; exit 0 ;;
esac
echo "the stand-in gh has no answer for: $*" >&2; exit 9
NO
chmod +x "$limited/gh"
export LIMITED_LOG="$fake/limited.log"; : > "$LIMITED_LOG"
out="$(PATH="$limited:$PATH" "$comment" "$repo" 94 --body-file "$body_file" 2>&1)"; rc=$?
check 'exits zero'          0 "$rc"
check 'the comment url'     'https://github.com/example-org/example-repo/issues/94#issuecomment-2' "$out"
check 'GraphQL never asked' 0 "$(grep -c 'graphql\|issue comment' "$LIMITED_LOG" || true)"
out="$(PATH="$limited:$PATH" "$comment" "$repo" 94 'Inline words' 2>&1)"; rc=$?
check 'inline: exits zero'  0 "$rc"
# the repository named by the checkout, not by the caller: resolved over REST as well
out="$(PATH="$limited:$PATH" "$comment" 94 'Inline words' 2>&1)"; rc=$?
check 'without a repo: exits zero' 0 "$rc"
check 'without a repo: GraphQL never asked' 0 "$(grep -c 'graphql\|issue comment\|repo view' "$LIMITED_LOG" || true)"

# The posting command of the shipped plan brief, filled as a coordinator fills it: the plan issue as
# the repository and the number the brief asks for, or as the one OWNER/REPO#NUMBER reference.
brief="$root/skills/person-in-charge/briefs/plan.md"
mkdir -p "$fake/home" "$fake/ai-core-home" "$fake/core-bin"
printf '#!/usr/bin/env bash\nexec bash "%s/bin/ai-core" "$@"\n' "$root" > "$fake/core-bin/ai-core"
chmod +x "$fake/core-bin/ai-core"
filled_command() {   # BRIEF FILE
  sed -n 's/.*`\(ai-core issue-comment [^`]*\)`.*/\1/p' "$1" | head -n 1 \
    | sed -e "s|{{plan issue repository}}|$repo|g" -e 's|{{plan issue number}}|94|g' \
          -e "s|{{plan issue reference}}|$repo#94|g" -e "s|{{plan issue}}|$repo#94|g" -e "s|<file>|$2|g"
}
run_filled() {   # BRIEF FILE: the filled command, run the way the session runs it
  local command; command="$(filled_command "$1" "$2")"
  case "$command" in *'{{'*) echo "an unfilled placeholder: $command" >&2; return 2 ;; esac
  # shellcheck disable=SC2086
  PATH="$fake/core-bin:$PATH" HOME="$fake/home" AI_CORE_HOME="$fake/ai-core-home" bash -c "cd '$fake' && $command"
}

echo 'the plan brief as shipped posts without a usage error'
printf 'A section of a plan.\n' > "$fake/section.md"
: > "$log"
out="$(run_filled "$brief" "$fake/section.md" 2>&1)"; rc=$?
check 'exits zero'          0 "$rc"
check 'the comment url'     'https://github.com/example-org/example-repo/issues/94#issuecomment-1' "$out"
check 'one post to the plan issue' "api repos/$repo/issues/94/comments -F body=@$fake/section.md --jq .html_url" \
  "$(grep -v '^api repos/{owner}' "$log" | sed "s|body=@[^ ]*|body=@$fake/section.md|")"
check 'the exact body bytes' yes "$(cmp -s "$fake/section.md" "$fake/sent-body" && echo yes || echo no)"

echo 'the joined placeholder of the old brief is refused, and the planted copy is red'
sed 's|{{plan issue repository}} {{plan issue number}}|{{plan issue}}|' "$brief" > "$fake/old-brief.md"
check 'the planted copy differs' yes "$(cmp -s "$brief" "$fake/old-brief.md" && echo no || echo yes)"
: > "$log"
out="$(run_filled "$fake/old-brief.md" "$fake/section.md" 2>&1)"; rc=$?
check 'the old brief: exits nonzero' yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'the old brief: the usage line' yes "$(grep -q 'usage: issue-comment.sh' <<< "$out" && echo yes || echo no)"
check 'the old brief: nothing sent'  0 "$(grep -c 'comments' "$log" || true)"

echo 'a malformed plan issue is refused before GitHub is reached'
for bad in "$repo#94" "$repo 9x" "$repo #94" "$repo 94 extra"; do
  : > "$log"
  "$comment" $bad --body-file "$fake/section.md" >/dev/null 2>&1; rc=$?
  check "'$bad': exits nonzero" yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
  check "'$bad': nothing sent"  0 "$(grep -c 'comments' "$log" || true)"
done

echo 'two filled commands with different bodies each deliver their own bytes once'
concurrent="$fake/concurrent"
mkdir -p "$concurrent"
cat > "$concurrent/gh" <<'NO'
#!/usr/bin/env bash
if [ "$1 $2" = "repo view" ] && [ "${4-} ${5-}" = "--json isPrivate" ]; then echo '{"isPrivate":false}'; exit 0; fi
for a in "$@"; do case "$a" in body=@*) sum="$(cksum < "${a#body=@}" | cut -d' ' -f1)"; cp "${a#body=@}" "$STORE/sent-$sum"; echo "https://github.com/example-org/example-repo/issues/94#issuecomment-$sum"; exit 0 ;; esac; done
echo "the stand-in gh has no answer for: $*" >&2; exit 9
NO
chmod +x "$concurrent/gh"
export STORE="$fake/store"; mkdir -p "$STORE"
printf 'The first planner section.\n'  > "$fake/section-a.md"
printf 'The second planner section.\n' > "$fake/section-b.md"
PATH="$concurrent:$PATH" run_filled "$brief" "$fake/section-a.md" > "$fake/out-a" 2>&1 &
pid_a=$!
PATH="$concurrent:$PATH" run_filled "$brief" "$fake/section-b.md" > "$fake/out-b" 2>&1 &
pid_b=$!
wait "$pid_a"; rc_a=$?; wait "$pid_b"; rc_b=$?
sum_a="$(cksum < "$fake/section-a.md" | cut -d' ' -f1)"; sum_b="$(cksum < "$fake/section-b.md" | cut -d' ' -f1)"
check 'both exit zero'      '0 0' "$rc_a $rc_b"
check 'two bodies stored'   2 "$(find "$STORE" -type f | grep -c .)"
check 'first body bytes'    yes "$(cmp -s "$fake/section-a.md" "$STORE/sent-$sum_a" && echo yes || echo no)"
check 'second body bytes'   yes "$(cmp -s "$fake/section-b.md" "$STORE/sent-$sum_b" && echo yes || echo no)"
check 'first gets its own url'  "https://github.com/example-org/example-repo/issues/94#issuecomment-$sum_a" "$(cat "$fake/out-a")"
check 'second gets its own url' "https://github.com/example-org/example-repo/issues/94#issuecomment-$sum_b" "$(cat "$fake/out-b")"

echo 'the same command twice is two requested comments'
rm -f "$STORE"/sent-*; : > "$fake/posts"
cat > "$concurrent/gh" <<'NO'
#!/usr/bin/env bash
if [ "$1 $2" = "repo view" ] && [ "${4-} ${5-}" = "--json isPrivate" ]; then echo '{"isPrivate":false}'; exit 0; fi
case "$*" in *"/comments "*) echo post >> "$STORE/posts"; echo 'https://github.com/example-org/example-repo/issues/94#issuecomment-7'; exit 0 ;; esac
echo "the stand-in gh has no answer for: $*" >&2; exit 9
NO
for _ in 1 2; do PATH="$concurrent:$PATH" run_filled "$brief" "$fake/section-a.md" >/dev/null 2>&1; done
check 'two posts' 2 "$(grep -c post "$STORE/posts")"


# THE CAP OF 2500 COMMENTS: GitHub refuses a comment on an issue that holds that many with HTTP 403, in words no rate limit
# uses, so the post is sent once and nothing waits. A lost answer is no refusal: the comment may be stored, so the outcome is
# unknown, and nothing is sent again. The stand-in keeps CAP_FREE slots; each post takes one atomically and a full issue
# refuses with the words GitHub gave on the recorded incident.
echo 'a comment on an issue at the cap is refused once, and a lost answer is not called a refusal'
capped="$fake/capped"; mkdir -p "$capped"
cat > "$capped/gh" <<'NO'
#!/usr/bin/env bash
if [ "$1 $2" = "repo view" ] && [ "${4-} ${5-}" = "--json isPrivate" ]; then echo '{"isPrivate":false}'; exit 0; fi
case "$*" in
  "api repos/{owner}/{repo} --jq .full_name") echo 'example-org/example-repo'; exit 0 ;;
  *'/comments '*body*)
    echo post >> "$CAP_STATE/posts"
    for a in "$@"; do case "$a" in body=@*) text="$(cat "${a#body=@}")" ;; body=*) text="${a#body=}" ;; esac; done
    for n in $(seq 1 "${CAP_FREE:-0}"); do
      if mkdir "$CAP_STATE/slot-$n" 2>/dev/null; then
        printf '%s' "$text" > "$CAP_STATE/stored-$n"
        [ ! -e "$CAP_STATE/lose-answer" ] || { echo 'error connecting to api.github.com' >&2; exit 1; }
        echo "https://github.com/example-org/example-repo/issues/94#issuecomment-$n"; exit 0
      fi
    done
    echo '{"message":"Commenting is disabled on issues with more than 2500 comments","documentation_url":"https://docs.github.com/rest/issues/comments"}'
    echo 'gh: Commenting is disabled on issues with more than 2500 comments (HTTP 403)' >&2; exit 1 ;;
esac
echo "the stand-in gh has no answer for: $*" >&2; exit 9
NO
chmod +x "$capped/gh"
printf '#!/usr/bin/env bash\necho waited >> "$CAP_STATE/waits"\n' > "$capped/record-sleep"; chmod +x "$capped/record-sleep"
cap_reset() { rm -rf "$fake/cap-state"; mkdir -p "$fake/cap-state"; export CAP_STATE="$fake/cap-state" CAP_FREE="$1"; }
cap_comment() { PATH="$capped:$PATH" AI_CORE_SLEEP="$capped/record-sleep" "$@"; }
cap_count() { if [ -f "$CAP_STATE/$1" ]; then grep -c . "$CAP_STATE/$1"; else echo 0; fi; }

cap_reset 0
out="$(cap_comment "$comment" "$repo" 94 --body-file "$body_file" 2>&1)"; rc=$?
check 'the cap: exits 1'                   1 "$rc"
check 'it says the comment was not posted' yes "$(grep -q 'the comment on example-org/example-repo#94 was NOT posted' <<< "$out" && echo yes || echo no)"
check 'with GitHub'"'"'s status and words'  yes "$(grep -q '(HTTP 403)' <<< "$out" && grep -q 'Commenting is disabled on issues with more than 2500 comments' <<< "$out" && echo yes || echo no)"
check 'and never a read-back error'        no "$(grep -q 'cannot read' <<< "$out" && echo yes || echo no)"
check 'no success address on stdout'       '' "$(cap_comment "$comment" "$repo" 94 --body-file "$body_file" 2>/dev/null)"
check 'one post each of the two runs, and no wait' '2 0' "$(cap_count posts) $(cap_count waits)"

cap_reset 3; touch "$CAP_STATE/lose-answer"
out="$(cap_comment "$comment" "$repo" 94 'Inline words' 2>&1)"; rc=$?
check 'a lost answer: exits 1'             1 "$rc"
check 'it is not known whether it was posted' yes "$(grep -q 'it is not known whether the comment on example-org/example-repo#94 was posted' <<< "$out" && echo yes || echo no)"
check 'it never says nothing was posted'   no "$(grep -qi 'was NOT posted' <<< "$out" && echo yes || echo no)"
check 'one post, stored once, no wait'     '1 1 0' "$(cap_count posts) $(ls "$CAP_STATE" | grep -c '^stored-') $(cap_count waits)"

echo 'two posts that both saw room for one: one is stored, the other is refused, neither is sent again'
cap_reset 1
cap_comment "$comment" "$repo" 94 'First of two' > "$fake/race-a.out" 2> "$fake/race-a.err" & race_a=$!
cap_comment "$comment" "$repo" 94 'Second of two' > "$fake/race-b.out" 2> "$fake/race-b.err" & race_b=$!
wait "$race_a"; rc_a=$?; wait "$race_b"; rc_b=$?
check 'exactly one of the two succeeded'   '0 1' "$(printf '%s\n' "$rc_a" "$rc_b" | sort | paste -sd' ' -)"
check 'one comment stored, two posts, no wait' '1 2 0' "$(ls "$CAP_STATE" | grep -c '^stored-') $(cap_count posts) $(cap_count waits)"
winner="$fake/race-a"; [ "$rc_a" -eq 0 ] || winner="$fake/race-b"; loser="$fake/race-b"; [ "$rc_a" -eq 0 ] || loser="$fake/race-a"
check 'the winner returns its own address' 'https://github.com/example-org/example-repo/issues/94#issuecomment-1' "$(cat "$winner.out")"
check 'the loser reports the 403 and returns no address' '1 0' "$(grep -c 'HTTP 403' "$loser.err") $(grep -c . "$loser.out")"
echo 'two posts that each find a slot: both comments survive'
cap_reset 2
cap_comment "$comment" "$repo" 94 'First of two' > "$fake/race-a.out" 2>&1 & race_a=$!
cap_comment "$comment" "$repo" 94 'Second of two' > "$fake/race-b.out" 2>&1 & race_b=$!
wait "$race_a"; rc_a=$?; wait "$race_b"; rc_b=$?
check 'both succeed'                       '0 0' "$rc_a $rc_b"
check 'each stored its own body'           'First of two|Second of two' "$(for stored in "$CAP_STATE"/stored-*; do cat "$stored"; echo; done | sort | paste -sd'|' -)"
echo 'solution-path: a lost answer is reported as unconfirmed, not as not posted'
cap_reset 3; touch "$CAP_STATE/lose-answer"
cat > "$fake/path-sections.md" <<'NO'
## Where a person meets this
Somebody.
## What they see today
Something.
## What the system does behind it
A thing.
## The decision
None.
## Options
A.
## Recommendation
A.
## Code facts
None.
## Reuse manifest
None.
NO
out="$(cap_comment "$root/bin/solution-path.sh" 94 "$fake/path-sections.md" 2>&1)"; rc=$?
check 'it fails, and says it cannot be confirmed' '1 yes' "$rc $(grep -q 'it cannot be confirmed that the solution path was posted' <<< "$out" && echo yes || echo no)"
check 'with the provider'"'"'s words, and no false claim' 'yes no' "$(grep -q 'it is not known whether the comment on' <<< "$out" && echo yes || echo no) $(grep -q 'solution path was NOT posted' <<< "$out" && echo yes || echo no)"
check 'one post, one stored comment'       '1 1' "$(cap_count posts) $(ls "$CAP_STATE" | grep -c '^stored-')"


if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
