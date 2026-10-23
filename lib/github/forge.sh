#!/usr/bin/env bash
# The forge of this harness on GitHub: repositories, the check of a commit and the signed-in user,
# asked with gh. lib/forge.sh sources it when FORGE is github, which is the default. Source it, do
# not run it.

. "$(dirname "${BASH_SOURCE[0]}")/gh.sh"

forge_host() { echo github.com; }

forge_name() { echo GitHub; }

not_signed_in_words() { echo "gh is not logged in"; }

checks_unreadable_message() {  # checks_unreadable_message <sha> <what gh said last>
  echo "gh could not read the checks of $1 until the deadline; it said last: $2 (is gh logged in?)"
}

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

# forge_repo_visibility <owner/repo>: public or private; fails, saying why, where the forge does not
# establish it.
forge_repo_visibility() {
  gh_repo_visibility "$1"
}

# commit_checked <checkout> <sha>: the workflow runs `check` of the commit and its commit statuses (the
# combined state; a pipeline that posts no run, such as tekton/ci, shows up only there). green when at
# least one result exists, every run completed and one succeeded where runs exist, and the combined
# state is success where statuses exist; red when the runs completed and none succeeded, or the combined
# state is failure or error; pending otherwise; unreadable when a query failed or answered nothing,
# then gh's words are on stderr. A query that fails is no answer yet: gh or the network fails once
# while the checks run on. The runs are listed whatever their workflow and filtered here: `gh run list
# --workflow check` fails on a repository that has no workflow of that name, which a repository with
# statuses alone does not. The listing is wide because other workflows' runs share it.
commit_checked() {
  local repo runs statuses answer said
  said="$(mktemp)"
  repo="$(origin_repo "$1")" || { echo unreadable; echo "$1 has no origin to ask for the checks" >&2; rm -f "$said"; return 0; }
  if runs="$(gh run list -R "$repo" --commit "$2" --json status,conclusion,workflowName --limit 30 2>"$said")" && [ -n "$runs" ] \
    && statuses="$(gh api "repos/$repo/commits/$2/status" 2>>"$said")" && [ -n "$statuses" ] \
    && answer="$(jq -rn --argjson all "$runs" --argjson status "$statuses" '
      if ($all | type) != "array" then error("the workflow runs are not a list") else . end
      | ($all | map(select(.workflowName == "check"))) as $runs
      | ($runs | length) as $runCount
      | ($status.total_count // 0) as $statusCount
      | ($status.state // "") as $state
      | ($runs | all(.status == "completed")) as $runsDone
      | ($runs | any(.conclusion == "success")) as $runPassed
      | if $runCount == 0 and $statusCount == 0 then "pending"
        elif ($runCount > 0 and $runsDone and ($runPassed | not)) or ($statusCount > 0 and ($state == "failure" or $state == "error")) then "red"
        elif ($runCount == 0 or ($runsDone and $runPassed)) and ($statusCount == 0 or $state == "success") then "green"
        else "pending" end' 2>>"$said")"; then
    echo "$answer"
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

# forge_doctor: the lines of `ai-core doctor` for the forge: its name, and gh through gh_doctor.
forge_doctor() {
  echo "  forge: github"
  gh_doctor
}
