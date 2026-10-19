#!/usr/bin/env bash
# What every section of the suite starts with: the root, fail, a throwaway directory of
# its own, and the stand-ins a section puts on the PATH. Sourced by tests/sections/*.sh; not run.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/tool-environment.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
section() { echo "==> $1"; }
WORK="$(mktemp -d)"
[ -n "${KEEP_WORK:-}" ] || trap 'rm -rf "$WORK"' EXIT   # KEEP_WORK=1 leaves the directory for a look
# the number of generic rule sections, what an assembled rules.md is measured against
SECTIONS="$(ls "$ROOT"/rules/[0-9][0-9]-*.md | wc -l | tr -d ' ')"

# A push init makes to an origin that is not there fails at once instead of asking for a login
export GIT_TERMINAL_PROMPT=0
# The commits init and pre-push --install make in the scratch repositories need an identity, and a
# runner has none configured
export GIT_AUTHOR_NAME=check GIT_AUTHOR_EMAIL=check@localhost GIT_COMMITTER_NAME=check GIT_COMMITTER_EMAIL=check@localhost
# session-start does not ask the origins here: nothing in this suite reaches the network
export AI_CORE_UPDATE_CHECK=never
# init writes Claude Code's user settings, so every section points them at a folder that does not
# exist: none touches the settings of this machine, and a check of them names its own folder
export CLAUDE_CONFIG_DIR="$WORK/claude-config"
# The same for Codex's user config, which init writes where Codex is served
export CODEX_HOME="$WORK/codex-config"
# And for the machine's files under the ai-core home, such as the settings of the claude -p runs
export AI_CORE_HOME="$WORK/ai-core-home"
# A team-modes table whose probes always pass, so the tools of this machine never decide a check
printf 'claude\tmode\talways\t-\t-\ncodex\tmode\talways\t-\t-\ngemini\tmode\talways\t-\t-\n' > "$WORK/modes.tsv"; export TEAM_MODES_FILE="$WORK/modes.tsv"

# A stand-in gh keeps GitHub on this disk: bare repositories under $GH_FAKE/github.com/<org>/<name>.git
make_gh_fake() {
GH_FAKE="$WORK/github"; mkdir -p "$GH_FAKE/github.com/example-org" "$WORK/ghbin"; export GH_FAKE
cat > "$WORK/ghbin/gh" <<'EOF'
#!/bin/sh
if [ "$1 $2" = "repo view" ] && [ "${4-} ${5-}" = "--json isPrivate" ]; then
  printf 'visibility\n' >> "$GH_FAKE/body-calls.log"
  [ -z "${GH_REWRITE_BODY_FILE:-}" ] || printf '%s' "$GH_REWRITE_BODY" > "$GH_REWRITE_BODY_FILE"
  case "${GH_VISIBILITY:-public}" in
    private) echo '{"isPrivate":true}' ;; public) echo '{"isPrivate":false}' ;;
    error) echo 'visibility denied' >&2; exit 1 ;; malformed) echo 'not json' ;;
    null) echo '{"isPrivate":null}' ;; string) echo '{"isPrivate":"true"}' ;;
    missing) echo '{}' ;; *) echo "$GH_VISIBILITY" ;;
  esac
  exit 0
fi
if [ "${GH_BODY_FIXTURE:-}" = 1 ]; then
  case "$1 $2" in
    'api graphql')
      case "$*" in
        *mutation*|*--input*)
          echo 'write mutation' >> "$GH_FAKE/body-calls.log"
          for arg in "$@"; do case "$arg" in t=*) printf '%s' "${arg#t=}" > "$GH_FAKE/sent-title" ;; esac; done
          printf '2\thttps://github.com/orgs/example-org/projects/2\n' ;;
        *'fields(first:50)'*) cat "$GH_FAKE/fields.json" ;;
        *'views(first:20)'*) printf 'ALL-ISSUES\tVIEW_example\n' ;;
        *'organization(login:$o){ id }'*|*'projectV2(number:$n){ id }'*) echo fixture-id ;;
      esac
      exit 0 ;;
    'issue create') kind=new ;;
    'issue view') echo type:feature; exit 0 ;;
    'issue edit') kind=labels ;;
    'label create') kind=label ;;
    'label list') exit 0 ;;
    'api --method') kind=edit ;;
    api*) case "$*" in *--jq\ .body*) cat "$GH_FAKE/current-body"; exit 0 ;; *--jq\ .node_id*) echo fixture-id; exit 0 ;; esac
      if [ "$#" -eq 2 ] && [ -f "$GH_FAKE/current-assignees" ]; then cat "$GH_FAKE/current-assignees"; exit 0; fi
      kind=comment ;;
    *) echo "unexpected fixture call: $*" >&2; exit 1 ;;
  esac
  [ -z "${GH_BODY_WRITE_FAILURE:-}" ] || { echo 'body write refused' >&2; exit 1; }
  printf 'write %s\n' "$kind" >> "$GH_FAKE/body-calls.log"
  while [ $# -gt 0 ]; do
    case "$1" in
      --title) printf '%s' "$2" > "$GH_FAKE/sent-title"; shift ;;
      --assignee) printf '%s' "$2" > "$GH_FAKE/sent-assignee"; shift ;;
      --input) cat > "$GH_FAKE/sent-input"; jq '{assignees: [.assignees[] | {login: .}]}' "$GH_FAKE/sent-input" > "$GH_FAKE/current-assignees"; shift ;;
      title=*) printf '%s' "${1#title=}" > "$GH_FAKE/sent-title" ;;
      --body-file) cp "$2" "$GH_FAKE/sent-body"; ls -l "$2" | cut -c1-10 > "$GH_FAKE/sent-body-mode"; printf '%s' "$2" > "$GH_FAKE/sent-body-path"; shift ;;
      body=@*) cp "${1#body=@}" "$GH_FAKE/sent-body"; ls -l "${1#body=@}" | cut -c1-10 > "$GH_FAKE/sent-body-mode"; printf '%s' "${1#body=@}" > "$GH_FAKE/sent-body-path" ;;
      body=*) printf '%s' "${1#body=}" > "$GH_FAKE/sent-body" ;;
    esac
    shift
  done
  echo 'https://github.com/example-org/example-repo/issues/9'
  exit 0
fi
case "$1 $2" in
  "repo view")   [ -d "$GH_FAKE/github.com/$3.git" ] ;;
  "repo clone")  git clone -q "$GH_FAKE/github.com/$3.git" "$4" ;;
  "repo create") [ "${3%%/*}" != nocreate-org ] && git init -q --bare "$GH_FAKE/github.com/$3.git" && git -C "$6" remote add origin "$GH_FAKE/github.com/$3.git" && git -C "$6" push -q -u origin HEAD ;;
  "run list") if [ -f "$GH_FAKE/run-broken" ]; then echo 'HTTP 502: Bad Gateway' >&2; exit 1; fi
              if [ -f "$GH_FAKE/run-fail" ]; then rm -f "$GH_FAKE/run-fail"; echo 'HTTP 502: Bad Gateway' >&2; exit 1; fi
              if [ -f "$GH_FAKE/run-pending" ]; then rm -f "$GH_FAKE/run-pending"; [ -z "${GH_FAKE_MOVE:-}" ] || git -C "$GH_FAKE_MOVE" commit -q --allow-empty -m "moved during the wait" >/dev/null 2>&1; echo '[{"status":"in_progress","conclusion":null}]'; else echo '[{"status":"completed","conclusion":"success"}]'; fi ;;
  "api repos/"*) echo '{"state":"pending","total_count":0}' ;;   # the commit statuses: none, as of a repository whose CI is Actions alone
  "auth status") exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/ghbin/gh"
PATH_SH="$WORK/ghbin:$PATH"
}

# A stand-in curl keeps Plane and Forgejo on this disk: tests/curl-fake.mjs answers from the JSON files
# of $CURL_FAKE_STATE (first state: plane.json and forgejo.json), logs every call, and plants an answer
# on demand (inject.json). PATH_CURL is the PATH to run a command under.
make_curl_fake() {
CURL_FAKE_STATE="$WORK/fake"; export CURL_FAKE_STATE
node "$ROOT/tests/curl-fake.mjs" --init "$CURL_FAKE_STATE"
mkdir -p "$WORK/curlbin"
printf '#!/bin/sh\nexec node "%s/tests/curl-fake.mjs" "$@"\n' "$ROOT" > "$WORK/curlbin/curl"
chmod +x "$WORK/curlbin/curl"
PATH_CURL="$WORK/curlbin:$PATH"
}

# make_plane_project: $P, a project whose tracker is Plane at plane.example.test, answered by the stand-in curl,
# its HOME and cache in $WORK, and the helpers the Plane tests share: ai <command> [args] runs bin/<command>.sh
# of $ROOT (or of ROOT_UNDER_TEST) in the project; planeq <js> reads the stand-in's project ENG as `p`;
# reset_log empties the logs of what curl was given.
make_plane_project() {
  export HOME="$WORK/home" AI_CORE_HOME="$WORK/ai-core-home" GH_CACHE_DIRECTORY="$WORK/cache" AI_CORE_SLEEP="$WORK/sleep"
  mkdir -p "$HOME" "$AI_CORE_HOME"
  printf '#!/bin/sh\necho "$@" >> "%s/slept"\n' "$WORK" > "$WORK/sleep"; chmod +x "$WORK/sleep"
  make_curl_fake
  printf 'plane-token-0123\n' > "$WORK/token"
  P="$WORK/project"; mkdir -p "$P/.ai-core"; git init -q "$P"
  git -C "$P" remote add origin https://forge.example.test/example-org/example-repo.git
  cat > "$P/.ai-core/config.env" <<CONF
TRACKER=plane
PLANE_URL=https://plane.example.test
PLANE_WORKSPACE=ws
PLANE_PROJECT=ENG
PLANE_TOKEN_COMMAND="cat $WORK/token"
CONF
}
ai() { local c="$1"; shift; ( cd "$P" && PATH="$PATH_CURL" bash "${ROOT_UNDER_TEST:-$ROOT}/bin/$c.sh" "$@" ); }
planeq() { node -e "const s=JSON.parse(require('fs').readFileSync('$CURL_FAKE_STATE/plane.json'));const p=s.projects[0];$1"; }
reset_log() { : > "$CURL_FAKE_STATE/requests.log"; : > "$CURL_FAKE_STATE/argv.log"; : > "$CURL_FAKE_STATE/env.log"; }
# plane_fn <function> [args]: a function of the tracker library, called in the project with its board selected
plane_fn() { ( cd "$P" && PATH="$PATH_CURL" bash -c '. "$1/lib/board.sh"; shift; set_project >/dev/null; "$@"' _ "${ROOT_UNDER_TEST:-$ROOT}" "$@" ); }
# planeset <js>: changes the stand-in's state as another hand would; `s` is the state, `p` its project ENG
planeset() {
  CURL_FAKE_STATE="$CURL_FAKE_STATE" node -e "const fs=require('fs'),f=process.env.CURL_FAKE_STATE+'/plane.json',s=JSON.parse(fs.readFileSync(f)),p=s.projects[0];$1;fs.writeFileSync(f,JSON.stringify(s))"
}
# plane_add_item <sequence id> <title> [label name...]: a work item another hand put into ENG, in state ready,
# the labels made where the project lacks them; ITEM_EXTERNAL_SOURCE and ITEM_EXTERNAL_ID in the environment
# set the fields a carried item has
plane_add_item() {
  local seq="$1" title="$2"; shift 2
  ITEM_SEQ="$seq" ITEM_TITLE="$title" ITEM_LABELS="$(printf '%s\n' "$@")" planeset '
    const id=()=>require("crypto").randomUUID(), e=process.env;
    const ids=e.ITEM_LABELS.split("\n").filter(Boolean).map((n)=>{let l=p.labels.find((x)=>x.name===n);if(!l){l={id:id(),name:n,color:"#000",description:""};p.labels.push(l);}return l.id;});
    p.issues.push({id:id(),project:p.id,name:e.ITEM_TITLE,description_html:"<p></p>",priority:"none",parent:null,labels:ids,assignees:[],sort_order:65535,
      external_source:e.ITEM_EXTERNAL_SOURCE||null,external_id:e.ITEM_EXTERNAL_ID||null,archived_at:null,created_at:s.day+"T08:00:00Z",updated_at:s.day+"T08:00:00Z",
      completed_at:null,sequence_id:+e.ITEM_SEQ,state:p.states.find((x)=>x.name==="ready").id});'
}
# plane_add_comment <sequence id> <text> [author email]: a comment on a work item of ENG, by a member of the project
# unless an author is named (gone@example.test left the project, stranger@example.test never was in it), the text as
# a person writes it, stored the way the harness stores one. is_member is true, as Plane computes it for the key's
# own user, whoever the author is.
plane_add_comment() {
  COMMENT_SEQ="$1" COMMENT_TEXT="$2" COMMENT_AUTHOR="${3:-me@example.test}" planeset '
    const it=p.issues.find((i)=>i.sequence_id===+process.env.COMMENT_SEQ), e=process.env.COMMENT_TEXT.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;");
    p.comments.push({id:require("crypto").randomUUID(),issue:it.id,comment_html:"<pre>"+e+"</pre>",created_at:new Date(Date.parse(s.day+"T09:00:00Z")+ ++s.clock*1000).toISOString(),actor:s.users.find((u)=>u.email===process.env.COMMENT_AUTHOR).id,is_member:true})'
}

# make_forgejo_project: $F, a checkout whose forge is Forgejo, and the instance on this disk: the API answered by
# the stand-in curl, the git of its repositories served over HTTP by tests/git-http-server.mjs (bare repositories
# under $REMOTE/<owner>/<name>.git, which the stand-in makes when the API creates one, and a login that is the
# token in $WORK/server-token; the token command prints $WORK/ftoken, which holds the same). $FORGE_URL is the address of both. An `ai-core` on the PATH runs the command of this
# tree, as the credential line git is given asks for. forge_fn <function> [args] calls a function of lib/forge.sh
# in $F; forgejo_set <js> changes the stand-in's state as another hand would (`s` is the state); forgejo_repo
# <owner/name> [files] adds a repository to it.
make_forgejo_project() {
  export HOME="$WORK/home" AI_CORE_HOME="$WORK/ai-core-home" GH_CACHE_DIRECTORY="$WORK/cache"
  mkdir -p "$HOME" "$AI_CORE_HOME"
  make_curl_fake
  git config --global init.defaultBranch main   # a repository the instance makes is on main too: the stand-in does not move the default branch to the first one pushed
  REMOTE="$WORK/remote"; mkdir -p "$REMOTE/example-org"; export CURL_FAKE_REPO_ROOT="$REMOTE"
  printf 'forgejo-token-4567\n' > "$WORK/ftoken"; cp "$WORK/ftoken" "$WORK/server-token"   # the token command's answer, and the token the server accepts
  GIT_SERVER_LOG="$WORK/git-server.log"; : > "$GIT_SERVER_LOG"
  node "$ROOT/tests/git-http-server.mjs" "$REMOTE" "$WORK/server-token" "$GIT_SERVER_LOG" > "$WORK/git-server.port" &
  GIT_SERVER_PID=$!
  trap 'kill "$GIT_SERVER_PID" 2>/dev/null || true; [ -n "${KEEP_WORK:-}" ] || rm -rf "$WORK"' EXIT
  local waited=0
  while [ ! -s "$WORK/git-server.port" ]; do
    waited=$((waited + 1)); [ "$waited" -le 100 ] || fail "the git server of the Forgejo stand-in did not start"
    sleep 0.1
  done
  FORGE_URL="http://127.0.0.1:$(cat "$WORK/git-server.port")"; FORGE_HOST="${FORGE_URL#http://}"
  mkdir -p "$WORK/aibin"
  printf '#!/bin/sh\nexec bash "${ROOT_UNDER_TEST:-%s}/bin/ai-core" "$@"\n' "$ROOT" > "$WORK/aibin/ai-core"; chmod +x "$WORK/aibin/ai-core"
  PATH_CURL="$WORK/aibin:$PATH_CURL"
  F="$WORK/forge-project"; mkdir -p "$F/.ai-core"; git init -q "$F"
  git -C "$F" remote add origin "$FORGE_URL/example-org/example-repo.git"
  cat > "$F/.ai-core/config.env" <<CONF
FORGE=forgejo
FORGEJO_URL=$FORGE_URL
FORGEJO_TOKEN_COMMAND="cat $WORK/ftoken"
CONF
}
forge_fn() { ( cd "$F" && PATH="$PATH_CURL" bash -c '. "$1/lib/forge.sh"; shift; "$@"' _ "${ROOT_UNDER_TEST:-$ROOT}" "$@" ); }
forgejo_set() {
  CURL_FAKE_STATE="$CURL_FAKE_STATE" node -e "const fs=require('fs'),f=process.env.CURL_FAKE_STATE+'/forgejo.json',s=JSON.parse(fs.readFileSync(f));$1;fs.writeFileSync(f,JSON.stringify(s))"
}
# forgejo_repo <owner/name> [number of files]: a repository the instance has, with a commit when it has files
forgejo_repo() {
  REPO_FULL="$1" REPO_FILES="${2:-0}" forgejo_set '
    const n=+process.env.REPO_FILES, full=process.env.REPO_FULL;
    s.repos[full]={name:full.split("/")[1],full_name:full,private:true,empty:n===0,default_branch:"main",files:Array.from({length:n},(_,i)=>"dir/file-"+i+".txt")}'
}
