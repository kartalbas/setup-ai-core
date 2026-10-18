#!/usr/bin/env bash
# What every section of the suite starts with: the root, fail, a throwaway directory of
# its own, and the stand-ins a section puts on the PATH. Sourced by tests/sections/*.sh; not run.
set -euo pipefail

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
# A team-modes table whose probes always pass, so the tools of this machine never decide a check
printf 'claude\tmode\talways\t-\t-\ncodex\tmode\talways\t-\t-\ngemini\tmode\talways\t-\t-\n' > "$WORK/modes.tsv"; export TEAM_MODES_FILE="$WORK/modes.tsv"

# A stand-in gh keeps GitHub on this disk: bare repositories under $GH_FAKE/github.com/<org>/<name>.git
make_gh_fake() {
GH_FAKE="$WORK/github"; mkdir -p "$GH_FAKE/github.com/example-org" "$WORK/ghbin"; export GH_FAKE
cat > "$WORK/ghbin/gh" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "repo view")   [ -d "$GH_FAKE/github.com/$3.git" ] ;;
  "repo clone")  git clone -q "$GH_FAKE/github.com/$3.git" "$4" ;;
  "repo create") [ "${3%%/*}" != nocreate-org ] && git init -q --bare "$GH_FAKE/github.com/$3.git" && git -C "$6" remote add origin "$GH_FAKE/github.com/$3.git" && git -C "$6" push -q -u origin HEAD ;;
  "run list") if [ -f "$GH_FAKE/run-broken" ]; then echo 'HTTP 502: Bad Gateway' >&2; exit 1; fi
              if [ -f "$GH_FAKE/run-fail" ]; then rm -f "$GH_FAKE/run-fail"; echo 'HTTP 502: Bad Gateway' >&2; exit 1; fi
              if [ -f "$GH_FAKE/run-pending" ]; then rm -f "$GH_FAKE/run-pending"; [ -z "${GH_FAKE_MOVE:-}" ] || git -C "$GH_FAKE_MOVE" commit -q --allow-empty -m "moved during the wait" >/dev/null 2>&1; echo '[{"status":"in_progress","conclusion":null}]'; else echo '[{"status":"completed","conclusion":"success"}]'; fi ;;
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
      external_source:e.ITEM_EXTERNAL_SOURCE||null,external_id:e.ITEM_EXTERNAL_ID||null,archived_at:null,created_at:"2026-10-18T08:00:00Z",updated_at:"2026-10-18T08:00:00Z",
      completed_at:null,sequence_id:+e.ITEM_SEQ,state:p.states.find((x)=>x.name==="ready").id});'
}
# plane_add_comment <sequence id> <text>: a comment by a member of the workspace on a work item of ENG, the text
# as a person writes it, stored the way the harness stores one
plane_add_comment() {
  COMMENT_SEQ="$1" COMMENT_TEXT="$2" planeset '
    const it=p.issues.find((i)=>i.sequence_id===+process.env.COMMENT_SEQ), e=process.env.COMMENT_TEXT.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;");
    p.comments.push({id:require("crypto").randomUUID(),issue:it.id,comment_html:"<pre>"+e+"</pre>",created_at:new Date(Date.UTC(2026,9,18,9,0,++s.clock)).toISOString(),actor:s.users[0].id,is_member:true})'
}
