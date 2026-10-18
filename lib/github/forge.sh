#!/usr/bin/env bash
# The forge of this harness on GitHub: repositories, the check of a commit and the signed-in user,
# asked with gh. lib/forge.sh sources it when FORGE is github, which is the default. Source it, do
# not run it.

. "$(dirname "${BASH_SOURCE[0]}")/gh.sh"

forge_host() { echo github.com; }

repo_exists() {  # repo_exists <owner/repo>
  gh repo view "$1" --json name
}

repo_clone() {  # repo_clone <owner/repo> <dir>
  gh repo clone "$1" "$2" -- --quiet
}

repo_create() {  # repo_create <owner/repo> <dir>: private, and pushes the checkout in <dir>
  gh repo create "$1" --private --source "$2" --push
}

# repo_default_branch <owner/repo>: the name of the default branch, nothing for a repository without a
# commit, which has none. Read as defaultBranchRef: the REST default_branch also answers for a
# repository with no commit, and its file list then fails.
repo_default_branch() {
  local page
  page="$(gh_read "the default branch of $1" api graphql -F owner="${1%%/*}" -F name="${1#*/}" -f query='
    query($owner:String!, $name:String!) { repository(owner:$owner, name:$name) {
      defaultBranchRef { name } } }')" || exit 1
  jq -rn 'first(inputs | .data.repository.defaultBranchRef.name // empty)' <<< "$page"
}

repo_file_tree() {  # repo_file_tree <owner/repo>
  gh_read "the files of $1" api "repos/$1/git/trees/HEAD?recursive=1"
}

# commit_checked <checkout> <sha>: green when every workflow run `check` of the commit completed and one
# succeeded, red when they completed and none did, pending while a run has not completed or none
# exists, unreadable when the query failed or answered nothing; then gh's words are on stderr. A query
# that fails is no answer yet: gh or the network fails once while the checks run on.
commit_checked() {
  local runs said
  said="$(mktemp)"
  if runs="$(cd "$1" && gh run list --commit "$2" --workflow check --json status,conclusion --limit 5 2>"$said")" && [ -n "$runs" ]; then
    if [ "$(printf '%s' "$runs" | jq 'length')" -gt 0 ] && printf '%s' "$runs" | jq -e 'all(.status == "completed")' >/dev/null; then
      if printf '%s' "$runs" | jq -e 'any(.conclusion == "success")' >/dev/null; then echo green; else echo red; fi
    else
      echo pending
    fi
  else
    echo unreadable
    tr -s '\r\n' '  ' < "$said" >&2
  fi
  rm -f "$said"
}

# signed_in_user: the login of the GitHub user gh is signed in as, empty where gh cannot say; exit 1
# where gh is missing or nobody is signed in.
signed_in_user() {
  command -v gh >/dev/null 2>&1 || return 1
  gh auth status >/dev/null 2>&1 || return 1
  gh api user -q .login 2>/dev/null || echo ""
}

# clone_sign_in: a checkout signs in to GitHub through gh, once for the machine, so it needs nothing of its own
clone_sign_in() { :; }

# forge_doctor: the gh lines of `ai-core doctor`, through doctor's own report, problem and
# install_tool, which doctor.sh defines.
forge_doctor() {
  local gh_status
  echo "  forge: github"
  if ! command -v gh >/dev/null 2>&1; then install_tool gh gh gh || true; fi
  if command -v gh >/dev/null 2>&1; then
    # the board commands write Projects v2, which a login with gh's default scopes cannot; a token
    # gh lists no scopes for (a fine-grained one, GH_TOKEN) is not judged
    if gh_status="$(gh auth status 2>&1)"; then
      if grep -q 'Token scopes:' <<< "$gh_status" && ! grep -q "'project'" <<< "$gh_status"; then
        report gh "no project scope" "the board commands read and write the project board; run: gh auth refresh -h github.com -s project"; problem
      else
        report gh present "$(gh --version 2>/dev/null | head -1), logged in"
      fi
    else
      report gh "not logged in" "run: gh auth login"; problem
    fi
  else
    report gh MISSING "install GitHub CLI from https://cli.github.com"; problem
  fi
}
