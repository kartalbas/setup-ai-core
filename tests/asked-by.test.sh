#!/usr/bin/env bash
# No issue without a person's yes: issue-new refuses without the person and the place, and
# writes both into the first line of the body it sends.
#
# A run with a fake gh on PATH proves both halves: the refusal never reaches gh at all, and
# the accepted call carries a body whose first line names who said yes and where.
#
#   bash test/asked-by.test.sh

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fake="$(mktemp -d)"
export GH_CACHE_DIRECTORY="$fake/cache"
# The board's organisation, as a repository of it would name it; the stand-in knows no repository
export GH_ORG=example-org
PROJECT_NUMBER=999991
trap 'rm -rf "$fake"' EXIT
log="$fake/calls.txt"
sent="$fake/sent-body.md"

# On `issue create` the fake keeps a copy of the body file it was handed, because the tool
# deletes its temporary body the moment the call returns.
cat > "$fake/gh" <<EOF
#!/usr/bin/env bash
if [ "\$1 \$2" = "repo view" ] && [ "\${4-} \${5-}" = "--json isPrivate" ]; then echo '{"isPrivate":false}'; exit 0; fi
echo "\$*" >> "$log"
case "\$*" in
  *issue*create*)
    while [ \$# -gt 0 ]; do
      if [ "\$1" = "--body-file" ]; then cp "\$2" "$sent"; fi
      shift
    done
    printf 'https://github.com/example-org/example-repo/issues/999\n'; exit 0 ;;
  *projectItems*)         exit 0 ;;
  *addProjectV2ItemById*) echo 'PVTI_new'; exit 0 ;;
  *"fields(first:50)"*)   cat "$fake/board.tsv"; exit 0 ;;
  *) echo '{}'; exit 0 ;;
esac
EOF
chmod +x "$fake/gh"
export PATH="$fake:$PATH"

# The board answers, seeded so no lookup has to be faked.
mkdir -p "$GH_CACHE_DIRECTORY/$PROJECT_NUMBER"
printf 'PVT_kwasked%s\n' "$PROJECT_NUMBER" > "$GH_CACHE_DIRECTORY/$PROJECT_NUMBER/project-id"
# The board as the stand-in answers a read of its fields, and the cache of it
printf 'Status\tF1\tready\tO1\nPriority\tF2\tP1\tO2\n' > "$fake/board.tsv"
cp "$fake/board.tsv" "$GH_CACHE_DIRECTORY/$PROJECT_NUMBER/fields.tsv"

failed=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}

body="$fake/body.md"; printf 'the body\n' > "$body"
repo='example-org/example-repo'
new() {
  : > "$log"; rm -f "$sent"
  bash "$root/bin/issue-new.sh" --repo "$repo" \
    --title 'Put every new issue on its board, or nobody reading the board sees it' \
    --body-file "$body" --label type:feature --label area:tooling --priority P1 \
    --project "$PROJECT_NUMBER" "$@" 2>&1 >/dev/null
}

echo 'without --asked-by the issue is refused before gh is called'
out="$(new --asked-in 'issue #12')"; rc=$?
check 'refused'                 yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'says what is missing'    yes "$(grep -q -- '--asked-by is required' <<< "$out" && echo yes || echo no)"
check 'nothing reached gh'      no  "$(grep -q 'issue create' "$log" 2>/dev/null && echo yes || echo no)"

echo 'without --asked-in the issue is refused too'
out="$(new --asked-by kartalbas)"; rc=$?
check 'refused'                 yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'says what is missing'    yes "$(grep -q -- '--asked-in is required' <<< "$out" && echo yes || echo no)"
check 'nothing reached gh'      no  "$(grep -q 'issue create' "$log" 2>/dev/null && echo yes || echo no)"

echo 'with both, the body starts with who said yes and where, and the original body follows'
new --asked-by kartalbas --asked-in 'issue #12, comment of 2026-09-03' >/dev/null
today="$(date +%Y-%m-%d)"
check 'the issue was created'   yes "$(grep -q 'issue create' "$log" && echo yes || echo no)"
check 'first line names the person, the day and the place' \
  "Asked for by @kartalbas on $today in issue #12, comment of 2026-09-03." "$(head -1 "$sent" 2>/dev/null)"
check 'the original body follows after a blank line' 'the body' "$(sed -n '3p' "$sent" 2>/dev/null)"

echo 'a leading @ on the login is not doubled'
new --asked-by @kartalbas --asked-in 'the chat' >/dev/null
check 'one @' yes "$(head -1 "$sent" 2>/dev/null | grep -q 'by @kartalbas on' && echo yes || echo no)"

# A finding filed without a yes is written down with --found-in, which stands in for the person,
# on a bug and on every other type: the issue keeper files a feature sub-issue this way.
issue_new="$root/bin/issue-new.sh"
found() {
  : > "$log"; rm -f "$sent"
  bash "$issue_new" --repo "$repo" \
    --title 'Keep the asked-for line on an edit, or the board loses who wanted it' \
    --body-file "$body" --label "$1" --label area:tooling --priority P1 \
    --project "$PROJECT_NUMBER" "${@:2}" 2>&1 >/dev/null
}
echo 'a defect found in the work is filed with --found-in, without a yes'
found type:bug --found-in 'the review of #91' >/dev/null
check 'the issue was created'   yes "$(grep -q 'issue create' "$log" && echo yes || echo no)"
check 'first line names where it was found and the day' \
  "Found in the review of #91 on $today, a defect filed without a yes." "$(head -1 "$sent" 2>/dev/null)"

echo 'a feature is filed with --found-in too, naming the session and the decision'
found type:feature --found-in 'the review of #91, filed by the issue keeper under the owner'"'"'s decision' >/dev/null
check 'the issue was created'   yes "$(grep -q 'issue create' "$log" && echo yes || echo no)"
check 'first line names the session, the decision and the day' \
  "Found in the review of #91, filed by the issue keeper under the owner's decision on $today, a defect filed without a yes." "$(head -1 "$sent" 2>/dev/null)"

# The planted defect: a copy of the command with the old refusal of every type but a bug put back
# must refuse the feature, so the check above is shown to go red.
planted="$(mktemp -d)"; mkdir "$planted/bin"; ln -s "$root/lib" "$planted/lib"; ln -s "$root/templates" "$planted/templates"
awk '{ print } /contradict each other: one says a session found a defect/ {
  print "  grep -qx type:bug <<< \"$(printf \"%s\\n\" \"${labels[@]}\")\" || die \"--found-in is only for a defect found in the work (label type:bug)\""
}' "$root/bin/issue-new.sh" > "$planted/bin/issue-new.sh"
check 'the planted refusal is in the copy' yes "$(grep -q 'is only for a defect found in the work' "$planted/bin/issue-new.sh" && echo yes || echo no)"
issue_new="$planted/bin/issue-new.sh"
out="$(found type:feature --found-in 'the review of #91')"; rc=$?
check 'planted: the feature is refused' yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'planted: and says why'           yes "$(grep -q -- '--found-in is only for a defect' <<< "$out" && echo yes || echo no)"
check 'planted: nothing reached gh'     no  "$(grep -q 'issue create' "$log" 2>/dev/null && echo yes || echo no)"
out="$(found type:bug --found-in 'the review of #91')"; rc=$?
check 'planted: a bug is still filed'   yes "$([ "$rc" -eq 0 ] && grep -q 'issue create' "$log" && echo yes || echo no)"
issue_new="$root/bin/issue-new.sh"
rm -rf "$planted"

echo '--found-in together with --asked-by is refused'
out="$(found type:bug --found-in 'the review of #91' --asked-by kartalbas --asked-in 'the chat')"; rc=$?
check 'refused'                 yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'nothing reached gh'      no  "$(grep -q 'issue create' "$log" 2>/dev/null && echo yes || echo no)"

# The caller's own file is theirs. A tool that wrote the line into it could not be run twice
# without the line standing there twice.
echo "the caller's body file is left as it was"
check 'still one line'   'the body' "$(cat "$body")"

echo 'a board of the older layout, without ready: refused before gh creates anything'
printf 'Status\tF1\ttodo\tO1\nPriority\tF2\tP1\tO2\n' > "$fake/board.tsv"
cp "$fake/board.tsv" "$GH_CACHE_DIRECTORY/$PROJECT_NUMBER/fields.tsv"
out="$(new --asked-by kartalbas --asked-in 'issue #12')"; rc=$?
check 'refused'                 yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'it names the option'     yes "$(grep -q "field 'Status' has no option 'ready'" <<< "$out" && echo yes || echo no)"
check 'nothing reached gh'      no  "$(grep -q 'issue create' "$log" 2>/dev/null && echo yes || echo no)"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
