#!/usr/bin/env bash
# What issue-label puts on an issue, what it takes off, and what it sends to do it.
#
#   bash test/issue-label.test.sh
#
# NOTHING REACHES github.com. A stand-in `gh` holds the labels of each issue in a file,
# answers `issue view` from it and applies `issue edit` to it, so the assertion is the
# label set the issue is left carrying and not merely the words the script printed. No
# board is resolved either: issue-label never selects a project.
#
# THE STAND-IN REFUSES WHAT gh REFUSES. Measured against github.com on 2026-08-26:
#
#   gh issue edit 12 --repo example-org/example-tools --remove-label does-not-exist-anywhere
#     -> failed to update ...: 'does-not-exist-anywhere' not found        exit 1
#   gh issue edit 12 --repo example-org/example-tools --remove-label type:bug   (not on it)
#     -> https://github.com/example-org/example-tools/issues/12               exit 0
#
# So a name the REPOSITORY does not carry kills the run, and a name the ISSUE does not
# carry is a no-op. That is the whole reason issue-label reads the issue's labels before
# it sends anything, and the stand-in models both answers so the difference can be shown.
#
# THE PLANTED DEFECTS, one per shape this suite catches, each replayed against the
# stand-in so it is shown RED rather than argued about:
#   - the edit call with its --remove-label half dropped, which is an edit that only ever
#     adds: the retired label is still on the issue afterwards.
#   - the removal sent without reading the issue first: gh exits 1 and the run is dead.
#   - a label name holding a space, word-split the way a glued command line splits it:
#     gh is asked to remove 'help', which the repository does not have, and exits 1.
#
# THE PLANTED INNOCENT CASES, so a green run means the checks looked: a run that only
# adds, a second run of the same call that changes nothing, and a removal of a name the
# taxonomy declares nothing about, which must be allowed.
#
# WHAT THIS DOES NOT REACH, named rather than counted:
#   - the taxonomy itself. The names used below are read from the tracked labels.tsv:
#     type:bug, type:chore, area:installation and area:tooling are declared there and
#     area:install, tooling and design are not, which is the retirement this ticket is
#     about. A change to that file that undeclares one of the first four, or declares
#     one of the last three, turns this suite red and is meant to.
#   - whether gh accepts what it is handed. Only the two answers measured above are
#     modelled; anything else gh does is gh's own check.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAKE="$(mktemp -d)"
REPO="example-org/example-repo"
failed=0

cleanup() { rm -rf "$FAKE"; }
trap cleanup EXIT

check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}

# The labels the REPOSITORY carries. labels-sync leaves a retired name alone, so the
# names taken off tickets below are all still here - which is why removing them works.
cat > "$FAKE/repo-labels" <<'EOF'
type:bug
type:chore
area:installation
area:tooling
area:install
tooling
design
help wanted
EOF

# One file per issue, holding the labels it carries.
seed() { # seed <number> <label>...
  local n="$1"; shift
  printf '%s\n' "$@" > "$FAKE/issue-$n"
}
labels_on() { tr '\n' ' ' < "$FAKE/issue-$1" | sed 's/ $//'; }

mkdir -p "$FAKE/bin"
cat > "$FAKE/bin/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$FAKE/calls"
if [ "\$1 \$2" = 'repo view' ] && [ "\${4-} \${5-}" = '--json isPrivate' ]; then
  echo '{"isPrivate":false}'; exit 0
fi
if [ "\$1" = api ]; then exec bash "$FAKE/remote-api.sh" "\$@"; fi
sub="\$2"; num="\$3"; shift 3
case "\$sub" in
  view) cat "$FAKE/issue-\$num"; exit 0 ;;
  edit)
    adds=(); removes=()
    while [ \$# -gt 0 ]; do
      case "\$1" in
        --add-label)    adds+=("\$2");    shift 2 ;;
        --remove-label) removes+=("\$2"); shift 2 ;;
        *) shift ;;
      esac
    done
    for l in \${adds[@]+"\${adds[@]}"} \${removes[@]+"\${removes[@]}"}; do
      grep -qxF -- "\$l" "$FAKE/repo-labels" || {
        echo "failed to update https://github.com/$REPO/issues/\$num: '\$l' not found" >&2
        echo 'failed to update 1 issue' >&2
        exit 1; }
    done
    for l in \${removes[@]+"\${removes[@]}"}; do
      grep -vxF -- "\$l" "$FAKE/issue-\$num" > "$FAKE/tmp" || true
      mv "$FAKE/tmp" "$FAKE/issue-\$num"
    done
    for l in \${adds[@]+"\${adds[@]}"}; do
      grep -qxF -- "\$l" "$FAKE/issue-\$num" || printf '%s\n' "\$l" >> "$FAKE/issue-\$num"
    done
    echo "https://github.com/$REPO/issues/\$num"
    exit 0 ;;
esac
echo "the stand-in was asked something it does not answer: \$sub" >&2
exit 1
EOF
chmod +x "$FAKE/bin/gh"
export PATH="$FAKE/bin:$PATH"
export FAKE

# THE FORGE'S READS. The stand-in serves two reads of a remote repository from $FAKE/remote/<owner>/<repo>:
#   commits/HEAD       the first line of head-queue (the commit the default branch stands at; the line is dropped once
#                      read, so a branch that moves between two reads shows), else the file head; fail-head makes it fail
#   contents/<path>    the file at at-<commit>/<path>, as GitHub answers it: a base64 file with its size; a path the
#                      commit lacks is 404, so is a commit the stand-in does not hold, and fail-read makes every read fail
cat > "$FAKE/remote-api.sh" <<'EOS'
#!/usr/bin/env bash
echo "$*" >> "$FAKE/api-calls"
path="${2%%\?*}"; query=""; case "$2" in *\?*) query="${2#*\?}" ;; esac
repo="$(printf '%s' "$path" | cut -d/ -f2,3)"; dir="$FAKE/remote/$repo"
notfound() { echo '{"message":"Not Found"}'; echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }
[ -d "$dir" ] || notfound
case "$path" in
  repos/*/*/commits/HEAD)
    [ ! -f "$dir/fail-head" ] || { echo 'error connecting to api.github.com' >&2; exit 1; }
    if [ -s "$dir/head-queue" ]; then head -n 1 "$dir/head-queue"; tail -n +2 "$dir/head-queue" > "$dir/head-queue.rest"; mv "$dir/head-queue.rest" "$dir/head-queue"
    else cat "$dir/head"; fi ;;
  repos/*/*/contents/*)
    [ ! -f "$dir/fail-read" ] || { echo 'error connecting to api.github.com' >&2; exit 1; }
    file="$dir/at-${query#ref=}/${path#repos/$repo/contents/}"
    [ -f "$file" ] || notfound
    jq -n --arg content "$(base64 < "$file")" --argjson size "$(wc -c < "$file" | tr -d ' ')" '{type: "file", encoding: "base64", size: $size, content: $content}' ;;
  *) echo "the stand-in was asked for a read it does not answer: $path" >&2; exit 1 ;;
esac
EOS

# A clone of the repository is where the command stands, with the catalog init installed there: the taxonomy of
# an issue is the one of the project of its repository.
mkclone() { # mkclone <dir> <origin repo> [catalog file]
  mkdir -p "$1/.ai-core"; git init -q "$1"; git -C "$1" remote add origin "https://github.com/$2.git"
  cp "${3:-$ROOT/templates/.ai-core/labels.tsv}" "$1/.ai-core/labels.tsv"
}
mkclone "$FAKE/project/example-repo" "$REPO"

run() { # run <issue-label.sh argument>...
  : > "$FAKE/calls"
  ( cd "$FAKE/project/example-repo" && bash "$ROOT/bin/issue-label.sh" "$REPO" "$@" 2>&1 )
}
edits() { grep -c '^issue edit' "$FAKE/calls"; }
edit_call() { grep '^issue edit' "$FAKE/calls" | head -1; }

# --- 1. retiring a label and putting its replacement on, in one call ---------------------------

echo 'a retired label off and its replacement on, in one call'

seed 72 type:bug area:install
out="$(run 72 --add area:installation --remove area:install)"
check 'the run says what it did'  '#72 -> +area:installation -area:install' "$out"
check 'the retired name is gone and the rest is untouched' 'type:bug area:installation' "$(labels_on 72)"
check 'one edit was sent, carrying both halves' \
      "issue edit 72 --repo $REPO --add-label area:installation --remove-label area:install" "$(edit_call)"

# THE PLANTED DEFECT: an edit that only ever adds.
# Replayed against the same starting point, the retired label is still there afterwards.
seed 72 type:bug area:install
"$FAKE/bin/gh" issue edit 72 --repo "$REPO" --add-label area:installation >/dev/null
check 'the plant: an edit with no remove half leaves the retired name on' \
      'type:bug area:install area:installation' "$(labels_on 72)"

# --- 2. a name the taxonomy no longer declares ------------------------------------------------

echo
echo 'a name labels.tsv does not declare comes off, and does not go on'

seed 8 tooling design type:chore area:tooling
out="$(run 8 --remove tooling --remove design)"
check 'both retired names come off'          '#8 -> -tooling -design' "$out"
check 'and the declared ones stay'           'type:chore area:tooling' "$(labels_on 8)"

seed 8 type:chore area:tooling
out="$(run 8 --add tooling)"
check 'the same name is refused on --add' yes \
      "$(case "$out" in *'"tooling" is not in the taxonomy'*) echo yes ;; *) echo "no: $out" ;; esac)"
check 'and nothing was sent' 0 "$(edits)"

# --- 3. a label the issue does not carry ------------------------------------------------------

echo
echo 'a label the issue does not carry is reported, and the run stays green'

seed 84 type:bug area:tooling
out="$(run 84 --remove area:instal)"
check 'it is named, and nothing changed' '#84 -> unchanged  not on it: area:instal' "$out"
check 'the labels are as they were'      'type:bug area:tooling' "$(labels_on 84)"
check 'and no edit was sent'             0 "$(edits)"

# THE PLANTED DEFECT: the same removal sent without reading the issue first, which is
# what a script that trusted its arguments would send.
"$FAKE/bin/gh" issue edit 84 --repo "$REPO" --remove-label area:instal >/dev/null 2>"$FAKE/err"
check 'the plant: sent unread, gh refuses it' 1 "$?"
check 'the plant: and says which name'  yes \
      "$(case "$(cat "$FAKE/err")" in *"'area:instal' not found"*) echo yes ;; *) echo "no: $(cat "$FAKE/err")" ;; esac)"

# --- 4. what the ticket is left missing -------------------------------------------------------

echo
echo 'a ticket left without a type or an area is named'

seed 95 type:bug area:tooling
out="$(run 95 --remove type:bug)"
check 'the missing family is named' '#95 -> -type:bug  MISSING a type label' "$out"

seed 96 type:bug area:tooling
out="$(run 96 --remove area:tooling)"
check 'and so is the other one'     '#96 -> -area:tooling  MISSING an area label' "$out"

# --- 5. a label name holding a space ----------------------------------------------------------

echo
echo 'a label name holding a space stays one argument'

seed 97 'help wanted' type:bug area:tooling
out="$(run 97 --remove 'help wanted')"
check 'it comes off whole'      '#97 -> -help wanted' "$out"
check 'and nothing else went with it' 'type:bug area:tooling' "$(labels_on 97)"

# THE PLANTED DEFECT: the same name word-split, the way a glued command line splits it.
seed 97 'help wanted' type:bug area:tooling
"$FAKE/bin/gh" issue edit 97 --repo "$REPO" --remove-label help wanted >/dev/null 2>"$FAKE/err"
check 'the plant: split in two, gh is asked for a label that does not exist' yes \
      "$(case "$(cat "$FAKE/err")" in *"'help' not found"*) echo yes ;; *) echo "no: $(cat "$FAKE/err")" ;; esac)"
check 'the plant: and the issue keeps it' 'help wanted type:bug area:tooling' "$(labels_on 97)"

# --- 6. the same name on both sides -----------------------------------------------------------

echo
echo 'the same name to add and to remove'

seed 98 type:bug area:tooling
out="$(run 98 --add area:tooling --remove area:tooling)"
check 'is refused, and named' yes \
      "$(case "$out" in *"'area:tooling' is named to add and to remove"*) echo yes ;; *) echo "no: $out" ;; esac)"
check 'and nothing was sent' 0 "$(edits)"

# --- 7. the innocent cases --------------------------------------------------------------------

echo
echo 'a run that only adds, and a second run of it'

seed 99 type:bug
out="$(run 99 --add area:tooling)"
check 'the label goes on'       '#99 -> +area:tooling' "$out"
check 'and the issue carries it' 'type:bug area:tooling' "$(labels_on 99)"

out="$(run 99 --add area:tooling)"
check 'running it again changes nothing' '#99 -> unchanged  already on it: area:tooling' "$out"
check 'and no edit was sent'             0 "$(edits)"

echo
echo 'a call that names no label, and the spelling this script used to take'

seed 102 type:bug area:tooling
out="$(run 102)"
check 'naming no label stops the run' 'error: nothing to do - name a label to add or to remove' "$out"
check 'and nothing was sent' 0 "$(edits)"

# The positional label list this script took before. It must refuse and say what to type,
# rather than reading the label as an issue number or dropping it.
out="$(run 102 type:chore)"
check 'a label where a number belongs is refused' \
      "error: 'type:chore' is not an issue number - a label is named with --add or --remove" "$out"
check 'and nothing was sent' 0 "$(edits)"

echo
echo 'several issues in one call'

seed 100 type:bug area:install
seed 101 type:bug
out="$(run 100 101 --add area:installation --remove area:install)"
check 'each one reports its own line' \
      '#100 -> +area:installation -area:install
#101 -> +area:installation  not on it: area:install' "$out"

# --- 8. the taxonomy of the project the issue's repository belongs to --------------------------------------------------

# The caller stands in a clone of a repository of one project; the issue is one of another project's repository. Its
# taxonomy declares area:ui and area:remote, which the caller's does not.
echo
echo 'the taxonomy of another project, read from its clone'

printf 'area:ui\narea:remote\narea:tracked\narea:base\narea:derived\narea:override\n' >> "$FAKE/repo-labels"
catalog() { cat "$ROOT/templates/.ai-core/labels.tsv"; for a in "$@"; do printf 'area\t%s\t0E8A16\tDeclared by the project\n' "$a"; done; }
catalog area:ui > "$FAKE/catalog-ui"
mkclone "$FAKE/project/caller" example-org/caller-repo
mkclone "$FAKE/project/shop-web" example-org/shop-web "$FAKE/catalog-ui"
mkclone "$FAKE/project/never-installed" example-org/never-installed
rm -rf "$FAKE/project/never-installed/.ai-core"
from_caller() { # from_caller <issue-label.sh argument>...
  : > "$FAKE/calls"; : > "$FAKE/api-calls"
  ( cd "$FAKE/project/caller" && bash "${LABEL_SCRIPT:-$ROOT/bin/issue-label.sh}" "$@" 2>&1 )
}

seed 31 type:bug area:ui
out="$(from_caller example-org/shop-web 31 --remove area:tooling)"
check 'a present area is not missing: removal of an absent label' '#31 -> unchanged  not on it: area:tooling' "$out"
check 'the clone answers, so no forge is read' 0 "$(grep -c . "$FAKE/api-calls")"
seed 31 type:bug
out="$(from_caller example-org/shop-web 31 --add area:ui)"
check 'a label only the target declares goes on'  '#31 -> +area:ui' "$out"
seed 32 type:bug area:tooling
out="$(from_caller example-org/example-repo 32 --add area:ui)"
check 'and the caller'"'"'s own project still refuses it' yes \
      "$(case "$out" in *'"area:ui" is not in the taxonomy'*) echo yes ;; *) echo "no: $out" ;; esac)"
seed 33 type:bug area:ui
out="$(from_caller example-org/shop-web 33 --add area:install)"
check 'a label GitHub still carries but the target no longer declares is refused' yes \
      "$(case "$out" in *'"area:install" is not in the taxonomy'*) echo yes ;; *) echo "no: $out" ;; esac)"
check 'and nothing was sent' 0 "$(edits)"
seed 34 type:bug
out="$(from_caller example-org/never-installed 34 --add area:installation)"
check 'a clone init never ran in answers with the base template' '#34 -> +area:installation' "$out"

# THE PLANTED DEFECT: the caller's catalog read for another project's repository.
rm -rf "$FAKE/plant"; mkdir -p "$FAKE/plant"; cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/templates" "$ROOT/VERSION" "$FAKE/plant/"
sed -i.bak 's|taxonomy="$(target_labels_tsv "$repo")"|taxonomy="$(labels_tsv)"|' "$FAKE/plant/bin/issue-label.sh"
check 'the plant differs from the script' yes "$(cmp -s "$ROOT/bin/issue-label.sh" "$FAKE/plant/bin/issue-label.sh" && echo no || echo yes)"
seed 31 type:bug area:ui
out="$(LABEL_SCRIPT="$FAKE/plant/bin/issue-label.sh" from_caller example-org/shop-web 31 --remove area:tooling)"
check 'the plant: the present area reads as missing' '#31 -> unchanged  not on it: area:tooling  MISSING an area label' "$out"
seed 31 type:bug
out="$(LABEL_SCRIPT="$FAKE/plant/bin/issue-label.sh" from_caller example-org/shop-web 31 --add area:ui)"
check 'the plant: the target'"'"'s own label is refused' yes \
      "$(case "$out" in *'"area:ui" is not in the taxonomy'*) echo yes ;; *) echo "no: $out" ;; esac)"

# --- 9. a target with no clone on this machine: the forge is read --------------------------------------------------

echo
echo 'the taxonomy of another project, read from the forge'

# A remote repository of the stand-in: remote_repo <owner/repo> <commit>; remote_file <owner/repo> <commit> <path> [file].
remote_repo() { mkdir -p "$FAKE/remote/$1"; printf '%s\n' "$2" > "$FAKE/remote/$1/head"; }
remote_file() { mkdir -p "$(dirname "$FAKE/remote/$1/at-$2/$3")"; if [ -n "${4-}" ]; then cp "$4" "$FAKE/remote/$1/at-$2/$3"; else printf '' > "$FAKE/remote/$1/at-$2/$3"; fi; }
manifest() { # manifest <extends repo or empty>: ai-core.json of a harness
  if [ -n "$1" ]; then printf '{"setup-ai-core": ">=1.0.0", "extends": "%s"}\n' "$1"; else printf '{"setup-ai-core": ">=1.0.0"}\n'; fi
}
catalog area:base > "$FAKE/catalog-base"; catalog area:derived > "$FAKE/catalog-derived"
catalog area:override > "$FAKE/catalog-override"; catalog area:tracked > "$FAKE/catalog-tracked"
manifest example-org/base-ai-core > "$FAKE/json-derived"; manifest '' > "$FAKE/json-base"
SHA1=1111111111111111111111111111111111111111; SHA2=2222222222222222222222222222222222222222
SHA3=3333333333333333333333333333333333333333; SHA4=4444444444444444444444444444444444444444
remote_repo example-org/blog-web "$SHA1"
remote_repo example-org/blog-ai-core "$SHA2"; remote_file example-org/blog-ai-core "$SHA2" ai-core.json "$FAKE/json-derived"
remote_repo example-org/base-ai-core "$SHA3"; remote_file example-org/base-ai-core "$SHA3" ai-core.json "$FAKE/json-base"
remote_file example-org/base-ai-core "$SHA3" labels.tsv "$FAKE/catalog-base"

adds() { # adds <issue> <label>: the label is added to a fresh issue of the target without a clone, and the answer printed
  seed "$1" type:bug; from_caller example-org/blog-web "$1" --add "$2"
}
accepted() { check "$1" "#$2 -> +$3" "$(adds "$2" "$3")"; }
refused() { check "$1" yes "$(case "$(adds "$2" "$3")" in *"\"$3\" is not in the taxonomy"*) echo yes ;; *) echo no ;; esac)"; }

accepted 'the base layer of the chain answers where the derived layer has no catalog' 40 area:base
refused 'a label no layer declares is refused' 41 area:derived
check 'only reads were made' 0 "$(grep -vcE '^api repos/[^ ]+/(commits/HEAD --jq \.sha|contents/[^ ]+\?ref=[0-9a-f]+)$' "$FAKE/api-calls" || true)"
remote_file example-org/blog-ai-core "$SHA2" labels.tsv "$FAKE/catalog-derived"
accepted 'the most derived layer wins, whole file' 42 area:derived
refused 'and the base catalog is not merged into it' 43 area:base
remote_file example-org/blog-ai-core "$SHA2" repos/blog-web/.ai-core/labels.tsv "$FAKE/catalog-override"
accepted 'the repository override of the innermost layer wins over its catalog' 44 area:override
refused 'and the catalog it overrides is not merged into it' 45 area:derived
remote_file example-org/blog-web "$SHA1" .ai-core/labels.tsv "$FAKE/catalog-tracked"
accepted 'a catalog the repository tracks itself is read first' 46 area:tracked
refused 'and the layers are not merged into it' 47 area:override
rm -rf "$FAKE/remote/example-org/blog-web/at-$SHA1" "$FAKE/remote/example-org/blog-ai-core/at-$SHA2/repos"

# the project harness is not there at all: init would create it from the skeleton, which carries the base template. The
# forge answers the same for a private harness this account may not read, so the call says which catalog it took.
mv "$FAKE/remote/example-org/blog-ai-core" "$FAKE/blog-ai-core.away"
out="$(adds 48 area:installation)"
check 'a project with no harness is read against the base template' '#48 -> +area:installation' "$(grep -v '^note: ' <<< "$out")"
check 'and the call says so, naming the harness it could not read' yes \
      "$(grep -qx 'note: example-org/blog-ai-core is not there, holds no commit or cannot be read by this account, so example-org/blog-web is read against the base template' <<< "$out" && echo yes || echo "no: $out")"
refused 'and the base template declares nothing else' 49 area:ui
mv "$FAKE/blog-ai-core.away" "$FAKE/remote/example-org/blog-ai-core"

# A branch that moves: the head of the harness is asked once, and every file is read at the commit that answer named.
queue_heads() { printf '%s\n' "$SHA2" "$SHA4" "$SHA4" "$SHA4" "$SHA4" > "$FAKE/remote/example-org/blog-ai-core/head-queue"; }
remote_file example-org/blog-ai-core "$SHA4" labels.tsv "$FAKE/catalog-override"
queue_heads; accepted 'a default branch that moves between two reads does not mix two catalogs' 50 area:derived
queue_heads; refused 'and the catalog of the later commit is not read' 51 area:override
# THE PLANTED DEFECT: every file asked for at the head of the moment, not at the commit pinned
rm -rf "$FAKE/plant2"; mkdir -p "$FAKE/plant2"; cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/templates" "$ROOT/VERSION" "$FAKE/plant2/"
sed -i.bak 's|repo_file_at "$2" "$3" "$4" "$remote_file"|repo_file_at "$2" "$(repo_head_revision "$2")" "$4" "$remote_file"|' "$FAKE/plant2/lib/board.sh"
check 'the plant differs from the resolver' yes "$(cmp -s "$ROOT/lib/board.sh" "$FAKE/plant2/lib/board.sh" && echo no || echo yes)"
queue_heads; seed 52 type:bug
out="$(LABEL_SCRIPT="$FAKE/plant2/bin/issue-label.sh" from_caller example-org/blog-web 52 --add area:override)"
check 'the plant: the catalog of the later commit is read' '#52 -> +area:override' "$out"
rm -f "$FAKE/remote/example-org/blog-ai-core/head-queue"
rm -rf "$FAKE/remote/example-org/blog-ai-core/at-$SHA4"

echo
echo 'a source that cannot be read stops before any edit, and names itself'

stops() { # stops <name> <fragment of the message> <issue>
  seed "$3" type:bug
  out="$(from_caller example-org/blog-web "$3" --add area:derived)"; rc=$?
  check "$1: nothing was sent" 0 "$(edits)"
  check "$1: the message" yes "$(case "$out" in *"$2"*) echo yes ;; *) echo "no: $out" ;; esac)"
}
touch "$FAKE/remote/example-org/blog-ai-core/fail-head"
stops 'a failed read of the harness'     'blog-ai-core could not be read'  60
rm -f "$FAKE/remote/example-org/blog-ai-core/fail-head"
touch "$FAKE/remote/example-org/blog-ai-core/fail-read"
stops 'a failed read of a file'          'was not read from example-org/blog-ai-core (ai-core.json'  61
rm -f "$FAKE/remote/example-org/blog-ai-core/fail-read"
printf 'area\tarea:broken\tnot-a-colour\tIt has a bad colour\n' > "$FAKE/bad-catalog"
remote_file example-org/blog-ai-core "$SHA2" labels.tsv "$FAKE/bad-catalog"
stops 'a malformed catalog'              'has '"'not-a-colour'"' where a six-digit hex colour belongs'  62
remote_file example-org/blog-ai-core "$SHA2" labels.tsv "$FAKE/catalog-derived"
printf '{"extends": 7}\n' > "$FAKE/bad-json"
remote_file example-org/blog-ai-core "$SHA2" ai-core.json "$FAKE/bad-json"
stops 'a malformed ai-core.json'         'ai-core.json of example-org/blog-ai-core is malformed'  63
printf '{"setup-ai-core": ">=999.0.0"}\n' > "$FAKE/json-new"
remote_file example-org/blog-ai-core "$SHA2" ai-core.json "$FAKE/json-new"
stops 'a harness that needs a newer setup-ai-core' 'needs setup-ai-core >=999.0.0'  64
# the next patch release is a newer one too, and a requirement of two numbers, as README.md writes one, is a requirement
IFS=. read -r major minor patch < "$ROOT/VERSION"
printf '{"setup-ai-core": ">=%s.%s.%s"}\n' "$major" "$minor" "$((patch + 1))" > "$FAKE/json-patch"
remote_file example-org/blog-ai-core "$SHA2" ai-core.json "$FAKE/json-patch"
stops 'a harness that needs the next patch release' "needs setup-ai-core >=$major.$minor.$((patch + 1))"  73
printf '{"setup-ai-core": ">=1.0", "extends": "example-org/base-ai-core"}\n' > "$FAKE/json-short"
remote_file example-org/blog-ai-core "$SHA2" ai-core.json "$FAKE/json-short"
accepted 'a requirement of two numbers is read, not called malformed' 70 area:derived
remote_file example-org/blog-ai-core "$SHA2" ai-core.json "$FAKE/json-derived"
mv "$FAKE/remote/example-org/base-ai-core" "$FAKE/base-ai-core.away"
stops 'a base the harness extends that is not there' 'example-org/base-ai-core, which example-org/blog-ai-core extends, is not there'  65
mv "$FAKE/base-ai-core.away" "$FAKE/remote/example-org/base-ai-core"
mv "$FAKE/remote/example-org/blog-web" "$FAKE/blog-web.away"
stops 'a target that is not there'       'example-org/blog-web is not there'  66
mv "$FAKE/blog-web.away" "$FAKE/remote/example-org/blog-web"

# an extends chain of nine layers, and one that runs in a circle
for i in 1 2 3 4 5 6 7 8; do
  remote_repo "example-org/l$i-ai-core" "$SHA3"
  if [ "$i" -lt 8 ]; then manifest "example-org/l$((i + 1))-ai-core" > "$FAKE/json-l"; else manifest '' > "$FAKE/json-l"; fi
  remote_file "example-org/l$i-ai-core" "$SHA3" ai-core.json "$FAKE/json-l"
done
manifest example-org/l1-ai-core > "$FAKE/json-derived-long"
remote_file example-org/blog-ai-core "$SHA2" ai-core.json "$FAKE/json-derived-long"
stops 'an extends chain longer than eight' 'the extends chain of example-org/blog-ai-core is longer than eight'  67
manifest example-org/blog-ai-core > "$FAKE/json-l"
remote_file example-org/l2-ai-core "$SHA3" ai-core.json "$FAKE/json-l"
printf '{"extends": "../escape-ai-core"}\n' > "$FAKE/json-climb"
remote_file example-org/blog-ai-core "$SHA2" ai-core.json "$FAKE/json-climb"
stops 'an extends that names a folder outside the temporary one' 'ai-core.json of example-org/blog-ai-core is malformed'  67
check 'and nothing was written outside it' 0 "$(ls "$FAKE/remote/example-org" | grep -c 'escape')"
for bad in 'example-org/../x' '../x' 'example-org/blog web' 'a/b/c' 'example-org/..'; do
  out="$(from_caller "$bad" 1 --add area:derived)"
  check "the repository '$bad' is refused before anything is read" "yes 0" "$(case "$out" in *"is no OWNER/REPO"*) echo yes ;; *) echo "no: $out" ;; esac) $(grep -c . "$FAKE/api-calls")"
done
remote_file example-org/blog-ai-core "$SHA2" ai-core.json "$FAKE/json-derived-long"
stops 'an extends chain that returns to a layer' 'runs in a circle at example-org/blog-ai-core'  68
remote_file example-org/blog-ai-core "$SHA2" ai-core.json "$FAKE/json-derived"
accepted 'and the restored chain answers again' 69 area:derived

echo
echo 'a harness source is its own catalog, and two targets in one run do not meet'

remote_repo example-org/setup-ai-core "$SHA1"; remote_file example-org/setup-ai-core "$SHA1" templates/.ai-core/labels.tsv "$FAKE/catalog-ui"
seed 71 type:bug; out="$(from_caller example-org/setup-ai-core 71 --add area:ui)"
check 'setup-ai-core answers with its templates' '#71 -> +area:ui' "$out"
remote_repo example-org/team-ai-core "$SHA2"; remote_file example-org/team-ai-core "$SHA2" ai-core.json "$FAKE/json-base"
remote_file example-org/team-ai-core "$SHA2" labels.tsv "$FAKE/catalog-override"
seed 72 type:bug; out="$(from_caller example-org/team-ai-core 72 --add area:override)"
check 'a harness answers with its root catalog' '#72 -> +area:override' "$out"
two="$(cd "$FAKE/project/caller" && TMPDIR="$FAKE/tmp-two" && mkdir -p "$TMPDIR" && export TMPDIR \
  && bash -c '. "$1/lib/board.sh"; for r in example-org/blog-web example-org/team-ai-core example-org/blog-web; do target_labels_tsv "$r" | grep -c "area:override\|area:derived"; done | tr "\n" " "; ls -A "$TMPDIR" | grep -c .' _ "$ROOT" 2>&1 || true)"
check 'each target gets its own catalog, and no temporary file stays' '1 1 1 0' "$(sed 's/ *$//' <<< "$two" | tr '\n' ' ' | sed 's/ *$//')"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo; echo 'all passed'
