#!/usr/bin/env bash
# Refusals reach every actual writer and leave no tracker mutations, including composed bodies.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
make_gh_fake
export HOME="$WORK/home" AI_CORE_HOME="$WORK/core" PATH="$PATH_SH" GH_BODY_FIXTURE=1 GH_VISIBILITY=public TMPDIR="$WORK/body-tmp"
mkdir -p "$HOME" "$AI_CORE_HOME" "$TMPDIR"
printf 'The existing body.\n' > "$GH_FAKE/current-body"
failed=0
check() { if [ "$2" != "$3" ]; then echo "FAIL: $1: expected [$2], got [$3]"; failed=$((failed+1)); fi; }
# This synthetic non-reserved domain is never contacted; the fake only records bodies.
real='someone@company.ch'
scoped='Use the scoped package `@scope/pkg`.'
unquoted_scoped='Use the scoped package @scope/pkg.'
bot='49699333+dependabot[bot]@users.noreply.github.com'
unicode_local="$(printf '\303\251')"
unicode_domain="$(printf '\303\251.company.ch')"
unicode_mark="$(printf 'e\314\201')"
unicode_symbol="$(printf '\360\237\223\247')"
separators=("$(printf '\343\200\202')" "$(printf '\357\274\216')" "$(printf '\357\275\241')")
# Each text beside the address the guard must name for it. A scoped package name is dropped before the
# scan, so these are the shapes in which that drop must not hide, or must not lose, an address.
overlaps=(); overlap_names=()
overlap() { overlaps+=("$1"); overlap_names+=("$2"); }
overlap '`@company.ch/' '`@company.ch'
overlap '`@company.ch/pkg`' '`@company.ch'
overlap 'x `@gmail.com/inbox` y' '`@gmail.com'
overlap '`@scope/@company.ch' '`@scope'
overlap '`@scope/pkg@company.ch' '`@scope'
overlap '`@scope/pkg`@company.ch' '`@company.ch'
overlap '`@scope/pkg/@company.ch' '/@company.ch'
overlap 'bob`@scope/pkg' 'bob`@scope'
overlap '"bob"@scope/pkg' '"bob"@scope'
overlap "$(printf '\303\251')"'`@scope/pkg`' "$(printf '\303\251')"'`@scope'
overlap 'Owners x@[bob@company.ch @1 @scope/pkg]' '[bob@company.ch'
overlap 'x@[`bob@company.ch` @2 `@scope/pkg`]' '[`bob@company.ch'
overlap 'x@[bob@company.ch @1]' '[bob@company.ch'
overlap '"bob@company.ch"@1' 'bob@company.ch'
overlap '"bob@company.ch"@localhost' 'bob@company.ch'
for quoted in 'Mail bob@[ @company.ch ] now' 'bob@[ @company.ch]' 'bob@[;@company.ch]' 'bob@[,@company.ch]'; do
  name="$quoted"; case "$quoted" in 'Mail '*) name='bob@[ @company.ch ]' ;; esac
  overlap "$quoted" "$name"
done
for quoted in '"@ops"@company.ch' '"A@"@company.ch' '"bob@"@company.ch' '"bob@ home"@company.ch' '"bob@1"@company.ch' '"@"@company.ch' '"very.unusual.@.unusual.com"@company.ch' 'Write to "@ops"@company.ch now'; do
  name="$quoted"; case "$quoted" in 'Write to '*) name='"@ops"@company.ch' ;; esac
  overlap "$quoted" "$name"
done
overlap '`@scope/pkg'"$(printf '\303\251')" '`@scope'
for separator in "${separators[@]}"; do
  overlap '`@scope/@company'"${separator}ch" '`@scope'
  overlap '`@scope/pkg@company'"${separator}ch" '`@scope'
done
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
  check "$path temporary bodies removed" '' "$(ls -A "$TMPDIR")"
}
for path in inline file new edit; do
  for address in "$real" "$unicode_local@company.ch" "ci@$unicode_domain" "$unicode_mark@company.ch" "$unicode_symbol@company.ch"; do
    case_body refuse "$address"
    check "$path names address" yes "$(grep -qF "$address" <<< "$out" && echo yes || echo no)"
  done
  case_body allow "$unicode_local@build.example.test"
  case_body allow $'A `backtick`, "quotes" and CRLF.\r\nNext line.\n'
  case_body allow "$scoped"
  case_body allow "$unquoted_scoped"
  for index in "${!overlaps[@]}"; do
    case_body refuse "${overlaps[index]}"
    check "$path names ${overlap_names[index]}" yes "$(grep -qF "refused email address ${overlap_names[index]} " <<< "$out" && echo yes || echo no)"
  done
  case_body refuse '`@company.ch'
  case_body refuse "$scoped $real"
  for address in "$bot" '49699333+dependabot[bot]@USERS.NOREPLY.GITHUB.COM'; do case_body allow "$address"; done
  for separator in "${separators[@]}"; do
    for prefix in users.noreply.github.com example.com; do
      case_body refuse "ci@$prefix${separator}company.ch"
    done
    case_body allow "ci@build${separator}example${separator}test"
  done
  case_body refuse "$bot $real"; case_body refuse "$real $bot"
  GH_VISIBILITY=private case_body allow "$real"
  for GH_VISIBILITY in error malformed null missing string; do export GH_VISIBILITY; case_body refuse "$real"; done
  export GH_VISIBILITY=public
done
# The visibility read must not change the bytes that are checked and then posted.
for path in file new edit; do
  text=$'Safe body.\r\nA `backtick` and trailing newlines.\n\n'
  printf '%s' "$text" > "$WORK/body"; cp "$WORK/body" "$WORK/before"
  : > "$GH_FAKE/body-calls.log"; rm -f "$GH_FAKE/sent-body"
  rc=0; out="$(GH_REWRITE_BODY_FILE="$WORK/body" GH_REWRITE_BODY="$real" invoke 2>&1)" || rc=$?
  check "$path changing original succeeds" 0 "$rc"
  check "$path changing original planted" "$real" "$(cat "$WORK/body")"
  check "$path changing original one write" 1 "$(grep -c '^write ' "$GH_FAKE/body-calls.log" || true)"
  if [ -f "$GH_FAKE/sent-body" ]; then
    if [ "$path" = new ]; then tail -n +3 "$GH_FAKE/sent-body" > "$WORK/posted"; else cp "$GH_FAKE/sent-body" "$WORK/posted"; fi
    check "$path posts checked snapshot bytes" yes "$(cmp -s "$WORK/posted" "$WORK/before" && echo yes || echo no)"
  else
    check "$path posts checked snapshot bytes" yes no
  fi
  check "$path changing original one visibility" 1 "$(grep -c '^visibility$' "$GH_FAKE/body-calls.log" || true)"
  check "$path snapshot private" '-rw-------' "$(cat "$GH_FAKE/sent-body-mode")"
  check "$path snapshot path removed" no "$([ -e "$(cat "$GH_FAKE/sent-body-path")" ] && echo yes || echo no)"
  check "$path changing original snapshot removed" '' "$(ls -A "$TMPDIR")"
  printf '%s' "$text" > "$WORK/body"
  rc=0; out="$(GH_BODY_WRITE_FAILURE=1 invoke 2>&1)" || rc=$?
  check "$path writer failure propagated" yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
  check "$path failed write snapshot removed" '' "$(ls -A "$TMPDIR")"
done
# Duplicate marking writes a generated comment and must check the receiving repository first.
case_duplicate() {
  local want="$1" canonical="$2" expected="$3"
  : > "$GH_FAKE/body-calls.log"; rm -f "$GH_FAKE/sent-body"
  rc=0; out="$(bash "$root_under_test/bin/issue-duplicate.sh" "$canonical" 1 example-org/example-repo 9 2>&1)" || rc=$?
  check 'duplicate one visibility decision' 1 "$(grep -c '^visibility$' "$GH_FAKE/body-calls.log" || true)"
  if [ "$want" = refuse ]; then
    check 'duplicate refuses unsafe body' yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
    check 'duplicate refusal names command' yes "$(grep -qF issue-duplicate <<< "$out" && echo yes || echo no)"
    check 'duplicate zero writes' 0 "$(grep -c '^write ' "$GH_FAKE/body-calls.log" || true)"
  else
    check 'duplicate succeeds' 0 "$rc"
    check 'duplicate one write' 1 "$(grep -c '^write ' "$GH_FAKE/body-calls.log" || true)"
    check 'duplicate exact comment' "$expected" "$(cat "$GH_FAKE/sent-body")"
  fi
}
case_duplicate refuse "$real/repo" ''
for GH_VISIBILITY in error malformed null missing string; do export GH_VISIBILITY; case_duplicate refuse "$real/repo" ''; done
export GH_VISIBILITY=public
case_duplicate allow example-org/example-repo 'Duplicate of #1'
case_duplicate allow example-org/other-repo 'Duplicate of example-org/other-repo#1'
case_duplicate allow ci@example.test/repo 'Duplicate of ci@example.test/repo#1'
GH_VISIBILITY=private case_duplicate allow "$real/repo" "Duplicate of $real/repo#1"
path=inline
for domain in invalid example test localhost example.com example.net example.org; do
  for address in "ci@$domain" "ci@build.$domain"; do case_body allow "$address"; done
done
case_body allow 'ci@EXAMPLE.TEST'
case_body allow 'package@1.2.3'
for address in "$real" 'name+tag@COMPANY.CH' '"quoted name"@company.ch' 'name@[192.0.2.1]' 'ci@example.com.company.ch' 'ci@notexample.com' 'noreply@company.ch' '123+noreply@company.ch' 'ci@sub.users.noreply.github.com' 'ci@users.noreply.github.com.company.ch'; do case_body refuse "mailto:$address, inside Markdown"; done
case_body refuse "ci@build.example.test $real"
remotes='Push to `ssh://git@forgejo.<fqdn>/<owner>/<repo>.git`, `git@github.com:owner/repo.git` or `https://x-access-token:{{ .pat }}@github.com`.'
case_body allow "$remotes"
case_body refuse "$remotes Ask $real."
check 'address beside remotes is named' yes "$(grep -qF "refused email address $real" <<< "$out" && echo yes || echo no)"
for text in "https://example.com?mail=$real" "https://example.com#$real" "https://example.com,$real" "[docs](https://example.com)[mail](mailto:$real)" "$real:25" "Ping $real:please" "Cc <$real>:note" $'https://{{ .host\nAsk '"$real"$'\nhttps://x:{{ .pat }}@github.com'; do case_body refuse "$text"; done
FORGE=forgejo case_body refuse 'noreply@company.ch'
path=new; asked_in="$real"; case_body refuse 'Safe input.'; unset asked_in
path=edit; printf 'Asked for by @someone on 2026-10-18 in %s.\n' "$real" > "$GH_FAKE/current-body"
case_body refuse 'Safe input.'
printf 'The existing body.\n' > "$GH_FAKE/current-body"
# Titles share the body's visibility decision, including an edit with no body.
title_provider=github
title_invoke() {
  if [ "$title_provider" = plane ]; then
    case "$path" in
      title-edit) ai issue-edit "$seed" --title "$title" ;;
      title-both) ai issue-edit "$seed" --title "$title" --body-file "$WORK/body" ;;
      title-new) ai issue-new --repo example-org/example-repo --title "$title" --body-file "$WORK/body" --label type:feature --label area:tooling --priority P2 --asked-by someone --asked-in 'the test' ;;
      title-project)
        planeset 's.projects=s.projects.filter(x=>x.identifier!=="NEW")'
        rm -rf "$GH_CACHE_DIRECTORY/plane"
        PLANE_PROJECT=NEW ai project-new "$title" ;;
    esac
  else
    case "$path" in
      title-edit) bash "$root_under_test/bin/issue-edit.sh" example-org/example-repo 9 --title "$title" ;;
      title-both) bash "$root_under_test/bin/issue-edit.sh" example-org/example-repo 9 --title "$title" --body-file "$WORK/body" ;;
      title-new) bash "$root_under_test/bin/issue-new.sh" --repo example-org/example-repo --title "$title" --body-file "$WORK/body" --label type:feature --label area:tooling --no-board --assignee someone --asked-by someone --asked-in 'the test' ;;
      title-project) GH_ORG=example-org bash "$root_under_test/bin/project-new.sh" "$title" 1 ;;
    esac
  fi
}
case_title() {
  local want="$1" label="$title_provider $path ${GH_VISIBILITY:-} ${TITLE_VISIBILITY:-}" reads=1 command
  title="$2"; printf 'Safe body.\n' > "$WORK/body"
  : > "$GH_FAKE/body-calls.log"; rm -f "$GH_FAKE/sent-title"
  if [ "$title_provider" = plane ]; then reset_log; : > "$TITLE_VISIBILITY_LOG"; fi
  rc=0; out="$(title_invoke 2>&1)" || rc=$?
  if [ "$title_provider" = plane ]; then
    writes="$(grep -cE '^(POST|PATCH|DELETE) ' "$CURL_FAKE_STATE/requests.log" || true)"
    visibility_reads="$(wc -l < "$TITLE_VISIBILITY_LOG" | tr -d ' ')"
  else
    writes="$(grep -c '^write ' "$GH_FAKE/body-calls.log" || true)"
    visibility_reads="$(grep -c '^visibility$' "$GH_FAKE/body-calls.log" || true)"
  fi
  # A repository's private answer cannot establish a project's visibility.
  [ "$path" != title-project ] || reads=0
  check "$label one visibility decision" "$reads" "$visibility_reads"
  case "$path" in title-new) command=issue-new ;; title-project) command=project-new ;; *) command=issue-edit ;; esac
  if [ "$want" = refuse ]; then
    check "$label refuses unsafe title" yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
    check "$label zero writes" 0 "$writes"
    check "$label names command and address" yes "$(grep -qF "$command: refused email address $title" <<< "$out" && echo yes || echo no)"
  else
    check "$label safe title succeeds" 0 "$rc"
    if [ "$title_provider" = github ]; then
      check "$label one write" 1 "$writes"
      check "$label exact title" "$title" "$(cat "$GH_FAKE/sent-title")"
    else
      case "$path" in
        title-new) primary="$(grep -cE '^POST .*/issues/$' "$CURL_FAKE_STATE/requests.log" || true)"; check "$label intended writes" 3 "$writes"
          posted_title="$(planeq 'console.log(p.issues[p.issues.length-1].name)')" ;;
        title-project) primary="$(grep -cE '^POST /api/v1/workspaces/ws/projects/$' "$CURL_FAKE_STATE/requests.log" || true)"
          posted_title="$(planeq 'console.log(s.projects.find(x=>x.identifier==="NEW").name)')"
          planeset 's.projects=s.projects.filter(x=>x.identifier!=="NEW")' ;;
        *) primary="$writes"; posted_title="$(ITEM_SEQ="$seed" planeq 'console.log(p.issues.find(i=>i.sequence_id===+process.env.ITEM_SEQ).name)')" ;;
      esac
      check "$label one primary write" 1 "$primary"
      check "$label exact title" "$title" "$posted_title"
    fi
  fi
  check "$label snapshots removed" '' "$(ls -A "$TMPDIR")"
}
for path in title-edit title-both title-new title-project; do
  for GH_VISIBILITY in public error malformed null missing string; do
    export GH_VISIBILITY
    case_title refuse "$real"
    case_title allow 'Keep the title, or it is lost'
  done
  if [ "$path" = title-project ]; then GH_VISIBILITY=private case_title refuse "$real"
  else GH_VISIBILITY=private case_title allow "$real"; fi
done
export GH_VISIBILITY=public
# GitHub receives logins, never literal addresses, for assignment and creation alike.
assignee_invoke() {
  case "$path" in
    assign-add) bash "$root_under_test/bin/issue-assign.sh" example-org/example-repo 9 --add "$assignee" ;;
    assign-replace) bash "$root_under_test/bin/issue-assign.sh" example-org/example-repo 9 --replace "$assignee" ;;
    assignee-new) bash "$root_under_test/bin/issue-new.sh" --repo example-org/example-repo --title 'Keep the title, or it is lost' --body-file "$WORK/body" --label type:feature --label area:tooling --no-board --assignee "$assignee" --asked-by someone --asked-in 'the test' ;;
  esac
}
case_assignee() {
  local want="$1" command=issue-assign
  assignee="$2"; printf 'Safe body.\n' > "$WORK/body"
  printf '{"assignees":[]}\n' > "$GH_FAKE/current-assignees"
  : > "$GH_FAKE/body-calls.log"; rm -f "$GH_FAKE/sent-assignee" "$GH_FAKE/sent-input"
  rc=0; out="$(assignee_invoke 2>&1)" || rc=$?
  writes="$(grep -c '^write ' "$GH_FAKE/body-calls.log" || true)"
  [ "$path" != assignee-new ] || command=issue-new
  if [ "$want" = refuse ]; then
    check "$path refuses address assignee" yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
    check "$path address assignee zero writes" 0 "$writes"
    check "$path assignee refusal names command" yes "$(grep -qF "$command:" <<< "$out" && echo yes || echo no)"
  else
    check "$path login succeeds" 0 "$rc"
    check "$path login one write" 1 "$writes"
    if [ "$path" = assignee-new ]; then posted_assignee="$(cat "$GH_FAKE/sent-assignee")"
    else posted_assignee="$(jq -r '.assignees | join("\n")' "$GH_FAKE/sent-input")"; fi
    check "$path exact assignee" "$assignee" "$posted_assignee"
  fi
  check "$path snapshots removed" '' "$(ls -A "$TMPDIR")"
}
for path in assign-add assign-replace assignee-new; do
  for GH_VISIBILITY in public error private; do
    export GH_VISIBILITY
    case_assignee refuse "$real"
    case_assignee allow someone
  done
done
path=assignee-new
for assignee in @me @copilot someone,@me; do case_assignee allow "$assignee"; done
case_assignee refuse "someone,$real"
export GH_VISIBILITY=public
# The writer audit also covers metadata, including a late unsafe label before any create.
audit_project="$WORK/metadata-project"; mkdir -p "$audit_project/.ai-core"; git init -q "$audit_project"
export GH_ORG=example-org GH_CACHE_DIRECTORY="$WORK/metadata-cache"
mkdir -p "$GH_CACHE_DIRECTORY/1"; echo fixture-id > "$GH_CACHE_DIRECTORY/1/project-id"
metadata_invoke() {
  (
    cd "$audit_project"
    case "$path" in
      labels-name|labels-description) bash "$ROOT/bin/labels-sync.sh" example-org/example-repo ;;
      repo-link-name|repo-link-description) bash "$ROOT/bin/repo-link.sh" --project 1 example-org/example-repo ;;
      new-label) bash "$ROOT/bin/issue-new.sh" --repo example-org/example-repo --title 'Keep the title, or it is lost' --body-file "$WORK/body" --label type:feature --label "area:$payload" --no-board --assignee someone --asked-by someone --asked-in 'the test' ;;
      issue-label) bash "$ROOT/bin/issue-label.sh" example-org/example-repo 9 --add "area:$payload" ;;
      field-name) bash "$ROOT/bin/field-option-add.sh" --project 1 --field Priority --name "$payload" --color GRAY ;;
      field-description) bash "$ROOT/bin/field-option-add.sh" --project 1 --field Priority --name P9 --color GRAY --description "$payload" ;;
      field-existing) bash "$ROOT/bin/field-option-add.sh" --project 1 --field Priority --name P9 --color GRAY --description 'Safe description.' ;;
      view-filter) bash "$ROOT/bin/view-filter.sh" --project 1 --repo-name "$payload" ;;
    esac
  )
}
case_metadata() {
  local want="$1" expected=1 name=area:tooling description='Safe description.' old='Safe description.' label="$path $2 ($GH_VISIBILITY)" address="${3:-$real}"
  payload="$2"
  case "$path" in labels-name|repo-link-name|new-label|issue-label) name="area:$payload" ;; labels-description|repo-link-description) description="$payload" ;; field-existing) old="$payload" ;; esac
  printf 'type\ttype:feature\t0E8A16\tSafe description.\narea\t%s\t0E8A16\t%s\n' "$name" "$description" > "$audit_project/.ai-core/labels.tsv"
  jq -n --arg d "$old" '{data:{node:{fields:{nodes:[{id:"FIELD_example",name:"Priority",options:[{id:"OPTION_example",name:"P2",color:"GRAY",description:$d}]}]}}}}' > "$GH_FAKE/fields.json"
  printf 'Safe body.\n' > "$WORK/body"; : > "$GH_FAKE/body-calls.log"
  rc=0; out="$(metadata_invoke 2>&1)" || rc=$?
  writes="$(grep -c '^write ' "$GH_FAKE/body-calls.log" || true)"
  if [ "$want" = refuse ]; then
    check "$label refuses unsafe metadata" yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
    check "$label unsafe metadata zero writes" 0 "$writes"
    check "$label names metadata address" yes "$(grep -qF 'refused email address' <<< "$out" && grep -qF "$address" <<< "$out" && echo yes || echo no)"
  else
    case "$path" in labels-*) expected=2 ;; repo-link-*) expected=3 ;; esac
    check "$path safe metadata succeeds" 0 "$rc"
    check "$path safe intended writes" "$expected" "$writes"
  fi
}
for path in labels-name labels-description repo-link-name repo-link-description new-label issue-label field-name field-description field-existing view-filter; do
  for GH_VISIBILITY in public error; do
    export GH_VISIBILITY
    case_metadata refuse "$real"
    case_metadata allow ci@build.example.test
    case_metadata allow "$scoped"
  done
done
for path in labels-description repo-link-description field-description field-existing; do
  for GH_VISIBILITY in public error; do
    export GH_VISIBILITY
    case_metadata allow "$unquoted_scoped"
    for index in "${!overlaps[@]}"; do case_metadata refuse "${overlaps[index]}" "${overlap_names[index]}"; done
  done
done
export GH_VISIBILITY=public
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
sed '/^  check_public_body /d' "$ROOT/bin/issue-duplicate.sh" > "$mutant/bin/issue-duplicate.sh"
root_under_test="$mutant"; : > "$GH_FAKE/body-calls.log"
out="$(bash "$root_under_test/bin/issue-duplicate.sh" "$real/repo" 1 example-org/example-repo 9 2>&1)" || true
check 'duplicate missing guard mutant writes' 1 "$(grep -c '^write ' "$GH_FAKE/body-calls.log" || true)"
cp "$ROOT/bin/issue-duplicate.sh" "$mutant/bin/issue-duplicate.sh"
sed '/users.noreply.github.com/d' "$ROOT/lib/tracker.sh" > "$mutant/lib/tracker.sh"
for path in inline file new edit; do
  text="$bot"; printf '%s' "$text" > "$WORK/body"; : > "$GH_FAKE/body-calls.log"; rc=0; out="$(invoke 2>&1)" || rc=$?
  check "$path exemption removal refuses innocent" yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
  check "$path exemption removal zero writes" 0 "$(grep -c '^write ' "$GH_FAKE/body-calls.log" || true)"
done
path=edit
for rule in 'url:s/^    gsub(.*/    ./:Push to `ssh://git@forgejo.<fqdn>/<owner>/<repo>.git`.' 'scp:s/^    | gsub(.*/    | ./:Push to `git@github.com:owner/repo.git`.'; do
  name="${rule%%:*}"; rest="${rule#*:}"; sed "${rest%%:*}" "$ROOT/lib/tracker.sh" > "$mutant/lib/tracker.sh"
  text="${rest#*:}"; printf '%s' "$text" > "$WORK/body"; : > "$GH_FAKE/body-calls.log"; rc=0; out="$(invoke 2>&1)" || rc=$?
  check "$name remote rule removal refuses innocent" yes "$([ "$rc" -ne 0 ] && grep -qF 'refused email address' <<< "$out" && echo yes || echo no)"
done
cp "$ROOT/lib/tracker.sh" "$mutant/lib/tracker.sh"
printf '\nrepo_visibility() { echo private; }\n' >> "$mutant/lib/github/tracker.sh"
path=inline; text="$real"; : > "$GH_FAKE/body-calls.log"; rc=0; out="$(invoke 2>&1)" || rc=$?
check 'fabricated private visibility mutant permits unsafe body' 1 "$(grep -c '^write ' "$GH_FAKE/body-calls.log" || true)"
root_under_test="$ROOT"
for command in issue-new issue-comment issue-edit issue-duplicate; do
  help="$(bash "$ROOT/bin/ai-core" "$command" --help)"
  check "$command actual help policy" yes "$(grep -q 'public' <<< "$help" && grep -q 'Plane' <<< "$help" && echo yes || echo no)"
  check "$command actual help usage" yes "$(grep -q "$command.*OWNER/REPO\|$command --repo\|$command.*CANONICAL_REPO" <<< "$help" && echo yes || echo no)"
done
for command in issue-new issue-edit project-new; do
  help="$(bash "$ROOT/bin/ai-core" "$command" --help)"
  check "$command actual help covers title or name" yes "$(grep -qiE 'titles|names' <<< "$help" && echo yes || echo no)"
done
# Unknown Plane visibility must apply the same policy, without consulting gh.
make_plane_project
unset GH_BODY_FIXTURE
PATH="$PATH_CURL"; export PATH
printf 'Safe body.\n' > "$WORK/seed-body"
seed="$(ai issue-new --repo example-org/example-repo --title 'Preserve the body, or text is lost' --body-file "$WORK/seed-body" --label type:feature --label area:tooling --priority P2 --asked-by someone --asked-in 'the test' 2>/dev/null)"
# Plane resolves an email locally and sends only its member UUID in either writer.
planeset 's.users.push({id:"00000000-0000-0000-0000-000000000099",email:"someone@company.ch",display_name:"Someone"})'
for path in assign-replace assignee-new; do
  reset_log; rc=0
  if [ "$path" = assign-replace ]; then out="$(ai issue-assign "$seed" --replace "$real" 2>&1)" || rc=$?
  else out="$(ai issue-new --repo example-org/example-repo --title 'Keep the title, or it is lost' --body-file "$WORK/seed-body" --label type:feature --label area:tooling --priority P2 --assignee "$real" --asked-by someone --asked-in 'the test' 2>&1)" || rc=$?; fi
  check "Plane $path email resolves" 0 "$rc"
  expected=1; [ "$path" != assignee-new ] || expected=3
  check "Plane $path intended writes" "$expected" "$(grep -cE '^(POST|PATCH|DELETE) ' "$CURL_FAKE_STATE/requests.log" || true)"
  if [ "$path" = assign-replace ]; then actual="$(ITEM_SEQ="$seed" planeq 'console.log(p.issues.find(i=>i.sequence_id===+process.env.ITEM_SEQ).assignees.join("\n"))')"
  else actual="$(planeq 'console.log(p.issues[p.issues.length-1].assignees.join("\n"))')"; fi
  check "Plane $path sends member UUID" 00000000-0000-0000-0000-000000000099 "$actual"
  check "Plane $path no email in requests" no "$(grep -qF "$real" "$CURL_FAKE_STATE/requests.log" && echo yes || echo no)"
done
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
# Plane must refuse before its relation, comment, or state write, even for an unresolved canonical repo.
reset_log; rc=0; out="$(ai issue-duplicate "$real/repo" 1 example-org/example-repo "$seed" 2>&1)" || rc=$?
check 'Plane duplicate refuses unsafe body' yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'Plane duplicate refusal names guard' yes "$(grep -qF 'issue-duplicate: refused email address' <<< "$out" && echo yes || echo no)"
check 'Plane duplicate refusal zero writes' 0 "$(grep -cE '^(POST|PATCH|DELETE) ' "$CURL_FAKE_STATE/requests.log" || true)"
plane_add_item 99 'The canonical issue'
reset_log; rc=0; out="$(ai issue-duplicate example-org/example-repo 99 example-org/example-repo "$seed" 2>&1)" || rc=$?
check 'Plane duplicate safe succeeds' 0 "$rc"
check 'Plane duplicate intended writes' 3 "$(grep -cE '^(POST|PATCH|DELETE) ' "$CURL_FAKE_STATE/requests.log" || true)"
check 'Plane duplicate exact comment' '<pre>Duplicate of #99</pre>' "$(planeq 'console.log(p.comments[p.comments.length-1].comment_html)')"
# Exercise both explicit public and unknown decisions through the real Plane writers.
title_provider=plane
title_root="$WORK/title-root"; mkdir -p "$title_root"; cp -R "$ROOT/lib" "$ROOT/bin" "$ROOT/templates" "$title_root/"
export TITLE_VISIBILITY_LOG="$WORK/title-visibility.log"
cat >> "$title_root/lib/plane/tracker.sh" <<'EOF'

repo_visibility() {
  printf 'visibility\n' >> "$TITLE_VISIBILITY_LOG"
  [ "$TITLE_VISIBILITY" = public ] || return 1
  echo public
}
EOF
export ROOT_UNDER_TEST="$title_root"
for path in title-edit title-both title-new title-project; do
  for TITLE_VISIBILITY in public unknown; do
    export TITLE_VISIBILITY
    case_title refuse "$real"
    case_title allow 'Keep the title, or it is lost'
  done
done
# Each missing title guard exposes the planted title on both providers.
for title_provider in github plane; do
  for path in title-edit title-new title-project; do
    case "$path" in title-edit) command=issue-edit ;; title-new) command=issue-new ;; *) command=project-new ;; esac
    sed '/check_public_body /s/"\$title"/""/g' "$ROOT/bin/$command.sh" > "$title_root/bin/$command.sh"
    title="$real"; printf 'Safe body.\n' > "$WORK/body"
    : > "$GH_FAKE/body-calls.log"; reset_log
    if [ "$title_provider" = github ]; then
      export GH_BODY_FIXTURE=1; PATH="$PATH_SH"; root_under_test="$title_root"
    else unset GH_BODY_FIXTURE; PATH="$PATH_CURL"; fi
    rc=0; out="$(title_invoke 2>&1)" || rc=$?
    check "$title_provider $path missing title guard succeeds" 0 "$rc"
    if [ "$title_provider" = github ]; then writes="$(grep -c '^write ' "$GH_FAKE/body-calls.log" || true)"
    else writes="$(grep -cE '^(POST|PATCH|DELETE) ' "$CURL_FAKE_STATE/requests.log" || true)"; fi
    check "$title_provider $path missing title guard writes" yes "$([ "$writes" -gt 0 ] && echo yes || echo no)"
    cp "$ROOT/bin/$command.sh" "$title_root/bin/$command.sh"
  done
done
# Plane project metadata must be checked before the project, states, or labels are created.
unset ROOT_UNDER_TEST GH_BODY_FIXTURE
PATH="$PATH_CURL"
for path in labels-name labels-description repo-link-label-name repo-link-label-description project-label-name project-label-description project-identifier; do
  payloads=("$real" ci@build.example.test "$scoped" "$unquoted_scoped")
  case "$path" in *description) payloads+=("${overlaps[@]}") ;; esac
  for payload in "${payloads[@]}"; do
    name=area:tooling; description='Safe description.'; ident=NEW
    case "$path" in *label*name) name="area:$payload" ;; *label*description) description="$payload" ;; project-identifier) [ "$payload" != "$real" ] || ident="$payload" ;; esac
    printf 'type\ttype:feature\t0E8A16\tSafe description.\narea\t%s\t0E8A16\t%s\n' "$name" "$description" > "$P/.ai-core/labels.tsv"
    planeset 'p.labels=[];s.projects=s.projects.filter(x=>x.identifier==="ENG"||x.identifier==="OPS")'
    rm -rf "$GH_CACHE_DIRECTORY/plane"
    reset_log; rc=0
    case "$path" in
      labels-*) out="$(ai labels-sync 2>&1)" || rc=$? ;;
      repo-link-*) out="$(ai repo-link --project ENG 2>&1)" || rc=$? ;;
      *) out="$(PLANE_PROJECT="$ident" ai project-new 'Keep the title, or it is lost' 2>&1)" || rc=$? ;;
    esac
    writes="$(grep -cE '^(POST|PATCH|DELETE) ' "$CURL_FAKE_STATE/requests.log" || true)"
    unsafe=no; [ "$payload" != "$real" ] || unsafe=yes
    for index in "${!overlaps[@]}"; do [ "$payload" != "${overlaps[index]}" ] || { unsafe=yes; named="${overlap_names[index]}"; }; done
    case "$unsafe" in
    yes)
      address="$real"; [ "$payload" = "$real" ] || address="$named"
      check "Plane $path $payload refuses metadata" yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
      check "Plane $path $payload metadata zero writes" 0 "$writes"
      check "Plane $path $payload names metadata address" yes "$(grep -qF 'refused email address' <<< "$out" && grep -qF "$address" <<< "$out" && echo yes || echo no)" ;;
    *)
      check "Plane $path safe metadata succeeds" 0 "$rc"
      expected=3; case "$path" in project-*) expected=15 ;; esac
      check "Plane $path safe metadata writes" "$expected" "$writes" ;;
    esac
  done
done
[ "$failed" -eq 0 ] || fail "$failed public body assertions failed"
echo 'all public body writers, visibility answers, mutants, and innocent cases passed'
