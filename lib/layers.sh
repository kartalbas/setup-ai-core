#!/usr/bin/env bash
# The project harness of a checkout: where it is on GitHub, where its clone is on this machine,
# and the chain of harnesses it extends. Sourced by init; do not run it.
#
# THE NAME COMES FROM THE REPOSITORY, nothing is configured: a checkout whose origin is
# github.com/<org>/<repo> belongs to the harness github.com/<org>/<prefix>-ai-core, where prefix is
# the repository name up to its first dash. shop-web and shop-api both belong to shop-ai-core. A
# repository named without a dash is its own prefix.
#
# THE CLONE IS ~/.<prefix>-ai-core, next to the setup-ai-core clone, one per machine and shared by
# every checkout of the project. Its origin is checked against the name before it is used, so a
# clone of another organisation's shop-ai-core never serves this one.
#
# EVERYTHING GITHUB-SIDE GOES THROUGH gh: reading whether the harness exists, cloning it, creating
# it. That is what makes it one login for everything, and what lets the tests stand a fake gh on
# the PATH so nothing reaches github.com.
#
# A harness may extend another one, ai-core.json {"extends": "<org>/<name>-ai-core"}. The chain is
# resolved base first, and a cycle or a chain longer than eight is refused.

# origin_parts <checkout>: prints "<org>\t<repo>" from the origin of the checkout, nothing when
# the checkout has no origin on github.com
origin_parts() {
  local url
  url="$(git -C "$1" remote get-url origin 2>/dev/null)" || return 1
  url="${url%/}"; url="${url%.git}"
  case "$url" in
    *github.com[:/]*/*) url="${url#*github.com}"; url="${url#[:/]}" ;;
    *) return 1 ;;
  esac
  case "$url" in */*/*) return 1 ;; esac
  [ -n "${url%%/*}" ] && [ -n "${url#*/}" ] || return 1
  printf '%s\t%s\n' "${url%%/*}" "${url#*/}"
}

# harness_of <repo name>: the prefix, or nothing for setup-ai-core and for a harness itself
harness_of() {
  case "$1" in
    setup-ai-core) return 1 ;;
    *-ai-core) return 1 ;;
    *-*) echo "${1%%-*}" ;;
    *) echo "$1" ;;
  esac
}

# layer_dir <org>/<name>: the clone on this machine
layer_dir() { echo "$HOME/.${1#*/}"; }

# The origin a clone of <org>/<name> must have
layer_url() { echo "https://github.com/$1.git"; }

# ensure_layer <org>/<name> <setup-ai-core root> [create]: the clone is there and current, or is
# cloned, or is created from the skeleton when "create" is given. Prints the clone directory.
# Exit 1 with a message when it cannot be had.
ensure_layer() {
  local full="$1" root="$2" create="${3:-}" dir origin
  dir="$(layer_dir "$full")"
  if [ -d "$dir/.git" ]; then
    origin="$(git -C "$dir" remote get-url origin 2>/dev/null || true)"
    case "${origin%.git}" in
      *github.com[:/]"$full") ;;
      *) echo "error: $dir is a clone of ${origin:-nothing}, not of $full; move it away" >&2; return 1 ;;
    esac
    if ! git -C "$dir" pull --ff-only --quiet >/dev/null 2>&1; then
      echo "note: could not pull $full into $dir (offline, or the clone has local changes); using it as it is" >&2
    fi
    echo "$dir"; return 0
  fi
  if gh repo view "$full" --json name >/dev/null 2>&1; then
    gh repo clone "$full" "$dir" -- --quiet >/dev/null 2>&1 || { echo "error: could not clone $full to $dir" >&2; return 1; }
    echo "$dir"; return 0
  fi
  [ "$create" = create ] || { echo "error: $full does not exist on GitHub" >&2; return 1; }
  # The skeleton: what every project harness starts from, plus the three data files and the
  # config, so the first init already has something to read
  mkdir -p "$dir"
  cp -R "$root/skeleton/." "$dir/"
  for f in config.env labels.tsv assignees.tsv team-modes.tsv; do cp "$root/templates/.ai-core/$f" "$dir/$f"; done
  git -C "$dir" init -q
  git -C "$dir" add -A
  git -C "$dir" -c user.name="${GIT_AUTHOR_NAME:-ai-core}" -c user.email="${GIT_AUTHOR_EMAIL:-ai-core@localhost}" commit -q -m "the project harness, from the skeleton of setup-ai-core"
  if ! gh repo create "$full" --private --source "$dir" --push >/dev/null 2>&1; then
    rm -rf "$dir"
    echo "error: could not create $full on GitHub (no permission, or gh is not logged in); the harness stays generic" >&2
    return 1
  fi
  echo "created: $full, private, from the skeleton" >&2
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
  local have="$1" want="$2" h w i h1 h2 h3 w1 w2 w3
  IFS=. read -r h1 h2 h3 <<< "$have.0.0"; IFS=. read -r w1 w2 w3 <<< "$want.0.0"
  for i in "$h1:$w1" "$h2:$w2" "$h3:$w3"; do
    h="${i%%:*}"; w="${i#*:}"
    [ "${h:-0}" -gt "${w:-0}" ] 2>/dev/null && return 0
    [ "${h:-0}" -lt "${w:-0}" ] 2>/dev/null && return 1
  done
  return 0
}

# layer_chain <org>/<name> <setup-ai-core root> [create]: every layer from the base down to the
# named one, one clone directory per line, cloned or pulled on the way. The named one may be
# created; a base it extends must exist.
layer_chain() {
  local full="$1" root="$2" create="${3:-}" dir req chain="" seen="" n=0 version
  version="$(tr -d '\r\n' < "$root/VERSION")"
  while [ -n "$full" ]; do
    n=$((n + 1)); [ "$n" -le 8 ] || { echo "error: the extends chain of $1 is longer than eight" >&2; return 1; }
    case " $seen " in *" $full "*) echo "error: the extends chain of $1 runs in a circle at $full" >&2; return 1 ;; esac
    seen="$seen $full"
    dir="$(ensure_layer "$full" "$root" "$create")" || return 1
    create=""
    if req="$(layer_requires "$dir")" && [ -n "$req" ]; then
      case "$req" in ">="*) version_at_least "$version" "${req#>=}" || { echo "error: $full needs setup-ai-core $req and this clone is $version; run ai-core update" >&2; return 1; } ;; esac
    fi
    chain="$dir"$'\n'"$chain"
    full="$(layer_extends "$dir")"
  done
  printf '%s' "$chain"
}
