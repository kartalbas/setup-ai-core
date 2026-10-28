#!/usr/bin/env bash
# The project harness of a checkout: where it is on the forge, where its clone is on this machine,
# and the chain of harnesses it extends. Sourced by init, push, update and session-start; do not
# run it.
#
# THE NAME COMES FROM THE REPOSITORY, nothing is configured: a checkout whose origin is
# github.com/<org>/<repo> belongs to the harness github.com/<org>/<prefix>-ai-core, where prefix is
# the repository name up to its first dash. shop-web and shop-api both belong to shop-ai-core. A
# repository named without a dash is its own prefix.
#
# THE CLONE LIES BESIDE THE REPOSITORIES IT SERVES, visible, a checkout like the others: the
# project folder that holds shop-web and shop-api holds shop-ai-core too. A worktree belongs to
# the folder of its main checkout. Its origin is checked against the name before it is used, so a
# clone of another organisation's shop-ai-core never serves this one. A clone an earlier version
# put into the home directory (~/.<name>-ai-core) is moved beside the repositories when it is
# needed there.
#
# EVERYTHING FORGE-SIDE GOES THROUGH lib/forge.sh: reading whether the harness exists, cloning it,
# creating it. On GitHub that is gh, which makes it one login for everything and lets the tests
# stand a fake gh on the PATH so nothing reaches github.com; the messages name the host
# forge_host gives.
#
# A harness may extend another one, ai-core.json {"extends": "<org>/<name>-ai-core"}. The chain is
# resolved base first, and a cycle or a chain longer than eight is refused.

. "$(dirname "${BASH_SOURCE[0]}")/forge.sh"

# origin_parts <checkout>: prints "<org>\t<repo>" from the origin of the checkout, nothing when
# the checkout has no origin on the forge
origin_parts() {
  local url host
  url="$(git -C "$1" remote get-url origin 2>/dev/null)" || return 1
  url="${url%/}"; url="${url%.git}"
  host="$(forge_host)" || return 1
  case "$url" in
    *"$host"[:/]*/*) url="${url#*"$host"}"; url="${url#[:/]}" ;;
    *) return 1 ;;
  esac
  case "$url" in */*/*) return 1 ;; esac
  [ -n "${url%%/*}" ] && [ -n "${url#*/}" ] || return 1
  printf '%s\t%s\n' "${url%%/*}" "${url#*/}"
}

# origin_host <checkout>: the host the origin names, with its port as the origin spells it; fails
# for a checkout without an origin. An origin that is a path on this disk names itself.
origin_host() {
  local url host
  url="$(git -C "$1" remote get-url origin 2>/dev/null)" || return 1
  case "$url" in
    *://*) host="${url#*://}"; host="${host%%/*}"; host="${host#*@}" ;;
    *@*:*) host="${url#*@}"; host="${host%%:*}" ;;
    *) host="$url" ;;
  esac
  printf '%s\n' "$host"
}

# harness_source_of <checkout>: the source identity comes from Git, never a directory name.
harness_source_of() {
  local parts repo
  parts="$(origin_parts "$1")" || return 1
  repo="${parts#*	}"
  harness_of "$repo" >/dev/null && return 1
  printf '%s/%s\n' "${parts%%	*}" "$repo"
}

# arm_message_hook <tree> <setup-ai-core root>: a harness source is never assembled by init, so the
# commit-msg hook init deploys beside the push gate is written here, untracked and in the clone's own
# exclude file, unless the repository commits its own; prints written, unchanged or tracked.
arm_message_hook() {
  local tree="$1" template="$2/templates/.githooks/commit-msg" exclude
  if git -C "$tree" ls-files --error-unmatch .githooks/commit-msg >/dev/null 2>&1; then echo tracked; return 0; fi
  exclude="$(cd "$tree" && git rev-parse --git-path info/exclude)" || return 1
  case "$exclude" in /*|[A-Za-z]:*) ;; *) exclude="$tree/$exclude" ;; esac
  grep -qxF '/.githooks/commit-msg' "$exclude" 2>/dev/null || printf '%s\n' '/.githooks/commit-msg' >> "$exclude" || return 1
  if cmp -s "$template" "$tree/.githooks/commit-msg" && [ -x "$tree/.githooks/commit-msg" ]; then echo unchanged; return 0; fi
  mkdir -p "$tree/.githooks" && cp "$template" "$tree/.githooks/commit-msg" && chmod 755 "$tree/.githooks/commit-msg" || return 1
  echo written
}

# source_rule_dirs <checkout> <setup-ai-core root>: validate local source inputs, base first.
# Resolving a source must never clone, pull, assemble, or repair it while checking readiness.
source_rule_dirs() {
  local dir="$1" core="$2" folder full expected seen="" n=0 version req extends chain="" checked source_dir file
  [ -s "$core/VERSION" ] && [ -s "$core/rules/skills.md" ] || { echo "error: missing setup-ai-core rule source" >&2; return 1; }
  version="$(tr -d '\r\n' < "$core/VERSION")"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: invalid setup-ai-core VERSION" >&2; return 1; }
  git -C "$core" ls-files --error-unmatch VERSION rules/skills.md >/dev/null 2>&1 \
    || { echo "error: missing tracked setup-ai-core rule source" >&2; return 1; }
  if ! checked="$(bash "$core/bin/rules-check.sh" "$core/rules" 2>&1)"; then printf '%s\n' "$checked" >&2; return 1; fi
  folder="$(project_folder_of "$dir")"
  expected="$(harness_source_of "$dir")" || return 1
  while [ -n "$expected" ]; do
    n=$((n + 1)); [ "$n" -le 8 ] || { echo "error: source extends chain is longer than eight" >&2; return 1; }
    case " $seen " in *" $expected "*) echo "error: source extends chain runs in a circle at $expected" >&2; return 1 ;; esac
    seen="$seen $expected"
    full="$(harness_source_of "$dir" || true)"
    [ "$full" = "$expected" ] || { echo "error: missing or wrong source origin for $expected" >&2; return 1; }
    [ -s "$dir/README.md" ] && [ -d "$dir/rules" ] \
      || { echo "error: missing source README.md or rules directory" >&2; return 1; }
    git -C "$dir" ls-files --error-unmatch README.md 'rules/*' >/dev/null 2>&1 \
      || { echo "error: source README.md and rules must be tracked" >&2; return 1; }
    extends=""
    if [ "${full#*/}" = setup-ai-core ]; then
      git -C "$dir" ls-files --error-unmatch VERSION bin/session-start.sh lib/layers.sh rules/skills.md >/dev/null 2>&1 \
        || { echo "error: missing tracked setup-ai-core source inputs" >&2; return 1; }
      for file in VERSION bin/session-start.sh lib/layers.sh rules/skills.md; do
        [ -s "$dir/$file" ] || { echo "error: missing setup-ai-core source inputs" >&2; return 1; }
      done
      [[ "$(tr -d '\r\n' < "$dir/VERSION")" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: invalid setup-ai-core VERSION" >&2; return 1; }
    else
      git -C "$dir" ls-files --error-unmatch ai-core.json >/dev/null 2>&1 \
        || { echo "error: source ai-core.json must be tracked" >&2; return 1; }
      jq -e -s 'length == 1 and (.[0] | type == "object" and (."setup-ai-core" | type == "string" and test("^>=[0-9]+\\.[0-9]+\\.[0-9]+$")) and (.extends == null or (.extends | type == "string" and test("^[^/]+/[^/]+-ai-core$"))))' "$dir/ai-core.json" >/dev/null 2>&1 \
        || { echo "error: missing or invalid source ai-core.json" >&2; return 1; }
      req="$(layer_requires "$dir")"
      version_at_least "$version" "${req#>=}" \
        || { echo "error: $full needs setup-ai-core $req and this clone is $version; run ai-core update" >&2; return 1; }
      extends="$(layer_extends "$dir")"
    fi
    for source_dir in "$core" "$dir"; do
      while IFS= read -r -d '' file; do
        [ -s "$source_dir/$file" ] || { echo "error: missing source rule file $file" >&2; return 1; }
      done < <(git -C "$source_dir" ls-files -z 'rules/*.md')
    done
    if ! checked="$(bash "$core/bin/rules-check.sh" "$dir" 2>&1)"; then printf '%s\n' "$checked" >&2; return 1; fi
    [ "$dir" = "$core" ] || chain="$dir/rules"$'\n'"$chain"
    expected="$extends"
    [ -z "$expected" ] || dir="$(layer_dir "$expected" "$folder")"
  done
  printf '%s\n' "$core/rules"
  [ -z "$chain" ] || printf '%s' "$chain"
}

# catch_up <checkout>: before ai-core commits a file of its own in a checkout, the checkout comes
# level with its origin: fetched, and fast-forwarded where it is only behind, with no commit of its
# own and no change to a tracked file. Prints what it did, or why it could not and returns 1 then:
# nothing of ai-core is committed on a checkout the origin has moved past, nor on one off a branch,
# where the commit reaches no branch and stays behind. Offline or without an origin it prints
# nothing and returns 0; the push says what happened.
catch_up() {
  local dir="$1" branch behind ahead why=""
  git -C "$dir" remote get-url origin >/dev/null 2>&1 || return 0
  branch="$(git -C "$dir" symbolic-ref --short -q HEAD)" || { echo "on no branch; check out its branch, then run this again"; return 1; }
  git -C "$dir" fetch --quiet origin "$branch" >/dev/null 2>&1 || return 0
  behind="$(git -C "$dir" rev-list --count HEAD..FETCH_HEAD 2>/dev/null)" || return 0
  [ "$behind" -gt 0 ] || return 0
  ahead="$(git -C "$dir" rev-list --count FETCH_HEAD..HEAD)"
  if [ "$ahead" -gt 0 ]; then why="with $ahead commit(s) of its own"
  elif [ -n "$(git -C "$dir" status --porcelain --untracked-files=no)" ]; then why="with changes to tracked files"
  elif ! git -C "$dir" merge --ff-only --quiet FETCH_HEAD >/dev/null 2>&1; then why="and could not be fast-forwarded"
  fi
  if [ -n "$why" ]; then echo "$behind commit(s) behind origin/$branch, $why; pull, then run this again"; return 1; fi
  echo "pulled $behind commit(s) from origin/$branch first"
}

# layer_dir <org>/<name> <folder>: the clone, beside the repositories of the folder
layer_dir() { echo "$2/${1#*/}"; }

# move_layer <org>/<name> <old> <new>: the clone an earlier version kept under the home
# directory goes beside the repositories: copied file by file, never over a file already there,
# so a move that was interrupted (the history here, the files still there) is completed by the
# next run; the old directory goes once every file of it is here unchanged.
move_layer() {
  local full="$1" old="$2" new="$3" differences
  mkdir -p "$new"
  cp -Rpn "$old"/. "$new"/ 2>/dev/null || true   # the exit status of cp -n differs between versions; the comparison judges
  differences="$(diff -rq "$old" "$new" 2>/dev/null)" || true
  if { [ -n "$differences" ] && grep -qvF "Only in $new" <<< "$differences"; } || ! git -C "$new" rev-parse --verify HEAD >/dev/null 2>&1; then
    echo "error: $full is not whole at $new after the move from $old; both directories stay" >&2; return 1
  fi
  rm -rf "$old"
  echo "moved: $full from $old to $new, beside the repositories it serves" >&2
}

# layer_skeleton_file <clone> <setup-ai-core root> <org>/<name> <file> <what it does> [dry]: a
# clone made before the skeleton carried <file> gets the lines of the skeleton's it lacks; the
# next ai-core push commits them. The skeleton's .gitattributes makes every checkout of the harness
# LF (the .githooks shims run through bash, a .tsv keeps its last field)
layer_skeleton_file() {
  local dir="$1" root="$2" full="$3" file="$4" why="$5" mode="${6:-}" have line missing=""
  have="$(tr -d '\r' 2>/dev/null < "$dir/$file" || true)"
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    grep -qxF -- "$line" <<< "$have" || missing="$missing$line"$'\n'
  done < <(tr -d '\r' < "$root/skeleton/$file")
  [ -n "$missing" ] || return 0
  if [ "$mode" = dry ]; then echo "note: $full would get the skeleton's $file ($why; dry run: not written)" >&2; return 0; fi
  if [ -f "$dir/$file" ]; then
    [ -z "$(tail -c 1 "$dir/$file")" ] || printf '\n' >> "$dir/$file"
    printf '%s' "$missing" >> "$dir/$file"
  else
    cp "$root/skeleton/$file" "$dir/$file"
  fi
  echo "note: $full: $file from the skeleton written into $dir ($why); ai-core push commits it" >&2
}

# fill_layer <clone> <setup-ai-core root>: the skeleton, what every project harness starts from,
# plus the two data files and the config, so the first init already has something to read;
# committed as the first commit of the clone. models.tsv and team-modes.tsv are not among them: a
# copy would pin today's table, and the project would never see a later one of setup-ai-core
fill_layer() {
  local dir="$1" root="$2"
  cp -R "$root/skeleton/." "$dir/"
  for f in config.env labels.tsv assignees.tsv; do cp "$root/templates/.ai-core/$f" "$dir/$f"; done
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "the project harness, from the skeleton of setup-ai-core"
}

# ensure_layer <org>/<name> <setup-ai-core root> <folder> [create|dry]: the clone is there and
# current, or is moved from the home directory, or is cloned, or is created from the skeleton
# when "create" is given; "dry" moves and creates nothing. Prints the clone directory. Exit 1
# with a message when it cannot be had.
ensure_layer() {
  local full="$1" root="$2" folder="$3" mode="${4:-}" dir old origin host name
  host="$(forge_host)" || return 1
  name="$(forge_name)" || return 1
  dir="$(layer_dir "$full" "$folder")"
  old="$HOME/.${full#*/}"
  if [ -d "$old/.git" ]; then
    if [ "$mode" = dry ]; then
      echo "note: $full would be moved from $old to $dir, beside the repositories it serves (dry run: not moved)" >&2
      [ -d "$dir/.git" ] || dir="$old"
    else
      move_layer "$full" "$old" "$dir" || return 1
    fi
  fi
  if [ -d "$dir/.git" ]; then
    origin="$(git -C "$dir" remote get-url origin 2>/dev/null || true)"
    case "${origin%.git}" in
      *"$host"[:/]"$full") ;;
      *) echo "error: $dir is a clone of ${origin:-nothing}, not of $full; move it away" >&2; return 1 ;;
    esac
    # A clone with no commit of an origin with none: the empty harness repository somebody with
    # the right to create it made by hand and cloned by hand; the first init fills it from the
    # skeleton and pushes, the way it fills one it creates itself
    if ! git -C "$dir" rev-parse -q --verify HEAD >/dev/null 2>&1 && [ -z "$(git -C "$dir" ls-remote --heads origin 2>/dev/null)" ]; then
      if [ "$mode" = dry ]; then echo "note: $full is empty here and on $name and would be filled from the skeleton (dry run: not written)" >&2; echo "$dir"; return 0; fi
      fill_layer "$dir" "$root" || { echo "error: could not fill $full at $dir from the skeleton" >&2; return 1; }
      git -C "$dir" push --quiet -u origin HEAD >/dev/null 2>&1 || { echo "error: could not push the skeleton to $full (no write access to it?); the clone at $dir keeps it" >&2; return 1; }
      echo "filled: $full, empty on $name, from the skeleton, at $dir" >&2
      echo "$dir"; return 0
    fi
    # A working tree that lost every tracked file (an interrupted move, cleaned up by hand) is
    # checked out again from its history
    if [ "$(git -C "$dir" ls-files 2>/dev/null | wc -l | tr -d ' ')" -gt 0 ] && [ "$(git -C "$dir" status --porcelain 2>/dev/null | grep -c '^ D')" = "$(git -C "$dir" ls-files | wc -l | tr -d ' ')" ]; then
      git -C "$dir" checkout -- . && echo "restored: the files of $full at $dir from its history (every tracked file was missing)" >&2
    fi
    if ! git -C "$dir" pull --ff-only --quiet >/dev/null 2>&1; then
      echo "note: could not pull $full into $dir (offline, or the clone has local changes); using it as it is" >&2
    fi
    layer_skeleton_file "$dir" "$root" "$full" .gitattributes 'every file LF' "$mode"
    echo "$dir"; return 0
  fi
  if repo_exists "$full" >/dev/null 2>&1; then
    [ "$mode" != dry ] || { echo "$dir"; return 0; }
    repo_clone "$full" "$dir" >/dev/null 2>&1 || { echo "error: could not clone $full to $dir" >&2; return 1; }
    # Empty on the forge, made by hand by whoever has the right to create it there: the first init
    # fills it from the skeleton and pushes, the way it fills one it creates itself
    if ! git -C "$dir" rev-parse -q --verify HEAD >/dev/null 2>&1; then
      fill_layer "$dir" "$root" || { echo "error: could not fill $full at $dir from the skeleton" >&2; return 1; }
      git -C "$dir" push --quiet -u origin HEAD >/dev/null 2>&1 || { echo "error: could not push the skeleton to $full (no write access to it?); the clone at $dir keeps it" >&2; return 1; }
      echo "filled: $full, empty on $name, from the skeleton, at $dir" >&2
    fi
    layer_skeleton_file "$dir" "$root" "$full" .gitattributes 'every file LF'
    echo "$dir"; return 0
  fi
  [ "$mode" = create ] || { echo "error: $full does not exist on $name" >&2; return 1; }
  git var GIT_COMMITTER_IDENT >/dev/null || { echo "error: $full is not created: git holds no identity to commit it under (see above)" >&2; return 1; }
  mkdir -p "$dir"
  git -C "$dir" init -q
  fill_layer "$dir" "$root"
  if ! repo_create "$full" "$dir" >/dev/null 2>&1; then
    rm -rf "$dir"
    echo "error: could not create $full on $name (no permission, or $(not_signed_in_words))" >&2
    return 1
  fi
  echo "created: $full, private, from the skeleton, at $dir" >&2
  echo "$dir"
}

# layer_extends <clone dir>: the "extends" of its ai-core.json, or nothing
layer_extends() {
  [ -f "$1/ai-core.json" ] || return 0
  jq -r '.extends // empty' "$1/ai-core.json" 2>/dev/null
}

# layer_requires <clone dir>: the setup-ai-core version its ai-core.json asks for, ">=X.Y.Z" or nothing
layer_requires() {
  [ -f "$1/ai-core.json" ] || return 0
  jq -r '."setup-ai-core" // empty' "$1/ai-core.json" 2>/dev/null
}

# version_at_least <have> <want>: true when have >= want, dotted numbers
version_at_least() {
  local have="$1" want="$2" h w i h1 h2 h3 w1 w2 w3 h_rest w_rest
  # read gives the last name the rest of the line, so the padding goes to a fourth one and the third holds one number
  IFS=. read -r h1 h2 h3 h_rest <<< "$have.0.0"; IFS=. read -r w1 w2 w3 w_rest <<< "$want.0.0"
  for i in "$h1:$w1" "$h2:$w2" "$h3:$w3"; do
    h="${i%%:*}"; w="${i#*:}"
    [ "${h:-0}" -gt "${w:-0}" ] 2>/dev/null && return 0
    [ "${h:-0}" -lt "${w:-0}" ] 2>/dev/null && return 1
  done
  return 0
}

# extends_chain_guard <chain start> <layer> <step, this layer included> <layers seen before>: refuses an
# extends chain longer than eight layers and one that runs in a circle
extends_chain_guard() {
  [ "$3" -le 8 ] || { echo "error: the extends chain of $1 is longer than eight" >&2; return 1; }
  case " $4 " in *" $2 "*) echo "error: the extends chain of $1 runs in a circle at $2" >&2; return 1 ;; esac
}

# layer_chain <org>/<name> <setup-ai-core root> <folder> [create|dry]: every layer from the base
# down to the named one, one clone directory per line, cloned or pulled on the way. The named
# one may be created; a base it extends must exist. "dry" moves, clones and creates nothing:
# a layer that is not there yet is reported as missing.
layer_chain() {
  local full="$1" root="$2" folder="$3" mode="${4:-}" dir req chain="" seen="" n=0 version
  version="$(tr -d '\r\n' < "$root/VERSION")"
  while [ -n "$full" ]; do
    n=$((n + 1)); extends_chain_guard "$1" "$full" "$n" "$seen" || return 1
    seen="$seen $full"
    dir="$(ensure_layer "$full" "$root" "$folder" "$mode")" || return 1
    [ "$mode" = dry ] || mode=""
    if [ -d "$dir" ]; then
      if req="$(layer_requires "$dir")" && [ -n "$req" ]; then
        case "$req" in ">="*) version_at_least "$version" "${req#>=}" || { echo "error: $full needs setup-ai-core $req and this clone is $version; run ai-core update" >&2; return 1; } ;; esac
      fi
    fi
    chain="$dir"$'\n'"$chain"
    full="$([ -d "$dir" ] && layer_extends "$dir" || true)"
  done
  printf '%s' "$chain"
}
