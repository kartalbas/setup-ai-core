#!/usr/bin/env bash
# The forge calls against Forgejo: FORGE=forgejo in a checkout whose curl is the stand-in of tests/lib.sh and whose
# git talks to tests/git-http-server.mjs, a git server over HTTP that takes the token as the password of HTTP Basic,
# the way Forgejo does. Each shape of defect the provider must refuse is planted and shown red, and the innocent case
# beside it green. Nothing here reaches a network.
#
#   bash tests/forgejo-forge.test.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
make_forgejo_project
TOKEN=forgejo-token-4567
LINE_KEY="credential.$FORGE_URL.helper"
SOURCE_KEY="credential.$FORGE_URL.aiCoreConfig"
user_sign_in_reset() {  # what init registered in the user's git configuration, taken out again
  git config --global --unset-all "$LINE_KEY" 2>/dev/null || true
  git config --global --unset-all "$SOURCE_KEY" 2>/dev/null || true
}
requests() { cat "$CURL_FAKE_STATE/requests.log"; }
inject() {  # inject <path fragment> <status> <body>: the next call whose "<METHOD> <path>" holds the fragment gets this answer
  INJ_MATCH="$1" INJ_STATUS="$2" INJ_BODY="$3" node -e "const fs=require('fs'),f=process.env.CURL_FAKE_STATE+'/inject.json',e=process.env;let l=[];try{l=JSON.parse(fs.readFileSync(f))}catch{};l.push({match:e.INJ_MATCH,status:+e.INJ_STATUS,body:e.INJ_BODY,times:1});fs.writeFileSync(f,JSON.stringify(l))"
}
pgit() { PATH="$PATH_CURL" git "$@"; }   # git as a person runs it, with ai-core on the PATH

section "the forge on Forgejo: the repository, the check of a commit, the signed-in user, and the sign-in of git"

# --- the host, a repository, the user -----------------------------------------------------------
[ "$(forge_fn forge_host)" = "$FORGE_HOST" ] || fail "forge_host is not the host of FORGEJO_URL: $(forge_fn forge_host)"
[ "$(forge_fn forge_name)" = "$FORGE_HOST" ] || fail "forge_name is not the host of FORGEJO_URL: $(forge_fn forge_name)"
forgejo_repo example-org/example-repo 3
forge_fn repo_exists example-org/example-repo || fail "repo_exists says a repository the instance has is not there"
forge_fn repo_exists example-org/missing && fail "repo_exists says a repository the instance lacks is there"
inject "GET /api/v1/repos/example-org/example-repo" 502 "Bad Gateway"
out="$(forge_fn repo_exists example-org/example-repo 2>&1)" && fail "repo_exists took a 502 for a repository that is there"
grep -q 'cannot tell whether example-org/example-repo exists - Forgejo answered 502: Bad Gateway' <<< "$out" || fail "repo_exists does not say what Forgejo answered: $out"
echo "  repo_exists: there, not there, and an answer that says neither is refused with Forgejo's words"
# forgejo_repo makes a private repository
[ "$(forge_fn forge_repo_visibility example-org/example-repo)" = private ] || fail "forge_repo_visibility: a private repository is not private"
forgejo_set 's.repos["example-org/example-repo"].private=false'
[ "$(forge_fn forge_repo_visibility example-org/example-repo)" = public ] || fail "forge_repo_visibility: a public repository is not public"
forgejo_set 's.repos["example-org/example-repo"].private="false"'
out="$(forge_fn forge_repo_visibility example-org/example-repo 2>&1)" && fail "forge_repo_visibility took a string for a boolean: $out"
grep -q 'cannot establish the visibility of example-org/example-repo: private was not a boolean' <<< "$out" || fail "forge_repo_visibility does not say what was wrong: $out"
forgejo_set 's.repos["example-org/example-repo"].private=true'
inject "GET /api/v1/repos/example-org/example-repo" 502 "Bad Gateway"
out="$(forge_fn forge_repo_visibility example-org/example-repo 2>&1)" && fail "forge_repo_visibility took a 502 for a visibility: $out"
grep -q 'cannot read the visibility of example-org/example-repo - Forgejo answered 502: Bad Gateway' <<< "$out" || fail "forge_repo_visibility does not say what Forgejo answered: $out"
out="$(forge_fn forge_repo_visibility example-org/missing 2>&1)" && fail "forge_repo_visibility took a missing repository for a visibility: $out"
echo "  forge_repo_visibility: private and public by the private field; a string, a failed query and a missing repository are refused with Forgejo's words"
[ "$(forge_fn signed_in_user)" = tester ] || fail "signed_in_user is not the login of the token"
printf 'wrong-token\n' > "$WORK/ftoken"
out="$(forge_fn signed_in_user 2>&1)" && fail "signed_in_user took a wrong token for a user: $out"
[ -z "$out" ] || fail "signed_in_user says something where nobody is signed in: $out"
printf '%s\n' "$TOKEN" > "$WORK/ftoken"
echo "  signed_in_user: the login of the token; nothing and exit 1 for a token Forgejo refuses"

# --- the session start names the forge in its sign-in line ---------------------------------------
S="$WORK/session"; git init -q -b master "$S"; mkdir -p "$S/.ai-core/rules"
git -C "$S" remote add origin "$FORGE_URL/example-org/example-repo.git"; printf '/.ai-core/\n' >> "$S/.git/info/exclude"
printf '# rules\n' > "$S/.ai-core/rules/rules.md"
printf 'FORGE=forgejo\nFORGEJO_URL=%s\nFORGEJO_TOKEN_COMMAND="cat %s"\nUPDATE_CHECK="never"\n' "$FORGE_URL" "$WORK/ftoken" > "$S/.ai-core/config.env"
git -C "$S" commit -q --allow-empty -m "first"
forge_line() { ( cd "$S" && PATH="$PATH_CURL" bash "$ROOT/bin/session-start.sh" 2>&1 | grep -a 'status   :' ); }
[ "$(forge_line)" = "Forgejo status   : ✓ Authenticated on $FORGE_HOST as @tester" ] || fail "the sign-in line of the session start does not name the Forgejo instance: $(forge_line)"
printf 'wrong-token\n' > "$WORK/ftoken"
[ "$(forge_line)" = "Forgejo status   : ✗ $FORGE_HOST: FORGEJO_URL or FORGEJO_TOKEN_COMMAND is not set, or the instance refuses the token" ] || fail "the failed sign-in line of the session start does not name the instance and what is missing: $(forge_line)"
printf '%s\n' "$TOKEN" > "$WORK/ftoken"
echo "  session start: the sign-in line names the instance, and on failure what is missing there"

# --- the settings: none has a default ------------------------------------------------------------
mkdir -p "$WORK/bare-folder/.ai-core"
in_bare() { ( cd "$WORK/bare-folder" && PATH="$PATH_CURL" bash -c '. "$1/lib/forge.sh"; shift; "$@"' _ "$ROOT" "$@" 2>&1 ); }
printf 'FORGE=forgejo\nFORGEJO_TOKEN_COMMAND="cat %s"\n' "$WORK/ftoken" > "$WORK/bare-folder/.ai-core/config.env"
out="$(in_bare forge_host)" && fail "a missing FORGEJO_URL gave a host: $out"
grep -q '^error: FORGEJO_URL is not set' <<< "$out" || fail "a missing FORGEJO_URL is not named: $out"
printf 'FORGE=forgejo\nFORGEJO_URL=%s/some/path\n' "$FORGE_URL" > "$WORK/bare-folder/.ai-core/config.env"
out="$(in_bare forge_host)" && fail "a FORGEJO_URL with a path gave a host: $out"
grep -q 'names a path' <<< "$out" || fail "a FORGEJO_URL with a path is not refused by name: $out"
printf 'FORGE=forgejo\nFORGEJO_URL=%s\n' "$FORGE_URL" > "$WORK/bare-folder/.ai-core/config.env"
out="$(in_bare repo_exists example-org/example-repo)" && fail "a missing FORGEJO_TOKEN_COMMAND was accepted"
grep -q '^error: FORGEJO_TOKEN_COMMAND is not set' <<< "$out" || fail "a missing FORGEJO_TOKEN_COMMAND is not named: $out"
echo "  FORGEJO_URL and FORGEJO_TOKEN_COMMAND: a missing one, and an address with a path, stop the call and are named"

# --- the default branch and the file tree --------------------------------------------------------
forgejo_repo example-org/empty-repo 0
[ -z "$(forge_fn repo_default_branch example-org/empty-repo)" ] || fail "an empty repository has a default branch"
[ "$(forge_fn repo_default_branch example-org/example-repo)" = main ] || fail "a repository with a commit lacks its default branch"
forgejo_repo example-org/big-repo 2305
reset_log
tree="$(forge_fn repo_file_tree example-org/big-repo)" || fail "repo_file_tree of 2305 files: $tree"
[ "$(jq '.tree | length' <<< "$tree")" = 2305 ] && [ "$(jq -r '.truncated' <<< "$tree")" = false ] || fail "repo_file_tree did not return all 2305 files, untruncated"
[ "$(jq -r '.tree[] | select(.type == "blob") | .path' <<< "$tree" | sort -u | wc -l | tr -d ' ')" = 2305 ] || fail "a page was read twice or a file is missing"
[ "$(requests | grep -c 'git/trees/.*recursive=true&per_page=1000&page=')" = 3 ] || fail "2305 files should take three pages: $(requests | grep trees)"
echo "  repo_file_tree: 2305 files in three pages, all of them once, the end named by total_count and not by Forgejo's truncated flag"
# the default branch moves while the pages are read: HEAD is resolved by each request, so the later pages ask for the tree
# the first one answered; planted below, a reader that asks for HEAD every time mixes two trees and says it is whole
forgejo_repo example-org/moving-repo 2305
forgejo_set 's.repos["example-org/moving-repo"].trees={treeA:Array.from({length:2305},(_,i)=>"dir/file-"+i+".txt"),treeB:["moved/only.txt"]};s.repos["example-org/moving-repo"].head="treeA";s.repos["example-org/moving-repo"].head_after_next="treeB"'
reset_log
tree="$(forge_fn repo_file_tree example-org/moving-repo)" || fail "repo_file_tree of a branch that moves between two pages: $tree"
[ "$(jq '.tree | length' <<< "$tree")" = 2305 ] && [ "$(jq -r '[.tree[] | select(.path | startswith("dir/file-"))] | length' <<< "$tree")" = 2305 ] \
  || fail "the listing mixes two trees or is short: $(jq -c '[.tree | length, (.tree[-1].path)]' <<< "$tree")"
[ "$(requests | grep -c 'git/trees/HEAD?')" = 1 ] && [ "$(requests | grep -c 'git/trees/treeA?')" = 2 ] \
  || fail "the later pages are not asked for the tree of the first: $(requests | grep trees)"
echo "  repo_file_tree: a default branch that moves between two pages does not mix two trees; the later pages ask for the tree the first one answered"
inject "page=2" 200 '{"tree":[],"total_count":2305,"page":2,"truncated":true}'
out="$(forge_fn repo_file_tree example-org/big-repo 2>&1)" && fail "repo_file_tree took a listing that ended early for a whole one"
grep -q 'ended at 1000 of 2305 entries' <<< "$out" || fail "an early end is not named: $out"
echo "  planted: a listing that ends before total_count is refused with both numbers"

# --- the pinned reads of the label taxonomy: the head commit, and a file at that commit ----------------------
COMMIT_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; COMMIT_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
forgejo_repo example-org/source-repo 1
forgejo_set 's.repos["example-org/source-repo"].head_commit="'"$COMMIT_A"'";s.repos["example-org/source-repo"].commits={"'"$COMMIT_A"'":{"labels.tsv":"area\tarea:one\n","ai-core.json":"{}\n"},"'"$COMMIT_B"'":{"labels.tsv":"moved\n"}}'
[ "$(forge_fn repo_head_revision example-org/source-repo)" = "$COMMIT_A" ] || fail "repo_head_revision is not the commit of the default branch"
rc=0; forge_fn repo_head_revision example-org/missing >/dev/null 2>&1 || rc=$?
[ "$rc" = 3 ] || fail "repo_head_revision of a repository that is not there is not exit 3 but $rc"
rc=0; forge_fn repo_head_revision example-org/empty-repo >/dev/null 2>&1 || rc=$?
[ "$rc" = 3 ] || fail "repo_head_revision of a repository without a commit is not exit 3 but $rc"
inject "GET /api/v1/repos/example-org/source-repo" 502 "Bad Gateway"
out="$(forge_fn repo_head_revision example-org/source-repo 2>&1)" && fail "repo_head_revision took a 502 for a commit"
grep -q 'cannot read example-org/source-repo - Forgejo answered 502: Bad Gateway' <<< "$out" || fail "a failed head read does not say what Forgejo answered: $out"
echo "  repo_head_revision: the commit of the default branch; exit 3 for a missing repository and an empty one; a 502 is refused with Forgejo's words"
rm -f "$WORK/read-out"
forge_fn repo_file_at example-org/source-repo "$COMMIT_A" labels.tsv "$WORK/read-out" || fail "repo_file_at did not read a file the commit holds"
[ "$(cat "$WORK/read-out")" = "$(printf 'area\tarea:one')" ] || fail "repo_file_at wrote another content than the commit holds: $(cat "$WORK/read-out")"
rc=0; forge_fn repo_file_at example-org/source-repo "$COMMIT_A" repos/none/labels.tsv "$WORK/read-none" >/dev/null 2>&1 || rc=$?
[ "$rc" = 3 ] && [ ! -e "$WORK/read-none" ] || fail "repo_file_at of a file the commit lacks is not exit 3 with no file: $rc"
[ "$(forge_fn repo_file_at example-org/source-repo "$COMMIT_B" labels.tsv "$WORK/read-b" >/dev/null 2>&1; cat "$WORK/read-b")" = moved ] || fail "repo_file_at did not read the commit it was asked for"
inject "contents/labels.tsv" 200 '{"type":"dir","encoding":"base64","size":3,"content":"YWJj"}'
out="$(forge_fn repo_file_at example-org/source-repo "$COMMIT_A" labels.tsv "$WORK/read-dir" 2>&1)" && fail "repo_file_at took a directory for a file"
grep -q 'the answer is no file in base64' <<< "$out" || fail "a wrong shape is not named: $out"
inject "contents/labels.tsv" 200 '{"type":"file","encoding":"base64","size":99,"content":"YWJj"}'
out="$(forge_fn repo_file_at example-org/source-repo "$COMMIT_A" labels.tsv "$WORK/read-short" 2>&1)" && fail "repo_file_at took a content of another size for a whole file"
grep -q 'it holds 3 bytes, and the answer names 99' <<< "$out" && [ ! -e "$WORK/read-short" ] || fail "a size that disagrees is not named, or its file stays: $out"
inject "contents/labels.tsv" 200 '{"type":"file","encoding":"base64","size":3,"content":"***"}'
out="$(forge_fn repo_file_at example-org/source-repo "$COMMIT_A" labels.tsv "$WORK/read-bad" 2>&1)" && fail "repo_file_at took a content that does not decode for a file"
grep -q 'its content does not decode' <<< "$out" || fail "a content that does not decode is not named: $out"
inject "contents/labels.tsv" 502 "Bad Gateway"
out="$(forge_fn repo_file_at example-org/source-repo "$COMMIT_A" labels.tsv "$WORK/read-502" 2>&1)" && fail "repo_file_at took a 502 for a file"
grep -q 'Forgejo answered 502: Bad Gateway' <<< "$out" || fail "a failed file read does not say what Forgejo answered: $out"
echo "  repo_file_at: a file as its commit holds it; exit 3 for a path the commit lacks; a directory, a wrong size, a content that does not decode and a 502 are refused and leave no file"

# --- the check of a commit: every answer of Forgejo, and a failed query --------------------------
sha=0123456789abcdef0123456789abcdef01234567
checked() {  # checked <the combined status Forgejo holds for the sha, as JSON>
  forgejo_set "s.statuses['$sha']=$1"
  forge_fn commit_checked "$F" "$sha" 2>&1
}
check_is() { [ "$2" = "$3" ] || fail "commit_checked, $1: expected '$2', got '$3'"; }
check_is "success" green "$(checked '{"state":"success","total_count":1,"statuses":[{"context":"check","status":"success"}]}')"
check_is "failure" red "$(checked '{"state":"failure","total_count":1,"statuses":[{"context":"check","status":"failure"}]}')"
check_is "error" red "$(checked '{"state":"error","total_count":1}')"
check_is "warning" red "$(checked '{"state":"warning","total_count":1}')"
check_is "pending" pending "$(checked '{"state":"pending","total_count":1}')"
check_is "no status yet ({})" pending "$(checked '{}')"
check_is "a state with total_count 0" pending "$(checked '{"state":"","total_count":0}')"
check_is "a state Forgejo does not have" "unreadable
Forgejo answered 200 with no state the harness knows (skipped) for the checks of $sha" "$(checked '{"state":"skipped","total_count":1}')"
check_is "an answer that is no JSON" "unreadable
Forgejo answered 200 with no state the harness knows (no JSON) for the checks of $sha" "$(checked '"<html>not json</html>"')"
check_is "a broken answer (502)" "unreadable
Forgejo answered 502: Bad Gateway" "$(checked '"broken"')"
git init -q "$WORK/gone"; git -C "$WORK/gone" remote add origin "$FORGE_URL/example-org/gone.git"
[ "$(forge_fn commit_checked "$WORK/gone" "$sha" 2>/dev/null)" = unreadable ] || fail "a repository the instance lacks is not unreadable"
git init -q "$WORK/no-origin"
check_is "a checkout with no origin" "unreadable
$WORK/no-origin has no origin to ask for the checks" "$(forge_fn commit_checked "$WORK/no-origin" "$sha" 2>&1)"
echo "  commit_checked: success is green; failure, error and warning are red; pending and no status yet are pending; a broken answer, an unknown state, a missing repository and no origin are unreadable, with Forgejo's words on stderr"

# --- a repository created on the instance, and one cloned ---------------------------------------
git init -q "$WORK/seed"; git -C "$WORK/seed" commit -q --allow-empty -m "the skeleton"
reset_log
forge_fn repo_create example-org/new-repo "$WORK/seed" || fail "repo_create of an organisation repository"
requests | grep -q '^POST /api/v1/orgs/example-org/repos$' || fail "an organisation repository is not created under /orgs/example-org/repos: $(requests | head -4)"
[ "$(requests | grep -A1 '^POST /api/v1/orgs/example-org/repos$' | tail -n1)" = '{"name":"new-repo","private":true}' ] || fail "the repository is not created private: $(requests | grep -A1 '^POST')"
[ "$(git -C "$REMOTE/example-org/new-repo.git" rev-list --count --all)" = 1 ] || fail "repo_create did not push the checkout to the instance"
[ "$(git -C "$WORK/seed" config --get remote.origin.url)" = "$FORGE_URL/example-org/new-repo.git" ] || fail "the origin of the created repository is not its address on the instance"
[ "$(git -C "$WORK/seed" config --get "$LINE_KEY")" = '!ai-core git-credential' ] || fail "the created repository does not sign in through ai-core git-credential"
git init -q "$WORK/seed2"; git -C "$WORK/seed2" commit -q --allow-empty -m "the skeleton"
reset_log
forge_fn repo_create tester/mine "$WORK/seed2" || fail "repo_create of a repository of the signed-in user"
requests | grep -q '^POST /api/v1/user/repos$' || fail "a repository of the signed-in user is not created under /user/repos: $(requests | head -4)"
out="$(forge_fn repo_create example-org/new-repo "$WORK/seed" 2>&1)" && fail "repo_create took a repository that exists"
grep -q 'cannot create example-org/new-repo - Forgejo answered 409' <<< "$out" || fail "a repository that exists is not refused with Forgejo's answer: $out"
echo "  repo_create: private, under /orgs/<org>/repos or /user/repos, pushed over HTTP with the token, its origin and sign-in line set; an existing one is refused with Forgejo's answer"
# the clone lies in a project folder, as a project harness does: git runs the helper where the clone has no .ai-core
mkdir -p "$WORK/clones/.ai-core"; cp "$F/.ai-core/config.env" "$WORK/clones/.ai-core/"
forge_fn repo_clone example-org/new-repo "$WORK/clones/cloned" || fail "repo_clone"
[ "$(git -C "$WORK/clones/cloned" log -1 --format=%s)" = "the skeleton" ] || fail "repo_clone did not clone the repository"
[ "$(git -C "$WORK/clones/cloned" config --get "$LINE_KEY")" = '!ai-core git-credential' ] || fail "the clone does not keep the line that lets git sign in"
pgit -C "$WORK/clones/cloned" pull -q --ff-only || fail "a pull in the clone does not sign in through the line it kept"
grep -q '^401 GET /example-org/new-repo.git/info/refs' "$GIT_SERVER_LOG" && grep -q '^200 GET /example-org/new-repo.git/info/refs user=ai-core' "$GIT_SERVER_LOG" \
  || fail "the server did not see git ask without a login first and then sign in with the helper's: $(head -6 "$GIT_SERVER_LOG")"
echo "  repo_clone: the clone has the commit and keeps the sign-in line in its own .git/config; git asked, was refused, and signed in with the helper's login"

# --- git is refused without the line, and with a token the server does not know -------------------
git clone -q "$FORGE_URL/example-org/new-repo.git" "$WORK/no-line" 2>/dev/null && fail "a clone without the sign-in line got in"
printf 'stale-token\n' > "$WORK/ftoken"
pgit -C "$WORK/clones/cloned" pull -q --ff-only 2>/dev/null && fail "git signed in with a token the server does not know"
printf '%s\n' "$TOKEN" > "$WORK/ftoken"
pgit -C "$WORK/clones/cloned" pull -q --ff-only || fail "innocent: the helper did not follow the token command back to the token"
printf 'rotated-token\n' | tee "$WORK/ftoken" > "$WORK/server-token"
pgit -C "$WORK/clones/cloned" pull -q --ff-only || fail "the helper did not follow a token that was rotated"
printf '%s\n' "$TOKEN" | tee "$WORK/ftoken" > "$WORK/server-token"
echo "  planted: no sign-in line, and a token the server rejects, each get nowhere; a token rotated in the command is followed at once, nothing is copied"

# --- the token: in no argument, no environment, no file ------------------------------------------
reset_log
forge_fn signed_in_user > /dev/null || fail "the innocent run gets no answer"
forge_fn repo_exists example-org/example-repo || fail "the innocent run gets no answer from repo_exists"
! grep -q "$TOKEN" "$CURL_FAKE_STATE/argv.log" "$CURL_FAKE_STATE/env.log" || fail "innocent: the token stands in curl's arguments or environment"
planted="$WORK/planted"; mkdir -p "$planted"; cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/templates" "$planted/"; cp "$ROOT/VERSION" "$planted/"
sed -i.bak 's|} \| curl --silent|} \| curl -H "$name: $prefix$token" --silent|' "$planted/lib/common.sh"
cmp -s "$ROOT/lib/common.sh" "$planted/lib/common.sh" && fail "the planted copy equals the real lib/common.sh"
reset_log; ROOT_UNDER_TEST="$planted" forge_fn signed_in_user > /dev/null || fail "the copy with the token in an argument should still get its answer"
grep -q "$TOKEN" "$CURL_FAKE_STATE/argv.log" || fail "planted: the token in an argument is not seen in the argument log, so the check cannot go red"
cp "$ROOT/lib/common.sh" "$planted/lib/common.sh"
sed -i.bak 's|^  token=""$|  export FORGEJO_LEAK="$token"; token=""|; s|^  {$|  export FORGEJO_LEAK="$token"; {|' "$planted/lib/common.sh"
reset_log; ROOT_UNDER_TEST="$planted" forge_fn signed_in_user > /dev/null || fail "the copy with the token in the environment should still get its answer"
grep -q "$TOKEN" "$CURL_FAKE_STATE/env.log" || fail "planted: the token in the environment is not seen in the environment log, so the check cannot go red"
cp "$ROOT/lib/common.sh" "$planted/lib/common.sh"
echo "  the token reached Forgejo and stands in no argument and no environment; planted: each is seen"
# a token in a file: nothing the calls wrote holds it but the token command's own file and the stand-in's state; the logs of
# the planted runs hold it on purpose, so they are emptied and an innocent call is logged again
leaked() { grep -rl "$TOKEN" "$WORK" 2>/dev/null | grep -v -e "^$WORK/ftoken$" -e "^$WORK/server-token$" -e "^$CURL_FAKE_STATE/forgejo.json$" -e "^$WORK/planted/" -e "^$WORK/rel-dev/tests/" || true; }
reset_log; forge_fn signed_in_user > /dev/null
[ -z "$(leaked)" ] || fail "the token stands in a file: $(leaked)"

# --- the token transport of every call: refused before curl, never in a trace, the caller's trace kept ---------
# a token Forgejo refuses is named with Forgejo's answer, and the same call with the right one is the innocent case
printf 'wrong-token\n' > "$WORK/ftoken"
out="$(forge_fn forgejo_api "the user" GET /user 2>&1)" && fail "a wrong token was accepted"
grep -q 'cannot read the user - Forgejo answered 401' <<< "$out" || fail "a refused token is not named: $out"
printf '%s\n' "$TOKEN" > "$WORK/ftoken"
forge_fn forgejo_api "the user" GET /user > /dev/null || fail "innocent: the right token is refused"
echo "  a token Forgejo refuses is named with its answer; the right one is taken"
# THE TRACE: under set -x the shell prints every assignment and argument it expands, the token among them, unless the code
# that holds the token switches the trace off, and the caller's setting is back afterwards
traced() { ( cd "$F" && PATH="$PATH_CURL" bash -x -c '. "$1/lib/forge.sh"; forgejo_api "the user" GET /user' _ "${ROOT_UNDER_TEST:-$ROOT}" 2>"$WORK/trace" ); }
traced > /dev/null || fail "forgejo_api under bash -x gets no answer"
grep -q 'forgejo_call' "$WORK/trace" || fail "the trace of bash -x is empty, so the check cannot go red"
! grep -q "$TOKEN" "$WORK/trace" || fail "the token stands in the trace of bash -x: $(grep -m1 "$TOKEN" "$WORK/trace")"
cp "$ROOT/lib/common.sh" "$planted/lib/common.sh"
sed -i.bak 's|traced=1; set +x|traced=1|' "$planted/lib/common.sh"
cmp -s "$ROOT/lib/common.sh" "$planted/lib/common.sh" && fail "the planted copy equals the real lib/common.sh"
ROOT_UNDER_TEST="$planted" traced > /dev/null || fail "the copy that leaves the trace on should still get its answer"
grep -q "$TOKEN" "$WORK/trace" || fail "planted: a token in the trace is not seen, so the check cannot go red"
rm -f "$WORK/trace"
cp "$ROOT/lib/common.sh" "$planted/lib/common.sh"
trace_after() {  # trace_after <on|off> <code>: whether xtrace is on after <code> ran with it <on|off>
  FORGEJO_TOKEN_COMMAND="cat $WORK/ftoken" PATH="$PATH_CURL" bash -c 'cd "$3"; . "$1/lib/common.sh"; [ "$2" != on ] || set -x; eval "$4" 2>/dev/null; case $- in *x*) echo on ;; *) echo off ;; esac' _ "$ROOT" "$1" "$F" "$2" 2>/dev/null
}
for mode in on off; do
  [ "$(trace_after $mode "http_call FORGEJO_TOKEN_COMMAND Authorization 'token ' GET $FORGE_URL/api/v1/user")" = "$mode" ] || fail "http_call changed the trace setting $mode of its caller"
  [ "$(trace_after $mode 'token_from_command FORGEJO_TOKEN_COMMAND >/dev/null')" = "$mode" ] || fail "token_from_command changed the trace setting $mode of its caller"
done
echo "  under bash -x the token is in no trace line, and the caller's trace setting, on or off, is back after a call; planted: a copy that leaves the trace on shows the token in it"
# Fatal token reads must restore tracing before the caller's EXIT trap runs.
trace_on_exit() {  # trace_on_exit <call> <token command>
  ( cd "$F" && PATH="$PATH_CURL" FORGEJO_TOKEN_COMMAND="$2" bash -c '
    . "$1/lib/forge.sh"
    trap '\''case $- in *x*) echo on >&3 ;; *) echo off >&3 ;; esac'\'' EXIT
    set -ex
    eval "$2" >/dev/null
  ' _ "$ROOT" "$1" 3>"$WORK/exit-setting" 2>"$WORK/exit-trace" )
}
http_user="http_call FORGEJO_TOKEN_COMMAND Authorization 'token ' GET $FORGE_URL/api/v1/user"
for command in "exit 7" "printf 'probe\nbad\n'" "printf ''"; do
  for call in 'token_from_command FORGEJO_TOKEN_COMMAND' "$http_user"; do
    trace_on_exit "$call" "$command" && fail "a failing or invalid token was accepted: $call"
    [ "$(cat "$WORK/exit-setting")" = on ] || fail "$call left xtrace off in the EXIT trap"
    ! grep -q probe "$WORK/exit-trace" || fail "a refused token reached the fatal trace"
  done
done
for call in 'token_from_command UNSET_TOKEN_COMMAND' "http_call UNSET_TOKEN_COMMAND Authorization 'token ' GET $FORGE_URL/api/v1/user"; do
  trace_on_exit "$call" "exit 7" && fail "a missing token setting was accepted: $call"
  [ "$(cat "$WORK/exit-setting")" = on ] || fail "$call left xtrace off in the EXIT trap"
done
trace_on_exit 'forgejo_api "the user" GET /user' "printf 'wrong-token\n'" && fail "a refused request was accepted"
[ "$(cat "$WORK/exit-setting")" = on ] || fail "a refused request left xtrace off in the EXIT trap"
grep -q 'Forgejo answered 401' "$WORK/exit-trace" || fail "the refused request was not named"
trace_on_exit 'forgejo_api "the user" GET /user' "cat $WORK/ftoken" || fail "innocent: the right token ended the run"
[ "$(cat "$WORK/exit-setting")" = on ] || fail "innocent: a call that got its answer left xtrace off in the EXIT trap"
echo "  fatal trace restoration: failed, invalid and empty token reads and a refused request leave xtrace on in the EXIT trap; the call that gets its answer leaves it on too"
for call in 'token_from_command FORGEJO_TOKEN_COMMAND >&-' 'token_from_command FORGEJO_TOKEN_COMMAND >/dev/full'; do
  trace_on_exit "$call" "cat $WORK/ftoken" && fail "a failed token write was accepted: $call"
  [ "$(cat "$WORK/exit-setting")" = on ] || fail "$call left xtrace off in the EXIT trap"
  grep -q 'cannot write the token from FORGEJO_TOKEN_COMMAND to standard output' "$WORK/exit-trace" || fail "a failed token write did not name its setting: $call"
  ! grep -q "$TOKEN" "$WORK/exit-trace" || fail "a failed token write exposed the token: $call"
done
echo "  fatal trace restoration: closed standard output and /dev/full fail by setting, restore xtrace in the EXIT trap and expose no token"
# A NUL must be rejected before command substitution can silently remove it.
out="$(cd "$F" && FORGEJO_TOKEN_COMMAND="printf 'probe\000-token\n'" bash -c '. "$1/lib/common.sh"; token_from_command FORGEJO_TOKEN_COMMAND' _ "$ROOT" 2>&1)" && fail "a NUL token was accepted by token_from_command"
grep -q 'FORGEJO_TOKEN_COMMAND printed a token with a control character' <<< "$out" || fail "a NUL token was not refused by its setting: $out"
! grep -qE 'probe|ignored null byte' <<< "$out" || fail "the NUL refusal exposed or discarded token bytes: $out"
echo "  NUL token refusal: token_from_command rejects probe, NUL, -token and newline without exposing the token"
# A TOKEN OF MORE THAN ONE LINE would add a line to curl's configuration: it is refused by the name of the setting, and curl is not called
printf 'first\nrequest = DELETE\n#\n' > "$WORK/ftoken"
reset_log; out="$(forge_fn forgejo_api "the user" GET /user 2>&1)" && fail "a token of three lines was accepted"
grep -q 'the command of FORGEJO_TOKEN_COMMAND printed a token with a control character in it' <<< "$out" || fail "a multiline token is not refused by the name of the setting: $out"
! grep -q 'first' <<< "$out" || fail "the refusal prints the token: $out"
[ ! -s "$CURL_FAKE_STATE/requests.log" ] || fail "curl was called with a refused token"
for token_bytes in 'forgejo-token-4567\r\n' 'forgejo-token\t4567\n'; do
  printf "$token_bytes" > "$WORK/ftoken"
  reset_log; out="$(forge_fn forgejo_api "the user" GET /user 2>&1)" && fail "a token with a carriage return or a tab was accepted: $token_bytes"
  grep -q 'FORGEJO_TOKEN_COMMAND printed a token with a control character' <<< "$out" || fail "a token with a carriage return or a tab is not refused by name: $out"
  [ ! -s "$CURL_FAKE_STATE/requests.log" ] || fail "curl was called with a refused token: $token_bytes"
done
printf 'first\nrequest = DELETE\n#\n' > "$WORK/ftoken"
sed -i.bak '/\*\[\[:cntrl:\]\]\*)/d' "$planted/lib/common.sh"
cmp -s "$ROOT/lib/common.sh" "$planted/lib/common.sh" && fail "the planted copy equals the real lib/common.sh"
reset_log; ROOT_UNDER_TEST="$planted" forge_fn forgejo_api "the user" GET /user >/dev/null 2>&1 || true
grep -q '^DELETE ' "$CURL_FAKE_STATE/requests.log" || fail "planted: a line added to curl's configuration by the token is not seen, so the check cannot go red"
cp "$ROOT/lib/common.sh" "$planted/lib/common.sh"
printf '%s\n' "$TOKEN" > "$WORK/ftoken"
reset_log; forge_fn forgejo_api "the user" GET /user >/dev/null || fail "the innocent one-line token is refused"
echo "  a token with a line break, a carriage return or a tab is refused by the name of the setting before curl is called; planted: without the check the extra line reaches curl"

# --- the helper ---------------------------------------------------------------------------------
helper() {  # helper <directory> <the lines git sends>: the helper itself, as git runs it
  ( cd "$1" && printf "$2" | PATH="$PATH_CURL" bash "${ROOT_UNDER_TEST:-$ROOT}/bin/git-credential.sh" get 2>&1 )
}
mine="protocol=http\nhost=$FORGE_HOST\n"
pair_in() { git -C "$1" config --add "$LINE_KEY" ""; git -C "$1" config --add "$LINE_KEY" '!ai-core git-credential'; }   # the pair init and the clone set
pair_in "$F"
[ "$(helper "$F" "$mine")" = "$(printf 'username=ai-core\npassword=%s' "$TOKEN")" ] || fail "the helper does not answer username ai-core and the token: $(helper "$F" "$mine")"
echo "  git-credential get: username ai-core and the token that FORGEJO_TOKEN_COMMAND prints"
# a clone with no .ai-core of its own, as the clone of a project harness: the settings of the project folder
mkdir -p "$WORK/folder/.ai-core"; cp "$F/.ai-core/config.env" "$WORK/folder/.ai-core/"
git init -q "$WORK/folder/x-ai-core"; pair_in "$WORK/folder/x-ai-core"
[ "$(helper "$WORK/folder/x-ai-core" "$mine")" = "$(printf 'username=ai-core\npassword=%s' "$TOKEN")" ] || fail "a harness clone does not get the token with the settings of its project folder"
git init -q "$WORK/folder/y-ai-core"
! helper "$WORK/folder/y-ai-core" "$mine" | grep -q password || fail "a clone that does not sign in through the helper got a token from the settings of its project folder"
mkdir -p "$WORK/elsewhere"
! helper "$WORK/elsewhere" "$mine" | grep -q password || fail "a folder with no settings at all got a token"
echo "  a clone without an .ai-core of its own that signs in through the helper reads the settings of its project folder; one that does not, and a place with none, get no token"
for other in "protocol=http\nhost=other.example.test\n" "protocol=https\nhost=$FORGE_HOST\n"; do
  out="$(helper "$F" "$other")"
  [ -z "$out" ] || fail "the helper answered for '$other': $out"
done
echo "  planted: another host, and another scheme for the same host, get no answer; innocent: the instance's own host does"
out="$(cd "$F" && FORGEJO_TOKEN_COMMAND="sh -c 'exit 3'" bash "$ROOT/bin/git-credential.sh" get <<< "$(printf "$mine")" 2>&1)" && fail "a failing token command gave an answer"
grep -q 'the command of FORGEJO_TOKEN_COMMAND failed (exit 3)' <<< "$out" || fail "a failing token command is not named: $out"
! grep -q 'password=' <<< "$out" || fail "a failing token command still gave a password"
out="$(cd "$F" && printf 'host=%s\n' "$FORGE_HOST" | bash "$ROOT/bin/git-credential.sh" store 2>&1)" || fail "store failed: $out"
[ -z "$out" ] || fail "store answered something: $out"
out="$(cd "$F" && bash "$ROOT/bin/git-credential.sh" frobnicate 2>&1 < /dev/null)" && fail "an unknown verb was accepted"
grep -q 'usage: ai-core git-credential get|store|erase' <<< "$out" || fail "the usage is not shown: $out"
echo "  a failing token command is named and gives no password; store is accepted and says nothing; an unknown verb shows the usage"
# THE TOKEN IN A TRACE: bash -x prints every assignment and argument it expands, so a helper run under it, as a person
# debugging git's sign-in would, must not expand the token with the trace on
trace="$WORK/helper-trace"
( cd "$F" && printf "$mine" | PATH="$PATH_CURL" bash -x "$ROOT/bin/git-credential.sh" get > /dev/null 2> "$trace" ) || fail "the helper under bash -x did not answer"
! grep -q "$TOKEN" "$trace" || fail "the token stands in the trace of the helper: $(grep -n "$TOKEN" "$trace" | head -2)"
cp "$ROOT/bin/git-credential.sh" "$planted/bin/git-credential.sh"
sed -i.bak '/^set +x$/d' "$planted/bin/git-credential.sh"
cmp -s "$ROOT/bin/git-credential.sh" "$planted/bin/git-credential.sh" && fail "the planted helper equals the real one"
( cd "$F" && printf "$mine" | PATH="$PATH_CURL" bash -x "$planted/bin/git-credential.sh" get > /dev/null 2> "$trace" ) || fail "the planted helper under bash -x did not answer"
grep -q "$TOKEN" "$trace" || fail "planted: a helper that leaves the trace on shows no token in it, so the check cannot go red"
rm -f "$trace"
cp "$ROOT/bin/git-credential.sh" "$planted/bin/git-credential.sh"
# A TOKEN WITH A LINE BREAK in it would add a field to git's answer (git takes the last password it reads), and a carriage
# return or a tab is no character of a token: each is refused by the name of the setting and answered with nothing
for command in "printf 'x\npassword=injected\n'" "printf 'abc\r'" "printf 'a\tb'"; do
  out="$(cd "$F" && FORGEJO_TOKEN_COMMAND="$command" bash "$ROOT/bin/git-credential.sh" get <<< "$(printf "$mine")" 2>&1)" && fail "a token with a control character gave an answer: $command"
  grep -q 'the command of FORGEJO_TOKEN_COMMAND printed a token with a control character in it' <<< "$out" || fail "the control character is not refused by the name of the setting ($command): $out"
  ! grep -q 'password=' <<< "$out" || fail "a token with a control character still gave a password ($command): $out"
done
out="$(cd "$F" && FORGEJO_TOKEN_COMMAND="printf 'probe\000-token\n'" bash "$ROOT/bin/git-credential.sh" get <<< "$(printf "$mine")" 2>&1)" && fail "git-credential accepted a NUL token"
grep -q 'FORGEJO_TOKEN_COMMAND printed a token with a control character' <<< "$out" || fail "git-credential did not name the setting of a NUL token: $out"
! grep -qE 'password=|probe|ignored null byte' <<< "$out" || fail "git-credential exposed or discarded NUL token bytes: $out"
echo "  NUL credential refusal: get rejects probe, NUL, -token and newline without answering a password"
cp "$ROOT/lib/common.sh" "$planted/lib/common.sh"
sed -i.bak '/\*\[\[:cntrl:\]\]\*)/d' "$planted/lib/common.sh"
cmp -s "$ROOT/lib/common.sh" "$planted/lib/common.sh" && fail "the planted copy equals the real lib/common.sh"
out="$(cd "$F" && FORGEJO_TOKEN_COMMAND="printf 'x\npassword=injected\n'" bash "$planted/bin/git-credential.sh" get <<< "$(printf "$mine")" 2>&1)" || fail "the planted helper should still answer"
[ "$(grep -c '^password=' <<< "$out")" = 2 ] || fail "planted: without the check the answer does not hold a second password field, so the check cannot go red: $out"
cp "$ROOT/lib/common.sh" "$planted/lib/common.sh"
echo "  the helper keeps the token out of a bash -x trace; a token with a line break, a carriage return or a tab is refused by the name of the setting and gets no password; planted: each is seen"
# the helper keeps the token out of every file: a planted copy that keeps it is seen by the scan, the real one is clean
[ -z "$(leaked)" ] || fail "the helper wrote the token to a file: $(leaked)"
sed -i.bak "s|^printf 'username|printf '%s' \"\$token\" > \"\$HOME/leak\"; printf 'username|" "$planted/bin/git-credential.sh"
cmp -s "$ROOT/bin/git-credential.sh" "$planted/bin/git-credential.sh" && fail "the planted helper equals the real one"
ROOT_UNDER_TEST="$planted" helper "$F" "$mine" > /dev/null
[ -n "$(leaked)" ] || fail "planted: a helper that writes the token to a file is not seen by the scan, so the check cannot go red"
rm -f "$HOME/leak"
[ -z "$(leaked)" ] || fail "the token stands in a file after the planted helper was removed: $(leaked)"
echo "  planted: a helper that keeps the token in a file is seen; the real one leaves none"
# a config.env that exists and cannot be read: git gets no answer and the file is named, and no token command is taken as unset
. "$ROOT/tests/unreadable.sh"
old_reader_copy "$ROOT" "$WORK/old-reader" || fail "no copy of the harness with the old reader"
cp "$F/.ai-core/config.env" "$WORK/config.env.readable"
make_unreadable "$F/.ai-core/config.env" || fail "the config.env of the checkout cannot be made unreadable"
unreadable_said="$F/.ai-core/config.env exists but cannot be read"
rc=0; out="$(helper "$F" "$mine")" || rc=$?
[ "$rc" -ne 0 ] && grep -qF "$unreadable_said" <<< "$out" && ! grep -qE 'password=|username=' <<< "$out" || fail "the helper gave an answer, or did not name the file, where config.env cannot be read: status $rc: $out"
rc=0; out="$(ROOT_UNDER_TEST="$WORK/old-reader" helper "$F" "$mine")" || rc=$?
grep -qF "$unreadable_said" <<< "$out" && fail "planted: the helper with the old reader still names the unreadable file: $out"
rc=0; out="$(FORGE=forgejo forge_fn token_from_command FORGEJO_TOKEN_COMMAND 2>&1)" || rc=$?
[ "$rc" -ne 0 ] && grep -qF "$unreadable_said" <<< "$out" && ! grep -qF "$TOKEN" <<< "$out" || fail "the token was asked of a command read from nowhere, or the file was not named: status $rc: $out"
grep -q 'the settings that hold FORGEJO_TOKEN_COMMAND cannot be read, so there is no token' <<< "$out" && ! grep -q 'FORGEJO_TOKEN_COMMAND is not set' <<< "$out" || fail "an unreadable file is said to be a missing setting: $out"
rc=0; out="$(FORGE=forgejo ROOT_UNDER_TEST="$WORK/old-reader" forge_fn token_from_command FORGEJO_TOKEN_COMMAND 2>&1)" || rc=$?
grep -qF "$unreadable_said" <<< "$out" && fail "planted: token_from_command with the old reader still names the unreadable file: $out"
grep -q 'FORGEJO_TOKEN_COMMAND is not set' <<< "$out" || fail "planted: the old reader did not turn the unreadable file into a missing setting, so the check cannot go red: $out"
reset_log
rc=0; out="$(forge_fn signed_in_user 2>&1)" || rc=$?
[ "$rc" -ne 0 ] && grep -qF "$unreadable_said" <<< "$out" && [ ! -s "$CURL_FAKE_STATE/requests.log" ] || fail "a call of the forge was made, or the file not named, where config.env cannot be read: status $rc: $out"
chmod 600 "$F/.ai-core/config.env"
[ "$(helper "$F" "$mine")" = "$(printf 'username=ai-core\npassword=%s' "$TOKEN")" ] || fail "innocent: the helper does not answer once the file can be read again"
echo "  an unreadable config.env: the helper answers nothing and names the file, the token is not asked of a command read from nowhere, and no call reaches the forge; planted: with the old reader the file reads as a missing setting"

# --- the line that signs a clone in --------------------------------------------------------------
# a clone that signs in already is announced only for what the user's git configuration lacks: git in a tool's own cache
user_line="credential.$FORGE_URL.helper and $SOURCE_KEY set in the user's git configuration: git in a tool's own cache asks ai-core git-credential too, with the settings of $F/.ai-core/config.env"
[ "$(forge_fn clone_sign_in "$WORK/clones/cloned" dry)" = "${user_line/ set / would be set }" ] || fail "the dry run does not announce only what the user's git configuration lacks: $(forge_fn clone_sign_in "$WORK/clones/cloned" dry)"
[ -z "$(git config --global --get-all "$LINE_KEY" || true)" ] || fail "the dry run wrote the user's git configuration"
[ "$(forge_fn clone_sign_in "$WORK/clones/cloned")" = "$user_line" ] || fail "clone_sign_in did not report what it set in the user's git configuration: $(forge_fn clone_sign_in "$WORK/clones/cloned")"
[ -z "$(forge_fn clone_sign_in "$WORK/clones/cloned" dry)" ] || fail "a clone that signs in everywhere was announced again (dry)"
git init -q "$WORK/fresh"; git -C "$WORK/fresh" remote add origin "$FORGE_URL/example-org/fresh.git"
set_line="$LINE_KEY set in .git/config: git asks ai-core git-credential for the token"
[ "$(forge_fn clone_sign_in "$WORK/fresh" dry)" = "${set_line/ set / would be set }" ] || fail "the dry run does not say what it would set: $(forge_fn clone_sign_in "$WORK/fresh" dry)"
[ -z "$(git -C "$WORK/fresh" config --local --get "$LINE_KEY" || true)" ] || fail "the dry run set the line"
[ "$(forge_fn clone_sign_in "$WORK/fresh")" = "$set_line" ] || fail "clone_sign_in did not set the line"
[ "$(git -C "$WORK/fresh" config --local --get "$LINE_KEY")" = '!ai-core git-credential' ] || fail "the line is not '!ai-core git-credential'"
[ -z "$(forge_fn clone_sign_in "$WORK/fresh")" ] || fail "a second run set the line again or said so"
[ "$(git -C "$WORK/fresh" config --local --get-all "$LINE_KEY")" = "$(printf '\n!ai-core git-credential')" ] || fail "the checkout holds more than the empty entry and the line after two runs: $(git -C "$WORK/fresh" config --local --get-all "$LINE_KEY" | paste -sd'|' -)"
for origin in git@127.0.0.1:example-org/ssh.git https://github.com/example-org/elsewhere.git; do
  git init -q "$WORK/other"; git -C "$WORK/other" remote add origin "$origin"
  [ -z "$(forge_fn clone_sign_in "$WORK/other")" ] || fail "a line was set for the origin $origin"
  [ -z "$(git -C "$WORK/other" config --local --get-regexp '^credential' || true)" ] || fail "a credential line stands in a checkout with the origin $origin"
  rm -rf "$WORK/other"
done
mkdir -p "$WORK/plain-folder"
[ -z "$(forge_fn clone_sign_in "$WORK/plain-folder")" ] || fail "a folder that is no checkout was signed in"
[ -z "$(cd "$F" && PATH="$PATH_CURL" FORGE=github bash -c '. "$1/lib/forge.sh"; clone_sign_in "$2"' _ "$ROOT" "$WORK/fresh")" ] || fail "GitHub's clone_sign_in says something"
echo "  clone_sign_in: one line in the clone's own .git/config, once; a dry run writes nothing; an ssh origin and another host get none"

# --- the helpers git already has -------------------------------------------------------------------
# A store or a cache in the user's configuration is asked before the harness's line and answers first; it keeps the token the
# line gave it, and answers with that after the token command has changed. The line therefore starts with an empty entry, which
# drops every helper collected before it. Real git, offline: credential fill and approve under a store helper in a scratch HOME.
fill() {  # fill <checkout>: what git credential fill answers for the instance
  ( cd "$1" && printf 'protocol=%s\nhost=%s\n\n' "${FORGE_URL%%://*}" "$FORGE_HOST" | PATH="$PATH_CURL" GIT_TERMINAL_PROMPT=0 FORGEJO_URL="$FORGE_URL" FORGEJO_TOKEN_COMMAND="cat $WORK/ftoken" git credential fill 2>/dev/null )
}
signs_in_alone() {  # signs_in_alone <checkout>: fill answers the token, approve stores it nowhere else, and a rotated token is followed
  local got
  rm -f "$HOME/.git-credentials"
  got="$(fill "$1")"
  [ "$(grep '^password=' <<< "$got")" = "password=$TOKEN" ] || return 1
  ( cd "$1" && printf '%s\n\n' "$got" | PATH="$PATH_CURL" git credential approve )
  [ ! -s "$HOME/.git-credentials" ] || return 1
  printf 'rotated-token\n' > "$WORK/ftoken"
  got="$(fill "$1" | grep '^password=')"
  printf '%s\n' "$TOKEN" > "$WORK/ftoken"
  [ "$got" = "password=rotated-token" ]
}
git config --global --add "$LINE_KEY" ""
git config --global --add "$LINE_KEY" '!ai-core git-credential'
git config --global --add credential.helper store
git init -q "$WORK/stored-fresh"; git -C "$WORK/stored-fresh" remote add origin "$FORGE_URL/example-org/stored.git"
forge_fn clone_sign_in "$WORK/stored-fresh" > /dev/null
signs_in_alone "$WORK/stored-fresh" || fail "clone_sign_in: an inherited URL pair hid the global store and kept the token"
[ "$(git -C "$WORK/stored-fresh" config --local --get-all "$LINE_KEY")" = "$(printf '\n!ai-core git-credential')" ] || fail "clone_sign_in installed no local reset/helper pair under the inherited pair"
git init -q "$WORK/stored-old"; git -C "$WORK/stored-old" remote add origin "$FORGE_URL/example-org/stored.git"
git -C "$WORK/stored-old" config "$LINE_KEY" '!ai-core git-credential'
signs_in_alone "$WORK/stored-old" && fail "planted: a line without the empty entry signs in alone under an inherited store, so the check cannot go red"
rm -f "$HOME/.git-credentials"
forge_fn clone_sign_in "$WORK/stored-old" > /dev/null
signs_in_alone "$WORK/stored-old" || fail "clone_sign_in did not repair the checkout that holds the line without the empty entry"
git init -q "$WORK/stored-seed"; git -C "$WORK/stored-seed" commit -q --allow-empty -m "the skeleton"
forge_fn repo_create example-org/stored "$WORK/stored-seed" || fail "repo_create under an inherited store"
signs_in_alone "$WORK/stored-seed" || fail "repo_create: an inherited store was asked, or kept the token, or answered with an old one"
[ "$(git -C "$WORK/stored-seed" config --local --get-all "$LINE_KEY")" = "$(printf '\n!ai-core git-credential')" ] || fail "repo_create installed no local reset/helper pair under the inherited pair"
forge_fn repo_clone example-org/stored "$WORK/clones/stored-clone" || fail "repo_clone under an inherited store"
signs_in_alone "$WORK/clones/stored-clone" || fail "repo_clone: an inherited store was asked, or kept the token, or answered with an old one"
[ "$(git -C "$WORK/clones/stored-clone" config --local --get-all "$LINE_KEY")" = "$(printf '\n!ai-core git-credential')" ] || fail "repo_clone installed no local reset/helper pair under the inherited pair"
pgit -C "$WORK/clones/stored-clone" pull -q --ff-only || fail "a pull under an inherited store does not sign in through the line"
git config --global --unset-all credential.helper
git config --global --unset-all "$LINE_KEY"
rm -f "$HOME/.git-credentials"
echo "  clone_sign_in, repo_create and repo_clone: an empty entry drops the helpers git already has, so a store is neither asked nor fed and a rotated token is followed; planted: the line without it feeds the store"

# --- git outside every checkout: the cache of a package manager -------------------------------------
# A tool with git repositories of its own, such as `dart pub get` with a git dependency, runs `git --git-dir <cache>` where
# no .git/config names the helper. init registers the pair and the settings file of the checkout in the user's git
# configuration, here the scratch file of GIT_CONFIG_GLOBAL, and the helper reads that file when git asks. The checkouts
# below carry their own config.env in a commit, so init keeps it and a test edits it as a person would.
. "$ROOT/tests/unreadable.sh"
user_sign_in_reset
proj="$WORK/cache-proj"; mkdir -p "$proj" "$WORK/outside"
: > "$WORK/spy.log"
cat > "$WORK/token spy.sh" <<SPY
#!/bin/sh
{ echo "args: \$*"; env; echo "--"; } >> "$WORK/spy.log"
exec cat "\$1"
SPY
chmod +x "$WORK/token spy.sh"
spy_command="sh '$WORK/token spy.sh' '$WORK/ftoken'"
spy_runs() { grep -c '^args:' "$WORK/spy.log" || true; }
make_shop() {  # make_shop <repository> <folder> <token command>: a checkout of example-org/<repository> in the project folder
  local seed="$WORK/seed-$1"
  git init -q "$seed"; mkdir -p "$seed/.ai-core"
  printf 'FORGE=forgejo\nFORGEJO_URL=%s\nFORGEJO_TOKEN_COMMAND="%s"\nUPDATE_CHECK="never"\n' "$FORGE_URL" "$3" > "$seed/.ai-core/config.env"
  git -C "$seed" add -A; git -C "$seed" commit -q -m "first"
  git init -q --bare -b main "$REMOTE/example-org/$1.git"; git -C "$seed" push -q "$REMOTE/example-org/$1.git" HEAD:refs/heads/main
  git clone -q "$REMOTE/example-org/$1.git" "$proj/$2"
  git -C "$proj/$2" remote set-url origin "$FORGE_URL/example-org/$1.git"
}
init_in() {  # init_in <checkout or worktree>: ai-core init as start-issue runs it in a new worktree, and what it reports
  ( cd "$1" && PATH="${EXTRA_PATH:+$EXTRA_PATH:}$PATH_CURL" bash "${ROOT_UNDER_TEST:-$ROOT}/bin/init.sh" "$1" --no-doctor 2>&1 )
}
registered() { git config --global --get-all "$SOURCE_KEY" || true; }
cache_fetch() {  # cache_fetch <git dir> <repository> [folder to run in]: git as a package manager runs it, with no FORGEJO setting and no git environment configuration
  ( cd "${3:-$WORK/outside}" && env -u FORGEJO_URL -u FORGEJO_TOKEN_COMMAND -u GIT_CONFIG_COUNT PATH="$PATH_CURL" \
      git --git-dir="$1" fetch --quiet "$FORGE_URL/example-org/$2.git" '+refs/heads/*:refs/heads/*' 2>&1 )
}
fetched() {  # fetched <repository> [folder to run in]: a fresh cache fetched from it holds the tip the server has
  local cache
  cache="$(mktemp -d "$WORK/cache.XXXXXX")"; git init -q --bare "$cache"
  FETCH_SAID="$(cache_fetch "$cache" "$1" "${2:-}")" || return 1
  [ "$(git --git-dir="$cache" rev-parse refs/heads/main)" = "$(git --git-dir="$REMOTE/example-org/$1.git" rev-parse refs/heads/main)" ]
}
served_since() { tail -n +$(($1 + 1)) "$GIT_SERVER_LOG"; }   # served_since <lines the log had>: what the server saw after
log_lines() { wc -l < "$GIT_SERVER_LOG" | tr -d ' '; }

make_shop shop-a shop-a "$spy_command"
# planted: the init of before, which sets the line in the checkout alone: the cache gets no sign-in
old="$WORK/old-init"; harness_copy "$ROOT" "$old"
sed -i.bak 's|^    user_sign_in_set "\$url" "\$settings"$|    :|' "$old/lib/forgejo/forge.sh"
cmp -s "$ROOT/lib/forgejo/forge.sh" "$old/lib/forgejo/forge.sh" && fail "the planted old init equals the real one"
ROOT_UNDER_TEST="$old" init_in "$proj/shop-a" > "$WORK/init-old.log" || fail "the planted old init failed: $(tail -5 "$WORK/init-old.log")"
[ "$(git -C "$proj/shop-a" config --local --get-all "$LINE_KEY")" = "$(printf '\n!ai-core git-credential')" ] || fail "the old init did not even set the line in the checkout, so the plant proves nothing"
[ -z "$(git config --global --get-all "$LINE_KEY" || true)" ] || fail "the old init wrote the user's git configuration"
mark="$(log_lines)"
fetched shop-a && fail "planted: a cache fetch signed in under the old init, so criterion 1 cannot go red"
served_since "$mark" | grep -q '^401 GET /example-org/shop-a.git/info/refs' && ! served_since "$mark" | grep -q '^200 ' || fail "planted: the old init's cache fetch was not refused with a 401 alone: $(served_since "$mark" | head -4)"
echo "  planted: the init that sets the line in the checkout alone leaves a cache fetch with the server's 401 and nothing more"

# dry run, report, idempotence, the references and nothing else, and what is not ours
git config --global user.name "Some One"
git config --global --add credential.https://other.example.test.helper store
git config --global core.editor "true"
cp "$GIT_CONFIG_GLOBAL" "$WORK/gitconfig.before"
dry="$(cd "$proj/shop-a" && PATH="$PATH_CURL" bash "$ROOT/bin/init.sh" . --no-doctor --dry-run 2>&1)" || fail "init --dry-run: $dry"
grep -qF "  credential.$FORGE_URL.helper and $SOURCE_KEY would be set in the user's git configuration" <<< "$dry" || fail "the dry run of init does not announce the user's git configuration: $dry"
cmp -s "$GIT_CONFIG_GLOBAL" "$WORK/gitconfig.before" || fail "the dry run of init wrote the user's git configuration"
out="$(init_in "$proj/shop-a")" || fail "init: $out"
grep -qF "  credential.$FORGE_URL.helper and $SOURCE_KEY set in the user's git configuration: git in a tool's own cache asks ai-core git-credential too, with the settings of $proj/shop-a/.ai-core/config.env" <<< "$out" || fail "init does not report what it set in the user's git configuration: $out"
[ "$(git config --global --get-all "$LINE_KEY")" = "$(printf '\n!ai-core git-credential')" ] || fail "the user's git configuration holds more than the empty value and the helper"
[ "$(registered)" = "$proj/shop-a/.ai-core/config.env" ] || fail "the user's git configuration does not name the settings file once: $(registered)"
[ "$(git config --global --get-all user.name)" = "Some One" ] && [ "$(git config --global --get-all credential.https://other.example.test.helper)" = store ] \
  && [ "$(git config --global --get-all core.editor)" = true ] || fail "init changed a setting that is not its own"
! grep -qE "$(cat "$WORK/ftoken")|token spy|ftoken" "$GIT_CONFIG_GLOBAL" || fail "the user's git configuration holds a token or a token command: $(cat "$GIT_CONFIG_GLOBAL")"
cp "$GIT_CONFIG_GLOBAL" "$WORK/gitconfig.after"
out="$(init_in "$proj/shop-a")" || fail "second init: $out"
! grep -q "user's git configuration" <<< "$out" && cmp -s "$GIT_CONFIG_GLOBAL" "$WORK/gitconfig.after" || fail "a second init reports or changes the user's git configuration: $out"
echo "  init: the dry run announces and writes nothing; the run sets the pair and the path of the settings file, no token and no command, leaves every other setting as it was, and a second run says nothing"

# criterion 1 and 2: a cache fetch outside every checkout, from the folder of a worktree as a package manager runs, with the line of the checkout absent
git -C "$proj/shop-a" worktree add -q -b issue-1-a "$proj/wt-a1"
git -C "$proj/shop-a" worktree add -q -b issue-2-a "$proj/wt-a2"
out="$(init_in "$proj/wt-a1")" || fail "init in a worktree: $out"
! grep -q "user's git configuration" <<< "$out" || fail "init in a worktree set what the checkout had set already: $out"
init_in "$proj/wt-a2" > /dev/null || fail "init in a second worktree"
[ "$(registered)" = "$proj/shop-a/.ai-core/config.env" ] || fail "a worktree registered its own copy of the settings: $(registered)"
git -C "$proj/shop-a" config --local --unset-all "$LINE_KEY"
for where in "$WORK/outside" "$proj/shop-a" "$proj/wt-a1"; do
  mark="$(log_lines)"
  fetched shop-a "$where" || fail "a cache fetch run in $where did not sign in: $FETCH_SAID"
  served_since "$mark" | grep -q '^401 GET /example-org/shop-a.git/info/refs' && served_since "$mark" | grep -q '^200 GET /example-org/shop-a.git/info/refs user=ai-core' \
    || fail "the server did not see git ask without a login first and then sign in with the helper's: $(served_since "$mark" | head -4)"
done
echo "  criteria 1 and 2: git --git-dir in an empty cache signs in with no variable set and no line in the checkout, run outside the project, in the checkout and in a worktree; the server refused first and then answered the helper's login"

# a release script clones other repositories of the instance into a temporary folder, outside every checkout, with no FORGEJO_URL
fresh_clone() {  # fresh_clone <repository> <folder>: git clone as that script runs it, from the temporary folder it made
  local temporary
  temporary="$(mktemp -d "$WORK/temporary.XXXXXX")"
  ( cd "$temporary" && env -u FORGEJO_URL -u FORGEJO_TOKEN_COMMAND -u GIT_CONFIG_COUNT PATH="$PATH_CURL" git clone --quiet "${3:-$FORGE_URL}/example-org/$1.git" "$2" 2>&1 )
}
user_sign_in_reset
ROOT_UNDER_TEST="$old" init_in "$proj/shop-a" > /dev/null || fail "the planted old init failed again"
rm -rf "$WORK/clone-old"
fresh_clone shop-a "$WORK/clone-old" && fail "planted: a fresh clone signed in with the helper only in a checkout's .git/config, so the check cannot go red"
init_in "$proj/shop-a" > /dev/null || fail "init after the planted old one failed"
mark="$(log_lines)"; runs="$(spy_runs)"
rm -rf "$WORK/clone-new"
fresh_clone shop-a "$WORK/clone-new" || fail "a fresh clone outside every checkout did not sign in through the user's git configuration"
[ "$(git -C "$WORK/clone-new" rev-parse HEAD)" = "$(git --git-dir="$REMOTE/example-org/shop-a.git" rev-parse refs/heads/main)" ] || fail "the fresh clone does not hold the commit of the server"
served_since "$mark" | grep -q '^401 GET /example-org/shop-a.git/info/refs' && served_since "$mark" | grep -q '^200 GET /example-org/shop-a.git/info/refs user=ai-core' || fail "the server did not see the fresh clone ask without a login first and then sign in with the helper's"
[ "$(spy_runs)" -gt "$runs" ] || fail "the token command did not run for the fresh clone"
runs="$(spy_runs)"
rm -rf "$WORK/clone-other"
fresh_clone shop-a "$WORK/clone-other" "http://127.0.0.1:1" > /dev/null && fail "a clone of another host went through"
[ "$(spy_runs)" = "$runs" ] || fail "the token command ran for a clone of another host"
echo "  a fresh git clone in a temporary folder outside every checkout, with no FORGEJO_URL, signs in through the user's git configuration; planted: with the helper only in the checkout's .git/config it gets the 401 and nothing more; innocent: a clone of another host is not answered and runs no token command"

# nothing is copied, so a rotated token and a changed token command are followed at once, and the copy of the settings that a
# worktree holds decides nothing: its folder is where a package manager runs git, with GIT_DIR naming the cache
shop_config() { printf 'FORGE=forgejo\nFORGEJO_URL=%s\nFORGEJO_TOKEN_COMMAND="%s"\nUPDATE_CHECK="never"\n' "${3:-$FORGE_URL}" "$2" > "$1/.ai-core/config.env"; }
plant_replace() {  # plant_replace <copy of the harness> <file in it> <text> <what takes its place>: the defect, as a copy of the code without that text
  OLD="$3" NEW="$4" FILE="$1/$2" node -e "const fs=require('fs');const t=fs.readFileSync(process.env.FILE,'utf8');if(!t.includes(process.env.OLD))process.exit(3);fs.writeFileSync(process.env.FILE,t.split(process.env.OLD).join(process.env.NEW))" \
    || fail "the planted copy of $2 does not hold the text it replaces: $3"
}
plant() {  # plant <name> <file in the copy> <text> <what takes its place>: a new copy of the harness with that one defect; PLANTED is its folder
  PLANTED="$WORK/planted-$1"; harness_copy "$ROOT" "$PLANTED"; plant_replace "$PLANTED" "$2" "$3" "$4"
}
wt="$proj/wt-a1"
printf 'rotated-3\n' | tee "$WORK/ftoken" > "$WORK/server-token"
fetched shop-a "$wt" || fail "a cache fetch did not follow a rotated token: $FETCH_SAID"
printf 'second-token\n' > "$WORK/ftoken-2"; cp "$WORK/ftoken-2" "$WORK/server-token"
shop_config "$proj/shop-a" "sh '$WORK/token spy.sh' '$WORK/ftoken-2'"
fetched shop-a "$wt" || fail "a cache fetch did not follow a changed token command, or took the stale copy of the worktree: $FETCH_SAID"
fetched shop-a || fail "a cache fetch outside the project did not follow a changed token command: $FETCH_SAID"
# the helper looks for the checkout git runs in without the GIT_DIR of the cache: a worktree of a checkout that signs in
# through the helper takes its checkout's settings even where no file is registered
plant stale bin/git-credential.sh 'unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR' ':'
cp "$GIT_CONFIG_GLOBAL" "$WORK/gitconfig.kept"; git config --global --unset-all "$SOURCE_KEY"
fetched shop-a "$wt" || fail "a cache fetch in a worktree of a checkout that signs in did not take the settings of its checkout: $FETCH_SAID"
ROOT_UNDER_TEST="$PLANTED" fetched shop-a "$wt" && fail "planted: a helper that keeps the GIT_DIR of the cache still found the checkout git runs in, so the check cannot go red"
cp "$WORK/gitconfig.kept" "$GIT_CONFIG_GLOBAL"
shop_config "$proj/shop-a" "$spy_command"; printf '%s\n' "$TOKEN" | tee "$WORK/ftoken" > "$WORK/server-token"
echo "  a rotated token and a changed token command are followed at once, and the copy in the worktree decides nothing; planted: a helper that keeps the GIT_DIR of the cache does not find the checkout git runs in"

# a settings file that no init registered, in a plain folder or in a clone nobody initialized that tracks one, does not
# answer for git run there: its token command does not run, and the registered file answers instead
mkdir -p "$WORK/foreign/plain/.ai-core" "$WORK/foreign/clone/.ai-core"
printf 'FORGEJO_URL=%s\nFORGEJO_TOKEN_COMMAND="touch %s; echo foreign-token"\n' "$FORGE_URL" "$WORK/foreign-ran" > "$WORK/foreign/plain/.ai-core/config.env"
git init -q "$WORK/foreign/clone"; cp "$WORK/foreign/plain/.ai-core/config.env" "$WORK/foreign/clone/.ai-core/"
git -C "$WORK/foreign/clone" add -A; git -C "$WORK/foreign/clone" commit -q -m 'tracks settings of its own'
for where in "$WORK/foreign/plain" "$WORK/foreign/clone"; do
  rm -f "$WORK/foreign-ran"
  fetched shop-a "$where" || fail "a cache fetch run in $where did not sign in with the registered file: $FETCH_SAID"
  [ ! -e "$WORK/foreign-ran" ] || fail "the token command of a settings file nobody registered ran for git in $where"
done
plant anyfolder bin/git-credential.sh '{ [ -n "$top" ] && sign_in_line_stands "$top" "$requested"; }' 'true'
rm -f "$WORK/foreign-ran"
ROOT_UNDER_TEST="$PLANTED" fetched shop-a "$WORK/foreign/clone" && fail "planted: a helper that takes the settings of any folder still signed in with the registered file"
[ -e "$WORK/foreign-ran" ] || fail "planted: a helper that takes the settings of any folder did not run the token command of that folder, so the check cannot go red"
rm -f "$WORK/foreign-ran"
echo "  a settings file nobody registered, in a plain folder or in a clone nobody initialized, runs no token command, and the registered file answers; planted: a helper that takes the settings of any folder runs that file's command and sends what it prints"

# another host, port and scheme get no token and the token command does not run; store and erase do nothing
helper_out() {  # helper_out <the lines git sends> [get|store|erase]: the helper as git runs it for a repository outside every checkout
  ( cd "$WORK/outside" && printf "$1" | env -u FORGEJO_URL -u FORGEJO_TOKEN_COMMAND PATH="$PATH_CURL" bash "${ROOT_UNDER_TEST:-$ROOT}/bin/git-credential.sh" "${2:-get}" 2>&1 )
}
mine="protocol=http\nhost=$FORGE_HOST\n"
asks="$(printf 'username=ai-core\npassword=%s' "$TOKEN")"
[ "$(helper_out "$mine")" = "$asks" ] || fail "the helper does not answer from the registered settings file: $(helper_out "$mine")"
runs="$(spy_runs)"
for other in "protocol=http\nhost=other.example.test\n" "protocol=http\nhost=127.0.0.1:1\n" "protocol=https\nhost=$FORGE_HOST\n"; do
  ! grep -qE 'username=|password=' <<< "$(helper_out "$other" || true)" || fail "the helper answered outside every checkout for '$other'"
done
for verb in store erase; do
  [ -z "$(helper_out "${mine}username=ai-core\npassword=$TOKEN\n" "$verb")" ] || fail "$verb answered something"
done
[ "$(spy_runs)" = "$runs" ] || fail "the token command ran for another host, another port, another scheme, store or erase"
[ "$(git config --global --get-all "$SOURCE_KEY")" = "$proj/shop-a/.ai-core/config.env" ] && cmp -s "$GIT_CONFIG_GLOBAL" "$WORK/gitconfig.after" || fail "store or erase changed the user's git configuration"
plant everyhost bin/git-credential.sh 'if [ "$url" = "$requested" ]; then' 'if true; then'
[ -n "$(cd "$F" && printf 'protocol=http\nhost=other.example.test\n' | PATH="$PATH_CURL" ROOT_UNDER_TEST="$PLANTED" bash "$PLANTED/bin/git-credential.sh" get 2>&1)" ] || fail "planted: a helper with no host check answered nobody, so the check cannot go red"
echo "  another host, another port and http against https get no answer and no run of the token command, outside every checkout; store and erase do nothing; planted: a helper without the host check answers any host"

# a helper that git already has for the instance is neither asked nor given the token: the empty value comes first
cat > "$WORK/spy-store" <<SPY
#!/bin/sh
echo "\$1" >> "$WORK/store-runs"
SPY
chmod +x "$WORK/spy-store"; : > "$WORK/store-runs"
user_sign_in_reset
git config --global --add credential.helper "!$WORK/spy-store"
init_in "$proj/shop-a" > /dev/null || fail "init under an inherited helper failed"
fetched shop-a || fail "a cache fetch under an inherited helper did not sign in: $FETCH_SAID"
[ ! -s "$WORK/store-runs" ] || fail "an inherited helper was asked or given the token: $(tr '\n' ' ' < "$WORK/store-runs")"
plant noreset lib/forgejo/forge.sh 'git config --global --replace-all "credential.$url.helper" ""' 'true'
user_sign_in_reset
ROOT_UNDER_TEST="$PLANTED" init_in "$proj/shop-a" > /dev/null || fail "the planted init without the empty value failed"
ROOT_UNDER_TEST="$PLANTED" fetched shop-a || true
[ -s "$WORK/store-runs" ] || fail "planted: the pair without its empty value did not ask the inherited helper, so the check cannot go red"
: > "$WORK/store-runs"; user_sign_in_reset
init_in "$proj/shop-a" > /dev/null || fail "init after the planted one failed"
fetched shop-a || fail "innocent: the cache fetch after the real init did not sign in: $FETCH_SAID"
[ ! -s "$WORK/store-runs" ] || fail "the real init left the inherited helper in the chain: $(tr '\n' ' ' < "$WORK/store-runs")"
git config --global --fixed-value --unset credential.helper "!$WORK/spy-store"
echo "  an inherited store or cache is neither asked nor given the token; planted: a pair without its empty value asks it and feeds it"

# a FORGEJO_URL with credentials, a path, a query or a fragment is refused, and the credentials are not repeated
for bad in 'https://user:secret@forge.example.test|must not carry credentials' 'https://forge.example.test/api/v1|names a path, a query or a fragment' \
           'https://forge.example.test?x=1|names a path, a query or a fragment' 'https://forge.example.test#top|names a path, a query or a fragment'; do
  url="${bad%%|*}"; said="${bad#*|}"
  out="$(FORGEJO_URL="$url" forge_fn clone_sign_in "$WORK/fresh" 2>&1)" && fail "clone_sign_in took $url"
  grep -q "$said" <<< "$out" && ! grep -q secret <<< "$out" || fail "$url is not refused by name, or its password is repeated: $out"
  out="$(cd "$F" && printf "$mine" | PATH="$PATH_CURL" FORGEJO_URL="$url" bash "$ROOT/bin/git-credential.sh" get 2>&1)" && fail "the helper took the settings of $url"
  ! grep -qE 'password=|secret' <<< "$out" || fail "the helper answered or repeated the password for $url: $out"
done
! grep -qs secret "$GIT_CONFIG_GLOBAL" "$WORK/fresh/.git/config" || fail "a credential of the address reached a git configuration"
echo "  FORGEJO_URL with credentials, a path, a query or a fragment is refused by clone_sign_in and by the helper, and no message or configuration repeats the password"

# two settings files for one instance: equivalent credentials work, differing credentials refuse
make_shop shop-b "shop b's folder" "$spy_command"
shop_b="$proj/shop b's folder"
out="$(init_in "$shop_b")" || fail "init of a second checkout: $out"
[ "$(registered | sort)" = "$(printf '%s\n%s\n' "$proj/shop-a/.ai-core/config.env" "$shop_b/.ai-core/config.env" | sort)" ] || fail "the user's git configuration does not name both files once: $(registered)"
: > "$WORK/spy.log"
fetched shop-a || fail "two files with the same token did not sign in: $FETCH_SAID"
[ "$(spy_runs)" -ge 2 ] || fail "the helper did not ask both files for their token: $(spy_runs)"
! grep -qF "$TOKEN" "$WORK/spy.log" || fail "the token stands in the arguments or the environment of a token command"
plant leak lib/forgejo/forge.sh 'token="$candidate"; first="$file"; rc=0' 'token="$candidate"; first="$file"; rc=0; export FORGEJO_LEAK="$token"'
ROOT_UNDER_TEST="$PLANTED" fetched shop-a || fail "the planted copy that leaks the token should still sign in: $FETCH_SAID"
grep -qF "$TOKEN" "$WORK/spy.log" || fail "planted: a token exported to the next token command is not seen in its environment, so the check cannot go red"
: > "$WORK/spy.log"
printf 'other-token\n' > "$WORK/ftoken-b"
shop_config "$shop_b" "sh '$WORK/token spy.sh' '$WORK/ftoken-b'"
refuses() {  # refuses <what it must name>: the helper gives no answer, says why and prints no token
  local rc=0 out
  out="$(helper_out "$mine")" || rc=$?
  [ "$rc" -ne 0 ] && grep -qF -- "$1" <<< "$out" && ! grep -qE 'username=|password=' <<< "$out" && ! grep -qE "$TOKEN|other-token" <<< "$out"
}
refuses "yield different tokens" || fail "the helper did not refuse two files with different tokens, or printed a token: $(helper_out "$mine" || true)"
grep -qF "$proj/shop-a/.ai-core/config.env" <<< "$(helper_out "$mine" || true)" && grep -qF "$shop_b/.ai-core/config.env" <<< "$(helper_out "$mine" || true)" || fail "the refusal does not name both files"
mark="$(log_lines)"
fetched shop-a && fail "a cache fetch signed in with two different tokens registered"
! served_since "$mark" | grep -q '^200 ' || fail "the server answered a fetch whose helper had to refuse"
# the settings of the checkout git runs in stay authoritative: they answer, and the registered files are not consulted
in_checkout() {  # in_checkout <checkout>: the helper as git runs it inside that checkout
  ( cd "$1" && printf "$mine" | env -u FORGEJO_URL -u FORGEJO_TOKEN_COMMAND PATH="$PATH_CURL" bash "${ROOT_UNDER_TEST:-$ROOT}/bin/git-credential.sh" get 2>&1 )
}
[ "$(in_checkout "$proj/shop-a")" = "$asks" ] || fail "the helper in a checkout did not answer with the settings of that checkout while the registered files differ: $(in_checkout "$proj/shop-a")"
plant registryfirst bin/git-credential.sh 'if [ "$url" = "$requested" ]; then' 'if false; then'
! grep -q '^password=' <<< "$(ROOT_UNDER_TEST="$PLANTED" in_checkout "$proj/shop-a")" || fail "planted: a helper that asks the registered files before the checkout still answered where they differ, so the check cannot go red"
init_in "$proj/shop-a" > /dev/null || fail "init of the first checkout, after the second"; init_in "$shop_b" > /dev/null || fail "init of the second checkout, again"
refuses "yield different tokens" || fail "the order of the inits decided between two different tokens"
plant nocompare lib/forgejo/forge.sh 'elif [ "$candidate" != "$token" ]; then' 'elif false; then'
grep -q '^password=' <<< "$(ROOT_UNDER_TEST="$PLANTED" helper_out "$mine")" || fail "planted: a helper that never compares the tokens still refused, so the check cannot go red"
# an unreadable file refuses by the rule of the config reader, and a file that is not there supplies nothing
make_unreadable "$shop_b/.ai-core/config.env" || fail "the settings file cannot be made unreadable"
refuses "exists but cannot be read" || fail "an unreadable registered file did not refuse: $(helper_out "$mine" || true)"
old_reader_copy "$ROOT" "$WORK/old-reader" || fail "no copy of the harness with the old reader"
grep -q '^password=' <<< "$(ROOT_UNDER_TEST="$WORK/old-reader" helper_out "$mine")" || fail "planted: with the old reader the unreadable file did not read as a missing setting, so the check cannot go red"
chmod 600 "$shop_b/.ai-core/config.env"
shop_config "$shop_b" "$spy_command"
[ "$(helper_out "$mine")" = "$asks" ] || fail "innocent: two files with the same token do not answer once the file reads again"
mv "$shop_b/.ai-core/config.env" "$WORK/b-config.kept"
[ "$(helper_out "$mine")" = "$asks" ] || fail "a registered file that is not there blocked the other"
mv "$WORK/b-config.kept" "$shop_b/.ai-core/config.env"
echo "  two registered files with the same token sign in; different tokens, an unreadable file and the order of the inits: refused, both files named, no token printed; a file that is gone supplies none; planted: no comparison and the old reader each answer"

# a file whose instance changed supplies nothing, and the token command it names does not run
git config --global --fixed-value --unset "$SOURCE_KEY" "$proj/shop-a/.ai-core/config.env"
shop_config "$shop_b" "$spy_command" "http://other.example.test"
runs="$(spy_runs)"
out="$(helper_out "$mine")" && ! grep -qE 'username=|password=' <<< "$out" || fail "a file that names another instance supplied a token: $out"
[ "$(spy_runs)" = "$runs" ] || fail "the token command of a file that names another instance ran"
plant everyfile lib/forgejo/forge.sh '[ "${file_url%/}" = "$url" ] || continue' ':'
grep -q '^password=' <<< "$(ROOT_UNDER_TEST="$PLANTED" helper_out "$mine")" || fail "planted: a helper that takes every registered file for the instance answered nobody, so the check cannot go red"
shop_config "$shop_b" "$spy_command"
echo "  a registered file that names another instance supplies no token and its token command does not run; planted: a helper without that check hands the token to the wrong server"

# two inits at once on one user configuration: two worktrees of one checkout and two checkouts. A git that holds the first
# write of each init until all four have read the configuration, or the seconds are over, makes the gap between reading and
# writing as wide as the inits need on any machine, so an init without the lock loses or doubles what another wrote
user_sign_in_reset; : > "$WORK/spy.log"
make_shop shop-c1 shop-c1 "$spy_command"; make_shop shop-c2 shop-c2 "$spy_command"
git -C "$proj/shop-c1" worktree add -q -b issue-3-c "$proj/wt-c1a"; git -C "$proj/shop-c1" worktree add -q -b issue-4-c "$proj/wt-c1b"
ROOT_UNDER_TEST="$old" init_in "$proj/shop-c1" > /dev/null || fail "the first init of the first checkout"
ROOT_UNDER_TEST="$old" init_in "$proj/shop-c2" > /dev/null || fail "the first init of the second checkout"
real_git="$(command -v git)"
four_inits_at_once() {  # four_inits_at_once <seconds>: init of both checkouts and both worktrees at once, each exit and report kept
  local n=0 dir pids="" hold
  hold="$(mktemp -d "$WORK/hold.XXXXXX")"
  cat > "$hold/git" <<HOLD
#!/bin/sh
case " \$* " in
  *" --global "*)
    case " \$* " in
      *" --add "*|*" --replace-all "*)
        if [ -n "\${HOLD_ID:-}" ] && [ ! -e "$hold/passed.\$HOLD_ID" ]; then
          : > "$hold/arrived.\$HOLD_ID"
          waited=0
          while [ "\$(ls "$hold" | grep -c '^arrived\.')" -lt 4 ] && [ "\$waited" -lt $(($1 * 10)) ]; do sleep 0.1; waited=\$((waited + 1)); done
          : > "$hold/passed.\$HOLD_ID"
        fi ;;
    esac ;;
esac
exec "$real_git" "\$@"
HOLD
  chmod +x "$hold/git"
  for dir in "$proj/shop-c1" "$proj/shop-c2" "$proj/wt-c1a" "$proj/wt-c1b"; do
    n=$((n + 1))
    ( rc=0; HOLD_ID="$n" EXTRA_PATH="$hold" init_in "$dir" > "$WORK/par-$n.log" || rc=$?; echo "$rc" > "$WORK/par-$n.rc" ) &
    pids="$pids $!"
  done
  wait $pids
}
concurrent_state() {  # concurrent_state: yes where both settings files and one pair stand, each once, and every init exited 0
  local rc ok=yes
  for rc in "$WORK"/par-?.rc; do [ "$(cat "$rc")" = 0 ] || ok=no; done
  [ "$(git config --global --get-all "$LINE_KEY")" = "$(printf '\n!ai-core git-credential')" ] || ok=no
  [ "$(registered | sort)" = "$(printf '%s\n%s\n' "$proj/shop-c1/.ai-core/config.env" "$proj/shop-c2/.ai-core/config.env" | sort)" ] || ok=no
  echo "$ok"
}
plant nolock lib/forgejo/forge.sh 'flock -x -w "$FORGEJO_SIGN_IN_LOCK_SECONDS" 7' 'true'
rm -f "$WORK"/par-*; ROOT_UNDER_TEST="$PLANTED" four_inits_at_once 60
[ "$(concurrent_state)" = no ] || fail "planted: four inits at once without the lock lost nothing and doubled nothing, so the check cannot go red"
user_sign_in_reset; rm -f "$WORK"/par-*
four_inits_at_once 2
[ "$(concurrent_state)" = yes ] || fail "four inits at once lost a settings file, doubled a value or failed: $(tail -n 3 "$WORK"/par-?.log | tr '\n' '|'); $(git config --global --get-all "$LINE_KEY" | paste -sd'|' -); $(registered | paste -sd'|' -)"
[ "$(cat "$WORK"/par-?.log | grep -c "set in the user's git configuration")" = 2 ] || fail "the reports of four inits do not name one change for each settings file: $(grep -h "user's git configuration" "$WORK"/par-?.log)"
echo "  four inits at once, two worktrees of one checkout and two checkouts: every exit 0, both files once, the pair once, one report line for each file; planted: without the lock the same run loses or doubles what the others wrote"

# two cache fetches at once, each with its own cache
c1="$WORK/cache-par-1"; c2="$WORK/cache-par-2"; git init -q --bare "$c1"; git init -q --bare "$c2"
mark="$(log_lines)"
( rc=0; cache_fetch "$c1" shop-c1 > "$WORK/fetch-1.log" || rc=$?; echo "$rc" > "$WORK/fetch-1.rc" ) &
first=$!
( rc=0; cache_fetch "$c2" shop-c2 > "$WORK/fetch-2.log" || rc=$?; echo "$rc" > "$WORK/fetch-2.rc" ) &
wait "$first" $!
for n in 1 2; do
  [ "$(cat "$WORK/fetch-$n.rc")" = 0 ] || fail "cache fetch $n at once failed: $(cat "$WORK/fetch-$n.log")"
  [ "$(git --git-dir="$WORK/cache-par-$n" rev-parse refs/heads/main)" = "$(git --git-dir="$REMOTE/example-org/shop-c$n.git" rev-parse refs/heads/main)" ] || fail "cache $n does not hold the commit of the server"
  served_since "$mark" | grep -q "^200 GET /example-org/shop-c$n.git/info/refs user=ai-core" || fail "the server did not see cache $n sign in"
done
! grep -qF "$TOKEN" "$WORK/spy.log" || fail "the token stands in the arguments or the environment of a token command"
echo "  two cache fetches at once both fetch their commit; the token stands in no argument and no environment of the token commands"

# a refused lock leaves the configuration as it was, and the next run completes it
user_sign_in_reset
lock="$AI_CORE_HOME/.ai-core/git-sign-in.lock"; mkdir -p "$(dirname "$lock")"
forge_fn_fast() { ( cd "$F" && PATH="$PATH_CURL" bash -c '. "$1/lib/forge.sh"; FORGEJO_SIGN_IN_LOCK_SECONDS=1; shift; "$@"' _ "$ROOT" "$@" 2>&1 ); }
cp "$GIT_CONFIG_GLOBAL" "$WORK/gitconfig.untouched"
( flock -x 9; sleep 5 ) 9>"$lock" & holder=$!
sleep 0.5
out="$(forge_fn_fast clone_sign_in "$WORK/fresh")" && fail "a registration went on while another init held the lock"
grep -q 'held by another ai-core init' <<< "$out" && grep -q 'nothing was changed' <<< "$out" || fail "the refusal does not say who holds the lock and that nothing changed: $out"
cmp -s "$GIT_CONFIG_GLOBAL" "$WORK/gitconfig.untouched" || fail "a refused registration changed the user's git configuration"
wait "$holder"
forge_fn_fast clone_sign_in "$WORK/fresh" > /dev/null || fail "the retry after the lock was free did not complete"
[ "$(git config --global --get-all "$LINE_KEY")" = "$(printf '\n!ai-core git-credential')" ] && [ "$(registered)" = "$F/.ai-core/config.env" ] || fail "the retry did not converge on the pair and the file"
# git's own lock on the file, held by somebody else's git config
user_sign_in_reset
cp "$GIT_CONFIG_GLOBAL" "$WORK/gitconfig.untouched"
: > "$GIT_CONFIG_GLOBAL.lock"
out="$(forge_fn clone_sign_in "$WORK/fresh" 2>&1)" && fail "a registration went on while git's lock on the configuration was held"
grep -q "cannot change the user's git configuration" <<< "$out" || fail "the refusal does not say that the configuration could not be changed: $out"
cmp -s "$GIT_CONFIG_GLOBAL" "$WORK/gitconfig.untouched" || fail "a registration refused by git's lock changed the user's git configuration"
rm -f "$GIT_CONFIG_GLOBAL.lock"
forge_fn clone_sign_in "$WORK/fresh" > /dev/null || fail "the retry after git's lock was gone did not complete"
[ "$(git config --global --get-all "$LINE_KEY")" = "$(printf '\n!ai-core git-credential')" ] && [ "$(registered)" = "$F/.ai-core/config.env" ] || fail "the retry after git's lock did not converge on the pair and the file"
echo "  a lock held by another init, and git's own lock on the file, each refuse with their reason and leave the configuration as it was; the retry completes it"

user_sign_in_reset
[ -z "$(leaked)" ] || fail "the token stands in a file after the cache fetches: $(leaked)"

# --- doctor --------------------------------------------------------------------------------------
doctor_lines() {  # the lines forge_doctor prints, report and problem in the shape doctor.sh gives them
  ( cd "${1:-$F}" && PATH="$PATH_CURL" bash -c '. "$1/lib/forge.sh"; report() { printf "  %-12s %-12s %s\n" "$1" "$2" "$3"; }; problem() { echo "PROBLEM"; }; forge_doctor' _ "${ROOT_UNDER_TEST:-$ROOT}" 2>&1 )
}
git init -q --bare -b main "$REMOTE/example-org/example-repo.git"
forge_fn clone_sign_in "$F" > /dev/null
out="$(doctor_lines)"
grep -qxF "  forge: forgejo ($FORGE_URL, the token answers)" <<< "$out" || fail "the doctor does not say the token answers: $out"
grep -q '  origin       answers' <<< "$out" || fail "the doctor does not say git reaches the origin: $out"
! grep -q "$TOKEN" <<< "$out" || fail "the doctor printed the token"
git -C "$F" config --unset-all "$LINE_KEY"
out="$(doctor_lines)"
grep -q 'origin       no sign-in   git ls-remote reaches the origin through the line init would set; the line is not set in this checkout, ai-core init sets it' <<< "$out" || fail "the doctor does not name the missing sign-in line after reading the origin through it: $out"
! grep -q PROBLEM <<< "$out" || fail "the doctor refuses a checkout whose only lack is the sign-in line init sets: $out"
[ -z "$(git -C "$F" config --local --get-all "$LINE_KEY" || true)" ] || fail "the doctor wrote the sign-in line"
git -C "$F" remote set-url origin "$FORGE_URL/example-org/missing.git"
out="$(doctor_lines)"
grep -q 'origin       refused' <<< "$out" && grep -q PROBLEM <<< "$out" || fail "the doctor does not refuse an origin git cannot read, with no sign-in line: $out"
[ -z "$(git -C "$F" config --local --get-all "$LINE_KEY" || true)" ] || fail "the doctor wrote the sign-in line for an origin it refused"
forge_fn clone_sign_in "$F" > /dev/null
out="$(doctor_lines)"
grep -q 'origin       refused' <<< "$out" && grep -q PROBLEM <<< "$out" || fail "the doctor does not refuse an origin git cannot read through the line: $out"
git -C "$F" remote set-url origin "$FORGE_URL/example-org/example-repo.git"
git -C "$F" config --unset-all "$LINE_KEY"
forge_fn clone_sign_in "$F" > /dev/null
printf 'wrong-token\n' > "$WORK/ftoken"
out="$(doctor_lines)"
grep -q "forge        refused      $FORGE_URL refuses the token (status 401)" <<< "$out" && grep -q PROBLEM <<< "$out" || fail "the doctor does not refuse a wrong token: $out"
! grep -q 'wrong-token' <<< "$out" || fail "the doctor printed the token"
! grep -q 'the token answers' <<< "$out" || fail "the doctor says a refused token answers: $out"
printf '%s\n' "$TOKEN" > "$WORK/ftoken"
cp "$F/.ai-core/config.env" "$F/.ai-core/config.env.keep"
printf 'FORGE=forgejo\nFORGEJO_URL=%s\n' "$FORGE_URL" > "$F/.ai-core/config.env"
out="$(doctor_lines)"
grep -q 'forge        not configured set FORGEJO_URL and FORGEJO_TOKEN_COMMAND' <<< "$out" && grep -q PROBLEM <<< "$out" || fail "the doctor does not name a missing token command: $out"
! grep -q 'the token answers' <<< "$out" || fail "the doctor says a missing token command answers: $out"
printf 'FORGE=forgejo\nFORGEJO_URL=%s\nFORGEJO_TOKEN_COMMAND="sh -c '"'"'exit 4'"'"'"\n' "$FORGE_URL" > "$F/.ai-core/config.env"
out="$(doctor_lines)"
grep -q 'forge        no token     the command of FORGEJO_TOKEN_COMMAND failed (exit 4)' <<< "$out" && grep -q PROBLEM <<< "$out" || fail "the doctor does not name a failing token command: $out"
! grep -q 'the token answers' <<< "$out" || fail "the doctor says a failing token command answers: $out"
mv "$F/.ai-core/config.env.keep" "$F/.ai-core/config.env"
inject "GET /api/v1/user" 502 "Bad Gateway"
out="$(doctor_lines)"
grep -q "forge        unexpected   the API of $FORGE_URL answered 502" <<< "$out" || fail "the doctor does not name an unexpected answer: $out"
! grep -q 'the token answers' <<< "$out" || fail "the doctor says a 502 is the token answering: $out"
echo "  doctor: the token answers; a wrong token, a missing or failing command, an origin git cannot sign in to and an unexpected answer are each named, and the token is never printed"
mkdir -p "$WORK/ghstub"; printf '#!/bin/sh\nexit 1\n' > "$WORK/ghstub/gh"; chmod +x "$WORK/ghstub/gh"   # the gh of this machine is not asked: the tracker checks it
out="$(cd "$F" && PATH="$WORK/ghstub:$PATH_CURL" bash "$ROOT/bin/doctor.sh" --no-install 2>&1 || true)"
[ "$(grep -c '^  forge:' <<< "$out")" = 1 ] && grep -q "^  forge: forgejo ($FORGE_URL, the token answers)\$" <<< "$out" || fail "bin/doctor.sh does not print the forge line of the provider once: $(grep forge <<< "$out")"

# a tracker that stays on GitHub while the forge moves is still GitHub's: gh, its login and the project scope are the tracker's
# to check. gh is a stand-in of this test: it is logged in where $WORK/gh-auth exists, and prints that file as its status.
mkdir -p "$WORK/ghstub"
cat > "$WORK/ghstub/gh" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "auth status") [ -f "$GH_STUB_AUTH" ] || { echo "You are not logged into any GitHub hosts." >&2; exit 1; }; cat "$GH_STUB_AUTH" ;;
  "--version "*|"--version") echo "gh version 2.0.0 (stand-in)" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/ghstub/gh"
printf 'command() { if [ "${1:-}" = -v ] && [ "${2:-}" = gh ]; then return 1; fi; builtin command "$@"; }\n' > "$WORK/no-gh.sh"
gh_doctor_lines() {  # gh_doctor_lines [doctor root]: the gh lines of bin/doctor.sh in $F, a tracker on GitHub and a forge on Forgejo
  ( cd "$F" && PATH="$WORK/ghstub:$PATH_CURL" GH_STUB_AUTH="$WORK/gh-auth" bash "${1:-$ROOT}/bin/doctor.sh" --no-install 2>&1 | grep -E '^  (tracker|gh) ' || true )
}
rm -f "$WORK/gh-auth"
out="$(gh_doctor_lines)"
grep -q '^  gh           not logged in' <<< "$out" || fail "the doctor does not check the login of a GitHub tracker beside a Forgejo forge: $out"
printf "Token scopes: 'repo', 'read:org'\n" > "$WORK/gh-auth"
out="$(gh_doctor_lines)"
grep -q '^  gh           no project scope' <<< "$out" || fail "the doctor does not check the project scope of a GitHub tracker beside a Forgejo forge: $out"
printf "Token scopes: 'project', 'repo'\n" > "$WORK/gh-auth"
out="$(gh_doctor_lines)"
grep -q '^  gh           present' <<< "$out" && ! grep -q 'not logged in\|no project scope\|MISSING' <<< "$out" || fail "innocent: a logged-in gh with the project scope is reported as a problem: $out"
out="$(cd "$F" && PATH="$WORK/ghstub:$PATH_CURL" GH_STUB_AUTH="$WORK/gh-auth" BASH_ENV="$WORK/no-gh.sh" bash "$ROOT/bin/doctor.sh" --no-install 2>&1 | grep -E '^  (tracker|gh) ' || true)"
grep -q '^  gh           MISSING' <<< "$out" || fail "the doctor does not check that gh is there for a GitHub tracker beside a Forgejo forge: $out"
rm -f "$WORK/gh-auth"
cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/templates" "$planted/"; cp "$ROOT/VERSION" "$planted/"
sed -i.bak '/|| gh_doctor$/d' "$planted/lib/github/tracker.sh"
cmp -s "$ROOT/lib/github/tracker.sh" "$planted/lib/github/tracker.sh" && fail "the planted tracker equals the real one"
! grep -q '^  gh ' <<< "$(gh_doctor_lines "$planted")" || fail "planted: a tracker that checks nothing still reports gh, so the check cannot go red"
echo "  doctor: a GitHub tracker beside a Forgejo forge checks gh, its login and the project scope itself; planted: without it the problems are not seen"

# --- init: the checkout signs in; the harness repository is created, then cloned -----------------
mkdir -p "$WORK/proj"; git init -q --bare -b main "$REMOTE/example-org/example-repo2.git"
git init -q "$WORK/proj/example-repo2"; git -C "$WORK/proj/example-repo2" remote add origin "$FORGE_URL/example-org/example-repo2.git"
git -C "$WORK/proj/example-repo2" commit -q --allow-empty -m "first"; cp -R "$F/.ai-core" "$WORK/proj/example-repo2/.ai-core"
# the first init of a project creates its harness from the template, whose config.env then replaces the checkout's, so a new
# project names its forge in the environment of that run, and keeps the settings in the harness afterwards
init() { ( cd "$WORK/proj/example-repo2" && FORGE=forgejo FORGEJO_URL="$FORGE_URL" FORGEJO_TOKEN_COMMAND="cat $WORK/ftoken" PATH="$PATH_CURL" bash "$ROOT/bin/init.sh" . --no-doctor "$@" 2>&1 ); }
reset_log
out="$(init --dry-run)" || fail "init --dry-run on Forgejo: $out"
grep -q "$LINE_KEY would be set in .git/config" <<< "$out" || fail "the dry run of init does not announce the sign-in line: $out"
grep -q 'example-org/example-ai-core would be created from the skeleton' <<< "$out" || fail "the dry run of init does not announce the harness: $out"
[ -z "$(git -C "$WORK/proj/example-repo2" config --local --get "$LINE_KEY" || true)" ] || fail "the dry run set the sign-in line"
! requests | grep -q '^POST' || fail "the dry run created something on the instance"
git config --global --add "$LINE_KEY" ""
git config --global --add "$LINE_KEY" '!ai-core git-credential'
git config --global --add credential.helper store
out="$(init)" || fail "init on Forgejo: $out"
grep -q 'created: example-org/example-ai-core, private, from the skeleton' <<< "$out" || fail "init did not create the harness repository: $out"
grep -q "  $LINE_KEY set in .git/config" <<< "$out" || fail "init does not report the sign-in line: $out"
requests | grep -q '^POST /api/v1/orgs/example-org/repos$' || fail "init did not create the harness repository on the instance"
[ "$(git -C "$REMOTE/example-org/example-ai-core.git" rev-list --count --all)" = 1 ] || fail "the harness repository got no skeleton commit"
[ "$(git -C "$WORK/proj/example-repo2" config --local --get "$LINE_KEY")" = '!ai-core git-credential' ] || fail "init did not set the sign-in line"
[ "$(git -C "$WORK/proj/example-repo2" config --local --get-all "$LINE_KEY")" = "$(printf '\n!ai-core git-credential')" ] || fail "init installed no local reset/helper pair under the inherited pair"
signs_in_alone "$WORK/proj/example-repo2" || fail "init: the inherited URL pair hid a store that kept the token"
out="$(init)" || fail "second init on Forgejo: $out"
! grep -q 'credential\.' <<< "$out" || fail "a second init reports the sign-in line again: $out"
rm -rf "$WORK/proj/example-ai-core"
reset_log
out="$(init)" || fail "init with the harness on the instance and not on this disk: $out"
[ -f "$WORK/proj/example-ai-core/ai-core.json" ] || fail "the harness repository was not cloned"
! requests | grep -q '^POST' || fail "init created a harness repository that exists"
[ "$(git -C "$WORK/proj/example-ai-core" config --local --get "$LINE_KEY")" = '!ai-core git-credential' ] || fail "the cloned harness does not sign in through the helper"
git config --global --unset-all credential.helper
git config --global --unset-all "$LINE_KEY"
echo "  init: the dry run announces; the run sets the sign-in line once and creates the harness private on the instance; a second machine clones it"

# init with its doctor: doctor reads the origin through the line init would set, so a checkout without the line passes and gets it; a wrong token or an origin that cannot be read stops it
init_with_doctor() { ( cd "$WORK/proj/example-repo2" && FORGE=forgejo FORGEJO_URL="$FORGE_URL" FORGEJO_TOKEN_COMMAND="cat $WORK/ftoken" GH_STUB_AUTH="$WORK/gh-auth" PATH="$WORK/ghstub:$PATH_CURL" bash "$ROOT/bin/init.sh" . "$@" 2>&1 ); }
printf "Token scopes: 'project', 'repo'\n" > "$WORK/gh-auth"
git -C "$WORK/proj/example-repo2" config --unset-all "$LINE_KEY"
out="$(init_with_doctor)" || fail "init with its doctor refused a checkout that has no sign-in line yet: $out"
grep -q "  $LINE_KEY set in .git/config" <<< "$out" || fail "init does not report the sign-in line it set: $out"
[ "$(git -C "$WORK/proj/example-repo2" config --local --get "$LINE_KEY")" = '!ai-core git-credential' ] || fail "init with its doctor did not set the sign-in line"
git -C "$WORK/proj/example-repo2" config --unset-all "$LINE_KEY"
out="$(init_with_doctor --dry-run)" || fail "init --dry-run with its doctor refused a checkout that has no sign-in line yet: $out"
grep -q "$LINE_KEY would be set in .git/config" <<< "$out" || fail "the dry run with its doctor does not announce the sign-in line: $out"
[ -z "$(git -C "$WORK/proj/example-repo2" config --local --get "$LINE_KEY" || true)" ] || fail "the dry run with its doctor set the sign-in line"
printf 'wrong-token\n' > "$WORK/ftoken"
out="$(init_with_doctor)" && fail "init went on with a token the instance refuses: $out"
[ -z "$(git -C "$WORK/proj/example-repo2" config --local --get "$LINE_KEY" || true)" ] || fail "a refused init left the sign-in line set"
grep -q "refuses the token (status 401)" <<< "$out" && grep -q 'fix the problems doctor reported' <<< "$out" || fail "init does not stop at doctor for a wrong token: $out"
printf '%s\n' "$TOKEN" > "$WORK/ftoken"
git -C "$WORK/proj/example-repo2" remote set-url origin "$FORGE_URL/example-org/missing.git"
out="$(init_with_doctor)" && fail "init went on with an origin that cannot be read: $out"
grep -q 'origin       refused' <<< "$out" && grep -q 'fix the problems doctor reported' <<< "$out" || fail "init does not stop at doctor for an origin that cannot be read: $out"
[ -z "$(git -C "$WORK/proj/example-repo2" config --local --get "$LINE_KEY" || true)" ] || fail "init set the sign-in line although doctor refused the origin"
git -C "$WORK/proj/example-repo2" remote set-url origin "$FORGE_URL/example-org/example-repo2.git"
rm -f "$WORK/gh-auth"
echo "  init with its doctor: a checkout with no sign-in line gets it and passes; a dry run passes and sets nothing; a wrong token or an origin that cannot be read stops at doctor and leaves no line"

# --- release: the combined status of the commit decides -------------------------------------------
RD="$WORK/rel-dev"; mkdir -p "$RD"
(cd "$ROOT" && git ls-files -co --exclude-standard -z | tar --null -cf - -T -) | tar -xf - -C "$RD"
cp -R "$F/.ai-core" "$RD/.ai-core"
git init -q -b main "$RD"; git -C "$RD" add -A; git -C "$RD" commit -q -m 'The tree #1'
git init -q --bare -b main "$REMOTE/example-org/rel.git"; forgejo_repo example-org/rel 1
git -C "$RD" remote add origin "$FORGE_URL/example-org/rel.git"
printf '9.9.0\n' > "$RD/VERSION"; git -C "$RD" commit -q -am 'release: 9.9.0'
user_sign_in_reset
pgit -C "$RD" push -q -u origin main 2>/dev/null && fail "a push without the sign-in line got in"
forge_fn clone_sign_in "$RD" > /dev/null
pgit -C "$RD" push -q -u origin main || fail "the push does not sign in through the line clone_sign_in set"
rsha="$(git -C "$RD" rev-parse HEAD)"
rel() { ( cd "$RD" && AI_CORE_RELEASE_POLL=1 PATH="$PATH_CURL" bash bin/release.sh "$@" 2>&1 ); }
out="$(AI_CORE_RELEASE_WAIT=0 rel 9.9.0)" && fail "a commit with no status was released"
grep -q "the checks for $rsha did not finish in 0 minute(s)" <<< "$out" || fail "a commit nobody posted a status for is not refused as unfinished: $out"
forgejo_set "s.statuses['$rsha']={state:'failure',total_count:1}"
out="$(rel 9.9.0)" && fail "a red commit was released"
grep -q "the checks for $rsha are not green; nothing is released red" <<< "$out" || fail "a failure is not refused as red: $out"
forgejo_set "s.statuses['$rsha']='broken'"
out="$(AI_CORE_RELEASE_WAIT=0 rel 9.9.0)" && fail "a commit whose status cannot be read was released"
grep -q "the checks of $rsha could not be read from $FORGE_HOST until the deadline; it said last: Forgejo answered 502: Bad Gateway (is anyone signed in there?)\$" <<< "$out" || fail "an unreadable status is not named: $out"
git -C "$REMOTE/example-org/rel.git" rev-parse -q --verify refs/tags/v9.9.0 > /dev/null && fail "v9.9.0 was tagged without a green status"
forgejo_set "s.statuses['$rsha']={state:'success',total_count:1,statuses:[{context:'check',status:'success'}]}"
out="$(rel 9.9.0)" || fail "a commit with a green status was refused: $out"
grep -q "^release: v9.9.0 on ${rsha:0:7}, pushed" <<< "$out" || fail "the release is not reported: $out"
git -C "$REMOTE/example-org/rel.git" rev-parse -q --verify refs/tags/v9.9.0 > /dev/null || fail "v9.9.0 was not pushed"
echo "  release: no status, a failure and a broken answer each refuse and tag nothing; a success tags the commit it waited for and pushes the tag"

[ -z "$(leaked)" ] || fail "the token stands in a file after the whole run: $(leaked)"
echo "OK"
