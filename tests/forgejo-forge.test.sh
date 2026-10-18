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
requests() { cat "$CURL_FAKE_STATE/requests.log"; }
inject() {  # inject <path fragment> <status> <body>: the next call whose "<METHOD> <path>" holds the fragment gets this answer
  INJ_MATCH="$1" INJ_STATUS="$2" INJ_BODY="$3" node -e "const fs=require('fs'),f=process.env.CURL_FAKE_STATE+'/inject.json',e=process.env;let l=[];try{l=JSON.parse(fs.readFileSync(f))}catch{};l.push({match:e.INJ_MATCH,status:+e.INJ_STATUS,body:e.INJ_BODY,times:1});fs.writeFileSync(f,JSON.stringify(l))"
}
pgit() { PATH="$PATH_CURL" git "$@"; }   # git as a person runs it, with ai-core on the PATH

section "the forge on Forgejo: the repository, the check of a commit, the signed-in user, and the sign-in of git"

# --- the host, a repository, the user -----------------------------------------------------------
[ "$(forge_fn forge_host)" = "$FORGE_HOST" ] || fail "forge_host is not the host of FORGEJO_URL: $(forge_fn forge_host)"
forgejo_repo example-org/example-repo 3
forge_fn repo_exists example-org/example-repo || fail "repo_exists says a repository the instance has is not there"
forge_fn repo_exists example-org/missing && fail "repo_exists says a repository the instance lacks is there"
inject "GET /api/v1/repos/example-org/example-repo" 502 "Bad Gateway"
out="$(forge_fn repo_exists example-org/example-repo 2>&1)" && fail "repo_exists took a 502 for a repository that is there"
grep -q 'cannot tell whether example-org/example-repo exists - Forgejo answered 502: Bad Gateway' <<< "$out" || fail "repo_exists does not say what Forgejo answered: $out"
echo "  repo_exists: there, not there, and an answer that says neither is refused with Forgejo's words"
[ "$(forge_fn signed_in_user)" = tester ] || fail "signed_in_user is not the login of the token"
printf 'wrong-token\n' > "$WORK/ftoken"
out="$(forge_fn signed_in_user 2>&1)" && fail "signed_in_user took a wrong token for a user: $out"
[ -z "$out" ] || fail "signed_in_user says something where nobody is signed in: $out"
printf '%s\n' "$TOKEN" > "$WORK/ftoken"
echo "  signed_in_user: the login of the token; nothing and exit 1 for a token Forgejo refuses"

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
[ "$(requests | grep -c 'git/trees/HEAD?recursive=true&per_page=1000&page=')" = 3 ] || fail "2305 files should take three pages: $(requests | grep trees)"
echo "  repo_file_tree: 2305 files in three pages, all of them once, the end named by total_count and not by Forgejo's truncated flag"
inject "page=2" 200 '{"tree":[],"total_count":2305,"page":2,"truncated":true}'
out="$(forge_fn repo_file_tree example-org/big-repo 2>&1)" && fail "repo_file_tree took a listing that ended early for a whole one"
grep -q 'ended at 1000 of 2305 entries' <<< "$out" || fail "an early end is not named: $out"
echo "  planted: a listing that ends before total_count is refused with both numbers"

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

# --- the helper ---------------------------------------------------------------------------------
helper() {  # helper <directory> <the lines git sends>: the helper itself, as git runs it
  ( cd "$1" && printf "$2" | PATH="$PATH_CURL" bash "${ROOT_UNDER_TEST:-$ROOT}/bin/git-credential.sh" get 2>&1 )
}
mine="protocol=http\nhost=$FORGE_HOST\n"
[ "$(helper "$F" "$mine")" = "$(printf 'username=ai-core\npassword=%s' "$TOKEN")" ] || fail "the helper does not answer username ai-core and the token: $(helper "$F" "$mine")"
echo "  git-credential get: username ai-core and the token that FORGEJO_TOKEN_COMMAND prints"
# a clone with no .ai-core of its own, as the clone of a project harness: the settings of the project folder
mkdir -p "$WORK/folder/.ai-core"; cp "$F/.ai-core/config.env" "$WORK/folder/.ai-core/"
git init -q "$WORK/folder/x-ai-core"
[ "$(helper "$WORK/folder/x-ai-core" "$mine")" = "$(printf 'username=ai-core\npassword=%s' "$TOKEN")" ] || fail "a harness clone does not get the token with the settings of its project folder"
mkdir -p "$WORK/elsewhere"
! helper "$WORK/elsewhere" "$mine" | grep -q password || fail "a folder with no settings at all got a token"
echo "  a clone without an .ai-core of its own reads the settings of its project folder; a place with none gets no token"
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
# the helper keeps the token out of every file: a planted copy that keeps it is seen by the scan, the real one is clean
[ -z "$(leaked)" ] || fail "the helper wrote the token to a file: $(leaked)"
sed -i.bak "s|^printf 'username|printf '%s' \"\$token\" > \"\$HOME/leak\"; printf 'username|" "$planted/bin/git-credential.sh"
cmp -s "$ROOT/bin/git-credential.sh" "$planted/bin/git-credential.sh" && fail "the planted helper equals the real one"
ROOT_UNDER_TEST="$planted" helper "$F" "$mine" > /dev/null
[ -n "$(leaked)" ] || fail "planted: a helper that writes the token to a file is not seen by the scan, so the check cannot go red"
rm -f "$HOME/leak"
[ -z "$(leaked)" ] || fail "the token stands in a file after the planted helper was removed: $(leaked)"
echo "  planted: a helper that keeps the token in a file is seen; the real one leaves none"

# --- the line that signs a clone in --------------------------------------------------------------
[ -z "$(forge_fn clone_sign_in "$WORK/clones/cloned" dry)" ] || fail "a clone that signs in already was announced again (dry)"
git init -q "$WORK/fresh"; git -C "$WORK/fresh" remote add origin "$FORGE_URL/example-org/fresh.git"
set_line="$LINE_KEY set in .git/config: git asks ai-core git-credential for the token"
[ "$(forge_fn clone_sign_in "$WORK/fresh" dry)" = "${set_line/ set / would be set }" ] || fail "the dry run does not say what it would set: $(forge_fn clone_sign_in "$WORK/fresh" dry)"
[ -z "$(git -C "$WORK/fresh" config --get "$LINE_KEY" || true)" ] || fail "the dry run set the line"
[ "$(forge_fn clone_sign_in "$WORK/fresh")" = "$set_line" ] || fail "clone_sign_in did not set the line"
[ "$(git -C "$WORK/fresh" config --get "$LINE_KEY")" = '!ai-core git-credential' ] || fail "the line is not '!ai-core git-credential'"
[ -z "$(forge_fn clone_sign_in "$WORK/fresh")" ] || fail "a second run set the line again or said so"
[ "$(git -C "$WORK/fresh" config --get-all "$LINE_KEY" | wc -l | tr -d ' ')" = 1 ] || fail "the line is not alone after two runs"
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
git -C "$F" config --unset "$LINE_KEY"
out="$(doctor_lines)"
grep -q 'origin       refused' <<< "$out" && grep -q PROBLEM <<< "$out" || fail "the doctor does not refuse an origin git cannot sign in to: $out"
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
out="$(cd "$F" && PATH="$PATH_CURL" bash "$ROOT/bin/doctor.sh" --no-install 2>&1 || true)"
[ "$(grep -c '^  forge:' <<< "$out")" = 1 ] && grep -q "^  forge: forgejo ($FORGE_URL, the token answers)\$" <<< "$out" || fail "bin/doctor.sh does not print the forge line of the provider once: $(grep forge <<< "$out")"

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
[ -z "$(git -C "$WORK/proj/example-repo2" config --get "$LINE_KEY" || true)" ] || fail "the dry run set the sign-in line"
! requests | grep -q '^POST' || fail "the dry run created something on the instance"
out="$(init)" || fail "init on Forgejo: $out"
grep -q 'created: example-org/example-ai-core, private, from the skeleton' <<< "$out" || fail "init did not create the harness repository: $out"
grep -q "  $LINE_KEY set in .git/config" <<< "$out" || fail "init does not report the sign-in line: $out"
requests | grep -q '^POST /api/v1/orgs/example-org/repos$' || fail "init did not create the harness repository on the instance"
[ "$(git -C "$REMOTE/example-org/example-ai-core.git" rev-list --count --all)" = 1 ] || fail "the harness repository got no skeleton commit"
[ "$(git -C "$WORK/proj/example-repo2" config --get "$LINE_KEY")" = '!ai-core git-credential' ] || fail "init did not set the sign-in line"
out="$(init)" || fail "second init on Forgejo: $out"
! grep -q 'credential\.' <<< "$out" || fail "a second init reports the sign-in line again: $out"
rm -rf "$WORK/proj/example-ai-core"
reset_log
out="$(init)" || fail "init with the harness on the instance and not on this disk: $out"
[ -f "$WORK/proj/example-ai-core/ai-core.json" ] || fail "the harness repository was not cloned"
! requests | grep -q '^POST' || fail "init created a harness repository that exists"
[ "$(git -C "$WORK/proj/example-ai-core" config --get "$LINE_KEY")" = '!ai-core git-credential' ] || fail "the cloned harness does not sign in through the helper"
echo "  init: the dry run announces; the run sets the sign-in line once and creates the harness private on the instance; a second machine clones it"

# --- release: the combined status of the commit decides -------------------------------------------
RD="$WORK/rel-dev"; mkdir -p "$RD"
(cd "$ROOT" && git ls-files -co --exclude-standard -z | tar --null -cf - -T -) | tar -xf - -C "$RD"
cp -R "$F/.ai-core" "$RD/.ai-core"
git init -q -b main "$RD"; git -C "$RD" add -A; git -C "$RD" commit -q -m 'The tree #1'
git init -q --bare -b main "$REMOTE/example-org/rel.git"; forgejo_repo example-org/rel 1
git -C "$RD" remote add origin "$FORGE_URL/example-org/rel.git"
printf '9.9.0\n' > "$RD/VERSION"; git -C "$RD" commit -q -am 'release: 9.9.0'
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
