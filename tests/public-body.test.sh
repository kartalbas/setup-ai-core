#!/usr/bin/env bash
# Refusals reach every actual writer and leave no tracker mutations, including composed bodies.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
make_gh_fake
export HOME="$WORK/home" AI_CORE_HOME="$WORK/core" PATH="$PATH_SH" GH_BODY_FIXTURE=1 GH_VISIBILITY=public
mkdir -p "$HOME" "$AI_CORE_HOME"
printf 'The existing body.\n' > "$GH_FAKE/current-body"
failed=0
check() { if [ "$2" != "$3" ]; then echo "FAIL: $1: expected [$2], got [$3]"; failed=$((failed+1)); fi; }
# This synthetic non-reserved domain is never contacted; the fake only records bodies.
real='someone@company.ch'
bot='49699333+dependabot[bot]@users.noreply.github.com'
unicode_local="$(printf '\303\251')"
unicode_domain="$(printf '\303\251.company.ch')"
unicode_mark="$(printf 'e\314\201')"
unicode_symbol="$(printf '\360\237\223\247')"
root_under_test="$ROOT"
invoke() {
  case "$path" in
    inline) bash "$root_under_test/bin/issue-comment.sh" example-org/example-repo 9 "$text" ;;
    file) bash "$root_under_test/bin/issue-comment.sh" example-org/example-repo 9 --body-file "$WORK/body" ;;
    new) bash "$root_under_test/bin/issue-new.sh" --repo example-org/example-repo --title 'Preserve the body, or text is lost' --body-file "$WORK/body" --label type:feature --label area:tooling --no-board --assignee someone --asked-by someone --asked-in "${asked_in:-the test}" ;;
    edit) bash "$root_under_test/bin/issue-edit.sh" example-org/example-repo 9 --body-file "$WORK/body" ;;
  esac
}
case_body() {
  local want="$1"; text="$2"
  printf '%s' "$text" > "$WORK/body"; cp "$WORK/body" "$WORK/before"
  : > "$GH_FAKE/body-calls.log"; rm -f "$GH_FAKE/sent-body"
  rc=0; out="$(invoke 2>&1)" || rc=$?
  writes="$(grep -c '^write ' "$GH_FAKE/body-calls.log" || true)"
  if [ "$want" = refuse ]; then
    check "$path refuses $text" yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
    check "$path zero writes" 0 "$writes"
    command=issue-comment; [ "$path" != new ] || command=issue-new; [ "$path" != edit ] || command=issue-edit
    check "$path names command" yes "$(grep -qF "$command" <<< "$out" && echo yes || echo no)"
  else
    check "$path allows $text" 0 "$rc"
    check "$path one write" 1 "$writes"
    if [ -f "$GH_FAKE/sent-body" ]; then
      if [ "$path" = new ]; then tail -n +3 "$GH_FAKE/sent-body" > "$WORK/posted"; else cp "$GH_FAKE/sent-body" "$WORK/posted"; fi
      check "$path exact body bytes" yes "$(cmp -s "$WORK/posted" "$WORK/body" && echo yes || echo no)"
    fi
  fi
  check "$path caller file preserved" yes "$(cmp -s "$WORK/body" "$WORK/before" && echo yes || echo no)"
  check "$path one visibility decision" 1 "$(grep -c '^visibility$' "$GH_FAKE/body-calls.log" || true)"
}
for path in inline file new edit; do
  for address in "$real" "$unicode_local@company.ch" "ci@$unicode_domain" "$unicode_mark@company.ch" "$unicode_symbol@company.ch"; do
    case_body refuse "$address"
    check "$path names address" yes "$(grep -qF "$address" <<< "$out" && echo yes || echo no)"
  done
  case_body allow "$unicode_local@build.example.test"
  case_body allow $'A `backtick`, "quotes" and CRLF.\r\nNext line.\n'
  for address in "$bot" '49699333+dependabot[bot]@USERS.NOREPLY.GITHUB.COM'; do case_body allow "$address"; done
  case_body refuse "$bot $real"; case_body refuse "$real $bot"
  GH_VISIBILITY=private case_body allow "$real"
  for GH_VISIBILITY in error malformed null missing string; do export GH_VISIBILITY; case_body refuse "$real"; done
  export GH_VISIBILITY=public
done
path=inline
for domain in invalid example test localhost example.com example.net example.org; do
  for address in "ci@$domain" "ci@build.$domain"; do case_body allow "$address"; done
done
case_body allow 'ci@EXAMPLE.TEST'
case_body allow 'package@1.2.3'
for address in "$real" 'name+tag@COMPANY.CH' '"quoted name"@company.ch' 'name@[192.0.2.1]' 'ci@example.com.company.ch' 'ci@notexample.com' 'noreply@company.ch' '123+noreply@company.ch' 'ci@sub.users.noreply.github.com' 'ci@users.noreply.github.com.company.ch'; do case_body refuse "mailto:$address, inside Markdown"; done
case_body refuse "ci@build.example.test $real"
FORGE=forgejo case_body refuse 'noreply@company.ch'
path=new; asked_in="$real"; case_body refuse 'Safe input.'; unset asked_in
path=edit; printf 'Asked for by @someone on 2026-10-18 in %s.\n' "$real" > "$GH_FAKE/current-body"
case_body refuse 'Safe input.'
printf 'The existing body.\n' > "$GH_FAKE/current-body"
: > "$GH_FAKE/body-calls.log"
bash "$ROOT/bin/issue-edit.sh" example-org/example-repo 9 --title 'Keep the title, or it is lost' > /dev/null 2>&1
check 'title-only no visibility' 0 "$(grep -c '^visibility$' "$GH_FAKE/body-calls.log" || true)"
# File errors cannot become an empty safe body.
printf '%s' "$real" > "$WORK/body"; chmod 000 "$WORK/body"
for path in file new edit; do
  : > "$GH_FAKE/body-calls.log"; rc=0; text="$real"; out="$(invoke 2>&1)" || rc=$?
  check "$path unreadable file refuses" yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
  check "$path unreadable zero writes" 0 "$(grep -c '^write ' "$GH_FAKE/body-calls.log" || true)"
done
chmod 600 "$WORK/body"
# Removing each guard lets a disallowed address through; removing only the exemption breaks the control.
mutant="$WORK/mutant"; mkdir -p "$mutant"; cp -R "$ROOT/lib" "$ROOT/bin" "$ROOT/templates" "$mutant/"
for path in inline file new edit; do
  command=issue-comment; [ "$path" != new ] || command=issue-new; [ "$path" != edit ] || command=issue-edit
  sed '/^check_public_body /d; /check_public_body .*issue-edit/d' "$ROOT/bin/$command.sh" > "$mutant/bin/$command.sh"
  root_under_test="$mutant"; text="$real"; printf '%s' "$text" > "$WORK/body"; : > "$GH_FAKE/body-calls.log"
  out="$(invoke 2>&1)" || true
  check "$path missing guard mutant writes" 1 "$(grep -c '^write ' "$GH_FAKE/body-calls.log" || true)"
  cp "$ROOT/bin/$command.sh" "$mutant/bin/$command.sh"
done
sed '/users.noreply.github.com/d' "$ROOT/lib/tracker.sh" > "$mutant/lib/tracker.sh"
for path in inline file new edit; do
  text="$bot"; printf '%s' "$text" > "$WORK/body"; : > "$GH_FAKE/body-calls.log"; rc=0; out="$(invoke 2>&1)" || rc=$?
  check "$path exemption removal refuses innocent" yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
  check "$path exemption removal zero writes" 0 "$(grep -c '^write ' "$GH_FAKE/body-calls.log" || true)"
done
cp "$ROOT/lib/tracker.sh" "$mutant/lib/tracker.sh"
printf '\nrepo_visibility() { echo private; }\n' >> "$mutant/lib/github/tracker.sh"
path=inline; text="$real"; : > "$GH_FAKE/body-calls.log"; rc=0; out="$(invoke 2>&1)" || rc=$?
check 'fabricated private visibility mutant permits unsafe body' 1 "$(grep -c '^write ' "$GH_FAKE/body-calls.log" || true)"
root_under_test="$ROOT"
for command in issue-new issue-comment issue-edit; do
  help="$(bash "$ROOT/bin/ai-core" "$command" --help)"
  check "$command actual help policy" yes "$(grep -q 'public' <<< "$help" && grep -q 'Plane' <<< "$help" && echo yes || echo no)"
  check "$command actual help usage" yes "$(grep -q "$command.*OWNER/REPO\|$command --repo" <<< "$help" && echo yes || echo no)"
done
# Unknown Plane visibility must apply the same policy, without consulting gh.
make_plane_project
unset GH_BODY_FIXTURE
PATH="$PATH_CURL"; export PATH
printf 'Safe body.\n' > "$WORK/seed-body"
seed="$(ai issue-new --repo example-org/example-repo --title 'Preserve the body, or text is lost' --body-file "$WORK/seed-body" --label type:feature --label area:tooling --priority P2 --asked-by someone --asked-in 'the test' 2>/dev/null)"
plane_invoke() {
 case "$path" in
  inline) ai issue-comment "$seed" "$text" ;;
  file) ai issue-comment "$seed" --body-file "$WORK/body" ;;
  new) ai issue-new --repo example-org/example-repo --title 'Preserve the body, or text is lost' --body-file "$WORK/body" --label type:feature --label area:tooling --priority P2 --asked-by someone --asked-in 'the test' ;;
  edit) ai issue-edit "$seed" --body-file "$WORK/body" ;;
 esac
}
for path in inline file new edit; do
 for text in "$bot" '49699333+dependabot[bot]@USERS.NOREPLY.GITHUB.COM' "$bot $real" "$real $bot"; do
  printf '%s' "$text" > "$WORK/body"; reset_log; rc=0; out="$(plane_invoke 2>&1)" || rc=$?
  writes="$(grep -cE '^(POST|PATCH|DELETE) ' "$CURL_FAKE_STATE/requests.log" || true)"
  case "$text" in
   *company.ch*) check "Plane $path mixed refuses" yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"; check "Plane $path zero writes" 0 "$writes" ;;
   *) check "Plane $path bot allowed" 0 "$rc"; expected=1; [ "$path" != new ] || expected=3; check "Plane $path intended writes" "$expected" "$writes"
      expected_text="$text"
      if [ "$path" = new ] || [ "$path" = edit ]; then expected_text="Asked for by @someone on $(date +%Y-%m-%d) in the test."$'\n\n'"$text"; fi
      case "$path" in
        inline|file) html="$(planeq 'console.log(p.comments[p.comments.length-1].comment_html)')" ;;
        new) html="$(planeq 'console.log(p.issues[p.issues.length-1].description_html)')" ;;
        edit) html="$(ITEM_SEQ="$seed" planeq 'console.log(p.issues.find(i=>i.sequence_id===+process.env.ITEM_SEQ).description_html)')" ;;
      esac
      check "Plane $path exact composed body" "<pre>$expected_text</pre>" "$html"
  esac
 done
done
[ "$failed" -eq 0 ] || fail "$failed public body assertions failed"
echo 'all public body writers, visibility answers, mutants, and innocent cases passed'
